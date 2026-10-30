#!/bin/bash
#
# Put a bootable image back on the H743 pad when the normal flash path fails.
#
#     tools/stlink_recover.sh                          # write tools' default image
#     tools/stlink_recover.sh /tmp/bl_sector0.bin      # bootloader only
#     tools/stlink_recover.sh image.bin 0x08000000
#     tools/stlink_recover.sh --dry-run image.bin
#
# Why this exists
# ---------------
# OpenOCD can examine, erase and *read* this fixture perfectly, but its flash
# loader download dies part-way through the write:
#
#     Error: Failed to write memory at 0x24001874
#     Error: error while writing to address 0x5200200c
#     Error: error during the lock of flash
#     Error: Error closing APs
#     unknown/unexpected STLINK status code 0x12 / 0x18
#
# and a failed write is only harmless while nothing has been erased. Once the
# chip is blank the app cannot be restored with the tool that erased it, so
# OpenOCD's `program` is not used here at all. This script tries two writers:
#
#   1. st-flash --connect-under-reset write   (stlink-tools)
#   2. STM32_Programmer_CLI (STM32CubeProgrammer) under reset
#
# st-flash has since failed on this pad too ("Flash programming error:
# 0x00040000"). For sector 0 - a bootloader - use tools/stlink_flash.sh first:
# its default direct writer is what put the bootloader back.
#
# Every step is judged by a *different* tool than the one that wrote: OpenOCD's
# `verify_image` readback. st-flash prints "Flash written and verified! jolly
# good!" and still gets it wrong sometimes, and the dongle is a clone that
# re-enumerates under load - a write that is not read back is not a write.
#
# Nothing here mass erases. An image is written, then read back; a failure
# leaves the rest of the flash alone so the next attempt still has something to
# work with.
#
# Exit codes: 0 written and verified, 1 usage, 2 no writer available,
#             3 write failed on every backend, 4 written but the readback
#             does not match, 5 the board has no contact at all.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CFG="${ROOT}/openocd_fixture.cfg"
OPENOCD="${OPENOCD:-openocd}"
STFLASH="${STLINK_STFLASH:-st-flash}"
CUBE="${STM32_PROGRAMMER:-STM32_Programmer_CLI}"
SPEED="${STLINK_SPEED:-50}"
TRIES="${STLINK_RECOVER_TRIES:-3}"
BACKOFF="${STLINK_CONNECT_BACKOFF:-2}"
DRY_RUN=0
IMG=""
BASE="0x08000000"

usage() {
    sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --speed)   SPEED="${2:?--speed needs a value}"; shift 2 ;;
        --tries)   TRIES="${2:?--tries needs a value}"; shift 2 ;;
        -*)        printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
        *)         if [[ -z "$IMG" ]]; then IMG="$1"; else BASE="$1"; fi; shift ;;
    esac
done

step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '   OK   %s\n' "$*"; }
bad()  { printf '   FAIL %s\n' "$*"; }

run() {  # run <label> <command...>
    local label="$1"
    shift
    if [[ "$DRY_RUN" = "1" ]]; then
        printf '   [dry-run] %s\n' "$*"
        return 0
    fi
    printf '   $ %s\n' "$*"
    "$@" 2>&1 | sed 's/^/     /'
    local rc=${PIPESTATUS[0]}
    if [[ $rc -eq 0 ]]; then
        ok "$label"
    else
        bad "$label (exit $rc)"
    fi
    return $rc
}

# ---------------------------------------------------------------- the target
if [[ -z "$IMG" ]]; then
    for candidate in \
        "$ROOT/../firmware/indi_h743/AP_Bootloader.bin" \
        "$(ls -1t /tmp/bl_sector0.bin 2>/dev/null | head -1)"
    do
        [[ -n "$candidate" && -f "$candidate" ]] && IMG="$candidate" && break
    done
fi

if [[ -z "$IMG" ]]; then
    cat >&2 <<'EOF'
no image given and none found.

    tools/stlink_recover.sh <image.bin> [base_addr]

The pad's bootloader is the 128 KiB sector 0 image at 0x08000000; the app is
written at 0x08020000. Keep a copy of the bootloader outside the pad - it is
the one thing a mass erase cannot bring back:
    tools/stlink_recover.sh /tmp/bl_sector0.bin 0x08000000
EOF
    exit 1
fi

IMG="$(realpath "$IMG")"
if [[ ! -f "$IMG" ]]; then
    printf 'file not found: %s\n' "$IMG" >&2
    exit 1
fi
SIZE=$(stat -c %s "$IMG")

printf 'recovering with %s (%s bytes) at %s\n' "$IMG" "$SIZE" "$BASE"
printf 'writers: st-flash=%s cube=%s  (readback: openocd=%s)\n' \
    "$(command -v "$STFLASH" || echo missing)" \
    "$(command -v "$CUBE" || echo missing)" \
    "$(command -v "$OPENOCD" || echo missing)"

have_stflash=0
have_cube=0
have_ocd=0
command -v "$STFLASH" >/dev/null 2>&1 && have_stflash=1
command -v "$CUBE" >/dev/null 2>&1 && have_cube=1
command -v "$OPENOCD" >/dev/null 2>&1 && have_ocd=1

if [[ $((have_stflash + have_cube)) -eq 0 ]]; then
    printf 'no writer installed: apt-get install stlink-tools, or install STM32CubeProgrammer\n' >&2
    exit 2
fi

# --------------------------------------------------------- 0. is it alive?
step "0. link check (OpenOCD examine, no erase, no reset)"
if [[ "$have_ocd" = "1" ]]; then
    if [[ "$DRY_RUN" = "1" ]]; then
        printf '   [dry-run] openocd ... -c "init; adapter speed %s; reset halt; reg pc; exit"\n' "$SPEED"
        CONTACT=1
    else
        # No `if {}` in Tcl here: the halt verdict is read from the log, because
        # a Tcl branch that never runs looks exactly like a halt that worked.
        HALT_LOG="$(mktemp)"
        "$OPENOCD" -f "$CFG" \
            -c "init; adapter speed ${SPEED}" \
            -c "reset halt" \
            -c "reg pc" -c "reg msp" \
            -c 'echo "RECOVER_HALT_DONE"' \
            -c "exit" > "$HALT_LOG" 2>&1
        sed 's/^/     /' "$HALT_LOG"
        CONTACT=1
        if ! grep -q "RECOVER_HALT_DONE" "$HALT_LOG" ||
            grep -qiE "target not halted|unknown state when halt|halt not|Failed to (read|write) memory at 0xe0" "$HALT_LOG"
        then
            CONTACT=0
        fi
        rm -f "$HALT_LOG"
        if [[ "$CONTACT" = "0" ]]; then
            cat >&2 <<'EOF'

no halt. Do not write yet, and do not erase: a write on a link that cannot
halt is how a blank chip happens. Check, in this order:
  * pogos seated (jog forward, wait for READY) - contact_ready only proves the
    motor reached its limit, not that SWD is connected
  * the dongle did not re-enumerate: dmesg -T | grep -iE "usb|stlink" | tail
  * target power, GND return, short cable, powered hub
  * tools/stlink_soak.sh 20   - how many connects out of 20 actually work?
Then re-run this script. st-flash is intermittent here: the same command can
fail with "Soft reset failed: error write to AIRCR" and succeed 54 s later.
EOF
            if [[ "$have_stflash" = "1" ]]; then
                info "st-flash --connect-under-reset retries anyway (it uses its own reset)"
            else
                exit 5
            fi
        else
            ok "target halted, SWD answers"
        fi
    fi
else
    info "OpenOCD missing - skipping the examine, st-flash will reset under reset"
fi

# ------------------------------------------------------------- 1. st-flash
attempt_write_stflash() {
    local n
    for (( n = 1; n <= TRIES; n++ )); do
        step "1. st-flash --connect-under-reset write ($n/$TRIES)"
        if run "st-flash write" "$STFLASH" --connect-under-reset \
            write "$IMG" "$BASE"; then
            return 0
        fi
        if [[ $n -lt $TRIES ]]; then
            info "retrying in ${BACKOFF}s - this dongle fails and then succeeds"
            sleep "$BACKOFF"
        fi
    done
    return 1
}

# --------------------------------- 2. STM32CubeProgrammer (vendor fallback)
attempt_write_cube() {
    step "2. STM32_Programmer_CLI (connect under reset)"
    # mode=UR = connect under reset, reset=SWrst keeps NRST out of it (the pad
    # has no NRST wire), -w writes, -v verifies with CubeProgrammer itself.
    run "CubeProgrammer write" "$CUBE" -c port=SWD mode=UR reset=SWrst \
        -w "$IMG" "$BASE" -v
}

WRITTEN=0
if [[ "$have_stflash" = "1" ]]; then
    attempt_write_stflash && WRITTEN=1
fi
if [[ "$WRITTEN" = "0" && "$have_cube" = "1" ]]; then
    attempt_write_cube && WRITTEN=1
fi

if [[ "$DRY_RUN" = "1" ]]; then
    step "dry run - nothing was written, nothing was verified"
    exit 0
fi

if [[ "$WRITTEN" = "0" ]]; then
    cat >&2 <<EOF

RECOVER_FAILED: no writer could put $SIZE bytes at $BASE.

What that does and does not mean:
  * a failed *write* does not damage anything by itself - sector 0 is erased and
    rewritten by each of these tools, so the next attempt starts over
  * for a bootloader (sector 0) run tools/stlink_flash.sh: its direct writer
    works on this pad where st-flash does not
  * if the board was already blank it stays blank: nothing to lose, keep trying
  * the dongle (0483:3748, garbage serial) re-enumerates under load. Move it to
    a powered hub / a direct Pi USB2 port with the shortest cable you have,
    check dmesg, then run this again
EOF
    exit 3
fi

# ------------------------------------- 3. read it back with a different tool
step "3. verify with OpenOCD's readback (the writer does not vote)"
if [[ "$have_ocd" = "0" ]]; then
    info "OpenOCD missing - install it before trusting any write"
    exit 4
fi

VERIFY_LOG="$(mktemp)"
"$OPENOCD" -f "$CFG" \
    -c "init; adapter speed ${SPEED}" \
    -c 'catch {reset halt}' \
    -c "verify_image $IMG $BASE" \
    -c "exit" > "$VERIFY_LOG" 2>&1
VRC=$?

if [[ $VRC -eq 0 ]] && grep -qi "verified" "$VERIFY_LOG"; then
    ok "readback matches ($(grep -io 'verified [0-9]* bytes[^)]*' "$VERIFY_LOG" | head -1))"
    step "4. release the target"
    if "$OPENOCD" -f "$CFG" -c "init; adapter speed ${SPEED}" \
        -c "reset run" -c 'echo "RECOVER_RUN"' -c "exit" 2>&1 | grep -q RECOVER_RUN
    then
        ok "target running"
    else
        info "reset run did not confirm - power-cycle the pad (jog away and back)"
    fi
    printf '\nRECOVER_OK %s bytes at %s (%s)\n' "$SIZE" "$BASE" "$IMG"
    rm -f "$VERIFY_LOG"
    exit 0
fi

sed 's/^/     /' "$VERIFY_LOG" >&2
cat >&2 <<EOF

RECOVER_FAILED verify: the writer said it succeeded and the readback disagrees.

That is the worst state to be in, so do not stop here: re-run this script (a
retry usually verifies), and if it stays mismatched run
    tools/stlink_flash.sh --help          # per-sector retries, slows SWD down
Log kept at $VERIFY_LOG
EOF
exit 4
