#!/usr/bin/env bash
# ============================================================================
# gm-nas — write /etc/issue: the banner agetty shows BEFORE the login prompt,
# so anyone at the physical console knows the box's state without logging in.
# Called at every state change (entering/leaving setup mode) so it's never
# stale by the time someone actually looks at the screen.
#     sudo bash update-issue.sh
# ============================================================================
set -u

# Optional: "pending" writes a transitional banner (AP still stabilizing)
# instead of the real setup-mode instructions. Without this, the console's
# already-running getty (started at boot, before the AP stabilization
# retries finish) kept showing whatever banner was there BEFORE this reset
# -- confirmed live: stale "online" info from the old network, for the
# whole ~20-40s the AP takes to come up. A visibly-in-progress message
# during that window beats a flatly wrong one.
if [ "${1:-}" = "pending" ]; then
    cat > /etc/issue <<'EOF'
============================================================
  gm-nas -- switching to SETUP MODE, please wait...
============================================================

EOF
    systemctl restart getty@tty1.service 2>/dev/null || true
    exit 0
fi

if [ ! -f /etc/homenas/provisioned ]; then
    cat > /etc/issue <<'EOF'
============================================================
  gm-nas -- SETUP MODE
============================================================
  1) Connect a phone/laptop to WiFi:  GMNas-Setup
     Password: gmnas2026
  2) Browse to: http://192.168.42.1
  3) Pick your home WiFi to finish setup
============================================================

EOF
else
    # Not `hostname -I`: that lists Docker's bridge addresses too (docker0
    # 172.17.0.1, br-<id> 172.18.0.1) in unstable order, so once a Docker
    # stack (Immich) was on the box this banner started advertising 172.18.0.1
    # as the box's IP -- unreachable from the LAN, and it looks like a fault.
    ip="$(ip -4 -o addr show scope global 2>/dev/null \
          | awk '$2 !~ /^(docker|br-|veth|tailscale|lo)/ {split($4,a,"/"); print a[1]; exit}')"
    ver="$(cat /etc/gmnas-build-version 2>/dev/null || echo '?')"
    cat > /etc/issue <<EOF
============================================================
  gm-nas -- online
  Host: $(hostname).local   IP: ${ip:-<none>}   Version: ${ver}
============================================================

EOF
fi

# Force the console to actually show this right away -- agetty only
# re-reads /etc/issue when its own process (re)starts, not on every failed
# login attempt at an already-running prompt. Without this, a getty that
# started earlier keeps displaying whatever was there when IT started.
systemctl restart getty@tty1.service 2>/dev/null || true
