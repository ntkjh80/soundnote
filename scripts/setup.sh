#!/bin/bash
# 시스템 Python을 바꾸지 않고 프로젝트 안에 전용 venv를 구성합니다.
# 예: bash scripts/setup.sh --python /opt/homebrew/bin/python3.12 --launch
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SORINOTE_SOURCE_PYTHON=""
SORINOTE_UPDATE_LOCK=false
SORINOTE_LAUNCH=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --python) [ "$#" -ge 2 ] || { echo '--python 뒤에 실행 파일 경로를 입력하세요.' >&2; exit 1; }; SORINOTE_SOURCE_PYTHON="$2"; shift 2;;
    --update-lock) SORINOTE_UPDATE_LOCK=true; shift;;
    --launch) SORINOTE_LAUNCH=true; shift;;
    *) echo "지원하지 않는 옵션: $1" >&2; exit 1;;
  esac
done
if [ "$(uname -m)" != arm64 ]; then
  echo "로컬 엔진은 Apple Silicon 맥이 필요합니다." >&2; exit 1
fi
compatible() {
  [ -x "$1" ] && [ "$1" != /usr/bin/python3 ] && "$1" -I -B -c 'import sys,platform; sys.exit(not (sys.version_info[:2] == (3,12) and platform.machine() == "arm64"))'
}
if [ -n "$SORINOTE_SOURCE_PYTHON" ] && ! compatible "$SORINOTE_SOURCE_PYTHON"; then
  echo "--python에는 ARM64 Python 3.12의 실행 파일을 지정하세요." >&2; exit 1
fi
if [ -x .venv/bin/python ] && ! compatible "$ROOT/.venv/bin/python"; then
  echo '기존 .venv의 Python 버전이 맞지 않습니다. 기존 환경을 다른 이름으로 보관한 뒤 다시 실행하세요.' >&2; exit 1
fi
mkdir -p .tools .runtime
# 내장·설치된 uv를 우선 사용하여 uv 자체를 다시 내려받는 일을 줄입니다.
if [ -x dist/SoriNote.app/Contents/Resources/installer/uv ]; then
  SORINOTE_UV="$ROOT/dist/SoriNote.app/Contents/Resources/installer/uv"
elif command -v uv >/dev/null 2>&1; then
  SORINOTE_UV="$(command -v uv)"
elif [ -x .tools/bootstrap/bin/uv ]; then
  SORINOTE_UV="$ROOT/.tools/bootstrap/bin/uv"
else
  SORINOTE_BOOTSTRAP="${SORINOTE_SOURCE_PYTHON:-python3}"
  "$SORINOTE_BOOTSTRAP" -m venv .tools/bootstrap
  .tools/bootstrap/bin/python -m pip install 'uv==0.13.0'
  SORINOTE_UV="$ROOT/.tools/bootstrap/bin/uv"
fi
export UV_CACHE_DIR="$ROOT/.tools/uv-cache"
export UV_PYTHON_INSTALL_DIR="$ROOT/.tools/python"
export UV_PYTHON_BIN_DIR="$ROOT/.tools/bin"
export UV_SYSTEM_CERTS="${UV_SYSTEM_CERTS:-true}"
# 설치 대상을 환경 변수로 다른 폴더나 시스템 Python으로 돌리지 않습니다.
unset UV_TARGET UV_PREFIX UV_SYSTEM_PYTHON UV_BREAK_SYSTEM_PACKAGES PIP_TARGET PIP_PREFIX PYTHONPATH PYTHONHOME
if [ ! -x .venv/bin/python ]; then
  if [ -z "$SORINOTE_SOURCE_PYTHON" ] && [ -n "${VIRTUAL_ENV:-}" ] && compatible "$VIRTUAL_ENV/bin/python"; then
    SORINOTE_SOURCE_PYTHON="$VIRTUAL_ENV/bin/python"
  fi
  if [ -z "$SORINOTE_SOURCE_PYTHON" ] && command -v python3.12 >/dev/null 2>&1 && compatible "$(command -v python3.12)"; then
    SORINOTE_SOURCE_PYTHON="$(command -v python3.12)"
  fi
  if [ -z "$SORINOTE_SOURCE_PYTHON" ]; then
    "$SORINOTE_UV" python install --no-bin 3.12.15
    SORINOTE_SOURCE_PYTHON=3.12.15
  fi
  "$SORINOTE_UV" venv --no-project --no-python-downloads --python "$SORINOTE_SOURCE_PYTHON" .venv
fi
if [ ! -f worker/requirements.lock.txt ] || [ "$SORINOTE_UPDATE_LOCK" = true ]; then
  "$SORINOTE_UV" pip compile worker/requirements.txt --python-version 3.12 --output-file worker/requirements.lock.txt
fi
"$SORINOTE_UV" pip sync --python .venv/bin/python --no-python-downloads --no-build worker/requirements.lock.txt
.venv/bin/python - <<'PY'
import json
from pathlib import Path
root = Path.cwd()
(root / '.runtime/runtime.json').write_text(json.dumps({'pythonPath': str(root / '.venv/bin/python')}))
print('AI 실행 엔진 준비 완료. 다음으로 scripts/build-app.sh를 실행하세요.')
PY
if [ "$SORINOTE_LAUNCH" = true ]; then
  bash scripts/build-app.sh
  exec "$ROOT/dist/SoriNote.app/Contents/MacOS/SoriNote"
fi
