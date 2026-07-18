#!/usr/bin/env bash
# ============================================================================
# gm-usb — mount the Ventoy USB and apply edited helper scripts OFFLINE.
# Lets you iterate without reinstalling: edit the scripts in /gmnas on the
# Ventoy drive (from Windows), plug the drive into the mini PC, then:
#     sudo gm-usb apply
#
# Usage:  sudo gm-usb [mount | apply | umount]
#   mount  - mount the Ventoy drive at /mnt/ventoy and list /gmnas
#   apply  - mount + copy /gmnas/*.sh into /usr/local/bin (offline update)
#   umount - unmount /mnt/ventoy
# ============================================================================
set -u
MNT=/mnt/ventoy

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo gm-usb ${1:-mount}" >&2
    exit 1
fi

LOGDIR=/var/log/gm-nas; mkdir -p "$LOGDIR" 2>/dev/null || true
exec > >(tee -a "$LOGDIR/gm-usb.log") 2>&1
echo "$(date '+%F %T') ===== gm-usb ${1:-mount} start ====="

find_dev() {
    local d
    d="$(blkid -L Ventoy 2>/dev/null)"
    [ -z "$d" ] && d="$(lsblk -rno NAME,LABEL | awk '$2=="Ventoy"{print "/dev/"$1}' | head -1)"
    echo "$d"
}

mount_usb() {
    if mountpoint -q "$MNT"; then echo "Already mounted at $MNT"; return 0; fi
    local d; d="$(find_dev)"
    if [ -z "$d" ]; then echo "Ventoy USB not found — plug it into the mini PC." >&2; return 1; fi
    mkdir -p "$MNT"
    if mount "$d" "$MNT" 2>/dev/null; then echo "Mounted $d at $MNT"; else
        echo "Mount failed (exfat support? try: apt-get install -y exfatprogs)" >&2; return 1
    fi
}

case "${1:-mount}" in
    mount)
        echo "=== drives / partitions ==="
        lsblk -o NAME,SIZE,LABEL,FSTYPE,TRAN,MOUNTPOINT | grep -vE '^loop'
        echo
        auto="$(find_dev)"
        [ -n "$auto" ] && echo "(detected Ventoy at: $auto)"
        read -rp "Device to mount [$auto]: " sel
        sel="${sel:-$auto}"
        if [ -z "$sel" ]; then echo "nothing selected"; exit 0; fi
        sel="/dev/${sel#/dev/}"
        mkdir -p "$MNT"
        mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null
        if mount "$sel" "$MNT" 2>/dev/null; then
            echo "Mounted $sel at $MNT"
            echo "--- $MNT ---"; ls -1 "$MNT" 2>/dev/null
            [ -d "$MNT/gmnas" ] && { echo "--- $MNT/gmnas ---"; ls -1 "$MNT/gmnas"; }
        else
            echo "mount failed for $sel (wrong device? exfat support?)" >&2; exit 1
        fi
        ;;
    apply)
        mount_usb || exit 1
        S="$MNT/gmnas"
        [ -d "$S" ] || { echo "no $S on the drive" >&2; exit 1; }
        for s in gmnas gm-update join-wifi reset-setup gm-usb; do
            if [ -f "$S/$s.sh" ]; then
                cp "$S/$s.sh" "/usr/local/bin/$s" && chmod +x "/usr/local/bin/$s" && echo "updated: $s"
            fi
        done
        echo "done — helper scripts applied from the USB."
        ;;
    umount|unmount)
        umount "$MNT" 2>/dev/null && echo "unmounted $MNT" || echo "was not mounted"
        ;;
    *)
        echo "usage: sudo gm-usb [mount|apply|umount]" >&2; exit 1 ;;
esac
