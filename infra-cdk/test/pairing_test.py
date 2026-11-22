"""Tests for lib/pairing (PairingInfo custom resource). Run: python3 -I test/pairing_test.py

read_pairing.sh runs against fake systemctl/journalctl and a fake root; handler.py runs
against a fake SSM client (boto3 is stubbed, so the test needs no AWS SDK).
"""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PAIRING = HERE.parent / "lib" / "pairing"
SCRIPT = PAIRING / "read_pairing.sh"

WEB = "https://dexample.cloudfront.net/web-index.html#pairing=orca%3A%2F%2Fpair%3Fcode%3DeyJ2Ijoy"
PAIR = "orca://pair?code=eyJ2IjoyLCJlbmRwb2ludCI6IndzczovL2RleGFtcGxlIn0"
CODE = "Zk3-setup_code-xyz"
CURRENT = "inv-current"

# systemctl show -p <Prop> --value <unit>, answered from $FAKE_SYSTEMD (JSON {unit: {Prop: value}}).
FAKE_SYSTEMCTL = textwrap.dedent(r'''
    #!/usr/bin/env python3
    import json, os, sys
    args = sys.argv[1:]
    units = json.load(open(os.environ["FAKE_SYSTEMD"]))
    prop, unit = args[args.index("-p") + 1], args[-1]
    print(units.get(unit, {}).get(prop, ""))
''').lstrip()

# Lines of the running invocation only when asked for it by ID; anything else gets older lines.
FAKE_JOURNALCTL = textwrap.dedent(r'''
    #!/usr/bin/env python3
    import os, sys
    want = "_SYSTEMD_INVOCATION_ID=" + os.environ["FAKE_INVOCATION"]
    name = "current.log" if want in sys.argv[1:] else "other.log"
    path = os.path.join(os.environ["FAKE_JOURNAL_DIR"], name)
    if os.path.exists(path):
        sys.stdout.write(open(path).read())
''').lstrip()


def readiness(web=WEB, pair=PAIR):
    lines = ["Orca server ready", "Bound endpoint: ws://0.0.0.0:6768"]
    if web:
        lines.append(f"Web client URL: {web}")
    lines.append(f"Pairing URL: {pair}")
    return "\n".join(lines) + "\n"


class ReadPairingScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.root, self.bin, self.journal = base / "root", base / "bin", base / "journal"
        for d in (self.root / "var/lib/orca-bootstrap", self.root / "proc", self.root / "etc/orca", self.bin, self.journal):
            d.mkdir(parents=True)
        for name, body in (("systemctl", FAKE_SYSTEMCTL), ("journalctl", FAKE_JOURNALCTL)):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.systemd = base / "systemd.json"
        self.set_units(bootstrap="inactive", serve="active", started_s=100)
        self.uptime(1000)

    def tearDown(self):
        self.tmp.cleanup()

    def set_units(self, bootstrap, serve, started_s, invocation=CURRENT):
        self.systemd.write_text(json.dumps({
            "orca-bootstrap": {"ActiveState": bootstrap},
            "orca-serve": {"ActiveState": serve, "InvocationID": invocation,
                           "ActiveEnterTimestampMonotonic": str(started_s * 1_000_000)},
        }))

    def uptime(self, seconds):
        (self.root / "proc/uptime").write_text(f"{seconds}.42 1234.00\n")

    def done(self):
        (self.root / "var/lib/orca-bootstrap/done").touch()

    def log(self, current=None, other=None):
        for name, text in (("current.log", current), ("other.log", other)):
            if text is not None:
                (self.journal / name).write_text(text)

    def run_script(self):
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "ORCA_PAIRING_TEST_ROOT": str(self.root),
            "FAKE_SYSTEMD": str(self.systemd),
            "FAKE_JOURNAL_DIR": str(self.journal),
            "FAKE_INVOCATION": CURRENT,
        }
        # sh, as SSM's AWS-RunShellScript would on a system whose /bin/sh is not bash.
        proc = subprocess.run(["bash", "--posix", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = proc.stdout.strip().splitlines()
        self.assertEqual(len(lines), 1, proc.stdout)
        return json.loads(lines[0])

    def test_waits_while_setup_runs(self):
        self.assertEqual(self.run_script(), {"state": "wait", "reason": "server setup"})

    def test_setup_that_gave_up_is_unavailable(self):
        self.set_units(bootstrap="failed", serve="inactive", started_s=0)
        out = self.run_script()
        self.assertEqual(out["state"], "unavailable")
        self.assertIn("user-data.log", out["reason"])

    def test_waits_for_orca_serve(self):
        self.done()
        self.set_units(bootstrap="inactive", serve="activating", started_s=0)
        self.assertEqual(self.run_script(), {"state": "wait", "reason": "orca-serve start"})

    def test_ready_with_setup_code(self):
        self.done()
        self.log(current=readiness())
        (self.root / "etc/orca/gate-setup-code").write_text(CODE)
        self.assertEqual(self.run_script(),
                         {"state": "ready", "webClientUrl": WEB, "pairingCode": PAIR, "setupCode": CODE})

    def test_ready_without_setup_code(self):
        self.done()
        self.log(current=readiness())
        self.assertEqual(self.run_script(), {"state": "ready", "webClientUrl": WEB, "pairingCode": PAIR})

    def test_reports_latest_start_of_running_process(self):
        self.done()
        self.log(current=readiness(web=WEB + "old", pair=PAIR + "old") + readiness())
        out = self.run_script()
        self.assertEqual((out["webClientUrl"], out["pairingCode"]), (WEB, PAIR))

    def test_ignores_lines_from_an_earlier_start(self):
        # The old offer may already be used; it must not be reported for the running process.
        self.done()
        self.log(current="Orca server ready\n", other=readiness())
        self.uptime(130)  # orca-serve became active 30 s ago
        self.assertEqual(self.run_script(), {"state": "wait", "reason": "orca-serve pairing link"})
        self.uptime(1000)
        out = self.run_script()
        self.assertEqual(out["state"], "unavailable")
        self.assertIn("journald", out["reason"])

    def test_pairing_unavailable_reason_is_passed_on(self):
        self.done()
        self.log(current="Pairing unavailable: websocket_unavailable\n")
        out = self.run_script()
        self.assertEqual(out["state"], "unavailable")
        self.assertIn("websocket_unavailable", out["reason"])

    def test_redacted_link_is_not_reported_as_a_code(self):
        self.done()
        self.log(current="Pairing URL: hidden because this supervised server is not writing to a terminal.\n")
        out = self.run_script()
        self.assertEqual(out["state"], "unavailable")
        self.assertNotIn("pairingCode", out)

    def test_values_are_json_escaped(self):
        self.done()
        odd_web = 'https://d.example/web-index.html#pairing=a"b\\c d'
        self.log(current=readiness(web=odd_web))
        self.assertEqual(self.run_script()["webClientUrl"], odd_web)


def load_handler():
    calls = []
    sys.modules["boto3"] = types.SimpleNamespace(client=lambda name: calls.append(name))
    spec = importlib.util.spec_from_file_location("pairing_handler", PAIRING / "handler.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class InvocationDoesNotExist(Exception):
    pass


class FakeSsm:
    def __init__(self, online=True, statuses=("Success",), stdout=""):
        self.online, self.statuses, self.stdout = online, list(statuses), stdout
        self.sent = []
        self.exceptions = types.SimpleNamespace(InvocationDoesNotExist=InvocationDoesNotExist)

    def describe_instance_information(self, Filters):
        self.filters = Filters
        status = "Online" if self.online else "ConnectionLost"
        return {"InstanceInformationList": [{"InstanceId": "i-0abc", "PingStatus": status}]}

    def send_command(self, **kwargs):
        self.sent.append(kwargs)
        return {"Command": {"CommandId": "cmd-1"}}

    def get_command_invocation(self, CommandId, InstanceId):
        status = self.statuses.pop(0) if len(self.statuses) > 1 else self.statuses[0]
        if status == "missing":
            raise InvocationDoesNotExist()
        return {"Status": status, "StandardOutputContent": self.stdout}


class FakeClock:
    def __init__(self, now=1_000_000.0):
        self.now = now

    def time(self):
        return self.now

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class HandlerTest(unittest.TestCase):
    def setUp(self):
        self.h = load_handler()
        self.clock = FakeClock()
        self.h.time = self.clock

    def event(self, request="Create", wait_until=None, gate=True):
        e = {"RequestType": request,
             "ResourceProperties": {"InstanceId": "i-0abc", "GateEnabled": "true" if gate else "false"}}
        if wait_until is not None:
            e["Data"] = {"WaitUntil": str(int(wait_until))}
        return e

    def ready(self, **values):
        return json.dumps({"state": "ready", "webClientUrl": WEB, "pairingCode": PAIR, **values}) + "\n"

    def complete(self, ssm, **kw):
        self.h._ssm = ssm
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            result = self.h.is_complete(self.event(wait_until=self.clock.now + 600, **kw), None)
        return result, printed.getvalue()

    def test_on_event_sets_a_give_up_time(self):
        result = self.h.on_event(self.event(), None)
        self.assertEqual(result["PhysicalResourceId"], "orca-pairing-info")
        self.assertEqual(int(result["Data"]["WaitUntil"]), int(self.clock.now) + self.h.GIVE_UP_SECONDS)
        self.assertEqual(self.h.on_event(self.event("Delete"), None), {})
        self.assertEqual(self.h.is_complete(self.event("Delete"), None), {"IsComplete": True})

    def test_ready_with_setup_code(self):
        ssm = FakeSsm(stdout="noise\n" + self.ready(setupCode=CODE))
        result, printed = self.complete(ssm)
        self.assertEqual(result, {"IsComplete": True, "Data": {
            "PairingWebLink": f"{WEB}&gate-setup={CODE}", "PairingCode": PAIR, "GateSetupCode": CODE}})
        # The script is sent as written, to this instance only.
        self.assertEqual(ssm.sent[0]["InstanceIds"], ["i-0abc"])
        self.assertEqual(ssm.sent[0]["DocumentName"], "AWS-RunShellScript")
        self.assertEqual(ssm.sent[0]["Parameters"], {"commands": [SCRIPT.read_text()]})
        self.assertEqual(ssm.filters, [{"Key": "InstanceIds", "Values": ["i-0abc"]}])
        # Credentials never reach the logs.
        for secret in (PAIR, CODE, "eyJ2"):
            self.assertNotIn(secret, printed)

    def test_ready_without_setup_code(self):
        data = self.complete(FakeSsm(stdout=self.ready()))[0]["Data"]
        self.assertEqual(data["PairingWebLink"], WEB)
        self.assertEqual(data["GateSetupCode"], "none (access password already set)")
        data = self.complete(FakeSsm(stdout=self.ready()), gate=False)[0]["Data"]
        self.assertEqual(data["GateSetupCode"], "none (password gate disabled)")

    def test_attribute_values_are_ascii(self):
        # CloudFormation turns non-ASCII custom resource attributes into "?".
        states = [{"state": "ready", "webClientUrl": WEB, "pairingCode": PAIR, "setupCode": CODE},
                  {"state": "ready", "pairingCode": PAIR},
                  {"state": "unavailable", "reason": "pairing link not in journald"}]
        for state in states:
            for gate in (True, False):
                for value in self.h.attributes(state, gate).values():
                    self.assertTrue(value.isascii(), value)

    def test_waits_until_give_up_then_reports_unavailable(self):
        offline = FakeSsm(online=False)
        self.assertEqual(self.complete(offline)[0], {"IsComplete": False})
        self.assertEqual(offline.sent, [])
        self.h._ssm = offline
        result = self.h.is_complete(self.event(wait_until=self.clock.now - 1), None)
        self.assertTrue(result["IsComplete"])
        self.assertEqual(set(result["Data"]), {"PairingWebLink", "PairingCode", "GateSetupCode"})
        for value in result["Data"].values():
            self.assertIn("SSM agent", value)
            self.assertIn("get_pairing_url.sh", value)

    def test_script_wait_and_unavailable(self):
        wait = json.dumps({"state": "wait", "reason": "server setup"})
        self.assertEqual(self.complete(FakeSsm(stdout=wait))[0], {"IsComplete": False})
        gone = json.dumps({"state": "unavailable", "reason": "pairing link not in journald"})
        result = self.complete(FakeSsm(stdout=gone))[0]
        self.assertTrue(result["IsComplete"])
        self.assertIn("journald", result["Data"]["PairingCode"])

    def test_invocation_not_registered_yet(self):
        result = self.complete(FakeSsm(statuses=("missing", "InProgress", "Success"), stdout=self.ready()))[0]
        self.assertEqual(result["Data"]["PairingCode"], PAIR)

    def test_command_failure_or_slowness_is_a_retry(self):
        for ssm in (FakeSsm(statuses=("Failed",)), FakeSsm(statuses=("InProgress",)),
                    FakeSsm(stdout="not json"), FakeSsm(stdout="")):
            self.assertEqual(self.complete(ssm)[0], {"IsComplete": False})

    def test_slow_command_stops_waiting_within_the_lambda_timeout(self):
        self.h._ssm = FakeSsm(statuses=("InProgress",))
        start = self.clock.now
        self.h.read_state("i-0abc")
        self.assertLessEqual(self.clock.now - start, self.h.COMMAND_WAIT_SECONDS + self.h.POLL_SECONDS)


if __name__ == "__main__":
    unittest.main(verbosity=2)
