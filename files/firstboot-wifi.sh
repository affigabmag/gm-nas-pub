#!/usr/bin/env bash
# ============================================================================
# gm-nas first-boot WiFi provisioning wrapper (verbose logging)
# ----------------------------------------------------------------------------
# Runs at boot via homenas-firstboot.service. If not provisioned, it starts
# wifi-connect (a WiFi AP + captive portal). Because this hardware can't switch
# AP->client live, we DON'T rely on wifi-connect's join: as soon as the user's
# WiFi profile appears we mark provisioned and REBOOT (clean client connect).
#
# Logs everything to /var/log/gm-nas/firstboot-wifi.log
# ============================================================================
set -uo pipefail

LOGDIR=/var/log/gm-nas
LOG="$LOGDIR/firstboot-wifi.log"
mkdir -p "$LOGDIR" 2>/dev/null || true
log() { printf '%s [firstboot] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }

FLAG=/etc/homenas/provisioned
PORTAL_SSID="GMNas-Setup"
PORTAL_PASSPHRASE="gmnas2026"
UI_DIR="/usr/local/lib/wifi-connect/ui"
WIFI_CONNECT="/usr/local/lib/wifi-connect/wifi-connect"

log "=============== firstboot-wifi start ==============="
log "flag=$FLAG  wifi_connect=$WIFI_CONNECT  ui=$UI_DIR"

if [ -f "$FLAG" ]; then
    log "already provisioned -> exit 0"
    exit 0
fi

log "waiting 5s for NetworkManager radios..."
sleep 5

log "connectivity state: $(nmcli -t -f STATE g 2>/dev/null)"
log "devices: $(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | tr '\n' ' ')"

if nmcli -t -f STATE g 2>/dev/null | grep -q '^connected$'; then
    log "already online -> mark provisioned + exit"
    mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"
    exit 0
fi

if ! nmcli -t -f TYPE device 2>/dev/null | grep -q '^wifi$'; then
    log "NO wifi device found -> skip setup AP, exit 0"
    exit 0
fi

WIFI_DEV="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
log "wifi device: $WIFI_DEV"
log "wifi-connect binary: $(ls -l "$WIFI_CONNECT" 2>&1)"
log "ui index: $(ls -l "$UI_DIR/index.html" 2>&1)"

wifi_profiles() {
    nmcli -t -f NAME,TYPE connection show 2>/dev/null \
        | awk -F: '$2 ~ /wireless/ && $1 !~ /GMNas-Setup|Hotspot|wifi-connect/ {print $1}' | sort
}
BEFORE="$(wifi_profiles)"
log "existing wifi profiles before portal: [$(echo "$BEFORE" | tr '\n' ',')]"

log "launching wifi-connect (AP '$PORTAL_SSID', portal on :80)..."
"$WIFI_CONNECT" \
    --portal-ssid "$PORTAL_SSID" \
    --portal-passphrase "$PORTAL_PASSPHRASE" \
    --ui-directory "$UI_DIR" >>"$LOG" 2>&1 &
WC_PID=$!
log "wifi-connect started, pid=$WC_PID"

# Give it a moment then log the AP state so we can see if the portal is up.
sleep 8
log "post-start device status: $(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | tr '\n' ' ')"
log "post-start addresses: $(ip -brief a 2>/dev/null | tr '\n' ' ')"
log "listening on :80? $(ss -ltnp 2>/dev/null | grep ':80 ' || echo none)"
log "wifi-connect alive? $(kill -0 "$WC_PID" 2>/dev/null && echo yes || echo NO-it-exited)"

log "watching for the user's WiFi selection (up to ~20 min)..."
for _ in $(seq 1 600); do
    if ! kill -0 "$WC_PID" 2>/dev/null; then
        log "wifi-connect process exited on its own"
        break
    fi
    NEW="$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$(wifi_profiles)"))"
    if [ -n "$NEW" ]; then
        log "NEW wifi profile detected: [$(echo "$NEW" | tr '\n' ',')] -> provisioning + reboot"
        printf '%s\n' "$NEW" | while read -r c; do
            [ -n "$c" ] && nmcli connection modify "$c" connection.autoconnect yes 2>/dev/null || true
        done
        mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"
        kill "$WC_PID" 2>/dev/null || true
        sleep 3
        log "rebooting now"
        systemctl reboot
        exit 0
    fi
    sleep 2
done

if nmcli -t -f STATE g 2>/dev/null | grep -q '^connected$'; then
    log "connected after wifi-connect exit -> provisioning + reboot"
    mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"; sleep 3
    log "provisioned -> rebooting now"
    systemctl reboot
    exit 0
fi
log "firstboot-wifi finished without provisioning (exit 0)"
exit 0
