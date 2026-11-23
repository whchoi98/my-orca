#!/bin/bash
# .claude/hooks/secret-scan.sh 의 검출과 오검출 시험. 실제 검사기를 실행한다
# (tests/run-all.sh가 source로 불러 실행한다). 표본은 tests/fixtures/에서 읽어 실행할 때 합친다.
# 이 파일의 변수는 SP_로 시작한다.

SP_SCANNER=".claude/hooks/secret-scan.sh"

# 검사기의 패턴 배열을 읽는다. $1 배열 이름(PATTERNS 또는 IDENTIFIER_PATTERNS)
sp_patterns() { sed -n "/^$1=(/,/^)/p" "$SP_SCANNER" | grep -oP "^\s+'\K[^']+(?=')"; }

# --- 검출: 표본마다 .txt와 .md 양쪽에서 잡아야 한다 ---
SP_SECRET_LINES=""
while IFS=$'\t' read -r SP_NAME SP_PREFIX SP_BODY; do
    [[ -z "$SP_NAME" || "$SP_NAME" == \#* ]] && continue
    SP_SECRET_LINES="$SP_SECRET_LINES${SP_PREFIX}${SP_BODY}"$'\n'
    for SP_EXT in txt md; do
        SP_SAMPLE="$TEST_TMP/tp-sample.$SP_EXT"
        printf '%s%s\n' "$SP_PREFIX" "$SP_BODY" > "$SP_SAMPLE"
        if bash "$SP_SCANNER" --files "$SP_SAMPLE" >/dev/null 2>&1; then
            fail "검출 ($SP_EXT): $SP_NAME" "검사기가 표본을 잡지 못함"
        else
            pass "검출 ($SP_EXT): $SP_NAME"
        fi
    done
done < tests/fixtures/secret-samples.txt

# --- 환경 식별 값: 표본마다 검사기가 막아야 한다 ---
SP_IDENT_LINES=""
while IFS=$'\t' read -r SP_NAME SP_PREFIX SP_BODY; do
    [[ -z "$SP_NAME" || "$SP_NAME" == \#* ]] && continue
    SP_IDENT_LINES="$SP_IDENT_LINES${SP_PREFIX}${SP_BODY}"$'\n'
    SP_SAMPLE="$TEST_TMP/id-sample.txt"
    printf 'value: %s%s end\n' "$SP_PREFIX" "$SP_BODY" > "$SP_SAMPLE"
    if bash "$SP_SCANNER" --files "$SP_SAMPLE" >/dev/null 2>&1; then
        fail "식별 값 검출: $SP_NAME" "검사기가 표본을 잡지 못함"
    else
        pass "식별 값 검출: $SP_NAME"
    fi
done < tests/fixtures/identifier-samples.txt

# --- 패턴마다 그 패턴을 울리는 표본이 있어야 한다 ---
# 표본이 없는 패턴은 깨져도 아무 시험도 실패하지 않는다. 표본을 지우면 여기서 드러난다.
while IFS= read -r SP_REGEX; do
    if printf '%s' "$SP_SECRET_LINES" | grep -qP -- "$SP_REGEX" 2>/dev/null; then
        pass "표본 있음: ${SP_REGEX:0:36}"
    else
        fail "표본 있음: ${SP_REGEX:0:36}" "tests/fixtures/secret-samples.txt에 이 패턴을 울리는 줄이 없음"
    fi
done < <(sp_patterns PATTERNS)
while IFS= read -r SP_REGEX; do
    if printf '%s' "$SP_IDENT_LINES" | grep -qP -- "$SP_REGEX" 2>/dev/null; then
        pass "표본 있음: ${SP_REGEX:0:36}"
    else
        fail "표본 있음: ${SP_REGEX:0:36}" "tests/fixtures/identifier-samples.txt에 이 패턴을 울리는 줄이 없음"
    fi
done < <(sp_patterns IDENTIFIER_PATTERNS)

# --- 오검출: 아래 줄은 하나도 걸리면 안 된다 ---
SP_FP_COUNT=0
while IFS= read -r SP_LINE; do
    [ -z "$SP_LINE" ] && continue
    SP_FP_COUNT=$((SP_FP_COUNT + 1))
    SP_SAMPLE="$TEST_TMP/fp-sample.md"
    printf '%s\n' "$SP_LINE" > "$SP_SAMPLE"
    if bash "$SP_SCANNER" --files "$SP_SAMPLE" >/dev/null 2>&1; then
        pass "오검출 없음: ${SP_LINE:0:40}"
    else
        fail "오검출 없음: ${SP_LINE:0:40}" "비밀 값이 아닌 줄이 걸림"
    fi
done < tests/fixtures/false-positives.txt
[ "$SP_FP_COUNT" -ge 15 ] && pass "오검출 표본이 열다섯 줄 이상 ($SP_FP_COUNT)" || fail "오검출 표본이 열다섯 줄 이상" "$SP_FP_COUNT줄"

# --- 저장소의 파일이 검사를 통과하는지 ---
# git 저장소면 추적하는 파일과 새 파일(무시되지 않은 것)을 본다. 아니면 .gitignore와 같은 제외 규칙으로 찾는다.
if git rev-parse --git-dir >/dev/null 2>&1; then
    mapfile -t SP_FILES < <(git ls-files 2>/dev/null; git ls-files -o --exclude-standard 2>/dev/null)
    SP_SOURCE="git이 추적하는 파일과 새 파일"
else
    mapfile -t SP_FILES < <(find . -type f -not -path "./orca/*" -not -path "*/node_modules/*" -not -path "*/cdk.out/*" \
        -not -path "*/__pycache__/*" -not -name "*.pyc" -not -name "cdk-outputs.json" -not -name "cdk.context.json" \
        -not -name ".env" -not -name "settings.local.json" | sed 's#^\./##')
    SP_SOURCE="git 저장소가 아니어서 .gitignore와 같은 규칙으로 찾은 파일"
fi
if [ "${#SP_FILES[@]}" -gt 20 ] && bash "$SP_SCANNER" --files "${SP_FILES[@]}" >/dev/null 2>&1; then
    pass "저장소: $SP_SOURCE ${#SP_FILES[@]}개가 검사를 통과"
else
    fail "저장소: $SP_SOURCE 가 검사를 통과" "$(bash "$SP_SCANNER" --files "${SP_FILES[@]}" 2>&1 | head -3 | tr '\n' ' ')"
fi

# --- 건너뛰는 파일과 금지한 파일 ---
bash "$SP_SCANNER" --files .env.example >/dev/null 2>&1 \
    && pass "건너뜀: .env.example은 검사하지 않음" || fail "건너뜀: .env.example은 검사하지 않음" "걸림"
bash "$SP_SCANNER" --files tests/fixtures/secret-samples.txt >/dev/null 2>&1 \
    && pass "건너뜀: 시험 자료는 검사하지 않음" || fail "건너뜀: 시험 자료는 검사하지 않음" "걸림"
# 금지한 경로는 내용과 상관없이 막아야 한다. 내용이 걸려서 막힌 것과 구별하려고 빈 내용의 사본으로 본다
SP_FORBID="$TEST_TMP/forbidden"
mkdir -p "$SP_FORBID/.claude" "$SP_FORBID/infra-cdk" "$SP_FORBID/infra-tf/attach" "$SP_FORBID/infra-tf/dedicated"
for SP_PATH in .env .claude/settings.local.json cdk-outputs.json infra-cdk/cdk.context.json \
               infra-tf/attach/terraform.tfstate infra-tf/dedicated/terraform.tfstate.backup \
               infra-tf/attach/orca.auto.tfvars.json infra-tf/dedicated/terraform.tfvars infra-tf/attach/orca.tfplan; do
    echo '{}' > "$SP_FORBID/$SP_PATH"
    (cd "$SP_FORBID" && bash "$PROJECT_ROOT/$SP_SCANNER" --files "$SP_PATH") >/dev/null 2>&1 \
        && fail "금지: $SP_PATH 는 내용과 상관없이 막음" "통과시킴" \
        || pass "금지: $SP_PATH 는 내용과 상관없이 막음"
done
echo '{}' > "$SP_FORBID/harmless.json"
(cd "$SP_FORBID" && bash "$PROJECT_ROOT/$SP_SCANNER" --files harmless.json) >/dev/null 2>&1 \
    && pass "금지: 다른 이름의 빈 파일은 통과" || fail "금지: 다른 이름의 빈 파일은 통과" "막힘"
# Terraform 코드와 잠금 파일은 추적한다. 금지 패턴이 넓어져 이것까지 막으면 안 된다
for SP_PATH in infra-tf/attach/main.tf infra-tf/attach/.terraform.lock.hcl infra-tf/dedicated/variables.tf; do
    echo '# empty' > "$SP_FORBID/$SP_PATH"
    (cd "$SP_FORBID" && bash "$PROJECT_ROOT/$SP_SCANNER" --files "$SP_PATH") >/dev/null 2>&1 \
        && pass "금지: $SP_PATH 는 통과" || fail "금지: $SP_PATH 는 통과" "막힘"
done
SP_SKIP_LINE=$(sed -n '/^SKIP_PATTERNS=(/,/)/p' "$SP_SCANNER" || true)
assert_not_contains "검사기: Markdown을 건너뛰지 않음" "$SP_SKIP_LINE" "'*.md'"
assert_not_contains "검사기: 코드 시험 디렉터리를 건너뛰지 않음" "$SP_SKIP_LINE" "infra-cdk"

# --- 패턴이 PCRE로 컴파일돼야 한다 (길이가 변하는 lookbehind 금지) ---
# grep은 "못 찾음"에 1, 패턴 오류에 2를 돌려준다. 오류가 2>/dev/null에 가려지면 그 패턴은 영원히 못 잡는다
SP_BAD=""
SP_COUNT=0
while IFS= read -r SP_REGEX; do
    SP_COUNT=$((SP_COUNT + 1))
    SP_REGEX_STATUS=0
    echo "x" | grep -P -- "$SP_REGEX" >/dev/null 2>&1 || SP_REGEX_STATUS=$?
    [ "$SP_REGEX_STATUS" -gt 1 ] && SP_BAD="$SP_BAD ${SP_REGEX:0:20}"
done < <(sp_patterns PATTERNS; sp_patterns IDENTIFIER_PATTERNS)
assert_eq "검사기의 모든 패턴이 컴파일됨" "" "$SP_BAD"
[ "$SP_COUNT" -ge 18 ] && pass "검사기의 패턴을 읽음 (${SP_COUNT}개)" || fail "검사기의 패턴을 읽음" "${SP_COUNT}개"

# 패턴이 깨지면 통과시키지 않고 막아야 한다. 일부러 깨뜨린 사본으로 본다
SP_BROKEN="$TEST_TMP/broken-scan.sh"
sed "s/^    'AKIA\[0-9A-Z\]{16}'/    '(?<=a+)AKIA'/" "$SP_SCANNER" > "$SP_BROKEN"
grep -qF "(?<=a+)AKIA" "$SP_BROKEN" && pass "깨뜨린 사본을 만듦" || fail "깨뜨린 사본을 만듦" "치환되지 않음"
echo "nothing here" > "$TEST_TMP/plain.txt"
SP_OUT=$(bash "$SP_BROKEN" --files "$TEST_TMP/plain.txt" 2>&1; echo "exit=$?")
assert_contains "검사기: 패턴 오류는 통과시키지 않고 exit 2" "$SP_OUT" "exit=2"
assert_contains "검사기: 패턴 오류를 알림" "$SP_OUT" "검사 패턴에 오류"
