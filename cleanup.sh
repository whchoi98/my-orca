#!/bin/bash
# Orca Server 스택 삭제
#   bash cleanup.sh [--region <region>] [--stack-name <name>] [--yes]
#   bash cleanup.sh --tf <dedicated|attach> [--yes]     # deploy_orca_tf.sh(Terraform)로 배포한 것
# CloudFront 배포가 포함되어 있어 삭제까지 10~15분 걸릴 수 있습니다.
# OrcaServerStack: EC2의 EBS(작업 중인 저장소, ~/.config/orca 세션 데이터 포함)도 함께 삭제됩니다.
# --attach 스택(OrcaOnVscodeStack): 호스트 서버에서 Orca만 제거하고 서버와 데이터는 그대로 둡니다.
# --tf dedicated, --tf attach 도 각각 같은 것을 지웁니다 (terraform destroy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STACK_NAME_SET=false
[ -n "${STACK_NAME:-}" ] && STACK_NAME_SET=true
STACK_NAME="${STACK_NAME:-OrcaServerStack}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-2}}"
ASSUME_YES=false
TF_MODE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --region) REGION="$2"; shift 2 ;;
        --stack-name) STACK_NAME="$2"; STACK_NAME_SET=true; shift 2 ;;
        --tf) TF_MODE="${2:-}"; shift 2 ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        --help|-h) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "알 수 없는 인자: $1" >&2; exit 1 ;;
    esac
done

# -------------------------------------------------------
# --tf: Terraform 배포 삭제
# -------------------------------------------------------
if [ -n "$TF_MODE" ]; then
    case "$TF_MODE" in
        dedicated|attach) ;;
        *) echo "[ERROR] --tf 값은 dedicated 또는 attach 입니다." >&2; exit 1 ;;
    esac
    command -v terraform >/dev/null 2>&1 || { echo "[ERROR] terraform 명령어가 필요합니다." >&2; exit 1; }
    TF_DIR="$SCRIPT_DIR/infra-tf/$TF_MODE"
    # 상태 파일에는 X-Custom-Secret 값이 들어 있습니다. 새로 쓰는 파일도 본인만 읽게 합니다.
    umask 077
    export TF_IN_AUTOMATION=1
    # 새로 내려받은 저장소처럼 .terraform이 없으면 상태를 읽지 못합니다. destroy에도 provider가 필요합니다.
    terraform -chdir="$TF_DIR" init -input=false >/dev/null 2>&1 \
        || { echo "[ERROR] terraform init 이 실패했습니다 (infra-tf/$TF_MODE)." >&2; exit 1; }
    STATE_LIST=$(terraform -chdir="$TF_DIR" state list 2>/dev/null || true)
    if [ -z "$STATE_LIST" ]; then
        echo "infra-tf/$TF_MODE 에 배포된 것이 없습니다."
        exit 0
    fi
    tf_output() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true; }
    echo "CloudFrontURL	$(tf_output cloudfront_url)"
    echo "InstanceId	$(tf_output instance_id)"
    if [ "$TF_MODE" = attach ]; then
        WHAT="배포를 삭제하고 $(tf_output host) 서버에서 Orca를 제거합니다 (서버와 EBS, ~/.config/orca는 유지)"
    else
        WHAT="배포와 EC2 볼륨을 삭제합니다"
    fi
    if ! "$ASSUME_YES"; then
        read -r -p "  infra-tf/$TF_MODE ($(tf_output region)) $WHAT. 계속? (yes 입력): " CONFIRM
        [ "$CONFIRM" = "yes" ] || { echo "취소했습니다."; exit 0; }
    fi
    terraform -chdir="$TF_DIR" destroy -input=false -auto-approve
    # 저장해 둔 입력 값(호스트 ID 등)도 지워, 다음 배포가 이전 값을 이어받지 않게 합니다.
    rm -f "$TF_DIR/orca.auto.tfvars.json"
    echo "infra-tf/$TF_MODE 삭제 완료."
    exit 0
fi

# 스택 이름을 정하지 않았고 OrcaServerStack이 없으면 deploy_orca.sh --attach의 기본 스택을 씁니다.
if ! "$STACK_NAME_SET" && ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1 \
    && aws cloudformation describe-stacks --stack-name OrcaOnVscodeStack --region "$REGION" >/dev/null 2>&1; then
    STACK_NAME=OrcaOnVscodeStack
fi

if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1; then
    echo "$STACK_NAME ($REGION) 스택이 없습니다."
    exit 0
fi

aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='CloudFrontURL' || OutputKey=='InstanceId' || OutputKey=='HostStack'].[OutputKey,OutputValue]" --output text
HOST_STACK=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='HostStack'].OutputValue" --output text)
if [ -n "$HOST_STACK" ] && [ "$HOST_STACK" != None ]; then
    # deploy_orca.sh --attach 스택: 서버는 호스트 스택의 것이라 지우지 않습니다.
    WHAT="스택을 삭제하고 $HOST_STACK 서버에서 Orca를 제거합니다 (서버·EBS·~/.config/orca는 유지)"
else
    WHAT="스택과 EC2 볼륨을 삭제합니다"
fi

if ! "$ASSUME_YES"; then
    read -r -p "  $STACK_NAME ($REGION) $WHAT. 계속? (yes 입력): " CONFIRM
    [ "$CONFIRM" = "yes" ] || { echo "취소했습니다."; exit 0; }
fi

aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
echo "삭제 요청 완료. 완료를 기다립니다 (최대 60분)..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
echo "$STACK_NAME 삭제 완료."
