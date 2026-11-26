#!/bin/bash
# Orca 업그레이드 (기존 서버에 추가한 --attach 스택, 기본 OrcaOnVscodeStack)
#
# 스택의 OrcaVersion과 GitHub 최신 릴리스(또는 --version)를 비교해, 새 버전이면
# deploy_orca.sh --attach <호스트 스택> --orca-version <버전> 으로 다시 배포합니다.
# 커스텀 리소스가 SSM Run Command로 install_orca.sh를 다시 실행해 RPM을 바꾸고 orca-serve만
# 재시작합니다 (재부팅·dnf update·다른 서비스 재시작 없음, ~/.config/orca와 접속 암호 유지).
# CDK 배포가 끝나면 마지막 화면에 접속 안내(전체 링크, 설정 코드, 페어링 코드)가 나옵니다.
#
# 사용법:
#   bash upgrade_orca.sh                     # 최신 릴리스로 업그레이드 (확인 후 진행)
#   bash upgrade_orca.sh --yes               # 확인 없이 진행
#   bash upgrade_orca.sh --version 1.4.260   # 지정한 버전으로
#   bash upgrade_orca.sh --check             # 버전만 비교하고 끝냄 (배포하지 않음)
#   옵션: --region <region> (기본: AWS_REGION 또는 ap-northeast-2), --stack-name <name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_NAME="${STACK_NAME:-OrcaOnVscodeStack}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-2}}"
TARGET=""
CHECK_ONLY=false
ASSUME_YES=false

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "  $*"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version|--orca-version) TARGET="${2#v}"; shift 2 ;;
        --check) CHECK_ONLY=true; shift ;;
        --region) REGION="$2"; shift 2 ;;
        --stack-name) STACK_NAME="$2"; shift 2 ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        --help|-h) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "알 수 없는 인자: $1 (--help 참고)" ;;
    esac
done

for cmd in aws curl python3; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd 명령어가 필요합니다."
done

# 스택 파라미터 OrcaVersion이 서버에 설치된 버전입니다 (설치가 실패하면 배포가 롤백되어 값이 그대로 남음).
read -r CURRENT HOST_STACK < <(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --output text --query "[Stacks[0].Parameters[?ParameterKey=='OrcaVersion'].ParameterValue | [0], Stacks[0].Outputs[?OutputKey=='HostStack'].OutputValue | [0]]" \
    2>/dev/null) || true
[ -n "${CURRENT:-}" ] || die "$STACK_NAME ($REGION) 스택을 찾지 못했습니다 (--stack-name, --region 확인)."
[ "$CURRENT" != None ] || die "$STACK_NAME 에 OrcaVersion 파라미터가 없습니다 (Orca 스택이 아님)."
if [ -z "${HOST_STACK:-}" ] || [ "$HOST_STACK" = None ]; then
    die "$STACK_NAME 은 --attach 스택이 아닙니다. 전용 서버 스택은 docs/usage.md의 'Orca 업그레이드'에 있는 수동 절차를 따르세요."
fi

if [ -n "$TARGET" ]; then
    SOURCE="지정한 버전"
else
    TARGET=$(curl -fsSL --retry 3 https://api.github.com/repos/stablyai/orca/releases/latest \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))') \
        || die "GitHub 최신 릴리스를 조회하지 못했습니다. --version 으로 지정하세요."
    SOURCE="GitHub 최신 릴리스"
fi
[[ "$TARGET" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "버전 형식이 아닙니다: $TARGET (예: 1.4.260)"

echo "=============================================="
echo " Orca 업그레이드 ($STACK_NAME → 호스트 $HOST_STACK, $REGION)"
echo "=============================================="
info "현재 버전: v$CURRENT"
info "목표 버전: v$TARGET ($SOURCE)"
echo ""

if [ "$TARGET" = "$CURRENT" ]; then
    info "이미 v$CURRENT 입니다. 업그레이드할 것이 없습니다."
    info "접속 안내 다시 보기: bash get_pairing_url.sh --region $REGION --stack-name $STACK_NAME"
    exit 0
fi
if [ "$(printf '%s\n%s\n' "$CURRENT" "$TARGET" | sort -V | head -n 1)" = "$TARGET" ]; then
    die "v$TARGET 은 현재 버전(v$CURRENT)보다 낮습니다. 이 스크립트는 낮은 버전으로 되돌리지 않습니다."
fi
if [ "$SOURCE" = "지정한 버전" ]; then
    curl -fsS --retry 3 -o /dev/null "https://api.github.com/repos/stablyai/orca/releases/tags/v${TARGET}" 2>/dev/null \
        || die "GitHub에서 v$TARGET 릴리스를 찾지 못했습니다 (버전 또는 네트워크 확인: https://github.com/stablyai/orca/releases)."
fi
if "$CHECK_ONLY"; then
    info "업그레이드 가능: v$CURRENT → v$TARGET"
    info "진행: bash upgrade_orca.sh --version $TARGET --region $REGION --stack-name $STACK_NAME"
    exit 0
fi
if ! "$ASSUME_YES"; then
    info "orca-serve가 재시작되어 열려 있는 Orca 웹 연결이 잠깐 끊깁니다 (터미널 데몬은 유지)."
    read -r -p "  v$CURRENT → v$TARGET 로 업그레이드할까요? [y/N]: " ANSWER || ANSWER=""
    case "$ANSWER" in
        y|Y|yes|YES) ;;
        *) info "취소했습니다."; exit 0 ;;
    esac
fi

# deploy_orca.sh가 RPM 자산을 확인하고 CDK로 배포한 뒤, 마지막에 버전과 접속 안내를 보여 줍니다.
exec bash "$SCRIPT_DIR/deploy_orca.sh" --attach "$HOST_STACK" --stack-name "$STACK_NAME" \
    --region "$REGION" --orca-version "$TARGET" --yes
