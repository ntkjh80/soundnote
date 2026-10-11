"""준비된 실제 모델로 전사 → 요약 → 검색을 확인합니다. 합성 음성만 사용합니다."""
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / ".runtime"
RUNTIME.mkdir(exist_ok=True)
audio = RUNTIME / "smoke-ko.aiff"
subprocess.run(["/usr/bin/say", "-v", "Yuna", "-o", str(audio),
    "이번 프로젝트는 금요일까지 초안을 완성합니다. 민수는 검색 기능을 확인하고 지민은 문서를 작성합니다."], check=True)


def run(action, **fields):
    request = {"action": action, "dataDir": str(RUNTIME / "smoke-library"), **fields}
    started = time.monotonic()
    child = subprocess.Popen([sys.executable, str(ROOT / "worker/main.py")],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    child.stdin.write(json.dumps(request))
    child.stdin.close()
    result = None
    for line in child.stdout:
        event = json.loads(line)
        if event["event"] == "progress": print(event["message"], flush=True)
        elif event["event"] == "error": raise RuntimeError(event["message"])
        elif event["event"] == "result": result = event["data"]
    if child.wait() != 0 or result is None: raise RuntimeError("워커가 정상 종료하지 않았습니다.")
    print(f"{action}: {time.monotonic() - started:.2f}초", flush=True)
    return result


entry = run("create", title="자동 검증용 합성 음성", kind="meeting", audioPath=str(audio))
entry = run("transcribe", id=entry["id"])
assert entry["text"].strip(), "전사문이 비었습니다."
print(entry["text"], flush=True)
entry = run("summarize", id=entry["id"])
assert entry["summary"].strip(), "요약이 비었습니다."
print(entry["summary"], flush=True)
answer = run("ask", id=entry["id"], question="초안을 언제까지 완성하나요? 누가 문서를 작성하나요?")
assert answer["sources"] and all(s["entry_id"] == entry["id"] for s in answer["sources"])
print(answer["answer"], flush=True)
(RUNTIME / "smoke-result.json").write_text(json.dumps({"entry": entry, "answer": answer}, ensure_ascii=False, indent=2))
print("실제 모델 연결 검사 완료. 결과는 .runtime/smoke-result.json에 저장했습니다.", flush=True)
