#!/bin/bash
# Runs on the Orca server through SSM Run Command (as root), sent by the PairingInfo custom
# resource (handler.py). Prints one JSON line:
#   {"state": "wait"}         setup or orca-serve start still in progress; the handler asks again
#   {"state": "unavailable"}  no link to report; "reason" says why and what to run instead
#   {"state": "ready", "webClientUrl", "pairingCode", "setupCode"}
# Exits 0 on every path so the handler reads the state from stdout, not from the command status.
# Values travel to python through the environment, not argv (/proc/*/cmdline is world-readable).
set -u
# Unset on the server; test/read_pairing_test.py points it at a fake root.
ROOT="${ORCA_PAIRING_TEST_ROOT:-}"

emit() {
    python3 -c 'import json, os
keys = ("state", "reason", "webClientUrl", "pairingCode", "setupCode")
print(json.dumps({k: os.environ["P_" + k] for k in keys if os.environ.get("P_" + k)}))'
    exit 0
}

if [ ! -f "$ROOT/var/lib/orca-bootstrap/done" ]; then
    # Restart=on-failure retries setup; "failed" means it gave up (StartLimitBurst).
    if [ "$(systemctl show -p ActiveState --value orca-bootstrap 2>/dev/null)" = failed ]; then
        P_state=unavailable P_reason="server setup failed (sudo tail -n 80 /var/log/user-data.log)" emit
    fi
    P_state=wait P_reason="server setup" emit
fi

if [ "$(systemctl show -p ActiveState --value orca-serve 2>/dev/null)" != active ]; then
    P_state=wait P_reason="orca-serve start" emit
fi

# Only the running process's lines: an earlier start may have printed an offer that a browser
# has since used, and the next start then prints a new one.
INVOCATION=$(systemctl show -p InvocationID --value orca-serve 2>/dev/null)
if [ -n "$INVOCATION" ]; then
    LOG=$(journalctl _SYSTEMD_INVOCATION_ID="$INVOCATION" -o cat --no-pager 2>/dev/null)
else
    LOG=$(journalctl -u orca-serve -b -o cat --no-pager 2>/dev/null)
fi
WEB=$(printf '%s\n' "$LOG" | sed -n 's/^Web client URL: //p' | tail -n 1)
PAIR=$(printf '%s\n' "$LOG" | sed -n 's/^Pairing URL: //p' | tail -n 1)

case "$PAIR" in
    orca://pair\?code=*) ;;
    "")
        WHY=$(printf '%s\n' "$LOG" | sed -n 's/^Pairing unavailable: //p' | tail -n 1)
        [ -n "$WHY" ] && P_state=unavailable P_reason="orca-serve: $WHY" emit
        # The readiness lines follow the start by a few seconds; after that they are not coming.
        STARTED_US=$(systemctl show -p ActiveEnterTimestampMonotonic --value orca-serve 2>/dev/null)
        UPTIME_S=$(awk '{print int($1)}' "$ROOT/proc/uptime")
        if [ $((UPTIME_S - ${STARTED_US:-0} / 1000000)) -lt 180 ]; then
            P_state=wait P_reason="orca-serve pairing link" emit
        fi
        P_state=unavailable P_reason="pairing link not in journald" emit
        ;;
    *) P_state=unavailable P_reason="orca-serve printed no pairing link: ${PAIR:0:120}" emit ;;
esac

# Present only until the access password is set (lib/gate/install.sh writes it, setup consumes it).
CODE=$(cat "$ROOT/etc/orca/gate-setup-code" 2>/dev/null || true)
P_state=ready P_webClientUrl="$WEB" P_pairingCode="$PAIR" P_setupCode="$CODE" emit
