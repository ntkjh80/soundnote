"""다운로드 없이 개인정보 경계, 데이터 보존, 검색의 일관성을 검사합니다."""
import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from main import dispatch
from sorinote.audio import assign_speakers, transcript_text
from sorinote.config import settings, validate_endpoint
from sorinote.intelligence import answer, cosine, fingerprint, index_entry, split_text, summarize
from sorinote.providers import NoRedirect, Provider
from sorinote.store import Store


class PrivacyTests(unittest.TestCase):
    def test_local_addresses(self):
        for url in ("http://127.0.0.1:11434", "http://localhost:1234/v1", "http://[::1]:8080"):
            self.assertTrue(validate_endpoint(url)[1])
        self.assertEqual(validate_endpoint("http://localhost:11434")[0], "http://127.0.0.1:11434")

    def test_external_and_disguised_addresses_rejected(self):
        for url in ("http://192.168.1.10", "https://example.org", "http://127.0.0.1.example.org",
                    "http://user:pass@localhost", "file:///tmp/x", "http://2130706433",
                    "http://localhost?key=secret", "http://localhost#fragment", "http://0.0.0.0"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                validate_endpoint(url)

    def test_external_requires_https_even_after_opt_in(self):
        self.assertFalse(validate_endpoint("https://example.org/v1", True)[1])
        with self.assertRaises(ValueError): validate_endpoint("http://example.org", True)

    def test_redirect_does_not_forward_payload(self):
        with self.assertRaises(ValueError):
            NoRedirect().redirect_request(None, None, 307, "", {}, "https://example.org")

    def test_cloud_model_and_alias_are_rejected_before_generation(self):
        with self.assertRaises(ValueError):
            Provider({"provider": "ollama", "url": "http://localhost", "model": "gemma4:cloud"})
        client = Provider(settings()["summary"])
        with patch.object(client, "request", return_value={"remote_host": "https://ollama.com"}) as request:
            with self.assertRaises(ValueError): client.chat("", "회의 비밀")
            self.assertEqual(request.call_count, 1)
            self.assertEqual(request.call_args.args[0], "/api/show")

    def test_settings_merge_does_not_mutate_defaults(self):
        changed = settings({"summary": {"model": "test"}})
        self.assertEqual(changed["summary"]["url"], "http://127.0.0.1:11434")
        self.assertNotEqual(settings()["summary"]["model"], "test")


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name) / "library")

    def tearDown(self):
        self.store.db.close()
        self.temp.cleanup()

    def test_text_edit_invalidates_summary_and_vectors(self):
        entry = self.store.create("회의", text="처음 내용")
        self.store.update(entry["id"], summary="옛 요약")
        self.store.replace_chunks(entry["id"], ["처음"], [[1, 0]], "old")
        updated = self.store.update(entry["id"], text="새 내용")
        self.assertEqual(updated["summary"], "")
        self.assertEqual(self.store.chunks(entry["id"]), [])

    def test_deletion_removes_copy_but_keeps_original(self):
        original = Path(self.temp.name) / "sample.wav"
        original.write_bytes(b"not-real-audio")
        entry = self.store.create("녹음", "meeting", audio_path=str(original))
        self.store.replace_chunks(entry["id"], ["말"], [[1]], "a")
        self.store.delete(entry["id"])
        self.assertTrue(original.exists())
        self.assertFalse(Path(entry["audio_path"]).exists())
        self.assertEqual(self.store.chunks(entry["id"]), [])

    def test_bad_vector_batch_does_not_remove_old_index(self):
        entry = self.store.create("문서", text="내용")
        self.store.replace_chunks(entry["id"], ["내용"], [[1]], "old")
        with self.assertRaises(ValueError):
            self.store.replace_chunks(entry["id"], ["새 문단", "다른 문단"], [[1]], "new")
        self.assertEqual(self.store.chunks(entry["id"])[0]["fingerprint"], "old")

    def test_missing_and_invalid_fields(self):
        with self.assertRaises(ValueError): self.store.get("missing")
        entry = self.store.create("문서")
        with self.assertRaises(ValueError): self.store.update(entry["id"], audio_path="/tmp/other")

    def test_worker_preserves_transcript_on_diarization_failure(self):
        entry = self.store.create("녹음", "meeting")
        self.store.db.execute("UPDATE entries SET audio_path='example.wav' WHERE id=?", (entry["id"],))
        self.store.db.commit()
        segments = [{"start": 0, "end": 2, "text": "반갑습니다", "speaker": "미지정"}]
        with patch("main.audio.transcribe", return_value=([], segments, segments, transcript_text(segments))), \
             patch("main.audio.diarize", side_effect=RuntimeError("secret-token")):
            result = dispatch({"action": "transcribe", "dataDir": str(self.store.root),
                "id": entry["id"], "config": {"diarization": True}}, lambda _: None)
        self.assertIn("반갑습니다", result["text"])
        self.assertIn("화자 분리는 실패", result["warning"])
        self.assertNotIn("secret-token", result["warning"])

    def test_manual_edit_clears_stale_timing(self):
        entry = self.store.create("녹음")
        self.store.update(entry["id"], segments=[{"start": 1, "end": 2, "speaker": "A", "text": "전사"}])
        result = dispatch({"action": "edit", "dataDir": str(self.store.root), "id": entry["id"], "text": "수정"}, lambda _: None)
        self.assertEqual(result["segments"], [])


class SpeakerTests(unittest.TestCase):
    def test_word_boundary_and_unknown_are_preserved(self):
        segments = [{"start": 0, "end": 6, "text": "안녕 좋아요 모름", "words": [
            {"start": 0, "end": 1, "word": "안녕"}, {"start": 2, "end": 3, "word": " 좋아요"},
            {"start": 5, "end": 6, "word": " 모름"}]}]
        result = assign_speakers(segments, [(0, 1.5, "A"), (1.5, 3, "B")])
        self.assertEqual([s["speaker"] for s in result], ["화자 1", "화자 2", "미확인"])
        self.assertIn("[00:02] 화자 2: 좋아요", transcript_text(result))

    def test_repeated_speaker_overlap_is_summed(self):
        result = assign_speakers([{"start": 0, "end": 4, "text": "문장"}],
            [(0, 1, "A"), (1, 2.5, "B"), (2.5, 4, "A")])
        self.assertEqual(result[0]["speaker"], "화자 1")
        self.assertEqual(result[0]["text"], "문장")


class FakeEmbedder:
    def __init__(self): self.calls = 0
    def embed(self, texts):
        self.calls += 1
        return [[1.0, 0.5] for _ in texts]


class RetrievalTests(unittest.TestCase):
    def test_chunking_covers_tail_and_long_sentence(self):
        value = "가" * 1800 + "끝부분"
        chunks = split_text(value)
        self.assertTrue(chunks[-1].endswith("끝부분"))
        self.assertTrue(all(len(x) <= 700 for x in chunks))
        self.assertEqual(split_text(""), [])
        self.assertEqual(split_text("짧은 문장"), ["짧은 문장"])
        with self.assertRaises(ValueError): split_text("x", 10, 10)

    def test_fingerprint_changes_for_model_endpoint_and_text(self):
        base = settings()
        first = fingerprint(base, "a")
        self.assertNotEqual(first, fingerprint(base, "b"))
        base["embedding"]["model"] = "other"
        self.assertNotEqual(first, fingerprint(base, "a"))
        base = settings(); base["embedding"]["url"] = "http://localhost:2"
        self.assertNotEqual(first, fingerprint(base, "a"))

    def test_model_switch_reindexes_and_title_change_reindexes(self):
        with tempfile.TemporaryDirectory() as folder:
            store = Store(folder)
            try:
                entry = store.create("회의", text="금요일까지 정리")
                client = FakeEmbedder(); config = settings()
                index_entry(store, entry, config, client)
                index_entry(store, entry, config, client)
                self.assertEqual(client.calls, 1)
                config["embedding"]["model"] = "new-model"
                index_entry(store, entry, config, client)
                self.assertEqual(client.calls, 2)
                entry = store.update(entry["id"], title="수정한 제목")
                index_entry(store, entry, config, client)
                self.assertEqual(client.calls, 3)
            finally: store.db.close()

    def test_failed_reindex_preserves_previous_vectors(self):
        with tempfile.TemporaryDirectory() as folder:
            store = Store(folder)
            try:
                entry = store.create("회의", text="중요한 내용")
                client = FakeEmbedder(); config = settings()
                old = index_entry(store, entry, config, client)
                config["embedding"]["model"] = "new-model"
                with patch.object(client, "embed", side_effect=ValueError("실패")):
                    with self.assertRaises(ValueError): index_entry(store, entry, config, client)
                self.assertEqual(store.chunks(entry["id"]), old)
            finally: store.db.close()

    def test_cosine_dimension_mismatch_is_not_silent(self):
        self.assertAlmostEqual(cosine([1, 2], [1, 2]), 1)
        with self.assertRaises(ValueError): cosine([1], [1, 2])

    def test_summary_processes_last_chunk(self):
        prompts = []
        class Client:
            def chat(self, system, prompt):
                prompts.append(prompt)
                return "부분 요약입니다."
        summarize("앞부분" + "가" * 15000 + "회의마지막결정", Client())
        self.assertTrue(any("회의마지막결정" in prompt for prompt in prompts))
        self.assertGreater(len(prompts), 3)

    def test_question_scope_and_citations(self):
        with tempfile.TemporaryDirectory() as folder:
            store = Store(folder)
            try:
                entry = store.create("선택된 회의", text="지민이 금요일에 초안을 작성합니다.")
                other = store.create("다른 회의", text="이 문서는 범위 밖입니다.")
                class Chat:
                    def chat(self, system, prompt): return "금요일입니다. [1]"
                with patch("sorinote.intelligence.provider", side_effect=lambda c, s, role: FakeEmbedder() if role == "embedding" else Chat()):
                    result = answer(store, "언제?", entry["id"], settings(), {})
                self.assertEqual(result["sources"][0]["entry_id"], entry["id"])
                self.assertEqual(store.chunks(other["id"]), [])
                self.assertIn("[1]", result["answer"])
            finally: store.db.close()


class ProviderTests(unittest.TestCase):
    def test_openai_embedding_order_is_restored(self):
        client = Provider({"provider": "openai", "url": "http://localhost:1234/v1", "model": "embed"})
        with patch.object(client, "request", return_value={"data": [
            {"index": 1, "embedding": [0, 1]}, {"index": 0, "embedding": [1, 0]}]}):
            self.assertEqual(client.embed(["a", "b"]), [[1, 0], [0, 1]])

    def test_invalid_vectors_rejected(self):
        for value in ([[0, 0]], [[math.nan]], [[1], [1, 2]], []):
            client = Provider({"provider": "ollama", "url": "http://localhost:11434", "model": "embeddinggemma:300m"})
            client.checked = True
            with patch.object(client, "request", return_value={"embeddings": value}):
                with self.assertRaises(ValueError): client.embed(["a"])

    def test_truncated_answer_is_not_saved_as_complete(self):
        client = Provider(settings()["summary"])
        client.checked = True
        with patch.object(client, "request", return_value={"done_reason": "length", "message": {"content": "잘린 내용"}}):
            with self.assertRaises(ValueError): client.chat("", "")

    def test_cli_returns_clean_json_on_error(self):
        worker = Path(__file__).resolve().parents[1] / "main.py"
        result = subprocess.run([sys.executable, str(worker)], input='{"action":"get"}', text=True, capture_output=True)
        event = json.loads(result.stdout)
        self.assertEqual(event["event"], "error")
        self.assertNotIn("Traceback", result.stdout)


if __name__ == "__main__":
    unittest.main()
