#!/bin/bash
# Flash .bin/.hex via ST-LINK for IndiH743 (no NRST).
#
# Two fixture quirks are handled here:
#
# 1. Flash-loader RAM. OpenOCD defaults the STM32H7 work area to DTCM
#    (0x20000000); writes there fault on this fixture ("Failed to write memory
#    at 0x2000xxxx") and the loader is never downloaded. We probe RAM and use
#    the first healthy region, AXI SRAM first.
#
# 2. Halting. `halt` on a running app does not stick (erratum 3092511 leaves
#    the core running, and the app's IWDG then resets the chip mid erase/write:
#    "erase time-out", "Fail reading CTRL/STAT register", "unable to connect").
#    Every sector session therefore starts with `reset halt` - SYSRESETREQ
#    plus vector catch stops the core at the reset vector before any software
#    runs, and that also leaves IWDG unarmed. The halt is confirmed by reading
#    DHCSR before anything is erased; without a confirmed halt nothing is
#    erased.
#
#   tools/stlink_flash.sh <image.bin|image.hex> [base_addr_for_bin]
#
# Environment overrides:
#   STLINK_SPEED            first SWD kHz             (default 50)
#   STLINK_FAST_SPEED       kHz after a good sector   (default 200, 0 = never)
#   STLINK_WORKAREA         forced loader RAM address (default: auto)
#   STLINK_WORKAREA_SIZE    loader RAM size           (default 0x10000)
#   STLINK_RESET_HALT       1 = halt out of reset     (default 1)
#   STLINK_HALT_TRIES       halt attempts             (default 4)
#   STLINK_ATTEMPTS         attempts per sector       (default 3)
#   STLINK_OPENOCD_TIMEOUT  per-session timeout s     (default 300)
#   STLINK_FULL_VERIFY      whole-image verify pass   (default 1)
#   STLINK_RUN_AFTER        1 = `reset run` at end    (default 1)
#   OPENOCD                 openocd binary            (default openocd)
#
# Exit codes: 0 ok, 1 usage/file error, 2 no writable work area,
#             3 flash/verify failed, 4 target could not be halted.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CFG="${ROOT}/openocd_fixture.cfg"
PY="${ROOT}/../venv/bin/python3"
[[ -x "$PY" ]] || PY=python3

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'
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

DHCSR = 0xE000EDF0               # bit 17 = S_HALT
DHCSR_S_HALT = 1 << 17
IWDG_KR = 0x58004800
IWDG_PR = 0x58004804
IWDG_RLR = 0x58004808
IWDG_SR = 0x5800480C


def _env(name, default):
    return (os.environ.get(name) or "").strip() or default


def _flag(name, default=True):
    val = (os.environ.get(name) or "").strip().lower()
    if not val:
        return default
    return val not in ("0", "false", "no", "off")


OPENOCD = _env("OPENOCD", "openocd")
SPEED = int(_env("STLINK_SPEED", "50"), 0)
FAST_SPEED = int(_env("STLINK_FAST_SPEED", "200"), 0)
WA_SIZE = int(_env("STLINK_WORKAREA_SIZE", "0x10000"), 0)
FORCED_WA = _env("STLINK_WORKAREA", "")
RESET_HALT = _flag("STLINK_RESET_HALT", True)
HALT_TRIES = max(1, int(_env("STLINK_HALT_TRIES", "4"), 0))
ATTEMPTS = max(1, int(_env("STLINK_ATTEMPTS", "3"), 0))
OCD_TIMEOUT = float(_env("STLINK_OPENOCD_TIMEOUT", "300"))
FULL_VERIFY = _flag("STLINK_FULL_VERIFY", True)
RUN_AFTER = _flag("STLINK_RUN_AFTER", True)

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
        return 124, "TIMEOUT: openocd did not finish in time"
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def wa_commands(phys: int, size: int) -> list[str]:
    """Tcl snippets that relocate the flash-loader work area before `init`."""
    return [
        "set _tgt [lindex [target names] 0]",
        f"$_tgt configure -work-area-phys {phys:#x} -work-area-size {size:#x}",
    ]


def dhcsr_from(text: str) -> int | None:
    """Parse the DHCSR value out of an `mdw 0xE000EDF0` dump."""
    m = None
    for m in re.finditer(r"0xe000edf0:\s*([0-9a-f]{8})", text, re.I):
        pass
    return int(m.group(1), 16) if m else None


def halted(text: str) -> bool:
    value = dhcsr_from(text)
    return value is not None and bool(value & DHCSR_S_HALT)


def stage_of(text: str) -> str | None:
    """Last FLASH_STAGE marker reached in an OpenOCD session."""
    found = re.findall(r"FLASH_STAGE\s+(\w+)", text)
    return found[-1] if found else None


def kind_of(text: str) -> str:
    """Failure kind from a session log."""
    low = text.lower()
    if "FLASH_EVENT halt_failed" in text:
        return "halt"
    if "erase time-out" in low or "failed erasing" in low or "erase_address" in low and "error" in low:
        return "erase"
    if "flash write algorithm" in low or "writing to address 0x52" in low or "lock of flash" in low:
        return "write"
    if "ctlr/stat" in low or "force reconnect" in low or "init mode failed" in low:
        return "swd"
    for m in re.finditer(r"failed to (?:write|read) memory at (0x[0-9a-f]+)", low):
        addr = int(m.group(1), 16)
        for lo, hi in RAM_RANGES:
            if lo <= addr < hi:
                return "ram"
    if "verify" in low and "error" in low:
        return "verify"
    if "timeout" in low or "timed out" in low:
        return "timeout"
    return "unknown"


def explain(kind: str) -> str:
    return {
        "halt": (
            "target did not halt - the core kept running (erratum 3092511 / "
            "app not stopped by `halt`), so nothing was erased"
        ),
        "erase": (
            "flash erase failed - usually the target reset itself mid-erase "
            "(independent watchdog or brownout)"
        ),
        "write": "flash write failed inside the loader algorithm",
        "swd": "SWD link was lost - pogo contact, target power or SWCLK/SWDIO",
        "ram": (
            "flash-loader RAM is unreachable over SWD (work area) - the target "
            "is probably not halted, or SWD contact is broken"
        ),
        "verify": "image read back different from what was written",
        "timeout": "OpenOCD did not finish in time",
        "unknown": "OpenOCD failed (see log)",
    }.get(kind, "OpenOCD failed (see log)")


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
                f"FLASH_FAILED ram: work area {phys:#x} (forced) is not writable "
                f"- {explain('ram')}\n"
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
        failures.append(f"    {label} @ {phys:#x}: {explain(kind_of(text))}")
        print(
            f"work area {label} @ {phys:#x} - RAM check FAILED "
            f"({explain(kind_of(text))})",
            flush=True,
        )

    sys.stderr.write("no writable work area for the flash loader:\n")
    for line in failures:
        sys.stderr.write(line + "\n")
    sys.stderr.write(
        "FLASH_FAILED ram: no writable RAM for the flash loader - target not "
        "halted or SWD contact broken\n"
    )
    raise SystemExit(2)


# --------------------------------------------------------------------- halt first

def halt_target(speed: int) -> str:
    """Stop the core before any erase. Returns how it was achieved.

    `reset halt` is the safe path: SYSRESETREQ plus vector catch stops the core
    at the reset vector before any software runs, and leaves IWDG unarmed.
    Falls back to halting a running core with the watchdog stretched, which is
    racy (the IWDG may already be counting).
    """
    last = ""

    if RESET_HALT:
        for attempt in range(1, HALT_TRIES + 1):
            cmds = [
                f"init; adapter speed {speed}",
                "catch {reset halt}",
                f"mdw {DHCSR:#x}",
                "exit",
            ]
            rc, text = run_openocd(cmds, timeout=min(OCD_TIMEOUT, 90))
            last = text
            if halted(text):
                if attempt > 1:
                    print(f"target halted out of reset (attempt {attempt})", flush=True)
                else:
                    print("target halted out of reset", flush=True)
                return "reset-halt"

            # A running app: stop it and stretch the IWDG before it bites.
            cmds = [
                f"init; adapter speed {speed}",
                "catch {halt}",
                f"catch {{mww {IWDG_KR:#x} 0x5555}}",
                f"catch {{mww {IWDG_RLR:#x} 0xfff}}",
                f"catch {{mww {IWDG_KR:#x} 0xaaaa}}",
                f"mdw {DHCSR:#x}",
                "exit",
            ]
            rc, text = run_openocd(cmds, timeout=min(OCD_TIMEOUT, 90))
            last = text
            if halted(text):
                print(
                    "target halted with plain halt (watchdog stretched) - "
                    "less reliable than reset halt",
                    flush=True,
                )
                return "halt"
            time.sleep(min(4.0, 1.5 * attempt))

    # Last resort: iterate `halt` without a reset, in one session.
    cmds = [
        f"init; adapter speed {speed}",
        "catch {halt}",
        "sleep 200",
        "catch {halt}",
        "sleep 500",
        "catch {halt}",
        f"mdw {DHCSR:#x}",
        "exit",
    ]
    rc, text = run_openocd(cmds, timeout=min(OCD_TIMEOUT, 90))
    last = text
    if halted(text):
        print("target halted after repeated halt requests (watchdog not reset)", flush=True)
        return "halt-retry"

    kind = kind_of(last)
    if kind in ("halt", "unknown"):
        kind = "halt"
    sys.stderr.write(last)
    sys.stderr.write(
        f"FLASH_FAILED {kind}: target could not be halted - {explain(kind)}\n"
        "    nothing was erased.\n"
        "    next steps: seat contact again, power-cycle the pad (jog away and "
        "back), then retry; keep SWD short and slow (STLINK_SPEED=25)\n"
    )
    raise SystemExit(4)


# ---------------------------------------------------------------------- flashing

n_chunks = (len(image) + SECTOR - 1) // SECTOR
print(
    f"flashing {img_path.name}: {len(image)} bytes @ {flash_base:#x} "
    f"in {n_chunks} sector(s)",
    flush=True,
)
print(f"adapter speed {SPEED} kHz", flush=True)

speed = SPEED
# Stop the core first: without a confirmed halt nothing may be erased, and the
# RAM probe is only meaningful once the target is under control.
halt_mode = halt_target(speed)
wa_phys, wa_size, wa_label = pick_work_area(speed)

tmpdir = Path(tempfile.mkdtemp(prefix="stlink_flash_"))
started = time.monotonic()


def sector_commands(erase_start: int, erase_len: int, part: Path, addr: int) -> str:
    """One self-contained session: halt out of reset, then erase/write/verify.

    The stages only run when the halt succeeded, so a core that will not stop
    can never be erased underneath.
    """
    stages = [
        'echo "FLASH_EVENT halt_ok"',
        'echo "FLASH_STAGE erase"',
        f"flash erase_address {erase_start:#x} {erase_len:#x}",
        'echo "FLASH_STAGE write"',
        f"flash write_image {part} {addr:#x}",
        'echo "FLASH_STAGE verify"',
        f"verify_image {part} {addr:#x}",
        'echo "FLASH_STAGE done"',
    ]
    body = "\n".join("    " + s for s in stages)
    if not RESET_HALT:
        return body
    return "\n".join(
        [
            "set _rc [catch {reset halt} _e]",
            "if {$_rc != 0} {",
            '    echo "FLASH_EVENT halt_failed $_e"',
            "} else {",
            body,
            "}",
        ]
    )


try:
    parts: list[Path] = []
    good_speed = speed
    for n in range(n_chunks):
        piece = image[n * SECTOR:(n + 1) * SECTOR]
        padded = piece if len(piece) % 32 == 0 else piece + b"\xFF" * (32 - len(piece) % 32)
        part = tmpdir / f"part_{n:02d}.bin"
        part.write_bytes(padded)
        parts.append(part)

        addr = flash_base + n * SECTOR
        # Erase whole sectors that the chunk touches (erase works in sectors).
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
        kind = "unknown"
        ok = False
        for attempt in range(1, ATTEMPTS + 1):
            cmds = wa_commands(wa_phys, wa_size) + [
                f"init; adapter speed {speed}",
                sector_commands(erase_start, erase_len, part, addr),
                "exit",
            ]
            rc, last_text = run_openocd(cmds)
            stage = stage_of(last_text)
            ok = rc == 0 and stage == "done" and "verified" in last_text.lower()
            if ok:
                break

            kind = kind_of(last_text)
            detail = (
                f"halt not confirmed" if kind == "halt" else f"failed during {stage or 'init'}"
            )
            print(
                f"    attempt {attempt}/{ATTEMPTS} failed: {detail} "
                f"({explain(kind)})",
                flush=True,
            )
            for line in last_text.splitlines():
                if "Error" in line or "Failed" in line:
                    print(f"      {line}", flush=True)

            if attempt == ATTEMPTS:
                break

            if kind in ("halt", "swd"):
                # Re-halt from scratch; the chip may have been reset by its
                # watchdog, which also means it is safe to slow SWD down.
                time.sleep(min(5.0, 1.5 * attempt))
                try:
                    halt_target(speed)
                except SystemExit:
                    pass
            elif kind == "ram":
                FORCED_WA = ""
                try:
                    wa_phys, wa_size, wa_label = pick_work_area(speed)
                except SystemExit:
                    pass
            elif kind in ("erase", "write", "unknown") and speed > 25:
                speed = max(25, speed // 2)
                print(f"    lowering adapter speed to {speed} kHz", flush=True)
            else:
                time.sleep(1.0)

        if not ok:
            sys.stderr.write(last_text)
            sys.stderr.write(
                f"FLASH_FAILED {kind}: sector {n} @ {addr:#x} - {explain(kind)}\n"
            )
            raise SystemExit(3)

        done = sum(p.stat().st_size for p in parts[:n + 1])
        elapsed = time.monotonic() - started
        rate = done / 1024 / elapsed if elapsed > 0 else 0
        print(f"    verified ({done} bytes, {rate:.0f} KiB/s)", flush=True)

        # Ramp SWD up once a sector has been proven, but remember what worked.
        good_speed = speed
        if FAST_SPEED and speed < FAST_SPEED:
            speed = min(FAST_SPEED, speed * 2)
            print(f"    adapter speed -> {speed} kHz", flush=True)

    # Whole-image verify in one session (each sector is already verified above;
    # STLINK_FULL_VERIFY=0 skips the second pass).
    if FULL_VERIFY:
        print("full verify...", flush=True)
        whole = tmpdir / "whole.bin"
        whole.write_bytes(b"".join(p.read_bytes() for p in parts))

        last_text = ""
        ok = False
        for attempt in range(1, ATTEMPTS + 1):
            cmds = wa_commands(wa_phys, wa_size) + [
                f"init; adapter speed {speed}",
                "catch {reset halt}",
                f"verify_image {whole} {flash_base:#x}",
                "exit",
            ]
            rc, last_text = run_openocd(cmds, timeout=OCD_TIMEOUT * 2)
            ok = rc == 0 and "verified" in last_text.lower() and "Error:" not in last_text
            if ok:
                break
            print(f"    verify attempt {attempt}/{ATTEMPTS} failed", flush=True)
            for line in last_text.splitlines():
                if "Error" in line or "Failed" in line:
                    print(f"      {line}", flush=True)
            time.sleep(1.0)
            speed = good_speed
        if not ok:
            sys.stderr.write(last_text)
            sys.stderr.write(
                f"FLASH_FAILED verify: whole-image verify failed - "
                f"{explain(kind_of(last_text))}\n"
            )
            raise SystemExit(3)
        print("Verified OK", flush=True)
    else:
        print("Verified OK (per-sector)", flush=True)

    if RUN_AFTER:
        rc, text = run_openocd(
            [f"init; adapter speed {speed}", "reset run", 'echo "FLASH_RUN"', "exit"],
            timeout=min(OCD_TIMEOUT, 120),
        )
        if "FLASH_RUN" in text and "Error:" not in text:
            print("target released with reset run", flush=True)
        else:
            print(
                "warning: `reset run` did not confirm - power-cycle the pad "
                "(jog away and back) to start the firmware",
                flush=True,
            )

    elapsed = time.monotonic() - started
    print(
        f"FLASH_OK {len(image)} bytes @ {flash_base:#x} "
        f"work-area {wa_phys:#x} ({wa_label}) halt {halt_mode} "
        f"speed {good_speed} kHz in {elapsed:.1f}s",
        flush=True,
    )
finally:
    for p in tmpdir.glob("*"):
        p.unlink(missing_ok=True)
    tmpdir.rmdir()
PY
