"""구간 요약의 저장·재시도·문맥 전달을 합성 자료로 검사합니다. 실제 회의·모델은 사용하지 않습니다."""
import contextlib
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from main import dispatch
from sorinote import intervals
from sorinote.config import settings
from sorinote.store import Store


class IntervalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = Store(self.root / "db")
        self.entry = self.store.create("구간 검사", "meeting")
        self.config = settings({"intervalSummaryEnabled": True, "intervalMinutes": 1,
                                "intervalFinalSummary": False, "qaEnabled": False})
        self.client = Mock()
        self.client.chat.side_effect = lambda system, prompt: "현재 결정: 금요일까지 초안 작성."
        self.phase = []
        def transcribe(*_):
            self.phase.append("asr")
            text = "금요일까지 초안을 작성합니다."
            segments = [{"start": 1, "end": 3, "text": text, "speaker": "미지정"}]
            return [], [], segments, text
        self.asr = patch("sorinote.audio.transcribe", side_effect=transcribe).start()
        @contextlib.contextmanager
        def client(*_):
            self.phase.append("summary")
            yield self.client
        patch("sorinote.intervals.summary_client", side_effect=client).start()
        self.addCleanup(patch.stopall)
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.store.db.close)

    def step(self, start=0, end=60, **kwargs):
        return intervals.process_interval(self.store, self.entry["id"], "sample.wav", start, end, 60,
                                          self.config, {}, lambda _: None, **kwargs)

    def test_default_off_and_interval_validation(self):
        self.assertFalse(settings()["intervalSummaryEnabled"])
        self.assertEqual(intervals.interval_seconds(settings()), 300)
        for value in (0, 31, -1, 1.5, True, "5"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                intervals.interval_seconds({"intervalMinutes": value})

    def test_serial_order_and_global_timing(self):
        self.step()
        result = self.step(60, 72)
        self.assertEqual(self.phase, ["asr", "summary", "asr", "summary"])
        self.assertEqual([s["start"] for s in result["segments"]], [1, 61])
        self.assertEqual([(n["start"], n["end"]) for n in result["interval_notes"]], [(0, 60), (60, 72)])
        self.assertEqual(result["interval_complete"], 0)
        self.assertEqual(result["interval_seconds"], 60)

    def test_word_timestamps_survive_for_final_speaker_alignment(self):
        self.step()
        segment = {"start": 1, "end": 3, "text": "단어 시각", "speaker": "미지정"}
        raw = {**segment, "words": [{"start": 1, "end": 2, "word": "단어"}, {"start": 2, "end": 3, "word": "시각"}]}
        self.asr.side_effect = None; self.asr.return_value = ([], [raw], [segment], "단어 시각")
        result = self.step(60, 65)
        self.assertEqual([word["start"] for word in result["segments"][-1]["words"]], [61, 62])

    def test_api_interval_size_guard(self):
        with self.assertRaisesRegex(ValueError, "25MB"):
            intervals.interval_seconds(settings({"asr": {"provider": "openai"}, "intervalMinutes": 14}))
        self.assertEqual(intervals.interval_seconds(settings({"asr": {"provider": "openai"}, "intervalMinutes": 13})), 780)

    def test_context_and_previous_tail_are_reference_only(self):
        self.step()
        self.step(60, 120)
        prompt = self.client.chat.call_args_list[2].args[1]
        data = json.loads(prompt.split("\n", 1)[1])
        self.assertIn("현재 결정", data["이전 맥락(참고)"])
        self.assertIn("초안을 작성", data["직전 발언(참고)"])
        self.assertIn("[01:01]", data["이번 구간"])
        self.assertIn("이전 결정이 이번에 다시", prompt)

    def test_summary_failure_keeps_transcript_and_retry_skips_asr(self):
        self.client.chat.side_effect = ValueError("서버 오류")
        with self.assertRaisesRegex(ValueError, "서버 오류"):
            self.step()
        entry = self.store.get(self.entry["id"])
        self.assertIn("초안", entry["text"])
        self.assertEqual(entry["interval_notes"][0]["status"], "transcribed")
        self.client.chat.side_effect = None; self.client.chat.return_value = "복구한 요약"
        result = self.step()
        self.assertEqual(self.asr.call_count, 1)
        self.assertEqual(result["interval_notes"][0]["summary"], "복구한 요약")
        self.assertEqual(len(result["segments"]), 1)

    def test_cancellation_preserves_previous_and_current_transcript(self):
        self.step()
        self.client.chat.side_effect = KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            self.step(60, 120)
        rows = self.store.interval_rows(self.entry["id"])
        self.assertEqual([r["status"] for r in rows], ["complete", "transcribed"])
        self.assertTrue(rows[0]["summary"])

    def test_out_of_order_duplicate_and_bad_ranges_do_not_write(self):
        self.step()
        before = self.store.get(self.entry["id"])
        for start, end in [(0, 60), (61, 120), (60, 121), (-1, 10), (60, float("nan"))]:
            with self.subTest(start=start, end=end), self.assertRaises(ValueError):
                self.step(start, end)
        self.assertEqual(before, self.store.get(self.entry["id"]))

    def test_failed_retranscription_keeps_old_notes(self):
        before = self.step()
        self.asr.side_effect = ValueError("ASR 실패")
        with self.assertRaises(ValueError):
            self.step(reset=True)
        self.assertEqual(before, self.store.get(self.entry["id"]))

    def test_reset_replaces_intervals_only_after_asr_success(self):
        self.step(); self.step(60, 70)
        after = self.step(reset=True)
        self.assertEqual(len(after["interval_notes"]), 1)
        self.assertEqual(len(after["segments"]), 1)

    def test_silence_and_short_tail_do_not_invoke_summary_model(self):
        self.asr.side_effect = None; self.asr.return_value = ([], [], [], "")
        self.step()
        self.step(60, 60.05)
        self.client.chat.assert_not_called()
        self.assertEqual(self.asr.call_count, 1)
        self.assertEqual(len(self.store.interval_rows(self.entry["id"])), 2)

    def test_json_only_api_does_not_invent_word_timestamps(self):
        self.asr.side_effect = None; self.asr.return_value = (None, [], [], "본문만 있는 응답")
        result = self.step()
        self.assertEqual(result["segments"], [])
        self.assertIn("[구간 00:00:00~00:01:00]", result["text"])

    def test_intermediate_updates_are_committed_and_persist_after_reopen(self):
        observed = []
        self.step(changed=lambda entry: observed.append(self.store.get(entry["id"])))
        self.assertEqual([e["interval_notes"][0]["status"] for e in observed], ["transcribed", "complete"])
        other = Store(self.root / "db")
        try:
            self.assertEqual(other.get(self.entry["id"]), observed[-1])
        finally:
            other.db.close()

    def test_audio_attachment_and_finalization_preserve_notes(self):
        self.step()
        audio = self.root / "audio.wav"; audio.write_bytes(b"synthetic")
        saved = self.store.attach_audio(self.entry["id"], str(audio))
        with patch("sorinote.audio.diarize", return_value=[{"start": 1, "end": 3, "speaker": "화자 1", "text": "내용"}]) as diarize:
            self.config["diarization"] = True
            result = intervals.finalize(self.store, self.entry["id"], self.config, {}, lambda _: None)
        self.assertEqual(len(result["interval_notes"]), 1)
        self.assertEqual(result["interval_complete"], 1)
        self.assertEqual(Path(result["audio_path"]).read_bytes(), b"synthetic")
        self.assertEqual(diarize.call_count, 1)
        self.assertEqual(result["segments"][0]["speaker"], "화자 1")
        self.assertTrue(audio.exists())

    def test_resume_uses_saved_interval_and_skips_completed_audio(self):
        self.step()
        self.config["intervalMinutes"] = 5
        source = self.root / "source.wav"; source.write_bytes(b"synthetic")
        self.store.attach_audio(self.entry["id"], str(source))
        with patch("sorinote.intervals.decoded_chunks", return_value=(value for value in [("sample.wav", 60, 75)])) as decoder:
            result = intervals.process_file(self.store, self.entry["id"], self.config, {}, lambda _: None, resume=True)
        self.assertEqual(decoder.call_args.args[1:], (60, 60))
        self.assertEqual(self.asr.call_count, 2)
        self.assertEqual(result["interval_complete"], 1)

    def test_manual_edit_invalidates_but_title_edit_keeps_notes(self):
        self.step()
        self.store.update(self.entry["id"], title="새 제목")
        self.assertEqual(len(self.store.get(self.entry["id"])["interval_notes"]), 1)
        self.store.update(self.entry["id"], text="바뀐 내용")
        value = self.store.get(self.entry["id"])
        self.assertEqual(value["interval_notes"], [])
        self.assertEqual(value["interval_seconds"], 0)

    def test_legacy_database_migration_keeps_records(self):
        legacy = self.root / "legacy"; legacy.mkdir()
        db = sqlite3.connect(legacy / "library.sqlite3")
        db.execute("CREATE TABLE entries (id TEXT PRIMARY KEY,title TEXT NOT NULL,kind TEXT NOT NULL,created TEXT NOT NULL,text TEXT NOT NULL DEFAULT '',segments TEXT NOT NULL DEFAULT '[]',summary TEXT NOT NULL DEFAULT '',audio_path TEXT NOT NULL DEFAULT '',warning TEXT NOT NULL DEFAULT '')")
        db.execute("INSERT INTO entries(id,title,kind,created,text,summary) VALUES('old','기존','document','2026','원문','요약')")
        db.commit(); db.close()
        for _ in range(2):
            store = Store(legacy)
            try:
                self.assertEqual(store.get("old")["text"], "원문")
                self.assertEqual(store.get("old")["summary"], "요약")
                self.assertEqual(store.get("old")["interval_notes"], [])
            finally: store.db.close()

    def test_stream_decoder_bounds_last_chunk_and_cleans_up(self):
        source = self.root / "source.wav"; source.touch()
        data = b"\x00\x01" * (65 * 16000)
        process = Mock(stdout=io.BytesIO(data))
        process.wait.return_value = 0; process.poll.return_value = None
        with patch.dict(sys.modules, {"imageio_ffmpeg": types.SimpleNamespace(get_ffmpeg_exe=lambda: "ffmpeg")}), \
             patch("sorinote.intervals.subprocess.Popen", return_value=process):
            chunks = intervals.decoded_chunks(source, 60)
            first, start, end = next(chunks)
            self.assertEqual((start, end), (0, 60))
            with wave.open(first) as reader: self.assertEqual(reader.getnframes(), 60 * 16000)
            second, start, end = next(chunks)
            self.assertEqual((start, end), (60, 65))
            chunks.close()
        self.assertFalse(Path(second).exists())
        process.kill.assert_called_once()
        self.assertTrue(process.stdout.closed)

    def test_new_live_entry_can_resume_before_first_transcription(self):
        entry = dispatch({"action": "create", "title": "녹음", "kind": "meeting", "intervalRecording": True,
                          "dataDir": str(self.root / "db"), "config": self.config}, lambda _: None)
        self.assertEqual(entry["interval_seconds"], 60)
        self.assertEqual(entry["interval_complete"], 0)
        self.assertEqual(entry["interval_notes"], [])

    def test_long_context_is_bounded_and_final_summary_is_optional(self):
        intervals.contextual_summary("현재 내용", "가" * 20000, "나" * 10000, self.client, lambda _: None)
        prompt = self.client.chat.call_args_list[0].args[1]
        data = json.loads(prompt.split("\n", 1)[1])
        self.assertEqual(len(data["이전 맥락(참고)"]), 4000)
        self.assertEqual(len(data["직전 발언(참고)"]), 1500)
        self.step()
        self.config["intervalFinalSummary"] = True
        with patch("sorinote.intelligence.summarize", return_value="전체 요약") as summarize:
            result = intervals.finalize(self.store, self.entry["id"], self.config, {}, lambda _: None)
        summarize.assert_called_once()
        self.assertEqual(result["summary"], "전체 요약")
        self.assertEqual(len(result["interval_notes"]), 1)


if __name__ == "__main__": unittest.main()
