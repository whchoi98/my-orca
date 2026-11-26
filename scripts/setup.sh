#!/bin/bash
# 이 저장소에서 작업을 시작할 때 한 번 실행한다.
# 사용법: bash scripts/setup.sh
# AWS 리소스를 만들거나 바꾸지 않고 서버의 서비스도 건드리지 않는다. 로컬 도구를 확인하고 훅과 CDK 의존성만 준비한다.

set -e

cd "$(dirname "$0")/.."

echo "=== 작업 환경 준비 ==="

# 훅과 시험이 쓰는 도구
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq가 필요합니다 (훅이 이벤트 JSON을 읽는 데 씁니다)"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3가 필요합니다 (시험과 배포 스크립트가 씁니다)"; exit 1; }
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "ERROR: Bash 4 이상이 필요합니다 (지금 $BASH_VERSION)"; exit 1; }

# 배포에 쓰는 도구. 없어도 문서 작업과 시험은 할 수 있으므로 경고만 한다.
for tool in node npm curl session-manager-plugin aws; do
    command -v "$tool" >/dev/null 2>&1 || echo "WARNING: $tool 이 없습니다 (docs/onboarding.md의 사전 요구 사항)"
done
# Terraform은 그 경로(deploy_orca_tf.sh, infra-tf/)를 쓸 때만 필요하다.
command -v terraform >/dev/null 2>&1 || echo "참고: terraform 이 없습니다 (Terraform으로 배포하거나 bash infra-tf/run-tests.sh 를 실행할 때만 필요)"

chmod +x .claude/hooks/*.sh scripts/*.sh tests/run-all.sh tests/*/*.sh infra-tf/run-tests.sh infra-tf/scripts/*.sh
# 루트의 스크립트. deploy_guide.sh는 두 배포 스크립트가 source로 불러 쓰는 파일이라 실행 권한을 주지 않는다.
# 권한을 주면 git이 추적하는 권한과 달라져 받은 직후의 작업 트리가 변경으로 잡힌다.
for script in ./*.sh; do
    [ "$script" = ./deploy_guide.sh ] || chmod +x "$script"
done
echo "훅과 스크립트에 실행 권한을 줬습니다"

# git 훅(commit-msg, pre-commit)
if [ -d ".git" ]; then
    bash scripts/install-hooks.sh
else
    echo "git 저장소가 아니어서 git 훅은 설치하지 않았습니다 (git init 뒤에 bash scripts/install-hooks.sh)"
fi

# CDK 의존성. 잠금 파일대로만 설치한다.
if command -v npm >/dev/null 2>&1 && [ ! -d infra-cdk/node_modules ]; then
    npm ci --prefix infra-cdk --no-fund --no-audit
fi

echo "=== 준비 완료 ==="
echo "다음 순서:"
echo "  1. CLAUDE.md와 docs/onboarding.md를 읽습니다"
echo "  2. 코드 시험: npm test --prefix infra-cdk, bash infra-tf/run-tests.sh (Terraform이 있을 때)"
echo "  3. 하네스 시험: bash tests/run-all.sh"
echo "  4. 배포, 업그레이드, 삭제는 차이를 보여 주고 승인을 받은 뒤 실행합니다 (docs/deployment.md, docs/runbooks/upgrade-orca.md). Claude Code에서는 /install-orca 로 처음 설치를 안내받습니다"
