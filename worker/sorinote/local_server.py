"""설치 패키지에 포함된 Ollama를 AI 작업 동안 실행합니다.

이미 실행 중인 서버는 그대로 사용하며, 직접 만든 프로세스만 정리합니다.
사용자가 고른 다른 주소나 OpenAI 호환 서버를 자동으로 실행하지 않습니다.
"""
import contextlib
import json
import os
import signal
import subprocess
import time
import urllib.request
from urllib.parse import urlsplit


def available(base):
    # 로컬 확인 요청에 시스템 프록시나 HTTP 리디렉션을 사용하지 않습니다.
    from .providers import NoRedirect
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(base + "/api/version", timeout=0.3) as response:
            return bool(json.load(response).get("version"))
    except (ValueError, OSError):
        return False


@contextlib.contextmanager
def managed_ollama(base):
    binary = os.environ.get("SORINOTE_OLLAMA_BIN", "")
    url = urlsplit(base)
    if (not binary or url.scheme != "http" or url.hostname not in ("127.0.0.1", "localhost")
            or url.port != 11434 or url.path.rstrip("/")):
        yield
        return
    if available(base):
        yield
        return
    # 외부 접속·클라우드 설정을 상속하지 않습니다. 기본 모델 캐시는 공유합니다.
    env = {key: value for key, value in os.environ.items() if not key.startswith("OLLAMA_")}
    env.update(OLLAMA_HOST="127.0.0.1:11434", OLLAMA_NO_CLOUD="1")
    try:
        process = subprocess.Popen([binary, "serve"], env=env, start_new_session=True,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        raise ValueError("내장 Ollama를 실행하지 못했습니다. 앱을 다시 설치하거나 설정에서 다른 서버를 선택하세요.") from None
    try:
        # GPU를 처음 확인하는 데 시간이 걸릴 수 있어 단순 포트 열림보다 준비 응답을 기다립니다.
        deadline = time.monotonic() + 45
        while not available(base):
            if process.poll() is not None or time.monotonic() >= deadline:
                raise ValueError("내장 Ollama가 준비 시간 안에 응답하지 않았습니다. 11434 포트와 GPU 사용 상태를 확인하고 다시 시도하세요.")
            time.sleep(0.15)
        yield
    finally:
        # 별도 세션의 자식 추론 프로세스도 함께 정리합니다. 다른 Ollama는 건드리지 않습니다.
        try:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=1.5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=0.5)
        except ProcessLookupError:
            pass

