#!/bin/bash
# Log out of a Pi's iSCSI target. Usage: pi-detach.sh <pi-ip-or-host>
set -u
PI="$1"; PI_IP=$(getent ahostsv4 "$PI" | awk '{print $1; exit}'); PI_IP=${PI_IP:-$PI}
for IQN in $(sudo iscsiadm -m session 2>/dev/null | grep "$PI_IP:" | awk '{print $4}'); do
  sudo iscsiadm -m node -T "$IQN" --logout >/dev/null && echo "detached $IQN"
done
exit 0
