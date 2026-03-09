#!/usr/bin/env python3
import argparse
import struct


FRACTION_BITS = 10 #N
SCALE = 1 << FRACTION_BITS

def to_float32(value):
    """Convert Python float to true 32-bit float."""
    return struct.unpack('!f', struct.pack('!f', float(value)))[0]

def to_q_format_32(value):
    """
    Convert a Python float to signed 32-bit Q(M).10 fixed point.
    M = 32 - 1(sign) - FRACTION_BITS
    """
    scaled = int(round(value * SCALE))

    # Force 32-bit signed two's complement
    scaled &= 0xFFFFFFFF
    return scaled

def to_signed_32(value):
    """Convert unsigned 32-bit to signed 32-bit (two's complement)."""
    if value & 0x80000000:  # Check if sign bit is set
        return value - 0x100000000
    return value

def to_hex_string_32(value32):
    """Format a 32-bit integer as x"1234ABCD";"""
    return f'x"{value32:08X}"'

def parse_two_bytes(s):
    # Normalize common hex formats
    s = s.replace("0x", "").replace("\\x", "")

    # Case 1: raw ASCII, length 2
    if len(s) == 2 and all(ord(c) < 256 for c in s):
        return ord(s[0]), ord(s[1])

    # Case 2: hex string of length 4 (e.g. "4142")
    if len(s) == 4:
        try:
            b1 = int(s[:2], 16)
            b2 = int(s[2:], 16)
            return b1, b2
        except ValueError:
            pass

    raise ValueError("Input must be 2 ASCII chars or 4 hex digits.")


def main():
    parser = argparse.ArgumentParser(
        description="Extract the most significant 10 bits from a 2-byte ASCII or hex input."
    )
    parser.add_argument("input", help="Example: AB   or   4142   or   0x41 0x42")

    parser.add_argument(
        "--lower-threshold",
        type=float,
        required=True,
        help="Lower threshold as a decimal 32-bit float."
    )

    parser.add_argument(
        "--upper-threshold",
        type=float,
        required=True,
        help="Upper threshold as a decimal 32-bit float."
    )

    args = parser.parse_args()

    lower_threshold = to_float32(args.lower_threshold)
    upper_threshold = to_float32(args.upper_threshold)

    # Convert to Q-format 32-bit signed integers
    lower_q = to_q_format_32(lower_threshold)
    upper_q = to_q_format_32(upper_threshold)

    # Convert to hex syntax
    lower_hex = to_hex_string_32(lower_q)
    upper_hex = to_hex_string_32(upper_q)


    b1, b2 = parse_two_bytes(args.input)

    # Combine into 16-bit integer
    value = (b1 << 8) | b2

    # extracts the 10 most significant bits
    msb10 = (value >> 6) & 0x3FF

    # Append 0 and 1
    lower_threshold_address = msb10 << 1
    upper_threshold_address = (msb10 << 1) | 1

    print(f"lower threshold is: {(to_signed_32(lower_q) / 1024.0):.4f}")
    print(f"upper threshold is: {(to_signed_32(upper_q) / 1024.0):.4f}")

    print(f"{lower_threshold_address} => {lower_hex},")
    print(f"{upper_threshold_address} => {upper_hex},")

if __name__ == "__main__":
    main()
