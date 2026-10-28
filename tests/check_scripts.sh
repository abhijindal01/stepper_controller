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

# ---------------------------------------------------------------- summary
printf '\n--------------------\n'
printf '%s checks, %s failure(s)\n' "$CHECKS" "$FAILED"

[ "$FAILED" = "0" ] || exit 1
