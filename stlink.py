"""ST-LINK / OpenOCD helpers for the IndiH743 pad-test fixture.

No NRST on the harness — use soft run or stepper power-cycle after flash.
"""

from __future__ import annotations

import os
import re
import subprocess
import threading
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
    hint = None
    if ram_fault is not None:
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

    if connect_fail:
        code, state = 3, "swd_fail"
    elif no_work_area:
        code, state = 5, "no_work_area"
    elif flash_fail or ram_fault is not None:
        code, state = 4, "flash_fail"
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


def run_openocd_script(
    script_name: str,
    args: list[str] | None = None,
    timeout: float = 120,
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


def flash(image: Path, base: str | None = None, timeout: float | None = None) -> dict:
    args = [str(image)]
    if base:
        args.append(base)
    elif image.suffix.lower() == ".bin":
        # App-only bins default to app base; combined/bootloader to flash base
        name = image.name.lower()
        if "combined" in name or "bootloader" in name or name.endswith("_bl.bin"):
            args.append(f"0x{FLASH_BASE:08X}")
        elif "arducopter" in name:
            args.append(f"0x{APP_BASE:08X}")
        else:
            args.append(f"0x{FLASH_BASE:08X}")

    # A combined 2 MB image is written 128 KiB at a time in a fresh OpenOCD
    # session per sector at 50-100 kHz SWD, so this is slow by design;
    # override with STLINK_FLASH_TIMEOUT (seconds).
    result = run_openocd_script(
        "stlink_flash.sh",
        args=args,
        timeout=timeout if timeout is not None else FLASH_TIMEOUT,
    )
    result["image"] = str(image)
    result["base"] = args[1] if len(args) > 1 else None

    log = result.get("log") or ""
    if "FLASH_OK" in log:
        result["ok"] = True
        result["code"] = 0
        result["state"] = "ok"
        result["verified"] = True
    elif "FLASH_FAILED" in log:
        result["ok"] = False
        result.setdefault("code", 4)
        if "RAM" in log or "memory at 0x" in log:
            result["state"] = "flash_fail"
    return result


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
        },
    }
