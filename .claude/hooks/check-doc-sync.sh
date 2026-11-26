#!/bin/bash
# 파일을 수정한 뒤 함께 맞춰야 할 문서와 확인할 일을 알려 준다.
# PostToolUse(Write|Edit)가 부른다. Claude Code는 이벤트를 stdin의 JSON(tool_input.file_path, session_id)으로
# 넘긴다. 손으로 돌리거나 시험할 때는 경로를 인자로 준다.
#
# project-init:module-coverage
# 모듈 문서의 규칙: 수정한 파일의 디렉터리나 그 위의 디렉터리(모듈 루트까지)에 CLAUDE.md가 있으면 그 모듈은
# 문서가 있는 것으로 본다. 없을 때는 하위 디렉터리마다 문서를 요구하지 않고 모듈 루트의 CLAUDE.md 하나를
# 알린다. 이 프로젝트는 SOURCE_ROOTS의 디렉터리 하나하나가 모듈이다.
# 문서가 없다는 알림(모듈 문서, ADR)은 세션마다 한 번만 한다. 인자로 부르면 세션이 없어 매번 알린다.
# 연결된 작업 트리(git worktree, .claude/worktrees/)에서 수정한 파일은 그 작업 트리를 기준으로 본다.
# CLAUDE_PROJECT_DIR은 세션을 시작한 체크아웃에 머물기 때문이다. 다른 저장소의 파일은 따라가지 않는다.

SESSION_ID=""
if [ "$#" -ge 1 ]; then
    FILE_PATH="$1"
    FROM_HOOK=false
else
    [ -t 0 ] && exit 0
    RAW=$(cat)
    FILE_PATH=$(jq -r '.tool_input.file_path // empty' <<<"$RAW" 2>/dev/null)
    SESSION_ID=$(jq -r '.session_id // empty' <<<"$RAW" 2>/dev/null)
    FROM_HOOK=true
fi
[ -z "$FILE_PATH" ] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# common_dir <디렉터리>: 저장소가 함께 쓰는 git 디렉터리. 연결된 작업 트리와 원래 체크아웃에서 같은 값이다
common_dir() {
    (
        cd "$1" 2>/dev/null || exit 0
        top=$(git rev-parse --show-toplevel 2>/dev/null) && cd "$top" || exit 0
        dir=$(git rev-parse --git-common-dir 2>/dev/null) && cd "$dir" && pwd -P
    ) 2>/dev/null
}

# once <키>: 이 세션에서 이 키를 처음 알릴 때만 참이다. 세션 ID가 없으면(인자로 부른 경우) 늘 참이다
once() {
    [ -z "$SESSION_ID" ] && return 0
    local seen="${TMPDIR:-/tmp}/claude-doc-sync-${SESSION_ID//[^A-Za-z0-9_-]/}"
    grep -qxF -- "$1" "$seen" 2>/dev/null && return 1
    printf '%s\n' "$1" >> "$seen" 2>/dev/null
    return 0
}

# 절대 경로는 그 파일이 든 작업 트리를 기준으로 푼다. 그 작업 트리가 이 저장소의 것일 때만 그렇게 한다.
# 경로는 git이 알려 주므로 체크아웃 경로가 심볼릭 링크여도 상관없다.
FILE_DIR=$(dirname "$FILE_PATH")
if [[ "$FILE_PATH" == /* ]] && TOP=$(git -C "$FILE_DIR" rev-parse --show-toplevel 2>/dev/null) &&
    COMMON=$(common_dir "$TOP") && [ -n "$COMMON" ] && [ "$COMMON" = "$(common_dir "$PROJECT_DIR")" ]; then
    PREFIX=$(git -C "$PROJECT_DIR" rev-parse --show-prefix 2>/dev/null)   # 프로젝트가 저장소의 하위 디렉터리일 때
    FILE_PATH="$(git -C "$FILE_DIR" rev-parse --show-prefix 2>/dev/null)${FILE_PATH##*/}"
    [[ "$FILE_PATH" == "$PREFIX"* ]] || exit 0   # 이 프로젝트 밖의 파일
    FILE_PATH="${FILE_PATH#"$PREFIX"}"
    PROJECT_DIR="$TOP${PREFIX:+/${PREFIX%/}}"
else
    FILE_PATH="${FILE_PATH#"$PROJECT_DIR"/}"
    FILE_PATH="${FILE_PATH#./}"
fi
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# 이 프로젝트의 소스 디렉터리. 각각이 모듈이고 CLAUDE.md를 하나씩 가진다.
# 루트의 운영 스크립트(deploy_orca.sh 등)는 루트 CLAUDE.md가 다룬다. docs, tools, orca(upstream clone)는 소스가 아니다.
SOURCE_ROOTS="infra-cdk infra-tf scripts tests"

MESSAGES=()

for ROOT in $SOURCE_ROOTS; do
    if [[ "$FILE_PATH" == ${ROOT}/* ]]; then
        DIR=$(dirname "$FILE_PATH")
        FOUND_CLAUDE=false
        CHECK_DIR="$DIR"
        while [ "$CHECK_DIR" != "." ] && [ -n "$CHECK_DIR" ]; do
            if [ -f "$CHECK_DIR/CLAUDE.md" ]; then
                FOUND_CLAUDE=true
                break
            fi
            [ "$CHECK_DIR" = "$ROOT" ] && break
            CHECK_DIR=$(dirname "$CHECK_DIR")
        done
        if ! $FOUND_CLAUDE && once "$ROOT/CLAUDE.md"; then
            MESSAGES+=("[doc-sync] $ROOT/CLAUDE.md가 없습니다. 모듈 문서를 만듭니다.")
        fi
        break
    fi
done

# 어떤 파일을 수정했는지에 따라 함께 볼 문서와 확인할 일
case "$FILE_PATH" in
    */CLAUDE.md) ;;                 # 모듈 문서 자체를 수정한 경우는 알리지 않는다
    infra-cdk/lib/host/*)
        MESSAGES+=("[doc-sync] 기존 서버 설치 코드가 바뀌었습니다. 다음 배포에서 Custom::OrcaHostInstall이 서버에서 설치 스크립트를 다시 실행합니다(ScriptSha256). Orca 버전을 올리는 배포와 묶지 않고 이 변경만 먼저 배포합니다(docs/runbooks/upgrade-orca.md). 실행 의존 패키지를 바꿨으면 infra-cdk/lib/orca-stack.ts와 infra-tf/dedicated/user_data.sh.tftpl의 목록도 맞춥니다. Terraform 배포(infra-tf/attach)도 이 스크립트를 쓰고, 다음 apply에서 설치를 다시 실행합니다. 시험: npm test --prefix infra-cdk, bash infra-tf/run-tests.sh")
        ;;
    infra-cdk/lib/gate/*|infra-cdk/lib/functions/*)
        MESSAGES+=("[doc-sync] 접속 암호 게이트가 바뀌었습니다. 경로, 상태 코드, 쿠키가 달라졌으면 docs/api-reference.md와 docs/reference/security.md, docs/deployment.md의 보안 기능과 docs/configuration.md의 암호 게이트 경로(영어와 한국어 두 구역)를 수정합니다. infra-cdk/lib/gate가 바뀌면 묶음 주소가 달라져 서버에서 설치가 다시 실행됩니다. Terraform 배포도 같은 파일을 씁니다. 시험: npm test --prefix infra-cdk, bash infra-tf/run-tests.sh")
        ;;
    infra-cdk/lib/pairing/*)
        MESSAGES+=("[doc-sync] 페어링 출력 코드가 바뀌었습니다. orca-serve의 로그 문구(Web client URL, Pairing URL, Orca server ready)에 의존합니다. 출력 이름이나 동작이 달라졌으면 docs/usage.md의 스택 출력 설명, docs/configuration.md의 출력 표(영어와 한국어 두 구역), docs/api-reference.md를 수정합니다. 링크와 설정 코드는 로그와 문서에 남기지 않습니다. 시험: npm test --prefix infra-cdk")
        ;;
    infra-cdk/lib/*.ts|infra-cdk/bin/*.ts)
        MESSAGES+=("[doc-sync] 스택 코드가 바뀌었습니다. 배포 전에 차이(npx cdk diff 또는 변경 세트)를 보여 주고 승인을 받습니다. --attach 스택은 Claude Code가 실행 중인 서버에 설치되어 있을 수 있습니다. 리소스가 달라졌으면 docs/architecture.md의 Infrastructure 표와 docs/reference/iac.md를 수정합니다. 같은 구성을 만드는 Terraform 코드(infra-tf/)에도 같은 변경을 넣습니다. UserData를 바꿨으면 infra-tf/dedicated/user_data.sh.tftpl도 수정합니다(bash tests/run-all.sh structure가 검사).")
        ;;
    infra-tf/dedicated/user_data.sh.tftpl)
        MESSAGES+=("[doc-sync] 전용 서버의 UserData 템플릿이 바뀌었습니다. infra-cdk/lib/orca-stack.ts의 setupScript와 같은 내용이어야 합니다(bash tests/run-all.sh structure가 검사). 셸의 \${VAR}는 \$\${VAR}로, rpm의 %{...}는 %%{...}로 적습니다. 이미 만든 인스턴스에는 반영되지 않습니다. 시험: bash infra-tf/run-tests.sh")
        ;;
    infra-tf/*/tests/*|infra-tf/test/*|infra-tf/run-tests.sh)
        MESSAGES+=("[doc-sync] Terraform 시험이 바뀌었습니다. bash infra-tf/run-tests.sh 로 확인합니다. 새 시험 파일은 infra-tf/run-tests.sh의 머리말과 infra-tf/CLAUDE.md에 적습니다. 새 확인은 일부러 깨뜨렸을 때 실패하는지 봅니다.")
        ;;
    infra-tf/*)
        MESSAGES+=("[doc-sync] Terraform 코드가 바뀌었습니다. 배포 전에 계획(bash deploy_orca_tf.sh --plan)을 보여 주고 승인을 받습니다. 같은 구성을 만드는 CDK 스택(infra-cdk/lib/)과 맞는지 봅니다. 리소스나 변수가 달라졌으면 docs/reference/iac.md와 docs/terraform.md(영어와 한국어 두 구역)를 수정합니다. 시험: bash infra-tf/run-tests.sh")
        ;;
    infra-cdk/package.json)
        MESSAGES+=("[doc-sync] CDK 패키지가 바뀌었습니다. CLAUDE.md의 Tech Stack 버전을 맞춥니다(bash tests/run-all.sh structure가 검사). 배포 전에 템플릿 차이를 확인합니다.")
        ;;
    deploy_guide.sh)
        MESSAGES+=("[doc-sync] 두 배포 스크립트가 함께 쓰는 대화형 안내가 바뀌었습니다. deploy_orca.sh와 deploy_orca_tf.sh 양쪽의 동작이 달라집니다. 인스턴스 타입 목록은 infra-cdk/lib/orca-stack.ts의 목록과 같아야 하고, 서브넷 분류는 CDK의 Vpc.fromLookup과 같은 기준이어야 합니다. 시험: npm test --prefix infra-cdk (infra-cdk/test/deploy_test.py), bash infra-tf/run-tests.sh. 질문이 달라졌으면 docs/deployment.md의 전용 서버 설명(영어와 한국어 두 구역)과 .claude/skills/install-orca/SKILL.md의 선택 표를 수정합니다.")
        ;;
    deploy_orca.sh|deploy_orca_tf.sh|upgrade_orca.sh|cleanup.sh|set_password.sh|get_pairing_url.sh)
        MESSAGES+=("[doc-sync] 운영 스크립트가 바뀌었습니다. 옵션이나 동작이 달라졌으면 README의 요약과 안내 문서(docs/deployment.md, docs/terraform.md, docs/usage.md, docs/configuration.md. 영어와 한국어 두 구역), CLAUDE.md의 Key Commands, .claude/skills/install-orca/SKILL.md를 수정합니다. deploy_orca.sh는 infra-cdk/test/deploy_test.py가, upgrade_orca.sh는 infra-cdk/test/upgrade_test.py가, deploy_orca_tf.sh와 --tf 옵션은 infra-tf/test/의 시험(bash infra-tf/run-tests.sh)이 다룹니다.")
        ;;
    docs/infographic/*.py|docs/infographic/build.sh)
        MESSAGES+=("[doc-sync] 인포그래픽 소스가 바뀌었습니다. docs/infographic/build.sh 로 그림을 다시 만들고 검사 결과가 0건인지 봅니다. 한국어 글(T)과 영어 글(T_EN)을 함께 수정하고, 그림에 적은 값의 근거가 달라졌으면 docs/infographic/sources.md도 수정합니다.")
        ;;
    .claude/hooks/*|.claude/settings.json|scripts/*.sh|tests/*)
        MESSAGES+=("[doc-sync] 작업 도구가 바뀌었습니다. bash tests/run-all.sh 로 확인합니다. 새 확인은 일부러 깨뜨렸을 때 실패하는지 봅니다.")
        ;;
esac

# 아키텍처를 수정했는데 ADR이 하나도 없으면 알린다.
if [[ "$FILE_PATH" == docs/architecture.md ]]; then
    ADR_COUNT=$(find docs/decisions -name 'ADR-*.md' 2>/dev/null | wc -l)
    if [ "$ADR_COUNT" -eq 0 ] && once "ADR"; then
        MESSAGES+=("[doc-sync] ADR이 없습니다. 대안을 비교해 내린 결정이면 /add-adr로 docs/decisions/에 남깁니다.")
    fi
fi

[ "${#MESSAGES[@]}" -eq 0 ] && exit 0

if $FROM_HOOK; then
    # additionalContext는 끝난 도구 호출을 막지 않고 Claude에게 전달된다. stdout의 보통 글은 전달되지 않는다.
    printf '%s\n' "${MESSAGES[@]}" | jq -Rs '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: .}}'
else
    printf '%s\n' "${MESSAGES[@]}"
fi
exit 0
