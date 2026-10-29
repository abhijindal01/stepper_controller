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
# OpenOCD that models the H7 RAM/bank behaviour. STUB_RAM_FAULT=0x20000000
# reproduces the reported failure: DTCM (OpenOCD's default work area) does
# not answer SWD writes, so the flash loader can never be downloaded.
printf '\nFlash wrapper (stubbed openocd)\n'

if bash "$ROOT/tools/stlink_flash.sh" --help >/dev/null 2>&1; then
    pass "stlink_flash.sh --help"
else
    fail "stlink_flash.sh --help"
fi

TMP_FLASH="$(mktemp -d)"
IMAGE_HEX="$TMP_FLASH/combined.hex"
IMAGE_BIN="$TMP_FLASH/combined.bin"

python3 - "$IMAGE_BIN" "$IMAGE_HEX" <<'PY'
import sys

bl = bytes(0x40)
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

# Healthy target: the loader must end up in AXI SRAM, not DTCM.
run_flash "flash uses a writable work area" 0 STUB_OPENOCD_LOG="$TMP_FLASH/ocd.log"
if grep -q "work-area-phys 0x24000000" "$TMP_FLASH/ocd.log" 2>/dev/null; then
    pass "flash configures the AXI SRAM work area"
else
    fail "flash configures the AXI SRAM work area"
fi
if grep -q "FLASH_OK" "$TMP_FLASH/last.log"; then
    pass "flash reports FLASH_OK"
else
    fail "flash reports FLASH_OK"
fi
if grep -q "0x20000000" "$TMP_FLASH/ocd.log" 2>/dev/null; then
    fail "flash never touches the DTCM work area"
else
    pass "flash never touches the DTCM work area"
fi

# The reported bug: DTCM dead -> flashing must still succeed via AXI SRAM.
run_flash "flash survives dead DTCM" 0 STUB_RAM_FAULT=0x20000000

# AXI SRAM dead too -> fall back to SRAM1, then SRAM4.
run_flash "flash falls back to SRAM1" 0 STUB_RAM_FAULT=0x20000000,0x24000000
run_flash "flash falls back to SRAM4" 0 \
    STUB_RAM_FAULT=0x20000000,0x24000000,0x30000000

# Forced bad work area must fail fast with a clear message, not retry blindly.
run_flash "forced dead work area fails" 2 \
    STUB_RAM_FAULT=0x20000000,0x24000000,0x30000000,0x38000000 \
    STLINK_WORKAREA=0x24000000
if grep -q "not writable" "$TMP_FLASH/last.log"; then
    pass "dead work area reports why"
else
    fail "dead work area reports why"
fi

# No SWD contact at all.
run_flash "no SWD contact is reported" 2 STUB_SWD_FAIL=1
if grep -q "no writable RAM" "$TMP_FLASH/last.log"; then
    pass "no SWD contact says no writable RAM"
else
    fail "no SWD contact says no writable RAM"
fi

# Guard rail: a .bin with an impossible base must be refused before any write.
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
