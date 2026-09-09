#!/bin/bash
# Log in to a Pi's iSCSI target (idempotent). Usage: pi-attach.sh <pi-ip-or-host> [--relogin]
# --relogin: log out first (refreshes the LUN's read-only flag and resets the agent's change tracking
#            because the block device is recreated).
set -eu
PI="$1"; RELOGIN="${2:-}"
PI_IP=$(getent ahostsv4 "$PI" | awk '{print $1; exit}'); PI_IP=${PI_IP:-$PI}
IQN=$(sudo iscsiadm -m discovery -t sendtargets -p "$PI_IP" | awk -v p="$PI_IP" '$1 ~ "^"p":" {print $2; exit}')
[ -z "$IQN" ] && { echo "no target discovered at $PI_IP" >&2; exit 1; }
HOST=${IQN##*:pi-}
if sudo iscsiadm -m session 2>/dev/null | grep -q " $IQN "; then
  if [ "$RELOGIN" = "--relogin" ]; then
    sudo iscsiadm -m node -T "$IQN" --logout >/dev/null
    for i in $(seq 1 20); do [ -e "/dev/pi/$HOST" ] || break; sleep 0.5; done
  else
    echo "attached (already) $IQN as $(readlink -f /dev/pi/$HOST 2>/dev/null || echo ?)"; exit 0
  fi
fi
# other portals of this target (old DHCP addresses): log their sessions out and forget the records,
# otherwise node.startup=automatic keeps re-creating a duplicate session and a second sdX device
# (`iscsiadm -m node` lists "portal,tpgt iqn" per record; with -T it would dump key=value pairs instead)
for p in $(sudo iscsiadm -m node 2>/dev/null | awk -v q="$IQN" '$2==q {print $1}' | cut -d, -f1 | grep -v "^$PI_IP:" || true); do
  sudo iscsiadm -m node -T "$IQN" -p "${p%:*}" --logout >/dev/null 2>&1 || true
  sudo iscsiadm -m node -T "$IQN" -p "${p%:*}" -o delete >/dev/null 2>&1 || true
done
sudo iscsiadm -m node -T "$IQN" -p "$PI_IP" --login >/dev/null
for i in $(seq 1 30); do [ -e "/dev/pi/$HOST" ] && break; sleep 1; done
[ -e "/dev/pi/$HOST" ] || { echo "device /dev/pi/$HOST did not appear" >&2; exit 1; }
DEV=$(readlink -f "/dev/pi/$HOST")
echo "attached $IQN from $PI_IP as $DEV ro=$(cat /sys/block/$(basename $DEV)/ro)"
