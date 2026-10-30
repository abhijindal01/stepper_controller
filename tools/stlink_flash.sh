#!/bin/bash
# Flash .bin/.hex via ST-LINK for IndiH743 (no NRST).
#
# Three fixture quirks are handled here:
#
# 1. Flash-loader RAM. OpenOCD defaults the STM32H7 work area to DTCM
#    (0x20000000); writes there fault on this fixture ("Failed to write memory
#    at 0x2000xxxx") and the loader is never downloaded. We probe RAM and use
#    the first healthy region, AXI SRAM first. The probe covers the *loader
#    footprint*, not just the ends of the window: a work area that answers a
#    single word at 0x24000000 can still fail every loader write
#    ("Failed to write memory at 0x24001874").
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
# 3. Order. Sector 0 carries the vector table (and the bootloader), so it is
#    written *last*: an interrupted multi-sector flash then leaves a board that
#    still boots instead of one with a blank vector table (SP=0xFFFFFFFC ->
#    lockup, pc=0xFFFFFFFE). Retries after a completed erase never erase again.
#
#   tools/stlink_flash.sh <image.bin|image.hex> [base_addr_for_bin]
#
# Environment overrides:
#   STLINK_SPEED            first SWD kHz             (default 50)
#   STLINK_FAST_SPEED       kHz after a good sector   (default 200, 0 = never)
#   STLINK_MIN_SPEED        slowest kHz tried         (default 12)
#   STLINK_WORKAREA         forced loader RAM address (default: auto)
#   STLINK_WORKAREA_SIZE    loader RAM size           (default 0x10000)
#   STLINK_RESET_HALT       1 = halt out of reset     (default 1)
#   STLINK_HALT_TRIES       halt attempts             (default 4)
#   STLINK_ATTEMPTS         attempts per sector       (default 3)
#   STLINK_OPENOCD_TIMEOUT  per-session timeout s     (default 300)
#   STLINK_CONNECT_BACKOFF  seconds before a connect retry (default 2)
#   STLINK_FULL_VERIFY      whole-image verify pass   (default 1)
#   STLINK_RUN_AFTER        1 = `reset run` at end    (default 1)
#   STLINK_PROBE_SIZE       1 = probe the device flash size first (default 1)
#   STLINK_ALLOW_OVERSIZE   1 = write an image bigger than the probed flash
#                            (default 0: refuse, see FLASH_WARN in the log)
#   OPENOCD                 openocd binary            (default openocd)
#
# Exit codes: 0 ok, 1 usage/file error (including an image that does not fit
#             the probed flash size), 2 no writable work area or unhealthy
#             link, 3 flash/verify failed or link lost, 4 target would not
#             halt, 5 the board's vector table is blank and this image does not
#             restore it (flash a full image from 0x08000000 instead).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CFG="${ROOT}/openocd_fixture.cfg"
PY="${ROOT}/../venv/bin/python3"
[[ -x "$PY" ]] || PY=python3

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'
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
MIN_SPEED = int(_env("STLINK_MIN_SPEED", "12"), 0)
WA_SIZE = int(_env("STLINK_WORKAREA_SIZE", "0x10000"), 0)
FORCED_WA = _env("STLINK_WORKAREA", "")
RESET_HALT = _flag("STLINK_RESET_HALT", True)
HALT_TRIES = max(1, int(_env("STLINK_HALT_TRIES", "4"), 0))
ATTEMPTS = max(1, int(_env("STLINK_ATTEMPTS", "3"), 0))
OCD_TIMEOUT = float(_env("STLINK_OPENOCD_TIMEOUT", "300"))
CONNECT_BACKOFF = float(_env("STLINK_CONNECT_BACKOFF", "2"))
FULL_VERIFY = _flag("STLINK_FULL_VERIFY", True)
RUN_AFTER = _flag("STLINK_RUN_AFTER", True)
PROBE_SIZE = _flag("STLINK_PROBE_SIZE", True)
ALLOW_OVERSIZE = _flag("STLINK_ALLOW_OVERSIZE", False)

# Sectors that were erased but not written back yet. Every failure message
# repeats this, because "nothing was erased" is only true when it is empty.
TOUCHED: list[str] = []

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


def ap_errors(text: str) -> bool:
    """True when core debug registers (0xE0001000-0xE00FFFFF) fail to answer.

    Those writes go through the same AP as everything else, so a failure there
    is a link/AP problem, not a halt or flash problem: the log usually looks
    like `Failed to write memory at 0xe0002010` (FPB) or
    `Execution of event examine-end failed`.
    """
    low = text.lower()
    if re.search(r"failed to (?:write|read) memory at 0xe0[0-9a-f]{5}", low):
        return True
    return "examine-end failed" in low


def kind_of(text: str) -> str:
    """Failure kind from a session log."""
    low = text.lower()
    if "ctlr/stat" in low or "force reconnect" in low or "init mode failed" in low:
        return "swd"
    if "FLASH_EVENT halt_failed" in text or "target not halted" in low:
        # halt failed *because* the debug registers stopped answering?
        return "ap" if ap_errors(text) else "halt"
    if ap_errors(text):
        return "ap"
    if "erase time-out" in low or "failed erasing" in low or "erase_address" in low and "error" in low:
        return "erase"
    if "flash write algorithm" in low or "writing to address 0x52" in low or "lock of flash" in low:
        return "write"
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
        "ap": (
            "core debug registers (0xE0001000+) do not answer - SWD link or "
            "AP is failing, so the target can neither be examined nor halted; "
            "nothing was erased"
        ),
        "erase": (
            "flash erase failed - usually the target reset itself mid-erase "
            "(independent watchdog or brownout)"
        ),
        "write": "flash write failed inside the loader algorithm",
        "swd": (
            "SWD link was lost or never came up - pogo contact, target power "
            "or SWCLK/SWDIO"
        ),
        "ram": (
            "the flash-loader work area did not hold the probe pattern - "
            "either the write failed (SWD link collapsing under load, target "
            "not halted) or the RAM answered with different data"
        ),
        "verify": "image read back different from what was written",
        "timeout": "OpenOCD did not finish in time",
        "unknown": "OpenOCD failed (see log)",
    }.get(kind, "OpenOCD failed (see log)")


# ---------------------------------------------------------------- work-area pick

# Offsets inside the work area that the flash loader really touches: OpenOCD
# downloads the loader blob at the base, allocates its parameter block and the
# image buffer after it, and then streams the image through that buffer. A
# probe that only pokes the first and the last word of the 64 KiB window says
# "RAM check ok" while every loader write past a few KiB fails:
#
#     work area AXI SRAM (D1) @ 0x24000000 - RAM check ok
#     Error: Failed to write memory at 0x24001874
#     Error: error writing to flash at address 0x08000000 at offset 0x00000000
#
# So probe the footprint (and a 32-word burst through it), not the ends of the
# window: a link that cannot sustain writes is caught *before* anything is
# erased.
WA_PROBE_OFFSETS = (
    0x0000, 0x0400, 0x0800, 0x1000, 0x1874,
    0x2000, 0x2800, 0x3074, 0x3994, 0x4000, 0x4074, 0x8000,
)
WA_BURST_AT = 0x1000
WA_BURST_WORDS = 32


def _probe_value(idx: int, addr: int) -> int:
    return (0x5AA50000 | ((idx & 0xFF) << 8)) ^ (addr & 0xFFFF)


def ram_usable(phys: int, size: int, speed: int) -> tuple[bool, str, int | None]:
    """Write a pattern through the loader footprint and read it back.

    Returns (ok, log, bad_address). `bad_address` is the first spot that did
    not hold the pattern, or None when the failure was elsewhere (no connect,
    link lost, ...).
    """
    size = min(size, WA_SIZE)
    spots: list[int] = [
        phys + off for off in WA_PROBE_OFFSETS if off + 4 <= size
    ]
    spots += [
        phys + WA_BURST_AT + 4 * i
        for i in range(WA_BURST_WORDS)
        if WA_BURST_AT + 4 * i + 4 <= size
    ]
    expected = {addr: _probe_value(i, addr) for i, addr in enumerate(spots)}

    cmds = wa_commands(phys, size) + [f"init; adapter speed {speed}; halt"]
    cmds += [f"mww {addr:#x} {val:#x}" for addr, val in expected.items()]
    cmds += [f"mdw {addr:#x}" for addr in expected]
    cmds.append("exit")

    rc, text = run_openocd(cmds, timeout=min(OCD_TIMEOUT, 90))
    if rc != 0 or "Error:" in text:
        # Report *which* spot died: that address is what the loader would have
        # hit, and 0x24001874 / 0x24004074 in an OpenOCD log are the signature
        # of this fixture.
        bad = None
        for m in re.finditer(
            r"failed to (?:write|read) memory at (0x[0-9a-f]+)", text, re.I
        ):
            addr = int(m.group(1), 16)
            if addr in expected:
                bad = addr
        return False, text, bad

    seen = {
        int(m.group(1), 16): int(m.group(2), 16)
        for m in re.finditer(r"0x([0-9a-f]{8}):\s*([0-9a-f]{8})", text, re.I)
    }
    for addr, want in expected.items():
        if seen.get(addr) != want:
            return False, text, addr
    return True, text, None


def damage_note() -> str:
    """What has already been erased - never claim "nothing" when it is false."""
    if not TOUCHED:
        return "    nothing was erased.\n"
    return (
        "    erased but NOT written: " + ", ".join(TOUCHED) + "\n"
        "    sector 0 @ 0x08000000 holds the vector table: if it is in that "
        "list the board\n"
        "    will not boot (pc 0xfffffffe / msp 0xfffffffc) until it is "
        "flashed again\n"
    )


def link_unhealthy(kind: str, text: str, tries: int) -> "SystemExit":
    """Build the failure for a link that will not carry AP transactions."""
    sys.stderr.write(text)
    sys.stderr.write(
        f"FLASH_FAILED {kind}: SWD link unhealthy ({tries} failures in a row) - "
        f"{explain(kind)}\n"
        + damage_note()
        + "    triage: tools/stlink_soak.sh (count good connects), then re-seat "
        "contact, check GND/SWCLK/SWDIO and target power\n"
    )
    return SystemExit(2)


def pick_work_area(speed: int) -> tuple[int, int, str]:
    if FORCED_WA:
        phys = int(FORCED_WA, 0)
        ok, text, bad = ram_usable(phys, WA_SIZE, speed)
        if not ok:
            sys.stderr.write(text)
            sys.stderr.write(
                f"FLASH_FAILED ram: work area {phys:#x} (forced) is not writable"
                + (f" at {bad:#x}" if bad else "")
                + f" - {explain('ram')}\n" + damage_note()
            )
            raise SystemExit(2)
        print(f"work area {phys:#x} (forced) - RAM check ok", flush=True)
        return phys, WA_SIZE, "forced"

    failures: list[str] = []
    for label, phys, usable in CANDIDATES:
        if usable < WA_SIZE:
            continue

        # A region that answers once on a flaky link is not evidence of
        # anything, so each candidate must pass twice when the first try
        # failed for link reasons (SWD loss / dead AP).
        for try_no in (1, 2):
            ok, text, bad = ram_usable(phys, usable, speed)
            if ok:
                print(f"work area {label} @ {phys:#x} - RAM check ok", flush=True)
                return phys, WA_SIZE, label

            kind = kind_of(text)
            where = f" at {bad:#x}" if bad else ""
            print(
                f"work area {label} @ {phys:#x} - RAM check FAILED{where} "
                f"({explain(kind)})",
                flush=True,
            )
            if kind in ("swd", "ap"):
                if try_no == 2:
                    # Probing further RAM is pointless: the bus itself is dying,
                    # so stop instead of "succeeding" on a luckier address.
                    raise link_unhealthy(kind, text, 2)
                time.sleep(0.5)
                continue

            failures.append(f"    {label} @ {phys:#x}{where}: {explain(kind)}")
            break

    sys.stderr.write("no writable work area for the flash loader:\n")
    for line in failures:
        sys.stderr.write(line + "\n")
    sys.stderr.write(
        "FLASH_FAILED ram: no writable RAM for the flash loader - target not "
        "halted or SWD contact broken\n" + damage_note()
    )
    raise SystemExit(2)


# --------------------------------------------------------------------- halt first

def _connect_error(text: str) -> bool:
    low = text.lower()
    return (
        "init mode failed" in low
        or "unable to connect" in low
        or ("failed to" in low and "memory at 0xe0" in low)
    )


def run_openocd_connect(commands: list[str], timeout: float = OCD_TIMEOUT) -> tuple[int, str]:
    """run_openocd, but retry a failed *connect* with backoff.

    These failures are transient - the same command succeeds seconds later on
    this fixture - so hammering the same session without a pause is pointless.
    """
    delays = [0.0, CONNECT_BACKOFF, min(5.0, CONNECT_BACKOFF * 2)]
    rc, text = 1, ""
    for delay in delays:
        if delay:
            time.sleep(delay)
        rc, text = run_openocd(commands, timeout=timeout)
        if not _connect_error(text):
            return rc, text
        print("    connect failed - retrying", flush=True)
    return rc, text


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
            rc, text = run_openocd_connect(cmds, timeout=min(OCD_TIMEOUT, 90))
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
            rc, text = run_openocd_connect(cmds, timeout=min(OCD_TIMEOUT, 90))
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
    rc, text = run_openocd_connect(cmds, timeout=min(OCD_TIMEOUT, 90))
    last = text
    if halted(text):
        print("target halted after repeated halt requests (watchdog not reset)", flush=True)
        return "halt-retry"

    kind = kind_of(last)
    if kind == "unknown":
        kind = "halt"
    # 3 = the link (or the debug port behind it) is broken, 4 = the target
    # refuses to stop. Both mean nothing was erased.
    exit_code = 4 if kind == "halt" else 3
    if kind in ("swd", "ap"):
        headline = "target could not be reached"
    else:
        headline = "target could not be halted"
    sys.stderr.write(last)
    sys.stderr.write(
        f"FLASH_FAILED {kind}: {headline} - {explain(kind)}\n"
        "    nothing was erased.\n"
        "    triage: tools/stlink_soak.sh (count good connects), then re-seat "
        "contact, power-cycle the pad (jog away and back) and retry at "
        "STLINK_SPEED=25\n"
    )
    raise SystemExit(exit_code)


# ------------------------------------------------------------- board state checks

def word_from(text: str, addr: int) -> int | None:
    """Last `mdw` dump value for `addr` in an OpenOCD log."""
    found = None
    for m in re.finditer(rf"0x{addr:08x}:\s*([0-9a-f]{{8}})", text, re.I):
        found = m.group(1)
    return int(found, 16) if found else None


def read_vectors(speed: int) -> tuple[int | None, int | None]:
    """SP/PC from the vector table at 0x08000000 (0xFFFFFFFF = blank sector)."""
    cmds = [
        f"init; adapter speed {speed}",
        "catch {halt}",
        f"mdw {FLASH_BASE:#x}",
        f"mdw {FLASH_BASE + 4:#x}",
        "exit",
    ]
    rc, text = run_openocd_connect(cmds, timeout=min(OCD_TIMEOUT, 90))
    return word_from(text, FLASH_BASE), word_from(text, FLASH_BASE + 4)


def vectors_state(sp: int | None) -> bool | None:
    """True = blank/garbage vector table, False = plausible, None = unknown.

    A linker puts the initial SP at the *top* of a RAM region (0x24080000 on
    this part), so the upper bound has to be inclusive - 0xFFFFFFFC (erased
    sector) and 0 (read failed / blank) are what we are looking for.
    """
    if sp is None:
        return None
    if sp in (0, 0xFFFFFFFF):
        return True
    return not any(lo <= sp <= hi for lo, hi in RAM_RANGES)


def probed_flash_size(speed: int) -> int | None:
    """Device flash size in bytes from the driver's own probe, if it answers."""
    rc, text = run_openocd(
        [
            f"init; adapter speed {speed}",
            "catch {halt}",
            "flash probe 0",
            "exit",
        ],
        timeout=min(OCD_TIMEOUT, 90),
    )
    m = None
    for m in re.finditer(r"flash size probed value\s+(\d+)\s*k", text, re.I):
        pass
    return int(m.group(1)) * 1024 if m else None


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

# Is there a vector table at 0x08000000? A previous run that erased sector 0 and
# then failed to write it leaves the board booting from 0xFFFFFFFF: SP
# 0xFFFFFFFC, pc 0xFFFFFFFE, hard fault loop. It still flashes over SWD, but it
# will not run - and jogging/power-cycling will not fix it.
sp, pc = read_vectors(speed)
blank = vectors_state(sp)
if blank:
    print(
        f"FLASH_EVENT vectors_blank SP={sp:#010x} PC={(pc if pc is not None else 0):#010x}",
        flush=True,
    )
    print(
        "WARNING: sector 0 @ 0x08000000 has no valid vector table - the board "
        "cannot boot\n"
        "    (pc 0xfffffffe / msp 0xfffffffc is what an erased sector looks "
        "like: an earlier\n"
        "    flash erased sector 0 and then failed before writing it back).",
        flush=True,
    )
    if flash_base > FLASH_BASE:
        sys.stderr.write(
            f"FLASH_FAILED vectors: this image starts at {flash_base:#x}, so it "
            "cannot restore the vector table at 0x08000000 - the board would "
            "stay unbootable\n"
            "    flash a full image from 0x08000000 (bootloader + app) instead\n"
        )
        raise SystemExit(5)
    print(
        "    this flash writes sector 0 last, so the board becomes bootable "
        "only if that\n"
        "    final sector verifies - do not power-cycle in between",
        flush=True,
    )
elif blank is False:
    print(f"vector table ok (SP={sp:#010x} PC={pc:#010x})", flush=True)

if PROBE_SIZE:
    device_flash = probed_flash_size(speed)
    if device_flash:
        dev_end = FLASH_BASE + device_flash
        print(f"device flash: probed {device_flash // 1024} KiB "
              f"({FLASH_BASE:#x}..{dev_end:#x})", flush=True)
        if end > dev_end:
            print(
                "FLASH_WARN image does not fit the probed flash size\n"
                f"    image : {flash_base:#010x}..{end:#010x} "
                f"({len(image)} bytes)\n"
                f"    device: {FLASH_BASE:#010x}..{dev_end:#010x} "
                f"({device_flash // 1024} KiB)\n"
                "    This part reports less flash than the 2 MiB the tooling "
                "assumes (H743xG is\n"
                "    1 MiB, an IndiH743 is normally 2 MiB). Sectors past "
                f"{dev_end:#010x} do not\n"
                "    exist, so the write would die there - after erasing "
                "everything before it.",
                flush=True,
            )
            if not ALLOW_OVERSIZE:
                sys.stderr.write(
                    "FLASH_FAILED size: refusing to write "
                    f"{len(image)} bytes into {device_flash // 1024} KiB of "
                    "flash - nothing was erased\n"
                    "    build the image for this part (FLASH_SIZE_KB), or "
                    "redo the probe if the\n"
                    "    part is really 2 MiB (STLINK_ALLOW_OVERSIZE=1 forces "
                    "the write)\n"
                )
                raise SystemExit(1)

wa_phys, wa_size, wa_label = pick_work_area(speed)

tmpdir = Path(tempfile.mkdtemp(prefix="stlink_flash_"))
started = time.monotonic()


def sector_commands(
    erase_start: int, erase_len: int, part: Path, addr: int, do_erase: bool = True
) -> str:
    """One self-contained session: halt out of reset, then erase/write/verify.

    The stages only run when the halt succeeded, so a core that will not stop
    can never be erased underneath. `do_erase=False` retries the write of a
    sector whose erase already completed - erasing again on every attempt is
    how a link glitch turns into a blank sector 0.
    """
    stages = ['echo "FLASH_EVENT halt_ok"']
    if do_erase:
        stages += [
            'echo "FLASH_STAGE erase"',
            f"flash erase_address {erase_start:#x} {erase_len:#x}",
        ]
    stages += [
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
    pieces: list[bytes] = []
    good_speed = speed
    done = 0
    for n in range(n_chunks):
        piece = image[n * SECTOR:(n + 1) * SECTOR]
        padded = piece if len(piece) % 32 == 0 else piece + b"\xFF" * (32 - len(piece) % 32)
        part = tmpdir / f"part_{n:02d}.bin"
        part.write_bytes(padded)
        parts.append(part)
        pieces.append(piece)

    # Sector 0 holds the vector table (and, on ArduPilot H7, the bootloader).
    # Write it last: if the link dies at sector 5 the board still boots the old
    # firmware instead of sitting in a hard-fault loop on a blank vector table.
    order = list(range(n_chunks))
    if n_chunks > 1:
        order = order[1:] + [0]
        print(
            f"sector order: 1..{n_chunks - 1}, then 0 - sector 0 (vector table / "
            "bootloader) is written last",
            flush=True,
        )

    for n in order:
        piece = pieces[n]
        part = parts[n]

        addr = flash_base + n * SECTOR
        # Erase whole sectors that the chunk touches (erase works in sectors).
        erase_start = FLASH_BASE + ((addr - FLASH_BASE) // SECTOR) * SECTOR
        erase_len = (
            ((addr + len(piece) - erase_start) + SECTOR - 1) // SECTOR
        ) * SECTOR
        note = " - vector table, last" if n == 0 and n_chunks > 1 else ""
        print(
            f"  sector {n}/{n_chunks - 1} @ {addr:#x} ({len(piece)} bytes, "
            f"erase {erase_len // 1024} KiB){note}",
            flush=True,
        )

        entry = f"sector {n} @ {addr:#x}"
        erased_here = False
        last_text = ""
        kind = "unknown"
        ok = False
        for attempt in range(1, ATTEMPTS + 1):
            cmds = wa_commands(wa_phys, wa_size) + [
                f"init; adapter speed {speed}",
                sector_commands(erase_start, erase_len, part, addr, not erased_here),
                "exit",
            ]
            rc, last_text = run_openocd_connect(cmds)
            stage = stage_of(last_text)
            ok = rc == 0 and stage == "done" and "verified" in last_text.lower()
            if ok:
                if entry in TOUCHED:
                    TOUCHED.remove(entry)
                break

            kind = kind_of(last_text)
            erase_done = stage in ("write", "verify", "done") or (
                "erased address" in last_text
            )
            if erase_done and entry not in TOUCHED:
                TOUCHED.append(entry)
            # Retry without a second erase - but only while the link is sane.
            # After a link failure the erase result is not trustworthy, so the
            # retry erases again.
            erased_here = erase_done and kind not in ("swd", "ap")

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

            if erased_here and kind not in ("halt", "swd", "ap"):
                print(
                    f"    sector {n} @ {addr:#x} is already erased - retrying the "
                    "write only (no second erase)",
                    flush=True,
                )

            if kind in ("halt", "swd"):
                # Re-halt from scratch; the chip may have been reset by its
                # watchdog, which also means it is safe to slow SWD down.
                time.sleep(min(5.0, 1.5 * attempt))
                try:
                    halt_target(speed)
                except SystemExit:
                    pass
            elif kind == "ram":
                # RAM answered the footprint probe but not the loader: re-probe
                # before writing again, and stop rather than grind on a dead bus.
                FORCED_WA = ""
                if erased_here:
                    print(
                        f"    sector {n} @ {addr:#x} is erased but NOT written - "
                        "re-probing the loader RAM",
                        flush=True,
                    )
                wa_phys, wa_size, wa_label = pick_work_area(speed)
            elif kind == "ap":
                # Debug-register writes failing: try slower before blaming the
                # harness, then stop rather than erase on a sick link.
                if speed > MIN_SPEED:
                    speed = max(MIN_SPEED, speed // 2)
                    print(f"    lowering adapter speed to {speed} kHz", flush=True)
                else:
                    time.sleep(min(5.0, 1.5 * attempt))
            elif kind in ("erase", "write", "unknown") and speed > MIN_SPEED:
                speed = max(MIN_SPEED, speed // 2)
                print(f"    lowering adapter speed to {speed} kHz", flush=True)
            else:
                time.sleep(1.0)

        if not ok:
            sys.stderr.write(last_text)
            sys.stderr.write(
                f"FLASH_FAILED {kind}: sector {n} @ {addr:#x} - {explain(kind)}\n"
                + damage_note()
            )
            raise SystemExit(3)

        done += len(piece)
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
            rc, last_text = run_openocd_connect(cmds, timeout=OCD_TIMEOUT * 2)
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
        rc, text = run_openocd_connect(
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
