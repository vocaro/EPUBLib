#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
python3 -m unittest discover -s scripts/tests -v
python3 scripts/check-modules.py
python3 scripts/check-docs.py
swift build --target ReaderHostSupport
swift test
bash scripts/test-ios.sh
xcodegen generate --spec Examples/VoiceOverVerification/project.yml
xcodebuild -project Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj -scheme VoiceOverProbeMac \
    -destination 'platform=macOS' -derivedDataPath .build/host-mac CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj -scheme VoiceOverProbeIOS \
    -destination 'generic/platform=iOS' -derivedDataPath .build/host-ios CODE_SIGNING_ALLOWED=NO build
