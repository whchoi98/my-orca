"""my-orca 인포그래픽의 공용 부품. aws-infographic 스킬의 infokit 위에 얹는다.

장 모듈은 한국어 글(T)과 영어 글(T_EN)을 따로 갖고, use(lang)으로 그릴 언어를 고른다. 구조와 좌표는 두 언어가 같다.
모든 글자에 감싸는 카드의 box를 넘겨 buildkit의 검사가 넘침을 잡게 한다.
"""
from infokit import CODE_FAMILY, Doc, cell, footer_note, header, para

LANG = "ko"


def use(lang):
    global LANG
    LANG = lang


def texts(ko, en):
    return en if LANG == "en" else ko


def page(theme, t):
    d = Doc(1920, 1080, theme)
    d.rect(0, 0, 1920, 1080, fill="bg")
    header(d, 48, 76, t["title"], t["sub_en"], t["sub_ko"])
    return d


def finish(d, t):
    footer_note(d, 1872, 1064, t["note"])
    return d.svg()


def node(d, x, y, w, h, name, sub, items, color, icon=None, dashed=False, fo=0.09):
    """구성 요소 카드: 아이콘, 이름, 한 줄 설명, (굵은 이름표, 설명) 항목들."""
    box = (x, y, w, h)
    d.rect(x, y, w, h, rx=12, fill=color + "F", fo=fo, stroke=color, sw=1.4, dash="7 5" if dashed else None)
    tx = x + 16
    if icon:
        d.icon(icon, x + 14, y + 14, 40)
        tx = x + 66
    d.text(tx, y + 32, name, 18, 700, "text", box=box)
    if sub:
        d.text(tx, y + 53, sub, 13, 400, "muted", box=box)
    yy = y + 92
    for label, body in items:
        if label:
            d.text(x + 16, yy, label, 14, 700, color, box=box)
            yy += 22
        last = para(d, x + 16, yy, w - 32, body, 14, 20, 400, "text2", box=box)
        yy = last + 32
    return yy


def hop(d, x1, x2, y, label=None, label_y=None, color="arrow", dash=None):
    """두 카드 사이의 화살표. 글은 화살표가 아니라 카드 줄 위(label_y)에 둔다."""
    d.arrow([(x1 + 5, y), (x2 - 5, y)], color=color, sw=2, dash=dash)
    if label:
        d.text((x1 + x2) / 2, label_y, label, 13, 700, "muted", "middle")


def table(d, x, y, w, h, head, rows, widths, box, size=14.5, lh=20, mono_first=False):
    """머리줄과 행. widths는 열 폭의 비율(합 1.0), 행 높이는 남은 높이를 행 수로 나눈 값."""
    hh = 30
    d.rect(x, y, w, hh, rx=6, fill="panel", stroke="cardline", sw=1)
    xs = [x]
    for f in widths:
        xs.append(xs[-1] + w * f)
    for i, t in enumerate(head):
        d.text(xs[i] + 12, y + 20, t, 12.5, 700, "muted", box=box)
    rh = (h - hh) / len(rows)
    for r, row in enumerate(rows):
        top = y + hh + r * rh
        if r:
            d.line(x, top, x + w, top, stroke="cardline", sw=1)
        mid = top + rh / 2
        for i, t in enumerate(row):
            first = i == 0
            if first and mono_first:
                d.text(xs[i] + 12, mid + 5, t, size, 700, "text", box=box, family=CODE_FAMILY)
            else:
                cell(d, xs[i] + 12, mid, xs[i + 1] - xs[i] - 24, t, size, lh, 700 if first else 400,
                     "text" if first else "text2", box)
    d.line(x, y + h, x + w, y + h, stroke="cardline", sw=1)


def step_chain(d, x, y, w, h, steps, color="blue", gap=30, code_size=12.5, colors=None):
    """번호가 붙은 단계 상자를 화살표로 잇는다. steps = [(제목, 명령 또는 None, 설명), ...]"""
    n = len(steps)
    bw = (w - gap * (n - 1)) / n
    for i, (title, cmd, body) in enumerate(steps):
        if colors:
            color = colors[i]
        bx = x + i * (bw + gap)
        box = (bx, y, bw, h)
        d.rect(bx, y, bw, h, rx=12, fill="panel", stroke="line2", sw=1.2)
        d.circle(bx + 28, y + 30, 14, fill=color + "F")
        d.text(bx + 28, y + 35.5, str(i + 1), 15, 700, "badgetext" if color in ("blue", "purple") else "onwarm", "middle")
        d.text(bx + 52, y + 36, title, 16, 700, "text", box=box)
        yy = y + 68
        if cmd:
            d.text(bx + 16, yy, cmd, code_size, 400, color, box=box, family=CODE_FAMILY)
            yy += 24
        para(d, bx + 16, yy, bw - 32, body, 13.5, 19, 400, "text2", box=box, maxl=5)
        if i < n - 1:
            d.arrow([(bx + bw + 4, y + h / 2), (bx + bw + gap - 4, y + h / 2)], sw=2)
    return bw


def block(d, x, y, w, h, title, chip, items, color, num=None):
    """제목, 오른쪽 이름표, 점 목록이 든 색 블록."""
    from infokit import dot_list, rw, tag
    box = (x, y, w, h)
    d.rect(x, y, w, h, rx=12, fill=color + "F", fo=0.08, stroke=color, sw=1.3)
    tx = x + 18
    if num is not None:
        d.circle(x + 30, y + 30, 14, fill=color + "F")
        d.text(x + 30, y + 35.5, str(num), 15, 700, "badgetext" if color in ("blue", "purple") else "onwarm", "middle")
        tx = x + 54
    d.text(tx, y + 37, title, 18, 700, "text", box=box)
    if chip:
        cwid = rw(chip, 12.5, 700) + 20
        tag(d, x + w - 18 - cwid, y + 18, chip, color, 12.5, 24, 10, box=box)
    dot_list(d, x + 20, y + 76, w - 40, items, 15, 22, 11, dot=color, box=box)


def mini(d, x, y, w, h, name, line, color=None, icon=None, isize=32):
    """작은 구성 요소 상자. color가 None이면 이 스택 밖(호스트)의 것으로 회색 점선."""
    box = (x, y, w, h)
    if color:
        d.rect(x, y, w, h, rx=10, fill=color + "F", fo=0.10, stroke=color, sw=1.4)
    else:
        d.rect(x, y, w, h, rx=10, fill="panel", stroke="muted", sw=1.3, dash="6 5")
    tx = x + 14
    if icon:
        d.icon(icon, x + 12, y + 12, isize)
        tx = x + 12 + isize + 10
    d.text(tx, y + 29, name, 15, 700, "text", box=box)
    if line:
        para(d, tx, y + 49, x + w - 12 - tx, line, 12.5, 17, 400, "muted", box=box, maxl=3)


def numbered(d, x, y, w, items, color, box, size=14, lh=20, gap=10):
    """번호 원과 문장의 목록. 마지막 줄의 기준선을 돌려준다."""
    yy = last = y
    for i, it in enumerate(items):
        d.circle(x + 10, yy - size * 0.34, 10, fill=color + "F")
        d.text(x + 10, yy - size * 0.34 + 4.5, str(i + 1), 12, 700, "badgetext" if color in ("blue", "purple") else "onwarm",
               "middle")
        last = para(d, x + 30, yy, w - 30, it, size, lh, 400, "text2", box=box)
        yy = last + lh + gap
    return last


def legend(d, x, y, items, box):
    """범례. items = [(color 또는 None, 글), ...]. 오른쪽 끝 x에 맞춰 왼쪽으로 놓는다."""
    from infokit import rw
    cx = x
    for color, label in reversed(items):
        wd = rw(label, 12.5, 400)
        cx -= wd
        d.text(cx, y + 4, label, 12.5, 400, "muted", box=box)
        cx -= 22
        if color:
            d.rect(cx, y - 8, 16, 14, rx=3, fill=color + "F", fo=0.18, stroke=color, sw=1.3)
        else:
            d.rect(cx, y - 8, 16, 14, rx=3, fill="panel", stroke="muted", sw=1.2, dash="4 3")
        cx -= 20
