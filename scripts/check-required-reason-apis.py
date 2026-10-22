#!/usr/bin/env python3
"""Verify that the five library targets, StaticSVG and resvg call none of Apple's required-reason APIs.

An app must declare in a privacy manifest, with a reason, each use of an API that reads the
system boot time, file timestamps, disk space, the active keyboards or user defaults, and App
Store Connect refuses an upload that uses one undeclared. EPUBLib ships no manifest, so its
targets, and the StaticSVG package and the resvg library EPUBViewing links, use none of them
(#685). This reads the objects compiled for the Mac by `swift test` and for iOS by
scripts/test-ios.sh, StaticSVG's among them, and the resvg slices of the framework StaticSVG's
release supplies, for what those APIs compile to: a C function, a Foundation key, a message sent,
the user defaults class or a `URLResourceValues` property. ZIPFoundation declares its own use in the
manifest it ships. The APIs are Apple's list in
https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys

TARGETS = ('EPUBCore', 'EPUBReading', 'EPUBText', 'EPUBWriting', 'EPUBViewing', 'StaticSVG')
PLATFORMS = ('iOS', 'macOS')
# PLATFORM_MACOS, PLATFORM_IOS and PLATFORM_IOSSIMULATOR in <mach-o/loader.h>.
PLATFORM_NUMBERS = {1: 'macOS', 2: 'iOS', 7: 'iOS'}
BOOT_TIME, FILE_TIMESTAMP, DISK_SPACE = 'system boot time', 'file timestamp', 'disk space'
FUNCTIONS = {
    'mach_absolute_time': BOOT_TIME,
    **dict.fromkeys(('stat', 'fstat', 'fstatat', 'lstat'), FILE_TIMESTAMP),
    **dict.fromkeys(('getattrlist', 'getattrlistbulk', 'fgetattrlist', 'getattrlistat'),
                    f'{FILE_TIMESTAMP} or {DISK_SPACE}'),
    **dict.fromkeys(('statfs', 'fstatfs', 'statvfs', 'fstatvfs'), DISK_SPACE),
}
CONSTANTS = {
    **dict.fromkeys(('NSFileCreationDate', 'NSFileModificationDate', 'NSURLCreationDateKey',
                     'NSURLContentModificationDateKey'), FILE_TIMESTAMP),
    **dict.fromkeys(('NSFileSystemFreeSize', 'NSFileSystemSize', 'NSURLVolumeAvailableCapacityKey',
                     'NSURLVolumeAvailableCapacityForImportantUsageKey',
                     'NSURLVolumeAvailableCapacityForOpportunisticUsageKey',
                     'NSURLVolumeTotalCapacityKey'), DISK_SPACE),
}
SELECTORS = {'systemUptime': BOOT_TIME, 'activeInputModes': 'active keyboards',
             'fileCreationDate': FILE_TIMESTAMP, 'fileModificationDate': FILE_TIMESTAMP}
CLASSES = {'NSUserDefaults': 'user defaults'}
RESOURCE_VALUES = {
    **dict.fromkeys(('creationDate', 'contentModificationDate'), FILE_TIMESTAMP),
    **dict.fromkeys(('volumeAvailableCapacity', 'volumeAvailableCapacityForImportantUsage',
                     'volumeAvailableCapacityForOpportunisticUsage', 'volumeTotalCapacity'), DISK_SPACE),
}
RESOURCE_VALUES_MEMBER = '$s10Foundation17URLResourceValuesV'


def category(symbol):
    """The required-reason category of an undefined symbol, or None."""
    name = symbol.removeprefix('_')
    if name.startswith('objc_msgSend$'):
        return SELECTORS.get(name.removeprefix('objc_msgSend$'))
    if name.startswith('OBJC_CLASS_$_'):
        return CLASSES.get(name.removeprefix('OBJC_CLASS_$_'))
    if name.startswith(RESOURCE_VALUES_MEMBER):
        # A Swift identifier is mangled as its length and then its characters.
        member = re.match(r'(\d+)', name.removeprefix(RESOURCE_VALUES_MEMBER))
        if not member:
            return None
        start = len(RESOURCE_VALUES_MEMBER) + len(member[1])
        return RESOURCE_VALUES.get(name[start:start + int(member[1])])
    # `stat$INODE64` and other variants are the function they are named for.
    return FUNCTIONS.get(name.split('$')[0]) or CONSTANTS.get(name)


def target(path):
    """The library target an object was compiled for, from its build folder, or None."""
    return next((name for name in TARGETS for part in path.parts
                 if re.fullmatch(rf'{name}(-\w+)?\.build', part)), None)


def tool_lines(command, objects):
    """What an Xcode tool prints for the objects, given 200 at a time."""
    for start in range(0, len(objects), 200):
        yield from subprocess.run(['xcrun', *command, *map(str, objects[start:start + 200])], check=True,
                                  capture_output=True, text=True).stdout.splitlines()


def platforms(objects):
    """The platform each object was built for, from its LC_BUILD_VERSION load command."""
    found, current = {}, None
    for line in tool_lines(['otool', '-l'], objects):
        if line.endswith(':') and not line[:1].isspace():
            current = Path(line[:-1])
        elif (number := re.fullmatch(r'\s*platform (\d+)', line)) and current is not None:
            found[current] = PLATFORM_NUMBERS.get(int(number[1]))
    return found


def undefined_symbols(objects):
    """Each object's undefined symbols, from `nm -u -A`, which names the object on every line."""
    symbols = {path: [] for path in objects}
    for line in tool_lines(['nm', '-u', '-A'], objects):
        path, _, symbol = line.partition(': ')
        if path:
            symbols[Path(path)].append(symbol.strip())
    return symbols


def resvg_findings(frameworks):
    """What the resvg slices import from the list, and any slice that could not be read.

    Its link-time optimization leaves in each archive only what the C API's functions reach, so
    what an archive imports is all that an app could. Each member carries LLVM bitcode, which
    Xcode's `nm` may not read; it reads the machine code alone, and every member must be read.
    """
    findings, unread = [], []
    slices = sorted(archive for framework in frameworks for archive in framework.glob('*/libresvg.a'))
    for archive in slices:
        kind = 'macOS' if archive.parent.name.startswith('macos') else 'iOS'
        result = subprocess.run(['xcrun', 'nm', '--no-llvm-bc', '-arch', 'all', '-u', '-A', str(archive)],
                                capture_output=True, text=True)
        lines, error = result.stdout.splitlines(), result.stderr.strip()
        if result.returncode or error or not lines:
            unread.append(f'{archive.parent.name}: {error.splitlines()[0] if error else "no symbols"}')
        for line in lines:
            member, _, symbol = line.rpartition(': ')
            if category(symbol):
                findings.append(f'CResvg ({kind}) {member.rpartition("/")[2]}: {symbol} ({category(symbol)})')
    if not slices:
        unread.append(f'no libresvg.a under {", ".join(map(str, frameworks))}')
    return findings, unread


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    # Swift Build keeps the Mac objects under `out`, SwiftPM's own build system under `debug`.
    parser.add_argument('roots', nargs='*', type=Path,
                        default=[root / '.build/out/Intermediates.noindex', root / '.build/debug',
                                 root / '.build/ios-validation/Build/Intermediates.noindex'],
                        help='folders to search for compiled objects')
    args = parser.parse_args()
    targets = {path: name for folder in args.roots if folder.exists()
               for path in sorted(folder.resolve().rglob('*.o')) if (name := target(path))}
    platform = platforms(list(targets))
    counts = {(name, kind): 0 for name in TARGETS for kind in PLATFORMS}
    for path, name in targets.items():
        if (name, platform.get(path)) in counts:
            counts[name, platform[path]] += 1
    findings = [f'{targets[path]} ({platform.get(path) or "other platform"}) {path.name}: {symbol} ({kind})'
                for path, symbols in undefined_symbols(list(targets)).items()
                for symbol in symbols if (kind := category(symbol))]
    missing = [f'{name} ({kind})' for (name, kind), count in counts.items() if count == 0]
    # SwiftPM keeps StaticSVG's framework under `artifacts`, and the iOS build under its own packages.
    frameworks = [root / '.build/artifacts/staticsvg/CResvg/Resvg.xcframework',
                  root / '.build/ios-validation/SourcePackages/artifacts/staticsvg/CResvg/Resvg.xcframework']
    resvg, unread = resvg_findings([framework for framework in frameworks if framework.exists()] or frameworks[:1])
    findings += resvg
    for line in findings:
        print(f'Required-reason API: {line}', file=sys.stderr)
    if missing:
        print(f'No compiled objects for {", ".join(missing)} under {", ".join(map(str, args.roots))};'
              ' run `swift test` and scripts/test-ios.sh first.', file=sys.stderr)
    for line in unread:
        print(f'Unread resvg slice: {line}', file=sys.stderr)
    if findings or missing or unread:
        return 1
    print(f'Verified that {len(targets)} objects of five targets and StaticSVG on iOS and macOS, and the'
          ' resvg slices, use no required-reason API.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
