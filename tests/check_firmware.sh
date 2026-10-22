#!/usr/bin/env bash
#
# Syntax-check the Arduino firmware on the PC, without the Arduino
# toolchain and without a board attached.
#
#   bash tests/check_firmware.sh
#
# It only type-checks the sources - it does not produce a .hex file and
# does not upload anything.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"

STUBS="$HERE/host_stubs"

CXX="${CXX:-g++}"

SOURCES=(
    "Commands.cpp"
    "Homing.cpp"
    "Machine.cpp"
    "Motion.cpp"
    "Status.cpp"
)

echo "Checking firmware in $ROOT"
echo

FAILED=0

# The .ino is checked through a wrapper because the Arduino IDE normally
# generates the forward declarations of setup()/loop() helpers for us.

WRAPPER="$(mktemp /tmp/stepper_ino_XXXXXX.cpp)"

{
    echo '#include <Arduino.h>'
    echo '#include <EEPROM.h>'
    echo '#include "Config.h"'
    echo '#include "State.h"'
    echo '#include "Machine.h"'
    echo 'void checkEmergencyStop();'
    echo 'void emergencyState();'
    echo "#include \"$ROOT/StepperController.ino\""
} > "$WRAPPER"


check_file() {
    local file="$1"

    if "$CXX" -fsyntax-only -std=c++11 -I"$ROOT" -I"$STUBS" -x c++ "$file" 2>&1
    then
        echo "  OK       $(basename "$file")"
    else
        echo "  FAILED   $(basename "$file")"
        FAILED=1
    fi
}


check_file "$WRAPPER"

for source in "${SOURCES[@]}"; do
    check_file "$ROOT/$source"
done

rm -f "$WRAPPER"

echo

if [ "$FAILED" != "0" ]; then
    echo "Firmware has errors"
    exit 1
fi

echo "Firmware syntax OK"


# ===========================================================
# Now actually RUN the firmware logic against the stub core
# ===========================================================

echo

BINARY="$(mktemp /tmp/stepper_tests_XXXXXX)"

if ! "$CXX" -std=c++11 -I"$ROOT" -I"$STUBS" \
    -o "$BINARY" \
    "$HERE/test_persistence.cpp" \
    "$ROOT/Commands.cpp" \
    "$ROOT/Homing.cpp" \
    "$ROOT/Machine.cpp" \
    "$ROOT/Motion.cpp" \
    "$ROOT/Status.cpp" \
    "$STUBS/stubs.cpp" 2>&1
then
    echo "Could not build the logic test"
    exit 1
fi

"$BINARY" > /tmp/stepper_test_output.txt 2>&1
RESULT=$?

cat /tmp/stepper_test_output.txt

rm -f "$BINARY"

exit $RESULT
