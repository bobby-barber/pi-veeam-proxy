#!/bin/bash
# Persistent iSCSI export of a Raspberry Pi's boot disk for a Veeam proxy. Run as root.
#   idle   : (boot) build the disk image device from the LIVE partitions, export it READ-ONLY
#   start  : freeze, snapshot every partition (blksnap), swap the image to the snapshots, LUN read-write
#   stop   : LUN read-only, swap back to the live partitions, destroy the snapshot
#   status : show what is exported and whether a snapshot is active
#   down   : remove the export and the image device entirely
# The live card is never writable from the network: idle = read-only LUN over live partitions,
# job = read-write LUN over snapshot images (writes land in the COW area in tmpfs).
# Why partitions, not the disk: the blksnap filter binds to the exact bdev (tracker.c: bio->bi_bdev->bd_filter).
set -euo pipefail
ACTION="${1:-status}"
PROXY_IP="${2:-$(cat /etc/pi-veeam/proxy 2>/dev/null || echo 10.10.0.20)}"
WORK=/run/pi-veeam                     # tmpfs: COW difference storage, header/tail copies, state
DIFF_LIMIT="${DIFF_LIMIT:-512M}"
HOST=$(hostname -s)
IQN="iqn.2026-09.local.lab:pi-${HOST}"
DM_NAME="pi-${HOST}-snap"
TID=1
STATE=$WORK/snapshot
ROOT_SRC=$(findmnt -n -o SOURCE /)
ROOT_DISK=/dev/$(lsblk -no PKNAME "$ROOT_SRC")

log() { echo "[pi-veeam-export] $*"; }
tgt() { tgtadm --lld iscsi "$@"; }
parts() {  # "<dev> <start> <size>" per partition, disk order
  sfdisk -d "$ROOT_DISK" | awk -F'[ ,=]+' '/^\/dev/ {for(i=1;i<=NF;i++){if($i=="start")s=$(i+1); if($i=="size")z=$(i+1)}; print $1, s, z}' | sort -k2,2n
}
# build a dm table; $1 = "live" (partition devices) or "snap" (blksnap image devices)
build_table() {
  local mode=$1 DISK_SECT FIRST_START LAST LAST_END TAIL_SECT TAIL_COPY POS TABLE p PDEV PSTART PSIZE SRC
  DISK_SECT=$(blockdev --getsz "$ROOT_DISK")
  mapfile -t PARTS < <(parts)
  set -- ${PARTS[0]}; FIRST_START=$2
  LAST=${PARTS[$((${#PARTS[@]}-1))]}; set -- $LAST; LAST_END=$(( $2 + $3 ))
  TAIL_SECT=$(( DISK_SECT - LAST_END )); TAIL_COPY=$(( TAIL_SECT < 2048 ? TAIL_SECT : 2048 ))
  if [ ! -f "$WORK/header.img" ]; then
    dd if="$ROOT_DISK" of="$WORK/header.img" bs=512 count="$FIRST_START" status=none
    losetup -f --show "$WORK/header.img" > "$WORK/loop_h"
    if [ "$TAIL_COPY" -gt 0 ]; then
      dd if="$ROOT_DISK" of="$WORK/tail.img" bs=512 skip=$(( DISK_SECT - TAIL_COPY )) count="$TAIL_COPY" status=none
      losetup -f --show "$WORK/tail.img" > "$WORK/loop_t"
    fi
  fi
  TABLE="0 $FIRST_START linear $(cat $WORK/loop_h) 0"
  POS=$FIRST_START
  for p in "${PARTS[@]}"; do
    set -- $p; PDEV=$1; PSTART=$2; PSIZE=$3
    if [ "$mode" = snap ]; then SRC=$(blksnap snapshot_info --device "$PDEV" --field image); [ -b "$SRC" ] || { log "no image for $PDEV"; return 1; }
    else
      # dm opens its targets exclusively and the mounted partitions are busy; a loop device over the
      # partition is not, so idle maps loop(partition). Writes are blocked by the LUN's readonly flag.
      local LF="$WORK/loop_$(basename $PDEV)"
      [ -f "$LF" ] && [ -b "$(cat $LF)" ] || losetup -f --show "$PDEV" > "$LF"
      SRC=$(cat "$LF")
    fi
    [ "$PSTART" -gt "$POS" ] && TABLE+=$'\n'"$POS $(( PSTART - POS )) zero"
    TABLE+=$'\n'"$PSTART $PSIZE linear $SRC 0"
    POS=$(( PSTART + PSIZE ))
  done
  local ZERO_TAIL=$(( DISK_SECT - TAIL_COPY - POS ))
  [ "$ZERO_TAIL" -gt 0 ] && TABLE+=$'\n'"$POS $ZERO_TAIL zero"
  [ "$TAIL_COPY" -gt 0 ] && TABLE+=$'\n'"$(( DISK_SECT - TAIL_COPY )) $TAIL_COPY linear $(cat $WORK/loop_t) 0"
  printf '%s\n' "$TABLE"
}
load_table() {  # create or hot-swap the dm device with the table on stdin
  if dmsetup info "$DM_NAME" >/dev/null 2>&1; then
    dmsetup suspend "$DM_NAME"; dmsetup reload "$DM_NAME"; dmsetup resume "$DM_NAME"
  else
    dmsetup create "$DM_NAME"
  fi
  # The dm node's page cache still holds pages from the previous mapping after a table swap; anything
  # reading the node through the cache (tgt without O_DIRECT, buffered loops) would serve stale blocks.
  blockdev --flushbufs "/dev/mapper/$DM_NAME"
}
set_ro() { tgt --op update --mode logicalunit --tid $TID --lun 1 --params readonly="$1"; }

case "$ACTION" in
  idle)
    modprobe veeamblksnap
    mkdir -p "$WORK"
    rm -f /etc/tgt/conf.d/veeam-pi.conf            # milestone-1/2 static config, superseded
    systemctl start tgt
    build_table live | load_table
    if ! tgt --op show --mode target | grep -q "$IQN"; then
      tgt --op new --mode target --tid $TID -T "$IQN"
      # bsoflags=direct: tgt reads the backing device with O_DIRECT, bypassing the page cache entirely
      tgt --op new --mode logicalunit --tid $TID --lun 1 -b "/dev/mapper/$DM_NAME" --bsoflags direct
      tgt --op bind --mode target --tid $TID -I "$PROXY_IP"
    fi
    set_ro 1
    log "idle: $IQN -> /dev/mapper/$DM_NAME (live partitions, READ-ONLY) for $PROXY_IP"
    ;;
  start)
    [ -f "$STATE" ] && { log "snapshot already active: $(cat $STATE)"; exit 1; }
    dmsetup info "$DM_NAME" >/dev/null 2>&1 || "$0" idle "$PROXY_IP"
    mapfile -t PARTS < <(parts)
    DEV_ARGS=(); for p in "${PARTS[@]}"; do set -- $p; DEV_ARGS+=(--device "$1"); blksnap attach --device "$1" >/dev/null 2>&1 || true; done
    SNAP_ID=$(blksnap snapshot_create "${DEV_ARGS[@]}" --file "$WORK" --limit "$DIFF_LIMIT" | grep -oE '[0-9a-f-]{36}' | head -1)
    [ -n "$SNAP_ID" ] || { log "snapshot_create returned no id"; exit 1; }
    FROZEN=(); thaw_all() { for m in "${FROZEN[@]:-}"; do [ -n "$m" ] && fsfreeze -u "$m" 2>/dev/null || true; done; FROZEN=(); }
    trap 'thaw_all; blksnap snapshot_destroy --id "$SNAP_ID" 2>/dev/null; exit 1' ERR
    sync
    for p in "${PARTS[@]}"; do set -- $p; for m in $(findmnt -n -o TARGET -S "$1" 2>/dev/null); do fsfreeze -f "$m" 2>/dev/null && FROZEN+=("$m") || true; done; done
    blksnap snapshot_take --id "$SNAP_ID"
    thaw_all
    build_table snap | load_table
    set_ro 0
    trap - ERR
    echo "$SNAP_ID" > "$STATE"
    log "start: snapshot $SNAP_ID exported READ-WRITE as $IQN"
    ;;
  stop)
    set_ro 1 2>/dev/null || true
    build_table live | load_table
    if [ -f "$STATE" ]; then blksnap snapshot_destroy --id "$(cat $STATE)" || true; rm -f "$STATE"; fi
    log "stop: back to live partitions, READ-ONLY; snapshot destroyed"
    ;;
  status)
    echo "target: $(tgt --op show --mode target | grep -E "^Target|Readonly|Backing store path|I_T nexus" | tr -s ' ' | paste -sd' ')"
    echo "dm:     $(dmsetup table "$DM_NAME" 2>/dev/null | paste -sd'|' || echo none)"
    echo "snap:   $(cat $STATE 2>/dev/null || echo none)"; blksnap snapshot_collect 2>/dev/null || true
    df -h "$WORK" 2>/dev/null | tail -1
    ;;
  down)
    "$0" stop "$PROXY_IP" >/dev/null 2>&1 || true
    tgt --op delete --mode target --tid $TID --force 2>/dev/null || true
    dmsetup remove "$DM_NAME" 2>/dev/null || true
    for f in "$WORK"/loop_*; do [ -f "$f" ] && losetup -d "$(cat $f)" 2>/dev/null; rm -f "$f"; done
    rm -f "$WORK/header.img" "$WORK/tail.img"
    log "down: export removed"
    ;;
  *) echo "usage: $0 idle|start|stop|status|down [proxy-ip]" >&2; exit 2 ;;
esac
