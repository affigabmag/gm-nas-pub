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

# Hardware/driver diagnostics up front -- when a customer reports "couldn't
# connect to the setup AP" and we have no live access to the box, this is
# the only record of whether the WiFi radio was even usable at boot.
log "-- hardware/driver diagnostics --"
log "rfkill: $(command -v rfkill >/dev/null 2>&1 && rfkill list 2>&1 | tr '\n' ' | ' || echo 'rfkill not installed')"
log "wifi interfaces: $(for i in /sys/class/net/*; do [ -d "$i/wireless" ] && echo -n "$(basename "$i") "; done)"
log "lsusb (wifi-relevant): $(lsusb 2>&1 | grep -iE 'wireless|wifi|802.11|realtek|atheros|broadcom|mediatek' || echo none)"
log "dmesg wifi/wlan errors: $(dmesg 2>/dev/null | grep -iE 'wlan|wifi|80211|firmware' | tail -10 | tr '\n' ' | ')"
log "nmcli general status: $(nmcli general status 2>&1 | tr '\n' ' | ')"

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

# An explicit request for setup mode (menu `h` / reset-setup.sh) overrides the
# connectivity heuristic entirely. The heuristic is right for the case it was
# written for -- a box that lost its network must always be able to fall back
# to the AP -- but it is wrong when the user deliberately asked for the wizard:
# any surviving WiFi profile would reconnect within the 60s grace window and
# send us down "normal boot, no wizard", so the AP never appeared. Confirmed
# live twice (2026-08-05, 2026-08-06).
#
# The marker is consumed here, so this is a one-shot: if the user never
# completes the portal, the next boot behaves normally again rather than
# trapping the box in AP mode forever.
FORCE_FLAG=/etc/homenas/force-setup
if [ -f "$FORCE_FLAG" ]; then
    log "force-setup marker present -> setup AP requested explicitly, ignoring any saved WiFi"
    rm -f "$FORCE_FLAG"
    # Drop anything that could grab the radio out from under wifi-connect.
    nmcli -t -f NAME,TYPE connection show 2>/dev/null \
        | awk -F: '$2 ~ /wireless/ && $1 !~ /GMNas-Setup|Hotspot|wifi-connect/ {print $1}' \
        | while read -r c; do
            [ -n "$c" ] && { nmcli connection delete "$c" 2>/dev/null && log "  deleted leftover WiFi profile: $c"; }
          done
elif saved_wifi; then
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
        bash /usr/local/sbin/update-issue.sh 2>/dev/null || true
        exit 0
    fi
    log "saved WiFi did not connect -> launching setup AP"
else
    # Fresh box / no home network yet — launch the setup AP immediately
    # (no point waiting 60s for a network that doesn't exist).
    log "no saved WiFi -> launching setup AP right away"
fi
log "devices: $(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | tr '\n' ' ')"

# Un-block the radio before anything else. A soft rfkill block (or NM's own
# `nmcli radio wifi off` state) makes the wifi device vanish from `nmcli
# device` entirely, which is indistinguishable from "no hardware" further
# down -- and that path used to give up permanently. Cheap, idempotent, and
# a no-op on a healthy box. Note rfkill itself may not be installed (the
# diagnostics above log "rfkill not installed" on this image), so don't rely
# on it alone.
command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi 2>/dev/null || true
nmcli radio wifi on 2>/dev/null || true
nmcli networking on 2>/dev/null || true

log "NO active network after wait -> (re)running the first-time WiFi wizard"
# Offline: treat the box as needing setup again so the welcome app (gated on
# this flag) stays down while the setup AP owns port 80.
rm -f "$FLAG" 2>/dev/null || true
# The welcome app may have already grabbed :80 on a stale flag — free it so
# wifi-connect's captive portal can bind.
systemctl stop gmnas-welcome.service 2>/dev/null || true
# The REAL setup-mode banner is written further down, only once the AP is
# CONFIRMED up with 192.168.42.1 -- but the console's getty starts almost
# immediately at boot, well before that confirmation (which can take
# 20-40s with retries). Without SOMETHING written here, whoever looks at
# the screen in that window sees stale leftover info from before this
# reset (confirmed live). A visibly-in-progress banner now, finalized later.
bash /usr/local/sbin/update-issue.sh pending 2>/dev/null || true

# Retry, don't fail once: on a cold power-on (as opposed to a warm reboot),
# the WiFi driver/firmware can genuinely still be loading when this service
# starts (confirmed live: dmesg showed the rtw88 driver's firmware not
# finishing load until ~14s into boot). A single immediate check that finds
# no wifi device yet used to give up right there and never show the AP at
# all -- even though the device was fully present half a minute later.
#
# 5 cycles of (2 checks, 15s apart); if still nothing after both checks in
# a cycle, kick the driver (it may be wedged, not just slow) before the
# next cycle. Progress logged as a bar so the whole wait is visible in the
# log, not just a silent multi-minute gap.
WIFI_CYCLES=5
WIFI_ATTEMPTS_PER_CYCLE=2
WIFI_RETRY_SECS=15
WIFI_TOTAL_STEPS=$((WIFI_CYCLES * WIFI_ATTEMPTS_PER_CYCLE))
wifi_progress_bar() {
    local done="$1" total="$2" pct filled bar
    pct=$((done * 100 / total))
    filled=$((done * 20 / total))
    bar="$(printf '#%.0s' $(seq 1 "$filled" 2>/dev/null))$(printf -- '-%.0s' $(seq 1 $((20 - filled)) 2>/dev/null))"
    log "waiting for wifi device: [$bar] ${pct}% (step $done/$total)"
}
kick_wifi_driver() {
    # Device-agnostic "restart" -- at this point there IS no net interface
    # yet to ask which kernel module backs it, so we can't target a modprobe
    # reload by name. Re-trigger udev's hardware detection + bounce
    # NetworkManager instead; safe to run repeatedly, no-op on healthy
    # hardware, gives a wedged/slow driver another chance to enumerate.
    log "no wifi device after ${WIFI_ATTEMPTS_PER_CYCLE} checks this cycle -- kicking the driver (udev retrigger + NetworkManager restart)"
    udevadm trigger --action=add --subsystem-match=net 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    systemctl restart NetworkManager 2>/dev/null || true
}
WIFI_STEP=0
WIFI_FOUND=no
for cycle in $(seq 1 "$WIFI_CYCLES"); do
    for attempt in $(seq 1 "$WIFI_ATTEMPTS_PER_CYCLE"); do
        if nmcli -t -f TYPE device 2>/dev/null | grep -q '^wifi$'; then
            WIFI_FOUND=yes
            break 2
        fi
        WIFI_STEP=$((WIFI_STEP + 1))
        wifi_progress_bar "$WIFI_STEP" "$WIFI_TOTAL_STEPS"
        sleep "$WIFI_RETRY_SECS"
    done
    if nmcli -t -f TYPE device 2>/dev/null | grep -q '^wifi$'; then
        WIFI_FOUND=yes
        break
    fi
    [ "$cycle" -lt "$WIFI_CYCLES" ] && kick_wifi_driver
done
if [ "$WIFI_FOUND" != yes ]; then
    log "NO wifi device found after $WIFI_CYCLES cycles ($((WIFI_CYCLES * WIFI_ATTEMPTS_PER_CYCLE * WIFI_RETRY_SECS))s total) -> cannot start setup AP, exit 0"
    exit 0
fi
[ "$WIFI_STEP" -gt 0 ] && log "wifi device appeared after $((WIFI_STEP * WIFI_RETRY_SECS))s"

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

# Write this box's own unique ID as a static file in wifi-connect's UI dir --
# wifi-connect only serves static files (no backend of its own), so the
# captive portal page reads THIS to know its own identity, then only
# accepts a scan match whose /gmnas-id response equals it. Without this,
# a second gm-nas box already on the LAN answers the same generic marker
# and the scan can match the wrong one -- confirmed live with two boxes.
cat /etc/machine-id > "$UI_DIR/my-id.txt" 2>/dev/null || true

log "launching wifi-connect (AP '$PORTAL_SSID', portal on :80, interface $WIFI_DEV)..."
# --portal-interface is REQUIRED on some USB WiFi adapters: wifi-connect's
# own device auto-detection reads the NetworkManager D-Bus device-type enum,
# and on this hardware that comes back as an unrecognized numeric value
# ("Undefined device type: 32") -- it then reports "Cannot find a WiFi
# device" and exits immediately, even though the device is real and managed.
# Passing the interface name explicitly skips that broken detection path.
"$WIFI_CONNECT" \
    --portal-ssid "$PORTAL_SSID" \
    --portal-passphrase "$PORTAL_PASSPHRASE" \
    --portal-interface "$WIFI_DEV" \
    --ui-directory "$UI_DIR" >>"$LOG" 2>&1 &
WC_PID=$!
log "wifi-connect started, pid=$WC_PID"

# Background: log every WiFi association/disassociation event straight from
# the driver, independent of DHCP/HTTP/dnsmasq. This is the one thing that
# definitively answers "did a phone even try to join the AP at all" --
# closing the one real blind spot: a phone can associate perfectly, get an
# IP, reach the portal, and STILL never trigger its own captive-portal
# popup (an OS-level client quirk, not something this box can see). If
# THIS log shows a MAC associating, the box did its job; anything after
# that point that still fails is on the phone's side, not ours.
(iw event 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        *"new station"*|*"del station"*|*connected*|*disconnected*)
            log "iw-event: $line" ;;
    esac
done) &
IWEVENT_PID=$!
trap 'kill "$IWEVENT_PID" 2>/dev/null || true' EXIT

# Actively wait for the AP interface to stabilize with 192.168.42.1 instead
# of a single fixed sleep -- confirmed live that the radio's AP transition
# can take longer than expected, or just not take at all on the first try.
# Retry a few times, restarting wifi-connect itself between attempts (not
# just waiting longer), before giving up and showing diagnostics either way.
AP_READY=no
for ap_attempt in 1 2 3 4; do
    sleep 4
    if ip -4 -o addr show dev "$WIFI_DEV" 2>/dev/null | grep -q '192\.168\.42\.1'; then
        AP_READY=yes
        log "AP interface confirmed up with 192.168.42.1 (attempt $ap_attempt/4)"
        break
    fi
    log "AP interface not up yet (attempt $ap_attempt/4)"
    [ "$ap_attempt" -eq 4 ] && break
    log "  restarting wifi-connect to retry the AP transition..."
    kill "$WC_PID" 2>/dev/null || true
    wait "$WC_PID" 2>/dev/null || true
    sleep 2
    "$WIFI_CONNECT" \
        --portal-ssid "$PORTAL_SSID" \
        --portal-passphrase "$PORTAL_PASSPHRASE" \
        --portal-interface "$WIFI_DEV" \
        --ui-directory "$UI_DIR" >>"$LOG" 2>&1 &
    WC_PID=$!
    log "  wifi-connect restarted, pid=$WC_PID"
done
if [ "$AP_READY" = yes ]; then
    bash /usr/local/sbin/update-issue.sh 2>/dev/null || true
else
    log "AP never confirmed up with 192.168.42.1 after retries -- showing setup banner anyway so the console isn't stuck on stale info"
    bash /usr/local/sbin/update-issue.sh 2>/dev/null || true
fi
log "-- AP diagnostics (post-stabilization) --"
log "post-start device status: $(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | tr '\n' ' ')"
log "post-start addresses: $(ip -brief a 2>/dev/null | tr '\n' ' ')"
log "listening on :80? $(ss -ltnp 2>/dev/null | grep ':80 ' || echo none)"
log "wifi-connect alive? $(kill -0 "$WC_PID" 2>/dev/null && echo yes || echo NO-it-exited)"
# Confirm the interface is genuinely in AP mode -- wifi-connect can stay
# alive as a process while the radio itself failed to actually enter AP
# mode (driver limitation, busy device, etc.), which looks identical to
# "working" in the process-alive check above but means no phone will ever
# see the network.
if command -v iw >/dev/null 2>&1; then
    log "iw mode check: $(iw dev "$WIFI_DEV" info 2>&1 | tr '\n' ' | ')"
    log "iw reg domain: $(iw reg get 2>&1 | tr '\n' ' | ')"
else
    log "iw mode check: iw not installed"
    log "iw reg domain: iw not installed"
fi
log "rfkill (post-start): $(command -v rfkill >/dev/null 2>&1 && rfkill list 2>&1 | tr '\n' ' | ' || echo 'rfkill not installed')"
# IP + gateway on the AP interface itself -- if wifi-connect never assigned
# its own 192.168.42.1, no phone can ever get a DHCP lease no matter how
# good the radio/SSID broadcast is.
log "AP interface IP: $(ip -4 -o addr show dev "$WIFI_DEV" 2>&1 | tr '\n' ' | ')"
log "AP interface link state: $(ip link show dev "$WIFI_DEV" 2>&1 | tr '\n' ' | ')"
# DHCP server (wifi-connect runs its own dnsmasq for the portal) -- if this
# isn't running, a phone can associate to the SSID but never get an IP or
# see the captive-portal redirect.
log "dnsmasq process: $(pgrep -af dnsmasq 2>&1 || echo none)"
log "dnsmasq listening (udp/67 DHCP, udp/53 DNS): $(ss -lunp 2>/dev/null | grep -E ':67 |:53 ' || echo none)"
# Find wifi-connect's own DHCP lease file wherever it put it -- a lease
# actually appearing here is direct proof a phone associated AND completed
# DHCP, i.e. everything on the box's side worked.
DHCP_LEASE_FILE="$(find /var/lib/misc /run /tmp -maxdepth 3 -iname '*dnsmasq*leases*' 2>/dev/null | head -1)"
log "dnsmasq lease file: ${DHCP_LEASE_FILE:-not found}"
# Self-test the captive portal HTTP server from localhost -- confirms the
# web server side works independent of anything WiFi/radio related.
log "self-curl http://127.0.0.1/ -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1/ 2>&1)"
log "self-curl http://192.168.42.1/ -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://192.168.42.1/ 2>&1)"

log "watching for the user's WiFi selection (up to ~20 min)..."
HB_LAST=0
for _ in $(seq 1 600); do
    if ! kill -0 "$WC_PID" 2>/dev/null; then
        log "wifi-connect process exited on its own"
        log "dmesg wifi/wlan errors since AP start: $(dmesg 2>/dev/null | grep -iE 'wlan|wifi|80211|firmware' | tail -10 | tr '\n' ' | ')"
        break
    fi
    # Heartbeat every ~60s during the long wait -- without this, a box that
    # sits untouched (or whose AP silently drops mid-wait) leaves a 20-min
    # gap in the log with zero evidence either way.
    HB_NOW="$(date +%s)"
    if [ $((HB_NOW - HB_LAST)) -ge 60 ]; then
        HB_LAST="$HB_NOW"
        HB_LEASES=""
        [ -n "$DHCP_LEASE_FILE" ] && HB_LEASES="$(cat "$DHCP_LEASE_FILE" 2>/dev/null | tr '\n' ' | ')"
        HB_MODE="n/a"; HB_CLIENTS="n/a"
        if command -v iw >/dev/null 2>&1; then
            HB_MODE="$(iw dev "$WIFI_DEV" info 2>/dev/null | awk '/type/{print $2}')"
            HB_CLIENTS="$(iw dev "$WIFI_DEV" station dump 2>/dev/null | grep -c '^Station')"
        fi
        log "heartbeat: AP proc alive, mode=$HB_MODE clients=$HB_CLIENTS ip=$(ip -4 -o addr show dev "$WIFI_DEV" 2>/dev/null | awk '{print $4}') dnsmasq=$(pgrep -x dnsmasq >/dev/null && echo up || echo DOWN) portal=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://192.168.42.1/ 2>/dev/null || echo unreachable) leases=[${HB_LEASES:-none}]"
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
        bash /usr/local/sbin/update-issue.sh 2>/dev/null || true
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
    mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"
    bash /usr/local/sbin/update-issue.sh 2>/dev/null || true
    sleep 3
    log "provisioned -> rebooting now"
    systemctl reboot
    exit 0
fi
log "firstboot-wifi finished without provisioning (exit 0)"
exit 0
