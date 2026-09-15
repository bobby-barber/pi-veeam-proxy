#!/bin/bash
# Per-policy wrapper (lives on the backup server, pushed to the proxy by VBR). Selects its own target list.
PI_VEEAM_TARGETS=/etc/pi-veeam/targets.d/pi-01 exec /usr/local/sbin/pi-job-pre.sh
