#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PYTHONDONTWRITEBYTECODE=1
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
python3 -m unittest discover -s worker/tests -v
if [ -d "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]; then
  swift test --scratch-path "$ROOT/.build"
else
  echo "현재 개발 도구에 XCTest가 없어 Swift 단독 통합 검사를 실행합니다."
  mkdir -p .build
  swiftc Sources/SoriNote/Models.swift Sources/SoriNote/RuntimeConfiguration.swift Sources/SoriNote/WorkerClient.swift Tests/Smoke/main.swift \
    -o .build/smoke-tests
  .build/smoke-tests
fi
# 녹음 권한이나 실제 소리 없이 합성 PCM으로 혼합·시각·복구를 검사합니다.
swiftc Sources/SoriNote/Models.swift Sources/SoriNote/RuntimeConfiguration.swift Sources/SoriNote/CaptureTimeline.swift \
  Sources/SoriNote/AudioCapture.swift Tests/AudioSmoke/main.swift -o .build/audio-smoke-tests
.build/audio-smoke-tests
# 원본을 보존하는 파일 내보내기와 취소·실패 복구를 검사합니다.
swiftc Sources/SoriNote/Models.swift Sources/SoriNote/RuntimeConfiguration.swift Sources/SoriNote/CaptureTimeline.swift \
  Sources/SoriNote/EntryExporter.swift Tests/ExportSmoke/main.swift -o .build/export-smoke-tests
.build/export-smoke-tests
# 설치에 인터넷을 쓰지 않고, 가짜 실행 도구로 실패·취소·재시도와 기존 환경 보존을 검사합니다.
swiftc Sources/SoriNote/Models.swift Sources/SoriNote/RuntimeConfiguration.swift Sources/SoriNote/RuntimeInstaller.swift \
  Tests/InstallerSmoke/main.swift -o .build/installer-smoke-tests
.build/installer-smoke-tests
