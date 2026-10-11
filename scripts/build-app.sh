#!/bin/bash
# Swift 실행 파일에 리소스와 마이크 권한 설명을 더해 Finder에서 여는 앱을 만듭니다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
swift build -c release --scratch-path "$ROOT/.build"
BIN="$(swift build -c release --scratch-path "$ROOT/.build" --show-bin-path)"
APP="$ROOT/dist/SoriNote.app"
mkdir -p "$ROOT/.runtime"
if [ "${1:-}" = "--installer" ]; then bash scripts/fetch-installer-tools.sh; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SoriNote" "$APP/Contents/MacOS/SoriNote"
# 배포 리소스에는 소스만 넣습니다. 캐시, 가상 환경, 녹음은 복사하지 않습니다.
rm -rf "$APP/Contents/Resources/worker"
mkdir -p "$APP/Contents/Resources/worker/sorinote"
cp worker/main.py "$APP/Contents/Resources/worker/"
cp worker/sorinote/*.py "$APP/Contents/Resources/worker/sorinote/"
rm -f "$APP/Contents/Resources/runtime.json"
rm -rf "$APP/Contents/Resources/installer"
if [ "${1:-}" = "--installer" ]; then
  ditto .runtime/installer-tools "$APP/Contents/Resources/installer"
elif [ -f .runtime/runtime.json ]; then
  cp .runtime/runtime.json "$APP/Contents/Resources/runtime.json"
fi
cp assets/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
IDENTITY="${CODE_SIGN_IDENTITY:--}"
if [ "$IDENTITY" != - ]; then
  # 내장 실행 파일과 라이브러리부터 서명한 뒤 바깥 앱을 서명합니다.
  while IFS= read -r -d '' item; do
    if file -b "$item" | grep -q 'Mach-O'; then
      codesign --force --options runtime --timestamp --sign "$IDENTITY" "$item"
    fi
  done < <(find "$APP/Contents/Resources" -type f -print0)
  codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier app.sorinote.local "$APP"
else
  codesign --force --sign - --identifier app.sorinote.local "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "앱 생성 완료: $APP"
