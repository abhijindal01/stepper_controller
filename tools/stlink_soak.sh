#!/bin/bash
# Measure ST-LINK/SWD link health before blaming the flash tooling.
#
# Opens N independent OpenOCD sessions and, in each one, checks the two things
# that keep failing on the IndiH743 pogo fixture:
#
#   1. connect + examine        (SWD DPIDR, stm32h7x.cpu0 Examination succeed)
#   2. AP traffic + halt        (`halt` accepted and DHCSR.S_HALT read back)
#
# A pass rate below the threshold means the harness is marginal - pogo
# contact, GND return, SWCLK/SWDIO integrity or target power - and a flash on
# that link will fail no matter which RAM region or speed it uses.
#
#   tools/stlink_soak.sh                 # 20 attempts, needs >= 90 %
#   tools/stlink_soak.sh 50 --min 95     # 50 attempts, needs >= 95 %
#   STLINK_SPEED=25 tools/stlink_soak.sh # soak at a different SWD speed
#
# Exit codes: 0 link healthy, 1 below threshold, 2 no ST-LINK / cannot run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CFG="${ROOT}/openocd_fixture.cfg"
PY="${ROOT}/../venv/bin/python3"
[[ -x "$PY" ]] || PY=python3

COUNT="${1:-${STLINK_SOAK_N:-20}}"
MIN_PCT="${STLINK_SOAK_MIN_PCT:-90}"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --min) MIN_PCT="${2:-90}"; shift 2 ;;
    --count) COUNT="${2:-20}"; shift 2 ;;
    --speed) export STLINK_SPEED="${2:-50}"; shift 2 ;;
    *) shift ;;
  esac
done

exec "$PY" - "$COUNT" "$MIN_PCT" "$CFG" <<'PY'
import os
import re
import subprocess
import sys
import time

count = max(1, int(sys.argv[1]))
min_pct = float(sys.argv[2])
cfg = sys.argv[3]

OPENOCD = os.environ.get("OPENOCD") or "openocd"
SPEED = os.environ.get("STLINK_SPEED") or "50"
GAP = float(os.environ.get("STLINK_SOAK_GAP") or "1.0")

DHCSR = 0xE000EDF0


def one_session() -> tuple[bool, str, str]:
    """Return (ok, kind, text) for a single connect+halt attempt."""
    cmd = [
        OPENOCD,
        "-f",
        cfg,
        "-c",
        f"init; adapter speed {SPEED}; halt",
        "-c",
        "catch {mww 0xe0002000 0x00000000}",  # AP write into FPB: link proof
        "-c",
        f"mdw {DHCSR:#x}",
        "-c",
        "exit",
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        sys.stderr.write(f"{OPENOCD}: not found\n")
        raise SystemExit(2)
    except subprocess.TimeoutExpired:
        return False, "timeout", "openocd timed out"
    text = (proc.stdout or "") + (proc.stderr or "")
    low = text.lower()

    if "init mode failed" in low or "unable to connect" in low:
        return False, "connect", text
    if re.search(r"failed to (?:write|read) memory at 0xe0[0-9a-f]{5}", low):
        return False, "ap", text
    if "ctlr/stat" in low or "force reconnect" in low:
        return False, "swd", text
    m = None
    for m in re.finditer(r"0xe000edf0:\s*([0-9a-f]{8})", low):
        pass
    if m is None:
        return False, "nodhcsr", text
    if not (int(m.group(1), 16) & (1 << 17)):
        return False, "nohalt", text
    if "examination succeed" not in low:
        return False, "examine", text
    return True, "ok", text


print(
    f"link soak: {count} sessions @ {SPEED} kHz, threshold {min_pct:.0f} %",
    flush=True,
)
counts: dict[str, int] = {}
passed = 0
first_bad = ""
started = time.monotonic()

for n in range(1, count + 1):
    ok, kind, text = one_session()
    counts[kind] = counts.get(kind, 0) + 1
    if ok:
        passed += 1
        print(f"  {n}/{count}  ok", flush=True)
    else:
        if not first_bad:
            first_bad = text
        print(f"  {n}/{count}  FAIL ({kind})", flush=True)
    if n < count:
        time.sleep(GAP)

rate = 100.0 * passed / count
elapsed = time.monotonic() - started
print(f"pass rate: {passed}/{count} = {rate:.0f} % in {elapsed:.1f}s", flush=True)

bad = {k: v for k, v in counts.items() if k != "ok"}
if bad:
    print("failures: " + ", ".join(f"{k}={v}" for k, v in sorted(bad.items())), flush=True)

verdict_ok = rate >= min_pct
if verdict_ok:
    print("LINK_OK: link is healthy enough to flash", flush=True)
    raise SystemExit(0)

sys.stderr.write("LINK_UNHEALTHY: the SWD link is marginal - do not flash yet\n")
triage = {
    "connect": "connect/examine fails: pogo contact, target power, SWCLK/SWDIO",
    "ap": "core debug registers unreachable: GND return or contact resistance",
    "swd": "link drops mid-session: contact, GND return, ST-LINK USB/power",
    "nohalt": "halt not accepted: the app keeps running (IWDG), try reset halt",
    "nodhcsr": "DHCSR unreadable: the session died before it could be read",
    "examine": "examine did not complete: floating SWDIO, marginal contact",
    "timeout": "OpenOCD hung: ST-LINK USB stall or target in reset loop",
}
for kind, n in sorted(bad.items()):
    sys.stderr.write(f"  {kind} x{n}: {triage.get(kind, 'see OpenOCD log')}\n")
sys.stderr.write(
    "  fixes: second/short GND pogo, bench supply to the pad, powered USB hub "
    "for the ST-LINK, STLINK_SPEED=25, steppers de-energised\n"
)
if first_bad:
    sys.stderr.write("--- first failing session ---\n")
    sys.stderr.write(first_bad[-2000:])
raise SystemExit(1)
PY
