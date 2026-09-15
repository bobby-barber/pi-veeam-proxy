#!/bin/bash
# Veeam post-job script on the proxy (runs as root after the data read). Per Pi: back to the live
# read-only export and destroy the snapshot, then re-login so the device stays present (read-only)
# for the next policy apply / job start.
set -uo pipefail
TARGETS=${PI_VEEAM_TARGETS:-/etc/pi-veeam/targets}
KEY=/root/.ssh/id_ed25519_pi
while read -r PI PI_USER _; do
  case "$PI" in ''|\#*) continue;; esac
  PI_USER=${PI_USER:-pi}
  echo "== $PI: release snapshot"
  ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$KEY" "${PI_USER}@${PI}" "sudo /usr/local/sbin/pi-veeam-export.sh stop" || true
  /usr/local/sbin/pi-attach.sh "$PI" --relogin </dev/null || true
done < "$TARGETS"
exit 0
