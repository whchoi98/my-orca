"""Tests for the --tf option of get_pairing_url.sh, set_password.sh and cleanup.sh.
Run: python3 -I test/ops_scripts_test.py

Each script runs from a temp dir with fake terraform, aws and session-manager-plugin on PATH.
Nothing here reaches AWS or a server.
"""
import base64
import hashlib
import json
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTANCE = "i-0123456789abcdef0"
KVS_ARN = "arn:aws:cloudfront::123456789012:key-value-store/example-store"

FAKE_TERRAFORM = r"""#!/bin/bash
echo "$*" >> "$FAKE_DIR/terraform-calls"
args=("$@")
[[ "${args[0]}" == -chdir=* ]] && args=("${args[@]:1}")
case "${args[0]}" in
    init) exit "${FAKE_INIT_RC:-0}" ;;
    state) for line in ${FAKE_STATE:-}; do echo "$line"; done ;;
    output)
        name="${args[${#args[@]}-1]}"
        var="FAKE_OUT_$name"
        [ -n "${!var:-}" ] || exit 1
        printf '%s' "${!var}" ;;
    destroy) echo "Destroy complete!"; exit "${FAKE_DESTROY_RC:-0}" ;;
esac
"""

FAKE_AWS = r"""#!/bin/bash
echo "$*" >> "$FAKE_DIR/aws-calls"
case "$1 $2" in
    "cloudformation describe-stacks") exit 255 ;;
    "ssm start-session") echo "SESSION-OUTPUT" ;;
    "ssm send-command") echo "cmd-0001" ;;
    "ssm wait") ;;
    "cloudfront-keyvaluestore describe-key-value-store") echo "ETAG1" ;;
    "cloudfront-keyvaluestore get-key") echo "${FAKE_SIGNKEY:-}"; [ -n "${FAKE_SIGNKEY:-}" ] || exit 254 ;;
    "cloudfront-keyvaluestore list-keys") echo '["auth-salt", "auth-hash", "auth-signkey"]' ;;
    "cloudfront-keyvaluestore update-keys")
        for arg in "$@"; do
            case "$arg" in file://*) cp "${arg#file://}" "$FAKE_DIR/update.json" ;; esac
        done ;;
    *) echo "unexpected aws call: $*" >&2; exit 99 ;;
esac
"""


class OpsScriptsTfTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        for name in ("get_pairing_url.sh", "set_password.sh", "cleanup.sh"):
            shutil.copy(ROOT / name, self.tmp / name)
        for mode in ("dedicated", "attach"):
            (self.tmp / "infra-tf" / mode).mkdir(parents=True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, text in (("terraform", FAKE_TERRAFORM), ("aws", FAKE_AWS), ("session-manager-plugin", "#!/bin/bash\n")):
            path = bin_dir / name
            path.write_text(text)
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
        self.env = {
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "HOME": str(self.tmp),
            "FAKE_DIR": str(self.tmp),
            "FAKE_OUT_instance_id": INSTANCE,
            "FAKE_OUT_region": "us-west-2",
            "FAKE_OUT_password_gate_store_arn": KVS_ARN,
            "FAKE_OUT_cloudfront_url": "https://example.test",
            "FAKE_OUT_host": "VscodeServerStack",
            "FAKE_STATE": "terraform_data.host_install module.routes.aws_lb_listener_rule.orca",
        }

    def run_script(self, name, *args, stdin="", drop=(), **env):
        e = dict(self.env)
        e.update(env)
        for key in drop:
            e.pop(key, None)
        return subprocess.run(["/bin/bash", str(self.tmp / name), *args],
                              input=stdin, capture_output=True, text=True, env=e, timeout=60)

    def calls(self, tool):
        path = self.tmp / f"{tool}-calls"
        return path.read_text().splitlines() if path.exists() else []

    # ---------------- get_pairing_url.sh ----------------
    def test_pairing_link_reads_the_instance_and_region_from_terraform(self):
        r = self.run_script("get_pairing_url.sh", "--tf", "attach")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        session = next(c for c in self.calls("aws") if c.startswith("ssm start-session"))
        self.assertIn(f"--target {INSTANCE}", session)
        self.assertIn("--region us-west-2", session)
        self.assertTrue(all(f"-chdir={self.tmp}/infra-tf/attach" in c for c in self.calls("terraform")))
        self.assertFalse(any(c.startswith("cloudformation") for c in self.calls("aws")))

    def test_pairing_link_without_a_terraform_deployment(self):
        r = self.run_script("get_pairing_url.sh", "--tf", "dedicated", drop=("FAKE_OUT_instance_id",))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("infra-tf/dedicated", r.stderr)
        self.assertFalse(any(c.startswith("ssm") for c in self.calls("aws")))

    def test_unknown_tf_mode_is_refused(self):
        for script in ("get_pairing_url.sh", "set_password.sh", "cleanup.sh"):
            with self.subTest(script):
                r = self.run_script(script, "--tf", "everything", "--yes" if script == "cleanup.sh" else "--help")
                if script == "cleanup.sh":
                    self.assertNotEqual(r.returncode, 0)
        r = self.run_script("get_pairing_url.sh", "--tf", "everything")
        self.assertNotEqual(r.returncode, 0)
        r = self.run_script("set_password.sh", "--tf", "everything", "--password-stdin", stdin="long enough password\n")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual([c for c in self.calls("aws") if not c.startswith("cloudformation")], [])
        self.assertFalse(any(" destroy" in c for c in self.calls("terraform")))

    # ---------------- set_password.sh ----------------
    def test_password_is_written_to_the_store_terraform_reports(self):
        r = self.run_script("set_password.sh", "--tf", "dedicated", "--password-stdin", stdin="correct horse battery\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        update = json.loads((self.tmp / "update.json").read_text())
        self.assertEqual(update["KvsARN"], KVS_ARN)
        self.assertEqual(update["IfMatch"], "ETAG1")
        puts = {item["Key"]: item["Value"] for item in update["Puts"]}
        self.assertEqual(sorted(puts), ["auth-hash", "auth-salt", "auth-signkey"])
        wire = base64.b64encode(b"correct horse battery").decode()
        self.assertEqual(puts["auth-hash"], hashlib.sha256(f"{puts['auth-salt']}:{wire}".encode()).hexdigest())
        self.assertNotIn("correct horse", "\n".join(self.calls("aws") + self.calls("terraform")) + r.stdout + r.stderr)
        self.assertFalse(any(c.startswith("cloudformation") for c in self.calls("aws")))
        self.assertTrue(all(f"-chdir={self.tmp}/infra-tf/dedicated" in c for c in self.calls("terraform")))

    def test_password_needs_the_gate(self):
        r = self.run_script("set_password.sh", "--tf", "attach", "--password-stdin", stdin="correct horse battery\n",
                            drop=("FAKE_OUT_password_gate_store_arn",))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("infra-tf/attach", r.stderr)
        self.assertFalse((self.tmp / "update.json").exists())

    def test_reset_ui_targets_the_terraform_instance(self):
        r = self.run_script("set_password.sh", "--tf", "attach", "--reset-ui", "--yes")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        send = next(c for c in self.calls("aws") if c.startswith("ssm send-command"))
        self.assertIn(f"--instance-ids {INSTANCE}", send)
        self.assertIn("--region us-west-2", send)
        self.assertIn("get_pairing_url.sh --tf attach", r.stdout)

    # ---------------- cleanup.sh ----------------
    def test_cleanup_destroys_the_terraform_deployment_and_its_saved_inputs(self):
        saved = self.tmp / "infra-tf" / "attach" / "orca.auto.tfvars.json"
        saved.write_text("{}")
        r = self.run_script("cleanup.sh", "--tf", "attach", "--yes")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        destroy = [c for c in self.calls("terraform") if " destroy" in c]
        self.assertEqual(len(destroy), 1)
        self.assertIn(f"-chdir={self.tmp}/infra-tf/attach", destroy[0])
        self.assertFalse(saved.exists())
        # The Terraform path ends there: it must not go on to look for a CloudFormation stack.
        self.assertEqual(self.calls("aws"), [])

    def test_cleanup_asks_first(self):
        r = self.run_script("cleanup.sh", "--tf", "attach", stdin="y\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(any(" destroy" in c for c in self.calls("terraform")))
        r = self.run_script("cleanup.sh", "--tf", "attach", stdin="yes\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(sum(" destroy" in c for c in self.calls("terraform")), 1)

    def test_cleanup_with_nothing_deployed(self):
        r = self.run_script("cleanup.sh", "--tf", "dedicated", "--yes", FAKE_STATE="")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("배포된 것이 없습니다", r.stdout)
        self.assertFalse(any(" destroy" in c for c in self.calls("terraform")))
        self.assertEqual(self.calls("aws"), [])

    def test_failed_destroy_keeps_the_saved_inputs(self):
        saved = self.tmp / "infra-tf" / "attach" / "orca.auto.tfvars.json"
        saved.write_text("{}")
        r = self.run_script("cleanup.sh", "--tf", "attach", "--yes", FAKE_DESTROY_RC="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(saved.exists())

    def test_cleanup_without_tf_still_uses_cloudformation(self):
        r = self.run_script("cleanup.sh", "--yes")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(any(c.startswith("cloudformation describe-stacks") for c in self.calls("aws")))
        self.assertEqual(self.calls("terraform"), [])


if __name__ == "__main__":
    unittest.main()
