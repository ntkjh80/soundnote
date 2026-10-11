"""모델 교체 시 데이터 경계와 음성 API 계약을 확인합니다. 실제 모델 다운로드는 하지 않습니다."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sorinote.audio import transcribe, diarize, prepare, timed_segments
from sorinote.config import settings, validate_profile
from sorinote.intelligence import provider, embedding_input, fingerprint
from sorinote.local_embedding import LocalEmbedder
from sorinote.providers import Provider, validate_vectors


class ModelSelectionTests(unittest.TestCase):
    def test_defaults_and_legacy_voice(self):
        c = settings({"asrModel": "custom/whisper", "diarizationModel": "custom/speaker"})
        self.assertEqual(c["asr"]["model"], "custom/whisper")
        self.assertEqual(c["speaker"]["model"], "custom/speaker")
        self.assertEqual(c["summary"]["model"], "gemma4:e4b")
        self.assertEqual(c["qa"]["model"], "gemma4:e4b")
        self.assertEqual(c["embedding"]["model"], "google/embeddinggemma-2")
        self.assertIsInstance(provider(c, {}, "embedding"), LocalEmbedder)

    def test_every_stage_can_use_compatible_server_and_own_key(self):
        for role in ("asr", "speaker", "summary", "embedding", "qa"):
            c = settings({role: {"provider": "openai", "url": "http://localhost:1234/v1", "model": role}})
            client = provider(c, {role + "Key": "stage-secret", "wrongKey": "other"}, role)
            self.assertIsInstance(client, Provider)
            self.assertEqual(client.key, "stage-secret")
            self.assertEqual(client.model, role)

    def test_invalid_role_provider_rejected(self):
        for role, kind in (("asr", "ollama"), ("speaker", "mlx"), ("embedding", "pyannote")):
            with self.assertRaises(ValueError): validate_profile(role, {"provider": kind, "model": "x"})

    def test_embedding_prompts_are_explicit_and_fingerprinted(self):
        c = settings()
        self.assertEqual(embedding_input(c, "질문", query=True), "task: search result | query: 질문")
        self.assertEqual(embedding_input(c, "본문", title="제목"), "title: 제목 | text: 본문")
        old = fingerprint(c, "본문")
        c["embedding"]["promptStyle"] = "plain"
        self.assertEqual(embedding_input(c, "본문"), "본문")
        self.assertNotEqual(old, fingerprint(c, "본문"))
        c["embedding"].update(model="server-alias", promptStyle="embeddinggemma")
        self.assertIn("task: search result", embedding_input(c, "질문", query=True))

    def test_prepare_downloads_only_selected_stage(self):
        with patch("sorinote.audio.model_path") as load:
            prepare(settings(), {"hfToken": "test"}, lambda _: None, "embedding")
        load.assert_called_once_with("google/embeddinggemma-2", True, "test")

    def test_local_embedder_normalizes_without_double_prompt(self):
        class Array:
            def tolist(self): return [[1., 0.]]
        class Engine:
            def encode(self, texts, **kwargs):
                self.kwargs = kwargs; self.texts = texts
                return Array()
        client = LocalEmbedder(settings()["embedding"])
        client.engine = Engine()
        self.assertEqual(client.embed(["task: search result | query: 내용"]), [[1., 0.]])
        self.assertEqual(client.engine.kwargs["prompt"], "")
        self.assertTrue(client.engine.kwargs["normalize_embeddings"])


class AudioAPITests(unittest.TestCase):
    def setUp(self):
        self.config = settings({"asr": {"provider": "openai", "url": "http://localhost:1234/v1", "model": "whisper-1"},
                                "speaker": {"provider": "openai", "url": "http://localhost:1234/v1", "model": "speaker"}})

    def test_multipart_has_correct_route_format_and_private_filename(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "우리회사_비밀회의.wav"; path.write_bytes(b"RIFF-test")
            client = provider(self.config, {"speakerKey": "secret"}, "speaker")
            with patch.object(client, "send", return_value={}) as send:
                client.transcribe(path, "diarized_json", "ko")
            request = send.call_args.args[0]
            self.assertTrue(request.full_url.endswith("/v1/audio/transcriptions"))
            self.assertEqual(request.get_header("Authorization"), "Bearer secret")
            self.assertIn(b"chunking_strategy", request.data)
            self.assertIn(b"diarized_json", request.data)
            self.assertIn(b"RIFF-test", request.data)
            self.assertNotIn(path.name.encode(), request.data)
            self.assertNotIn(b"secret", request.data)
            boundary = request.get_header("Content-type").split("boundary=")[1]
            self.assertTrue(request.data.endswith(("--" + boundary + "--\r\n").encode()))

    def test_remote_audio_blocked_before_reading_file(self):
        self.config["asr"]["url"] = "https://example.org/v1"
        with patch("pathlib.Path.read_bytes") as read:
            with self.assertRaises(ValueError): transcribe("missing.wav", self.config, {}, lambda _: None)
        read.assert_not_called()

    def test_oversized_audio_rejected_before_payload_read(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "large.wav"
            with path.open("wb") as f: f.truncate(25_000_001)
            with patch("pathlib.Path.read_bytes") as read:
                with self.assertRaises(ValueError): provider(self.config, {}, "asr").transcribe(path)
            read.assert_not_called()

    def test_json_only_does_not_fabricate_timing(self):
        with patch.object(Provider, "transcribe", return_value={"text": "시각 없는 본문"}):
            wave, raw, segments, text = transcribe("unused.wav", self.config, {}, lambda _: None)
        self.assertIsNone(wave); self.assertEqual(raw, []); self.assertEqual(segments, [])
        self.assertEqual(text, "시각 없는 본문")
        with self.assertRaisesRegex(ValueError, "시각 정보"):
            diarize(wave, raw, self.config, {}, lambda _: None, "unused.wav")

    def test_speaker_api_preserves_asr_words(self):
        raw = [{"start": 0., "end": 2., "text": "원래 발언"}, {"start": 3., "end": 5., "text": "두 번째 발언"}]
        result = {"segments": [{**raw[0], "text": "다른 내용", "speaker": "A"}, {**raw[1], "speaker": "B"}]}
        with patch.object(Provider, "transcribe", return_value=result) as call:
            labeled = diarize(None, raw, self.config, {}, lambda _: None, "test.wav")
        self.assertEqual([s["text"] for s in labeled], ["원래 발언", "두 번째 발언"])
        self.assertEqual([s["speaker"] for s in labeled], ["화자 1", "화자 2"])
        call.assert_called_once_with("test.wav", "diarized_json", "ko")

    def test_invalid_timing_and_missing_speaker_rejected(self):
        for segment in ({"start": 0, "end": float("nan")}, {"start": -1, "end": 2}, {"start": 2, "end": 1}):
            with self.assertRaises(ValueError): timed_segments({"segments": [segment]})
        with self.assertRaises(ValueError): timed_segments({"segments": [{"start": 0, "end": 2}]}, True)
        with self.assertRaises(ValueError): timed_segments({"text": "화자 없는 본문"}, True)

if __name__ == "__main__": unittest.main()
