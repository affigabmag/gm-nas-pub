#!/usr/bin/env bash
# ============================================================================
# gm-install-all — "Resume install": download + install everything the OFFLINE
# base skipped. Run this from the gmnas menu AFTER you have joined WiFi.
#   Installs: avahi (.local), btop, ttyd, samba, python3-flask, cockpit, NFS,
#             the gm-nas welcome app, and refreshes the helper scripts.
# Stays on netplan/networkd for WiFi (does NOT install NetworkManager, which
# would hijack the WiFi link you just connected).
#     sudo gm-install-all
# ============================================================================
set -u
BASE="https://raw.githubusercontent.com/affigabmag/gm-nas-pub/main"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo gm-install-all" >&2
    exit 1
fi

LOGDIR=/var/log/gm-nas; mkdir -p "$LOGDIR" 2>/dev/null || true
exec > >(tee -a "$LOGDIR/gm-install-all.log") 2>&1
echo "$(date '+%F %T') ===== gm-install-all (resume) start ====="

# Robust online check (routers often block ICMP -> ping alone is unreliable).
net_online() {
    ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && return 0
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && return 0
    timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null && return 0
    timeout 5 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53'  2>/dev/null && return 0
    return 1
}

# --- need internet (retry forever; a flaky link just pauses) ----------------
tries=0
while ! net_online; do
    tries=$((tries+1))
    echo "  NO INTERNET yet (attempt $tries) -- connect WiFi first (menu: Connect to WiFi)."
    echo "  Waiting 10s, will retry forever... (Ctrl-C to abort)"
    sleep 10
done
echo "== internet OK, starting downloads =="

export DEBIAN_FRONTEND=noninteractive

# retry-forever wrapper so a flaky link never fails the install
retry() { local n=1; while true; do "$@" && return 0; echo "  retry $n: $* (waiting 10s)"; sleep 10; n=$((n+1)); done; }

echo "-- apt update + universe --"
retry apt-get update
apt-get install -y software-properties-common >/dev/null 2>&1 || true
add-apt-repository -y universe >/dev/null 2>&1 || true
retry apt-get update

echo "-- apt packages --"
# network-manager is needed here for the "First-time wizard" (GMNas-Setup AP):
# wifi-connect creates/tears down the AP via NetworkManager's D-Bus API, and
# reset-setup.sh uses nmcli. It was intentionally NOT part of the offline base
# (can't install without internet) -- this is the one place it's added back.
# ONE apt-get call for all packages, not a per-package loop: apt rebuilds its
# whole dependency tree/cache from scratch on EVERY invocation, so installing
# 7 packages one-by-one meant paying that cost 7 times -- with universe
# enabled that's a large index to re-resolve repeatedly on this hardware.
retry apt-get install -y avahi-daemon btop ttyd samba python3-flask cockpit nfs-kernel-server network-manager w3m lynx

echo "-- enabling services --"
systemctl enable --now ssh avahi-daemon 2>/dev/null || true
systemctl enable --now smbd nmbd 2>/dev/null || true
systemctl enable --now cockpit.socket 2>/dev/null || true
systemctl enable --now nfs-kernel-server 2>/dev/null || true
systemctl enable --now ttyd.service 2>/dev/null || true
systemctl enable --now NetworkManager 2>/dev/null || true

# --- Hand the WiFi device from networkd back to NetworkManager -------------
# join-wifi.sh (used during the OFFLINE phase, before NetworkManager exists)
# writes /etc/netplan/60-gmnas-wifi.yaml with renderer: networkd. As long as
# that file exists, NetworkManager treats the WiFi device as "unmanaged" --
# nmcli then reports NO wifi device at all, and the First-time wizard
# (wifi-connect + nmcli) silently does nothing. Migrate: read the SSID/
# password out of that file, recreate the same connection under
# NetworkManager, then remove the networkd file so NM can claim the device.
WIFI_NETPLAN=/etc/netplan/60-gmnas-wifi.yaml
if [ -f "$WIFI_NETPLAN" ]; then
    echo "-- migrating WiFi from networkd to NetworkManager --"
    WDEV="$(python3 -c "
import re
d = open('$WIFI_NETPLAN').read()
m = re.search(r'wifis:\s*\n\s*([^\s:]+):', d)
print(m.group(1) if m else '')
")"
    WSSID="$(python3 -c "
import re
d = open('$WIFI_NETPLAN').read()
m = re.search(r'access-points:\s*\n\s*\"(.*)\":', d)
print(m.group(1) if m else '')
")"
    WPASS="$(python3 -c "
import re
d = open('$WIFI_NETPLAN').read()
m = re.search(r'password:\s*\"(.*)\"', d)
print(m.group(1) if m else '')
")"
    if [ -n "$WSSID" ] && [ -n "$WPASS" ]; then
        nmcli connection delete "$WSSID" 2>/dev/null || true
        nmcli connection add type wifi con-name "$WSSID" ${WDEV:+ifname "$WDEV"} ssid "$WSSID" \
            wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WPASS" \
            connection.autoconnect yes connection.autoconnect-priority 100 2>/dev/null \
            && echo "  recreated '$WSSID' under NetworkManager"
        rm -f "$WIFI_NETPLAN"
        netplan generate 2>/dev/null || true
        netplan apply 2>/dev/null || true
        systemctl restart NetworkManager 2>/dev/null || true
        sleep 3
        nmcli connection up "$WSSID" >/dev/null 2>&1 || true
        echo "  WiFi device handed to NetworkManager (was: $WDEV)"
    else
        echo "  WARNING: could not parse SSID/password from $WIFI_NETPLAN -- leaving as-is."
        echo "  You may need to re-run 'Connect to WiFi' after this."
    fi
fi

echo "-- wifi-connect (GMNas-Setup AP for the First-time wizard) --"
mkdir -p /usr/local/lib/wifi-connect/ui
retry curl -fsSL https://github.com/balena-os/wifi-connect/releases/latest/download/wifi-connect-x86_64-unknown-linux-gnu.tar.gz -o /tmp/wifi-connect.tar.gz
tar -xzf /tmp/wifi-connect.tar.gz -C /usr/local/lib/wifi-connect || true
chmod +x /usr/local/lib/wifi-connect/wifi-connect || true
retry curl -fsSL "$BASE/ui/index.html" -o /usr/local/lib/wifi-connect/ui/index.html
for f in generate_204 gen_204 hotspot-detect.html ncsi.txt connecttest.txt redirect success.txt; do
    curl -fsSL "$BASE/ui/$f" -o "/usr/local/lib/wifi-connect/ui/$f" || true
done
retry curl -fsSL "$BASE/files/firstboot-wifi.sh" -o /usr/local/sbin/firstboot-wifi.sh
chmod +x /usr/local/sbin/firstboot-wifi.sh || true
retry curl -fsSL "$BASE/files/homenas-firstboot.service" -o /etc/systemd/system/homenas-firstboot.service
systemctl daemon-reload
systemctl enable homenas-firstboot.service 2>/dev/null || true

if command -v cha >/dev/null 2>&1; then
    echo "  chawan installed: $(command -v cha)"
else
    echo "  WARNING: chawan install failed -- 'Web browser' menu item won't work"
fi

echo "-- welcome app --"
mkdir -p /usr/local/lib/gmnas-welcome
retry curl -fsSL "$BASE/welcome/app.py"              -o /usr/local/lib/gmnas-welcome/app.py
retry curl -fsSL "$BASE/files/gmnas-welcome.service" -o /etc/systemd/system/gmnas-welcome.service
retry curl -fsSL "$BASE/files/ttyd.service"          -o /etc/systemd/system/ttyd.service
systemctl daemon-reload
systemctl enable --now ttyd.service gmnas-welcome.service 2>/dev/null || true

# Helper scripts are NEVER re-downloaded from GitHub here. They already came
# from the seed (the current, correct copies -- e.g. 'gmnas' with the "Check
# internet" menu option). GitHub can be stale/behind the seed; overwriting a
# good local script with an older remote one would silently remove features
# ("x" disappearing from the menu). If you genuinely want the GitHub version,
# use 'gm-update' explicitly -- never as a side effect of resuming install.
curl -fsSL --max-time 20 "$BASE/VERSION" -o /etc/gmnas-build-version 2>/dev/null || true

# storage perms (group may exist only after packages create it; best-effort)
chown root:gmnas /srv/storage 2>/dev/null || true
chmod 2775 /srv/storage 2>/dev/null || true

H="$(hostname).local"
echo "== done =="
echo "  Welcome  : http://$H"
echo "  Cockpit  : https://$H:9090"
echo "  Terminal : http://$H:7681"
echo "  (open the Welcome page to create your account + shares)"
