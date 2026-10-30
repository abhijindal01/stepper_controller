"""Unit tests for the OpenOCD result classifier in stlink.py.

No hardware and no OpenOCD needed: the log samples are the real ones from the
fixture (including the DTCM write failure this repo had to work around).

    python3 -m unittest discover -s tests -p 'test_stlink.py'
"""

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import stlink  # noqa: E402


STLINK_BANNER = """\
Info : STLINK V2J46S7 (API v2) VID:PID 0483:3748
Info : Target voltage: 3.274455
Info : SWD DPIDR 0x6ba02477
Info : [stm32h7x.cpu0] Examination succeed
"""

# The failure from the field: loader RAM (DTCM) does not answer SWD writes.
DTCM_FAULT = STLINK_BANNER + """\
Info : Device: STM32H74x/75x
Info : flash size probed value 2048k
erased address 0x08000000 (length 131072) in 0.898930s (142.392 KiB/s)
Error: Failed to write memory at 0x20003994
Error: error writing to flash at address 0x08000000 at offset 0x00000000
flash failed at sector 0 @ 0x8000000
"""

# Second field failure: halt did not stick, so the erase timed out.
HALT_FAIL_LOG = STLINK_BANNER + """\
Work-area: AXI SRAM @ 0x24000000 (0x10000 bytes)
Info : Device: STM32H74x/75x
Info : flash size probed value 2048k
Warn : [stm32h7x.cpu0] target was in unknown state when halt was requested
Error: erase time-out or operation error sector 0
Error: failed erasing sectors 0 to 0

FLASH_FAILED sector 0 @ 0x8000000: unknown OpenOCD failure
"""

HALT_FAIL_MARKED = STLINK_BANNER + """\
adapter speed 50 kHz
cortex_m reset halt failed
FLASH_FAILED halt: target could not be halted - target did not halt
    nothing was erased.
"""

ERASE_FAIL_MARKED = STLINK_BANNER + """\
  sector 0/12 @ 0x8000000 (131072 bytes, erase 128 KiB)
    attempt 1/3 failed: failed during erase
      Error: erase time-out or operation error sector 0
FLASH_FAILED erase: sector 0 @ 0x8000000 - flash erase failed
"""

SWD_LOST_MARKED = STLINK_BANNER + """\
FLASH_EVENT halt_ok
FLASH_STAGE erase
Error: Fail reading CTRL/STAT register. Force reconnect
FLASH_FAILED swd: sector 0 @ 0x8000000 - SWD link was lost
"""

# Third field failure: SWD transactions into core debug registers fail, so the
# target can be neither examined nor halted. Note there is no halt/erase here.
AP_FAIL_LOG = STLINK_BANNER + """\
adapter speed 50 kHz
0xe000edf0: 00000003
Error: Failed to write memory at 0xe0002004
Error: [stm32h7x.cpu0] Execution of event examine-end failed:
Error: Failed to write memory at 0xe0002010
FLASH_EVENT halt_failed TARGET: stm32h7x.cpu0 - Not halted
FLASH_FAILED ap: target could not be halted - core debug registers dead
    nothing was erased.
"""

# Link that dies during the work-area probe: no RAM region may be "accepted".
LINK_UNHEALTHY_LOG = STLINK_BANNER + """\
target halted out of reset
work area AXI SRAM (D1) @ 0x24000000 - RAM check FAILED (SWD link was lost)
work area SRAM1 (D2) @ 0x30000000 - RAM check FAILED (SWD link was lost)
Error: Fail reading CTRL/STAT register. Force reconnect
FLASH_FAILED swd: SWD link unhealthy (2 failures in a row) - SWD link lost
    nothing was erased.
"""

FLASH_OK_LOG = STLINK_BANNER + """\
flashing arducopter_with_bl.hex: 1645996 bytes @ 0x8000000 in 13 sector(s)
work area AXI SRAM (D1) 0x24000000 - RAM check ok
  sector 0/12 @ 0x8000000 (131072 bytes, erase 128 KiB)
    verified (131072 bytes, 61 KiB/s)
full verify...
Verified OK
FLASH_OK 1645996 bytes @ 0x8000000 work-area 0x24000000 (AXI SRAM (D1) 0x24000000) speed 50 kHz in 412.3s
"""


class ClassifierTest(unittest.TestCase):
    def setUp(self):
        self._orig = stlink.stlink_usb_present
        stlink.stlink_usb_present = lambda: True

    def tearDown(self):
        stlink.stlink_usb_present = self._orig

    def classify(self, text, rc=1):
        return stlink._classify_openocd("", text, rc)

    def test_dtcm_work_area_fault_is_a_failure(self):
        r = self.classify(DTCM_FAULT)
        self.assertFalse(r["ok"])
        self.assertEqual(r["state"], "flash_fail")
        self.assertIn("0x20003994", r["hint"])
        self.assertIn("AXI SRAM", r["hint"])

    def test_flash_ok_marker_wins(self):
        r = self.classify(FLASH_OK_LOG, rc=0)
        self.assertTrue(r["ok"])
        self.assertEqual(r["state"], "ok")
        self.assertTrue(r["verified"])
        self.assertAlmostEqual(r["voltage"], 3.274455)

    def test_halt_failure_is_not_unknown(self):
        r = self.classify(HALT_FAIL_LOG)
        self.assertFalse(r["ok"])
        self.assertEqual(r["state"], "halt_fail")
        self.assertEqual(r["code"], 4)
        self.assertIn("halt", r["hint"].lower())

    def test_halt_marker(self):
        r = self.classify(HALT_FAIL_MARKED)
        self.assertEqual(r["state"], "halt_fail")
        self.assertIn("erase", r["hint"])

    def test_erase_marker(self):
        r = self.classify(ERASE_FAIL_MARKED)
        self.assertEqual(r["state"], "erase_fail")
        self.assertEqual(r["code"], 4)

    def test_swd_lost_marker(self):
        r = self.classify(SWD_LOST_MARKED)
        self.assertEqual(r["state"], "swd_lost")
        self.assertEqual(r["code"], 3)

    def test_ap_failure_is_named(self):
        r = self.classify(AP_FAIL_LOG)
        self.assertFalse(r["ok"])
        self.assertEqual(r["state"], "ap_fail")
        self.assertEqual(r["code"], 3)
        self.assertIn("debug registers", r["hint"])
        self.assertIn("soak", r["hint"])

    def test_ap_failure_without_marker(self):
        r = self.classify(
            STLINK_BANNER
            + "Error: Failed to write memory at 0xe0002014\n"
            + "Error: Failed to read memory at 0xe00e4004\n"
        )
        self.assertEqual(r["state"], "ap_fail")

    def test_unhealthy_link_is_named(self):
        r = self.classify(LINK_UNHEALTHY_LOG)
        self.assertEqual(r["state"], "swd_lost")
        self.assertEqual(r["code"], 3)

    def test_flash_never_reports_ok_on_failure(self):
        # Even if the wrapper exited 0, a FLASH_FAILED log must not be "ok".
        orig = stlink.run_openocd_script
        stlink.run_openocd_script = lambda *a, **k: {
            "ok": True, "code": 0, "state": "ok", "log": LINK_UNHEALTHY_LOG,
        }
        try:
            r = stlink.flash(Path("arducopter_with_bl.hex"))
        finally:
            stlink.run_openocd_script = orig
        self.assertFalse(r["ok"])
        self.assertNotEqual(r["state"], "ok")

    def test_flash_reports_ok_on_flash_ok(self):
        orig = stlink.run_openocd_script
        stlink.run_openocd_script = lambda *a, **k: {
            "ok": False, "code": 4, "state": "flash_fail", "log": FLASH_OK_LOG,
        }
        try:
            r = stlink.flash(Path("arducopter_with_bl.hex"), precheck=False)
        finally:
            stlink.run_openocd_script = orig
        self.assertTrue(r["ok"])
        self.assertEqual(r["state"], "ok")
        self.assertTrue(r["verified"])

    def test_no_writable_ram(self):
        text = STLINK_BANNER + "no writable RAM for the flash loader\nFLASH_FAILED ...\n"
        r = self.classify(text)
        self.assertEqual(r["state"], "no_work_area")
        self.assertEqual(r["code"], 5)
        self.assertIn("contact", r["hint"])

    def test_blank_vector_table_refusal(self):
        text = STLINK_BANNER + (
            "FLASH_EVENT vectors_blank SP=0xffffffff PC=0xffffffff\n"
            "FLASH_FAILED vectors: this image starts at 0x8020000, so it cannot "
            "restore the vector table at 0x08000000 - the board would stay "
            "unbootable\n"
        )
        r = self.classify(text)
        self.assertEqual(r["state"], "vectors_blank")
        self.assertEqual(r["code"], 5)
        self.assertIn("0x08000000", r["hint"])

    def test_image_too_big_for_probed_flash(self):
        text = STLINK_BANNER + (
            "device flash: probed 1024 KiB (0x8000000..0x8100000)\n"
            "FLASH_WARN image does not fit the probed flash size\n"
            "FLASH_FAILED size: refusing to write 1645996 bytes into 1024 KiB "
            "of flash - nothing was erased\n"
        )
        r = self.classify(text)
        self.assertEqual(r["state"], "image_too_big")
        self.assertEqual(r["code"], 5)
        self.assertIn("FLASH_SIZE_KB", r["hint"])

    def test_brownout_is_named(self):
        text = STLINK_BANNER + (
            "Error: error while writing to address 0x5200200c\n"
            "Error: error during the lock of flash\n"
            "Error: Error closing APs\n"
            "FLASH_FAILED brownout: sector 1 @ 0x08020000\n"
        )
        r = self.classify(text)
        self.assertEqual(r["state"], "brownout")
        self.assertEqual(r["code"], 4)
        self.assertFalse(r["ok"])
        self.assertIn("brownout", r["hint"].lower())
        self.assertIn("0x5200200C", r["hint"])

    def test_brownout_is_retryable(self):
        self.assertIn("brownout", stlink.TRANSIENT_STATES)

    def test_stflash_failure_is_named(self):
        text = STLINK_BANNER + (
            "WARN common.c: NRST is not connected\n"
            "ERROR Soft reset failed: error write to AIRCR\n"
            "Failed to enter SWD mode\n"
            "FLASH_FAILED stflash: st-flash could not write 0x8000000..0x8200000\n"
        )
        r = self.classify(text)
        self.assertEqual(r["state"], "flash_fail")
        self.assertEqual(r["code"], 4)
        self.assertIn("st-flash", r["hint"])

    def test_stflash_success_is_ok(self):
        text = STLINK_BANNER + (
            "backend: stflash\n"
            "  st-flash: 131072 bytes written and verified (attempt 2)\n"
            "Verified OK\n"
            "FLASH_OK 131072 bytes @ 0x8000000 backend stflash speed 50 kHz in 4.2s\n"
        )
        r = self.classify(text, rc=0)
        self.assertTrue(r["ok"])
        self.assertEqual(r["state"], "ok")
        self.assertTrue(r["verified"])

    def test_swd_connect_failure(self):
        r = self.classify("Error: init mode failed (unable to connect to the target)\n")
        self.assertEqual(r["state"], "swd_fail")
        self.assertEqual(r["code"], 3)

    def test_verified_flash_not_downgraded_without_lsusb(self):
        stlink.stlink_usb_present = lambda: False
        r = self.classify(FLASH_OK_LOG, rc=0)
        self.assertTrue(r["ok"])
        self.assertEqual(r["state"], "ok")

    def test_missing_adapter(self):
        stlink.stlink_usb_present = lambda: False
        r = self.classify("Error: open failed\n")
        self.assertEqual(r["state"], "no_adapter")
        self.assertEqual(r["code"], 2)

    def test_probe_ok(self):
        r = self.classify(STLINK_BANNER + "PROBE_OK\n", rc=0)
        self.assertTrue(r["ok"])

    # ------------------------------------------------------------- flash gating
    def _with_scripts(self, soak_result, flash_results):
        """Patch soak() and run_openocd_script for flash() tests."""
        calls = {"flash": 0}
        orig_soak, orig_run = stlink.soak, stlink.run_openocd_script
        stlink.soak = lambda *a, **k: dict(soak_result)

        def fake_run(script, args=None, timeout=120, env=None):
            if script == "stlink_flash.sh":
                idx = min(calls["flash"], len(flash_results) - 1)
                calls["flash"] += 1
                return dict(flash_results[idx])
            return {"ok": True, "log": ""}

        stlink.run_openocd_script = fake_run
        return calls, (orig_soak, orig_run)

    @staticmethod
    def _restore(saved):
        stlink.soak, stlink.run_openocd_script = saved

    HEALTHY_LINK = {
        "ok": True, "state": "link_ok", "passed": 3, "attempts": 3,
        "pass_rate": 100.0, "hint": None, "log": "pass rate: 3/3 = 100 %",
    }
    BAD_LINK = {
        "ok": False, "state": "link_unhealthy", "passed": 0, "attempts": 3,
        "pass_rate": 0.0, "failures": {"connect": 3},
        "hint": "SWD link is marginal", "log": "pass rate: 0/3 = 0 %",
    }

    def test_flash_refuses_when_link_is_bad(self):
        calls, saved = self._with_scripts(self.BAD_LINK, [])
        try:
            r = stlink.flash(Path("arducopter_with_bl.hex"), precheck=True)
        finally:
            self._restore(saved)
        self.assertFalse(r["ok"])
        self.assertEqual(r["state"], "link_unhealthy")
        self.assertEqual(calls["flash"], 0)          # nothing was flashed
        self.assertIn("not flashing", r["log"])

    def test_flash_runs_when_link_is_healthy(self):
        ok_run = {"ok": True, "code": 0, "state": "ok", "log": FLASH_OK_LOG}
        calls, saved = self._with_scripts(self.HEALTHY_LINK, [ok_run])
        try:
            r = stlink.flash(Path("arducopter_with_bl.hex"), precheck=True)
        finally:
            self._restore(saved)
        self.assertTrue(r["ok"])
        self.assertEqual(calls["flash"], 1)

    def test_transient_failure_is_retried(self):
        bad = {"ok": False, "code": 3, "state": "swd_lost",
               "log": "FLASH_FAILED swd: SWD link unhealthy"}
        good = {"ok": True, "code": 0, "state": "ok", "log": FLASH_OK_LOG}
        calls, saved = self._with_scripts(self.HEALTHY_LINK, [bad, good])
        orig_delay = stlink.FLASH_RETRY_DELAY
        stlink.FLASH_RETRY_DELAY = 0
        try:
            r = stlink.flash(Path("arducopter_with_bl.hex"), precheck=True, retries=1)
        finally:
            stlink.FLASH_RETRY_DELAY = orig_delay
            self._restore(saved)
        self.assertTrue(r["ok"])
        self.assertEqual(calls["flash"], 2)
        self.assertTrue(r["notes"])

    def test_non_transient_failure_is_not_retried(self):
        bad = {"ok": False, "code": 4, "state": "erase_fail",
               "log": "FLASH_FAILED erase: flash erase failed"}
        calls, saved = self._with_scripts(self.HEALTHY_LINK, [bad])
        try:
            r = stlink.flash(Path("arducopter_with_bl.hex"), precheck=True, retries=2)
        finally:
            self._restore(saved)
        self.assertFalse(r["ok"])
        self.assertEqual(calls["flash"], 1)

    def test_flash_speed_is_passed_through(self):
        seen = {}
        orig_soak, orig_run = stlink.soak, stlink.run_openocd_script
        stlink.soak = lambda *a, **k: dict(self.HEALTHY_LINK)

        def fake_run(script, args=None, timeout=120, env=None):
            if script == "stlink_flash.sh":
                seen["env"] = env
                return {"ok": True, "code": 0, "state": "ok", "log": FLASH_OK_LOG}
            return {"ok": True, "log": ""}

        stlink.run_openocd_script = fake_run
        try:
            stlink.flash(Path("x.bin"), speed=25, precheck=False)
        finally:
            self._restore((orig_soak, orig_run))
        self.assertEqual(seen["env"], {"STLINK_SPEED": 25})

    def test_soak_healthy(self):
        log = (
            "link soak: 4 sessions @ 50 kHz, threshold 90 %\n"
            "  1/4  ok\n  2/4  ok\n  3/4  ok\n  4/4  ok\n"
            "pass rate: 4/4 = 100 % in 1.0s\n"
            "LINK_OK: link is healthy enough to flash\n"
        )
        orig = stlink.run_openocd_script
        stlink.run_openocd_script = lambda *a, **k: {"ok": True, "log": log}
        try:
            r = stlink.soak(count=4)
        finally:
            stlink.run_openocd_script = orig
        self.assertTrue(r["ok"])
        self.assertEqual(r["state"], "link_ok")
        self.assertEqual((r["passed"], r["attempts"]), (4, 4))
        self.assertEqual(r["pass_rate"], 100.0)

    def test_soak_unhealthy(self):
        log = (
            "link soak: 4 sessions @ 50 kHz, threshold 90 %\n"
            "  1/4  FAIL (connect)\n  2/4  ok\n  3/4  FAIL (connect)\n"
            "  4/4  FAIL (ap)\n"
            "pass rate: 1/4 = 25 % in 1.0s\n"
            "failures: ap=1, connect=2\n"
            "LINK_UNHEALTHY: the SWD link is marginal - do not flash yet\n"
        )
        orig = stlink.run_openocd_script
        stlink.run_openocd_script = lambda *a, **k: {"ok": False, "log": log}
        try:
            r = stlink.soak(count=4)
        finally:
            stlink.run_openocd_script = orig
        self.assertFalse(r["ok"])
        self.assertEqual(r["state"], "link_unhealthy")
        self.assertEqual(r["failures"], {"ap": 1, "connect": 2})
        self.assertIn("harness", r["hint"])

    def test_work_area_defaults_are_axi_sram(self):
        status = stlink.quick_status()
        self.assertTrue(status["defaults"]["work_area"].startswith("0x24000000"))

    def test_flash_image_roles(self):
        self.assertEqual(stlink._image_role("arducopter_with_bl.hex")[0], "combined")
        self.assertEqual(stlink._image_role("AP_Bootloader.bin")[0], "bootloader")
        self.assertEqual(stlink._image_role("arducopter.bin")[1], stlink.APP_BASE)


if __name__ == "__main__":
    unittest.main()
