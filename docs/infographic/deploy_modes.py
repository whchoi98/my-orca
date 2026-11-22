"""두 가지 배포 방식 인포그래픽 (02). 근거는 sources.md.

  landscape(theme)  16:9 한 장. 영어판은 deploy_modes_en.py가 같은 좌표에 T_EN의 글로 그린다
"""
import orcakit as kit
from infokit import CODE_FAMILY, dot_list, section, tag

CF, ALB, EC2 = "service/Amazon-CloudFront", "service/Elastic-Load-Balancing", "service/Amazon-EC2"

T = dict(
    title="두 가지 배포 방식",
    sub_en="Dedicated Server or an Existing Server",
    sub_ko="새로 만드는 것과 호스트 스택에서 함께 쓰는 것",
    s1=("전용 서버", "스택 OrcaServerStack"),
    cmd1="bash deploy_orca.sh",
    vpc="새 VPC 10.253.0.0/16 (기존 VPC도 선택 가능)",
    n1=[("Amazon CloudFront", "접속 암호 게이트"), ("ALB", "퍼블릭 서브넷"), ("Amazon EC2", "프라이빗 서브넷, AL2023")],
    b1=[
        "UserData는 orca-bootstrap 서비스만 만들고 설치는 그 서비스가 실행, 재부팅되어도 완료 표시가 생길 때까지 다시 실행",
        "SSM VPC 엔드포인트로 SSH 없이 Session Manager 접속",
        "인스턴스 역할은 SSM, CloudWatch 에이전트, Bedrock 모델 호출 권한",
    ],
    s2=("기존 서버에 추가", "스택 OrcaOnVscodeStack"),
    cmd2="bash deploy_orca.sh --attach <호스트 스택>",
    legend=[("blue", "이 스택이 만듦"), (None, "호스트 스택의 것")],
    cf_host=("CloudFront (VS Code)", "기존 배포, 헤더 값 A"),
    cf_orca=("CloudFront (Orca)", "새 배포, 암호 게이트, 헤더 값 B"),
    alb=("호스트 ALB :80", "X-Custom-Secret 값으로 구분"),
    rules=[("헤더 A", "code-server :8888", None), ("헤더 B", "orca-serve :6768", "blue"),
           ("헤더 B, /__gate/setup", ":6769", "blue"), ("그 밖", "403", "pink")],
    host="호스트 EC2",
    svc_host=("code-server :8888", "재시작하지 않음"),
    svc_orca=("orca-serve :6768", "orca-gate-setup :6769"),
    adds_label="이 스택이 더하는 것",
    adds=["Orca 전용 CloudFront", "리스너 규칙 2개 (우선순위 5, 10)", "보안 그룹 규칙 2개 (6768, 6769)", "역할 정책 1개"],
    adds_note="호스트 스택은 수정하지 않고, 더한 것은 이 스택을 지우면 함께 삭제",
    s3=("방식별 차이", "같은 코드, 같은 접속 경로, 서버를 다루는 방법만 다름"),
    head=["항목", "전용 서버", "기존 서버에 추가"],
    rows=[
        ("새로 만드는 것", "VPC, ALB, EC2 (기본 r6g.xlarge, EBS 100GB gp3 암호화), CloudFront, SSM VPC 엔드포인트",
         "Orca 전용 CloudFront와 암호 게이트, 호스트 ALB의 리스너 규칙 2개, 호스트 EC2의 보안 그룹 규칙 2개, 호스트 역할의 정책 1개"),
        ("서버 설치", "UserData가 만든 orca-bootstrap 서비스가 실행, 인스턴스가 뜬 뒤 5~10분",
         "SSM Run Command (Custom::OrcaHostInstall), 재부팅과 dnf update 없음, orca-serve와 orca-gate-setup만 다룸"),
        ("Orca 업그레이드", "서버에서 RPM을 직접 설치, 스택의 OrcaVersion은 최초 설치에만 사용",
         "bash upgrade_orca.sh, OrcaVersion을 바꿔 다시 배포하면 orca-serve만 재시작"),
        ("스택 삭제", "EC2와 EBS까지 삭제, 작업 중인 저장소와 ~/.config/orca도 삭제",
         "Orca만 제거, 서버와 다른 서비스, ~/.config/orca는 유지"),
        ("배포 전 점검", "CloudFront prefix list 조회, 설치할 릴리스의 RPM 확인",
         "호스트 ALB에 0.0.0.0/0 규칙 없음, 리스너 HTTP:80, 우선순위 5와 10 비어 있음, SSM 에이전트 온라인"),
    ],
    note="2026-11-22 기준, 근거는 infra-cdk/lib/orca-stack.ts, orca-attach-stack.ts, deploy_orca.sh",
)

T_EN = dict(
    title="Two Ways to Deploy",
    sub_en="Dedicated Server or an Existing Server",
    sub_ko="What the stack creates and what it shares with a host stack",
    s1=("Dedicated server", "Stack OrcaServerStack"),
    cmd1="bash deploy_orca.sh",
    vpc="New VPC 10.253.0.0/16 (an existing VPC can be chosen)",
    n1=[("Amazon CloudFront", "Access password gate"), ("ALB", "Public subnets"), ("Amazon EC2", "Private subnet, AL2023")],
    b1=[
        "UserData only creates the orca-bootstrap service, which runs the install again on every boot until its done marker exists",
        "SSM VPC endpoints give Session Manager access without SSH",
        "The instance role allows SSM, the CloudWatch agent and Bedrock model calls",
    ],
    s2=("Add to an existing server", "Stack OrcaOnVscodeStack"),
    cmd2="bash deploy_orca.sh --attach <host stack>",
    legend=[("blue", "Created by this stack"), (None, "Owned by the host stack")],
    cf_host=("CloudFront (VS Code)", "Existing, header value A"),
    cf_orca=("CloudFront (Orca)", "New, password gate, header value B"),
    alb=("Host ALB :80", "Told apart by X-Custom-Secret"),
    rules=[("Header A", "code-server :8888", None), ("Header B", "orca-serve :6768", "blue"),
           ("Header B, /__gate/setup", ":6769", "blue"), ("Anything else", "403", "pink")],
    host="Host EC2",
    svc_host=("code-server :8888", "Never restarted"),
    svc_orca=("orca-serve :6768", "orca-gate-setup :6769"),
    adds_label="What this stack adds",
    adds=["CloudFront for Orca", "2 listener rules (priority 5, 10)", "2 security group rules (6768, 6769)", "1 role policy"],
    adds_note="The host stack is not modified, and everything added goes away with this stack",
    s3=("How the two differ", "Same code and same access path, only the way the server is handled differs"),
    head=["Item", "Dedicated server", "Add to an existing server"],
    rows=[
        ("Created", "VPC, ALB, EC2 (r6g.xlarge by default, 100 GB encrypted gp3 EBS), CloudFront, SSM VPC endpoints",
         "CloudFront for Orca with the password gate, 2 listener rules on the host ALB, 2 security group rules on the host EC2, 1 policy on the host role"),
        ("Server install", "The orca-bootstrap service created by UserData, 5~10 minutes after the instance starts",
         "SSM Run Command (Custom::OrcaHostInstall), no reboot and no dnf update, touches only orca-serve and orca-gate-setup"),
        ("Orca upgrade", "Install the RPM on the server by hand, the stack's OrcaVersion is used for the first install only",
         "bash upgrade_orca.sh, a redeploy with a new OrcaVersion restarts orca-serve only"),
        ("Stack deletion", "Deletes the EC2 instance and its EBS volume, including work in progress and ~/.config/orca",
         "Removes Orca only, the server, its other services and ~/.config/orca stay"),
        ("Checks before deploy", "Looks up the CloudFront prefix list and the RPM of the release to install",
         "No 0.0.0.0/0 rule on the host ALB, listener on HTTP:80, priorities 5 and 10 free, SSM agent online"),
    ],
    note="As of 2026-11-22, based on infra-cdk/lib/orca-stack.ts, orca-attach-stack.ts and deploy_orca.sh",
)


def command(d, x, y, text, box):
    d.text(x, y, text, 14, 400, "blue", "end", box=box, family=CODE_FAMILY)


def s1(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 1, *t["s1"])
    box = (x, y, w, h)
    command(d, x + w - 26, y + 40, t["cmd1"], box)
    ix, iw = x + 24, w - 48
    top = cy + 44
    # VPC 묶음
    vx = ix + 268
    d.rect(vx, cy + 6, ix + iw - vx, 150, rx=12, fill="none", stroke="green", sw=1.3, dash="7 5")
    d.text(vx + 14, cy + 28, t["vpc"], 12.5, 700, "green", box=box)
    xs, ws = [ix, vx + 18, vx + 18 + 250 + 46], [222, 250, ix + iw - (vx + 18 + 250 + 46) - 18]
    for i, ((name, line), icon) in enumerate(zip(t["n1"], (CF, ALB, EC2))):
        kit.mini(d, xs[i], top, ws[i], 92, name, line, "blue", icon)
    for i in range(2):
        kit.hop(d, xs[i] + ws[i], xs[i + 1], top + 46)
    dot_list(d, ix + 4, cy + 196, iw - 8, t["b1"], 14.5, 21, 11, dot="blue", box=box)


def s2(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 2, *t["s2"])
    box = (x, y, w, h)
    command(d, x + w - 26, y + 40, t["cmd2"], box)
    ix, iw = x + 24, w - 48
    kit.legend(d, ix + iw, cy + 8, t["legend"], box)
    y1, y2, bh = cy + 28, cy + 120, 80
    cw_, aw = 238, 286
    ax = ix + cw_ + 50
    ex = ax + aw + 46
    ew = ix + iw - ex
    kit.mini(d, ix, y1, cw_, bh, t["cf_host"][0], t["cf_host"][1], None, CF, 28)
    kit.mini(d, ix, y2, cw_, bh, t["cf_orca"][0], t["cf_orca"][1], "blue", CF, 28)
    # 호스트 ALB: 헤더 값에 따라 갈라지는 규칙 표
    ah = y2 + bh - y1
    abox = (ax, y1, aw, ah)
    d.rect(ax, y1, aw, ah, rx=10, fill="panel", stroke="muted", sw=1.3, dash="6 5")
    d.icon(ALB, ax + 12, y1 + 10, 28)
    d.text(ax + 50, y1 + 25, t["alb"][0], 15, 700, "text", box=abox)
    d.text(ax + 50, y1 + 43, t["alb"][1], 12, 400, "muted", box=abox)
    ry = y1 + 58
    rh = (ah - 58 - 8) / len(t["rules"])
    for i, (cond, target, color) in enumerate(t["rules"]):
        mid = ry + i * rh + rh / 2
        d.text(ax + 14, mid + 4.5, cond, 12.5, 700, color or "muted", box=abox)
        d.text(ax + aw - 14, mid + 4.5, target, 12.5, 400, "text2", "end", box=abox, family=CODE_FAMILY)
    # 호스트 EC2
    hbox = (ex, y1 - 6, ew, ah + 12)
    d.rect(*hbox, rx=12, fill="none", stroke="muted", sw=1.3, dash="6 5")
    d.icon(EC2, ex + 12, y1 + 4, 26)
    d.text(ex + 46, y1 + 22, t["host"], 14, 700, "text", box=hbox)
    sh = (ah - 44 - 10) / 2
    kit.mini(d, ex + 12, y1 + 38, ew - 24, sh, t["svc_host"][0], t["svc_host"][1], None)
    kit.mini(d, ex + 12, y1 + 38 + sh + 8, ew - 24, sh, t["svc_orca"][0], t["svc_orca"][1], "blue")
    kit.hop(d, ix + cw_, ax, y1 + bh / 2)
    kit.hop(d, ix + cw_, ax, y2 + bh / 2, color="blue")
    kit.hop(d, ax + aw, ex + 12, y1 + 38 + sh / 2)
    kit.hop(d, ax + aw, ex + 12, y1 + 38 + sh + 8 + sh / 2, color="blue")
    # 이 스택이 더하는 것
    ty = y2 + bh + 30
    d.text(ix, ty + 18, t["adds_label"], 14, 700, "text", box=box)
    tx = ix
    ty += 30
    for label in t["adds"]:
        tx += tag(d, tx, ty, label, "blue", 12.5, 26, 11, box=box) + 8
    d.text(ix, ty + 52, t["adds_note"], 13.5, 400, "muted", box=box)


def s3(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 3, *t["s3"])
    kit.table(d, x + 22, cy + 2, w - 44, y + h - 20 - (cy + 2), t["head"], t["rows"], [0.13, 0.42, 0.45], (x, y, w, h))


def landscape(theme):
    t = kit.texts(T, T_EN)
    d = kit.page(theme, t)
    s1(d, 48, 140, 902, 404, t)
    s2(d, 970, 140, 902, 404, t)
    s3(d, 48, 564, 1824, 480, t)
    return kit.finish(d, t)
