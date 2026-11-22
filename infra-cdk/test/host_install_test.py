"""Tests for lib/host (OrcaHostInstall custom resource). Run: python3 -I test/host_install_test.py

handler.py runs against a fake SSM client (boto3 is stubbed, so no AWS SDK is needed).
install_orca.sh's guards run against fake commands on PATH; the full install is exercised on a
real host only.
"""
import contextlib
import importlib.util
import io
import os
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
HOST = HERE.parent / "lib" / "host"
INSTANCE = "i-0abc"
PROPS = {
    "InstanceId": INSTANCE,
    "User": "ec2-user",
    "OrcaVersion": "1.4.253",
    "PairingAddress": "wss://dexample.cloudfront.net",
    "Region": "ap-northeast-2",
    "GateStoreArn": "arn:aws:cloudfront::111122223333:key-value-store/abc",
    "GateBundleUrl": "s3://bucket/gate.zip",
    "ScriptSha256": "0" * 64,
}


def load_handler():
    sys.modules["boto3"] = types.SimpleNamespace(client=lambda name: None)
    spec = importlib.util.spec_from_file_location("host_handler", HOST / "handler.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class InvocationDoesNotExist(Exception):
    pass


class FakeSsm:
    def __init__(self, online=True, statuses=("Success",), stdout="", stderr=""):
        self.online, self.statuses = online, list(statuses)
        self.stdout, self.stderr = stdout, stderr
        self.sent = []
        self.exceptions = types.SimpleNamespace(InvocationDoesNotExist=InvocationDoesNotExist)

    def describe_instance_information(self, Filters):
        assert Filters == [{"Key": "InstanceIds", "Values": [INSTANCE]}], Filters
        status = "Online" if self.online else "ConnectionLost"
        return {"InstanceInformationList": [{"InstanceId": INSTANCE, "PingStatus": status}]}

    def send_command(self, **kwargs):
        self.sent.append(kwargs)
        return {"Command": {"CommandId": f"cmd-{len(self.sent)}"}}

    def get_command_invocation(self, CommandId, InstanceId):
        assert InstanceId == INSTANCE
        status = self.statuses.pop(0) if len(self.statuses) > 1 else self.statuses[0]
        if status == "missing":
            raise InvocationDoesNotExist()
        return {"Status": status, "StandardOutputContent": self.stdout, "StandardErrorContent": self.stderr}


def event(request_type, physical_id=None, data=None, props=PROPS):
    e = {"RequestType": request_type, "ResourceProperties": dict(props)}
    if physical_id is not None:
        e["PhysicalResourceId"] = physical_id
    if data is not None:
        e["Data"] = data
    return e


class HandlerTest(unittest.TestCase):
    def setUp(self):
        self.h = load_handler()

    def run_quietly(self, fn, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            result = fn(*args)
        return result, out.getvalue()

    def test_create_sends_the_install_script_with_its_inputs(self):
        self.h._ssm = ssm = FakeSsm()
        result = self.h.on_event(event("Create"), None)
        self.assertEqual(result, {"PhysicalResourceId": "orca-host-" + INSTANCE, "Data": {"CommandId": "cmd-1"}})
        sent = ssm.sent[0]
        self.assertEqual(sent["InstanceIds"], [INSTANCE])
        self.assertEqual(sent["DocumentName"], "AWS-RunShellScript")
        self.assertEqual(sent["Parameters"]["executionTimeout"], ["1800"])
        command = sent["Parameters"]["commands"][0]
        self.assertTrue(command.endswith((HOST / "install_orca.sh").read_text()))
        self.assertIn("export ORCA_PAIRING_ADDRESS=wss://dexample.cloudfront.net", command)
        self.assertIn("export GATE_BUNDLE_URL=s3://bucket/gate.zip", command)

    def test_update_of_the_same_instance_keeps_the_physical_id(self):
        # A changed ID would make CloudFormation delete the old one, i.e. uninstall Orca.
        self.h._ssm = FakeSsm()
        result = self.h.on_event(event("Update", physical_id="orca-host-" + INSTANCE), None)
        self.assertEqual(result["PhysicalResourceId"], "orca-host-" + INSTANCE)

    def test_create_fails_fast_when_the_instance_is_offline(self):
        self.h._ssm = ssm = FakeSsm(online=False)
        with self.assertRaisesRegex(RuntimeError, "not online"):
            self.h.on_event(event("Create"), None)
        self.assertEqual(ssm.sent, [])

    def test_environment_values_stay_inert(self):
        hostile = dict(PROPS, PairingAddress="wss://x'; touch /tmp/pwned; echo '", GateStoreArn="")
        script = self.h.environment(hostile) + '\nprintf "%s|%s" "$ORCA_PAIRING_ADDRESS" "$GATE_KVS_ARN"'
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True).stdout
        self.assertEqual(out, "wss://x'; touch /tmp/pwned; echo '|")

    def test_is_complete_waits_for_the_command(self):
        for status in ("missing", "Pending", "InProgress", "Delayed"):
            self.h._ssm = FakeSsm(statuses=(status,))
            result = self.h.is_complete(event("Create", data={"CommandId": "cmd-1"}), None)
            self.assertEqual(result, {"IsComplete": False}, status)

    def test_success_completes(self):
        self.h._ssm = FakeSsm(stdout="[orca-install] done")
        result, printed = self.run_quietly(self.h.is_complete, event("Create", data={"CommandId": "cmd-1"}), None)
        self.assertEqual(result, {"IsComplete": True})
        self.assertIn("Success", printed)
        self.assertIn("[orca-install] done", printed)

    def test_failed_install_fails_the_deploy_with_its_output(self):
        for status in ("Failed", "TimedOut", "Cancelled"):
            self.h._ssm = FakeSsm(statuses=(status,), stdout="x" * 5000 + "[orca-install] ERROR: port 6768")
            with self.assertRaisesRegex(RuntimeError, f"ended {status}.*port 6768"):
                self.run_quietly(self.h.is_complete, event("Update", data={"CommandId": "cmd-1"}), None)

    def test_delete_uninstalls_when_installed_and_online(self):
        self.h._ssm = ssm = FakeSsm()
        result = self.h.on_event(event("Delete", physical_id="orca-host-" + INSTANCE), None)
        self.assertEqual(result, {"Data": {"CommandId": "cmd-1"}})
        self.assertTrue(ssm.sent[0]["Parameters"]["commands"][0].endswith((HOST / "uninstall_orca.sh").read_text()))

    def test_delete_never_blocks(self):
        # Nothing installed (a Create that failed before sending), or the instance is gone.
        for physical_id, ssm in (("some-provider-generated-id", FakeSsm()), ("orca-host-" + INSTANCE, FakeSsm(online=False))):
            self.h._ssm = ssm
            result, _ = self.run_quietly(self.h.on_event, event("Delete", physical_id=physical_id), None)
            self.assertEqual(result, {"Data": {"CommandId": ""}})
            self.assertEqual(ssm.sent, [])
            done, _ = self.run_quietly(self.h.is_complete, event("Delete", physical_id=physical_id, data=result["Data"]), None)
            self.assertEqual(done, {"IsComplete": True})
        # A failed uninstall is logged, not raised.
        self.h._ssm = FakeSsm(statuses=("Failed",), stdout="boom")
        done, printed = self.run_quietly(self.h.is_complete, event("Delete", data={"CommandId": "cmd-9"}), None)
        self.assertEqual(done, {"IsComplete": True})
        self.assertIn("Failed", printed)


FAKE = {
    # "<port>" listening only for the ports in $FAKE_BUSY_PORTS
    "ss": '#!/bin/bash\nfor p in $FAKE_BUSY_PORTS; do case "$*" in *":$p"*) echo "LISTEN 0 4096 0.0.0.0:$p 0.0.0.0:* users:((\\"other\\",pid=42,fd=3))";; esac; done\n',
    "systemctl": '#!/bin/bash\necho "systemctl $*" >> "$FAKE_LOG"\n[ "$1" = is-active ] && exit 3\nexit 0\n',
    "getent": '#!/bin/bash\necho "ec2-user:x:1000:1000::/home/ec2-user:/bin/bash"\n',
    "id": '#!/bin/bash\necho 1000\n',
    "uname": '#!/bin/bash\necho aarch64\n',
}
for name in ("dnf", "rpm", "curl", "install", "loginctl"):
    FAKE[name] = f'#!/bin/bash\necho "{name} $*" >> "$FAKE_LOG"\nexit 0\n'


class InstallScriptGuardTest(unittest.TestCase):
    def run_script(self, busy="", **env):
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp, "bin")
            bin_dir.mkdir()
            for name, body in FAKE.items():
                path = bin_dir / name
                path.write_text(body)
                path.chmod(path.stat().st_mode | stat.S_IEXEC)
            log = Path(tmp, "log")
            log.touch()
            base = {"PATH": f"{bin_dir}:/usr/bin:/bin", "FAKE_LOG": str(log), "FAKE_BUSY_PORTS": busy,
                    "ORCA_VERSION": "1.4.253", "ORCA_PAIRING_ADDRESS": "wss://d.example", "ORCA_REGION": "ap-northeast-2"}
            base.update(env)
            proc = subprocess.run(["bash", str(HOST / "install_orca.sh")], capture_output=True, text=True,
                                  env=base, timeout=30)
            return proc, log.read_text()

    def test_scripts_parse(self):
        for script in ("install_orca.sh", "uninstall_orca.sh"):
            subprocess.run(["bash", "-n", str(HOST / script)], check=True)

    def test_rollback_can_install_an_older_package(self):
        # A failed upgrade is rolled back by running the script with the previous version;
        # rpm refuses the older package without --oldpackage (UPDATE_ROLLBACK_FAILED).
        rpm_lines = [line.strip() for line in (HOST / "install_orca.sh").read_text().splitlines()
                     if line.strip().startswith("rpm -U")]
        self.assertEqual(len(rpm_lines), 1, rpm_lines)
        self.assertIn("--oldpackage", rpm_lines[0].split())

    def test_required_inputs(self):
        proc, calls = self.run_script(ORCA_PAIRING_ADDRESS="")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("ORCA_PAIRING_ADDRESS", proc.stdout + proc.stderr)
        self.assertEqual(calls, "")

    def test_never_takes_over_a_port_another_program_uses(self):
        proc, calls = self.run_script(busy="6768")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("port 6768 is in use by another program", proc.stdout)
        self.assertNotIn("dnf", calls)  # stopped before changing anything
        proc, calls = self.run_script(busy="6769", GATE_KVS_ARN="arn:kvs", GATE_BUNDLE_URL="s3://b/k")
        self.assertEqual(proc.returncode, 1)
        self.assertNotIn("dnf", calls)
        if os.access("/usr/local/bin/aws", os.X_OK):  # otherwise the AWS CLI check stops it first
            self.assertIn("port 6769 is in use by another program", proc.stdout)

    def test_gate_needs_its_bundle(self):
        proc, _ = self.run_script(GATE_KVS_ARN="arn:kvs")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("GATE_BUNDLE_URL is required", proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)
