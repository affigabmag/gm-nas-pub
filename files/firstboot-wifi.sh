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

# Launch the captive portal AP. wifi-connect blocks until the user submits
# their home WiFi credentials and the device successfully connects, then exits 0.
"$WIFI_CONNECT" \
    --portal-ssid "$PORTAL_SSID" \
    --portal-passphrase "$PORTAL_PASSPHRASE" \
    --ui-directory "$UI_DIR"

# Connected to home WiFi -> record provisioning so we never show the AP again.
mkdir -p "$(dirname "$FLAG")"
touch "$FLAG"
