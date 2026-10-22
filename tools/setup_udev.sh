#!/usr/bin/env bash
#
# Create the stable serial-port names the web app expects:
#
#       MOTOR 1  ->  /dev/stepper_a
#       MOTOR 2  ->  /dev/stepper_b
#
# Both Arduinos run identical firmware, so the ONLY thing that tells
# them apart is the port they are plugged into. Binding each board to a
# fixed name means a reboot (or swapping which socket is plugged in
# first) can never mix the two motors up.
#
# Usage:
#     sudo bash tools/setup_udev.sh                 # interactive
#     sudo bash tools/setup_udev.sh --out FILE      # write rules elsewhere
#     sudo MOTOR1_DEV=/dev/ttyUSB0 MOTOR2_DEV=/dev/ttyACM0 bash tools/setup_udev.sh
#

set -u

OUT="/etc/udev/rules.d/99-stepper-controllers.rules"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done


# ---------------------------------------------------------------
# Find the serial devices that are plugged in right now
# ---------------------------------------------------------------

DEVICES=()

for dev in /dev/ttyUSB* /dev/ttyACM*; do
    [ -e "$dev" ] || continue
    DEVICES+=("$dev")
done

if [ ${#DEVICES[@]} -eq 0 ]; then
    echo "No /dev/ttyUSB* or /dev/ttyACM* device found."
    echo "Plug in BOTH Arduino boards and run this again."
    exit 1
fi


# ---------------------------------------------------------------
# Describe each device
# ---------------------------------------------------------------

describe() {
    local dev="$1"
    local props path serial kernel vendor model

    props=$(udevadm info -q property -n "$dev" 2>/dev/null)

    serial=$(echo "$props" | sed -n 's/^ID_SERIAL_SHORT=//p')
    vendor=$(echo "$props" | sed -n 's/^ID_VENDOR_ID=//p')
    model=$(echo "$props"  | sed -n 's/^ID_MODEL_ID=//p')

    path=$(udevadm info -q path -n "$dev" 2>/dev/null)

    # e.g. /devices/.../1-1.2/1-1.2:1.0/ttyUSB0 -> 1-1.2
    kernel=$(echo "$path" | tr '/' '\n' | grep -E '^[0-9]+-[0-9]+(\.[0-9]+)*$' | head -1)

    printf '%s|%s|%s|%s|%s' "$dev" "${serial:-}" "${kernel:-}" "${vendor:-}" "${model:-}"
}


echo
echo "USB serial devices found:"
echo

INFO=()
i=0

for dev in "${DEVICES[@]}"; do
    i=$((i + 1))
    info=$(describe "$dev")
    INFO+=("$info")

    IFS='|' read -r _d serial kernel vendor model <<< "$info"

    echo "  [$i] $dev"
    echo "      usb id : ${vendor}:${model}"
    echo "      serial : ${serial:-<none - will use the USB socket instead>}"
    echo "      socket : ${kernel:-<unknown>}"
    echo
done


# ---------------------------------------------------------------
# Pick which board is which motor
# ---------------------------------------------------------------

index_of_dev() {
    local want="$1" idx
    for idx in "${!DEVICES[@]}"; do
        if [ "${DEVICES[$idx]}" = "$want" ]; then
            echo $((idx + 1))
            return 0
        fi
    done
    return 1
}


A_CHOICE=""
B_CHOICE=""

if [ -n "${MOTOR1_DEV:-}" ]; then
    A_CHOICE=$(index_of_dev "$MOTOR1_DEV") || { echo "MOTOR1_DEV=$MOTOR1_DEV was not found."; exit 1; }
fi

if [ -n "${MOTOR2_DEV:-}" ]; then
    B_CHOICE=$(index_of_dev "$MOTOR2_DEV") || { echo "MOTOR2_DEV=$MOTOR2_DEV was not found."; exit 1; }
fi

if [ -z "$A_CHOICE" ] || [ -z "$B_CHOICE" ]; then

    if [ ! -t 0 ]; then
        echo "No terminal to ask on - set MOTOR1_DEV and MOTOR2_DEV instead:"
        echo "  sudo MOTOR1_DEV=/dev/ttyUSB0 MOTOR2_DEV=/dev/ttyACM1 bash tools/setup_udev.sh"
        exit 1
    fi

    if [ -z "$A_CHOICE" ]; then
        read -r -p "Which board drives MOTOR 1 (/dev/stepper_a)? [1-$i, default 1] " A_CHOICE
        A_CHOICE=${A_CHOICE:-1}
    fi

    if [ -z "$B_CHOICE" ]; then
        read -r -p "Which board drives MOTOR 2 (/dev/stepper_b)? [1-$i, default 2] " B_CHOICE
        B_CHOICE=${B_CHOICE:-2}
    fi

fi


valid_choice() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "$i" ]
}

if ! valid_choice "$A_CHOICE" || ! valid_choice "$B_CHOICE"; then
    echo "Invalid selection (choose between 1 and $i)." >&2
    exit 1
fi


IFS='|' read -r A_DEV A_SERIAL A_KERNEL _a1 _a2 <<< "${INFO[$((A_CHOICE - 1))]}"
IFS='|' read -r B_DEV B_SERIAL B_KERNEL _b1 _b2 <<< "${INFO[$((B_CHOICE - 1))]}"

echo
echo "  MOTOR 1 -> $A_DEV -> /dev/stepper_a"
echo "  MOTOR 2 -> $B_DEV -> /dev/stepper_b"
echo


# ---------------------------------------------------------------
# Build one rule
# ---------------------------------------------------------------

rule_for() {
    local dev="$1" serial="$2" kernel="$3" link="$4"

    if [ -n "$serial" ]; then
        # unique per board: follows it to any USB socket
        echo "SUBSYSTEM==\"tty\", ATTRS{serial}==\"$serial\", SYMLINK+=\"$link\", MODE=\"0666\""
    elif [ -n "$kernel" ]; then
        # clones without a serial: tied to the physical socket
        echo "SUBSYSTEM==\"tty\", KERNELS==\"$kernel\", SYMLINK+=\"$link\", MODE=\"0666\""
    else
        echo "Could not build a rule for $dev (no serial, no usb path)." >&2
        return 1
    fi
}


TMP=$(mktemp)

{
    echo "# Generated by tools/setup_udev.sh on $(date)"
    echo "#"
    echo "#   MOTOR 1 -> /dev/stepper_a   ($A_DEV)"
    echo "#   MOTOR 2 -> /dev/stepper_b   ($B_DEV)"
    echo "#"
    echo "# Edit by hand, or re-run:  sudo bash tools/setup_udev.sh"
    echo
    rule_for "$A_DEV" "$A_SERIAL" "$A_KERNEL" "stepper_a"
    rule_for "$B_DEV" "$B_SERIAL" "$B_KERNEL" "stepper_b"
} > "$TMP"


cat "$TMP"
echo

if ! cp "$TMP" "$OUT" 2>/dev/null; then

    FALLBACK="udev/99-stepper-controllers.generated.rules"

    cp "$TMP" "$FALLBACK"

    echo "Could not write $OUT (run as root?) - wrote $FALLBACK instead."
    echo "Install it with:"
    echo "  sudo cp $FALLBACK $OUT"
    echo "  sudo udevadm control --reload-rules && sudo udevadm trigger"

    rm -f "$TMP"

    exit 0

fi

rm -f "$TMP"

echo "Wrote $OUT"


# ---------------------------------------------------------------
# Reload udev so the symlinks appear right now
# ---------------------------------------------------------------

if command -v udevadm >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then

    udevadm control --reload-rules
    udevadm trigger

    sleep 2

    echo
    echo "Result:"

    ls -l /dev/stepper_a /dev/stepper_b 2>/dev/null \
        || echo "  (not created yet - unplug and replug the boards, then check again)"

fi


echo
echo "Ports hardcoded in steppers.py:"
echo "   MOTOR 1 : /dev/stepper_a"
echo "   MOTOR 2 : /dev/stepper_b"
