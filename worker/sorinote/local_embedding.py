"""Ollama 없이 맥에서 직접 임베딩 모델을 실행합니다."""
import gc
from .audio import model_path
from .providers import validate_vectors


class LocalEmbedder:
    kind = "sentence_transformers"

    def __init__(self, profile, token=""):
        self.profile = profile
        self.model = profile["model"]
        self.token = token
        self.engine = None
        self.device = None

    def load(self):
        if self.engine is not None:
            return
        import torch
        from sentence_transformers import SentenceTransformer
        from transformers import AutoConfig
        cached = model_path(self.model, token=self.token)
        selected = self.profile.get("device", "auto")
        available = torch.backends.mps.is_available()
        if selected == "mps" and not available:
            raise ValueError("이 환경에서는 Apple GPU를 사용할 수 없습니다. 자동 또는 CPU를 선택하세요.")
        self.device = "mps" if (selected == "mps" or selected == "auto" and available) else "cpu"
        config = AutoConfig.from_pretrained(cached, local_files_only=True, trust_remote_code=False)
        options = {}
        if config.model_type == "embedding_gemma2":
            # 검색은 텍스트만 사용하므로 영상·음성 인코더를 불러오지 않습니다.
            options["config_kwargs"] = {"vision_config": None, "audio_config": None}
        # EmbeddingGemma 2는 float16에서 잘못된 벡터를 만들 수 있어 float32로 고정합니다.
        self.engine = SentenceTransformer(cached, device=self.device, local_files_only=True,
            trust_remote_code=False, model_kwargs={"torch_dtype": torch.float32}, **options)
        # 역할에 맞는 접두어는 intelligence.py에서 한 번만 적용합니다.
        self.engine.default_prompt_name = None

    def embed(self, texts):
        self.load()
        try:
            values = self.engine.encode(texts, batch_size=8, show_progress_bar=False,
                convert_to_numpy=True, normalize_embeddings=True, prompt="")
        except RuntimeError as error:
            if self.profile.get("device", "auto") == "auto" and self.device == "mps" and "mps" in str(error).lower():
                self.engine.to("cpu")
                self.device = "cpu"
                values = self.engine.encode(texts, batch_size=8, show_progress_bar=False,
                    convert_to_numpy=True, normalize_embeddings=True, prompt="")
            else:
                raise
        return validate_vectors(values.tolist(), len(texts))

    def release(self):
        """답변 모델을 로드하기 전에 임베딩 모델의 메모리를 돌려줍니다."""
        self.engine = None
        gc.collect()
        import torch
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
