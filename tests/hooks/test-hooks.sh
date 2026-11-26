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
# .env.local 같은 파일도 막는다. .env.example은 값이 없는 견본이라 읽을 수 있어야 한다
assert_contains "deny: .env.* 읽기" "$HK_DENY" "Read(./.env.*)"
assert_contains "deny: .env.example은 예외" "$HK_DENY" "Read(!.env.example)"
assert_contains "deny: 강제 push의 짧은 옵션" "$HK_DENY" "Bash(git push -f *)"
assert_contains "deny: rm -fr" "$HK_DENY" "Bash(rm -fr *)"
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

# 두 배포 스크립트가 함께 쓰는 안내: 양쪽 시험과 맞춰야 할 두 곳(스택의 타입 목록, CDK의 서브넷 분류)을 알린다
HK_OUT=$(bash .claude/hooks/check-doc-sync.sh "deploy_guide.sh" 2>&1 || true)
assert_contains "check-doc-sync: 안내 코드는 CDK 쪽 시험을 알림" "$HK_OUT" "infra-cdk/test/deploy_test.py"
assert_contains "check-doc-sync: 안내 코드는 Terraform 쪽 시험을 알림" "$HK_OUT" "bash infra-tf/run-tests.sh"
assert_contains "check-doc-sync: 안내 코드는 스택의 타입 목록을 알림" "$HK_OUT" "infra-cdk/lib/orca-stack.ts"
assert_contains "check-doc-sync: 안내 코드는 CDK의 서브넷 분류를 알림" "$HK_OUT" "Vpc.fromLookup"
assert_contains "check-doc-sync: 안내 코드는 README의 두 구역을 알림" "$HK_OUT" "영어와 한국어 두 구역"

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
HK_SYNC_TMP="$TEST_TMP/sync-tmp"
mkdir -p "$HK_SYNC/infra-cdk/lib" "$HK_SYNC/docs/decisions" "$HK_SYNC_TMP"
echo "export {}" > "$HK_SYNC/infra-cdk/lib/x.ts"
HK_OUT=$(TMPDIR="$HK_SYNC_TMP" CLAUDE_PROJECT_DIR="$HK_SYNC" bash .claude/hooks/check-doc-sync.sh "infra-cdk/lib/x.ts" 2>&1 || true)
assert_contains "check-doc-sync: 모듈 문서가 없으면 알림" "$HK_OUT" "infra-cdk/CLAUDE.md가 없습니다"
HK_OUT=$(TMPDIR="$HK_SYNC_TMP" CLAUDE_PROJECT_DIR="$HK_SYNC" bash .claude/hooks/check-doc-sync.sh "infra-cdk/lib/x.ts" 2>&1 || true)
assert_contains "check-doc-sync: 인자로 부르면(세션 없음) 되풀이해도 알림" "$HK_OUT" "infra-cdk/CLAUDE.md가 없습니다"
echo "# infra-cdk" > "$HK_SYNC/infra-cdk/CLAUDE.md"
HK_OUT=$(TMPDIR="$HK_SYNC_TMP" CLAUDE_PROJECT_DIR="$HK_SYNC" bash .claude/hooks/check-doc-sync.sh "infra-cdk/lib/x.ts" 2>&1 || true)
assert_not_contains "check-doc-sync: 모듈 루트의 CLAUDE.md를 찾음" "$HK_OUT" "CLAUDE.md가 없습니다"

HK_OUT=$(TMPDIR="$HK_SYNC_TMP" CLAUDE_PROJECT_DIR="$HK_SYNC" bash .claude/hooks/check-doc-sync.sh "docs/architecture.md" 2>&1 || true)
assert_contains "check-doc-sync: ADR이 없으면 아키텍처 변경에서 알림" "$HK_OUT" "ADR이 없습니다"
HK_OUT=$(TMPDIR="$HK_SYNC_TMP" CLAUDE_PROJECT_DIR="$HK_SYNC" bash .claude/hooks/check-doc-sync.sh "docs/architecture.md" 2>&1 || true)
assert_contains "check-doc-sync: ADR 알림도 인자로 부르면 되풀이함" "$HK_OUT" "ADR이 없습니다"
echo "# ADR" > "$HK_SYNC/docs/decisions/ADR-001-x.md"
HK_OUT=$(TMPDIR="$HK_SYNC_TMP" CLAUDE_PROJECT_DIR="$HK_SYNC" bash .claude/hooks/check-doc-sync.sh "docs/architecture.md" 2>&1 || true)
assert_not_contains "check-doc-sync: ADR이 있으면 알리지 않음" "$HK_OUT" "ADR이 없습니다"

# 연결된 작업 트리(git worktree)에서 수정한 파일은 그 작업 트리를 기준으로 본다. CLAUDE_PROJECT_DIR은 원래 체크아웃에 머문다.
# hk_sync <프로젝트 디렉터리> <파일의 절대 경로> <세션 ID, 없으면 빈 값>: 훅 방식으로 돌리고 Claude에게 가는 글을 출력한다
hk_sync() {
    jq -n --arg f "$2" --arg s "$3" '{tool_input: {file_path: $f}, session_id: $s}' \
        | TMPDIR="$HK_SYNC_TMP" CLAUDE_PROJECT_DIR="$1" bash "$PROJECT_ROOT/.claude/hooks/check-doc-sync.sh" 2>/dev/null \
        | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}
HK_WT="$TEST_TMP/wt-main"
mkdir -p "$HK_WT/infra-cdk/lib" "$HK_WT/docs"
git -C "$HK_WT" init -q
echo "export {}" > "$HK_WT/infra-cdk/lib/x.ts"
echo "# 구조" > "$HK_WT/docs/architecture.md"
git -C "$HK_WT" add .
git -C "$HK_WT" -c user.name=t -c user.email=t@example.invalid commit -q -m init
HK_LINKED="$HK_WT/.claude/worktrees/feature"
git -C "$HK_WT" worktree add -q -b feature "$HK_LINKED" >/dev/null 2>&1
assert_file_exists "check-doc-sync: 시험 준비: 연결된 작업 트리를 만듦" "$HK_LINKED/infra-cdk/lib/x.ts"
echo "# infra-cdk" > "$HK_LINKED/infra-cdk/CLAUDE.md"
HK_OUT=$(hk_sync "$HK_WT" "$HK_LINKED/infra-cdk/lib/x.ts" "")
assert_contains "check-doc-sync: 연결된 작업 트리의 파일도 함께 볼 문서를 알림" "$HK_OUT" "docs/reference/iac.md"
assert_not_contains "check-doc-sync: 모듈 문서를 그 작업 트리에서 찾음" "$HK_OUT" "CLAUDE.md가 없습니다"
HK_OUT=$(hk_sync "$HK_WT" "$HK_WT/infra-cdk/lib/x.ts" "")
assert_contains "check-doc-sync: 원래 체크아웃의 파일은 원래 체크아웃에서 모듈 문서를 찾음" "$HK_OUT" "infra-cdk/CLAUDE.md가 없습니다"

# 다른 저장소의 파일은 경로가 같은 모양이어도 따라가지 않는다
HK_OTHER="$TEST_TMP/other-repo"
mkdir -p "$HK_OTHER/infra-cdk/lib"
git -C "$HK_OTHER" init -q
echo "export {}" > "$HK_OTHER/infra-cdk/lib/x.ts"
assert_eq "check-doc-sync: 다른 저장소의 파일은 조용함" "" "$(hk_sync "$HK_WT" "$HK_OTHER/infra-cdk/lib/x.ts" "")"

# 문서가 없다는 알림은 세션마다 한 번만 한다. 수정할 때마다 되풀이하지 않는다
HK_OUT=$(hk_sync "$HK_WT" "$HK_WT/infra-cdk/lib/x.ts" "hk-session-1")
assert_contains "check-doc-sync: 세션의 첫 수정에서 모듈 문서가 없다고 알림" "$HK_OUT" "infra-cdk/CLAUDE.md가 없습니다"
HK_OUT=$(hk_sync "$HK_WT" "$HK_WT/infra-cdk/lib/x.ts" "hk-session-1")
assert_not_contains "check-doc-sync: 같은 세션의 다음 수정에서는 되풀이하지 않음" "$HK_OUT" "CLAUDE.md가 없습니다"
assert_contains "check-doc-sync: 그때도 함께 볼 문서는 알림" "$HK_OUT" "docs/reference/iac.md"
HK_OUT=$(hk_sync "$HK_WT" "$HK_WT/infra-cdk/lib/x.ts" "hk-session-2")
assert_contains "check-doc-sync: 다른 세션에서는 다시 알림" "$HK_OUT" "infra-cdk/CLAUDE.md가 없습니다"
HK_OUT=$(hk_sync "$HK_WT" "$HK_WT/docs/architecture.md" "hk-session-1")
assert_contains "check-doc-sync: 세션의 첫 아키텍처 수정에서 ADR이 없다고 알림" "$HK_OUT" "ADR이 없습니다"
assert_eq "check-doc-sync: 같은 세션에서는 ADR 알림을 되풀이하지 않음" "" "$(hk_sync "$HK_WT" "$HK_WT/docs/architecture.md" "hk-session-1")"

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
assert_eq "secret-scan: --staged(git pre-commit)도 exit 2로 막음" "2" "$HK_STATUS"

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

# --- secret-scan: 이미 스테이징한 것만이 아니라 그 커밋에 들어갈 내용을 본다 (project-init:commit-scope) ---
# hk_scan <프로젝트 디렉터리> <이벤트의 cwd, 없으면 빈 값> <명령>: PreToolUse 방식으로 검사기를 돌리고 종료 코드를 출력한다
hk_scan() {
    jq -n --arg c "$3" --arg d "$2" '{tool_input: {command: $c}} + (if $d == "" then {} else {cwd: $d} end)' \
        | CLAUDE_PROJECT_DIR="$1" bash "$PROJECT_ROOT/.claude/hooks/secret-scan.sh" >/dev/null 2>&1
    echo $?
}
# hk_staged <저장소>: git pre-commit 방식으로 검사기를 돌리고 종료 코드를 출력한다
hk_staged() {
    (cd "$1" && bash "$PROJECT_ROOT/.claude/hooks/secret-scan.sh" --staged) >/dev/null 2>&1
    echo $?
}
# hk_repo <이름>: 커밋이 하나 있는 임시 저장소를 만들고 경로를 출력한다
hk_repo() {
    local dir="$TEST_TMP/$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.name t
    git -C "$dir" config user.email t@example.invalid
    echo '# base' > "$dir/base.md"
    git -C "$dir" add base.md
    git -C "$dir" commit -q -m init
    printf '%s' "$dir"
}
HK_LEAK="키: ${HK_KEY_PREFIX}${HK_KEY_BODY}"

# 커밋이 아닌 명령은 스테이징한 비밀 값이 있어도 지나간다. 커밋은 다른 명령과 이어 쓰거나 옵션이 끼어도 찾는다
for HK_CMD in "git log --grep commit" "git commit-graph write" "echo commit" "git show commit.txt"; do
    assert_eq "secret-scan: '$HK_CMD'은 커밋이 아니라 통과" "0" "$(hk_scan "$HK_SCAN" "" "$HK_CMD")"
done
for HK_CMD in "git -c user.name=t commit -m x" "ls; git commit -m x" "true && git commit -m x" "git --no-pager commit -m x" "(git commit -m x)"; do
    assert_eq "secret-scan: '$HK_CMD'도 커밋으로 보고 막음" "2" "$(hk_scan "$HK_SCAN" "" "$HK_CMD")"
done

# 커밋이 실행될 저장소를 본다: 이벤트의 cwd, 같은 줄의 cd와 pushd, git -C, --git-dir와 --work-tree
HK_CLEAN=$(hk_repo clean-repo)
mkdir -p "$HK_SCAN/sub"
assert_eq "secret-scan: 이벤트의 cwd가 가리키는 저장소를 봄" "2" "$(hk_scan "$HK_CLEAN" "$HK_SCAN" "git commit -m x")"
assert_eq "secret-scan: cwd가 저장소의 하위 디렉터리여도 봄" "2" "$(hk_scan "$HK_CLEAN" "$HK_SCAN/sub" "git commit -m x")"
assert_eq "secret-scan: cwd의 저장소가 깨끗하면 프로젝트 디렉터리의 스테이징은 상관없음" "0" "$(hk_scan "$HK_SCAN" "$HK_CLEAN" "git commit -m x")"
for HK_CMD in "git -C $HK_SCAN commit -m x" "git -C \"$HK_SCAN\" commit -m x" "cd $HK_SCAN && git commit -m x" "cd '$HK_SCAN'; git commit -m x" \
              "cd $HK_SCAN/sub && git commit -m x" "pushd $HK_SCAN >/dev/null && git commit -m x" \
              "git --git-dir=$HK_SCAN/.git --work-tree=$HK_SCAN commit -m x" "git --git-dir $HK_SCAN/.git --work-tree $HK_SCAN commit -m x" \
              "git --git-dir=$HK_SCAN/.git commit -m x"; do
    assert_eq "secret-scan: '${HK_CMD//$TEST_TMP/TMP}'은 그 저장소를 봄" "2" "$(hk_scan "$HK_CLEAN" "$HK_CLEAN" "$HK_CMD")"
done
assert_eq "secret-scan: 'git -C <깨끗한 저장소> commit'은 지금 저장소의 스테이징과 상관없음" "0" \
    "$(hk_scan "$HK_SCAN" "$HK_SCAN" "git -C $HK_CLEAN commit -m x")"

# 경로를 준 커밋은 그 경로의 수정본을 스테이징 없이 커밋한다
echo '# other' > "$HK_AM/other.md"
git -C "$HK_AM" add other.md
git -C "$HK_AM" -c user.name=t -c user.email=t@example.invalid commit -q -m other other.md
echo 'more' >> "$HK_AM/other.md"
for HK_CMD in "git commit -m test notes.md" "git commit -m test -- notes.md" "git commit notes.md -m test" "git commit -m test '*.md'"; do
    assert_eq "secret-scan: '$HK_CMD'은 그 경로의 수정본을 exit 2로 막음" "2" "$(hk_scan "$HK_AM" "" "$HK_CMD")"
done
assert_eq "secret-scan: 다른 경로만 준 커밋은 막지 않음" "0" "$(hk_scan "$HK_AM" "" "git commit -m test other.md")"

# 같은 줄의 git add -f는 무시된 파일도 스테이징한다. 배포 출력 파일은 .gitignore에 있어서 이 길로만 커밋에 들어온다
HK_FORCE=$(hk_repo force-repo)
printf 'cdk-outputs.json\nlocal/\n' > "$HK_FORCE/.gitignore"
git -C "$HK_FORCE" add .gitignore
git -C "$HK_FORCE" commit -q -m ignore
echo '{}' > "$HK_FORCE/cdk-outputs.json"
mkdir -p "$HK_FORCE/local"
echo "$HK_LEAK" > "$HK_FORCE/local/key.txt"
assert_eq "secret-scan: 'git add .'은 무시된 파일을 넣지 않으므로 통과" "0" "$(hk_scan "$HK_FORCE" "" "git add . && git commit -m x")"
for HK_CMD in "git add -f cdk-outputs.json && git commit -m x" "git add --force cdk-outputs.json && git commit -m x" \
              "git stage -f cdk-outputs.json && git commit -m x" "git add -f local/key.txt && git commit -m x" \
              "git add -f local && git commit -m x" "cd local && git add -f key.txt && git commit -m x" "git add -f && git commit -m x"; do
    assert_eq "secret-scan: '$HK_CMD'은 무시된 파일도 보고 막음" "2" "$(hk_scan "$HK_FORCE" "" "$HK_CMD")"
done

# 스테이징한 파일은 인덱스의 사본을 본다. 스테이징한 뒤에 작업 트리의 파일을 수정해도 커밋에 들어가는 것은 인덱스의 사본이다
HK_IDX=$(hk_repo index-repo)
echo "$HK_LEAK" > "$HK_IDX/staged.md"
git -C "$HK_IDX" add staged.md
echo '지웠음' > "$HK_IDX/staged.md"
assert_eq "secret-scan: 작업 트리에서 지웠어도 스테이징한 사본의 비밀 값을 막음" "2" "$(hk_scan "$HK_IDX" "" "git commit -m x")"
HK_OUT=$(echo '{"tool_input":{"command":"git commit -m x"}}' | CLAUDE_PROJECT_DIR="$HK_IDX" bash .claude/hooks/secret-scan.sh 2>&1 >/dev/null || true)
assert_contains "secret-scan: 스테이징한 사본에서 걸렸다고 알림" "$HK_OUT" "staged.md (스테이징한 사본)"
assert_eq "secret-scan: --staged도 스테이징한 사본을 봄" "2" "$(hk_staged "$HK_IDX")"

HK_IDX2=$(hk_repo index-repo2)
echo '깨끗함' > "$HK_IDX2/doc.md"
git -C "$HK_IDX2" add doc.md
echo "$HK_LEAK" > "$HK_IDX2/doc.md"
assert_eq "secret-scan: 스테이징한 사본이 깨끗하면 작업 트리의 수정본은 보통의 커밋을 막지 않음" "0" "$(hk_scan "$HK_IDX2" "" "git commit -m x")"
assert_eq "secret-scan: --staged도 작업 트리의 수정본은 보지 않음" "0" "$(hk_staged "$HK_IDX2")"
assert_eq "secret-scan: 같은 저장소에서 commit -a는 그 수정본을 막음" "2" "$(hk_scan "$HK_IDX2" "" "git commit -am x")"

# 이름을 바꾼 파일과 한글 이름의 파일도 빠뜨리지 않는다
HK_REN=$(hk_repo rename-repo)
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n' > "$HK_REN/old.md"
git -C "$HK_REN" add old.md
git -C "$HK_REN" commit -q -m old
git -C "$HK_REN" mv old.md new.md
echo "$HK_LEAK" >> "$HK_REN/new.md"
git -C "$HK_REN" add new.md
assert_eq "secret-scan: 시험 준비: 이름 변경으로 스테이징됨" "R" "$(git -C "$HK_REN" diff --cached --name-status | cut -c1)"
assert_eq "secret-scan: 이름을 바꾸며 수정한 파일을 막음" "2" "$(hk_scan "$HK_REN" "" "git commit -m x")"
assert_eq "secret-scan: --staged도 이름을 바꾼 파일을 막음" "2" "$(hk_staged "$HK_REN")"
HK_KO=$(hk_repo korean-repo)
echo "$HK_LEAK" > "$HK_KO/문서 안내.md"
git -C "$HK_KO" add .
assert_eq "secret-scan: 한글과 공백이 든 이름의 파일을 막음" "2" "$(hk_scan "$HK_KO" "" "git commit -m x")"
HK_OUT=$(echo '{"tool_input":{"command":"git commit -m x"}}' | CLAUDE_PROJECT_DIR="$HK_KO" bash .claude/hooks/secret-scan.sh 2>&1 >/dev/null || true)
assert_contains "secret-scan: 한글 이름의 파일을 읽어서 막음(꺼내지 못해 막은 것이 아님)" "$HK_OUT" "문서 안내.md (스테이징한 사본) 에 비밀 값"
assert_eq "secret-scan: --staged도 한글 이름의 파일을 막음" "2" "$(hk_staged "$HK_KO")"
HK_OUT=$( (cd "$HK_KO" && bash "$PROJECT_ROOT/.claude/hooks/secret-scan.sh" --staged) 2>&1 >/dev/null || true)
assert_contains "secret-scan: --staged도 한글 이름의 파일을 읽어서 막음" "$HK_OUT" "문서 안내.md (스테이징한 사본) 에 비밀 값"

# 병합 충돌을 `git add`로 풀면서 커밋하는 줄은 막지 않는다(충돌 항목은 인덱스에서 꺼낼 사본이 없다). 그 파일은 작업 트리의 내용으로 본다
HK_MERGE=$(hk_repo merge-repo)
git -C "$HK_MERGE" checkout -q -b side
echo 'side' > "$HK_MERGE/base.md"
git -C "$HK_MERGE" commit -q -am side
git -C "$HK_MERGE" checkout -q -
echo 'main' > "$HK_MERGE/base.md"
git -C "$HK_MERGE" commit -q -am main
git -C "$HK_MERGE" merge side >/dev/null 2>&1 || true
assert_contains "secret-scan: 시험 준비: 충돌이 풀리지 않은 항목이 있음" "$(git -C "$HK_MERGE" diff --cached --name-status)" "U"
echo 'resolved' > "$HK_MERGE/base.md"
assert_eq "secret-scan: 충돌을 풀면서 커밋하는 줄은 통과" "0" "$(hk_scan "$HK_MERGE" "" "git add base.md && git commit -m x")"
echo "$HK_LEAK" > "$HK_MERGE/base.md"
assert_eq "secret-scan: 충돌을 푼 내용에 비밀 값이 있으면 막음" "2" "$(hk_scan "$HK_MERGE" "" "git add base.md && git commit -m x")"

# 검사하지 못하면 통과시키지 않는다: 임시 디렉터리를 만들지 못할 때와 인덱스에서 꺼내지 못할 때
HK_OUT=$(echo '{"tool_input":{"command":"git commit -m x"}}' \
    | TMPDIR="$TEST_TMP/no-such-dir" CLAUDE_PROJECT_DIR="$HK_IDX2" bash .claude/hooks/secret-scan.sh 2>&1 >/dev/null; echo "exit=$?")
assert_contains "secret-scan: 임시 디렉터리를 만들지 못하면 exit 2" "$HK_OUT" "exit=2"
assert_contains "secret-scan: 임시 디렉터리를 만들지 못한 이유를 알림" "$HK_OUT" "임시 디렉터리를 만들지 못해"
mkdir -p "$TEST_TMP/fakebin"
printf '#!/bin/bash\ncase " $* " in *" checkout-index "*) exit 1 ;; esac\nexec %q "$@"\n' "$(command -v git)" > "$TEST_TMP/fakebin/git"
chmod +x "$TEST_TMP/fakebin/git"
HK_OUT=$(echo '{"tool_input":{"command":"git commit -m x"}}' \
    | PATH="$TEST_TMP/fakebin:$PATH" CLAUDE_PROJECT_DIR="$HK_IDX2" bash .claude/hooks/secret-scan.sh 2>&1 >/dev/null; echo "exit=$?")
assert_contains "secret-scan: 인덱스에서 꺼내지 못하면 exit 2" "$HK_OUT" "exit=2"
assert_contains "secret-scan: 인덱스에서 꺼내지 못한 이유를 알림" "$HK_OUT" "인덱스에서 파일을 꺼내지 못해"

# 인덱스에서 꺼낸 사본을 남기지 않는다(비밀 값이 들어 있을 수 있다)
HK_TMPD="$TEST_TMP/scan-tmp"
mkdir -p "$HK_TMPD"
echo '{"tool_input":{"command":"git commit -m x"}}' | TMPDIR="$HK_TMPD" CLAUDE_PROJECT_DIR="$HK_IDX" bash .claude/hooks/secret-scan.sh >/dev/null 2>&1
assert_eq "secret-scan: 인덱스에서 꺼낸 사본을 지움" "" "$(ls -A "$HK_TMPD")"

# 변수로 준 디렉터리는 따라가지 못한다. 저장소를 찾지 못하면 통과시키되 검사하지 못했다고 알린다
HK_OUT=$(jq -n --arg d "$HK_SYNC" '{tool_input: {command: "cd \"$REPO\" && git commit -m x"}, cwd: $d}' \
    | GIT_CEILING_DIRECTORIES="$TEST_TMP" CLAUDE_PROJECT_DIR="$HK_SYNC" bash .claude/hooks/secret-scan.sh 2>/dev/null; echo "exit=$?")
assert_contains "secret-scan: 저장소를 찾지 못한 커밋은 통과" "$HK_OUT" "exit=0"
assert_contains "secret-scan: 검사하지 못했다고 사용자에게 알림(systemMessage)" \
    "$(echo "${HK_OUT%exit=*}" | jq -r '.systemMessage // empty' 2>/dev/null)" "검사를 하지 않았습니다"
assert_contains "secret-scan: 검사하지 못했다고 Claude에게 알림(additionalContext)" \
    "$(echo "${HK_OUT%exit=*}" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)" "사용자에게 알립니다"
HK_OUT=$(jq -n --arg d "$HK_SYNC" '{tool_input: {command: "git commit -m x"}, cwd: $d}' \
    | GIT_CEILING_DIRECTORIES="$TEST_TMP" CLAUDE_PROJECT_DIR="$HK_SYNC" bash .claude/hooks/secret-scan.sh 2>&1; echo "exit=$?")
assert_eq "secret-scan: 저장소가 아닌 곳의 보통 커밋은 출력 없이 통과" "exit=0" "$HK_OUT"

# 이벤트를 JSON으로 읽지 못해도 커밋이면 검사한다
HK_STATUS=$(printf 'git commit -m x' | CLAUDE_PROJECT_DIR="$HK_SCAN" bash .claude/hooks/secret-scan.sh >/dev/null 2>&1; echo $?)
assert_eq "secret-scan: JSON이 아닌 입력에서도 커밋을 찾아 막음" "2" "$HK_STATUS"

# 손으로 돌리는 방식도 같은 종료 코드로 막는다
echo "$HK_LEAK" > "$TEST_TMP/files-leak.txt"
HK_STATUS=$(bash .claude/hooks/secret-scan.sh --files "$TEST_TMP/files-leak.txt" >/dev/null 2>&1; echo $?)
assert_eq "secret-scan: --files도 exit 2로 막음" "2" "$HK_STATUS"

# --- project-init 3.1.0의 훅 계약 ---
assert_contains "secret-scan: 커밋 범위 표식이 있음" "$(cat .claude/hooks/secret-scan.sh)" "project-init:commit-scope"
assert_contains "check-doc-sync: 모듈 규칙 표식이 있음" "$(cat .claude/hooks/check-doc-sync.sh)" "project-init:module-coverage"
# 도구 호출을 막는 종료 코드는 2뿐이다. exit 1은 막지 못하고 지나간다. 주석은 빼고 본다
if grep -v '^[[:space:]]*#' .claude/hooks/secret-scan.sh | sed -E 's/[[:space:]]#.*$//' | grep -qE '(^|[^A-Za-z0-9_.])exit[[:space:]]+1([^0-9]|$)'; then
    fail "secret-scan: exit 1을 쓰지 않음" "exit 1이 있음"
else
    pass "secret-scan: exit 1을 쓰지 않음"
fi

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
# 준비 스크립트를 실행해도 작업 트리가 변경으로 잡히지 않아야 한다. 권한을 잃은 사본에서 실행해 본다.
# deploy_guide.sh는 source로만 쓰는 파일이라 실행 권한을 받지 않는다(git도 그렇게 추적한다).
HK_SETUP="$TEST_TMP/setup-copy"
mkdir -p "$HK_SETUP/infra-cdk/node_modules"
cp --parents .claude/hooks/*.sh scripts/*.sh tests/run-all.sh tests/*/*.sh ./*.sh infra-tf/run-tests.sh infra-tf/scripts/*.sh "$HK_SETUP/"
chmod -x "$HK_SETUP"/*.sh "$HK_SETUP"/tests/run-all.sh
HK_OUT=$(bash "$HK_SETUP/scripts/setup.sh" 2>&1)
assert_eq "setup.sh: 사본에서 끝까지 실행됨" "0" "$?"
assert_contains "setup.sh: 준비 완료를 알림" "$HK_OUT" "준비 완료"
for HK_NAME in deploy_orca.sh deploy_orca_tf.sh upgrade_orca.sh get_pairing_url.sh set_password.sh cleanup.sh tests/run-all.sh; do
    assert_file_executable "setup.sh: $HK_NAME 에 실행 권한을 줌" "$HK_SETUP/$HK_NAME"
done
[ -x "$HK_SETUP/deploy_guide.sh" ] && fail "setup.sh: deploy_guide.sh에는 실행 권한을 주지 않음" "실행 권한이 생김" \
    || pass "setup.sh: deploy_guide.sh에는 실행 권한을 주지 않음"
# setup.sh가 실행 권한을 주는 자리의 스크립트는 git도 실행 파일로 추적한다. 다르면 setup.sh를 실행한 뒤 작업 트리가 변경으로 잡힌다
if git rev-parse --git-dir >/dev/null 2>&1; then
    assert_eq "setup.sh가 권한을 주는 스크립트 가운데 git이 실행 파일로 추적하지 않는 것은 deploy_guide.sh뿐" "deploy_guide.sh " \
        "$(git ls-files -s -- '.claude/hooks/*.sh' 'scripts/*.sh' tests/run-all.sh 'tests/*/*.sh' ':(glob)*.sh' infra-tf/run-tests.sh 'infra-tf/scripts/*.sh' \
            | awk '$1 != "100755" {print $4}' | sort | tr '\n' ' ')"
else
    skip "setup.sh가 권한을 주는 스크립트를 git이 실행 파일로 추적함" "git 저장소가 아님"
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
