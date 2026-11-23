# Implementation Reference Index / 구현 참조 인덱스

<a href="#english"><img src="https://img.shields.io/badge/lang-English-blue.svg" alt="English"></a>
<a href="#korean"><img src="https://img.shields.io/badge/lang-한국어-red.svg" alt="Korean"></a>

---

<a id="english"></a>

# English

Layer-by-layer implementation guides. Each file has the same five sections: Overview, Components, Key Decisions, Code Pointers, and Cross-references. The working rules of this project live in the root `CLAUDE.md`; these files point at code.

<!-- AUTO-MANAGED:index -->
| Layer | File | Status |
|---|---|---|
| Infrastructure | — | not applicable |
| Data | — | not applicable |
| API | — | not applicable |
| IaC | [iac.md](iac.md) | present |
| Frontend | — | not applicable |
| UI | — | not applicable |
| Security | [security.md](security.md) | present |
| Agent · LLM | — | declined |

Last updated: 2026-11-23 (managed by /init-project, /add-reference-doc, /sync-docs)
<!-- /AUTO-MANAGED -->

Why the other layers have no file:

- Infrastructure: there are no container or cluster files. The network and the instance are in IaC.
- API: the HTTP paths of the password gate are in `docs/api-reference.md`.
- Frontend and UI: the web client belongs to upstream Orca.
- Agent · LLM: the detection signal (a directory named prompts) matches `tools/prompts/`, an empty placeholder directory. This project has no LLM code, so the layer is marked declined.

---

<a id="korean"></a>

# 한국어

층별 구현 안내입니다. 모든 파일은 개요, 구성요소, 주요 결정, 코드 포인터, 상호 참조의 다섯 구역으로 되어 있습니다. 이 프로젝트의 작업 규칙은 루트의 `CLAUDE.md`에 있고 이 파일들은 코드를 가리킵니다.

<!-- AUTO-MANAGED:index -->
| 계층 | 파일 | 상태 |
|---|---|---|
| 인프라 | — | 해당 없음 |
| 데이터 | — | 해당 없음 |
| API | — | 해당 없음 |
| IaC | [iac.md](iac.md) | 있음 |
| 프론트엔드 | — | 해당 없음 |
| UI | — | 해당 없음 |
| 보안 | [security.md](security.md) | 있음 |
| Agent · LLM | — | 제외 |

최종 갱신: 2026-11-23 (/init-project, /add-reference-doc, /sync-docs가 관리)
<!-- /AUTO-MANAGED -->

나머지 층에 파일이 없는 이유:

- 인프라: 컨테이너와 클러스터 파일이 없습니다. 네트워크와 인스턴스는 IaC에 있습니다.
- API: 암호 게이트의 HTTP 경로는 `docs/api-reference.md`에 있습니다.
- 프론트엔드와 UI: 웹 클라이언트는 upstream Orca의 것입니다.
- Agent · LLM: 감지 신호(prompts라는 이름의 디렉터리)가 빈 자리 표시 디렉터리인 `tools/prompts/`에 맞았습니다. 이 프로젝트에는 LLM 코드가 없어 제외로 표시했습니다.
