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

If the image does not fit the part (the pad reports 1024 KiB, see
`docs/STLINK_FLASH_HANDOFF.md`), restore just the bootloader sector first - it
carries the vector table and is the same 128 KiB on every H743:

```bash
head -c 131072 combined.bin > bl_only.bin    # BL lives at the start of combined.bin
../tools/stlink_flash.sh bl_only.bin 0x08000000
```

Then check the board: `../tools/stlink_probe.sh` and `openocd ... -c "init;
mdw 0x08000000; exit"` must return a stack pointer inside RAM
(`0x200xxxxx`, `0x2400xxxx`-`0x24080000`, `0x300xxxxx`, `0x3800xxxx`), not
`ffffffff`.
