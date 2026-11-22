"""첫 접속 절차 인포그래픽 (03). 근거는 sources.md.

  landscape(theme)  16:9 한 장. 영어판은 first_access_en.py가 같은 좌표에 T_EN의 글로 그린다
"""
import orcakit as kit
from infokit import callout, rw, section, tag

T = dict(
    title="첫 접속 절차",
    sub_en="From Deploy to the First Session",
    sub_ko="링크 하나로 암호 설정, 로그인, 페어링까지",
    s1=("배포부터 Orca 화면까지", "배포할 때 암호를 정했으면 3단계는 생략"),
    steps=[
        ("배포", "bash deploy_orca.sh", "서버 설치가 끝날 때까지 대기, 끝나면 스택 출력에 페어링 링크 표시"),
        ("링크 받기", "PairingWebLink", "배포 마지막 화면의 전체 링크 사용, 다시 받을 때는 get_pairing_url.sh"),
        ("암호 설정", "POST /__gate/setup", "설정 코드, 새 암호, 확인 암호 입력, 설정 서비스가 KeyValueStore에 저장"),
        ("로그인", "POST /__gate/login", "암호가 맞으면 orca_gate 쿠키 발급, 7일 동안 유지"),
        ("페어링", "#pairing=...", "링크의 # 뒤에 있는 페어링 코드로 브라우저 등록, 디바이스 키 저장"),
        ("Orca 화면", "WSS :6768", "이후에는 CloudFront 주소만 열면 접속, 페어링은 브라우저가 기억"),
    ],
    by_label="처리하는 곳",
    by=["CDK, CloudFormation", "스택 출력, SSM", "CloudFront Function, EC2 :6769", "CloudFront Function", "orca-serve", "orca-serve"],
    s2=("게이트의 응답", "같은 요청도 암호를 정하기 전과 뒤에 응답이 다름"),
    head=["상태", "요청", "응답"],
    rows=[
        ("암호를 정하기 전", "HTML 요청 (GET)", "401, 암호 설정 화면"),
        ("암호를 정하기 전", "그 밖의 요청, WebSocket", "503"),
        ("암호를 정하기 전", "POST /__gate/setup", "설정 서비스로 전달, 다른 메서드는 405"),
        ("암호를 정한 뒤", "/__gate/setup", "409"),
        ("암호를 정한 뒤", "POST /__gate/login", "암호가 맞으면 204와 쿠키, 틀리면 401"),
        ("암호를 정한 뒤", "쿠키 없는 요청", "401, HTML 요청에는 로그인 화면"),
        ("암호를 정한 뒤", "/__gate/logout", "302, 쿠키 삭제"),
        ("쿠키가 유효함", "모든 요청", "게이트 쿠키를 빼고 오리진으로 전달"),
    ],
    s3=("다시 받을 때와 바꿀 때", "명령은 저장소 루트에서 실행"),
    head3=["상황", "방법"],
    rows3=[
        ("서버를 재시작해 링크가 바뀜", "bash get_pairing_url.sh"),
        ("로그에서 링크가 사라짐", "bash get_pairing_url.sh --restart"),
        ("링크가 복사 중에 잘림", "접속 주소를 열고 설정 코드와 페어링 코드를 직접 입력"),
        ("접속 암호 변경", "bash set_password.sh, 기존 세션은 만료 (--keep-sessions로 유지)"),
        ("접속 암호 분실", "bash set_password.sh --reset-ui 뒤 새 설정 링크로 접속"),
        ("설정 코드 오입력 20회로 잠김", "서버에서 orca-gate-setup 재시작"),
        ("로그아웃", "브라우저에서 /__gate/logout 열기"),
    ],
    insight=("링크와 코드는 화면 밖에 남기지 않기", "페어링 코드는 URL의 # 뒤에 있어 CloudFront와 ALB의 로그에 남지 않음"),
    note="2026-11-22 기준, 근거는 infra-cdk/lib/functions/password-gate.js, infra-cdk/lib/gate/setup_service.py, README.md",
)

T_EN = dict(
    title="First Access Procedure",
    sub_en="From Deploy to the First Session",
    sub_ko="One link covers password setup, login and pairing",
    s1=("From deploy to the Orca screen", "Step 3 is skipped when the password was given at deploy time"),
    steps=[
        ("Deploy", "bash deploy_orca.sh", "Waits for the server install, then the stack outputs show the pairing link"),
        ("Get the link", "PairingWebLink", "Use the full link on the last deploy screen, get it again with get_pairing_url.sh"),
        ("Set the password", "POST /__gate/setup", "Enter the setup code and the new password twice, the setup service writes the KeyValueStore"),
        ("Log in", "POST /__gate/login", "A correct password issues the orca_gate cookie, kept for 7 days"),
        ("Pair", "#pairing=...", "The pairing code after # registers the browser and stores its device key"),
        ("Orca screen", "WSS :6768", "From then on the CloudFront address is enough, the browser remembers the pairing"),
    ],
    by_label="Handled by",
    by=["CDK, CloudFormation", "Stack outputs, SSM", "CloudFront Function, EC2 :6769", "CloudFront Function", "orca-serve", "orca-serve"],
    s2=("What the gate answers", "The same request gets a different answer before and after a password is set"),
    head=["State", "Request", "Response"],
    rows=[
        ("No password yet", "HTML request (GET)", "401 with the password setup page"),
        ("No password yet", "Any other request, WebSocket", "503"),
        ("No password yet", "POST /__gate/setup", "Passed to the setup service, other methods get 405"),
        ("Password set", "/__gate/setup", "409"),
        ("Password set", "POST /__gate/login", "204 and the cookie when it matches, 401 when it does not"),
        ("Password set", "Request without a cookie", "401, with the login page for HTML requests"),
        ("Password set", "/__gate/logout", "302, cookie removed"),
        ("Valid cookie", "Every request", "Forwarded to the origin without the gate cookie"),
    ],
    s3=("Getting it again and changing it", "Run the commands in the repository root"),
    head3=["Situation", "What to do"],
    rows3=[
        ("The link changed after a server restart", "bash get_pairing_url.sh"),
        ("The link is gone from the log", "bash get_pairing_url.sh --restart"),
        ("The link was cut while copying", "Open the address and type the setup code and the pairing code"),
        ("Change the access password", "bash set_password.sh, existing sessions end (--keep-sessions keeps them)"),
        ("Lost the access password", "bash set_password.sh --reset-ui, then open the new setup link"),
        ("Locked after 20 wrong setup codes", "Restart orca-gate-setup on the server"),
        ("Log out", "Open /__gate/logout in the browser"),
    ],
    insight=("Keep the link and the codes off the record", "The pairing code sits after # in the URL, so CloudFront and ALB logs never see it"),
    note="As of 2026-11-22, based on infra-cdk/lib/functions/password-gate.js, infra-cdk/lib/gate/setup_service.py and README.md",
)

STEP_COLORS = ["blue", "blue", "orange", "orange", "purple", "purple"]


def s1(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 1, *t["s1"])
    box = (x, y, w, h)
    ix, iw = x + 24, w - 48
    gap = 30
    sh = 176
    bw = kit.step_chain(d, ix, cy + 6, iw, sh, t["steps"], gap=gap, colors=STEP_COLORS)
    ly = cy + 6 + sh + 14
    d.text(ix, ly + 17, t["by_label"], 13, 700, "muted", box=box)
    lab = rw(t["by_label"], 13, 700) + 16
    for i, name in enumerate(t["by"]):
        bx = ix + i * (bw + gap)
        tag(d, bx + (lab if i == 0 else 0), ly, name, STEP_COLORS[i], 12, 24, 9, box=box)


def s2(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 2, *t["s2"])
    kit.table(d, x + 22, cy + 2, w - 44, y + h - 20 - (cy + 2), t["head"], t["rows"], [0.22, 0.31, 0.47], (x, y, w, h))


def s3(d, x, y, w, h, t):
    cy = section(d, x, y, w, h, 3, *t["s3"])
    box = (x, y, w, h)
    call_y = y + h - 20 - 58
    kit.table(d, x + 22, cy + 2, w - 44, call_y - 14 - (cy + 2), t["head3"], t["rows3"], [0.36, 0.64], box)
    callout(d, x + 22, call_y, w - 44, *t["insight"], color="pink", box=box)


def landscape(theme):
    t = kit.texts(T, T_EN)
    d = kit.page(theme, t)
    s1(d, 48, 140, 1824, 306, t)
    s2(d, 48, 466, 896, 578, t)
    s3(d, 964, 466, 908, 578, t)
    return kit.finish(d, t)
