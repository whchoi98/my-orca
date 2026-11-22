#!/bin/bash
# 세션을 시작할 때 프로젝트 맥락을 알려 준다.
# SessionStart의 stdout은 Claude의 맥락에 들어가므로 짧고 사실만 적는다.
# AWS를 부르지 않는다(느리고 자격 증명이 필요하다). 로컬 파일과 이 서버의 상태에서 알 수 있는 것만 낸다.
# 스택 출력, cdk-outputs.json, 로그의 페어링 줄은 읽지 않는다. 링크와 설정 코드가 맥락에 들어가면 안 된다.

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0

echo "=== 프로젝트 맥락 ==="
echo "프로젝트: my-orca (Orca headless 서버를 CloudFront와 ALB 뒤의 Private EC2에 올리는 프로젝트. AWS CDK와 Terraform 두 가지로 배포)"
echo "규칙: 배포, 업그레이드, 암호 변경, 삭제는 차이를 보여 주고 승인을 받은 뒤 실행합니다. 페어링 링크, 설정 코드, 접속 암호는 출력하지 않습니다."

DEFAULT_VERSION=$(grep -A3 "CfnParameter(this, 'OrcaVersion'" infra-cdk/lib/orca-attach-stack.ts 2>/dev/null \
    | sed -n "s/.*default: '\([0-9.]*\)'.*/\1/p" | head -1)
[ -n "$DEFAULT_VERSION" ] && echo "코드의 기본 Orca 버전: $DEFAULT_VERSION"

# 이 서버에 Orca가 설치되어 있으면 --attach 스택의 대상이 이 서버일 수 있다
if command -v rpm >/dev/null 2>&1 && INSTALLED=$(rpm -q --qf '%{VERSION}' orca-ide 2>/dev/null); then
    STATE=$(systemctl is-active orca-serve 2>/dev/null || true)
    echo "이 서버에 설치된 Orca: $INSTALLED (orca-serve: ${STATE:-unknown}). --attach 스택의 배포와 업그레이드는 이 서버의 orca-serve를 재시작합니다. code-server는 재시작하지 않습니다."
fi

if git rev-parse --git-dir >/dev/null 2>&1; then
    LAST_COMMIT=$(git log -1 --format="%h %s (%cr)" 2>/dev/null)
    [ -n "$LAST_COMMIT" ] && echo "마지막 커밋: $LAST_COMMIT"
    BRANCH=$(git branch --show-current 2>/dev/null)
    [ -n "$BRANCH" ] && echo "브랜치: $BRANCH"
    CHANGES=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [ "${CHANGES:-0}" -gt 0 ] && echo "커밋하지 않은 변경: ${CHANGES}개"
else
    echo "git 저장소가 아닙니다. 변경 기록이 남지 않습니다."
fi

# 작업 준비 상태
[ -d infra-cdk/node_modules ] || echo "경고: infra-cdk/node_modules 가 없습니다. bash scripts/setup.sh 가 npm ci를 실행합니다."

# 문서 상태
CLAUDE_COUNT=$(find . -name "CLAUDE.md" -not -path "./.git/*" -not -path "*/node_modules/*" -not -path "./orca/*" 2>/dev/null | wc -l | tr -d ' ')
ADR_COUNT=$(find docs/decisions -name 'ADR-*.md' 2>/dev/null | wc -l | tr -d ' ')
RUNBOOK_COUNT=$(find docs/runbooks -name '*.md' -not -name '.template.md' 2>/dev/null | wc -l | tr -d ' ')
echo "CLAUDE.md ${CLAUDE_COUNT}개, ADR ${ADR_COUNT}개, 런북 ${RUNBOOK_COUNT}개"

echo "====================="
