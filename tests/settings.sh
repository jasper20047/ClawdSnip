#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .test-build
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -module-cache-path .test-build/modules -swift-version 5 -parse-as-library RecordingOptions.swift HotKeyRules.swift tests/SettingsTests.swift -o .test-build/settings-tests
.test-build/settings-tests
# OS integration is separate because sandboxed processes may not reach WindowServer:
# swiftc ... tests/HotKeyIntegration.swift; run .test-build/hotkey-integration outside sandbox.
if [[ "${1:-}" == --integration ]]; then
  swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -module-cache-path .test-build/modules -swift-version 5 -parse-as-library RecordingOptions.swift HotKeyRules.swift GlobalHotKeys.swift SettingsUI.swift tests/HotKeyIntegration.swift -o .test-build/hotkey-integration
  .test-build/hotkey-integration
fi
