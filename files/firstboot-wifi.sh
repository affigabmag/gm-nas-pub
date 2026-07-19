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

# -------------------------------------------------------------------------
# DECISION IS CONNECTIVITY-BASED (not the provisioned flag): run the WiFi
# wizard whenever the box has no active network. A headless box (no keyboard/
# screen) that loses its saved WiFi (wrong password, moved home, router
# replaced) must ALWAYS be able to fall back to the setup AP so it can be
# reconfigured from a phone. The user may power-cycle freely; every boot
# re-evaluates connectivity.
# -------------------------------------------------------------------------
# Decision is based on WIFI specifically — a wired tether/Ethernet (used during
# install) must NOT count as "provisioned", or the setup AP never appears.
wifi_connected() {
    nmcli -t -f TYPE,STATE device status 2>/dev/null | grep -q '^wifi:connected'
}
saved_wifi() {
    nmcli -t -f NAME,TYPE connection show 2>/dev/null \
        | awk -F: '$2 ~ /wireless/ && $1 !~ /GMNas-Setup|Hotspot|wifi-connect/ {print $1}' | grep -q .
}

if saved_wifi; then
    # A home network is configured — give it up to ~60s to auto-connect before
    # falling back to the setup AP (tolerates brief router outages).
    log "saved WiFi found — waiting up to ~60s for it to connect..."
    CONNECTED=no
    for i in $(seq 1 12); do
        if wifi_connected; then CONNECTED=yes; break; fi
        log "  [$i/12] no active WiFi yet — waiting 5s..."
        sleep 5
    done
    if [ "$CONNECTED" = yes ]; then
        log "WiFi is UP -> normal boot (mark provisioned), no wizard"
        mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"
        exit 0
    fi
    log "saved WiFi did not connect -> launching setup AP"
else
    # Fresh box / no home network yet — launch the setup AP immediately
    # (no point waiting 60s for a network that doesn't exist).
    log "no saved WiFi -> launching setup AP right away"
fi
log "devices: $(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | tr '\n' ' ')"

log "NO active network after wait -> (re)running the first-time WiFi wizard"
# Offline: treat the box as needing setup again so the welcome app (gated on
# this flag) stays down while the setup AP owns port 80.
rm -f "$FLAG" 2>/dev/null || true
# The welcome app may have already grabbed :80 on a stale flag — free it so
# wifi-connect's captive portal can bind.
systemctl stop gmnas-welcome.service 2>/dev/null || true

if ! nmcli -t -f TYPE device 2>/dev/null | grep -q '^wifi$'; then
    log "NO wifi device found -> cannot start setup AP, exit 0"
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
        log "NEW wifi profile detected: [$(echo "$NEW" | tr '\n' ',')] -> provisioning"
        FIRST_NEW="$(printf '%s\n' "$NEW" | head -1)"
        # Make the user's network the top-priority autoconnect on boot.
        printf '%s\n' "$NEW" | while read -r c; do
            [ -n "$c" ] && nmcli connection modify "$c" \
                connection.autoconnect yes connection.autoconnect-priority 100 2>/dev/null || true
        done
        # Stop wifi-connect so it releases the radio + tears down the AP.
        kill "$WC_PID" 2>/dev/null || true
        sleep 3
        # CRITICAL: delete the setup-AP profile(s) so they cannot re-broadcast
        # on reboot and steal the radio from the user's network.
        nmcli -t -f NAME,TYPE connection show 2>/dev/null \
            | awk -F: '$2 ~ /wireless/ && $1 ~ /GMNas-Setup|Hotspot|wifi-connect/ {print $1}' \
            | while read -r ap; do
                [ -n "$ap" ] && { nmcli connection delete "$ap" 2>/dev/null && log "deleted setup-AP profile: $ap"; }
              done
        # Actively bring up the user's network and confirm real connectivity
        # (up to ~60s) BEFORE we commit — so we never reboot on a half-join.
        log "activating '$FIRST_NEW' and waiting for connectivity..."
        for _ in $(seq 1 20); do
            nmcli connection up "$FIRST_NEW" >/dev/null 2>&1
            sleep 3
            if nmcli -t -f STATE g 2>/dev/null | grep -q '^connected$'; then
                log "connectivity confirmed on '$FIRST_NEW'"; break
            fi
        done
        mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"
        log "provisioned -> rebooting now (clean client join)"
        sleep 2
        systemctl reboot
        exit 0
    fi
    sleep 2
done

if nmcli -t -f STATE g 2>/dev/null | grep -q '^connected$'; then
    log "connected after wifi-connect exit -> provisioning + reboot"
    # Same cleanup: drop the setup-AP profile so it can't win on reboot.
    nmcli -t -f NAME,TYPE connection show 2>/dev/null \
        | awk -F: '$2 ~ /wireless/ && $1 ~ /GMNas-Setup|Hotspot|wifi-connect/ {print $1}' \
        | while read -r ap; do
            [ -n "$ap" ] && { nmcli connection delete "$ap" 2>/dev/null && log "deleted setup-AP profile: $ap"; }
          done
    mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"; sleep 3
    log "provisioned -> rebooting now"
    systemctl reboot
    exit 0
fi
log "firstboot-wifi finished without provisioning (exit 0)"
exit 0
