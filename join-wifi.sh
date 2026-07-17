#!/usr/bin/env bash
# ============================================================================
# gm-nas — join a WiFi network from the console (stops the setup AP first).
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

echo "== stopping setup AP =="
pkill -f wifi-connect 2>/dev/null || true
systemctl stop homenas-firstboot.service 2>/dev/null || true

echo "== connecting to WiFi: $SSID =="
nmcli radio wifi on 2>/dev/null || true
nmcli device wifi rescan 2>/dev/null || true
sleep 2
nmcli device wifi connect "$SSID" password "$PASS"

echo "== current addresses =="
ip -brief a
