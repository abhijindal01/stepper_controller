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


def _classify_openocd(stdout: str, stderr: str, returncode: int) -> dict:
    text = f"{stdout}\n{stderr}"
    voltage = None
    m = re.search(r"Target voltage:\s*([0-9.]+)\s*V?", text, re.I)
    if m:
        try:
            voltage = float(m.group(1))
        except ValueError:
            voltage = None

    adapter_ok = (
        "STLINK" in text
        or "stlink" in text.lower()
        or "ST-Link" in text
        or "adapter speed" in text.lower()
    )
    connect_fail = "unable to connect" in text.lower()
    verified = "Verified OK" in text or "verified" in text.lower() and "ok" in text.lower()
    probe_ok = "PROBE_OK" in text
    run_ok = "RUN_OK" in text

    if returncode == 0 and (probe_ok or verified or run_ok or not connect_fail):
        code = 0
        state = "ok"
    elif not stlink_usb_present() and "Error" in text and "open" in text.lower():
        code = 2
        state = "no_adapter"
    elif connect_fail:
        code = 3
        state = "swd_fail"
    elif returncode != 0 and ("program" in text.lower() or "Error" in text):
        code = 4
        state = "flash_fail" if "program" in text.lower() else "error"
    elif returncode != 0:
        code = 4 if "flash" in text.lower() or "program" in text.lower() else 3
        state = "error"
    else:
        code = 0
        state = "ok"

    # USB missing overrides when we can detect it cleanly
    if not stlink_usb_present():
        code = 2
        state = "no_adapter"

    return {
        "ok": code == 0,
        "code": code,
        "state": state,
        "adapter_present": stlink_usb_present(),
        "adapter_seen": adapter_ok,
        "voltage": voltage,
        "verified": verified,
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


def flash(image: Path, base: str | None = None, timeout: float = 180) -> dict:
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

    result = run_openocd_script("stlink_flash.sh", args=args, timeout=timeout)
    result["image"] = str(image)
    result["base"] = args[1] if len(args) > 1 else None
    if result.get("ok") or "Verified OK" in (result.get("log") or ""):
        # OpenOCD often prints Verified OK then exits 0
        if "Verified OK" in (result.get("log") or ""):
            result["ok"] = True
            result["code"] = 0
            result["state"] = "ok"
            result["verified"] = True
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
        },
    }
