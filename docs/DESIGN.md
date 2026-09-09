# Design: backing up Raspberry Pis with Veeam via an x86 proxy

## Why this exists
Veeam Agent for Linux is x86_64 (and POWER) only; the product manager confirmed no ARM64 build in v13.
Rather than emulate the agent or reverse-engineer its protocol, the Pi presents a consistent image of
its boot disk to an x86 host that runs the stock agent. VBR sees an ordinary Linux workload.

## Prerequisites
- **Every Pi must have a static IP or a DHCP reservation.** The proxy addresses each Pi by the value in
  `/etc/pi-veeam/targets`, and open-iscsi remembers the portal address. On networks with dynamic DNS the
  scripts also accept hostnames, but this lab's DNS does not resolve the Pis, so an address change would
  break the export until the targets file is corrected. The proxy itself should be static too (the Pi's
  tgt ACL and the VBR managed-server entry both name its address).
- Pi: Raspberry Pi OS (Debian 12/13) 64-bit with kernel headers, Ethernet (Wi-Fi works but is ~15x slower).
- Proxy: x86_64 Rocky/RHEL 9 VM, 2 vCPU / 4 GB, Secure Boot either off or with Veeam's MOK enrolled.
- VBR v13 with a Linux managed-server entry for the proxy (needed to copy the two wrapper scripts onto
  the appliance through the console's Files view).

## Components
| Where | What | Role |
|---|---|---|
| Pi (aarch64, Debian 13) | Veeam `blksnap` 13.1.1.4 built from Veeam's DKMS source + `pi/blksnap-arm64-ftrace.patch`; `blksnap` CLI from the GitHub VAL-13.1 branch; `tgt`; `pi/pi-veeam-export.sh` + `pi-veeam-export.service` | **Persistent** iSCSI export of a device-mapper disk image (ACL = proxy IP). Idle: maps the live partitions (through loop devices) with the LUN **read-only**. Job: freeze, snapshot every partition, hot-swap the dm table to the snapshot images, LUN read-write. |
| Proxy (x86_64 Rocky 9, "pproxy") | stock Veeam Agent for Linux 13.1.1.4 with `kmod-blksnap` (Secure Boot: Veeam MOK enrolled); `iscsi-initiator-utils`; udev alias rule; `/etc/pi-veeam/targets`; `pi-job-pre.sh` / `pi-job-post.sh` | Attach every Pi image as `/dev/pi/<host>`, let the agent back it up as a volume, detach and tell the Pi to drop the snapshot |
| VBR v13 (Software Appliance) | Protection group "Pi Proxy" (pproxy); Linux **policy** "Pi pi-02 image (policy)" with device objects `/dev/pi/<host>`; two 2-line wrappers `pi-veeam-pre.sh` / `pi-veeam-post.sh` uploaded once via the thick console | Schedules, repository, retention, restores |

## Run sequence (managed-by-agent policy)
0. Between jobs the proxy stays logged in to every Pi's read-only export, so `/dev/pi/<host>` always
   exists. The agent validates the policy's device objects at apply time **and at job start, before
   the pre-job script runs**, which is why the export must be persistent. A timer on the proxy
   (`pi-veeam-attach.timer`) re-attaches after Pi reboots.
1. Agent on the proxy runs the pre-job script (uploaded from VBR to `/var/lib/veeam/scripts/<policy>/`).
   It reads `/etc/pi-veeam/targets` and, per Pi: ssh → `pi-veeam-export.sh start` (fsfreeze,
   partition snapshots, dm table hot-swapped to the images, LUN read-write) → iSCSI re-login on the
   proxy (refreshes the write-protect flag and resets change tracking because the device is recreated).
2. Agent enumerates objects, finds ext4/vfat on the image partitions, takes its own blksnap snapshot
   of the image device, reads only allocated blocks (~9 GB of a 30 GB card), sends to the repository.
3. Post-job script: per Pi, ssh → `pi-veeam-export.sh stop` (LUN read-only, dm table back to the
   live partitions, blksnap snapshot destroyed, tmpfs COW freed) → iSCSI re-login so the device stays
   present, read-only, for the next apply or run.

## Things that were not obvious (each cost a failed run)
- **Snapshot partitions, not the disk.** The blksnap filter binds to the exact bdev it is attached
  to (`bio->bi_bdev->bd_filter`); filesystems submit I/O on partition devices, so a whole-disk
  snapshot silently misses every write. Veeam Agent snapshots partitions for the same reason.
- **COW must be off the snapshotted disk.** The module refuses ("already being used as difference
  storage") and skips that partition. tmpfs (`/run/pi-veeam`, 512 MiB) is fine for a quiet Pi.
- **Freeze before `snapshot_take`.** Debian 13's ext4 has `orphan_file`; a crash-consistent image
  fails to mount on the proxy ("orphan file block 0: bad checksum"), the agent then falls back to a
  raw full read and the restore point has no mountable rootfs. `fsfreeze -f` for the instant of the
  snapshot fixes it (this is what the agent does natively).
- **The LUN must be read-write.** The proxy's blksnap filter opens the device RW to attach; a RO LUN
  (or a dm-linear over one) fails. Exporting a snapshot *image* RW is harmless (writes go to COW).
- **VBR rejects ':' in device paths**, so the by-path symlink cannot be the job object; a udev rule
  keyed on the target IQN provides `/dev/pi/<host>`.
- **The nosnap agent cannot image plain partitions** (LVM/Btrfs only); the full agent with the
  kernel module is required on the proxy. Under Secure Boot that means enrolling Veeam's certificate
  (`veeam-ueficert` from repository.veeam.com) via MOK.
- **Server-job scripts run on the backup server**, not the agent; pre-freeze/post-thaw run on the
  agent but only bracket the snapshot. **Managed-by-agent policies** run pre-job/post-job on the
  agent, before enumeration and after the data read, which is the contract these hooks need.
- **Policy scripts are pushed from the backup server.** VBR reads the file on the VSA, hashes it,
  uploads it to the agent. The web console has no upload control; the thick console's Browse does it.
  Keep the uploaded file a stable 2-line wrapper so the appliance is touched exactly once.

## Why the export is persistent, and the placeholder alternative
The agent validates a policy's device objects twice: when the policy is applied and again at job start,
*before* the user pre-job script runs (agent log: `CBackupPolicyJobPerformer. PreJob action ... Failed`
→ `No policy filters matching the system`). So `/dev/pi/<host>` must exist between runs; the pre/post
scripts can only manage what is *behind* the device, not the device itself.

Two ways to satisfy that:

1. **Pi-side persistent export (implemented).** The Pi keeps its target up. Idle: the image maps the
   live partitions (via loop devices) and the LUN is flagged read-only in tgt, enforced at the protocol
   level and reflected as a write-protected disk on the proxy (`dd` to it fails with EROFS). Job: the
   pre-job script swaps the table to frozen snapshot images and flips the LUN read-write; post-job
   reverts. The live card is never writable from the network. The agent sees real partition tables and
   filesystems at every stage, so used-block detection and file-level restore always work.

2. **Proxy-side placeholder (the author's suggestion, viable, not chosen).** Between runs the proxy presents
   a dummy block device under `/dev/pi/<host>`; pre-job removes it, logs in the real LUN, post-job
   restores the dummy. Requirements and caveats: the object is a *block device*, not a mount, so the
   dummy must be a device with the same partition table (e.g. a dm device built from the header copy
   plus zero targets) and the udev alias must be swapped without a name collision; and if the agent
   probes filesystems before the pre-job script runs, a hollow dummy makes it treat the disk as raw for
   that run (full read, no mountable rootfs — the same symptom as the orphan_file failure). Choose this
   variant only when a Pi must be completely unreachable between jobs; then use a dummy that carries
   real superblocks (a copy of the last snapshot's first megabytes per partition) to keep enumeration
   honest.

## Multiple Pis
VBR allows a machine in one job/policy only, and the proxy is the machine. Therefore:
- **A proxy can hold one *server job*, but several *policies*** (verified on v13: two policies on the
  same agent host, one per Pi, applied and ran back-to-back; each pre-job script snapshotted only
  its own Pi and the Backups view shows one chain per policy name). So the recommended layout is **one policy per Pi** on a
  single proxy: each policy has one device object (`/dev/pi/<host>`), its own wrapper pair on the
  VSA that selects its own target list (`/etc/pi-veeam/targets.d/<host>`), its own schedule and
  retention, and a restore chain named after the Pi. Stagger the schedules; the agent runs one job
  at a time. If you would rather have a single run for all Pis, one policy with several device
  objects also works (all Pis then share schedule, retention and restore chain).
- **Adding a Pi:** (1) install the Pi package (`pi/install.sh`), (2) `pi-add-target.sh <ip> <host>`
  on the proxy (targets line, udev alias, SSH key) and a `targets.d/<host>` file, (3) copy the two
  2-line wrappers for that Pi to the VSA via the console's Files view (the only appliance touch),
  (4) create the policy: workload pproxy, device `/dev/pi/<host>`, Scripts = those wrappers,
  (5) Apply Configuration with the export attached (select that one policy; the button is hidden
  when several rows are selected).
- **Run time grows linearly:** ~4.5 min per 30 GB card at the ~40 MB/s an SD card delivers. Pis are
  snapshotted at the start, so their freeze windows stay sub-second; only the tmpfs COW on each Pi
  keeps growing until the post-job script releases it.
- **Disk identifier collision is the trap.** The agent identifies a disk by its MBR signature
  (pi-02 = 0x261b0f5f). Cards written from the same image can carry the same signature. Checked
  2026-09-08: pi-02 0x261b0f5f, pi-01 0x4ed3ef9d — distinct, and filesystem UUIDs differ too
  (Raspberry Pi OS regenerates them at first boot). If two ever match, change one with `fdisk`
  (expert mode, `i`) and update the PARTUUID references in `/boot/firmware/cmdline.txt` and `/etc/fstab`.
- **Labels collide, IDs don't.** Every Pi presents "bootfs"/"rootfs"; file-level restore shows
  several drives with the same label, so pick by disk (`/dev/pi/<host>`) rather than by label.
- The iSCSI target name is `iqn.2026-09.local.lab:pi-<hostname>`; hostnames must be unique.

## Throughput observed (for sizing expectations)
All figures from this lab: Pi 4 Model B, 32 GB class-10 microSD, Rocky 9 proxy VM on vSphere, VBR v13
Software Appliance, repository on the appliance's local disk.

| Path | Rate | Notes |
|---|---|---|
| SD card, local sequential read on the Pi (`dd bs=4M iflag=direct`) | 44 MB/s | the ceiling for everything below |
| Pi on 2.4 GHz Wi-Fi → proxy, raw TCP (python socket test) | ~4 MB/s | 130 Mbit/s link, 77% signal |
| Pi on 2.4 GHz Wi-Fi → proxy, iSCSI read | 3.3 MB/s | i.e. wire speed; a 30 GB card takes ~2.5 h |
| Pi on Ethernet → proxy, iSCSI read | 57 MB/s (dd), 40–43 MB/s sustained during a job | the card is the bottleneck, not the network |
| Veeam job, first full, Ethernet | 8.5 GB read in 4m33s (Read 8.54 GB / Transferred 2.84 GB), processing rate 37 MB/s | agent skips unallocated blocks: 8.5 GB of a 30 GB card |
| Veeam job, incremental, Ethernet | 8.86 GB read in 4m38s, Transferred 22 MB | change tracking is reset each run (new device), so every run is a full read with dedup |
| Veeam job when used-block detection fails (crash-consistent image, or stale cache) | 27–30 GB read, 12–14 min | the failure signature: read ≈ device size |
| Pi #1 on Wi-Fi during the two-Pi run | 3 MB/s sampled from /proc/diskstats | ~2.5 h per run; moved to Ethernet |
| Two Pis on Ethernet, one policy run | 9 GB each at 42.5 MB/s, 8m17s total | disks are read sequentially: ~4 min per Pi |
| Restore: Publish Disks FUSE read → image on pproxy | 9.3 GB in 53 s (~175 MB/s) | repository on the appliance's local disk |
| Restore: `.img.gz` (2.36 GB) `gunzip | dd` to microSD, USB reader on a MacBook Air | 14.6 MB/s, 35m38s for 31.3 GB | card write speed; the slowest step of the whole restore |

Rules of thumb: Ethernet is mandatory for anything beyond a proof; expect ~4–5 minutes per 30 GB card
per run on Ethernet; run time scales linearly with the number of Pis in the policy because the agent
reads the disks sequentially; VBR reports the bottleneck as "Source" (the SD card), never the proxy,
network or repository.

## Restore paths
- **File-level:** Backups → pproxy → Restore Guest Files (verified; point-in-time checked with marker
  files).
- **Bare metal to a new card (verified 2026-09-08, Pi #1 pi-01):** Publish Disks (web console)
  to pproxy → rebuild a whole-disk image from the published partitions → shrink to the target card
  → `.img.gz` → write with `dd` or Raspberry Pi Imager → boot. Scripts: `proxy/pi-rebuild-image.sh`,
  `proxy/pi-fit-image.sh`; keep an `sfdisk -d` dump per Pi (`docs/sfdisk-<host>.txt`).

  | Step | Where | Time |
  |---|---|---|
  | Publish Disks (register, data mover, FUSE mount) | web console → pproxy | 1m46s |
  | Rebuild whole-disk sparse image (2 partitions, 9.3 GB allocated) | pproxy | 53 s |
  | e2fsck + resize2fs + sfdisk + truncate to card size | pproxy | 5 s |
  | pigz -6 → 2.36 GB `.img.gz` | pproxy | 84 s |
  | scp to laptop | LAN | 96 s |
  | `dd` to microSD via USB reader | laptop | 35m38s (14.6 MB/s — the only slow step) |
  | Boot, feeders re-register on their own | Pi | ~1 min |

  Result: same hostname, addresses, PARTUUID-based fstab/cmdline, FlightAware site and feeder ID;
  clean ext4 (journal replayed at first mount), no kernel errors. Everything installed after the
  restore point (WireGuard, in this case) is absent — which is the proof that it is the backup.
- Three things a bare-metal restore of a Pi needs that a VM restore does not:
  1. **The MBR is not in the published set** — Publish Disks exposes partitions, so the partition
     table is rebuilt from the saved `sfdisk -d` dump, reusing the original disk identifier because
     Raspberry Pi OS boots by `PARTUUID=<diskid>-02`.
  2. **"32 GB" cards differ in size** (here by 711 MB); the root filesystem must be shrunk to the
     target card before the table is rewritten. That needs e2fsprogs ≥ 1.47 for Debian 13's
     `orphan_file` feature (Rocky 9 ships 1.46; build 1.47.2 into /opt).
  3. **Write the whole image, zeros included** — `dd` cannot skip sparse regions on a card, so the
     card's write speed (~15 MB/s here) dominates the wall clock.
- Alternatives not used: Entire Restore back onto the iSCSI-presented disk (would write to the Pi's
  live card through the read-write LUN — technically possible, deliberately avoided); Export Disk in
  the thick client (VMDK/VHD, would still need conversion and the same MBR/size handling).
