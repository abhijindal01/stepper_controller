"""
Dual-Arduino serial controller layer for Raspberry Pi.

ONE Raspberry Pi drives TWO independent Arduino stepper controllers over
hardcoded, udev-pinned serial device paths:

    MOTOR 1  ->  /dev/stepper_a
    MOTOR 2  ->  /dev/stepper_b

See udev/99-stepper-controllers.rules and tools/setup_udev.sh for how each
physical Arduino USB port or board serial number is bound to /dev/stepper_a
and /dev/stepper_b so they never swap across reboots.
"""

from __future__ import annotations

import json
import os
import threading
import time
from typing import Any

import serial


# =============================================================
# HARDCODED ARDUINO PORTS (Raspberry Pi)
# =============================================================

MOTOR_1_PORT = "/dev/stepper_a"
MOTOR_2_PORT = "/dev/stepper_b"

BAUD_RATE = 115200
SERIAL_TIMEOUT = 1.0
BOOT_SETTLE_SECONDS = 2.0
RECONNECT_COOLDOWN_SECONDS = 3.0


# Unsolicited progress lines emitted by firmware during motion/homing
_ASYNC_PREFIXES = (
    "MOVING_FORWARD POSITION:",
    "MOVING_BACKWARD POSITION:",
    "FIRST HOME FOUND",
    "OFFSET COMPLETE",
    "FINAL HOMING",
    "=================================",
    "STEPPER CONTROLLER",
    "FIRMWARE :",
    "EEPROM ",
    "NO LIMITS SAVED",
    "FORWARD LIMIT:",
    "BACKWARD LIMIT:",
    "STARTING AUTOMATIC HOMING",
    "STATE RESTORED",
)


def _is_async_banner_or_progress(line: str) -> bool:
    upper = line.strip().upper()
    if not upper:
        return True
    return any(upper.startswith(prefix) for prefix in _ASYNC_PREFIXES)


class StepperMotor:
    """Thread-safe serial connection to one Arduino stepper controller."""

    def __init__(
        self,
        motor_id: str,
        name: str,
        port: str,
        default_purpose: str = "",
        baud: int = BAUD_RATE,
        boot_settle: float = BOOT_SETTLE_SECONDS,
    ) -> None:
        self.id = motor_id
        self.name = name
        self.port = port
        self.default_purpose = default_purpose
        self.baud = baud
        self.boot_settle = boot_settle

        self._serial: Any = None
        self._lock = threading.Lock()
        self._last_connect_attempt = 0.0
        self.connected = False
        self.last_error: str | None = "Not connected"
        self.last_status: dict[str, Any] | None = None

    def connect(self, force: bool = True) -> bool:
        """Open the hardcoded serial port for this Arduino."""
        with self._lock:
            return self._connect_locked(force=force)

    def _connect_locked(self, force: bool = False) -> bool:
        if self._serial is not None and getattr(self._serial, "is_open", False):
            self.connected = True
            return True

        now = time.monotonic()
        if not force and (now - self._last_connect_attempt) < RECONNECT_COOLDOWN_SECONDS:
            return False

        self._last_connect_attempt = now
        self._close_locked()

        try:
            ser = serial.Serial(
                port=self.port,
                baudrate=self.baud,
                timeout=SERIAL_TIMEOUT,
                write_timeout=SERIAL_TIMEOUT,
            )
            if self.boot_settle > 0:
                time.sleep(self.boot_settle)
            self._drain_input_locked(ser)

            self._serial = ser
            self.connected = True
            self.last_error = None
            return True
        except Exception as exc:
            self._serial = None
            self.connected = False
            self.last_error = str(exc)
            return False

    def disconnect(self) -> None:
        """Close the serial port cleanly."""
        with self._lock:
            self._close_locked()

    def _close_locked(self) -> None:
        if self._serial is not None:
            try:
                self._serial.close()
            except Exception:
                pass
        self._serial = None
        self.connected = False

    @staticmethod
    def _drain_input_locked(ser: Any) -> None:
        """Discard stale unsolicited telemetry/boot lines before issuing a command."""
        try:
            if hasattr(ser, "reset_input_buffer"):
                ser.reset_input_buffer()
        except Exception:
            pass

    def _read_lines_locked(self, max_lines: int = 8) -> list[str]:
        if self._serial is None:
            return []
        lines: list[str] = []
        for _ in range(max_lines):
            raw = self._serial.readline()
            if not raw:
                break
            decoded = raw.decode("utf-8", errors="replace").strip()
            if decoded:
                lines.append(decoded)
            # Stop immediately once we have at least one meaningful line and buffer is empty
            in_waiting = getattr(self._serial, "in_waiting", 0)
            if lines and not in_waiting:
                break
        return lines

    def send(self, command: str) -> str | None:
        """Send one command line to the Arduino and return its reply line."""
        clean = command.strip()
        if not clean:
            return None

        with self._lock:
            if not self._connect_locked(force=False):
                return None

            try:
                self._drain_input_locked(self._serial)
                self._serial.write((clean + "\n").encode("utf-8"))
                self._serial.flush()

                # Read lines, skipping async motion/homing progress notifications
                for _ in range(10):
                    raw = self._serial.readline()
                    if not raw:
                        break
                    line = raw.decode("utf-8", errors="replace").strip()
                    if not line:
                        continue
                    if clean.upper() == "STATUS":
                        if line.startswith("{") and line.endswith("}"):
                            return line
                        continue
                    if clean.upper() == "GET_POSITION":
                        if line.upper().startswith("POSITION:"):
                            return line
                        continue
                    if not _is_async_banner_or_progress(line):
                        return line

                return None
            except Exception as exc:
                self.last_error = str(exc)
                self._close_locked()
                return None

    def status(self) -> dict[str, Any] | None:
        """Query STATUS JSON from the Arduino."""
        reply = self.send("STATUS")
        if not reply:
            return None

        try:
            parsed = json.loads(reply)
        except ValueError:
            self.last_error = f"Invalid status JSON: {reply[:80]}"
            return None

        if not isinstance(parsed, dict):
            return None

        self.last_status = parsed
        return dict(parsed)

    def position(self) -> int | None:
        """Return the current step counter from the Arduino."""
        reply = self.send("GET_POSITION")
        if reply and ":" in reply:
            try:
                return int(reply.split(":", 1)[1].strip())
            except ValueError:
                pass

        st = self.status()
        if st and "position" in st:
            try:
                return int(st["position"])
            except (ValueError, TypeError):
                return None
        return None

    def info(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "label": self.name,
            "port": self.port,
            "default_purpose": self.default_purpose,
            "connected": self.connected,
            "error": self.last_error,
        }


# =============================================================
# MOTOR REGISTRY (2 Arduinos on 1 Raspberry Pi)
# =============================================================

MOTOR_IDS: tuple[str, ...] = ("motor1", "motor2")

MOTORS: dict[str, StepperMotor] = {
    "motor1": StepperMotor(
        motor_id="motor1",
        name="Motor 1",
        port=os.environ.get("MOTOR1_PORT", MOTOR_1_PORT),
        default_purpose="H7 Pad-Test Fixture",
        boot_settle=float(os.environ.get("ARDUINO_BOOT_SETTLE", str(BOOT_SETTLE_SECONDS))),
    ),
    "motor2": StepperMotor(
        motor_id="motor2",
        name="Motor 2",
        port=os.environ.get("MOTOR2_PORT", MOTOR_2_PORT),
        default_purpose="ESC Test Fixture",
        boot_settle=float(os.environ.get("ARDUINO_BOOT_SETTLE", str(BOOT_SETTLE_SECONDS))),
    ),
}


def get_motor(motor_id: str) -> StepperMotor | None:
    return MOTORS.get(motor_id)


def connect_all() -> dict[str, bool]:
    """Attempt initial connection to both Arduinos concurrently on startup."""
    results: dict[str, bool] = {}
    threads: list[threading.Thread] = []

    def _open(mid: str, motor: StepperMotor) -> None:
        ok = motor.connect(force=True)
        results[mid] = ok
        if ok:
            print(f"[{motor.name}] Connected on {motor.port}")
        else:
            print(f"[{motor.name}] Offline on {motor.port}: {motor.last_error}")

    for mid in MOTOR_IDS:
        t = threading.Thread(target=_open, args=(mid, MOTORS[mid]), daemon=True)
        threads.append(t)
        t.start()

    for t in threads:
        t.join(timeout=5.0)

    return results
