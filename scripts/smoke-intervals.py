"""합성 WAV → 실제 FFmpeg 분할 → 워커 프로세스 → 로컬 모의 API를 검사합니다.

기본 Python에는 imageio_ffmpeg가 없을 수 있어 프로젝트 venv로 실행합니다.
사용자 기록·API Key·마이크는 사용하지 않으며 테스트 데이터는 끝나면 지웁니다.
"""
import io
import json
import os
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import wave

ROOT = Path(__file__).resolve().parents[1]
seen = []
fail_context = True
errors = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass

    def do_POST(self):
        global fail_context
        try:
            body = self.rfile.read(int(self.headers["Content-Length"]))
            if self.path == "/v1/audio/transcriptions":
                message = BytesParser(policy=default).parsebytes(
                    ("Content-Type: " + self.headers["Content-Type"] + "\r\n\r\n").encode() + body)
                parts = {p.get_param("name", header="content-disposition"): p.get_payload(decode=True) for p in message.iter_parts()}
                assert parts["model"] == b"asr" and self.headers["Authorization"] == "Bearer test-asr"
                with wave.open(io.BytesIO(parts["file"])) as reader:
                    duration = reader.getnframes() / reader.getframerate()
                seen.append(("asr", duration))
                text = "금요일까지 초안을 완성합니다." if duration == 60 else "일정을 월요일로 변경합니다."
                result = {"text": text, "segments": [{"start": 1, "end": 3, "text": text}]}
            elif self.path == "/v1/chat/completions":
                request = json.loads(body)
                assert request["model"] == "summary" and self.headers["Authorization"] == "Bearer test-summary"
                prompt = request["messages"][-1]["content"]
                context = "누적 맥락" in prompt
                seen.append(("context" if context else "summary", 0))
                if context and fail_context:
                    fail_context = False
                    self.send_error(503)
                    return
                result = {"choices": [{"finish_reason": "stop", "message": {"content": "일정을 확인합니다."}}]}
            else:
                raise AssertionError("불필요한 모델 요청: " + self.path)
            encoded = json.dumps(result).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded))); self.end_headers(); self.wfile.write(encoded)
        except Exception as error:
            errors.append(repr(error)); self.send_error(500)


server = HTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
try:
    with tempfile.TemporaryDirectory(prefix="sorinote-interval-http-") as folder:
        root = Path(folder); sample = root / "source.wav"
        with wave.open(str(sample), "wb") as writer:
            writer.setnchannels(1); writer.setsampwidth(2); writer.setframerate(16000)
            writer.writeframes(b"\x00\x01" * (70 * 16000))
        url = f"http://127.0.0.1:{server.server_port}/v1"
        config = {role: {"provider": "openai", "url": url, "model": role} for role in ("asr", "summary")}
        config.update(intervalSummaryEnabled=True, intervalMinutes=1, intervalFinalSummary=True, qaEnabled=False)
        def run(action, **fields):
            request = {"action": action, "dataDir": str(root / "db"), "config": config,
                       "secrets": {"asrKey": "test-asr", "summaryKey": "test-summary"}, **fields}
            response = subprocess.run([sys.executable, str(ROOT / "worker/main.py")], input=json.dumps(request),
                capture_output=True, text=True, check=True, timeout=90,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "SORINOTE_OFFLINE": "1"})
            events = [json.loads(line) for line in response.stdout.splitlines()]
            assert events and not errors, errors
            return events
        entry = run("create", title="합성 구간 검사", kind="meeting", audioPath=str(sample))[-1]["data"]
        first = run("transcribe", id=entry["id"])
        assert first[-1]["event"] == "error"
        saved = [e["data"] for e in first if e["event"] == "entry"][-1]
        assert saved["interval_notes"][0]["status"] == "transcribed" and saved["text"]
        second = run("continueIntervals", id=entry["id"])
        assert second[-1]["event"] == "result", second[-1]
        result = second[-1]["data"]
        assert [pair for pair in seen if pair[0] == "asr"] == [("asr", 60), ("asr", 10)], seen
        assert [(note["start"], note["end"]) for note in result["interval_notes"]] == [(0, 60), (60, 70)]
        assert all(note["status"] == "complete" for note in result["interval_notes"])
        assert result["interval_complete"] == 1 and result["summary"]
        assert result["segments"][1]["start"] == 61
        assert result["text"].count("금요일") == 1 and result["text"].count("월요일") == 1
        assert Path(result["audio_path"]).read_bytes() == sample.read_bytes()
        assert len([e for e in second if e["event"] == "entry"]) >= 4
        # 라이브 녹음과 동일하게 구간마다 별도 워커를 실행하고 중간에 원음을 연결합니다.
        live = run("create", title="녹음 중 구간 경로", kind="meeting", intervalRecording=True)[-1]["data"]
        with wave.open(str(sample), "rb") as reader:
            for index, frames in enumerate((60 * 16000, 10 * 16000)):
                chunk = root / f"closed-{index}.wav"
                with wave.open(str(chunk), "wb") as writer:
                    writer.setparams(reader.getparams()); writer.writeframes(reader.readframes(frames))
                if index == 1:
                    attached = run("attachAudio", id=live["id"], audioPath=str(sample))[-1]["data"]
                    assert len(attached["interval_notes"]) == 1
                completed = run("interval", id=live["id"], audioPath=str(chunk), start=index * 60, end=60 if index == 0 else 70)
                assert completed[-1]["event"] == "result", completed[-1]
        live = run("finalizeIntervals", id=live["id"])[-1]["data"]
        assert live["interval_complete"] == 1 and len(live["interval_notes"]) == 2 and live["summary"]
        print("녹음 경로의 워커 분리·중간 원음 연결·마지막 구간·최종 요약 검사 통과")
        print("실제 워커·FFmpeg·호환 API 구간 처리 통과: 60초+10초, 중간 결과, 요약 실패 후 전사 재사용, 단계별 키, 전체 요약, 원음 보존")
finally:
    server.shutdown(); server.server_close(); thread.join(timeout=2)
