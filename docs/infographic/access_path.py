"""접속 경로와 보호 계층 인포그래픽 (01). 근거는 sources.md.

  landscape(theme)  16:9 한 장. buildkit이 SVG와 PNG로 만든다
  영어판은 access_path_en.py가 같은 좌표에 T_EN의 글로 그린다
"""
import orcakit as kit
from infokit import callout, section, tag

T = dict(
    title="접속 경로와 보호 계층",
    sub_en="Access Path and Protection Layers",
    sub_ko="브라우저에서 Private EC2의 orca-serve까지",
    s1=("요청 경로", "경계마다 확인하는 것이 다르고, 통과하지 못한 요청은 그 자리에서 거절"),
    hops=["HTTPS, WSS", "HTTP:80 + X-Custom-Secret", "HTTP, WebSocket :6768"],
    nodes=[
        ("브라우저", "사용자", [("보관하는 것", "게이트 쿠키, 페어링한 디바이스 키")]),
        ("Amazon CloudFront", "HTTPS와 WSS 종료, /assets/*만 캐시",
         [("Function (viewer request)", "모든 요청의 쿠키 확인, 로그인 화면과 최초 설정 화면 제공"),
          ("KeyValueStore", "salt, 암호 해시, 쿠키 서명 키 보관, Function은 읽기만 가능")]),
        ("Application Load Balancer", "퍼블릭 서브넷, HTTP:80",
         [("보안 그룹", "CloudFront origin-facing prefix list의 TCP 80만 허용"),
          ("리스너 규칙", "X-Custom-Secret 헤더가 일치할 때만 전달, 기본 동작은 403")]),
        ("Amazon EC2", "프라이빗 서브넷, 공인 IP 없음",
         [("orca-serve :6768", "웹 UI와 런타임 RPC(WebSocket)를 한 포트에서 처리"),
          ("orca-gate-setup :6769", "최초 로그인 암호 설정, /__gate/setup 경로만 전달")]),
    ],
    reject_label="거절되는 요청",
    rejects=[
        ["쿠키 없음: 401", "암호 설정 전의 WebSocket: 503"],
        ["prefix list 밖의 주소: 연결 불가", "헤더 불일치: 403 Access Denied"],
        ["ALB 보안 그룹 밖: 연결 불가"],
    ],
    s2=("접속 두 단계", "접속 암호를 지난 요청만 Orca 페어링에 도달"),
    gate=("1단계 접속 암호 게이트", "CloudFront Function", [
        "HTML, /assets/*, WebSocket 업그레이드까지 모든 요청에서 쿠키 확인",
        "암호가 맞으면 orca_gate 쿠키 발급, 만료 시각을 HMAC-SHA256으로 서명, 7일",
        "쿠키 속성은 HttpOnly, Secure, SameSite=Lax, 오리진에는 쿠키를 전달하지 않음",
    ]),
    pair=("2단계 Orca 페어링", "orca-serve", [
        "페어링 링크를 연 브라우저만 서버에 등록, 디바이스 키는 브라우저에 저장",
        "RPC는 종단 간 암호화, CloudFront와 ALB에는 암호문만 통과",
        "링크는 1회용 (Orca 1.4.254부터), 서버를 시작할 때마다 새 링크 출력",
    ]),
    s3=("비밀 값의 보관 위치", "평문으로 남는 값은 페어링 링크와 설정 코드"),
    head=["값", "보관 위치", "알아 둘 점"],
    rows=[
        ("X-Custom-Secret", "Secrets Manager (48자 랜덤)", "CloudFront와 ALB 규칙이 같은 값을 동적 참조, 스택 출력에는 ARN만 표시"),
        ("접속 암호", "KeyValueStore의 salt와 sha256 해시", "평문은 저장하지 않음, 8자 이상"),
        ("쿠키 서명 키", "KeyValueStore", "암호를 바꾸면 새 키로 교체되어 기존 로그인 세션 만료 (기본값)"),
        ("1회용 설정 코드", "서버의 root 전용 파일, 스택 출력", "암호를 정하면 삭제, 오입력 20회에서 잠금"),
        ("페어링 링크", "journald, 스택 출력, cdk-outputs.json", "평문으로 남음, --no-pairing-output으로 출력에서 제외"),
    ],
    insight=("인스턴스 역할 권한이 곧 Orca 접속 권한", "터미널과 에이전트가 인스턴스 역할로 실행, 링크와 암호는 관리자 자격 증명처럼 관리"),
    note="2026-11-22 기준, Orca 1.4.269, 근거는 infra-cdk/lib의 코드와 Orca 1.4.254 릴리스 노트",
)

T_EN = dict(
    title="Access Path and Protection Layers",
    sub_en="Orca on EC2",
    sub_ko="From the browser to orca-serve on a private EC2 instance",
    s1=("Request path", "Each boundary checks something different and refuses what does not pass"),
    hops=["HTTPS, WSS", "HTTP:80 + X-Custom-Secret", "HTTP, WebSocket :6768"],
    nodes=[
        ("Browser", "User", [("Keeps", "The gate cookie and the paired device key")]),
        ("Amazon CloudFront", "Ends HTTPS and WSS, caches /assets/* only",
         [("Function (viewer request)", "Checks the cookie on every request, serves the login and first-setup pages"),
          ("KeyValueStore", "Salt, password hash and cookie signing key, read-only for the function")]),
        ("Application Load Balancer", "Public subnets, HTTP:80",
         [("Security group", "TCP 80 from the CloudFront origin-facing prefix list only"),
          ("Listener rule", "Forwards only when X-Custom-Secret matches, default action is 403")]),
        ("Amazon EC2", "Private subnet, no public IP",
         [("orca-serve :6768", "Web UI and runtime RPC (WebSocket) on one port"),
          ("orca-gate-setup :6769", "First-login password setup, receives /__gate/setup only")]),
    ],
    reject_label="Refused requests",
    rejects=[
        ["No cookie: 401", "WebSocket before a password is set: 503"],
        ["Outside the prefix list: no connection", "Wrong header: 403"],
        ["Outside the ALB security group: no connection"],
    ],
    s2=("Two steps to get in", "Only requests past the access password reach Orca pairing"),
    gate=("Step 1 Access password gate", "CloudFront Function", [
        "Checks the cookie on every request: HTML, /assets/* and WebSocket upgrades",
        "A correct password issues the orca_gate cookie, expiry signed with HMAC-SHA256, 7 days",
        "Cookie attributes HttpOnly, Secure, SameSite=Lax, never forwarded to the origin",
    ]),
    pair=("Step 2 Orca pairing", "orca-serve", [
        "Only a browser that opened the pairing link is registered, its device key stays in the browser",
        "RPC is end-to-end encrypted, CloudFront and the ALB carry ciphertext only",
        "A link is single-use (from Orca 1.4.254), every server start prints a new one",
    ]),
    s3=("Where the secrets are kept", "Only the pairing link and the setup code remain in plain text"),
    head=["Value", "Kept in", "Good to know"],
    rows=[
        ("X-Custom-Secret", "Secrets Manager (48 random characters)", "CloudFront and the ALB rule use the same dynamic reference, stack outputs show the ARN only"),
        ("Access password", "Salt and sha256 hash in the KeyValueStore", "Plain text is never stored, 8 characters or more"),
        ("Cookie signing key", "KeyValueStore", "A password change replaces it, which ends existing sessions (default)"),
        ("One-time setup code", "Root-only file on the server, stack outputs", "Deleted once a password is set, locked after 20 wrong codes"),
        ("Pairing link", "journald, stack outputs, cdk-outputs.json", "Plain text, leave it out of the outputs with --no-pairing-output"),
    ],
    insight=("The instance role is what an Orca session can use", "Terminals and agents run with the instance role, so handle the link and the password like admin credentials"),
    note="As of 2026-11-22, Orca 1.4.269, based on the code in infra-cdk/lib and the Orca 1.4.254 release notes",
)

ICONS = ["resource/User", "service/Amazon-CloudFront", "service/Elastic-Load-Balancing", "service/Amazon-EC2"]
COLORS = ["purple", "orange", "blue", "green"]


def s1(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 1, *t["s1"])
    ix, iw = x + 24, w - 48
    widths = [240, 0, 0, 0]
    gap = 66
    rest = (iw - widths[0] - gap * 3) / 3
    widths[1:] = [rest] * 3
    top, nh = cy + 34, 236
    xs = []
    cx = ix
    for wd in widths:
        xs.append(cx)
        cx += wd + gap
    for i, (name, sub, items) in enumerate(t["nodes"]):
        kit.node(d, xs[i], top, widths[i], nh, name, sub, items, COLORS[i], ICONS[i])
    for i, label in enumerate(t["hops"]):
        kit.hop(d, xs[i] + widths[i], xs[i + 1], top + nh / 2, label, cy + 18)
    # 거절되는 요청: 각 경계 아래에 이름표로 적는다
    ry = top + nh + 16
    d.text(xs[0] + widths[0], ry + 18, t["reject_label"], 13.5, 700, "pink", "end", box=(x, y, w, h))
    for i, labels in enumerate(t["rejects"]):
        tx = xs[i + 1]
        for label in labels:
            tx += tag(d, tx, ry, label, "pink", 12.5, 26, 11, box=(x, y, w, h)) + 8


def s2(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 2, *t["s2"])
    ix, iw = x + 22, w - 44
    bh = (y + h - 20 - cy - 12) / 2
    kit.block(d, ix, cy + 2, iw, bh, t["gate"][0], t["gate"][1], t["gate"][2], "orange")
    kit.block(d, ix, cy + 2 + bh + 12, iw, bh, t["pair"][0], t["pair"][1], t["pair"][2], "purple")


def s3(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 3, *t["s3"])
    box = (x, y, w, h)
    ix, iw = x + 22, w - 44
    call_y = y + h - 20 - 58
    kit.table(d, ix, cy + 2, iw, call_y - 14 - (cy + 2), t["head"], t["rows"], [0.22, 0.34, 0.44], box)
    callout(d, ix, call_y, iw, *t["insight"], color="pink", box=box)


def landscape(theme):
    t = kit.texts(T, T_EN)
    d = kit.page(theme, t)
    s1(d, 48, 140, 1824, 414, t)
    s2(d, 48, 574, 860, 470, t)
    s3(d, 928, 574, 944, 470, t)
    return kit.finish(d, t)
