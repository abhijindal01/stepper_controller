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

    def test_no_writable_ram(self):
        text = STLINK_BANNER + "no writable RAM for the flash loader\nFLASH_FAILED ...\n"
        r = self.classify(text)
        self.assertEqual(r["state"], "no_work_area")
        self.assertEqual(r["code"], 5)
        self.assertIn("contact", r["hint"])

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

    def test_work_area_defaults_are_axi_sram(self):
        status = stlink.quick_status()
        self.assertTrue(status["defaults"]["work_area"].startswith("0x24000000"))

    def test_flash_image_roles(self):
        self.assertEqual(stlink._image_role("arducopter_with_bl.hex")[0], "combined")
        self.assertEqual(stlink._image_role("AP_Bootloader.bin")[0], "bootloader")
        self.assertEqual(stlink._image_role("arducopter.bin")[1], stlink.APP_BASE)


if __name__ == "__main__":
    unittest.main()
