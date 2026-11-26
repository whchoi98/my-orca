---
name: sync-docs
description: 이 저장소의 문서(루트와 모듈의 CLAUDE.md, docs/architecture.md, docs/reference/, docs/api-reference.md, 런북, README와 안내 문서, CHANGELOG)를 지금 코드와 맞추고 CLAUDE.md의 품질을 점수로 냅니다. 코드를 크게 바꾼 뒤나 문서를 맞춰 달라는 요청에 씁니다.
---

# 문서 동기화

문서를 지금 코드와 맞춥니다. 사용법과 운영 절차의 원본은 안내 문서(`docs/deployment.md`, `docs/terraform.md`, `docs/usage.md`, `docs/configuration.md`, `docs/development.md`)이고 `README.md`는 요약과 포인터만 둡니다. 같은 내용을 다른 문서에 옮겨 적지 않고 가리키기만 합니다.

## 할 일

### 1. CLAUDE.md 품질 평가
루트와 모듈의 CLAUDE.md를 각각 0에서 100으로 평가합니다.
- 명령과 작업 흐름 (20점)
- 구조 설명의 정확성 (20점)
- 모호하지 않은 규칙 (20점)
- 관례와 주의할 점 (20점)
- 지금 코드와 맞는지 (20점)

### 2. 루트 CLAUDE.md
- Tech Stack의 버전이 `infra-cdk/package.json`과 맞는지, Terraform provider 버전이 `infra-tf/dedicated/.terraform.lock.hcl`과 맞는지 봅니다
- Key Commands의 옵션이 실제 스크립트에 있는지 봅니다
- `<!-- AUTO-MANAGED:references -->` 구역이 `docs/reference/`의 파일 목록과 같은지 봅니다

### 3. 모듈 CLAUDE.md
- `infra-cdk/`, `infra-tf/`, `scripts/`, `tests/`의 Key Files가 실제 파일을 모두 적는지 봅니다. 하네스는 적힌 경로가 있는지와 파일 이름이 문서에 있는지를 검사하지만 설명이 맞는지는 읽어서 확인해야 합니다
- 새 최상위 소스 디렉터리가 생겼으면 CLAUDE.md를 만들고 `.claude/hooks/check-doc-sync.sh`의 `SOURCE_ROOTS`에 넣습니다

### 4. docs/architecture.md
- 구성 요소, Mermaid 그림, Infrastructure 표가 `infra-cdk/lib/`의 스택 코드와 맞는지 봅니다
- CDK와 Terraform의 차이를 적은 자리(`docs/terraform.md`의 비교 표, `docs/reference/iac.md`)가 `infra-tf/`의 코드와 맞는지 봅니다
- English와 한국어 구역의 구조, 표, 그림이 같은지 봅니다

### 5. docs/reference/와 docs/api-reference.md
- 층마다 "Code Pointers"의 경로가 실제로 있는지 봅니다
- 게이트의 경로와 상태 코드를 `infra-cdk/lib/functions/password-gate.js`, `infra-cdk/lib/gate/setup_service.py`에서 다시 읽어 맞춥니다. 추측으로 적지 않습니다
- 새 층이 생겼으면 `/add-reference-doc <layer>`로 더하고 `docs/reference/INDEX.md`를 수정합니다

### 6. README, 안내 문서, 런북
- README와 안내 문서의 두 언어 구역이 같은 구조인지, 예시 명령의 옵션이 스크립트에 있는지 봅니다
- README는 짧게 둡니다(400줄 이하, `bash tests/run-all.sh structure`가 검사). 자세한 내용은 안내 문서에 넣고 README에서는 가리킵니다
- 런북의 절차를 수정할 때는 실제로 실행해 확인한 것과 확인하지 못한 것을 나눠 적고 "Last verified" 날짜를 바꿉니다

### 7. 확인
```bash
bash tests/run-all.sh structure
```

### 8. 보고
```
## 문서 동기화 보고

### 품질 점수
| 파일 | 점수 | 메모 |
|---|---|---|

### 수정한 것
- <파일>: <무엇을>

### 사용자 확인이 필요한 것
- <코드와 문서가 다른데 어느 쪽이 맞는지 알 수 없는 항목>
```

## 주의
- 문서의 한국어는 합니다체로 씁니다
- 계정 ID, CloudFront 주소, 인스턴스 ID는 `<account-id>`, `<cloudfront-domain>`, `<InstanceId>`로 씁니다
- 페어링 링크, 설정 코드, 접속 암호는 어떤 문서에도 넣지 않습니다. `cdk-outputs.json`은 읽지 않습니다
