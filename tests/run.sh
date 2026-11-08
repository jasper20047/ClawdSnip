#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .test-build
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -module-cache-path .test-build/modules -swift-version 5 -framework Cocoa -framework ScreenCaptureKit RecordingOptions.swift tests/main.swift -o .test-build/rules
.test-build/rules
