"""회사 인증서·오프라인 준비·민감 정보 없는 오류 분류를 검사합니다."""
import os
import io
import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sorinote.network import configure, failure_hint
from sorinote.providers import Provider
from sorinote.config import settings
from sorinote import audio
from main import dispatch, main


class NetworkTests(unittest.TestCase):
    @patch.dict(os.environ, {"SORINOTE_SYSTEM_CERTS": "1"}, clear=True)
    def test_native_certificates_injected(self):
        library = SimpleNamespace(inject_into_ssl=Mock())
        with patch.dict(sys.modules, {"truststore": library}):
            configure()
        library.inject_into_ssl.assert_called_once()

    @patch.dict(os.environ, {"SORINOTE_SYSTEM_CERTS": "1", "SSL_CERT_FILE": "/company/ca.pem"}, clear=True)
    def test_custom_bundle_precedes_native_injection(self):
        library = SimpleNamespace(inject_into_ssl=Mock())
        with patch.dict(sys.modules, {"truststore": library}):
            configure()
        library.inject_into_ssl.assert_not_called()
        self.assertEqual(os.environ["REQUESTS_CA_BUNDLE"], "/company/ca.pem")

    @patch.dict(os.environ, {"SORINOTE_OFFLINE": "1"}, clear=True)
    def test_offline_prepare_does_not_clear_hub_offline(self):
        configure()
        with patch.object(audio, "prepare", return_value={}) as prepare:
            dispatch({"action": "prepare"}, lambda _: None)
        prepare.assert_called_once()
        self.assertEqual(os.environ["HF_HUB_OFFLINE"], "1")

    @patch.dict(os.environ, {"SORINOTE_OFFLINE": "1"}, clear=True)
    def test_ollama_offline_checks_without_pull(self):
        client = Provider(settings()["summary"])
        with patch.object(client, "check_local_model") as check, patch("urllib.request.build_opener") as opener:
            client.pull(lambda _: None)
        check.assert_called_once()
        opener.assert_not_called()

    @patch.dict(os.environ, {"SORINOTE_OFFLINE": "1"}, clear=True)
    def test_huggingface_offline_never_downloads(self):
        class HubError(Exception):
            pass
        snapshot = Mock(return_value="/cached/model")
        errors = SimpleNamespace(LocalEntryNotFoundError=HubError, GatedRepoError=HubError, RepositoryNotFoundError=HubError)
        with patch.dict(sys.modules, {"huggingface_hub": SimpleNamespace(snapshot_download=snapshot), "huggingface_hub.errors": errors}):
            self.assertEqual(audio.model_path("example/model", True), "/cached/model")
        self.assertTrue(snapshot.call_args.kwargs["local_files_only"])

    def test_error_classification_does_not_leak_secrets(self):
        for raw, expected in [("SSL certificate: https://user:secret@example.org?token=x", "인증서"),
                              ("407 proxy authentication password=secret", "프록시"), ("403 forbidden token=secret", "접근"),
                              ("Connection timeout secret", "연결")]:
            message = failure_hint(RuntimeError(raw))
            self.assertIn(expected, message)
            self.assertNotIn("secret", message)
        self.assertIsNone(failure_hint(RuntimeError("unrelated secret")))

    @patch.dict(os.environ, {}, clear=True)
    def test_local_server_error_keeps_its_specific_message(self):
        message = "모델 서버에 연결할 수 없습니다. Ollama 실행 상태와 서버 주소를 확인하세요."
        output = io.StringIO()
        with patch("sys.stdin", io.StringIO('{"action":"summarize"}')), patch("sys.stdout", output), \
             patch("main.dispatch", side_effect=ValueError(message)):
            main()
        self.assertEqual(json.loads(output.getvalue().splitlines()[-1])["message"], message)

    def test_nested_certificate_error_is_detected(self):
        error = RuntimeError("request failed")
        error.__cause__ = RuntimeError("CERTIFICATE_VERIFY_FAILED")
        self.assertIn("인증서", failure_hint(error))


if __name__ == "__main__":
    unittest.main()
