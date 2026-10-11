#!/bin/bash
# 시스템 Python을 바꾸지 않고 이 프로젝트 안에 전용 AI 엔진을 설치합니다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ "$(uname -m)" != arm64 ]; then
  echo "MLX 음성 인식은 Apple Silicon 맥이 필요합니다." >&2
  exit 1
fi
mkdir -p .tools .runtime
if [ ! -x .tools/bootstrap/bin/uv ]; then
  python3 -m venv .tools/bootstrap
  .tools/bootstrap/bin/python -m pip install 'uv>=0.9,<1'
fi
UV="$ROOT/.tools/bootstrap/bin/uv"
export UV_CACHE_DIR="$ROOT/.tools/uv-cache"
export UV_PYTHON_INSTALL_DIR="$ROOT/.tools/python"
export UV_PYTHON_BIN_DIR="$ROOT/.tools/bin"
"$UV" python install 3.12
if [ ! -x .venv/bin/python ]; then
  "$UV" venv --python 3.12 .venv
fi
if [ ! -f worker/requirements.lock.txt ] || [ "${1:-}" = "--update-lock" ]; then
  "$UV" pip compile worker/requirements.txt --python-version 3.12 \
    --output-file worker/requirements.lock.txt
fi
"$UV" pip sync --python .venv/bin/python worker/requirements.lock.txt
.venv/bin/python - <<'PY'
import json
from pathlib import Path
root = Path.cwd()
(root / '.runtime/runtime.json').write_text(json.dumps({'pythonPath': str(root / '.venv/bin/python')}))
print('AI 실행 엔진 준비 완료. 다음으로 scripts/build-app.sh를 실행하세요.')
PY
