# Deploy with Terraform

<a href="#english"><img src="https://img.shields.io/badge/lang-English-blue.svg" alt="English"></a>
<a href="#korean"><img src="https://img.shields.io/badge/lang-한국어-red.svg" alt="Korean"></a>

---

<a id="english"></a>

# English

`deploy_orca_tf.sh` creates the same structure from the Terraform configuration in `infra-tf/`: `infra-tf/dedicated` for a dedicated server and `infra-tf/attach` for an existing server. The edge function and the server scripts are the files the CDK stacks use (`infra-cdk/lib/functions/password-gate.js`, `infra-cdk/lib/gate/`, `infra-cdk/lib/host/`).

What to do after a deployment is in [usage.md](usage.md), and upgrading a Terraform deployment is under [Upgrade Orca](usage.md#terraform-deployment).

## Deployment

```bash
bash deploy_orca_tf.sh --attach VscodeServerStack --yes     # Add Orca to an existing server (infra-tf/attach)
bash deploy_orca_tf.sh --attach-instance <InstanceId> --attach-listener <listener-arn> --yes   # A server that CloudFormation did not create
bash deploy_orca_tf.sh                                      # Interactive: the same menus (region, VPC, instance type) for a dedicated server
bash deploy_orca_tf.sh --plan                               # Show the plan only: nothing is created and no input is saved
ORCA_WEB_PASSWORD='...' bash deploy_orca_tf.sh --yes        # Set the password too, without prompts
```

After the deployment the same scripts work with `--tf`.

```bash
bash get_pairing_url.sh --tf attach      # Pairing link (use dedicated for the dedicated server)
bash set_password.sh --tf attach         # Set or change the access password
bash cleanup.sh --tf attach              # Remove the deployment (terraform destroy)
```

- **One server, one deployment.** Before the first apply on an existing server the script stops when the host ALB already has a rule that forwards to a target group on port 6768, which is the case when the CDK stack is attached. On 2026-11-22 `bash deploy_orca_tf.sh --attach VscodeServerStack --plan` stopped this way on the server that runs `OrcaOnVscodeStack`.
- **Checks before the deployment**: the listener is HTTP:80, no security group of the host ALB has a rule open to the internet, the SSM agent of the host is online, and on the first apply the two rule priorities are free. `--orca-rule-priority` and `--gate-rule-priority` change the priorities.
- **Inputs are saved.** The script writes its inputs to `infra-tf/<dedicated|attach>/orca.auto.tfvars.json`, and an option left out on a later run keeps the saved value. This includes `--no-password-gate`, which `deploy_orca.sh` does not carry over. Without `--orca-version` the saved version stays, and when nothing is saved the latest GitHub release is used.
- **The plan comes first.** The script shows the `terraform plan` output and asks before it applies. `--plan` stops after the plan.
- **The pairing link is not an output.** A Terraform output would stay in the state file in plain text, so the link is read with `get_pairing_url.sh --tf`. The output of a Terraform deployment therefore has no link and no setup code to mask.
- **The state file holds the `X-Custom-Secret` value in plain text** (`terraform.tfstate` under `infra-tf/<dedicated|attach>/`). The script creates the state, plan and input files with umask 077, `.gitignore` and the commit check keep them out of commits, and `.claude/settings.json` denies reading the state file in a Claude Code session. This repository configures no backend, so the state is local. Use an encrypted remote backend when several people deploy.
- **Terraform can be used directly.** Put the variables in a `.tfvars` file or pass them with `-var`, then run the commands below. `infra-tf/attach` requires `host_instance_id` and `host_listener_arn`.

```bash
terraform -chdir=infra-tf/attach init
terraform -chdir=infra-tf/attach plan
terraform -chdir=infra-tf/attach apply
```

## Differences from the CDK Deployment

| Item | CDK (`deploy_orca.sh`) | Terraform (`deploy_orca_tf.sh`) |
|---|---|---|
| Install on an existing server | Lambda custom resource `Custom::OrcaHostInstall` | The `local-exec` provisioner of `terraform_data.host_install` runs `infra-tf/scripts/ssm_run.sh`, which sends the script through SSM Run Command. The machine that runs Terraform needs the AWS CLI |
| Failed install | CloudFormation rolls back and runs the install again with the previous values | No rollback. The server stays where the script stopped, `terraform_data.host_install` is tainted and the next apply runs the install again |
| Uninstall | Delete of the custom resource | Destroy provisioner of `terraform_data.host_uninstall`. It runs on `terraform destroy` or when the instance changes, not on a version change |
| Pairing link | In the stack outputs unless `--no-pairing-output` is given | Never an output. Read it with `get_pairing_url.sh --tf` |
| `X-Custom-Secret` value | CloudFormation dynamic reference, not in the template | In the state file in plain text |
| Setup service bundle | CDK asset bucket | A bucket of its own (public access blocked, TLS only, content hash in the object key) |
| Resource names | Built from the stack name | Built from the `name` variable (2 to 24 lowercase letters, digits or hyphens): `<name>-alb`, `<name>-tg`, `<name>-gate-tg`, `<name>-orca-role-<region>` |
| Instance type of the dedicated server | Allowed list in the template. The menu shows that list | Any type (the menu has a custom entry). The AMI architecture is read from the type |
| Existing VPC for the dedicated server | `--vpc-id` or the menu. CDK picks the subnets | `--vpc-id` or the menu. The script picks one public subnet per Availability Zone and a private subnet (asked in the menu), or takes them from `--alb-subnets` and `--instance-subnet` |
| AMI, UserData and tags of an existing dedicated instance | The AMI is pinned in `cdk.context.json`, and a changed `OrcaVersion` restarts the instance | Changes are not applied (`ignore_changes`). This protects the volume and leaves tags that account automation adds to the instance alone. Rebuild with `terraform apply -replace=aws_instance.orca` |
| Options on a later run | The VPC and the instance type of a dedicated stack are kept. `--no-password-gate` and `--no-pairing-output` must be given again | Saved inputs are kept |
| Upgrade | `upgrade_orca.sh` | `deploy_orca_tf.sh --attach <host stack> --orca-version <version>` |

## What Was Checked

Checked on 2026-11-22 and 2026-11-23 with Terraform 1.14.7 (AWS provider 6.73.0, random 3.9.1 and archive 2.8.1, pinned in `.terraform.lock.hcl` with the hashes of four platforms): `terraform validate` on both configurations, `bash infra-tf/run-tests.sh`, and that the UserData of the dedicated server is byte for byte what the CDK stack produces.

The dedicated server was deployed for real twice with `deploy_orca_tf.sh` and removed again with `cleanup.sh --tf dedicated`: once into a new VPC (55 resources) and once into an existing VPC (33 resources, with the subnets found by the script and the SSM endpoints of that VPC left alone). Each time the server finished its setup, both target groups became healthy, a login through CloudFront reached `orca-serve` (web client, assets and the WebSocket upgrade), direct access to the ALB did not connect, and nothing was left after the destroy. On the second deployment a new plan showed no changes.

Not checked with a real deployment: the configuration for an existing server (`infra-tf/attach`). For it the read-only `terraform plan` against the real account (21 resources), `infra-tf/scripts/ssm_run.sh` with a harmless script over real SSM, and the timing of the install and uninstall resources with a local configuration of the same shape were checked: a version change runs only the install again, a failed install runs again on the next apply, and the uninstall runs only on destroy or when the instance changes.

Terraform versions other than 1.14.7 were not tried (`required_version` is `>= 1.5.0`).

## Options and Variables

The table lists the options of `deploy_orca_tf.sh` and the Terraform variables they set. The script saves the values in `infra-tf/<dedicated|attach>/orca.auto.tfvars.json`.

| Option | Terraform variable | Description | Default |
|---|---|---|---|
| `--attach <host-stack>` | `host_instance_id`, `host_listener_arn`, `host_label` | CloudFormation stack of the existing server (for example `VscodeServerStack`). The script finds its EC2 instance and its ALB listener | (dedicated server when no attach option is given) |
| `--attach-instance <id>` | `host_instance_id` | Instance ID of the existing server, given directly together with `--attach-listener` | |
| `--attach-listener <arn>` | `host_listener_arn` | ARN of the HTTP:80 listener of the ALB in front of the existing server | |
| `--host-instance-sg <sg-id>` | `host_instance_security_group_id` | Host security group that admits the ALB, needed when the host has more than one | the only security group of the host |
| `--host-alb-sg <sg-id>` | `host_alb_security_group_id` | ALB security group, needed when the ALB has more than one | the only security group of the ALB |
| `--orca-rule-priority <n>` | `orca_rule_priority` | Priority of the Orca listener rule on the existing server | 10 |
| `--gate-rule-priority <n>` | `gate_setup_rule_priority` | Priority of the `/__gate/setup` rule, a lower number than the Orca rule | 5 |
| `--region <region>` | `region` | Region of the deployment | saved value, else `AWS_REGION` or ap-northeast-2 |
| `--name <name>` | `name` | Deployment name and prefix of every resource name (2 to 24 lowercase letters, digits or hyphens) | `orca-server`, or `orca-on-vscode` on an existing server |
| `--instance-type <type>` | `instance_type` | EC2 instance type of the dedicated server | r6g.xlarge |
| `--orca-version <x.y.z>` | `orca_version` | Orca release to install | saved value, else the latest GitHub release (variable default 1.4.269) |
| `--vpc-id <vpc-id>` | `vpc_id` | Existing VPC for the dedicated server. Its subnets are checked before the deployment | new VPC 10.253.0.0/16 |
| `--alb-subnets <a,b>` | `alb_subnet_ids` | Two or more public subnets of the existing VPC in different Availability Zones | one public subnet per Availability Zone, found in the VPC |
| `--instance-subnet <id>` | `instance_subnet_id` | Private subnet of the existing VPC with a route out to the internet | the first private subnet found in the VPC |
| `--vpc-name <name>` | `vpc_name` | Name tag of the new VPC | orca-vpc |
| `--skip-vpc-endpoints` | `create_ssm_endpoints` (false) | Skip the SSM VPC endpoints. An existing VPC that already has them is detected, so the option is rarely needed | endpoints are created |
| `--no-password-gate`, `--password-gate` | `password_gate` | Leave out the CloudFront password gate, or create it again | gate on |
| `--plan` | | Show the plan and stop | |
| `--yes` | | Proceed without confirmation | |

Two variables have no script option: `host_user` (the account that runs `orca-serve`, default `ec2-user`) and `vpc_cidr` (CIDR of the new VPC, default 10.253.0.0/16).

Both configurations have the outputs `cloudfront_url`, `pairing_address`, `instance_id`, `alb_endpoint`, `origin_secret_arn`, `password_gate_store_arn`, `password_gate_setup_bundle`, `ssm_access`, `region`, `name` and `orca_version`. The dedicated server adds `private_ip`, `vpc_id` and `ec2_role_name`, and the existing server adds `host`. There is no pairing output.

---

<a id="korean"></a>

# 한국어

`deploy_orca_tf.sh`는 `infra-tf/`의 Terraform 구성으로 같은 구조를 만듭니다. 전용 서버는 `infra-tf/dedicated`, 기존 서버에 추가하는 방식은 `infra-tf/attach`입니다. 엣지 함수와 서버 스크립트는 CDK 스택이 쓰는 파일(`infra-cdk/lib/functions/password-gate.js`, `infra-cdk/lib/gate/`, `infra-cdk/lib/host/`)을 그대로 씁니다.

배포한 뒤에 할 일은 [usage.md](usage.md#korean)에, Terraform 배포의 업그레이드는 [Orca 업그레이드](usage.md#terraform-배포)에 있습니다.

## 배포

```bash
bash deploy_orca_tf.sh --attach VscodeServerStack --yes     # 기존 서버에 Orca 추가 (infra-tf/attach)
bash deploy_orca_tf.sh --attach-instance <InstanceId> --attach-listener <listener-arn> --yes   # CloudFormation으로 만들지 않은 서버
bash deploy_orca_tf.sh                                      # 대화형: 전용 서버를 같은 메뉴(리전, VPC, 인스턴스 타입)로 배포
bash deploy_orca_tf.sh --plan                               # 계획만 확인: 아무것도 만들지 않고 입력 값도 저장하지 않음
ORCA_WEB_PASSWORD='...' bash deploy_orca_tf.sh --yes        # 암호까지 프롬프트 없이 지정
```

배포한 뒤에는 같은 스크립트를 `--tf`와 함께 씁니다.

```bash
bash get_pairing_url.sh --tf attach      # 페어링 링크 (전용 서버는 dedicated)
bash set_password.sh --tf attach         # 접속 암호 설정과 변경
bash cleanup.sh --tf attach              # 배포 삭제 (terraform destroy)
```

- **한 서버에는 배포 하나만 붙입니다.** 기존 서버에 처음 적용하기 전에 호스트 ALB에 6768 포트 대상 그룹으로 전달하는 규칙이 이미 있으면 스크립트가 멈춥니다. CDK 스택이 붙어 있는 서버가 그렇습니다. 2026-11-22에 `OrcaOnVscodeStack`이 있는 서버에서 `bash deploy_orca_tf.sh --attach VscodeServerStack --plan`이 이렇게 멈추는 것을 확인했습니다.
- **배포 전 점검**: 리스너가 HTTP:80일 것, 호스트 ALB의 어느 보안 그룹에도 인터넷 전체에 열린 규칙이 없을 것, 호스트의 SSM 에이전트가 온라인일 것, 처음 적용할 때는 규칙 우선순위 둘이 비어 있을 것. 우선순위는 `--orca-rule-priority`와 `--gate-rule-priority`로 바꿉니다.
- **입력 값을 저장합니다.** 스크립트는 입력 값을 `infra-tf/<dedicated|attach>/orca.auto.tfvars.json`에 쓰고 다시 실행할 때 주지 않은 옵션은 저장된 값을 유지합니다. `deploy_orca.sh`가 이어받지 않는 `--no-password-gate`도 유지됩니다. `--orca-version`을 주지 않으면 저장된 버전을 유지하고 저장된 값이 없으면 GitHub 최신 릴리스를 씁니다.
- **계획을 먼저 보여 줍니다.** 스크립트는 `terraform plan` 결과를 보여 주고 적용하기 전에 묻습니다. `--plan`은 계획까지만 실행합니다.
- **페어링 링크는 출력에 넣지 않습니다.** Terraform 출력은 상태 파일에 평문으로 남기 때문에 링크는 `get_pairing_url.sh --tf`로 읽습니다. 그래서 Terraform 배포의 출력에는 가릴 링크와 설정 코드가 없습니다.
- **상태 파일에는 `X-Custom-Secret` 값이 평문으로 들어갑니다**(`infra-tf/<dedicated|attach>/` 아래의 `terraform.tfstate`). 스크립트는 상태, 계획, 입력 값 파일을 umask 077로 만들고 `.gitignore`와 커밋 전 검사가 이 파일들의 커밋을 막으며 `.claude/settings.json`이 Claude Code 세션에서 상태 파일 읽기를 거부합니다. 이 저장소는 백엔드를 설정하지 않아 상태가 로컬에 있습니다. 여럿이 배포한다면 암호화된 원격 백엔드를 씁니다.
- **Terraform을 직접 써도 됩니다.** 변수를 `.tfvars` 파일에 두거나 `-var`로 넘기고 아래 명령을 실행합니다. `infra-tf/attach`에 꼭 필요한 변수는 `host_instance_id`와 `host_listener_arn`입니다.

```bash
terraform -chdir=infra-tf/attach init
terraform -chdir=infra-tf/attach plan
terraform -chdir=infra-tf/attach apply
```

## CDK 배포와 다른 점

| 항목 | CDK (`deploy_orca.sh`) | Terraform (`deploy_orca_tf.sh`) |
|---|---|---|
| 기존 서버 설치 | Lambda 커스텀 리소스 `Custom::OrcaHostInstall` | `terraform_data.host_install`의 `local-exec` 프로비저너가 `infra-tf/scripts/ssm_run.sh`를 실행하고 이 스크립트가 SSM Run Command로 설치 스크립트를 보냄. Terraform을 실행하는 자리에 AWS CLI가 필요 |
| 설치 실패 | CloudFormation이 롤백하면서 이전 값으로 설치를 다시 실행 | 롤백 없음. 서버는 스크립트가 멈춘 자리에 남고 `terraform_data.host_install`이 tainted가 되어 다음 apply에서 설치를 다시 실행 |
| 제거 | 커스텀 리소스의 Delete | `terraform_data.host_uninstall`의 destroy 프로비저너. `terraform destroy`나 인스턴스가 바뀔 때 실행되고 버전을 바꿀 때는 실행되지 않음 |
| 페어링 링크 | `--no-pairing-output`을 주지 않으면 스택 출력에 들어감 | 출력에 넣지 않음. `get_pairing_url.sh --tf`로 읽음 |
| `X-Custom-Secret` 값 | CloudFormation 동적 참조라 템플릿에 없음 | 상태 파일에 평문으로 들어감 |
| 설정 서비스 묶음 | CDK 자산 버킷 | 전용 버킷(공개 차단, TLS만 허용, 객체 키에 내용 해시) |
| 리소스 이름 | 스택 이름으로 만듦 | `name` 변수(소문자, 숫자, 하이픈 2자에서 24자)로 만듦: `<name>-alb`, `<name>-tg`, `<name>-gate-tg`, `<name>-orca-role-<region>` |
| 전용 서버의 인스턴스 타입 | 템플릿의 허용 목록. 메뉴가 그 목록을 보여 줌 | 제한 없음(메뉴에 직접 입력 항목이 있음). AMI 아키텍처를 타입에서 읽음 |
| 전용 서버의 기존 VPC | `--vpc-id` 또는 메뉴. 서브넷은 CDK가 고름 | `--vpc-id` 또는 메뉴. 스크립트가 가용 영역마다 퍼블릭 서브넷 하나와 프라이빗 서브넷 하나(메뉴에서 물음)를 고르고, `--alb-subnets`와 `--instance-subnet`으로 직접 줄 수도 있음 |
| 이미 만든 전용 서버의 AMI, UserData, 태그 | AMI는 `cdk.context.json`에 고정하고 `OrcaVersion`을 바꾸면 인스턴스가 재시작됨 | 변경을 반영하지 않음(`ignore_changes`). 볼륨을 지키고 계정의 자동화가 인스턴스에 붙인 태그를 그대로 두기 위한 것. 다시 만들려면 `terraform apply -replace=aws_instance.orca` |
| 다시 실행할 때의 옵션 | 전용 서버 스택의 VPC와 인스턴스 타입은 유지. `--no-password-gate`와 `--no-pairing-output`은 다시 줘야 함 | 저장된 입력 값을 유지 |
| 업그레이드 | `upgrade_orca.sh` | `deploy_orca_tf.sh --attach <호스트 스택> --orca-version <버전>` |

## 확인한 범위

2026-11-22와 2026-11-23에 Terraform 1.14.7(AWS provider 6.73.0, random 3.9.1, archive 2.8.1. `.terraform.lock.hcl`에 네 플랫폼의 해시와 함께 고정)로 확인한 것은 다음과 같습니다. 두 구성의 `terraform validate`, `bash infra-tf/run-tests.sh`, 그리고 전용 서버의 UserData가 CDK 스택이 만드는 것과 바이트 단위로 같다는 것입니다.

전용 서버는 `deploy_orca_tf.sh`로 실제로 두 번 배포하고 `cleanup.sh --tf dedicated`로 지웠습니다. 한 번은 새 VPC에(리소스 55개), 한 번은 기존 VPC에(리소스 33개, 서브넷은 스크립트가 찾았고 그 VPC의 SSM 엔드포인트는 그대로 둠) 배포했습니다. 두 번 모두 서버 설치가 끝났고 대상 그룹 둘이 healthy가 됐으며 CloudFront로 로그인해 `orca-serve`까지 닿았습니다(웹 클라이언트, 자산, WebSocket 업그레이드). ALB 직접 접속은 연결되지 않았고 삭제 뒤에 남은 리소스가 없었습니다. 두 번째 배포에서는 계획을 다시 계산해 변경이 없음을 확인했습니다.

실제 배포로 확인하지 않은 것은 기존 서버에 추가하는 구성(`infra-tf/attach`)입니다. 이 구성은 실제 계정을 상대로 한 읽기 전용 `terraform plan`(리소스 21개), 실제 SSM으로 무해한 스크립트를 보낸 `infra-tf/scripts/ssm_run.sh`, 그리고 같은 모양의 로컬 구성으로 본 설치와 제거 리소스의 실행 시점까지 확인했습니다. 버전을 바꾸면 설치만 다시 실행되고, 실패한 설치는 다음 apply에서 다시 실행되며, 제거는 destroy와 인스턴스 변경 때만 실행됩니다.

1.14.7이 아닌 Terraform 버전은 시험하지 않았습니다(`required_version`은 `>= 1.5.0`).

## 옵션과 변수

`deploy_orca_tf.sh`의 옵션과 그 옵션이 정하는 Terraform 변수입니다. 스크립트는 값을 `infra-tf/<dedicated|attach>/orca.auto.tfvars.json`에 저장합니다.

| 옵션 | Terraform 변수 | 설명 | 기본값 |
|---|---|---|---|
| `--attach <host-stack>` | `host_instance_id`, `host_listener_arn`, `host_label` | 기존 서버의 CloudFormation 스택(예: `VscodeServerStack`). 스크립트가 그 스택의 EC2 인스턴스와 ALB 리스너를 찾음 | (attach 옵션이 없으면 전용 서버) |
| `--attach-instance <id>` | `host_instance_id` | 기존 서버의 인스턴스 ID. `--attach-listener`와 함께 직접 지정 | |
| `--attach-listener <arn>` | `host_listener_arn` | 기존 서버 앞 ALB의 HTTP:80 리스너 ARN | |
| `--host-instance-sg <sg-id>` | `host_instance_security_group_id` | ALB 트래픽을 받을 호스트 보안 그룹. 호스트의 보안 그룹이 여러 개일 때 필요 | 호스트의 하나뿐인 보안 그룹 |
| `--host-alb-sg <sg-id>` | `host_alb_security_group_id` | ALB 보안 그룹. ALB의 보안 그룹이 여러 개일 때 필요 | ALB의 하나뿐인 보안 그룹 |
| `--orca-rule-priority <n>` | `orca_rule_priority` | 기존 서버에 추가할 때 Orca 리스너 규칙의 우선순위 | 10 |
| `--gate-rule-priority <n>` | `gate_setup_rule_priority` | `/__gate/setup` 규칙의 우선순위. Orca 규칙보다 낮은 수 | 5 |
| `--region <region>` | `region` | 배포 리전 | 저장된 값, 없으면 `AWS_REGION` 또는 ap-northeast-2 |
| `--name <name>` | `name` | 배포 이름. 모든 리소스 이름의 앞부분(소문자, 숫자, 하이픈 2자에서 24자) | `orca-server`, 기존 서버에 추가하면 `orca-on-vscode` |
| `--instance-type <type>` | `instance_type` | 전용 서버의 EC2 인스턴스 타입 | r6g.xlarge |
| `--orca-version <x.y.z>` | `orca_version` | 설치할 Orca 릴리스 | 저장된 값, 없으면 GitHub 최신 릴리스 (변수 기본값 1.4.269) |
| `--vpc-id <vpc-id>` | `vpc_id` | 전용 서버가 쓸 기존 VPC. 배포 전에 서브넷을 확인함 | 새 VPC 10.253.0.0/16 |
| `--alb-subnets <a,b>` | `alb_subnet_ids` | 기존 VPC의 퍼블릭 서브넷 둘 이상. 가용 영역이 달라야 함 | VPC에서 찾은 퍼블릭 서브넷을 가용 영역마다 하나씩 |
| `--instance-subnet <id>` | `instance_subnet_id` | 기존 VPC의 프라이빗 서브넷. 인터넷으로 나가는 경로가 있어야 함 | VPC에서 찾은 첫 프라이빗 서브넷 |
| `--vpc-name <name>` | `vpc_name` | 새 VPC의 Name 태그 | orca-vpc |
| `--skip-vpc-endpoints` | `create_ssm_endpoints` (false) | SSM VPC 엔드포인트 생성을 생략. 기존 VPC에 이미 있으면 스크립트가 알아서 생략하므로 줄 일이 드묾 | 엔드포인트를 만듦 |
| `--no-password-gate`, `--password-gate` | `password_gate` | CloudFront 접속 암호 게이트를 만들지 않거나 다시 만듦 | 게이트 켬 |
| `--plan` | | 계획만 보여 주고 끝냄 | |
| `--yes` | | 확인 없이 진행 | |

스크립트 옵션이 없는 변수는 둘입니다. `host_user`(`orca-serve`를 실행할 계정, 기본값 `ec2-user`)와 `vpc_cidr`(새 VPC의 CIDR, 기본값 10.253.0.0/16)입니다.

두 구성 모두 `cloudfront_url`, `pairing_address`, `instance_id`, `alb_endpoint`, `origin_secret_arn`, `password_gate_store_arn`, `password_gate_setup_bundle`, `ssm_access`, `region`, `name`, `orca_version`을 출력합니다. 전용 서버는 `private_ip`, `vpc_id`, `ec2_role_name`을, 기존 서버에 추가하는 구성은 `host`를 더 출력합니다. 페어링 값은 출력하지 않습니다.
