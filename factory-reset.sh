#!/usr/bin/env bash
# ============================================================================
# gm-nas — full factory reset: undo the welcome wizard AND the WiFi setup, so
# the box replays the ENTIRE first-boot experience (AP -> home WiFi -> welcome
# wizard account creation -> default shares) without reflashing the OS.
#
# Removes: the admin account created by the wizard (+ its Samba login), the
# shares list + managed Samba config (so defaults reseed fresh), the admin/
# password-not-set bookkeeping, and the hostname (back to "my-gmnas"). Then
# does the same WiFi reset as reset-setup.sh.
#
# KEEPS: everything under /srv/storage (your actual files) is untouched --
# only accounts, Samba logins, share definitions and WiFi are reset.
#
# Run on the mini PC:   sudo bash factory-reset.sh
# ============================================================================
set -u

LOGDIR=/var/log/gm-nas; LOGF="$LOGDIR/factory-reset.log"; mkdir -p "$LOGDIR" 2>/dev/null || true
log() { printf '%s [factory-reset] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGF" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo bash factory-reset.sh" >&2
    exit 1
fi

ADMIN_USER_FILE=/etc/homenas/admin-user
SHARES_JSON=/etc/homenas/shares.json
SHARES_SEEDED_FLAG=/etc/homenas/shares-seeded
PW_FLAG=/etc/homenas/password-not-set
SMB_CONF=/etc/samba/smb.conf
SMB_MARK="# --- gm-nas managed shares ---"
DEFAULT_HOSTNAME=my-gmnas

log "=============== factory-reset start ==============="
log "stopping welcome app"
systemctl stop gmnas-welcome.service 2>/dev/null || true

# --- Remove the wizard-created admin account (never the built-in 'gmnas') --
if [ -f "$ADMIN_USER_FILE" ]; then
    admin="$(cat "$ADMIN_USER_FILE" 2>/dev/null)"
    if [ -n "$admin" ] && [ "$admin" != "gmnas" ] && id "$admin" >/dev/null 2>&1; then
        command -v smbpasswd >/dev/null 2>&1 && smbpasswd -x "$admin" 2>/dev/null
        userdel -r "$admin" 2>/dev/null
        log "removed admin account: $admin (Linux + Samba + home dir)"
    fi
    rm -f "$ADMIN_USER_FILE"
fi

# --- Reset shares: drop our managed block from smb.conf, clear the list -----
if [ -f "$SMB_CONF" ] && grep -qF "$SMB_MARK" "$SMB_CONF" 2>/dev/null; then
    head -n "$(( $(grep -nF "$SMB_MARK" "$SMB_CONF" | head -1 | cut -d: -f1) - 1 ))" "$SMB_CONF" > "$SMB_CONF.tmp" \
        && mv "$SMB_CONF.tmp" "$SMB_CONF"
    log "stripped gm-nas managed block from smb.conf"
fi
rm -f "$SHARES_JSON" "$SHARES_SEEDED_FLAG"
log "cleared shares.json + seeded flag -- defaults reseed on next welcome load"

# --- Wipe storage: reformat the partition instead of rm -rf (seconds, not
# minutes on a large disk, and guarantees a truly clean filesystem) ---------
log "locating storage partition"
STORAGE_DEV="$(findmnt -no SOURCE /srv/storage 2>/dev/null)"
STORAGE_FSTYPE="$(findmnt -no FSTYPE /srv/storage 2>/dev/null)"
STORAGE_UUID="$(blkid -s UUID -o value "$STORAGE_DEV" 2>/dev/null)"

if [ -n "$STORAGE_DEV" ]; then
    log "unmounting $STORAGE_DEV"
    umount /srv/storage 2>/dev/null || fuser -km /srv/storage 2>/dev/null
    sleep 1
    umount /srv/storage 2>/dev/null || true

    log "reformatting $STORAGE_DEV ($STORAGE_FSTYPE) -- keeping UUID so fstab still matches"
    case "$STORAGE_FSTYPE" in
        ext4|"") mkfs.ext4 -F -q -L storage ${STORAGE_UUID:+-U "$STORAGE_UUID"} "$STORAGE_DEV" ;;
        *)       mkfs.ext4 -F -q -L storage ${STORAGE_UUID:+-U "$STORAGE_UUID"} "$STORAGE_DEV" ;;
    esac

    mkdir -p /srv/storage
    mount /srv/storage 2>/dev/null || mount -a
    chown root:gmnas /srv/storage 2>/dev/null || true
    chmod 2775 /srv/storage 2>/dev/null || true
    log "storage partition reformatted and reset to factory state"
else
    log "WARNING: could not resolve /srv/storage's device, falling back to rm -rf"
    rm -rf /srv/storage/* 2>/dev/null || true
    mkdir -p /srv/storage 2>/dev/null || true
    chown root:gmnas /srv/storage 2>/dev/null || true
    chmod 2775 /srv/storage 2>/dev/null || true
fi

# --- Back to the b1 flow: welcome page asks for a fresh account again -------
mkdir -p "$(dirname "$PW_FLAG")"
touch "$PW_FLAG"
log "password-not-set flag restored -- welcome wizard will run again"

# --- Hostname back to factory default ---------------------------------------
hostnamectl set-hostname "$DEFAULT_HOSTNAME" 2>/dev/null || true
if [ -f /etc/hosts ]; then
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$DEFAULT_HOSTNAME/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$DEFAULT_HOSTNAME" >> /etc/hosts
    fi
fi
log "hostname reset to $DEFAULT_HOSTNAME"

# --- Same WiFi reset as reset-setup.sh: forget the network, relaunch the AP -
log "disconnecting WiFi so the box is not 'online'"
for dev in $(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1}'); do
    nmcli device disconnect "$dev" 2>/dev/null || true
    log "  disconnected $dev"
done
nmcli -t -f NAME,TYPE connection show 2>/dev/null \
    | awk -F: '$2 ~ /wireless/ && $1 !~ /GMNas-Setup|Hotspot|wifi-connect/ {print $1}' \
    | while read -r c; do
        [ -n "$c" ] && { nmcli connection delete "$c" 2>/dev/null && log "  deleted saved WiFi profile: $c"; }
      done
rm -f /etc/homenas/provisioned

log "done -- rebooting now; homenas-firstboot launches GMNas-Setup AP on boot"
log "connect a phone to WiFi 'GMNas-Setup', browse http://192.168.42.1"
sleep 2
log "rebooting now"
systemctl reboot
