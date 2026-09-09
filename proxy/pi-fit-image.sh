#!/bin/bash
# Fit a rebuilt Pi card image onto a card that is smaller than the original:
# shrink the ext4 root filesystem, shorten partition 2, truncate the image file.
# Usage: pi-fit-image.sh <image> <card-size-in-512-byte-sectors> [<sfdisk-dump-file>]
#   card size: `diskutil info /dev/diskN | grep "512-Byte-Units"` (macOS) or `blockdev --getsz` (Linux)
#   Needs e2fsprogs >= 1.47 for Debian 13 ext4 (orphan_file); set E2FS=/opt/e2fsprogs/sbin if built locally.
set -eu
IMG="$1"; CARD_SECTORS="$2"; DUMP="${3:-}"
E=${E2FS:-/opt/e2fsprogs/sbin}; [ -x "$E/resize2fs" ] || E=/usr/sbin
P1_START=16384; P1_SIZE=1048576; P2_START=1064960; DISKID=4ed3ef9d
if [ -n "$DUMP" ]; then
  DISKID=$(awk '/^label-id:/ {sub("0x","",$2); print $2}' "$DUMP")
  read -r P1_START P1_SIZE P2_START < <(awk '/^\/dev/ {gsub(",","",$0); for(i=1;i<=NF;i++){if($i=="start=")s[n]=$(i+1); if($i=="size=")z[n]=$(i+1)}; n++} END{print s[0], z[0], s[1]}' "$DUMP")
fi
P2_SIZE=$((CARD_SECTORS-P2_START))
L=$(losetup -f --show -P "$IMG")
"$E/e2fsck" -fy "${L}p2" >/dev/null || true          # replays the journal left by the frozen snapshot
"$E/resize2fs" "${L}p2" $((P2_SIZE/8))                 # size in 4 KiB blocks (no unit suffix!)
"$E/e2fsck" -fn "${L}p2" | tail -1
losetup -d "$L"
sfdisk --quiet "$IMG" <<T
label: dos
label-id: 0x$DISKID
unit: sectors
start=$P1_START, size=$P1_SIZE, type=c
start=$P2_START, size=$P2_SIZE, type=83
T
truncate -s $((CARD_SECTORS*512)) "$IMG"
fdisk -l "$IMG" | grep -E "identifier|^$IMG"
