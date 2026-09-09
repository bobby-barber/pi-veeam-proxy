#!/bin/bash
# Register a new Raspberry Pi with the proxy. Usage: pi-add-target.sh <pi-ip> <pi-hostname> [ssh-user]
# - appends the Pi to /etc/pi-veeam/targets
# - adds a udev alias so its LUN appears as /dev/pi/<hostname> (matched on the iSCSI target IQN)
# - installs the proxy's root key on the Pi if it is not there yet (needs a password once, or an
#   existing key), and verifies passwordless sudo on the Pi
# Afterwards: add object /dev/pi/<hostname> to the VBR policy and Apply Configuration.
set -euo pipefail
PI_IP="$1"; PI_HOST="$2"; PI_USER="${3:-pi}"
IQN_BASE="iqn.2026-09.local.lab"
KEY=/root/.ssh/id_ed25519_pi
grep -qE "^\s*${PI_IP}(\s|$)" /etc/pi-veeam/targets 2>/dev/null || echo "$PI_IP $PI_USER" >> /etc/pi-veeam/targets
RULE="KERNEL==\"sd*\", SUBSYSTEM==\"block\", ENV{DEVTYPE}==\"disk\", ENV{ID_PATH}==\"*iscsi-${IQN_BASE}:pi-${PI_HOST}-lun-*\", SYMLINK+=\"pi/${PI_HOST}\""
grep -qF "pi/${PI_HOST}\"" /etc/udev/rules.d/99-pi-veeam.rules 2>/dev/null || echo "$RULE" >> /etc/udev/rules.d/99-pi-veeam.rules
udevadm control --reload
[ -f "$KEY" ] || ssh-keygen -t ed25519 -N "" -C "proxy-root-to-pi" -f "$KEY" -q
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -i "$KEY" "${PI_USER}@${PI_IP}" true 2>/dev/null; then
  echo "installing proxy key on ${PI_USER}@${PI_IP} (you may be asked for that user's password once)"
  ssh-copy-id -i "$KEY.pub" "${PI_USER}@${PI_IP}"
fi
ssh -o BatchMode=yes -i "$KEY" "${PI_USER}@${PI_IP}" 'sudo -n true' && echo "sudo OK on $PI_HOST"
echo "registered $PI_HOST ($PI_IP). Next: add /dev/pi/${PI_HOST} as a Device object in the VBR policy and Apply Configuration."
