"""음성 인식과 화자 분리는 모델을 차례대로 사용해 메모리 피크를 낮춥니다."""
import gc
import math
import os
import subprocess
from pathlib import Path


def model_path(name, download=False, token=""):
    path = Path(name).expanduser()
    if path.is_dir():
        return str(path.resolve())
    if path.is_absolute():
        raise ValueError("설정한 로컬 모델 폴더가 없습니다. 모델 경로를 확인해 주세요.")
    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError, GatedRepoError, RepositoryNotFoundError
    try:
        return snapshot_download(repo_id=name, token=token or None, local_files_only=not download or os.environ.get("SORINOTE_OFFLINE") == "1")
    except LocalEntryNotFoundError:
        raise ValueError("저장된 모델을 찾지 못했습니다. 설정을 저장한 뒤 해당 단계의 '모델 다운로드 / 준비'를 실행하세요.") from None
    except GatedRepoError:
        raise ValueError("모델 접근 승인이 필요합니다. Hugging Face에서 이용 조건에 동의하고 읽기 토큰을 설정하세요.") from None
    except RepositoryNotFoundError:
        raise ValueError("모델 저장소에 접근하지 못했습니다. 모델 ID와 Hugging Face 토큰을 확인하세요.") from None


def prepare(config, secrets, progress, role=None):
    """모델 다운로드는 사용자가 준비 버튼을 눌렀을 때만 허용합니다."""
    from .config import validate_profile, stage_enabled
    roles = [role] if role else ["asr", "embedding"] + (["speaker"] if config["diarization"] else [])
    for stage in roles:
        if stage not in ("asr", "speaker", "embedding", "summary", "qa"):
            raise ValueError("지원하지 않는 모델 단계입니다.")
        if not stage_enabled(config, stage):
            if role:
                raise ValueError("이 기능은 꺼져 있습니다. 모델 및 환경 설정에서 켠 뒤 준비하세요.")
            continue
        profile = config[stage]
        validate_profile(stage, profile, config["allowRemote"])
        if profile["provider"] in ("mlx", "pyannote", "sentence_transformers"):
            progress(profile["model"] + (" 로컬 캐시 확인 중" if os.environ.get("SORINOTE_OFFLINE") == "1" else " 다운로드 중 · 이용 조건 동의가 필요할 수 있습니다"))
            model_path(profile["model"], True, secrets.get("hfToken", ""))
        elif profile["provider"] == "ollama":
            from .providers import Provider
            Provider(profile, False, secrets.get(stage + "Key", "")).pull(progress)
    return {"message": "로컬 모델 준비가 끝났습니다. 이후 처리는 캐시된 모델만 사용합니다."}


def decode_audio(path):
    import imageio_ffmpeg
    import numpy as np
    command = [imageio_ffmpeg.get_ffmpeg_exe(), "-nostdin", "-v", "error", "-i", path,
               "-t", "14401", "-f", "f32le", "-ac", "1", "-ar", "16000", "pipe:1"]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        output, _ = process.communicate(timeout=600)
        if process.returncode:
            raise ValueError("음성 파일을 읽을 수 없습니다. WAV, M4A, MP3 파일인지 확인하세요.")
    except BaseException:
        process.kill()
        process.wait()
        raise
    audio = np.frombuffer(output, dtype=np.float32).copy()
    if len(audio) > 16000 * 14400:
        raise ValueError("4시간이 넘는 녹음은 여러 파일로 나누어 주세요.")
    if len(audio) < 1600:
        raise ValueError("녹음이 너무 짧거나 비어 있습니다.")
    return audio


def assign_speakers(segments, turns):
    """단어와 가장 오래 겹치는 화자를 배정합니다. 겹침이 없으면 '미확인'입니다."""
    output, names = [], {}
    for segment in segments:
        units = segment.get("words") or [segment]
        for unit in units:
            start, end = float(unit["start"]), float(unit["end"])
            overlaps = {}
            for a, b, speaker in turns:
                duration = max(0, min(end, b) - max(start, a))
                overlaps[speaker] = overlaps.get(speaker, 0) + duration
            best = max(overlaps, key=overlaps.get) if overlaps else None
            if best is None or overlaps[best] <= 0:
                name = "미확인"
            else:
                if best not in names:
                    names[best] = f"화자 {len(names) + 1}"
                name = names[best]
            content = unit.get("word", unit.get("text", ""))
            if not content.strip():
                continue
            if (output and output[-1]["speaker"] == name and start - output[-1]["end"] < 1.2
                    and end - output[-1]["start"] < 25):
                output[-1]["text"] += (" " if not segment.get("words") and not content.startswith(" ") else "") + content
                output[-1]["end"] = end
            else:
                output.append({"start": start, "end": end, "speaker": name, "text": content})
    for item in output:
        item["text"] = item["text"].strip()
    return output


def transcribe(path, config, secrets, progress):
    from .config import validate_profile
    from .providers import Provider
    profile = config["asr"]
    validate_profile("asr", profile, config["allowRemote"])
    if profile["provider"] == "openai":
        progress("선택한 음성 인식 API에서 문자 변환 중")
        client = Provider(profile, config["allowRemote"], secrets.get("asrKey", ""))
        result = client.transcribe(path, profile.get("responseFormat", "verbose_json"), config["language"])
        segments = [s for s in timed_segments(result) if s["text"].strip()]
        plain = [{**s, "speaker": "미지정"} for s in segments]
        text = transcript_text(plain) if plain else result.get("text", "").strip()
        if not text:
            raise ValueError("음성 인식 API가 전사문을 반환하지 않았습니다.")
        # json 전사에는 시각이 없을 수 있습니다. 가짜 시각을 만들지 않고 본문만 저장합니다.
        return None, segments, plain, text
    progress("음성 인식 모델 확인 중")
    cached = model_path(profile["model"], token=secrets.get("hfToken", ""))
    import mlx_whisper
    import mlx.core as mx
    progress("음성을 16kHz 모노로 변환 중")
    waveform = decode_audio(path)
    progress("음성을 문자로 변환 중 · 긴 회의는 시간이 걸립니다")
    result = mlx_whisper.transcribe(waveform, path_or_hf_repo=cached,
        language=config["language"] or None, word_timestamps=True, verbose=None,
        condition_on_previous_text=False)
    segments = result.get("segments", [])
    # mlx-whisper의 전역 캐시도 비워야 다음 PyTorch 단계에 메모리를 양보할 수 있습니다.
    from mlx_whisper.transcribe import ModelHolder
    ModelHolder.model = None
    gc.collect()
    mx.clear_cache()
    plain = [{"start": s["start"], "end": s["end"], "text": s["text"].strip(),
              "speaker": "미지정"} for s in segments if s["text"].strip()]
    return waveform, segments, plain, transcript_text(plain)


def timed_segments(result, require_speakers=False):
    """서버가 준 시각을 검증합니다. 시각 없는 전사에는 화자를 임의로 붙이지 않습니다."""
    if not isinstance(result, dict) or not isinstance(result.get("text", ""), str):
        raise ValueError("음성 API 응답 형식을 확인하세요.")
    if not isinstance(result.get("segments", []), list):
        raise ValueError("음성 API의 구간 목록이 올바르지 않습니다.")
    output = []
    previous = -1
    for item in result.get("segments", []):
        if not isinstance(item, dict):
            raise ValueError("음성 API의 구간 형식이 올바르지 않습니다.")
        start, end = item.get("start"), item.get("end")
        if (not all(isinstance(v, (int, float)) and math.isfinite(v) for v in (start, end))
                or start < 0 or end <= start or start < previous):
            raise ValueError("음성 API가 올바른 구간 시각을 반환하지 않았습니다.")
        if require_speakers and (not isinstance(item.get("speaker"), str) or not item["speaker"].strip()):
            raise ValueError("화자 API가 화자 이름을 반환하지 않았습니다. diarized_json 지원 여부를 확인하세요.")
        if not isinstance(item.get("text", ""), str):
            raise ValueError("음성 API의 구간 본문이 올바르지 않습니다.")
        output.append({"start": start, "end": end, "text": item.get("text", ""),
                       "speaker": str(item.get("speaker", ""))})
        previous = start
    if require_speakers and not output:
        raise ValueError("화자 API가 화자 구간을 반환하지 않았습니다.")
    return output


def diarize(waveform, segments, config, secrets, progress, path=""):
    from .config import validate_profile
    from .providers import Provider
    if not segments:
        raise ValueError("화자 분리에는 시각 정보가 필요합니다. 음성 인식 API의 응답을 verbose_json으로 바꾸세요.")
    profile = config["speaker"]
    validate_profile("speaker", profile, config["allowRemote"])
    if profile["provider"] == "openai":
        progress("선택한 화자 분리 API에서 화자 구간 확인 중")
        client = Provider(profile, config["allowRemote"], secrets.get("speakerKey", ""))
        result = client.transcribe(path, "diarized_json", config["language"])
        turns = [(s["start"], s["end"], s["speaker"]) for s in timed_segments(result, True)]
        # 이 단계는 화자만 배정합니다. 앞 단계에서 확정한 전사문을 덮어쓰지 않습니다.
        return assign_speakers(segments, turns)
    progress("화자 분리 중 · CPU에서 실행하며 실시간 처리는 아닙니다")
    import torch
    from pyannote.audio import Pipeline
    cached = model_path(profile["model"], token=secrets.get("hfToken", ""))
    if waveform is None:
        waveform = decode_audio(path)
    pipeline = Pipeline.from_pretrained(cached, token=secrets.get("hfToken") or None)
    # MPS 연산 지원 차이에 의한 실패를 피하기 위해 화자 분리는 CPU를 기본으로 합니다.
    pipeline.to(torch.device("cpu"))
    count = int(config["speakerCount"])
    if not 0 <= count <= 30:
        raise ValueError("화자 수는 자동(0) 또는 1~30명으로 입력하세요.")
    kwargs = {"num_speakers": count} if count else {}
    result = pipeline({"waveform": torch.from_numpy(waveform).unsqueeze(0), "sample_rate": 16000}, **kwargs)
    annotation = result.exclusive_speaker_diarization
    turns = [(turn.start, turn.end, speaker) for turn, _, speaker in annotation.itertracks(yield_label=True)]
    return assign_speakers(segments, turns)


def transcript_text(segments):
    return "\n".join(f"[{int(s['start']) // 60:02d}:{int(s['start']) % 60:02d}] "
                     f"{s['speaker']}: {s['text']}" for s in segments)
