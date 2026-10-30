#!/usr/bin/env bash
#
# Syntax/smoke tests for the shell tooling. No hardware, no root, no network.
#
#     bash tests/check_scripts.sh
#
# Everything that would touch the system supports --dry-run / --help, so this
# can run anywhere (including CI).

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"

FAILED=0
CHECKS=0

pass() { CHECKS=$((CHECKS + 1)); printf '  PASS    %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILED=1; printf '  FAIL    %s\n' "$1"; }

printf '\nShell tooling tests\n--------------------\n'

# ---------------------------------------------------------------- syntax
for script in "$ROOT"/tools/*.sh; do
    name="$(basename "$script")"

    if bash -n "$script" 2>/dev/null; then
        pass "$name syntax"
    else
        fail "$name syntax"
        bash -n "$script"
    fi
done

# ---------------------------------------------------------------- --help
for script in "$ROOT"/tools/setup_hostname.sh "$ROOT"/tools/diagnose.sh; do
    name="$(basename "$script")"

    if bash "$script" --help >/dev/null 2>&1; then
        pass "$name --help"
    else
        fail "$name --help"
    fi
done

# ------------------------------------------------- unknown option rejected
if bash "$ROOT/tools/setup_hostname.sh" --nonsense >/dev/null 2>&1; then
    fail "setup_hostname.sh rejects unknown options"
else
    pass "setup_hostname.sh rejects unknown options"
fi

# ---------------------------------------------------------------- dry run
DRY_OUT="$(bash "$ROOT/tools/setup_hostname.sh" --dry-run --hostname assurance 2>&1)"
DRY_RC=$?

if [ "$DRY_RC" = "0" ]; then
    pass "setup_hostname.sh --dry-run exits 0"
else
    fail "setup_hostname.sh --dry-run exits 0 (got $DRY_RC)"
fi

if printf '%s' "$DRY_OUT" | grep -q "Dry run only - nothing was changed"; then
    pass "dry run says nothing was changed"
else
    fail "dry run says nothing was changed"
fi

if printf '%s' "$DRY_OUT" | grep -q 'assurance.local'; then
    pass "dry run reports the .local URL"
else
    fail "dry run reports the .local URL"
fi

# A dry run must not write to /etc/hosts or create the avahi unit
if printf '%s' "$DRY_OUT" | grep -q '\[dry-run\]'; then
    pass "dry run reports each action"
else
    fail "dry run reports each action"
fi

# ------------------------------------------------------- diagnose runs
DIAG_OUT="$(cd "$ROOT" && timeout 120 bash tools/diagnose.sh 2>&1)"
DIAG_RC=$?

if [ "$DIAG_RC" = "0" ]; then
    pass "diagnose.sh exits 0"
else
    fail "diagnose.sh exits 0 (got $DIAG_RC)"
fi

for marker in "===== system" "===== service" "===== hostname / mDNS" "===== verdict"; do
    if printf '%s' "$DIAG_OUT" | grep -q "$marker"; then
        pass "diagnose.sh reports $marker"
    else
        fail "diagnose.sh reports $marker"
    fi
done

# ------------------------------------------------------- flash script (fake OCD)
#
# tools/stlink_flash.sh is exercised against tests/stubs/openocd, a fake
# OpenOCD that models the H7 RAM, halt and flash behaviour:
#
#   STUB_RAM_FAULT=0x20000000   DTCM does not answer SWD writes
#   STUB_HALT_FAIL=1            halt / reset halt never stick (running app)
#   STUB_ERASE_FAIL=1           erase times out (target resets mid-erase)
#   STUB_DROP_AFTER=erase       target falls off SWD after the erase
#   STUB_AP_FAIL=1              core debug registers (0xE0001xxx+) dead
#   STUB_DROP_ON_RAM=1          link dies during the work-area probe
#   STUB_LINK_PATTERN=10        every second session cannot connect
#   STUB_SPEED_MAX=25           only connects at <= 25 kHz
#
printf '\nFlash wrapper (stubbed openocd)\n'

if bash "$ROOT/tools/stlink_flash.sh" --help >/dev/null 2>&1; then
    pass "stlink_flash.sh --help"
else
    fail "stlink_flash.sh --help"
fi

TMP_FLASH="$(mktemp -d)"
IMAGE_HEX="$TMP_FLASH/combined.hex"
IMAGE_BIN="$TMP_FLASH/combined.bin"
OCD_LOG="$TMP_FLASH/ocd.log"

python3 - "$IMAGE_BIN" "$IMAGE_HEX" <<'PY'
import sys

payload = bytes((i * 7) & 0xFF for i in range(0x400))
img = bytes(0x100) + payload  # 0x08000000 .. 0x080004FF
with open(sys.argv[1], "wb") as fh:
    fh.write(img)

lines = [":020000040800F2"]
for off in range(0, len(img), 16):
    chunk = img[off:off + 16]
    rec = [len(chunk), (off >> 8) & 0xFF, off & 0xFF, 0]
    rec += list(chunk)
    total = sum(rec) & 0xFF
    rec.append((-total) & 0xFF)
    lines.append(":" + "".join(f"{b:02X}" for b in rec))
lines.append(":00000001FF")
with open(sys.argv[2], "w", encoding="ascii") as fh:
    fh.write("\n".join(lines) + "\n")
PY

run_flash() {  # run_flash <label> <expected-rc> [env assignments...]
    local label="$1" want="$2"
    shift 2
    local out rc
    rm -f "$OCD_LOG"
    out="$(env PATH="$HERE/stubs:$PATH" "$@" \
        bash "$ROOT/tools/stlink_flash.sh" "$IMAGE_HEX" 2>&1)"
    rc=$?
    printf '%s' "$out" > "$TMP_FLASH/last.log"
    if [ "$rc" = "$want" ]; then
        pass "$label (exit $rc)"
    else
        fail "$label (exit $rc, wanted $want)"
        printf '%s\n' "$out" | tail -20
    fi
}

expect_log() {  # expect_log <label> <pattern>
    if grep -q -- "$2" "$TMP_FLASH/last.log" 2>/dev/null; then
        pass "$1"
    else
        fail "$1 (no '$2' in output)"
        tail -12 "$TMP_FLASH/last.log"
    fi
}

reject_log() {  # reject_log <label> <pattern>
    if grep -q -- "$2" "$TMP_FLASH/last.log" 2>/dev/null; then
        fail "$1 (found '$2')"
    else
        pass "$1"
    fi
}

# ---------------------------------------------------------------- healthy target
run_flash "flash uses a writable work area" 0 STUB_OPENOCD_LOG="$OCD_LOG"
expect_log "flash reports FLASH_OK" "FLASH_OK"
expect_log "flash halts the core out of reset" "target halted out of reset"
if grep -q "work-area-phys 0x24000000" "$OCD_LOG" 2>/dev/null; then
    pass "flash configures the AXI SRAM work area"
else
    fail "flash configures the AXI SRAM work area"
fi
if grep -q "0x20000000" "$OCD_LOG" 2>/dev/null; then
    fail "flash never touches the DTCM work area"
else
    pass "flash never touches the DTCM work area"
fi
if grep -q "mdw 0xe000edf0" "$OCD_LOG" 2>/dev/null; then
    pass "flash confirms the halt via DHCSR"
else
    fail "flash confirms the halt via DHCSR"
fi
if grep -q "reset halt" "$OCD_LOG" 2>/dev/null; then
    pass "flash erases only after reset halt"
else
    fail "flash erases only after reset halt"
fi
if grep -q "0x20000200" "$OCD_LOG" 2>/dev/null; then
    fail "flash sets no DTCM trampoline"
else
    pass "flash sets no DTCM trampoline"
fi
expect_log "flash releases the target after verify" "reset run"

# ------------------------------------------------------- loader RAM fallbacks
run_flash "flash survives dead DTCM" 0 STUB_RAM_FAULT=0x20000000
expect_log "dead DTCM still reaches FLASH_OK" "FLASH_OK"

run_flash "flash falls back to SRAM1" 0 STUB_RAM_FAULT=0x20000000,0x24000000 \
    STUB_OPENOCD_LOG="$OCD_LOG"
if grep -q "work-area-phys 0x30000000" "$OCD_LOG" 2>/dev/null; then
    pass "fallback uses SRAM1"
else
    fail "fallback uses SRAM1"
fi

run_flash "flash falls back to SRAM4" 0 \
    STUB_RAM_FAULT=0x20000000,0x24000000,0x30000000 STUB_OPENOCD_LOG="$OCD_LOG"
if grep -q "work-area-phys 0x38000000" "$OCD_LOG" 2>/dev/null; then
    pass "fallback uses SRAM4"
else
    fail "fallback uses SRAM4"
fi

run_flash "forced dead work area fails" 2 \
    STUB_RAM_FAULT=0x20000000,0x24000000,0x30000000,0x38000000 \
    STLINK_WORKAREA=0x24000000
expect_log "dead work area reports why" "not writable"

# ------------------------------------------------------------- halt behaviour
run_flash "halt that does not stick is reported" 4 STUB_HALT_FAIL=1 STLINK_HALT_TRIES=1
expect_log "unhaltable target says so" "FLASH_FAILED halt"
expect_log "unhaltable target says nothing was erased" "nothing was erased"
reject_log "nothing is erased without a confirmed halt" "erased address"

run_flash "plain halt fallback works" 0 STLINK_RESET_HALT=0
expect_log "plain halt path still flashes" "FLASH_OK"

# ------------------------------------------------------------- erase behaviour
run_flash "erase timeout is reported" 3 STUB_ERASE_FAIL=1 STLINK_ATTEMPTS=2
expect_log "erase failure says erase" "FLASH_FAILED erase"
expect_log "erase retry slows SWD down" "lowering adapter speed"

run_flash "target dropping off SWD is reported" 3 STUB_DROP_AFTER=erase \
    STLINK_ATTEMPTS=2 STLINK_HALT_TRIES=1
expect_log "loss of SWD says swd" "FLASH_FAILED swd"

run_flash "no SWD contact is reported" 3 STUB_SWD_FAIL=1 STLINK_HALT_TRIES=1
expect_log "no SWD reports swd" "FLASH_FAILED swd"

# ------------------------------------------------- debug registers (AP) faults
run_flash "dead core debug registers are reported" 3 STUB_AP_FAIL=1
expect_log "AP failure is named as ap" "FLASH_FAILED ap"
expect_log "AP failure mentions debug registers" "debug registers"
reject_log "nothing is erased with a dead AP" "erased address"

# --------------------------------------------- link health measured, not guessed
run_flash "link dying in the RAM probe aborts" 2 STUB_DROP_ON_RAM=1
expect_log "unhealthy link is reported" "SWD link unhealthy"
expect_log "unhealthy link points at the soak tool" "stlink_soak.sh"
reject_log "no RAM region is accepted on a dying link" "RAM check ok"

# ------------------------------------------- marginal link needs a slow clock
run_flash "too-fast SWD cannot connect" 3 STUB_SPEED_MAX=25 \
    STLINK_CONNECT_BACKOFF=0 STLINK_HALT_TRIES=1
expect_log "connect failure says 'could not be reached'" "could not be reached"
reject_log "connect failure is not called a halt failure" "could not be halted"
expect_log "connect failure retries with a pause" "connect failed - retrying"

run_flash "slow SWD connects and flashes" 0 STUB_SPEED_MAX=25 STLINK_SPEED=25
expect_log "slow path still reaches FLASH_OK" "FLASH_OK"

run_flash "flaky link recovered by connect retry" 0 STUB_LINK_PATTERN=10 \
    STLINK_CONNECT_BACKOFF=0
expect_log "flaky link ends in FLASH_OK" "FLASH_OK"

# ------------------------------------------------------------- soak tool
if bash "$ROOT/tools/stlink_soak.sh" --help >/dev/null 2>&1; then
    pass "stlink_soak.sh --help"
else
    fail "stlink_soak.sh --help"
fi

rm -f "$TMP_FLASH/sessions"
SOAK_OUT="$(env PATH="$HERE/stubs:$PATH" STUB_STATE_FILE="$TMP_FLASH/sessions" \
    STLINK_SOAK_GAP=0 bash "$ROOT/tools/stlink_soak.sh" 4 --min 90 2>&1)"
SOAK_RC=$?
if [ "$SOAK_RC" = "0" ] && printf '%s' "$SOAK_OUT" | grep -q "LINK_OK"; then
    pass "soak passes on a healthy link"
else
    fail "soak passes on a healthy link (exit $SOAK_RC)"
    printf '%s\n' "$SOAK_OUT" | tail -10
fi
if printf '%s' "$SOAK_OUT" | grep -q "4/4 = 100 %"; then
    pass "soak reports the pass rate"
else
    fail "soak reports the pass rate"
fi

rm -f "$TMP_FLASH/sessions"
SOAK_OUT="$(env PATH="$HERE/stubs:$PATH" STUB_STATE_FILE="$TMP_FLASH/sessions" \
    STUB_LINK_PATTERN=10 STLINK_SOAK_GAP=0 \
    bash "$ROOT/tools/stlink_soak.sh" 4 --min 90 2>&1)"
SOAK_RC=$?
if [ "$SOAK_RC" != "0" ]; then
    pass "soak fails on a flaky link (exit $SOAK_RC)"
else
    fail "soak fails on a flaky link (exit 0)"
fi
if printf '%s' "$SOAK_OUT" | grep -qi "unhealthy\|marginal"; then
    pass "soak explains a flaky link"
else
    fail "soak explains a flaky link"
fi
if printf '%s' "$SOAK_OUT" | grep -q "connect x2"; then
    pass "soak classifies connect failures"
else
    fail "soak classifies connect failures"
    printf '%s\n' "$SOAK_OUT" | tail -12
fi

# ------------------------------------------------------ speed ladder goes slow
run_flash "erase failure walks the speed ladder down" 3 STUB_ERASE_FAIL=1 \
    STLINK_ATTEMPTS=4
if grep -q "lowering adapter speed to 25 kHz" "$TMP_FLASH/last.log"; then
    pass "ladder reaches 25 kHz"
else
    fail "ladder reaches 25 kHz"
fi
if grep -q "lowering adapter speed to 12 kHz" "$TMP_FLASH/last.log"; then
    pass "ladder reaches the 12 kHz floor"
else
    fail "ladder reaches the 12 kHz floor"
fi

# --------------------------------------------------------------- guard rails
OUT="$(env PATH="$HERE/stubs:$PATH" bash "$ROOT/tools/stlink_flash.sh" \
    "$IMAGE_BIN" 0x20000000 2>&1)"
RC=$?
if [ "$RC" != "0" ] && printf '%s' "$OUT" | grep -q "outside internal flash"; then
    pass "flash refuses out-of-flash base"
else
    fail "flash refuses out-of-flash base (exit $RC)"
fi

# ------------------------------------- work area: probe the loader footprint
# The fault seen on the pad: AXI SRAM answers a word at its base, so the old
# two-word probe said "RAM check ok", and then the loader write died at
# 0x24001874 - after the erase. The probe must cover that footprint, so nothing
# is erased at all.
run_flash "work area that only answers its base word is rejected" 0 \
    STUB_RAM_FAULT_ABOVE=0x24001000
expect_log "loader footprint failure names the address" "RAM check FAILED at 0x24001000"
expect_log "the loader moves to SRAM1 instead" "work area SRAM1 (D2)"
run_flash "probe writes through the loader footprint" 0 STUB_OPENOCD_LOG="$OCD_LOG"
if grep -q "mww 0x24004074" "$OCD_LOG" 2>/dev/null &&
    grep -q "mww 0x24001874" "$OCD_LOG" 2>/dev/null; then
    pass "work-area probe covers the loader footprint (0x1874 / 0x4074)"
else
    fail "work-area probe covers the loader footprint (0x1874 / 0x4074)"
fi

# --------------------------------------------- retries never erase twice
# A write that fails *after* the erase used to re-erase on every attempt: three
# attempts per sector meant three chances to leave sector 0 blank.
rm -f "$TMP_FLASH/writes"
run_flash "write failure after erase retries without erasing" 0 \
    STUB_WRITE_FAIL_ONCE=1 STUB_WRITE_STATE_FILE="$TMP_FLASH/writes" \
    STUB_OPENOCD_LOG="$OCD_LOG" STLINK_ATTEMPTS=2
expect_log "write retry says it is not erasing again" "no second erase"
ERASES="$(grep -c "flash erase_address" "$OCD_LOG" 2>/dev/null || echo 0)"
WRITES="$(grep -c "flash write_image" "$OCD_LOG" 2>/dev/null || echo 0)"
if [ "$ERASES" = "1" ] && [ "$WRITES" = "2" ]; then
    pass "one erase, two writes (1 erase, $WRITES writes)"
else
    fail "one erase, two writes (got $ERASES erases, $WRITES writes)"
fi

# ------------------------------------------- sector 0 (vector table) is last
python3 - "$TMP_FLASH/two_sectors.bin" <<'PY2'
import sys

with open(sys.argv[1], "wb") as fh:
    fh.write(bytes((i * 13) & 0xFF for i in range(0x40000)))  # 256 KiB = 2 sectors
PY2
rm -f "$OCD_LOG"
OUT="$(env PATH="$HERE/stubs:$PATH" STUB_OPENOCD_LOG="$OCD_LOG" \
    bash "$ROOT/tools/stlink_flash.sh" "$TMP_FLASH/two_sectors.bin" 2>&1)"
RC=$?
printf '%s' "$OUT" > "$TMP_FLASH/last.log"
if [ "$RC" = "0" ]; then
    pass "two-sector image flashes (exit 0)"
else
    fail "two-sector image flashes (exit $RC)"
    printf '%s\n' "$OUT" | tail -15
fi
expect_log "sector order is announced" "sector 0 (vector table / bootloader) is written last"
FIRST_WRITE="$(grep -n "flash write_image" "$OCD_LOG" 2>/dev/null | head -1)"
LAST_WRITE="$(grep -n "flash write_image" "$OCD_LOG" 2>/dev/null | tail -1)"
case "$FIRST_WRITE" in
    *part_01.bin*) FIRST_IS_ONE=1 ;;
    *) FIRST_IS_ONE=0 ;;
esac
case "$LAST_WRITE" in
    *part_00.bin*) LAST_IS_ZERO=1 ;;
    *) LAST_IS_ZERO=0 ;;
esac
if [ "$FIRST_IS_ONE" = "1" ] && [ "$LAST_IS_ZERO" = "1" ]; then
    pass "sector 1 is written before sector 0"
else
    fail "sector 1 is written before sector 0"
fi

# --------------------------------------------- board state: blank vectors
run_flash "blank vector table is reported" 0 STUB_BLANK_VECTORS=1
expect_log "blank vectors are named" "FLASH_EVENT vectors_blank"
expect_log "blank vectors explain why the board will not boot" "no valid vector table"
expect_log "blank vectors still reach FLASH_OK" "FLASH_OK"

OUT="$(env PATH="$HERE/stubs:$PATH" STUB_BLANK_VECTORS=1 \
    bash "$ROOT/tools/stlink_flash.sh" "$IMAGE_BIN" 0x08020000 2>&1)"
RC=$?
printf '%s' "$OUT" > "$TMP_FLASH/last.log"
if [ "$RC" = "5" ]; then
    pass "app-only image on a blank-vector board is refused (exit 5)"
else
    fail "app-only image on a blank-vector board is refused (exit $RC, wanted 5)"
    printf '%s\n' "$OUT" | tail -8
fi
expect_log "refusal says to flash a full image" "flash a full image from 0x08000000"
reject_log "refusal happens before any erase" "erased address"

# ------------------------------------------- board state: probed flash size
OUT="$(env PATH="$HERE/stubs:$PATH" STUB_FLASH_SIZE_KB=128 \
    bash "$ROOT/tools/stlink_flash.sh" "$TMP_FLASH/two_sectors.bin" 2>&1)"
RC=$?
printf '%s' "$OUT" > "$TMP_FLASH/last.log"
if [ "$RC" = "1" ]; then
    pass "image bigger than the probed flash is refused (exit 1)"
else
    fail "image bigger than the probed flash is refused (exit $RC, wanted 1)"
    printf '%s\n' "$OUT" | tail -10
fi
expect_log "oversize refusal shows the probed size" "image does not fit the probed flash size"
reject_log "oversize refusal erases nothing" "erased address"

run_flash "oversize write can be forced" 0 STUB_FLASH_SIZE_KB=128 \
    STLINK_ALLOW_OVERSIZE=1
reject_log "forced oversize does not claim FLASH_FAILED" "FLASH_FAILED"

rm -rf "$TMP_FLASH"

# ---------------------------------------------------------------- summary
printf '\n--------------------\n'
printf '%s checks, %s failure(s)\n' "$CHECKS" "$FAILED"

[ "$FAILED" = "0" ] || exit 1
