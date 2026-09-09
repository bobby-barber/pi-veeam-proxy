#!/bin/bash
# Create the two per-policy wrapper scripts for a Pi. Usage: pi-make-wrappers.sh <pi-name> [outdir]
# The wrappers are installed in /usr/local/sbin on the proxy AND must be copied, unchanged, to
# /var/lib/veeam/scripts/ on the Veeam backup server (VBR hashes them there and pushes them to the agent).
set -euo pipefail
NAME="$1"; OUT="${2:-/usr/local/sbin}"
[ -f "/etc/pi-veeam/targets.d/$NAME" ] || { echo "missing /etc/pi-veeam/targets.d/$NAME (one line: <pi-ip> <ssh-user>)" >&2; exit 1; }
for kind in pre post; do
  f="$OUT/pi-veeam-${kind}-${NAME}.sh"
  printf '#!/bin/bash\n# Per-policy wrapper for %s (lives on the backup server, pushed to the proxy by VBR).\nPI_VEEAM_TARGETS=/etc/pi-veeam/targets.d/%s exec /usr/local/sbin/pi-job-%s.sh\n' "$NAME" "$NAME" "$kind" > "$f"
  chmod 755 "$f"; echo "wrote $f"
done
echo "copy both files to /var/lib/veeam/scripts/ on the Veeam server, then reference them in the policy's Scripts tab."
