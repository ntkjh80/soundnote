"""사용자가 선택한 로컬 모델만 준비합니다. API 설정과 기존 기록은 바꾸지 않습니다."""
from . import audio
from .config import validate_profile
from .providers import Provider


def install_models(config, secrets, progress):
    seen = set()
    for stage in ("asr", "embedding", "summary", "qa", "speaker"):
        if stage == "speaker" and not config["diarization"]:
            continue
        profile = config[stage]
        if profile["provider"] == "openai":
            continue  # API 서버에 모델 설치 요청을 보내지 않습니다.
        validate_profile(stage, profile, config["allowRemote"])
        identity = (profile["provider"], profile.get("url", ""), profile["model"])
        if identity in seen:
            continue
        seen.add(identity)
        if profile["provider"] == "ollama":
            # 자동 다운로드 대상은 맥 안의 서버로 한정합니다.
            client = Provider(profile, False, secrets.get(stage + "Key", ""))
            client.pull(progress)
        else:
            audio.prepare(config, secrets, progress, stage)
    return {"message": "선택한 로컬 모델을 준비했습니다. API 방식은 지정한 서버를 그대로 사용합니다."}

