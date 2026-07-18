#!/usr/bin/env bash
# ============================================================================
# gm-install-all — install the heavier components that need internet.
# The minimal install ships only the essentials (NetworkManager, avahi, btop,
# wifi-connect). Run this when the box is online to add the rest:
#   Cockpit, Tailscale, Samba, NFS, ttyd browser terminal, welcome app.
#     sudo gm-install-all
# ============================================================================
set -u
BASE="https://raw.githubusercontent.com/affigabmag/gm-nas-pub/main"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo gm-install-all" >&2
    exit 1
fi

LOGDIR=/var/log/gm-nas; mkdir -p "$LOGDIR" 2>/dev/null || true
exec > >(tee -a "$LOGDIR/gm-install-all.log") 2>&1
echo "$(date '+%F %T') ===== gm-install-all start ====="

# need internet
if ! getent hosts github.com >/dev/null 2>&1 && ! curl -fsS --max-time 8 https://github.com >/dev/null 2>&1; then
    echo "No internet — connect WiFi/tether first (try: sudo join-wifi)." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
echo "== installing all gm-nas components (this needs internet) =="

echo "-- apt: cockpit, samba, nfs, flask --"
apt-get update
apt-get install -y cockpit samba nfs-kernel-server python3-flask
systemctl enable --now cockpit.socket 2>/dev/null || true
systemctl enable --now smbd nmbd 2>/dev/null || true
systemctl enable --now nfs-kernel-server 2>/dev/null || true

echo "-- Tailscale --"
curl -fsSL https://tailscale.com/install.sh | sh || true
systemctl enable --now tailscaled 2>/dev/null || true

echo "-- ttyd browser terminal --"
curl -fsSL https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 -o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd

echo "-- welcome app + services --"
mkdir -p /usr/local/lib/gmnas-welcome
curl -fsSL "$BASE/welcome/app.py"              -o /usr/local/lib/gmnas-welcome/app.py
curl -fsSL "$BASE/files/gmnas-welcome.service" -o /etc/systemd/system/gmnas-welcome.service
curl -fsSL "$BASE/files/ttyd.service"          -o /etc/systemd/system/ttyd.service
systemctl daemon-reload
systemctl enable --now ttyd.service gmnas-welcome.service 2>/dev/null || true

H="$(hostname).local"
echo "== done =="
echo "  Welcome  : http://$H"
echo "  Cockpit  : https://$H:9090"
echo "  Terminal : http://$H:7681"
