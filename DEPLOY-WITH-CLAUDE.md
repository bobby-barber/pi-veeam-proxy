# Deploy with Claude Code

You do not have to do the Linux side by hand. Clone this repository, open it in
[Claude Code](https://claude.com/claude-code), and paste the prompt below. Claude will ask you for
the addresses of your proxy VM and each Raspberry Pi, help you grant it SSH access, install and
verify everything on the proxy and the Pis, prepare the two wrapper files for your Veeam server,
and then walk you through the Veeam web console steps one at a time.

**Before you start, have ready:**
- A Rocky/RHEL 9 x86_64 VM for the proxy, with a static IP and a user that can `sudo`.
- Each Raspberry Pi on Raspberry Pi OS 64-bit (Debian 12/13), on Ethernet, with a static IP or DHCP
  reservation and a user that can `sudo`.
- Veeam Backup & Replication v13 with a Linux backup repository, and the web console URL.
- SSH access from the machine running Claude Code to the proxy and to each Pi (Claude will help
  set this up; it never asks you for passwords in chat).

```bash
git clone https://github.com/pi-barber/pi-veeam-proxy.git
cd pi-veeam-proxy
claude
```

Then paste this prompt:

```text
You are deploying the pi-veeam-proxy project from this repository: it backs up Raspberry Pis
with Veeam Backup & Replication v13 by exporting a frozen snapshot image of each Pi's SD card
over iSCSI to an x86 "proxy" VM that runs the stock Veeam Agent for Linux. Read README.md,
docs/DESIGN.md and docs/COMMANDS.md first so you understand the design before touching any host.

Work through the phases below in order. Before each phase, tell me what you are about to do.
Show me every command you intend to run on a remote host before running it. Ask before anything
that is not easily reversible. Never write to a Pi's SD card, never run fsfreeze by hand, never
put private keys or passwords in the conversation, and never modify the Veeam appliance itself.

PHASE 0 - Inventory. Ask me for:
  - the proxy VM: IP or hostname, SSH user (must be able to sudo), and whether Secure Boot is on;
  - each Raspberry Pi: IP or hostname, a short unique name (used for /dev/pi/<name> and the policy
    name), and SSH user (must be able to sudo);
  - the Veeam backup server's DNS name as the agent will reach it, and the web console URL.
  Confirm with me that every Pi and the proxy have a static IP or a DHCP reservation and that the
  Pis are on Ethernet, and explain why both matter if I am unsure.

PHASE 1 - SSH access. For the proxy and each Pi, test key-based SSH from this machine
(ssh -o BatchMode=yes user@host true). Where it fails, help me fix it: if I have no key, create
one; then give me the exact ssh-copy-id command to run myself in a terminal (it will prompt for
my password once) and re-test afterwards. Also check passwordless sudo on every host and tell me
the exact line to add with visudo if it is missing.

PHASE 2 - Proxy. On the proxy: install iscsi-initiator-utils and enable iscsid; copy the files
from proxy/ into /usr/local/sbin and /etc/systemd/system exactly as docs/COMMANDS.md shows;
create /etc/pi-veeam and /etc/pi-veeam/targets.d; enable pi-veeam-attach.timer. Create the
proxy's root SSH key for reaching the Pis (/root/.ssh/id_ed25519_pi) if it does not exist, print
its PUBLIC key, and install it into the SSH user's authorized_keys on every Pi using the access
from Phase 1. Verify from the proxy that root can run "sudo -n true" on each Pi non-interactively.
If Secure Boot is on, tell me now that after Veeam installs the agent I will need to enroll the
veeam-ueficert certificate with mokutil and reboot once, and that I must be at the console.

PHASE 3 - Pis. For each Pi, one at a time: copy the pi/ directory to it, run
"sudo ./install.sh <proxy-ip>" and watch it through. It builds Veeam's blksnap kernel module with
DKMS (several minutes on a Pi 4), builds the blksnap CLI, installs tgt and the export service.
When it finishes, run "sudo pi-veeam-export.sh status" and confirm: the target is listed, the LUN
shows Readonly: Yes, and no snapshot is active. Do not continue to the next Pi until this one
is verified.

PHASE 4 - Register each Pi on the proxy. For each Pi: "pi-add-target.sh <ip> <name> <user>",
write "/etc/pi-veeam/targets.d/<name>" with the line "<ip> <user>", and run
"pi-make-wrappers.sh <name>" to create the two per-policy wrapper scripts. Run
"systemctl start pi-veeam-attach.service" and confirm /dev/pi/<name> exists for every Pi and
that "cat /sys/block/$(readlink /dev/pi/<name> | xargs basename)/ro" prints 1 (read-only).

PHASE 5 - Dry run of the hooks. For one Pi, run the pre-job hook manually as root on the proxy
with PI_VEEAM_TARGETS=/etc/pi-veeam/targets.d/<name>, confirm it reports "ro=0" and that
"pi-veeam-export.sh status" on the Pi shows an active snapshot; then run the post-job hook and
confirm the LUN is read-only again and the snapshot is gone. Report the timings.

PHASE 6 - Files for the Veeam server. Collect the wrapper pair for every Pi
(/usr/local/sbin/pi-veeam-pre-<name>.sh and -post-<name>.sh) into a local folder and tell me
they must be placed, unchanged, in /var/lib/veeam/scripts/ on the Veeam backup server. Offer
the two ways: scp, or adding the proxy as a managed Linux server in the web console (with every
optional component cleared) and using the console's Files view. This is the only step that
touches the backup server.

PHASE 7 - Veeam web console, guided. Walk me through these steps one at a time, waiting for me
to confirm each, and tell me what to check after each: (1) Protection group with the proxy as
its only computer, SSH credential with privilege elevation, "Install nosnap backup agent" left
unchecked, then Install Backup Agent; handle the Secure Boot enrollment now if needed. (2) One
Agent backup job of type Server POLICY per Pi: workload = the proxy, volume-level, object =
Device /dev/pi/<name>, destination = Veeam backup repository, backup server = the DNS name from
Phase 0. Guest Processing: enable application-aware processing, Customize -> proxy ->
Application Settings -> Scripts: enable script execution, job scripts =
/var/lib/veeam/scripts/pi-veeam-pre-<name>.sh and pi-veeam-post-<name>.sh. (3) Apply
Configuration with the policy selected on its own; it must say the configuration has been
applied. (4) Start the policy and watch the session: "Pre-job script has been executed
successfully", "Creating volume snapshot", "Backed up sdX N GB at ~40 MB/s", "Post-job script
has been executed successfully". While it runs, confirm from the proxy that the LUN is read-write
and from the Pi that a snapshot is active; afterwards confirm both are back to idle. (5) Set a
schedule per policy, staggered, about five minutes per 32 GB card.

PHASE 8 - Save what a restore will need. For each Pi, save the output of
"sudo sfdisk -d /dev/mmcblk0" as docs/sfdisk-<name>.txt in this repository and commit it; explain
that bare-metal restore rebuilds the partition table from it (see docs/DESIGN.md, Restore paths).
Finally, print a summary: every host, what was installed where, the policy names, and the exact
next steps for a file-level and a bare-metal restore.
```

What Claude cannot do for you: type your passwords, click through the Veeam console on your
behalf unless you have given it browser access, or press the Secure Boot enrollment keys at the
proxy's console. Everything else in the deployment is reproducible from this repository.
