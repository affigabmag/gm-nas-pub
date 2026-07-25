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

# Capture BEFORE the tee redirect below replaces stdout with a pipe -- once
# that happens, [ -t 1 ] inside this script always reads "not a terminal"
# even when the real terminal on the other end of tee is one.
if [ -t 1 ]; then
    B=$'\e[1m'; R=$'\e[0m'
    CY=$'\e[38;5;44m'; GR=$'\e[38;5;83m'; YL=$'\e[38;5;227m'; RD=$'\e[38;5;203m'
else
    B=; R=; CY=; GR=; YL=; RD=
fi

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
    echo "  If you need to copy the URL: select it, then right-click ->"
    echo "  Copy. Ctrl+C in a terminal does NOT copy -- it sends an"
    echo "  interrupt instead (this is exactly what pauses below)."
    echo "============================================================"
    # A single accidental Ctrl+C (someone reflexively copying the URL the
    # normal way) used to cancel the whole setup outright -- confirmed
    # live, that's exactly what happened on a real run. Now it just asks
    # whether you meant it, and if not, prints a fresh login link and
    # keeps waiting instead of throwing away everything so far.
    login_interrupted() {
        echo
        echo "Ctrl+C caught. If that was an attempt to COPY the URL above,"
        echo "it cancelled the wait instead -- use right-click -> Copy, not Ctrl+C."
        read -rp "Really abort the whole setup? [y/N]: " really
        case "$(printf '%s' "$really" | tr '[:upper:]' '[:lower:]')" in
            y|yes) trap abort INT TERM; abort ;;
            *) echo "Continuing -- starting a fresh login link..." ;;
        esac
    }
    trap login_interrupted INT
    login_tries=0
    until [ -f "$CERT" ]; do
        login_tries=$((login_tries + 1))
        if [ "$login_tries" -gt 10 ]; then
            echo "ERROR: login still hasn't completed after $login_tries attempts. Aborting." >&2
            trap abort INT TERM
            exit 1
        fi
        cloudflared tunnel login
    done
    trap abort INT TERM
    if [ ! -f "$CERT" ]; then
        echo "ERROR: login did not complete (no $CERT found). Aborting." >&2
        exit 1
    fi
    echo "Login successful."
fi

# --- 2) Name the tunnel -----------------------------------------------------
echo
read_or_abort TUNNEL_NAME "Tunnel name [gmnas001]: " "gmnas001"

# A hand-rolled grep against `tunnel list -o json` here previously failed to
# match the real field order/format cloudflared actually emits -- confirmed
# live: the tunnel was created successfully ("Created tunnel gmnas001 with id
# ...") but the grep found nothing, so the script errored out right after a
# real success. Parse with python3 (always present on this box) instead of
# guessing at JSON via regex.
tunnel_uuid_by_name() {
    cloudflared tunnel list -o json 2>/dev/null | python3 -c "
import json, sys
name = sys.argv[1]
try:
    tunnels = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for t in tunnels:
    if t.get('name') == name:
        print(t.get('id', ''))
        break
" "$1"
}

EXISTING_UUID="$(tunnel_uuid_by_name "$TUNNEL_NAME")"
if [ -n "$EXISTING_UUID" ]; then
    echo "Tunnel '$TUNNEL_NAME' already exists (uuid $EXISTING_UUID) -- reusing it."
    TUNNEL_UUID="$EXISTING_UUID"
else
    echo "Creating tunnel '$TUNNEL_NAME'..."
    CREATE_OUT="$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)"
    CREATE_RC=$?
    echo "$CREATE_OUT"
    if [ "$CREATE_RC" -ne 0 ]; then
        echo "ERROR: tunnel creation failed." >&2
        exit 1
    fi
    # cloudflared's own success line already states the UUID directly
    # ("Created tunnel NAME with id UUID") -- read it from there first,
    # falling back to the JSON lookup only if that line's format changes.
    TUNNEL_UUID="$(printf '%s\n' "$CREATE_OUT" | grep -oE 'with id [a-f0-9-]+' | awk '{print $3}')"
    [ -z "$TUNNEL_UUID" ] && TUNNEL_UUID="$(tunnel_uuid_by_name "$TUNNEL_NAME")"
fi
if [ -z "$TUNNEL_UUID" ]; then
    echo "ERROR: could not determine the tunnel's UUID after creation." >&2
    exit 1
fi
CRED_FILE="/root/.cloudflared/${TUNNEL_UUID}.json"

# --- 3) Hostname to expose ---------------------------------------------------
# If this tunnel already has a hostname configured (from a previous run),
# don't ask again -- just confirm and reuse it. Re-running this option
# every time asked for the hostname from scratch even when nothing had
# changed, which is unnecessary friction for something already set up.
EXISTING_HOSTNAME=""
if [ -f "$CFG_DIR/config.yml" ] && grep -q "^tunnel: $TUNNEL_UUID$" "$CFG_DIR/config.yml"; then
    # config.yml lines look like "  - hostname: value" -- $2 in awk's default
    # whitespace split is the literal word "hostname:", not the value (real
    # bug, confirmed live: it printed "hostname:" as the actual hostname).
    EXISTING_HOSTNAME="$(sed -n 's/.*hostname: *//p' "$CFG_DIR/config.yml" | head -1)"
fi
echo
if [ -n "$EXISTING_HOSTNAME" ]; then
    echo "This tunnel is already routed to: $EXISTING_HOSTNAME"
    read_or_abort HOSTNAME "Hostname [$EXISTING_HOSTNAME, Enter to keep]: " "$EXISTING_HOSTNAME"
else
    echo "Example: gmnas001.your-domain.com (must be on a domain already added"
    echo "to your Cloudflare account)."
    read_or_abort HOSTNAME "Full hostname for this box: " ""
fi
if [ -z "$HOSTNAME" ]; then
    echo "ERROR: a hostname is required." >&2
    exit 1
fi

if [ "$HOSTNAME" = "$EXISTING_HOSTNAME" ]; then
    echo "Keeping existing route: $HOSTNAME -> tunnel '$TUNNEL_NAME' (already routed, skipping)."
elif ! cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME"; then
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
echo "${CY}============================================================${R}"
echo "${CY}  Cloudflare Tunnel is live: ${B}${GR}$HOSTNAME${R}"
echo "${CY}============================================================${R}"
echo "  Tunnel name : ${GR}$TUNNEL_NAME${R}"
echo "  Status      : sudo systemctl status cloudflared"
echo "  Logs        : sudo journalctl -u cloudflared -f"
echo

# One paste-able block per OS instead of a generic 3-step list -- the end
# user picks their OS once and copies ONE thing into their terminal that
# installs cloudflared (if needed), wires up SSH config, and connects, all
# in one go. No separate "now edit this file" step to get wrong.
# NOTE: no color codes inside the actual heredoc code blocks below -- those
# get copy-pasted verbatim into someone else's terminal, and stray ANSI
# escape sequences in pasted shell/PowerShell input would break it.
echo "${YL}------------------------------------------------------------${R}"
echo "${YL}${B}TO CONNECT FROM A REMOTE COMPUTER${R}${YL}: pick which OS you'll be"
echo "connecting FROM, and this shows just the one block you need.${R}"
echo "${YL}------------------------------------------------------------${R}"
echo "  1) Windows (PowerShell)"
echo "  2) Linux / macOS (bash)"
echo "  3) Show both"
read_or_abort OS_CHOICE "Select [1-3, default 3]: " "3"
echo "$(date '+%F %T') [install-cloudflared] connect-instructions OS choice: $OS_CHOICE" >> "$LOGDIR/install-cloudflared.log"

if [ "$OS_CHOICE" = "1" ] || [ "$OS_CHOICE" = "3" ]; then
    echo
    echo "${B}${CY}=== Windows (PowerShell) ===${R}"
    cat <<WINEOF
winget install --id Cloudflare.cloudflared -e --silent
# winget updates the system PATH, but THIS already-open PowerShell window
# doesn't see it until reopened -- confirmed live: ssh's ProxyCommand
# couldn't find cloudflared right after install ("posix_spawnp: No such
# file or directory"), in the very same window that just installed it.
# Refresh this session's PATH so the ssh command below actually works
# without needing to close and reopen the window.
\$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
if (-not (Test-Path "\$env:USERPROFILE\.ssh")) { New-Item -ItemType Directory "\$env:USERPROFILE\.ssh" | Out-Null }
Add-Content "\$env:USERPROFILE\.ssh\config" "\`nHost $HOSTNAME\`n  ProxyCommand cloudflared access ssh --hostname %h\`n"
ssh gmnas@$HOSTNAME
WINEOF
fi
if [ "$OS_CHOICE" = "2" ] || [ "$OS_CHOICE" = "3" ]; then
    echo
    echo "${B}${CY}=== Linux / macOS (bash) ===${R}"
    cat <<NIXEOF
command -v cloudflared >/dev/null 2>&1 || {
  if command -v brew >/dev/null 2>&1; then brew install cloudflared
  else
    sudo mkdir -p /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared \$(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
    sudo apt-get update && sudo apt-get install -y cloudflared
  fi
}
mkdir -p ~/.ssh
printf '\nHost $HOSTNAME\n  ProxyCommand cloudflared access ssh --hostname %%h\n' >> ~/.ssh/config
ssh gmnas@$HOSTNAME
NIXEOF
fi
echo
echo "${CY}============================================================${R}"
