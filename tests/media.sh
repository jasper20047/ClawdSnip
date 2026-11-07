#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .test-build
ROOT="$(mktemp -d "$PWD/.test-build/media.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys, wave, math, struct
root=Path(sys.argv[1])
for frequency in [440,880]:
 with wave.open(str(root/f'{frequency}.wav'),'wb') as f:
  f.setnchannels(1); f.setsampwidth(2); f.setframerate(48000)
  f.writeframes(b''.join(struct.pack('<h',int(9000*math.sin(2*math.pi*frequency*i/48000))) for i in range(96000)))
PY
swiftc -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" -module-cache-path .test-build/modules -swift-version 5 -parse-as-library RecordingOptions.swift RecordingFile.swift tests/MediaTests.swift -o .test-build/media-tests
.test-build/media-tests "$ROOT"
