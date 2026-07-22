#!/usr/bin/env bash
# ============================================================================
# save-fail-log — run this from a shell (Ctrl+Alt+F2) DURING/right after a
# failed offline install, BEFORE rebooting/retrying. Saves the installer's
# logs onto the Ventoy USB so they survive the next disk wipe.
#     bash save-fail-log.sh
# ============================================================================
set -u
DEST=/mnt/gmnas-faillog
mkdir -p "$DEST" 2>/dev/null

MP=/mnt/gmusb
mkdir -p "$MP"
dev="$(blkid -L Ventoy 2>/dev/null)"
[ -z "$dev" ] && dev="$(lsblk -rno NAME,LABEL 2>/dev/null | awk '$2=="Ventoy"{print "/dev/"$1; exit}')"

if [ -z "$dev" ]; then
    echo "ERROR: could not find the Ventoy USB partition. Is it plugged in?"
    exit 1
fi

mount "$dev" "$MP" 2>/dev/null || mount -t exfat "$dev" "$MP" 2>/dev/null
if ! mountpoint -q "$MP"; then
    echo "ERROR: could not mount Ventoy USB ($dev)."
    exit 1
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"
OUT="$MP/gmnas/install-fail-$STAMP"
mkdir -p "$OUT"

cp -r /var/log/installer "$OUT/" 2>/dev/null
journalctl -b 0 --no-pager > "$OUT/journal.log" 2>/dev/null
dmesg > "$OUT/dmesg.log" 2>/dev/null

echo "Saved to: /gmnas/install-fail-$STAMP  on the Ventoy USB."
echo "Contents:"
ls -la "$OUT"

umount "$MP" 2>/dev/null
echo "Done. Safe to reboot/retry now."
