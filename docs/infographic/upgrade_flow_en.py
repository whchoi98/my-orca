"""upgrade_flow.py의 영어판. 구조와 좌표는 같고 글만 다르다."""
import upgrade_flow
import orcakit


def landscape(theme):
    orcakit.use("en")
    try:
        return upgrade_flow.landscape(theme)
    finally:
        orcakit.use("ko")
