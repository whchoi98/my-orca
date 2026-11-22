"""deploy_modes.py의 영어판. 구조와 좌표는 같고 글만 다르다."""
import deploy_modes
import orcakit


def landscape(theme):
    orcakit.use("en")
    try:
        return deploy_modes.landscape(theme)
    finally:
        orcakit.use("ko")
