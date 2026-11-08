#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .test-build
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swiftc -O -sdk "$SDK" -module-cache-path .test-build/modules -swift-version 5 -parse-as-library RecordingOptions.swift ScreenshotOutputOptions.swift ScreenshotFile.swift LongImageStitcher.swift tests/ScreenshotTests.swift -o .test-build/screenshot-tests
.test-build/screenshot-tests
if [[ "${1:-}" == --integration ]]; then
 swiftc -sdk "$SDK" -module-cache-path .test-build/modules -swift-version 5 -parse-as-library RecordingOptions.swift ScreenshotOutputOptions.swift ScreenshotFile.swift ScreenshotOutputController.swift tests/ScreenshotClipboardTests.swift -o .test-build/clipboard-tests
 .test-build/clipboard-tests
fi
