#!/bin/bash
# 배포 스크립트 둘(deploy_orca.sh, deploy_orca_tf.sh)이 함께 쓰는 대화형 안내.
# 직접 실행하는 파일이 아니라 두 스크립트가 source로 불러 쓴다. 번호 메뉴로 리전, VPC(새로 만들기 또는 계정의 기존 VPC),
# 인스턴스 타입을 고르게 하고, 기존 VPC는 서브넷과 SSM 엔드포인트를 배포 전에 확인한다.
# ec2_vscode의 deploy_vscode.sh와 같은 방식이다. AWS는 읽기만 한다(describe-*).
# 결과는 GUIDE_로 시작하는 변수에 둔다. 부르는 스크립트의 set -euo pipefail 아래에서 동작한다.

GUIDE_REGIONS=(
    "ap-northeast-2:서울"
    "ap-northeast-1:도쿄"
    "ap-northeast-3:오사카"
    "ap-southeast-1:싱가포르"
    "ap-southeast-2:시드니"
    "ap-south-1:뭄바이"
    "us-east-1:버지니아 북부"
    "us-east-2:오하이오"
    "us-west-2:오레곤"
    "eu-west-1:아일랜드"
    "eu-central-1:프랑크푸르트"
    "eu-west-2:런던"
)

# 전용 서버 스택(infra-cdk/lib/orca-stack.ts)이 받는 인스턴스 타입이다. 목록이 같아야 한다
# (bash tests/run-all.sh structure가 검사). Terraform 배포는 목록 밖의 타입도 받는다.
GUIDE_INSTANCE_TYPES=(
    "r6g.xlarge:ARM64 Graviton, 4 vCPU, 32GB"
    "r6g.2xlarge:ARM64 Graviton, 8 vCPU, 64GB"
    "r7g.xlarge:ARM64 Graviton, 4 vCPU, 32GB"
    "r7g.2xlarge:ARM64 Graviton, 8 vCPU, 64GB"
    "m6g.xlarge:ARM64 Graviton, 4 vCPU, 16GB"
    "m6g.2xlarge:ARM64 Graviton, 8 vCPU, 32GB"
    "m7g.xlarge:ARM64 Graviton, 4 vCPU, 16GB"
    "m7g.2xlarge:ARM64 Graviton, 8 vCPU, 32GB"
    "t4g.xlarge:ARM64 Graviton, 4 vCPU, 16GB"
    "t4g.2xlarge:ARM64 Graviton, 8 vCPU, 32GB"
    "r7i.xlarge:x86_64 Intel, 4 vCPU, 32GB"
    "m7i.xlarge:x86_64 Intel, 4 vCPU, 16GB"
    "m7i.2xlarge:x86_64 Intel, 8 vCPU, 32GB"
    "t3.xlarge:x86_64 Intel, 4 vCPU, 16GB"
    "t3.2xlarge:x86_64 Intel, 8 vCPU, 32GB"
)

# 서브넷을 CDK가 기존 VPC를 읽을 때(Vpc.fromLookup)와 같은 기준으로 나눈다. 차례대로:
# aws-cdk:subnet-type 태그, 공인 IP 자동 할당, IGW로 가는 경로, NAT로 가는 기본 경로,
# Transit Gateway로 가는 기본 경로, 아무것도 없으면 격리. 라우팅 테이블은 서브넷에 연결된 것,
# 없으면 VPC의 기본(main) 테이블을 본다. 입력은 fd 3(describe-subnets)과 fd 4(describe-route-tables).
GUIDE_CLASSIFY_PY='
import json, os

subnets = json.load(os.fdopen(3)).get("Subnets", [])
tables = json.load(os.fdopen(4)).get("RouteTables", [])
main = next((t for t in tables if any(a.get("Main") for a in t.get("Associations", []))), None)


def routes_of(subnet_id):
    table = next((t for t in tables if any(a.get("SubnetId") == subnet_id for a in t.get("Associations", []))), None)
    return (table or main or {}).get("Routes", [])


def tag(subnet, key):
    return next((t["Value"] for t in subnet.get("Tags", []) if t["Key"] == key), None)


def kind(subnet):
    tagged = tag(subnet, "aws-cdk:subnet-type")
    if tagged:
        return tagged
    if subnet.get("MapPublicIpOnLaunch"):
        return "Public"
    routes = routes_of(subnet["SubnetId"])
    if any((r.get("GatewayId") or "").startswith("igw-") for r in routes):
        return "Public"
    if any(r.get("NatGatewayId") and r.get("DestinationCidrBlock") == "0.0.0.0/0" for r in routes):
        return "Private"
    if any(r.get("TransitGatewayId") and r.get("DestinationCidrBlock") == "0.0.0.0/0" for r in routes):
        return "Private"
    return "Isolated"


order = {"Public": 0, "Private": 1, "Isolated": 2}
rows = sorted(
    ((kind(s), s["AvailabilityZone"], s["SubnetId"], (tag(s, "Name") or "-").replace("\t", " ")) for s in subnets),
    key=lambda row: (order.get(row[0], 3), row[1], row[2]),
)
for row in rows:
    print("\t".join(row))
'

# 한 줄을 묻는다. 답은 GUIDE_ANSWER에 둔다. 입력이 끝났으면(EOF) 빈 값이고, 빈 값은 기본값을 뜻한다.
guide_ask() {
    GUIDE_ANSWER=""
    read -r -p "$1" GUIDE_ANSWER || true
}

# 리전을 고른다. <지금 값>. 결과: GUIDE_REGION
guide_region() {
    local current="$1" i code mark
    echo ""
    echo "  [리전] 배포할 리전을 고릅니다."
    for i in "${!GUIDE_REGIONS[@]}"; do
        code="${GUIDE_REGIONS[$i]%%:*}"
        mark=""
        if [ "$code" = "$current" ]; then mark="  (지금 값)"; fi
        printf '    %2d) %-16s %s%s\n' $((i + 1)) "$code" "${GUIDE_REGIONS[$i]#*:}" "$mark"
    done
    while true; do
        guide_ask "  번호 또는 리전 코드 [$current]: "
        if [ -z "$GUIDE_ANSWER" ]; then
            GUIDE_REGION="$current"
            break
        elif [[ "$GUIDE_ANSWER" =~ ^[0-9]+$ ]] && [ "$GUIDE_ANSWER" -ge 1 ] && [ "$GUIDE_ANSWER" -le "${#GUIDE_REGIONS[@]}" ]; then
            GUIDE_REGION="${GUIDE_REGIONS[$((GUIDE_ANSWER - 1))]%%:*}"
            break
        elif [[ "$GUIDE_ANSWER" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]]; then
            GUIDE_REGION="$GUIDE_ANSWER"
            break
        fi
        echo "  [!] 목록의 번호나 리전 코드(예: ap-northeast-2)를 입력합니다."
    done
    echo "  리전: $GUIDE_REGION"
}

# 새 VPC를 만들지 기존 VPC를 쓸지 고른다. <리전> <새 VPC 이름의 기본값> <새 VPC 설명>
# 결과: GUIDE_VPC_ID(새로 만들면 빈 값), GUIDE_VPC_NAME. 기존 VPC를 고르면 guide_inspect_vpc의 결과도 남는다.
guide_vpc() {
    local region="$1" default_name="$2" description="$3"
    GUIDE_VPC_ID=""
    GUIDE_VPC_NAME="$default_name"
    echo ""
    echo "  [VPC] 새 VPC를 만들지 기존 VPC를 쓸지 고릅니다."
    echo "     1) 새 VPC 생성 ($description)"
    echo "     2) 기존 VPC 사용 (이 계정의 $region VPC 목록에서 고름)"
    while true; do
        guide_ask "  번호 [1]: "
        case "${GUIDE_ANSWER:-1}" in
            1)
                guide_ask "  새 VPC의 Name 태그 [$default_name]: "
                GUIDE_VPC_NAME="${GUIDE_ANSWER:-$default_name}"
                echo "  VPC: 새로 만듦 ($GUIDE_VPC_NAME)"
                return 0
                ;;
            2)
                # 쓸 수 있는 VPC를 고르지 못하면 처음 질문으로 돌아간다.
                if guide_pick_vpc "$region"; then
                    echo "  VPC: 기존 VPC 사용 ($GUIDE_VPC_ID)"
                    return 0
                fi
                echo "     1) 새 VPC 생성   2) 기존 VPC 사용"
                ;;
            *) echo "  [!] 1 또는 2를 입력합니다." ;;
        esac
    done
}

# 계정의 VPC 목록에서 하나를 고르고 서브넷을 확인한다. <리전>. 쓸 수 있는 VPC를 골랐으면 0.
guide_pick_vpc() {
    local region="$1" rows id cidr name note i=0 chosen=""
    local -a ids=()
    rows=$(aws ec2 describe-vpcs --region "$region" --output json | python3 -I -c '
import json, sys
for vpc in json.load(sys.stdin).get("Vpcs", []):
    name = next((t["Value"] for t in vpc.get("Tags", []) if t["Key"] == "Name"), "(이름 없음)")
    print("\t".join([vpc["VpcId"], vpc.get("CidrBlock", "?"), name.replace("\t", " "), "기본 VPC" if vpc.get("IsDefault") else "-"]))
') || { echo "  [!] VPC 목록을 읽지 못했습니다."; return 1; }
    if [ -z "$rows" ]; then
        echo "  [!] $region 리전에 VPC가 없습니다."
        return 1
    fi
    echo ""
    echo "  $region 리전의 VPC:"
    while IFS=$'\t' read -r id cidr name note; do
        i=$((i + 1))
        ids+=("$id")
        if [ "$note" = "-" ]; then note=""; else note="  [$note]"; fi
        printf '    %2d) %-22s %-18s %s%s\n' "$i" "$id" "$cidr" "$name" "$note"
    done <<<"$rows"
    guide_ask "  VPC 번호 또는 VPC ID: "
    if [[ "$GUIDE_ANSWER" =~ ^[0-9]+$ ]] && [ "$GUIDE_ANSWER" -ge 1 ] && [ "$GUIDE_ANSWER" -le "${#ids[@]}" ]; then
        chosen="${ids[$((GUIDE_ANSWER - 1))]}"
    else
        for id in "${ids[@]}"; do
            if [ "$id" = "$GUIDE_ANSWER" ]; then chosen="$id"; fi
        done
    fi
    if [ -z "$chosen" ]; then
        echo "  [!] 목록에 없는 값입니다."
        return 1
    fi
    guide_inspect_vpc "$region" "$chosen" || return 1
    if ! "$GUIDE_VPC_OK"; then
        return 1
    fi
    GUIDE_VPC_ID="$chosen"
}

# 기존 VPC의 서브넷을 분류해 보여 주고 이 배포에 쓸 수 있는지 판단한다. <리전> <VPC ID>
# 결과: GUIDE_VPC_OK(true|false), GUIDE_PUBLIC_SUBNETS(가용 영역마다 하나, 쉼표 목록),
#       GUIDE_PRIVATE_SUBNETS(쉼표 목록), GUIDE_PRIVATE_ROWS("서브넷 영역 이름" 배열)
# AWS를 읽지 못하면 1을 돌려준다.
guide_inspect_vpc() {
    local region="$1" vpc="$2" subnets tables rows kind az id name label public_azs=" " zones=0
    GUIDE_VPC_OK=false
    GUIDE_PUBLIC_SUBNETS=""
    GUIDE_PRIVATE_SUBNETS=""
    GUIDE_PRIVATE_ROWS=()
    subnets=$(aws ec2 describe-subnets --region "$region" --filters "Name=vpc-id,Values=$vpc" --output json) \
        || { echo "  [!] $vpc 의 서브넷을 읽지 못했습니다."; return 1; }
    tables=$(aws ec2 describe-route-tables --region "$region" --filters "Name=vpc-id,Values=$vpc" --output json) \
        || { echo "  [!] $vpc 의 라우팅 테이블을 읽지 못했습니다."; return 1; }
    rows=$(python3 -I -c "$GUIDE_CLASSIFY_PY" 3<<<"$subnets" 4<<<"$tables") \
        || { echo "  [!] $vpc 의 서브넷을 분류하지 못했습니다."; return 1; }

    echo ""
    echo "  $vpc 의 서브넷 (CDK가 기존 VPC를 읽을 때와 같은 기준으로 나눔):"
    while IFS=$'\t' read -r kind az id name; do
        [ -n "$kind" ] || continue
        case "$kind" in
            Public)
                label="퍼블릭"
                # ALB에는 가용 영역마다 서브넷 하나만 붙일 수 있다.
                if [[ "$public_azs" != *" $az "* ]]; then
                    public_azs="$public_azs$az "
                    zones=$((zones + 1))
                    GUIDE_PUBLIC_SUBNETS="${GUIDE_PUBLIC_SUBNETS:+$GUIDE_PUBLIC_SUBNETS,}$id"
                fi
                ;;
            Private)
                label="프라이빗"
                GUIDE_PRIVATE_SUBNETS="${GUIDE_PRIVATE_SUBNETS:+$GUIDE_PRIVATE_SUBNETS,}$id"
                GUIDE_PRIVATE_ROWS+=("$id $az $name")
                ;;
            *) label="격리" ;;
        esac
        printf '    %-26s %-18s %s  %s\n' "$id" "$az" "$label" "$name"
    done <<<"$rows"
    if [ -z "$rows" ]; then
        echo "    (서브넷 없음)"
    fi

    if [ "$zones" -ge 2 ] && [ -n "$GUIDE_PRIVATE_SUBNETS" ]; then
        GUIDE_VPC_OK=true
        echo "  ALB는 퍼블릭 서브넷에, EC2는 프라이빗 서브넷에 둡니다."
        return 0
    fi
    if [ "$zones" -lt 2 ]; then
        echo "  [!] 이 VPC는 쓸 수 없습니다. ALB에는 가용 영역 둘 이상의 퍼블릭 서브넷이 필요합니다 (지금 ${zones}개 영역)."
    fi
    if [ -z "$GUIDE_PRIVATE_SUBNETS" ]; then
        echo "  [!] 이 VPC는 쓸 수 없습니다. EC2를 둘 프라이빗 서브넷(NAT나 Transit Gateway로 나가는 기본 경로가 있는 것)이 필요합니다."
    fi
}

# EC2를 둘 프라이빗 서브넷을 고른다(guide_inspect_vpc 뒤에 부른다). 결과: GUIDE_INSTANCE_SUBNET
guide_instance_subnet() {
    local i
    GUIDE_INSTANCE_SUBNET="${GUIDE_PRIVATE_SUBNETS%%,*}"
    if [ "${#GUIDE_PRIVATE_ROWS[@]}" -le 1 ]; then
        return 0
    fi
    echo ""
    echo "  EC2를 둘 프라이빗 서브넷을 고릅니다."
    for i in "${!GUIDE_PRIVATE_ROWS[@]}"; do
        printf '    %2d) %s\n' $((i + 1)) "${GUIDE_PRIVATE_ROWS[$i]}"
    done
    while true; do
        guide_ask "  번호 [1]: "
        if [ -z "$GUIDE_ANSWER" ]; then
            break
        elif [[ "$GUIDE_ANSWER" =~ ^[0-9]+$ ]] && [ "$GUIDE_ANSWER" -ge 1 ] && [ "$GUIDE_ANSWER" -le "${#GUIDE_PRIVATE_ROWS[@]}" ]; then
            GUIDE_INSTANCE_SUBNET="${GUIDE_PRIVATE_ROWS[$((GUIDE_ANSWER - 1))]%% *}"
            break
        fi
        echo "  [!] 목록의 번호를 입력합니다."
    done
}

# 기존 VPC에 SSM 엔드포인트가 이미 있는지 본다. <리전> <VPC ID>
# 하나라도 있으면 새로 만들지 않는다. 같은 서비스의 엔드포인트를 한 VPC에 둘 만들면 프라이빗 DNS가 충돌해
# 배포가 실패한다. 처음 배포할 때만 부른다. 이미 배포한 뒤에는 그 배포가 만든 엔드포인트가 여기에 잡힌다.
# 결과: GUIDE_SKIP_ENDPOINTS(true|false)
guide_ssm_endpoints() {
    local region="$1" vpc="$2" found id count=0
    GUIDE_SKIP_ENDPOINTS=false
    found=$(aws ec2 describe-vpc-endpoints --region "$region" \
        --filters "Name=vpc-id,Values=$vpc" "Name=vpc-endpoint-state,Values=available,pending" \
        --query "VpcEndpoints[?ends_with(ServiceName, '.ssm') || ends_with(ServiceName, '.ssmmessages') || ends_with(ServiceName, '.ec2messages')].VpcEndpointId" \
        --output text 2>/dev/null) || {
        echo "  [!] $vpc 의 VPC 엔드포인트를 확인하지 못했습니다. SSM 엔드포인트가 이미 있으면 --skip-vpc-endpoints 를 줍니다."
        return 0
    }
    for id in $found; do
        # 엔드포인트가 없으면 AWS CLI가 빈 값이나 None을 돌려준다.
        if [ "$id" != None ]; then
            count=$((count + 1))
        fi
    done
    if [ "$count" -gt 0 ]; then
        GUIDE_SKIP_ENDPOINTS=true
        echo "  이 VPC에는 SSM 엔드포인트가 이미 있습니다 (${count}개). 새로 만들지 않습니다."
    fi
}

# 목록에 있는 타입 이름을 공백으로 이어 돌려준다.
guide_instance_names() {
    local item names=""
    for item in "${GUIDE_INSTANCE_TYPES[@]}"; do
        names="$names ${item%%:*}"
    done
    printf '%s' "${names# }"
}

# <타입>이 목록에 있으면 0.
guide_instance_in_list() {
    [[ " $(guide_instance_names) " == *" $1 "* ]]
}

# <리전> <타입>의 RPM 아키텍처(aarch64 또는 x86_64)를 돌려준다. 목록, EC2 API, 이름의 차례로 판단한다.
guide_instance_arch() {
    local region="$1" type="$2" item archs
    for item in "${GUIDE_INSTANCE_TYPES[@]}"; do
        if [ "${item%%:*}" = "$type" ]; then
            if [[ "${item#*:}" == ARM64* ]]; then echo aarch64; else echo x86_64; fi
            return 0
        fi
    done
    archs=$(aws ec2 describe-instance-types --region "$region" --instance-types "$type" \
        --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text 2>/dev/null || true)
    if [[ " $archs " == *arm64* ]]; then
        echo aarch64
    elif [[ " $archs " == *x86_64* ]]; then
        echo x86_64
    else
        case "$type" in
            *g.*|*gd.*|*gn.*) echo aarch64 ;;
            *) echo x86_64 ;;
        esac
    fi
}

# 인스턴스 타입을 고른다. <리전> <기본값> <목록 밖의 타입도 받는지 true|false>. 결과: GUIDE_INSTANCE_TYPE
guide_instance_type() {
    local region="$1" default="$2" allow_custom="$3" i type mark offered names candidate
    names=$(guide_instance_names)
    # 리전에서 제공하지 않는 타입을 고르면 배포가 EC2 생성 단계에서 실패한다. 조회하지 못하면 표시하지 않는다.
    offered=$(aws ec2 describe-instance-type-offerings --region "$region" --location-type region \
        --filters "Name=instance-type,Values=${names// /,}" \
        --query 'InstanceTypeOfferings[].InstanceType' --output text 2>/dev/null || true)
    offered=" $(tr '\t\n' '  ' <<<"$offered") "
    echo ""
    echo "  [인스턴스 타입] EC2 인스턴스 타입을 고릅니다 (ARM64 Graviton 권장)."
    for i in "${!GUIDE_INSTANCE_TYPES[@]}"; do
        type="${GUIDE_INSTANCE_TYPES[$i]%%:*}"
        mark=""
        if [ "$type" = "$default" ]; then mark="  (기본값)"; fi
        if [ -n "${offered// /}" ] && [[ "$offered" != *" $type "* ]]; then mark="  (이 리전에서 제공하지 않음)"; fi
        printf '    %2d) %-13s %s%s\n' $((i + 1)) "$type" "${GUIDE_INSTANCE_TYPES[$i]#*:}" "$mark"
    done
    if "$allow_custom"; then
        echo "     0) 직접 입력"
    fi
    while true; do
        guide_ask "  번호 또는 타입 [$default]: "
        candidate="${GUIDE_ANSWER:-$default}"
        if [ "$candidate" = 0 ] && "$allow_custom"; then
            guide_ask "  인스턴스 타입: "
            candidate="$GUIDE_ANSWER"
            if [ -z "$candidate" ]; then candidate="$default"; fi
        elif [[ "$candidate" =~ ^[0-9]+$ ]]; then
            if [ "$candidate" -ge 1 ] && [ "$candidate" -le "${#GUIDE_INSTANCE_TYPES[@]}" ]; then
                candidate="${GUIDE_INSTANCE_TYPES[$((candidate - 1))]%%:*}"
            else
                echo "  [!] 목록의 번호를 입력합니다."
                continue
            fi
        fi
        if guide_instance_in_list "$candidate"; then
            if [ -n "${offered// /}" ] && [[ "$offered" != *" $candidate "* ]]; then
                echo "  [!] $candidate 은 $region 리전에서 제공하지 않습니다. 다른 타입을 고릅니다."
                continue
            fi
        elif ! "$allow_custom"; then
            echo "  [!] $candidate 은 이 스택이 받는 목록에 없습니다. 목록에서 고릅니다."
            continue
        elif ! aws ec2 describe-instance-type-offerings --region "$region" --location-type region \
            --filters "Name=instance-type,Values=$candidate" \
            --query 'InstanceTypeOfferings[].InstanceType' --output text 2>/dev/null | grep -qxF -- "$candidate"; then
            echo "  [!] $candidate 은 $region 리전에 없는 타입입니다."
            continue
        fi
        GUIDE_INSTANCE_TYPE="$candidate"
        break
    done
    echo "  인스턴스 타입: $GUIDE_INSTANCE_TYPE"
}
