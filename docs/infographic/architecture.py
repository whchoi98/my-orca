"""상세 아키텍처 인포그래픽 (05). 근거는 sources.md.

  landscape(theme)  16:9 한 장. 영어판은 architecture_en.py가 같은 좌표에 T_EN의 글로 그린다

구조도는 ow-on-gpu 저장소의 요청 경로 그림(docs/infographic/flow.py)과 같은 방식으로 그린다. 구성 요소를 열과 행의
격자에 한 번만 정의하고(GRID), Geo가 격자 좌표를 그릴 좌표로 바꾸며, layout()이 선과 단계 번호의 좌표를 정하고,
arch_map()이 그린다. 그쪽 코드를 불러오지는 않는다.

  0~3열   0행은 접속 암호와 헤더 값, 1행은 접속 경로, 2행은 배포와 페어링 링크 조회
  4열     EC2 인스턴스(틀). 설정 서비스, orca-serve, 터미널과 에이전트를 감싼다
  5~6열   서버가 쓰는 것(볼륨, 역할)과 서버가 밖으로 나가는 경로(NAT Gateway를 거치는 세 곳)
  3열과 틀 사이는 넓게 띄운다. 선이 갈라지는 자리와 선에 붙는 글이 거기에 있다

그림은 전용 서버(OrcaServerStack)를 새 VPC에 배포한 구성이다. 기존 서버에 추가하는 방식과 다른 점은 2번 섹션에 적는다.
"""
import orcakit as kit
from infokit import F, cell, dot_list, poly_d, rw, section, tag

NODE_W, NODE_H = 170, 84
K = 1.15                                   # 노드와 글자의 배율
COLS = [98, 336, 575, 813, 1177, 1435, 1678]
ROWS = [0, 1, 2]
MAP_W = 1776

# 인스턴스 틀과 그 위 막대의 치수(K를 곱해 쓴다)
ZONE_PAD_X, ZONE_PAD_TOP, ZONE_PAD_BOTTOM = 16, 26, 12
BAR_H, BAR_GAP = 40, 20
LANE_GAP = 16    # 틀 아래로 세션 선이 지나가는 거리
TOP_LANE = 15    # 0행 위로 암호 저장 선이 지나가는 거리
PORT = 26        # 한 변에 선 둘이 닿을 때 가운데에서 벌리는 거리
BRANCH = 14      # 한 변에서 선 둘이 나갈 때 가운데에서 벌리는 거리

CF = "service/Amazon-CloudFront"
ELB = "service/Elastic-Load-Balancing"

# id: (열, 행, 아이콘). 이름, 설명, 값은 T와 T_EN의 nodes에 같은 순서로 적는다
GRID = {
    "user": (0, 1, "resource/Client"),
    "ops": (0, 2, "resource/User"),
    "gate": (1, 0, "resource/SSL-padlock"),
    "cf": (1, 1, CF),
    "stack": (1, 2, "service/AWS-CloudFormation"),
    "kvs": (2, 0, "resource/Database"),
    "alb": (2, 1, ELB),
    "pairing": (2, 2, "service/AWS-Lambda"),
    "secret": (3, 0, "service/AWS-Secrets-Manager"),
    "rules": (3, 1, ELB),
    "ssm": (3, 2, "service/AWS-Systems-Manager"),
    "setup": (4, 0, "resource/Gear"),
    "serve": (4, 1, "service/Amazon-EC2"),
    "agents": (4, 2, "resource/Source-Code"),
    "ebs": (5, 0, "service/Amazon-Elastic-Block-Store"),
    "nat": (5, 1, "service/Amazon-Virtual-Private-Cloud"),
    "role": (5, 2, "service/AWS-Identity-and-Access-Management"),
    "github": (6, 0, "resource/Git-Repository"),
    "s3": (6, 1, "service/Amazon-Simple-Storage-Service"),
    "bedrock": (6, 2, "service/Amazon-Bedrock"),
}

T = dict(
    title="상세 아키텍처",
    sub_en="Orca on EC2 Architecture in Detail",
    sub_ko="접속 경로, 접속 암호와 헤더 값, 배포와 페어링 링크, 서버가 밖으로 나가는 경로",
    s1=("구조와 배포부터 접속까지의 흐름", "실선은 요청과 데이터, 점선은 읽기, 참조, 권한, 번호는 아래 흐름의 단계"),
    s2=("배포 방식별 구성", "CloudFront, 암호 게이트, 헤더 값은 두 방식 공통"),
    s3=("값과 설정", "코드에 정한 값"),
    s4=("경계별 접근 제한", "바깥에서 안쪽으로 여섯 겹"),
    zone="EC2 인스턴스, 프라이빗 서브넷",
    boot=("orca-bootstrap.service", "UserData 설치, 부팅마다 재실행"),
    # 구역 이름, 첫 노드, 마지막 노드
    captions=[("접속 경로와 배포 경로", "user", "secret"), ("서버가 쓰는 것과 밖으로 나가는 경로", "ebs", "github")],
    # id, 이름, 설명, 값
    nodes=[
        ("user", "브라우저", "게이트 쿠키, 디바이스 키", "쿠키 유효 7일"),
        ("ops", "운영자", "배포 스크립트, AWS CLI", "CDK 또는 Terraform"),
        ("gate", "암호 게이트", "Function, viewer request", "쿠키 없음 401"),
        ("cf", "CloudFront", "HTTPS, WSS 종료", "/assets/*만 캐시"),
        ("stack", "CloudFormation", "OrcaServerStack", "Terraform은 apply로 대체"),
        ("kvs", "KeyValueStore", "salt, 해시, 서명 키", "Function은 읽기만"),
        ("alb", "ALB", "퍼블릭 서브넷, HTTP:80", "prefix list의 TCP 80만"),
        ("pairing", "페어링 출력", "Lambda 커스텀 리소스", "30초마다, 최대 40분"),
        ("secret", "Secrets Manager", "X-Custom-Secret 값", "48자 랜덤"),
        ("rules", "리스너 규칙", "X-Custom-Secret 일치", "우선순위 5, 10"),
        ("ssm", "Systems Manager", "Run Command, 세션", "엔드포인트 3개"),
        ("setup", "orca-gate-setup", "최초 암호 설정", "포트 6769"),
        ("serve", "orca-serve", "웹 UI, RPC(WebSocket)", "포트 6768"),
        ("agents", "터미널, 에이전트", "Claude Code, Codex, Kiro", "인스턴스 역할로 실행"),
        ("ebs", "EBS 볼륨", "100GB gp3, 암호화", "저장소, 세션 데이터"),
        ("nat", "NAT Gateway", "아웃바운드 전용", "퍼블릭 서브넷에 1개"),
        ("role", "인스턴스 역할", "SSM, CloudWatch, Bedrock", "KeyValueStore 쓰기"),
        ("github", "GitHub Releases", "orca-ide RPM", "기본 버전 1.4.269"),
        ("s3", "S3 버킷", "설정 서비스 묶음", "설치할 때 내려받음"),
        ("bedrock", "Amazon Bedrock", "에이전트의 모델 호출", "역할에 호출 권한"),
    ],
    # 선에 붙이는 글
    edge=dict(read="읽기", write="첫 로그인의 암호 저장", header="헤더 값", setup="/__gate/setup",
              serve="HTTP, WebSocket", run="Run Command", session="get_pairing_url.sh, Session Manager"),
    # 번호, 이름, 값, 색
    steps=[
        ("1", "배포 실행", "CDK 또는 Terraform", "blue"),
        ("2", "서버 설치", "orca-ide RPM, systemd 유닛", "blue"),
        ("3", "페어링 링크 조회", "스택 출력, get_pairing_url.sh", "blue"),
        ("4", "접속 암호 확인", "첫 화면에서 설정, 쿠키 7일", "orange"),
        ("5", "헤더 확인과 전달", "불일치 403, 포트 6768", "orange"),
        ("6", "페어링과 사용", "링크를 연 브라우저만 등록", "purple"),
    ],
    mode_head=("전용 서버 (위 그림)", "기존 서버에 추가"),
    # 표에서 두 방식의 글이 시작하는 x(이름표 폭에 맞춘다)
    mode_x=(134, 366),
    # 항목, 전용 서버, 기존 서버에 추가, 색
    modes=[
        ("스택", "OrcaServerStack", "OrcaOnVscodeStack", "blue"),
        ("VPC, ALB, EC2", "새로 생성, VPC는 기존 것도 가능", "호스트의 것을 함께 사용", "green"),
        ("리스너 규칙", "새 리스너, 기본 동작 403", "호스트 리스너에 2개 추가", "orange"),
        ("서버 설치", "UserData, orca-bootstrap", "SSM Run Command", "purple"),
        ("삭제", "스택의 리소스 모두 삭제", "Orca만 제거, 호스트는 유지", "pink"),
    ],
    # 값이 끝나는 x와 설명이 시작하는 x
    value_x=(262, 280),
    # 이름, 값, 설명
    values=[
        ("Orca 포트", "6768", "웹 UI와 RPC(WebSocket)"),
        ("설정 서비스 포트", "6769", "암호를 정하기 전의 /__gate/setup"),
        ("리스너 규칙 우선순위", "5, 10", "설정 경로, Orca"),
        ("게이트 쿠키", "7일", "만료 시각을 HMAC-SHA256 서명"),
        ("X-Custom-Secret", "48자", "Secrets Manager가 생성"),
        ("ALB 유휴 제한 시간", "3,600초", "WebSocket 세션 유지"),
        ("대상 그룹 상태 확인", "30초", "/web-index.html, 200"),
        ("페어링 링크 대기", "최대 40분", "넘으면 unavailable 보고"),
    ],
    limits=[
        "CloudFront Function: 쿠키 없는 요청은 401, 암호 설정 전의 WebSocket은 503",
        "ALB 보안 그룹: CloudFront origin-facing prefix list의 TCP 80만 허용",
        "리스너 규칙: X-Custom-Secret 불일치는 403 Access Denied",
        "EC2 보안 그룹: ALB 보안 그룹의 6768, 6769만 허용, 공인 IP 없음",
        "설정 서비스: 1회용 설정 코드 확인, 오입력 20회에서 잠금",
        "Orca 페어링: 링크를 연 브라우저만 등록, RPC는 종단 간 암호화",
    ],
    note=("전용 서버(OrcaServerStack)를 새 VPC에 배포한 구성, 2026-11-26 기준, Orca 1.4.269, 근거는 infra-cdk/lib의 코드. "
          "Terraform 배포에는 CloudFormation과 페어링 출력(Lambda)이 없음"),
)

T_EN = dict(
    title="Architecture in Detail",
    sub_en="Orca on EC2",
    sub_ko="Access path, access password and header value, deployment and pairing link, outbound paths",
    s1=("Architecture and the flow from deployment to access",
        "Solid: requests and data, dashed: reads, references, permissions, badges: steps in the strip below"),
    s2=("Layout by deployment mode", "Same CloudFront and gate in both"),
    s3=("Values and settings", "Set in the code"),
    s4=("Access limits by boundary", "Six layers from the outside in"),
    zone="EC2 instance, private subnet",
    boot=("orca-bootstrap.service", "UserData setup, re-run on boot"),
    captions=[("Access and deployment paths", "user", "secret"),
              ("What the server uses and where it calls out", "ebs", "github")],
    nodes=[
        ("user", "Browser", "Gate cookie, device key", "Cookie valid 7 days"),
        ("ops", "Operator", "Deploy scripts, AWS CLI", "CDK or Terraform"),
        ("gate", "Password gate", "Function, viewer request", "No cookie: 401"),
        ("cf", "CloudFront", "Ends HTTPS and WSS", "Caches /assets/* only"),
        ("stack", "CloudFormation", "OrcaServerStack", "Terraform: apply instead"),
        ("kvs", "KeyValueStore", "Salt, hash, signing key", "Function can only read"),
        ("alb", "ALB", "Public subnets, HTTP:80", "TCP 80, prefix list only"),
        ("pairing", "Pairing output", "Lambda custom resource", "Every 30 s, up to 40 min"),
        ("secret", "Secrets Manager", "X-Custom-Secret value", "48 random characters"),
        ("rules", "Listener rules", "X-Custom-Secret matches", "Priorities 5 and 10"),
        ("ssm", "Systems Manager", "Run Command, sessions", "3 VPC endpoints"),
        ("setup", "orca-gate-setup", "First password setup", "Port 6769"),
        ("serve", "orca-serve", "Web UI, RPC (WebSocket)", "Port 6768"),
        ("agents", "Terminals, agents", "Claude Code, Codex, Kiro", "Use the instance role"),
        ("ebs", "EBS volume", "100 GB gp3, encrypted", "Repositories, sessions"),
        ("nat", "NAT Gateway", "Outbound only", "One, in a public subnet"),
        ("role", "Instance role", "SSM, CloudWatch, Bedrock", "KeyValueStore writes"),
        ("github", "GitHub Releases", "orca-ide RPM", "Default version 1.4.269"),
        ("s3", "S3 bucket", "Setup service bundle", "Downloaded at install"),
        ("bedrock", "Amazon Bedrock", "Model calls by agents", "Allowed by the role"),
    ],
    edge=dict(read="read", write="Stores the first password", header="header value", setup="/__gate/setup",
              serve="HTTP, WebSocket", run="Run Command", session="get_pairing_url.sh, Session Manager"),
    steps=[
        ("1", "Deploy", "CDK or Terraform", "blue"),
        ("2", "Server setup", "orca-ide RPM, systemd units", "blue"),
        ("3", "Get the pairing link", "Stack output, get_pairing_url.sh", "blue"),
        ("4", "Access password", "Set on the first page, 7 days", "orange"),
        ("5", "Header check, forward", "Mismatch 403, port 6768", "orange"),
        ("6", "Pair and use", "Only the browser with the link", "purple"),
    ],
    mode_head=("Dedicated server (map above)", "Added to an existing server"),
    mode_x=(134, 366),
    modes=[
        ("Stack", "OrcaServerStack", "OrcaOnVscodeStack", "blue"),
        ("VPC, ALB, EC2", "Created, or an existing VPC", "Shared with the host", "green"),
        ("Listener rules", "New listener, default 403", "Two added to the host listener", "orange"),
        ("Server setup", "UserData, orca-bootstrap", "SSM Run Command", "purple"),
        ("Deletion", "Every resource of the stack", "Orca only, the host stays", "pink"),
    ],
    value_x=(262, 280),
    values=[
        ("Orca port", "6768", "Web UI and RPC (WebSocket)"),
        ("Setup service port", "6769", "/__gate/setup until a password is set"),
        ("Listener rule priorities", "5, 10", "Setup path, Orca"),
        ("Gate cookie", "7 days", "Expiry signed with HMAC-SHA256"),
        ("X-Custom-Secret", "48 chars", "Generated by Secrets Manager"),
        ("ALB idle timeout", "3,600 s", "Keeps WebSocket sessions open"),
        ("Target group health check", "30 s", "/web-index.html, 200"),
        ("Pairing link wait", "up to 40 min", "Then reports unavailable"),
    ],
    limits=[
        "CloudFront Function: 401 without a cookie, WebSocket 503 before setup",
        "ALB security group: TCP 80 from the CloudFront origin-facing prefix list only",
        "Listener rules: 403 Access Denied when X-Custom-Secret does not match",
        "EC2 security group: 6768, 6769 from the ALB security group only, no public IP",
        "Setup service: checks the one-time setup code, locks after 20 wrong codes",
        "Orca pairing: registers only a browser with the link, end-to-end encrypted RPC",
    ],
    note=("Dedicated server (OrcaServerStack) in a new VPC, as of 2026-11-26, Orca 1.4.269, based on the code in infra-cdk/lib. "
          "A Terraform deployment has no CloudFormation and no pairing output (Lambda)"),
)


class Geo:
    """격자 좌표를 그릴 좌표로 바꾼다. (ox, oy)는 왼쪽 위, sx와 sy는 위치의 배율, k는 노드와 글자의 배율."""

    def __init__(self, ox, oy, sx, sy, k):
        self.ox, self.oy, self.sx, self.sy, self.k = ox, oy, sx, sy, k
        self.nw, self.nh = NODE_W * k, NODE_H * k

    def center(self, name):
        col, row = GRID[name][:2]
        return self.ox + COLS[col] * self.sx, self.oy + ROWS[row] * self.sy

    def rect(self, name):
        k = self.k
        if name == "ec2":  # 설정 서비스, orca-serve, 터미널과 에이전트를 감싸는 틀
            x, top = self.rect("setup")[:2]
            bottom = self.rect("agents")[1] + self.nh
            return (x - ZONE_PAD_X * k, top - ZONE_PAD_TOP * k, self.nw + 2 * ZONE_PAD_X * k,
                    bottom - top + (ZONE_PAD_TOP + ZONE_PAD_BOTTOM) * k)
        if name == "boot":  # 틀 위의 막대
            x, y, w, _ = self.rect("ec2")
            return (x, y - (BAR_GAP + BAR_H) * k, w, BAR_H * k)
        cx, cy = self.center(name)
        return (cx - self.nw / 2, cy - self.nh / 2, self.nw, self.nh)

    def side(self, name, where, shift=0.0):
        """테두리의 한 점. where는 left, right, top, bottom. shift는 변을 따라 옮기는 거리."""
        x, y, w, h = self.rect(name)
        s = shift * self.k
        return {"left": (x, y + h / 2 + s), "right": (x + w, y + h / 2 + s),
                "top": (x + w / 2 + s, y), "bottom": (x + w / 2 + s, y + h)}[where]

    @property
    def lane(self):
        """틀 아래로 세션 선이 지나가는 높이."""
        _, y, _, h = self.rect("ec2")
        return y + h + LANE_GAP * self.k

    @property
    def top_lane(self):
        """0행 위로 암호 저장 선이 지나가는 높이."""
        return self.rect("kvs")[1] - TOP_LANE * self.k

    @property
    def band(self):
        """0행과 1행 사이로 헤더 값 선이 지나가는 높이."""
        return (self.rect("secret")[1] + self.nh + self.rect("rules")[1]) / 2


def fit(ox, top, sx, height, k):
    """주어진 높이에 구조도가 꼭 맞도록 세로 배율과 원점을 정한다."""
    fixed = (NODE_H + ZONE_PAD_TOP + BAR_GAP + BAR_H + ZONE_PAD_BOTTOM + LANE_GAP) * k + 6
    g = Geo(ox, 0, sx, (height - fixed) / (ROWS[-1] - ROWS[0]), k)
    g.oy = top - g.rect("boot")[1] + 2
    return g


def via_x(start, end, x):
    return [start, (x, start[1]), (x, end[1]), end]


def via_y(start, end, y):
    return [start, (start[0], y), (end[0], y), end]


def layout(g, t):
    """선과 배지의 좌표.

    선은 id: (경로, 점선 여부, 글의 목록, 양쪽 화살촉 여부)이고 글은 (글, x, y, 정렬)이다.
    배지는 (단계 번호, x, y)의 목록이다.
    """
    s, k, lab = g.side, g.k, t["edge"]
    zx, zy, zw, zh = g.rect("ec2")
    zone_left, zone_right = zx, zx + zw
    y0, y1, y2 = (g.center(name)[1] for name in ("setup", "serve", "agents"))
    fork_in = zone_left - 36 * k                               # 리스너 규칙과 틀 사이에서 선이 갈라지는 자리
    turn = fork_in - 52 * k                                    # 암호 저장 선이 위로 꺾이는 자리
    fork_out = (s("nat", "right")[0] + s("s3", "left")[0]) / 2  # NAT Gateway와 오른쪽 열 사이
    gap = (s("gate", "right")[0] + s("kvs", "left")[0]) / 2
    rules_right = s("rules", "right")[0]
    edges = {
        # 접속 경로
        "user-cf": ([s("user", "right"), s("cf", "left")], False, [], False),
        "cf-alb": ([s("cf", "right"), s("alb", "left")], False, [], False),
        "alb-rules": ([s("alb", "right"), s("rules", "left")], False, [], False),
        "rules-serve": ([s("rules", "right", BRANCH), s("serve", "left", BRANCH)], False,
                        [(lab["serve"], rules_right + 12 * k, s("rules", "right", BRANCH)[1] + 18 * k, "start")], False),
        "rules-setup": (via_x(s("rules", "right", -BRANCH), s("setup", "left", BRANCH), fork_in), False,
                        [(lab["setup"], rules_right + 10 * k, s("rules", "right", -BRANCH)[1] - 11 * k, "start")], False),
        "serve-agents": ([s("serve", "bottom"), s("agents", "top")], False, [], False),
        # 접속 암호: 함수는 저장소를 읽기만 하고, 첫 암호는 서버의 설정 서비스가 저장한다
        "cf-gate": ([s("cf", "top", -PORT), s("gate", "bottom", -PORT)], False, [], True),
        "gate-kvs": ([s("gate", "right"), s("kvs", "left")], True,
                     [(lab["read"], gap, s("gate", "right")[1] - 8 * k, "middle")], False),
        "setup-kvs": ([s("setup", "left", -BRANCH), (turn, s("setup", "left", -BRANCH)[1]), (turn, g.top_lane),
                       (s("kvs", "top")[0], g.top_lane), s("kvs", "top")], False,
                      [(lab["write"], s("kvs", "top")[0] + 14 * k, g.top_lane - 7 * k, "start")], False),
        # 헤더 값: CloudFront가 오리진 요청에 붙이고 리스너 규칙이 같은 값을 확인한다
        "secret-cf": (via_y(s("secret", "bottom", -PORT), s("cf", "top", PORT), g.band), True, [], False),
        "secret-rules": ([s("secret", "bottom", PORT), s("rules", "top", PORT)], True,
                         [(lab["header"], s("secret", "bottom", PORT)[0] + 9 * k, g.band + 4 * k, "start")], False),
        # 배포와 페어링 링크 조회
        "ops-stack": ([s("ops", "right"), s("stack", "left")], False, [], False),
        "stack-pairing": ([s("stack", "right"), s("pairing", "left")], False, [], False),
        "pairing-ssm": ([s("pairing", "right"), s("ssm", "left")], False, [], False),
        "ssm-ec2": ([s("ssm", "right"), (zone_left, y2)], False,
                    [(lab["run"], (rules_right + zone_left) / 2, y2 - 8 * k, "middle")], False),
        "ops-ssm": (via_y(s("ops", "bottom"), s("ssm", "bottom"), g.lane), True,
                    [(lab["session"], s("ops", "bottom")[0] + 12 * k, g.lane - 7 * k, "start")], False),
        # 서버가 쓰는 것과 밖으로 나가는 경로
        "ec2-ebs": ([(zone_right, y0), s("ebs", "left")], False, [], False),
        "ec2-nat": ([(zone_right, y1), s("nat", "left")], False, [], False),
        "role-ec2": ([s("role", "left"), (zone_right, y2)], True, [], False),
        "nat-github": (via_x(s("nat", "right", -BRANCH), s("github", "left"), fork_out), False, [], False),
        "nat-s3": ([s("nat", "right"), s("s3", "left")], False, [], False),
        "nat-bedrock": (via_x(s("nat", "right", BRANCH), s("bedrock", "left"), fork_out), False, [], False),
        "boot-ec2": ([s("boot", "bottom"), s("ec2", "top")], False, [], False),
    }
    bar = g.rect("boot")

    def corner(name):
        x, y = g.rect(name)[:2]
        return x - 3, y - 3

    badges = [
        ("1", *corner("stack")),
        ("2", bar[0] + 18 * k, bar[1] + bar[3] / 2),
        ("3", *corner("ssm")),
        ("4", *corner("gate")),
        ("5", fork_in, s("rules", "right")[1]),
        ("6", *corner("serve")),
    ]
    return edges, badges


def arrow_head(points, size):
    """마지막 선분 방향의 화살촉 세 점."""
    (x0, y0), (x1, y1) = points[-2], points[-1]
    length = ((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5 or 1.0
    ux, uy = (x1 - x0) / length, (y1 - y0) / length
    bx, by = x1 - ux * size, y1 - uy * size
    return [(x1, y1), (bx - uy * size * 0.5, by + ux * size * 0.5), (bx + uy * size * 0.5, by - ux * size * 0.5)]


def text_on(color):
    """진한 채움 위의 글자 색."""
    return "badgetext" if color in ("blue", "purple") else "onwarm"


def step_badge(d, cx, cy, num, r, size, colors):
    color = colors[num]
    d.circle(cx, cy, r, fill=color + "F", stroke="card", sw=2)
    d.text(cx, cy + size * 0.36, num, size, 700, text_on(color), "middle")


def arch_map(d, g, t, box):
    """구조도를 그린다. 틀과 구역 이름, 선, 노드, 막대, 단계 번호의 순서다."""
    k = g.k
    edges, marks = layout(g, t)
    colors = {step[0]: step[3] for step in t["steps"]}

    # 위쪽 띠의 구역 이름. 왼쪽 네 열이 접속과 배포, 오른쪽 두 열이 서버가 쓰는 것과 나가는 경로다.
    bar = g.rect("boot")
    for text, first, last in t["captions"]:
        x0, x1 = g.rect(first)[0], g.rect(last)[0] + g.rect(last)[2]
        mid = bar[1] + bar[3] / 2
        d.text(x0, mid + 4 * k, text, F(12, k), 700, "faint", box=box)
        d.line(x0 + rw(text, F(12, k), 700) + 12 * k, mid, x1, mid, stroke="line2", sw=1)

    zx, zy, zw, zh = g.rect("ec2")
    d.rect(zx, zy, zw, zh, rx=12 * k, fill="greenF", fo=0.06, stroke="green", sw=1.3)
    d.text(zx + 12 * k, zy + 17 * k, t["zone"], F(11.5, k), 700, "green", box=box)

    for points, dashed, labels, both in edges.values():
        heads = [arrow_head(points, 9 * k)] + ([arrow_head(points[::-1], 9 * k)] if both else [])
        line = list(points)
        for index, head in zip((-1, 0), heads):  # 선은 화살촉의 밑변에서 끝낸다
            line[index] = ((head[1][0] + head[2][0]) / 2, (head[1][1] + head[2][1]) / 2)
        d.path(poly_d(line, 8 * k), stroke="arrow", sw=1.6 * k, dash=f"{5 * k:.0f} {5 * k:.0f}" if dashed else None)
        for head in heads:
            d.add('<path d="M' + " L".join(f"{x:.1f},{y:.1f}" for x, y in head) + f' z" fill="{d.c("arrow")}"/>')
        for text, x, y, anchor in labels:
            d.text(x, y, text, F(11.5, k), 400, "muted", anchor, box=box)

    for name, title, sub, value in t["nodes"]:
        icon = GRID[name][2]
        x, y, nw, nh = nbox = g.rect(name)
        d.rect(x, y, nw, nh, rx=10 * k, fill="panel", stroke="line2", sw=1.3)
        d.icon(icon, x + 10 * k, y + 9 * k, 26 * k)
        size = F(13, k)
        while rw(title, size, 700) > nw - 51 * k and size > 11:  # 긴 이름은 글자를 줄여 칸에 맞춘다
            size -= 0.5
        d.text(x + 43 * k, y + 27 * k, title, size, 700, "text", box=nbox)
        d.text(x + 10 * k, y + 53 * k, sub, F(11, k), 400, "muted", box=nbox)
        d.text(x + 10 * k, y + 72 * k, value, F(11.5, k), 700, "orange", box=nbox)

    bx, by, bw, bh = bbox = g.rect("boot")
    d.rect(bx, by, bw, bh, rx=10 * k, fill="panel", stroke="line2", sw=1.3)
    d.text(bx + 34 * k, by + 17 * k, t["boot"][0], F(12, k), 700, "text", box=bbox)
    d.text(bx + 34 * k, by + 32 * k, t["boot"][1], F(10, k), 400, "muted", box=bbox)

    for num, cx, cy in marks:
        step_badge(d, cx, cy, num, 10 * k, F(12, k), colors)


def strip(d, x, y, w, h, t, box):
    """1번에서 6번까지의 흐름 띠."""
    steps = t["steps"]
    gap = 30
    cw = (w - gap * (len(steps) - 1)) / len(steps)
    for index, (num, title, value, color) in enumerate(steps):
        cx = x + index * (cw + gap)
        d.rect(cx, y, cw, h, rx=10, fill=color + "F", fo=0.1, stroke=color, sw=1.3)
        d.circle(cx + 26, y + h / 2, 13, fill=color + "F")
        d.text(cx + 26, y + h / 2 + 5.4, num, 15, 700, text_on(color), "middle")
        d.text(cx + 50, y + 24, title, 15, 700, "text", box=box)
        d.text(cx + 50, y + 44, value, 13, 400, "text2", box=box)
        if index + 1 < len(steps):
            d.arrow([(cx + cw + 5, y + h / 2), (cx + cw + gap - 5, y + h / 2)], sw=1.6, r=0)


def s1(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 1, *t["s1"])
    box = (x, y, w, h)
    strip_h = 56
    strip_y = y + h - 18 - strip_h
    top = cy - 8
    g = fit(x + 24, top, (w - 48) / MAP_W, strip_y - 12 - top, K)
    arch_map(d, g, t, box)
    strip(d, x + 24, strip_y, w - 48, strip_h, t, box)


def s2(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 2, *t["s2"])
    box = (x, y, w, h)
    ix, iw = x + 24, w - 48
    ax, bx = t["mode_x"]
    d.text(ix + ax, cy + 4, t["mode_head"][0], 13, 700, "muted", box=box)
    d.text(ix + bx, cy + 4, t["mode_head"][1], 13, 700, "muted", box=box)
    top = cy + 14
    rh = (y + h - 12 - top) / len(t["modes"])
    for index, (name, own, shared, color) in enumerate(t["modes"]):
        mid = top + index * rh + rh / 2
        d.line(ix, mid - rh / 2, ix + iw, mid - rh / 2, stroke="cardline", sw=1)
        tag(d, ix, mid - 12, name, color, 13, 24, 10, box=box)
        cell(d, ix + ax, mid, bx - ax - 12, own, 14, 18, 400, "text2", box)
        cell(d, ix + bx, mid, iw - bx, shared, 14, 18, 400, "text2", box)


def s3(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 3, *t["s3"])
    box = (x, y, w, h)
    ix, iw = x + 24, w - 48
    value_end, note_x = t["value_x"]
    rh = (y + h - cy - 12) / len(t["values"])
    for index, (name, value, note) in enumerate(t["values"]):
        mid = cy + index * rh + rh / 2
        d.text(ix, mid + 5, name, 14, 400, "text2", box=box)
        d.text(ix + value_end, mid + 5, value, 15, 700, "orange", "end", box=box)
        d.text(ix + note_x, mid + 5, note, 13, 400, "muted", box=box)
        if index:
            d.line(ix, mid - rh / 2, ix + iw, mid - rh / 2, stroke="cardline", sw=1)


def s4(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 4, *t["s4"])
    box = (x, y, w, h)
    dot_list(d, x + 24, cy + 12, w - 48, t["limits"], 14, 20, 7, dot="green", box=box)


def landscape(theme):
    t = kit.texts(T, T_EN)
    d = kit.page(theme, t)
    s1(d, 48, 140, 1824, 628, t)
    s2(d, 48, 788, 620, 256, t)
    s3(d, 688, 788, 560, 256, t)
    s4(d, 1268, 788, 604, 256, t)
    return kit.finish(d, t)
