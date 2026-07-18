#!/usr/bin/env bash
# ============================================================================
# gm-nas — save a WiFi network and mark the device set up.
# The single USB WiFi adapter can't reliably switch from AP mode to client
# mode while running, so this SAVES the WiFi profile (autoconnect) and a
# REBOOT applies it cleanly (adapter comes up fresh in client mode).
# Run:  sudo join-wifi [SSID] [PASSWORD]     (defaults: home / teva2000)
# ============================================================================
set -u
SSID="${1:-home}"
PASS="${2:-teva2000}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo join-wifi [SSID] [PASSWORD]" >&2
    exit 1
fi

echo "== stopping the setup AP =="
systemctl stop homenas-firstboot.service 2>/dev/null || true
pkill -f wifi-connect 2>/dev/null || true
sleep 2

DEV="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"

echo "== saving WiFi profile: $SSID =="
nmcli connection delete "$SSID" 2>/dev/null || true
nmcli connection add type wifi con-name "$SSID" ${DEV:+ifname "$DEV"} ssid "$SSID" \
    wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASS" \
    connection.autoconnect yes 2>/dev/null \
    && echo "  saved (autoconnect on)" \
    || echo "  WARN: could not save profile"

# Mark provisioned so first boot doesn't re-open the setup AP.
mkdir -p /etc/homenas
touch /etc/homenas/provisioned

# Best-effort live connect (often fails if the adapter is stuck in AP mode —
# that's fine, the reboot will apply it).
nmcli connection up "$SSID" 2>/dev/null || true

echo
echo ">> WiFi '$SSID' saved. A REBOOT is required to leave AP mode and connect."
