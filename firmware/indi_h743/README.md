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
