---
name: release
description: 이 저장소의 변경을 CHANGELOG.md에 정리하고 버전을 매깁니다. 릴리스, 버전 올리기, Changelog 정리를 요청받았을 때 씁니다. Orca 자체를 새 버전으로 올리는 일은 릴리스가 아니라 업그레이드이고 docs/runbooks/upgrade-orca.md가 다룹니다.
---

# 릴리스

이 저장소는 아직 태그가 없습니다. `CHANGELOG.md`의 `[Unreleased]`에 변경을 모아 두고, 사용자가 릴리스를 요청할 때 버전을 매깁니다. AWS 스택의 배포와 Orca 업그레이드는 릴리스와 다른 일이고 `/deploy`와 `docs/runbooks/upgrade-orca.md`가 다룹니다.

## 절차

### 1. 사전 확인
- git 저장소인지, 작업 트리가 깨끗한지 확인합니다: `git status`. git 저장소가 아니면 태그를 달 수 없다는 점을 먼저 알립니다
- 시험이 통과하는지 확인합니다: `npm test --prefix infra-cdk`, `bash infra-tf/run-tests.sh`, `bash tests/run-all.sh`
- 문서가 코드와 맞는지 확인합니다: `/sync-docs`

### 2. 버전 정하기
- 태그가 없으면 첫 버전을 사용자에게 묻습니다. 추측해서 정하지 않습니다(`infra-cdk/package.json`의 `version`은 참고만 합니다)
- 태그가 있으면 Semantic Versioning으로 올립니다. 호환되지 않는 변경은 major, 기능 추가는 minor, 수정은 patch입니다
- 기존 스택을 다시 배포했을 때 리소스가 교체되거나 옵션의 뜻이 바뀌는 변경은 호환되지 않는 변경으로 다룹니다

### 3. CHANGELOG.md 갱신
- `[Unreleased]`의 항목을 `## [X.Y.Z] - YYYY-MM-DD` 아래로 옮기고 `[Unreleased]`는 비워 둡니다
- English와 한국어 두 구역을 같은 구조로 수정합니다. 분류 제목(`### Added` 등)은 두 구역 모두 영어입니다
- 영어 항목은 명령형 동사로, 한국어 항목은 명사형으로 끝냅니다
- 원격 저장소가 있으면 아래쪽 비교 링크를 넣습니다. 없으면 넣지 않습니다
- `infra-cdk/package.json`의 `version`을 같은 값으로 맞춥니다

### 4. 태그
- 사용자가 요청할 때만 커밋하고 태그를 답니다: `git tag -a vX.Y.Z -m "vX.Y.Z"`
- push는 사용자가 요청할 때만 합니다

## 주의
- 배포 상태를 CHANGELOG에 추정으로 적지 않습니다. 확인한 사실만 적습니다
- 시험 추가, 하네스 변경 같은 내부 변경은 CHANGELOG에 넣지 않습니다
- 계정 ID, CloudFront 주소 같은 환경 식별 값을 CHANGELOG에 넣지 않습니다
