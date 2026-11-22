#!/bin/bash
# Orca Server 배포 스크립트 (CDK)
#   CloudFront (HTTPS) -> ALB (CloudFront prefix list SG + X-Custom-Secret) -> Private EC2 (orca-ide serve :6768)
#
# 사용법:
#   bash deploy_orca.sh --attach VscodeServerStack --yes   # 기존 VS Code 서버에 Orca 추가 (OrcaOnVscodeStack)
#   bash deploy_orca.sh                     # 대화형 (Orca 전용 VPC/ALB/EC2를 새로 만듦)
#   bash deploy_orca.sh --yes               # 기본값으로 바로 배포 (ap-northeast-2, r6g.xlarge, 새 VPC)
#   bash deploy_orca.sh --region us-west-2 --instance-type r7g.xlarge --yes
#   bash deploy_orca.sh --vpc-id vpc-0123456789abcdef0 --skip-vpc-endpoints --yes
#   ORCA_WEB_PASSWORD='...' bash deploy_orca.sh --yes   # 접속 암호까지 비대화형으로 설정
#
# 배포는 서버 설치가 끝날 때까지 기다린 뒤 페어링 링크·설정 코드·페어링 코드를 스택 출력
# (PairingWebLink / GateSetupCode / PairingCode)과 이 스크립트의 마지막 화면에 보여 줍니다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CDK_DIR="$SCRIPT_DIR/infra-cdk"

# STACK_NAME 환경 변수나 --stack-name이 없으면 기본 이름을 씁니다 (--attach는 OrcaOnVscodeStack).
STACK_NAME_SET=false
[ -n "${STACK_NAME:-}" ] && STACK_NAME_SET=true
STACK_NAME="${STACK_NAME:-OrcaServerStack}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-2}}"
INSTANCE_TYPE="r6g.xlarge"
ORCA_VERSION=""
EXISTING_VPC_ID=""
VPC_NAME="orca-vpc"
SKIP_VPC_ENDPOINTS=false
PASSWORD_GATE=true
WEB_PASSWORD="${ORCA_WEB_PASSWORD:-}"
PAIRING_OUTPUT=true
ASSUME_YES=false
ATTACH_TO=""
ROLE_NAME_SUFFIX=""   # 전용 서버 스택만 씀
CF_PREFIX_LIST=""

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'
옵션:
  --attach <host-stack>      기존 서버 스택(예: VscodeServerStack)의 EC2와 ALB에 Orca를 추가합니다.
                             호스트 스택은 수정하지 않고, Orca 전용 CloudFront·암호 게이트·ALB 규칙만 만듭니다.
                             이 모드에서 --instance-type/--vpc-* 옵션은 쓰지 않습니다 (기본 스택: OrcaOnVscodeStack).
  --region <region>          배포 리전 (기본: AWS_REGION 또는 ap-northeast-2)
  --instance-type <type>     EC2 인스턴스 타입 (기본: r6g.xlarge)
  --orca-version <x.y.z>     설치할 Orca 릴리스 (기본: GitHub 최신 릴리스, 기존 스택은 이전 값 유지)
  --vpc-id <vpc-id>          기존 VPC 사용 (기본: 새 VPC 10.253.0.0/16 생성)
  --vpc-name <name>          새 VPC Name 태그 (기본: orca-vpc)
  --skip-vpc-endpoints       SSM VPC 엔드포인트 생성 생략 (기존 VPC에 이미 있을 때)
  --no-password-gate         CloudFront 접속 암호 게이트를 만들지 않음 (Orca 페어링만 사용)
  --no-pairing-output        페어링 링크를 스택 출력에 넣지 않음 (get_pairing_url.sh로만 조회)
  --stack-name <name>        스택 이름 (기본: OrcaServerStack)
  --yes                      확인 없이 진행
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --region) REGION="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --orca-version) ORCA_VERSION="${2#v}"; shift 2 ;;
        --vpc-id) EXISTING_VPC_ID="$2"; shift 2 ;;
        --vpc-name) VPC_NAME="$2"; shift 2 ;;
        --skip-vpc-endpoints) SKIP_VPC_ENDPOINTS=true; shift ;;
        --no-password-gate) PASSWORD_GATE=false; shift ;;
        --no-pairing-output) PAIRING_OUTPUT=false; shift ;;
        --stack-name) STACK_NAME="$2"; STACK_NAME_SET=true; shift 2 ;;
        --attach) ATTACH_TO="$2"; shift 2 ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "알 수 없는 인자: $1 (--help 참고)" >&2; exit 1 ;;
    esac
done

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "  $*"; }

if [ -n "$ATTACH_TO" ] && ! "$STACK_NAME_SET"; then
    STACK_NAME=OrcaOnVscodeStack
fi

for cmd in aws node npm python3 curl; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd 명령어가 필요합니다."
done

echo "=============================================="
if [ -n "$ATTACH_TO" ]; then
    echo " Orca 추가 배포 ($ATTACH_TO 서버에 설치)"
else
    echo " Orca Server 배포 (CloudFront -> ALB -> EC2)"
fi
echo "=============================================="

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || die "AWS 자격 증명을 확인하세요."
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
info "계정: $ACCOUNT_ID ($CALLER_ARN)"

# -------------------------------------------------------
# 대화형 입력 (--yes가 없을 때)
# -------------------------------------------------------
if ! "$ASSUME_YES" && [ -n "$ATTACH_TO" ]; then
    read -r -p "  리전 [$REGION]: " INPUT && REGION="${INPUT:-$REGION}"
elif ! "$ASSUME_YES"; then
    read -r -p "  리전 [$REGION]: " INPUT && REGION="${INPUT:-$REGION}"
    echo "  인스턴스 타입 (ARM64 Graviton 권장): r6g.xlarge r6g.2xlarge r7g.xlarge r7g.2xlarge m7g.xlarge m7g.2xlarge t4g.2xlarge"
    read -r -p "  인스턴스 타입 [$INSTANCE_TYPE]: " INPUT && INSTANCE_TYPE="${INPUT:-$INSTANCE_TYPE}"
    read -r -p "  기존 VPC ID (빈값이면 새 VPC 생성) [${EXISTING_VPC_ID}]: " INPUT && EXISTING_VPC_ID="${INPUT:-$EXISTING_VPC_ID}"
fi
export AWS_REGION="$REGION" CDK_DEFAULT_REGION="$REGION"

STACK_EXISTS=false
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1; then
    STACK_EXISTS=true
fi

# -------------------------------------------------------
# --attach: 호스트 스택의 EC2 / ALB 리스너 / 보안 그룹 / IAM 역할 찾기
# -------------------------------------------------------
if [ -n "$ATTACH_TO" ]; then
    aws cloudformation describe-stacks --stack-name "$ATTACH_TO" --region "$REGION" >/dev/null 2>&1 \
        || die "호스트 스택 $ATTACH_TO ($REGION)을 찾지 못했습니다."
    host_resource() {  # <resource type>: 호스트 스택에 정확히 하나만 있어야 합니다.
        local ids
        ids=$(aws cloudformation list-stack-resources --stack-name "$ATTACH_TO" --region "$REGION" \
            --query "StackResourceSummaries[?ResourceType=='$1'].PhysicalResourceId" --output text)
        [ -n "$ids" ] && [ "$ids" != None ] || die "$ATTACH_TO 스택에 $1 리소스가 없습니다."
        [ "$(wc -w <<<"$ids")" -eq 1 ] || die "$ATTACH_TO 스택에 $1 리소스가 여러 개라 고를 수 없습니다."
        echo "$ids"
    }
    HOST_INSTANCE_ID=$(host_resource AWS::EC2::Instance)
    HOST_LISTENER_ARN=$(host_resource AWS::ElasticLoadBalancingV2::Listener)
    HOST_LB_ARN=$(host_resource AWS::ElasticLoadBalancingV2::LoadBalancer)
    read -r HOST_VPC_ID HOST_INSTANCE_SG HOST_ARCH HOST_PROFILE_ARN < <(aws ec2 describe-instances \
        --region "$REGION" --instance-ids "$HOST_INSTANCE_ID" --output text \
        --query 'Reservations[0].Instances[0].[VpcId,SecurityGroups[0].GroupId,Architecture,IamInstanceProfile.Arn]')
    read -r HOST_ALB_DNS HOST_ALB_SG < <(aws elbv2 describe-load-balancers --region "$REGION" \
        --load-balancer-arns "$HOST_LB_ARN" --output text \
        --query 'LoadBalancers[0].[DNSName,SecurityGroups[0]]')
    HOST_ROLE=$(aws iam get-instance-profile --instance-profile-name "${HOST_PROFILE_ARN##*/}" \
        --query 'InstanceProfile.Roles[0].RoleName' --output text) \
        || die "호스트 인스턴스 프로파일의 IAM 역할을 읽지 못했습니다."
    [ "$(aws elbv2 describe-listeners --region "$REGION" --listener-arns "$HOST_LISTENER_ARN" \
        --query 'Listeners[0].[Port,Protocol]' --output text)" = "80	HTTP" ] \
        || die "호스트 ALB 리스너가 HTTP:80이 아닙니다 (CloudFront 오리진은 HTTP:80으로 연결)."
    # CloudFront를 거치지 않는 경로가 열려 있으면 Orca 헤더 값만이 보호 수단이 됩니다.
    OPEN_RULES=$(aws ec2 describe-security-group-rules --region "$REGION" \
        --filters "Name=group-id,Values=$HOST_ALB_SG" \
        --query "SecurityGroupRules[?!IsEgress && (CidrIpv4=='0.0.0.0/0' || CidrIpv6=='::/0')].SecurityGroupRuleId" \
        --output text)
    [ -z "$OPEN_RULES" ] || [ "$OPEN_RULES" = None ] || die "호스트 ALB 보안 그룹($HOST_ALB_SG)이 인터넷 전체에 열려 있습니다 ($OPEN_RULES). CloudFront 접두사 목록만 허용하도록 먼저 고치세요."
    if ! "$STACK_EXISTS"; then
        USED=$(aws elbv2 describe-rules --region "$REGION" --listener-arn "$HOST_LISTENER_ARN" \
            --query "Rules[?Priority=='5' || Priority=='10'].Priority" --output text)
        [ -z "$USED" ] || die "호스트 리스너의 규칙 우선순위 $USED 가 이미 사용 중입니다 (-c orcaRulePriority / gateSetupRulePriority 로 바꿀 수 있음)."
    fi
    [ "$(aws ssm describe-instance-information --region "$REGION" \
        --filters "Key=InstanceIds,Values=$HOST_INSTANCE_ID" \
        --query 'InstanceInformationList[0].PingStatus' --output text)" = Online ] \
        || die "호스트 $HOST_INSTANCE_ID 의 SSM 에이전트가 온라인이 아닙니다 (Orca는 SSM Run Command로 설치)."
    info "호스트: $HOST_INSTANCE_ID ($HOST_ARCH, $HOST_VPC_ID), ALB $HOST_ALB_DNS, 역할 $HOST_ROLE"
fi

# -------------------------------------------------------
# Orca 릴리스 확인
# -------------------------------------------------------
if [ -n "$ATTACH_TO" ]; then
    [ "$HOST_ARCH" = arm64 ] && RPM_ARCH=aarch64 || RPM_ARCH=x86_64
else
    case "$INSTANCE_TYPE" in
        *g.*|*gd.*|*gn.*) RPM_ARCH=aarch64 ;;
        *) RPM_ARCH=x86_64 ;;
    esac
fi
if [ -z "$ORCA_VERSION" ] && ! "$STACK_EXISTS"; then
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
    info "Orca: v$ORCA_VERSION ($RPM_ARCH RPM 확인)"
else
    info "Orca: 기존 스택의 OrcaVersion 유지 (설치된 서버는 재설치하지 않음)"
fi

if [ -z "$ATTACH_TO" ]; then
# -------------------------------------------------------
# CloudFront origin-facing prefix list
# -------------------------------------------------------
CF_PREFIX_LIST=$(aws ec2 describe-managed-prefix-lists --region "$REGION" \
    --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
    --query 'PrefixLists[0].PrefixListId' --output text)
[[ "$CF_PREFIX_LIST" == pl-* ]] || die "CloudFront prefix list를 찾지 못했습니다 ($REGION)."
info "CloudFront prefix list: $CF_PREFIX_LIST"

# -------------------------------------------------------
# IAM Role 이름 (IAM은 전역: 다른 리전에 같은 스택이 있으면 리전 접미사)
# -------------------------------------------------------
ROLE_BASE="${STACK_NAME}-Orca-Role"
ROLE_NAME_SUFFIX=""
if "$STACK_EXISTS"; then
    EXISTING_ROLE=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='EC2RoleName'].OutputValue" --output text 2>/dev/null || true)
    if [ -n "$EXISTING_ROLE" ] && [ "$EXISTING_ROLE" != "None" ]; then
        ROLE_NAME_SUFFIX="${EXISTING_ROLE#"$ROLE_BASE"}"
    fi
elif aws iam get-role --role-name "$ROLE_BASE" >/dev/null 2>&1; then
    ROLE_NAME_SUFFIX="-$REGION"
fi
fi  # --attach가 아닐 때만

# -------------------------------------------------------
# 접속 암호 (CloudFront Function 게이트)
# -------------------------------------------------------
GATE_CONFIGURED=false
if "$PASSWORD_GATE" && "$STACK_EXISTS"; then
    GATE_ARN=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='PasswordGateStoreArn'].OutputValue" --output text 2>/dev/null || true)
    if [[ "$GATE_ARN" == arn:* ]] && aws cloudfront-keyvaluestore get-key --kvs-arn "$GATE_ARN" --key auth-hash >/dev/null 2>&1; then
        GATE_CONFIGURED=true
    fi
fi
# 지금 입력하면 배포 직후 적용하고, 비워 두면(Enter) 최초 로그인 화면에서 암호를 정합니다.
if "$PASSWORD_GATE" && [ -z "$WEB_PASSWORD" ] && ! "$ASSUME_YES"; then
    if "$GATE_CONFIGURED"; then
        echo "  접속 암호가 이미 설정되어 있습니다. 바꾸려면 새 암호를, 유지하려면 Enter를 누르세요."
    else
        echo "  접속 암호를 지금 정하거나, Enter로 건너뛰고 최초 로그인 화면에서 정할 수 있습니다."
    fi
    while true; do
        read -r -s -p "  Orca 접속 암호 (8자 이상, 12자 이상 권장, Enter=건너뛰기): " WEB_PASSWORD; echo
        [ -z "$WEB_PASSWORD" ] && break
        read -r -s -p "  암호 확인: " WEB_PASSWORD_CONFIRM; echo
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
# 요약 및 확인
# -------------------------------------------------------
echo ""
echo "---------------- 배포 요약 ----------------"
info "스택: $STACK_NAME ($REGION, $( "$STACK_EXISTS" && echo 업데이트 || echo 신규))"
if [ -n "$ATTACH_TO" ]; then
    info "설치 대상: $ATTACH_TO 의 $HOST_INSTANCE_ID (재부팅·기존 서비스 재시작 없음, SSM으로 설치)"
    info "추가되는 것: Orca 전용 CloudFront, ALB 규칙(우선순위 5/10), 보안 그룹 규칙(6768/6769), 역할 정책"
else
    info "인스턴스: $INSTANCE_TYPE"
    info "VPC: ${EXISTING_VPC_ID:-새 VPC 10.253.0.0/16 ($VPC_NAME)}"
    info "IAM Role: ${ROLE_BASE}${ROLE_NAME_SUFFIX}"
fi
if "$PASSWORD_GATE"; then
    info "접속 암호: $( [ -n "$WEB_PASSWORD" ] && echo '배포 직후 적용' || { "$GATE_CONFIGURED" && echo '기존 암호 유지' || echo '최초 로그인 화면에서 설정 (get_pairing_url.sh 링크로 접속)'; } )"
else
    info "접속 암호: 사용 안 함 (Orca 페어링만)"
fi
if "$PAIRING_OUTPUT"; then
    info "페어링 링크: 스택 출력에 포함 (서버 설치 완료까지 대기, 새 스택은 약 5~10분 추가)"
else
    info "페어링 링크: 스택 출력에 넣지 않음 (get_pairing_url.sh로 조회)"
fi
if [ -n "$ATTACH_TO" ]; then
    info "과금 리소스: CloudFront(+Function/KeyValueStore), Secrets Manager, Lambda (EC2·ALB는 호스트 것을 함께 씀)"
else
    info "과금 리소스: EC2, EBS 100GB, NAT Gateway(새 VPC), ALB, CloudFront(+Function/KeyValueStore), VPC 엔드포인트, Secrets Manager"
fi
echo "-------------------------------------------"
if ! "$ASSUME_YES"; then
    read -r -p "  배포 시작? (y/n) [y]: " CONFIRM
    [[ "${CONFIRM:-y}" =~ ^[Yy]$ ]] || { echo "취소했습니다."; exit 0; }
fi

# -------------------------------------------------------
# CDK 배포
# -------------------------------------------------------
cd "$CDK_DIR"
npm install --quiet --no-fund --no-audit

if ! aws cloudformation describe-stacks --stack-name CDKToolkit --region "$REGION" >/dev/null 2>&1; then
    echo "  CDK bootstrap: aws://$ACCOUNT_ID/$REGION"
    npx cdk bootstrap "aws://$ACCOUNT_ID/$REGION"
fi

CDK_CONTEXT=(-c "stackName=$STACK_NAME")
if [ -n "$ATTACH_TO" ]; then
    CDK_CONTEXT+=(-c "attachTo=$ATTACH_TO" -c "hostInstanceId=$HOST_INSTANCE_ID" -c "hostVpcId=$HOST_VPC_ID"
        -c "hostListenerArn=$HOST_LISTENER_ARN" -c "hostAlbDnsName=$HOST_ALB_DNS"
        -c "hostAlbSecurityGroupId=$HOST_ALB_SG" -c "hostInstanceSecurityGroupId=$HOST_INSTANCE_SG"
        -c "hostRoleName=$HOST_ROLE")
fi
if [ -n "$EXISTING_VPC_ID" ]; then
    CDK_CONTEXT+=(-c useExistingVpc=true -c "vpcId=$EXISTING_VPC_ID")
fi
"$SKIP_VPC_ENDPOINTS" && CDK_CONTEXT+=(-c skipVpcEndpoints=true)
"$PASSWORD_GATE" || CDK_CONTEXT+=(-c passwordGate=false)
[ -n "$ROLE_NAME_SUFFIX" ] && CDK_CONTEXT+=(-c "roleNameSuffix=$ROLE_NAME_SUFFIX")
# 배포할 때마다 서버에서 현재 페어링 링크를 다시 읽도록 값을 바꿔 넘깁니다.
if "$PAIRING_OUTPUT"; then
    CDK_CONTEXT+=(-c "pairingRefresh=$(date +%s)")
else
    CDK_CONTEXT+=(-c pairingOutput=false)
fi

CDK_PARAMS=()
if [ -z "$ATTACH_TO" ]; then
    CDK_PARAMS+=(
        --parameters "InstanceType=$INSTANCE_TYPE"
        --parameters "CloudFrontPrefixListId=$CF_PREFIX_LIST"
        --parameters "VpcName=$VPC_NAME"
    )
fi
# OrcaVersion은 최초 설치 버전입니다. 기존 스택에서 값을 바꾸면 UserData 변경으로
# 인스턴스가 재시작되지만 이미 끝난 부트스트랩은 다시 실행되지 않으므로, 명시했을 때만 넘깁니다.
# (--attach 스택은 값을 바꾸면 호스트를 재부팅 없이 그 버전으로 업그레이드합니다.)
[ -n "$ORCA_VERSION" ] && CDK_PARAMS+=(--parameters "OrcaVersion=$ORCA_VERSION")

# cdk-outputs.json에는 페어링 링크가 들어가므로 본인만 읽을 수 있게 만듭니다.
OUTPUTS_FILE="$SCRIPT_DIR/cdk-outputs.json"
(umask 077 && touch "$OUTPUTS_FILE" && chmod 600 "$OUTPUTS_FILE" &&
    npx cdk deploy "$STACK_NAME" "${CDK_CONTEXT[@]}" ${CDK_PARAMS[@]+"${CDK_PARAMS[@]}"} \
        --require-approval never \
        --outputs-file "$OUTPUTS_FILE")
chmod 600 "$OUTPUTS_FILE"

PASSWORD_SET_NOW=false
if "$PASSWORD_GATE" && [ -n "$WEB_PASSWORD" ]; then
    PASSWORD_SET_NOW=true
    # printf는 셸 내장 명령이라 암호가 프로세스 인자로 노출되지 않습니다.
    printf '%s\n' "$WEB_PASSWORD" | bash "$SCRIPT_DIR/set_password.sh" \
        --region "$REGION" --stack-name "$STACK_NAME" --password-stdin
    unset WEB_PASSWORD
fi

# -------------------------------------------------------
# 결과
# -------------------------------------------------------
output() {
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
STACK_ARG=""
[ "$STACK_NAME" = OrcaServerStack ] || STACK_ARG=" --stack-name $STACK_NAME"
echo ""
echo "=============================================="
echo " 배포 완료"
echo "=============================================="
info "CloudFront URL : $(output CloudFrontURL)"
info "Instance ID    : $(output InstanceId)"
info "Orca 버전      : v$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Parameters[?ParameterKey=='OrcaVersion'].ParameterValue | [0]" --output text)"
[ -n "$ATTACH_TO" ] && info "호스트 스택    : $ATTACH_TO (변경 없음, 이 스택을 지우면 Orca만 제거)"
info "ALB (직접 차단): $(output PublicALBEndpoint)"
info "SSM 접속       : $(output SSMAccess)"
echo ""
PAIR_CODE=$(output PairingCode)
if [[ "$PAIR_CODE" == orca://pair* ]]; then
    LINK=$(output PairingWebLink)
    SETUP_CODE=$(output GateSetupCode)
    # 스택 출력 값은 ASCII입니다(CloudFormation이 커스텀 리소스 속성의 한글을 ?로 바꿈).
    # 방금 암호를 정했다면 출력에 담긴 설정 코드는 더 쓰이지 않습니다.
    if "$PASSWORD_SET_NOW"; then
        LINK="${LINK%%&gate-setup=*}"
        SETUP_CODE="none (just set)"
    fi
    echo "  접속 정보 (스택 출력 PairingWebLink / GateSetupCode / PairingCode). 서버 접근 권한이니 공유하지 마세요."
    echo ""
    echo "  [1] 전체 링크 (이 링크 하나로 암호 설정/로그인 + 페어링):"
    echo "  $LINK"
    echo ""
    echo "  [2] 링크가 잘리거나 열리지 않으면 아래 값을 직접 입력하세요."
    info "  접속 주소  : $(output CloudFrontURL)/"
    if "$PASSWORD_GATE"; then
        if [[ "$SETUP_CODE" == none* ]]; then
            info "  설정 코드  : 없음 (접속 암호가 이미 설정됨 - 로그인 화면에 암호 입력)"
        else
            info "  설정 코드  : $SETUP_CODE   (접속 암호 설정 화면에 입력, 1회용)"
        fi
    fi
    info "  페어링 코드: $PAIR_CODE"
    info "               (Orca 연결 화면의 Pairing URL or code 칸에 붙여 넣고 Connect)"
    if "$PASSWORD_GATE" && [[ "$SETUP_CODE" != none* ]]; then
        echo ""
        echo "  첫 화면에서 새 암호와 확인 암호를 입력하면 적용 후 페어링까지 이어집니다."
        echo "  (변경: bash set_password.sh, 분실: bash set_password.sh --reset-ui)"
    fi
    echo ""
    echo "  서버를 재시작한 뒤 링크가 바뀌었으면 bash get_pairing_url.sh --region $REGION$STACK_ARG 으로 다시 받으세요."
else
    if "$PAIRING_OUTPUT"; then
        echo "  스택 출력으로 페어링 링크를 받지 못했습니다 (서버 응답: $PAIR_CODE)."
    else
        echo "  1) 서버 설치 완료까지 약 5~10분 기다립니다 (진행: SSM 접속 후 sudo tail -f /var/log/user-data.log)."
    fi
    echo "  페어링 링크를 받아 브라우저로 엽니다:  bash get_pairing_url.sh --region $REGION$STACK_ARG"
    if "$PASSWORD_GATE"; then
        echo "  암호를 아직 정하지 않았다면 첫 화면에서 새 암호와 확인 암호를 입력합니다."
        echo "  이미 정했다면 로그인 화면에 입력합니다 (변경: bash set_password.sh, 분실: bash set_password.sh --reset-ui)."
    fi
fi
