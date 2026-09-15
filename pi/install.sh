#!/bin/bash
# Pi-side installer. Run as root on a Raspberry Pi OS (Debian 12/13, arm64) box.
#   sudo ./install.sh <proxy-ip> [blksnap-binary]
# Installs: tgt, dkms, Veeam blksnap DKMS module (patched for arm64), the blksnap CLI (built here, or a
# prebuilt binary if given), pi-veeam-export.sh + systemd unit, and brings the read-only export up.
set -euo pipefail
PROXY_IP="${1:?usage: install.sh <proxy-ip> [blksnap-binary]}"
BLKSNAP_BIN="${2:-}"
HERE=$(cd "$(dirname "$0")" && pwd)
VER=13.1.1.4
REPO=https://repository.veeam.com/backup/linux/agent-13/dpkg/debian/public

echo "== packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tgt dkms "linux-headers-$(uname -r)" build-essential curl >/dev/null

echo "== Veeam blksnap DKMS source ($VER)"
if ! dkms status 2>/dev/null | grep -q "blksnap/$VER.*installed"; then
  cd /tmp && curl -sO "$REPO/pool/veeam/b/blksnap-dkms/blksnap_${VER}_amd64.deb"
  dpkg -i --force-architecture "blksnap_${VER}_amd64.deb" || true    # DKMS build may fail before the patch; we rebuild below
  cd "/usr/src/blksnap-$VER"
  if ! grep -q CONFIG_HAVE_DYNAMIC_FTRACE_WITH_ARGS bdevfilter-submit_bio.h; then
    echo "   applying arm64 ftrace patch"
    patch -p0 -s < "$HERE/blksnap-arm64-ftrace.patch"
  fi
  dkms remove "blksnap/$VER" --all >/dev/null 2>&1 || true
  dkms install "blksnap/$VER" -k "$(uname -r)"
fi
modprobe veeamblksnap && ls /dev/veeamblksnap >/dev/null

echo "== blksnap CLI"
if [ -n "$BLKSNAP_BIN" ]; then
  install -m 755 "$BLKSNAP_BIN" /usr/local/bin/blksnap
elif ! command -v blksnap >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cmake libboost-program-options-dev libboost-filesystem-dev libboost-system-dev uuid-dev git >/dev/null
  rm -rf /tmp/blksnap-src && git clone -q --depth 1 -b VAL-13.1 https://github.com/veeam/blksnap.git /tmp/blksnap-src
  cd /tmp/blksnap-src && sed -i 's|^add_subdirectory(${CMAKE_SOURCE_DIR}/tests/cpp)|#&|' CMakeLists.txt
  mkdir -p build && cd build && cmake -DCMAKE_BUILD_TYPE=Release .. >/dev/null && make -j4 blksnap-tools >/dev/null
  install -m 755 tools/blksnap/blksnap /usr/local/bin/blksnap
fi
[ "$(blksnap version)" = "$VER" ] || { echo "blksnap CLI version $(blksnap version) != module $VER" >&2; exit 1; }

echo "== export service"
install -m 755 "$HERE/pi-veeam-export.sh" /usr/local/sbin/pi-veeam-export.sh
install -m 644 "$HERE/pi-veeam-export.service" /etc/systemd/system/pi-veeam-export.service
mkdir -p /etc/pi-veeam && echo "$PROXY_IP" > /etc/pi-veeam/proxy
rm -f /etc/tgt/conf.d/veeam-pi.conf
systemctl daemon-reload && systemctl enable --now tgt >/dev/null 2>&1
systemctl enable --now pi-veeam-export.service
/usr/local/sbin/pi-veeam-export.sh status
echo "== done. On the proxy: pi-add-target.sh <this-pi-ip> $(hostname -s); then add /dev/pi/$(hostname -s) to the VBR policy and Apply Configuration."
