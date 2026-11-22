#!/bin/bash
# Orca 웹 클라이언트 페어링 링크 조회
#
# orca-serve.service가 시작할 때 journald에 출력한 "Web client URL"을 SSM Session Manager
# 대화형 세션으로 읽어 옵니다. send-command와 달리 출력이 SSM 명령 기록에 남지 않습니다.
# 이 링크는 서버 접근 권한 그 자체이고 headless serve 링크는 만료되지 않으니, 비밀번호처럼 다루세요.
#
# 사용법:
#   bash get_pairing_url.sh [--region <region>] [--stack-name <name>] [--restart]
#   bash get_pairing_url.sh --tf <dedicated|attach> [--restart]
#     --tf       deploy_orca_tf.sh(Terraform)로 배포한 서버. 인스턴스와 리전을 Terraform 출력에서 읽습니다
#     --restart  journald에서 링크가 사라졌을 때 orca-serve를 재시작해 다시 출력시킵니다
#                (터미널 데몬과 에이전트는 KillMode=process로 유지됩니다)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STACK_NAME_SET=false
[ -n "${STACK_NAME:-}" ] && STACK_NAME_SET=true
STACK_NAME="${STACK_NAME:-OrcaServerStack}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-2}}"
RESTART=false
TF_MODE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --region) REGION="$2"; shift 2 ;;
        --stack-name) STACK_NAME="$2"; STACK_NAME_SET=true; shift 2 ;;
        --tf) TF_MODE="${2:-}"; shift 2 ;;
        --restart) RESTART=true; shift ;;
        --help|-h) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "알 수 없는 인자: $1" >&2; exit 1 ;;
    esac
done

# --tf: Terraform 배포의 출력에서 값을 읽습니다.
tf_output() { terraform -chdir="$SCRIPT_DIR/infra-tf/$TF_MODE" output -raw "$1" 2>/dev/null || true; }
case "$TF_MODE" in
    "") ;;
    dedicated|attach) command -v terraform >/dev/null 2>&1 || { echo "[ERROR] terraform 명령어가 필요합니다." >&2; exit 1; } ;;
    *) echo "[ERROR] --tf 값은 dedicated 또는 attach 입니다." >&2; exit 1 ;;
esac

# 스택 이름을 정하지 않았고 OrcaServerStack이 없으면 deploy_orca.sh --attach의 기본 스택을 씁니다.
if [ -z "$TF_MODE" ] && ! "$STACK_NAME_SET" && ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1 \
    && aws cloudformation describe-stacks --stack-name OrcaOnVscodeStack --region "$REGION" >/dev/null 2>&1; then
    STACK_NAME=OrcaOnVscodeStack
fi

command -v session-manager-plugin >/dev/null 2>&1 || {
    echo "[ERROR] session-manager-plugin이 필요합니다:" >&2
    echo "  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2
    exit 1
}

if [ -n "$TF_MODE" ]; then
    INSTANCE_ID=$(tf_output instance_id)
    TF_REGION=$(tf_output region)
    [[ "$INSTANCE_ID" == i-* ]] && [ -n "$TF_REGION" ] \
        || { echo "[ERROR] infra-tf/$TF_MODE 에 배포된 Orca가 없습니다 (terraform output에 instance_id가 없음)." >&2; exit 1; }
    REGION="$TF_REGION"
else
    INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
    [[ "$INSTANCE_ID" == i-* ]] || { echo "[ERROR] $STACK_NAME ($REGION) 스택의 InstanceId를 찾지 못했습니다." >&2; exit 1; }
fi

REMOTE='if [ ! -f /var/lib/orca-bootstrap/done ]; then echo "[WAIT] 서버 설치가 아직 진행 중입니다: sudo tail -f /var/log/user-data.log"; exit 0; fi; '
if "$RESTART"; then
    REMOTE+='sudo systemctl restart orca-serve; for i in $(seq 1 45); do sudo journalctl -u orca-serve --since "-2min" -o cat --no-pager | grep -q "Web client URL:" && break; sleep 2; done; '
fi
REMOTE+='J=$(sudo journalctl -u orca-serve -o cat --no-pager); '
REMOTE+='URL=$(echo "$J" | grep -F "Web client URL:" | tail -n 1 | sed "s/^Web client URL: //"); '
REMOTE+='PAIR=$(echo "$J" | grep -F "Pairing URL:" | tail -n 1 | sed "s/^Pairing URL: //"); '
REMOTE+='if [ -z "$URL" ]; then echo "[WARN] 링크가 journald에 없습니다. --restart 옵션으로 다시 실행하세요."; exit 0; fi; '
# While no access password exists, append the one-time setup code: the first page asks for a new password.
REMOTE+='CODE=$(sudo cat /etc/orca/gate-setup-code 2>/dev/null || true); '
REMOTE+='[ -n "$CODE" ] && URL="$URL&gate-setup=$CODE"; '
REMOTE+='echo; echo "[1] 전체 링크 (이 링크 하나로 암호 설정/로그인 + 페어링):"; echo "$URL"; echo; '
REMOTE+='echo "[2] 링크가 잘리거나 열리지 않으면 아래 값을 직접 입력하세요."; '
REMOTE+='echo "    접속 주소  : ${URL%%/web-index.html*}/"; '
REMOTE+='if [ -n "$CODE" ]; then echo "    설정 코드  : $CODE   (접속 암호 설정 화면에 입력, 1회용)"; '
REMOTE+='else echo "    설정 코드  : 없음 (접속 암호가 이미 설정됨 - 로그인 화면에 암호 입력)"; fi; '
REMOTE+='echo "    페어링 코드: $PAIR"; echo "                 (Orca 연결 화면의 Pairing URL or code 칸에 붙여 넣고 Connect)"; echo'

PARAMS=$(python3 -c 'import json,sys; print(json.dumps({"command": [sys.argv[1]]}))' "$REMOTE")

echo "인스턴스 $INSTANCE_ID ($REGION)에서 접속 정보를 읽습니다..."
aws ssm start-session --target "$INSTANCE_ID" --region "$REGION" \
    --document-name AWS-StartInteractiveCommand --parameters "$PARAMS"
echo "링크와 코드는 서버 접근 권한입니다. 다른 사람과 공유하지 마세요. 페어링 후 주소창의 토큰은 자동으로 지워집니다."
