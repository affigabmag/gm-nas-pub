#!/usr/bin/env bash
# ============================================================================
# gm-benchmark — quick CPU/RAM/disk score, "Windows/Linux Experience Index" style.
# Installs sysbench on first run (needs internet). Uses the real root disk
# device (not hardcoded /dev/sda) so it works regardless of storage layout.
#     sudo gm-benchmark
# ============================================================================
set -u

if ! command -v sysbench >/dev/null 2>&1; then
    echo "Installing sysbench (one-time, needs internet)..."
    sudo apt-get update -y >/dev/null 2>&1
    sudo apt-get install -y sysbench >/dev/null 2>&1
    if ! command -v sysbench >/dev/null 2>&1; then
        echo "ERROR: could not install sysbench (check internet / apt)." >&2
        exit 1
    fi
fi

# Root disk device (e.g. /dev/sda), not hardcoded, so this works on nvme/mmcblk too.
DISKDEV="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)"
[ -z "$DISKDEV" ] && DISKDEV="sda"
DISKPATH="/dev/$DISKDEV"

echo -e "\n============================================\n          WINDOWS EXPERIENCE INDEX          \n============================================\n"

echo -n "[1/3] Benchmarking Processor... "
cpu_raw=$(sysbench cpu --threads="$(nproc)" --cpu-max-prime=20000 run | grep "events per second:" | awk '{print $4}')
echo "Done."

echo -n "[2/3] Benchmarking Memory...    "
mem_raw=$(sysbench memory --threads="$(nproc)" run | grep "transferred (" | awk -F'(' '{print $2}' | awk '{print $1}')
echo "Done."

echo -n "[3/3] Benchmarking Disk ($DISKPATH)... "
disk_raw=$(sudo dd if="$DISKPATH" of=/dev/null bs=1M count=300 2>&1 | tail -n1 | \
    awk '{for(i=1;i<=NF;i++) if($i~/^[0-9.]+$/ && ($(i+1)=="MB/s" || $(i+1)=="GB/s" || $(i+1)=="MiB/s")) {print $i; break}}')
echo "Done."

cpu_score=$(echo "$cpu_raw" | awk '{ score = 1.0 + ($1 / 400); if(score > 9.9) score = 9.9; if(score < 1.0) score = 1.0; printf "%.1f", score }')
mem_score=$(echo "$mem_raw" | awk '{ score = 1.0 + ($1 / 1600); if(score > 9.9) score = 9.9; if(score < 1.0) score = 1.0; printf "%.1f", score }')
disk_score=$(echo "$disk_raw" | awk '{ score = 1.0 + ($1 / 40); if(score > 9.9) score = 9.9; if(score < 1.0) score = 1.0; printf "%.1f", score }')
base_score=$(echo -e "$cpu_score\n$mem_score\n$disk_score" | sort -n | head -n1)

echo -e "\n--------------------------------------------"
echo -e " [Processor]  Calculations/sec:  $cpu_score  (Raw: $cpu_raw Ev/s)"
echo -e " [Memory RAM] Memory operations: $mem_score  (Raw: $mem_raw MiB/s)"
echo -e " [Primary HD] Disk data rate:    $disk_score  (Raw: $disk_raw MB/s)"
echo -e "--------------------------------------------"
echo -e " Base Score:                     $base_score"
echo -e "--------------------------------------------\n"
