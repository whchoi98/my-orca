"""접속 경로와 보호 계층 인포그래픽의 영어판. 구조와 좌표는 access_path.py와 같고 글만 다르다."""
import access_path
import orcakit


def landscape(theme):
    orcakit.use("en")
    try:
        return access_path.landscape(theme)
    finally:
        orcakit.use("ko")
