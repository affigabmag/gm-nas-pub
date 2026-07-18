#!/usr/bin/env bash
# ============================================================================
# gm-nas updater — run ON the mini PC to pull the latest app/UI/services from
# gm-nas-pub without reinstalling. Needs internet + root.
#
#   sudo bash gm-update.sh
# ============================================================================
set -u
BASE="https://raw.githubusercontent.com/affigabmag/gm-nas-pub/main"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo bash gm-update.sh" >&2
    exit 1
fi

echo "== gm-nas update: pulling latest from gm-nas-pub =="

# Flask for the welcome app (no-op if already present)
apt-get install -y python3-flask >/dev/null 2>&1 || true

mkdir -p /usr/local/lib/gmnas-welcome /usr/local/lib/wifi-connect/ui /usr/local/sbin

get() {  # get <url-path> <dest>
    if curl -fsSL "$BASE/$1" -o "$2"; then echo "  updated $2"
    else echo "  FAILED  $2" >&2; fi
}

get welcome/app.py                  /usr/local/lib/gmnas-welcome/app.py
get files/gmnas-welcome.service     /etc/systemd/system/gmnas-welcome.service
get files/ttyd.service              /etc/systemd/system/ttyd.service
get files/firstboot-wifi.sh         /usr/local/sbin/firstboot-wifi.sh
get files/homenas-firstboot.service /etc/systemd/system/homenas-firstboot.service
get ui/index.html                   /usr/local/lib/wifi-connect/ui/index.html

# Refresh the helper commands too (so the gmnas menu updates itself).
for h in gmnas gm-usb gm-update join-wifi reset-setup gm-install-all; do
    if curl -fsSL "$BASE/$h.sh" -o "/usr/local/bin/$h"; then chmod +x "/usr/local/bin/$h"; echo "  updated cmd: $h"; fi
done

chmod +x /usr/local/sbin/firstboot-wifi.sh 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now ttyd.service gmnas-welcome.service 2>/dev/null || true
systemctl restart gmnas-welcome.service ttyd.service 2>/dev/null || true

H="$(hostname).local"
echo "== done =="
echo "  Welcome app : http://$H"
echo "  Cockpit     : https://$H:9090"
echo "  Terminal    : http://$H:7681"
