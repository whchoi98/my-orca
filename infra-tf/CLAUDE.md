# infra-tf 모듈

## Role

`infra-cdk/`의 두 스택과 같은 구성을 Terraform으로 만드는 코드입니다. 루트 모듈 둘(전용 서버, 기존 서버에 추가), 두 구성이 함께 쓰는 모듈 둘, 기존 서버에 설치 스크립트를 보내는 도우미, 그리고 이 코드의 시험이 들어 있습니다. 엣지 함수, 설정 서비스, 서버 설치 스크립트는 복사하지 않고 `infra-cdk/lib/`의 파일을 그대로 읽습니다. 루트의 `deploy_orca_tf.sh`가 이 코드를 배포합니다.

## Key Files

| 파일 | 내용 |
|---|---|
| `dedicated/main.tf` | 전용 서버. 보안 그룹, IAM 역할, ALB와 리스너(기본 응답 403), EC2. `infra-cdk/lib/orca-stack.ts`에 대응 |
| `dedicated/network.tf` | 새 VPC(퍼블릭과 프라이빗 서브넷 둘씩, NAT 하나) 또는 기존 VPC, SSM 엔드포인트 |
| `dedicated/user_data.sh.tftpl` | 전용 서버의 UserData 템플릿. CDK 스택의 UserData와 같은 내용 |
| `dedicated/variables.tf`, `dedicated/outputs.tf`, `dedicated/versions.tf` | 전용 서버의 입력, 출력, provider 설정 |
| `attach/main.tf` | 기존 서버에 추가. 호스트 조회(읽기만), 보안 그룹 규칙, 호스트 역할의 인라인 정책, 설치와 제거(`terraform_data`). `infra-cdk/lib/orca-attach-stack.ts`에 대응 |
| `attach/variables.tf`, `attach/outputs.tf`, `attach/versions.tf` | 기존 서버 추가의 입력, 출력, provider 설정 |
| `modules/front-door/main.tf` | 두 구성 공용. `X-Custom-Secret` 값, 접속 암호 게이트(KeyValueStore, 함수, 설정 서비스 묶음 버킷), CloudFront 배포. `infra-cdk/lib/orca-front-door.ts`에 대응 |
| `modules/front-door/variables.tf`, `modules/front-door/outputs.tf`, `modules/front-door/versions.tf` | 진입 경로 모듈의 입력, 출력, provider 요구 사항 |
| `modules/routes/main.tf` | 두 구성 공용. 대상 그룹 둘(6768, 6769)과 리스너 규칙 둘 |
| `modules/routes/variables.tf`, `modules/routes/outputs.tf`, `modules/routes/versions.tf` | 규칙 모듈의 입력, 출력(포트 번호), provider 요구 사항 |
| `scripts/ssm_run.sh` | 설치와 제거 스크립트를 SSM Run Command로 보내고 끝날 때까지 기다림. `infra-cdk/lib/host/handler.py`에 대응 |
| `run-tests.sh` | 이 모듈의 시험 실행기 |
| `dedicated/tests/dedicated.tftest.hcl` | 기본 배포 시험. 이미 만든 인스턴스가 버전 변경에 바뀌지 않는지도 확인 |
| `dedicated/tests/variants.tftest.hcl` | x86 타입, 기존 VPC, 게이트 끔, 잘못된 입력 |
| `dedicated/tests/modules.tftest.hcl` | 공용 모듈 둘의 시험 |
| `dedicated/tests/mocks/aws.tfmock.hcl`, `attach/tests/mocks/aws.tfmock.hcl` | 가짜 AWS provider가 돌려주는 값 |
| `attach/tests/attach.tftest.hcl` | 기존 서버 추가 시험. 계획만 계산 |
| `test/ssm_run_test.py` | `scripts/ssm_run.sh` 시험(가짜 aws) |
| `test/deploy_script_test.py` | 루트의 `deploy_orca_tf.sh` 시험(가짜 aws, terraform, curl). 사전 점검, 입력 값의 저장과 이어받기, 접속 암호 전달, 대화형 안내(`deploy_guide.sh`)와 기존 VPC의 서브넷 자동 선택 |
| `test/ops_scripts_test.py` | 루트의 `get_pairing_url.sh`, `set_password.sh`, `cleanup.sh`의 `--tf` 옵션 시험(가짜 terraform, aws) |
| `dedicated/.terraform.lock.hcl`, `attach/.terraform.lock.hcl` | provider 버전과 해시(네 플랫폼). 두 파일은 같은 내용 |

`deploy_orca_tf.sh`는 입력 값을 구성 디렉터리의 `orca.auto.tfvars.json`에, Terraform은 상태를 `terraform.tfstate`에 둡니다. 둘 다 추적하지 않습니다. `modules/front-door/.build/`는 설정 서비스 묶음 zip이 만들어지는 자리이고 역시 추적하지 않습니다.

## Rules

- 시험: `bash infra-tf/run-tests.sh`. 형식 검사, 두 구성의 `validate`, 계획 시험, 묶음 내용 확인, 스크립트 시험 세 개(`ssm_run.sh`, 배포 스크립트, 운영 스크립트의 `--tf`)를 차례로 실행합니다. AWS provider를 가짜로 바꿔 실행하므로 AWS를 부르지 않습니다. 처음 실행할 때 provider를 내려받습니다
- 배포는 루트의 `deploy_orca_tf.sh`로 합니다. 배포 전에 계획(`bash deploy_orca_tf.sh --plan`)을 보여 주고 승인을 받습니다
- 한 서버에는 CDK 스택과 Terraform 배포 가운데 하나만 붙입니다. 둘 다 붙이면 설치 스크립트가 서로의 페어링 주소를 덮어씁니다
- 상태 파일에는 `X-Custom-Secret` 값이 평문으로 들어 있습니다. 읽지 않고, `terraform show`와 `terraform state pull`처럼 상태를 그대로 출력하는 명령을 쓰지 않습니다. 값이 필요하면 `terraform output`을 씁니다(비밀 값은 출력으로 만들지 않았습니다)
- 페어링 링크와 설정 코드를 출력(output)이나 리소스 속성으로 만들지 않습니다. 상태 파일에 남기 때문입니다
- 시험 파일(`*.tftest.hcl`)은 머리의 `variables` 블록에서 구성의 모든 변수를 정합니다. `terraform test`는 구성 디렉터리의 `orca.auto.tfvars.json`도 읽으므로, 빠진 변수가 있으면 배포가 있는 디렉터리에서 시험 결과가 달라집니다(`bash tests/run-all.sh structure`가 검사). 변수를 더하면 시험 파일에도 더합니다
- 전용 서버의 인스턴스는 AMI, UserData, 태그의 변경을 반영하지 않습니다(`ignore_changes`). AMI가 바뀌면 볼륨째 교체되고, 계정의 자동화가 붙인 태그를 지우면 다음 적용마다 서로 되돌리게 됩니다
- `attach/tests/`의 시험은 `command = plan`만 씁니다. apply를 하면 `local-exec`가 실제 AWS에 설치 명령을 보냅니다
- `terraform_data.host_install`에는 destroy 프로비저너를 두지 않고, `terraform_data.host_uninstall`의 `triggers_replace`에는 인스턴스 ID만 둡니다. 어기면 버전을 올릴 때 Orca를 먼저 제거하게 됩니다
- `dedicated/user_data.sh.tftpl`은 `infra-cdk/lib/orca-stack.ts`의 UserData와 같은 내용이어야 합니다. 셸의 `${VAR}`는 `$${VAR}`로, rpm의 `%{...}`는 `%%{...}`로 적습니다. 이미 만든 인스턴스에는 반영되지 않습니다(`ignore_changes`)
- 두 구성의 `orca_version` 기본값은 CDK 두 스택의 `OrcaVersion` 기본값과 같게 둡니다
- 리소스 이름은 `var.name`으로 시작합니다. 대상 그룹 이름이 32자까지라 `name`은 24자까지입니다
- 코드 주석은 영어로 씁니다(`infra-cdk/lib/`와 같음)
- `.terraform.lock.hcl`은 추적합니다. provider를 올리면 네 플랫폼(linux_arm64, linux_amd64, darwin_arm64, darwin_amd64)으로 `terraform providers lock`을 다시 실행하고 두 구성에 같은 파일을 둡니다
