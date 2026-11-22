---
name: project-review
description: 이 저장소의 변경을 CLAUDE.md의 관례에 비춰 검토하고 확신도 75 이상인 문제만 보고합니다. diff나 파일, 커밋 전 변경을 검토해 달라는 요청에 씁니다. 특히 CDK 스택, 서버 설치 스크립트, 접속 암호 게이트, 루트의 운영 스크립트와 그 문서를 수정했을 때 씁니다.
---

# 변경 검토

변경한 코드와 문서를 검토하고 확신도 점수로 잘못된 지적을 걸러 냅니다. 내장 `/code-review`와 이름이 겹치지 않게 `project-review`로 둡니다.

## 검토 범위

기본은 `git diff`의 스테이징하지 않은 변경입니다. git 저장소가 아니거나 사용자가 파일을 지정하면 그 파일을 봅니다.

## 검토 기준

### 프로젝트 관례 (CLAUDE.md "Conventions")
- 페어링 링크, 설정 코드, 접속 암호, `X-Custom-Secret` 값이 코드, 문서, 로그 출력, 시험 자료에 들어가지 않았는지. 설치 스크립트와 Lambda가 비밀 값을 출력하지 않는지
- 계정 ID, ARN, CloudFront 주소, 인스턴스 ID 같은 환경 식별 값이 추적하는 파일에 들어가지 않았는지
- 기존 서버에 설치하는 코드가 `orca-serve`와 `orca-gate-setup` 말고 다른 것을 건드리지 않는지(code-server 재시작, `dnf update`, 재부팅, 다른 프로그램이 쓰는 포트)
- 요청 범위 밖의 기능, 불필요한 추상화, 중복 코드가 없는지. 주석이 이유와 제약만 적는지

### 파일 사이의 일관성
- Orca 버전의 기본값이 네 곳에서 같은지(`infra-cdk/lib/orca-stack.ts`, `infra-cdk/lib/orca-attach-stack.ts`, `infra-tf/dedicated/variables.tf`, `infra-tf/attach/variables.tf`)
- 실행 의존 패키지 목록이 `infra-cdk/lib/host/install_orca.sh`, `infra-cdk/lib/orca-stack.ts`, `infra-tf/dedicated/user_data.sh.tftpl`에서 같은지
- 스택 코드(`infra-cdk/lib/`)를 바꿨으면 같은 변경이 Terraform 코드(`infra-tf/`)에도 들어갔는지, 그 반대도. 전용 서버의 UserData는 두 곳이 같은 내용이어야 합니다
- 운영 스크립트의 옵션을 바꿨으면 README의 두 언어 구역과 `infra-cdk/test/upgrade_test.py`가 함께 바뀌었는지
- 게이트의 경로, 상태 코드, 쿠키를 바꿨으면 `docs/api-reference.md`와 시험이 함께 바뀌었는지
- 자산 디렉터리(`infra-cdk/lib/host/`, `infra-cdk/lib/pairing/`, `infra-cdk/lib/gate/`)에 코드가 아닌 파일이 들어가지 않았는지

### 배포에 미치는 영향
- 커스텀 리소스의 속성이 바뀌어 서버에서 설치가 다시 실행되는지, 그 변경이 Orca 버전 변경과 한 배포에 묶였는지
- 실패했을 때 CloudFormation이 되돌릴 수 있는지(이전 속성으로 다시 실행했을 때 성공하는지)
- 기존 스택을 옵션 없이 다시 배포했을 때 설정이 바뀌는지
- Terraform 코드: `terraform_data.host_install`에 destroy 프로비저너가 붙지 않았는지, `terraform_data.host_uninstall`의 `triggers_replace`가 인스턴스 ID뿐인지(어기면 버전을 올릴 때 Orca를 먼저 제거합니다). 페어링 링크나 설정 코드가 출력이나 리소스 속성으로 상태 파일에 들어가지 않는지

### 버그와 품질
- 논리 오류, 빈 값 처리, 셸의 따옴표와 `set -e`에서 끊기는 자리
- 인증 없이 열리는 경로, 게이트를 지나치는 요청
- 중복, 과한 복잡도, 빠진 시험

## 확신도 점수

문제마다 0에서 100으로 점수를 매깁니다.

| 점수 | 뜻 |
|---|---|
| 0 | 잘못된 지적이거나 이번 변경 이전부터 있던 문제 |
| 25 | 실제 문제일 수 있으나 확인하지 못함 |
| 50 | 실제 문제이나 사소함 |
| 75 | 확인한 실제 문제이고 동작에 영향이 있음 |
| 100 | 확실하고 자주 일어남 |

**75 이상만 보고합니다.**

## 출력 형식

문제마다 다음을 적습니다.

```
### [CRITICAL|IMPORTANT] <제목> (확신도: XX)
**파일:** `path/to/file.ext:line`
**문제:** <무엇이 왜 문제인지>
**근거:** <CLAUDE.md의 관례 또는 확인한 사실>
**수정 방법:** <구체적인 수정>
```

75 이상인 문제가 없으면 무엇을 확인했는지 짧게 적고 끝냅니다. 코드를 읽어서 찾았는지 실행해서 재현했는지를 밝힙니다.
