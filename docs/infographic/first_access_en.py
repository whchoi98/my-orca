"""first_access.py의 영어판. 구조와 좌표는 같고 글만 다르다."""
import first_access
import orcakit


def landscape(theme):
    orcakit.use("en")
    try:
        return first_access.landscape(theme)
    finally:
        orcakit.use("ko")
