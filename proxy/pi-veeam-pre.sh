#!/bin/bash
# The ONLY file that lives on the backup server (uploaded once via the thick console's Browse button).
# VBR copies it to /var/lib/veeam/scripts/<policy>/ on the proxy and runs it there as root.
# It never changes: adding a Pi is an edit to /etc/pi-veeam/targets on the proxy.
exec /usr/local/sbin/pi-job-pre.sh
