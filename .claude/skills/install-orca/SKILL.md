---
name: install-orca
description: Orca를 AWS에 처음 설치합니다. 도구와 계정을 확인하고 배포 방식, 배포 도구, 리전, VPC, 인스턴스 타입을 정한 뒤 만들 리소스를 보여 주고 승인을 받아 배포한 다음 첫 접속까지 안내합니다. 설치, 처음 배포, install 요청에 씁니다. 이미 배포한 스택의 변경과 업그레이드는 /deploy가 다룹니다.
---

# Orca 설치

이 저장소를 처음 받은 사람이 Orca를 AWS에 올리고 브라우저로 접속할 때까지의 절차입니다. 실제 계정에 과금되는 리소스를 만듭니다. 배포 명령은 미리 허용되어 있지 않아 실행할 때마다 사용자가 승인합니다.

$ARGUMENTS에 값이 있으면(예: `--attach VscodeServerStack`, `terraform`, 리전 코드) 2단계의 선택에 미리 채우고 그 항목은 묻지 않습니다.

이 스킬이 다루지 않는 일은 다음과 같습니다.

- 이미 배포한 스택의 코드 변경과 Orca 업그레이드: `/deploy`, `docs/runbooks/upgrade-orca.md`
- 배포 삭제와 접속 암호 변경: `bash cleanup.sh`, `bash set_password.sh`

## 지킬 것

- 접속 암호를 대화에서 묻지 않고 명령에도 넣지 않습니다. 암호 없이 배포하고 사용자가 첫 접속 화면에서 정합니다
- 페어링 링크, 설정 코드, 페어링 코드를 출력하지 않습니다. CDK 배포의 출력은 4단계의 가리기 필터를 거칩니다
- `cdk-outputs.json`과 Terraform 상태 파일은 읽지 않습니다. 스택 출력을 통째로 조회하지 않고 `--query`로 필요한 값만 읽습니다(출력에 `PairingWebLink`, `GateSetupCode`, `PairingCode`가 있습니다)
- `get_pairing_url.sh`는 실행하지 않습니다. 사용자가 자기 터미널에서 실행합니다. 세션 안에서 실행하면 링크가 대화에 남습니다
- 세션의 셸에는 터미널 입력이 없어 배포 스크립트의 번호 메뉴를 쓸 수 없습니다. 선택은 대화로 받아 옵션으로 넘기고 항상 `--yes`를 붙입니다
- 한 서버에는 CDK 스택과 Terraform 배포 가운데 하나만 붙입니다
- 계정 ID, 인스턴스 ID, CloudFront 주소는 대화에 보여도 되지만 저장소의 파일에는 적지 않습니다

## 1단계: 준비 확인

AWS를 읽기만 합니다.

1. `bash scripts/setup.sh`를 실행합니다. 도구를 확인하고 실행 권한, git 훅, CDK 의존성을 준비합니다. ERROR로 멈추면 빠진 도구를 알리고 멈춥니다. WARNING에 나온 도구(`aws`, `node`, `npm`, `curl`, `session-manager-plugin`)는 배포와 첫 접속에 필요하니 설치를 안내합니다
2. `aws sts get-caller-identity`로 자격 증명을 확인합니다. 계정과 역할을 보여 주고 이 계정에 설치하는 것이 맞는지 확인받습니다
3. 리전을 정합니다. 사용자가 말하지 않았으면 `AWS_REGION`, 없으면 ap-northeast-2입니다
4. 이미 배포한 것이 있는지 봅니다. 있으면 처음 설치가 아니므로 멈추고 `/deploy`를 안내합니다
   - CDK: `aws cloudformation describe-stacks --stack-name OrcaServerStack --region <리전> --query 'Stacks[0].StackStatus' --output text`. `OrcaOnVscodeStack`도 같은 방법으로 봅니다
   - Terraform: `infra-tf/dedicated`와 `infra-tf/attach`에 저장된 입력 값 파일(`orca.auto.tfvars.json`)이 있는지만 봅니다. 파일을 열지 않습니다

## 2단계: 선택

아래 표의 기본값을 한 번에 보여 주고 바꿀 항목이 있는지 묻습니다. 사용자가 이미 말한 값은 채워서 보여 줍니다.

| 항목 | 기본값 | 다른 선택 |
|---|---|---|
| 배포 방식 | 전용 서버. VPC, ALB, EC2, CloudFront를 새로 만듭니다 | 기존 서버에 추가. ec2_vscode로 만든 VS Code 서버의 EC2와 ALB를 함께 씁니다 |
| 배포 도구 | AWS CDK (`deploy_orca.sh`) | Terraform (`deploy_orca_tf.sh`, Terraform 1.5 이상) |
| 리전 | 1단계에서 정한 리전 | `deploy_guide.sh`의 `GUIDE_REGIONS`에 있는 리전이나 다른 리전 코드 |
| VPC | 새 VPC (10.253.0.0/16, 이름 orca-vpc) | 기존 VPC (`--vpc-id`) |
| 인스턴스 타입 | r6g.xlarge | `deploy_guide.sh`의 `GUIDE_INSTANCE_TYPES`에 있는 타입 |
| 접속 암호 | 첫 접속 화면에서 정합니다 | 없음. 이 스킬은 암호를 받지 않습니다 |

선택에 따라 더 확인합니다.

- 기존 VPC: 아래 명령으로 목록을 보여 줍니다. 퍼블릭 서브넷이 가용 영역 둘 이상에 있고 NAT Gateway나 Transit Gateway로 나가는 기본 경로가 있는 프라이빗 서브넷이 하나 이상 있어야 합니다. 배포 스크립트가 시작 전에 같은 조건을 확인하고 맞지 않으면 이유를 출력하고 멈춥니다

```bash
aws ec2 describe-vpcs --region <리전> --output table \
  --query "Vpcs[].[VpcId,CidrBlock,Tags[?Key=='Name']|[0].Value]"
```

- 기존 서버에 추가: 호스트 스택 이름을 받습니다(ec2_vscode의 기본 이름은 `VscodeServerStack`). 호스트 스택은 수정하지 않고 서버를 재부팅하지 않으며 다른 서비스를 재시작하지 않습니다. 그 서버가 지금 Claude Code가 실행 중인 서버일 수 있다는 점과 Orca가 호스트 역할의 권한을 그대로 쓴다는 점을 알립니다. 자세한 내용은 `docs/deployment.md`에 있습니다
- Terraform: 페어링 링크가 출력에 없고 상태 파일이 구성 디렉터리에 평문으로 남는다는 점을 알립니다. 자세한 내용은 `docs/terraform.md`에 있습니다
- 계정을 여러 사람이 함께 쓰면 CDK 배포에 `--no-pairing-output`을 권합니다. 스택 출력의 페어링 링크는 `cloudformation:DescribeStacks` 권한이 있는 사람이 볼 수 있습니다

## 3단계: 계획과 승인

실행하기 전에 아래 내용을 본문에 보여 주고 승인을 기다립니다.

- 정한 값과 실행할 명령 그대로
- 과금되는 리소스. 삭제할 때까지 과금됩니다
  - 전용 서버: EC2, EBS 100GB, NAT Gateway(새 VPC일 때), ALB, CloudFront와 Function, KeyValueStore, VPC 엔드포인트, Secrets Manager
  - 기존 서버에 추가: CloudFront와 Function, KeyValueStore, Secrets Manager, Lambda. EC2와 ALB는 호스트의 것을 함께 씁니다
- CDK를 처음 쓰는 리전이면 배포 스크립트가 CDK bootstrap(`CDKToolkit` 스택)을 먼저 실행한다는 점
- Terraform이면 계획을 먼저 실행해 보여 줍니다. 아무것도 만들지 않습니다: `bash deploy_orca_tf.sh <옵션> --plan`

CDK의 새 스택은 모두 새로 만드는 리소스라 미리 볼 차이가 없습니다. 위 요약이 계획입니다. 승인받은 내용과 다른 값으로 실행하지 않습니다.

## 4단계: 배포

배포는 CloudFront 배포와 서버 설치가 끝날 때까지 기다립니다. 포그라운드 실행의 제한 시간을 넘길 수 있으니 백그라운드로 실행하고 끝났다는 알림을 기다립니다.

CDK 배포의 출력에는 페어링 링크와 설정 코드가 있습니다. 가리기 필터를 붙여 실행합니다. 필터 뒤라 종료 코드는 필터의 것이므로 성공은 출력의 `배포 완료`로 확인합니다.

```bash
bash deploy_orca.sh --region <리전> <옵션> --yes 2>&1 | sed -u -E \
  's#(pairing=)[^ ]*#\1<masked>#g; s#(orca://pair)[^ ]*#\1<masked>#g; s#(GateSetupCode = ).*#\1<masked>#; s#(설정 코드  : ).*#\1<masked>#'
```

`<옵션>` 자리에는 선택에 따라 `--instance-type <타입>`, `--vpc-id <vpc-id>`, `--attach <호스트 스택>`, `--no-pairing-output`을 넣습니다.

Terraform 배포의 출력에는 링크가 없어 필터가 필요 없습니다.

```bash
bash deploy_orca_tf.sh --region <리전> <옵션> --yes
```

## 5단계: 확인

AWS를 읽기만 합니다.

- CDK: 스택 상태와 주소, 설치된 버전을 필요한 값만 읽습니다

```bash
aws cloudformation describe-stacks --stack-name <스택> --region <리전> --output table \
  --query "Stacks[0].{Status:StackStatus,Url:Outputs[?OutputKey=='CloudFrontURL']|[0].OutputValue,Orca:Parameters[?ParameterKey=='OrcaVersion']|[0].ParameterValue}"
```

- Terraform: `terraform -chdir=infra-tf/<dedicated|attach> output -raw cloudfront_url`
- 암호 게이트가 동작하는지 봅니다. 쿠키 없는 HTML 요청에 401이 나와야 합니다: `curl -s -o /dev/null -w '%{http_code}\n' -H 'Accept: text/html' <CloudFront 주소>/`
- 브라우저 로그인과 페어링은 접속 암호와 링크가 필요해 세션에서 확인하지 않습니다. 확인하지 못했다고 보고합니다

## 6단계: 첫 접속 안내

사용자가 직접 합니다. 링크와 코드를 대화에 붙여 넣지 말라고 함께 알립니다.

1. 자기 터미널에서 `bash get_pairing_url.sh --region <리전>`을 실행합니다. Terraform 배포는 `bash get_pairing_url.sh --tf <dedicated|attach>`입니다. CDK 배포는 CloudFormation 콘솔의 출력 탭에 있는 `PairingWebLink`를 써도 됩니다
2. 링크를 브라우저로 열고 첫 화면에서 새 암호와 확인 암호를 입력합니다. 12자 이상을 권합니다
3. 브라우저가 페어링되고 Orca 화면이 열립니다. 그 뒤로는 CloudFront 주소만 엽니다

링크의 `#` 뒤가 잘려 열리지 않으면 `get_pairing_url.sh` 출력의 `[2]`에 있는 값을 화면에 직접 입력합니다. 서버에서 에이전트를 설정하는 방법은 `docs/usage.md`에 있습니다.

## 7단계: 보고

- 만든 것: 스택 또는 Terraform 구성, 리전, Orca 버전
- 확인한 것과 확인하지 못한 것(브라우저 로그인, 페어링)
- 지우는 방법: `bash cleanup.sh --region <리전>`, Terraform 배포는 `bash cleanup.sh --tf <dedicated|attach>`

## 막혔을 때

### 배포 스크립트가 시작 전에 멈출 때
스크립트가 출력한 이유를 그대로 전합니다. 기존 VPC가 조건에 맞지 않으면 다른 VPC나 새 VPC를 고르게 합니다. 기존 서버에 추가하는 방식에서 호스트 ALB의 보안 그룹이 인터넷에 열려 있다고 나오면 `docs/deployment.md`의 호스트 스택 보안 점검을 안내하고 직접 수정하지 않습니다.

### CDK 배포가 실패할 때
실패한 리소스와 이유를 읽어 보고합니다. 다시 시도할지 지울지는 사용자와 정합니다.

```bash
aws cloudformation describe-stack-events --stack-name <스택> --region <리전> --output table \
  --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]"
```

### 스택은 만들어졌는데 페어링 링크를 받지 못했다고 나올 때
서버 설치가 실패했거나 40분 안에 끝나지 않은 경우입니다. 디버깅할 서버가 롤백으로 사라지지 않도록 스택은 실패하지 않습니다. 사용자가 자기 터미널에서 `bash get_pairing_url.sh --restart`를 실행하게 합니다. 설치의 진행 상황은 서버의 `/var/log/user-data.log`에 있습니다.

### Terraform 배포가 실패할 때
롤백이 없습니다. 만들어진 리소스는 남습니다. 원인을 수정한 뒤 같은 명령을 다시 실행하면 남은 것부터 만듭니다. 상태 파일은 읽지 않습니다.
