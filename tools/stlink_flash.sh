#!/bin/bash
# Flash .bin/.hex via ST-LINK for IndiH743 (no NRST).
#
# OpenOCD's single `program` on this H7+ST-LINK/V2 combo fails mid multi-sector
# erase/algo load. CubeProgrammer works on the same harness. This wrapper
# matches that reliability by erasing+writing one 128 KiB sector at a time at
# low SWD speed with a RAM trampoline so a blank vector table cannot lock up
# the flash loader.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CFG="${ROOT}/openocd_fixture.cfg"
PY="${ROOT}/../venv/bin/python3"
[[ -x "$PY" ]] || PY=python3

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <image.bin|image.hex> [base_addr_for_bin]" >&2
  exit 1
fi

IMG="$(realpath "$1")"
BASE="${2:-0x08000000}"

if [[ ! -f "$IMG" ]]; then
  echo "file not found: $IMG" >&2
  exit 1
fi

exec "$PY" - "$IMG" "$BASE" "$CFG" <<'PY'
import subprocess, sys, tempfile, time
from pathlib import Path

img_path = Path(sys.argv[1])
base = int(sys.argv[2], 0)
cfg = sys.argv[3]
chunk = 128 * 1024

def parse_hex(path: Path) -> tuple[int, bytes]:
    base_ela = 0
    data: dict[int, int] = {}
    for line in path.open():
        line = line.strip()
        if not line.startswith(":"):
            continue
        rl = int(line[1:3], 16)
        addr = int(line[3:7], 16)
        rt = int(line[7:9], 16)
        if rt == 4:
            base_ela = int(line[9:13], 16) << 16
        elif rt == 0:
            a = base_ela + addr
            for i in range(rl):
                data[a + i] = int(line[9 + 2 * i : 11 + 2 * i], 16)
        elif rt == 1:
            break
    if not data:
        raise SystemExit(f"no data in {path}")
    lo, hi = min(data), max(data) + 1
    img = bytearray(b"\xFF" * (hi - lo))
    for a, b in data.items():
        img[a - lo] = b
    return lo, bytes(img)

suffix = img_path.suffix.lower()
if suffix == ".hex":
    flash_base, image = parse_hex(img_path)
elif suffix == ".bin":
    flash_base, image = base, img_path.read_bytes()
else:
    raise SystemExit(f"unsupported extension: {suffix}")

n_chunks = (len(image) + chunk - 1) // chunk
print(
    f"flashing {img_path.name}: {len(image)} bytes @ {flash_base:#x} in {n_chunks} sector(s)",
    flush=True,
)

tmpdir = Path(tempfile.mkdtemp(prefix="stlink_flash_"))
try:
    for n in range(n_chunks):
        piece = image[n * chunk : (n + 1) * chunk]
        if len(piece) % 32:
            piece += b"\xFF" * (32 - len(piece) % 32)
        part = tmpdir / f"part_{n:02d}.bin"
        part.write_bytes(piece)
        addr = flash_base + n * chunk
        print(f"  sector {n}/{n_chunks - 1} @ {addr:#x} ({len(piece)} bytes)", flush=True)
        cmd = [
            "openocd",
            "-f",
            cfg,
            "-c",
            "init; halt; adapter speed 50",
            "-c",
            "mww 0x20000200 0xE7FEE7FE; reg msp 0x20010000; reg pc 0x20000201",
            "-c",
            f"flash erase_address {addr:#x} {len(piece)}",
            "-c",
            f"flash write_image {part} {addr:#x}",
            "-c",
            f"verify_image {part} {addr:#x}",
            "-c",
            "exit",
        ]
        for attempt in range(1, 5):
            r = subprocess.run(cmd, capture_output=True, text=True)
            text = (r.stdout or "") + (r.stderr or "")
            ok = (
                r.returncode == 0
                and "verified" in text.lower()
                and "Error:" not in text
            )
            if ok:
                break
            print(f"    retry {attempt}/4", flush=True)
            for line in text.splitlines():
                if "Error" in line or "Failed" in line:
                    print(f"    {line}", flush=True)
            time.sleep(1.0)
        else:
            sys.stderr.write(text)
            raise SystemExit(f"flash failed at sector {n} @ {addr:#x}")

    print("full verify...", flush=True)
    whole = tmpdir / "whole.bin"
    whole.write_bytes(image if len(image) % 32 == 0 else image + b"\xFF" * (32 - len(image) % 32))
    # pad image file to match what we wrote (sector pads)
    padded = bytearray(image)
    if len(padded) % chunk:
        # last sector was padded to 32, not full chunk — rebuild from parts
        padded = bytearray()
        for n in range(n_chunks):
            padded.extend((tmpdir / f"part_{n:02d}.bin").read_bytes())
        whole.write_bytes(padded)
    else:
        whole.write_bytes(image)

    cmd = [
        "openocd",
        "-f",
        cfg,
        "-c",
        "init; halt; adapter speed 50",
        "-c",
        "mww 0x20000200 0xE7FEE7FE; reg msp 0x20010000; reg pc 0x20000201",
        "-c",
        f"verify_image {whole} {flash_base:#x}",
        "-c",
        "exit",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    text = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0 or "verified" not in text.lower() or "Error:" in text:
        sys.stderr.write(text)
        raise SystemExit("full verify failed")
    print("Verified OK", flush=True)
finally:
    for p in tmpdir.glob("*"):
        p.unlink(missing_ok=True)
    tmpdir.rmdir()
PY
