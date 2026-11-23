---
description: 이 저장소의 시험(코드 시험 여섯 묶음, Terraform 시험, 하네스, 형식 검사)을 모두 실행하고 결과를 보고합니다
allowed-tools: Read, Glob, Bash(bash tests/run-all.sh:*), Bash(npm test --prefix infra-cdk:*), Bash(bash infra-tf/run-tests.sh:*)
---

# 전체 시험

이 저장소의 시험을 모두 실행합니다. 여기 있는 명령은 AWS 리소스를 만들거나 바꾸지 않고 서버의 서비스를 건드리지 않습니다.

## 1단계: 환경 확인

- `infra-cdk/node_modules`가 있는지 봅니다. 없으면 `bash scripts/setup.sh`가 `npm ci`를 실행합니다
- `jq`, `python3`, `node`가 있는지 봅니다
- `terraform`이 있는지 봅니다. 없으면 Terraform 시험을 건너뛰고 그 사실을 보고합니다

## 2단계: 시험 실행

하나가 실패해도 나머지를 계속 실행해 전체 결과를 보고합니다.

```bash
# 코드 시험 (게이트 함수, 설정 서비스, 페어링, 호스트 설치, 업그레이드 스크립트, 배포 스크립트)
npm test --prefix infra-cdk

# Terraform 시험 (형식, validate, 가짜 provider의 계획 시험, ssm_run.sh). 처음에는 provider를 내려받음
bash infra-tf/run-tests.sh

# 하네스 (훅, 설정, 비밀 값 패턴, 구조, 문서의 포인터)
bash tests/run-all.sh

# 형식 검사
(cd infra-cdk && npx tsc --noEmit -p .)
```

$ARGUMENTS가 있으면 그 묶음만 실행합니다(`code`, `terraform`, `harness`, `types`). 하네스는 `bash tests/run-all.sh hooks`처럼 이름으로 고를 수 있습니다.

`npm test`는 시험 파일을 `&&`로 이어 실행하므로 앞 파일이 실패하면 뒤 파일은 실행되지 않습니다. 실패가 나오면 나머지 파일을 하나씩 따로 실행해 전체 결과를 확인합니다.

## 3단계: 보고

- 묶음마다 실행, 통과, 실패, 건너뜀 수
- 실패한 시험의 파일 경로와 오류
- 원인이 분명하면 수정 방법

## 막혔을 때

### 하네스 시험이 "카운터가 맞지 않거나 실행한 시험이 없습니다"로 끝날 때
시험 파일이 실행기의 변수(`TOTAL`, `PASSED` 등)를 덮어쓴 것입니다. 시험 파일의 변수 이름에 접두어를 붙입니다.

### 구조 시험이 "소스 파일을 모두 적음"에서 실패할 때
새 파일이 모듈의 `CLAUDE.md`에 없습니다. Key Files 표에 더합니다.

### 저장소 검사가 실패할 때 ("저장소: ... 검사를 통과")
추적할 파일에 비밀 값이나 환경 식별 값이 있습니다. 메시지가 가리키는 파일에서 값을 지우거나 자리 표시로 바꿉니다. 검사 대상에서 빼는 것으로 해결하지 않습니다.
