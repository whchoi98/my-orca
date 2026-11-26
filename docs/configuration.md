# Configuration Reference

<a href="#english"><img src="https://img.shields.io/badge/lang-English-blue.svg" alt="English"></a>
<a href="#korean"><img src="https://img.shields.io/badge/lang-한국어-red.svg" alt="Korean"></a>

---

<a id="english"></a>

# English

The access password is never stored in a file. Enter it at the prompt of `deploy_orca.sh`, `deploy_orca_tf.sh` or `set_password.sh`, or pass it once as an environment variable in front of the command. Only a salt, a salted hash and the cookie signing key are stored, in the CloudFront KeyValueStore.

The options and variables of the Terraform deployment are in [terraform.md](terraform.md#options-and-variables).

## Environment Variables

| Variable | Description | Default |
|---|---|---|
| `ORCA_WEB_PASSWORD` | Access password for `deploy_orca.sh` and `deploy_orca_tf.sh`, passed once in front of the command for a deployment without prompts. Do not write it to `.env` or any other file | (none: prompt, or setup at first login) |
| `AWS_REGION` | Region used by every script. `--region` overrides it. With `--tf` the region comes from the Terraform outputs | ap-northeast-2 |
| `AWS_DEFAULT_REGION` | Region used when `AWS_REGION` is not set | ap-northeast-2 |
| `STACK_NAME` | Stack name used by every script. `--stack-name` overrides it. Not used with `--tf` | `OrcaServerStack` (`OrcaOnVscodeStack` with `--attach` and in `upgrade_orca.sh`) |
| `CLAUDE_NOTIFY_WEBHOOK` | Webhook URL for Claude Code notifications (optional, read by the notification hook) | (empty: no notification) |

## Stack Parameters

| Parameter | Description | Default |
|---|---|---|
| InstanceType | EC2 instance type (ARM64 Graviton recommended, some x86 types allowed) | r6g.xlarge |
| OrcaVersion | Orca release to install. An `--attach` stack upgrades to the new value when it changes (`upgrade_orca.sh`); the dedicated server stack uses it only for the first installation | Latest release at deploy time (template default 1.4.269) |
| CloudFrontPrefixListId | ID of the CloudFront origin-facing managed prefix list | (looked up by the deploy script) |
| VpcName | Name tag of the new VPC | orca-vpc |

## CDK Context

CDK context for `--attach`: `attachTo`, `hostInstanceId`, `hostVpcId`, `hostListenerArn`, `hostAlbDnsName`, `hostAlbSecurityGroupId`, `hostInstanceSecurityGroupId`, `hostRoleName` (all found in the host stack and passed by `deploy_orca.sh`), `hostUser` (default `ec2-user`), `orcaRulePriority` and `gateSetupRulePriority` (default 10 and 5).

CDK context for the dedicated server: `useExistingVpc=true` with `vpcId=<id>` (existing VPC), `vpcCidr` (CIDR of the new VPC), `skipVpcEndpoints=true`, `passwordGate=false` (no password gate, `deploy_orca.sh --no-password-gate`), `pairingOutput=false` (keeps the pairing link out of the outputs, `--no-pairing-output`), `pairingRefresh` (when the value changes, the link is read again during the deployment), `roleNameSuffix`, `stackName`.

## Outputs

The table lists the outputs of the CDK stacks. The Terraform outputs are under [Terraform Options and Variables](terraform.md#options-and-variables).

| Output | Description |
|---|---|
| CloudFrontURL | URL of the Orca web client (HTTPS) |
| PairingWebLink | Full link to open in a browser (password setup or login, then pairing). Before a password is set it includes `&gate-setup=<setup code>` |
| GateSetupCode | One-time code for the password setup page at first login (gone once a password is set; later deployments show `none (...)`) |
| PairingCode | `orca://pair?code=...` to paste into the **Pairing URL or code** field of the Orca connection screen |
| PairingAddress | Address embedded in the pairing link (`wss://<cloudfront-domain>`) |
| InstanceId | EC2 instance ID (for SSM access) |
| PrivateIP | Private IP of the EC2 instance |
| PublicALBEndpoint | ALB DNS name (access from outside the CloudFront prefix list is blocked; the host ALB with `--attach`) |
| HostStack | (`--attach` only) Stack of the server Orca is installed on. Deleting this stack removes only Orca |
| OriginSecretArn | ARN of the Secrets Manager secret that holds the `X-Custom-Secret` value (the value itself is not an output) |
| PasswordGateStoreArn | ARN of the password gate KeyValueStore (used by `set_password.sh`) |
| PasswordGateSetupBundle | S3 URL of the setup service bundle that the server downloads |
| EC2RoleName / SSMAccess / Architecture | For reference |

## EC2 IAM Role

The table lists the role of the dedicated server. An `--attach` stack uses the role of the host and adds one policy to it. The Terraform deployment creates the same policies, and the role of its dedicated server is named `<name>-orca-role-<region>`.

| Policy | Purpose |
|---|---|
| `AmazonSSMManagedInstanceCore` | SSM Session Manager |
| `CloudWatchAgentServerPolicy` | CloudWatch monitoring |
| Inline `BedrockInvokeForCodingAgents` | Bedrock model calls from Claude Code, Codex and Kiro (`InvokeModel*`, `Converse*`, inference profile lookup) |

## Password Gate Paths

The password gate adds the paths below in front of Orca. The details are in [docs/api-reference.md](api-reference.md).

| Path | Method | Handled by | Response |
|---|---|---|---|
| `/__gate/login` | POST | CloudFront Function | 204 with the `orca_gate` cookie when the `x-orca-password` header matches, 401 when it does not, 405 for other methods |
| `/__gate/logout` | any | CloudFront Function | 302 to `/` and the cookie is cleared (when a password is set) |
| `/__gate/setup` | POST | Setup service on the server (port 6769), only while no password is set | 204 when the password is stored, 401 for a wrong setup code, 400 for an invalid password, 409 when the setup is already done, 423 after 20 wrong codes, 502 when the KeyValueStore cannot be read or written. Once a password exists, the CloudFront Function answers 409 |
| `/__gate/health` | GET | Setup service on the server | 200. It is the health check path of the ALB target group and is not routed from CloudFront |
| every other path | any | CloudFront Function, then Orca | Passed to Orca with a valid cookie. Without one: 401 with the login page for HTML requests and 401 for other requests, including the WebSocket upgrade. Before a password is set: 401 with the setup page for HTML requests and 503 for other requests |

Passwords travel as base64 of the UTF-8 text in the request headers `x-orca-password` and `x-orca-password-confirm`, and the setup code in `x-orca-setup-code`.

---

<a id="korean"></a>

# 한국어

접속 암호는 어떤 파일에도 저장하지 않습니다. `deploy_orca.sh`, `deploy_orca_tf.sh`, `set_password.sh`의 프롬프트에 입력하거나 명령 앞에 환경 변수로 한 번만 넘깁니다. CloudFront KeyValueStore에는 salt, salt를 더한 해시, 쿠키 서명 키만 저장됩니다.

Terraform 배포의 옵션과 변수는 [terraform.md](terraform.md#옵션과-변수)에 있습니다.

## 환경 변수

| 변수 | 설명 | 기본값 |
|---|---|---|
| `ORCA_WEB_PASSWORD` | `deploy_orca.sh`와 `deploy_orca_tf.sh`가 읽는 접속 암호. 프롬프트 없이 배포할 때 명령 앞에 한 번만 붙여 넘깁니다. `.env`나 다른 파일에 적지 않습니다 | (없음: 프롬프트 또는 최초 로그인 때 설정) |
| `AWS_REGION` | 모든 스크립트가 쓰는 리전. `--region`이 우선합니다. `--tf`를 주면 Terraform 출력의 리전을 씁니다 | ap-northeast-2 |
| `AWS_DEFAULT_REGION` | `AWS_REGION`이 없을 때 쓰는 리전 | ap-northeast-2 |
| `STACK_NAME` | 모든 스크립트가 쓰는 스택 이름. `--stack-name`이 우선합니다. `--tf`에서는 쓰지 않습니다 | `OrcaServerStack` (`--attach`와 `upgrade_orca.sh`에서는 `OrcaOnVscodeStack`) |
| `CLAUDE_NOTIFY_WEBHOOK` | Claude Code 알림을 보낼 웹훅 주소 (선택, 알림 훅이 읽음) | (비어 있음: 알림을 보내지 않음) |

## 스택 파라미터

| 파라미터 | 설명 | 기본값 |
|---|---|---|
| InstanceType | EC2 인스턴스 타입 (ARM64 Graviton 권장, x86 일부 허용) | r6g.xlarge |
| OrcaVersion | 설치할 Orca 릴리스. `--attach` 스택은 값이 바뀌면 그 버전으로 업그레이드하고(`upgrade_orca.sh`) 전용 서버 스택은 최초 설치에만 씁니다 | 배포 시점 최신 릴리스 (템플릿 기본값 1.4.269) |
| CloudFrontPrefixListId | CloudFront origin-facing managed prefix list의 ID | (배포 스크립트가 조회) |
| VpcName | 새 VPC의 Name 태그 | orca-vpc |

## CDK Context

`--attach`의 CDK context: `attachTo`, `hostInstanceId`, `hostVpcId`, `hostListenerArn`, `hostAlbDnsName`, `hostAlbSecurityGroupId`, `hostInstanceSecurityGroupId`, `hostRoleName`(모두 `deploy_orca.sh`가 호스트 스택에서 찾아 넘깁니다), `hostUser`(기본 `ec2-user`), `orcaRulePriority`와 `gateSetupRulePriority`(기본 10과 5).

전용 서버의 CDK context: `useExistingVpc=true`와 `vpcId=<id>`(기존 VPC), `vpcCidr`(새 VPC의 CIDR), `skipVpcEndpoints=true`, `passwordGate=false`(암호 게이트 비활성화, `deploy_orca.sh --no-password-gate`), `pairingOutput=false`(페어링 링크를 출력에서 제외, `--no-pairing-output`), `pairingRefresh`(값이 바뀌면 배포 때 링크를 다시 읽음), `roleNameSuffix`, `stackName`.

## 출력

아래 표는 CDK 스택의 출력입니다. Terraform 출력은 [Terraform 옵션과 변수](terraform.md#옵션과-변수)에 있습니다.

| 출력 | 설명 |
|---|---|
| CloudFrontURL | Orca 웹 클라이언트 URL (HTTPS) |
| PairingWebLink | 브라우저로 여는 전체 링크 (암호 설정 또는 로그인, 그다음 페어링). 암호를 정하기 전이면 `&gate-setup=<설정 코드>` 포함 |
| GateSetupCode | 최초 로그인 암호 설정 화면의 1회용 코드 (암호를 정하면 소멸, 그 뒤 배포에서는 `none (...)`) |
| PairingCode | Orca 연결 화면의 페어링 코드 입력 칸(Pairing URL or code)에 붙여 넣는 `orca://pair?code=...` |
| PairingAddress | 페어링 링크에 들어가는 주소 (`wss://<cloudfront-domain>`) |
| InstanceId | EC2 인스턴스 ID (SSM 접속용) |
| PrivateIP | EC2의 사설 IP |
| PublicALBEndpoint | ALB DNS 이름 (CloudFront prefix list 밖의 접근은 차단, `--attach`는 호스트 ALB) |
| HostStack | (`--attach`만) Orca가 설치된 서버의 스택. 이 스택을 지우면 Orca만 제거 |
| OriginSecretArn | `X-Custom-Secret` 값이 든 Secrets Manager 보안 암호의 ARN (값 자체는 출력하지 않음) |
| PasswordGateStoreArn | 접속 암호 게이트 KeyValueStore의 ARN (`set_password.sh`가 사용) |
| PasswordGateSetupBundle | 서버가 내려받는 설정 서비스 번들의 S3 주소 |
| EC2RoleName / SSMAccess / Architecture | 참고용 |

## EC2 IAM 역할

아래 표는 전용 서버의 역할입니다. `--attach` 스택은 호스트의 역할을 그대로 쓰고 정책 하나만 추가합니다. Terraform 배포도 같은 정책을 만들고 전용 서버의 역할 이름은 `<name>-orca-role-<region>`입니다.

| 정책 | 용도 |
|---|---|
| `AmazonSSMManagedInstanceCore` | SSM Session Manager |
| `CloudWatchAgentServerPolicy` | CloudWatch 모니터링 |
| 인라인 `BedrockInvokeForCodingAgents` | Claude Code, Codex, Kiro의 Bedrock 모델 호출 (`InvokeModel*`, `Converse*`, 추론 프로파일 조회) |

## 암호 게이트의 경로

암호 게이트는 Orca 앞에 아래 경로를 더합니다. 자세한 내용은 [docs/api-reference.md](api-reference.md)에 있습니다.

| 경로 | 메서드 | 처리하는 곳 | 응답 |
|---|---|---|---|
| `/__gate/login` | POST | CloudFront Function | `x-orca-password` 헤더가 맞으면 `orca_gate` 쿠키와 함께 204, 틀리면 401, 다른 메서드는 405 |
| `/__gate/logout` | 모두 | CloudFront Function | `/`로 302, 쿠키 삭제 (암호가 설정된 경우) |
| `/__gate/setup` | POST | 서버의 설정 서비스(포트 6769), 암호가 없는 동안만 | 암호를 저장하면 204, 설정 코드가 틀리면 401, 암호가 조건에 맞지 않으면 400, 이미 설정을 마쳤으면 409, 코드를 20번 틀린 뒤에는 423, KeyValueStore를 읽거나 쓰지 못하면 502. 암호가 생긴 뒤에는 CloudFront Function이 409로 응답 |
| `/__gate/health` | GET | 서버의 설정 서비스 | 200. ALB 대상 그룹의 상태 확인 경로이며 CloudFront에서는 이 경로로 가지 않음 |
| 그 밖의 모든 경로 | 모두 | CloudFront Function, 그다음 Orca | 쿠키가 유효하면 Orca로 전달. 쿠키가 없으면 HTML 요청에는 로그인 페이지와 함께 401, WebSocket 업그레이드를 포함한 다른 요청에는 401. 암호를 정하기 전에는 HTML 요청에 설정 페이지와 함께 401, 다른 요청에는 503 |

암호는 UTF-8 문자열을 base64로 바꿔 요청 헤더 `x-orca-password`와 `x-orca-password-confirm`에 싣고 설정 코드는 `x-orca-setup-code`에 싣습니다.
