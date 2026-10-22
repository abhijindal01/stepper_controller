#!/usr/bin/env python3
"""Merge ArduPilot STM32H7 bootloader + application into one flash image.

Default layout (verify against IndiH743 hwdef before production use):

  0x08000000  bootloader   (FLASH_RESERVE_START_KB 0 in hwdef-bl)
  0x08020000  application  (FLASH_BOOTLOADER_LOAD_KB 128)

Gap between end of bootloader and app offset is filled with 0xFF (erased flash).

Examples:
  python3 merge_indi_h743_image.py \\
    --bootloader AP_Bootloader.bin \\
    --firmware arducopter.bin \\
    --out-bin combined.bin \\
    --out-hex combined.hex
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


FLASH_BASE_DEFAULT = 0x08000000
APP_OFFSET_DEFAULT = 0x20000  # 128 KiB


def load_bin(path: Path) -> bytes:
    data = path.read_bytes()
    if not data:
        raise SystemExit(f"empty file: {path}")
    return data


def merge(bootloader: bytes, firmware: bytes, app_offset: int) -> bytes:
    if len(bootloader) > app_offset:
        raise SystemExit(
            f"bootloader is {len(bootloader)} bytes; exceeds app offset "
            f"0x{app_offset:X} ({app_offset} bytes). Check FLASH_BOOTLOADER_LOAD_KB."
        )

    size = app_offset + len(firmware)
    image = bytearray(b"\xFF" * size)
    image[0 : len(bootloader)] = bootloader
    image[app_offset : app_offset + len(firmware)] = firmware
    return bytes(image)


def write_intel_hex(path: Path, image: bytes, base: int, record_size: int = 16) -> None:
    """Minimal I32HEX writer (data + extended linear address + EOF)."""
    lines: list[str] = []
    addr = base
    end = base + len(image)
    offset = 0
    current_ela = None

    while addr < end:
        ela = (addr >> 16) & 0xFFFF
        if ela != current_ela:
            # Extended Linear Address record
            payload = struct.pack(">H", ela)
            checksum = (-(2 + 0 + 0x04 + payload[0] + payload[1])) & 0xFF
            lines.append(f":02000004{ela:04X}{checksum:02X}")
            current_ela = ela

        chunk_len = min(record_size, end - addr, 0x10000 - (addr & 0xFFFF))
        chunk = image[offset : offset + chunk_len]
        lo = addr & 0xFFFF
        reclen = len(chunk)
        csum = reclen + (lo >> 8) + (lo & 0xFF) + 0x00 + sum(chunk)
        csum = (-csum) & 0xFF
        lines.append(f":{reclen:02X}{lo:04X}00{chunk.hex().upper()}{csum:02X}")
        addr += reclen
        offset += reclen

    lines.append(":00000001FF")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bootloader", required=True, type=Path, help="AP_Bootloader.bin")
    p.add_argument("--firmware", required=True, type=Path, help="arducopter.bin (app linked for 0x08020000)")
    p.add_argument("--out-bin", required=True, type=Path, help="Output combined .bin")
    p.add_argument("--out-hex", type=Path, default=None, help="Optional Intel HEX output")
    p.add_argument("--flash-base", type=lambda s: int(s, 0), default=FLASH_BASE_DEFAULT)
    p.add_argument(
        "--app-offset",
        type=lambda s: int(s, 0),
        default=APP_OFFSET_DEFAULT,
        help="Byte offset of app from flash base (default 0x20000 = 128 KiB)",
    )
    args = p.parse_args()

    bl = load_bin(args.bootloader)
    fw = load_bin(args.firmware)
    image = merge(bl, fw, args.app_offset)

    args.out_bin.parent.mkdir(parents=True, exist_ok=True)
    args.out_bin.write_bytes(image)

    print(f"bootloader : {args.bootloader} ({len(bl)} bytes)")
    print(f"firmware   : {args.firmware} ({len(fw)} bytes)")
    print(f"app offset : 0x{args.app_offset:X} ({args.app_offset} bytes)")
    print(f"flash base : 0x{args.flash_base:08X}")
    print(f"combined   : {args.out_bin} ({len(image)} bytes)")
    print(f"  BL  @ 0x{args.flash_base:08X}")
    print(f"  APP @ 0x{args.flash_base + args.app_offset:08X}")

    if args.out_hex:
        args.out_hex.parent.mkdir(parents=True, exist_ok=True)
        write_intel_hex(args.out_hex, image, args.flash_base)
        print(f"hex        : {args.out_hex}")

    if len(bl) > 96 * 1024:
        print(
            "warning: bootloader > 96 KiB; still OK if < app offset, but unusual for AP_Bootloader",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
