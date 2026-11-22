"""PairingInfo custom resource: put Orca's pairing link in the stack outputs.

The link exists only after the instance has finished setup and orca-serve has started, so the
CDK Provider framework calls is_complete every 30 seconds until read_pairing.sh, sent through
SSM Run Command, reports it. Nothing about the instance changes: the command only reads
journald and the setup code file.

The values are credentials. They are returned as resource attributes for the outputs and are
never printed here; the provider framework's own logging stays at FATAL.
"""
import json
import os
import time
from pathlib import Path

import boto3

SCRIPT = Path(__file__).with_name("read_pairing.sh").read_text()
# After this, report "unavailable" rather than fail the stack: a slow or broken setup should not
# roll back the instance the user would debug. Below the provider's totalTimeout.
GIVE_UP_SECONDS = int(os.environ.get("PAIRING_GIVE_UP_SECONDS", str(40 * 60)))
COMMAND_WAIT_SECONDS = 50
POLL_SECONDS = 2
FALLBACK = "bash get_pairing_url.sh"

_ssm = None


def ssm():
    global _ssm
    if _ssm is None:
        _ssm = boto3.client("ssm")
    return _ssm


def on_event(event, _context):
    if event["RequestType"] == "Delete":
        return {}
    # Merged into every is_complete event, and into the final attributes.
    return {
        "PhysicalResourceId": "orca-pairing-info",
        "Data": {"WaitUntil": str(int(time.time()) + GIVE_UP_SECONDS)},
    }


def is_complete(event, _context):
    if event["RequestType"] == "Delete":
        return {"IsComplete": True}
    props = event["ResourceProperties"]
    state = read_state(props["InstanceId"])
    if state.get("state") == "wait":
        wait_until = int(event.get("Data", {}).get("WaitUntil", "0"))
        if time.time() < wait_until:
            print(f"waiting for {state.get('reason', 'server')}")
            return {"IsComplete": False}
        state = {"state": "unavailable", "reason": f"timed out waiting for {state.get('reason', 'server')}"}
    print(f"pairing state: {state.get('state')}" + (f" ({state['reason']})" if state.get("reason") else ""))
    return {"IsComplete": True, "Data": attributes(state, props.get("GateEnabled") == "true")}


def read_state(instance_id):
    """Run read_pairing.sh on the instance; any SSM hiccup is a 'wait' for the next poll."""
    info = ssm().describe_instance_information(
        Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
    )["InstanceInformationList"]
    if not any(i.get("PingStatus") == "Online" for i in info):
        return {"state": "wait", "reason": "SSM agent"}

    command_id = ssm().send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": [SCRIPT]},
        TimeoutSeconds=60,
        Comment="Orca pairing link for the stack outputs",
    )["Command"]["CommandId"]

    deadline = time.monotonic() + COMMAND_WAIT_SECONDS
    while True:
        time.sleep(POLL_SECONDS)
        try:
            invocation = ssm().get_command_invocation(CommandId=command_id, InstanceId=instance_id)
        except ssm().exceptions.InvocationDoesNotExist:
            invocation = {"Status": "Pending"}
        status = invocation["Status"]
        if status == "Success":
            break
        if status not in ("Pending", "InProgress", "Delayed") or time.monotonic() > deadline:
            return {"state": "wait", "reason": f"SSM command ({status})"}

    lines = invocation.get("StandardOutputContent", "").strip().splitlines()
    try:
        state = json.loads(lines[-1])
    except (IndexError, ValueError):
        return {"state": "wait", "reason": "SSM command output"}
    return state if isinstance(state, dict) else {"state": "wait", "reason": "SSM command output"}


def attributes(state, gate_enabled):
    """Output values. Every key is always present: Fn::GetAtt on a missing one fails the stack.

    ASCII only: CloudFormation stores non-ASCII characters in custom resource attributes as "?"
    (seen on this stack: Korean text came back as "?? (?? ...)"). deploy_orca.sh translates the
    "none ..." and "unavailable ..." notes for the terminal.
    """
    if state.get("state") != "ready":
        note = f"unavailable ({state.get('reason', 'unknown')}) - run: {FALLBACK} --restart"
        return {"PairingWebLink": note, "PairingCode": note, "GateSetupCode": note}

    code = state.get("setupCode", "")
    web = state.get("webClientUrl", "")
    if web and code:
        # Same link get_pairing_url.sh prints: the first page asks for a new access password.
        web = f"{web}&gate-setup={code}"
    if not code:
        code = "none (access password already set)" if gate_enabled else "none (password gate disabled)"
    return {
        "PairingWebLink": web or "none (this Orca build has no web client) - use PairingCode",
        "PairingCode": state["pairingCode"],
        "GateSetupCode": code,
    }
