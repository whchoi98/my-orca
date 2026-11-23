#!/bin/bash
# Orca Server 배포 스크립트 (Terraform)
#   CloudFront (HTTPS) -> ALB (CloudFront prefix list SG + X-Custom-Secret) -> Private EC2 (orca-ide serve :6768)
#
# deploy_orca.sh(CDK)와 같은 구성을 infra-tf/의 Terraform 코드로 만듭니다. 한 서버에는 둘 중 하나만 씁니다.
#
# 사용법:
#   bash deploy_orca_tf.sh --attach VscodeServerStack --yes   # 기존 VS Code 서버에 Orca 추가 (infra-tf/attach)
#   bash deploy_orca_tf.sh --attach-instance i-0123456789abcdef0 --attach-listener <리스너 ARN> --yes
#                                                             # CloudFormation으로 만들지 않은 서버에 추가
#   bash deploy_orca_tf.sh                    # 대화형: 번호 메뉴로 리전, VPC(새로 만들기 또는 기존 VPC), 인스턴스 타입을 고름
#   bash deploy_orca_tf.sh --yes              # 기본값으로 바로 배포 (ap-northeast-2, r6g.xlarge, 새 VPC)
#   bash deploy_orca_tf.sh --plan             # 계획만 보고 끝냄 (아무것도 만들지 않음)
#   ORCA_WEB_PASSWORD='...' bash deploy_orca_tf.sh --yes   # 접속 암호까지 비대화형으로 설정
#
# 입력 값은 infra-tf/<dedicated|attach>/orca.auto.tfvars.json에 저장하고, 다시 실행할 때 주지 않은
# 옵션은 저장된 값을 유지합니다. 페어링 링크는 Terraform 출력에 넣지 않습니다(상태 파일에 평문으로
# 남기 때문). 배포 뒤 bash get_pairing_url.sh --tf <dedicated|attach> 로 받습니다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 리전, VPC, 인스턴스 타입을 고르는 대화형 안내 (guide_로 시작하는 함수)
# shellcheck source=deploy_guide.sh
source "$SCRIPT_DIR/deploy_guide.sh"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-2}}"
REGION_SET=false
ORCA_VERSION=""
WEB_PASSWORD="${ORCA_WEB_PASSWORD:-}"
ASSUME_YES=false
PLAN_ONLY=false
ATTACH_TO=""
ATTACH_INSTANCE=""
ATTACH_LISTENER=""
DEDICATED_ONLY=""     # 전용 서버에만 쓰는 옵션을 받았으면 그 이름
# 명시한 옵션만 모읍니다. "<종류>:<변수>=<값>", 종류는 s(문자열) b(참거짓) n(숫자) l(쉼표 목록).
OVERRIDES=()

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'
옵션:
  --attach <host-stack>        기존 서버의 CloudFormation 스택(예: VscodeServerStack). EC2와 ALB 리스너를 찾아 Orca를 추가합니다.
  --attach-instance <id>       기존 서버의 인스턴스 ID (스택 대신 직접 지정, --attach-listener와 함께)
  --attach-listener <arn>      기존 서버 앞 ALB의 HTTP:80 리스너 ARN
  --host-instance-sg <sg-id>   ALB 트래픽을 받을 호스트 보안 그룹 (호스트의 보안 그룹이 여러 개일 때)
  --host-alb-sg <sg-id>        ALB 보안 그룹 (ALB의 보안 그룹이 여러 개일 때)
  --orca-rule-priority <n>     Orca 리스너 규칙의 우선순위 (기본 10, 기존 서버에 추가할 때)
  --gate-rule-priority <n>     /__gate/setup 규칙의 우선순위 (기본 5, Orca 규칙보다 낮은 수)
  --region <region>            배포 리전 (기본: 저장된 값, 없으면 AWS_REGION 또는 ap-northeast-2)
  --name <name>                배포 이름. 모든 리소스 이름의 앞부분 (기본: orca-server, 기존 서버에 추가하면 orca-on-vscode)
  --instance-type <type>       EC2 인스턴스 타입 (기본: r6g.xlarge, 전용 서버)
  --orca-version <x.y.z>       설치할 Orca 릴리스 (기본: 저장된 값, 없으면 GitHub 최신 릴리스)
  --vpc-id <vpc-id>            기존 VPC 사용 (기본: 새 VPC 10.253.0.0/16). 서브넷을 주지 않으면 VPC에서 찾습니다.
  --alb-subnets <a,b>          기존 VPC의 퍼블릭 서브넷 둘 이상 (가용 영역이 달라야 함. 기본: 영역마다 하나씩 자동 선택)
  --instance-subnet <id>       기존 VPC의 프라이빗 서브넷 (인터넷으로 나가는 경로가 있어야 함. 기본: 첫 프라이빗 서브넷)
  --vpc-name <name>            새 VPC Name 태그 (기본: orca-vpc)
  --skip-vpc-endpoints         SSM VPC 엔드포인트 생성 생략 (기존 VPC에 이미 있으면 주지 않아도 생략합니다)
  --no-password-gate           CloudFront 접속 암호 게이트를 만들지 않음 (Orca 페어링만 사용)
  --password-gate              접속 암호 게이트를 다시 만듦 (--no-password-gate로 배포한 뒤)
  --plan                       계획만 보여 주고 끝냄
  --yes                        확인 없이 진행
EOF
}

# 값이 빠지면 다음 옵션을 값으로 삼키게 됩니다(--name --yes). 그 경우도 막습니다.
need_value() { [ "$#" -ge 2 ] && [[ "$2" != --* ]] || { echo "$1 옵션에 값이 필요합니다 (--help 참고)" >&2; exit 1; }; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --attach) need_value "$@"; ATTACH_TO="$2"; shift 2 ;;
        --attach-instance) need_value "$@"; ATTACH_INSTANCE="$2"; shift 2 ;;
        --attach-listener) need_value "$@"; ATTACH_LISTENER="$2"; shift 2 ;;
        --host-instance-sg) need_value "$@"; OVERRIDES+=("s:host_instance_security_group_id=$2"); shift 2 ;;
        --host-alb-sg) need_value "$@"; OVERRIDES+=("s:host_alb_security_group_id=$2"); shift 2 ;;
        --orca-rule-priority) need_value "$@"; OVERRIDES+=("n:orca_rule_priority=$2"); shift 2 ;;
        --gate-rule-priority) need_value "$@"; OVERRIDES+=("n:gate_setup_rule_priority=$2"); shift 2 ;;
        --region) need_value "$@"; REGION="$2"; REGION_SET=true; shift 2 ;;
        --name) need_value "$@"; OVERRIDES+=("s:name=$2"); shift 2 ;;
        --instance-type) need_value "$@"; OVERRIDES+=("s:instance_type=$2"); DEDICATED_ONLY="$1"; shift 2 ;;
        --orca-version) need_value "$@"; ORCA_VERSION="${2#v}"; shift 2 ;;
        --vpc-id) need_value "$@"; OVERRIDES+=("s:vpc_id=$2"); DEDICATED_ONLY="$1"; shift 2 ;;
        --alb-subnets) need_value "$@"; OVERRIDES+=("l:alb_subnet_ids=$2"); DEDICATED_ONLY="$1"; shift 2 ;;
        --instance-subnet) need_value "$@"; OVERRIDES+=("s:instance_subnet_id=$2"); DEDICATED_ONLY="$1"; shift 2 ;;
        --vpc-name) need_value "$@"; OVERRIDES+=("s:vpc_name=$2"); DEDICATED_ONLY="$1"; shift 2 ;;
        --skip-vpc-endpoints) OVERRIDES+=("b:create_ssm_endpoints=false"); DEDICATED_ONLY="$1"; shift ;;
        --no-password-gate) OVERRIDES+=("b:password_gate=false"); shift ;;
        --password-gate) OVERRIDES+=("b:password_gate=true"); shift ;;
        --plan) PLAN_ONLY=true; shift ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "알 수 없는 인자: $1 (--help 참고)" >&2; exit 1 ;;
    esac
done

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "  $*"; }

if [ -n "$ATTACH_TO" ] || [ -n "$ATTACH_INSTANCE" ] || [ -n "$ATTACH_LISTENER" ]; then
    MODE=attach
    [ -z "$DEDICATED_ONLY" ] || die "$DEDICATED_ONLY 옵션은 기존 서버에 추가할 때 쓰지 않습니다."
    if [ -n "$ATTACH_TO" ]; then
        [ -z "$ATTACH_INSTANCE$ATTACH_LISTENER" ] || die "--attach 와 --attach-instance/--attach-listener 는 함께 쓰지 않습니다."
    else
        [ -n "$ATTACH_INSTANCE" ] && [ -n "$ATTACH_LISTENER" ] || die "--attach-instance 와 --attach-listener 를 함께 지정합니다."
    fi
else
    MODE=dedicated
fi
TF_DIR="$SCRIPT_DIR/infra-tf/$MODE"
VARS_FILE="$TF_DIR/orca.auto.tfvars.json"

for cmd in aws terraform python3 curl; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd 명령어가 필요합니다."
done

# 상태 파일에는 X-Custom-Secret 값이 평문으로 들어갑니다. 이 스크립트가 만드는 파일(상태, 계획, 입력 값)은
# 본인만 읽을 수 있게 합니다.
umask 077
export TF_IN_AUTOMATION=1

# 저장된 입력 값에서 하나를 읽습니다. 없으면 빈 문자열.
saved() {
    python3 -I - "$VARS_FILE" "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        value = json.load(f).get(sys.argv[2], "")
except (OSError, ValueError):
    value = ""
if isinstance(value, bool):
    value = "true" if value else "false"
print("" if value is None else value)
PY
}

SAVED_REGION=$(saved region)
if ! "$REGION_SET" && [ -n "$SAVED_REGION" ]; then
    REGION="$SAVED_REGION"
fi
SAVED_VERSION=$(saved orca_version)

echo "=============================================="
if [ "$MODE" = attach ]; then
    echo " Orca 추가 배포 (Terraform, 기존 서버에 설치)"
else
    echo " Orca Server 배포 (Terraform, CloudFront -> ALB -> EC2)"
fi
echo "=============================================="

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || die "AWS 자격 증명을 확인하세요."
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
info "계정: $ACCOUNT_ID ($CALLER_ARN)"

# -------------------------------------------------------
# 대화형 안내 (--yes와 --plan이 없을 때). 옵션으로 준 값과 저장된 값은 묻지 않습니다.
# -------------------------------------------------------
INTERACTIVE=false
if ! "$ASSUME_YES" && ! "$PLAN_ONLY"; then
    INTERACTIVE=true
fi
if "$INTERACTIVE" && ! "$REGION_SET" && [ -z "$SAVED_REGION" ]; then
    guide_region "$REGION"
    REGION="$GUIDE_REGION"
fi
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
OVERRIDES+=("s:region=$REGION")

# 변수의 지금 값: 이번에 옵션으로 준 값, 없으면 저장된 값, 둘 다 없으면 빈 문자열.
effective() {
    local item value
    value=$(saved "$1")
    for item in ${OVERRIDES[@]+"${OVERRIDES[@]}"}; do
        case "$item" in
            ?:"$1"=*) value="${item#*=}" ;;
        esac
    done
    printf '%s' "$value"
}

# -------------------------------------------------------
# Terraform 준비. 상태에 리소스가 있으면 이미 배포한 것입니다.
# -------------------------------------------------------
if ! INIT_OUTPUT=$(terraform -chdir="$TF_DIR" init -input=false -no-color 2>&1); then
    echo "$INIT_OUTPUT" >&2
    die "terraform init 이 실패했습니다."
fi
STATE_LIST=$(terraform -chdir="$TF_DIR" state list 2>/dev/null || true)
DEPLOYED=false
[ -z "$STATE_LIST" ] || DEPLOYED=true

# -------------------------------------------------------
# 전용 서버: VPC와 인스턴스 타입
# -------------------------------------------------------
if [ "$MODE" = dedicated ]; then
    # 이미 배포했으면 저장된 값을 그대로 씁니다. VPC가 바뀌면 ALB와 EC2(EBS의 작업 내용 포함)를 모두 새로 만들게 됩니다.
    if ! "$DEPLOYED"; then
        VPC_ID_NOW=$(effective vpc_id)
        VPC_INSPECTED=false
        if "$INTERACTIVE" && [ -z "$VPC_ID_NOW" ]; then
            VPC_NAME_NOW=$(effective vpc_name)
            guide_vpc "$REGION" "${VPC_NAME_NOW:-orca-vpc}" "10.253.0.0/16, 퍼블릭과 프라이빗 서브넷 둘씩, NAT Gateway 하나"
            if [ -n "$GUIDE_VPC_ID" ]; then
                VPC_ID_NOW="$GUIDE_VPC_ID"
                VPC_INSPECTED=true
                OVERRIDES+=("s:vpc_id=$VPC_ID_NOW")
            else
                OVERRIDES+=("s:vpc_name=$GUIDE_VPC_NAME")
            fi
        fi
        if [ -n "$VPC_ID_NOW" ]; then
            # 서브넷을 주지 않았으면 VPC에서 찾습니다. ALB에는 가용 영역마다 퍼블릭 서브넷 하나, EC2에는 프라이빗 서브넷 하나.
            if [ -z "$(effective alb_subnet_ids)" ] || [ -z "$(effective instance_subnet_id)" ]; then
                if ! "$VPC_INSPECTED"; then
                    guide_inspect_vpc "$REGION" "$VPC_ID_NOW" || die "VPC $VPC_ID_NOW ($REGION)를 읽지 못했습니다."
                    "$GUIDE_VPC_OK" || die "VPC $VPC_ID_NOW 는 이 배포에 쓸 수 없습니다 (위 안내 참고). 쓸 서브넷을 --alb-subnets 와 --instance-subnet 으로 직접 줄 수도 있습니다."
                fi
                if [ -z "$(effective alb_subnet_ids)" ]; then
                    OVERRIDES+=("l:alb_subnet_ids=$GUIDE_PUBLIC_SUBNETS")
                    info "ALB 서브넷: $GUIDE_PUBLIC_SUBNETS"
                fi
                if [ -z "$(effective instance_subnet_id)" ]; then
                    if "$INTERACTIVE"; then
                        guide_instance_subnet
                    else
                        GUIDE_INSTANCE_SUBNET="${GUIDE_PRIVATE_SUBNETS%%,*}"
                    fi
                    OVERRIDES+=("s:instance_subnet_id=$GUIDE_INSTANCE_SUBNET")
                    info "EC2 서브넷: $GUIDE_INSTANCE_SUBNET"
                fi
            fi
            if [ -z "$(effective create_ssm_endpoints)" ]; then
                guide_ssm_endpoints "$REGION" "$VPC_ID_NOW"
                if "$GUIDE_SKIP_ENDPOINTS"; then
                    OVERRIDES+=("b:create_ssm_endpoints=false")
                fi
            fi
        fi
    fi
    if "$INTERACTIVE" && [ -z "$(effective instance_type)" ]; then
        guide_instance_type "$REGION" r6g.xlarge true
        OVERRIDES+=("s:instance_type=$GUIDE_INSTANCE_TYPE")
    fi
fi

# -------------------------------------------------------
# 기존 서버에 추가: 호스트의 EC2와 ALB 리스너를 찾고 미리 확인합니다
# -------------------------------------------------------
if [ "$MODE" = attach ]; then
    if [ -n "$ATTACH_TO" ]; then
        aws cloudformation describe-stacks --stack-name "$ATTACH_TO" --region "$REGION" >/dev/null 2>&1 \
            || die "호스트 스택 $ATTACH_TO ($REGION)을 찾지 못했습니다."
        host_resource() {  # <resource type>: 호스트 스택에 정확히 하나만 있어야 합니다.
            local ids
            ids=$(aws cloudformation list-stack-resources --stack-name "$ATTACH_TO" --region "$REGION" \
                --query "StackResourceSummaries[?ResourceType=='$1'].PhysicalResourceId" --output text)
            [ -n "$ids" ] && [ "$ids" != None ] || die "$ATTACH_TO 스택에 $1 리소스가 없습니다."
            [ "$(wc -w <<<"$ids")" -eq 1 ] || die "$ATTACH_TO 스택에 $1 리소스가 여러 개라 고를 수 없습니다. --attach-instance 와 --attach-listener 로 지정하세요."
            echo "$ids"
        }
        HOST_INSTANCE_ID=$(host_resource AWS::EC2::Instance)
        HOST_LISTENER_ARN=$(host_resource AWS::ElasticLoadBalancingV2::Listener)
        HOST_LABEL="$ATTACH_TO"
    else
        HOST_INSTANCE_ID="$ATTACH_INSTANCE"
        HOST_LISTENER_ARN="$ATTACH_LISTENER"
        HOST_LABEL="$ATTACH_INSTANCE"
    fi
    OVERRIDES+=("s:host_instance_id=$HOST_INSTANCE_ID" "s:host_listener_arn=$HOST_LISTENER_ARN" "s:host_label=$HOST_LABEL")

    HOST_ARCH=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$HOST_INSTANCE_ID" --output text \
        --query 'Reservations[0].Instances[0].Architecture') || die "호스트 인스턴스 $HOST_INSTANCE_ID 를 찾지 못했습니다."
    read -r HOST_LB_ARN HOST_LISTENER_PORT HOST_LISTENER_PROTOCOL < <(aws elbv2 describe-listeners --region "$REGION" \
        --listener-arns "$HOST_LISTENER_ARN" --output text \
        --query 'Listeners[0].[LoadBalancerArn,Port,Protocol]') || die "호스트 ALB 리스너를 찾지 못했습니다."
    [ "$HOST_LISTENER_PORT $HOST_LISTENER_PROTOCOL" = "80 HTTP" ] \
        || die "호스트 ALB 리스너가 HTTP:80이 아닙니다 (CloudFront 오리진은 HTTP:80으로 연결)."
    read -r HOST_ALB_DNS HOST_ALB_SGS < <(aws elbv2 describe-load-balancers --region "$REGION" \
        --load-balancer-arns "$HOST_LB_ARN" --output text \
        --query 'LoadBalancers[0].[DNSName,join(`,`,SecurityGroups)]')
    # CloudFront를 거치지 않는 경로가 열려 있으면 Orca 헤더 값만이 보호 수단이 됩니다. ALB의 보안 그룹을 모두 봅니다.
    OPEN_RULES=$(aws ec2 describe-security-group-rules --region "$REGION" \
        --filters "Name=group-id,Values=$HOST_ALB_SGS" \
        --query "SecurityGroupRules[?!IsEgress && (CidrIpv4=='0.0.0.0/0' || CidrIpv6=='::/0')].SecurityGroupRuleId" \
        --output text)
    [ -z "$OPEN_RULES" ] || [ "$OPEN_RULES" = None ] || die "호스트 ALB 보안 그룹($HOST_ALB_SGS)이 인터넷 전체에 열려 있습니다 ($OPEN_RULES). CloudFront 접두사 목록만 허용하도록 먼저 수정하세요."
    [ "$(aws ssm describe-instance-information --region "$REGION" \
        --filters "Key=InstanceIds,Values=$HOST_INSTANCE_ID" \
        --query 'InstanceInformationList[0].PingStatus' --output text)" = Online ] \
        || die "호스트 $HOST_INSTANCE_ID 의 SSM 에이전트가 온라인이 아닙니다 (Orca는 SSM Run Command로 설치)."

    if ! "$DEPLOYED"; then
        # 한 서버에는 Orca 배포가 하나만 붙습니다. CDK 스택이나 다른 Terraform 배포가 이미 붙어 있으면
        # 설치 스크립트가 그쪽의 페어링 주소를 덮어쓰게 되므로 여기서 멈춥니다.
        RULE_TARGETS=$(aws elbv2 describe-rules --region "$REGION" --listener-arn "$HOST_LISTENER_ARN" --output text \
            --query 'Rules[].Actions[?Type==`forward`].TargetGroupArn[]')
        if [ -n "$RULE_TARGETS" ] && [ "$RULE_TARGETS" != None ]; then
            # shellcheck disable=SC2086
            ORCA_TARGETS=$(aws elbv2 describe-target-groups --region "$REGION" --target-group-arns $RULE_TARGETS \
                --query 'TargetGroups[?Port==`6768`].TargetGroupName' --output text)
            [ -z "$ORCA_TARGETS" ] || [ "$ORCA_TARGETS" = None ] || die "이 서버의 ALB에는 이미 Orca(6768 포트) 규칙이 있습니다 ($ORCA_TARGETS). CDK 스택으로 배포했다면 그쪽을 계속 쓰거나 bash cleanup.sh 로 지운 뒤 다시 실행하세요."
        fi
        ORCA_PRIORITY=$(saved orca_rule_priority); ORCA_PRIORITY="${ORCA_PRIORITY:-10}"
        GATE_PRIORITY=$(saved gate_setup_rule_priority); GATE_PRIORITY="${GATE_PRIORITY:-5}"
        for item in ${OVERRIDES[@]+"${OVERRIDES[@]}"}; do
            case "$item" in
                n:orca_rule_priority=*) ORCA_PRIORITY="${item#*=}" ;;
                n:gate_setup_rule_priority=*) GATE_PRIORITY="${item#*=}" ;;
            esac
        done
        USED=$(aws elbv2 describe-rules --region "$REGION" --listener-arn "$HOST_LISTENER_ARN" \
            --query "Rules[?Priority=='$GATE_PRIORITY' || Priority=='$ORCA_PRIORITY'].Priority" --output text)
        [ -z "$USED" ] || [ "$USED" = None ] || die "호스트 리스너의 규칙 우선순위 $USED 가 이미 사용 중입니다 (--orca-rule-priority, --gate-rule-priority 로 바꿀 수 있음)."
    fi
    info "호스트: $HOST_INSTANCE_ID ($HOST_ARCH), ALB $HOST_ALB_DNS"
fi

# -------------------------------------------------------
# Orca 릴리스 확인
# -------------------------------------------------------
if [ "$MODE" = attach ]; then
    [ "$HOST_ARCH" = arm64 ] && RPM_ARCH=aarch64 || RPM_ARCH=x86_64
else
    INSTANCE_TYPE=$(effective instance_type)
    INSTANCE_TYPE="${INSTANCE_TYPE:-r6g.xlarge}"
    RPM_ARCH=$(guide_instance_arch "$REGION" "$INSTANCE_TYPE")
fi
if [ -z "$ORCA_VERSION" ] && [ -z "$SAVED_VERSION" ]; then
    ORCA_VERSION=$(curl -fsSL https://api.github.com/repos/stablyai/orca/releases/latest \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))') \
        || die "Orca 최신 릴리스를 조회하지 못했습니다. --orca-version 으로 지정하세요."
fi
if [ -n "$ORCA_VERSION" ]; then
    RPM_NAME="orca-ide-${ORCA_VERSION}.${RPM_ARCH}.rpm"
    # 다운로드 주소(github.com) 대신 API로 확인합니다. github.com 웹이 5xx를 돌려줄 때도 동작합니다.
    curl -fsSL --retry 3 "https://api.github.com/repos/stablyai/orca/releases/tags/v${ORCA_VERSION}" \
        | python3 -c 'import json, sys
sys.exit(0 if any(a.get("name") == sys.argv[1] for a in json.load(sys.stdin).get("assets", [])) else 1)' "$RPM_NAME" \
        || die "릴리스 자산을 찾지 못했습니다: v$ORCA_VERSION / $RPM_NAME"
    OVERRIDES+=("s:orca_version=$ORCA_VERSION")
    if [ -n "$SAVED_VERSION" ] && [ "$SAVED_VERSION" != "$ORCA_VERSION" ]; then
        info "Orca: v$SAVED_VERSION 에서 v$ORCA_VERSION 로 ($RPM_ARCH RPM 확인)"
    else
        info "Orca: v$ORCA_VERSION ($RPM_ARCH RPM 확인)"
    fi
else
    info "Orca: 저장된 버전 v$SAVED_VERSION 유지"
fi

# -------------------------------------------------------
# 입력 값 합치기: 저장된 값 위에 이번에 명시한 옵션을 덮어씁니다
# -------------------------------------------------------
NEXT_VARS="$TF_DIR/orca.next.tfvars.json"
PLAN_FILE="$TF_DIR/orca.tfplan"
trap 'rm -f "$NEXT_VARS" "$PLAN_FILE"' EXIT
python3 -I - "$VARS_FILE" "$NEXT_VARS" ${OVERRIDES[@]+"${OVERRIDES[@]}"} <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except (OSError, ValueError):
    data = {}
for item in sys.argv[3:]:
    kind, rest = item.split(":", 1)
    key, value = rest.split("=", 1)
    if kind == "b":
        value = value == "true"
    elif kind == "n":
        value = int(value)
    elif kind == "l":
        value = [v.strip() for v in value.split(",") if v.strip()]
    data[key] = value
with open(sys.argv[2], "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
next_value() {
    python3 -I -c 'import json, sys
value = json.load(open(sys.argv[1])).get(sys.argv[2], sys.argv[3])
print(("true" if value else "false") if isinstance(value, bool) else value)' "$NEXT_VARS" "$1" "$2"
}
PASSWORD_GATE=$(next_value password_gate true)

# -------------------------------------------------------
# 접속 암호 (CloudFront Function 게이트)
# -------------------------------------------------------
GATE_CONFIGURED=false
if [ "$PASSWORD_GATE" = true ] && "$DEPLOYED"; then
    GATE_ARN=$(terraform -chdir="$TF_DIR" output -raw password_gate_store_arn 2>/dev/null || true)
    if [[ "$GATE_ARN" == arn:* ]] && aws cloudfront-keyvaluestore get-key --kvs-arn "$GATE_ARN" --key auth-hash >/dev/null 2>&1; then
        GATE_CONFIGURED=true
    fi
fi
# 지금 입력하면 배포 직후 적용하고, 비워 두면(Enter) 최초 로그인 화면에서 암호를 정합니다.
if [ "$PASSWORD_GATE" = true ] && [ -z "$WEB_PASSWORD" ] && ! "$ASSUME_YES" && ! "$PLAN_ONLY"; then
    if "$GATE_CONFIGURED"; then
        echo "  접속 암호가 이미 설정되어 있습니다. 바꾸려면 새 암호를, 유지하려면 Enter를 누르세요."
    else
        echo "  접속 암호를 지금 정하거나, Enter로 건너뛰고 최초 로그인 화면에서 정할 수 있습니다."
    fi
    while true; do
        # IFS= 가 없으면 read가 앞뒤 공백을 잘라 내 입력한 암호와 다른 값이 저장됩니다.
        IFS= read -r -s -p "  Orca 접속 암호 (8자 이상, 12자 이상 권장, Enter=건너뛰기): " WEB_PASSWORD; echo
        [ -z "$WEB_PASSWORD" ] && break
        IFS= read -r -s -p "  암호 확인: " WEB_PASSWORD_CONFIRM; echo
        if [ "${#WEB_PASSWORD}" -lt 8 ]; then
            echo "  [!] 8자 이상이어야 합니다."
        elif [ "$WEB_PASSWORD" != "$WEB_PASSWORD_CONFIRM" ]; then
            echo "  [!] 두 암호가 다릅니다."
        else
            break
        fi
    done
    unset WEB_PASSWORD_CONFIRM
fi

# -------------------------------------------------------
# 요약과 계획
# -------------------------------------------------------
echo ""
echo "---------------- 배포 요약 ----------------"
info "구성: infra-tf/$MODE ($REGION, $( "$DEPLOYED" && echo 업데이트 || echo 신규)), 이름 $(next_value name "$( [ "$MODE" = attach ] && echo orca-on-vscode || echo orca-server )")"
if [ "$MODE" = attach ]; then
    info "설치 대상: $HOST_LABEL 의 $HOST_INSTANCE_ID (재부팅과 기존 서비스 재시작 없음, SSM으로 설치)"
    info "추가되는 것: Orca 전용 CloudFront, ALB 규칙, 보안 그룹 규칙(6768, 6769), 호스트 역할의 인라인 정책"
    info "과금 리소스: CloudFront(Function, KeyValueStore 포함), Secrets Manager, S3 (EC2와 ALB는 호스트 것을 함께 씀)"
else
    info "인스턴스: $INSTANCE_TYPE"
    info "VPC: $(next_value vpc_id "새 VPC 10.253.0.0/16")"
    info "과금 리소스: EC2, EBS 100GB, NAT Gateway(새 VPC), ALB, CloudFront(Function, KeyValueStore 포함), VPC 엔드포인트, Secrets Manager, S3"
fi
if [ "$PASSWORD_GATE" = true ]; then
    info "접속 암호: $( [ -n "$WEB_PASSWORD" ] && echo '배포 직후 적용' || { "$GATE_CONFIGURED" && echo '기존 암호 유지' || echo '최초 로그인 화면에서 설정 (get_pairing_url.sh 링크로 접속)'; } )"
else
    info "접속 암호: 사용 안 함 (Orca 페어링만)"
fi
info "페어링 링크: Terraform 출력에 넣지 않음 (bash get_pairing_url.sh --tf $MODE 로 조회)"
echo "-------------------------------------------"

terraform -chdir="$TF_DIR" plan -input=false -var-file="$NEXT_VARS" -out="$PLAN_FILE"

if "$PLAN_ONLY"; then
    echo ""
    echo "  계획만 확인했습니다. 만든 것이 없고 입력 값도 저장하지 않았습니다."
    exit 0
fi
if ! "$ASSUME_YES"; then
    read -r -p "  위 계획대로 배포할까요? (y/n) [y]: " CONFIRM
    [[ "${CONFIRM:-y}" =~ ^[Yy]$ ]] || { echo "취소했습니다."; exit 0; }
fi

# 적용이 중간에 실패해도 상태와 맞는 입력 값이 남도록 먼저 저장합니다.
mv "$NEXT_VARS" "$VARS_FILE"
terraform -chdir="$TF_DIR" apply -input=false "$PLAN_FILE"

if [ "$PASSWORD_GATE" = true ] && [ -n "$WEB_PASSWORD" ]; then
    # printf는 셸 내장 명령이라 암호가 프로세스 인자로 노출되지 않습니다.
    printf '%s\n' "$WEB_PASSWORD" | bash "$SCRIPT_DIR/set_password.sh" --tf "$MODE" --password-stdin
    unset WEB_PASSWORD
fi

# -------------------------------------------------------
# 결과
# -------------------------------------------------------
output() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true; }
echo ""
echo "=============================================="
echo " 배포 완료"
echo "=============================================="
info "CloudFront URL : $(output cloudfront_url)"
info "Instance ID    : $(output instance_id)"
info "Orca 버전      : v$(output orca_version)"
[ "$MODE" = attach ] && info "호스트         : $(output host) (변경 없음, bash cleanup.sh --tf attach 는 Orca만 제거)"
info "ALB (직접 차단): $(output alb_endpoint)"
info "SSM 접속       : $(output ssm_access)"
echo ""
if [ "$MODE" = dedicated ] && ! "$DEPLOYED"; then
    echo "  1) 서버 설치 완료까지 약 5~10분 기다립니다 (진행: SSM 접속 후 sudo tail -f /var/log/user-data.log)."
fi
echo "  페어링 링크를 받아 브라우저로 엽니다:  bash get_pairing_url.sh --tf $MODE"
if [ "$PASSWORD_GATE" = true ]; then
    echo "  암호를 아직 정하지 않았다면 첫 화면에서 새 암호와 확인 암호를 입력합니다."
    echo "  이미 정했다면 로그인 화면에 입력합니다 (변경: bash set_password.sh --tf $MODE, 분실: bash set_password.sh --tf $MODE --reset-ui)."
fi
echo "  삭제: bash cleanup.sh --tf $MODE"
