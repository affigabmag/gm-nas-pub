#!/usr/bin/env bash
# ============================================================================
# gm-nas — write /etc/issue: the banner agetty shows BEFORE the login prompt,
# so anyone at the physical console knows the box's state without logging in.
# Called at every state change (entering/leaving setup mode) so it's never
# stale by the time someone actually looks at the screen.
#     sudo bash update-issue.sh
# ============================================================================
set -u

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
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    ver="$(cat /etc/gmnas-build-version 2>/dev/null || echo '?')"
    cat > /etc/issue <<EOF
============================================================
  gm-nas -- online
  Host: $(hostname).local   IP: ${ip:-<none>}   Version: ${ver}
============================================================

EOF
fi
