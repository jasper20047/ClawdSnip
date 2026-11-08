#!/bin/zsh
# Local integration: visible synthetic animation only; no microphone, no user recordings.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .test-build
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
ROOT="$(mktemp -d "$PWD/.test-build/motion.XXXXXX")"
fixture_pid=""
cleanup() {
  [[ -z "$fixture_pid" ]] || kill -TERM "$fixture_pid" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT
swiftc -sdk "$SDK" -module-cache-path .test-build/modules -swift-version 5 tests/MotionFixture.swift -o "$ROOT/fixture"
swiftc -sdk "$SDK" -module-cache-path .test-build/modules -swift-version 5 -parse-as-library RecordingOptions.swift RecordingFile.swift ScreenRecorder.swift tests/MotionCapture.swift -o "$ROOT/capture"
swiftc -sdk "$SDK" -module-cache-path .test-build/modules -swift-version 5 -parse-as-library tests/VideoMotionProbe.swift -o "$ROOT/probe"
"$ROOT/fixture" >"$ROOT/fixture.log" 2>&1 &
fixture_pid=$!
"$ROOT/capture" "$ROOT/audio.mp4" --audio
"$ROOT/probe" "$ROOT/audio.mp4" --require-motion --expected-seconds=5
CLAWD_TEST_QUALITY=qhd1440 "$ROOT/capture" "$ROOT/qhd-silent.mp4"
"$ROOT/probe" "$ROOT/qhd-silent.mp4" --require-motion --expected-seconds=5
"$ROOT/capture" "$ROOT/repeat-audio.mp4" --audio
"$ROOT/probe" "$ROOT/repeat-audio.mp4" --require-motion --expected-seconds=5
print 'PASS: sustained dynamic recording, audio on/off, quality selection and repeated capture'
