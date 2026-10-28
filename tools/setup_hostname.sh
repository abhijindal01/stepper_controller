#!/usr/bin/env bash
#
# Publish the stepper dashboard under a stable name instead of a raw IP.
#
#       http://<hostname>.local:<port>/      (mDNS / Bonjour)
#
# Run this ON the Raspberry Pi:
#
#     sudo bash tools/setup_hostname.sh                 # keep the current name
#     sudo bash tools/setup_hostname.sh --hostname assurance
#     sudo bash tools/setup_hostname.sh --dry-run       # show, change nothing
#
# It is idempotent and safe to re-run. It:
#   1. sets the system hostname (if you asked for a different one)
#   2. keeps /etc/hosts consistent (127.0.1.1 <name>)
#   3. installs and starts avahi-daemon so <name>.local resolves over mDNS
#   4. advertises the dashboard as _http._tcp so it shows up in network browsing
#   5. opens the dashboard port in ufw, when ufw is enabled
#   6. verifies the name actually resolves and the dashboard answers
#
# mDNS only works on the local network. For access from another subnet, VPN or
# Windows with "secure DNS" on, see docs/NETWORK_ACCESS.md.

set -u

PORT="${PORT:-5000}"
SERVICE_NAME="${SERVICE_NAME:-stepper_controller.service}"
AVAHI_FILE="/etc/avahi/services/stepper-controller.service"
HOSTS_FILE="/etc/hosts"

WANT_HOSTNAME=""
DRY_RUN=0
SKIP_AVAHI=0
SKIP_FIREWALL=0

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --hostname)      WANT_HOSTNAME="${2:-}"; shift 2 ;;
        --port)          PORT="${2:-}"; shift 2 ;;
        --skip-avahi)    SKIP_AVAHI=1; shift ;;
        --skip-firewall) SKIP_FIREWALL=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

run() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '   [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

if [ "$DRY_RUN" != "1" ] && [ "$(id -u)" != "0" ]; then
    say "Run this with sudo:  sudo bash tools/setup_hostname.sh"
    exit 1
fi

CURRENT="$(hostname -s 2>/dev/null || hostname)"
TARGET="${WANT_HOSTNAME:-$CURRENT}"

say "Stepper dashboard name setup"
say "  current hostname : $CURRENT"
say "  target hostname  : $TARGET"
say "  dashboard port   : $PORT"

# ---------------------------------------------------------------- 1. hostname
step "1/6 hostname"

if [ "$TARGET" != "$CURRENT" ]; then
    if command -v hostnamectl >/dev/null 2>&1; then
        run hostnamectl set-hostname "$TARGET"
    else
        run hostname "$TARGET"
        if [ "$DRY_RUN" != "1" ]; then
            echo "$TARGET" > /etc/hostname
        else
            printf '   [dry-run] write %s to /etc/hostname\n' "$TARGET"
        fi
    fi
    if [ "$DRY_RUN" = "1" ]; then
        say "   would set the hostname to $TARGET"
    else
        say "   hostname set to $TARGET"
    fi
else
    say "   already $TARGET - nothing to do"
fi

# ---------------------------------------------------------------- 2. /etc/hosts
step "2/6 /etc/hosts"

if grep -qE "^[[:space:]]*127\.0\.1\.1[[:space:]]+$TARGET([[:space:]]|$)" "$HOSTS_FILE" 2>/dev/null; then
    say "   127.0.1.1 $TARGET already present"
else
    if [ "$DRY_RUN" = "1" ]; then
        printf '   [dry-run] append "127.0.1.1 %s" to %s\n' "$TARGET" "$HOSTS_FILE"
    else
        printf '127.0.1.1\t%s\n' "$TARGET" >> "$HOSTS_FILE"
        say "   added 127.0.1.1 $TARGET"
    fi
fi

# ---------------------------------------------------------------- 3. avahi
step "3/6 mDNS (avahi-daemon)"

if [ "$SKIP_AVAHI" = "1" ]; then
    say "   skipped (--skip-avahi)"
else
    if ! command -v avahi-daemon >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1 && [ "$DRY_RUN" != "1" ]; then
            say "   installing avahi-daemon + libnss-mdns ..."
            apt-get update -qq >/dev/null 2>&1 || true
            if ! apt-get install -y -qq avahi-daemon libnss-mdns; then
                say "   install failed - is the Pi online? retry later."
            fi
        else
            printf '   [dry-run] would install avahi-daemon libnss-mdns\n'
        fi
    fi

    if command -v avahi-daemon >/dev/null 2>&1 || [ "$DRY_RUN" = "1" ]; then
        run systemctl enable --now avahi-daemon
        if [ "$DRY_RUN" = "1" ]; then
            say "   would enable and start avahi-daemon"
        else
            say "   avahi-daemon enabled and started"
        fi
    fi
fi

# ------------------------------------------------- 4. service advertisement
step "4/6 advertise the dashboard (_http._tcp)"

AVAHI_XML="<?xml version=\"1.0\" standalone='no'?><!--*-nxml-*-->
<!DOCTYPE service-group SYSTEM \"avahi-service.dtd\">
<service-group>
  <name replace-wildcards=\"yes\">Stepper Controller on %h</name>
  <service>
    <type>_http._tcp</type>
    <port>$PORT</port>
    <txt-record>path=/</txt-record>
  </service>
</service-group>"

if [ "$SKIP_AVAHI" = "1" ]; then
    say "   skipped (--skip-avahi)"
elif [ "$DRY_RUN" = "1" ]; then
    printf '   [dry-run] write %s (port %s)\n' "$AVAHI_FILE" "$PORT"
else
    mkdir -p "$(dirname "$AVAHI_FILE")"
    printf '%s\n' "$AVAHI_XML" > "$AVAHI_FILE"
    say "   wrote $AVAHI_FILE"
    systemctl restart avahi-daemon 2>/dev/null || true
fi

# ---------------------------------------------------------------- 5. firewall
step "5/6 firewall"

if [ "$SKIP_FIREWALL" = "1" ]; then
    say "   skipped (--skip-firewall)"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    run ufw allow "$PORT"/tcp
    run ufw allow 5353/udp
    say "   allowed $PORT/tcp (dashboard) and 5353/udp (mDNS)"
else
    say "   ufw not active - nothing to open"
fi

# ---------------------------------------------------------------- 6. verify
step "6/6 verify"

if [ "$DRY_RUN" = "1" ]; then
    printf '   [dry-run] getent hosts %s\n' "$TARGET"
    printf '   [dry-run] avahi-resolve -n %s.local\n' "$TARGET"
    printf '   [dry-run] curl -m 3 -o /dev/null -w %%{http_code} http://127.0.0.1:%s/login\n' "$PORT"
    say ""
    say "Dry run only - nothing was changed."
    exit 0
fi

say "   /etc/hosts     : $(getent hosts "$TARGET" | head -1 || echo 'not found')"

if command -v avahi-resolve >/dev/null 2>&1; then
    RESOLVED="$(avahi-resolve -n "$TARGET.local" 2>/dev/null || true)"
    say "   mDNS           : ${RESOLVED:-$TARGET.local did not answer (avahi starting up?)}"
else
    say "   mDNS           : avahi-utils not installed (avahi-resolve missing)"
fi

CODE="$(curl -m 3 -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/login" 2>/dev/null || true)"
say "   dashboard      : http://127.0.0.1:$PORT/login -> ${CODE:-no answer}"

if [ "$CODE" != "200" ]; then
    say ""
    say "   The dashboard did not answer. Check it first:"
    say "     systemctl status $SERVICE_NAME --no-pager"
    say "     journalctl -u $SERVICE_NAME -n 30 --no-pager"
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

say ""
say "----------------------------------------------------------------"
say "Open one of these:"
say "  http://$TARGET.local:$PORT/login"
[ -n "$IP" ] && say "  http://$IP:$PORT/login"
say ""
say "If <name>.local fails on a Windows/Chrome client, that is the client,"
say "not the Pi - see docs/NETWORK_ACCESS.md. Short version:"
say "  * Chrome -> Settings -> Privacy -> turn OFF 'Use secure DNS'"
say "  * or add to C:\\Windows\\System32\\drivers\\etc\\hosts:"
[ -n "$IP" ] && say "        $IP  $TARGET.local $TARGET"
say "  * or use the Tailscale name/IP if the client is on the tailnet"
say "----------------------------------------------------------------"
