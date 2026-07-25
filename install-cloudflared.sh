#!/usr/bin/env bash
# ============================================================================
# gm-nas — install Cloudflare Tunnel for remote SSH access, no Cloudflare
# account or domain required (uses a Cloudflare "quick tunnel").
#
# Installs cloudflared, runs it as a persistent systemd service tunneling
# this box's SSH port (22) out through Cloudflare's network, then prints the
# exact steps to connect from anywhere.
#
# NOTE: a quick-tunnel hostname is temporary -- it changes every time the
# service (re)starts. Re-run this (menu: Installs -> Cloudflare Tunnel) any
# time to see the CURRENT hostname; it's also always in the service log.
#
# Run on the mini PC:   sudo bash install-cloudflared.sh
# ============================================================================
set -u

LOGDIR=/var/log/gm-nas; LOGF="$LOGDIR/cloudflared.log"; mkdir -p "$LOGDIR" 2>/dev/null || true
log() { printf '%s [cloudflared] %s\n' "$(date '+%F %T')" "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo bash install-cloudflared.sh" >&2
    exit 1
fi

if ! command -v cloudflared >/dev/null 2>&1; then
    log "downloading cloudflared..."
    ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb" \
        -o /tmp/cloudflared.deb
    dpkg -i /tmp/cloudflared.deb 2>/dev/null || apt-get install -f -y
    rm -f /tmp/cloudflared.deb
fi

if ! command -v cloudflared >/dev/null 2>&1; then
    echo "ERROR: cloudflared install failed." >&2
    exit 1
fi
log "cloudflared installed: $(cloudflared --version 2>&1 | head -1)"

cat > /etc/systemd/system/cloudflared-ssh.service <<'EOF'
[Unit]
Description=gm-nas remote SSH access via Cloudflare Tunnel (quick tunnel)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --url tcp://localhost:22 --logfile /var/log/gm-nas/cloudflared.log
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudflared-ssh.service
log "cloudflared-ssh.service enabled + started"

# Give it a few seconds to connect and log its assigned hostname.
HOST=""
for _ in $(seq 1 10); do
    HOST="$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$LOGF" 2>/dev/null | tail -1)"
    [ -n "$HOST" ] && break
    sleep 2
done
HOST="${HOST#https://}"

echo
echo "============================================================"
echo "  Cloudflare Tunnel is running."
echo "============================================================"
if [ -n "$HOST" ]; then
    echo "  Your remote-access hostname:  $HOST"
else
    echo "  Hostname not detected yet -- check:  sudo tail -f $LOGF"
fi
echo
echo "  This hostname is TEMPORARY: it changes if the box reboots or"
echo "  the service restarts. Come back to this menu (Installs ->"
echo "  Cloudflare Tunnel) any time to see the current one."
echo
echo "  ------------------------------------------------------------"
echo "  TO CONNECT FROM ANY REMOTE COMPUTER:"
echo "  ------------------------------------------------------------"
echo "  1) Install cloudflared on that computer (one-time):"
echo "     https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
echo
echo "  2) On that computer, open a terminal and run:"
echo "     cloudflared access tcp --hostname $HOST --url localhost:2222"
echo "     (leave this window running)"
echo
echo "  3) In a SECOND terminal on that computer, run:"
echo "     ssh -p 2222 gmnas@localhost"
echo "============================================================"
