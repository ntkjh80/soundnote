"""Ollama와 OpenAI 호환 서버의 차이를 UI 밖으로 감춥니다."""
import json
import os
import math
import mimetypes
import urllib.error
import urllib.request
import uuid
import contextlib
from pathlib import Path
from .config import validate_endpoint


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("서버가 다른 주소로 연결을 바꾸려 해서 중단했습니다. 최종 주소를 직접 설정하세요.")


class Provider:
    def __init__(self, profile, allow_remote=False, key=""):
        self.profile = profile
        self.base, self.local = validate_endpoint(profile["url"], allow_remote)
        self.model = profile["model"].strip()
        self.kind = profile["provider"]
        self.key = key
        self.allow_remote = allow_remote
        if self.kind not in ("ollama", "openai") or not self.model:
            raise ValueError("공급자와 모델 이름을 확인해 주세요.")
        if not allow_remote and ("cloud" in self.model.lower()):
            raise ValueError("클라우드 모델은 로컬 전용 모드에서 사용할 수 없습니다.")
        self.checked = False

    def request(self, path, body=None):
        headers = {"Content-Type": "application/json"}
        if self.key:
            headers["Authorization"] = "Bearer " + self.key
        request = urllib.request.Request(self.base + path,
            data=json.dumps(body).encode() if body is not None else None, headers=headers)
        return self.send(request)

    def send(self, request):
        from .local_server import managed_ollama
        with managed_ollama(self.base) if self.kind == "ollama" else contextlib.nullcontext():
            return self._send(request)

    def _send(self, request):
        # 환경 변수의 프록시로 로컬 회의 데이터가 우회 전송되지 않도록 합니다.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        try:
            with opener.open(request, timeout=600) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            # 서버 응답에는 원문이나 키가 포함될 수 있어서 그대로 화면에 노출하지 않습니다.
            raise ValueError(f"모델 서버 오류({error.code}). 모델 설치, 주소, API Key를 확인하세요.") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise ValueError("모델 서버에 연결할 수 없습니다. Ollama 실행 상태와 서버 주소를 확인하세요.") from None
        if isinstance(result, dict) and result.get("error"):
            raise ValueError("모델 서버가 요청을 거절했습니다. 선택한 모델과 서버 설정을 확인하세요.")
        return result

    def pull(self, progress):
        """다운로드 스트림을 읽되 서버의 원문 오류와 인증 정보는 화면에 남기지 않습니다."""
        from .local_server import managed_ollama
        if self.kind != "ollama" or not self.local or "cloud" in self.model.lower():
            raise ValueError("자동 다운로드는 로컬 Ollama 모델에만 사용할 수 있습니다.")
        if os.environ.get("SORINOTE_OFFLINE") == "1":
            progress(self.model + " 로컬 설치 확인 중")
            self.check_local_model()
            return
        headers = {"Content-Type": "application/json"}
        if self.key:
            headers["Authorization"] = "Bearer " + self.key
        request = urllib.request.Request(self.base + "/api/pull", headers=headers,
            data=json.dumps({"model": self.model, "stream": True}).encode())
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        progress(self.model + " 다운로드 중")
        complete, last_percent = False, -1
        with managed_ollama(self.base):
            try:
                with opener.open(request, timeout=600) as response:
                    for line in response:
                        value = json.loads(line)
                        if value.get("error"):
                            from .network import failure_hint
                            hint = failure_hint(ValueError(str(value["error"])))
                            raise ValueError(hint or "Ollama 모델 다운로드에 실패했습니다. 모델 이름과 인터넷 연결을 확인하세요.")
                        total = value.get("total", 0)
                        if total > 0:
                            percent = int(value.get("completed", 0) * 100 / total)
                            if percent != last_percent:
                                progress(f"{self.model} 다운로드 중 · 현재 파일 {percent}%")
                                last_percent = percent
                        complete = complete or value.get("status") == "success"
            except (urllib.error.URLError, OSError):
                raise ValueError("모델 다운로드 서버에 연결하지 못했습니다. 인터넷 연결과 모델 서버 상태를 확인하세요.") from None
        if not complete:
            raise ValueError("모델 다운로드가 완료되기 전에 연결이 끝났습니다. 다시 준비해 주세요.")
        self.check_local_model()

    def transcribe(self, path, response_format="verbose_json", language=""):
        """파일 전사 API만 호출합니다. 일반 채팅 API로 음성 파일을 보내지 않습니다."""
        if self.kind != "openai":
            raise ValueError("음성 API는 OpenAI 호환 실행 방식을 선택하세요.")
        source = Path(path)
        if source.stat().st_size > 25_000_000:
            raise ValueError("음성 API에는 25MB 이하 파일을 보내도록 제한했습니다. 파일을 나누거나 로컬 처리를 사용하세요.")
        if response_format not in ("json", "verbose_json", "diarized_json"):
            raise ValueError("지원하지 않는 음성 API 응답 형식입니다.")
        fields = {"model": self.model, "response_format": response_format}
        if language:
            fields["language"] = language
        if response_format == "diarized_json":
            fields["chunking_strategy"] = "auto"
        boundary = "sorinote-" + uuid.uuid4().hex
        body = bytearray()
        for name, value in fields.items():
            body.extend((f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n').encode())
        suffix = source.suffix.lower()
        # 사용자의 원본 파일명은 업로드 헤더에 넣지 않습니다.
        safe_suffix = suffix if suffix in (".wav", ".mp3", ".m4a", ".mp4", ".webm", ".ogg", ".flac", ".aiff") else ".bin"
        mime = mimetypes.guess_type("recording" + safe_suffix)[0] or "application/octet-stream"
        body.extend((f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="recording{safe_suffix}"\r\n'
                     f'Content-Type: {mime}\r\n\r\n').encode())
        body.extend(source.read_bytes())
        body.extend(f"\r\n--{boundary}--\r\n".encode())
        headers = {"Content-Type": "multipart/form-data; boundary=" + boundary}
        if self.key:
            headers["Authorization"] = "Bearer " + self.key
        return self.send(urllib.request.Request(self.base + "/audio/transcriptions", data=bytes(body), headers=headers))

    def check_local_model(self):
        if self.checked or self.allow_remote or self.kind != "ollama":
            return
        info = self.request("/api/show", {"model": self.model})
        if info.get("remote_host") or info.get("remote_model"):
            raise ValueError("이 Ollama 모델은 외부 서버를 사용합니다. 로컬 모델을 선택하세요.")
        self.checked = True

    def chat(self, system, prompt):
        self.check_local_model()
        messages = [{"role": "system", "content": system}, {"role": "user", "content": prompt}]
        if self.kind == "ollama":
            result = self.request("/api/chat", {"model": self.model, "messages": messages,
                "stream": False, "keep_alive": 0,
                "options": {"temperature": 0.2, "num_ctx": 16384, "num_predict": 2300}})
            if result.get("done_reason") == "length":
                raise ValueError("모델 답변이 길이 제한으로 잘렸습니다. 원문을 나누거나 다른 모델을 선택하세요.")
            answer = result.get("message", {}).get("content", "")
        else:
            result = self.request("/chat/completions", {"model": self.model,
                "messages": messages, "stream": False, "temperature": 0.2, "max_tokens": 2300})
            choices = result.get("choices", [])
            if not choices or choices[0].get("finish_reason") == "length":
                raise ValueError("모델 답변이 비어 있거나 길이 제한으로 잘렸습니다.")
            answer = choices[0].get("message", {}).get("content", "")
        if not isinstance(answer, str) or not answer.strip():
            raise ValueError("모델이 빈 답변을 반환했습니다. 모델 설정을 확인해 주세요.")
        return answer.strip()

    def embed(self, texts):
        self.check_local_model()
        vectors = []
        # 문서 전체를 한 요청에 넣지 않아 임베딩 서버의 메모리 사용을 제한합니다.
        for start in range(0, len(texts), 16):
            batch = texts[start:start + 16]
            if self.kind == "ollama":
                result = self.request("/api/embed", {"model": self.model, "input": batch,
                    "truncate": False, "keep_alive": 0})
                current = result.get("embeddings", [])
            else:
                result = self.request("/embeddings", {"model": self.model, "input": batch})
                data = sorted(result.get("data", []), key=lambda item: item["index"])
                if [item["index"] for item in data] != list(range(len(batch))):
                    raise ValueError("임베딩 서버가 문단 순서를 잘못 반환했습니다.")
                current = [item["embedding"] for item in data]
            if len(current) != len(batch):
                raise ValueError("임베딩 서버가 일부 문단의 벡터를 반환하지 않았습니다.")
            vectors.extend(current)
        return validate_vectors(vectors, len(texts))


def validate_vectors(vectors, expected):
    """직접 실행과 서버 응답에 동일한 벡터 품질 검사를 적용합니다."""
    if not isinstance(vectors, list) or len(vectors) != expected or not vectors:
        raise ValueError("문단 수와 검색 벡터 수가 일치하지 않습니다.")
    if not all(isinstance(v, list) and v for v in vectors) or len({len(v) for v in vectors}) != 1:
        raise ValueError("검색 벡터의 길이가 올바르지 않습니다.")
    if any(not all(isinstance(x, (float, int)) and math.isfinite(x) for x in v)
           or sum(x*x for x in v) == 0 for v in vectors):
        raise ValueError("검색 벡터에 사용할 수 없는 숫자가 있습니다.")
    return vectors
