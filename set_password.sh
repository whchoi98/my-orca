#!/bin/bash
# Orca 접속 암호 설정/변경 (CloudFront Function 암호 게이트)
#
# CloudFront KeyValueStore에 salt, 해시, 쿠키 서명 키만 저장합니다. 평문 암호는 어디에도
# 저장하지 않으며 명령줄 인자로도 넘기지 않습니다. 변경 내용은 수 초 안에 엣지에 반영됩니다.
#
# 사용법:
#   bash set_password.sh [--region <region>] [--stack-name <name>] [--keep-sessions] [--password-stdin]
#   bash set_password.sh --reset-ui [--yes]
#   bash set_password.sh --tf <dedicated|attach> [위와 같은 옵션]
#     --tf              deploy_orca_tf.sh(Terraform)로 배포한 서버. 값과 리전을 Terraform 출력에서 읽습니다
#     --keep-sessions   쿠키 서명 키를 유지해 이미 로그인한 브라우저를 로그아웃시키지 않음
#                       (기본: 암호를 바꾸면 서명 키도 새로 만들어 모든 세션을 끊음)
#     --password-stdin  암호를 표준 입력 첫 줄에서 읽음 (자동화용)
#     --reset-ui        암호를 지우고 "최초 로그인 시 설정" 상태로 되돌림 (암호 분실 시).
#                       서버에 새 1회용 설정 코드를 만들며, get_pairing_url.sh가 링크에 붙여 줍니다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_NAME_SET=false
[ -n "${STACK_NAME:-}" ] && STACK_NAME_SET=true
STACK_NAME="${STACK_NAME:-OrcaServerStack}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-2}}"
KEEP_SESSIONS=false
PASSWORD_STDIN=false
RESET_UI=false
ASSUME_YES=false
TF_MODE=""
MIN_LENGTH=8

while [ "$#" -gt 0 ]; do
    case "$1" in
        --region) REGION="$2"; shift 2 ;;
        --stack-name) STACK_NAME="$2"; STACK_NAME_SET=true; shift 2 ;;
        --tf) TF_MODE="${2:-}"; shift 2 ;;
        --keep-sessions) KEEP_SESSIONS=true; shift ;;
        --password-stdin) PASSWORD_STDIN=true; shift ;;
        --reset-ui) RESET_UI=true; shift ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        --help|-h) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "알 수 없는 인자: $1" >&2; exit 1 ;;
    esac
done

case "$TF_MODE" in
    ""|dedicated|attach) ;;
    *) echo "[ERROR] --tf 값은 dedicated 또는 attach 입니다." >&2; exit 1 ;;
esac

# 스택 이름을 정하지 않았고 OrcaServerStack이 없으면 deploy_orca.sh --attach의 기본 스택을 씁니다.
if [ -z "$TF_MODE" ] && ! "$STACK_NAME_SET" && ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1 \
    && aws cloudformation describe-stacks --stack-name OrcaOnVscodeStack --region "$REGION" >/dev/null 2>&1; then
    STACK_NAME=OrcaOnVscodeStack
fi

die() { echo "[ERROR] $*" >&2; exit 1; }

if [ -n "$TF_MODE" ]; then
    # Terraform 배포: 같은 값을 Terraform 출력에서 읽습니다.
    command -v terraform >/dev/null 2>&1 || die "terraform 명령어가 필요합니다."
    output() {
        local name
        case "$1" in
            PasswordGateStoreArn) name=password_gate_store_arn ;;
            InstanceId) name=instance_id ;;
            *) return 0 ;;
        esac
        terraform -chdir="$SCRIPT_DIR/infra-tf/$TF_MODE" output -raw "$name" 2>/dev/null || true
    }
    TF_REGION=$(terraform -chdir="$SCRIPT_DIR/infra-tf/$TF_MODE" output -raw region 2>/dev/null || true)
    [ -n "$TF_REGION" ] || die "infra-tf/$TF_MODE 에 배포된 Orca가 없습니다."
    REGION="$TF_REGION"
    WHERE="infra-tf/$TF_MODE ($REGION)"
    PAIRING_HINT="bash get_pairing_url.sh --tf $TF_MODE"
else
    output() {
        aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
            --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null || true
    }
    WHERE="$STACK_NAME ($REGION)"
    PAIRING_HINT="bash get_pairing_url.sh --region $REGION"
fi
KVS_ARN=$(output PasswordGateStoreArn)
[[ "$KVS_ARN" == arn:aws:cloudfront::* ]] || die "$WHERE 에 암호 게이트(PasswordGateStoreArn)가 없습니다."

# -------------------------------------------------------
# --reset-ui: 최초 로그인 설정 상태로 되돌리기
# -------------------------------------------------------
if "$RESET_UI"; then
    INSTANCE_ID=$(output InstanceId)
    [[ "$INSTANCE_ID" == i-* ]] || die "InstanceId를 찾지 못했습니다."
    if ! "$ASSUME_YES"; then
        echo "  접속 암호와 모든 로그인 세션을 지웁니다. 새 설정 링크로 암호를 정하기 전까지 Orca UI가 열리지 않습니다."
        read -r -p "  계속? (yes 입력): " CONFIRM
        [ "$CONFIRM" = "yes" ] || { echo "취소했습니다."; exit 0; }
    fi
    # 1) 서버에 새 1회용 설정 코드 (명령 출력에는 코드가 나오지 않음)
    CMD_ID=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript --comment "orca gate reset-ui" \
        --parameters 'commands=["set -e","(umask 077 && python3 -c \"import secrets; print(secrets.token_urlsafe(24))\" > /etc/orca/gate-setup-code)","systemctl restart orca-gate-setup","systemctl is-active orca-gate-setup"]' \
        --query Command.CommandId --output text)
    aws ssm wait command-executed --region "$REGION" --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
        || die "서버에서 설정 코드를 만들지 못했습니다 (SSM $CMD_ID)."
    # 2) 키 삭제 → CloudFront Function이 설정 화면 모드로 전환
    KEYS=$(aws cloudfront-keyvaluestore list-keys --kvs-arn "$KVS_ARN" --query 'Items[].Key' --output json)
    if [ "$KEYS" != "[]" ]; then
        ETAG=$(aws cloudfront-keyvaluestore describe-key-value-store --kvs-arn "$KVS_ARN" --query ETag --output text)
        DELETES=$(python3 -c 'import json,sys; print(json.dumps([{"Key": k} for k in json.loads(sys.argv[1])]))' "$KEYS")
        aws cloudfront-keyvaluestore update-keys --kvs-arn "$KVS_ARN" --if-match "$ETAG" --deletes "$DELETES" >/dev/null
    fi
    echo "  최초 로그인 설정 상태로 되돌렸습니다. 새 설정 링크: $PAIRING_HINT"
    exit 0
fi

if "$PASSWORD_STDIN"; then
    IFS= read -r ORCA_WEB_PASSWORD || true
else
    read -r -s -p "  Orca 접속 암호 (${MIN_LENGTH}자 이상, 12자 이상 권장): " ORCA_WEB_PASSWORD; echo
    read -r -s -p "  암호 확인: " CONFIRM; echo
    [ "$ORCA_WEB_PASSWORD" = "$CONFIRM" ] || die "두 암호가 다릅니다."
    unset CONFIRM
fi
[ "${#ORCA_WEB_PASSWORD}" -ge "$MIN_LENGTH" ] || die "암호는 ${MIN_LENGTH}자 이상이어야 합니다."
export ORCA_WEB_PASSWORD

SIGNKEY=""
if "$KEEP_SESSIONS"; then
    SIGNKEY=$(aws cloudfront-keyvaluestore get-key --kvs-arn "$KVS_ARN" --key auth-signkey \
        --query Value --output text 2>/dev/null || true)
fi

ETAG=$(aws cloudfront-keyvaluestore describe-key-value-store --kvs-arn "$KVS_ARN" --query ETag --output text)
REQUEST_FILE=$(umask 077 && mktemp)
trap 'rm -f "$REQUEST_FILE"' EXIT

# 해시 대상은 base64(utf8(암호))입니다: 로그인 페이지가 헤더로 보내는 형태와 같습니다.
KVS_ARN="$KVS_ARN" ETAG="$ETAG" SIGNKEY="$SIGNKEY" python3 - "$REQUEST_FILE" <<'PY'
import base64, hashlib, json, os, secrets, sys
salt = secrets.token_hex(16)
wire = base64.b64encode(os.environ["ORCA_WEB_PASSWORD"].encode("utf-8")).decode("ascii")
puts = [
    {"Key": "auth-salt", "Value": salt},
    {"Key": "auth-hash", "Value": hashlib.sha256(f"{salt}:{wire}".encode()).hexdigest()},
    {"Key": "auth-signkey", "Value": os.environ["SIGNKEY"] or secrets.token_hex(32)},
]
with open(sys.argv[1], "w") as f:
    json.dump({"KvsARN": os.environ["KVS_ARN"], "IfMatch": os.environ["ETAG"], "Puts": puts}, f)
PY
unset ORCA_WEB_PASSWORD

aws cloudfront-keyvaluestore update-keys --cli-input-json "file://$REQUEST_FILE" \
    --query '{Items:ItemCount,Bytes:TotalSizeInBytes}' --output text >/dev/null
echo "  암호를 설정했습니다 ($( "$KEEP_SESSIONS" && echo '기존 세션 유지' || echo '기존 로그인 세션 모두 만료' ))."
echo "  CloudFront 엣지 반영까지 수 초~1분 걸릴 수 있습니다."
