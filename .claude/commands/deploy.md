---
description: Orca 스택을 배포하거나 업그레이드합니다. 차이를 보여 주고 승인을 받은 뒤 실행하고 출력의 페어링 링크를 가립니다
allowed-tools: Read, Glob, Grep, Bash(bash tests/run-all.sh:*), Bash(npm test --prefix infra-cdk:*), Bash(git status:*)
---

# 배포

실제 AWS 계정과 서버를 바꿉니다. `--attach` 스택은 Claude Code가 실행 중인 서버에 설치되어 있을 수 있습니다. 배포, 업그레이드, 암호 변경, 삭제 명령은 일부러 미리 허용하지 않았습니다. 명령마다 사용자가 승인합니다.

$ARGUMENTS로 할 일을 고릅니다: `deploy`(코드 변경 반영), `upgrade`(Orca 버전 올리기). 스택 삭제와 암호 변경은 이 명령이 다루지 않습니다. 처음 설치는 `install-orca` 스킬이 다룹니다.

배포 도구는 둘입니다. 대상이 CDK 스택이면 아래 단계를 그대로 따르고, Terraform 배포(`infra-tf/`)면 맨 아래 "Terraform 배포일 때"의 차이를 함께 적용합니다. 한 서버에는 둘 가운데 하나만 붙입니다.

## 1단계: 사전 확인

1. 시험을 실행합니다: `npm test --prefix infra-cdk`, `bash tests/run-all.sh`
2. 대상 스택과 지금 `OrcaVersion`을 확인합니다(읽기만): `bash upgrade_orca.sh --check`
3. 바뀐 파일을 봅니다. `infra-cdk/lib/host/`가 바뀌었고 Orca 버전도 올린다면 두 번으로 나눕니다. 설치 코드만 지금 버전으로 먼저 배포하고 그다음에 올립니다(`docs/runbooks/upgrade-orca.md`)
4. 업그레이드면 새 RPM의 의존성, `serve` 옵션, 로그 문구를 런북의 순서로 미리 확인합니다

## 2단계: 차이 보기

템플릿의 차이를 읽기 전용 변경 세트로 봅니다. context 값은 `deploy_orca.sh`가 호스트 스택에서 읽는 것과 같은 값을 줍니다.

- 차이에 Lambda 코드, 설치 커스텀 리소스, 페어링 재조회 말고 다른 리소스(CloudFront, ALB 규칙, 보안 그룹, IAM)가 있으면 이유를 설명합니다
- 차이 화면은 `OrcaVersion`을 템플릿의 기본값으로 계산합니다. 실제 배포에서 버전이 움직이지 않게 하려면 `--orca-version <지금 버전>`을 명시합니다

## 3단계: 승인

차이의 요약(바뀌는 리소스와 서버에서 다시 실행되는 것, 재시작되는 서비스)을 본문에 보여 주고 사용자의 승인을 기다립니다. 승인받은 내용과 다른 변경이 생기면 다시 보여 줍니다.

## 4단계: 실행과 확인

배포 명령의 출력에는 페어링 링크와 설정 코드가 들어 있습니다. `CLAUDE.md`의 Key Commands에 있는 가리기 필터를 거쳐 실행합니다.

실행 뒤에 확인합니다.
- 스택 상태와 `OrcaVersion` 파라미터, 서버의 `rpm -q orca-ide`
- `orca-serve`와 `orca-gate-setup`이 active인지, 재시작 횟수, code-server가 그대로인지
- 대상 그룹 둘이 healthy인지, 사설 IP의 `/web-index.html`이 200인지
- CloudFront가 쿠키 없는 요청에 401을, 암호를 정한 뒤의 `/__gate/setup`에 409를 돌려주는지, ALB 직접 접속이 막히는지
- 브라우저 로그인과 이미 페어링한 브라우저의 재접속은 접속 암호가 필요합니다. 사용자에게 확인을 부탁하고 확인하지 못했다고 적습니다

## 5단계: 보고

- 배포한 것(버전, 바뀐 리소스)과 확인한 결과
- 확인하지 않은 것과 그 이유
- 수정한 문서(`README.md`, `docs/`의 안내 문서, `CHANGELOG.md`, `docs/runbooks/upgrade-orca.md`)

## 막혔을 때

### 차이가 예상과 다를 때
실행하지 않습니다. 차이를 그대로 보여 주고 원인을 확인합니다.

### 설치가 실패해 롤백될 때
CloudFormation이 이전 속성으로 설치를 다시 실행합니다. 롤백이 끝난 뒤 서버의 `rpm -q orca-ide`와 `orca-serve` 상태를 확인하고 SSM Run Command 기록에서 설치 스크립트의 출력을 봅니다.

### 스택이 UPDATE_ROLLBACK_FAILED로 남을 때
더 진행하지 않고 상태와 실패한 리소스를 보고합니다. 되돌리는 방법은 사용자와 정합니다.

## Terraform 배포일 때

- 사전 확인: `bash infra-tf/run-tests.sh`도 실행합니다. 지금 버전은 `terraform -chdir=infra-tf/attach output -raw orca_version`으로 읽습니다(`upgrade_orca.sh`는 CDK 스택만 다룹니다)
- 차이 보기: `bash deploy_orca_tf.sh --attach <호스트 스택> --plan`(업그레이드면 `--orca-version <버전>`을 붙임). 계획만 계산하고 아무것도 만들지 않습니다. `terraform_data.host_install`이 교체된다고 나오면 서버에서 설치 스크립트가 다시 실행되고 `orca-serve`가 재시작될 수 있습니다. `terraform_data.host_uninstall`이 교체되거나 삭제된다고 나오면 Orca를 제거한다는 뜻이니 멈추고 이유를 확인합니다
- 실행: 승인을 받은 뒤 같은 명령에서 `--plan`을 `--yes`로 바꿉니다. 출력에 페어링 링크가 없어 가리기 필터가 필요 없습니다
- 확인: 스택 상태 대신 `terraform -chdir=infra-tf/attach output`의 값과 서버의 `rpm -q orca-ide`를 봅니다. 나머지 확인은 같습니다
- 설치가 실패했을 때: 롤백이 없습니다. 서버는 스크립트가 멈춘 자리에 남고 `terraform_data.host_install`이 tainted가 됩니다. 원인을 수정한 뒤 다시 실행하면 설치부터 다시 합니다. 이전 버전으로 돌아가려면 `--orca-version <이전 버전>`으로 다시 실행합니다
- 상태 파일(`terraform.tfstate`)은 읽지 않습니다. `X-Custom-Secret` 값이 평문으로 들어 있습니다
