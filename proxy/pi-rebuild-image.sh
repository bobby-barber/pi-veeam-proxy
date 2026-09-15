#!/bin/bash
# Rebuild a bootable whole-disk image from the per-partition files that Veeam "Publish Disks"
# exposes on a Linux target (/run/media/Veeam.Mount.Disks/<guid>/<diskid>_<n>).
# Usage: pi-rebuild-image.sh <publish-dir> <sfdisk-dump-file> <output.img>
#   <sfdisk-dump-file> is the output of `sfdisk -d /dev/mmcblk0` taken on the Pi (keep one per Pi);
#   it carries the disk size implicitly via the last partition, the MBR id (label-id) and offsets.
set -eu
PUB="$1"; DUMP="$2"; IMG="$3"
DISKID=$(awk '/^label-id:/ {sub("0x","",$2); print $2}' "$DUMP")
# total size = end of last partition (sectors) * 512; Raspberry Pi OS puts p2 at the very end
LAST=$(awk '/^\/dev/ {gsub(",","",$0); for(i=1;i<=NF;i++){if($i=="start=")s=$(i+1); if($i=="size=")z=$(i+1)}; e=s+z; if(e>m)m=e} END{print m}' "$DUMP")
rm -f "$IMG"; truncate -s $((LAST*512)) "$IMG"
sed -e '/^device:/d' "$DUMP" | sfdisk --quiet "$IMG"
n=0
awk '/^\/dev/ {gsub(",","",$0); for(i=1;i<=NF;i++){if($i=="start=")print $(i+1)}}' "$DUMP" | while read -r start; do
  src="$PUB/${DISKID}_$n"
  [ -f "$src" ] || { echo "missing $src" >&2; exit 1; }
  echo "$(date +%T) partition $n ($(stat -c %s "$src") bytes) -> sector $start"
  dd if="$src" of="$IMG" bs=4M seek=$((start*512)) oflag=seek_bytes conv=notrunc,sparse status=none
  n=$((n+1))
done
echo "$(date +%T) done: $(du -h "$IMG" | cut -f1) allocated"; fdisk -l "$IMG" | grep -E "identifier|^$IMG"
