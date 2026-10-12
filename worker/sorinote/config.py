"""설정의 기본값과 네트워크 경계를 한곳에서 관리합니다."""
import copy
import ipaddress
from urllib.parse import urlsplit


DEFAULTS = {
    "settingsVersion": 2,
    "asr": {"provider": "mlx", "url": "", "model": "mlx-community/whisper-large-v3-turbo", "responseFormat": "verbose_json"},
    "speaker": {"provider": "pyannote", "url": "", "model": "pyannote/speaker-diarization-community-1"},
    "diarization": False,
    "qaEnabled": True,
    "intervalSummaryEnabled": False,
    "intervalMinutes": 5,
    "intervalFinalSummary": True,
    "speakerCount": 0,
    "language": "ko",
    "allowRemote": False,
    "summary": {"provider": "ollama", "url": "http://127.0.0.1:11434", "model": "gemma4:e4b"},
    "qa": {"provider": "ollama", "url": "http://127.0.0.1:11434", "model": "gemma4:e4b"},
    "embedding": {"provider": "sentence_transformers", "url": "", "model": "google/embeddinggemma-2", "device": "auto", "promptStyle": "auto"},
}

PROVIDERS = {"asr": {"mlx", "openai"}, "speaker": {"pyannote", "openai"},
             "summary": {"ollama", "openai"}, "qa": {"ollama", "openai"},
             "embedding": {"sentence_transformers", "ollama", "openai"}}


def settings(value=None):
    """일부 항목만 전달해도 나머지 역할의 기본값을 유지합니다."""
    result = copy.deepcopy(DEFAULTS)
    for key, item in (value or {}).items():
        if key in PROVIDERS:
            result[key].update(item)
        else:
            result[key] = item
    # 0.1 설정 파일과 기존 스크립트도 읽되, 명시한 새 프로필을 우선합니다.
    for old, stage in (("asrModel", "asr"), ("diarizationModel", "speaker")):
        if old in (value or {}) and stage not in (value or {}):
            result[stage]["model"] = value[old]
    return result


def stage_enabled(config, role):
    """전환 설정은 준비·진단·서버 시작에서 공통으로 사용합니다. 저장된 모델 설정은 지우지 않습니다."""
    if role == "speaker":
        return config.get("diarization", False)
    if role in ("qa", "embedding"):
        return config.get("qaEnabled", True)
    return True


def require_action_enabled(config, action):
    # UI를 거치지 않는 워커 요청도 모델·서버·색인에 접근하기 전에 막습니다.
    if action == "ask" and not stage_enabled(config, "qa"):
        raise ValueError("질문 답변이 꺼져 있습니다. 모델 및 환경 설정에서 다시 켜 주세요.")


def validate_profile(role, profile, allow_remote=False):
    if role not in PROVIDERS or profile.get("provider") not in PROVIDERS[role]:
        raise ValueError("이 단계에서 지원하지 않는 실행 방식입니다.")
    if not isinstance(profile.get("model"), str) or not profile["model"].strip():
        raise ValueError("모델 이름을 입력해 주세요.")
    if profile["provider"] in ("ollama", "openai"):
        validate_endpoint(profile.get("url", ""), allow_remote)
    if role == "asr" and profile["provider"] == "openai" and profile.get("responseFormat", "verbose_json") not in ("json", "verbose_json"):
        raise ValueError("음성 인식 API 응답 형식은 json 또는 verbose_json을 선택하세요.")
    if role == "embedding" and profile.get("promptStyle", "auto") not in ("auto", "embeddinggemma", "plain"):
        raise ValueError("검색 입력 형식을 확인하세요.")
    if role == "embedding" and profile.get("device", "auto") not in ("auto", "cpu", "mps"):
        raise ValueError("로컬 임베딩 장치는 자동, CPU, Apple GPU 중에서 선택하세요.")


def validate_endpoint(url, allow_remote=False):
    """로컬 전용 모드에서는 루프백 주소만 허용합니다. 우회 주소는 받지 않습니다."""
    parsed = urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("서버 주소는 http:// 또는 https://로 시작해야 합니다.")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("서버 주소에 비밀번호, 쿼리, # 기호를 넣을 수 없습니다.")
    host = parsed.hostname.lower()
    local = host == "localhost"
    try:
        local = local or ipaddress.ip_address(host).is_loopback
    except ValueError:
        pass
    if not local and not allow_remote:
        raise ValueError("로컬 전용 모드입니다. 외부 서버를 쓰려면 설정에서 외부 전송을 허용하세요.")
    if not local and parsed.scheme != "https":
        raise ValueError("외부 서버에는 HTTPS 주소만 사용할 수 있습니다.")
    # localhost는 이름 해석을 거치지 않고 루프백에 고정합니다.
    if host == "localhost":
        url = parsed._replace(netloc="127.0.0.1" + (f":{parsed.port}" if parsed.port else "")).geturl()
    return url.rstrip("/"), local
