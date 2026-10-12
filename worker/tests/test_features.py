"""메모리를 아끼려고 끈 기능이 모델·서버·색인에 접근하지 않는지 확인합니다."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from main import dispatch, dispatch_with_servers, diagnostic
from sorinote import audio
from sorinote.config import settings, stage_enabled
from sorinote.installation import install_models
from sorinote.intelligence import fingerprint
from sorinote.providers import Provider
from sorinote.store import Store


class OptionalFeatureTests(unittest.TestCase):
    def test_old_settings_keep_question_answering_enabled(self):
        config = settings({"qa": {"model": "custom-model"}})
        self.assertTrue(stage_enabled(config, "qa"))
        self.assertTrue(stage_enabled(config, "embedding"))
        self.assertFalse(stage_enabled(config, "speaker"))
        self.assertEqual(config["qa"]["model"], "custom-model")

    def test_model_preparation_skips_disabled_features_and_keeps_summary(self):
        config = settings({"qaEnabled": False, "diarization": False,
                           "qa": {"model": "other-answer"}, "embedding": {"provider": "ollama", "model": "other-embedding"}})
        pulled = []
        with patch("sorinote.installation.audio.prepare") as prepare, \
             patch.object(Provider, "pull", autospec=True, side_effect=lambda client, _: pulled.append(client.model)):
            install_models(config, {}, lambda _: None)
        self.assertEqual([call.args[3] for call in prepare.call_args_list], ["asr"])
        self.assertEqual(pulled, [config["summary"]["model"]])

    def test_speaker_can_stay_on_when_qa_is_off(self):
        config = settings({"qaEnabled": False, "diarization": True})
        with patch("sorinote.installation.audio.prepare") as prepare, patch.object(Provider, "pull"):
            install_models(config, {}, lambda _: None)
        self.assertEqual([call.args[3] for call in prepare.call_args_list], ["asr", "speaker"])

    def test_preparing_disabled_stage_cannot_load_or_download(self):
        config = settings({"qaEnabled": False, "diarization": False})
        with patch("sorinote.audio.model_path") as load, patch.object(Provider, "pull") as pull:
            for role in ("speaker", "embedding", "qa"):
                with self.subTest(role=role), self.assertRaisesRegex(ValueError, "꺼져"):
                    audio.prepare(config, {}, lambda _: None, role)
            load.assert_not_called(); pull.assert_not_called()
            audio.prepare(config, {}, lambda _: None)
            load.assert_called_once_with(config["asr"]["model"], True, "")

    def test_disabled_qa_is_blocked_before_network_server_and_storage(self):
        request = {"action": "ask", "config": {"qaEnabled": False}}
        with patch("sorinote.network.configure") as network, \
             patch("sorinote.local_server.managed_ollama") as server, patch("main.Store") as store:
            for route in (dispatch, dispatch_with_servers):
                with self.assertRaisesRegex(ValueError, "꺼져"):
                    route(request, lambda _: None)
            network.assert_not_called(); server.assert_not_called(); store.assert_not_called()

    def test_disabled_qa_worker_protocol_does_not_create_database(self):
        with tempfile.TemporaryDirectory() as folder:
            data = Path(folder) / "data"
            request = {"action": "ask", "config": {"qaEnabled": False}, "dataDir": str(data)}
            env = {**os.environ, "SORINOTE_SYSTEM_CERTS": "1", "SORINOTE_OLLAMA_BIN": "/missing/ollama"}
            result = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / "main.py")],
                                    input=json.dumps(request), text=True, capture_output=True, env=env, check=True)
            events = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(len(events), 1)
            self.assertEqual(events[0]["event"], "error")
            self.assertIn("꺼져", events[0]["message"])
            self.assertFalse(data.exists())

    def test_disabled_roles_do_not_start_model_servers_during_setup(self):
        config = {"qaEnabled": False, "summary": {"provider": "openai", "url": "http://localhost:1234/v1", "model": "summary"},
                  "embedding": {"provider": "ollama", "url": "http://127.0.0.1:11434", "model": "embedding"}}
        with patch("sorinote.network.configure"), patch("sorinote.local_server.managed_ollama") as server, \
             patch("main.dispatch", return_value={}) as work:
            dispatch_with_servers({"action": "install_models", "config": config}, lambda _: None)
        server.assert_not_called(); work.assert_called_once()

    def test_diagnostic_skips_disabled_models(self):
        config = settings({"qaEnabled": False, "diarization": False})
        client = Mock(kind="ollama")
        with patch("main.importlib.util.find_spec", return_value=object()) as find, \
             patch("sorinote.audio.model_path") as model, patch("sorinote.intelligence.provider", return_value=client) as provider:
            report = diagnostic(config, {})
        self.assertEqual([call.args[2] for call in provider.call_args_list], ["summary"])
        model.assert_called_once_with(config["asr"]["model"], token="")
        names = {item["name"] for item in report["checks"]}
        self.assertFalse(names.intersection({"qa", "embedding", "speaker", "pyannote.audio", "sentence_transformers"}))
        self.assertNotIn("pyannote.audio", [call.args[0] for call in find.call_args_list])

    def test_transcription_without_diarization_preserves_plain_text(self):
        with tempfile.TemporaryDirectory() as folder:
            store = Store(folder)
            source = Path(folder) / "test.wav"
            source.write_bytes(b"synthetic-placeholder")
            entry = store.create("회의", "meeting", audio_path=str(source))
            plain = [{"start": 0, "end": 1, "text": "안녕하세요", "speaker": "미지정"}]
            with patch("sorinote.audio.transcribe", return_value=([], [], plain, "안녕하세요")), \
                 patch("sorinote.audio.diarize") as diarize:
                result = dispatch({"action": "transcribe", "config": {"diarization": False, "qaEnabled": False},
                                   "dataDir": folder, "id": entry["id"]}, lambda _: None)
            self.assertEqual(result["text"], "안녕하세요")
            diarize.assert_not_called()
            store.db.close()

    def test_toggle_does_not_change_index_fingerprint_or_existing_records(self):
        config = settings()
        original = fingerprint(config, "본문")
        with tempfile.TemporaryDirectory() as folder:
            store = Store(folder)
            entry = store.create("문서", text="보존할 본문")
            store.update(entry["id"], summary="보존할 요약")
            store.replace_chunks(entry["id"], ["보존할 본문"], [[1, 0]], original)
            before = (store.get(entry["id"]), store.chunks(entry["id"]))
            config["qaEnabled"] = False
            with self.assertRaises(ValueError):
                dispatch({"action": "ask", "config": config, "dataDir": folder, "id": entry["id"]}, lambda _: None)
            self.assertEqual((store.get(entry["id"]), store.chunks(entry["id"])), before)
            config["qaEnabled"] = True
            self.assertEqual(fingerprint(config, "본문"), original)
            with patch("sorinote.intelligence.answer", return_value={"answer": "다시 켬", "sources": []}) as answer:
                result = dispatch({"action": "ask", "config": config, "dataDir": folder,
                                   "id": entry["id"], "question": "질문"}, lambda _: None)
            answer.assert_called_once()
            self.assertEqual(result["answer"], "다시 켬")
            store.db.close()


if __name__ == "__main__":
    unittest.main()
