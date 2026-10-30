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

# ---------------------------------------------------------------- no hardware
# The wrapper picks its writer with `command -v st-flash`, so any test that
# only puts tests/stubs (fake OpenOCD) on PATH used to reach the real
# /usr/bin/st-flash and program the board on the fixture. Shadow every PATH
# directory that holds a real programmer with a copy that lacks it: the tests
# then see exactly the stubs they put on PATH and nothing else.
REAL_TOOLS="st-flash st-info st-util openocd STM32_Programmer_CLI"
SHADOW_ROOT="$(mktemp -d)"
trap 'rm -rf "$SHADOW_ROOT"' EXIT
SAFE_PATH=""
IFS=: read -r -a _path_dirs <<< "$PATH"
for _dir in "${_path_dirs[@]}"; do
    _hit=0
    for _tool in $REAL_TOOLS; do
        [ -e "$_dir/$_tool" ] && _hit=1
    done
    if [ "$_hit" = "1" ]; then
        _shadow="$SHADOW_ROOT/$(printf '%s' "$_dir" | tr '/' '_')"
        mkdir -p "$_shadow"
        for _f in "$_dir"/*; do
            case " $REAL_TOOLS " in *" $(basename "$_f") "*) continue ;; esac
            ln -s "$_f" "$_shadow/" 2>/dev/null
        done
        _dir="$_shadow"
    fi
    SAFE_PATH="${SAFE_PATH:+$SAFE_PATH:}$_dir"
done
export PATH="$SAFE_PATH"
for _tool in $REAL_TOOLS; do
    if command -v "$_tool" >/dev/null 2>&1; then
        printf 'refusing to run: real %s still on PATH (%s)\n' \
            "$_tool" "$(command -v "$_tool")" >&2
        exit 2
    fi
done

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
# The image below fits sector 0, which `auto` now hands to the direct writer.
# Point it at nothing so these tests keep exercising st-flash/OpenOCD; the
# direct backend has its own section further down.
export STLINK_DIRECT_WRITER="$TMP_FLASH/no-direct-writer"

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
    rm -rf "$TMP_FLASH/mem"
    out="$(env PATH="$HERE/stubs:$PATH" STUB_MEM_DIR="$TMP_FLASH/mem" "$@" \
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
if grep -q "work-area-phys 0x20000000" "$OCD_LOG" 2>/dev/null; then
    fail "DTCM is never used as the loader work area"
else
    pass "DTCM is never used as the loader work area"
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
    STUB_RAM_FAULT=0x24000000 STLINK_WORKAREA=0x24000000
expect_log "dead work area reports why" "not writable"
expect_log "the integrity walk noticed it first" "RAM integrity FAILED - AXI SRAM (D1)"

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

# ----------------------------------------------- st-flash backend (the pad fix)
# OpenOCD erases and reads this fixture but its flash loader download dies
# ("Failed to write memory at 0x24001874", STLINK status 0x12/0x18), so
# tools/stlink_flash.sh writes through `st-flash --connect-under-reset` when it
# is installed and keeps OpenOCD for the probe and the readback verify.
#
#   tests/stubs/stflash/st-flash   fake 1.8.0 writer (own 128 KiB page erase)
#   tests/stubs/stflash/st-info    fake probe, second opinion on the flash size
#
#   STUB_STFLASH_FAIL_TIMES=1   first call fails to enter SWD mode
#   STUB_STFLASH_DIE=write      writes always fail
#   STUB_STFLASH_SHORT_WRITE=1  claims fewer bytes written than the file holds
#   STUB_STINFO_FLASH_KB=128    st-info disagrees with the OpenOCD probe
#   STUB_VERIFY_FAIL=1          the readback does not match
printf '\nFlash wrapper (st-flash backend)\n'

SFLASH_PATH="$HERE/stubs/stflash:$HERE/stubs"
SFLASH_LOG="$TMP_FLASH/stflash.log"

run_sflash() {  # run_sflash <label> [expected-rc] [env assignments...]
    local label="$1" want="${2:-0}"
    if [ "$#" -ge 2 ]; then shift 2; else shift 1; fi
    local out rc
    rm -f "$OCD_LOG" "$SFLASH_LOG"
    rm -rf "$TMP_FLASH/mem"
    out="$(env PATH="$SFLASH_PATH:$PATH" STUB_OPENOCD_LOG="$OCD_LOG" \
        STUB_MEM_DIR="$TMP_FLASH/mem" \
        STUB_STFLASH_LOG="$SFLASH_LOG" "$@" \
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

run_flash_with_image() {  # run_flash_with_image <label> <want> <image> [env...]
    local label="$1" want="$2" img="$3"
    shift 3
    local out rc
    rm -f "$OCD_LOG" "$SFLASH_LOG"
    rm -rf "$TMP_FLASH/mem"
    out="$(env PATH="$SFLASH_PATH:$PATH" STUB_OPENOCD_LOG="$OCD_LOG" \
        STUB_MEM_DIR="$TMP_FLASH/mem" \
        STUB_STFLASH_LOG="$SFLASH_LOG" "$@" \
        bash "$ROOT/tools/stlink_flash.sh" "$img" 2>&1)"
    rc=$?
    printf '%s' "$out" > "$TMP_FLASH/last.log"
    if [ "$rc" = "$want" ]; then
        pass "$label (exit $rc)"
    else
        fail "$label (exit $rc, wanted $want)"
        printf '%s\n' "$out" | tail -20
    fi
}

run_sflash "st-flash is used when installed"
expect_log "backend is announced" "backend: stflash"
expect_log "st-info confirms the part size" "st-info reports 1024 KiB"
expect_log "the write goes through st-flash" "bytes written and verified"
expect_log "OpenOCD still verifies the readback" "Verified OK"
expect_log "FLASH_OK names the backend" "backend stflash"
reject_log "no OpenOCD flash write_image" "flash write_image"
if grep -q "st-flash --connect-under-reset write" "$SFLASH_LOG" 2>/dev/null; then
    pass "the image really went to st-flash"
else
    fail "the image really went to st-flash"
fi
if grep -q "dump_image" "$OCD_LOG" 2>/dev/null; then
    pass "the writer does not vote: OpenOCD read the image back"
else
    fail "the writer does not vote: OpenOCD read the image back"
fi

# The dongle on the pad fails the first `--connect-under-reset` and succeeds on
# a retry (15:54:31 was the second attempt); a transient must not fail a flash.
rm -f "$TMP_FLASH/state"
run_sflash "a failed SWD entry is retried" 0 STUB_STFLASH_STATE_FILE="$TMP_FLASH/state" \
    STUB_STFLASH_FAIL_TIMES=1
expect_log "the first attempt is reported" "st-flash attempt 1/3 failed"
expect_log "the retry succeeds" "attempt 2"

run_sflash "st-flash that never enters SWD fails the flash" 3 \
    STUB_STFLASH_STATE_FILE="$TMP_FLASH/state" STUB_STFLASH_FAIL_TIMES=99
expect_log "the failure is classified" "FLASH_FAILED stflash"
expect_log "the dongle log is shown" "Failed to enter SWD mode"
if grep -q "stflash_attempt1.log" "$TMP_FLASH/last.log"; then
    pass "the failing session log is kept"
else
    fail "the failing session log is kept"
fi

run_sflash "a short write is not trusted" 3 STUB_STFLASH_SHORT_WRITE=1
expect_log "short write is a failure" "FLASH_FAILED"

# st-flash verifies its own write - and so does OpenOCD. When they disagree the
# readback wins.
run_sflash "readback mismatch fails the flash" 3 STUB_VERIFY_FAIL=1
expect_log "verify failure is classified" "FLASH_FAILED verify"
reject_log "a lying writer never prints FLASH_OK" "FLASH_OK"

# ------------------------------------------------------ mass erase (opt-in)
run_sflash "mass erase erases before writing" 0 STLINK_MASS_ERASE=1
expect_log "mass erase is announced" "mass erase requested"
expect_log "mass erase result is reported" "st-flash mass erase: ok"
ERASE_LINE="$(grep -n "erase" "$SFLASH_LOG" 2>/dev/null | head -1 | cut -d: -f1)"
WRITE_LINE="$(grep -n "write" "$SFLASH_LOG" 2>/dev/null | head -1 | cut -d: -f1)"
if [ -n "$ERASE_LINE" ] && [ -n "$WRITE_LINE" ] && [ "$ERASE_LINE" -lt "$WRITE_LINE" ]; then
    pass "erase happens before the write"
else
    fail "erase happens before the write"
fi

run_sflash "a failed mass erase writes nothing" 3 STLINK_MASS_ERASE=1 \
    STUB_STFLASH_DIE=erase
expect_log "erase failure is classified" "FLASH_FAILED erase"
if grep -q "write" "$SFLASH_LOG" 2>/dev/null; then
    fail "a failed mass erase writes nothing (a write followed)"
else
    pass "a failed mass erase writes nothing"
fi

# The size guard runs *before* any erase - the whole point of the guard. This is
# the sequence that once left the pad blank: mass erase, then a write that could
# not fit.
run_flash_with_image "mass erase refuses an image that does not fit" 1 \
    "$TMP_FLASH/two_sectors.bin" STLINK_MASS_ERASE=1 STUB_FLASH_SIZE_KB=128
expect_log "oversize refusal still happens first" "nothing was erased"
reject_log "nothing is mass erased" "mass erase"
if grep -q "erase" "$SFLASH_LOG" 2>/dev/null; then
    fail "nothing is mass erased (st-flash erase was called)"
else
    pass "nothing is mass erased"
fi

# The same knob on the OpenOCD path: `stm32h7x mass_erase 0` after a halt.
run_sflash "OpenOCD mass erase works too" 0 STLINK_BACKEND=ocd STLINK_MASS_ERASE=1
expect_log "OpenOCD mass erase is announced" "the board is blank until this flash ends"
expect_log "OpenOCD mass erase completes" "mass erase complete"
if grep -q "mass_erase" "$OCD_LOG" 2>/dev/null; then
    pass "mass_erase really reached OpenOCD"
else
    fail "mass_erase really reached OpenOCD"
fi

run_sflash "an OpenOCD mass erase that fails writes nothing" 4 STLINK_BACKEND=ocd \
    STLINK_MASS_ERASE=1 STUB_MASS_ERASE_FAIL=1
expect_log "failed mass erase is classified" "FLASH_FAILED erase"
reject_log "failed mass erase writes nothing" "flash write_image"
expect_log "the erased state is disclosed" "whole flash (mass erase)"

run_flash_with_image "st-info disagreement refuses the write" 1 \
    "$TMP_FLASH/two_sectors.bin" STUB_STINFO_FLASH_KB=128 STLINK_ALLOW_OVERSIZE=0
expect_log "st-info size is quoted" "st-info says 128 KiB"
reject_log "st-info refusal erases nothing" "erased address"
reject_log "st-info refusal writes nothing" "bytes written and verified"

# --------------------------------------------------------------- backend choice
run_sflash "STLINK_BACKEND=ocd keeps the OpenOCD path" 0 STLINK_BACKEND=ocd
expect_log "backend override is announced" "backend: ocd"
if grep -q "flash write_image" "$OCD_LOG" 2>/dev/null; then
    pass "OCD backend writes with OpenOCD"
else
    fail "OCD backend writes with OpenOCD"
fi

# No st-flash on PATH and no explicit backend: fall back, do not fail.
OUT="$(env PATH="$HERE/stubs:$PATH" STLINK_BACKEND=stflash \
    bash "$ROOT/tools/stlink_flash.sh" "$IMAGE_HEX" 2>&1)"
RC=$?
printf '%s' "$OUT" > "$TMP_FLASH/last.log"
if [ "$RC" = "1" ]; then
    pass "missing st-flash is a usage error when forced (exit 1)"
else
    fail "missing st-flash is a usage error when forced (exit $RC, wanted 1)"
fi
expect_log "the fix is spelled out" "stlink-tools"

# ------------------------------------------------------------ direct backend
# st-flash failed on the pad too ("Flash programming error: 0x00040000"), so a
# sector-0 image goes through tools/h7_direct/h7_robust_write.py. Stubbed here:
#   tests/stubs/direct/h7_robust_write.py
printf '\nFlash wrapper (direct backend)\n'
DIRECT_LOG="$TMP_FLASH/direct.log"
DIRECT_STUB="$HERE/stubs/direct/h7_robust_write.py"

run_direct() {  # run_direct <label> <want> [env...]
    rm -f "$DIRECT_LOG"
    local label="$1" want="$2"
    shift 2
    run_sflash "$label" "$want" STLINK_DIRECT_WRITER="$DIRECT_STUB" \
        STUB_DIRECT_LOG="$DIRECT_LOG" "$@"
}

run_direct "a sector-0 image goes to the direct writer" 0
expect_log "auto picks direct" "backend: direct"
expect_log "the writer finished" "ROBUST_WRITE_DONE"
expect_log "OpenOCD still verifies the readback" "Verified OK"
expect_log "FLASH_OK names the backend" "backend direct"
reject_log "st-flash is not used" "bytes written and verified"
if grep -q -- "--erase" "$DIRECT_LOG" 2>/dev/null; then
    fail "a clean sector is not erased first"
else
    pass "a clean sector is not erased first"
fi

run_direct "foreign data in sector 0 is erased, then written" 0 STUB_DIRECT_FOREIGN=1
expect_log "the erase is announced" "erasing it and writing again"
if [ "$(grep -c -- "--erase" "$DIRECT_LOG" 2>/dev/null)" = "1" ]; then
    pass "exactly one --erase run"
else
    fail "exactly one --erase run"
fi

run_direct "a writer that gives up fails the flash" 3 STUB_DIRECT_DIE=1
expect_log "the failure is classified" "FLASH_FAILED direct"
reject_log "a failed write is never released" "FLASH_OK"

run_direct "a writer that did not write fails the direct flash" 3 STUB_DIRECT_NOWRITE=1
expect_log "mismatch is reported" "FLASH_FAILED verify: two bulk readbacks agree"
reject_log "a real mismatch is never released" "FLASH_OK"

# The pad's dongle drops and shifts words in bulk reads; one bad bulk read must
# not overrule the writer's word-by-word readback.
run_direct "a bulk read that disagrees with itself does not fail the flash" 0 \
    STUB_DUMP_UNSTABLE=1
reject_log "an unstable readback is not called a mismatch" "FLASH_FAILED"

run_flash_with_image "direct refuses an image past sector 0" 1 \
    "$TMP_FLASH/two_sectors.bin" STLINK_BACKEND=direct \
    STLINK_DIRECT_WRITER="$DIRECT_STUB" STUB_DIRECT_LOG="$DIRECT_LOG"
expect_log "the limit is spelled out" "only knows sector 0"

run_flash_with_image "auto skips direct for a two-sector image" 0 \
    "$TMP_FLASH/two_sectors.bin" STLINK_DIRECT_WRITER="$DIRECT_STUB"
expect_log "auto falls back to st-flash" "backend: stflash"

# Per-session logs land in STLINK_LOG_DIR, named and readable.
mkdir -p "$TMP_FLASH/logs"
run_sflash "session logs are written" 0 STLINK_LOG_DIR="$TMP_FLASH/logs"
if [ -n "$(ls -A "$TMP_FLASH/logs" 2>/dev/null)" ]; then
    pass "session logs are written"
else
    fail "session logs are written"
fi

# ---------------------------------------------------------- recovery ladder
# tools/stlink_recover.sh writes with st-flash, falls back to CubeProgrammer and
# then to OpenOCD, and always judges the result by OpenOCD's readback.
printf '\nRecovery script (stubbed openocd + st-flash)\n'

if bash "$ROOT/tools/stlink_recover.sh" --help >/dev/null 2>&1; then
    pass "stlink_recover.sh --help"
else
    fail "stlink_recover.sh --help"
fi

run_recover() {  # run_recover <label> <expected-rc> [env assignments...]
    local label="$1" want="$2"
    shift 2
    local out rc
    rm -rf "$TMP_FLASH/mem"
    out="$(env PATH="$SFLASH_PATH:$PATH" STUB_MEM_DIR="$TMP_FLASH/mem" "$@" \
        bash "$ROOT/tools/stlink_recover.sh" "$IMAGE_BIN" 0x08000000 2>&1)"
    rc=$?
    printf '%s' "$out" > "$TMP_FLASH/last.log"
    if [ "$rc" = "$want" ]; then
        pass "$label (exit $rc)"
    else
        fail "$label (exit $rc, wanted $want)"
        printf '%s\n' "$out" | tail -20
    fi
}

run_recover "recovery writes with st-flash and verifies" 0
if grep -q "st-flash --connect-under-reset write" "$TMP_FLASH/last.log"; then
    pass "recovery prefers st-flash"
else
    fail "recovery prefers st-flash"
fi
if grep -q "RECOVER_OK" "$TMP_FLASH/last.log"; then
    pass "recovery reports RECOVER_OK"
else
    fail "recovery reports RECOVER_OK"
fi
reject_log "recovery never mass erases" "mass_erase"
reject_log "recovery never mass erases (st-flash)" "st-flash --connect-under-reset erase"

# st-flash failing every time falls through to the vendor tool (absent here) and
# then to OpenOCD, which dies in the loader on this fixture.
run_recover "recovery falls through to OpenOCD" 3 \
    STUB_STFLASH_DIE=write STUB_PROGRAM_FAIL=1 STLINK_RECOVER_TRIES=1
expect_log "fallback is announced" "LAST RESORT"
expect_log "every writer failed" "RECOVER_FAILED"

# A writer that claims success and a readback that disagrees is the one case
# that must never print OK.
run_recover "recovery trusts the readback, not the writer" 4 STUB_VERIFY_FAIL=1
expect_log "readback mismatch is named" "RECOVER_FAILED verify"

# No halt and no st-flash: refuse rather than write on a dead link.
OUT="$(env PATH="$HERE/stubs:$PATH" STUB_HALT_FAIL=1 STLINK_STFLASH=/nonexistent \
    bash "$ROOT/tools/stlink_recover.sh" "$IMAGE_BIN" 2>&1)"
RC=$?
printf '%s' "$OUT" > "$TMP_FLASH/last.log"
if [ "$RC" = "5" ]; then
    pass "no halt and no writer stops the recovery (exit 5)"
else
    fail "no halt and no writer stops the recovery (exit $RC, wanted 5)"
fi
expect_log "no-halt advice names the pogos" "jog forward"
reject_log "no write happens without a halt" "connect-under-reset write"

OUT="$(env PATH="$SFLASH_PATH:$PATH" STUB_MEM_DIR="$TMP_FLASH/mem" STUB_HALT_FAIL=1 \
    bash "$ROOT/tools/stlink_recover.sh" "$IMAGE_BIN" 2>&1)"
printf '%s' "$OUT" > "$TMP_FLASH/last.log"
if printf '%s' "$OUT" | grep -q "st-flash --connect-under-reset write"; then
    pass "a marginal link still tries st-flash (it resets itself)"
else
    fail "a marginal link still tries st-flash (it resets itself)"
fi

# --dry-run touches nothing at all.
OUT="$(env PATH="$SFLASH_PATH:$PATH" \
    bash "$ROOT/tools/stlink_recover.sh" --dry-run "$IMAGE_BIN" 2>&1)"
RC=$?
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "\[dry-run\]"; then
    pass "recovery --dry-run plans without writing"
else
    fail "recovery --dry-run plans without writing (exit $RC)"
fi

# ------------------------------------- verdicts are measurements, not exit codes
# The pad produced "131072/131072 bytes written" + PGSERR, an OpenOCD readback
# that failed with a bus error, and two dumps of the same range that disagreed.
# Each of those needs its own verdict, and none of them may erase anything.
printf '\nVerdicts, preflight and loader-RAM checks\n'

# st-info 1.8.0 prints BYTES: `flash: 1048576` for a 1 MiB part, `sram: 131072`.
run_sflash "st-info's byte count is converted, not multiplied" 0
expect_log "st-info size is reported in KiB" "st-info reports 1024 KiB"

run_sflash "a KiB-style st-info line still works" 0 STUB_STINFO_UNIT_KIB=1
expect_log "the KiB form parses to the same size" "st-info reports 1024 KiB"

# ---------------------------------------------------------------- preflight
run_sflash "two identical readbacks gate the flash" 0
expect_log "the preflight runs before anything else" "preflight: both readbacks match"

run_sflash "a link that corrupts reads is refused" 3 STUB_DUMP_UNSTABLE=1
expect_log "the disagreement is named" "two readbacks of the same range disagree"
expect_log "the corruption is located" "first difference at 0x8000010"
expect_log "nothing is erased" "nothing was erased"
if grep -q "connect-under-reset write" "$SFLASH_LOG" 2>/dev/null; then
    fail "an unstable readback writes nothing (st-flash write ran)"
else
    pass "an unstable readback writes nothing"
fi

run_sflash "a flash that cannot be read is refused" 3 STUB_DUMP_FAIL_AT=0x08000040
expect_log "an unreadable flash is not a mismatch" "cannot be read at all"
expect_log "the link is blamed, not the image" "the link is not usable"

# ------------------------------------------------------ loader RAM integrity
run_sflash "the loader RAM is tested with code-sized data" 0
expect_log "the RAM walk reports what held" "RAM integrity ok - AXI SRAM"

run_sflash "no usable loader RAM stops the flash" 2 \
    STUB_RAM_FAULT=0x20000000,0x24000000,0x30000000,0x38000000
expect_log "the verdict is about RAM" "no RAM region held a 4 KiB random block"
expect_log "the consequence is spelled out" "Nothing was erased"
expect_log "the power cycle is suggested" "power-cycle the pad"

# -------------------------------------------- erratum 3092511 is not a halt
run_sflash "a bogus halt is rejected" 4 STUB_BOGUS_HALT=1 STLINK_HALT_TRIES=1
expect_log "the erratum is named" "erratum 3092511"
expect_log "the workaround is named" "STLINK_BACKEND=stflash"
reject_log "a bogus halt never reaches the flash" "FLASH_OK"

# ------------------------------------------------------------- blank check
run_sflash "the erase is checked for real blanking" 0 STLINK_MASS_ERASE=1
expect_log "the blank check runs" "blank check:"

run_sflash "an erase that leaves a byte is caught" 4 STLINK_MASS_ERASE=1 \
    STUB_ERASE_INCOMPLETE=1
expect_log "the incomplete erase is named" "did not read back as erased"
expect_log "PGSERR is explained" "PGSERR"
if grep -q "connect-under-reset write" "$SFLASH_LOG" 2>/dev/null; then
    fail "nothing is written after a failed blank check"
else
    pass "nothing is written after a failed blank check"
fi

# ------------------------------------------------- what the flash really holds
run_sflash "a partial program is measured, not guessed" 3 STUB_STFLASH_PARTIAL=0x100
expect_log "the damage is counted" "the flash holds"
expect_log "the count is against the whole image" "of 1280 bytes of this image"
expect_log "the first difference is located" "first difference at 0x8000100"
expect_log "the state is named" "PARTIALLY written"
expect_log "it is a failure" "FLASH_FAILED"

run_sflash "a writer that lies about a good flash is not a failure" 0 \
    STUB_STFLASH_PGSERR=1
expect_log "the lie is named" "st-flash reported failure, but the readback matches"
expect_log "the flash is still OK" "FLASH_OK"

# ------------------------------------------------------- st-flash knobs
run_sflash "st-flash frequency and size reach the command" 0 \
    STLINK_STFLASH_FREQ=25k STLINK_STFLASH_FLASH=1M
if grep -q -- "--freq=25k" "$SFLASH_LOG" 2>/dev/null &&
    grep -q -- "--flash=1M" "$SFLASH_LOG" 2>/dev/null; then
    pass "st-flash gets --freq and --flash"
else
    fail "st-flash gets --freq and --flash"
fi
expect_log "the label reports the clock" "freq 25k"

run_sflash "plain attach is available" 0 STLINK_STFLASH_CONNECT=plain
if grep -q "connect-under-reset" "$SFLASH_LOG" 2>/dev/null; then
    fail "plain attach omits --connect-under-reset"
else
    pass "plain attach omits --connect-under-reset"
fi

rm -rf "$TMP_FLASH"

# ---------------------------------------------------------------- summary
printf '\n--------------------\n'
printf '%s checks, %s failure(s)\n' "$CHECKS" "$FAILED"

[ "$FAILED" = "0" ] || exit 1
