#!/bin/bash
# The Mac suite as the swift-tests lane and the gate run it: `swift test` with this script's
# arguments, such as --filter X, on a bounded build, its output kept in .build/validation/mac.log.
# A test a busy host decided skips as unmeasured (Tests/EPUBTestSupport/TestDeadline.swift); a run
# with one exits 3, neither passed nor failed (doc/testing.md, "Local gate").
set -uo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.." || exit 1
# Admission counts this script as one job however many workers it starts, so it bounds its build.
jobs="${EPUB_BUILD_JOBS:-4}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    echo "EPUB_BUILD_JOBS must be a positive number of build workers" >&2
    exit 2
fi
mkdir -p .build/validation || exit 1
log=.build/validation/mac.log
swift test --jobs "$jobs" "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
(( status == 0 )) || exit "$status"
unmeasured=$(grep -E ': Test skipped - Unmeasured: ' "$log" | sort -u)
if [[ -n "$unmeasured" ]]; then
    echo "Unmeasured: macOS: $(wc -l <<< "$unmeasured" | tr -d ' ') tests a busy host decided; see $log"
    echo "$unmeasured"
    exit 3
fi
