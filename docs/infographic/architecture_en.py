"""상세 아키텍처 인포그래픽의 영어판. 구조와 좌표는 architecture.py와 같고 글만 다르다."""
import architecture
import orcakit


def landscape(theme):
    orcakit.use("en")
    try:
        return architecture.landscape(theme)
    finally:
        orcakit.use("ko")
