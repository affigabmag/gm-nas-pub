#!/usr/bin/env bash
# ============================================================================
# gm-nas — re-run first-boot WiFi setup (bring back the GMNas-Setup AP).
# Clears the "provisioned" flag, disconnects WiFi (so the box isn't "online"),
# and restarts the setup service so the captive-portal AP broadcasts again.
# Run on the mini PC:   sudo bash reset-setup.sh
# ============================================================================
set -u

LOGDIR=/var/log/gm-nas; LOGF="$LOGDIR/reset-setup.log"; mkdir -p "$LOGDIR" 2>/dev/null || true
log() { printf '%s [reset-setup] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGF" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo bash reset-setup.sh" >&2
    exit 1
fi

log "=============== reset-setup start ==============="
log "clearing provisioned flag"
rm -f /etc/homenas/provisioned

# Same reasoning as factory-reset.sh: whatever console autologin state
# existed before this ran, force it OFF here too. The First-time wizard
# switches the box to AP + phone setup, not back to an unauthenticated
# console menu -- physical access should require a real login regardless
# of which reset path got here.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noclear %I $TERM
EOF
systemctl daemon-reload 2>/dev/null || true
# NOT restarting getty@tty1 here at all -- confirmed live (twice, both a
# synchronous restart and a delayed detached one) that it kills THIS script,
# since it runs on tty1 itself. This flow doesn't reboot on its own the way
# factory-reset does, so the override.conf change here takes effect on
# whatever the NEXT actual reboot/getty restart is (including the one
# factory-reset.sh performs, or a manual reboot).
log "console autologin disabled -- tty1 now requires a real login"

log "stopping welcome app so wifi-connect can own port 80"
systemctl stop gmnas-welcome.service 2>/dev/null || true
log "port 80 now: $(ss -ltnp 2>/dev/null | grep ':80 ' || echo free)"

log "disconnecting WiFi so the box is not 'online'"
for dev in $(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1}'); do
    nmcli device disconnect "$dev" 2>/dev/null || true
    log "  disconnected $dev"
done

# CRITICAL: delete the saved home-WiFi profile(s), not just disconnect. A saved
# profile keeps autoconnect=yes (set when it was first joined), so NetworkManager
# keeps trying to reconnect it in the background — racing wifi-connect for the
# single radio and tearing the GMNas-Setup AP down within seconds of it starting.
nmcli -t -f NAME,TYPE connection show 2>/dev/null \
    | awk -F: '$2 ~ /wireless/ && $1 !~ /GMNas-Setup|Hotspot|wifi-connect/ {print $1}' \
    | while read -r c; do
        [ -n "$c" ] && { nmcli connection delete "$c" 2>/dev/null && log "  deleted saved WiFi profile: $c"; }
      done
# nmcli connection delete only removes NetworkManager's own copy -- netplan
# keeps a mirrored YAML (e.g. 9x-NM-<uuid>.yaml) for any NM-managed wifi
# connection and replays it, silently reconnecting to the "deleted" network.
# factory-reset.sh has always stripped these; this script did NOT, and that
# was the whole bug: confirmed live 2026-08-05, the box rejoined home WiFi
# ~10s after this script finished, so homenas-firstboot logged "WiFi is UP ->
# normal boot (mark provisioned), no wizard" and the GMNas-Setup AP never
# appeared -- while the menu still showed "setup mode" from the cleared flag.
# Never touches 01-gmnas-net.yaml (ethernet/usb-tether only, no wifis: key).
for f in /etc/netplan/*-NM-*.yaml; do
    if [ -f "$f" ] && grep -q '^[[:space:]]*wifis:' "$f"; then
        rm -f "$f"
        log "  removed stale netplan WiFi profile: $f"
    fi
done
# The flag was cleared at the top, but NM may have re-marked the box
# provisioned in between (see above) -- clear it again, now that nothing can
# bring the old network back.
rm -f /etc/homenas/provisioned

log "done — rebooting now; homenas-firstboot launches GMNas-Setup AP on boot"
log "connect a phone to WiFi 'GMNas-Setup', browse http://192.168.42.1"
log "(follow the AP flow in /var/log/gm-nas/firstboot-wifi.log)"
# Reboot instead of just restarting homenas-firstboot in place, matching
# factory-reset.sh. Restarting the service worked, but left the box in a
# half-state the rest of the system doesn't expect:
#   - gmnas-welcome stays dead until the NEXT boot regardless, because its
#     ConditionPathExists=/etc/homenas/provisioned is only evaluated at boot;
#   - the getty override written above (console autologin off) also only takes
#     effect on the next getty restart, which this now guarantees;
#   - a clean boot re-runs the AP flow from exactly the same state a real
#     first boot has, instead of from whatever the previous session left
#     behind (leftover dnsmasq, stale routes, docker bridges already up).
# firstboot then finds no saved WiFi and raises the AP itself.
sleep 2
systemctl reboot
