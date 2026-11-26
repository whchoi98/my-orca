# 인포그래픽의 근거

그림에 적은 값과 동작을 어디에서 확인했는지 적습니다. 확인하지 못한 것은 그림의 각주와 아래 "확인하지 않은 것"에 적습니다. 확인일은 2026-11-22입니다.

## 코드에서 확인한 것

| 주장 | 값 | 근거 |
|---|---|---|
| Orca 포트와 설정 서비스 포트 | 6768, 6769 | `infra-cdk/lib/orca-front-door.ts`의 `ORCA_PORT`, `GATE_SETUP_PORT` |
| `X-Custom-Secret` 값 | Secrets Manager가 만든 48자, 문장 부호 제외 | `infra-cdk/lib/orca-front-door.ts`의 `passwordLength`, `excludePunctuation` |
| ALB 리스너 규칙의 우선순위 | 설정 경로 5, Orca 10 | `infra-cdk/lib/orca-front-door.ts`, `infra-cdk/lib/orca-attach-stack.ts` |
| ALB의 기본 동작 | 403 `Access Denied` | `infra-cdk/lib/orca-stack.ts`의 `fixedResponse(403)` |
| ALB 보안 그룹 | CloudFront origin-facing prefix list의 TCP 80만, `open: false` | `infra-cdk/lib/orca-stack.ts` |
| 캐시 | `/assets/*`만 | `infra-cdk/lib/orca-front-door.ts` |
| 전용 서버의 VPC와 인스턴스 | 10.253.0.0/16, 기본 r6g.xlarge, EBS 100GB gp3 암호화 | `infra-cdk/lib/orca-stack.ts` |
| 게이트 쿠키 | 이름 `orca_gate`, 7일, `Secure; HttpOnly; SameSite=Lax`, 만료 시각의 HMAC-SHA256 서명 | `infra-cdk/lib/functions/password-gate.js` |
| KeyValueStore의 키 | `auth-salt`, `auth-hash`(sha256), `auth-signkey` | `infra-cdk/lib/functions/password-gate.js` |
| 게이트의 응답 | 설정 전 HTML 401, 그 밖 503, `/__gate/setup`은 POST만(405). 설정 후 `/__gate/setup` 409, 로그인 성공 204, 쿠키 없음 401, 로그아웃 302 | `infra-cdk/lib/functions/password-gate.js`의 `handler` |
| 설정 서비스 | 암호 8자 이상, 코드 오입력 20회에서 423 | `infra-cdk/lib/gate/setup_service.py`의 `MIN_LENGTH`, `MAX_FAILURES` |
| 설정 코드 | 암호가 없을 때만 만들고 root 전용 파일에 보관, 암호를 정하면 삭제 | `infra-cdk/lib/gate/install.sh`, `infra-cdk/lib/gate/setup_service.py` |
| 암호 변경과 세션 | 기본은 서명 키를 새로 만들어 기존 세션 만료, `--keep-sessions`는 유지 | `set_password.sh` |
| 기존 서버에 추가할 때 더하는 것 | 리스너 규칙 2개, 보안 그룹 규칙 2개, 역할 정책 1개 | `infra-cdk/lib/orca-attach-stack.ts`, `docs/deployment.md` |
| 기존 서버 설치 | SSM Run Command, `rpm -Uvh --nodeps --oldpackage`, `orca-serve`만 재시작, 상태 확인 | `infra-cdk/lib/host/install_orca.sh`, `infra-cdk/lib/host/handler.py` |
| 배포 전 점검 | 호스트 ALB의 열린 규칙, 리스너 HTTP:80, 우선순위 5와 10, SSM 온라인 | `deploy_orca.sh` |

## 실행으로 확인한 것 (2026-11-22, 서울 리전의 `--attach` 스택)

| 주장 | 결과 |
|---|---|
| 1.4.253에서 1.4.269로 업그레이드 | 스택 `UPDATE_COMPLETE`, `orca-serve` 한 번 재시작, code-server는 재시작 없음 |
| 업그레이드 뒤 경로 | 대상 그룹 둘 healthy, 사설 IP의 `/web-index.html` 200, CloudFront 쿠키 없는 요청 401, `/__gate/setup` 409, ALB 직접 접속 불가 |
| 새 RPM의 의존성 | 1.4.269가 `/usr/bin/dbus-send`를 추가로 요구(`rpm -qp --requires`) |
| 공인 주소 거부 정책 | 시작 로그에 `Accepting connections from any address`(`--pairing-address`가 호스트 이름이기 때문) |

## 외부 자료

| 주장 | 출처 |
|---|---|
| CloudFront Function은 KeyValueStore를 읽기만 함 | [Amazon CloudFront KeyValueStore](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/kvs-with-functions.html) ("allows read access from within CloudFront Functions") |
| 페어링 링크는 1회용, `orca serve`는 공인 주소를 기본으로 거부 (1.4.254부터) | [Orca v1.4.254 릴리스 노트](https://github.com/stablyai/orca/releases/tag/v1.4.254) |
| 시작할 때마다 새 링크를 출력하고 이전의 미사용 링크를 폐기 | 1.4.269 패키지의 `orca-ide serve --help` |
| 페어링한 브라우저의 디바이스 키 저장과 RPC의 종단 간 암호화 | upstream 소스(2026-11-07의 main): `src/renderer/src/web/web-device-key-store.ts`, `src/shared/remote-runtime/e2ee/` |

## 확인하지 않은 것

- 업그레이드가 실패했을 때의 롤백. CloudFormation이 이전 버전으로 설치를 다시 실행하고 `--oldpackage`가 낮은 버전 설치를 허용한다는 것은 코드와 `rpm`의 동작에서 추론한 것이고, 실제 서버에서 실행된 적이 없습니다.
- 업그레이드 뒤 이미 페어링한 브라우저의 재접속. 접속 암호가 없어 확인하지 못했습니다.
- 페어링 링크의 1회용 동작. 릴리스 노트를 인용했고 직접 시험하지 않았습니다.
