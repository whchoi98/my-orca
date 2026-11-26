# Development

<a href="#english"><img src="https://img.shields.io/badge/lang-English-blue.svg" alt="English"></a>
<a href="#korean"><img src="https://img.shields.io/badge/lang-한국어-red.svg" alt="Korean"></a>

---

<a id="english"></a>

# English

The full layout of the repository and its tests. The working rules are in the root `CLAUDE.md`, and each module document (`infra-cdk/CLAUDE.md`, `infra-tf/CLAUDE.md`, `scripts/CLAUDE.md`, `tests/CLAUDE.md`) lists every source file of its module.

## Project Structure

```text
.
├── deploy_orca.sh            # CDK deployment script (interactive or --yes)
├── deploy_orca_tf.sh         # Terraform deployment script (interactive or --yes, --plan shows the plan only)
├── deploy_guide.sh           # Menus both deployment scripts share (region, VPC, instance type); not run directly
├── upgrade_orca.sh           # Upgrade Orca to a new version (--attach stacks; redeploys with deploy_orca.sh)
├── get_pairing_url.sh        # Read the pairing link (SSM Session Manager)
├── set_password.sh           # Set or change the access password (KeyValueStore)
├── cleanup.sh                # Delete the stack (--tf: terraform destroy)
├── README.md
├── CHANGELOG.md
├── CLAUDE.md                 # Project context for Claude Code
├── .env.example              # Environment variables the scripts read (no slot for the access password)
├── .editorconfig
├── .mcp.json
├── infra-cdk/                # CDK TypeScript project
│   ├── bin/app.ts            #   App entry point (-c attachTo=<stack> selects OrcaAttachStack)
│   ├── lib/orca-stack.ts     #   Dedicated server stack (VPC, SG, ALB, CloudFront, Secret, EC2, SSM)
│   ├── lib/orca-attach-stack.ts        # Stack added to an existing server (uses the host ALB and EC2)
│   ├── lib/orca-front-door.ts          # Shared by both stacks: header secret, password gate, CloudFront, ALB rules, pairing outputs
│   ├── lib/host/install_orca.sh        # Install orca-serve on an existing server (SSM Run Command, safe to re-run)
│   ├── lib/host/uninstall_orca.sh      #   Remove it when the stack is deleted (keeps ~/.config/orca)
│   ├── lib/host/handler.py             #   Custom resource Lambda for install and uninstall
│   ├── lib/functions/password-gate.js  # CloudFront Function (login and first-login setup pages)
│   ├── lib/gate/setup_service.py       # Password setup service for the first login (EC2 :6769, S3 asset)
│   ├── lib/gate/install.sh             #   Install the setup service (run by the bootstrap and by install_orca.sh)
│   ├── lib/pairing/handler.py          # Pairing link into the stack outputs (custom resource Lambda)
│   ├── lib/pairing/read_pairing.sh     #   Script run on the server through SSM Run Command
│   ├── test/password-gate.test.mjs     # Gate function tests
│   ├── test/setup_service_test.py      # Setup service tests
│   ├── test/pairing_test.py            # Pairing output tests
│   ├── test/host_install_test.py       # Tests of the install custom resource and the install script guards
│   ├── test/upgrade_test.py            # upgrade_orca.sh tests (fake aws, curl and deploy)
│   ├── test/deploy_test.py             # deploy_orca.sh and deploy_guide.sh tests (fake aws, curl, npm, npx; npm test runs all six)
│   ├── cdk.context.json      #   Pinned AMI IDs (not tracked by git because it holds the account ID; deleting it replaces the instance with the latest AMI on the next deployment)
│   ├── package.json
│   ├── tsconfig.json
│   └── cdk.json
├── infra-tf/                 # Terraform configuration of the same structure
│   ├── dedicated/            #   Dedicated server: main.tf, network.tf, user_data.sh.tftpl, tests/
│   ├── attach/               #   Existing server: listener rules, security group rules, role policy, SSM install, tests/
│   ├── modules/front-door/   #   Shared: header secret, password gate, setup bundle bucket, CloudFront
│   ├── modules/routes/       #   Shared: target groups and listener rules
│   ├── scripts/ssm_run.sh    #   Sends install_orca.sh or uninstall_orca.sh through SSM Run Command and waits
│   ├── test/ssm_run_test.py  #   ssm_run.sh tests (fake aws)
│   └── run-tests.sh          #   fmt, validate, terraform test with a mock provider, ssm_run.sh tests
├── .claude/                  # Claude Code settings (settings.json), hooks, skills, commands, agents
├── docs/                     # Guides (deployment.md, terraform.md, usage.md, configuration.md, development.md), architecture.md, onboarding.md, api-reference.md, reference/, decisions/, runbooks/
│   └── infographic/          #   Sources of the figures (build.sh rebuilds build/*.png and *.svg in Korean and English)
├── scripts/                  # setup.sh (working environment), install-hooks.sh (git hooks)
├── tests/                    # Harness tests: run-all.sh, hooks/, structure/, fixtures/
├── tools/prompts/            # Place for prompts (empty for now)
└── orca/                     # (upstream clone for analysis, ignored by git)
```

## Testing

```bash
# Project code: gate function, setup service, pairing output, host install, upgrade script
npm test --prefix infra-cdk

# Harness: hooks, settings, project structure and document pointers
bash tests/run-all.sh
bash tests/run-all.sh structure      # One suite by name: hooks or structure

# Terraform: formatting, validation, plan tests with a mock provider, ssm_run.sh
bash infra-tf/run-tests.sh
```

The tests use fake AWS clients and commands and do not call AWS. The Terraform tests use a mock provider, and their first run downloads the providers (`terraform init`).

| Suite | File | Checks |
|---|---|---|
| Password gate function | `infra-cdk/test/password-gate.test.mjs` | Responses of the CloudFront Function and its size |
| Setup service | `infra-cdk/test/setup_service_test.py` | Storing the first password, the setup code, the lockout and the routes |
| Pairing output | `infra-cdk/test/pairing_test.py` | The custom resource handler and the script that reads the link on the server |
| Host install | `infra-cdk/test/host_install_test.py` | The install custom resource and the guards of the install script |
| Upgrade script | `infra-cdk/test/upgrade_test.py` | Version comparison, refusals and the hand-off to `deploy_orca.sh` |
| Deployment script and menus | `infra-cdk/test/deploy_test.py` | The menus, the subnet check of an existing VPC, settings kept from a deployed stack |
| Terraform configuration | `infra-tf/dedicated/tests/`, `infra-tf/attach/tests/` | Security group rules, listener rules and their priorities, the gate switch, UserData, input validation, and that a version change does not reach the uninstall |
| SSM install helper | `infra-tf/test/ssm_run_test.py` | The command sent through SSM, shell quoting of the inputs, a failed install, and that an uninstall never blocks a destroy |

---

<a id="korean"></a>

# 한국어

저장소의 전체 구조와 테스트입니다. 작업 규칙은 루트의 `CLAUDE.md`에 있고 모듈 문서(`infra-cdk/CLAUDE.md`, `infra-tf/CLAUDE.md`, `scripts/CLAUDE.md`, `tests/CLAUDE.md`)가 그 모듈의 소스 파일을 모두 적습니다.

## 프로젝트 구조

```text
.
├── deploy_orca.sh            # CDK 배포 스크립트 (대화형 또는 --yes)
├── deploy_orca_tf.sh         # Terraform 배포 스크립트 (대화형 또는 --yes, --plan은 계획만 확인)
├── deploy_guide.sh           # 두 배포 스크립트가 함께 쓰는 메뉴(리전, VPC, 인스턴스 타입). 직접 실행하지 않음
├── upgrade_orca.sh           # Orca를 새 버전으로 업그레이드 (--attach 스택, deploy_orca.sh로 다시 배포)
├── get_pairing_url.sh        # 페어링 링크 조회 (SSM Session Manager)
├── set_password.sh           # 접속 암호 설정과 변경 (KeyValueStore)
├── cleanup.sh                # 스택 삭제 (--tf: terraform destroy)
├── README.md
├── CHANGELOG.md
├── CLAUDE.md                 # Claude Code용 프로젝트 맥락
├── .env.example              # 스크립트가 읽는 환경 변수 (접속 암호 자리는 없음)
├── .editorconfig
├── .mcp.json
├── infra-cdk/                # CDK TypeScript 프로젝트
│   ├── bin/app.ts            #   App 진입점 (-c attachTo=<스택>이면 OrcaAttachStack)
│   ├── lib/orca-stack.ts     #   전용 서버 스택 (VPC, SG, ALB, CloudFront, Secret, EC2, SSM)
│   ├── lib/orca-attach-stack.ts        # 기존 서버에 추가하는 스택 (호스트의 ALB와 EC2를 사용)
│   ├── lib/orca-front-door.ts          # 두 스택 공용: 헤더 비밀값, 암호 게이트, CloudFront, ALB 규칙, 페어링 출력
│   ├── lib/host/install_orca.sh        # 기존 서버에 orca-serve 설치 (SSM Run Command, 다시 실행해도 안전)
│   ├── lib/host/uninstall_orca.sh      #   스택 삭제 때 제거 (~/.config/orca는 유지)
│   ├── lib/host/handler.py             #   설치와 제거를 맡는 커스텀 리소스 Lambda
│   ├── lib/functions/password-gate.js  # CloudFront Function (로그인과 최초 설정 화면)
│   ├── lib/gate/setup_service.py       # 최초 로그인 암호 설정 서비스 (EC2 :6769, S3 asset)
│   ├── lib/gate/install.sh             #   설정 서비스 설치 (부트스트랩과 install_orca.sh가 실행)
│   ├── lib/pairing/handler.py          # 페어링 링크를 스택 출력으로 (커스텀 리소스 Lambda)
│   ├── lib/pairing/read_pairing.sh     #   서버에서 SSM Run Command로 실행하는 조회 스크립트
│   ├── test/password-gate.test.mjs     # 게이트 함수 테스트
│   ├── test/setup_service_test.py      # 설정 서비스 테스트
│   ├── test/pairing_test.py            # 페어링 출력 테스트
│   ├── test/host_install_test.py       # 설치 커스텀 리소스와 설치 스크립트 안전장치 테스트
│   ├── test/upgrade_test.py            # upgrade_orca.sh 테스트 (가짜 aws, curl, deploy)
│   ├── test/deploy_test.py             # deploy_orca.sh와 deploy_guide.sh 테스트 (가짜 aws, curl, npm, npx. npm test가 여섯 개를 모두 실행)
│   ├── cdk.context.json      #   고정된 AMI ID (계정 ID가 들어 있어 git으로 추적하지 않음. 지우면 다음 배포 때 최신 AMI로 인스턴스 교체)
│   ├── package.json
│   ├── tsconfig.json
│   └── cdk.json
├── infra-tf/                 # 같은 구조를 만드는 Terraform 구성
│   ├── dedicated/            #   전용 서버: main.tf, network.tf, user_data.sh.tftpl, tests/
│   ├── attach/               #   기존 서버에 추가: 리스너 규칙, 보안 그룹 규칙, 역할 정책, SSM 설치, tests/
│   ├── modules/front-door/   #   공용: 헤더 비밀값, 암호 게이트, 설정 묶음 버킷, CloudFront
│   ├── modules/routes/       #   공용: 대상 그룹과 리스너 규칙
│   ├── scripts/ssm_run.sh    #   install_orca.sh나 uninstall_orca.sh를 SSM Run Command로 보내고 기다림
│   ├── test/ssm_run_test.py  #   ssm_run.sh 테스트 (가짜 aws)
│   └── run-tests.sh          #   fmt, validate, 가짜 provider로 하는 terraform test, ssm_run.sh 테스트
├── .claude/                  # Claude Code 설정(settings.json), 훅, 스킬, 명령, 에이전트
├── docs/                     # 안내 문서(deployment.md, terraform.md, usage.md, configuration.md, development.md), architecture.md, onboarding.md, api-reference.md, reference/, decisions/, runbooks/
│   └── infographic/          #   그림의 소스 (build.sh가 build/*.png와 *.svg를 한국어판과 영어판으로 다시 만듦)
├── scripts/                  # setup.sh (작업 환경 준비), install-hooks.sh (git 훅 설치)
├── tests/                    # 하네스 테스트: run-all.sh, hooks/, structure/, fixtures/
├── tools/prompts/            # 프롬프트를 둘 자리 (지금은 비어 있음)
└── orca/                     # (분석용 upstream clone, git이 무시)
```

## 테스트

```bash
# 프로젝트 코드: 게이트 함수, 설정 서비스, 페어링 출력, 호스트 설치, 업그레이드 스크립트
npm test --prefix infra-cdk

# 하네스: 훅, 설정, 프로젝트 구조, 문서의 포인터
bash tests/run-all.sh
bash tests/run-all.sh structure      # 이름으로 한 묶음만 실행: hooks 또는 structure

# Terraform: 형식, 구성 검증, 가짜 provider로 하는 계획 테스트, ssm_run.sh
bash infra-tf/run-tests.sh
```

테스트는 가짜 AWS 클라이언트와 명령을 쓰고 AWS를 호출하지 않습니다. Terraform 테스트는 가짜 provider를 쓰고 처음 실행할 때 provider를 내려받습니다(`terraform init`).

| 묶음 | 파일 | 확인하는 것 |
|---|---|---|
| 암호 게이트 함수 | `infra-cdk/test/password-gate.test.mjs` | CloudFront Function의 응답과 크기 |
| 설정 서비스 | `infra-cdk/test/setup_service_test.py` | 첫 암호 저장, 설정 코드, 잠금, 경로 |
| 페어링 출력 | `infra-cdk/test/pairing_test.py` | 커스텀 리소스 핸들러와 서버에서 링크를 읽는 스크립트 |
| 호스트 설치 | `infra-cdk/test/host_install_test.py` | 설치 커스텀 리소스와 설치 스크립트의 안전장치 |
| 업그레이드 스크립트 | `infra-cdk/test/upgrade_test.py` | 버전 비교, 거부하는 경우, `deploy_orca.sh`로 넘기는 인자 |
| 배포 스크립트와 메뉴 | `infra-cdk/test/deploy_test.py` | 메뉴, 기존 VPC의 서브넷 확인, 배포한 스택에서 이어받는 설정 |
| Terraform 구성 | `infra-tf/dedicated/tests/`, `infra-tf/attach/tests/` | 보안 그룹 규칙, 리스너 규칙과 우선순위, 게이트를 켜고 끄는 변수, UserData, 입력 값 검증, 버전을 바꿔도 제거가 실행되지 않는 것 |
| SSM 설치 도우미 | `infra-tf/test/ssm_run_test.py` | SSM으로 보내는 명령, 입력 값의 셸 인용, 설치 실패, 제거가 destroy를 막지 않는 것 |
