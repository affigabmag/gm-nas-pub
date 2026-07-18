#!/usr/bin/env bash
# ============================================================================
# gm-nas — join a WiFi network from the console (tears down the setup AP first).
# Run on the mini PC:   sudo bash join-wifi.sh [SSID] [PASSWORD]
# Defaults: SSID "home", password "teva2000".
# ============================================================================
set -u
SSID="${1:-home}"
PASS="${2:-teva2000}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo bash join-wifi.sh [SSID] [PASSWORD]" >&2
    exit 1
fi

echo "== stopping the setup AP =="
systemctl stop homenas-firstboot.service 2>/dev/null || true
pkill -f wifi-connect 2>/dev/null || true
sleep 2

# The WiFi adapter is still bound to wifi-connect's AP/hotspot connection.
# Bring down every active wireless connection and delete the AP profiles so
# the adapter is free to switch from AP mode to station (client) mode.
echo "== releasing the WiFi adapter from AP mode =="
for c in $(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2 ~ /wireless/ {print $1}'); do
    nmcli connection down "$c" 2>/dev/null || true
done
nmcli connection delete "wifi-connect" 2>/dev/null || true
nmcli connection delete "Hotspot" 2>/dev/null || true
nmcli connection delete "GMNas-Setup" 2>/dev/null || true

nmcli radio wifi on 2>/dev/null || true
sleep 2
nmcli device wifi rescan 2>/dev/null || true
sleep 3

echo "== connecting to WiFi: $SSID =="
nmcli device wifi connect "$SSID" password "$PASS"

echo "== current addresses =="
ip -brief a
