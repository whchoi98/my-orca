#!/usr/bin/env python3
"""First-run password setup for the Orca CloudFront password gate.

CloudFront Functions can only read their key value store, so this small service on the
Orca server writes it once: POST /__gate/setup with the one-time setup code (embedded in
the pairing link that get_pairing_url.sh prints), the password and its confirmation.
On success the setup code file is deleted; after that, or once any password exists,
every request is refused. It is reached only through the ALB rule that also checks
X-Custom-Secret, and the CloudFront Function forwards /__gate/setup only while no
password is configured.

Passwords arrive as base64(utf-8) headers (fetch() header values must be Latin-1) and
are stored only as sha256(salt + ":" + base64(utf-8(password))), the form the gate
function checks.
"""
import base64
import binascii
import hashlib
import hmac
import json
import os
import secrets
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KVS_ARN = os.environ.get("GATE_KVS_ARN", "")
CODE_FILE = os.environ.get("GATE_SETUP_CODE_FILE", "/etc/orca/gate-setup-code")
PORT = int(os.environ.get("GATE_SETUP_PORT", "6769"))
AWS_CLI = os.environ.get("GATE_AWS_CLI", "aws")
MIN_LENGTH = 8
MAX_FAILURES = 20

_lock = threading.Lock()
_failures = 0


class SetupError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def _kvs(*args):
    # The key value store data API needs SigV4A, which the AWS CLI v2 bundles (boto3 does not).
    return subprocess.run(
        [AWS_CLI, "cloudfront-keyvaluestore", *args, "--output", "json"],
        capture_output=True, text=True, timeout=60,
    )


def is_configured():
    proc = _kvs("get-key", "--kvs-arn", KVS_ARN, "--key", "auth-hash")
    if proc.returncode == 0:
        return True
    if "ResourceNotFoundException" in proc.stderr:
        return False
    raise SetupError(502, "key value store unavailable")


def write_password(wire):
    describe = _kvs("describe-key-value-store", "--kvs-arn", KVS_ARN)
    if describe.returncode != 0:
        raise SetupError(502, "key value store unavailable")
    salt = secrets.token_hex(16)
    request = {
        "KvsARN": KVS_ARN,
        "IfMatch": json.loads(describe.stdout)["ETag"],
        "Puts": [
            {"Key": "auth-salt", "Value": salt},
            {"Key": "auth-hash", "Value": hashlib.sha256(f"{salt}:{wire}".encode()).hexdigest()},
            {"Key": "auth-signkey", "Value": secrets.token_hex(32)},
        ],
    }
    fd, path = tempfile.mkstemp(prefix="orca-gate-", suffix=".json")  # mode 0600
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(request, handle)
        proc = _kvs("update-keys", "--cli-input-json", f"file://{path}")
    finally:
        os.unlink(path)
    if proc.returncode != 0:
        raise SetupError(502, "could not write the key value store")


def decode_password(value):
    try:
        return base64.b64decode(value.encode("ascii"), validate=True).decode("utf-8")
    except (binascii.Error, UnicodeError, ValueError):
        raise SetupError(400, "password must be base64(utf-8)")


def handle_setup(headers):
    global _failures
    with _lock:
        if _failures >= MAX_FAILURES:
            raise SetupError(423, "too many failed attempts; restart orca-gate-setup")
        try:
            with open(CODE_FILE) as handle:
                expected = handle.read().strip()
        except FileNotFoundError:
            raise SetupError(409, "setup already completed")
        supplied = headers.get("x-orca-setup-code", "")
        if not expected or not hmac.compare_digest(supplied.encode(), expected.encode()):
            _failures += 1
            raise SetupError(401, "invalid setup code")
        password = decode_password(headers.get("x-orca-password", ""))
        confirm = decode_password(headers.get("x-orca-password-confirm", ""))
        if len(password) < MIN_LENGTH:
            raise SetupError(400, f"password must be at least {MIN_LENGTH} characters")
        if not hmac.compare_digest(password.encode(), confirm.encode()):
            raise SetupError(400, "passwords do not match")
        if is_configured():
            raise SetupError(409, "a password is already set")
        write_password(base64.b64encode(password.encode("utf-8")).decode("ascii"))
        os.unlink(CODE_FILE)


class Handler(BaseHTTPRequestHandler):
    server_version = "orca-gate-setup"
    sys_version = ""

    def _reply(self, status, message=""):
        self.send_response(status)
        self.send_header("Cache-Control", "no-store")
        if status == 204:
            self.end_headers()
            return
        body = message.encode()
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/__gate/health":
            self._reply(200, "ok")
        elif path == "/__gate/setup":
            self._reply(405, "POST only")
        else:
            self._reply(404, "not found")

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/__gate/setup":
            self._reply(404, "not found")
            return
        try:
            handle_setup(self.headers)
            self._reply(204)
        except SetupError as error:
            self._reply(error.status, error.message)

    def log_message(self, fmt, *args):
        # Request line and status only; never headers (they carry the password).
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def main():
    if not KVS_ARN:
        sys.exit("GATE_KVS_ARN is not set")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
