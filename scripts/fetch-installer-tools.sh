#!/bin/bash
# 공식 배포본만 받으며, 압축을 풀기 전에 고정한 해시와 일치하는지 확인합니다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/installer/versions.sh"
CACHE="$ROOT/.runtime/installer-downloads"
OUTPUT="$ROOT/.runtime/installer-tools"
mkdir -p "$CACHE"
fetch() {
  local url="$1" file="$2" expected="$3"
  if [ ! -f "$file" ]; then
    curl --fail --location --retry 3 "$url" --output "$file.partial"
    mv "$file.partial" "$file"
  fi
  local actual
  actual="$(shasum -a 256 "$file" | cut -d ' ' -f 1)"
  if [ "$actual" != "$expected" ]; then
    echo "다운로드 파일의 해시가 일치하지 않습니다: $file" >&2
    exit 1
  fi
}
fetch "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz" \
  "$CACHE/uv-$UV_VERSION.tar.gz" "$UV_SHA256"
fetch "https://github.com/ollama/ollama/releases/download/v$OLLAMA_VERSION/ollama-darwin.tgz" \
  "$CACHE/ollama-$OLLAMA_VERSION.tgz" "$OLLAMA_SHA256"
# 두 파일을 검증한 뒤 생성 전용 폴더를 비워, 버전 변경 시 옛 라이브러리가 섞이지 않게 합니다.
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/ollama" "$OUTPUT/licenses"
tar -xzf "$CACHE/uv-$UV_VERSION.tar.gz" --strip-components 1 -C "$OUTPUT" uv-aarch64-apple-darwin/uv
tar -xzf "$CACHE/ollama-$OLLAMA_VERSION.tgz" -C "$OUTPUT/ollama"
cp "$ROOT/worker/requirements.lock.txt" "$OUTPUT/requirements.lock.txt"
cp "$ROOT/installer/licenses/"*.txt "$OUTPUT/licenses/"
cp "$ROOT/installer/versions.sh" "$OUTPUT/versions.sh"
chmod 755 "$OUTPUT/uv" "$OUTPUT/ollama/ollama"
echo "설치 도구 준비 완료: uv $UV_VERSION, Ollama $OLLAMA_VERSION"
