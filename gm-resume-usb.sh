#!/usr/bin/env bash
# ============================================================================
# gm-resume-usb — Resume install over a PHONE USB TETHER (fallback for when
# WiFi isn't available). Brings up the tether interface, waits for internet
# (forever, prompting), then runs the normal resume install (gm-install-all).
#     sudo gm-resume-usb
# ============================================================================
set -u
# blinking red / bold helpers (fall back to plain if not a terminal)
if [ -t 1 ]; then BR=$'\e[5;1;31m'; RB=$'\e[0m'; else BR=; RB=; fi

net_online() {
    ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && return 0
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && return 0
    timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null && return 0
    timeout 5 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53'  2>/dev/null && return 0
    return 1
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo gm-resume-usb" >&2
    exit 1
fi

echo "============================================================"
echo "  Resume install over USB tether"
echo "  1) Plug the phone into the box with a USB cable."
echo "  2) On the phone: enable USB tethering."
echo "  3) Make sure the phone itself has working internet."
echo "============================================================"

# Ensure the tether interfaces get DHCP via networkd (no NetworkManager needed).
CFG=/etc/netplan/61-gmnas-usb.yaml
cat > "$CFG" <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    usb-tether:
      match:
        name: "usb*"
      dhcp4: true
      optional: true
    enx-tether:
      match:
        name: "enx*"
      dhcp4: true
      optional: true
EOF
chmod 600 "$CFG"
netplan generate 2>/dev/null || true
netplan apply 2>/dev/null || true

# Wait FOREVER for internet, re-applying netplan each round so a freshly
# plugged tether is picked up. Ctrl-C to abort back to the menu.
n=0
while ! net_online; do
    n=$((n+1))
    echo ""
    echo "  ${BR}>>> PLUG IN THE PHONE USB TETHER NOW <<<${RB}"
    echo "  (phone must have working internet) — attempt $n, retrying forever. Ctrl-C to cancel."
    for i in $(ls /sys/class/net 2>/dev/null | grep -E '^(usb|enx|en|eth)'); do
        ip link set "$i" up 2>/dev/null || true
    done
    netplan apply 2>/dev/null || true
    sleep 10
done

echo ">> Internet OK over tether. Starting resume install..."
exec gm-install-all
