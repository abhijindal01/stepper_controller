#!/usr/bin/env bash
#
# One-shot health report for the stepper dashboard.
#
#     bash tools/diagnose.sh                 # normal run
#     sudo bash tools/diagnose.sh            # adds process names + kernel log
#     bash tools/diagnose.sh --port 5000 --service stepper_controller.service
#
# Prints a verdict at the end. Nothing is changed.
#
# It answers, in order:
#   * is the service running, and has it been crashing?
#   * is anything listening, and does the dashboard actually answer?
#   * does the hostname resolve (local, .local, LAN IP)?
#   * are both Arduinos present, and which board is where?
#   * is the Pi throttling, and did USB drop a board?
#   * what is each board's driver/heat state (when the service is stopped)?

set -u

PORT="${PORT:-5000}"
SERVICE="${SERVICE:-stepper_controller.service}"
MOTOR1="${MOTOR1:-/dev/stepper_a}"
MOTOR2="${MOTOR2:-/dev/stepper_b}"

PROBLEMS=0
NOTES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --port)    PORT="${2:-}"; shift 2 ;;
        --service) SERVICE="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

section() { printf '\n===== %s\n' "$*"; }
row()     { printf '  %-22s %s\n' "$1" "$2"; }
bad()     { PROBLEMS=$((PROBLEMS + 1)); NOTES+=("$1"); }

HAS_SYSTEMD=0
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    HAS_SYSTEMD=1
fi

HOST="$(hostname -s 2>/dev/null || hostname)"
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

section "system"
row "hostname" "$HOST"
row "addresses" "$(hostname -I 2>/dev/null || echo '?')"
row "uptime" "$(uptime -p 2>/dev/null || uptime)"
row "kernel" "$(uname -r)"

if command -v vcgencmd >/dev/null 2>&1; then
    THROTTLED="$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)"
    row "throttled" "$THROTTLED"
    if [ "$THROTTLED" != "0x0" ]; then
        bad "Pi is throttled ($THROTTLED) - power supply or cooling"
    fi
else
    row "throttled" "(vcgencmd not available)"
fi

section "service ($SERVICE)"
if [ "$HAS_SYSTEMD" = "0" ]; then
    row "systemd" "not available (not a systemd host, or a container)"
else
    STATE="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    ENABLED="$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
    RESTARTS="$(systemctl show -p NRestarts --value "$SERVICE" 2>/dev/null || echo '?')"
    SINCE="$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE" 2>/dev/null || echo '?')"

    row "active" "${STATE:-unknown}"
    row "enabled at boot" "${ENABLED:-unknown}"
    row "restarts" "${RESTARTS:-?}"
    row "active since" "${SINCE:-?}"

    [ "$STATE" = "active" ] || bad "service ${STATE:-is not running} - check: systemctl status $SERVICE"

    case "${RESTARTS:-x}" in
        ''|*[!0-9]*) : ;;                       # unknown, do not guess
        0) : ;;
        *) NOTES+=("service has restarted $RESTARTS time(s) - look for a traceback") ;;
    esac

    ERRORS="$(journalctl -u "$SERVICE" -n 400 --no-pager 2>/dev/null | grep -cE 'Traceback|Error|Exception|Killed' || true)"
    row "error lines (last 400)" "${ERRORS:-0}"
    if [ "${ERRORS:-0}" != "0" ]; then
        bad "errors in the journal - run: journalctl -u $SERVICE -n 60 --no-pager"
    fi
fi

section "port $PORT"
LISTEN="$(ss -tln 2>/dev/null | awk -v p=":$PORT" '$4 ~ p {print $4}' | head -3)"
row "listening on" "${LISTEN:-nothing}"
[ -n "$LISTEN" ] || bad "nothing is listening on port $PORT"

HTTP_LOCAL="$(curl -m 3 -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/login" 2>/dev/null || true)"
row "127.0.0.1" "${HTTP_LOCAL:-no answer}"
[ "$HTTP_LOCAL" = "200" ] || bad "dashboard does not answer on 127.0.0.1:$PORT"

if [ -n "$IP" ]; then
    HTTP_IP="$(curl -m 3 -s -o /dev/null -w '%{http_code}' "http://$IP:$PORT/login" 2>/dev/null || true)"
    row "LAN IP ($IP)" "${HTTP_IP:-no answer}"
fi

HTTP_NAME="$(curl -m 3 -s -o /dev/null -w '%{http_code}' "http://$HOST.local:$PORT/login" 2>/dev/null || true)"
row "$HOST.local" "${HTTP_NAME:-no answer}"
if [ "$HTTP_NAME" != "200" ]; then
    NOTES+=("http://$HOST.local:$PORT did not answer from the Pi - check avahi: systemctl status avahi-daemon")
fi

section "hostname / mDNS"
HOSTS_ROW="$(getent hosts "$HOST" 2>/dev/null | head -1)"
row "/etc/hosts" "${HOSTS_ROW:-no entry for $HOST}"
[ -n "$HOSTS_ROW" ] || NOTES+=("/etc/hosts has no entry for $HOST - run: sudo bash tools/setup_hostname.sh")

MDNS_ROW="$(getent hosts "$HOST.local" 2>/dev/null | head -1)"
row "getent .local" "${MDNS_ROW:-not resolved locally (nss-mdns may be missing)}"

if command -v avahi-resolve >/dev/null 2>&1; then
    row "avahi-resolve" "$(avahi-resolve -n "$HOST.local" 2>/dev/null || echo 'no answer')"
else
    row "avahi-resolve" "not installed (apt install avahi-utils)"
fi

if [ "$HAS_SYSTEMD" = "1" ]; then
    row "avahi-daemon" "$(systemctl is-active avahi-daemon 2>/dev/null || echo 'unknown')"
fi

section "Arduinos"
for dev in "$MOTOR1" "$MOTOR2"; do
    if [ -e "$dev" ]; then
        REAL="$(readlink -f "$dev" 2>/dev/null || echo '?')"
        SOCKET="$(udevadm info -q path -n "$dev" 2>/dev/null | tr '/' '\n' | grep -E '^[0-9]+-[0-9]+' | tail -1)"
        row "$(basename "$dev")" "-> $(basename "$REAL") on USB $SOCKET"
    else
        row "$(basename "$dev")" "MISSING"
        bad "$dev is missing - board unplugged, or udev rules need re-running (sudo bash tools/setup_udev.sh)"
    fi
done

ACMS="$(ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null | wc -l)"
row "serial devices" "$ACMS"

section "USB stability"
DROPS="$(journalctl -k -b --no-pager 2>/dev/null | grep -ciE 'USB disconnect' || true)"
UNDERVOLT="$(journalctl -k -b --no-pager 2>/dev/null | grep -ciE 'under-voltage|over-current' || true)"
row "disconnects (boot)" "${DROPS:-0}"
row "power warnings" "${UNDERVOLT:-0}"
if [ "${DROPS:-0}" != "0" ]; then
    NOTES+=("$DROPS USB disconnect(s) this boot - that is what makes both motors vanish; check hub/cabling")
fi
if [ "${UNDERVOLT:-0}" != "0" ]; then
    bad "under-voltage/over-current in the kernel log - replace the PSU or use a powered hub"
fi

section "driver / heat state"
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    row "boards" "service holds the serial ports"
    row "to inspect" "sudo systemctl stop $SERVICE && venv/bin/python tools/check_boards.py"
else
    if [ -f tools/check_boards.py ]; then
        PY=""
        for candidate in venv/bin/python python3 python; do
            if command -v "$candidate" >/dev/null 2>&1 \
                    && "$candidate" -c "import serial" >/dev/null 2>&1; then
                PY="$candidate"
                break
            fi
        done

        if [ -n "$PY" ]; then
            "$PY" tools/check_boards.py 2>&1 | sed 's/^/  /' || true
        else
            row "checker" "needs pyserial: venv/bin/pip install -r requirements.txt"
        fi
    else
        row "checker" "tools/check_boards.py not found"
    fi
fi

section "verdict"
if [ "$PROBLEMS" -eq 0 ]; then
    printf '  No hard failures found.\n'
else
    printf '  %s problem(s):\n' "$PROBLEMS"
fi

if [ "${#NOTES[@]}" -gt 0 ]; then
    printf '\n  notes:\n'
    for note in "${NOTES[@]}"; do printf '   - %s\n' "$note"; done
fi

printf '\n  Useful next commands:\n'
printf '    journalctl -u %s -n 60 --no-pager\n' "$SERVICE"
printf '    sudo systemctl restart %s\n' "$SERVICE"
printf '    sudo bash tools/setup_hostname.sh\n'
printf '    docs/NETWORK_ACCESS.md   (why a name might fail on the client)\n'
