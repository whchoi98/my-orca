#!/bin/bash
# .claude/hooks/*.sh 와 .claude/settings.json 의 시험 (tests/run-all.sh가 source로 불러 실행한다)
# 실행기의 변수(TOTAL, PASSED, FAILED, SKIPPED, FAILURES)와 겹치지 않게 이 파일의 변수는 HK_로 시작한다.

# --- 있는지, 실행 권한, 문법 ---
for HK_NAME in check-doc-sync secret-scan session-context notify; do
    assert_file_exists "$HK_NAME.sh 있음" ".claude/hooks/$HK_NAME.sh"
    assert_file_executable "$HK_NAME.sh 실행 권한" ".claude/hooks/$HK_NAME.sh"
    assert_bash_syntax "$HK_NAME.sh bash 문법" ".claude/hooks/$HK_NAME.sh"
done

# --- settings.json의 훅 등록 ---
assert_file_exists "settings.json 있음" ".claude/settings.json"
assert_json_valid "settings.json은 JSON" ".claude/settings.json"

HK_SETTINGS=$(cat .claude/settings.json)
assert_contains "SessionStart 훅 등록" "$(jq -r '.hooks.SessionStart[0].hooks[0].command' .claude/settings.json)" "session-context.sh"
assert_contains "PreToolUse 훅 등록" "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' .claude/settings.json)" "secret-scan.sh"
assert_contains "PostToolUse 훅 등록" "$(jq -r '.hooks.PostToolUse[0].hooks[0].command' .claude/settings.json)" "check-doc-sync.sh"
assert_contains "Notification 훅 등록" "$(jq -r '.hooks.Notification[0].hooks[0].command' .claude/settings.json)" "notify.sh"
assert_eq "PostToolUse matcher는 Write|Edit" "Write|Edit" "$(jq -r '.hooks.PostToolUse[0].matcher' .claude/settings.json)"

# 훅은 stdin의 JSON을 읽는다. 템플릿의 가짜 변수($TOOL_INPUT_PATH 등)가 돌아오면 안 된다
assert_not_contains "settings: 가짜 환경 변수 인자 없음" "$HK_SETTINGS" "TOOL_INPUT_PATH"

# PreToolUse는 exit 2로만 막는다. 명령이 종료 코드를 삼키면 막지 못한다
HK_PRE_CMD=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' .claude/settings.json)
assert_not_contains "PreToolUse 명령이 종료 코드를 유지" "$HK_PRE_CMD" "|| true"
assert_eq "PreToolUse matcher는 Bash" "Bash" "$(jq -r '.hooks.PreToolUse[0].matcher' .claude/settings.json)"

HK_DENY=$(jq -r '.permissions.deny[]' .claude/settings.json)
assert_contains "deny: rm -rf" "$HK_DENY" "Bash(rm -rf:*)"
assert_contains "deny: 강제 push" "$HK_DENY" "Bash(git push --force:*)"
assert_contains "deny: .env 읽기" "$HK_DENY" "Read(./.env)"
# cdk-outputs.json에는 페어링 링크가 평문으로 들어 있다
assert_contains "deny: cdk-outputs.json 읽기" "$HK_DENY" "Read(./cdk-outputs.json)"
# Terraform 상태 파일에는 X-Custom-Secret 값이 평문으로 들어 있다
assert_contains "deny: Terraform 상태 파일 읽기" "$HK_DENY" "Read(./infra-tf/**/*.tfstate)"
assert_contains "deny: Terraform 상태 파일의 백업 읽기" "$HK_DENY" "Read(./infra-tf/**/*.tfstate.*)"

# 서버와 스택을 바꾸는 명령은 실행할 때마다 승인을 묻는다. allow에 들어가면 승인 절차가 사라진다
HK_ASK=$(jq -r '.permissions.ask[]' .claude/settings.json)
HK_ALLOW=$(jq -r '.permissions.allow[]' .claude/settings.json)
for HK_WORD in deploy_orca.sh deploy_orca_tf.sh upgrade_orca.sh cleanup.sh set_password.sh get_pairing_url.sh "cdk deploy" "cdk destroy" \
               "Bash(terraform apply:" "Bash(terraform destroy:" "infra-tf/dedicated apply:" "infra-tf/dedicated destroy:" \
               "infra-tf/attach apply:" "infra-tf/attach destroy:"; do
    assert_contains "ask: $HK_WORD 는 승인을 물음" "$HK_ASK" "$HK_WORD"
    assert_not_contains "allow: $HK_WORD 를 미리 허용하지 않음" "$HK_ALLOW" "$HK_WORD"
done
assert_not_contains "allow: 모든 Bash 명령을 허용하지 않음" "$HK_ALLOW" "Bash(*)"

# --- check-doc-sync의 동작 ---
HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "" 2>&1 || true)
assert_eq "check-doc-sync: 빈 경로는 출력 없음" "" "$HK_OUT"

HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "README.md" 2>&1 || true)
assert_eq "check-doc-sync: 소스가 아닌 파일은 조용함" "" "$HK_OUT"

HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "infra-cdk/lib/host/install_orca.sh" 2>&1 || true)
assert_contains "check-doc-sync: 설치 스크립트는 서버에서 다시 실행됨을 알림" "$HK_OUT" "Custom::OrcaHostInstall"
assert_contains "check-doc-sync: 설치 스크립트는 버전 변경과 따로 배포하라고 알림" "$HK_OUT" "docs/runbooks/upgrade-orca.md"
assert_contains "check-doc-sync: 설치 스크립트는 패키지 목록의 다른 자리를 알림" "$HK_OUT" "infra-cdk/lib/orca-stack.ts"
assert_contains "check-doc-sync: 설치 스크립트는 Terraform 쪽 패키지 목록도 알림" "$HK_OUT" "infra-tf/dedicated/user_data.sh.tftpl"
assert_contains "check-doc-sync: 설치 스크립트는 Terraform 시험도 알림" "$HK_OUT" "bash infra-tf/run-tests.sh"
assert_not_contains "check-doc-sync: infra-cdk/CLAUDE.md를 찾음" "$HK_OUT" "CLAUDE.md가 없습니다"

HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "infra-cdk/lib/functions/password-gate.js" 2>&1 || true)
assert_contains "check-doc-sync: 게이트 함수는 API 문서를 알림" "$HK_OUT" "docs/api-reference.md"
HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "infra-cdk/lib/gate/setup_service.py" 2>&1 || true)
assert_contains "check-doc-sync: 설정 서비스는 보안 참조 문서를 알림" "$HK_OUT" "docs/reference/security.md"

HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "infra-cdk/lib/pairing/read_pairing.sh" 2>&1 || true)
assert_contains "check-doc-sync: 페어링 코드는 로그 문구 의존을 알림" "$HK_OUT" "Web client URL"

HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "infra-cdk/lib/orca-attach-stack.ts" 2>&1 || true)
assert_contains "check-doc-sync: 스택 코드는 차이와 승인을 알림" "$HK_OUT" "승인"
assert_contains "check-doc-sync: 스택 코드는 IaC 참조 문서를 알림" "$HK_OUT" "docs/reference/iac.md"
assert_contains "check-doc-sync: 스택 코드는 Terraform 코드에도 같은 변경을 넣으라고 알림" "$HK_OUT" "infra-tf/"
HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "infra-cdk/bin/app.ts" 2>&1 || true)
assert_contains "check-doc-sync: 앱 진입점도 스택 코드로 다룸" "$HK_OUT" "docs/architecture.md"

HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "infra-cdk/package.json" 2>&1 || true)
assert_contains "check-doc-sync: 패키지 변경은 Tech Stack을 알림" "$HK_OUT" "Tech Stack"

HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "infra-cdk/test/upgrade_test.py" 2>&1 || true)
assert_eq "check-doc-sync: 코드 시험 파일은 조용함" "" "$HK_OUT"

# Terraform 코드: 계획과 승인, CDK와 맞추기, 시험
for HK_NAME in infra-tf/attach/main.tf infra-tf/dedicated/network.tf infra-tf/modules/routes/main.tf infra-tf/scripts/ssm_run.sh; do
    HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "$HK_NAME" 2>&1 || true)
    assert_contains "check-doc-sync: $HK_NAME 은 계획을 먼저 보라고 알림" "$HK_OUT" "deploy_orca_tf.sh --plan"
    assert_contains "check-doc-sync: $HK_NAME 은 승인을 알림" "$HK_OUT" "승인"
    assert_contains "check-doc-sync: $HK_NAME 은 CDK 스택과 맞추라고 알림" "$HK_OUT" "infra-cdk/lib/"
    assert_contains "check-doc-sync: $HK_NAME 은 Terraform 시험을 알림" "$HK_OUT" "bash infra-tf/run-tests.sh"
    assert_not_contains "check-doc-sync: $HK_NAME 에서 infra-tf/CLAUDE.md를 찾음" "$HK_OUT" "CLAUDE.md가 없습니다"
done
HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "infra-tf/dedicated/user_data.sh.tftpl" 2>&1 || true)
assert_contains "check-doc-sync: UserData 템플릿은 CDK의 같은 자리를 알림" "$HK_OUT" "infra-cdk/lib/orca-stack.ts"
assert_contains "check-doc-sync: UserData 템플릿은 템플릿 이스케이프를 알림" "$HK_OUT" '%%{'
for HK_NAME in infra-tf/dedicated/tests/variants.tftest.hcl infra-tf/attach/tests/mocks/aws.tfmock.hcl infra-tf/test/ssm_run_test.py infra-tf/run-tests.sh; do
    HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "$HK_NAME" 2>&1 || true)
    assert_contains "check-doc-sync: $HK_NAME 은 Terraform 시험 실행을 알림" "$HK_OUT" "bash infra-tf/run-tests.sh"
    # 시험 파일을 수정했는데 배포 승인을 알리면 알림이 무뎌진다. 시험 가지가 일반 가지보다 먼저 맞아야 한다
    assert_not_contains "check-doc-sync: $HK_NAME 은 배포 승인을 알리지 않음" "$HK_OUT" "승인"
done

for HK_NAME in deploy_orca.sh deploy_orca_tf.sh upgrade_orca.sh cleanup.sh set_password.sh get_pairing_url.sh; do
    HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "$HK_NAME" 2>&1 || true)
    assert_contains "check-doc-sync: $HK_NAME 은 README의 두 구역을 알림" "$HK_OUT" "영어와 한국어 두 구역"
    assert_contains "check-doc-sync: $HK_NAME 은 Terraform 쪽 스크립트 시험을 알림" "$HK_OUT" "bash infra-tf/run-tests.sh"
done

for HK_NAME in docs/infographic/access_path.py docs/infographic/orcakit.py docs/infographic/build.sh; do
    HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "$HK_NAME" 2>&1 || true)
    assert_contains "check-doc-sync: $HK_NAME 은 그림 다시 만들기를 알림" "$HK_OUT" "docs/infographic/build.sh"
    assert_contains "check-doc-sync: $HK_NAME 은 두 언어의 글을 함께 수정하라고 알림" "$HK_OUT" "T_EN"
done
HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "docs/infographic/sources.md" 2>&1 || true)
assert_eq "check-doc-sync: 그림의 근거 문서는 조용함" "" "$HK_OUT"

HK_OUT=$(bash .claude/hooks/check-doc-sync.sh ".claude/hooks/secret-scan.sh" 2>&1 || true)
assert_contains "check-doc-sync: 훅을 수정하면 하네스 시험을 알림" "$HK_OUT" "bash tests/run-all.sh"
HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "tests/hooks/test-hooks.sh" 2>&1 || true)
assert_contains "check-doc-sync: 시험을 수정하면 하네스 시험을 알림" "$HK_OUT" "bash tests/run-all.sh"
assert_not_contains "check-doc-sync: tests/CLAUDE.md를 찾음" "$HK_OUT" "CLAUDE.md가 없습니다"

# 모듈 문서 자체를 수정하면 조용해야 한다. 모듈마다 본다(다른 가지가 가려 주는 모듈이 있으면 빠진 가지를 못 잡는다)
HK_ROOTS=$(sed -n 's/^SOURCE_ROOTS="\(.*\)"/\1/p' .claude/hooks/check-doc-sync.sh)
for HK_ROOT in $HK_ROOTS; do
    HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "$HK_ROOT/CLAUDE.md" 2>&1 || true)
    assert_eq "check-doc-sync: $HK_ROOT/CLAUDE.md 자체를 수정하면 조용함" "" "$HK_OUT"
done

# 훅 방식: stdin의 JSON을 읽고 PostToolUse JSON을 낸다. 보통 글로 내면 Claude에게 전달되지 않는다
HK_OUT=$(echo "{\"tool_input\":{\"file_path\":\"$PROJECT_ROOT/infra-cdk/lib/orca-stack.ts\"}}" \
    | bash .claude/hooks/check-doc-sync.sh 2>&1 || true)
assert_eq "check-doc-sync: 훅 방식은 PostToolUse JSON을 냄" "PostToolUse" \
    "$(echo "$HK_OUT" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null || true)"
assert_contains "check-doc-sync: 훅 방식의 내용에 알림이 있음" \
    "$(echo "$HK_OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)" "docs/reference/iac.md"

# 모듈 문서와 ADR 알림은 저장소 상태에 따라 달라지므로 임시 디렉터리에서 본다
HK_SYNC="$TEST_TMP/sync-project"
mkdir -p "$HK_SYNC/infra-cdk/lib" "$HK_SYNC/docs/decisions"
echo "export {}" > "$HK_SYNC/infra-cdk/lib/x.ts"
HK_OUT=$(CLAUDE_PROJECT_DIR="$HK_SYNC" bash .claude/hooks/check-doc-sync.sh "infra-cdk/lib/x.ts" 2>&1 || true)
assert_contains "check-doc-sync: 모듈 문서가 없으면 알림" "$HK_OUT" "infra-cdk/CLAUDE.md가 없습니다"
echo "# infra-cdk" > "$HK_SYNC/infra-cdk/CLAUDE.md"
HK_OUT=$(CLAUDE_PROJECT_DIR="$HK_SYNC" bash .claude/hooks/check-doc-sync.sh "infra-cdk/lib/x.ts" 2>&1 || true)
assert_not_contains "check-doc-sync: 모듈 루트의 CLAUDE.md를 찾음" "$HK_OUT" "CLAUDE.md가 없습니다"

HK_OUT=$(CLAUDE_PROJECT_DIR="$HK_SYNC" bash .claude/hooks/check-doc-sync.sh "docs/architecture.md" 2>&1 || true)
assert_contains "check-doc-sync: ADR이 없으면 아키텍처 변경에서 알림" "$HK_OUT" "ADR이 없습니다"
echo "# ADR" > "$HK_SYNC/docs/decisions/ADR-001-x.md"
HK_OUT=$(CLAUDE_PROJECT_DIR="$HK_SYNC" bash .claude/hooks/check-doc-sync.sh "docs/architecture.md" 2>&1 || true)
assert_not_contains "check-doc-sync: ADR이 있으면 알리지 않음" "$HK_OUT" "ADR이 없습니다"

# --- secret-scan의 동작 (PreToolUse 방식, 따로 만든 git 저장소) ---
HK_OUT=$(echo '{"tool_input":{"command":"ls -la"}}' | bash .claude/hooks/secret-scan.sh 2>&1; echo "exit=$?")
assert_eq "secret-scan: 커밋이 아닌 명령은 조용히 통과" "exit=0" "$HK_OUT"

HK_SCAN="$TEST_TMP/scan-repo"
mkdir -p "$HK_SCAN"
git -C "$HK_SCAN" init -q
echo '# 안내' > "$HK_SCAN/clean.md"
git -C "$HK_SCAN" add clean.md
HK_STATUS=$(echo '{"tool_input":{"command":"git commit -m test"}}' \
    | CLAUDE_PROJECT_DIR="$HK_SCAN" bash .claude/hooks/secret-scan.sh >/dev/null 2>&1; echo $?)
assert_eq "secret-scan: 깨끗한 파일은 커밋 허용" "0" "$HK_STATUS"

# 완전한 키 문자열을 저장소에 두지 않으려고 실행할 때 합친다
HK_KEY_PREFIX="AKIA"
HK_KEY_BODY="IOSFODNN7EXAMPLE"
echo "키: ${HK_KEY_PREFIX}${HK_KEY_BODY}" > "$HK_SCAN/leak.md"
# 스테이징하지 않은 새 파일은 보통의 커밋에서는 들어가지 않으므로 막지 않는다
HK_STATUS=$(echo '{"tool_input":{"command":"git commit -m test"}}' \
    | CLAUDE_PROJECT_DIR="$HK_SCAN" bash .claude/hooks/secret-scan.sh >/dev/null 2>&1; echo $?)
assert_eq "secret-scan: 스테이징하지 않은 파일은 보통의 커밋을 막지 않음" "0" "$HK_STATUS"
HK_STATUS=$(echo '{"tool_input":{"command":"git add -A && git commit -m test"}}' \
    | CLAUDE_PROJECT_DIR="$HK_SCAN" bash .claude/hooks/secret-scan.sh >/dev/null 2>&1; echo $?)
assert_eq "secret-scan: 스테이징 전의 비밀 값도 'git add && commit'에서 exit 2로 막음" "2" "$HK_STATUS"

git -C "$HK_SCAN" add leak.md
HK_STATUS=$(echo '{"tool_input":{"command":"git commit -m test"}}' \
    | CLAUDE_PROJECT_DIR="$HK_SCAN" bash .claude/hooks/secret-scan.sh >/dev/null 2>&1; echo $?)
assert_eq "secret-scan: 스테이징한 비밀 값을 exit 2로 막음" "2" "$HK_STATUS"
HK_STATUS=$(bash -c "cd '$HK_SCAN' && bash '$PROJECT_ROOT/.claude/hooks/secret-scan.sh' --staged" >/dev/null 2>&1; echo $?)
assert_eq "secret-scan: --staged(git pre-commit)는 exit 1로 막음" "1" "$HK_STATUS"

# commit -a와 commit -am은 추적하는 파일의 수정본을 훅이 돈 뒤에 스테이징한다
HK_AM="$TEST_TMP/am-repo"
mkdir -p "$HK_AM"
git -C "$HK_AM" init -q
echo 'first' > "$HK_AM/notes.md"
git -C "$HK_AM" add notes.md
git -C "$HK_AM" -c user.name=t -c user.email=t@example.invalid commit -q -m init
echo "키: ${HK_KEY_PREFIX}${HK_KEY_BODY}" >> "$HK_AM/notes.md"
for HK_CMD in "git commit -am test" "git commit -a -m test" "git commit --all -m test" "git commit -m test -a"; do
    HK_STATUS=$(jq -n --arg c "$HK_CMD" '{tool_input: {command: $c}}' \
        | CLAUDE_PROJECT_DIR="$HK_AM" bash .claude/hooks/secret-scan.sh >/dev/null 2>&1; echo $?)
    assert_eq "secret-scan: '$HK_CMD'의 수정본을 exit 2로 막음" "2" "$HK_STATUS"
done
HK_STATUS=$(echo '{"tool_input":{"command":"git commit -m test"}}' \
    | CLAUDE_PROJECT_DIR="$HK_AM" bash .claude/hooks/secret-scan.sh >/dev/null 2>&1; echo $?)
assert_eq "secret-scan: -a가 없으면 스테이징하지 않은 수정본은 막지 않음" "0" "$HK_STATUS"

# 내용이 비어 있어도 배포 출력 파일은 막는다(페어링 링크가 들어가는 파일)
HK_OUTPUTS="$TEST_TMP/outputs-repo"
mkdir -p "$HK_OUTPUTS"
git -C "$HK_OUTPUTS" init -q
echo '{}' > "$HK_OUTPUTS/cdk-outputs.json"
git -C "$HK_OUTPUTS" add -f cdk-outputs.json
HK_STATUS=$(echo '{"tool_input":{"command":"git commit -m outputs"}}' \
    | CLAUDE_PROJECT_DIR="$HK_OUTPUTS" bash .claude/hooks/secret-scan.sh >/dev/null 2>&1; echo $?)
assert_eq "secret-scan: 스테이징한 cdk-outputs.json을 exit 2로 막음" "2" "$HK_STATUS"

# 막을 때는 이유를 stderr로 알린다(Claude에게 전달되는 것은 stderr다)
HK_OUT=$(echo '{"tool_input":{"command":"git commit -m outputs"}}' \
    | CLAUDE_PROJECT_DIR="$HK_OUTPUTS" bash .claude/hooks/secret-scan.sh 2>&1 >/dev/null || true)
assert_contains "secret-scan: 막은 이유를 stderr로 알림" "$HK_OUT" "커밋하면 안 되는 파일"

# git 저장소가 아닌 곳에서는 커밋 명령이어도 조용히 통과한다(막을 대상이 없다)
HK_STATUS=$(echo '{"tool_input":{"command":"git commit -m test"}}' \
    | GIT_CEILING_DIRECTORIES="$TEST_TMP" CLAUDE_PROJECT_DIR="$HK_SYNC" bash .claude/hooks/secret-scan.sh >/dev/null 2>&1; echo $?)
assert_eq "secret-scan: git 저장소가 아니면 통과" "0" "$HK_STATUS"

# --- session-context ---
HK_OUT=$(bash .claude/hooks/session-context.sh 2>&1 || true)
assert_contains "session-context: 머리글" "$HK_OUT" "프로젝트 맥락"
assert_contains "session-context: 승인 규칙을 알림" "$HK_OUT" "승인"
assert_contains "session-context: 비밀 값을 출력하지 않는 규칙을 알림" "$HK_OUT" "출력하지 않습니다"
assert_contains "session-context: 문서 수를 알림" "$HK_OUT" "CLAUDE.md "
HK_VERSION=$(grep -A3 "CfnParameter(this, 'OrcaVersion'" infra-cdk/lib/orca-attach-stack.ts | sed -n "s/.*default: '\([0-9.]*\)'.*/\1/p" | head -1)
assert_contains "session-context: 코드의 기본 Orca 버전" "$HK_OUT" "기본 Orca 버전: $HK_VERSION"
# 맥락에 식별 값이나 페어링 링크가 섞이면 안 된다
if printf '%s\n' "$HK_OUT" | grep -qE '[0-9]{12}|cloudfront\.net|orca://pair|gate-setup='; then
    fail "session-context: 계정 ID, 사이트 주소, 페어링 링크를 내지 않음" "출력에 식별 값이나 링크가 있음"
else
    pass "session-context: 계정 ID, 사이트 주소, 페어링 링크를 내지 않음"
fi
# AWS와 스택 출력, 서비스 로그를 읽지 않는다
if grep -vE '^[[:space:]]*#' .claude/hooks/session-context.sh | grep -qE '\baws [a-z0-9-]+ [a-z-]+|cdk-outputs\.json|journalctl|describe-stacks'; then
    fail "session-context: AWS, 배포 출력 파일, 서비스 로그를 읽지 않음" "해당 명령이 있음"
else
    pass "session-context: AWS, 배포 출력 파일, 서비스 로그를 읽지 않음"
fi

# --- 준비 스크립트는 AWS와 서버를 건드리지 않는다 ---
assert_file_executable "scripts/setup.sh 실행 권한" "scripts/setup.sh"
if grep -vE '^[[:space:]]*#' scripts/setup.sh | grep -qE '\baws [a-z0-9-]+ [a-z-]+|\bcdk (deploy|destroy)|deploy_orca|upgrade_orca|cleanup\.sh|set_password|systemctl|\bsudo\b'; then
    fail "setup.sh: AWS를 부르거나 배포하거나 서비스를 건드리지 않음" "해당 명령이 있음"
else
    pass "setup.sh: AWS를 부르거나 배포하거나 서비스를 건드리지 않음"
fi

# --- AI 공동 저자 줄 제거 ---
assert_eq "settings: 커밋 attribution 끔" "" "$(jq -r '.attribution.commit' .claude/settings.json)"
assert_eq "settings: PR attribution 끔" "" "$(jq -r '.attribution.pr' .claude/settings.json)"

HK_MSG="$TEST_TMP/msg-repo"
mkdir -p "$HK_MSG/scripts"
git -C "$HK_MSG" init -q
cp scripts/install-hooks.sh "$HK_MSG/scripts/"
bash "$HK_MSG/scripts/install-hooks.sh" >/dev/null
assert_file_executable "install-hooks: pre-commit 설치" "$HK_MSG/.git/hooks/pre-commit"
assert_file_executable "install-hooks: commit-msg 설치" "$HK_MSG/.git/hooks/commit-msg"
assert_contains "install-hooks: pre-commit이 검사기의 --staged를 부름" "$(cat "$HK_MSG/.git/hooks/pre-commit")" "secret-scan.sh\" --staged"
printf 'feat: sample\n\nBody line.\n\nCo-Authored-By: Claude <noreply@example.invalid>\nco-authored-by: Bot <b@x>\n  CO-AUTHORED-BY: Other <o@x>\nClaude-Session: abc123\n\n' \
    > "$HK_MSG/msg.txt"
bash "$HK_MSG/.git/hooks/commit-msg" "$HK_MSG/msg.txt"
HK_MSG_OUT=$(cat "$HK_MSG/msg.txt")
assert_not_contains "commit-msg: Co-Authored-By를 대소문자 구분 없이 지움" "$(echo "$HK_MSG_OUT" | tr '[:upper:]' '[:lower:]')" "co-authored-by"
assert_not_contains "commit-msg: Claude-Session 줄을 지움" "$HK_MSG_OUT" "Claude-Session"
assert_contains "commit-msg: 제목은 남김" "$HK_MSG_OUT" "feat: sample"
assert_contains "commit-msg: 본문은 남김" "$HK_MSG_OUT" "Body line."
assert_eq "commit-msg: 끝에 빈 줄 없음" "Body line." "$(tail -n 1 "$HK_MSG/msg.txt")"

# git 저장소가 아니면 설치 스크립트가 실패로 알린다
HK_NOGIT="$TEST_TMP/no-git"
mkdir -p "$HK_NOGIT/scripts"
cp scripts/install-hooks.sh "$HK_NOGIT/scripts/"
HK_STATUS=$(GIT_CEILING_DIRECTORIES="$TEST_TMP" bash "$HK_NOGIT/scripts/install-hooks.sh" >/dev/null 2>&1; echo $?)
assert_eq "install-hooks: git 저장소가 아니면 exit 1" "1" "$HK_STATUS"

# --- notify ---
HK_OUT=$(CLAUDE_NOTIFY_WEBHOOK="" bash .claude/hooks/notify.sh "test" "msg" 2>&1 || true)
assert_eq "notify: 웹훅 주소가 없으면 출력 없음" "" "$HK_OUT"
