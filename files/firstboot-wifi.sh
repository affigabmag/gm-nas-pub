#!/usr/bin/env bash
# ============================================================================
# gm-nas first-boot WiFi provisioning wrapper
# ----------------------------------------------------------------------------
# Runs at boot via homenas-firstboot.service. If the device has not been
# provisioned yet, it starts wifi-connect: a temporary WiFi access point +
# captive portal the end user joins to pick their home WiFi. Once the device
# joins the home network, wifi-connect exits and we write the provisioned flag
# so this never runs again.
#
# SAFE FOR PUBLIC REPO: the only credential here is the SETUP AP passphrase,
# which by design is fixed, printed on the device's physical label, and only
# guards the local first-run setup portal (no internet, no data access).
# ============================================================================
set -euo pipefail

FLAG=/etc/homenas/provisioned

# ---- Setup AP credentials (printed on the physical label) ------------------
# CHANGE THIS before building units, and print it on the label.
# WPA2 passphrase must be 8-63 characters.
PORTAL_SSID="GMNas-Setup"
PORTAL_PASSPHRASE="gmnas2026"

UI_DIR="/usr/local/lib/wifi-connect/ui"
WIFI_CONNECT="/usr/local/lib/wifi-connect/wifi-connect"

# Already provisioned -> boot normally, do nothing.
if [ -f "$FLAG" ]; then
    exit 0
fi

# Give NetworkManager a moment to bring up radios.
sleep 5

# If the device is already online via Ethernet or a known WiFi, skip the portal
# and just mark provisioned (nothing for the user to set up).
if nmcli -t -f STATE g 2>/dev/null | grep -q '^connected$'; then
    mkdir -p "$(dirname "$FLAG")"
    touch "$FLAG"
    exit 0
fi

# No WiFi adapter present (or none NetworkManager can drive) -> nothing to
# broadcast. Exit cleanly so the unit doesn't fail/loop; it will try again on
# the next boot in case a WiFi adapter appears. (Handles test benches and any
# unit whose WiFi isn't AP-capable.)
if ! nmcli -t -f TYPE device 2>/dev/null | grep -q '^wifi$'; then
    echo "gm-nas: no WiFi device found — skipping setup AP" >&2
    exit 0
fi

# Snapshot existing WiFi profiles so we can detect the NEW one the user picks.
wifi_profiles() {
    nmcli -t -f NAME,TYPE connection show 2>/dev/null \
        | awk -F: '$2 ~ /wireless/ && $1 !~ /GMNas-Setup|Hotspot|wifi-connect/ {print $1}' | sort
}
BEFORE="$(wifi_profiles)"

# Launch the captive portal AP in the background. wifi-connect captures the
# user's WiFi choice via the portal and creates a NetworkManager profile for
# it. On this hardware the live AP->client switch is unreliable, so we DON'T
# depend on wifi-connect completing the join: as soon as the user's WiFi
# profile appears, we mark provisioned and REBOOT — the adapter comes up fresh
# in client mode and NetworkManager auto-connects to the saved network.
"$WIFI_CONNECT" \
    --portal-ssid "$PORTAL_SSID" \
    --portal-passphrase "$PORTAL_PASSPHRASE" \
    --ui-directory "$UI_DIR" &
WC_PID=$!

# Wait up to ~20 min for the user to submit their WiFi via the portal.
for _ in $(seq 1 600); do
    kill -0 "$WC_PID" 2>/dev/null || break     # wifi-connect exited on its own
    NEW="$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$(wifi_profiles)"))"
    if [ -n "$NEW" ]; then
        # user submitted -> ensure autoconnect, mark provisioned, reboot
        printf '%s\n' "$NEW" | while read -r c; do
            [ -n "$c" ] && nmcli connection modify "$c" connection.autoconnect yes 2>/dev/null || true
        done
        mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"
        kill "$WC_PID" 2>/dev/null || true
        sleep 3
        systemctl reboot
        exit 0
    fi
    sleep 2
done

# wifi-connect exited by itself. If it actually connected, finish + reboot.
if nmcli -t -f STATE g 2>/dev/null | grep -q '^connected$'; then
    mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"; sleep 3; systemctl reboot
fi
exit 0
