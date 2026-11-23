#!/bin/bash
# 커밋되기 전에 파일에 비밀 값과 환경 식별 값이 있는지 본다.
# 이 프로젝트의 비밀 값은 AWS 키 말고도 Orca 페어링 링크, 1회용 설정 코드, 접속 암호가 있다. 페어링 링크는
# 서버 접근 권한 그 자체다. 계정 ID, ARN, CloudFront 주소 같은 환경 식별 값도 저장소에 올리지 않는다.
#
# project-init:commit-scope
# 이미 스테이징한 것만이 아니라 그 커밋에 들어갈 내용을 본다.
#   스테이징한 파일           인덱스의 사본을 본다(이름 변경과 종류 변경 포함). 스테이징한 뒤에 작업 트리의
#                             파일이 달라졌어도 커밋에 들어가는 것은 인덱스의 사본이다.
#   commit -a, --all, -am     추적하는 파일의 수정본(작업 트리)도 본다.
#   commit <경로>             그 경로의 수정본(작업 트리)도 본다. '*.py' 같은 글로브도 받는다.
#   같은 줄의 git add, stage  추적하는 파일의 수정본과 추적하지 않는(무시되지 않은) 파일도 본다. 일부러 넓게
#                             잡는다. 막을 때 어느 파일인지 알린다.
#   같은 줄의 git add -f      이름을 준 무시된 파일도 본다(cdk-outputs.json 같은 파일). 이름을 주지 않았으면
#                             무시된 파일을 모두 본다.
# git은 커밋이 실행될 자리에서 부른다. 이벤트의 cwd에서 시작해 같은 줄의 앞선 cd와 pushd, git -C,
# --git-dir, --work-tree를 따라간다.
# 한계: 명령의 글자를 읽어 판단한다. rebase, cherry-pick, am, merge, git alias, 스크립트가 만드는 커밋은 보지
# 못하고 변수로 준 디렉터리($DIR)는 따라가지 못한다. 이 저장소에서는 그런 커밋도 git pre-commit 훅이 본다.
#
# 실행 방식:
#   (인자 없음)       PreToolUse 훅(matcher: Bash). stdin의 이벤트 JSON(tool_input.command, cwd)을 읽고
#                     `git commit` 명령일 때만 동작한다. 그 밖의 명령은 출력 없이 통과한다.
#   --staged          git pre-commit 훅(scripts/install-hooks.sh가 설치). 인덱스의 사본을 본다.
#   --files F [F..]   준 파일만 본다(손으로 돌리거나 시험할 때).
# 걸리면 어느 방식이든 exit 2로 끝난다. PreToolUse에서는 exit 2만 도구 호출을 막고 stderr의 이유가 Claude에게
# 전달된다. git pre-commit 훅은 종료 코드가 0이 아니면 커밋을 막는다.
#
# 문서도 검사한다(*.md를 건너뛰지 않는다). 배포 출력을 문서에 붙여 넣다가 링크가 들어가기 쉽기 때문이다.

PATTERNS=(
    'AKIA[0-9A-Z]{16}'                                                  # AWS Access Key ID
    'aws_secret_access_key\s{0,5}[=:]\s{0,5}["\x27]?[A-Za-z0-9/+=]{40}' # AWS Secret Key(앞뒤 문맥 포함)
    'sk-ant-[A-Za-z0-9-]{90,}'                                          # Anthropic API Key
    'ghp_[A-Za-z0-9]{36}'                                               # GitHub Personal Access Token
    'gho_[A-Za-z0-9]{36}'                                               # GitHub OAuth Token
    'github_pat_[A-Za-z0-9_]{82}'                                       # GitHub Fine-grained PAT
    'xoxb-[0-9]+-[A-Za-z0-9]+'                                          # Slack Bot Token
    'AIza[A-Za-z0-9_-]{35}'                                             # Google API Key
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'                                # 개인 키
    'orca://pair\?code=[A-Za-z0-9_-]{80,}'                              # Orca 페어링 코드(실제 값은 500자 안팎)
    'orca%3A%2F%2Fpair%3Fcode%3D[A-Za-z0-9_%-]{80,}'                    # 브라우저 링크 안의 페어링 코드
    'gate-setup=[A-Za-z0-9_-]{32}(?![A-Za-z0-9_-])'                     # 1회용 설정 코드(token_urlsafe(24)는 32자)
    'password\s*[:=]\s*["\x27][^"\x27\s]{8,}'                           # 비밀번호 대입
    'secret\s*[:=]\s*["\x27][^"\x27\s]{8,}'                             # secret 대입
    'api[_-]?key\s*[:=]\s*["\x27][^"\x27\s]{8,}'                        # API 키 대입
)

# AWS 환경을 식별하는 값. 비밀은 아니지만 올리지 않는다. 문서와 예시에는 <account-id>, <cloudfront-domain> 같은 자리 표시를 쓴다.
# 111122223333과 123456789012는 AWS 문서가 쓰는 예시 계정이고, 0123456789abcdef로 시작하는 ID는 예시 값이라 막지 않는다.
IDENTIFIER_PATTERNS=(
    'arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:(?!111122223333:|123456789012:)[0-9]{12}:'                  # 계정이 든 ARN
    '(account=|"ownerAccountId": "|"Account": "|AWSLogs/)(?!111122223333|123456789012)[0-9]{12}(?![0-9])' # 그 밖의 자리의 계정 ID
    '\bd[a-z0-9]{12,14}\.cloudfront\.net\b'                                                             # CloudFront 도메인
    '\b[A-Za-z0-9-]+\.[a-z0-9-]+\.elb\.amazonaws\.com\b'                                               # 로드 밸런서 주소
    '\b(vpc|subnet|sgr|sg|eni|eipalloc|nat|igw|rtb|vpce|i)-(?!0123456789abcdef)[0-9a-f]{8,17}\b'       # VPC, 서브넷, 보안 그룹, 인스턴스 ID
    'key-value-store/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'                     # CloudFront KeyValueStore ID
)

# 검사하지 않는 파일: 자리만 있는 템플릿, 잠금 파일, 그리고 검사기 자신의 시험 자료
SKIP_PATTERNS=('.env.example' '*secret-scan.sh' '*package-lock.json'
               'tests/fixtures/*' 'tests/hooks/test-secret-patterns.sh')

# 내용과 상관없이 커밋하면 안 되는 파일. cdk-outputs.json에는 페어링 링크가, cdk.context.json에는 계정 ID와 VPC ID가 들어 있다.
# 글로브 패턴이다. * 는 / 도 포함해 맞춘다. Terraform 상태 파일에는 X-Custom-Secret 값이, 입력 값과
# 계획 파일에는 인스턴스 ID와 ARN이 들어 있다.
FORBIDDEN_PATHS=('.env' '.claude/settings.local.json' 'cdk-outputs.json' 'infra-cdk/cdk.context.json'
    'infra-tf/*.tfstate' 'infra-tf/*.tfstate.*' 'infra-tf/*.tfvars' 'infra-tf/*.tfvars.json' 'infra-tf/*.tfplan')

# 인덱스의 사본을 볼 때 알림에 붙이는 말. 작업 트리의 파일과 내용이 다를 수 있어 구별한다.
COPY_NOTE=""

# 인덱스의 사본을 꺼내 두는 임시 디렉터리. 훅이 중간에 끊겨도 남기지 않는다.
SCAN_TMP=""
trap '[ -n "$SCAN_TMP" ] && rm -rf "$SCAN_TMP"' EXIT

# scan_files <경로...>: 지금 디렉터리를 기준으로 준 파일을 본다. 걸린 것이 있으면 0이 아닌 값을 돌려준다.
scan_files() {
    local found=0 file pattern regex skip combined status
    local -a candidates=() hits=()
    for file in "$@"; do
        skip=false
        for pattern in "${SKIP_PATTERNS[@]}"; do
            [[ "$file" == $pattern ]] && skip=true && break
        done
        $skip && continue
        for pattern in "${FORBIDDEN_PATHS[@]}"; do
            # shellcheck disable=SC2053
            if [[ "$file" == $pattern ]]; then
                echo "[secret-scan] $file 은 커밋하면 안 되는 파일입니다" >&2
                found=1
            fi
        done
        [ -f "$file" ] && candidates+=("$file")
    done
    [ "${#candidates[@]}" -eq 0 ] && return $found

    # 모든 패턴을 하나로 묶어 먼저 본다. 걸린 파일만 패턴별로 다시 봐서 무엇이 걸렸는지 알린다.
    combined=$(printf '(?:%s)|' "${PATTERNS[@]}" "${IDENTIFIER_PATTERNS[@]}")
    combined="${combined%|}"
    # 패턴이 컴파일되지 않으면 grep이 아무것도 찾지 못한 것처럼 보인다. 그 경우 통과시키지 않고 막는다.
    status=0
    echo "x" | grep -qP -- "$combined" 2>/dev/null || status=$?
    if [ "$status" -gt 1 ]; then
        echo "[secret-scan] 검사 패턴에 오류가 있어 검사할 수 없습니다 (grep 상태 $status)" >&2
        return 1
    fi
    # -I는 바이너리 파일을 건너뛴다
    mapfile -d '' -t hits < <(printf '%s\0' "${candidates[@]}" | xargs -0 grep -IlZP -- "$combined" 2>/dev/null)
    for file in "${hits[@]}"; do
        for regex in "${PATTERNS[@]}"; do
            if grep -IqP -- "$regex" "$file" 2>/dev/null; then
                echo "[secret-scan] $file$COPY_NOTE 에 비밀 값으로 보이는 문자열이 있습니다 (패턴: ${regex:0:30}...)" >&2
                found=1
            fi
        done
        for regex in "${IDENTIFIER_PATTERNS[@]}"; do
            if grep -IqP -- "$regex" "$file" 2>/dev/null; then
                echo "[secret-scan] $file$COPY_NOTE 에 환경 식별 값이 있습니다 (패턴: ${regex:0:30}...)" >&2
                found=1
            fi
        done
    done
    return $found
}

# scan_index <경로...>: 인덱스에 있는 사본을 임시 디렉터리에 꺼내 본다. 저장소의 맨 위에서 부른다.
# 꺼내지 못하면 검사하지 못한 것이므로 통과시키지 않고 막는다.
scan_index() {
    [ "$#" -eq 0 ] && return 0
    local status=0
    if ! SCAN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/secret-scan.XXXXXX"); then
        SCAN_TMP=""
        echo "[secret-scan] 임시 디렉터리를 만들지 못해 스테이징한 파일을 검사할 수 없습니다" >&2
        return 1
    fi
    if printf '%s\0' "$@" | git checkout-index --prefix="$SCAN_TMP/" -z --stdin >/dev/null 2>&1; then
        (cd "$SCAN_TMP" && COPY_NOTE=" (스테이징한 사본)" && scan_files "$@") || status=1
    else
        echo "[secret-scan] 인덱스에서 파일을 꺼내지 못해 스테이징한 파일을 검사할 수 없습니다" >&2
        status=1
    fi
    rm -rf "$SCAN_TMP"
    SCAN_TMP=""
    return $status
}

report_blocked() {
    echo "" >&2
    echo "[secret-scan] 막음: 커밋하려는 파일에 비밀 값이나 환경 식별 값이 있습니다." >&2
    echo "[secret-scan] 페어링 링크, 설정 코드, 접속 암호, 키는 파일에서 지웁니다. 페어링 링크가 이미 다른 곳에 남았다면 orca-serve를 재시작해 새 링크로 바꿉니다." >&2
    echo "[secret-scan] 계정 ID, ARN, CloudFront 주소 같은 식별 값은 <account-id>, <cloudfront-domain> 같은 자리 표시로 바꿉니다." >&2
}

# warn_unscanned <이유>: 커밋을 통과시키되 검사하지 못했다고 알린다. exit 0인 훅의 stderr는 사용자에게도
# Claude에게도 전달되지 않아서 systemMessage(사용자)와 additionalContext(Claude)로 알린다.
warn_unscanned() {
    echo "[secret-scan] $1. 이 커밋은 비밀 값 검사를 하지 않았습니다." >&2
    printf '{"systemMessage": "[secret-scan] %s. 이 커밋은 비밀 값 검사를 하지 않았습니다.", "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "[secret-scan] %s. 이 커밋은 비밀 값 검사를 하지 않았습니다. 사용자에게 알립니다."}}\n' "$1" "$1"
    exit 0
}

case "${1:-}" in
    --files)
        shift
        scan_files "$@" || { report_blocked; exit 2; }
        exit 0
        ;;
    --staged)
        TOP=$(git rev-parse --show-toplevel 2>/dev/null) && cd "$TOP" 2>/dev/null || exit 0
        # --diff-filter=du는 삭제와 충돌이 풀리지 않은 항목을 뺀다. 추가, 수정, 이름 변경, 종류 변경, 복사가 남는다.
        # 충돌이 풀리지 않은 항목은 인덱스에 사본이 하나로 정해지지 않았고 git도 그 상태로는 커밋하지 않는다.
        # -z는 이름을 NUL로 나눠 준다. -z가 없으면 한글이나 공백이 든 이름을 git이 따옴표로 감싸 출력한다.
        mapfile -d '' -t FILES < <(git diff -z --cached --name-only --diff-filter=du 2>/dev/null)
        scan_index "${FILES[@]}" || { report_blocked; exit 2; }
        exit 0
        ;;
esac

# --- PreToolUse 방식: 명령 읽기 ---
[ -t 0 ] && exit 0
RAW=$(cat)
# Bash 호출의 대부분은 커밋이 아니다. jq를 띄우기 전에 끝낸다.
case "$RAW" in *commit*) ;; *) exit 0 ;; esac
COMMAND=$(jq -r '.tool_input.command // empty' <<<"$RAW" 2>/dev/null)
HOOK_CWD=$(jq -r '.cwd // empty' <<<"$RAW" 2>/dev/null)
# jq가 없거나 JSON을 읽지 못하면 COMMAND가 비어 있다. 그때는 이벤트 원문에서 커밋을 찾아 검사를 이어 간다.
[ -n "$COMMAND" ] || COMMAND="$RAW"

# --- 커밋일 때만 동작한다: `git commit`, `git -C dir commit`, `git -c k=v commit`. 다른 명령과 이어 써도 찾는다 ---
# 셸의 낱말 하나: 따옴표 없는 글자, \x, $(...), `...`, "...", '...'.
# 괄호식([...])이 역슬래시로 끝나지 않게 써서, 괄호식 안의 \ 를 이스케이프로 읽는 정규식 라이브러리에서도 컴파일된다.
SQ="'"
WORD='([^[:space:]"\;&|<>()`'"$SQ"']|\\.|\$\([^)]*\)|`[^`]*`|"([^\"]|\\.)*"|'"$SQ[^$SQ]*$SQ"')+'
LEADING_WORD_RE='^[[:space:]]*('"$WORD"')'
VALUE_FLAG_RE='^-[^mFCct]*[mFCct]$'   # -m, -am, -F, -C, -c, -t: 값이 다음 낱말에 온다
GIT_OPTS='([[:space:]]+(-[cC][[:space:]]+'"$WORD"'|--(git-dir|work-tree|namespace|config-env|exec-path|super-prefix)[[:space:]]+'"$WORD"'|--?[[:alnum:]]('"$WORD"')?))*'
COMMIT_RE='(^|[^[:alnum:]_.-])git'"$GIT_OPTS"'[[:space:]]+commit([^[:alnum:]_-]|$)'
ADD_RE='(^|[^[:alnum:]_.-])git'"$GIT_OPTS"'[[:space:]]+(add|stage)([^[:alnum:]_-]|$)'
# cd와 pushd, 그리고 그 디렉터리(BASH_REMATCH[5]). 앞의 -L, -P, -e, -@, -- 는 옵션이다
CD_RE='(^|[;&|(){}'$'\n''])[[:space:]]*(cd|pushd)[[:space:]]+((-[LPe@]+|--)[[:space:]]+)*('"$WORD"')'
[[ "$COMMAND" =~ $COMMIT_RE ]] || exit 0
COMMIT_MATCH="${BASH_REMATCH[0]}"

# split_words <글>: 글의 앞에서부터 셸 낱말을 WORDS에 담는다. 제어 연산자(; & | < > 괄호)나 짝이 맞지 않는
# 따옴표를 만나면 멈춘다
split_words() {
    local rest="$1"
    WORDS=()
    while [[ "$rest" =~ $LEADING_WORD_RE ]]; do
        WORDS+=("${BASH_REMATCH[1]}")
        rest="${rest:${#BASH_REMATCH[0]}}"
    done
}
# args_after <글> <맞은 부분>: 맞은 부분 뒤의 글. 정규식이 끝에서 한 글자를 더 가져갔으면 그 글자를 돌려놓는다
args_after() {
    local after="${1#*"$2"}"
    case "$2" in
        *[[:alnum:]]) ;;
        *) after="${2#"${2%?}"}$after" ;;
    esac
    printf '%s' "$after"
}
# unquote <낱말>: 따옴표와 역슬래시를 떼고 맨 앞의 ~ 를 편다. $ 나 ` 가 든 낱말은 값을 알 수 없어 실패한다
unquote() {
    local w="$1"
    case "$w" in *'$'*|*'`'*) return 1 ;; esac
    w="${w//\"/}"; w="${w//\'/}"; w="${w//\\/}"
    case "$w" in "~") w="$HOME" ;; "~/"*) w="$HOME/${w#\~/}" ;; esac
    printf '%s' "$w"
}
# chdir <낱말>: cd나 -C가 가리키는 곳으로 간다
UNRESOLVED=false
chdir() {
    local dir
    dir=$(unquote "$1") || { UNRESOLVED=true; return 0; }
    cd "$dir" >/dev/null 2>&1 || true
}
# follow_cd <글>: 글에 있는 cd와 pushd를 순서대로 따라간다
follow_cd() {
    local text="$1"
    while [[ "$text" =~ $CD_RE ]]; do
        chdir "${BASH_REMATCH[5]}"
        text="${text#*"${BASH_REMATCH[0]}"}"
    done
}

# --- git을 커밋이 실행될 자리에서 부른다: Claude의 cwd, 앞선 cd와 pushd, 그리고 -C와 --git-dir ---
# 이벤트에 cwd가 없으면(시험, 손으로 돌릴 때) 프로젝트 디렉터리에서 시작한다.
START_DIR="${HOOK_CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cd "$START_DIR" 2>/dev/null || exit 0
follow_cd "${COMMAND%%"$COMMIT_MATCH"*}"
split_words "${COMMIT_MATCH#*git}"
LOCATIONS=()   # --git-dir=<dir>와 --work-tree=<dir>
i=0
while [ "$i" -lt "${#WORDS[@]}" ]; do
    next="${WORDS[$((i + 1))]:-}"
    case "${WORDS[$i]}" in
        -C) chdir "$next"; i=$((i + 1)) ;;
        --git-dir|--work-tree) LOCATIONS+=("${WORDS[$i]}=$next"); i=$((i + 1)) ;;
        --git-dir=*|--work-tree=*) LOCATIONS+=("${WORDS[$i]}") ;;
        -c|--namespace|--config-env|--exec-path|--super-prefix) i=$((i + 1)) ;;
    esac
    i=$((i + 1))
done
# git은 이 둘을 모든 -C를 적용한 뒤의 자리에서 읽는다. 그래서 여기서 절대 경로로 바꾼다
for location in "${LOCATIONS[@]}"; do
    if dir=$(unquote "${location#*=}") && dir=$(cd "$dir" 2>/dev/null && pwd); then
        case "$location" in --git-dir=*) export GIT_DIR="$dir" ;; *) export GIT_WORK_TREE="$dir" ;; esac
    else
        UNRESOLVED=true
    fi
done
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    $UNRESOLVED && warn_unscanned "커밋이 실행될 저장소를 찾지 못했습니다"
    exit 0
fi

# --- 이 커밋에 무엇이 들어갈지 정한다 ---
split_words "$(args_after "$COMMAND" "$COMMIT_MATCH")"
SCAN_TRACKED=false
PATHSPECS=()
value_next=false
paths_only=false
for word in "${WORDS[@]}"; do
    if $value_next; then value_next=false; continue; fi
    plain="${word//\"/}"; plain="${plain//\'/}"
    if ! $paths_only; then
        case "$plain" in
            --) paths_only=true; continue ;;
            --all) SCAN_TRACKED=true; continue ;;
            --message|--file|--reuse-message|--reedit-message|--template|--author|--date|--cleanup|--trailer|--fixup|--squash)
                value_next=true; continue ;;
            --*) continue ;;
            -*)
                case "$plain" in -*a*) SCAN_TRACKED=true ;; esac
                [[ "$plain" =~ $VALUE_FLAG_RE ]] && value_next=true
                continue ;;
        esac
    fi
    # 있는 경로이거나 글로브면 경로 지정으로 본다. 따옴표로 감싼 글로브도 git이 직접 편다
    path=$(unquote "$word") && { [ -e "$path" ] || case "$path" in *[*?[]*) true ;; *) false ;; esac; } &&
        PATHSPECS+=("$path")
done

# add_directory <add 앞의 글> <add에 맞은 부분>: `git add`가 실행될 디렉터리를 출력한다. Claude의 cwd에서
# 시작해 그 앞의 cd와 pushd, 그리고 add 자신의 -C를 따라간다. 서브셸이라 훅의 자리는 바뀌지 않는다.
add_directory() (
    cd "$START_DIR" 2>/dev/null
    follow_cd "$1"
    split_words "${2#*git}"
    i=0
    while [ "$i" -lt "${#WORDS[@]}" ]; do
        case "${WORDS[$i]}" in
            -C) chdir "${WORDS[$((i + 1))]:-}"; i=$((i + 1)) ;;
            -c|--git-dir|--work-tree|--namespace|--config-env|--exec-path|--super-prefix) i=$((i + 1)) ;;
        esac
        i=$((i + 1))
    done
    pwd -P
)

# 같은 줄의 `git add`와 `git stage`: 스테이징될 수 있는 것을 모두 본다. `add -f`면 이름을 준 무시된 파일도
# 본다(이름이 없으면 무시된 파일 전부)
ADDS=false
FORCED=()   # 절대 경로. add마다 실행되는 디렉터리가 다를 수 있다
FORCE_ALL=false
rest="$COMMAND"
while [[ "$rest" =~ $ADD_RE ]]; do
    ADDS=true
    SCAN_TRACKED=true
    add_match="${BASH_REMATCH[0]}"
    before="${COMMAND%"$rest"}${rest%%"$add_match"*}"
    split_words "$(args_after "$rest" "$add_match")"
    rest="${rest#*"$add_match"}"
    force=false
    add_paths=()
    for word in "${WORDS[@]}"; do
        plain="${word//\"/}"; plain="${plain//\'/}"
        case "$plain" in
            --force) force=true ;;
            --*) ;;
            -*f*) force=true ;;
            -*) ;;
            *) path=$(unquote "$word") && add_paths+=("$path") ;;
        esac
    done
    if $force && [ ${#add_paths[@]} -eq 0 ]; then
        FORCE_ALL=true
    elif $force; then
        add_dir=$(add_directory "$before" "$add_match")
        for path in "${add_paths[@]}"; do
            case "$path" in /*) FORCED+=("$path") ;; *) FORCED+=("$add_dir/$path") ;; esac
        done
    fi
done

# 경로 지정은 이 디렉터리를 기준으로 한다. git diff는 어디서 불러도 저장소 기준의 경로를 출력한다.
COMMIT_DIR="$PWD"
TOP=$(git rev-parse --show-toplevel 2>/dev/null) && cd "$TOP" 2>/dev/null || exit 0

# 스테이징한 파일(인덱스의 사본으로 본다). --diff-filter=du와 -z는 위의 --staged와 같은 이유다.
# 충돌을 `git add`로 풀면서 커밋하는 줄에서는 그 파일을 아래의 작업 트리 목록으로 본다.
mapfile -d '' -t INDEX_FILES < <(git diff -z --cached --name-only --diff-filter=du 2>/dev/null)

# 작업 트리의 파일로 볼 것
work_list() {
    local spec
    if $SCAN_TRACKED; then
        git diff -z --name-only --diff-filter=d 2>/dev/null
    fi
    # 경로마다 git을 따로 부른다. 저장소 밖의 경로는 치명적 오류라 그 경로만 빠지게 한다
    for spec in "${PATHSPECS[@]}"; do
        git -C "$COMMIT_DIR" diff -z --name-only --diff-filter=d -- "$spec" 2>/dev/null
    done
    if $ADDS; then
        git ls-files -z --others --exclude-standard 2>/dev/null
    fi
    if $FORCE_ALL; then
        git ls-files -z --others --ignored --exclude-standard 2>/dev/null
    else
        for spec in "${FORCED[@]}"; do
            git -C "$COMMIT_DIR" ls-files -z --full-name --others --ignored --exclude-standard -- "$spec" 2>/dev/null
        done
    fi
}
mapfile -d '' -t WORK_FILES < <(work_list | sort -zu)

# --- 검사 ---
BLOCKED=false
scan_index "${INDEX_FILES[@]}" || BLOCKED=true
scan_files "${WORK_FILES[@]}" || BLOCKED=true
if $BLOCKED; then
    report_blocked
    exit 2
fi
exit 0
