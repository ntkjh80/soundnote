"""캐시된 EmbeddingGemma 2로 한국어 검색을 확인합니다. 사용자 자료는 읽지 않습니다."""
import json
import os
import sys
import time
from pathlib import Path

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))
from sorinote.config import settings
from sorinote.intelligence import provider, embedding_input, cosine

config = settings(); client = provider(config, {}, "embedding")
started = time.monotonic()
vectors = client.embed([
    embedding_input(config, "금요일까지 온보딩 문서 초안을 완성합니다.", title="제품 회의"),
    embedding_input(config, "점심 식사는 비빔밥입니다.", title="식단"),
    embedding_input(config, "문서 초안 마감일은 언제인가요?", query=True)])
result = {"model": client.model, "device": client.device, "dimensions": [len(v) for v in vectors],
          "seconds": round(time.monotonic() - started, 2),
          "relevant": round(cosine(vectors[0], vectors[2]), 4), "irrelevant": round(cosine(vectors[1], vectors[2]), 4)}
assert all(len(v) == 768 for v in vectors)
assert result["relevant"] > result["irrelevant"]
print(json.dumps(result, ensure_ascii=False, indent=2))
client.release()
