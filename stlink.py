"""ST-LINK / OpenOCD helpers for the IndiH743 pad-test fixture.

No NRST on the harness — use soft run or stepper power-cycle after flash.
"""

from __future__ import annotations

import os
import re
import subprocess
import threading
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent
TOOLS = ROOT / "tools"
FIRMWARE_DIR = ROOT / "firmware" / "indi_h743"

STLINK_USB_ID = "0483:3748"
FLASH_BASE = 0x08000000
APP_BASE = 0x08020000

# RAM the OpenOCD flash loader is told to use (tools/openocd_fixture.cfg).
# DTCM (0x20000000) is what stm32h7x.cfg picks by default; on this fixture
# writes there fail with "Failed to write memory at 0x2000xxxx" and the loader
# can never be downloaded, so AXI SRAM is used instead.
WORK_AREA = 0x24000000
WORK_AREA_SIZE = 0x10000

_openocd_lock = threading.Lock()


def stlink_usb_present() -> bool:
    try:
        out = subprocess.check_output(
            ["lsusb"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        return False
    return STLINK_USB_ID.lower() in out.lower()


DEFAULT_IMAGE_NAME = "arducopter_with_bl.hex"


def _image_role(name: str) -> tuple[str, int]:
    """Return (role, default_base) for a firmware filename."""
    lower = name.lower()
    if (
        "combined" in lower
        or "with_bl" in lower
        or "with-bl" in lower
        or "_bl." in lower
    ):
        return "combined", FLASH_BASE
    if "bootloader" in lower or lower.endswith("_bl.bin"):
        return "bootloader", FLASH_BASE
    if "arducopter" in lower or "firmware" in lower or "padtest" in lower:
        return "app", APP_BASE
    return "other", FLASH_BASE


def _collect_image(path: Path) -> dict | None:
    if not path.is_file():
        return None
    suffix = path.suffix.lower()
    if suffix not in (".bin", ".hex"):
        return None
    role, default_base = _image_role(path.name)
    return {
        "name": path.name,
        "path": str(path.resolve()),
        "size": path.stat().st_size,
        "role": role,
        "default_base": f"0x{default_base:08X}",
    }


def list_images() -> list[dict]:
    """Return flashable images (firmware dir + project-root defaults)."""
    seen: set[str] = set()
    images: list[dict] = []

    # Prefer the uploaded combined hex in the project root.
    for candidate in (
        ROOT / DEFAULT_IMAGE_NAME,
        FIRMWARE_DIR / DEFAULT_IMAGE_NAME,
    ):
        info = _collect_image(candidate)
        if info and info["name"] not in seen:
            seen.add(info["name"])
            images.append(info)

    if FIRMWARE_DIR.is_dir():
        for path in sorted(FIRMWARE_DIR.iterdir()):
            info = _collect_image(path)
            if info and info["name"] not in seen:
                seen.add(info["name"])
                images.append(info)

    # Any other *.hex/*.bin sitting in the working directory
    for path in sorted(ROOT.glob("*.hex")) + sorted(ROOT.glob("*.bin")):
        info = _collect_image(path)
        if info and info["name"] not in seen:
            seen.add(info["name"])
            images.append(info)

    return images


def resolve_image(name: str | None) -> Path | None:
    """Resolve a basename under FIRMWARE_DIR or project root (no path traversal)."""
    if not name:
        preferred = [
            DEFAULT_IMAGE_NAME,
            "combined.bin",
            "combined.hex",
            "arducopter.bin",
            "AP_Bootloader.bin",
        ]
        for pref in preferred:
            for folder in (ROOT, FIRMWARE_DIR):
                p = folder / pref
                if p.is_file():
                    return p.resolve()
        images = list_images()
        return Path(images[0]["path"]) if images else None

    base = os.path.basename(name)
    for folder in (ROOT, FIRMWARE_DIR):
        path = (folder / base).resolve()
        try:
            path.relative_to(folder.resolve())
        except ValueError:
            continue
        if path.is_file():
            return path
    return None


#: RAM the OpenOCD flash loader may live in (see tools/openocd_fixture.cfg).
RAM_RANGES = (
    (0x20000000, 0x20020000),  # DTCM - dead over SWD on this fixture
    (0x24000000, 0x24080000),  # AXI SRAM - what the fixture actually uses
    (0x30000000, 0x30048000),  # SRAM1/2/3 (D2)
    (0x38000000, 0x38010000),  # SRAM4 (D3)
)


def _ram_fault_address(text: str) -> int | None:
    """Address of an OpenOCD "Failed to write memory at 0x..." error in RAM."""
    for m in re.finditer(r"failed to write memory at (0x[0-9a-f]+)", text, re.I):
        addr = int(m.group(1), 16)
        for lo, hi in RAM_RANGES:
            if lo <= addr < hi:
                return addr
    return None


#: Failure kinds printed by tools/stlink_flash.sh as ``FLASH_FAILED <kind>: ...``
#: mapped to (exit code, state, hint).
FLASH_FAILURE_KINDS = {
    "halt": (
        4,
        "halt_fail",
        "The target would not halt (erratum 3092511 / running app), so nothing "
        "was erased. Re-seat contact, power-cycle the pad, then retry at a "
        "lower STLINK_SPEED.",
    ),
    "erase": (
        4,
        "erase_fail",
        "Flash erase failed - the target usually reset itself mid-erase "
        "(independent watchdog or brownout). Check target power and retry.",
    ),
    "write": (
        4,
        "flash_fail",
        "The flash loader failed while writing - check the image base address "
        "and SWD speed.",
    ),
    "readback": (
        3,
        "verify_unreadable",
        "The flash could not be read back at all, so what it holds is "
        "unknown - that is a link failure, not a mismatch. On a blank H7 it "
        "is usually erratum 3092511 (a halt with pc/msp = 0): power-cycle the "
        "pad and retry.",
    ),
    "verify": (
        4,
        "verify_fail",
        "Read-back did not match the image - re-flash; if it repeats, suspect "
        "the flash bank or the SWD link.",
    ),
    "brownout": (
        4,
        "brownout",
        "The program was torn down: the target dropped off SWD when the flash "
        "controller was programmed (FLASH_CR 0x5200200C, \"error during the "
        "lock of flash\", \"Error closing APs\"), or the flash controller "
        "raised PGSERR (0x00040000) after \"st-flash\" streamed every byte. "
        "Both are a brownout or reset during programming, not a tool problem: "
        "the word was not cleanly erased or the supply disturbed the program. "
        "Check pad supply, GND return and VCAP caps, "
        "erase before writing (STLINK_MASS_ERASE=1), power-cycle the pad, then "
        "retry.",
    ),
    "stflash": (
        4,
        "flash_fail",
        "st-flash could not write the image (SWD entry or the write "
        "itself). Re-run it - this dongle succeeds on a retry - and watch "
        "`dmesg -T -w | grep -iE \"usb|stlink\"` for USB resets.",
    ),
    "direct": (
        4,
        "flash_fail",
        "The word-by-word writer stopped: the SWD link would not give "
        "consistent reads, or sector 0 holds data that is neither blank nor "
        "the image. Re-run it - it resumes where it stopped and never "
        "programs a word twice.",
    ),
    "nowriter": (
        5,
        "no_writer",
        "This image reaches past sector 0, and the only writer that works on "
        "this fixture (the direct writer) only knows sector 0. Nothing was "
        "erased. Flash a bootloader-only image (128 KiB or less at "
        "0x08000000); the application sectors have no working writer here "
        "yet.",
    ),
    "swd": (
        3,
        "swd_lost",
        "SWD link lost or never came up - check pogo contact, target power, "
        "SWCLK/SWDIO, then run tools/stlink_soak.sh.",
    ),
    "ap": (
        3,
        "ap_fail",
        "Core debug registers (0xE0001000+) do not answer, so the target can "
        "neither be examined nor halted. That is a link/harness problem (GND "
        "return, contact resistance, target power) - run tools/stlink_soak.sh "
        "before retrying.",
    ),
    "ram": (
        5,
        "no_work_area",
        "The flash loader's work area did not hold the probe pattern (base "
        "word plus a 32-word burst through the loader footprint) - the target "
        "is not halted or the SWD link collapses under load. Check pogo "
        "contact / target power, then tools/stlink_soak.sh.",
    ),
    "size": (
        5,
        "image_too_big",
        "The image is larger than the flash this target reports (the pad "
        "returns 1024 KiB, i.e. an H743xG / relabelled H750). Nothing was "
        "erased. Build for FLASH_SIZE_KB 1024, or re-probe the flash size on "
        "a clean link - STLINK_ALLOW_OVERSIZE=1 forces the write.",
    ),
    "vectors": (
        5,
        "vectors_blank",
        "Sector 0 holds no vector table, so the board cannot boot (pc "
        "0xfffffffe / msp 0xfffffffc) and an app-only image cannot repair it. "
        "Nothing was erased - flash a full image from 0x08000000.",
    ),
    "timeout": (
        4,
        "timeout",
        "OpenOCD timed out - check the pad is powered and contact is held.",
    ),
}


def _flash_failure_kind(text: str) -> str | None:
    """Kind from a ``FLASH_FAILED <kind>: ...`` marker, if present."""
    found = re.findall(r"FLASH_FAILED\s+(\w+):", text)
    return found[-1].lower() if found else None


def _classify_openocd(stdout: str, stderr: str, returncode: int) -> dict:
    text = f"{stdout}\n{stderr}"
    low = text.lower()

    voltage = None
    m = re.search(r"Target voltage:\s*([0-9.]+)\s*V?", text, re.I)
    if m:
        try:
            voltage = float(m.group(1))
        except ValueError:
            voltage = None

    adapter_present = stlink_usb_present()
    adapter_ok = (
        "STLINK" in text
        or "stlink" in low
        or "ST-Link" in text
        or "adapter speed" in low
    )
    has_error = "error:" in low or "failed to" in low
    connect_fail = "unable to connect" in low or "init mode failed" in low
    # tools/stlink_flash.sh prints these markers itself.
    flash_ok = "FLASH_OK" in text
    flash_fail = "FLASH_FAILED" in text
    no_work_area = "no writable ram" in low or "not writable" in low
    verified = flash_ok or (
        not has_error and ("Verified OK" in text or "verified" in low)
    )
    probe_ok = "PROBE_OK" in text
    run_ok = "RUN_OK" in text

    ram_fault = _ram_fault_address(text)
    fail_kind = _flash_failure_kind(text)
    hinted = False
    hint = None
    if fail_kind in FLASH_FAILURE_KINDS:
        code, state, hint = FLASH_FAILURE_KINDS[fail_kind]
        hinted = True
    elif ram_fault is not None:
        hint = (
            f"ST-LINK could not write RAM at 0x{ram_fault:08X}; the flash "
            "loader work area must live in AXI SRAM (0x24000000), not DTCM"
        )
    elif no_work_area:
        hint = "No writable RAM for the flash loader - check pogo contact / target power"
    elif connect_fail:
        hint = "SWD connect failed - check pogo contact, target power, SWCLK/SWDIO"
    elif "dap transaction stalled" in low:
        hint = "SWD stalls at this adapter speed - lower STLINK_SPEED"

    if hinted:
        pass  # FLASH_FAILED marker already decided code/state/hint
    elif re.search(r"failed to (?:write|read) memory at 0xe0[0-9a-f]{5}", low) or (
        "examine-end failed" in low
    ):
        code, state, hint = FLASH_FAILURE_KINDS["ap"]
    elif (
        "FLASH_EVENT halt_failed" in text
        or "target not halted" in low
        or "unknown state when halt was requested" in low
    ):
        code, state = 4, "halt_fail"
        hint = FLASH_FAILURE_KINDS["halt"][2]
    elif "erase time-out" in low or "failed erasing" in low:
        code, state = 4, "erase_fail"
        hint = FLASH_FAILURE_KINDS["erase"][2]
    elif connect_fail:
        code, state = 3, "swd_fail"
    elif no_work_area:
        code, state = 5, "no_work_area"
    elif flash_fail or ram_fault is not None:
        code, state = 4, "flash_fail"
        if ram_fault is not None and hint is None:
            hint = (
                f"ST-LINK could not write RAM at 0x{ram_fault:08X}; the flash "
                "loader work area must live in AXI SRAM (0x24000000), not DTCM"
            )
    elif flash_ok or verified or probe_ok or run_ok or returncode == 0:
        code, state = 0, "ok"
    elif "flash" in low or "program" in low:
        code, state = 4, "flash_fail"
    else:
        code, state = 3, "error"

    # USB missing overrides only when the log does not prove the adapter was
    # there (a successful OpenOCD session always prints the STLINK banner).
    if not adapter_present and not adapter_ok and not (code == 0 and verified):
        code = 2
        state = "no_adapter"

    return {
        "ok": code == 0,
        "code": code,
        "state": state,
        "adapter_present": adapter_present,
        "adapter_seen": adapter_ok,
        "voltage": voltage,
        "verified": bool(verified),
        "hint": hint,
        "log": text[-8000:],
    }


def _subprocess_env(extra: dict | None) -> dict:
    if not extra:
        return os.environ.copy()
    env = os.environ.copy()
    for key, value in extra.items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = str(value)
    return env


def run_openocd_script(
    script_name: str,
    args: list[str] | None = None,
    timeout: float = 120,
    env: dict | None = None,
) -> dict:
    script = TOOLS / script_name
    if not script.is_file():
        return {
            "ok": False,
            "code": 1,
            "state": "missing_tool",
            "adapter_present": stlink_usb_present(),
            "log": f"tool not found: {script}",
        }

    cmd = [str(script)] + (args or [])
    with _openocd_lock:
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=str(ROOT),
                env=_subprocess_env(env),
            )
        except subprocess.TimeoutExpired as e:
            out = (e.stdout or "") if isinstance(e.stdout, str) else ""
            err = (e.stderr or "") if isinstance(e.stderr, str) else str(e)
            return {
                "ok": False,
                "code": 4,
                "state": "timeout",
                "adapter_present": stlink_usb_present(),
                "log": f"{out}\n{err}\nTIMEOUT after {timeout}s",
            }
        except OSError as e:
            return {
                "ok": False,
                "code": 1,
                "state": "exec_error",
                "adapter_present": stlink_usb_present(),
                "log": str(e),
            }

    result = _classify_openocd(proc.stdout or "", proc.stderr or "", proc.returncode)
    result["returncode"] = proc.returncode
    result["cmd"] = " ".join(cmd)
    return result


def probe(timeout: float = 20) -> dict:
    result = run_openocd_script("stlink_probe.sh", timeout=timeout)
    if result.get("ok") and "PROBE_OK" not in (result.get("log") or ""):
        # Still connected if OpenOCD exited 0 without connect failure
        if "unable to connect" in (result.get("log") or "").lower():
            result["ok"] = False
            result["code"] = 3
            result["state"] = "swd_fail"
    return result


FLASH_TIMEOUT = float(os.environ.get("STLINK_FLASH_TIMEOUT") or 1800)
#: Link states that are worth retrying - they are transient on this fixture,
#: and the same command often succeeds a couple of seconds later.
TRANSIENT_STATES = (
    "swd_lost",
    "ap_fail",
    "link_unhealthy",
    "halt_fail",
    # A brownout resets the target mid-program; the flash wrapper retries it,
    # so the API may too.
    "brownout",
)
PRECHECK_N = int(os.environ.get("STLINK_FLASH_PRECHECK_N") or 3)
PRECHECK_MIN_PCT = float(os.environ.get("STLINK_FLASH_PRECHECK_MIN") or 66)
FLASH_RETRIES = int(os.environ.get("STLINK_FLASH_RETRIES") or 2)
FLASH_RETRY_DELAY = float(os.environ.get("STLINK_FLASH_RETRY_DELAY") or 2)


def _flash_default_base(image: Path) -> int:
    """Base address used for a .bin, from its name."""
    name = image.name.lower()
    if "combined" in name or "bootloader" in name or name.endswith("_bl.bin"):
        return FLASH_BASE
    if "arducopter" in name:
        return APP_BASE
    return FLASH_BASE


def flash(
    image: Path,
    base: str | None = None,
    timeout: float | None = None,
    speed: int | None = None,
    precheck: bool | None = None,
    retries: int | None = None,
) -> dict:
    """Flash an image, gating on link health and retrying transient failures.

    ``speed`` selects the SWD kHz (the flash wrapper still walks its own
    ladder down from there). ``precheck`` runs a short link soak first and
    refuses to flash when the harness is marginal; ``retries`` re-attempts a
    transient link failure with a pause in between.
    """
    args = [str(image)]
    resolved_base: int | None = None
    if base:
        args.append(base)
        try:
            resolved_base = int(str(base), 0)
        except ValueError:
            resolved_base = None
    elif image.suffix.lower() == ".bin":
        resolved_base = _flash_default_base(image)
        args.append(f"0x{resolved_base:08X}")

    if precheck is None:
        precheck = (os.environ.get("STLINK_FLASH_PRECHECK") or "1").strip().lower() not in (
            "0", "false", "no", "off",
        )
    attempts = 1 if retries is None else max(0, int(retries)) + 1
    if retries is None:
        attempts = max(1, FLASH_RETRIES + 1)

    link: dict | None = None
    if precheck:
        link = soak(count=PRECHECK_N, min_pct=PRECHECK_MIN_PCT, speed=speed)
        if not link["ok"]:
            return {
                "ok": False,
                "code": 3,
                "state": "link_unhealthy",
                "verified": False,
                "image": str(image),
                "base": args[1] if len(args) > 1 else None,
                "speed": speed,
                "link": link,
                "hint": link.get("hint"),
                "log": (
                    f"link precheck: {link.get('passed')}/{link.get('attempts')} "
                    f"sessions usable (need {PRECHECK_MIN_PCT:.0f} %) - not flashing\n"
                    + (link.get("log") or "")
                ),
            }

    env = {"STLINK_SPEED": speed} if speed else None
    result: dict = {}
    notes: list[str] = []
    for attempt in range(1, attempts + 1):
        # A combined 2 MB image is written 128 KiB at a time in a fresh
        # OpenOCD session per sector, so this is slow by design; override with
        # STLINK_FLASH_TIMEOUT (seconds).
        result = run_openocd_script(
            "stlink_flash.sh",
            args=args,
            timeout=timeout if timeout is not None else FLASH_TIMEOUT,
            env=env,
        )
        log = result.get("log") or ""
        if "FLASH_FAILED" in log:
            # The classifier mapped FLASH_FAILED <kind> to code/state/hint;
            # make sure the result is not reported as ok.
            result["ok"] = False
            if result.get("code") == 0:
                result["code"] = 4
            if result.get("state") in (None, "ok"):
                result["state"] = "flash_fail"

        if result.get("ok") or "FLASH_OK" in log:
            result["ok"] = True
            result["code"] = 0
            result["state"] = "ok"
            result["verified"] = True
            break

        if attempt >= attempts or result.get("state") not in TRANSIENT_STATES:
            break

        # Transient: pause, re-measure the link, then try the whole sector loop
        # again from a fresh session.
        delay = FLASH_RETRY_DELAY * attempt
        notes.append(
            f"attempt {attempt}/{attempts} failed ({result.get('state')}) - "
            f"retrying in {delay:.0f}s"
        )
        time.sleep(delay)
        if precheck:
            link = soak(count=PRECHECK_N, min_pct=PRECHECK_MIN_PCT, speed=speed)
            if not link["ok"]:
                result["link"] = link
                result["hint"] = link.get("hint")
                result["state"] = "link_unhealthy"
                result["ok"] = False
                result["code"] = 3
                break

    result["image"] = str(image)
    result["base"] = args[1] if len(args) > 1 else None
    result["speed"] = speed
    result["attempts"] = attempt
    if notes:
        result["notes"] = notes
    if link is not None:
        result["link"] = link
    return result


SOAK_N = int(os.environ.get("STLINK_SOAK_N") or 20)
SOAK_MIN_PCT = float(os.environ.get("STLINK_SOAK_MIN_PCT") or 90)


def soak(count: int | None = None, min_pct: float | None = None,
         timeout: float | None = None, speed: int | None = None) -> dict:
    """Open N OpenOCD sessions and report how many got a usable target.

    A marginal link (pogo contact, GND return, target power, ST-LINK USB) is
    behind most flash failures on this fixture, and it is not something a
    flash retry can fix - so measure it first.
    """
    count = int(count or SOAK_N)
    min_pct = SOAK_MIN_PCT if min_pct is None else float(min_pct)
    # ~3 s per session upper bound, plus slack.
    timeout = timeout if timeout is not None else max(120.0, count * 20.0)

    args = [str(count), "--min", str(min_pct)]
    if speed:
        args += ["--speed", str(int(speed))]
    run = run_openocd_script(
        "stlink_soak.sh",
        args=args,
        timeout=timeout,
        env={"STLINK_SOAK_GAP": "0"} if count <= 5 else None,
    )
    log = run.get("log") or ""
    passed = attempts = None
    m = re.search(r"pass rate:\s*(\d+)/(\d+)\s*=\s*([0-9.]+)\s*%", log)
    if m:
        passed, attempts = int(m.group(1)), int(m.group(2))
        rate = float(m.group(3))
    else:
        rate = None

    failures: dict[str, int] = {}
    for k, v in re.findall(r"(\w+)=(\d+)", log):
        if k != "ok":
            failures[k] = int(v)

    healthy = bool(passed is not None and rate is not None and rate >= min_pct)
    return {
        "ok": healthy,
        "code": 0 if healthy else 1,
        "state": "link_ok" if healthy else "link_unhealthy",
        "attempts": attempts if attempts is not None else count,
        "passed": passed,
        "pass_rate": rate,
        "min_pass_rate": min_pct,
        "failures": failures,
        "hint": (
            None
            if healthy
            else "SWD link is marginal - fix the harness (GND return, pogo "
            "contact, target power, ST-LINK USB) before flashing again"
        ),
        "log": log[-8000:],
    }


def soft_run(timeout: float = 20) -> dict:
    return run_openocd_script("stlink_run.sh", timeout=timeout)


def quick_status() -> dict:
    """Lightweight status for UI polling (USB + available images)."""
    images = list_images()
    return {
        "adapter_present": stlink_usb_present(),
        "usb_id": STLINK_USB_ID,
        "images": images,
        "firmware_dir": str(FIRMWARE_DIR),
        "defaults": {
            "flash_base": f"0x{FLASH_BASE:08X}",
            "app_base": f"0x{APP_BASE:08X}",
            "reset": "none (no NRST)",
            # Flash loader RAM. DTCM (0x20000000, OpenOCD's default for
            # STM32H7) is not writable over SWD on this fixture.
            "work_area": f"0x{WORK_AREA:08X} (AXI SRAM)",
            "work_area_size": f"0x{WORK_AREA_SIZE:08X}",
            "halt": "reset halt (SYSRESETREQ + vector catch)",
            "soak": f"{SOAK_N} sessions, needs {SOAK_MIN_PCT:.0f} %",
            "flash_precheck": (
                f"{PRECHECK_N} sessions, needs {PRECHECK_MIN_PCT:.0f} %"
            ),
            "flash_retries": FLASH_RETRIES,
        },
    }
