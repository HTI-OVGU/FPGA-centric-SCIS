#!/usr/bin/env python3
"""
Generate `slow_control_catalog.json` from `Slow_control_protocol_example.csv`.

The CSV is the human-maintained slow-control parameter list (one row per
parameter, with subsystem, unit, nominal value, warning/critical limits,
measurement interval, interlock action and priority). This script expands it
into the identifier-keyed catalog the metric server and the device simulator
consume.

Identifier layout (from the CSV header, matches the FPGA CAN adapter):

    | 'V01' 24 bit | DeviceTypeID 10 bit | Device No 6 bit | value 32 bit |

    identifier = (DeviceTypeID << 6) | DeviceNo      # the 16 bit on-wire id

Array parameters (`LNA[0:63]_V1`, DeviceTypeID `100+[63]`) are expanded so that
the **channel goes into Device No** and each *parameter* of the group gets its
own DeviceTypeID, counting up from the base — the same convention the CSV uses
explicitly for the ADC/DAC boards (`ADC1..4_3V3` = type 900, Device No 0..3):

    LNA00_V1 .. LNA63_V1     -> type 100, Device No 0..63
    LNA00_I1 .. LNA63_I1     -> type 101, Device No 0..63
    LNA00_Temp .. LNA63_Temp -> type 102, Device No 0..63

Usage:
    python build_slow_control_catalog.py                      # default paths
    python build_slow_control_catalog.py ../Slow_control_protocol_example.csv
"""

import csv
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CSV = os.path.join(HERE, "..", "Slow_control_protocol_example.csv")
DEFAULT_OUT = os.path.join(HERE, "slow_control_catalog.json")

ARRAY_RE = re.compile(r"\[(\d+)\s*:\s*(\d+)\]")
LEADING_INT_RE = re.compile(r"^\s*(\d+)")

TYPE_ID_BITS = 10
DEVICE_NO_BITS = 6


def _clean(value):
    return (value or "").strip()


def _number(value):
    """Parse a numeric CSV cell; empty/non-numeric cells become None."""
    text = _clean(value).replace(",", ".")
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def _column_index(header, *candidates):
    for i, cell in enumerate(header):
        name = _clean(cell).lower()
        for candidate in candidates:
            if name.startswith(candidate):
                return i
    return None


def read_rows(csv_path):
    """Return (header, data_rows) starting at the `Parameter_Name` header line."""
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.reader(f))
    for i, row in enumerate(rows):
        if any(_clean(cell) == "Parameter_Name" for cell in row):
            return [_clean(c) for c in row], rows[i + 1:]
    raise SystemExit(f"No 'Parameter_Name' header row found in {csv_path}")


def parse_spec(csv_path):
    """Parse the CSV into a list of device dicts (arrays already expanded)."""
    header, rows = read_rows(csv_path)

    col = {
        "responsible": _column_index(header, "responsible"),
        "parameter": _column_index(header, "parameter_name"),
        "type_id": _column_index(header, "devicetypeid"),
        "device_no": _column_index(header, "device№", "device no", "device_no", "device"),
        "subsystem": _column_index(header, "subsystem"),
        "description": _column_index(header, "description"),
        "unit": _column_index(header, "unit"),
        "nominal": _column_index(header, "nominal"),
        "warn_low": _column_index(header, "warning_low"),
        "warn_high": _column_index(header, "warning_high"),
        "crit_low": _column_index(header, "critical_low"),
        "crit_high": _column_index(header, "critical_high"),
        "interval": _column_index(header, "measurement_interval"),
        "sensor": _column_index(header, "sensor_type"),
        "transfer": _column_index(header, "transfer"),
        "interlock": _column_index(header, "interlock_action"),
        "priority": _column_index(header, "priority"),
    }
    # `Device No` must not resolve to the `DeviceTypeID` column.
    if col["device_no"] == col["type_id"]:
        col["device_no"] = col["type_id"] + 1

    def cell(row, key):
        idx = col[key]
        return _clean(row[idx]) if idx is not None and idx < len(row) else ""

    devices = []
    # Per base DeviceTypeID: how many parameters of that group we have seen.
    array_offsets = {}
    skipped = []

    for row in rows:
        parameter = cell(row, "parameter")
        type_field = cell(row, "type_id")
        if not parameter:
            continue
        match = LEADING_INT_RE.match(type_field)
        if not match:
            skipped.append((parameter, "no DeviceTypeID"))
            continue
        base_type = int(match.group(1))

        array = ARRAY_RE.search(parameter)
        if array:
            lo, hi = int(array.group(1)), int(array.group(2))
            offset = array_offsets.setdefault(base_type, 0)
            array_offsets[base_type] = offset + 1
            type_id = base_type + offset
            channels = range(lo, hi + 1)
            name_for = lambda ch: ARRAY_RE.sub(f"{ch:02d}", parameter)
        else:
            device_field = cell(row, "device_no")
            device_no = int(LEADING_INT_RE.match(device_field).group(1)) if \
                LEADING_INT_RE.match(device_field) else 0
            type_id = base_type
            channels = [device_no]
            name_for = lambda ch: parameter.rstrip("_")

        if type_id >= (1 << TYPE_ID_BITS):
            skipped.append((parameter, f"DeviceTypeID {type_id} exceeds 10 bit"))
            continue

        unit = cell(row, "unit")
        common = {
            "unit": unit,
            "subsystem": cell(row, "subsystem") or "unassigned",
            "priority": cell(row, "priority") or "Medium",
            "interlock": cell(row, "interlock") or "",
            "description": cell(row, "description"),
            "responsible": cell(row, "responsible"),
            "sensor": cell(row, "sensor"),
            "transfer": cell(row, "transfer"),
            "kind": "boolean" if unit.lower() == "boolean" else "analog",
            "nominal": _number(row[col["nominal"]]) if col["nominal"] is not None else None,
            "warn_low": _number(row[col["warn_low"]]) if col["warn_low"] is not None else None,
            "warn_high": _number(row[col["warn_high"]]) if col["warn_high"] is not None else None,
            "crit_low": _number(row[col["crit_low"]]) if col["crit_low"] is not None else None,
            "crit_high": _number(row[col["crit_high"]]) if col["crit_high"] is not None else None,
            "interval": _number(row[col["interval"]]) if col["interval"] is not None else None,
        }

        for channel in channels:
            if channel >= (1 << DEVICE_NO_BITS):
                skipped.append((parameter, f"Device No {channel} exceeds 6 bit"))
                continue
            entry = dict(common)
            entry["name"] = name_for(channel)
            entry["type_id"] = type_id
            entry["device_no"] = channel
            entry["identifier"] = f"{(type_id << DEVICE_NO_BITS) | channel:04x}"
            devices.append(entry)

    return devices, skipped


def to_catalog(devices, csv_path):
    catalog = {}
    for entry in devices:
        identifier = entry.pop("identifier")
        if identifier in catalog:
            raise SystemExit(
                f"Identifier collision on {identifier}: "
                f"{catalog[identifier]['name']} vs {entry['name']}"
            )
        # Drop empty/None fields to keep the generated file readable.
        catalog[identifier] = {k: v for k, v in entry.items() if v not in (None, "")}
    return {
        "_comment": (
            "GENERATED from " + os.path.basename(csv_path) + " by "
            "build_slow_control_catalog.py -- do not edit by hand. "
            "Keys are the 16 bit on-wire identifier ((DeviceTypeID << 6) | DeviceNo) "
            "as lowercase hex. crit_low/crit_high are the interlock limits, "
            "warn_low/warn_high the operator-warning band."
        ),
        "source": os.path.basename(csv_path),
        "devices": dict(sorted(catalog.items())),
    }


# ---- VHDL threshold table -----------------------------------------------------
# The FPGA threshold BRAM (threshold_tables_pkg.vhd) is addressed by the
# DeviceTypeID alone -- `address = metric_id(15 downto 6) & '0'/'1'` -- so the
# 64 channels of a device type share ONE {lower, upper} pair, and there is
# exactly one table entry per DeviceTypeID.

def q22_10_hex(value):
    """Signed 32-bit Q22.10 as an 8-digit hex literal (the BRAM word format)."""
    q = int(round(value * 1024))
    if not -(1 << 31) <= q < (1 << 31):
        raise SystemExit(f"{value} does not fit in a signed Q22.10 word")
    return f"{q & 0xFFFFFFFF:08X}"


def threshold_rows(devices):
    """One row per DeviceTypeID: (type_id, lower, upper, label, note)."""
    by_type = {}
    for dev in devices:
        by_type.setdefault(dev["type_id"], []).append(dev)

    rows = []
    for type_id, group in sorted(by_type.items()):
        first = group[0]
        names = sorted({d["name"] for d in group})
        if len(names) > 1:
            # Same type, several instances: collapse LNA00_V1..LNA63_V1 to a range.
            label = f"{names[0]}..{names[-1]}"
        else:
            label = names[0]
        label = f"{label} ({first['subsystem']})"

        if first["kind"] == "boolean":
            # Nominal-1 signals: the only safe value is 1, so lower == upper == 1.
            rows.append((type_id, 1.0, 1.0, label, "boolean, must stay asserted"))
            continue

        low, high = first["crit_low"], first["crit_high"]
        note = "Critical_Low/High"
        if low is None and high is None:
            low, high = first["warn_low"], first["warn_high"]
            note = "no critical limits in the CSV -- warning band used"
        if low is None or high is None:
            # The CSV leaves these blank. Emitting a guess as a live limit would
            # be inventing a safety number, so the caller comments them out and
            # the fail-safe zero entry applies until someone fills them in.
            nominal = first["nominal"]
            unit = first["unit"]
            rows.append((type_id, nominal * 0.8, nominal * 1.2, label,
                         f"UNDEFINED in the CSV -- placeholder is +-20% of the "
                         f"nominal {nominal:g} {unit}".strip()))
            continue
        rows.append((type_id, low, high, label, note))
    return rows


def emit_vhdl(devices, transfer=None):
    """Print threshold_tables_pkg.vhd entries for pasting into the package."""
    if transfer:
        devices = [d for d in devices
                   if d.get("transfer", "").lower() == transfer.lower()]
    lines = []
    for type_id, low, high, label, note in threshold_rows(devices):
        addr = type_id * 2
        undefined = note.startswith("UNDEFINED")
        prefix = "-- " if undefined else ""
        unit = ""
        lines.append(f"    {prefix}{addr:<4} => x\"{q22_10_hex(low)}\", "
                     f"-- {label}: {low:g} .. {high:g}{unit}"
                     + (f"  [{note}]" if note != "Critical_Low/High" else ""))
        lines.append(f"    {prefix}{addr + 1:<4} => x\"{q22_10_hex(high)}\",")
    print("\n".join(lines))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    csv_path = args[0] if args else DEFAULT_CSV
    out_path = args[1] if len(args) > 1 else DEFAULT_OUT

    devices, skipped = parse_spec(csv_path)

    for flag in flags:
        if flag == "--vhdl":
            emit_vhdl(devices)
            return
        if flag.startswith("--vhdl-transfer="):
            emit_vhdl(devices, flag.split("=", 1)[1])
            return
        raise SystemExit(f"Unknown flag {flag}")

    catalog = to_catalog(devices, csv_path)

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, indent=1, ensure_ascii=False)
        f.write("\n")

    subsystems = sorted({d["subsystem"] for d in catalog["devices"].values()})
    print(f"{len(catalog['devices'])} devices -> {out_path}")
    print(f"subsystems: {', '.join(subsystems)}")
    for name, reason in skipped:
        print(f"  skipped {name!r}: {reason}")


if __name__ == "__main__":
    main()
