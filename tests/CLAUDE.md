# tests 모듈

## Role

작업 도구(하네스)가 실제로 동작하는지 확인하는 시험입니다. 훅, `.claude/settings.json`, 스킬과 에이전트의 형식, 문서의 구조와 포인터, 그리고 여러 곳에 나뉘어 있는 코드 값의 일치(CDK와 Terraform 사이 포함)를 봅니다. Orca 스택 코드의 시험은 여기가 아니라 `infra-cdk/test/`에 있고 `npm test --prefix infra-cdk`로 실행합니다. Terraform 코드의 시험은 `infra-tf/`에 있고 `bash infra-tf/run-tests.sh`로 실행합니다.

## Key Files

| 파일 | 내용 |
|---|---|
| `run-all.sh` | 실행기. `test-*.sh`를 찾아 source로 불러 실행하고 통과, 실패, 건너뜀을 셈 |
| `hooks/test-hooks.sh` | 훅의 존재와 권한, 설정 등록, 승인을 묻는 명령 목록(CDK와 Terraform의 배포와 삭제), Terraform 상태 파일 읽기 거부, 훅의 실제 동작(문서 알림, 커밋 차단, 세션 맥락, 커밋 메시지 훅). 커밋 차단은 그 커밋에 들어갈 내용을 보는지 확인(인덱스의 사본, 경로를 준 커밋, 같은 줄의 `git add -f`, 커밋이 실행될 저장소). 문서 알림은 연결된 작업 트리의 파일과 세션마다 한 번만 하는 알림을 확인. project-init 3.1.0의 훅 계약(표식 둘, 검사기에 `exit 1` 없음)도 확인 |
| `hooks/test-secret-patterns.sh` | 비밀 값과 환경 식별 값 패턴의 검출과 오검출. 실제 검사기를 실행하고 패턴마다 표본이 있는지와 깨진 패턴을 통과시키지 않는지도 확인. 커밋하면 안 되는 경로(Terraform의 상태, 입력 값, 계획 파일 포함)를 내용과 상관없이 막는지 확인 |
| `structure/test-project-structure.sh` | CLAUDE.md의 구역과 버전, 모듈 문서가 소스 파일을 모두 적는지, 자산 디렉터리, 기본 Orca 버전 네 곳과 패키지 목록 세 곳의 일치, 전용 서버의 UserData가 CDK 소스와 Terraform 템플릿에서 같은지, Terraform의 설치와 제거 리소스 구성, 운영 스크립트가 읽는 Terraform 출력, provider 잠금 파일과 CLAUDE.md의 버전, 스킬과 에이전트의 frontmatter, 두 언어 문서의 구조, 문서의 그림(파일이 있는지, 영어 구역은 영어판인지, 다크와 라이트의 짝, 두 언어 글의 구조가 같은지), 문서가 적은 경로, `.gitignore`의 동작 |
| `fixtures/secret-samples.txt` | 검출해야 하는 표본. 접두어와 본문을 나눠 저장하고 실행할 때 합침 |
| `fixtures/identifier-samples.txt` | 막아야 하는 환경 식별 값의 표본(지어낸 값) |
| `fixtures/false-positives.txt` | 검출하면 안 되는 줄 |

## Rules

- 실행: `bash tests/run-all.sh`. 이름으로 고르려면 `bash tests/run-all.sh hooks`, `bash tests/run-all.sh secret-patterns`, `bash tests/run-all.sh structure`
- 시험 파일은 실행기와 같은 셸에서 실행됩니다. `TOTAL`, `PASSED`, `FAILED`, `SKIPPED`, `FAILURES` 같은 실행기의 변수 이름을 쓰지 않습니다. 파일마다 접두어(`HK_`, `SP_`, `ST_`)를 붙입니다
- 실행기는 `set -e`를 쓰지 않습니다. 아무것도 찾지 못한 `grep`이 실행을 끊으면 안 되기 때문입니다. 모든 확인은 `pass`, `fail`, `skip`으로 보고합니다
- 완전한 비밀 값 문자열을 저장소에 두지 않습니다. 표본은 접두어와 본문으로 나눕니다. 검사기에 패턴을 더하면 그 패턴을 울리는 표본도 더합니다
- 임시 파일과 임시 git 저장소는 `$TEST_TMP` 아래에 만듭니다
- 훅이나 구조를 바꾸면 시험도 함께 바꿉니다. 새 시험은 일부러 깨뜨렸을 때 실패하는지 확인합니다(`|| true`를 붙여 보거나 경로를 틀리게 해 봅니다)
- 이 시험은 AWS를 부르지 않고 서버의 서비스를 건드리지 않습니다
