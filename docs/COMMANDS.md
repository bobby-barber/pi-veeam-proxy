# Command transcript

Every command run during the build, in order, with the host it ran on and notable output.
Scripts referenced here live in `pi/` and `proxy/`.

## Workstation (macOS)

```bash
# dedicated SSH key for the proxy
ssh-keygen -t ed25519 -N "" -C "claude-pproxy" -f ~/.ssh/id_ed25519_pproxy
```

## Proxy (Rocky Linux 9.8, user pproxy, run via ssh)

```bash
# one-time: authorize the key (run on the proxy as pproxy)
mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '<pubkey>' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
# passwordless sudo (run as root)
echo 'pproxy ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/pproxy && chmod 440 /etc/sudoers.d/pproxy

# baseline
sudo hostnamectl set-hostname pproxy
sudo dnf -y install iscsi-initiator-utils qemu-img git tar unzip
sudo systemctl enable --now iscsid
cat /etc/iscsi/initiatorname.iscsi        # InitiatorName=iqn.1994-05.com.redhat:5affe9db7c6d

# static IP (values taken from the DHCP lease first with: nmcli -g IP4.GATEWAY,IP4.DNS,IP4.DOMAIN dev show ens33)
sudo nmcli con mod ens33 ipv4.method manual ipv4.addresses 10.10.0.20/24 ipv4.gateway 10.10.0.x \
  ipv4.dns "10.10.0.x 10.10.0.153 1.1.1.1" ipv4.dns-search lab.local
sudo nmcli con up ens33

# after VBR deployed the agent — verification
rpm -qa | grep -i veeam
#   veeamdeployment-13.1.1.18-1.x86_64
#   veeamtransport-13.1.1.18-1.x86_64
#   veeam-libs-13.1.1.4-1.x86_64
#   veeam-nosnap-13.1.1.4-1.el9.x86_64
systemctl is-active veeamservice veeamtransport   # active / active
veeamconfig -v                                    # v13.1.1.4
```

## Pi #2 "pi-02" (Raspberry Pi 4, Raspberry Pi OS Trixie arm64, 10.10.0.112)

```bash
# inspect
lsblk -o NAME,SIZE,RO,TYPE,FSTYPE,MOUNTPOINT
#   mmcblk0 29.8G; mmcblk0p1 512M vfat /boot/firmware; mmcblk0p2 29.3G ext4 /
findmnt -n -o SOURCE /                            # /dev/mmcblk0p2

# export the SD card read-only over iSCSI to the proxy (script in pi/)
sudo bash pi-export-install.sh 10.10.0.20
```

First run of the script produced a target with only the controller LUN 0. `tgt-admin --update ALL -v` explained:

```
# Device /dev/mmcblk0 is used by the system (mounted, used by swap?).
# Skipping device /dev/mmcblk0 - it is in use.
# You can override it with --force or 'allow-in-use yes' config option.
```

Fix: add `allow-in-use yes` to the target block (acceptable because the export is `readonly 1`). Re-ran the script.

Second run (with `allow-in-use yes`):

```
Target 1: iqn.2026-09.local.lab:pi-pi-02
        LUN: 1
            Size: 32011 MB, Block size: 512
            Readonly: Yes
            Backing store path: /dev/mmcblk0
```

## Proxy — attach the Pi disk

```bash
./pi-attach.sh 10.10.0.112        # script in proxy/
#   attached iqn.2026-09.local.lab:pi-pi-02 from 10.10.0.112 as /dev/sdb
#   sdb    29.8G RO=1 disk
#   ├─sdb1  512M vfat bootfs
#   └─sdb2 29.3G ext4 rootfs
sudo iscsiadm -m session
#   tcp: [1] 10.10.0.112:3260,1 iqn.2026-09.local.lab:pi-pi-02 (non-flash)
ls -l /dev/disk/by-path/ | grep 10.10.0.112   # stable by-path names for the LUN and partitions

# throughput check
sudo dd if=/dev/sdb of=/dev/null bs=4M count=64 status=progress      # 3.3 MB/s over iSCSI
# on the Pi, for comparison:
sudo dd if=/dev/mmcblk0 of=/dev/null bs=4M count=64 iflag=direct     # 44.3 MB/s local SD read
```

## Network check (why iSCSI is slow)

Pi #2 is on 2.4 GHz Wi-Fi (`nmcli dev wifi list`: 130 Mbit/s link, signal 77%).
Raw TCP test with a throwaway python socket sender on the proxy and receiver on the Pi:

```
proxy->pi send 4.2 MB/s
recv 4.0 MB/s
```

iSCSI at 3.3 MB/s is therefore near wire speed. Full 30 GB pass ≈ 2.5 h on this link.
For anything beyond the proof, put the Pi on Ethernet.

## Switch Pi #2 to Ethernet

Cable plugged in; NetworkManager's `netplan-eth0` DHCP profile came up on its own:

```
eth0 up: 10.10.0.102/23
default via 10.10.0.x dev eth0  metric 100
default via 10.10.0.x dev wlan0 metric 600
```

Proxy side: log out of the Wi-Fi portal, forget its node record, re-attach on the wired address.

```bash
./pi-detach.sh 10.10.0.112
sudo iscsiadm -m node -o delete -p 10.10.0.112
./pi-attach.sh 10.10.0.102
#   attached iqn.2026-09.local.lab:pi-pi-02 from 10.10.0.102 as /dev/sdb
sudo dd if=/dev/sdb of=/dev/null bs=4M count=128 status=progress
#   537 MB copied, 9.36 s, 57.4 MB/s          (was 3.3 MB/s on Wi-Fi)
```

Bug fixed in `proxy/pi-attach.sh` along the way: `set -o pipefail` plus `| head -1` made awk die with
SIGPIPE and the script exit silently. Rewritten without pipefail and with an explicit login step.

## Proxy — stable colon-free alias for the Pi LUN (VBR rejects ':' in device paths)

```bash
sudo install -m 644 99-pi-veeam.rules /etc/udev/rules.d/99-pi-veeam.rules   # file in proxy/
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=block --action=add
ls -l /dev/pi/            # pi-02 -> ../sdb
udevadm info -q property /dev/sdb | grep -E "^ID_PATH=|^DEVLINKS="
```

## Proxy — replace the nosnap agent with the full agent

```bash
sudo dnf -y remove veeam-nosnap
sudo dnf -y install "kernel-devel-$(uname -r)" gcc make elfutils-libelf-devel   # in case a DKMS build is ever needed
# then in VBR: Protection Group > Rescan, then Install > Install Backup Agent
rpm -qa | grep -iE "veeam|blksnap" | sort
#   kmod-blksnap-13.1.1.4-1.el9.x86_64   veeam-13.1.1.4-1.el9.x86_64   veeam-libs / veeamtransport / veeamdeployment
mokutil --sb-state                      # SecureBoot enabled
rpm -ql kmod-blksnap | grep -oE "5\.14\.0-[^/]+" | sort -uV | tail -1   # 5.14.0-687.5.1.el9_8 (running: 687.10.1)
modinfo /lib/modules/5.14.0-687.5.1.el9_8.x86_64/extra/veeamblksnap.ko | grep -E "signer|sig_key"
#   signer: Entrust Extended Validation Code Signing CA - EVCS2   sig_key: 6D:CA:74:1E:C2:59:17:C3:4D:AB:CA:27:7C:79:65:2B
```

## Proxy — link the kABI-compatible module and enroll Veeam's Secure Boot key

```bash
# prebuilt module is for 5.14.0-687.5.1.el9_8; running kernel is 5.14.0-687.10.1.el9_8.0.1 (same series)
K=5.14.0-687.5.1.el9_8.x86_64
printf '%s\n' /lib/modules/$K/extra/bdevfilter.ko /lib/modules/$K/extra/veeamblksnap.ko | sudo /usr/sbin/weak-modules --add-modules --no-initramfs
sudo depmod -a
modinfo veeamblksnap | grep filename          # .../weak-updates/veeamblksnap.ko
sudo modprobe veeamblksnap                     # ERROR: Key was rejected by service  (Secure Boot)

# Veeam's UEFI certificate package, from the public repo
cd /tmp
curl -sO https://repository.veeam.com/backup/linux/agent-13/rpm/el/9/x86_64/veeam-ueficert-13.1.1.4-1.noarch.rpm
curl -sO https://repository.veeam.com/keys/RPM-E6FBD664 && sudo rpm --import RPM-E6FBD664
rpm -K veeam-ueficert-13.1.1.4-1.noarch.rpm    # digests signatures OK
sudo rpm -i veeam-ueficert-13.1.1.4-1.noarch.rpm
#   postinstall tries `mokutil --import --root-pw` -> "Failed to get root password hash" (root is locked). Harmless.
printf 'PiProxy2026\nPiProxy2026\n' | sudo mokutil --import /etc/uefi/certs/veeam-ueficert
sudo mokutil -N                                # shows the pending Veeam Software Group GmbH key
sudo iscsiadm -m node -T iqn.2026-09.local.lab:pi-pi-02 -p 10.10.0.102 | grep node.startup   # automatic
# reboot, then at the console: MOK management > Enroll MOK > Continue > Yes > PiProxy2026 > Reboot
```

## Proxy — after the MOK enrollment reboot

```bash
sudo mokutil --list-enrolled | grep -c "Veeam Software"   # 1
sudo modprobe veeamblksnap && lsmod | grep -E "blksnap|bdevfilter"
#   veeamblksnap 172032 0 / bdevfilter 102400 1 veeamblksnap
sudo iscsiadm -m session          # tcp: [1] 10.10.0.102:3260,1 iqn.2026-09.local.lab:pi-pi-02
ls -l /dev/pi/                    # pi-02 -> ../sdb
systemctl is-active veeamservice veeamtransport veeamdeployment
```

## Re-export read-write (blksnap filter cannot attach to a read-only device)

```bash
# proxy
./pi-detach.sh 10.10.0.102
# pi
sudo bash pi-export-install.sh 10.10.0.20 0      # 2nd arg = readonly flag; 0 for the proof
# proxy
./pi-attach.sh 10.10.0.102 ; cat /sys/block/sdb/ro   # 0
# for the record, a dm-linear wrapper does not help:
#   dmsetup create pitest --table "0 $(blockdev --getsz /dev/sdb) linear /dev/sdb 0"
#   -> device-mapper: reload ioctl on pitest failed: Read-only file system
```

## Proxy — agent-side view of the successful run

```bash
sudo veeamconfig session list | tail -2
#   Pi pi-02 image - 10.10.0.20  Backup  {46e8e9c7-...}  Success  2026-09-08 02:17 ... 02:21
sudo veeamconfig session log --id '{46e8e9c7-f73a-40bd-868f-dc5b29d27c89}'
#   Creating volume snapshot / Starting full backup to [VBR01] Backup Repository 1
#   Backed up sdb 8.5 GB at 44 MB/s / Releasing snapshot
# read rate sampled from /proc/diskstats during the run: ~40-43 MB/s from sdb
```

## Pi — Veeam blksnap DKMS source package (Milestone 2)

```bash
# find the package (repo index is per-arch, but the DKMS deb is source-only)
curl -s https://repository.veeam.com/backup/linux/agent-13/dpkg/debian/public/dists/stable/veeam/binary-amd64/Packages \
  | awk '/^Package:/{p=$2} /^Version:/{v=$2} /^Filename:/{print p, v, $2}' | grep '^blksnap ' | sort -k2V | tail -1
#   blksnap 13.1.1.4 pool/veeam/b/blksnap-dkms/blksnap_13.1.1.4_amd64.deb
cd /tmp && curl -sO https://repository.veeam.com/backup/linux/agent-13/dpkg/debian/public/pool/veeam/b/blksnap-dkms/blksnap_13.1.1.4_amd64.deb
dpkg -c blksnap_13.1.1.4_amd64.deb | grep -c "\.c$"      # sources only
sudo apt-get install -y dkms                             # 3.2.2 on Trixie; headers 6.18.34 already present
sudo dpkg -i --force-architecture blksnap_13.1.1.4_amd64.deb
sudo dkms status
sudo modprobe veeamblksnap && lsmod | grep -E "blksnap|bdevfilter"
```

## Pi — arm64 fix for bdevfilter and rebuild

```bash
cd /usr/src/blksnap-13.1.1.4
for f in bdevfilter-submit_bio.h bdevfilter-bdev_mark_dead.h bdevfilter-del_gendisk.h; do
  sudo cp -n $f $f.orig
  sudo sed -i 's/^\(\s*\)FTRACE_OPS_FL_SAVE_REGS |$/#ifndef CONFIG_HAVE_DYNAMIC_FTRACE_WITH_ARGS\n\1FTRACE_OPS_FL_SAVE_REGS |\n#endif/' $f
done
# (the resulting diff is saved as pi/blksnap-arm64-ftrace.patch; `patch -p0 < ...` in /usr/src/blksnap-13.1.1.4 applies it)
sudo dkms remove blksnap/13.1.1.4 --all
sudo dkms install blksnap/13.1.1.4 -k $(uname -r)
sudo modprobe veeamblksnap && lsmod | grep -E "blksnap|bdevfilter" && ls -l /dev/veeamblksnap
# before the patch dmesg showed: bdevfilter: Failed to register ftrace handler (-22)
```

## Pi — build the blksnap CLI (tools/blksnap from the VAL-13.1 branch)

```bash
sudo apt-get install -y cmake libboost-program-options-dev libboost-filesystem-dev libboost-system-dev uuid-dev
git clone --depth 1 -b VAL-13.1 https://github.com/veeam/blksnap.git /tmp/blksnap-src
cd /tmp/blksnap-src
# tests/cpp needs OpenSSL and is not needed for the CLI:
sed -i 's|^add_subdirectory(${CMAKE_SOURCE_DIR}/tests/cpp)|#&|' CMakeLists.txt
mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=Release .. && make -j4 blksnap-tools
sudo install -m 755 tools/blksnap/blksnap /usr/local/bin/blksnap
sudo blksnap version                         # 13.1.1.4 (matches the DKMS module)
sudo blksnap attach --device /dev/mmcblk0    # Attached successfully
sudo blksnap cbtinfo --device /dev/mmcblk0   # block_size=65536 device_capacity=32010928128 changes_number=0
```

## Pi + proxy — snapshot-image export (Milestone 2)

```bash
# proxy: release the live-disk export
./pi-detach.sh 10.10.0.102
# pi: snapshot + export the image (script in pi/)
sudo bash pi-snapshot-export.sh start 10.10.0.20
#   OK: snapshot 081612a0-... of /dev/mmcblk0 exported as iqn.2026-09.local.lab:pi-pi-02 (image /dev/vbsnap-179-0)
sudo bash pi-snapshot-export.sh status
# proxy
./pi-attach.sh 10.10.0.102 ; cat /sys/block/sdb/ro ; ls -l /dev/pi/
# pi: marker written after the snapshot (must be absent from the backup)
echo "written after snapshot 1 at $(date -u +%FT%TZ)" | sudo tee /root/AFTER-SNAPSHOT-1.txt
```

## Proxy — incremental run against the snapshot image

```bash
sudo veeamconfig session list | tail -2
#   Pi pi-02 image - 10.10.0.20  Backup  {148028e9-...}  Success  02:33 -> 02:37
sudo veeamconfig session log --id '{148028e9-e4ba-476d-afed-0e3a3faf30d5}'
#   Starting incremental backup to [VBR01] Backup Repository 1
#   Backed up sdb 8.8 GB at 40.6 MB/s
# VBR session: Read 8.85 GB, Processed 29.8 GB, Transferred 162.89 MB, 00:04:23
```

## Pi — partition snapshots assembled into a disk image (final Milestone 2 form)

```bash
sudo bash pi-snapshot-export.sh start 10.10.0.20
#   OK: snapshot c2542ea6-... of 2 partition(s) on /dev/mmcblk0 assembled as /dev/mapper/pi-pi-02-snap, exported ...
sudo bash pi-snapshot-export.sh status
#   0 16384 linear 7:1 0            <- header.img loop (MBR + gap, copied)
#   16384 1048576 linear 259:0 0    <- p1 snapshot image
#   1064960 61456384 linear 259:1 0 <- p2 snapshot image
# verify point-in-time without the proxy: ext4 listing straight off the dm device
L=$(sudo losetup -f --show -r -o $((1064960*512)) /dev/mapper/pi-pi-02-snap)
sudo debugfs -R "ls -l /root" $L | grep AFTER ; sudo losetup -d $L
# failure seen with COW on the root fs (now avoided by WORK=/run/pi-veeam):
#   veeamblksnap-snapshot: The block device 179:2 is already being used as difference storage
```

## Orchestration plumbing

```bash
# proxy (root key for the hop to the Pi)
sudo ssh-keygen -t ed25519 -N "" -C "proxy-root-to-pi" -f /root/.ssh/id_ed25519_pi
sudo cat /root/.ssh/id_ed25519_pi.pub      # -> append to ~pi/.ssh/authorized_keys on the Pi
sudo install -m 755 pi-attach.sh pi-detach.sh pi-job-pre.sh pi-job-post.sh /usr/local/sbin/
sudo ssh -i /root/.ssh/id_ed25519_pi pi@10.10.0.102 'hostname; sudo -n true && echo pi_sudo_ok'
# pi
sudo install -m 755 pi-snapshot-export.sh /usr/local/sbin/pi-snapshot-export.sh
```

## Diagnosing the crash-consistent image (before the fsfreeze fix)

```bash
# proxy, during the job / FLR mount:
sudo dmesg | grep EXT4
#   EXT4-fs error (device vbsnap-8-18): ext4_init_orphan_info:617: comm mount: orphan file block 0: bad checksum
#   EXT4-fs (vbsnap-8-18): mount failed
# pi, read-only check of the image partition (loop at p2 offset):
L=$(sudo losetup -f --show -r -o $((1064960*512)) /dev/mapper/pi-pi-02-snap); sudo e2fsck -fn $L; sudo losetup -d $L
#   before fix: "Orphan file ... Recreate? no"   after fix: clean
# proxy, after fix:
sudo mount -o ro /dev/sdb2 /mnt/pi && sudo dmesg | tail -3   # orphan cleanup on readonly fs / recovery complete
```

## Fourth run (final design) — agent view

```bash
sudo veeamconfig session list | tail -2
#   Pi pi-02 image - 10.10.0.20  Backup  {fe4ffbc8-...}  Success  03:04 -> 03:08
#   Backed up sdb 8.9 GB at 41.1 MB/s ; VBR: Read 8.86 GB, Transferred 21.98 MB, 00:04:38
sudo dmesg | grep EXT4 | tail -2
#   EXT4-fs (vbsnap-8-18): mounted filesystem ... r/w with ordered data mode
```

## Proxy — argument-free wrappers for the policy Scripts tab

```bash
# VBR treats the whole field as one path, so no arguments; one wrapper per Pi
cat > /usr/local/sbin/pi-pi-02-pre.sh  <<'X'
#!/bin/bash
exec /usr/local/sbin/pi-job-pre.sh 10.10.0.102
X
cat > /usr/local/sbin/pi-pi-02-post.sh <<'X'
#!/bin/bash
exec /usr/local/sbin/pi-job-post.sh 10.10.0.102
X
chmod 755 /usr/local/sbin/pi-pi-02-*.sh
# evidence that policy scripts are pushed from the backup server:
sudo find /var/lib/veeam/scripts     # .../scripts/<policy-guid>/pre  (empty: upload failed, source missing on VSA)
```

## Proxy — target-list hooks (final form)

```bash
sudo install -m 755 pi-job-pre.sh pi-job-post.sh pi-veeam-pre.sh pi-veeam-post.sh /usr/local/sbin/
sudo mkdir -p /etc/pi-veeam && sudo install -m 644 targets.example /etc/pi-veeam/targets
sudo /usr/local/sbin/pi-veeam-pre.sh ; ls -l /dev/pi/     # attaches every Pi in the list
sudo /usr/local/sbin/pi-veeam-post.sh                     # detaches and destroys the snapshots
# disk identifier check before adding a second Pi (must differ per Pi):
sudo fdisk -l /dev/mmcblk0 | grep identifier              # run on each Pi
```

## Diagnosing the persistent-export data mismatch

```bash
# proxy (LUN attached read-write after pi-veeam-pre.sh)
sudo dd if=/dev/sdb2 bs=1M count=64 iflag=direct status=none | md5sum      # a3e1247a...
# pi
sudo dd if=/dev/mapper/pi-pi-02-snap bs=512 skip=1064960 count=131072 iflag=direct status=none | md5sum   # 9efbfcd4...
sudo blockdev --flushbufs /dev/mapper/pi-pi-02-snap
# proxy again -> 9efbfcd4... (matches). Fix: tgt LUN with --bsoflags direct + flushbufs after each dm reload.
tgtadm --lld iscsi --op new --mode logicalunit --tid 1 --lun 1 -b /dev/mapper/pi-<host>-snap --bsoflags direct
```

## Pi #1 onboarding (one command per side)

```bash
# pi #1
sudo ./install.sh 10.10.0.20 /tmp/blksnap-arm64        # blksnap CLI copied from Pi #2 (same arch)
# proxy
sudo pi-add-target.sh 10.10.0.111 pi-01 pi
sudo systemctl start pi-veeam-attach.service              # or wait for the timer
ls -l /dev/pi/                                            # pi-01 -> sdc, pi-02 -> sdb
```

## One policy per Pi (proxy side)

```bash
# per-policy target lists and 2-line wrappers (already in the repo: proxy/per-policy/)
sudo install -d /etc/pi-veeam/targets.d
echo "10.10.0.102 pi" | sudo tee /etc/pi-veeam/targets.d/pi-02
echo "10.10.0.101 pi"  | sudo tee /etc/pi-veeam/targets.d/pi-01
sudo install -m 755 per-policy/pi-veeam-*-dump*.sh /usr/local/sbin/
# the same four wrappers go to /var/lib/veeam/scripts/ on the VSA (thick console → Files view)
# after Apply Configuration, VBR pushes them to the agent:
sudo ls -R /var/lib/veeam/scripts/            # <policy-guid>/{pre,post}/pi-veeam-*-<host>.sh
sudo veeamconfig job list                     # both policies listed for the one agent
```

## Bare-metal restore: rebuild a card image from Publish Disks (on pproxy, as root)

```bash
# after Publish Disks (web console) to pproxy:
mount | grep veeam_fuse                     # /run/media/Veeam.Mount.Disks/<guid>
ls -l /run/media/Veeam.Mount.Disks/<guid>/  # 4ed3ef9d_0 (boot, 512 MiB), 4ed3ef9d_1 (root, 29.3 GiB)
cat /run/media/Veeam.Mount.FS/<guid>/4ed3ef9d_0/cmdline.txt   # root=PARTUUID=4ed3ef9d-02

# original geometry (run on the Pi beforehand and keep it with the docs)
sudo sfdisk -d /dev/mmcblk0
#   label-id: 0x4ed3ef9d
#   p1 : start=16384,   size=1048576,  type=c
#   p2 : start=1064960, size=61456384, type=83

IMG=/var/tmp/pi-pi-01-restore.img
truncate -s 32010928128 $IMG                # 62521344 sectors x 512
sfdisk $IMG <<'T'
label: dos
label-id: 0x4ed3ef9d
unit: sectors
start=16384,   size=1048576,  type=c
start=1064960, size=61456384, type=83
T
D=/run/media/Veeam.Mount.Disks/<guid>
dd if=$D/4ed3ef9d_0 of=$IMG bs=4M seek=$((16384*512))   oflag=seek_bytes conv=notrunc,sparse
dd if=$D/4ed3ef9d_1 of=$IMG bs=4M seek=$((1064960*512)) oflag=seek_bytes conv=notrunc,sparse
fdisk -l $IMG
```
# inspect and package (pproxy)
L=$(losetup -f --show -P -r $IMG); blkid ${L}p1 ${L}p2
mount -o ro,noload ${L}p2 /mnt; cat /mnt/etc/hostname; umount /mnt; losetup -d $L
pigz -6 -p6 -k -c $IMG > $IMG.gz          # 2.36 GB
# mac
scp pproxy:/var/tmp/pi-pi-01-restore.img.gz ~/Downloads/

## Fit the image to a smaller card (pproxy, root)

```bash
# card size from the Mac: diskutil info /dev/disk8 | grep "512-Byte-Units"   -> 61132800
# newer e2fsprogs for Debian 13's orphan_file feature (Rocky 9 ships 1.46.5)
dnf -y install gcc make
curl -sSLO https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v1.47.2/e2fsprogs-1.47.2.tar.xz
tar xf e2fsprogs-1.47.2.tar.xz && cd e2fsprogs-1.47.2
./configure --prefix=/opt/e2fsprogs --disable-nls && make -j6 && make install

IMG=/var/tmp/pi-pi-01-restore.img
L=$(losetup -f --show -P $IMG)
/opt/e2fsprogs/sbin/e2fsck -fy ${L}p2                  # replay journal
/opt/e2fsprogs/sbin/resize2fs ${L}p2 7508480           # (61132800-1064960)/8 blocks, NO 's' suffix
/opt/e2fsprogs/sbin/e2fsck -fn ${L}p2
losetup -d $L
sfdisk $IMG <<'T'
label: dos
label-id: 0x4ed3ef9d
unit: sectors
start=16384,   size=1048576,  type=c
start=1064960, size=60067840, type=83
T
truncate -s $((61132800*512)) $IMG
pigz -6 -p6 -k -c $IMG > $IMG.gz
# or in one go: proxy/pi-fit-image.sh $IMG 61132800 docs/sfdisk-pi-01.txt
```

## Write the card (Mac)

```bash
diskutil list external physical                       # /dev/disk8, 31.3 GB
diskutil unmountDisk /dev/disk8
gunzip -c ~/Downloads/pi-pi-01-restore.img.gz | sudo dd of=/dev/rdisk8 bs=4m status=progress && sync
diskutil eject /dev/disk8
```

## Verify the restored Pi

```bash
uptime -p
sudo fdisk -l /dev/mmcblk0 | grep -E 'sectors$|^/dev'    # 61132800 sectors, p2 size 60067840 = new card
df -h / | tail -1                                         # 29G, 7.7G used
grep -o 'root=[^ ]*' /proc/cmdline                        # root=PARTUUID=4ed3ef9d-02
sudo journalctl -b -o cat | grep 'EXT4-fs (mmcblk0p2)'    # orphan cleanup, mounted ro, re-mounted r/w
sudo tune2fs -l /dev/mmcblk0p2 | grep -E 'Block count|state'
systemctl is-active dump1090-fa dump978-fa piaware fr24feed adsbexchange-feed
sudo journalctl -u piaware -b -o cat | grep -iE 'feeder ID|site'
ls /etc/wireguard    # absent: installed after the restore point
```
