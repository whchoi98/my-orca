# Changelog

<a href="#english"><img src="https://img.shields.io/badge/lang-English-blue.svg" alt="English"></a>
<a href="#korean"><img src="https://img.shields.io/badge/lang-한국어-red.svg" alt="Korean"></a>

---

<a id="english"></a>

# English

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add a dedicated server stack that creates a VPC, an ALB, a CloudFront distribution and a private EC2 instance running `orca-ide serve`
- Add a stack that installs Orca on an existing server behind its ALB through SSM Run Command, without changing the host stack
- Add a password gate at the edge with a CloudFront Function and a KeyValueStore that covers the UI, the assets and the WebSocket upgrade
- Add password setup at first login through a one-time setup code and a setup service on the server
- Add an origin check with the CloudFront prefix list and a random `X-Custom-Secret` header kept in Secrets Manager
- Add the pairing link, the pairing code and the setup code to the stack outputs, with `--no-pairing-output` to leave them out
- Add `deploy_orca.sh`, `get_pairing_url.sh`, `set_password.sh` and `cleanup.sh` for deployment, pairing, the access password and stack deletion
- Add `upgrade_orca.sh` to upgrade Orca on an existing server in place, with a sha256 check of the release RPM and no reboot
- Add a Terraform deployment (`infra-tf/`, `deploy_orca_tf.sh`) that creates the same structure as the CDK stacks in both deployment modes, with `--plan` to show the plan only and inputs that are kept between runs
- Add `--tf` to `get_pairing_url.sh`, `set_password.sh` and `cleanup.sh` so that they work on a Terraform deployment
- Add numbered menus to both deployment scripts for the region, the VPC (a new one or one of the VPCs in the account) and the instance type, with a check of the subnets of an existing VPC before the deployment
- Add four figures to the README, the architecture document and the upgrade runbook: access path and protection layers, the two deployment modes, the first access procedure and the upgrade procedure

### Changed

- Change the default Orca version of both stacks to 1.4.269
- Install `dbus-tools` with the runtime dependencies, because the Orca RPM requires `/usr/bin/dbus-send` from 1.4.269
- Update aws-cdk-lib to 2.278.0 and aws-cdk to 2.1149.0
- Keep the VPC and the instance type of a deployed dedicated server stack when `deploy_orca.sh` runs again, and stop when another VPC is given
- Skip the SSM VPC endpoints without `--skip-vpc-endpoints` when the existing VPC already has them
- Find the subnets of an existing VPC in `deploy_orca_tf.sh` when `--alb-subnets` and `--instance-subnet` are left out

### Fixed

- Fix the rollback of a failed upgrade on an existing server by installing the RPM with `--oldpackage`, so that the previous version can be installed again
- Fix `scripts/setup.sh` so that it no longer gives `deploy_guide.sh` the execute permission, which made a fresh clone show a change in the working tree

---

<a id="korean"></a>

# 한국어

이 프로젝트의 모든 주요 변경 사항은 이 파일에 기록됩니다.
이 문서는 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)를 기반으로 하며,
[Semantic Versioning](https://semver.org/spec/v2.0.0.html)을 따릅니다.

## [Unreleased]

### Added

- VPC, ALB, CloudFront 배포, `orca-ide serve`를 실행하는 Private EC2를 만드는 전용 서버 스택 추가
- 호스트 스택을 바꾸지 않고 SSM Run Command로 기존 서버의 ALB 뒤에 Orca를 설치하는 스택 추가
- UI, 자산, WebSocket 업그레이드까지 확인하는 엣지의 접속 암호 게이트(CloudFront Function과 KeyValueStore) 추가
- 1회용 설정 코드와 서버의 설정 서비스로 처리하는 최초 로그인 암호 설정 추가
- CloudFront prefix list와 Secrets Manager에 보관하는 랜덤 `X-Custom-Secret` 헤더로 하는 오리진 검증 추가
- 스택 출력의 페어링 링크, 페어링 코드, 설정 코드와 이를 제외하는 `--no-pairing-output` 추가
- 배포, 페어링, 접속 암호, 스택 삭제를 맡는 `deploy_orca.sh`, `get_pairing_url.sh`, `set_password.sh`, `cleanup.sh` 추가
- 릴리스 RPM의 sha256을 확인하고 재부팅 없이 기존 서버의 Orca를 올리는 `upgrade_orca.sh` 추가
- 두 배포 방식 모두에서 CDK 스택과 같은 구조를 만드는 Terraform 배포(`infra-tf/`, `deploy_orca_tf.sh`) 추가. 계획만 보여 주는 `--plan`과 실행 사이에 유지되는 입력 값 포함
- Terraform 배포에서도 쓸 수 있도록 `get_pairing_url.sh`, `set_password.sh`, `cleanup.sh`에 `--tf` 옵션 추가
- 두 배포 스크립트에 리전, VPC(새로 만들기 또는 계정의 기존 VPC), 인스턴스 타입을 고르는 번호 메뉴 추가. 기존 VPC는 배포 전에 서브넷을 확인
- README, 아키텍처 문서, 업그레이드 런북에 그림 네 개(접속 경로와 보호 계층, 두 가지 배포 방식, 첫 접속 절차, 업그레이드 절차) 추가

### Changed

- 두 스택의 기본 Orca 버전을 1.4.269로 변경
- Orca RPM이 1.4.269부터 `/usr/bin/dbus-send`를 요구해 실행 의존 패키지에 `dbus-tools` 설치 추가로 변경
- aws-cdk-lib을 2.278.0으로, aws-cdk를 2.1149.0으로 변경
- `deploy_orca.sh`를 다시 실행할 때 이미 배포한 전용 서버 스택의 VPC와 인스턴스 타입을 유지하고 다른 VPC를 주면 멈추도록 변경
- 기존 VPC에 SSM VPC 엔드포인트가 이미 있으면 `--skip-vpc-endpoints` 없이도 생성을 생략하도록 변경
- `deploy_orca_tf.sh`에서 `--alb-subnets`와 `--instance-subnet`을 주지 않으면 기존 VPC의 서브넷을 찾도록 변경

### Fixed

- RPM을 `--oldpackage`로 설치해 이전 버전을 다시 설치할 수 있게 하여 기존 서버에서 실패한 업그레이드의 롤백 수정
- `scripts/setup.sh`가 `deploy_guide.sh`에 실행 권한을 줘서 저장소를 받은 직후의 작업 트리가 변경으로 잡히던 문제 수정
