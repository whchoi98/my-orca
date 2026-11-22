#!/bin/bash
# Removes what install_orca.sh added. Sent by the OrcaHostInstall custom resource (handler.py)
# when the stack is deleted. Keeps ~/.config/orca (sessions, settings, paired devices), so a
# later install picks up where this one left off. Best effort: every step runs even when an
# earlier one fails, and the script always exits 0 so a stack delete is never blocked.
set -uo pipefail
exec 2>&1

ORCA_USER="${ORCA_USER:-ec2-user}"
STATE=/var/lib/orca-bootstrap

log() { echo "[orca-uninstall] $*"; }

for unit in orca-serve orca-gate-setup; do
    if [ -f "/etc/systemd/system/$unit.service" ]; then
        # KillMode=process would leave orca-serve's terminal daemon running after the stop.
        systemctl kill --kill-whom=all "$unit.service" 2>/dev/null || true
        systemctl disable --now --quiet "$unit.service" 2>/dev/null || true
        rm -f "/etc/systemd/system/$unit.service"
        log "removed $unit.service"
    fi
done
systemctl daemon-reload

# Leftovers outside a running unit: the Electron processes run from /opt/Orca and the terminal
# daemon from the node runtime Orca unpacks under ~/.config/orca/orcad-artifacts. (Xvfb runs with
# -terminate and exits with its last client.)
ORCA_HOME=$(getent passwd "$ORCA_USER" | cut -d: -f6)
PATTERN="^(/opt/(Orca|orca-ide)/|$ORCA_HOME/\.config/orca/orcad-artifacts/)"
if pkill -TERM -u "$ORCA_USER" -f "$PATTERN"; then
    sleep 5
    pkill -KILL -u "$ORCA_USER" -f "$PATTERN" || true
    log "stopped remaining Orca processes"
fi

if rpm -q orca-ide >/dev/null 2>&1; then
    rpm -e --nodeps orca-ide && log "removed the orca-ide package"
fi
rm -rf /etc/orca /opt/orca-gate /opt/orca-gate-src

if [ -f "$STATE/linger-enabled-by-orca" ]; then
    loginctl disable-linger "$ORCA_USER" && log "turned lingering for $ORCA_USER back off"
fi
rm -rf "$STATE"
log "done; kept $(getent passwd "$ORCA_USER" | cut -d: -f6)/.config/orca"
exit 0
