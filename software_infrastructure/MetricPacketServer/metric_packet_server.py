#!/usr/bin/env python3
"""
UDP Metrics Server for Prometheus

Listens on UDP ports 9217-9224 for metric records in the format:
- 3 bytes: Protocol version (expected: "V01")
- 2 bytes: Metric identifier ((DeviceTypeID << 6) | DeviceNo)
- 4 bytes: 32-bit Q22.10 metric value

One datagram carries one OR MORE such records back to back. The FPGA
accumulates up to TX_BATCH_MAX_PACKETS (16) records in the W5500's per-socket
transmit buffer and issues SEND once, so a datagram is normally 9 * N bytes --
9 bytes only when the batch happened to close after a single record. Alerts
(INTERLOCK / ALMOSTFULL) always arrive alone: batch_solo in
w5500_state_machine.vhd closes the datagram around any payload that is not a
V01 record.

Metric identifiers are mapped to human-readable device names/units/limits via
two catalogs:
  * device_catalog.json        - transcribed from the FPGA threshold BRAM
  * slow_control_catalog.json  - generated from Slow_control_protocol_example.csv
                                 by build_slow_control_catalog.py
Each reading is classified against its catalog limits (ok / warning / critical)
and exposed, together with the raw value and the limits themselves, via an HTTP
endpoint for Prometheus to scrape.
"""

import json
import logging
import os
import socket
import struct
import threading
import time

from prometheus_client import Counter, Gauge, start_http_server

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
UDP_PORTS = range(9217, 9225)  # Ports 9217 to 9224 (inclusive)
PROMETHEUS_PORT = 8001
PACKET_SIZE = 9  # 3 + 2 + 4 bytes, one metric record
# The W5500 socket transmit/receive buffers are 2 KB, which is the largest
# datagram this design can emit; reading that much means a deeper RTL batch
# never arrives truncated.
RECV_BUFFER_SIZE = 2048
PROTOCOL_VERSION = b'V01'
HERE = os.path.dirname(os.path.abspath(__file__))
# Only devices in these catalogs are published. slow_control_catalog.json is
# generated from Slow_control_protocol_example.csv, so the exposed series are
# exactly the CSV's parameters, named by their Parameter_Name.
# Append device_catalog.json here to also publish the pre-CSV bench devices
# (PSU/COIL/FAN speed/system load). Later catalogs win on identifier collisions.
CATALOG_PATHS = [
    os.path.join(HERE, 'slow_control_catalog.json'),
]

SEVERITY_OK = 0
SEVERITY_WARNING = 1
SEVERITY_CRITICAL = 2

FRACTION_BITS = 10
SCALE = 1 << FRACTION_BITS

# ---- Prometheus metrics -----------------------------------------------------
# Main metric. Carries name/unit labels resolved from the device catalog so
# dashboards can show human-readable devices; identifier is kept for backwards
# compatibility and for joining against the threshold gauges below.
#
# Deliberately NOT labelled by port. A parameter can reach us over more than one
# transport -- Room_Temperature is Transfer=CAN in the CSV but simulate_devices.py
# also injects it over UDP -- and the port a reading arrives on is a property of
# the transport, not of the sensor. Labelling by it split every such parameter
# into two competing lines on the dashboard, and left a frozen series behind
# whenever a subsystem's port assignment changed. One device, one series: the
# most recent reading wins, whichever channel carried it. Per-port/per-transport
# activity is still visible in the dc_*_total counters below.
DATA_CONCENTRATOR = Gauge(
    'data_concentrator_0',
    'Latest metric value received from the data concentrator, from whichever '
    'transport carried it last',
    ['identifier', 'name', 'unit', 'subsystem']
)

LAST_INTERLOCK = Gauge(
    'last_interlock_assertion',
    'Unix timestamp (ms precision) of the last INTERLOCK packet',
    ['port']
)

# Diagnostic counters (drive the admin dashboard).
PACKETS_TOTAL = Counter(
    'dc_metric_packets_total', 'Valid V01 metric packets received', ['port']
)
INVALID_PACKETS_TOTAL = Counter(
    'dc_invalid_packets_total', 'Malformed records (bad protocol) or trailing bytes', ['port']
)
DATAGRAMS_TOTAL = Counter(
    'dc_metric_datagrams_total',
    'Datagrams carrying metric records. Divide dc_metric_packets_total by this '
    'to get the achieved batch size (1.0 means batching is not in effect)',
    ['port']
)
ALMOSTFULL_TOTAL = Counter(
    'dc_almostfull_total', 'ALMOSTFULL (FIFO congestion) alerts received', ['port']
)
INTERLOCK_TOTAL = Counter(
    'dc_interlock_total', 'INTERLOCK assertions received', ['port']
)
UNKNOWN_IDENTIFIER_TOTAL = Counter(
    'dc_unknown_identifier_packets_total',
    'Valid V01 packets whose identifier is not a catalog (CSV) parameter; '
    'counted here instead of creating an unnamed device_<id> series',
    ['port']
)

# Per-device limits, published once at startup from the catalog so Grafana can
# draw limit lines. upper/lower are the *critical* (interlock) limits; the
# warning band is the operator-alert band inside them.
DEVICE_UPPER_THRESHOLD = Gauge(
    'dc_device_upper_threshold', 'Critical (interlock) upper limit for a device',
    ['identifier', 'name', 'unit', 'subsystem']
)
DEVICE_LOWER_THRESHOLD = Gauge(
    'dc_device_lower_threshold', 'Critical (interlock) lower limit for a device',
    ['identifier', 'name', 'unit', 'subsystem']
)
DEVICE_WARN_HIGH = Gauge(
    'dc_device_warn_high', 'Warning upper limit for a device',
    ['identifier', 'name', 'unit', 'subsystem']
)
DEVICE_WARN_LOW = Gauge(
    'dc_device_warn_low', 'Warning lower limit for a device',
    ['identifier', 'name', 'unit', 'subsystem']
)
DEVICE_NOMINAL = Gauge(
    'dc_device_nominal', 'Nominal (expected) value for a device',
    ['identifier', 'name', 'unit', 'subsystem']
)

# Severity of the most recent reading, evaluated against the catalog limits.
# 0 = ok, 1 = warning band, 2 = critical / interlock condition. This is what the
# overview dashboard filters on, so the alarm view needs no PromQL joins.
DEVICE_SEVERITY = Gauge(
    'dc_device_severity',
    'Severity of the last reading: 0=ok, 1=warning, 2=critical',
    ['identifier', 'name', 'unit', 'subsystem', 'priority', 'interlock']
)
DEVICE_LAST_SEEN = Gauge(
    'dc_device_last_seen_timestamp_seconds',
    'Unix timestamp of the last packet received from a device',
    ['identifier', 'name', 'subsystem']
)


def load_catalogs(paths) -> dict:
    """Merge the identifier -> device-metadata catalogs; later files win."""
    merged = {}
    for path in paths:
        try:
            with open(path) as f:
                devices = json.load(f).get('devices', {})
        except FileNotFoundError:
            logger.warning(f"Device catalog {path} not found; skipping")
            continue
        except (OSError, ValueError) as exc:
            logger.warning(f"Could not load device catalog at {path}: {exc}; skipping")
            continue
        for identifier, entry in devices.items():
            # Normalise keys to lowercase hex, matching bytes.hex() output.
            merged[identifier.lower()] = normalise_entry(entry, identifier.lower())
        logger.info(f"Loaded {len(devices)} device(s) from {os.path.basename(path)}")
    return merged


def normalise_entry(entry: dict, identifier: str) -> dict:
    """Bring both catalog formats onto one set of keys."""
    normalised = dict(entry)
    normalised.setdefault('name', f'device_{identifier}')
    normalised.setdefault('unit', '')
    normalised.setdefault('subsystem', 'unassigned')
    normalised.setdefault('priority', '')
    normalised.setdefault('interlock', '')
    normalised.setdefault('kind', 'analog')
    # device_catalog.json (FPGA BRAM) calls the interlock limits lower/upper.
    if 'crit_low' not in normalised and 'lower' in normalised:
        normalised['crit_low'] = normalised['lower']
    if 'crit_high' not in normalised and 'upper' in normalised:
        normalised['crit_high'] = normalised['upper']
    return normalised


CATALOG = load_catalogs(CATALOG_PATHS)


def device_meta(identifier: str):
    """Return the catalog entry for an identifier, or None if it is not a
    CSV parameter. Unknown identifiers are deliberately NOT published: an
    unnamed device_<id> series is noise on the dashboards and cannot be
    classified against any limits."""
    return CATALOG.get(identifier)


def classify(entry: dict, value: float) -> int:
    """Rate a reading against its catalog limits (0=ok, 1=warning, 2=critical)."""
    if entry.get('kind') == 'boolean':
        # Booleans are nominal-1 signals (e.g. Emergency_Stop continuity):
        # anything but asserted is a critical condition.
        return SEVERITY_OK if value >= 0.5 else SEVERITY_CRITICAL

    crit_low, crit_high = entry.get('crit_low'), entry.get('crit_high')
    if (crit_low is not None and value < crit_low) or \
       (crit_high is not None and value > crit_high):
        return SEVERITY_CRITICAL

    warn_low, warn_high = entry.get('warn_low'), entry.get('warn_high')
    if (warn_low is not None and value < warn_low) or \
       (warn_high is not None and value > warn_high):
        return SEVERITY_WARNING

    return SEVERITY_OK


def publish_thresholds():
    """Expose catalog limits as gauges so dashboards can draw/annotate them."""
    limit_gauges = (
        ('crit_high', DEVICE_UPPER_THRESHOLD),
        ('crit_low', DEVICE_LOWER_THRESHOLD),
        ('warn_high', DEVICE_WARN_HIGH),
        ('warn_low', DEVICE_WARN_LOW),
        ('nominal', DEVICE_NOMINAL),
    )
    for identifier, entry in CATALOG.items():
        labels = dict(
            identifier=identifier, name=entry['name'],
            unit=entry['unit'], subsystem=entry['subsystem'],
        )
        for key, gauge in limit_gauges:
            if entry.get(key) is not None:
                gauge.labels(**labels).set(entry[key])


def from_q_format_32(qval: int) -> float:
    """
    Convert a signed 32-bit Q(M).10 fixed-point integer back to a float.
    """
    # Interpret as signed 32-bit integer
    if qval & 0x80000000:  # if sign bit is set
        qval = -((~qval & 0xFFFFFFFF) + 1)

    return qval / SCALE


def split_records(data: bytes):
    """Split one datagram into fixed-size records.

    Returns (records, trailing) -- a list of PACKET_SIZE-byte slices, plus any
    bytes left over. A well-formed datagram divides exactly; a non-zero
    remainder means the datagram was truncated or is not a metric datagram at
    all, and the caller counts it as invalid. The whole records that precede a
    remainder are still returned: they parsed cleanly and dropping them would
    lose readings the FPGA did send.
    """
    whole = len(data) // PACKET_SIZE
    records = [data[i * PACKET_SIZE:(i + 1) * PACKET_SIZE] for i in range(whole)]
    return records, data[whole * PACKET_SIZE:]


def parse_record(record: bytes):
    """Parse one PACKET_SIZE-byte V01 record into (identifier, value)."""
    protocol = record[0:3]
    if protocol != PROTOCOL_VERSION:
        logger.warning(
            f"Invalid protocol version: {protocol} (expected {PROTOCOL_VERSION}), record: {record}"
        )
        return None

    identifier_str = record[3:5].hex()
    value = struct.unpack('>i', record[5:9])[0]
    return identifier_str, from_q_format_32(value)


def publish_reading(port: int, identifier: str, value: float, addr) -> None:
    """Expose one reading, or count it as unknown if it is not in the catalog."""
    entry = device_meta(identifier)
    PACKETS_TOTAL.labels(port=str(port)).inc()

    if entry is None:
        UNKNOWN_IDENTIFIER_TOTAL.labels(port=str(port)).inc()
        logger.debug(
            f"Port {port}: identifier {identifier} is not a catalog "
            f"parameter (value {value}) -- not published"
        )
        return

    name, unit = entry['name'], entry['unit']
    subsystem = entry['subsystem']
    logger.debug(f"Port {port}: Received metric {name} ({identifier})={value} from {addr}")

    DATA_CONCENTRATOR.labels(
        identifier=identifier, name=name, unit=unit, subsystem=subsystem
    ).set(value)
    DEVICE_SEVERITY.labels(
        identifier=identifier, name=name, unit=unit,
        subsystem=subsystem, priority=entry['priority'],
        interlock=entry['interlock']
    ).set(classify(entry, value))
    DEVICE_LAST_SEEN.labels(
        identifier=identifier, name=name, subsystem=subsystem
    ).set(time.time())


def udp_listener(port: int):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('0.0.0.0', port))

    logger.info(f"UDP listener started on port {port}")

    while True:
        try:
            # A full batch is TX_BATCH_MAX_PACKETS * PACKET_SIZE = 144 bytes, but
            # size the buffer for the W5500's whole 2 KB socket buffer so raising
            # the batch depth in the RTL cannot silently truncate a datagram here.
            data, addr = sock.recvfrom(RECV_BUFFER_SIZE)

            # Alerts are checked first and compared against the whole datagram.
            # That is exact, not a heuristic: batch_solo in the RTL guarantees a
            # non-V01 payload is the only thing in its datagram. Note INTERLOCK is
            # itself 9 bytes, so this test has to come before record splitting.
            if data == b'INTERLOCK':
                timestamp = time.time()
                LAST_INTERLOCK.labels(port=str(port)).set(timestamp)
                INTERLOCK_TOTAL.labels(port=str(port)).inc()
                logger.info(f"INTERLOCK assertion received on port {port} at {timestamp}")
                continue

            if data == b'ALMOSTFULL':
                ALMOSTFULL_TOTAL.labels(port=str(port)).inc()
                logger.info("ALMOST FULL, FIFO Congestion detected in Data Concentrator")
                continue

            records, trailing = split_records(data)

            if trailing:
                INVALID_PACKETS_TOTAL.labels(port=str(port)).inc()
                logger.warning(
                    f"Port {port}: datagram of {len(data)} bytes is not a whole "
                    f"number of {PACKET_SIZE}-byte records; {len(trailing)} "
                    f"trailing byte(s) discarded: {trailing!r}"
                )

            if not records:
                continue

            DATAGRAMS_TOTAL.labels(port=str(port)).inc()

            for record in records:
                parsed = parse_record(record)
                if parsed is None:
                    INVALID_PACKETS_TOTAL.labels(port=str(port)).inc()
                    continue
                identifier, value = parsed
                publish_reading(port, identifier, value, addr)

        except Exception as e:
            logger.error(f"Error in UDP listener on port {port}: {e}", exc_info=True)


def main():
    logger.info("Starting UDP Metrics Server for Prometheus")
    subsystems = sorted({e['subsystem'] for e in CATALOG.values()})
    logger.info(f"Device catalog: {len(CATALOG)} named device(s) across "
                f"{len(subsystems)} subsystem(s): {', '.join(subsystems)}")
    publish_thresholds()

    start_http_server(PROMETHEUS_PORT)
    logger.info(f"Prometheus metrics endpoint started on http://0.0.0.0:{PROMETHEUS_PORT}/metrics")

    threads = []
    for port in UDP_PORTS:
        thread = threading.Thread(target=udp_listener, args=(port,), daemon=True)
        thread.start()
        threads.append(thread)
        logger.info(f"Started listener thread for UDP port {port}")

    logger.info(f"All listeners started. Listening on ports {list(UDP_PORTS)}")
    logger.info("Press Ctrl+C to stop")

    try:  # keep main thread alive
        for thread in threads:
            thread.join()
    except KeyboardInterrupt:
        logger.info("Shutting down...")


if __name__ == '__main__':
    main()
