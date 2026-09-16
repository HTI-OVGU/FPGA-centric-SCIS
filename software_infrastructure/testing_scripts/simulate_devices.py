#!/usr/bin/env python3
"""
Slow-control device simulator for the SCIS data concentrator.

Sends UDP traffic AS THE REAL NAMED PARAMETERS of the slow-control protocol
(`software_infrastructure/Slow_control_protocol_example.csv`, expanded into
`MetricPacketServer/slow_control_catalog.json` by `build_slow_control_catalog.py`):
Safety interlocks, room environment, mains voltage, ADC/DAC board rails and FPGA
temperatures, and the 64-channel LNA / VCO / PA / Switch arrays.

Every device is simulated with the properties the CSV gives it:

  * its identifier      -- (DeviceTypeID << 6) | DeviceNo, exactly what the FPGA
                           CAN adapter puts on the wire, so the metric server
                           labels the series with the real name/unit/subsystem
  * its nominal value   -- readings jitter around it
  * its warning band    -- Warning_Low / Warning_High
  * its critical band   -- Critical_Low / Critical_High (the interlock limits)
  * its sample interval -- Measurement_Interval_s (clamped, see --max-interval)

A single scheduler thread paces all devices, so simulating hundreds of
parameters costs one socket and one thread.

Scenarios:
  normal      every device jitters inside its warning band (all green)
  warn        every device with a warning band sits inside it (no interlock)
  trip        every device is pushed past its critical limit (interlock)
  fault       realistic mix: everything normal except --faults random devices
              that go into warning/critical -- the best dashboard demo
  sweep       one device ramps nominal -> past its critical limit, then holds
  dropout     everything normal, then --faults devices stop reporting (stale)
  congestion  one device is flooded at --rate to provoke ALMOSTFULL

This is a *sender-only* tool, so it is safe to run while the metric server owns
the UDP ports (unlike the rtt/random_port scripts).

Examples:
  python simulate_devices.py                                   # normal, all subsystems
  python simulate_devices.py --scenario fault --faults 5
  python simulate_devices.py --subsystem Safety --subsystem ADC --scenario trip
  python simulate_devices.py --scenario sweep --device Room_Temperature --duration 60
  python simulate_devices.py --channels 64 --scenario normal   # full 64-ch arrays
  python simulate_devices.py --target 127.0.0.1                # dashboards only, no FPGA
"""

import argparse
import fnmatch
import heapq
import json
import os
import random
import socket
import struct
import sys
import time

PROTOCOL_CODE = b"V01"
BASE_PORT = 9217
NUM_PORTS = 8  # ports 9217-9224
DEVICE_NO_BITS = 6

_CATALOG_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "MetricPacketServer"
)
DEFAULT_CATALOGS = [os.path.join(_CATALOG_DIR, "slow_control_catalog.json")]
BRAM_CATALOG = os.path.join(_CATALOG_DIR, "device_catalog.json")

SEVERITY_NAMES = {0: "ok", 1: "warning", 2: "critical"}
SWEEP_INTERVAL = 0.5  # sample period forced on the swept device, seconds

# The FPGA's RX W5500 -- where metric packets are INGESTED (see the top-level
# README). Sending anywhere else means no RX LED activity and no interlock.
FPGA_RX_IP = "192.168.2.100"
LOCAL_TARGETS = ("127.0.0.1", "localhost", "::1")


# ---- Packet encoding --------------------------------------------------------

def float_to_q22_10(value):
    """Q22.10: value * 2^10, as a signed 32-bit int (matches the FPGA format)."""
    q = int(round(value * (1 << 10)))
    return max(-(1 << 31), min((1 << 31) - 1, q))


def build_packet(identifier_hex, value):
    """9-byte V01 packet: 'V01' + 2-byte id (big-endian) + 4-byte Q22.10 value."""
    identifier = int(identifier_hex, 16)
    return struct.pack("!3sH i", PROTOCOL_CODE, identifier, float_to_q22_10(value))


# ---- Catalog ----------------------------------------------------------------

def load_devices(catalog_paths, base_port=BASE_PORT):
    """Merge the catalogs into a list of device dicts; later files win."""
    merged = {}
    for path in catalog_paths:
        try:
            with open(path, encoding="utf-8") as f:
                devices = json.load(f).get("devices", {})
        except OSError as exc:
            raise SystemExit(f"Cannot read catalog {path}: {exc}")
        for identifier, entry in devices.items():
            merged[identifier.lower()] = dict(entry, identifier=identifier.lower())

    subsystems = sorted({e.get("subsystem", "unassigned") for e in merged.values()})
    out = []
    for identifier, entry in sorted(merged.items()):
        subsystem = entry.get("subsystem", "unassigned")
        dev = {
            "identifier": identifier,
            "name": entry.get("name", f"device_{identifier}"),
            "unit": entry.get("unit", ""),
            "subsystem": subsystem,
            "priority": entry.get("priority", ""),
            "kind": entry.get("kind", "analog"),
            "type_id": entry.get("type_id", int(identifier, 16) >> DEVICE_NO_BITS),
            "device_no": entry.get("device_no", int(identifier, 16) & 0x3F),
            "nominal": entry.get("nominal"),
            "warn_low": entry.get("warn_low"),
            "warn_high": entry.get("warn_high"),
            # device_catalog.json (FPGA BRAM) calls the interlock limits lower/upper
            "crit_low": entry.get("crit_low", entry.get("lower")),
            "crit_high": entry.get("crit_high", entry.get("upper")),
            "interval": entry.get("interval"),
            # Group a subsystem onto one UDP port so per-port throughput on the
            # admin dashboard is meaningful.
            "port": base_port + (subsystems.index(subsystem) % NUM_PORTS),
        }
        if dev["nominal"] is None:
            dev["nominal"] = _implied_nominal(dev)
        out.append(dev)
    return out


def _implied_nominal(dev):
    """Fall back to the middle of whatever band the CSV does give us."""
    low = dev["warn_low"] if dev["warn_low"] is not None else dev["crit_low"]
    high = dev["warn_high"] if dev["warn_high"] is not None else dev["crit_high"]
    if low is not None and high is not None:
        return (low + high) / 2.0
    if high is not None:
        return high * 0.5
    if low is not None:
        return low * 1.5
    return 1.0


def select_devices(devices, args):
    """Apply the --subsystem / --device / --priority / --channels filters."""
    if args.subsystem:
        wanted = {s.lower() for arg in args.subsystem for s in arg.split(",")}
        devices = [d for d in devices if d["subsystem"].lower() in wanted]
    if args.priority:
        wanted = {p.lower() for arg in args.priority for p in arg.split(",")}
        devices = [d for d in devices if d["priority"].lower() in wanted]
    if args.device:
        patterns = [p for arg in args.device for p in arg.split(",")]
        devices = [d for d in devices
                   if any(fnmatch.fnmatch(d["name"].lower(), p.lower().strip())
                          or d["name"].lower() == p.lower().strip()
                          for p in patterns)]
    if args.channels:
        # Keep only the first N instances of any device type with more than N.
        per_type = {}
        for d in devices:
            per_type.setdefault(d["type_id"], []).append(d)
        devices = [d for d in devices
                   if len(per_type[d["type_id"]]) <= args.channels
                   or d["device_no"] < args.channels]
    return devices


# ---- Limits and value generation --------------------------------------------

def ok_band(dev):
    """(low, high) the reading should stay inside for the device to read 'ok'."""
    low = dev["warn_low"] if dev["warn_low"] is not None else dev["crit_low"]
    high = dev["warn_high"] if dev["warn_high"] is not None else dev["crit_high"]
    nominal = dev["nominal"]
    if low is None and high is None:
        # No limits in the CSV (the LNA/VCO/PA/Switch arrays): jitter +-5% of
        # nominal, but never below one Q22.10 LSB or the jitter is invisible.
        span = max(abs(nominal) * 0.05, 1.0 / (1 << 10))
        return nominal - span, nominal + span
    if low is None:
        low = nominal - abs(high - nominal)
    if high is None:
        high = nominal + abs(nominal - low)
    return low, high


def has_warning_band(dev):
    return dev["warn_low"] is not None or dev["warn_high"] is not None


def has_critical_band(dev):
    return dev["kind"] == "boolean" or \
        dev["crit_low"] is not None or dev["crit_high"] is not None


def value_normal(dev, t):
    """Jitter around nominal, clamped so a 'normal' run never raises an alarm."""
    if dev["kind"] == "boolean":
        return 1.0
    low, high = ok_band(dev)
    nominal = min(max(dev["nominal"], low), high)
    sigma = max(min(nominal - low, high - nominal) / 4.0, abs(nominal) * 1e-3, 1e-3)
    margin = (high - low) * 0.02
    return min(max(random.gauss(nominal, sigma), low + margin), high - margin)


def value_warning(dev, t):
    """A reading inside the warning band but short of the interlock limit."""
    if dev["kind"] == "boolean":
        return 1.0  # booleans have no warning state
    if dev["warn_high"] is not None:
        top = dev["crit_high"] if dev["crit_high"] is not None else dev["warn_high"] * 1.1
        return dev["warn_high"] + max(top - dev["warn_high"], abs(top) * 0.01) * 0.4
    if dev["warn_low"] is not None:
        bottom = dev["crit_low"] if dev["crit_low"] is not None else dev["warn_low"] * 0.9
        return dev["warn_low"] - max(dev["warn_low"] - bottom, abs(bottom) * 0.01) * 0.4
    return value_normal(dev, t)  # nothing to warn about


def value_critical(dev, t):
    """A reading past the interlock limit."""
    if dev["kind"] == "boolean":
        return 0.0  # e.g. Emergency_Stop continuity lost
    if dev["crit_high"] is not None:
        return dev["crit_high"] + max(abs(dev["crit_high"]) * 0.1, 0.5)
    if dev["crit_low"] is not None:
        return dev["crit_low"] - max(abs(dev["crit_low"]) * 0.1, 0.5)
    return value_warning(dev, t)  # no critical limit configured


def value_sweep(dev, t, duration):
    """Ramp nominal -> past the critical limit over 80% of the run, then hold."""
    if dev["kind"] == "boolean":
        return 1.0 if t < duration * 0.8 else 0.0
    target = value_critical(dev, t)
    frac = min(t / max(duration * 0.8, 1e-6), 1.0)
    return dev["nominal"] + (target - dev["nominal"]) * frac


SCENARIOS = ("normal", "warn", "trip", "fault", "sweep", "dropout", "congestion")


# ---- Runner -----------------------------------------------------------------

class Simulation:
    """Holds the per-device plan and answers 'what should this device send now'."""

    def __init__(self, devices, args):
        self.args = args
        self.devices = devices
        self.duration = args.duration
        self.faulted = {}   # name -> "warning" | "critical"
        self.silenced = set()
        self.sweeping = None

        if args.scenario == "fault":
            candidates = [d for d in devices if has_warning_band(d) or has_critical_band(d)]
            for dev in random.sample(candidates, min(args.faults, len(candidates))):
                # Booleans (and devices with no warning band) can only fail hard.
                if has_critical_band(dev) and (dev["kind"] == "boolean"
                                               or not has_warning_band(dev)
                                               or random.random() < 0.5):
                    self.faulted[dev["name"]] = "critical"
                else:
                    self.faulted[dev["name"]] = "warning"
        elif args.scenario == "dropout":
            for dev in random.sample(devices, min(args.faults, len(devices))):
                self.silenced.add(dev["name"])
        elif args.scenario in ("sweep", "congestion"):
            self.sweeping = devices[0]

    def interval_for(self, dev, args):
        interval = effective_interval(dev, args)
        if self.sweeping is dev and args.scenario == "sweep":
            # A ramp is only readable if it is sampled often, whatever the CSV
            # says about this parameter's measurement interval.
            return min(interval, SWEEP_INTERVAL)
        return interval

    def should_send(self, dev, t):
        if dev["name"] in self.silenced:
            # Devices go quiet halfway into the run (or after 10 s if endless).
            return t < (self.duration * 0.5 if self.duration else 10.0)
        return True

    def value(self, dev, t):
        scenario = self.args.scenario
        if scenario == "warn":
            return value_warning(dev, t)
        if scenario == "trip":
            return value_critical(dev, t)
        if scenario == "sweep":
            if dev is self.sweeping:
                return value_sweep(dev, t, self.duration or 30.0)
            return value_normal(dev, t)
        if scenario == "fault":
            mode = self.faulted.get(dev["name"])
            if mode == "critical":
                return value_critical(dev, t)
            if mode == "warning":
                return value_warning(dev, t)
        return value_normal(dev, t)


def effective_interval(dev, args):
    """Sample period for a device: from the CSV, clamped into a usable range."""
    interval = dev["interval"] if dev["interval"] else args.interval
    if args.max_interval:
        interval = min(interval, args.max_interval)
    return max(interval, args.min_interval)


def run_scheduled(devices, sim, args, sock):
    """Pace every device at its own measurement interval from one scheduler."""
    start = time.monotonic()
    sent = {}
    queue = []
    for i, dev in enumerate(devices):
        interval = sim.interval_for(dev, args)
        # Stagger the first sample so slow and fast devices do not burst together.
        heapq.heappush(queue, (random.random() * interval, i, dev, interval))

    while queue:
        due, i, dev, interval = heapq.heappop(queue)
        now = time.monotonic() - start
        if args.duration and due >= args.duration:
            break
        if due > now:
            time.sleep(due - now)
        t = time.monotonic() - start
        if sim.should_send(dev, t):
            try:
                sock.sendto(build_packet(dev["identifier"], sim.value(dev, t)),
                            (args.target, dev["port"]))
                sent[dev["name"]] = sent.get(dev["name"], 0) + 1
            except OSError as exc:
                print(f"  [{dev['name']}] send error: {exc}")
        heapq.heappush(queue, (due + interval, i, dev, interval))
    return sent


def run_congestion(dev, args, sock):
    """Flood one device as fast as requested to provoke ALMOSTFULL."""
    start = time.monotonic()
    interval = 1.0 / args.rate if args.rate > 0 else 0.0
    count = 0
    next_send = 0.0
    while True:
        t = time.monotonic() - start
        if args.duration and t >= args.duration:
            break
        if interval:
            if t < next_send:
                time.sleep(min(next_send - t, 0.001))
                continue
            next_send += interval
        try:
            sock.sendto(build_packet(dev["identifier"], value_normal(dev, t)),
                        (args.target, dev["port"]))
            count += 1
        except OSError as exc:
            print(f"  [{dev['name']}] send error: {exc}")
            break
    return {dev["name"]: count}


def describe(devices, sim, args):
    print(f"Target {args.target}  |  scenario={args.scenario}  |  "
          f"duration={args.duration or 'inf'}s  |  {len(devices)} device(s)")

    by_subsystem = {}
    for dev in devices:
        by_subsystem.setdefault(dev["subsystem"], []).append(dev)
    for subsystem, group in sorted(by_subsystem.items()):
        rates = sorted({effective_interval(d, args) for d in group})
        print(f"  {subsystem:<20} {len(group):>3} param(s)  port {group[0]['port']}  "
              f"every {'/'.join(f'{r:g}' for r in rates)} s")

    if args.verbose:
        for dev in devices:
            limits = ", ".join(
                f"{key}={dev[key]:g}" for key in
                ("warn_low", "warn_high", "crit_low", "crit_high")
                if dev[key] is not None
            ) or "no limits"
            print(f"    {dev['name']:<18} id={dev['identifier']} "
                  f"nominal={dev['nominal']:g}{dev['unit']}  {limits}")

    if sim.faulted:
        print("Injected faults:")
        for name, mode in sorted(sim.faulted.items()):
            print(f"    {name:<18} -> {mode}")
    if sim.silenced:
        print(f"Going silent mid-run: {', '.join(sorted(sim.silenced))}")
    if sim.sweeping and args.scenario == "sweep":
        print(f"Sweeping {sim.sweeping['name']} from nominal "
              f"({sim.sweeping['nominal']:g}{sim.sweeping['unit']}) past its critical "
              f"limit, sampled every {sim.interval_for(sim.sweeping, args):g} s")

    no_limits = [d for d in devices if not has_critical_band(d)]
    if args.scenario in ("trip", "sweep") or \
            any(m == "critical" for m in sim.faulted.values()):
        print("NOTE: this drives devices past their critical limits. Against the "
              "FPGA it asserts the GLOBAL interlock -- clear it with SW3 on the "
              "GateMate EVB afterwards.")
        if no_limits:
            print(f"      {len(no_limits)} device(s) have no critical limit in the "
                  "CSV and can only reach 'warning'.")

    # threshold_tables_pkg.vhd only leaves an entry at the fail-safe zero when the
    # CSV gives neither a critical nor a warning band (a warning band is used as
    # the interlock limit when Critical_* is blank).
    if args.target in LOCAL_TARGETS:
        print("NOTE: target is LOCAL -- packets go straight to a metric server on this "
              "machine.\n      The FPGA sees nothing: no RX LED activity, no threshold "
              f"check, no interlock.\n      Use --target {FPGA_RX_IP} to drive the board.")

    unbounded = [d for d in devices
                 if not has_critical_band(d) and not has_warning_band(d)]
    if unbounded and args.target not in LOCAL_TARGETS:
        types = sorted({d["type_id"] for d in unbounded})
        print(f"NOTE: {len(types)} DeviceTypeID(s) {types} have blank Critical_* "
              "columns in the CSV, so threshold_tables_pkg.vhd leaves them at the "
              "fail-safe zero entry -- on the FPGA every one of their readings "
              "asserts the interlock until real limits are defined. The metric "
              "server rates them 'ok'.")


def run(args):
    devices = select_devices(load_devices(args.catalog, args.base_port), args)
    if not devices:
        raise SystemExit("No devices matched the filters -- check "
                         "--subsystem/--device/--priority.")
    if args.scenario in ("sweep", "congestion") and len(devices) > 1 and not args.device:
        print(f"NOTE: --scenario {args.scenario} acts on the first matching device; "
              "use --device NAME to pick one.", file=sys.stderr)

    sim = Simulation(devices, args)
    describe(devices, sim, args)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        if args.scenario == "congestion":
            dev = devices[0]
            print(f"Flooding {dev['name']} on port {dev['port']} at ~{args.rate:g} "
                  "pkt/s to provoke ALMOSTFULL...")
            sent = run_congestion(dev, args, sock)
        else:
            sent = run_scheduled(devices, sim, args, sock)
    except KeyboardInterrupt:
        print("\nStopping...")
        sent = {}
    finally:
        sock.close()

    if sent:
        total = sum(sent.values())
        print(f"\n=== {total} packet(s) sent across {len(sent)} device(s) ===")
        if args.verbose or len(sent) <= 20:
            for name, n in sorted(sent.items()):
                print(f"  {name:<18} {n}")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--scenario", choices=SCENARIOS, default="normal",
                   help="traffic pattern to generate (default: normal)")
    p.add_argument("--target", default=FPGA_RX_IP,
                   help=f"destination IP (default {FPGA_RX_IP}, the FPGA RX chip -- "
                        "same as test_dataconcentrator.py). Use 127.0.0.1 to feed a "
                        "local metric server directly, with no FPGA in the path.")
    p.add_argument("--duration", type=float, default=0,
                   help="seconds to run (0 = until Ctrl+C; default 0)")
    p.add_argument("--faults", type=int, default=3,
                   help="devices to fault (scenario fault) or silence "
                        "(scenario dropout); default 3")
    p.add_argument("--subsystem", action="append", default=[],
                   help="only simulate this subsystem (repeatable/comma-separated, "
                        "e.g. Safety, ADC, 'PreAmp / LNA')")
    p.add_argument("--device", action="append", default=[],
                   help="only simulate devices matching this name or glob "
                        "(repeatable, e.g. 'ADC*_3V3'); also picks the device for "
                        "sweep/congestion")
    p.add_argument("--priority", action="append", default=[],
                   help="only simulate this priority (Critical, High, Medium)")
    p.add_argument("--channels", type=int, default=8,
                   help="instances to simulate per device type, for the 64-channel "
                        "LNA/VCO/PA/Switch arrays (0 = all 64; default 8)")
    p.add_argument("--interval", type=float, default=1.0,
                   help="sample period for devices with no Measurement_Interval_s "
                        "in the CSV (default 1 s)")
    p.add_argument("--max-interval", type=float, default=1.0,
                   help="clamp slow parameters (Room_Temperature is 60 s in the CSV) so "
                        "every device sends at least ~1 Hz -- the cadence "
                        "test_dataconcentrator.py uses, and enough for visible RX LED "
                        "activity; 0 = honour the CSV exactly (default 1 s)")
    p.add_argument("--min-interval", type=float, default=0.05,
                   help="floor on the sample period (default 0.05 s)")
    p.add_argument("--base-port", type=int, default=BASE_PORT,
                   help=f"first of the {NUM_PORTS} destination UDP ports "
                        f"(default {BASE_PORT}); subsystems are spread across them")
    p.add_argument("--rate", type=float, default=5000.0,
                   help="packets/second for --scenario congestion (default 5000)")
    p.add_argument("--catalog", action="append", default=None,
                   help=f"catalog to simulate (repeatable; default "
                        f"slow_control_catalog.json). Pass {BRAM_CATALOG} to also "
                        "drive the FPGA BRAM devices (PSU/COIL/FAN speed).")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="list every device with its limits")
    args = p.parse_args()
    if args.catalog is None:
        args.catalog = DEFAULT_CATALOGS
    return args


if __name__ == "__main__":
    run(parse_args())
