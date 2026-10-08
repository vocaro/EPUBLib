#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
python3 scripts/check-modules.py
python3 scripts/check-docs.py
swift build --target ReaderSampleSupport
swift test
bash scripts/test-ios.sh
xcodegen generate --spec Examples/ReaderSample/project.yml
xcodebuild -project Examples/ReaderSample/ReaderSample.xcodeproj -scheme ReaderSampleMac \
    -destination 'platform=macOS' -derivedDataPath .build/sample-mac CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Examples/ReaderSample/ReaderSample.xcodeproj -scheme ReaderSample \
    -destination 'generic/platform=iOS' -derivedDataPath .build/sample-ios CODE_SIGNING_ALLOWED=NO build
