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

# --- 0) If NetworkManager is already installed+running (i.e. Resume install
#        has already happened), use it directly via nmcli -- the ORIGINAL,
#        simpler mechanism. Do NOT write a networkd netplan profile in that
#        case: it would make NetworkManager mark the WiFi device "unmanaged",
#        breaking the First-time wizard AP (wifi-connect + nmcli need to see
#        a managed wifi device). Only fall back to the offline
#        networkd+wpa_supplicant path when NetworkManager genuinely isn't
#        available yet.
if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "== NetworkManager present -- joining via nmcli =="
    DEV="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
    # If DEV was already associated to this SSID from a previous attempt, its
    # old IP/lease can still be sitting on the interface for a few seconds
    # after we ask it to reconnect with a NEW (possibly wrong) password --
    # checking "is there any IP" alone reads that stale lease as success.
    # Disconnect first so a failed auth genuinely has no IP to show.
    if [ -n "$DEV" ]; then
        nmcli device disconnect "$DEV" >/dev/null 2>&1
        # Wait for the teardown to actually finish -- reconnecting while the
        # device is still "deactivating" can fail for reasons that have
        # nothing to do with the password, and get misreported as a wrong
        # password (intermittently, since it's a race).
        for _ in $(seq 1 10); do
            st="$(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: -v d="$DEV" '$1==d{print $2}')"
            [ "$st" = "disconnected" ] && break
            sleep 0.5
        done
    fi
    nmcli connection delete "$SSID" 2>/dev/null || true
    nmcli connection add type wifi con-name "$SSID" ${DEV:+ifname "$DEV"} ssid "$SSID" \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASS" \
        connection.autoconnect yes connection.autoconnect-priority 100 2>/dev/null \
        && echo "  connection '$SSID' created"
    NEW_UUID="$(nmcli -t -f connection.uuid connection show "$SSID" 2>/dev/null | cut -d: -f2)"
    up_err="$(nmcli connection up "$SSID" 2>&1)"; up_rc=$?
    if [ "$up_rc" -ne 0 ]; then
        # One retry -- a transient device-state race on the first attempt is
        # common and shouldn't be reported as a wrong password.
        sleep 2
        up_err="$(nmcli connection up "$SSID" 2>&1)"; up_rc=$?
    fi
    sleep 2
    active_uuid="$(nmcli -t -f GENERAL.CON-UUID device show "$DEV" 2>/dev/null | cut -d: -f2)"
    ip=""
    [ "$up_rc" -eq 0 ] && [ -n "$NEW_UUID" ] && [ "$active_uuid" = "$NEW_UUID" ] \
        && ip="$(ip -4 -o addr show dev "$DEV" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    echo
    if [ -n "$ip" ]; then
        echo ">> Connected to '$SSID'. IP: $ip"
        mkdir -p /etc/homenas; touch /etc/homenas/provisioned
    else
        # Don't guess "wrong password" when nmcli's own error says something
        # else entirely -- e.g. "base network connection was interrupted"
        # is NetworkManager reporting the activation got yanked out from
        # under it (a device-state race), which has nothing to do with the
        # password and was misleading people into re-entering a correct one.
        case "$up_err" in
            *"802-1x"*|*supplicant*|*"Secrets were required"*|*"No reason given"*)
                echo ">> Failed to connect to '$SSID' -- wrong password, or out of range." ;;
            *)
                echo ">> Failed to connect to '$SSID'." ;;
        esac
        [ -n "$up_err" ] && echo "   nmcli: $up_err"
        nmcli connection delete "$SSID" 2>/dev/null || true
        echo "   Re-run 'Connect to WiFi' from the menu to try again."
    fi
    exit 0
fi

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
