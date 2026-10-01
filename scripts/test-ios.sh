#!/bin/bash
# Own both simulators and always delete them; never select a shared booted device.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
runtime="${EPUB_SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"
mkdir -p .build/validation
device=""
cleanup() {
    if [[ -n "$device" ]]; then
        xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
        xcrun simctl delete "$device" >/dev/null 2>&1 || true
        device=""
    fi
}
trap cleanup EXIT
for kind in iPhone-17-Pro iPad-Air-13-inch-M4; do
    device=$(xcrun simctl create "EPUBLib-$kind-$$" "com.apple.CoreSimulator.SimDeviceType.$kind" "$runtime")
    xcrun simctl boot "$device"
    xcrun simctl bootstatus "$device" -b
    xcodebuild -scheme EPUBLib-Package -destination "platform=iOS Simulator,id=$device" \
        -derivedDataPath .build/ios-validation -parallel-testing-enabled NO \
        CODE_SIGNING_ALLOWED=NO test > ".build/validation/$kind.log" 2>&1
    cleanup
    echo "Passed: $kind ($runtime)"
done
