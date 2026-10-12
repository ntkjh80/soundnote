"""워커 시작 시 적용할 다운로드 신뢰 설정입니다. TLS 검증을 끄지 않습니다."""
import os


def configure():
    # 라이브러리가 SSLContext를 가져오기 전에 앱 진입점에서 한 번만 호출합니다.
    # 사내 PEM을 지정한 경우 해당 파일을 우선하고, 나머지는 macOS 키체인을 사용합니다.
    ca = os.environ.get("SSL_CERT_FILE")
    if ca:
        os.environ["REQUESTS_CA_BUNDLE"] = ca
    if os.environ.get("SORINOTE_SYSTEM_CERTS") == "1" and not ca and not os.environ.get("SSL_CERT_DIR"):
        import truststore
        truststore.inject_into_ssl()
    if os.environ.get("SORINOTE_OFFLINE") == "1":
        os.environ["HF_HUB_OFFLINE"] = "1"


def failure_hint(error):
    """예외 내용은 분류에만 사용합니다. 서명된 주소·토큰이 들어갈 수 있어 원문은 반환하지 않습니다."""
    messages = []
    current = error
    seen = set()
    while current is not None and id(current) not in seen and len(messages) < 6:
        seen.add(id(current))
        messages.append(str(current).lower())
        current = current.__cause__ or current.__context__
    text = " ".join(messages)
    if any(word in text for word in ("certificate", "unknownissuer", "unknown issuer", "ssl", "tls")):
        return "인증서 검증에 실패했습니다. 공통 환경의 회사 네트워크 설정에서 macOS 인증서 사용 또는 사내 CA 인증서 묶음을 확인하세요."
    if "407" in text or "proxy authentication" in text:
        return "프록시 인증이 필요합니다. 회사의 프록시 주소와 인증 설정을 확인하세요."
    if "403" in text or "forbidden" in text:
        return "다운로드 서버가 접근을 거절했습니다. 사내 허용 정책과 모델 이용 조건·토큰을 확인하세요."
    if any(word in text for word in ("timeout", "timed out", "connect", "resolve", "dns")):
        return "다운로드 서버에 연결하지 못했습니다. 회사 프록시·허용 주소와 네트워크 연결을 확인하세요."
    return None
