"""로컬 모의 서버로 다섯 단계의 실제 HTTP 규격을 검사합니다. 외부 API·실제 키는 사용하지 않습니다."""
import json
import sys
import tempfile
import threading
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))
from main import dispatch

seen = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.path == "/v1/audio/transcriptions":
            message = BytesParser(policy=default).parsebytes(
                ("Content-Type: " + self.headers["Content-Type"] + "\r\n\r\n").encode() + body)
            parts = {p.get_param("name", header="content-disposition"): p.get_payload(decode=True) for p in message.iter_parts()}
            model = parts["model"].decode()
            assert parts["file"] == b"RIFF-mock-audio"
            fmt = parts["response_format"].decode()
            assert fmt == ("diarized_json" if model == "speaker" else "verbose_json")
            segments = [{"start": 0., "end": 2., "text": "지민이 금요일까지 문서를 작성합니다."}]
            if model == "speaker":
                assert parts["chunking_strategy"] == b"auto"
                segments[0].update(speaker="A", text="이 화자 모델의 본문으로 대체하면 안 됩니다.")
            result = {"text": "지민이 금요일까지 문서를 작성합니다.", "segments": segments}
        else:
            payload = json.loads(body); model = payload["model"]
            if self.path == "/v1/embeddings":
                result = {"data": [{"index": i, "embedding": [1., .5, .2]} for i in reversed(range(len(payload["input"])))]}
            elif self.path == "/v1/chat/completions":
                result = {"choices": [{"finish_reason": "stop", "message": {"content": "지민이 금요일까지 작성합니다. [1]"}}]}
            else: raise AssertionError("예상하지 않은 API 경로")
        assert self.headers["Authorization"] == "Bearer test-" + model
        seen.append(model)
        encoded = json.dumps(result).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded))); self.end_headers(); self.wfile.write(encoded)

server = HTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
try:
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder); sample = root / "sample.wav"; sample.write_bytes(b"RIFF-mock-audio")
        roles = ("asr", "speaker", "summary", "embedding", "qa")
        config = {role: {"provider": "openai", "url": f"http://127.0.0.1:{server.server_port}/v1", "model": role} for role in roles}
        config["diarization"] = True
        secrets = {role + "Key": "test-" + role for role in roles}
        def run(action, **fields):
            return dispatch({"action": action, "config": config, "secrets": secrets, "dataDir": str(root / "db"), **fields}, lambda _: None)
        entry = run("create", title="호환 API 검사", kind="meeting", audioPath=str(sample))
        entry = run("transcribe", id=entry["id"])
        assert "지민이 금요일" in entry["text"] and "대체하면" not in entry["text"]
        assert entry["segments"][0]["speaker"] == "화자 1" and not entry["warning"]
        assert run("summarize", id=entry["id"])["summary"]
        answer = run("ask", id=entry["id"], question="누가 언제까지 작성하나요?")
        assert answer["sources"][0]["entry_id"] == entry["id"]
        assert set(seen) == set(roles)
        print("다섯 단계 OpenAI 호환 API 통합 검사 통과: 단계별 키·모델, 음성 multipart, 화자 정렬, 요약, 임베딩, 출처 답변")
finally:
    server.shutdown(); server.server_close(); thread.join(timeout=2)
