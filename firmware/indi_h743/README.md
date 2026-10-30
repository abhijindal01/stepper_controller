# IndiH743 flash images for pad-test ST-LINK programming

Place binaries here (not committed by default — large / build-specific):

| File | Role |
|------|------|
| `AP_Bootloader.bin` | From WSL: `build/IndiH743/bin/AP_Bootloader.bin` or `Tools/bootloaders/IndiH743_bl.bin` |
| `arducopter.bin` | Pad-test app: `build/IndiH743-PadTest/bin/arducopter.bin` |
| `combined.bin` / `combined.hex` | Output of `tools/merge_indi_h743_image.py` |

Merge:

```bash
python3 ../tools/merge_indi_h743_image.py \
  --bootloader AP_Bootloader.bin \
  --firmware arducopter.bin \
  --out-bin combined.bin \
  --out-hex combined.hex
```

Flash map (confirm `FLASH_BOOTLOADER_LOAD_KB` in IndiH743 hwdef):

- Bootloader `@ 0x08000000`
- App `@ 0x08020000` (128 KiB)

## Recovery: the board booted from an erased sector 0

Symptom (OpenOCD, or the pad simply not starting):

```text
[stm32h7x.cpu0] halted due to debug-request, current mode: Thread
xPSR: 0x01000000 pc: 0xfffffffe msp: 0xfffffffc
```

An interrupted flash erased sector 0 (vector table + bootloader) and never
wrote it back. `tools/stlink_flash.sh` now reports this as
`FLASH_EVENT vectors_blank` and writes sector 0 **last**, so a full image
repairs it:

```bash
../tools/stlink_flash.sh combined.hex        # full image, sector 0 written last
```

The pad is a **1 MiB** H743 (`xG`), so the app partition is
`0x08020000`-`0x080FFFFF` = **896 KiB** and `text + data` must stay under
917,504 B. A 1.6 MB ArduCopter image does not fit and is refused before
anything is erased. Either build with `FLASH_SIZE_KB 1024` +
`HAL_MINIMIZE_FEATURES` and check `arm-none-eabi-size`, or restore the
bootloader sector - it carries the vector table and is the same 128 KiB on
every H743:

```bash
head -c 131072 combined.bin > bl_only.bin    # BL lives at the start of combined.bin
../tools/stlink_flash.sh bl_only.bin 0x08000000      # st-flash does the write
```

If that fails, the escalation ladder is `../tools/stlink_recover.sh`:

```bash
../tools/stlink_recover.sh bl_only.bin 0x08000000    # st-flash -> CubeProgrammer -> OpenOCD
../tools/stlink_recover.sh --dry-run bl_only.bin     # show the plan only
```

It retries `st-flash --connect-under-reset` (the only writer that has ever
completed on this board), falls back to CubeProgrammer and then OpenOCD, and
judges the result with OpenOCD's readback - `st-flash` says "jolly good!" and is
occasionally wrong. `RECOVER_OK` or nothing. Keep a copy of the bootloader
outside the pad: it is the one thing an erase cannot bring back.

Then check the board: `../tools/stlink_probe.sh` and `openocd ... -c "init;
mdw 0x08000000; exit"` must return a stack pointer inside RAM
(`0x200xxxxx`, `0x2400xxxx`-`0x24080000`, `0x300xxxxx`, `0x3800xxxx`), not
`ffffffff`.
