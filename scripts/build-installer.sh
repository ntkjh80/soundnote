#!/bin/bash
# 앱만 /Applications에 설치합니다. 네트워크 설치와 모델 다운로드는 사용자 권한으로 앱에서 합니다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ "$(uname -m)" != arm64 ]; then
  echo "이 설치 패키지는 Apple Silicon 맥에서 빌드하세요." >&2; exit 1
fi
bash scripts/build-app.sh --installer
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' assets/Info.plist)"
STAGE="$(mktemp -d "$ROOT/.runtime/pkg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/root/Applications"
ditto --noextattr --norsrc dist/SoriNote.app "$STAGE/root/Applications/SoriNote.app"
pkgbuild --analyze --root "$STAGE/root" "$STAGE/components.plist"
# 이미 다른 폴더에 있는 개발용 앱을 찾아 덮어쓰는 설치 프로그램의 재배치 기능을 끕니다.
/usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$STAGE/components.plist"
pkgbuild --root "$STAGE/root" --component-plist "$STAGE/components.plist" \
  --identifier app.sorinote.local.pkg --version "$VERSION" --install-location / \
  "$STAGE/SoriNote-component.pkg"
sed "s/@VERSION@/$VERSION/g" installer/distribution.xml > "$STAGE/distribution.xml"
PACKAGE="$ROOT/dist/SoriNote-$VERSION-arm64.pkg"
if [ -n "${INSTALLER_SIGN_IDENTITY:-}" ]; then
  productbuild --distribution "$STAGE/distribution.xml" --resources "$ROOT/installer" \
    --package-path "$STAGE" --sign "$INSTALLER_SIGN_IDENTITY" --timestamp "$PACKAGE"
else
  productbuild --distribution "$STAGE/distribution.xml" --resources "$ROOT/installer" \
    --package-path "$STAGE" "$PACKAGE"
fi
cd "$ROOT/dist"
shasum -a 256 "$(basename "$PACKAGE")" > "$(basename "$PACKAGE").sha256"
echo "설치 파일 생성 완료: $PACKAGE"
