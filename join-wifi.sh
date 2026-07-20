#!/usr/bin/env bash
# ============================================================================
# gm-nas — connect to WiFi, OFFLINE-capable.
# The base (offline) install has no NetworkManager. This uses netplan +
# wpa_supplicant (installed from the Ventoy USB packages staged at
# /root/wifi-debs) so WiFi works before any internet is available.
# Run:  sudo join-wifi [SSID] [PASSWORD]     (defaults: home / teva2000)
# ============================================================================
set -u
SSID="${1:-home}"
PASS="${2:-teva2000}"
DEBS=/root/wifi-debs

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo join-wifi [SSID] [PASSWORD]" >&2
    exit 1
fi

LOGDIR=/var/log/gm-nas; mkdir -p "$LOGDIR" 2>/dev/null || true
exec > >(tee -a "$LOGDIR/join-wifi.log") 2>&1
echo "$(date '+%F %T') ===== join-wifi start (SSID=$SSID) ====="

# --- 1) Ensure wpa_supplicant is present -------------------------------------
# Not on the minimal base install. Install offline from the WiFi .debs: first
# from /root/wifi-debs, else copy them off the Ventoy USB (works now that the
# system is booted -- the USB is no longer busy serving the installer ISO).
if ! command -v wpa_supplicant >/dev/null 2>&1; then
    if ! ls "$DEBS"/*.deb >/dev/null 2>&1; then
        if [ -t 1 ]; then BR=$'\e[5;1;31m'; RB=$'\e[0m'; else BR=; RB=; fi
        echo "== WiFi packages not installed yet =="
        echo "   ${BR}>>> PLUG THE gm-nas SETUP USB BACK IN NOW, then press ENTER <<<${RB}"
        read -t 120 _ 2>/dev/null || true
        mkdir -p "$DEBS"
        MP=/mnt/gmusb; mkdir -p "$MP"
        dev="$(blkid -L Ventoy 2>/dev/null)"
        [ -z "$dev" ] && dev="$(lsblk -rno NAME,LABEL 2>/dev/null | awk '$2=="Ventoy"{print "/dev/"$1; exit}')"
        if [ -n "$dev" ] && { mount "$dev" "$MP" 2>/dev/null || mount -t exfat "$dev" "$MP" 2>/dev/null; }; then
            cp -f "$MP/gmnas/wifi-debs/"*.deb "$DEBS"/ 2>/dev/null && echo "   copied WiFi packages from USB"
            umount "$MP" 2>/dev/null || true
        fi
    fi
    if ls "$DEBS"/*.deb >/dev/null 2>&1; then
        echo "== installing WiFi packages (offline) =="
        dpkg -i "$DEBS"/*.deb || echo "!! dpkg reported errors installing WiFi packages." >&2
    else
        echo "============================================================"
        echo "  ERROR: WiFi packages not found (looked in $DEBS and the USB)."
        echo "  Plug in the gm-nas setup USB and run 'Connect to WiFi' again."
        echo "============================================================"
        exit 1
    fi
fi
if ! command -v wpa_supplicant >/dev/null 2>&1; then
    echo "ERROR: wpa_supplicant still not available after install. Cannot continue." >&2
    exit 1
fi

# --- 2) Find the WiFi interface ---------------------------------------------
DEV=""
for i in /sys/class/net/*; do
    [ -d "$i/wireless" ] && { DEV="$(basename "$i")"; break; }
done
if [ -z "$DEV" ]; then
    echo "============================================================"
    echo "  ERROR: no WiFi adapter detected."
    echo "  (No /sys/class/net/*/wireless interface.)"
    echo "  If it's a USB WiFi dongle, its driver may not be in the"
    echo "  base kernel — that would need a driver package too."
    echo "============================================================"
    exit 1
fi
echo "== WiFi interface: $DEV =="

# --- 3) Write a netplan WiFi profile (networkd + wpa_supplicant) -------------
CFG=/etc/netplan/60-gmnas-wifi.yaml
cat > "$CFG" <<EOF
network:
  version: 2
  renderer: networkd
  wifis:
    ${DEV}:
      dhcp4: true
      optional: true
      access-points:
        "${SSID}":
          password: "${PASS}"
EOF
chmod 600 "$CFG"
echo "== wrote $CFG =="

# Mark provisioned (so any first-boot AP logic won't fire).
mkdir -p /etc/homenas
touch /etc/homenas/provisioned

# --- 4) Apply + wait briefly for an IP --------------------------------------
netplan generate 2>/dev/null || true
netplan apply 2>/dev/null || true
echo "== applying WiFi, waiting for an IP (up to 30s) =="
ip=""
for _ in $(seq 1 15); do
    sleep 2
    ip="$(ip -4 -o addr show dev "$DEV" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    [ -n "$ip" ] && break
done

echo
if [ -n "$ip" ]; then
    echo ">> Connected to '$SSID'. IP: $ip"
    if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
        echo ">> Internet OK. You can now run 'Resume install' from the menu."
    else
        echo ">> Got an IP but no internet yet — check the WiFi password / router."
    fi
else
    echo ">> No IP yet. WiFi may still be associating, or the password is wrong."
    echo "   Re-run 'Connect to WiFi' from the menu to try again."
fi
