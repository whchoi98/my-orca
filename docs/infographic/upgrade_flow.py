"""Orca 업그레이드 절차 인포그래픽 (04). 근거는 sources.md와 docs/runbooks/upgrade-orca.md.

  landscape(theme)  16:9 한 장. 영어판은 upgrade_flow_en.py가 같은 좌표에 T_EN의 글로 그린다
"""
import orcakit as kit
from infokit import check, dot_list, rw, section

CFN, LAMBDA, SSM, EC2 = ("service/AWS-CloudFormation", "service/AWS-Lambda", "service/AWS-Systems-Manager",
                         "service/Amazon-EC2")

T = dict(
    title="Orca 업그레이드 절차",
    sub_en="Upgrading Orca on an Existing Server",
    sub_ko="버전을 올리기 전의 확인과 실패했을 때의 복구",
    s1=("다섯 단계", "기존 서버에 추가한 스택(--attach) 기준, 3단계는 설치 코드가 바뀐 경우만"),
    steps=[
        ("버전 비교", "upgrade_orca.sh --check", "스택의 OrcaVersion과 GitHub 최신 릴리스 비교, 배포하지 않음"),
        ("새 RPM 사전 확인", "rpm -qp --requires", "임시 폴더에서 sha256, 의존성, serve 옵션, 로그 문구가 그대로인지 확인"),
        ("설치 코드 먼저 배포", "--orca-version <지금 버전>", "infra-cdk/lib/host가 바뀌었으면 버전은 그대로 두고 스크립트만 먼저 배포"),
        ("업그레이드", "upgrade_orca.sh --version <새 버전>", "OrcaVersion을 바꿔 다시 배포, 서버에서는 orca-serve만 재시작"),
        ("확인", "rpm -q orca-ide", "스택 상태, 서비스, 대상 그룹, CloudFront 응답, 브라우저 로그인"),
    ],
    s2=("업그레이드 한 번의 내부 순서", "CloudFormation이 서버의 설치 스크립트를 다시 실행"),
    actors=[("AWS CloudFormation", "OrcaVersion 파라미터 변경"), ("AWS Lambda", "Custom::OrcaHostInstall"),
            ("SSM Run Command", "설치 스크립트 전송"), ("호스트 EC2", "install_orca.sh 실행")],
    script_title="설치 스크립트가 하는 일",
    script=[
        "RPM을 내려받아 릴리스의 sha256과 대조",
        "rpm -Uvh --nodeps --oldpackage로 설치",
        "패키지나 설정이 바뀐 경우에만 orca-serve 재시작",
        "서버 안에서 :6768과 :6769의 응답 확인",
        "완료 표시, 이후 페어링 정보는 별도 리소스가 다시 조회",
    ],
    fail_title="실패했을 때",
    fail=[
        "설치가 실패하면 스택 업데이트가 실패로 끝나고 롤백 시작",
        "롤백은 이전 OrcaVersion으로 설치를 다시 실행, rpm이 낮은 버전을 거부하지 않도록 --oldpackage 필요",
        "롤백이 이전 Lambda 코드로 실행된다고 보고 --oldpackage가 든 설치 코드를 먼저 배포 (3단계)",
    ],
    check_title="업그레이드 뒤 확인 (5단계)",
    checks=[
        "rpm -q orca-ide가 새 버전",
        "스택 UPDATE_COMPLETE, OrcaVersion이 새 버전",
        "orca-serve와 orca-gate-setup이 active",
        "code-server가 재시작되지 않음",
        "대상 그룹 둘 다 healthy",
        "사설 IP의 /web-index.html이 200",
        "CloudFront가 쿠키 없는 요청에 401",
        "ALB 직접 접속은 연결 불가",
    ],
    rollback="실패하면 이전 버전으로 설치 재실행",
    s3=("유지되는 것과 바뀌는 것", "재부팅, dnf update, 다른 서비스의 재시작 없음"),
    keep_title="유지",
    keep=[
        "~/.config/orca의 세션과 설정",
        "접속 암호와 로그인 쿠키 (KeyValueStore는 그대로)",
        "페어링한 브라우저의 등록",
        "code-server를 비롯한 다른 서비스",
        "실행 중인 터미널 (터미널 데몬은 재시작 대상 아님)",
    ],
    change_title="바뀜",
    change=[
        "orca-ide 패키지와 orca-serve 프로세스, 열려 있던 웹 연결은 잠깐 끊김",
        "페어링 링크 (시작할 때마다 새로 출력, 이전의 미사용 링크는 폐기)",
        "스택 출력과 cdk-outputs.json의 링크",
    ],
    avoid_title="피할 것",
    avoid=[
        "서버에서 RPM을 직접 설치하면 스택의 OrcaVersion과 어긋나고, 다음 배포가 스택의 버전으로 되돌림",
        "낮은 버전 지정은 upgrade_orca.sh가 배포 전에 중단",
    ],
    note="2026-11-22에 1.4.253에서 1.4.269로 올리며 확인, 롤백과 페어링한 브라우저의 재접속은 실행으로 확인하지 않음",
)

T_EN = dict(
    title="Orca Upgrade Procedure",
    sub_en="Upgrading Orca on an Existing Server",
    sub_ko="Checks before the version moves and recovery when it fails",
    s1=("Five steps", "For a stack added to an existing server (--attach), step 3 only when the install code changed"),
    steps=[
        ("Compare versions", "upgrade_orca.sh --check", "Compares the stack's OrcaVersion with the latest GitHub release, deploys nothing"),
        ("Pre-check the new RPM", "rpm -qp --requires", "In a scratch folder: sha256, dependencies, serve options and log lines are unchanged"),
        ("Deploy install code first", "--orca-version <current>", "If infra-cdk/lib/host changed, deploy the scripts alone and keep the version"),
        ("Upgrade", "upgrade_orca.sh --version <new>", "Redeploys with the new OrcaVersion, the server restarts orca-serve only"),
        ("Verify", "rpm -q orca-ide", "Stack status, services, target groups, CloudFront responses, browser login"),
    ],
    s2=("What one upgrade does inside", "CloudFormation runs the install script on the server again"),
    actors=[("AWS CloudFormation", "OrcaVersion parameter changes"), ("AWS Lambda", "Custom::OrcaHostInstall"),
            ("SSM Run Command", "Sends the install script"), ("Host EC2", "Runs install_orca.sh")],
    script_title="What the install script does",
    script=[
        "Downloads the RPM and checks it against the release sha256",
        "Installs with rpm -Uvh --nodeps --oldpackage",
        "Restarts orca-serve only when the package or settings changed",
        "Checks the answers of :6768 and :6769 on the server",
        "Writes the done marker, the pairing data is read again afterwards",
    ],
    fail_title="When it fails",
    fail=[
        "A failed install fails the stack update, and the rollback starts",
        "The rollback runs the install again with the previous OrcaVersion, --oldpackage keeps rpm from refusing the older package",
        "The rollback is expected to run the previous Lambda code, so deploy the install code with --oldpackage first (step 3)",
    ],
    check_title="Checks after the upgrade (step 5)",
    checks=[
        "rpm -q orca-ide shows the new version",
        "Stack UPDATE_COMPLETE with the new OrcaVersion",
        "orca-serve and orca-gate-setup are active",
        "code-server was not restarted",
        "Both target groups are healthy",
        "/web-index.html answers 200 on the private IP",
        "CloudFront answers 401 without a cookie",
        "No direct connection to the ALB",
    ],
    rollback="On failure the install runs again with the previous version",
    s3=("What stays, what changes", "No reboot and no dnf update"),
    keep_title="Stays",
    keep=[
        "Sessions and settings in ~/.config/orca",
        "Access password and login cookies (the KeyValueStore is untouched)",
        "Browsers that are already paired",
        "code-server and every other service",
        "Running terminals (the terminal daemon is not restarted)",
    ],
    change_title="Changes",
    change=[
        "The orca-ide package and the orca-serve process, open web connections drop briefly",
        "The pairing link (printed anew on every start, the unused earlier one is retired)",
        "The link in the stack outputs and cdk-outputs.json",
    ],
    avoid_title="Avoid",
    avoid=[
        "Installing the RPM by hand leaves the stack's OrcaVersion behind, and the next deploy puts the stack's version back",
        "A lower target version makes upgrade_orca.sh stop before it deploys",
    ],
    note="Checked on 2026-11-22 while upgrading 1.4.253 to 1.4.269, the rollback and paired-browser reconnect were not exercised",
)

STEP_COLORS = ["blue", "blue", "orange", "green", "green"]


def titled(d, x, y, w, h, title, color):
    """제목 줄이 있는 색 블록의 틀. 내용이 시작하는 y를 돌려준다."""
    d.rect(x, y, w, h, rx=12, fill=color + "F", fo=0.08, stroke=color, sw=1.3)
    d.text(x + 18, y + 33, title, 16, 700, color, box=(x, y, w, h))
    return y + 62


def s1(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 1, *t["s1"])
    kit.step_chain(d, x + 24, cy + 6, w - 48, y + h - 22 - (cy + 6), t["steps"], gap=34, colors=STEP_COLORS)


def s2(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 2, *t["s2"])
    box = (x, y, w, h)
    ix, iw = x + 22, w - 44
    gap = 36
    aw = (iw - gap * 3) / 4
    for i, ((name, line), icon) in enumerate(zip(t["actors"], (CFN, LAMBDA, SSM, EC2))):
        ax = ix + i * (aw + gap)
        kit.mini(d, ax, cy + 6, aw, 76, name, line, "blue", icon, 30)
        if i < 3:
            kit.hop(d, ax + aw, ax + aw + gap, cy + 44)
    # 실패했을 때 되돌아가는 경로: 호스트에서 CloudFormation으로
    ry = cy + 6 + 76 + 22
    d.arrow([(ix + iw - aw / 2, cy + 82), (ix + iw - aw / 2, ry), (ix + aw / 2, ry), (ix + aw / 2, cy + 86)], color="pink",
            sw=1.8, dash="6 5")
    lab = rw(t["rollback"], 13, 700) + 24
    d.rect(ix + iw / 2 - lab / 2, ry - 13, lab, 26, rx=13, fill="card", stroke="pink", sw=1.2)
    d.text(ix + iw / 2, ry + 4.5, t["rollback"], 13, 700, "pink", "middle", box=box)
    top = ry + 30
    bh = 236
    lw = iw * 0.46
    by = titled(d, ix, top, lw, bh, t["script_title"], "blue")
    kit.numbered(d, ix + 18, by + 4, lw - 36, t["script"], "blue", (ix, top, lw, bh), 14.5, 21, 11)
    rx = ix + lw + 16
    rw_ = iw - lw - 16
    fy = titled(d, rx, top, rw_, bh, t["fail_title"], "pink")
    dot_list(d, rx + 20, fy + 4, rw_ - 40, t["fail"], 14.5, 21, 12, dot="pink", box=(rx, top, rw_, bh))
    # 5단계의 확인 목록: 두 줄로 나눈 체크 표시
    ky = top + bh + 14
    kh = y + h - 20 - ky
    cy2 = titled(d, ix, ky, iw, kh, t["check_title"], "green")
    cols = 2
    per = (len(t["checks"]) + cols - 1) // cols
    colw = (iw - 36) / cols
    rh = (ky + kh - 14 - cy2) / per
    for i, item in enumerate(t["checks"]):
        cx = ix + 18 + (i // per) * colw
        mid = cy2 + (i % per) * rh + rh / 2 - 6
        check(d, cx, mid - 7, 14)
        d.text(cx + 26, mid + 5, item, 14.5, 400, "text2", box=(ix, ky, iw, kh))


def s3(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 3, *t["s3"])
    ix, iw = x + 22, w - 44
    total = y + h - 20 - (cy + 6) - 28
    parts = [("keep", "green", 0.39), ("change", "orange", 0.35), ("avoid", "pink", 0.26)]
    by = cy + 6
    for key, color, share in parts:
        bh = total * share
        ty = titled(d, ix, by, iw, bh, t[key + "_title"], color)
        dot_list(d, ix + 20, ty + 2, iw - 40, t[key], 14.5, 21, 8, dot=color, box=(ix, by, iw, bh))
        by += bh + 14


def landscape(theme):
    t = kit.texts(T, T_EN)
    d = kit.page(theme, t)
    s1(d, 48, 140, 1824, 250, t)
    s2(d, 48, 410, 1140, 634, t)
    s3(d, 1208, 410, 664, 634, t)
    return kit.finish(d, t)
