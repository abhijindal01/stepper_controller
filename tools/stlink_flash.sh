#!/bin/bash
# Flash .bin/.hex via ST-LINK for IndiH743 (no NRST).
#
# OpenOCD's single `program` on this H7+ST-LINK/V2 combo fails mid multi-sector
# erase/algo load, so this wrapper erases + writes one 128 KiB sector at a time
# in a fresh OpenOCD session.
#
# It also picks a *writable* flash-loader work area before it starts. OpenOCD
# defaults the STM32H7 work area to DTCM (0x20000000); on this fixture writes
# into DTCM come back as
#
#     Error: Failed to write memory at 0x20002194
#     Error: error writing to flash at address 0x08000000 at offset 0x00000000
#
# which kills the flash loader, so sector 0 never programs even though the
# erase succeeds. We probe RAM candidates (AXI SRAM first) and use the first
# one that takes and returns a pattern.
#
#   tools/stlink_flash.sh <image.bin|image.hex> [base_addr_for_bin]
#
# Environment overrides:
#   STLINK_SPEED            SWD kHz used for erase/write   (default 50)
#   STLINK_WORKAREA         forced loader RAM address      (default: auto)
#   STLINK_WORKAREA_SIZE    loader RAM size                (default 0x10000)
#   STLINK_ATTEMPTS         attempts per sector            (default 3)
#   STLINK_OPENOCD_TIMEOUT  per-OpenOCD-session timeout s  (default 300)
#   STLINK_FULL_VERIFY      second whole-image verify pass (default 1)
#   OPENOCD                 openocd binary                 (default openocd)
#
# Exit codes: 0 ok, 1 usage/file error, 2 no writable work area,
#             3 flash/verify failed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CFG="${ROOT}/openocd_fixture.cfg"
PY="${ROOT}/../venv/bin/python3"
[[ -x "$PY" ]] || PY=python3

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  [[ $# -lt 1 ]] && exit 1
  exit 0
fi

IMG="$(realpath "$1")"
BASE="${2:-0x08000000}"

if [[ ! -f "$IMG" ]]; then
  echo "file not found: $IMG" >&2
  exit 1
fi

exec "$PY" - "$IMG" "$BASE" "$CFG" <<'PY'
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

img_path = Path(sys.argv[1])
base = int(sys.argv[2], 0)
cfg = sys.argv[3]

FLASH_BASE = 0x08000000
FLASH_MAX = 2048 * 1024          # STM32H743, dual bank
SECTOR = 128 * 1024

OPENOCD = os.environ.get("OPENOCD") or "openocd"
SPEED = int(os.environ.get("STLINK_SPEED") or "50", 0)
WA_SIZE = int(os.environ.get("STLINK_WORKAREA_SIZE") or "0x10000", 0)
FORCED_WA = (os.environ.get("STLINK_WORKAREA") or "").strip()
ATTEMPTS = max(1, int(os.environ.get("STLINK_ATTEMPTS") or "3", 0))
OCD_TIMEOUT = float(os.environ.get("STLINK_OPENOCD_TIMEOUT") or 300)
FULL_VERIFY = (os.environ.get("STLINK_FULL_VERIFY") or "1").strip().lower() not in (
    "0", "false", "no", "off",
)

# (label, phys, usable size). AXI SRAM first: it answers debug accesses on this
# fixture, DTCM does not.
CANDIDATES = (
    ("AXI SRAM (D1)", 0x24000000, 0x80000),
    ("SRAM1 (D2)", 0x30000000, 0x20000),
    ("SRAM4 (D3)", 0x38000000, 0x10000),
    ("DTCM (CM7)", 0x20000000, 0x20000),
)
RAM_RANGES = (
    (0x20000000, 0x20020000),
    (0x24000000, 0x24080000),
    (0x30000000, 0x30048000),
    (0x38000000, 0x38010000),
)


def usage_error(msg: str):
    sys.stderr.write(msg + "\n")
    raise SystemExit(1)


# --------------------------------------------------------------------------- image

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
        elif rt == 2:
            base_ela = int(line[9:13], 16) << 4
        elif rt == 0:
            a = base_ela + addr
            for i in range(rl):
                data[a + i] = int(line[9 + 2 * i: 11 + 2 * i], 16)
        elif rt == 1:
            break
    if not data:
        usage_error(f"no data in {path}")
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
    usage_error(f"unsupported extension: {suffix}")

if not image:
    usage_error(f"{img_path} is empty")

end = flash_base + len(image)
if flash_base < FLASH_BASE or end > FLASH_BASE + FLASH_MAX:
    usage_error(
        f"image range {flash_base:#010x}..{end:#010x} is outside internal flash "
        f"{FLASH_BASE:#010x}..{FLASH_BASE + FLASH_MAX:#010x}; refusing to write "
        "(use the correct base address for a .bin)"
    )


# --------------------------------------------------------------------------- openocd

def run_openocd(commands: list[str], timeout: float = OCD_TIMEOUT) -> tuple[int, str]:
    cmd: list[str] = [OPENOCD, "-f", cfg]
    for c in commands:
        cmd += ["-c", c]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        usage_error(f"{OPENOCD}: not found")
    except subprocess.TimeoutExpired:
        return 124, f"TIMEOUT: openocd did not finish within {timeout:.0f}s"
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def wa_commands(phys: int, size: int) -> list[str]:
    """Tcl snippets that relocate the flash-loader work area before `init`."""
    return [
        "set _tgt [lindex [target names] 0]",
        f"$_tgt configure -work-area-phys {phys:#x} -work-area-size {size:#x}",
    ]


def ok_text(text: str) -> bool:
    return "verified" in text.lower() and "Error:" not in text


def diagnose(text: str) -> str:
    """Short human-readable reason for an OpenOCD failure."""
    low = text.lower()
    for m in re.finditer(r"failed to (?:write|read) memory at (0x[0-9a-f]+)", low):
        addr = int(m.group(1), 16)
        for lo, hi in RAM_RANGES:
            if lo <= addr < hi:
                return (
                    f"RAM write fault at {m.group(1)} - flash loader work area "
                    "is not reachable over SWD"
                )
    if "unable to connect" in low or "init mode failed" in low:
        return "SWD connect failed - check pogo contact, target power, SWCLK/SWDIO"
    if "dap transaction stalled" in low or "stalled" in low:
        return "SWD stalls at this adapter speed"
    if "flash write algorithm aborted" in low or "flash_sr" in low:
        return "flash controller rejected the write (FLASH_SR error)"
    if "timeout" in low:
        return "openocd timed out"
    return "unknown OpenOCD failure"


# ---------------------------------------------------------------- work-area pick

def ram_usable(phys: int, size: int, speed: int) -> tuple[bool, str]:
    lo = phys
    hi = phys + min(size, WA_SIZE) - 4
    pat_lo, pat_hi = 0x5AA5C33C, 0x3CC35AA5
    cmds = wa_commands(phys, size) + [
        f"init; adapter speed {speed}; halt",
        f"mww {lo:#x} {pat_lo:#x}",
        f"mww {hi:#x} {pat_hi:#x}",
        f"mdw {lo:#x}",
        f"mdw {hi:#x}",
        "exit",
    ]
    rc, text = run_openocd(cmds, timeout=min(OCD_TIMEOUT, 60))
    if rc != 0 or "Error:" in text:
        return False, text
    low = text.lower()
    return (f"{pat_lo:08x}" in low and f"{pat_hi:08x}" in low), text


def pick_work_area(speed: int) -> tuple[int, int, str]:
    if FORCED_WA:
        phys = int(FORCED_WA, 0)
        ok, text = ram_usable(phys, WA_SIZE, speed)
        if not ok:
            sys.stderr.write(text)
            sys.stderr.write(
                f"FLASH_FAILED work area {phys:#x} (forced) is not writable: "
                f"{diagnose(text)}\n"
            )
            raise SystemExit(2)
        print(f"work area {phys:#x} (forced) - RAM check ok", flush=True)
        return phys, WA_SIZE, "forced"

    failures: list[str] = []
    for label, phys, usable in CANDIDATES:
        if usable < WA_SIZE:
            continue
        ok, text = ram_usable(phys, usable, speed)
        if ok:
            print(f"work area {label} @ {phys:#x} - RAM check ok", flush=True)
            return phys, WA_SIZE, label
        failures.append(f"    {label} @ {phys:#x}: {diagnose(text)}")
        print(
            f"work area {label} @ {phys:#x} - RAM check FAILED "
            f"({diagnose(text)})",
            flush=True,
        )

    sys.stderr.write("no writable work area for the flash loader:\n")
    for line in failures:
        sys.stderr.write(line + "\n")
    sys.stderr.write(
        "FLASH_FAILED no writable RAM for the flash loader - target not halted "
        "or SWD contact broken\n"
    )
    raise SystemExit(2)


# ---------------------------------------------------------------------- flashing

n_chunks = (len(image) + SECTOR - 1) // SECTOR
print(
    f"flashing {img_path.name}: {len(image)} bytes @ {flash_base:#x} "
    f"in {n_chunks} sector(s)",
    flush=True,
)

speed = SPEED
print(f"adapter speed {speed} kHz", flush=True)
wa_phys, wa_size, wa_label = pick_work_area(speed)

tmpdir = Path(tempfile.mkdtemp(prefix="stlink_flash_"))
started = time.monotonic()
try:
    parts: list[Path] = []
    for n in range(n_chunks):
        piece = image[n * SECTOR:(n + 1) * SECTOR]
        if len(piece) % 32:
            piece += b"\xFF" * (32 - len(piece) % 32)
        part = tmpdir / f"part_{n:02d}.bin"
        part.write_bytes(piece)
        parts.append(part)

        addr = flash_base + n * SECTOR
        # Erase whole sectors that the chunk touches.
        erase_start = FLASH_BASE + ((addr - FLASH_BASE) // SECTOR) * SECTOR
        erase_len = (
            ((addr + len(piece) - erase_start) + SECTOR - 1) // SECTOR
        ) * SECTOR
        print(
            f"  sector {n}/{n_chunks - 1} @ {addr:#x} ({len(piece)} bytes, "
            f"erase {erase_len // 1024} KiB)",
            flush=True,
        )

        last_text = ""
        for attempt in range(1, ATTEMPTS + 1):
            cmds = wa_commands(wa_phys, wa_size) + [
                f"init; adapter speed {speed}; halt",
                f"flash erase_address {erase_start:#x} {erase_len}",
                f"flash write_image {part} {addr:#x}",
                f"verify_image {part} {addr:#x}",
                "exit",
            ]
            rc, last_text = run_openocd(cmds)
            if rc == 0 and ok_text(last_text):
                break

            reason = diagnose(last_text)
            print(f"    attempt {attempt}/{ATTEMPTS} failed: {reason}", flush=True)
            for line in last_text.splitlines():
                if "Error" in line or "Failed" in line or "Warn" in line:
                    print(f"      {line}", flush=True)

            if attempt == ATTEMPTS:
                break

            if "work area" in reason or "RAM write fault" in reason:
                # Re-run the RAM survey: the target may have come back in a
                # different state, or another region may be healthy.
                print("    re-checking work area...", flush=True)
                FORCED_WA = ""  # let the auto-detection move off a dead region
                wa_phys, wa_size, wa_label = pick_work_area(speed)
            elif "stalls" in reason:
                speed = max(25, speed // 2)
                print(f"    lowering adapter speed to {speed} kHz", flush=True)
            time.sleep(1.0)

        if not (rc == 0 and ok_text(last_text)):
            sys.stderr.write(last_text)
            sys.stderr.write(
                f"FLASH_FAILED sector {n} @ {addr:#x}: {diagnose(last_text)}\n"
            )
            raise SystemExit(3)

        done = sum(p.stat().st_size for p in parts)
        elapsed = time.monotonic() - started
        rate = done / 1024 / elapsed if elapsed > 0 else 0
        print(f"    verified ({done} bytes, {rate:.0f} KiB/s)", flush=True)

    # Whole-image verify in one session (each sector is already verified above;
    # STLINK_FULL_VERIFY=0 skips the second pass).
    if not FULL_VERIFY:
        print("Verified OK (per-sector)", flush=True)
        elapsed = time.monotonic() - started
        print(
            f"FLASH_OK {len(image)} bytes @ {flash_base:#x} "
            f"work-area {wa_phys:#x} ({wa_label}) speed {speed} kHz "
            f"in {elapsed:.1f}s",
            flush=True,
        )
        raise SystemExit(0)

    print("full verify...", flush=True)
    whole = tmpdir / "whole.bin"
    padded = bytearray()
    for part in parts:
        padded.extend(part.read_bytes())
    whole.write_bytes(bytes(padded))

    last_text = ""
    for attempt in range(1, ATTEMPTS + 1):
        cmds = wa_commands(wa_phys, wa_size) + [
            f"init; adapter speed {speed}; halt",
            f"verify_image {whole} {flash_base:#x}",
            "exit",
        ]
        rc, last_text = run_openocd(cmds, timeout=OCD_TIMEOUT * 2)
        if rc == 0 and ok_text(last_text):
            print("Verified OK", flush=True)
            break
        print(f"    verify attempt {attempt}/{ATTEMPTS} failed", flush=True)
        for line in last_text.splitlines():
            if "Error" in line or "Failed" in line:
                print(f"      {line}", flush=True)
        time.sleep(1.0)
    else:
        sys.stderr.write(last_text)
        sys.stderr.write(f"FLASH_FAILED full verify: {diagnose(last_text)}\n")
        raise SystemExit(3)

    elapsed = time.monotonic() - started
    print(
        f"FLASH_OK {len(image)} bytes @ {flash_base:#x} "
        f"work-area {wa_phys:#x} ({wa_label}) speed {speed} kHz "
        f"in {elapsed:.1f}s",
        flush=True,
    )
finally:
    for p in tmpdir.glob("*"):
        p.unlink(missing_ok=True)
    tmpdir.rmdir()
PY
