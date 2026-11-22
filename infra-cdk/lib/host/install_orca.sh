#!/bin/bash
# Installs orca-serve (and the password gate's first-login setup service) on an existing server,
# e.g. ec2_vscode's VS Code EC2, without disturbing what already runs there: no system update,
# no reboot, no restart of other services. Sent by the OrcaHostInstall custom resource
# (handler.py) through SSM Run Command as root. Safe to re-run: orca-serve restarts only when
# its package, unit or environment changed.
#
# Environment (handler.py exports it ahead of this script):
#   ORCA_VERSION          orca-ide release, e.g. 1.4.253
#   ORCA_PAIRING_ADDRESS  wss://<CloudFront domain>, the address Orca embeds in pairing links
#   ORCA_REGION           AWS region of the stack
#   ORCA_USER             account orca-serve runs as (default ec2-user)
#   GATE_KVS_ARN          password gate KeyValueStore ARN; empty when the gate is off
#   GATE_BUNDLE_URL       s3:// URL of the lib/gate bundle; empty when the gate is off
# Prints nothing secret: the pairing link goes to journald, the setup code to a root-only file.
set -euo pipefail
exec 2>&1

: "${ORCA_VERSION:?}" "${ORCA_PAIRING_ADDRESS:?}" "${ORCA_REGION:?}"
ORCA_USER="${ORCA_USER:-ec2-user}"
GATE_KVS_ARN="${GATE_KVS_ARN:-}"
GATE_BUNDLE_URL="${GATE_BUNDLE_URL:-}"
ORCA_PORT=6768
GATE_PORT=6769
# read_pairing.sh and get_pairing_url.sh wait for $STATE/done, as on OrcaStack's own instance.
STATE=/var/lib/orca-bootstrap
AWS_CLI=/usr/local/bin/aws   # lib/gate/install.sh and its service use this path

log() { echo "[orca-install] $*"; }
die() { log "ERROR: $*"; exit 1; }

getent passwd "$ORCA_USER" >/dev/null || die "user $ORCA_USER does not exist"
ORCA_HOME=$(getent passwd "$ORCA_USER" | cut -d: -f6)
ORCA_UID=$(id -u "$ORCA_USER")
if [ -n "$GATE_KVS_ARN" ]; then
    [ -n "$GATE_BUNDLE_URL" ] || die "GATE_BUNDLE_URL is required with GATE_KVS_ARN"
    [ -x "$AWS_CLI" ] || die "$AWS_CLI (AWS CLI v2) is required for the password gate"
fi
case "$(uname -m)" in
    aarch64) RPM_ARCH=aarch64 ;;
    x86_64) RPM_ARCH=x86_64 ;;
    *) die "unsupported architecture $(uname -m)" ;;
esac

# A shared server may already use these ports; never take one over.
port_taken() {  # <port> <unit that may legitimately own it>
    ss -Hltn "sport = :$1" | grep -q . && ! systemctl is-active --quiet "$2"
}
port_taken "$ORCA_PORT" orca-serve && die "port $ORCA_PORT is in use by another program: $(ss -Hltnp "sport = :$ORCA_PORT" | head -n 1)"
if [ -n "$GATE_KVS_ARN" ] && port_taken "$GATE_PORT" orca-gate-setup; then
    die "port $GATE_PORT is in use by another program: $(ss -Hltnp "sport = :$GATE_PORT" | head -n 1)"
fi

install -d -m 755 "$STATE" /etc/orca
rm -f "$STATE/done"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CHANGED=false

# Runtime deps from the orca-ide RPM. Already installed packages are left as they are (no
# upgrade). xdotool and xclip are not in the AL2023 repositories; only desktop control (orca
# computer) and file clipboard copy use them, so the RPM is installed with --nodeps.
# dbus-tools provides /usr/bin/dbus-send, which the RPM requires from 1.4.269 on.
log "runtime packages"
dnf install -y -q gtk3 libnotify nss libXScrnSaver libXtst xdg-utils at-spi2-core libuuid alsa-lib \
    python3-gobject xorg-x11-server-Xvfb dbus-tools

if [ "$(rpm -q --qf '%{VERSION}' orca-ide 2>/dev/null || true)" != "$ORCA_VERSION" ]; then
    RPM_NAME="orca-ide-${ORCA_VERSION}.${RPM_ARCH}.rpm"
    log "$RPM_NAME"
    # Release metadata: the asset's API URL and sha256. The API also serves the file when
    # github.com itself answers 5xx (seen on 2026-11-08 while api.github.com was fine).
    ASSET=$(curl -fsSL --retry 3 "https://api.github.com/repos/stablyai/orca/releases/tags/v${ORCA_VERSION}" \
        | python3 -c 'import json, sys
for a in json.load(sys.stdin).get("assets", []):
    if a.get("name") == sys.argv[1]:
        digest = a.get("digest") or ""
        print(a["url"], digest[len("sha256:"):] if digest.startswith("sha256:") else "-")' "$RPM_NAME" 2>/dev/null || true)
    read -r ASSET_API ASSET_SHA <<<"$ASSET"
    if ! curl -fsSL --retry 3 -o "$TMP/orca-ide.rpm" \
        "https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/${RPM_NAME}"; then
        [ -n "${ASSET_API:-}" ] || die "cannot download $RPM_NAME (github.com and api.github.com both failed)"
        log "github.com download failed; using the release asset API"
        curl -fsSL --retry 3 -H 'Accept: application/octet-stream' -o "$TMP/orca-ide.rpm" "$ASSET_API"
    fi
    if [ -n "${ASSET_SHA:-}" ] && [ "$ASSET_SHA" != - ]; then
        echo "$ASSET_SHA  $TMP/orca-ide.rpm" | sha256sum --check --quiet - \
            || die "$RPM_NAME does not match the release sha256"
        log "sha256 matches the release digest"
    else
        log "WARN: release digest unavailable (GitHub API); installing without a checksum check"
    fi
    # --oldpackage: when an upgrade fails after this step, CloudFormation rolls back by running
    # this script again with the previous version. Without the flag rpm refuses the older
    # package ("newer ... is already installed") and the stack ends UPDATE_ROLLBACK_FAILED.
    rpm -Uvh --nodeps --oldpackage --quiet "$TMP/orca-ide.rpm"
    CHANGED=true
fi
log "orca-ide --version: $(sudo -u "$ORCA_USER" -H /usr/bin/orca-ide --version)"

# A user manager lets Orca put each terminal in its own systemd user scope.
if [ ! -e "/var/lib/systemd/linger/$ORCA_USER" ]; then
    loginctl enable-linger "$ORCA_USER"
    touch "$STATE/linger-enabled-by-orca"   # uninstall_orca.sh turns it back off
fi

write_if_changed() {  # <target> <mode>, content on stdin
    cat > "$TMP/new"
    if ! cmp -s "$TMP/new" "$1"; then
        install -m "$2" "$TMP/new" "$1"
        CHANGED=true
    fi
}

write_if_changed /etc/orca/serve.env 644 <<ENVEOF
# orca-serve.service environment. Edit, then: sudo systemctl restart orca-serve
# Address embedded in pairing links (the CloudFront domain of the Orca stack).
ORCA_PAIRING_ADDRESS=$ORCA_PAIRING_ADDRESS
AWS_REGION=$ORCA_REGION
ORCA_TELEMETRY_DISABLED=1
# Agents started from Orca chat inherit this environment (it does not read ~/.bashrc).
# CLAUDE_CODE_USE_BEDROCK=1
ENVEOF

write_if_changed /etc/systemd/system/orca-serve.service 644 <<UNITEOF
[Unit]
Description=Orca headless server (orca-ide serve)
Wants=network-online.target user@${ORCA_UID}.service
After=network-online.target user@${ORCA_UID}.service
StartLimitIntervalSec=900
StartLimitBurst=5

[Service]
Type=simple
User=$ORCA_USER
WorkingDirectory=$ORCA_HOME
EnvironmentFile=/etc/orca/serve.env
Environment=PATH=$ORCA_HOME/.local/bin:$ORCA_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin
Environment=XDG_RUNTIME_DIR=/run/user/$ORCA_UID
Environment=ORCA_USER_DATA_PATH=$ORCA_HOME/.config/orca
# Not orca serve service install: that unit adds --no-pairing, and this release has no
# orca pair command, so the pairing link printed at start is the only way to pair.
# No --supervise either: supervised serve hides the pairing link when stdout is not a
# TTY (journald), so systemd Restart= takes over restarts.
ExecStart=/usr/bin/orca-ide serve --port $ORCA_PORT --bind 0.0.0.0 --pairing-address \${ORCA_PAIRING_ADDRESS}
Restart=on-failure
RestartSec=10
TimeoutStopSec=90
# The terminal daemon outlives orca serve restarts, as in the upstream service unit.
KillMode=process

[Install]
WantedBy=multi-user.target
UNITEOF

if [ -n "$GATE_KVS_ARN" ]; then
    # The stack attaches the S3 read policy to the host role moments before this runs, and IAM
    # takes a few seconds to apply it.
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        "$AWS_CLI" s3 cp --only-show-errors --region "$ORCA_REGION" "$GATE_BUNDLE_URL" "$TMP/gate.zip" && break
        [ "$attempt" = 10 ] && die "cannot download $GATE_BUNDLE_URL"
        sleep 6
    done
    rm -rf /opt/orca-gate-src && mkdir -p /opt/orca-gate-src
    unzip -oq "$TMP/gate.zip" -d /opt/orca-gate-src
    bash /opt/orca-gate-src/install.sh "$GATE_KVS_ARN" "$ORCA_REGION"
elif [ -f /etc/systemd/system/orca-gate-setup.service ]; then
    log "password gate is off: removing orca-gate-setup"
    systemctl disable --now --quiet orca-gate-setup.service || true
    rm -f /etc/systemd/system/orca-gate-setup.service /etc/orca/gate.env /etc/orca/gate-setup-code
    rm -rf /opt/orca-gate /opt/orca-gate-src
fi

systemctl daemon-reload
systemctl enable --quiet orca-serve.service
if "$CHANGED" || ! systemctl is-active --quiet orca-serve.service; then
    log "(re)starting orca-serve"
    systemctl restart orca-serve.service
fi
# The same paths the ALB health checks use.
healthy() {  # <url>
    for _ in $(seq 1 45); do
        curl -fsS -o /dev/null --max-time 3 "$1" && return 0
        sleep 2
    done
    return 1
}
if ! healthy "http://127.0.0.1:$ORCA_PORT/web-index.html"; then
    # Pairing lines carry credentials; leave them out of the SSM command output.
    journalctl -u orca-serve -n 30 -o cat --no-pager | grep -viE 'pair|token|code=' || true
    die "orca-serve does not answer on :$ORCA_PORT"
fi
if [ -n "$GATE_KVS_ARN" ] && ! healthy "http://127.0.0.1:$GATE_PORT/__gate/health"; then
    journalctl -u orca-gate-setup -n 30 -o cat --no-pager || true
    die "orca-gate-setup does not answer on :$GATE_PORT"
fi
touch "$STATE/done"
log "done: orca-ide $(rpm -q --qf '%{VERSION}' orca-ide), orca-serve and" \
    "$( [ -n "$GATE_KVS_ARN" ] && echo "the password gate setup service" || echo "no password gate") answering"
