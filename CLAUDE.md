# Project Context

## Overview

my-orca는 Orca(AI 코딩 에이전트 오케스트레이터)의 headless 서버(`orca-ide serve`)를 Private EC2에 올리고 브라우저에서 CloudFront HTTPS로 접속하게 하는 프로젝트입니다. 같은 구성을 AWS CDK와 Terraform 두 가지로 배포할 수 있습니다. 요청은 CloudFront(접속 암호 게이트), ALB(`X-Custom-Secret` 헤더 규칙), EC2의 6768 포트 순서로 지나갑니다.

배포 방식은 두 가지입니다.

- 전용 서버: `bash deploy_orca.sh`, 스택 `OrcaServerStack`. VPC, ALB, EC2를 새로 만듭니다.
- 기존 서버에 추가: `bash deploy_orca.sh --attach <호스트 스택>`, 스택 `OrcaOnVscodeStack`. ec2_vscode로 만든 VS Code 서버의 EC2와 ALB를 함께 쓰고 Orca 전용 CloudFront만 새로 만듭니다.

Terraform으로는 `bash deploy_orca_tf.sh`(전용 서버, `infra-tf/dedicated`)와 `bash deploy_orca_tf.sh --attach <호스트 스택>`(기존 서버에 추가, `infra-tf/attach`)으로 같은 것을 만듭니다. 한 서버에는 CDK 스택과 Terraform 배포 가운데 하나만 붙입니다.

사용법과 운영 절차의 원본은 `README.md`이고, 전체 구조는 `docs/architecture.md`에 있습니다. 같은 내용을 이 파일에 옮겨 적지 않습니다.

## Tech Stack

- **IaC** (`infra-cdk/`): AWS CDK(TypeScript). aws-cdk-lib 2.278.0, aws-cdk 2.1149.0, TypeScript 5.7, ts-node로 실행합니다. Node.js 20 이상이 필요합니다
- **IaC** (`infra-tf/`): Terraform. Terraform 1.14.7에서 확인했고 AWS provider 6.73.0, random 3.9.1, archive 2.8.1을 `.terraform.lock.hcl`에 고정했습니다. 엣지 함수와 서버 스크립트는 `infra-cdk/lib/`의 파일을 그대로 씁니다
- **엣지**: CloudFront Function(JavaScript runtime 2.0)과 CloudFront KeyValueStore. 코드는 `infra-cdk/lib/functions/password-gate.js`입니다
- **Lambda**: Python 3.13 커스텀 리소스 핸들러 둘(`infra-cdk/lib/host/handler.py`, `infra-cdk/lib/pairing/handler.py`)과 CDK Provider 프레임워크
- **서버**: Amazon Linux 2023, `orca-ide` RPM, systemd 유닛 `orca-serve`와 `orca-gate-setup`. 설치 스크립트는 Bash, 최초 로그인 설정 서비스는 Python 표준 라이브러리만 씁니다
- **운영 스크립트**: Bash, AWS CLI v2, curl, python3, session-manager-plugin
- **시험**: Node.js(게이트 함수), Python unittest(`python3 -I`), Terraform test(가짜 provider), Bash(하네스)

설치할 Orca 버전은 스택 파라미터 `OrcaVersion`(CDK)과 변수 `orca_version`(Terraform)입니다. 코드의 기본값은 `infra-cdk/lib/orca-stack.ts`, `infra-cdk/lib/orca-attach-stack.ts`, `infra-tf/dedicated/variables.tf`, `infra-tf/attach/variables.tf` 네 곳에 있고 같은 값이어야 합니다.

## Project Structure

```
deploy_orca.sh          CDK 배포 (대화형 또는 --yes, --attach로 기존 서버에 추가)
deploy_orca_tf.sh       Terraform 배포 (같은 옵션 체계, --plan으로 계획만 확인)
deploy_guide.sh         두 배포 스크립트가 함께 쓰는 대화형 안내(리전, VPC, 인스턴스 타입). 직접 실행하지 않음
upgrade_orca.sh         --attach 스택(CDK)의 Orca를 새 버전으로 올림 (deploy_orca.sh를 다시 실행)
get_pairing_url.sh      페어링 링크 조회 (SSM Session Manager). 링크를 화면에 출력함
set_password.sh         접속 암호 설정과 변경 (CloudFront KeyValueStore)
cleanup.sh              스택 삭제. --tf를 주면 Terraform 배포 삭제
infra-cdk/              CDK 프로젝트. 스택, 엣지 함수, Lambda 핸들러, 서버 설치 스크립트, 코드 시험
infra-tf/               Terraform 코드. 구성 둘(dedicated, attach), 공용 모듈 둘, 설치 도우미, 시험
scripts/                작업 환경 준비(setup.sh), git 훅 설치(install-hooks.sh)
tests/                  하네스 시험(훅, 설정, 구조, 문서의 포인터). bash tests/run-all.sh
tools/prompts/          프롬프트를 둘 자리(지금은 비어 있음)
.claude/                Claude Code 설정(settings.json), 훅, 스킬, 명령, 에이전트
docs/architecture.md    전체 구조와 Mermaid 그림(영어와 한국어)
docs/reference/         층별 구현 참조(iac, security)
docs/api-reference.md   접속 암호 게이트의 HTTP 경로와 커스텀 리소스의 속성
docs/onboarding.md      처음 작업하는 사람을 위한 안내
docs/runbooks/          런북. upgrade-orca.md(Orca 업그레이드)
docs/decisions/         ADR. 지금은 템플릿만 있음
docs/infographic/       문서에 넣은 그림 네 개의 소스와 결과물(build/). 한국어판과 영어판, 다크와 라이트
orca/                   분석용 upstream clone. 추적하지 않음
```

모듈마다 `CLAUDE.md`가 있습니다: `infra-cdk/`, `infra-tf/`, `scripts/`, `tests/`. 루트의 운영 스크립트 여섯 개와 `deploy_guide.sh`는 이 파일이 다룹니다.

## Conventions

- 루트 스크립트의 주석과 메시지, 문서, 훅의 메시지는 한국어로 씁니다. 문서는 합니다체입니다. `infra-cdk/lib/`와 `infra-tf/`의 코드 주석은 영어입니다. 식별자, 명령, 경로, 표준 용어는 원문대로 둡니다
- 배포, 업그레이드, 암호 변경, 삭제(`deploy_orca.sh`, `deploy_orca_tf.sh`, `upgrade_orca.sh`, `set_password.sh`, `cleanup.sh`, `npx cdk deploy`, `npx cdk destroy`, `terraform apply`, `terraform destroy`)는 차이를 먼저 보여 주고 승인을 받은 뒤 실행합니다. `.claude/settings.json`이 이 명령들을 실행할 때마다 승인을 묻습니다
- 한 서버에는 CDK 스택과 Terraform 배포 가운데 하나만 붙입니다. `deploy_orca_tf.sh`는 호스트의 ALB에 Orca 규칙이 이미 있으면 멈춥니다
- `--attach` 스택은 Claude Code가 실행 중인 서버에 설치되어 있을 수 있습니다. 그 서버의 code-server를 재시작하지 않고, `dnf update`와 재부팅, 다른 서비스의 재시작도 하지 않습니다. 설치 스크립트는 `orca-serve`와 `orca-gate-setup`만 다룹니다
- 페어링 링크, 1회용 설정 코드, 접속 암호, `X-Custom-Secret` 값은 출력, 문서, 로그, 커밋에 남기지 않습니다. 페어링 링크는 서버 접근 권한 그 자체입니다. `cdk-outputs.json`은 읽지 않고, `get_pairing_url.sh`는 사용자가 직접 실행합니다
- Terraform 상태 파일(`terraform.tfstate`)에는 `X-Custom-Secret` 값이 평문으로 들어 있습니다. 읽지 않고, `terraform show`와 `terraform state pull`을 쓰지 않습니다. `.claude/settings.json`이 상태 파일 읽기를 거부합니다. Terraform 배포는 페어링 링크를 출력으로 만들지 않습니다
- CDK 배포 명령(`deploy_orca.sh`, `upgrade_orca.sh`)의 출력에는 페어링 링크와 설정 코드가 들어 있습니다. 세션에서 실행할 때는 아래 Key Commands의 가리기 필터를 거칩니다. `deploy_orca_tf.sh`의 출력에는 들어 있지 않습니다
- 계정 ID, ARN, CloudFront 주소, 인스턴스 ID 같은 환경 식별 값은 코드와 문서에 넣지 않고 `<account-id>`, `<cloudfront-domain>`, `<InstanceId>` 같은 자리 표시를 씁니다. 커밋 전 검사가 같은 값을 막습니다. `infra-cdk/cdk.context.json`은 계정 ID가 들어 있어 추적하지 않습니다. Terraform의 입력 값 파일(`orca.auto.tfvars.json`)과 계획 파일도 인스턴스 ID와 ARN이 들어 있어 추적하지 않습니다
- 접속 암호는 어떤 파일에도 두지 않습니다. 배포 명령 앞에 `ORCA_WEB_PASSWORD`로 한 번만 넘기거나 프롬프트에 입력합니다
- 기존 서버 설치 코드(`infra-cdk/lib/host/`)의 변경과 Orca 버전 변경은 한 배포에 묶지 않습니다. 설치 코드만 지금 버전으로 먼저 배포하고 그다음에 버전을 올립니다. 업그레이드가 실패하면 CloudFormation이 이전 Lambda 코드로 설치를 다시 실행하기 때문입니다(`docs/runbooks/upgrade-orca.md`). Terraform에는 롤백이 없습니다. 설치가 실패하면 서버는 스크립트가 멈춘 자리에 남고 다음 apply가 설치를 다시 실행합니다
- 서버에 설치하는 실행 의존 패키지 목록은 `infra-cdk/lib/host/install_orca.sh`, `infra-cdk/lib/orca-stack.ts`, `infra-tf/dedicated/user_data.sh.tftpl` 세 곳에 있습니다. 하나를 바꾸면 나머지도 바꿉니다
- 전용 서버의 UserData는 `infra-cdk/lib/orca-stack.ts`와 `infra-tf/dedicated/user_data.sh.tftpl` 두 곳에 있고 같은 내용이어야 합니다. 스택 코드를 바꾸면 Terraform 코드에도 같은 변경을 넣습니다
- 자산 디렉터리(`infra-cdk/lib/host/`, `infra-cdk/lib/pairing/`, `infra-cdk/lib/gate/`)에는 문서 파일을 두지 않습니다. 파일이 늘면 자산 해시가 바뀌어 다음 배포에서 Lambda가 갱신되고 서버에서 설치가 다시 실행됩니다. Terraform 배포도 `infra-cdk/lib/gate/`를 묶어 올리고 `infra-cdk/lib/host/`의 스크립트 해시로 재설치를 정합니다
- 커스텀 리소스가 돌려주는 속성 값은 ASCII로 씁니다. CloudFormation이 한글을 `?`로 바꿉니다
- 문서의 그림은 `docs/infographic/`의 Python 모듈로 그립니다(aws-infographic 스킬의 `infokit.py`, `buildkit.py`). 그림에는 코드나 실행으로 확인한 값만 적고 근거를 `docs/infographic/sources.md`에 남깁니다. 영어 구역에는 영어판(`-en`), 한국어 구역에는 한국어판을 넣습니다

## Key Commands

```bash
# 작업 환경 준비 (도구 확인, 실행 권한, CDK 의존성). AWS와 서버를 건드리지 않음
bash scripts/setup.sh

# 코드 시험 여섯 묶음 (게이트 함수, 설정 서비스, 페어링, 호스트 설치, 업그레이드 스크립트, 배포 스크립트)
npm test --prefix infra-cdk

# Terraform 시험 (형식, validate, 계획 시험, ssm_run.sh). AWS를 부르지 않음. 처음에는 provider를 내려받음
bash infra-tf/run-tests.sh

# 하네스 시험. 이름으로 고를 수 있음: hooks, secret-patterns, structure
bash tests/run-all.sh

# 형식 검사
(cd infra-cdk && npx tsc --noEmit -p .)

# 버전 비교만 (배포하지 않음)
bash upgrade_orca.sh --check

# 배포와 업그레이드. 승인을 받은 뒤 실행하고 출력의 링크와 코드를 가림
bash deploy_orca.sh --attach <호스트 스택> --yes 2>&1 | sed -u -E \
  's#(pairing=)[^ ]*#\1<masked>#g; s#(orca://pair)[^ ]*#\1<masked>#g; s#(GateSetupCode = ).*#\1<masked>#; s#(설정 코드  : ).*#\1<masked>#'
bash upgrade_orca.sh --version <버전> --yes     # 같은 필터를 거침

# Terraform 배포. 계획만 보려면 --plan (아무것도 만들지 않음). 출력에 링크가 없어 필터가 필요 없음
bash deploy_orca_tf.sh --attach <호스트 스택> --plan
bash deploy_orca_tf.sh --attach <호스트 스택> --yes                          # 승인을 받은 뒤
bash deploy_orca_tf.sh --attach <호스트 스택> --orca-version <버전> --yes    # Terraform 배포의 업그레이드

# 문서의 그림 다시 만들기 (검사 결과가 0건이어야 함). 이름의 앞부분으로 고를 수 있음: 01, 02, 03, 04
docs/infographic/build.sh

# 접속 암호 변경, 스택 삭제 (승인을 받은 뒤). Terraform 배포는 --tf <dedicated|attach>를 붙임
bash set_password.sh
bash cleanup.sh
bash set_password.sh --tf attach
bash cleanup.sh --tf attach
```

알아 둘 점:

- `npx cdk diff`는 `OrcaVersion`을 스택의 지금 값이 아니라 템플릿의 기본값으로 계산해 보여 줍니다(2026-11-22 확인). 버전이 움직이면 안 되는 배포에는 `--orca-version <지금 버전>`을 명시합니다. 옵션을 빼면 이전 값을 유지하도록 만들어져 있지만 그 경로는 기본값과 지금 값이 다른 상태에서 확인한 적이 없습니다
- `deploy_orca.sh`는 `--no-pairing-output`과 `--no-password-gate`를 이전 배포에서 이어받지 않습니다. 이 옵션으로 만든 스택은 다시 배포할 때마다 같은 옵션을 줍니다. `upgrade_orca.sh`는 두 옵션을 넘기지 못합니다
- 전용 서버를 `--yes` 없이 배포하면 번호 메뉴로 리전, VPC(새로 만들기 또는 계정의 기존 VPC 목록), 인스턴스 타입을 고릅니다(`deploy_guide.sh`). 옵션으로 준 값은 묻지 않습니다. 기존 VPC는 서브넷을 CDK의 `Vpc.fromLookup`과 같은 기준으로 나눠 보여 주고, 퍼블릭 서브넷이 가용 영역 둘 이상에 있고 프라이빗 서브넷이 하나 이상 있어야 받습니다. 그 VPC에 SSM 엔드포인트가 이미 있으면 새로 만들지 않습니다
- 이미 배포한 전용 서버 스택은 VPC와 인스턴스 타입을 지금 값으로 이어받습니다. 다른 VPC를 주면 멈춥니다(VPC가 바뀌면 ALB와 EC2를 모두 새로 만들게 됩니다)
- `deploy_orca_tf.sh`는 입력 값을 구성 디렉터리의 `orca.auto.tfvars.json`에 저장하고 다시 실행할 때 주지 않은 옵션은 저장된 값을 유지합니다(`--no-password-gate` 포함). `upgrade_orca.sh`는 CDK 스택만 다룹니다
- Terraform의 전용 서버 구성(`infra-tf/dedicated`)은 실제로 두 번 배포해 확인하고 지웠습니다(2026-11-23, 새 VPC와 기존 VPC). 기존 서버에 추가하는 구성(`infra-tf/attach`)은 적용해 본 적이 없습니다. 읽기 전용 `terraform plan`, 가짜 provider의 계획 시험, 같은 모양의 로컬 구성으로 본 설치와 제거의 실행 시점까지만 확인했습니다
- 배포가 있는 구성 디렉터리에는 저장된 입력 값(`orca.auto.tfvars.json`)과 상태 파일이 있습니다. 그 디렉터리에서 `terraform test`를 실행해도 되도록 시험 파일은 모든 변수를 스스로 정합니다
- 새 Orca 버전으로 올리기 전에 RPM의 의존성, `serve` 옵션, 로그 문구가 그대로인지 확인합니다. 순서는 `docs/runbooks/upgrade-orca.md`에 있습니다
- `/deploy`, `/test-all`, `/review` 명령과 `project-review`, `sync-docs`, `refactor`, `release` 스킬이 위 절차를 담고 있습니다

---

## Auto-Sync Rules

Plan 모드를 나온 뒤와 코드를 크게 바꾼 뒤에 아래 규칙을 따릅니다.

### Post-Plan Mode Actions

Plan 모드(`/plan`)를 나와 구현을 시작하기 전에:

1. **아키텍처가 바뀌는 결정**을 했으면 `docs/architecture.md`를 수정합니다
2. **대안을 비교해 내린 결정**이면 `docs/decisions/ADR-NNN-title.md`를 만듭니다
3. **새 최상위 소스 디렉터리**를 만들면 그 디렉터리에 `CLAUDE.md`를 만들고 `.claude/hooks/check-doc-sync.sh`의 `SOURCE_ROOTS`에 넣습니다
4. **운영 절차를 정했으면** `docs/runbooks/`에 런북을 만듭니다
5. **이 파일에 적은 명령이나 관례가 바뀌면** 위 구역을 수정합니다

### Code Change Sync Rules

| 바꾼 것 | 함께 수정할 문서 |
|---|---|
| 스택 코드(`infra-cdk/lib/orca-stack.ts`, `infra-cdk/lib/orca-attach-stack.ts`, `infra-cdk/lib/orca-front-door.ts`) | `docs/architecture.md`의 Infrastructure 표, `docs/reference/iac.md`, `README.md`의 환경 설정. 같은 변경을 `infra-tf/`에도 넣음 |
| Terraform 코드(`infra-tf/`) | `docs/reference/iac.md`, `README.md`의 Terraform 설명과 비교 표, `infra-tf/CLAUDE.md`. 같은 변경을 `infra-cdk/lib/`에도 넣음 |
| 접속 암호 게이트(`infra-cdk/lib/functions/`, `infra-cdk/lib/gate/`) | `docs/api-reference.md`, `docs/reference/security.md`, `README.md`의 보안 기능 |
| 기존 서버 설치 코드(`infra-cdk/lib/host/`) | `docs/runbooks/upgrade-orca.md`, `README.md`의 업그레이드 설명 |
| 페어링 출력(`infra-cdk/lib/pairing/`) | `README.md`의 스택 출력 설명, `docs/api-reference.md` |
| 루트의 운영 스크립트 | `README.md`의 사용법과 환경 설정 표(영어와 한국어 두 구역), 이 파일의 Key Commands |
| `infra-cdk/package.json`의 버전 | 이 파일의 Tech Stack |
| 그림에 적힌 값(포트, 상태 코드, 우선순위, 버전, 절차) | `docs/infographic/`의 장 모듈(`T`와 `T_EN`)과 `docs/infographic/sources.md`를 수정하고 `docs/infographic/build.sh`로 다시 만듦 |
| 사용자에게 보이는 변경 | `CHANGELOG.md`의 `[Unreleased]`(영어와 한국어 두 구역) |

### ADR Numbering

`docs/decisions/ADR-*.md`에서 가장 큰 번호에 1을 더합니다. 형식은 `ADR-NNN-concise-title.md`입니다.

## Implementation References

<!-- AUTO-MANAGED:references -->
층별 구현 참조는 `docs/reference/`에 있습니다. 색인은 [INDEX](docs/reference/INDEX.md)입니다.
- [IaC](docs/reference/iac.md)
- [Security](docs/reference/security.md)
<!-- /AUTO-MANAGED -->
