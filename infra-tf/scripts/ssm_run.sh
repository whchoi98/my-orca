#!/bin/bash
# Runs a host script on an EC2 instance through SSM Run Command and waits for it to finish.
# Terraform counterpart of infra-cdk/lib/host/handler.py, called by the local-exec provisioners
# of ../attach (terraform_data.host_install and terraform_data.host_uninstall).
#
#   ssm_run.sh install   <install_orca.sh>     fails when the script fails
#   ssm_run.sh uninstall <uninstall_orca.sh>   never fails: a destroy must not be blocked by an
#                                              offline or removed instance, or a failed uninstall
#
# Environment:
#   ORCA_INSTANCE_ID, AWS_REGION                      the target
#   ORCA_VERSION, ORCA_PAIRING_ADDRESS, ORCA_REGION,
#   ORCA_USER, GATE_KVS_ARN, GATE_BUNDLE_URL           exported ahead of the script on the host
# The host scripts print nothing secret (see install_orca.sh), so the tail of their output is shown.
set -euo pipefail

USAGE="usage: ssm_run.sh <install|uninstall> <script>"
MODE="${1:?$USAGE}"
SCRIPT="${2:?$USAGE}"
case "$MODE" in
    install|uninstall) ;;
    *) echo "$USAGE" >&2; exit 2 ;;
esac
: "${ORCA_INSTANCE_ID:?}" "${AWS_REGION:?}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

# install_orca.sh's own limit on the host.
EXECUTION_TIMEOUT_SECONDS=1800
OUTPUT_TAIL=1500
POLL_SECONDS="${SSM_RUN_POLL_SECONDS:-5}"
# A little over the execution timeout plus the 600 s delivery timeout.
WAIT_SECONDS="${SSM_RUN_WAIT_SECONDS:-2500}"

log() { echo "[ssm-run] $*"; }
# install: fail the apply. uninstall: report and let the destroy go on.
give_up() {
    log "$*"
    [ "$MODE" = uninstall ] && exit 0
    exit 1
}

[ -f "$SCRIPT" ] || give_up "script not found: $SCRIPT"
for cmd in aws python3; do
    command -v "$cmd" >/dev/null 2>&1 || give_up "$cmd is required"
done

PING=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$ORCA_INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
if [ "$PING" != Online ]; then
    if [ "$MODE" = uninstall ]; then
        log "$ORCA_INSTANCE_ID is not online in SSM; skipping the uninstall"
        exit 0
    fi
    give_up "$ORCA_INSTANCE_ID is not online in SSM Fleet Manager; the install needs the SSM agent"
fi

# The script's inputs as shell exports ahead of it; shlex.quote keeps any value inert.
PARAMS=$(umask 077 && mktemp)
trap 'rm -f "$PARAMS"' EXIT
python3 - "$SCRIPT" "$PARAMS" "$EXECUTION_TIMEOUT_SECONDS" <<'PY'
import json
import os
import shlex
import sys

NAMES = ("ORCA_VERSION", "ORCA_PAIRING_ADDRESS", "ORCA_REGION", "ORCA_USER", "GATE_KVS_ARN", "GATE_BUNDLE_URL")
DEFAULTS = {"ORCA_USER": "ec2-user"}

exports = "\n".join(
    f"export {name}={shlex.quote(os.environ.get(name) or DEFAULTS.get(name, ''))}" for name in NAMES
)
with open(sys.argv[1]) as f:
    script = f.read()
with open(sys.argv[2], "w") as f:
    json.dump({"commands": [exports + "\n" + script], "executionTimeout": [sys.argv[3]]}, f)
PY

if [ "$MODE" = install ]; then
    COMMENT="Orca install (terraform)"
else
    COMMENT="Orca uninstall (terraform destroy)"
fi
COMMAND_ID=$(aws ssm send-command --instance-ids "$ORCA_INSTANCE_ID" --document-name AWS-RunShellScript \
    --parameters "file://$PARAMS" --timeout-seconds 600 --comment "$COMMENT" \
    --query Command.CommandId --output text) || give_up "ssm send-command failed"
log "$MODE on $ORCA_INSTANCE_ID: SSM command $COMMAND_ID"

DEADLINE=$(( $(date +%s) + WAIT_SECONDS ))
while :; do
    sleep "$POLL_SECONDS"
    # Right after send-command the invocation may not exist yet; that reads as Pending.
    STATUS=$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$ORCA_INSTANCE_ID" \
        --query Status --output text 2>/dev/null || echo Pending)
    case "$STATUS" in
        Pending|InProgress|Delayed) ;;
        *) break ;;
    esac
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        STATUS="still $STATUS after ${WAIT_SECONDS}s"
        break
    fi
done

# Both host scripts send stderr to stdout.
OUTPUT=$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$ORCA_INSTANCE_ID" \
    --query StandardOutputContent --output text 2>/dev/null || true)
if [ -n "$OUTPUT" ]; then
    tail -c "$OUTPUT_TAIL" <<<"$OUTPUT"
fi

if [ "$STATUS" = Success ]; then
    log "$MODE finished"
    exit 0
fi
give_up "Orca $MODE on $ORCA_INSTANCE_ID ended: $STATUS (SSM command $COMMAND_ID)"
