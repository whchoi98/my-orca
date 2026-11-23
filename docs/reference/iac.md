# Infrastructure as Code / IaC 구현 상세

<a href="#english"><img src="https://img.shields.io/badge/lang-English-blue.svg" alt="English"></a>
<a href="#korean"><img src="https://img.shields.io/badge/lang-한국어-red.svg" alt="Korean"></a>

<a id="english"></a>
## English

### 1. Overview
The AWS resources are defined with AWS CDK (TypeScript) in `infra-cdk/` and, as a second deployment tool, with Terraform in `infra-tf/`. The CDK app holds two stacks and picks one from the CDK context: `OrcaStack` (default stack name OrcaServerStack) with its own VPC, ALB and instance, or `OrcaAttachStack` (default stack name OrcaOnVscodeStack) on a server and ALB that another stack already runs. Both call the same helpers in `infra-cdk/lib/orca-front-door.ts`, so the header secret, the password gate, the distribution, the listener rules and the pairing outputs keep the same construct IDs. Deployments go through `deploy_orca.sh`, which looks up the values the stacks need and passes them as context and parameters. The Terraform configuration has two root modules, `infra-tf/dedicated` and `infra-tf/attach`, that share `infra-tf/modules/front-door` and `infra-tf/modules/routes` and read the edge function, the setup service and the host scripts from `infra-cdk/lib/`. `deploy_orca_tf.sh` deploys it. One server takes one deployment from one tool.

### 2. Components
| Component | Path | Purpose |
|---|---|---|
| App entry point | `infra-cdk/bin/app.ts` | Chooses `OrcaAttachStack` when the context key `attachTo` is set, `OrcaStack` otherwise |
| Dedicated stack | `infra-cdk/lib/orca-stack.ts` | VPC, security groups, SSM endpoints, IAM role, ALB and listener, EC2 instance with the setup script in UserData |
| Attach stack | `infra-cdk/lib/orca-attach-stack.ts` | Imports the host resources, adds security group rules, runs the host install custom resource |
| Shared front door | `infra-cdk/lib/orca-front-door.ts` | `addOriginSecret`, `addPasswordGate`, `addDistribution`, `addOrcaRoutes`, `addPairingInfo`, `addPairingOutputs` |
| Host install | `infra-cdk/lib/host/handler.py` | `Custom::OrcaHostInstall`: sends the install or uninstall script through SSM Run Command |
| Host scripts | `infra-cdk/lib/host/install_orca.sh` | Installs the RPM, the unit files and the setup service on an existing server; `infra-cdk/lib/host/uninstall_orca.sh` removes them |
| Pairing outputs | `infra-cdk/lib/pairing/handler.py` | `Custom::OrcaPairingInfo`: runs `infra-cdk/lib/pairing/read_pairing.sh` and returns the link as attributes |
| Gate bundle | `infra-cdk/lib/gate` | S3 asset with the setup service and its installer, downloaded by the server |
| Edge function | `infra-cdk/lib/functions/password-gate.js` | Source of the CloudFront Function, read with `FunctionCode.fromFile` |
| Deployment script | `deploy_orca.sh` | Host lookup, pre-deployment checks, `cdk deploy` with context and parameters, connection guide |
| Dependencies | `infra-cdk/package.json` | `aws-cdk-lib`, the `aws-cdk` CLI, TypeScript, and the `npm test` script |
| Terraform dedicated | `infra-tf/dedicated` | Root module of the dedicated mode: `infra-tf/dedicated/network.tf` (new or existing VPC, SSM endpoints), `infra-tf/dedicated/main.tf` (security groups, role, ALB, instance) and the UserData template |
| Terraform attach | `infra-tf/attach` | Root module of the attach mode: host data sources with postconditions, ingress rules, an inline policy on the host role, the install and uninstall resources |
| Terraform front door | `infra-tf/modules/front-door` | Header value and secret, KeyValueStore, function, bundle bucket, distribution. Counterpart of `infra-cdk/lib/orca-front-door.ts` |
| Terraform routes | `infra-tf/modules/routes` | Target groups, attachments and listener rules; also the source of the two port numbers |
| Terraform host install | `infra-tf/scripts/ssm_run.sh` | Sends the install or uninstall script through SSM Run Command and waits. Counterpart of `infra-cdk/lib/host/handler.py` |
| Terraform deployment script | `deploy_orca_tf.sh` | Host lookup, pre-deployment checks, saved inputs, `terraform plan` and `terraform apply`, connection guide |
| Terraform tests | `infra-tf/run-tests.sh` | `terraform fmt`, `terraform validate`, `terraform test` with a mock provider, the bundle contents and `infra-tf/test/ssm_run_test.py` |

### 3. Key Decisions
- One app, two stacks, one set of helpers: the dedicated stack and the attach stack differ only in where the ALB and the instance come from.
- The attach stack owns everything it adds: two listener rules (priorities 5 and 10), two ingress rules on the host instance security group and one policy on the host role. Deleting the stack removes them, and the host stack is never updated.
- The host install is a custom resource, not UserData: it runs through SSM Run Command, the property `ScriptSha256` re-runs it when a host script changes, and the property `OrcaVersion` upgrades the server in place.
- The three asset directories (`infra-cdk/lib/host`, `infra-cdk/lib/pairing`, `infra-cdk/lib/gate`) exclude only Python bytecode. Any other file added there changes the asset hash, which updates the Lambda functions and, for the gate bundle, re-runs the install on the server. Documents do not belong in these directories.
- `infra-cdk/cdk.context.json` is a local file. It pins the AMI of the dedicated stack and caches the host VPC lookup, and it contains the account ID, so it is not committed.
- `cdk diff` built its change set with the template default of `OrcaVersion`, not with the value of the running stack (seen on 2026-11-22). `deploy_orca.sh` leaves the parameter out for an existing stack so that the running value stays, but that behaviour of `cdk deploy` was not tested here. Pass `--orca-version` to `deploy_orca.sh` when the version must not move.
- A change under `infra-cdk/lib/host` is deployed alone before a version bump, on the reasoning that a rollback runs with the previous Lambda code. The reasoning has not been tested.
- The Terraform configuration mirrors the CDK stacks and shares their server files. It reads `infra-cdk/lib/functions/password-gate.js`, `infra-cdk/lib/gate` and `infra-cdk/lib/host` in place, so the rule about documents in those directories also protects it: the bundle key carries the content hash, and a changed bundle or host script re-runs the install on the next apply.
- The Terraform host install is a `local-exec` provisioner, so the machine that runs Terraform needs the AWS CLI. `terraform_data.host_install` is replaced when the instance, one of the six install inputs or a host script changes, and it has no destroy provisioner. `terraform_data.host_uninstall` is replaced only when the instance changes, and its destroy provisioner runs the uninstall. A version change therefore re-installs in place.
- Terraform does not roll back. A failed install leaves the install resource tainted and the server where the script stopped, and the next apply runs the install again.
- The Terraform configuration has no pairing output and no pairing resource. The state file already holds the `X-Custom-Secret` value in plain text, and a pairing link would be a second credential in it.
- `deploy_orca_tf.sh` keeps its inputs in `orca.auto.tfvars.json` in the root module directory. An option that is left out keeps its saved value, including the password gate switch and the Orca version. The file holds instance IDs and ARNs and is not committed.
- No backend is configured, so the state is a local file in the root module directory. `infra-tf/dedicated/.terraform.lock.hcl` and `infra-tf/attach/.terraform.lock.hcl` pin the providers (AWS 6.73.0, random 3.9.1, archive 2.8.1) with the hashes of four platforms and are committed.
- In `infra-tf/dedicated` the instance ignores changes of the AMI and of UserData, the role name always ends with the Region, an existing VPC needs its subnets as inputs, and there is no list of allowed instance types.
- Checked on 2026-11-22 and 2026-11-23 with Terraform 1.14.7: `terraform validate`, the tests of `infra-tf/run-tests.sh`, and two real deployments of the dedicated server (a new VPC with 55 resources, an existing VPC with 33) that were verified through a login to `orca-serve` and destroyed without leftovers. The configuration for an existing server was not applied. For it a read-only plan against the real account, `infra-tf/scripts/ssm_run.sh` with a harmless script, and the timing of the install and uninstall resources with a local configuration of the same shape were checked: a version change runs only the install again, a failed install runs again on the next apply, and the uninstall runs only on destroy or when the instance changes. No other Terraform version was tried (`required_version` is `>= 1.5.0`).

No ADR has been written yet. The design decisions are listed in `docs/architecture.md`.

### 4. Code Pointers
- `infra-cdk/lib/orca-front-door.ts`: `addOrcaRoutes` (target groups, health checks, listener rule priorities), `addPairingInfo` (provider timeouts, the `Refresh` property)
- `infra-cdk/lib/orca-attach-stack.ts`: `hostResources` (context keys and their patterns), the `HostInstall` custom resource properties
- `infra-cdk/lib/orca-stack.ts`: `setupScript` (the server setup), `Listener80` (`open: false`, default 403), the `cachedInContext` AMI lookup
- `infra-cdk/lib/host/handler.py`: `on_event`, `is_complete`, `environment`
- `infra-cdk/lib/pairing/handler.py`: `read_state`, `attributes`
- `infra-cdk/cdk.json`: CDK app command and feature flags
- `deploy_orca.sh`: the `CDK_CONTEXT` and `CDK_PARAMS` arrays
- `infra-tf/attach/main.tf`: the host data sources and their postconditions, `terraform_data.host_install` (`triggers_replace`), `terraform_data.host_uninstall` (destroy provisioner)
- `infra-tf/dedicated/main.tf`: `aws_instance.orca` (`ignore_changes`), `aws_lb_listener.http` (default 403); `infra-tf/dedicated/network.tf`: the new or the existing VPC
- `infra-tf/modules/front-door/main.tf`: `random_password.origin`, `aws_cloudfront_function.gate`, `aws_s3_object.gate` (content hash in the key)
- `infra-tf/modules/routes/main.tf`: target groups, health checks and listener rule priorities
- `infra-tf/scripts/ssm_run.sh`: `give_up` (an install fails, an uninstall never does)
- `deploy_orca_tf.sh`: the `OVERRIDES` array and the merge with the saved inputs

### 5. Cross-references
- Related modules: `infra-cdk/CLAUDE.md`, `infra-tf/CLAUDE.md`
- Related documents: `docs/architecture.md`, `docs/api-reference.md`, `docs/reference/security.md`
- Related ADRs: none yet
- Related runbooks: `docs/runbooks/upgrade-orca.md`

<a id="korean"></a>
## 한국어

### 1. 개요
AWS 리소스는 `infra-cdk/`의 AWS CDK(TypeScript)로 정의하고 두 번째 배포 도구로 `infra-tf/`의 Terraform으로도 정의합니다. CDK 앱 하나에 스택이 둘 있고 CDK context로 하나를 고릅니다. `OrcaStack`(기본 스택 이름 OrcaServerStack)은 전용 VPC, ALB, 인스턴스를 만들고 `OrcaAttachStack`(기본 스택 이름 OrcaOnVscodeStack)은 다른 스택이 이미 운영하는 서버와 ALB에 올라갑니다. 둘 다 `infra-cdk/lib/orca-front-door.ts`의 같은 함수를 호출하므로 헤더 비밀값, 암호 게이트, 배포, 리스너 규칙, 페어링 출력의 construct ID가 같습니다. 배포는 `deploy_orca.sh`로 합니다. 이 스크립트가 스택에 필요한 값을 조회해 context와 파라미터로 넘깁니다. Terraform 구성에는 루트 모듈이 둘(`infra-tf/dedicated`, `infra-tf/attach`) 있고 둘이 `infra-tf/modules/front-door`와 `infra-tf/modules/routes`를 함께 쓰며 엣지 함수, 설정 서비스, 호스트 스크립트를 `infra-cdk/lib/`에서 읽습니다. 배포는 `deploy_orca_tf.sh`로 합니다. 한 서버에는 한 도구의 배포 하나만 붙입니다.

### 2. 구성요소
| 구성요소 | 경로 | 목적 |
|---|---|---|
| App entry point | `infra-cdk/bin/app.ts` | context 키 `attachTo`가 있으면 `OrcaAttachStack`, 없으면 `OrcaStack`을 고름 |
| Dedicated stack | `infra-cdk/lib/orca-stack.ts` | VPC, 보안 그룹, SSM 엔드포인트, IAM 역할, ALB와 리스너, UserData에 설치 스크립트를 가진 EC2 인스턴스 |
| Attach stack | `infra-cdk/lib/orca-attach-stack.ts` | 호스트 리소스를 가져오고 보안 그룹 규칙을 추가하며 호스트 설치 커스텀 리소스를 실행 |
| Shared front door | `infra-cdk/lib/orca-front-door.ts` | `addOriginSecret`, `addPasswordGate`, `addDistribution`, `addOrcaRoutes`, `addPairingInfo`, `addPairingOutputs` |
| Host install | `infra-cdk/lib/host/handler.py` | `Custom::OrcaHostInstall`: 설치 또는 제거 스크립트를 SSM Run Command로 보냄 |
| Host scripts | `infra-cdk/lib/host/install_orca.sh` | 기존 서버에 RPM, 유닛 파일, 설정 서비스를 설치. `infra-cdk/lib/host/uninstall_orca.sh`가 제거 |
| Pairing outputs | `infra-cdk/lib/pairing/handler.py` | `Custom::OrcaPairingInfo`: `infra-cdk/lib/pairing/read_pairing.sh`를 실행하고 링크를 속성으로 돌려줌 |
| Gate bundle | `infra-cdk/lib/gate` | 설정 서비스와 그 설치 스크립트가 든 S3 자산. 서버가 내려받음 |
| Edge function | `infra-cdk/lib/functions/password-gate.js` | CloudFront Function의 소스. `FunctionCode.fromFile`로 읽음 |
| Deployment script | `deploy_orca.sh` | 호스트 조회, 배포 전 점검, context와 파라미터를 붙인 `cdk deploy`, 접속 안내 |
| Dependencies | `infra-cdk/package.json` | `aws-cdk-lib`, `aws-cdk` CLI, TypeScript, `npm test` 스크립트 |
| Terraform dedicated | `infra-tf/dedicated` | 전용 서버 방식의 루트 모듈: `infra-tf/dedicated/network.tf`(새 VPC 또는 기존 VPC, SSM 엔드포인트), `infra-tf/dedicated/main.tf`(보안 그룹, 역할, ALB, 인스턴스), UserData 템플릿 |
| Terraform attach | `infra-tf/attach` | 기존 서버에 추가하는 방식의 루트 모듈: 사후 조건이 붙은 호스트 데이터 소스, 인바운드 규칙, 호스트 역할의 인라인 정책, 설치와 제거 리소스 |
| Terraform front door | `infra-tf/modules/front-door` | 헤더 값과 비밀값, KeyValueStore, 함수, 묶음 버킷, 배포. `infra-cdk/lib/orca-front-door.ts`에 대응 |
| Terraform routes | `infra-tf/modules/routes` | 대상 그룹, 대상 등록, 리스너 규칙. 포트 번호 둘도 여기서 나옴 |
| Terraform host install | `infra-tf/scripts/ssm_run.sh` | 설치 또는 제거 스크립트를 SSM Run Command로 보내고 기다림. `infra-cdk/lib/host/handler.py`에 대응 |
| Terraform deployment script | `deploy_orca_tf.sh` | 호스트 조회, 배포 전 점검, 입력 값 저장, `terraform plan`과 `terraform apply`, 접속 안내 |
| Terraform tests | `infra-tf/run-tests.sh` | `terraform fmt`, `terraform validate`, 가짜 provider로 하는 `terraform test`, 묶음 내용 확인, `infra-tf/test/ssm_run_test.py` |

### 3. 주요 결정
- 앱 하나, 스택 둘, 함수 한 벌: 전용 서버 스택과 추가 스택은 ALB와 인스턴스가 어디서 오는지만 다릅니다.
- 추가 스택은 자기가 추가한 것을 모두 소유합니다. 리스너 규칙 2개(우선순위 5와 10), 호스트 인스턴스 보안 그룹의 인바운드 규칙 2개, 호스트 역할의 정책 1개입니다. 스택을 삭제하면 함께 사라지고 호스트 스택은 수정하지 않습니다.
- 호스트 설치는 UserData가 아닌 커스텀 리소스입니다. SSM Run Command로 실행하고 속성 `ScriptSha256`이 호스트 스크립트가 바뀌면 설치를 다시 실행하며 속성 `OrcaVersion`이 서버를 그 자리에서 업그레이드합니다.
- 자산 디렉터리 셋(`infra-cdk/lib/host`, `infra-cdk/lib/pairing`, `infra-cdk/lib/gate`)은 Python 바이트코드만 제외합니다. 다른 파일을 넣으면 자산 해시가 바뀌어 Lambda 함수가 갱신되고 gate 묶음이면 서버에서 설치가 다시 실행됩니다. 문서는 이 디렉터리에 두지 않습니다.
- `infra-cdk/cdk.context.json`은 로컬 파일입니다. 전용 서버 스택의 AMI를 고정하고 호스트 VPC 조회 결과를 담고 있으며 계정 ID가 들어 있어 커밋하지 않습니다.
- `cdk diff`는 실행 중인 스택의 값이 아닌 `OrcaVersion`의 템플릿 기본값으로 변경 세트를 만들었습니다(2026-11-22에 확인). `deploy_orca.sh`는 기존 스택이면 실행 중인 값이 유지되도록 파라미터를 넘기지 않는데, `cdk deploy`의 이 동작은 여기서 시험하지 않았습니다. 버전이 바뀌면 안 될 때는 `deploy_orca.sh`에 `--orca-version`을 넘깁니다.
- `infra-cdk/lib/host` 아래를 수정하면 버전을 올리기 전에 그 변경만 먼저 배포합니다. 롤백이 이전 Lambda 코드로 실행된다고 판단했기 때문입니다. 이 판단은 시험하지 않았습니다.
- Terraform 구성은 CDK 스택과 같은 구조를 만들고 서버 파일을 함께 씁니다. `infra-cdk/lib/functions/password-gate.js`, `infra-cdk/lib/gate`, `infra-cdk/lib/host`를 그 자리에서 읽으므로 이 디렉터리에 문서를 두지 않는다는 규칙이 Terraform에도 적용됩니다. 묶음의 객체 키에 내용 해시가 들어가고 묶음이나 호스트 스크립트가 바뀌면 다음 apply에서 설치가 다시 실행됩니다.
- Terraform의 호스트 설치는 `local-exec` 프로비저너라서 Terraform을 실행하는 자리에 AWS CLI가 있어야 합니다. `terraform_data.host_install`은 인스턴스, 설치 입력 값 여섯 개 가운데 하나, 호스트 스크립트가 바뀌면 교체되고 destroy 프로비저너가 없습니다. `terraform_data.host_uninstall`은 인스턴스가 바뀔 때만 교체되고 destroy 프로비저너가 제거를 실행합니다. 그래서 버전을 바꾸면 그 자리에서 다시 설치합니다.
- Terraform은 롤백하지 않습니다. 설치가 실패하면 설치 리소스는 tainted가 되고 서버는 스크립트가 멈춘 자리에 남으며 다음 apply에서 설치가 다시 실행됩니다.
- Terraform 구성에는 페어링 출력과 페어링 리소스가 없습니다. 상태 파일에 이미 `X-Custom-Secret` 값이 평문으로 들어 있고 페어링 링크를 넣으면 자격 증명이 하나 더 들어가기 때문입니다.
- `deploy_orca_tf.sh`는 입력 값을 루트 모듈 디렉터리의 `orca.auto.tfvars.json`에 둡니다. 주지 않은 옵션은 저장된 값을 유지하고 암호 게이트를 켜고 끄는 값과 Orca 버전도 마찬가지입니다. 이 파일에는 인스턴스 ID와 ARN이 들어 있어 커밋하지 않습니다.
- 백엔드를 설정하지 않았으므로 상태는 루트 모듈 디렉터리의 로컬 파일입니다. `infra-tf/dedicated/.terraform.lock.hcl`과 `infra-tf/attach/.terraform.lock.hcl`이 provider(AWS 6.73.0, random 3.9.1, archive 2.8.1)를 네 플랫폼의 해시와 함께 고정하고 이 두 파일은 커밋합니다.
- `infra-tf/dedicated`에서는 인스턴스가 AMI와 UserData의 변경을 무시하고 역할 이름이 항상 리전으로 끝나며 기존 VPC는 서브넷을 입력으로 받고 인스턴스 타입 허용 목록이 없습니다.
- 2026-11-22와 2026-11-23에 Terraform 1.14.7로 확인한 것: `terraform validate`, `infra-tf/run-tests.sh`의 시험, 전용 서버의 실제 배포 두 번(새 VPC에 리소스 55개, 기존 VPC에 리소스 33개). 두 배포는 로그인해 `orca-serve`까지 확인한 뒤 남은 리소스 없이 삭제했습니다. 기존 서버에 추가하는 구성은 적용하지 않았습니다. 이 구성은 실제 계정을 상대로 한 읽기 전용 계획, 무해한 스크립트로 실행한 `infra-tf/scripts/ssm_run.sh`, 같은 모양의 로컬 구성으로 본 설치와 제거 리소스의 실행 시점까지 확인했습니다. 버전을 바꾸면 설치만 다시 실행되고, 실패한 설치는 다음 apply에서 다시 실행되며, 제거는 destroy와 인스턴스 변경 때만 실행됩니다. 다른 Terraform 버전은 시험하지 않았습니다(`required_version`은 `>= 1.5.0`).

ADR은 아직 없습니다. 설계 결정은 `docs/architecture.md`에 적혀 있습니다.

### 4. 코드 포인터
- `infra-cdk/lib/orca-front-door.ts`: `addOrcaRoutes`(대상 그룹, 상태 확인, 리스너 규칙 우선순위), `addPairingInfo`(프로바이더 제한 시간, `Refresh` 속성)
- `infra-cdk/lib/orca-attach-stack.ts`: `hostResources`(context 키와 형식), `HostInstall` 커스텀 리소스의 속성
- `infra-cdk/lib/orca-stack.ts`: `setupScript`(서버 설치), `Listener80`(`open: false`, 기본 403), `cachedInContext` AMI 조회
- `infra-cdk/lib/host/handler.py`: `on_event`, `is_complete`, `environment`
- `infra-cdk/lib/pairing/handler.py`: `read_state`, `attributes`
- `infra-cdk/cdk.json`: CDK 앱 실행 명령과 기능 플래그
- `deploy_orca.sh`: `CDK_CONTEXT`와 `CDK_PARAMS` 배열
- `infra-tf/attach/main.tf`: 호스트 데이터 소스와 사후 조건, `terraform_data.host_install`(`triggers_replace`), `terraform_data.host_uninstall`(destroy 프로비저너)
- `infra-tf/dedicated/main.tf`: `aws_instance.orca`(`ignore_changes`), `aws_lb_listener.http`(기본 403). `infra-tf/dedicated/network.tf`: 새 VPC 또는 기존 VPC
- `infra-tf/modules/front-door/main.tf`: `random_password.origin`, `aws_cloudfront_function.gate`, `aws_s3_object.gate`(키에 내용 해시)
- `infra-tf/modules/routes/main.tf`: 대상 그룹, 상태 확인, 리스너 규칙 우선순위
- `infra-tf/scripts/ssm_run.sh`: `give_up`(설치는 실패하고 제거는 실패하지 않음)
- `deploy_orca_tf.sh`: `OVERRIDES` 배열과 저장된 입력 값의 병합

### 5. 상호 참조
- 관련 모듈: `infra-cdk/CLAUDE.md`, `infra-tf/CLAUDE.md`
- 관련 문서: `docs/architecture.md`, `docs/api-reference.md`, `docs/reference/security.md`
- 관련 ADR: 아직 없음
- 관련 런북: `docs/runbooks/upgrade-orca.md`

Last updated: 2026-11-22
