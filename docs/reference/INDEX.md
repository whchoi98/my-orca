# Implementation Reference Index / 구현 참조 인덱스

<a href="#english"><img src="https://img.shields.io/badge/lang-English-blue.svg" alt="English"></a>
<a href="#korean"><img src="https://img.shields.io/badge/lang-한국어-red.svg" alt="Korean"></a>

<a id="english"></a>
## English

Layer-by-layer implementation guides. Each file follows the same 5-section
structure (Overview, Components, Key Decisions, Code Pointers, Cross-references).
The working rules of this project live in the root `CLAUDE.md`; these files point at code.

<!-- AUTO-MANAGED:index -->
| Layer | File | Status |
|---|---|---|
| Infrastructure | — | not generated (no container or cluster files; the network and the instance are in IaC) |
| Data | — | not applicable |
| API | — | not generated (the HTTP paths of the password gate are in `docs/api-reference.md`) |
| IaC | [iac.md](iac.md) | present |
| Frontend | — | not applicable (the web client belongs to upstream Orca) |
| UI | — | not applicable |
| Security | [security.md](security.md) | present |
| Agent · LLM | — | not applicable |
<!-- /AUTO-MANAGED -->

Last updated: 2026-11-22 (managed by /init-project, /add-reference-doc, /sync-docs)

<a id="korean"></a>
## 한국어

층별 구현 안내입니다. 각 파일은 같은 5개 구역(개요, 구성요소, 주요 결정, 코드 포인터, 상호 참조)을 따릅니다.
이 프로젝트의 작업 규칙은 루트의 `CLAUDE.md`에 있고 이 파일들은 코드를 가리킵니다.

| 층 | 파일 | 상태 |
|---|---|---|
| Infrastructure | — | not generated (컨테이너와 클러스터 파일이 없음. 네트워크와 인스턴스는 IaC에 있음) |
| Data | — | not applicable |
| API | — | not generated (암호 게이트의 HTTP 경로는 `docs/api-reference.md`에 있음) |
| IaC | [iac.md](iac.md) | present |
| Frontend | — | not applicable (웹 클라이언트는 upstream Orca의 것) |
| UI | — | not applicable |
| Security | [security.md](security.md) | present |
| Agent · LLM | — | not applicable |

마지막 갱신: 2026-11-22 (/init-project, /add-reference-doc, /sync-docs가 관리)
