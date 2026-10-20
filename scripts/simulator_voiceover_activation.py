"""Guarded simulator-only VoiceOver cursor dispatch; qualification: issue #495."""
import hashlib
import json
import re
from pathlib import Path
from uuid import uuid4

RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-27-2'
BUILD = '24B5110a'
VOT_SHA256 = 'eff48aa54691d86f352370f71dce32fcbec847b34967b9446bebce17a4f360fd'
MARKER = 'EPUB495: cursor activation v1 enabled build ' + BUILD
QUALIFIED = False  # Flip only after the recorded qualification passes.


def prepare(root, derived, runtime, run):
    runtimes = json.loads(run('xcrun', 'simctl', 'list', 'runtimes', '--json'))['runtimes']
    found = next((item for item in runtimes if item['identifier'] == runtime), None)
    if runtime != RUNTIME or not found or found['buildversion'] != BUILD:
        raise RuntimeError('Cursor activation is not qualified for this runtime/build; use --activation stock for a stock recording')
    binary = Path(found['runtimeRoot']) / 'System/Library/CoreServices/VoiceOverTouch.app/vot'
    if hashlib.sha256(binary.read_bytes()).hexdigest() != VOT_SHA256:
        raise RuntimeError('VoiceOver executable differs from the qualified SHA-256; refusing injection')
    # Never replace a dylib mapped by another concurrent run in this worktree.
    library = derived / 'cursor-activation' / f'v1-{uuid4().hex}.dylib'
    library.parent.mkdir(parents=True, exist_ok=True)
    run('xcrun', '--sdk', 'iphonesimulator', 'clang', '-dynamiclib',
        '-target', 'arm64-apple-ios27.0-simulator',
        str(root / 'scripts/probe-simulator-voiceover-activation.m'),
        '-framework', 'Foundation', '-o', str(library), timeout=120)
    run('codesign', '--force', '--sign', '-', str(library))
    return library.resolve()


def evidence_failures(log, vot):
    failures = []
    observed = set(re.findall(r'\bvot\[(\d+):', vot))
    confirmed = {match[1] for line in vot.splitlines() if MARKER in line
                 for match in [re.search(r'\bvot\[(\d+):', line)] if match}
    if not confirmed:
        failures.append('cursor activation hook did not confirm its validated installation')
    if observed - confirmed:
        failures.append('a VoiceOver process did not confirm the hook after a restart')
    if 'EPUB495: refused' in vot:
        failures.append('cursor activation hook refused an unknown implementation')
    if 'VOICEOVER_ACTIVATION_CHECK passed:' not in log:
        failures.append('cursor activation startup self-test did not pass')
    return failures
