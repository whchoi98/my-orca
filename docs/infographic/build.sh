#!/usr/bin/env bash
# my-orca 문서의 인포그래픽을 만든다. aws-infographic 스킬의 infokit.py, buildkit.py를 그대로 쓴다.
#   ./build.sh            build/ 아래에 16:9 다크, 라이트 SVG와 PNG를 한국어판과 영어판으로 만들고 검사 결과를 출력한다
#   ./build.sh 01         이름이 01로 시작하는 그림만 만든다
# 필요한 것
#   uv                Playwright와 Pillow를 받아 실행한다 (없으면 PYTHON에 두 패키지가 설치된 파이썬을 준다)
#   INFOKIT_FONTS     nanumsquare/, d2coding/ 폴더가 있는 글꼴 디렉터리 (기본: ~/.local/share/infokit-fonts)
#   AWS_ICON_BUNDLE   aws-diagram 스킬의 assets/icons.json (비워 두면 infokit이 설치된 플러그인에서 찾는다)
# AWS를 부르지 않는다.
set -euo pipefail
cd "$(dirname "$0")"
export INFOKIT_FONTS="${INFOKIT_FONTS:-$HOME/.local/share/infokit-fonts}"
# Playwright 휠에 든 node가 이 서버에서 실행되지 않아 설치된 node를 쓴다
export PLAYWRIGHT_NODEJS_PATH="${PLAYWRIGHT_NODEJS_PATH:-$(command -v node)}"
if [ -n "${PYTHON:-}" ]; then
    RUN=("$PYTHON")
else
    RUN=(uv run --no-project --with playwright==1.65.0 --with pillow python)
fi

PAGES=(
    access_path:01-access-path access_path_en:01-access-path-en
    deploy_modes:02-deploy-modes deploy_modes_en:02-deploy-modes-en
    first_access:03-first-access first_access_en:03-first-access-en
    upgrade_flow:04-upgrade-flow upgrade_flow_en:04-upgrade-flow-en
    architecture:05-architecture architecture_en:05-architecture-en
)
FILTER="${1:-}"
SPECS=()
for spec in "${PAGES[@]}"; do
    case "${spec#*:}" in "$FILTER"*) SPECS+=("$spec") ;; esac
done
[ "${#SPECS[@]}" -gt 0 ] || { echo "만들 그림이 없습니다: $FILTER"; exit 1; }

status=0
"${RUN[@]}" -B buildkit.py build "${SPECS[@]}" || status=$?
# README에 넣는 2x PNG는 256색으로 줄인다(글자와 선이 주라 눈에 띄는 손실이 없고 용량은 3분의 1 수준이 된다)
"${RUN[@]}" -B - "${SPECS[@]}" <<'PY'
import sys
from pathlib import Path
from PIL import Image
for spec in sys.argv[1:]:
    slug = spec.split(":")[1]
    for theme in ("dark", "light"):
        path = Path("build") / f"{slug}_16x9_{theme}.png"
        before = path.stat().st_size
        Image.open(path).convert("RGB").quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(path, optimize=True)
        print(f"{path}  {before // 1024} KB -> {path.stat().st_size // 1024} KB")
PY
exit $status
