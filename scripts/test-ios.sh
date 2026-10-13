#!/bin/bash
# Own both simulators and always delete them; never select a shared booted device.
set -uo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.." || exit 1
runtime="${EPUB_SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"
boot_timeout="${EPUB_SIM_BOOT_TIMEOUT:-600}"
if [[ ! "$boot_timeout" =~ ^[1-9][0-9]*$ ]]; then
    echo "EPUB_SIM_BOOT_TIMEOUT must be a positive number of seconds" >&2
    exit 2
fi
mkdir -p .build/validation || exit 1
device=""
child_pid=""
device_name=""
create_output=""
creation_pending=0
run_id=$(python3 -c 'import uuid; print(uuid.uuid4())') || exit 1

# Kill only descendants of the command this script started. Waiting on an asynchronous
# child lets TERM/INT run the trap while bootstatus or xcodebuild is still waiting.
process_tree() {
    local pid="$1" descendant
    for descendant in $(pgrep -P "$pid" 2>/dev/null || true); do
        process_tree "$descendant"
    done
    echo "$pid"
}
stop_process_tree() {
    local targets target active deadline
    targets=$(process_tree "$1")
    for target in $targets; do kill -TERM "$target" 2>/dev/null || true; done
    deadline=$((SECONDS + 2))
    while (( SECONDS < deadline )); do
        active=0
        for target in $targets; do
            if kill -0 "$target" 2>/dev/null; then active=1; break; fi
        done
        (( active == 0 )) && return
        sleep 0.05
    done
    # A CLI that ignores TERM must not keep the EXIT trap waiting without end.
    for target in $targets; do kill -KILL "$target" 2>/dev/null || true; done
}
cleanup() {
    if [[ -n "$child_pid" ]]; then
        stop_process_tree "$child_pid"
        wait "$child_pid" 2>/dev/null || true
        child_pid=""
    fi
    # A creation interrupted after the service stored the device may have written its
    # UUID already. If not, recover only the exact unique name this run asked to create.
    if [[ -z "$device" && -n "$create_output" && -s "$create_output" ]]; then
        device=$(cat "$create_output")
    fi
    if [[ -z "$device" && -n "$device_name" ]]; then
        local recovery_deadline=$((SECONDS + 5))
        while true; do
            device=$(perl -e 'alarm 2; exec @ARGV' xcrun simctl list devices --json 2>/dev/null | \
                python3 -c 'import json, sys
try:
    devices = json.load(sys.stdin)["devices"]
except (ValueError, KeyError):
    sys.exit(0)
matches = [d["udid"] for group in devices.values() for d in group if d.get("name") == sys.argv[1]]
if len(matches) == 1:
    print(matches[0])' "$device_name")
            [[ -n "$device" ]] && break
            # Only an interrupted command needs a short grace period for its service request.
            (( creation_pending == 1 && SECONDS < recovery_deadline )) || break
            sleep 0.2
        done
    fi
    if [[ -n "$device" ]]; then
        xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
        xcrun simctl delete "$device" >/dev/null 2>&1 || true
        device=""
    fi
    device_name=""
    create_output=""
    creation_pending=0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_child() {
    local status
    "$@" &
    child_pid=$!
    wait "$child_pid"
    status=$?
    child_pid=""
    return "$status"
}

failed=0
for kind in iPhone-17-Pro iPad-Air-13-inch-M4; do
    boot_log=".build/validation/$kind-boot.log"
    test_log=".build/validation/$kind.log"
    # Remove old results so a failed boot cannot appear to have this run's test output.
    : > "$boot_log"
    : > "$test_log"
    device_name="EPUBLib-$kind-$run_id"
    create_output=".build/validation/$kind-create.log"
    : > "$create_output"
    echo "Creating: $kind ($runtime), name: $device_name"
    creation_pending=1
    if run_child xcrun simctl create "$device_name" "com.apple.CoreSimulator.SimDeviceType.$kind" "$runtime" > "$create_output"; then
        creation_pending=0
        device=$(cat "$create_output")
    else
        creation_pending=0
        echo "Failed: $kind ($runtime): simulator creation"
        failed=$((failed + 1))
        cleanup
        continue
    fi
    if [[ -z "$device" ]]; then
        echo "Failed: $kind ($runtime): simulator creation returned no identifier"
        failed=$((failed + 1))
        cleanup
        continue
    fi
    echo "Booting: $kind ($device), limit ${boot_timeout}s; log: $boot_log"
    if ! run_child xcrun simctl boot "$device" > "$boot_log" 2>&1; then
        echo "Failed: $kind ($runtime): simulator boot; see $boot_log"
        cat "$boot_log"
        failed=$((failed + 1))
        cleanup
        continue
    fi
    # exec keeps the alarm on the bootstatus process itself; a stalled migration cannot
    # leave a watchdog's child running. Its last stage remains in the boot log.
    if ! run_child perl -e 'alarm shift; exec @ARGV; die "exec: $!"' "$boot_timeout" \
        xcrun simctl bootstatus "$device" -b >> "$boot_log" 2>&1; then
        echo "Failed: $kind ($runtime): bootstatus failed or exceeded ${boot_timeout}s; see $boot_log"
        cat "$boot_log"
        echo "First-boot migration can stall with other simulators booting or pending host authorization; this is not a test failure."
        failed=$((failed + 1))
        cleanup
        continue
    fi
    cat "$boot_log"
    echo "Testing: $kind ($device); log: $test_log"
    if run_child xcodebuild -scheme EPUBLib-Package -destination "platform=iOS Simulator,id=$device" \
        -destination-timeout 600 -derivedDataPath .build/ios-validation -parallel-testing-enabled NO \
        -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO test > "$test_log" 2>&1; then
        echo "Passed: $kind ($runtime)"
    else
        echo "Failed: $kind ($runtime): tests; see $test_log"
        tail -n 40 "$test_log"
        failed=$((failed + 1))
    fi
    cleanup
done
if (( failed > 0 )); then
    echo "iOS validation failed on $failed of 2 devices"
    exit 1
fi
