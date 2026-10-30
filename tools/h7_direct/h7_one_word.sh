#!/bin/bash
# Program the single flash word at 0x080045A0 and show everything OpenOCD says.
# Retries the SWD connect up to 10 times. Run from ~/stepper_controller.
IMG=firmware/indi_h743/bl_sector0_from_arducopter_with_bl.bin
W=$(python3 -I -c "import struct,sys;b=open(sys.argv[1],'rb').read();print(' '.join('0x%08x'%x for x in struct.unpack_from('<8I',b,0x45a0)))" "$IMG")
for i in $(seq 1 10); do
    r=$(timeout 60 openocd -f tools/openocd_fixture.cfg -c "adapter speed 200" -c "init" \
        -c "reset halt" -c "echo DHCSR; mdw 0xE000EDF0" \
        -c "echo SR1_CR1_before; mdw 0x52002010; mdw 0x5200200C" \
        -c "mww 0x52002004 0x45670123; mww 0x52002004 0xCDEF89AB; mww 0x52002014 0x0FEF0000; mww 0x5200200C 0x32" \
        -c "echo CR1_unlocked; mdw 0x5200200C" \
        -c "write_memory 0x080045a0 32 {$W}" -c "sleep 20" \
        -c "echo SR1_after; mdw 0x52002010" -c "mww 0x5200200C 1" \
        -c "echo WORD; mdw 0x080045a0 8" -c exit 2>&1)
    if echo "$r" | grep -q "init mode failed"; then echo "connect $i/10 failed"; sleep 2; continue; fi
    echo "$r" | grep -vE "^Licensed|^For bug|^\s+http|^Open On|gdb|breakpoints"
    echo "EXPECTED: $W"
    exit 0
done
echo "NO_CONNECT: SWD never came up in 10 tries"
