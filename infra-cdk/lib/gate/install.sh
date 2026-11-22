#!/bin/bash
# Installs the Orca password gate first-run setup service (orca-gate-setup.service, :6769).
# Run as root from the unpacked CDK asset; safe to re-run.
#   install.sh <password-gate-kvs-arn> <aws-region>
set -euo pipefail

KVS_ARN="$1"
REGION="$2"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWS_CLI=/usr/local/bin/aws

install -d -m 755 /opt/orca-gate /etc/orca
install -m 755 "$SRC_DIR/setup_service.py" /opt/orca-gate/setup_service.py

cat > /etc/orca/gate.env <<ENVEOF
GATE_KVS_ARN=$KVS_ARN
AWS_REGION=$REGION
GATE_AWS_CLI=$AWS_CLI
ENVEOF

# One-time setup code, only while no password exists. get_pairing_url.sh appends it to the
# pairing link; the service deletes it once the first password is set.
if ! "$AWS_CLI" cloudfront-keyvaluestore get-key --kvs-arn "$KVS_ARN" --key auth-hash >/dev/null 2>&1 \
    && [ ! -s /etc/orca/gate-setup-code ]; then
    (umask 077 && python3 -c 'import secrets; print(secrets.token_urlsafe(24))' > /etc/orca/gate-setup-code)
fi

cat > /etc/systemd/system/orca-gate-setup.service <<'UNITEOF'
[Unit]
Description=Orca password gate first-run setup (POST /__gate/setup)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/orca/gate.env
# The AWS CLI keeps its cache under HOME; give it the private /tmp.
Environment=HOME=/tmp
ExecStart=/usr/bin/python3 /opt/orca-gate/setup_service.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/etc/orca

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable orca-gate-setup.service
systemctl restart orca-gate-setup.service
echo "orca-gate-setup installed (setup code: $( [ -s /etc/orca/gate-setup-code ] && echo pending || echo none ))"
