"""Tests for lib/gate/setup_service.py against a fake `aws` CLI. Run: python3 -I test/setup_service_test.py"""
import base64
import hashlib
import http.client
import importlib.util
import json
import os
import stat
import sys
import tempfile
import textwrap
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
SERVICE = HERE.parent / "lib" / "gate" / "setup_service.py"

FAKE_AWS = textwrap.dedent(r'''
    #!/usr/bin/env python3
    # Minimal stand-in for `aws cloudfront-keyvaluestore` keeping state in $FAKE_KVS_STATE.
    import json, os, stat, sys
    state_path = os.environ["FAKE_KVS_STATE"]
    state = json.load(open(state_path))
    args = sys.argv[1:]
    if state.get("fail"):
        sys.stderr.write("An error occurred (InternalServerException)\n"); sys.exit(255)
    def arg(name):
        return args[args.index(name) + 1]
    cmd = args[1]
    if cmd == "get-key":
        key = arg("--key")
        if key in state["keys"]:
            print(json.dumps({"Key": key, "Value": state["keys"][key]})); sys.exit(0)
        sys.stderr.write("An error occurred (ResourceNotFoundException) when calling GetKey\n"); sys.exit(254)
    if cmd == "describe-key-value-store":
        print(json.dumps({"ETag": state["etag"]})); sys.exit(0)
    if cmd == "update-keys":
        path = arg("--cli-input-json")[len("file://"):]
        state["request_mode"] = oct(stat.S_IMODE(os.stat(path).st_mode))
        request = json.load(open(path))
        if request["IfMatch"] != state["etag"]:
            sys.stderr.write("An error occurred (ConflictException)\n"); sys.exit(254)
        for put in request["Puts"]:
            state["keys"][put["Key"]] = put["Value"]
        state["etag"] += "x"
        json.dump(state, open(state_path, "w")); print("{}"); sys.exit(0)
    sys.exit(2)
''').lstrip()


def b64(text):
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


class SetupServiceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        cls.fake_aws = root / "aws"
        cls.fake_aws.write_text(FAKE_AWS)
        cls.fake_aws.chmod(0o755)
        cls.state_path = root / "state.json"
        cls.code_file = root / "gate-setup-code"
        os.environ.update({
            "GATE_KVS_ARN": "arn:aws:cloudfront::123456789012:key-value-store/test",
            "GATE_SETUP_CODE_FILE": str(cls.code_file),
            "GATE_AWS_CLI": str(cls.fake_aws),
            "FAKE_KVS_STATE": str(cls.state_path),
        })
        spec = importlib.util.spec_from_file_location("setup_service", SERVICE)
        cls.svc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.svc)
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), cls.svc.Handler)
        cls.server.RequestHandlerClass.log_message = lambda *a: None
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.tmp.cleanup()

    def setUp(self):
        self.svc._failures = 0
        self.state_path.write_text(json.dumps({"keys": {}, "etag": "E1"}))
        self.code_file.write_text("the-setup-code\n")

    def state(self):
        return json.loads(self.state_path.read_text())

    def request(self, method, path, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        conn.request(method, path, headers=headers or {})
        response = conn.getresponse()
        body = response.read().decode()
        conn.close()
        return response.status, body

    def setup(self, code="the-setup-code", password="한글 암호 password", confirm=None):
        headers = {"x-orca-setup-code": code, "x-orca-password": b64(password),
                   "x-orca-password-confirm": b64(password if confirm is None else confirm)}
        return self.request("POST", "/__gate/setup", headers)

    def test_success_writes_salted_hash_and_consumes_code(self):
        status, _ = self.setup()
        self.assertEqual(status, 204)
        keys = self.state()["keys"]
        wire = b64("한글 암호 password")
        self.assertEqual(keys["auth-hash"], hashlib.sha256(f"{keys['auth-salt']}:{wire}".encode()).hexdigest())
        self.assertRegex(keys["auth-signkey"], r"^[0-9a-f]{64}$")
        self.assertEqual(self.state()["request_mode"], "0o600")
        self.assertFalse(self.code_file.exists(), "setup code is one-time")
        self.assertEqual(self.setup()[0], 409, "second setup is refused")

    def test_wrong_code_is_refused_and_counted(self):
        self.assertEqual(self.setup(code="guess")[0], 401)
        self.assertEqual(self.setup(code="")[0], 401)
        self.assertEqual(self.svc._failures, 2)
        self.assertEqual(self.state()["keys"], {})

    def test_lockout_after_too_many_wrong_codes(self):
        for _ in range(self.svc.MAX_FAILURES):
            self.setup(code="guess")
        self.assertEqual(self.setup()[0], 423, "locked even with the right code")
        self.assertEqual(self.state()["keys"], {})

    def test_password_validation(self):
        self.assertEqual(self.setup(password="short")[0], 400)
        self.assertEqual(self.setup(confirm="different password")[0], 400)
        status, _ = self.request("POST", "/__gate/setup", {"x-orca-setup-code": "the-setup-code",
                                 "x-orca-password": "not base64!!", "x-orca-password-confirm": "x"})
        self.assertEqual(status, 400)
        self.assertEqual(self.state()["keys"], {})
        self.assertTrue(self.code_file.exists(), "a rejected attempt keeps the code")

    def test_existing_password_is_never_overwritten(self):
        self.state_path.write_text(json.dumps({"keys": {"auth-hash": "set-by-cli"}, "etag": "E1"}))
        self.assertEqual(self.setup()[0], 409)
        self.assertEqual(self.state()["keys"], {"auth-hash": "set-by-cli"})

    def test_store_failure_keeps_code(self):
        self.state_path.write_text(json.dumps({"keys": {}, "etag": "E1", "fail": True}))
        self.assertEqual(self.setup()[0], 502)
        self.assertTrue(self.code_file.exists())

    def test_routes(self):
        self.assertEqual(self.request("GET", "/__gate/health")[0], 200)
        self.assertEqual(self.request("GET", "/__gate/setup")[0], 405)
        self.assertEqual(self.request("POST", "/elsewhere")[0], 404)


if __name__ == "__main__":
    unittest.main()
