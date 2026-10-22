import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

os.environ["SKIP_INITIAL_CONNECT"] = "1"
os.environ["APP_PASSWORD"] = "testpass123"

import steppers
import server


class FakeSerialArduino:
    """In-memory stand-in for an Arduino running StepperController firmware."""

    def __init__(self, port: str):
        self.port = port
        self.is_open = True
        self.state = "READY"
        self.position = 0
        self.homed = True
        self.forward = 85000
        self.backward = -85000
        self._rx_lines: list[bytes] = []
        self.commands_seen: list[str] = []

    @property
    def in_waiting(self) -> int:
        return sum(len(x) for x in self._rx_lines)

    def reset_input_buffer(self) -> None:
        self._rx_lines.clear()

    def flush(self) -> None:
        pass

    def close(self) -> None:
        self.is_open = False

    def write(self, payload: bytes) -> int:
        cmd = payload.decode("utf-8").strip().upper()
        self.commands_seen.append(cmd)

        # Inject an unsolicited motion line before real reply to verify filtering
        self._rx_lines.append(b"MOVING_FORWARD POSITION:100\n")

        if cmd == "STATUS":
            doc = {
                "state": self.state,
                "position": self.position,
                "homed": self.homed,
                "forward": self.forward,
                "backward": self.backward,
                "home_switch": "OFF",
                "forward_switch": "OFF",
                "backward_switch": "OFF",
                "emergency": "OFF",
            }
            self._rx_lines.append((json.dumps(doc) + "\n").encode("utf-8"))
        elif cmd == "GET_POSITION":
            self._rx_lines.append(f"POSITION:{self.position}\n".encode("utf-8"))
        elif cmd == "CLEAR_LIMITS":
            self.forward = 85000
            self.backward = -85000
            self._rx_lines.append(b"LIMITS CLEARED\n")
        elif cmd == "SAVE_FORWARD":
            self.forward = self.position
            self._rx_lines.append(f"FORWARD LIMIT SAVED: {self.forward}\n".encode("utf-8"))
        elif cmd == "SAVE_BACKWARD":
            self.backward = self.position
            self._rx_lines.append(f"BACKWARD LIMIT SAVED: {self.backward}\n".encode("utf-8"))
        elif cmd == "SAVE_POSITION":
            self._rx_lines.append(f"POSITION SAVED: {self.position}\n".encode("utf-8"))
        elif cmd == "RESET_STATE":
            self.homed = False
            self._rx_lines.append(b"STATE RESET\n")
        elif cmd.startswith("LOAD_LIMITS,"):
            _, fwd, bwd = cmd.split(",")
            self.forward = int(fwd)
            self.backward = int(bwd)
            self._rx_lines.append(
                f"LIMITS LOADED: Forward={self.forward}, Backward={self.backward}\n".encode("utf-8")
            )
        elif cmd == "JOG 1":
            self.position = self.forward
            self.state = "READY"
            self._rx_lines.append(b"START MOVING FORWARD\n")
        elif cmd == "JOG -1":
            self.position = self.backward
            self.state = "READY"
            self._rx_lines.append(b"START MOVING BACKWARD\n")
        elif cmd == "ESTOP":
            self.state = "EMERGENCY STOP"
            self._rx_lines.append(b"EMERGENCY STOP\n")
        elif cmd == "STOP":
            self.state = "READY"
            self._rx_lines.append(b"STOPPED\n")
        elif cmd == "HOME":
            self.position = 0
            self.homed = True
            self.state = "READY"
            self._rx_lines.append(b"START HOME\n")
        else:
            self._rx_lines.append(b"OK\n")

        return len(payload)

    def readline(self) -> bytes:
        if self._rx_lines:
            return self._rx_lines.pop(0)
        return b""


class DualStepperConsoleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".json")
        self.tmp.write(
            json.dumps(
                {
                    "H7": {"forward": 64560, "backward": 50000},
                    "ESC": {"axis": "2", "forward": 78000, "backward": 70000},
                }
            ).encode("utf-8")
        )
        self.tmp.close()
        server.PROJECT_FILE = self.tmp.name

        self.fake_a = FakeSerialArduino("/dev/stepper_a")
        self.fake_b = FakeSerialArduino("/dev/stepper_b")
        self.fake_a.position = 12345
        self.fake_b.position = -4321

        m1 = steppers.MOTORS["motor1"]
        m2 = steppers.MOTORS["motor2"]
        m1._serial = self.fake_a
        m1.connected = True
        m1.last_error = None

        m2._serial = self.fake_b
        m2.connected = True
        m2.last_error = None

        server.app.config["TESTING"] = True
        self.client = server.app.test_client()

    def tearDown(self) -> None:
        os.unlink(self.tmp.name)

    def _login(self):
        return self.client.post("/login", data={"password": "testpass123"}, follow_redirects=True)

    def test_hardcoded_ports(self):
        self.assertEqual(steppers.MOTOR_1_PORT, "/dev/stepper_a")
        self.assertEqual(steppers.MOTOR_2_PORT, "/dev/stepper_b")
        self.assertEqual(steppers.MOTORS["motor1"].port, "/dev/stepper_a")
        self.assertEqual(steppers.MOTORS["motor2"].port, "/dev/stepper_b")

    def test_dashboard_removes_hardware_monitor_and_renders_both_motors(self):
        resp = self._login()
        self.assertEqual(resp.status_code, 200)
        html = resp.get_data(as_text=True)

        # Both hardcoded ports and side-by-side panels present
        self.assertIn("/dev/stepper_a", html)
        self.assertIn("/dev/stepper_b", html)
        self.assertIn("panel-motor1", html)
        self.assertIn("panel-motor2", html)
        self.assertIn("85,000", html)
        self.assertIn("ST-LINK / STM32H743 Fixture Programming", html)

        # Hardware Monitor & buzzer completely removed
        self.assertNotIn("Hardware Monitor", html)
        self.assertNotIn("TEST BUZZER", html)
        self.assertNotIn("4.5V Rail", html)
        self.assertNotIn("9V Rail", html)
        self.assertNotIn("SPI Communication", html)

    def test_legacy_projects_migrated_per_motor(self):
        self._login()
        p1 = self.client.get("/api/motor/motor1/projects").get_json()
        p2 = self.client.get("/api/motor/motor2/projects").get_json()

        self.assertIn("H7", p1)
        self.assertNotIn("ESC", p1)
        self.assertIn("ESC", p2)
        self.assertEqual(p2["ESC"], {"forward": 78000, "backward": 70000})

    def test_independent_motor_status_and_actions(self):
        self._login()

        s1 = self.client.get("/api/motor/motor1/status").get_json()
        s2 = self.client.get("/api/motor/motor2/status").get_json()
        self.assertEqual(s1["position"], 12345)
        self.assertEqual(s2["position"], -4321)

        # Load H7 on motor1 only
        r_load = self.client.post("/api/motor/motor1/projects/H7/load").get_json()
        self.assertTrue(r_load["ok"])
        self.assertEqual(self.fake_a.forward, 64560)
        self.assertEqual(self.fake_a.backward, 50000)
        # Motor 2 limits untouched
        self.assertEqual(self.fake_b.forward, 85000)
        self.assertEqual(self.fake_b.backward, -85000)

        # Clear limits on motor1 -> +/- 85000
        r_clr = self.client.post("/api/motor/motor1/action/clear_limits").get_json()
        self.assertTrue(r_clr["ok"])
        self.assertEqual(self.fake_a.forward, 85000)
        self.assertEqual(self.fake_a.backward, -85000)

        # Save position & rename purpose on motor2
        r_save = self.client.post("/api/motor/motor2/action/save_position").get_json()
        self.assertTrue(r_save["ok"])
        self.assertIn("POSITION SAVED", r_save["response"])

        r_purp = self.client.post(
            "/api/motor/motor2/purpose",
            json={"purpose": "Calibration Stage"},
        ).get_json()
        self.assertEqual(r_purp["purpose"], "Calibration Stage")

    def test_stlink_endpoints_wired(self):
        self._login()
        st = self.client.get("/api/stlink/status").get_json()
        self.assertIn("adapter_present", st)
        self.assertIn("images", st)

        contact = self.client.post(
            "/api/stlink/contact",
            json={"motor": "motor1", "load_h7": True},
        ).get_json()
        self.assertTrue(contact["ok"])
        self.assertEqual(self.fake_a.position, 64560)


if __name__ == "__main__":
    unittest.main()
