# scripts 모듈

## Role

작업 환경을 준비하는 스크립트입니다. AWS 리소스와 서버의 서비스를 건드리지 않습니다. 배포와 운영에 쓰는 스크립트(`deploy_orca.sh`, `upgrade_orca.sh`, `set_password.sh`, `get_pairing_url.sh`, `cleanup.sh`)는 여기가 아니라 저장소 루트에 있습니다.

## Key Files

| 파일 | 내용 |
|---|---|
| `setup.sh` | 처음 작업할 때 한 번 실행. 도구 확인(Terraform은 없어도 됨), 실행 권한(source로만 쓰는 `deploy_guide.sh`는 제외), git 훅 설치(git 저장소일 때), `infra-cdk`의 `npm ci` |
| `install-hooks.sh` | git 훅 둘을 설치. `commit-msg`는 `Co-Authored-By`와 `Claude-Session` 줄을 지우고, `pre-commit`은 `.claude/hooks/secret-scan.sh --staged`를 실행 |

## Rules

- 이 디렉터리의 스크립트는 `aws` 명령, 배포 스크립트, `systemctl`, `sudo`를 부르지 않습니다(`bash tests/run-all.sh hooks`가 `setup.sh`를 검사합니다)
- 주석과 메시지는 한국어로 씁니다
- 스크립트를 수정하면 `bash tests/run-all.sh`로 확인합니다
- `setup.sh`는 git이 추적하는 권한을 바꾸지 않습니다. 실행해도 작업 트리가 변경으로 잡히지 않아야 합니다(`bash tests/run-all.sh hooks`가 검사합니다)
- `install-hooks.sh`는 git 저장소가 아니면 exit 1로 끝납니다. `setup.sh`는 그 경우 훅 설치를 건너뛰고 알립니다
