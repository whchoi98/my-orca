"""Tests for upgrade_orca.sh. Run: python3 -I test/upgrade_test.py

The script runs from a temp dir next to a fake deploy_orca.sh that records its arguments, with
fake aws and curl on PATH. The real deploy (CDK + SSM install) is exercised on a real host only.
"""
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "upgrade_orca.sh"

FAKE_AWS = """#!/bin/bash
# describe-stacks: "<OrcaVersion>\\t<HostStack>", or a missing stack
[ -n "${FAKE_STACK:-}" ] || { echo "Stack does not exist" >&2; exit 255; }
printf '%s\\t%s\\n' "$FAKE_CURRENT" "$FAKE_HOST"
"""

FAKE_CURL = """#!/bin/bash
url="${@: -1}"
case "$url" in
    */releases/latest) [ -n "${FAKE_LATEST:-}" ] || exit 22; echo "{\\"tag_name\\": \\"v$FAKE_LATEST\\"}" ;;
    */releases/tags/v*) tag="${url##*/releases/tags/v}"; [[ " ${FAKE_TAGS:-} " == *" $tag "* ]] || exit 22 ;;
    *) exit 22 ;;
esac
"""

FAKE_DEPLOY = """#!/bin/bash
printf '%s\\n' "$@" > "$(dirname "$0")/deploy-args"
echo "FAKE DEPLOY DONE"
"""


def write_exec(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class UpgradeScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        shutil.copy(SCRIPT, self.tmp / "upgrade_orca.sh")
        write_exec(self.tmp / "deploy_orca.sh", FAKE_DEPLOY)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        write_exec(bin_dir / "aws", FAKE_AWS)
        write_exec(bin_dir / "curl", FAKE_CURL)
        self.env = {
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "HOME": str(self.tmp),
            "FAKE_STACK": "1",
            "FAKE_CURRENT": "1.4.253",
            "FAKE_HOST": "VscodeServerStack",
            "FAKE_LATEST": "1.4.260",
            "FAKE_TAGS": "1.4.253 1.4.260",
        }

    def run_script(self, *args, stdin="", **env):
        e = dict(self.env)
        e.update(env)
        return subprocess.run(["/bin/bash", str(self.tmp / "upgrade_orca.sh"), *args],
                              input=stdin, capture_output=True, text=True, env=e, timeout=30)

    def deploy_args(self):
        path = self.tmp / "deploy-args"
        return path.read_text().split("\n")[:-1] if path.exists() else None

    def test_upgrades_to_latest_through_deploy_attach(self):
        r = self.run_script("--yes")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.deploy_args(), [
            "--attach", "VscodeServerStack", "--stack-name", "OrcaOnVscodeStack",
            "--region", "ap-northeast-2", "--orca-version", "1.4.260", "--yes"])
        self.assertIn("v1.4.253", r.stdout)
        self.assertTrue(r.stdout.rstrip().endswith("FAKE DEPLOY DONE"), r.stdout)

    def test_explicit_version_strips_v_and_keeps_region_and_stack(self):
        r = self.run_script("--version", "v1.4.260", "--region", "us-west-2",
                            "--stack-name", "MyOrca", "--yes")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.deploy_args(), [
            "--attach", "VscodeServerStack", "--stack-name", "MyOrca",
            "--region", "us-west-2", "--orca-version", "1.4.260", "--yes"])

    def test_numeric_not_lexical_version_order(self):
        r = self.run_script("--yes", FAKE_CURRENT="1.4.99", FAKE_LATEST="1.4.100")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("1.4.100", self.deploy_args())

    def test_same_version_is_a_no_op(self):
        r = self.run_script("--yes", FAKE_LATEST="1.4.253")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(self.deploy_args())
        self.assertIn("get_pairing_url.sh", r.stdout)

    def test_refuses_downgrade(self):
        r = self.run_script("--version", "1.4.200", "--yes", FAKE_TAGS="1.4.200")
        self.assertEqual(r.returncode, 1)
        self.assertIsNone(self.deploy_args())
        self.assertIn("낮습니다", r.stderr)

    def test_check_only_reports_without_deploying(self):
        r = self.run_script("--check")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(self.deploy_args())
        self.assertIn("v1.4.253 → v1.4.260", r.stdout)

    def test_unknown_explicit_version_stops_before_deploy(self):
        r = self.run_script("--version", "1.4.999", "--yes")
        self.assertEqual(r.returncode, 1)
        self.assertIsNone(self.deploy_args())
        self.assertIn("v1.4.999", r.stderr)

    def test_confirmation_declined_or_no_tty_does_not_deploy(self):
        for answer in ("n\n", ""):
            r = self.run_script(stdin=answer)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIsNone(self.deploy_args(), answer)
            self.assertIn("취소", r.stdout)

    def test_confirmation_yes_deploys(self):
        r = self.run_script(stdin="y\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("1.4.260", self.deploy_args())

    def test_refuses_non_attach_stack(self):
        r = self.run_script("--yes", FAKE_HOST="None")
        self.assertEqual(r.returncode, 1)
        self.assertIsNone(self.deploy_args())
        self.assertIn("README", r.stderr)

    def test_refuses_stack_without_orca_version(self):
        r = self.run_script("--yes", FAKE_CURRENT="None", FAKE_HOST="None")
        self.assertEqual(r.returncode, 1)
        self.assertIsNone(self.deploy_args())
        self.assertIn("OrcaVersion", r.stderr)

    def test_missing_stack(self):
        r = self.run_script("--yes", FAKE_STACK="")
        self.assertEqual(r.returncode, 1)
        self.assertIsNone(self.deploy_args())
        self.assertIn("찾지 못했습니다", r.stderr)

    def test_latest_lookup_failure_and_bad_version(self):
        r = self.run_script("--yes", FAKE_LATEST="")
        self.assertEqual(r.returncode, 1)
        self.assertIn("--version", r.stderr)
        # The format check alone stops these: the tag exists, or the latest path skips the tag check.
        for args, env in ((("--version", "1.4.x"), {"FAKE_TAGS": "1.4.x"}),
                          ((), {"FAKE_LATEST": "1.5.0-beta"})):
            r = self.run_script(*args, "--yes", **env)
            self.assertEqual(r.returncode, 1, args)
            self.assertIsNone(self.deploy_args(), args)
            self.assertIn("버전 형식", r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
