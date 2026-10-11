#!/usr/bin/env python3
"""stdin으로 요청 하나를 받고 stdout으로 진행 알림과 결과를 내보냅니다.

토큰을 실행 인자나 디스크에 남기지 않기 위해 JSON 파이프를 사용합니다.
모델 라이브러리의 일반 출력은 stderr로 보내 통신 메시지와 섞이지 않게 합니다.
"""
import contextlib
import importlib.util
import json
import os
import signal
import sys
from pathlib import Path

from sorinote.config import settings, validate_profile
from sorinote.store import Store
from sorinote import audio, intelligence


def diagnostic(config, secrets):
    checks = [{"name": "Python", "ok": sys.version_info >= (3, 10),
               "detail": sys.version.split()[0] + " · " + sys.executable}]
    for name in ("mlx_whisper", "pyannote.audio", "imageio_ffmpeg", "huggingface_hub", "sentence_transformers", "transformers"):
        try:
            exists = importlib.util.find_spec(name) is not None
        except ModuleNotFoundError:
            exists = False
        checks.append({"name": name, "ok": exists,
                       "detail": "설치됨" if exists else "공통 환경의 자동 설치 / 복구를 실행하세요. 소스 빌드는 scripts/setup.sh를 사용할 수 있습니다."})
    for role in ("asr", "speaker", "summary", "qa", "embedding"):
        if role == "speaker" and not config["diarization"]:
            continue
        try:
            profile = config[role]
            validate_profile(role, profile, config["allowRemote"])
            if profile["provider"] in ("mlx", "pyannote", "sentence_transformers"):
                audio.model_path(profile["model"], token=secrets.get("hfToken", ""))
                checks.append({"name": role, "ok": True, "detail": "로컬 캐시 확인 · 실제 추론 검사는 별도입니다."})
                continue
            client = intelligence.provider(config, secrets, role)
            if client.kind == "ollama":
                client.check_local_model()
                client.request("/api/show", {"model": client.model})
            else:
                client.request("/models")
            checks.append({"name": role, "ok": True, "detail": "서버 목록 API 연결 확인 · 실제 단계 지원 여부는 처리 시 확인합니다. " + client.model})
        except Exception as error:
            checks.append({"name": role, "ok": False, "detail": str(error)})
    return {"checks": checks}


def dispatch(request, progress):
    config = settings(request.get("config"))
    secrets = request.get("secrets", {})
    action = request["action"]
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
    os.environ["DO_NOT_TRACK"] = "1"
    if action in ("prepare", "install_models"):
        os.environ.pop("HF_HUB_OFFLINE", None)
        if action == "install_models":
            from sorinote.installation import install_models
            return install_models(config, secrets, progress)
        return audio.prepare(config, secrets, progress, request.get("role"))
    os.environ["HF_HUB_OFFLINE"] = "1"
    if action == "diagnostic":
        return diagnostic(config, secrets)
    store = Store(request["dataDir"])
    try:
        entry_id = request.get("id", "")
        if action == "list":
            return {"entries": store.list()}
        if action == "get":
            return store.get(entry_id)
        if action == "create":
            return store.create(request.get("title", ""), request.get("kind", "document"),
                                request.get("text", ""), request.get("audioPath", ""))
        if action == "delete":
            return store.delete(entry_id)
        if action == "edit":
            values = {key: request[key] for key in ("title", "text", "segments") if key in request}
            if "text" in values and "segments" not in values:
                values["segments"] = []  # 수동 편집 뒤에는 이전 시각 정보를 남기지 않습니다.
            if len(values.get("text", "")) > 2_000_000:
                raise ValueError("본문은 200만 글자 이내로 입력하세요.")
            return store.update(entry_id, **values)
        if action == "renameSpeaker":
            entry = store.get(entry_id)
            new = request["new"].strip()[:40]
            if not new:
                raise ValueError("화자 이름을 입력해 주세요.")
            for segment in entry["segments"]:
                if segment["speaker"] == request["old"]:
                    segment["speaker"] = new
            return store.update(entry_id, segments=entry["segments"], text=audio.transcript_text(entry["segments"]))
        if action == "transcribe":
            entry = store.get(entry_id)
            if not entry["audio_path"]:
                raise ValueError("이 항목에는 녹음 파일이 없습니다.")
            waveform, raw, plain, text = audio.transcribe(entry["audio_path"], config, secrets, progress)
            # 화자 분리가 실패하거나 취소되어도 완료된 전사문은 복구할 수 있습니다.
            store.update(entry_id, segments=plain, text=text, warning="")
            if config["diarization"]:
                try:
                    labeled = audio.diarize(waveform, raw, config, secrets, progress, entry["audio_path"])
                    store.update(entry_id, segments=labeled, text=audio.transcript_text(labeled))
                except Exception as error:
                    store.update(entry_id, warning="문자 변환은 완료했지만 화자 분리는 실패했습니다. "
                        + (str(error) if isinstance(error, ValueError) else "화자 모델 준비, 토큰 또는 API의 diarized_json 지원 여부를 확인하세요."))
            return store.get(entry_id)
        if action == "summarize":
            entry = store.get(entry_id)
            result = intelligence.summarize(entry["text"], intelligence.provider(config, secrets, "summary"), progress)
            return store.update(entry_id, summary=result)
        if action == "ask":
            return intelligence.answer(store, request["question"], entry_id, config, secrets, progress)
        if action == "reindex":
            with store.db:
                store.db.execute("DELETE FROM chunks")
            return {"message": "검색 색인을 비웠습니다. 다음 질문에서 현재 모델로 다시 만듭니다."}
        raise ValueError("지원하지 않는 작업입니다.")
    finally:
        store.db.close()


def main():
    os.umask(0o077)
    output = sys.stdout

    def emit(value):
        print(json.dumps(value, ensure_ascii=False, allow_nan=False), file=output, flush=True)

    def stop(*_):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, stop)
    try:
        request = json.load(sys.stdin)
        with contextlib.redirect_stdout(sys.stderr):
            result = dispatch(request, lambda message: emit({"event": "progress", "message": message}))
        emit({"event": "result", "data": result})
    except KeyboardInterrupt:
        emit({"event": "error", "message": "작업을 취소했습니다."})
    except ModuleNotFoundError:
        emit({"event": "error", "message": "AI 실행 엔진이 설치되지 않았습니다. 공통 환경에서 자동 설치 / 복구를 실행하세요. 소스 빌드는 scripts/setup.sh를 사용할 수 있습니다."})
    except Exception as error:
        message = str(error) if isinstance(error, ValueError) else (
            "처리하지 못했습니다. 모델 준비, 파일 형식, 엔진 설치 상태를 확인하세요. 오류 종류: " + type(error).__name__)
        emit({"event": "error", "message": message})


if __name__ == "__main__":
    main()
