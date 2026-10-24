#!/bin/bash
set -euo pipefail
# The gate is whole: a filter given to `eng run gate` would be ignored, not applied.
if (( $# > 0 )); then
    echo "check-all.sh takes no arguments; filter the swift-tests or ios-tests lane instead (doc/testing.md)" >&2
    exit 2
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
# Heavy-work admission counts the gate as one job however many workers it starts, so the gate
# bounds its builds; its tests run one at a time (doc/testing.md, "Local gate").
export EPUB_BUILD_JOBS="${EPUB_BUILD_JOBS:-4}"
if [[ ! "$EPUB_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "EPUB_BUILD_JOBS must be a positive number of build workers" >&2
    exit 2
fi
jobs="$EPUB_BUILD_JOBS"
python3 -m unittest discover -s scripts/tests -v
python3 scripts/check-modules.py
python3 scripts/check-docs.py
swift build --target ReaderHostSupport --jobs "$jobs"
python3 scripts/check-licenses.py
# A suite that a busy host left a test or a simulator boot unmeasured in exits 3: the gate goes
# on, and ends neither passed nor failed.
mac=0
bash scripts/test-mac.sh || mac=$?
if (( mac != 0 && mac != 3 )); then exit "$mac"; fi
ios=0
bash scripts/test-ios.sh || ios=$?
if (( ios != 0 && ios != 3 )); then exit "$ios"; fi
python3 scripts/check-required-reason-apis.py
xcodegen generate --spec Examples/VoiceOverVerification/project.yml
xcodebuild -project Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj -scheme VoiceOverProbeMac \
    -destination 'platform=macOS' -derivedDataPath .build/host-mac -jobs "$jobs" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj -scheme VoiceOverProbeIOS \
    -destination 'generic/platform=iOS' -derivedDataPath .build/host-ios -jobs "$jobs" CODE_SIGNING_ALLOWED=NO build
if (( mac == 3 || ios == 3 )); then
    echo "The gate left tests unmeasured, listed above: neither passed nor failed; run them again when the host is quieter"
    exit 3
fi
