"""다운로드 없이 설치 대상 선택, 서버 소유권과 실패 정리를 검사합니다."""
import io
import os
import signal
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sorinote.config import settings
from sorinote.installation import install_models
from sorinote.local_server import managed_ollama
from sorinote.providers import Provider


class InstallationTests(unittest.TestCase):
    def test_default_models_deduplicated_and_speaker_opt_in(self):
        with patch("sorinote.installation.audio.prepare") as prepare, patch.object(Provider, "pull") as pull:
            config = settings()
            install_models(config, {}, lambda _: None)
            self.assertEqual([call.args[3] for call in prepare.call_args_list], ["asr", "embedding"])
            self.assertEqual(pull.call_count, 1)
            prepare.reset_mock()
            config["diarization"] = True
            install_models(config, {}, lambda _: None)
            self.assertEqual([call.args[3] for call in prepare.call_args_list], ["asr", "embedding", "speaker"])

    def test_api_profiles_skipped_without_changes(self):
        config = settings({role: {"provider": "openai", "url": "https://example.org/v1", "model": "custom"}
                           for role in ("asr", "speaker", "embedding", "summary", "qa")})
        config["allowRemote"] = True
        with patch("sorinote.installation.audio.prepare") as prepare, patch.object(Provider, "pull") as pull:
            install_models(config, {}, lambda _: None)
            prepare.assert_not_called(); pull.assert_not_called()
            self.assertEqual(config["embedding"]["model"], "custom")

    @patch.dict(os.environ, {"SORINOTE_OLLAMA_BIN": "/fake/ollama"})
    def test_existing_server_not_stopped(self):
        with patch("sorinote.local_server.available", return_value=True), \
             patch("sorinote.local_server.subprocess.Popen") as start, patch("sorinote.local_server.os.killpg") as stop:
            with managed_ollama("http://127.0.0.1:11434"):
                pass
            start.assert_not_called(); stop.assert_not_called()

    @patch.dict(os.environ, {"SORINOTE_OLLAMA_BIN": "/fake/ollama"})
    def test_custom_address_not_started(self):
        with patch("sorinote.local_server.subprocess.Popen") as start:
            for base in ("http://127.0.0.1:1234", "https://example.org", "http://127.0.0.1:11434/proxy"):
                with managed_ollama(base):
                    pass
            start.assert_not_called()

    @patch.dict(os.environ, {"SORINOTE_OLLAMA_BIN": "/fake/ollama", "OLLAMA_HOST": "0.0.0.0:11434"})
    def test_owned_server_stopped_even_on_cancel(self):
        process = Mock(pid=4242)
        with patch("sorinote.local_server.available", side_effect=[False, True]), \
             patch("sorinote.local_server.subprocess.Popen", return_value=process) as start, \
             patch("sorinote.local_server.os.killpg") as stop:
            with self.assertRaises(KeyboardInterrupt):
                with managed_ollama("http://127.0.0.1:11434"):
                    raise KeyboardInterrupt()
            self.assertTrue(start.call_args.kwargs["start_new_session"])
            self.assertEqual(start.call_args.kwargs["env"]["OLLAMA_HOST"], "127.0.0.1:11434")
            self.assertEqual(start.call_args.kwargs["env"]["OLLAMA_NO_CLOUD"], "1")
            stop.assert_called_once_with(4242, signal.SIGTERM)

    @patch.dict(os.environ, {"SORINOTE_OLLAMA_BIN": "/fake/ollama"})
    def test_start_failure_is_cleaned_up(self):
        process = Mock(pid=4242); process.poll.return_value = 1
        with patch("sorinote.local_server.available", return_value=False), \
             patch("sorinote.local_server.subprocess.Popen", return_value=process), \
             patch("sorinote.local_server.os.killpg") as stop:
            with self.assertRaisesRegex(ValueError, "시작되지"):
                with managed_ollama("http://127.0.0.1:11434"):
                    pass
            stop.assert_called_once_with(4242, signal.SIGTERM)

    @patch.dict(os.environ, {"SORINOTE_OLLAMA_BIN": ""})
    def test_pull_requires_success_before_ready(self):
        client = Provider(settings()["summary"])
        opener = Mock()
        with patch("sorinote.providers.urllib.request.build_opener", return_value=opener), \
             patch.object(client, "check_local_model") as check:
            opener.open.return_value = io.BytesIO(b'{"status":"downloading","total":100,"completed":50}\n')
            with self.assertRaisesRegex(ValueError, "완료되기"):
                client.pull(lambda _: None)
            check.assert_not_called()
            opener.open.return_value = io.BytesIO(b'{"status":"success"}\n')
            client.pull(lambda _: None)
            check.assert_called_once()

    def test_remote_pull_rejected(self):
        client = Provider({"provider": "ollama", "url": "https://example.org", "model": "custom"}, True)
        with self.assertRaisesRegex(ValueError, "로컬"):
            client.pull(lambda _: None)


if __name__ == "__main__":
    unittest.main()
