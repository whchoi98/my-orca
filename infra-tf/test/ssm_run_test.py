"""Tests for scripts/ssm_run.sh. Run: python3 -I test/ssm_run_test.py

The script runs with a fake aws on PATH that records its calls and plays back the answers of
the four SSM calls ssm_run.sh makes. The real install is exercised on a real host only.
"""
import json
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "ssm_run.sh"

FAKE_AWS = """#!/bin/bash
echo "$*" >> "$FAKE_DIR/calls"
case "$2" in
    describe-instance-information) echo "${FAKE_PING:-Online}" ;;
    send-command)
        [ -z "${FAKE_SEND_FAIL:-}" ] || { echo "AccessDeniedException" >&2; exit 254; }
        for arg in "$@"; do
            case "$arg" in file://*) cp "${arg#file://}" "$FAKE_DIR/params.json" ;; esac
        done
        echo "cmd-0001" ;;
    get-command-invocation)
        if [[ "$*" == *"--query Status"* ]]; then
            n=$(cat "$FAKE_DIR/polls" 2>/dev/null || echo 0)
            echo $((n + 1)) > "$FAKE_DIR/polls"
            read -r -a statuses <<<"${FAKE_STATUSES:-Success}"
            [ "$n" -lt "${#statuses[@]}" ] || n=$(( ${#statuses[@]} - 1 ))
            if [ "${statuses[$n]}" = Missing ]; then
                echo "InvocationDoesNotExist" >&2
                exit 254
            fi
            echo "${statuses[$n]}"
        else
            printf '%s\\n' "${FAKE_OUTPUT:-}"
        fi ;;
    *) echo "unexpected aws call: $*" >&2; exit 99 ;;
esac
"""


class SsmRunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        aws = bin_dir / "aws"
        aws.write_text(FAKE_AWS)
        aws.chmod(aws.stat().st_mode | stat.S_IXUSR)
        self.host_script = self.tmp / "host_script.sh"
        self.host_script.write_text("#!/bin/bash\necho HOST-SCRIPT-BODY\n")
        self.env = {
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "HOME": str(self.tmp),
            "FAKE_DIR": str(self.tmp),
            "SSM_RUN_POLL_SECONDS": "0",
            "ORCA_INSTANCE_ID": "i-0123456789abcdef0",
            "AWS_REGION": "ap-northeast-2",
            "ORCA_VERSION": "1.4.269",
            "ORCA_PAIRING_ADDRESS": "wss://example.cloudfront.test",
            "ORCA_REGION": "ap-northeast-2",
            "ORCA_USER": "ec2-user",
            "GATE_KVS_ARN": "arn:aws:cloudfront::123456789012:key-value-store/example-store",
            "GATE_BUNDLE_URL": "s3://bucket/gate/abc.zip",
        }

    def run_script(self, mode, script=None, drop=(), **env):
        e = dict(self.env)
        e.update(env)
        for name in drop:
            e.pop(name, None)
        return subprocess.run(["/bin/bash", str(SCRIPT), mode, str(script or self.host_script)],
                              capture_output=True, text=True, env=e, timeout=30)

    def calls(self):
        path = self.tmp / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def sent(self):
        return json.loads((self.tmp / "params.json").read_text())

    def test_install_sends_the_script_behind_its_exports_and_waits(self):
        r = self.run_script("install", FAKE_STATUSES="Missing Pending InProgress Success", FAKE_OUTPUT="[orca-install] done")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        params = self.sent()
        self.assertEqual(params["executionTimeout"], ["1800"])
        self.assertEqual(len(params["commands"]), 1)
        command = params["commands"][0]
        self.assertEqual(command.split("\n")[:6], [
            "export ORCA_VERSION=1.4.269",
            "export ORCA_PAIRING_ADDRESS=wss://example.cloudfront.test",
            "export ORCA_REGION=ap-northeast-2",
            "export ORCA_USER=ec2-user",
            "export GATE_KVS_ARN=arn:aws:cloudfront::123456789012:key-value-store/example-store",
            "export GATE_BUNDLE_URL=s3://bucket/gate/abc.zip",
        ])
        self.assertTrue(command.endswith("#!/bin/bash\necho HOST-SCRIPT-BODY\n"))
        # Four status polls: the missing invocation and the two pending states are waited out.
        self.assertEqual(sum("--query Status" in c for c in self.calls()), 4)
        send = next(c for c in self.calls() if " send-command " in c)
        self.assertIn("--instance-ids i-0123456789abcdef0", send)
        self.assertIn("--document-name AWS-RunShellScript", send)
        self.assertIn("[orca-install] done", r.stdout)

    def test_values_are_shell_quoted(self):
        r = self.run_script("install", ORCA_PAIRING_ADDRESS="wss://x; touch /tmp/pwned $(id)", ORCA_USER="o'brien")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        command = self.sent()["commands"][0]
        self.assertIn("export ORCA_PAIRING_ADDRESS='wss://x; touch /tmp/pwned $(id)'\n", command)
        self.assertIn("export ORCA_USER='o'\"'\"'brien'\n", command)

    def test_missing_inputs_become_empty_exports_and_the_user_defaults(self):
        r = self.run_script("uninstall", drop=("ORCA_VERSION", "ORCA_PAIRING_ADDRESS", "ORCA_REGION", "ORCA_USER",
                                               "GATE_KVS_ARN", "GATE_BUNDLE_URL"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        command = self.sent()["commands"][0]
        self.assertIn("export ORCA_VERSION=''\n", command)
        self.assertIn("export ORCA_USER=ec2-user\n", command)
        self.assertIn("export GATE_KVS_ARN=''\n", command)

    def test_failed_install_fails_and_shows_the_output_tail(self):
        r = self.run_script("install", FAKE_STATUSES="InProgress Failed", FAKE_OUTPUT="x" * 5000 + "\n[orca-install] ERROR: port 6768 is in use")
        self.assertEqual(r.returncode, 1)
        self.assertIn("ERROR: port 6768 is in use", r.stdout)
        self.assertIn("ended: Failed", r.stdout)
        self.assertIn("cmd-0001", r.stdout)
        # Only the tail of a long output is shown.
        self.assertLess(r.stdout.count("x"), 1600)

    def test_install_needs_the_instance_online(self):
        r = self.run_script("install", FAKE_PING="None")
        self.assertEqual(r.returncode, 1)
        self.assertIn("not online", r.stdout)
        self.assertFalse(any(" send-command " in c for c in self.calls()))

    def test_install_fails_when_the_command_cannot_be_sent(self):
        r = self.run_script("install", FAKE_SEND_FAIL="1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("send-command failed", r.stdout)

    def test_install_gives_up_after_the_wait_limit(self):
        r = self.run_script("install", FAKE_STATUSES="InProgress", SSM_RUN_WAIT_SECONDS="0")
        self.assertEqual(r.returncode, 1)
        self.assertIn("still InProgress", r.stdout)

    def test_uninstall_never_blocks_a_destroy(self):
        cases = {
            "offline instance": {"FAKE_PING": "None"},
            "send-command refused": {"FAKE_SEND_FAIL": "1"},
            "failed uninstall": {"FAKE_STATUSES": "Failed"},
            "timed out uninstall": {"FAKE_STATUSES": "InProgress", "SSM_RUN_WAIT_SECONDS": "0"},
        }
        for name, env in cases.items():
            with self.subTest(name):
                (self.tmp / "polls").unlink(missing_ok=True)
                r = self.run_script("uninstall", **env)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_offline_uninstall_sends_nothing(self):
        r = self.run_script("uninstall", FAKE_PING="ConnectionLost")
        self.assertEqual(r.returncode, 0)
        self.assertIn("skipping the uninstall", r.stdout)
        self.assertFalse(any(" send-command " in c for c in self.calls()))

    def test_missing_script(self):
        self.assertEqual(self.run_script("install", script=self.tmp / "nope.sh").returncode, 1)
        self.assertEqual(self.run_script("uninstall", script=self.tmp / "nope.sh").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_unknown_mode_and_missing_target(self):
        self.assertEqual(self.run_script("upgrade").returncode, 2)
        self.assertNotEqual(self.run_script("install", drop=("ORCA_INSTANCE_ID",)).returncode, 0)
        self.assertNotEqual(self.run_script("install", drop=("AWS_REGION",)).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_the_real_host_scripts_keep_their_inputs(self):
        """ssm_run.sh exports exactly what install_orca.sh documents and handler.py passes."""
        host = SCRIPT.resolve().parents[2] / "infra-cdk" / "lib" / "host"
        handler = (host / "handler.py").read_text()
        install = (host / "install_orca.sh").read_text()
        ssm_run = SCRIPT.read_text()
        for name in ("ORCA_VERSION", "ORCA_PAIRING_ADDRESS", "ORCA_REGION", "ORCA_USER", "GATE_KVS_ARN", "GATE_BUNDLE_URL"):
            with self.subTest(name):
                self.assertIn(f'"{name}"', handler)
                self.assertIn(name, install)
                self.assertIn(f'"{name}"', ssm_run)


if __name__ == "__main__":
    unittest.main()
