#!/bin/bash
# 프로젝트 구조와 문서의 시험 (tests/run-all.sh가 source로 불러 실행한다)
# 이 파일의 변수와 함수는 ST_, st_로 시작한다. 실행기의 변수(TOTAL, PASSED 등)와 겹치면 안 된다.

# 두 언어 문서에서 한 언어 구역만 꺼낸다. $1 파일, $2 english|korean
st_section() {
    if [ "$2" = english ]; then
        sed -n '/<a id="english"><\/a>/,/<a id="korean"><\/a>/p' "$1" | sed '$d'
    else
        sed -n '/<a id="korean"><\/a>/,$p' "$1"
    fi
}
# 코드 블록 안의 줄을 뺀다(코드 주석의 #을 제목으로 세지 않게)
st_outside_code() { awk '/^```/{inside=!inside; next} !inside'; }
st_count() { grep -cE -- "$1" || true; }
ST_HANGUL='[\x{AC00}-\x{D7A3}]'

# --- 루트의 파일 ---
for ST_FILE in CLAUDE.md README.md CHANGELOG.md .gitignore .env.example .editorconfig .mcp.json; do
    assert_file_exists "루트: $ST_FILE" "$ST_FILE"
done
assert_json_valid ".mcp.json은 JSON" ".mcp.json"
assert_eq ".mcp.json에 mcpServers 키" "object" "$(jq -r '.mcpServers | type' .mcp.json 2>/dev/null || true)"

# --- CLAUDE.md: 정해진 구역과 코드에서 읽은 버전 ---
for ST_HEAD in "Overview" "Tech Stack" "Project Structure" "Conventions" "Key Commands" "Auto-Sync Rules" "Implementation References"; do
    grep -qx "## $ST_HEAD" CLAUDE.md && pass "CLAUDE.md: 구역 '$ST_HEAD'" || fail "CLAUDE.md: 구역 '$ST_HEAD'" "제목 없음"
done
ST_CDK_LIB=$(jq -r '.dependencies["aws-cdk-lib"]' infra-cdk/package.json | tr -d '^~')
ST_CDK_CLI=$(jq -r '.devDependencies["aws-cdk"]' infra-cdk/package.json | tr -d '^~')
assert_contains "CLAUDE.md: aws-cdk-lib 버전이 package.json과 같음 ($ST_CDK_LIB)" "$(cat CLAUDE.md)" "aws-cdk-lib $ST_CDK_LIB"
assert_contains "CLAUDE.md: aws-cdk 버전이 package.json과 같음 ($ST_CDK_CLI)" "$(cat CLAUDE.md)" "aws-cdk $ST_CDK_CLI"

# --- 모듈 문서: 훅의 SOURCE_ROOTS와 실제 디렉터리가 맞는지 ---
ST_ROOTS=$(sed -n 's/^SOURCE_ROOTS="\(.*\)"/\1/p' .claude/hooks/check-doc-sync.sh)
[ -n "$ST_ROOTS" ] && pass "check-doc-sync: SOURCE_ROOTS를 읽음 ($ST_ROOTS)" || fail "check-doc-sync: SOURCE_ROOTS를 읽음" "값 없음"
for ST_ROOT in $ST_ROOTS; do
    assert_file_exists "모듈 문서: $ST_ROOT/CLAUDE.md" "$ST_ROOT/CLAUDE.md"
    for ST_HEAD in "Role" "Key Files" "Rules"; do
        grep -qx "## $ST_HEAD" "$ST_ROOT/CLAUDE.md" 2>/dev/null && pass "$ST_ROOT/CLAUDE.md: 구역 '$ST_HEAD'" \
            || fail "$ST_ROOT/CLAUDE.md: 구역 '$ST_HEAD'" "제목 없음"
    done
done
# 새 최상위 디렉터리가 생기면 소스인지 아닌지 정해야 한다. orca는 분석용 upstream clone이다(.gitignore).
ST_NON_SOURCE="docs tools orca"
ST_UNKNOWN=""
for ST_DIR in */; do
    ST_DIR="${ST_DIR%/}"
    case " $ST_ROOTS $ST_NON_SOURCE " in *" $ST_DIR "*) ;; *) ST_UNKNOWN="$ST_UNKNOWN $ST_DIR" ;; esac
done
assert_eq "최상위 디렉터리가 모두 소스 또는 비소스 목록에 있음" "" "$ST_UNKNOWN"

# 문서가 적은 경로가 있는지만 보면, 새로 생긴 소스 파일이 문서에 빠져도 통과한다. 그래서 파일 이름을 문서에서 찾는다.
# $1 문서, 나머지는 파일 경로. 문서에 이름(basename)이 없는 파일을 돌려준다.
st_unnamed() {
    local doc="$1" file missing=""
    shift
    for file in "$@"; do
        grep -qF -- "$(basename "$file")" "$doc" 2>/dev/null || missing="$missing $file"
    done
    printf '%s' "$missing"
}
mapfile -t ST_FILES < <(find infra-cdk/bin infra-cdk/lib infra-cdk/test -type f \
    \( -name '*.ts' -o -name '*.py' -o -name '*.sh' -o -name '*.mjs' -o -path '*/functions/*.js' \) -not -name '*.d.ts' | sort)
[ "${#ST_FILES[@]}" -ge 15 ] && pass "infra-cdk: 소스 파일을 찾음 (${#ST_FILES[@]}개)" || fail "infra-cdk: 소스 파일을 찾음" "${#ST_FILES[@]}개"
assert_eq "infra-cdk/CLAUDE.md: 소스 파일을 모두 적음" "" "$(st_unnamed infra-cdk/CLAUDE.md "${ST_FILES[@]}")"
# infra-tf에는 main.tf, variables.tf처럼 이름이 같은 파일이 여럿이다. 이름이 아니라 모듈 기준 경로로 찾는다.
mapfile -t ST_FILES < <(find infra-tf -type f \( -name '*.tf' -o -name '*.tftpl' -o -name '*.hcl' -o -name '*.sh' -o -name '*.py' \) \
    -not -path '*/.terraform/*' -not -path '*/.build/*' | sed 's#^infra-tf/##' | sort)
[ "${#ST_FILES[@]}" -ge 25 ] && pass "infra-tf: 소스 파일을 찾음 (${#ST_FILES[@]}개)" || fail "infra-tf: 소스 파일을 찾음" "${#ST_FILES[@]}개"
ST_MISSING=""
for ST_FILE in "${ST_FILES[@]}"; do
    grep -qF -- "\`$ST_FILE\`" infra-tf/CLAUDE.md || ST_MISSING="$ST_MISSING $ST_FILE"
done
assert_eq "infra-tf/CLAUDE.md: 소스 파일을 모두 경로로 적음" "" "$ST_MISSING"
mapfile -t ST_FILES < <(find scripts -maxdepth 1 -type f -not -name CLAUDE.md | sort)
assert_eq "scripts/CLAUDE.md: 스크립트를 모두 적음" "" "$(st_unnamed scripts/CLAUDE.md "${ST_FILES[@]}")"
mapfile -t ST_FILES < <(find tests -type f -not -name CLAUDE.md | sort)
assert_eq "tests/CLAUDE.md: 시험 파일을 모두 적음" "" "$(st_unnamed tests/CLAUDE.md "${ST_FILES[@]}")"
mapfile -t ST_FILES < <(find . -maxdepth 1 -type f -name '*.sh' | sed 's#^\./##' | sort)
[ "${#ST_FILES[@]}" -ge 6 ] && pass "루트: 운영 스크립트를 찾음 (${#ST_FILES[@]}개)" || fail "루트: 운영 스크립트를 찾음" "${#ST_FILES[@]}개"
assert_eq "CLAUDE.md: 루트의 운영 스크립트를 모두 적음" "" "$(st_unnamed CLAUDE.md "${ST_FILES[@]}")"

# --- 자산 디렉터리에 문서가 섞이지 않는지 ---
# lib/host와 lib/pairing은 Lambda 코드, lib/gate는 서버가 내려받는 묶음이다. 파일이 하나 늘면 자산 해시가 바뀌어
# 다음 배포에서 Lambda가 갱신되고, gate는 설치 스크립트까지 서버에서 다시 실행된다.
for ST_DIR in infra-cdk/lib/host infra-cdk/lib/pairing infra-cdk/lib/gate; do
    assert_eq "$ST_DIR: 문서 파일이 없음" "0" "$(find "$ST_DIR" -type f \( -name '*.md' -o -name '*.txt' \) | wc -l | tr -d ' ')"
done

# --- 프로젝트 코드의 일관성 ---
ST_V1=$(grep -A3 "CfnParameter(this, 'OrcaVersion'" infra-cdk/lib/orca-stack.ts | sed -n "s/.*default: '\([0-9.]*\)'.*/\1/p")
ST_V2=$(grep -A3 "CfnParameter(this, 'OrcaVersion'" infra-cdk/lib/orca-attach-stack.ts | sed -n "s/.*default: '\([0-9.]*\)'.*/\1/p")
[ -n "$ST_V1" ] && pass "orca-stack.ts: 기본 OrcaVersion을 읽음 ($ST_V1)" || fail "orca-stack.ts: 기본 OrcaVersion을 읽음" "값 없음"
assert_eq "두 스택의 기본 OrcaVersion이 같음" "$ST_V1" "$ST_V2"
# Terraform의 두 구성도 같은 기본값을 쓴다
st_tf_default() { sed -n '/^variable "orca_version"/,/^}/p' "$1" | sed -n 's/^ *default *= *"\([0-9.]*\)".*/\1/p'; }
ST_V3=$(st_tf_default infra-tf/dedicated/variables.tf)
ST_V4=$(st_tf_default infra-tf/attach/variables.tf)
[ -n "$ST_V3" ] && pass "infra-tf/dedicated: 기본 orca_version을 읽음 ($ST_V3)" || fail "infra-tf/dedicated: 기본 orca_version을 읽음" "값 없음"
assert_eq "Terraform 전용 서버의 기본 orca_version이 CDK와 같음" "$ST_V1" "$ST_V3"
assert_eq "Terraform 기존 서버 추가의 기본 orca_version이 CDK와 같음" "$ST_V1" "$ST_V4"
# 서버에 설치하는 실행 의존 패키지 목록은 두 곳에 있다(기존 서버용 스크립트, 전용 서버의 UserData)
ST_P1=$(sed -n '/^dnf install -y -q gtk3/,/[^\\]$/p' infra-cdk/lib/host/install_orca.sh | tr -d '\\' | tr -s ' \n' '\n' \
    | grep -vE '^(dnf|install|-y|-q|)$' | sort | tr '\n' ' ')
ST_P2=$(grep -oP "'dnf install -y gtk3[^']*'" infra-cdk/lib/orca-stack.ts | tr -d "'" | tr -s ' ' '\n' \
    | grep -vE '^(dnf|install|-y|)$' | sort | tr '\n' ' ')
[ -n "$ST_P1" ] && pass "install_orca.sh: 실행 의존 패키지 목록을 읽음" || fail "install_orca.sh: 실행 의존 패키지 목록을 읽음" "값 없음"
assert_eq "실행 의존 패키지 목록이 두 설치 경로에서 같음" "$ST_P1" "$ST_P2"
ST_P3=$(grep -E '^dnf install -y gtk3' infra-tf/dedicated/user_data.sh.tftpl | tr -s ' ' '\n' \
    | grep -vE '^(dnf|install|-y|)$' | sort | tr '\n' ' ')
[ -n "$ST_P3" ] && pass "user_data.sh.tftpl: 실행 의존 패키지 목록을 읽음" || fail "user_data.sh.tftpl: 실행 의존 패키지 목록을 읽음" "값 없음"
assert_eq "실행 의존 패키지 목록이 Terraform의 UserData에서도 같음" "$ST_P1" "$ST_P3"

# 전용 서버의 UserData는 CDK 소스(문자열 배열)와 Terraform 템플릿 두 곳에 있다. 한쪽만 바꾸면 두 도구가 다른 서버를 만든다.
# CDK의 줄 가운데 이스케이프와 보간이 없는 문자열은 템플릿에 같은 차례로 있어야 하고,
# 템플릿의 줄 가운데 보간과 따옴표가 없는 것은 CDK 소스에 있어야 한다.
ST_USERDATA=$(python3 -I - <<'PYEOF' 2>&1 || true
import re

ts = open("infra-cdk/lib/orca-stack.ts").read()
lines = ts.split("\n")

def block(first, last):
    start = next(i for i, l in enumerate(lines) if l.strip() == first)
    end = next(i for i, l in enumerate(lines) if i > start and l.strip() == last)
    return lines[start + 1:end]

def literals(block_lines):
    out = []
    for line in block_lines:
        m = re.fullmatch(r"\s*'([^'\\]*)',", line) or re.fullmatch(r'\s*"([^"\\]*)",', line)
        if m:
            out.append(m.group(1))
    return out

# 서버가 받는 차례대로: 감싸는 스크립트의 앞부분, setup.sh의 내용, 감싸는 스크립트의 뒷부분
wrapper = block("userData.addCommands(", ");")
spread = next(i for i, l in enumerate(wrapper) if l.strip() == "...setupScript,")
plain = literals(wrapper[:spread]) + literals(block("const setupScript = [", "];")) + literals(wrapper[spread + 1:])

raw = open("infra-tf/dedicated/user_data.sh.tftpl").read().split("\n")
template = [l.replace("$${", "${").replace("%%{", "%{") for l in raw]

missing, pos = [], 0
for want in plain:
    try:
        pos = template.index(want, pos) + 1
    except ValueError:
        missing.append(want)

extra = []
for original, line in zip(raw, template):
    if not line.strip() or original.startswith("%{") or "'" in line or "\\" in line:
        continue
    if re.search(r"(?<!\$)\$\{[a-z_]+\}", original):   # 템플릿 변수가 든 줄
        continue
    if line not in ts:
        extra.append(line)

print(f"plain={len(plain)} missing={len(missing)} extra={len(extra)}")
for item in (missing + extra)[:4]:
    print("  " + item[:90])
PYEOF
)
ST_USERDATA_HEAD=$(head -n 1 <<<"$ST_USERDATA")
ST_PLAIN=$(sed -n 's/^plain=\([0-9]*\) .*/\1/p' <<<"$ST_USERDATA_HEAD")
[ "${ST_PLAIN:-0}" -ge 150 ] && pass "UserData: CDK 소스에서 비교할 줄을 읽음 (${ST_PLAIN}줄)" || fail "UserData: CDK 소스에서 비교할 줄을 읽음" "$ST_USERDATA_HEAD"
assert_contains "UserData: CDK의 줄이 Terraform 템플릿에 같은 차례로 모두 있음" "$ST_USERDATA_HEAD" " missing=0 "
assert_contains "UserData: Terraform 템플릿에만 있는 줄이 없음" "$ST_USERDATA_HEAD " " extra=0 "

# 기존 서버 설치: 설치 리소스에 제거 동작이 붙으면 버전을 올릴 때 Orca를 먼저 제거한다
ST_TF_INSTALL=$(sed -n '/^resource "terraform_data" "host_install" {/,/^}/p' infra-tf/attach/main.tf)
ST_TF_UNINSTALL=$(sed -n '/^resource "terraform_data" "host_uninstall" {/,/^}/p' infra-tf/attach/main.tf)
[ -n "$ST_TF_INSTALL" ] && [ -n "$ST_TF_UNINSTALL" ] && pass "infra-tf/attach: 설치와 제거 리소스를 읽음" \
    || fail "infra-tf/attach: 설치와 제거 리소스를 읽음" "terraform_data 블록 없음"
assert_not_contains "infra-tf/attach: 설치 리소스에 destroy 프로비저너가 없음" "$ST_TF_INSTALL" "destroy"
# "uninstall_orca.sh"에는 "install_orca.sh"가 들어 있다. 구분하려고 앞의 빗금까지 본다
assert_contains "infra-tf/attach: 설치 리소스가 install_orca.sh를 보냄" "$ST_TF_INSTALL" "/install_orca.sh"
assert_not_contains "infra-tf/attach: 설치 리소스가 제거 스크립트를 보내지 않음" "$ST_TF_INSTALL" "uninstall_orca.sh"
assert_contains "infra-tf/attach: 제거 리소스에 destroy 프로비저너가 있음" "$ST_TF_UNINSTALL" "when    = destroy"
assert_contains "infra-tf/attach: 제거 리소스가 uninstall_orca.sh를 보냄" "$ST_TF_UNINSTALL" "/uninstall_orca.sh"
assert_not_contains "infra-tf/attach: 제거 리소스가 설치 스크립트를 보내지 않음" "$ST_TF_UNINSTALL" "/install_orca.sh"
assert_contains "infra-tf/attach: 제거 리소스는 인스턴스가 바뀔 때만 교체됨" "$ST_TF_UNINSTALL" "triggers_replace = [var.host_instance_id]"
# 페어링 링크와 설정 코드는 Terraform 출력으로 만들지 않는다. 상태 파일에 평문으로 남기 때문이다
assert_eq "infra-tf: 페어링 링크나 설정 코드를 출력으로 만들지 않음" "0" \
    "$(cat infra-tf/dedicated/outputs.tf infra-tf/attach/outputs.tf infra-tf/modules/*/outputs.tf | grep -ciE '^output "[a-z_]*(pairing_(web_)?link|pairing_code|pairing_url|setup_code)"' || true)"
# 운영 스크립트가 읽는 Terraform 출력이 두 구성에 모두 있어야 한다
ST_MISSING=""
for ST_NAME in region instance_id password_gate_store_arn cloudfront_url orca_version alb_endpoint ssm_access; do
    for ST_FILE in infra-tf/dedicated/outputs.tf infra-tf/attach/outputs.tf; do
        grep -qx "output \"$ST_NAME\" {" "$ST_FILE" || ST_MISSING="$ST_MISSING $ST_FILE:$ST_NAME"
    done
done
grep -qx 'output "host" {' infra-tf/attach/outputs.tf || ST_MISSING="$ST_MISSING infra-tf/attach/outputs.tf:host"
assert_eq "infra-tf: 운영 스크립트가 읽는 출력이 모두 있음" "" "$ST_MISSING"
for ST_FILE in get_pairing_url.sh set_password.sh cleanup.sh; do
    grep -qF -- '--tf) TF_MODE=' "$ST_FILE" && pass "$ST_FILE: --tf 옵션을 받음" || fail "$ST_FILE: --tf 옵션을 받음" "옵션 처리 없음"
done
# provider 잠금 파일: 두 구성이 같은 버전을 쓰고 CLAUDE.md의 Tech Stack과 맞는다
assert_file_exists "infra-tf/dedicated: 잠금 파일" "infra-tf/dedicated/.terraform.lock.hcl"
cmp -s infra-tf/dedicated/.terraform.lock.hcl infra-tf/attach/.terraform.lock.hcl && pass "infra-tf: 두 구성의 잠금 파일이 같음" \
    || fail "infra-tf: 두 구성의 잠금 파일이 같음" "내용이 다름"
st_locked() { sed -n "/^provider \"registry.terraform.io\/hashicorp\/$1\" {/,/^}/p" infra-tf/dedicated/.terraform.lock.hcl | sed -n 's/^ *version *= *"\(.*\)"/\1/p'; }
ST_TF_AWS=$(st_locked aws)
[ -n "$ST_TF_AWS" ] && pass "infra-tf: 잠금 파일에서 AWS provider 버전을 읽음 ($ST_TF_AWS)" || fail "infra-tf: 잠금 파일에서 AWS provider 버전을 읽음" "값 없음"
assert_contains "CLAUDE.md: AWS provider 버전이 잠금 파일과 같음" "$(cat CLAUDE.md)" "AWS provider $ST_TF_AWS"
assert_contains "CLAUDE.md: random provider 버전이 잠금 파일과 같음" "$(cat CLAUDE.md)" "random $(st_locked random)"
assert_contains "CLAUDE.md: archive provider 버전이 잠금 파일과 같음" "$(cat CLAUDE.md)" "archive $(st_locked archive)"
assert_eq "infra-tf: 잠금 파일에 네 플랫폼의 해시가 있음" "12" "$(grep -c '"h1:' infra-tf/dedicated/.terraform.lock.hcl || true)"
# infra-tf/run-tests.sh가 시험 파일을 모두 적는지 (terraform test는 tests/ 아래를 스스로 찾지만, 머리말이 목록이다)
ST_MISSING=""
while IFS= read -r ST_FILE; do
    grep -qF -- "$(basename "$ST_FILE")" infra-tf/run-tests.sh || ST_MISSING="$ST_MISSING $ST_FILE"
done < <(find infra-tf -type f \( -name '*.tftest.hcl' -o -name '*_test.py' \) -not -path '*/.terraform/*' | sort)
assert_eq "infra-tf/run-tests.sh가 시험 파일을 모두 적음" "" "$ST_MISSING"
if command -v terraform >/dev/null 2>&1; then
    ST_FMT=$(terraform fmt -check -recursive infra-tf 2>&1 || true)
    assert_eq "infra-tf: terraform fmt 형식" "" "$ST_FMT"
else
    skip "infra-tf: terraform fmt 형식" "terraform이 없음"
fi
# npm test가 infra-cdk/test의 시험 파일을 모두 실행하는지
ST_NPM_TEST=$(jq -r '.scripts.test' infra-cdk/package.json)
ST_MISSING=""
for ST_FILE in infra-cdk/test/*; do
    [ -f "$ST_FILE" ] || continue
    printf '%s' "$ST_NPM_TEST" | grep -qF -- "test/$(basename "$ST_FILE")" || ST_MISSING="$ST_MISSING $(basename "$ST_FILE")"
done
assert_eq "npm test가 infra-cdk/test의 파일을 모두 실행함" "" "$ST_MISSING"
for ST_FILE in *.sh infra-cdk/lib/host/*.sh infra-cdk/lib/gate/*.sh infra-cdk/lib/pairing/*.sh scripts/*.sh \
               infra-tf/run-tests.sh infra-tf/scripts/*.sh; do
    assert_bash_syntax "bash 문법: $ST_FILE" "$ST_FILE"
done

# --- 스킬: frontmatter와 이름 ---
for ST_DIR in .claude/skills/*/; do
    ST_SKILL=$(basename "$ST_DIR")
    assert_file_exists "스킬 $ST_SKILL: SKILL.md" "$ST_DIR/SKILL.md"
    head -1 "$ST_DIR/SKILL.md" | grep -qx -- '---' && pass "스킬 $ST_SKILL: frontmatter 시작" \
        || fail "스킬 $ST_SKILL: frontmatter 시작" "첫 줄이 ---가 아님"
    assert_eq "스킬 $ST_SKILL: name이 디렉터리 이름과 같음" "$ST_SKILL" \
        "$(sed -n '2,/^---$/s/^name: //p' "$ST_DIR/SKILL.md" | head -1)"
    ST_DESC=$(sed -n '2,/^---$/s/^description: //p' "$ST_DIR/SKILL.md" | head -1)
    [ "${#ST_DESC}" -ge 30 ] && pass "스킬 $ST_SKILL: description 있음 (${#ST_DESC}자)" \
        || fail "스킬 $ST_SKILL: description 있음" "너무 짧거나 없음"
done
for ST_SKILL in project-review refactor release sync-docs; do
    assert_file_exists "스킬: $ST_SKILL" ".claude/skills/$ST_SKILL/SKILL.md"
done
[ -d .claude/skills/code-review ] && fail "스킬: 내장 /code-review를 가리지 않음" ".claude/skills/code-review가 있음" \
    || pass "스킬: 내장 /code-review를 가리지 않음"

# --- 에이전트: .md와 frontmatter (.yml은 불러오지 않는다) ---
assert_eq "에이전트: .yml 파일 없음" "0" "$(find .claude/agents -name '*.yml' -o -name '*.yaml' | wc -l | tr -d ' ')"
for ST_FILE in .claude/agents/*.md; do
    ST_AGENT=$(basename "$ST_FILE" .md)
    assert_eq "에이전트 $ST_AGENT: name이 파일 이름과 같음" "$ST_AGENT" "$(sed -n '2,/^---$/s/^name: //p' "$ST_FILE" | head -1)"
    for ST_KEY in description tools; do
        sed -n '2,/^---$/p' "$ST_FILE" | grep -q "^$ST_KEY: " && pass "에이전트 $ST_AGENT: $ST_KEY" \
            || fail "에이전트 $ST_AGENT: $ST_KEY" "frontmatter에 없음"
    done
done
assert_file_exists "에이전트: code-reviewer" ".claude/agents/code-reviewer.md"
assert_file_exists "에이전트: security-auditor" ".claude/agents/security-auditor.md"

# --- 명령 ---
for ST_CMD in review test-all deploy; do
    assert_file_exists "명령 /$ST_CMD" ".claude/commands/$ST_CMD.md"
    sed -n '2,/^---$/p' ".claude/commands/$ST_CMD.md" 2>/dev/null | grep -q "^description: " && pass "명령 /$ST_CMD: description" \
        || fail "명령 /$ST_CMD: description" "frontmatter에 없음"
done
# 배포 명령은 실제 배포 명령을 미리 허용하지 않는다. 승인 절차가 사라지기 때문이다
ST_ALLOWED=$(sed -n '2,/^---$/s/^allowed-tools: //p' .claude/commands/deploy.md)
[ -n "$ST_ALLOWED" ] && pass "명령 /deploy: allowed-tools를 읽음" || fail "명령 /deploy: allowed-tools를 읽음" "값 없음"
for ST_WORD in "deploy_orca" "upgrade_orca" "cleanup" "set_password" "get_pairing_url" "npx cdk" "cdk deploy" "cdk destroy" "npm run" \
               "terraform apply" "terraform destroy" "Bash(terraform:"; do
    assert_not_contains "명령 /deploy: $ST_WORD 를 미리 허용하지 않음" "$ST_ALLOWED" "$ST_WORD"
done

# --- 문서가 있는지 ---
for ST_FILE in docs/architecture.md docs/onboarding.md docs/api-reference.md docs/decisions/.template.md \
               docs/runbooks/.template.md docs/runbooks/upgrade-orca.md docs/reference/INDEX.md \
               docs/reference/iac.md docs/reference/security.md; do
    assert_file_exists "문서: $ST_FILE" "$ST_FILE"
done

# --- 두 언어 문서: 두 구역의 구조가 같다 ---
for ST_FILE in README.md CHANGELOG.md docs/architecture.md docs/decisions/.template.md docs/runbooks/.template.md \
               docs/runbooks/*.md docs/reference/*.md; do
    ST_EN_LINE=$(grep -n -m1 '<a id="english"></a>' "$ST_FILE" | cut -d: -f1)
    ST_KO_LINE=$(grep -n -m1 '<a id="korean"></a>' "$ST_FILE" | cut -d: -f1)
    if [ -n "$ST_EN_LINE" ] && [ -n "$ST_KO_LINE" ] && [ "$ST_EN_LINE" -lt "$ST_KO_LINE" ]; then
        pass "$ST_FILE: english, korean 표식이 차례대로 있음"
    else
        fail "$ST_FILE: english, korean 표식이 차례대로 있음" "표식이 없거나 순서가 다름"
        continue
    fi
    ST_EN=$(st_section "$ST_FILE" english)
    ST_KO=$(st_section "$ST_FILE" korean)
    assert_eq "$ST_FILE: 두 구역의 제목 수" \
        "$(printf '%s\n' "$ST_EN" | st_outside_code | st_count '^#{1,4} ')" "$(printf '%s\n' "$ST_KO" | st_outside_code | st_count '^#{1,4} ')"
    assert_eq "$ST_FILE: 두 구역의 코드 블록 수" \
        "$(printf '%s\n' "$ST_EN" | st_count '^```')" "$(printf '%s\n' "$ST_KO" | st_count '^```')"
    assert_eq "$ST_FILE: 두 구역의 표 줄 수" \
        "$(printf '%s\n' "$ST_EN" | st_count '^\|')" "$(printf '%s\n' "$ST_KO" | st_count '^\|')"
    assert_eq "$ST_FILE: 두 구역의 목록 줄 수" \
        "$(printf '%s\n' "$ST_EN" | st_outside_code | st_count '^ *- ')" "$(printf '%s\n' "$ST_KO" | st_outside_code | st_count '^ *- ')"
    if grep -qP "$ST_HANGUL" <<<"$ST_EN"; then
        fail "$ST_FILE: 영어 구역에 한글이 없음" "$(grep -m1 -P "$ST_HANGUL" <<<"$ST_EN" | cut -c1-60)"
    else
        pass "$ST_FILE: 영어 구역에 한글이 없음"
    fi
    grep -qP "$ST_HANGUL" <<<"$ST_KO" && pass "$ST_FILE: 한국어 구역에 한글이 있음" \
        || fail "$ST_FILE: 한국어 구역에 한글이 있음" "한글 없음"
done
# 그림은 두 구역에 같은 것이 들어간다
assert_eq "docs/architecture.md: 두 구역의 Mermaid 그림이 같음" \
    "$(st_section docs/architecture.md english | sed -n '/^```mermaid/,/^```$/p' | md5sum | cut -d' ' -f1)" \
    "$(st_section docs/architecture.md korean | sed -n '/^```mermaid/,/^```$/p' | md5sum | cut -d' ' -f1)"
[ "$(st_section docs/architecture.md english | st_count '^```mermaid')" -ge 2 ] && pass "docs/architecture.md: Mermaid 그림이 둘 이상" \
    || fail "docs/architecture.md: Mermaid 그림이 둘 이상" "전체 그림과 흐름 그림이 있어야 함"

# --- README: 필요한 구역이 차례대로 있다 ---
assert_eq "README: 영어 구역의 차례" \
    "Overview|Features|Prerequisites|Installation|Usage|Configuration|Project Structure|Testing|API Documentation|Contributing|License|Contact|" \
    "$(st_section README.md english | st_outside_code | sed -n 's/^## //p' | tr '\n' '|')"
assert_eq "README: 한국어 구역의 차례" \
    "개요|주요 기능|사전 요구 사항|설치 방법|사용법|환경 설정|프로젝트 구조|테스트|API 문서|기여 방법|라이선스|연락처|" \
    "$(st_section README.md korean | st_outside_code | sed -n 's/^## //p' | tr '\n' '|')"
# 언어 전환은 ASCII 앵커를 쓴다. 한글 앵커(#한국어)는 GitHub 밖의 뷰어에서 동작하지 않는다
for ST_FILE in README.md CHANGELOG.md docs/architecture.md; do
    ST_HEAD_PART=$(sed '/<a id="english"><\/a>/q' "$ST_FILE")
    assert_contains "$ST_FILE: 언어 전환이 #english를 가리킴" "$ST_HEAD_PART" 'href="#english"'
    assert_contains "$ST_FILE: 언어 전환이 #korean을 가리킴" "$ST_HEAD_PART" 'href="#korean"'
done
ST_FEATURES=$(st_section README.md english | sed -n '/^## Features/,/^## Prerequisites/p' | grep -E '^- ' || true)
[ "$(printf '%s\n' "$ST_FEATURES" | st_count '^- \*\*[^*]+\*\* — ')" -ge 4 ] && pass "README: 기능 항목이 '- **이름** — 설명' 형식 (넷 이상)" \
    || fail "README: 기능 항목이 '- **이름** — 설명' 형식 (넷 이상)" "$(printf '%s\n' "$ST_FEATURES" | head -1 | cut -c1-60)"
assert_eq "README: 형식이 다른 기능 항목이 없음" "0" "$(printf '%s\n' "$ST_FEATURES" | grep -vcE '^- \*\*[^*]+\*\* — ' || true)"
grep -qxF '| Variable | Description | Default |' <<<"$(st_section README.md english)" && pass "README: 환경 설정 표의 머리줄" \
    || fail "README: 환경 설정 표의 머리줄" "'| Variable | Description | Default |' 줄이 없음"
# README의 예시 명령이 가리키는 스크립트 옵션은 실제 스크립트에 있어야 한다
ST_MISSING=""
while IFS= read -r ST_OPT; do
    [ -z "$ST_OPT" ] && continue
    grep -qF -- "$ST_OPT" deploy_orca.sh deploy_orca_tf.sh upgrade_orca.sh cleanup.sh set_password.sh get_pairing_url.sh || ST_MISSING="$ST_MISSING $ST_OPT"
done < <(st_section README.md english | grep -E '^(ORCA_WEB_PASSWORD=.* )?bash (deploy_orca|deploy_orca_tf|upgrade_orca|cleanup|set_password|get_pairing_url)\.sh' \
    | grep -oE -- '--[a-z][a-z-]+' | sort -u)
assert_eq "README: 예시 명령의 옵션이 스크립트에 모두 있음" "" "$ST_MISSING"

# --- 인포그래픽: 문서가 가리키는 그림이 있고, 언어와 테마의 짝이 맞는다 ---
# 그림 경로는 그 문서가 있는 디렉터리 기준이다. 영어 구역은 영어판(-en), 한국어 구역은 같은 그림의 한국어판을 쓴다.
st_images() { grep -oP '(?:src|srcset)="\K[^"]+(?=")' | grep -vE '^https?://' || true; }
ST_FIG_DIR="docs/infographic/build"
for ST_FILE in README.md docs/architecture.md docs/runbooks/upgrade-orca.md; do
    ST_BASE=$(dirname "$ST_FILE")
    ST_EN_IMAGES=$(st_section "$ST_FILE" english | st_images)
    ST_KO_IMAGES=$(st_section "$ST_FILE" korean | st_images)
    ST_MISSING=""
    ST_UNTRACKED=""
    while IFS= read -r ST_PATH; do
        [ -z "$ST_PATH" ] && continue
        [ -f "$ST_BASE/$ST_PATH" ] || ST_MISSING="$ST_MISSING $ST_PATH"
        if git rev-parse --git-dir >/dev/null 2>&1; then
            git ls-files --error-unmatch -- "$ST_BASE/$ST_PATH" >/dev/null 2>&1 || ST_UNTRACKED="$ST_UNTRACKED $ST_PATH"
        fi
    done < <(printf '%s\n%s\n' "$ST_EN_IMAGES" "$ST_KO_IMAGES")
    assert_eq "$ST_FILE: 그림 파일이 모두 있음" "" "$ST_MISSING"
    assert_eq "$ST_FILE: 그림 파일을 git이 추적함 (git 저장소일 때)" "" "$ST_UNTRACKED"
    [ "$(printf '%s\n' "$ST_EN_IMAGES" | st_count '_light\.png$')" -ge 1 ] && pass "$ST_FILE: 영어 구역에 그림이 있음" \
        || fail "$ST_FILE: 영어 구역에 그림이 있음" "없음"
    assert_eq "$ST_FILE: 그림마다 다크와 라이트가 짝을 이룸" \
        "$(printf '%s\n' "$ST_EN_IMAGES" "$ST_KO_IMAGES" | grep '_dark\.png$' | sed 's/_dark\.png$//')" \
        "$(printf '%s\n' "$ST_EN_IMAGES" "$ST_KO_IMAGES" | grep '_light\.png$' | sed 's/_light\.png$//')"
    assert_eq "$ST_FILE: 한국어 구역의 그림은 영어 구역 그림의 한국어판" \
        "$(printf '%s\n' "$ST_EN_IMAGES" | sed 's/-en_/_/')" "$ST_KO_IMAGES"
    printf '%s\n' "$ST_EN_IMAGES" | grep -v -- '-en_' | grep -q . && fail "$ST_FILE: 영어 구역은 영어판 그림만 씀" \
        "$(printf '%s\n' "$ST_EN_IMAGES" | grep -v -- '-en_' | head -1)" || pass "$ST_FILE: 영어 구역은 영어판 그림만 씀"
    assert_eq "$ST_FILE: 그림의 alt 글이 비어 있지 않음" "0" "$(grep -c '<img [^>]*alt=""' "$ST_FILE" || true)"
done
assert_eq "README: 영어 구역의 그림은 넷" "4" "$(st_section README.md english | st_images | st_count '_light\.png$')"
# 한국어로만 쓴 문서는 한국어판 그림을 쓴다
for ST_FILE in docs/onboarding.md docs/api-reference.md; do
    ST_MISSING=""
    ST_COUNT=0
    while IFS= read -r ST_PATH; do
        [ -z "$ST_PATH" ] && continue
        ST_COUNT=$((ST_COUNT + 1))
        [ -f "docs/$ST_PATH" ] || ST_MISSING="$ST_MISSING $ST_PATH"
    done < <(st_images < "$ST_FILE")
    assert_eq "$ST_FILE: 그림 파일이 모두 있음" "" "$ST_MISSING"
    [ "$ST_COUNT" -ge 2 ] && pass "$ST_FILE: 그림이 있음" || fail "$ST_FILE: 그림이 있음" "${ST_COUNT}개"
    assert_eq "$ST_FILE: 한국어판 그림만 씀" "0" "$(st_images < "$ST_FILE" | grep -c -- '-en_' || true)"
done
# build.sh가 만드는 그림마다 두 언어, 두 테마의 PNG와 SVG가 있다
ST_SLUGS=$(sed -n '/^PAGES=(/,/^)/p' docs/infographic/build.sh | grep -oE ':[0-9]{2}-[a-z0-9-]+' | tr -d ':' | sort -u)
[ "$(printf '%s\n' "$ST_SLUGS" | st_count '.')" -ge 8 ] && pass "인포그래픽: build.sh의 그림 목록을 읽음" \
    || fail "인포그래픽: build.sh의 그림 목록을 읽음" "$(printf '%s\n' "$ST_SLUGS" | st_count '.')개"
ST_MISSING=""
for ST_SLUG in $ST_SLUGS; do
    for ST_NAME in "${ST_SLUG}_16x9_dark.png" "${ST_SLUG}_16x9_light.png" "${ST_SLUG}_16x9_dark.svg" "${ST_SLUG}_16x9_light.svg"; do
        [ -s "$ST_FIG_DIR/$ST_NAME" ] || ST_MISSING="$ST_MISSING $ST_NAME"
    done
done
assert_eq "인포그래픽: 그림마다 PNG와 SVG가 다크, 라이트로 있음" "" "$ST_MISSING"
assert_eq "인포그래픽: 한국어판마다 영어판이 있음" \
    "$(printf '%s\n' "$ST_SLUGS" | grep -v -- '-en$' | sed 's/$/-en/')" "$(printf '%s\n' "$ST_SLUGS" | grep -- '-en$')"
# 문서가 쓰지 않는 그림이나, 문서에는 있는데 build.sh에 없는 그림이 없어야 한다
ST_USED=$(cat README.md docs/architecture.md docs/runbooks/upgrade-orca.md docs/onboarding.md docs/api-reference.md | st_images \
    | sed -E 's#.*/##; s/_16x9_(dark|light)\.png$//' | sort -u)
assert_eq "인포그래픽: build.sh의 그림을 문서가 모두 씀" "$ST_SLUGS" "$ST_USED"
# 한국어 글(T)과 영어 글(T_EN)은 같은 키와 같은 길이의 목록을 가진다(구조와 좌표를 함께 쓰기 때문이다)
ST_PARITY=$(python3 -I - <<'PYEOF' 2>&1 || true
import importlib, sys
sys.path.insert(0, "docs/infographic")
bad = []
for name in ("access_path", "deploy_modes", "first_access", "upgrade_flow"):
    mod = importlib.import_module(name)
    ko, en = mod.T, mod.T_EN
    if set(ko) != set(en):
        bad.append(f"{name}: keys {sorted(set(ko) ^ set(en))}")
        continue
    for key in ko:
        a, b = ko[key], en[key]
        if type(a) is not type(b):
            bad.append(f"{name}.{key}: type")
        elif isinstance(a, (list, tuple)) and len(a) != len(b):
            bad.append(f"{name}.{key}: {len(a)} vs {len(b)}")
        elif isinstance(a, (list, tuple)):
            for i, (x, y) in enumerate(zip(a, b)):
                if isinstance(x, (list, tuple)) and (not isinstance(y, (list, tuple)) or len(x) != len(y)):
                    bad.append(f"{name}.{key}[{i}]: shape")
        if any("가" <= ch <= "힣" for ch in repr(b)):
            bad.append(f"{name}.{key}: Hangul in T_EN")
print("; ".join(bad))
PYEOF
)
assert_eq "인포그래픽: T와 T_EN의 키와 목록 길이가 같고 T_EN에 한글이 없음" "" "$ST_PARITY"
assert_file_executable "docs/infographic/build.sh 실행 권한" "docs/infographic/build.sh"
assert_bash_syntax "bash 문법: docs/infographic/build.sh" "docs/infographic/build.sh"
assert_file_exists "인포그래픽: 근거 문서" "docs/infographic/sources.md"

# --- CHANGELOG: 두 구역의 버전 목록이 같고 분류 제목은 영어다 ---
ST_EN=$(st_section CHANGELOG.md english)
ST_KO=$(st_section CHANGELOG.md korean)
assert_contains "CHANGELOG: 영어 구역에 [Unreleased]" "$ST_EN" "## [Unreleased]"
assert_contains "CHANGELOG: 한국어 구역에 [Unreleased]" "$ST_KO" "## [Unreleased]"
assert_contains "CHANGELOG: 영어 구역의 머리말" "$ST_EN" "All notable changes to this project will be documented in this file."
assert_contains "CHANGELOG: 한국어 구역의 머리말" "$ST_KO" "이 프로젝트의 모든 주요 변경 사항은 이 파일에 기록됩니다."
assert_eq "CHANGELOG: 두 구역의 버전 목록이 같음" \
    "$(printf '%s\n' "$ST_EN" | grep -oP '^## \[\K[^]]+' | tr '\n' ' ')" "$(printf '%s\n' "$ST_KO" | grep -oP '^## \[\K[^]]+' | tr '\n' ' ')"
assert_eq "CHANGELOG: 한국어 구역의 분류 제목도 영어" "" \
    "$(printf '%s\n' "$ST_KO" | grep -E '^### ' | grep -vE '^### (Added|Changed|Deprecated|Removed|Fixed|Security)$' | tr '\n' ' ')"
assert_eq "CHANGELOG: 날짜는 YYYY-MM-DD" "" \
    "$(printf '%s\n' "$ST_EN" | grep -E '^## \[[0-9]' | grep -vE '^## \[[0-9]+\.[0-9]+\.[0-9]+\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$' | tr '\n' ' ')"

# --- 참조 문서: 색인과 CLAUDE.md의 목록이 파일과 맞는지 ---
for ST_FILE in docs/reference/*.md; do
    ST_LAYER=$(basename "$ST_FILE" .md)
    [ "$ST_LAYER" = INDEX ] && continue
    grep -qF "($ST_LAYER.md)" docs/reference/INDEX.md && pass "INDEX.md: $ST_LAYER.md를 가리킴" \
        || fail "INDEX.md: $ST_LAYER.md를 가리킴" "색인에 없음"
    sed -n '/<!-- AUTO-MANAGED:references -->/,/<!-- \/AUTO-MANAGED -->/p' CLAUDE.md | grep -qF "(docs/reference/$ST_LAYER.md)" \
        && pass "CLAUDE.md: docs/reference/$ST_LAYER.md를 가리킴" || fail "CLAUDE.md: docs/reference/$ST_LAYER.md를 가리킴" "AUTO-MANAGED 구역에 없음"
done
ST_MISSING=""
while IFS= read -r ST_LINK; do
    [ -f "docs/reference/$ST_LINK" ] || ST_MISSING="$ST_MISSING $ST_LINK"
done < <(grep -oP '\]\(\K[a-z-]+\.md(?=\))' docs/reference/INDEX.md | sort -u)
assert_eq "INDEX.md: 가리키는 파일이 모두 있음" "" "$ST_MISSING"

# --- 문서가 적은 경로가 실제로 있는지 ---
# 백틱 안의 값 가운데 경로 모양(디렉터리 구분자가 있는 상대 경로)만 본다. 서버의 절대 경로(/etc/orca 등)는 대상이 아니다.
# 커밋하지 않는 파일, 자리 표시 이름, 저장소 이름, MIME 형식, CIDR과 포트 쌍은 뺀다.
ST_PATH_EXCLUDE='(^|/)node_modules(/|$)|(^|/)cdk\.out(/|$)|cdk-outputs\.json$|cdk\.context\.json$|settings\.local\.json$|\.tfvars(\.json)?$|\.tfstate$|\.tfplan$|(^|/)\.terraform(/|$)|(^|/)\.build(/|$)|ADR-NNN|^feat/|^fix/|^stablyai/|^whchoi98/|^(text|application)/|^HTTP/|^[0-9.]+/[0-9]+$|^\.git/|^orca/$'
st_paths() { grep -oP '`[^`]+`' "$1" | tr -d '`' | grep -P '^\.?[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+/?$|^[A-Za-z0-9_-]+/$' \
    | grep -vE -- "$ST_PATH_EXCLUDE" | sort -u; }
for ST_FILE in CLAUDE.md README.md docs/architecture.md docs/reference/*.md docs/onboarding.md docs/api-reference.md docs/runbooks/*.md \
               .claude/commands/*.md .claude/skills/*/SKILL.md .claude/agents/*.md; do
    ST_MISSING=""
    while IFS= read -r ST_PATH; do
        [ -e "$ST_PATH" ] || ST_MISSING="$ST_MISSING $ST_PATH"
    done < <(st_paths "$ST_FILE")
    assert_eq "$ST_FILE: 적은 경로가 모두 있음" "" "$ST_MISSING"
done
# 모듈 문서의 경로는 모듈 디렉터리 기준이거나 저장소 루트 기준이다
for ST_ROOT in $ST_ROOTS; do
    ST_MISSING=""
    while IFS= read -r ST_PATH; do
        [ -e "$ST_ROOT/$ST_PATH" ] || [ -e "$ST_PATH" ] || ST_MISSING="$ST_MISSING $ST_PATH"
    done < <(st_paths "$ST_ROOT/CLAUDE.md")
    assert_eq "$ST_ROOT/CLAUDE.md: 적은 경로가 모두 있음" "" "$ST_MISSING"
done
# 아키텍처 문서의 구성 요소는 "- **경로**: 설명" 형식이고 경로가 있어야 한다
ST_MISSING=""
ST_COMPONENTS=0
while IFS= read -r ST_PATH; do
    [ -z "$ST_PATH" ] && continue
    ST_COMPONENTS=$((ST_COMPONENTS + 1))
    [ -e "$ST_PATH" ] || ST_MISSING="$ST_MISSING $ST_PATH"
done < <(st_section docs/architecture.md english | sed -n '/^## Components/,/^## Full Architecture Diagram/p' | grep -oP '^- \*\*\K[^*]+(?=\*\*)' | sort -u)
assert_eq "docs/architecture.md: 구성 요소의 경로가 모두 있음" "" "$ST_MISSING"
[ "$ST_COMPONENTS" -ge 8 ] && pass "docs/architecture.md: 구성 요소가 여덟 이상 ($ST_COMPONENTS)" \
    || fail "docs/architecture.md: 구성 요소가 여덟 이상" "$ST_COMPONENTS개"

# --- 만든 문서와 도구에 환경 식별 값이 없는지 ---
# 111122223333과 123456789012는 AWS 문서가 쓰는 예시 계정이다(검사기도 같은 값을 허용한다).
ST_LEAK=""
for ST_FILE in CLAUDE.md README.md CHANGELOG.md docs/*.md docs/reference/*.md docs/runbooks/*.md docs/runbooks/.template.md \
               docs/decisions/.template.md infra-cdk/CLAUDE.md infra-tf/CLAUDE.md scripts/CLAUDE.md tests/CLAUDE.md \
               .claude/commands/*.md .claude/skills/*/SKILL.md .claude/agents/*.md .claude/hooks/*.sh .claude/settings.json scripts/*.sh \
               docs/infographic/sources.md docs/infographic/build.sh docs/infographic/access_path.py docs/infographic/deploy_modes.py \
               docs/infographic/first_access.py docs/infographic/upgrade_flow.py docs/infographic/orcakit.py; do
    # grep -c는 입력을 끝까지 읽는다. grep -q를 파이프 뒤에 두면 파일 앞쪽의 값을 놓칠 수 있다(run-all.sh의 contains 설명)
    ST_HITS=$(sed -E 's/111122223333|123456789012//g' "$ST_FILE" \
        | grep -cE '(^|[^0-9])[0-9]{12}([^0-9]|$)|[a-z0-9]{10,}\.cloudfront\.net|\bi-[0-9a-f]{17}\b|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.(com|net)' || true)
    [ "${ST_HITS:-0}" -gt 0 ] && ST_LEAK="$ST_LEAK $ST_FILE"
done
assert_eq "만든 문서와 도구에 계정 ID, CloudFront 도메인, 인스턴스 ID, 이메일이 없음" "" "$ST_LEAK"

# --- .gitignore와 .env.example ---
ST_IGNORE=$(cat .gitignore)
for ST_RULE in ".env" ".env.*" "!.env.example" ".claude/settings.local.json" "node_modules/" "cdk-outputs.json" \
               "infra-cdk/cdk.out/" "infra-cdk/cdk.context.json" "__pycache__/" "/orca/" \
               "infra-tf/**/.terraform/" "infra-tf/**/*.tfstate" "infra-tf/**/*.tfstate.*" "infra-tf/**/*.tfvars" \
               "infra-tf/**/*.tfvars.json" "infra-tf/**/*.tfplan" "infra-tf/**/.build/"; do
    printf '%s\n' "$ST_IGNORE" | grep -qxF -- "$ST_RULE" && pass ".gitignore: $ST_RULE" || fail ".gitignore: $ST_RULE" "규칙 없음"
done
# 규칙이 실제로 그렇게 동작하는지는 임시 git 저장소에서 본다(이 디렉터리가 git 저장소가 아니어도 확인할 수 있다)
ST_IGN="$TEST_TMP/ignore-repo"
mkdir -p "$ST_IGN"
git -C "$ST_IGN" init -q
cp .gitignore "$ST_IGN/.gitignore"
for ST_PATH in .env .env.local cdk-outputs.json infra-cdk/cdk.context.json infra-cdk/cdk.out/manifest.json infra-cdk/lib/orca-stack.js \
               infra-cdk/lib/host/__pycache__/handler.cpython-39.pyc .claude/settings.local.json orca/README.md \
               infra-tf/attach/terraform.tfstate infra-tf/attach/terraform.tfstate.backup infra-tf/attach/.terraform.tfstate.lock.info \
               infra-tf/dedicated/.terraform/providers/x infra-tf/attach/orca.auto.tfvars.json infra-tf/dedicated/terraform.tfvars \
               infra-tf/dedicated/orca.tfplan infra-tf/modules/front-door/.build/gate.zip; do
    git -C "$ST_IGN" check-ignore -q "$ST_PATH" && pass ".gitignore: $ST_PATH 를 무시함" || fail ".gitignore: $ST_PATH 를 무시함" "추적 대상이 됨"
done
for ST_PATH in .env.example infra-cdk/lib/functions/password-gate.js infra-cdk/lib/orca-stack.ts infra-cdk/package-lock.json \
               .claude/settings.json deploy_orca.sh deploy_orca_tf.sh infra-tf/attach/main.tf infra-tf/attach/.terraform.lock.hcl \
               infra-tf/dedicated/user_data.sh.tftpl infra-tf/dedicated/tests/mocks/aws.tfmock.hcl infra-tf/test/ssm_run_test.py; do
    git -C "$ST_IGN" check-ignore -q "$ST_PATH" && fail ".gitignore: $ST_PATH 를 추적함" "무시됨" || pass ".gitignore: $ST_PATH 를 추적함"
done
# 접속 암호는 파일에 두지 않는다. 배포 명령 앞에 한 번만 붙이거나 프롬프트에 입력한다
grep -qE '^[[:space:]]*ORCA_WEB_PASSWORD=' .env.example && fail ".env.example: 접속 암호 자리를 두지 않음" "ORCA_WEB_PASSWORD= 줄이 있음" \
    || pass ".env.example: 접속 암호 자리를 두지 않음"
assert_eq ".env.example: 값이 있는 변수는 비밀이 아닌 것뿐" "AWS_REGION " \
    "$(grep -E '^[A-Z_]+=.+' .env.example | cut -d= -f1 | sort | tr '\n' ' ')"

# --- 시험 파일이 실행기의 변수를 덮어쓰지 않는지 ---
assert_eq "시험 파일이 실행기의 카운터를 대입하지 않음" "" \
    "$(grep -lE '^[[:space:]]*(TOTAL|PASSED|FAILED|SKIPPED|FAILURES|FILTER|PROJECT_ROOT|TEST_TMP)=' tests/*/test-*.sh | tr '\n' ' ')"
# 큰 글의 맨 앞에 있는 값도 찾아야 한다(파이프 뒤의 grep -q는 여기서 틀린 답을 낸다)
ST_BIG="needle-at-the-start"$'\n'"$(head -c 400000 /dev/zero | tr '\0' 'x' | fold -w 100)"
contains "$ST_BIG" "needle-at-the-start" && pass "실행기: 큰 글의 앞쪽에 있는 문자열을 찾음" \
    || fail "실행기: 큰 글의 앞쪽에 있는 문자열을 찾음" "contains가 찾지 못함"
contains "$ST_BIG" "not-there" && fail "실행기: 없는 문자열은 찾지 못함" "찾았다고 답함" || pass "실행기: 없는 문자열은 찾지 못함"
head -12 tests/run-all.sh | grep -q '^set -uo pipefail' && pass "run-all.sh: set -e를 쓰지 않음" \
    || fail "run-all.sh: set -e를 쓰지 않음" "-e가 있으면 아무것도 못 찾은 grep이 실행을 끊음"
