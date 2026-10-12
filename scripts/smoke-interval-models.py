"""이미 준비된 로컬 모델로 60초+짧은 꼬리의 자동 구간 요약을 검사합니다.

프로젝트 venv로 실행하세요. 합성 한국어 음성만 사용하며 모델을 다운로드하지 않습니다.
Ollama가 실행 중이 아니면 SORINOTE_OLLAMA_BIN에 내장 실행 파일을 지정할 수 있습니다.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import imageio_ffmpeg

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="sorinote-interval-models-") as folder:
    root = Path(folder)
    for name, phrase in [("first", "이번 프로젝트의 초안은 금요일까지 작성합니다. 지민이 문서를 맡고 민수는 검색 기능을 확인합니다."),
                         ("second", "앞서 논의한 초안의 검토 회의는 다음 주 월요일입니다. 초안 작성 기한은 금요일로 유지합니다.")]:
        subprocess.run(["/usr/bin/say", "-v", "Yuna", "-o", str(root / (name + ".aiff")), phrase], check=True)
    sample = root / "sample.wav"
    subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-nostdin", "-v", "error", "-i", str(root / "first.aiff"),
        "-i", str(root / "second.aiff"), "-filter_complex", "[1:a]adelay=60000:all=1[late];[0:a][late]amix=inputs=2:duration=longest:normalize=0[out]",
        "-map", "[out]", "-ar", "16000", "-ac", "1", str(sample)], check=True)
    config = {"intervalSummaryEnabled": True, "intervalMinutes": 1, "intervalFinalSummary": True,
              "qaEnabled": False, "diarization": False}
    def run(action, **fields):
        request = {"action": action, "dataDir": str(root / "db"), "config": config, **fields}
        began = time.monotonic()
        process = subprocess.Popen([sys.executable, str(ROOT / "worker/main.py")], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "HF_HUB_OFFLINE": "1", "SORINOTE_OFFLINE": "1"})
        process.stdin.write(json.dumps(request)); process.stdin.close()
        result = None; updates = []
        try:
            for line in process.stdout:
                event = json.loads(line)
                if event["event"] == "progress": print(event["message"], flush=True)
                elif event["event"] == "entry": updates.append(event["data"])
                elif event["event"] == "result": result = event["data"]
                elif event["event"] == "error": raise RuntimeError(event["message"])
            assert process.wait() == 0 and result is not None
        finally:
            if process.poll() is None: process.terminate()
            process.wait(); process.stdout.close()
        print(f"{action}: {time.monotonic() - began:.2f}초 · 중간 저장 {len(updates)}회", flush=True)
        return result, updates
    entry, _ = run("create", title="합성 음성 구간 요약", kind="meeting", audioPath=str(sample))
    result, updates = run("transcribe", id=entry["id"])
    assert len(result["interval_notes"]) == 2 and result["interval_notes"][0]["end"] == 60
    assert result["interval_complete"] == 1 and result["summary"].strip()
    assert all(note["status"] == "complete" and note["summary"].strip() for note in result["interval_notes"])
    assert any(entry["interval_notes"][-1]["status"] == "transcribed" for entry in updates)
    assert Path(result["audio_path"]).read_bytes() == sample.read_bytes()
    print(json.dumps({"text": result["text"], "interval_notes": result["interval_notes"], "summary": result["summary"]}, ensure_ascii=False, indent=2))
    print("기본 로컬 모델 자동 구간 요약 검사 통과. 합성 자료의 연결 확인이며 실제 회의 정확도·최대 메모리 실측은 아닙니다.")
