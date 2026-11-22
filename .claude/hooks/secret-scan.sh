#!/bin/bash
# 커밋되기 전에 파일에 비밀 값과 환경 식별 값이 있는지 본다.
# 이 프로젝트의 비밀 값은 AWS 키 말고도 Orca 페어링 링크, 1회용 설정 코드, 접속 암호가 있다. 페어링 링크는
# 서버 접근 권한 그 자체다. 계정 ID, ARN, CloudFront 주소 같은 환경 식별 값도 저장소에 올리지 않는다.
#
# 실행 방식:
#   (인자 없음)       PreToolUse 훅(matcher: Bash). stdin의 이벤트 JSON을 읽고 `git commit` 명령일 때만 동작한다.
#                     exit 2면 도구 호출이 막히고 stderr의 이유가 Claude에게 전달된다.
#   --staged          git pre-commit 훅(scripts/install-hooks.sh가 설치). exit 1이면 커밋이 막힌다.
#   --files F [F..]   준 파일만 본다(손으로 돌리거나 시험할 때). 걸리면 exit 1.
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
                echo "[secret-scan] $file 에 비밀 값으로 보이는 문자열이 있습니다 (패턴: ${regex:0:30}...)" >&2
                found=1
            fi
        done
        for regex in "${IDENTIFIER_PATTERNS[@]}"; do
            if grep -IqP -- "$regex" "$file" 2>/dev/null; then
                echo "[secret-scan] $file 에 환경 식별 값이 있습니다 (패턴: ${regex:0:30}...)" >&2
                found=1
            fi
        done
    done
    return $found
}

report_blocked() {
    echo "" >&2
    echo "[secret-scan] 막음: 커밋하려는 파일에 비밀 값이나 환경 식별 값이 있습니다." >&2
    echo "[secret-scan] 페어링 링크, 설정 코드, 접속 암호, 키는 파일에서 지웁니다. 페어링 링크가 이미 다른 곳에 남았다면 orca-serve를 재시작해 새 링크로 바꿉니다." >&2
    echo "[secret-scan] 계정 ID, ARN, CloudFront 주소 같은 식별 값은 <account-id>, <cloudfront-domain> 같은 자리 표시로 바꿉니다." >&2
}

case "${1:-}" in
    --files)
        shift
        scan_files "$@" || { report_blocked; exit 1; }
        exit 0
        ;;
    --staged)
        mapfile -t FILES < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
        [ "${#FILES[@]}" -eq 0 ] && exit 0
        scan_files "${FILES[@]}" || { report_blocked; exit 1; }
        exit 0
        ;;
esac

# PreToolUse 방식
COMMAND=$(jq -r '.tool_input.command // empty' 2>/dev/null)
[[ "$COMMAND" =~ git[[:space:]]+([^|;&]*[[:space:]])?commit ]] || exit 0

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

mapfile -t FILES < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
# `git add ... && git commit`이나 `commit -a`, `commit -am`은 이 훅이 돈 뒤에 파일을 스테이징한다.
# 그래서 수정된 파일과 추적하지 않는(무시되지 않은) 파일도 함께 본다.
if [[ "$COMMAND" =~ git[[:space:]]+add || "$COMMAND" =~ commit[[:space:]]+(.*[[:space:]])?(-[a-zA-Z]*a[a-zA-Z]*|--all)([[:space:]]|$) ]]; then
    mapfile -t -O "${#FILES[@]}" FILES < <(git ls-files -m -o --exclude-standard 2>/dev/null)
fi
[ "${#FILES[@]}" -eq 0 ] && exit 0

mapfile -t FILES < <(printf '%s\n' "${FILES[@]}" | sort -u)
scan_files "${FILES[@]}" || { report_blocked; exit 2; }
exit 0
