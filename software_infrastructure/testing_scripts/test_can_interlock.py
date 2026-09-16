#!/usr/bin/env python3
"""
CAN interlock test (host-side observer).

The CAN frames are transmitted by the STM32 `can_publisher` firmware
(github.com/mzahorodniuk/can_publisher) into the FPGA's CAN core, which receives
the frames and acknowledges them (ACK_DRIVE=true on can_tx). A CAN
value beyond the device's critical limit trips the Data Concentrator's GLOBAL
interlock; the FPGA then emits the ASCII "INTERLOCK" packet over the
W5500/Ethernet path, which the metric server turns into the Prometheus gauge
`last_interlock_assertion`. So the trigger is CAN, but verification is over
Ethernet -- this script only OBSERVES (it sends nothing).

Target device: any slow-control parameter the publisher sends, by name
(default Room_Temperature). The mapping is fixed by can_metric_adapter.vhd:

    metric_id <= rx_id(9 downto 0) & "000000";

so the CAN ID *is* the DeviceTypeID and Device No is always 0:

    CAN ID 1 -> identifier 0x0040 -> Room_Temperature (critical 15 .. 30 degC)
    CAN ID 2 -> identifier 0x0080 -> Room_Humidity    (critical 20 .. 80 %RH)

The limits are not hardcoded here: they are read from the metric server's
`dc_device_upper_threshold` / `dc_device_lower_threshold` gauges, which the
server publishes from the same CSV that generates the FPGA's threshold BRAM.

It polls the metric server's HTTP endpoint (default http://localhost:8001/metrics)
rather than binding UDP 9217-9224, because the running metric server already owns
those ports. (Fallback for when the server is NOT running is documented at the
bottom of this file.)

Examples:
  python test_can_interlock.py                          # watch Room_Temperature
  python test_can_interlock.py --device Room_Humidity
  python test_can_interlock.py --device PSU             # the legacy 0x140 bench test
"""

import argparse
import re
import sys
import time
import urllib.request
from datetime import datetime

# ---- Configuration ----------------------------------------------------------
METRICS_URL   = "http://localhost:8001/metrics"
DEFAULT_DEVICE = "Room_Temperature"   # CAN ID 1 -> identifier 0x0040
POLL_INTERVAL = 0.2          # seconds between scrapes (~5 Hz)
TIMEOUT       = 120.0        # give up waiting for a fresh interlock after this many seconds

Q_SCALE = 1 << 10            # Q22.10 (for reference; the gauge value is already the human float)

# Prometheus text-format line:  name{label="v",...} 123.45
_LINE = re.compile(r'^([a-zA-Z_:][\w:]*)\{([^}]*)\}\s+([-+0-9.eE]+)\s*$')


def fetch_metrics(url):
    """GET the /metrics text, or None if the server is unreachable."""
    try:
        with urllib.request.urlopen(url, timeout=2.0) as resp:
            return resp.read().decode("utf-8", "replace")
    except Exception as exc:  # noqa: BLE001 - report and keep polling
        print(f"  (metric server unreachable at {url}: {exc})")
        return None


def parse_samples(text, name):
    """Return a list of (labels_dict, value_float) for every series of `name`."""
    out = []
    if not text:
        return out
    for line in text.splitlines():
        if not line.startswith(name + "{"):
            continue
        m = _LINE.match(line)
        if not m or m.group(1) != name:
            continue
        labels = dict(re.findall(r'(\w+)="([^"]*)"', m.group(2)))
        try:
            out.append((labels, float(m.group(3))))
        except ValueError:
            pass
    return out


def by_device(text, metric, device):
    """Value of `metric` for the named device, or None."""
    for labels, value in parse_samples(text, metric):
        if labels.get("name") == device:
            return value
    return None


def device_labels(text, device):
    """The label set the metric server attached to this device, or {}."""
    for labels, _ in parse_samples(text, "data_concentrator_0"):
        if labels.get("name") == device:
            return labels
    return {}


def latest_interlock(text):
    """Most recent last_interlock_assertion timestamp across all ports, or None."""
    samples = parse_samples(text, "last_interlock_assertion")
    return max((v for _, v in samples), default=None)


def describe_limits(low, high, unit):
    if low is None and high is None:
        return "no critical limits published"
    lo = "-inf" if low is None else f"{low:g}"
    hi = "+inf" if high is None else f"{high:g}"
    return f"critical {lo} .. {hi} {unit}".strip()


def out_of_range(value, low, high):
    return (low is not None and value < low) or (high is not None and value > high)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--device", default=DEFAULT_DEVICE,
                   help=f"slow-control parameter to watch (default {DEFAULT_DEVICE})")
    p.add_argument("--url", default=METRICS_URL, help=f"metrics endpoint (default {METRICS_URL})")
    p.add_argument("--timeout", type=float, default=TIMEOUT,
                   help=f"seconds to wait for a fresh interlock (default {TIMEOUT:.0f})")
    args = p.parse_args()

    print("=" * 72)
    print("CAN interlock test (observer)")
    print("=" * 72)

    start_ts = time.time()
    text = fetch_metrics(args.url)

    crit_high = by_device(text, "dc_device_upper_threshold", args.device)
    crit_low = by_device(text, "dc_device_lower_threshold", args.device)
    labels = device_labels(text, args.device)
    unit = labels.get("unit", "")
    identifier = labels.get("identifier")
    can_id = int(identifier, 16) >> 6 if identifier else None

    print("Prerequisites:")
    print("  * FPGA running the drain-fixed bitstream; monitoring stack up.")
    print("  * STM32 can_publisher, FPGA can_rx (PMOD B pin 7 / IO_NB_B4) and FPGA")
    print("    can_tx (PMOD B pin 8 / IO_NB_B5) all on one shared wire with a 1k-2.2k")
    print("    pull-up to 3V3 and a common GND (top.vhd wiring config B).")
    print("  * Publisher in scenario 'n' (normal) at start, then press 't' (trip)")
    print("    or 's' (sweep) in its serial monitor.")
    print(f"  * Watching device {args.device!r}"
          + (f" (identifier {identifier}, CAN ID {can_id})" if identifier else " (not seen yet)"))
    print(f"    {describe_limits(crit_low, crit_high, unit)}")
    print(f"  * Watching {args.url}")
    print("-" * 72)
    if crit_high is None and crit_low is None:
        print("WARNING: the metric server publishes no critical limit for this device,")
        print("         so the FPGA cannot trip on it either (fail-safe zero entry).")
    print("Start this WHILE the publisher is in range so the rising edge is caught.")
    print("Ctrl+C to stop.\n")

    # Snapshot any pre-existing latched interlock so we only react to a FRESH one.
    baseline = latest_interlock(text)
    if baseline is not None and baseline <= start_ts:
        when = datetime.fromtimestamp(baseline).strftime("%H:%M:%S")
        print(f"NOTE: an interlock is already latched (last assertion {when}).")
        print("      Press SW3 on the GateMate EVB to clear it, then let the publisher re-trip;")
        print("      this test reports PASS only on a NEW assertion after start.\n")

    last_printed = None
    crossed_at = None          # time we first saw the value leave its critical band
    deadline = start_ts + args.timeout

    try:
        while time.time() < deadline:
            text = fetch_metrics(args.url)

            val = by_device(text, "data_concentrator_0", args.device)
            if val is not None and val != last_printed:
                breached = out_of_range(val, crit_low, crit_high)
                state = "OUT-OF-RANGE" if breached else "in range"
                print(f"  {args.device} = {val:>10.3f} {unit}  ({state})")
                last_printed = val
                if breached and crossed_at is None:
                    crossed_at = time.time()

            ts = latest_interlock(text)
            if ts is not None and ts > start_ts + 1e-3:
                when = datetime.fromtimestamp(ts).strftime("%H:%M:%S.%f")[:-3]
                print("\n" + "=" * 72)
                print("PASS: fresh INTERLOCK assertion observed")
                print("=" * 72)
                print(f"  assertion timestamp : {when}")
                if crossed_at is not None:
                    print(f"  {args.device} left its critical band -> interlock in "
                          f"~{ts - crossed_at:+.3f} s")
                if last_printed is not None:
                    print(f"  last value seen     : {last_printed:.3f} {unit}")
                print("\nThe CAN -> threshold -> interlock -> Ethernet path works.")
                print("Press SW3 on the GateMate EVB to clear the latched interlock.")
                return 0

            time.sleep(POLL_INTERVAL)

    except KeyboardInterrupt:
        print("\nInterrupted.")
        return 130

    print("\n" + "-" * 72)
    print(f"TIMEOUT: no fresh interlock within {args.timeout:.0f} s.")
    if last_printed is None:
        print(f"  No metric named {args.device!r} seen at all -> is the publisher sending")
        print(f"  CAN ID {can_id if can_id is not None else '<the right ID>'}, and is CAN "
              "telemetry reaching the host? Check")
        print("  `curl -s http://localhost:8001/metrics | grep data_concentrator_0`.")
    elif crossed_at is None:
        print("  The value never left its critical band -> the publisher is probably still")
        print("  in scenario 'n'; press 't' or 's' in its serial monitor.")
    else:
        print("  The value left its critical band but no INTERLOCK arrived -> check that the")
        print("  FPGA's CAN_THRESHOLD_TABLE has an entry for this DeviceTypeID, the")
        print("  W5500/Ethernet return path, and that the bitstream has the drain fix.")
    return 1


# -----------------------------------------------------------------------------
# Fallback (metric server NOT running): bind the UDP ports directly and watch for
# the raw INTERLOCK packet, like measure_time_until_alert.py. Only use this if
# :8001 is down, since the metric server otherwise owns these ports.
#
#   import socket
#   s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
#   s.bind(("192.168.2.106", 9217))           # one of 9217-9224
#   while True:
#       data, addr = s.recvfrom(4096)
#       if data == b"INTERLOCK":
#           print("INTERLOCK from", addr); break
# -----------------------------------------------------------------------------

if __name__ == "__main__":
    sys.exit(main())
