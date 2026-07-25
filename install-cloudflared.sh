#!/usr/bin/env bash
# ============================================================================
# gm-nas — set up a PERSISTENT, NAMED Cloudflare Tunnel for remote SSH access
# under your own domain (e.g. gmnas001.your-domain.com). This requires a
# Cloudflare account with that domain already added as a zone.
#
# Interactive: it walks you through `cloudflared tunnel login` (opens a URL
# you open in ANY browser, on any device, to authorize this box), asks for a
# tunnel name and the hostname to expose, creates the tunnel + DNS record,
# and installs it as a systemd service so it survives reboots.
#
# Run on the mini PC:   sudo bash install-cloudflared.sh
# ============================================================================
set -u

LOGDIR=/var/log/gm-nas; mkdir -p "$LOGDIR" 2>/dev/null || true
exec > >(tee -a "$LOGDIR/install-cloudflared.log") 2>&1
echo "$(date '+%F %T') ===== install-cloudflared start ====="

CFG_DIR=/etc/cloudflared
CERT="/root/.cloudflared/cert.pem"

# Abort cleanly at any point (Ctrl+C, or typing "abort" at any prompt below)
# instead of leaving a raw bash interrupt trace or a half-finished setup
# with no explanation of what state things were left in.
abort() {
    echo
    echo "== Aborted -- Cloudflare Tunnel setup was NOT completed. =="
    if [ -n "${TUNNEL_NAME:-}" ] && [ -n "${TUNNEL_UUID:-}" ]; then
        echo "   A tunnel named '$TUNNEL_NAME' may already exist on your"
        echo "   Cloudflare account (created before the abort) -- re-running"
        echo "   this option will detect and reuse it rather than duplicate it."
    fi
    exit 130
}
trap abort INT TERM

# Read a prompt, treating "abort"/"a" (case-insensitive) as a request to
# cancel the whole setup instead of being taken as a literal answer.
read_or_abort() {
    local __var="$1" __prompt="$2" __default="${3:-}" __ans
    read -rp "$__prompt" __ans
    case "$(printf '%s' "$__ans" | tr '[:upper:]' '[:lower:]')" in
        abort|a) abort ;;
    esac
    printf -v "$__var" '%s' "${__ans:-$__default}"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo bash install-cloudflared.sh" >&2
    exit 1
fi

if ! command -v cloudflared >/dev/null 2>&1; then
    echo "== installing cloudflared =="
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
echo "cloudflared installed: $(cloudflared --version 2>&1 | head -1)"

# --- 1) Log in to your Cloudflare account (one-time) -----------------------
echo
echo "(At any prompt: type 'abort' to cancel, or press Ctrl+C at any time.)"

if [ -f "$CERT" ]; then
    echo
    echo "Already logged in (found $CERT)."
    read_or_abort relogin "Log in again with a different account? [y/N]: " "n"
    [ "$relogin" = "y" ] || [ "$relogin" = "Y" ] && rm -f "$CERT"
fi
if [ ! -f "$CERT" ]; then
    echo
    echo "============================================================"
    echo "  STEP 1: authorize this box on your Cloudflare account."
    echo "  cloudflared will print a URL below -- copy the FULL link"
    echo "  (it's long) into any browser, on any device. Log in if"
    echo "  asked, then look for a page that asks you to pick a"
    echo "  zone/domain and AUTHORIZE this specific request -- just"
    echo "  landing on your normal Cloudflare dashboard is NOT enough,"
    echo "  that means the link wasn't opened (or got cut short)."
    echo "  Once authorized, this terminal continues on its own within"
    echo "  a few seconds -- nothing else to do here."
    echo "  (Ctrl+C here cancels the whole setup.)"
    echo "============================================================"
    cloudflared tunnel login
    if [ ! -f "$CERT" ]; then
        echo "ERROR: login did not complete (no $CERT found). Aborting." >&2
        exit 1
    fi
    echo "Login successful."
fi

# --- 2) Name the tunnel -----------------------------------------------------
echo
read_or_abort TUNNEL_NAME "Tunnel name [gmnas001]: " "gmnas001"

EXISTING_UUID="$(cloudflared tunnel list -o json 2>/dev/null \
    | grep -o "\"id\":\"[a-f0-9-]*\",\"name\":\"$TUNNEL_NAME\"" | grep -o '^"id":"[a-f0-9-]*"' | cut -d'"' -f4)"
if [ -n "$EXISTING_UUID" ]; then
    echo "Tunnel '$TUNNEL_NAME' already exists (uuid $EXISTING_UUID) -- reusing it."
    TUNNEL_UUID="$EXISTING_UUID"
else
    echo "Creating tunnel '$TUNNEL_NAME'..."
    if ! cloudflared tunnel create "$TUNNEL_NAME"; then
        echo "ERROR: tunnel creation failed." >&2
        exit 1
    fi
    TUNNEL_UUID="$(cloudflared tunnel list -o json 2>/dev/null \
        | grep -o "\"id\":\"[a-f0-9-]*\",\"name\":\"$TUNNEL_NAME\"" | grep -o '^"id":"[a-f0-9-]*"' | cut -d'"' -f4)"
fi
if [ -z "$TUNNEL_UUID" ]; then
    echo "ERROR: could not determine the tunnel's UUID after creation." >&2
    exit 1
fi
CRED_FILE="/root/.cloudflared/${TUNNEL_UUID}.json"

# --- 3) Hostname to expose ---------------------------------------------------
echo
echo "Example: gmnas001.your-domain.com (must be on a domain already added"
echo "to your Cloudflare account)."
read_or_abort HOSTNAME "Full hostname for this box: " ""
if [ -z "$HOSTNAME" ]; then
    echo "ERROR: a hostname is required." >&2
    exit 1
fi

echo "Routing $HOSTNAME -> tunnel '$TUNNEL_NAME'..."
if ! cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME"; then
    echo "ERROR: DNS routing failed (hostname already used elsewhere, or the" >&2
    echo "domain isn't on this Cloudflare account)." >&2
    exit 1
fi

# --- 4) Config + persistent service -----------------------------------------
mkdir -p "$CFG_DIR"
cat > "$CFG_DIR/config.yml" <<EOF
tunnel: $TUNNEL_UUID
credentials-file: $CRED_FILE

ingress:
  - hostname: $HOSTNAME
    service: ssh://localhost:22
  - service: http_status:404
EOF

cloudflared service install >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now cloudflared.service
sleep 2

echo
echo "============================================================"
echo "  Cloudflare Tunnel is live: $HOSTNAME"
echo "============================================================"
echo "  Tunnel name : $TUNNEL_NAME"
echo "  Status      : sudo systemctl status cloudflared"
echo "  Logs        : sudo journalctl -u cloudflared -f"
echo
echo "  ------------------------------------------------------------"
echo "  TO CONNECT FROM ANY REMOTE COMPUTER:"
echo "  ------------------------------------------------------------"
echo "  1) Install cloudflared on that computer (one-time):"
echo "     https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
echo
echo "  2) Add this to that computer's ~/.ssh/config:"
echo "       Host $HOSTNAME"
echo "         ProxyCommand cloudflared access ssh --hostname %h"
echo
echo "  3) Then just:"
echo "     ssh gmnas@$HOSTNAME"
echo "============================================================"
