#!/bin/bash
set -euo pipefail
# The gate is whole: a filter given to `eng run gate` would be ignored, not applied.
if (( $# > 0 )); then
    echo "check-all.sh takes no arguments; filter the swift-tests or ios-tests lane instead (doc/testing.md)" >&2
    exit 2
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
python3 -m unittest discover -s scripts/tests -v
python3 scripts/check-modules.py
python3 scripts/check-docs.py
swift build --target ReaderHostSupport
swift test
bash scripts/test-ios.sh
python3 scripts/check-required-reason-apis.py
xcodegen generate --spec Examples/VoiceOverVerification/project.yml
xcodebuild -project Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj -scheme VoiceOverProbeMac \
    -destination 'platform=macOS' -derivedDataPath .build/host-mac CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj -scheme VoiceOverProbeIOS \
    -destination 'generic/platform=iOS' -derivedDataPath .build/host-ios CODE_SIGNING_ALLOWED=NO build
