#!/bin/bash
# Read-only: is the flash word at 0x080045A0 an uncorrectable-ECC word?
# Reads the neighbours, then the word, then the ECC flags and fail address.
# Retries the SWD connect up to 10 times. Run from ~/stepper_controller.
for i in $(seq 1 10); do
    r=$(timeout 60 openocd -f tools/openocd_fixture.cfg -c "adapter speed 200" -c "init" \
        -c "reset halt" \
        -c "mww 0x52002014 0x0FEF0000" \
        -c "echo WORD_BEFORE_0x08004580; mdw 0x08004580 8" \
        -c "echo WORD_AFTER_0x080045C0; mdw 0x080045c0 8" \
        -c "echo SR1_neighbours; mdw 0x52002010" \
        -c "echo WORD_0x080045A0; catch {mdw 0x080045a0 8} e; echo \$e" \
        -c "echo SR1_after_read; mdw 0x52002010" \
        -c "echo ECC_FA1R; mdw 0x52002060" \
        -c exit 2>&1)
    if echo "$r" | grep -q "init mode failed"; then echo "connect $i/10 failed"; sleep 2; continue; fi
    echo "$r" | grep -vE "^Licensed|^For bug|^\s+http|^Open On|gdb|breakpoints|^Info|Erratum|Work-area|adapter speed"
    exit 0
done
echo "NO_CONNECT: SWD never came up in 10 tries"
