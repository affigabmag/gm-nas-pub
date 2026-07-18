#!/usr/bin/env bash
# ============================================================================
# gm-nas — re-run first-boot WiFi setup (bring back the GMNas-Setup AP).
# Clears the "provisioned" flag, disconnects WiFi (so the box isn't "online"),
# and restarts the setup service so the captive-portal AP broadcasts again.
# Run on the mini PC:   sudo bash reset-setup.sh
# ============================================================================
set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo bash reset-setup.sh" >&2
    exit 1
fi

echo "== clearing provisioned flag =="
rm -f /etc/homenas/provisioned

echo "== stopping welcome app so wifi-connect can own port 80 =="
systemctl stop gmnas-welcome.service 2>/dev/null || true

echo "== disconnecting WiFi so the box is not 'online' =="
for dev in $(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1}'); do
    nmcli device disconnect "$dev" 2>/dev/null || true
done

echo "== restarting first-boot setup (GMNas-Setup AP) =="
systemctl restart homenas-firstboot.service 2>/dev/null || true

echo "== done — connect a phone to WiFi 'GMNas-Setup' to run setup again =="
