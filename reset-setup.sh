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

log "stopping welcome app so wifi-connect can own port 80"
systemctl stop gmnas-welcome.service 2>/dev/null || true
log "port 80 now: $(ss -ltnp 2>/dev/null | grep ':80 ' || echo free)"

log "disconnecting WiFi so the box is not 'online'"
for dev in $(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1}'); do
    nmcli device disconnect "$dev" 2>/dev/null || true
    log "  disconnected $dev"
done

log "restarting first-boot setup service (launches GMNas-Setup AP)"
systemctl restart homenas-firstboot.service 2>/dev/null || true
sleep 2
log "homenas-firstboot state: $(systemctl is-active homenas-firstboot.service 2>/dev/null)"
log "done — connect a phone to WiFi 'GMNas-Setup', browse http://192.168.42.1"
log "(follow the AP flow in /var/log/gm-nas/firstboot-wifi.log)"
