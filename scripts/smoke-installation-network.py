"""임시 HTTPS 서버로 사내 CA 설정을 재현합니다. 키체인·실제 회사 서버는 변경하지 않습니다.

실행: 준비된 venv/bin/python scripts/smoke-installation-network.py /경로/uv
모든 인증서·테스트 패키지·venv는 임시 폴더 안에서 만들고 검사 후 지웁니다.
"""
import functools
import http.server
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import zipfile

ROOT = Path(__file__).resolve().parents[1]
UV = str(Path(sys.argv[1]).resolve())


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def run(args, env, success=True):
    result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=60)
    if (result.returncode == 0) != success:
        raise RuntimeError("인증서 검사 결과가 예상과 다릅니다: " + result.stderr[-2000:])
    return result


with tempfile.TemporaryDirectory(prefix="sorinote-tls-") as folder:
    root = Path(folder)
    cert, key = root / "ca.pem", root / "key.pem"
    config = root / "openssl.cnf"
    config.write_text("""[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=SoriNote Local Test Root
[ext]
subjectAltName=DNS:localhost,IP:127.0.0.1
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
[leaf]
subjectAltName=DNS:localhost,IP:127.0.0.1
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
""")
    subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-config", str(config), "-keyout", str(key), "-out", str(cert)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.chmod(key, 0o600)
    leaf_cert, leaf_key, csr = root / "server.pem", root / "server-key.pem", root / "server.csr"
    subprocess.run(["/usr/bin/openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost",
                    "-keyout", str(leaf_key), "-out", str(csr)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["/usr/bin/openssl", "x509", "-req", "-in", str(csr), "-CA", str(cert), "-CAkey", str(key),
                    "-CAcreateserial", "-days", "1", "-extfile", str(config), "-extensions", "leaf", "-out", str(leaf_cert)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.chmod(leaf_key, 0o600)
    (root / "ok").write_text("ok")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(root)))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(leaf_cert, leaf_key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"https://127.0.0.1:{server.server_port}"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("UV_", "PIP_"))}
    for name in ("SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "PYTHONPATH"):
        env.pop(name, None)
    env.update(SORINOTE_SYSTEM_CERTS="1", NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost",
               UV_NO_CONFIG="true", UV_CACHE_DIR=str(root / "cache"), UV_SYSTEM_CERTS="true")
    code = """
import sys
sys.path.insert(0, sys.argv[1])
from sorinote.network import configure
configure()
import urllib.request, requests, httpx
assert urllib.request.urlopen(sys.argv[2], timeout=5).read() == b'ok'
assert requests.get(sys.argv[2], timeout=5).text == 'ok'
assert httpx.get(sys.argv[2], timeout=5).text == 'ok'
"""
    try:
        args = [sys.executable, "-c", code, str(ROOT / "worker"), base + "/ok"]
        rejected = run(args, env, success=False)
        assert "certificate" in rejected.stderr.lower(), "TLS 검증 외의 이유로 실패했습니다."
        print("통과: 등록하지 않은 자체 인증서를 기본 상태에서 거절", flush=True)
        approved = {**env, "SSL_CERT_FILE": str(cert)}
        run(args, approved)
        print("통과: 명시한 PEM으로 urllib·requests·httpx의 HTTPS 연결", flush=True)

        wheel = "sorinote_tls_probe-1.0-py3-none-any.whl"
        with zipfile.ZipFile(root / wheel, "w") as archive:
            archive.writestr("sorinote_tls_probe.py", "VALUE = 42\n")
            prefix = "sorinote_tls_probe-1.0.dist-info/"
            archive.writestr(prefix + "METADATA", "Metadata-Version: 2.1\nName: sorinote-tls-probe\nVersion: 1.0\n")
            archive.writestr(prefix + "WHEEL", "Wheel-Version: 1.0\nGenerator: sorinote-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n")
            archive.writestr(prefix + "RECORD", "")
        index = root / "simple/sorinote-tls-probe"
        index.mkdir(parents=True)
        (index / "index.html").write_text(f'<a href="/{wheel}">{wheel}</a>')
        venv = root / "venv"
        run([UV, "venv", "--no-project", "--no-python-downloads", "--python", sys.executable, str(venv)], env)
        install = [UV, "pip", "install", "--python", str(venv / "bin/python"), "--no-python-downloads", "--no-build",
                   "--default-index", base + "/simple", "sorinote-tls-probe==1.0"]
        rejected = run(install, env, success=False)
        assert any(word in rejected.stderr.lower() for word in ("certificate", "unknownissuer", "unknown issuer"))
        run(install, approved)
        run([str(venv / "bin/python"), "-c", "import sorinote_tls_probe; assert sorinote_tls_probe.VALUE == 42"], env)
        print("통과: uv가 미신뢰 인덱스를 거절하고 지정한 CA로 사내 인덱스 설치", flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
