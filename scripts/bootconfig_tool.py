#!/usr/bin/env python3
"""Append or verify a Linux bootconfig trailer on an initrd.

The format matches the current Linux bootconfig contract used by Android GKI:
[initrd][bootconfig + NUL + zero padding][size le32][checksum le32][#BOOTCONFIG\n]
The complete output is aligned to four bytes. The checksum is the unsigned
32-bit sum of every byte covered by size; zero padding does not change it.
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys

MAGIC = b"#BOOTCONFIG\n"
FOOTER_SIZE = 8 + len(MAGIC)
ALIGNMENT = 4
MAX_BOOTCONFIG = 32 * 1024 - 1


def checksum(data: bytes) -> int:
    return sum(data) & 0xFFFFFFFF


def parse_attached(data: bytes) -> tuple[int, int, bytes]:
    if len(data) < FOOTER_SIZE or not data.endswith(MAGIC):
        raise ValueError("bootconfig magic is missing")
    size, expected_checksum = struct.unpack_from("<II", data, len(data) - FOOTER_SIZE)
    start = len(data) - FOOTER_SIZE - size
    if start < 0:
        raise ValueError("bootconfig size exceeds initrd size")
    payload = data[start : start + size]
    actual_checksum = checksum(payload)
    if actual_checksum != expected_checksum:
        raise ValueError(
            f"bootconfig checksum mismatch: expected {expected_checksum}, got {actual_checksum}"
        )
    return start, size, payload


def append_bootconfig(initrd: pathlib.Path, bootconfig: pathlib.Path) -> None:
    initrd_data = initrd.read_bytes()
    config = bootconfig.read_bytes()

    if b"\0" in config:
        raise ValueError("bootconfig input contains an embedded NUL byte")
    if len(config) + 1 > MAX_BOOTCONFIG:
        raise ValueError(f"bootconfig exceeds {MAX_BOOTCONFIG} bytes")

    # Match the kernel bootconfig utility: the parsed text includes a trailing
    # NUL. Then add zero padding so the entire initrd+footer ends on a 4-byte
    # boundary. The stored size includes this padding.
    payload = config + b"\0"
    pad = (-(len(initrd_data) + len(payload) + FOOTER_SIZE)) % ALIGNMENT
    payload += b"\0" * pad
    trailer = struct.pack("<II", len(payload), checksum(payload)) + MAGIC

    output = initrd_data + payload + trailer
    if len(output) % ALIGNMENT != 0:
        raise AssertionError("bootconfig output is not four-byte aligned")
    initrd.write_bytes(output)

    start, stored_size, stored_payload = parse_attached(output)
    if start != len(initrd_data) or stored_size != len(payload) or stored_payload != payload:
        raise AssertionError("bootconfig round-trip verification failed")


def verify(initrd: pathlib.Path) -> None:
    data = initrd.read_bytes()
    _, size, payload = parse_attached(data)
    if len(data) % ALIGNMENT != 0:
        raise ValueError("initrd with bootconfig is not four-byte aligned")
    if not payload or b"\0" not in payload:
        raise ValueError("bootconfig payload is missing its terminating NUL/padding")
    print(f"BOOTCONFIG_VERIFY = PASS size={size} checksum={checksum(payload)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    append_parser = sub.add_parser("append", help="append bootconfig to an initrd in place")
    append_parser.add_argument("initrd", type=pathlib.Path)
    append_parser.add_argument("bootconfig", type=pathlib.Path)

    verify_parser = sub.add_parser("verify", help="verify an attached bootconfig trailer")
    verify_parser.add_argument("initrd", type=pathlib.Path)

    args = parser.parse_args()
    try:
        if args.command == "append":
            append_bootconfig(args.initrd, args.bootconfig)
            verify(args.initrd)
        else:
            verify(args.initrd)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
