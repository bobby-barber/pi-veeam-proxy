#!/bin/bash
# Veeam pre-job script on the proxy (runs as root, before the data read). Per Pi in
# /etc/pi-veeam/targets: ask the Pi for a fresh frozen snapshot (LUN becomes read-write), then
# re-login so the proxy sees the new content read-write and change tracking starts clean.
set -uo pipefail
TARGETS=${PI_VEEAM_TARGETS:-/etc/pi-veeam/targets}
KEY=/root/.ssh/id_ed25519_pi
rc=0
while read -r PI PI_USER _; do
  case "$PI" in ''|\#*) continue;; esac
  PI_USER=${PI_USER:-pi}
  SSH="ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i $KEY ${PI_USER}@${PI}"
  echo "== $PI: snapshot"
  $SSH "sudo /usr/local/sbin/pi-veeam-export.sh stop" >/dev/null 2>&1 || true      # clear a stale snapshot
  if ! $SSH "sudo /usr/local/sbin/pi-veeam-export.sh start"; then echo "!! $PI: snapshot failed" >&2; rc=1; continue; fi
  OUT=$(/usr/local/sbin/pi-attach.sh "$PI" --relogin </dev/null) || { echo "!! $PI: attach failed" >&2; rc=1; continue; }
  echo "$OUT"; echo "$OUT" | grep -q "ro=0" || { echo "!! $PI: LUN still read-only" >&2; rc=1; }
done < "$TARGETS"
exit $rc
