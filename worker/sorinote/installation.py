"""사용자가 선택한 로컬 모델만 준비합니다. API 설정과 기존 기록은 바꾸지 않습니다."""
from . import audio
from .config import validate_profile, stage_enabled
from .providers import Provider


def install_models(config, secrets, progress):
    seen = set()
    for stage in ("asr", "embedding", "summary", "qa", "speaker"):
        if not stage_enabled(config, stage):
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
    return {"message": "사용 중인 로컬 모델을 준비했습니다. 꺼진 기능과 API 방식은 건너뜁니다."}

