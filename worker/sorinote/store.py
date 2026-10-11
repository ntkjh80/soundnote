"""회의 원문, 요약, 검색용 벡터를 SQLite 한 파일에 저장합니다."""
import json
import os
import shutil
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path


class Store:
    def __init__(self, directory):
        self.root = Path(directory).expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.audio = self.root / "recordings"
        self.audio.mkdir(exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.root / "library.sqlite3", timeout=30)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL,
                created TEXT NOT NULL, text TEXT NOT NULL DEFAULT '',
                segments TEXT NOT NULL DEFAULT '[]', summary TEXT NOT NULL DEFAULT '',
                audio_path TEXT NOT NULL DEFAULT '', warning TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS chunks (
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL, text TEXT NOT NULL, vector TEXT NOT NULL,
                fingerprint TEXT NOT NULL, PRIMARY KEY(entry_id, ordinal)
            );
            PRAGMA user_version=1;
        """)
        os.chmod(self.root / "library.sqlite3", 0o600)

    def list(self):
        return [dict(row) for row in self.db.execute(
            "SELECT id,title,kind,created,substr(text,1,120) AS preview,"
            "length(summary)>0 AS summarized,audio_path FROM entries ORDER BY created DESC")]

    def get(self, entry_id):
        row = self.db.execute("SELECT * FROM entries WHERE id=?", (entry_id,)).fetchone()
        if not row:
            raise ValueError("항목을 찾을 수 없습니다. 목록을 새로 고쳐 주세요.")
        value = dict(row)
        value["segments"] = json.loads(value["segments"])
        return value

    def create(self, title, kind="document", text="", audio_path=""):
        if kind not in ("document", "meeting"):
            raise ValueError("알 수 없는 자료 종류입니다.")
        if len(text) > 2_000_000:
            raise ValueError("한 문서에는 최대 200만 글자까지 넣을 수 있습니다.")
        entry_id = str(uuid.uuid4())
        copied = ""
        if audio_path:
            source = Path(audio_path).resolve()
            if not source.is_file():
                raise ValueError("녹음 파일을 찾을 수 없습니다.")
            if source.stat().st_size > 2 * 1024**3:
                raise ValueError("음성 파일은 2GB 이하로 나누어 주세요.")
            destination = self.audio / (entry_id + source.suffix.lower())
            shutil.copyfile(source, destination)
            os.chmod(destination, 0o600)
            copied = str(destination)
        try:
            with self.db:
                self.db.execute("INSERT INTO entries(id,title,kind,created,text,audio_path) VALUES(?,?,?,?,?,?)",
                                (entry_id, title.strip()[:200] or "제목 없는 기록", kind,
                                 datetime.now(timezone.utc).isoformat(), text, copied))
        except Exception:
            if copied:
                Path(copied).unlink(missing_ok=True)
            raise
        return self.get(entry_id)

    def update(self, entry_id, **values):
        self.get(entry_id)
        if not values.keys() <= {"title", "text", "segments", "summary", "warning"}:
            raise ValueError("수정할 수 없는 항목입니다.")
        if "segments" in values:
            values["segments"] = json.dumps(values["segments"], ensure_ascii=False)
        with self.db:
            for key, value in values.items():
                self.db.execute(f"UPDATE entries SET {key}=? WHERE id=?", (value, entry_id))
            # 원문이 바뀌면 이전 요약과 임베딩을 함께 무효화합니다.
            if "text" in values:
                self.db.execute("DELETE FROM chunks WHERE entry_id=?", (entry_id,))
                self.db.execute("UPDATE entries SET summary='' WHERE id=?", (entry_id,))
        return self.get(entry_id)

    def delete(self, entry_id):
        entry = self.get(entry_id)
        with self.db:
            self.db.execute("DELETE FROM entries WHERE id=?", (entry_id,))
        path = Path(entry["audio_path"]).resolve() if entry["audio_path"] else None
        # DB가 손상되어도 앱의 녹음 폴더 밖에 있는 원본은 삭제하지 않습니다.
        if path and path.parent == self.audio.resolve():
            path.unlink(missing_ok=True)
        return {"deleted": entry_id}

    def replace_chunks(self, entry_id, texts, vectors, fingerprint):
        if len(texts) != len(vectors):
            raise ValueError("문단 수와 검색 벡터 수가 일치하지 않습니다.")
        with self.db:
            self.db.execute("DELETE FROM chunks WHERE entry_id=?", (entry_id,))
            self.db.executemany("INSERT INTO chunks VALUES(?,?,?,?,?)", [
                (entry_id, i, text, json.dumps(vector), fingerprint)
                for i, (text, vector) in enumerate(zip(texts, vectors))])

    def chunks(self, entry_id):
        return [dict(row) for row in self.db.execute(
            "SELECT * FROM chunks WHERE entry_id=? ORDER BY ordinal", (entry_id,))]
