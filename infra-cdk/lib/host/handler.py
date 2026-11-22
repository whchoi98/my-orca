"""OrcaHostInstall custom resource: install orca-serve on an existing server over SSM.

Create and Update send install_orca.sh through SSM Run Command, and the CDK Provider framework
calls is_complete until the command finishes; a failed install fails the deploy with the tail of
its output. Delete sends uninstall_orca.sh, but never blocks the stack delete: an offline or
removed instance, or a failed uninstall, is logged and the delete goes on.

The scripts print nothing secret (see install_orca.sh), so their output may be logged.
"""
import shlex
from pathlib import Path

import boto3

HERE = Path(__file__).parent
INSTALL = (HERE / "install_orca.sh").read_text()
UNINSTALL = (HERE / "uninstall_orca.sh").read_text()
# Physical IDs this handler created; anything else (a Create that failed before sending) has
# nothing on the instance to remove.
ID_PREFIX = "orca-host-"
EXECUTION_TIMEOUT_SECONDS = 1800
OUTPUT_TAIL = 1500
PENDING = ("Pending", "InProgress", "Delayed")

_ssm = None


def ssm():
    global _ssm
    if _ssm is None:
        _ssm = boto3.client("ssm")
    return _ssm


def on_event(event, _context):
    props = event["ResourceProperties"]
    instance_id = props["InstanceId"]
    if event["RequestType"] == "Delete":
        if not event.get("PhysicalResourceId", "").startswith(ID_PREFIX):
            print("nothing was installed")
            return {"Data": {"CommandId": ""}}
        if not online(instance_id):
            print(f"{instance_id} is not online in SSM; skipping the uninstall")
            return {"Data": {"CommandId": ""}}
        return {"Data": {"CommandId": send(instance_id, props, UNINSTALL, "Orca uninstall (stack delete)")}}

    if not online(instance_id):
        raise RuntimeError(f"{instance_id} is not online in SSM Fleet Manager; the install needs the SSM agent")
    # Same ID on every update of the same instance. A new InstanceId yields a new ID, and
    # CloudFormation then deletes the old one, which uninstalls Orca from the old instance.
    return {
        "PhysicalResourceId": ID_PREFIX + instance_id,
        "Data": {"CommandId": send(instance_id, props, INSTALL, "Orca install")},
    }


def is_complete(event, _context):
    command_id = event.get("Data", {}).get("CommandId", "")
    if not command_id:
        return {"IsComplete": True}
    instance_id = event["ResourceProperties"]["InstanceId"]
    try:
        invocation = ssm().get_command_invocation(CommandId=command_id, InstanceId=instance_id)
    except ssm().exceptions.InvocationDoesNotExist:
        return {"IsComplete": False}
    status = invocation["Status"]
    if status in PENDING:
        return {"IsComplete": False}

    output = tail(invocation)
    print(f"{event['RequestType']}: SSM command {command_id} on {instance_id}: {status}\n{output}")
    if status == "Success" or event["RequestType"] == "Delete":
        return {"IsComplete": True}
    raise RuntimeError(
        f"Orca install on {instance_id} ended {status} (SSM command {command_id}). "
        f"Last output: {output[-700:]}"
    )


def online(instance_id):
    info = ssm().describe_instance_information(
        Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
    )["InstanceInformationList"]
    return any(i.get("PingStatus") == "Online" for i in info)


def send(instance_id, props, script, comment):
    return ssm().send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={
            "commands": [environment(props) + "\n" + script],
            "executionTimeout": [str(EXECUTION_TIMEOUT_SECONDS)],
        },
        TimeoutSeconds=600,
        Comment=comment,
    )["Command"]["CommandId"]


def environment(props):
    """install_orca.sh's inputs as shell exports; shlex.quote keeps any value inert."""
    values = {
        "ORCA_VERSION": props["OrcaVersion"],
        "ORCA_PAIRING_ADDRESS": props["PairingAddress"],
        "ORCA_REGION": props["Region"],
        "ORCA_USER": props.get("User", "ec2-user"),
        "GATE_KVS_ARN": props.get("GateStoreArn", ""),
        "GATE_BUNDLE_URL": props.get("GateBundleUrl", ""),
    }
    return "\n".join(f"export {key}={shlex.quote(value)}" for key, value in values.items())


def tail(invocation):
    text = (invocation.get("StandardOutputContent", "") + invocation.get("StandardErrorContent", "")).strip()
    return text[-OUTPUT_TAIL:]
