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

rm -rf "$TMP_FLASH"

# ---------------------------------------------------------------- summary
printf '\n--------------------\n'
printf '%s checks, %s failure(s)\n' "$CHECKS" "$FAILED"

[ "$FAILED" = "0" ] || exit 1
