# infra-cdk 모듈

## Role

Orca 서버의 AWS 리소스와 서버 설치를 정의하는 CDK(TypeScript) 프로젝트입니다. 스택 둘(전용 서버, 기존 서버에 추가), 두 스택이 함께 쓰는 진입 경로(헤더 비밀값, 접속 암호 게이트, CloudFront, ALB 규칙, 페어링 출력), 엣지 함수, 커스텀 리소스 Lambda, 서버에서 실행되는 설치 스크립트, 그리고 이 코드의 시험이 들어 있습니다. 루트의 `deploy_orca.sh`가 이 프로젝트를 배포합니다.

## Key Files

| 파일 | 내용 |
|---|---|
| `bin/app.ts` | App 진입점. context `attachTo`가 있으면 `OrcaAttachStack`, 없으면 `OrcaStack`을 만듦 |
| `lib/orca-stack.ts` | 전용 서버 스택(`OrcaServerStack`). VPC, 보안 그룹, ALB, EC2, SSM 엔드포인트, UserData의 부트스트랩 |
| `lib/orca-attach-stack.ts` | 기존 서버에 추가하는 스택(`OrcaOnVscodeStack`). 호스트의 ALB 리스너 규칙, 보안 그룹 규칙, 역할 정책, 설치 커스텀 리소스 |
| `lib/orca-front-door.ts` | 두 스택 공용. `X-Custom-Secret` 비밀값, 접속 암호 게이트, CloudFront 배포, ALB 규칙, 페어링 출력 |
| `lib/functions/password-gate.js` | CloudFront Function(viewer request). 로그인과 최초 설정 화면, 쿠키 검증 |
| `lib/gate/setup_service.py` | 최초 로그인 암호 설정 서비스. 서버의 6769 포트에서 실행 |
| `lib/gate/install.sh` | 설정 서비스를 서버에 설치. 암호가 없을 때만 1회용 설정 코드를 만듦 |
| `lib/host/install_orca.sh` | 기존 서버에 `orca-serve`를 설치. SSM Run Command로 실행되고 다시 실행해도 안전 |
| `lib/host/uninstall_orca.sh` | 스택을 삭제할 때 설치한 것을 지움. `~/.config/orca`는 남김 |
| `lib/host/handler.py` | 설치와 제거 커스텀 리소스(`Custom::OrcaHostInstall`)의 Lambda |
| `lib/pairing/handler.py` | 페어링 링크를 스택 출력으로 넣는 커스텀 리소스(`Custom::OrcaPairingInfo`)의 Lambda |
| `lib/pairing/read_pairing.sh` | 서버에서 지금 실행 중인 `orca-serve`의 페어링 정보를 읽는 스크립트 |
| `test/password-gate.test.mjs` | 게이트 함수 시험(Node.js) |
| `test/setup_service_test.py` | 설정 서비스 시험 |
| `test/pairing_test.py` | 페어링 핸들러와 조회 스크립트 시험 |
| `test/host_install_test.py` | 설치 커스텀 리소스와 설치 스크립트의 안전장치 시험 |
| `test/upgrade_test.py` | 루트의 `upgrade_orca.sh` 시험(가짜 aws, curl, deploy) |
| `package.json` | 의존성과 `npm test`. 시험 파일 다섯 개를 차례로 실행 |
| `cdk.json` | CDK 앱 실행 명령과 기능 플래그 |

`cdk.context.json`은 AMI ID를 고정하는 로컬 파일입니다. 계정 ID와 VPC ID가 들어 있어 추적하지 않습니다. 지우면 다음 배포에서 최신 AMI를 다시 조회합니다.

## Rules

- 시험: `npm test --prefix infra-cdk`(저장소 루트에서) 또는 이 디렉터리에서 `npm test`. Python 시험은 `python3 -I`로 실행합니다. 새 시험 파일을 만들면 `package.json`의 `test` 스크립트에 더합니다
- 배포는 루트의 `deploy_orca.sh`로 합니다. 호스트 스택에서 읽어야 하는 context 값이 많아 `npx cdk deploy`를 직접 쓰지 않습니다. 배포 전에 차이를 보여 주고 승인을 받습니다
- `lib/host/`, `lib/pairing/`, `lib/gate/`는 그대로 Lambda 코드나 서버가 내려받는 묶음이 됩니다. 문서 파일을 두지 않습니다(`__pycache__`와 `*.pyc`만 자산에서 빠집니다)
- `lib/host/` 아래 스크립트가 바뀌면 `ScriptSha256` 속성이 달라져 다음 배포에서 서버의 설치가 다시 실행됩니다. Orca 버전을 올리는 배포와 묶지 않습니다
- `lib/host/install_orca.sh`의 `dnf install` 패키지 목록과 `lib/orca-stack.ts`의 UserData 목록을 같게 둡니다. Terraform 쪽의 `infra-tf/dedicated/user_data.sh.tftpl`도 같습니다
- 두 스택의 `OrcaVersion` 기본값을 같게 둡니다. Terraform 두 구성의 `orca_version` 기본값도 같은 값입니다
- Terraform 코드(`infra-tf/`)는 같은 구성을 만들고 `lib/functions/password-gate.js`, `lib/gate/`, `lib/host/`의 파일을 복사하지 않고 그대로 읽습니다. 이 파일들을 옮기거나 이름을 바꾸면 `infra-tf/`의 경로도 수정합니다. 스택의 리소스나 `lib/orca-stack.ts`의 UserData를 바꾸면 Terraform 쪽에도 같은 변경을 넣습니다(`bash tests/run-all.sh structure`가 UserData를 비교합니다)
- 설치 스크립트는 비밀 값을 출력하지 않습니다. 페어링 줄은 journald에만, 설정 코드는 root만 읽는 파일에만 둡니다
- 커스텀 리소스가 돌려주는 속성 값은 ASCII로 씁니다
- `tsc`가 만드는 `*.js`와 `*.d.ts`는 추적하지 않습니다. `lib/functions/*.js`만 예외입니다
