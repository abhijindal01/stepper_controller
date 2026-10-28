#!/usr/bin/env python3
"""
Check both stepper Arduinos for the firmware that fixes the motor heating.

    python3 tools/check_boards.py
    python3 tools/check_boards.py --port /dev/stepper_a
    python3 tools/check_boards.py --port /dev/ttyACM0 --port /dev/ttyACM1

Read-only: it only sends STATUS, so limits, position and drive state are
untouched.

Firmware 2.2.0 added automatic release of the driver coils when the axis
is idle. A board still running an older sketch never releases them, so it
keeps heating at the position where it stops. That is what this script
looks for.

The Flask console holds /dev/stepper_a and /dev/stepper_b open, so stop it
first:

    sudo systemctl stop stepper_controller
    python3 tools/check_boards.py
    sudo systemctl start stepper_controller
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial is missing: venv/bin/pip install -r requirements.txt")

DEFAULT_PORTS = ("/dev/stepper_a", "/dev/stepper_b")
SERVICE = "stepper_controller.service"
SETTLE_SECONDS = 0.5
REPLY_TIMEOUT = 2.0

# Neither of these replies existed before 2.2.0
FIX_KEYS = ("driver", "idle_hold_ms")


def service_is_active() -> bool:
    """True when the Flask console is running and holding the serial ports."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", SERVICE],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return False

    return result.stdout.strip() == "active"


def candidate_ports(explicit: list[str] | None) -> list[str]:
    if explicit:
        return explicit

    ports = [os.environ.get("MOTOR1_PORT", DEFAULT_PORTS[0]),
             os.environ.get("MOTOR2_PORT", DEFAULT_PORTS[1])]

    # Only report ports that exist, so a single-board setup is not an error
    return [port for port in ports if os.path.exists(port)]


def read_status(port: str) -> dict | None:
    """Open the port, ask for STATUS and decode the JSON reply."""
    try:
        connection = serial.Serial(port, 115200, timeout=REPLY_TIMEOUT)
    except Exception as exc:  # busy, permission, unplugged, ...
        print(f"  cannot open {port}: {exc}")
        return None

    try:
        time.sleep(SETTLE_SECONDS)
        connection.reset_input_buffer()
        connection.write(b"STATUS\n")
        connection.flush()

        deadline = time.monotonic() + REPLY_TIMEOUT
        buffer = b""

        while time.monotonic() < deadline:
            buffer += connection.readline()
            line = buffer.strip()

            if line.startswith(b"{") and line.endswith(b"}"):
                try:
                    return json.loads(line.decode("utf-8", errors="replace"))
                except ValueError as exc:
                    print(f"  {port}: invalid STATUS JSON ({exc}): {line[:120]!r}")
                    return None

        print(f"  {port}: no STATUS reply")
        return None
    finally:
        connection.close()


# report() verdicts
HAS_FIX = "has_fix"
HOLDING = "holding"
NO_FIX = "no_fix"
FIX_BUT_ENERGISED = "fix_but_energised"


def report(port: str, status: dict) -> str:
    """Print one board's state and return the verdict."""
    has_fix = all(key in status for key in FIX_KEYS)

    position = status.get("position", "?")
    forward = status.get("forward", "?")
    backward = status.get("backward", "?")

    print(f"  position {position}  limits {backward} .. {forward}")
    print(f"  state {status.get('state', '?')}  homed {status.get('homed', '?')}"
          f"  home switch {status.get('home_switch', '?')}"
          f"  e-stop {status.get('emergency', '?')}")

    if not has_fix:
        print("  driver: n/a  ->  OLD firmware (does not release the coils)")
        return NO_FIX

    driver = str(status.get("driver", "?")).upper()
    hold = bool(status.get("hold", False))
    idle_ms = status.get("idle_ms", "?")
    idle_hold_ms = status.get("idle_hold_ms", "?")

    detail = "holding (coils energised)" if driver == "ON" else "released (cooling)"

    if hold:
        detail += ", operator hold override active"

    print(f"  driver {driver}: {detail}  [{idle_ms} ms since last step,"
          f" release window {idle_hold_ms} ms]")

    if driver == "ON" and hold:
        return HOLDING

    applied = str(status.get("state", "")).upper() == "READY"

    if driver == "ON" and not hold and applied and isinstance(idle_ms, int) \
            and isinstance(idle_hold_ms, int) and idle_hold_ms > 0 \
            and idle_ms > idle_hold_ms + 1000:
        print("  WARNING: energised well past the release window while READY")
        print("           (expected the coils to be released - check the sketch)")
        return FIX_BUT_ENERGISED

    return HAS_FIX


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", action="append", metavar="DEVICE",
                        help="serial device to check (repeatable)")
    args = parser.parse_args()

    if service_is_active():
        print(f"{SERVICE} is running and holds the serial ports.")
        print("    sudo systemctl stop stepper_controller")
        print("    ... run this again, then ...")
        print("    sudo systemctl start stepper_controller")
        print()

    ports = candidate_ports(args.port)

    if not ports:
        print("No stepper ports found. Check the udev rules:")
        print("    ls -l /dev/stepper_*")
        print("    bash tools/setup_udev.sh")
        return 2

    print(f"Checking {len(ports)} board(s): {', '.join(ports)}")
    print()

    failures = 0
    missing_fix: list[str] = []
    energised: list[str] = []
    holding: list[str] = []

    for port in ports:
        print(port)
        status = read_status(port)

        if status is None:
            failures += 1
            print()
            continue

        verdict = report(port, status)

        if verdict == NO_FIX:
            missing_fix.append(port)
        elif verdict == FIX_BUT_ENERGISED:
            energised.append(port)
        elif verdict == HOLDING:
            holding.append(port)

        print()

    print("-" * 60)

    if missing_fix:
        print("OLD firmware (no heat fix) on: " + ", ".join(missing_fix))
        print("Upload StepperController.ino (firmware 2.2.0) to those boards -")
        print("see docs/MOTOR_HEATING.md")

    if energised:
        if missing_fix:
            print()
        print("Still energised past the release window on: " + ", ".join(energised))
        print("Send DRIVER_OFF, then watch STATUS: driver should stay OFF while idle.")

    if failures:
        if missing_fix or energised:
            print()
        print(f"{failures} board(s) did not answer")

    if missing_fix or energised or failures:
        return 1

    print("All boards run firmware 2.2.0.")

    if holding:
        print("Holding torque by request on: " + ", ".join(holding))
        print("Release those coils with DRIVER_OFF (or the Hold Torque button).")
    else:
        print("The coils are released while idle, so nothing heats up at rest.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
