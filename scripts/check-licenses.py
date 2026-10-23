#!/usr/bin/env python3
"""Hold the license texts EPUBCore ships to their projects' files and to the third-party notices.

An app shows the license and notice texts of EPUBLib and of the code its products contain from
EPUBCore's resource bundle (#699). Each copy must be, byte for byte, its project's file at the
revision Package.resolved pins, read from that dependency's checkout, under the name given here,
and every license or notice file at the top of a pinned package must be copied. The folders must
be the components that doc/third-party-notices.md names, at the versions pinned. Run it after
`swift build` or `swift test`, which check the dependencies out.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

LICENSES = Path('Sources/EPUBCore/Licenses')
# For each pinned package, its folder and where each copy comes from in the package: a file, or
# a folder (ending in `/`) whose files keep their names.
PACKAGES = {
    'zipfoundation': ('ZIPFoundation', {'LICENSE': 'LICENSE'}),
    'mathmllayout': ('MathMLLayout', {'LICENSE.txt': 'LICENSE', '': 'doc/licenses/'}),
    'staticsvg': ('StaticSVG', {'LICENSE.txt': 'LICENSE', 'THIRD_PARTY_NOTICES.md': 'THIRD_PARTY_NOTICES.md',
                                'dependencies.json': 'Resvg/dependencies.json', 'Licenses/': 'Resvg/Licenses/'}),
}
# foliate-js is ported, not a dependency: its license at the commit the port follows.
FOLIATE_COMMIT = '78914aef4466eb960965702401634c2cb348e9b1'
FOLIATE_FILES = {'LICENSE': '5930571b73151702a913179ef5f96313ad7d25d3'}
COMPONENTS = {'EPUBLib', 'foliate-js', *(component for component, _ in PACKAGES.values())}
NOTICE_NAMES = re.compile(r'(LICEN[CS]E|NOTICE|COPYING|COPYRIGHT|THIRD[-_]?PARTY)', re.IGNORECASE)


def blob(data):
    """The Git blob identifier of a file's bytes."""
    return hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()


def copies(folder):
    """Each file in a component's folder, by its path there, with its blob identifier."""
    return {path.relative_to(folder).as_posix(): blob(path.read_bytes()) for path in sorted(folder.rglob('*'))
            if path.is_file() and not any(part.startswith('.') for part in path.relative_to(folder).parts)}


def pinned_files(checkout, revision, sources):
    """The blob of each copy's source at the pinned revision, by the copy's path, and what is missing."""
    listing = subprocess.run(['git', '-C', str(checkout), 'ls-tree', '-r', revision],
                             capture_output=True, text=True)
    if listing.returncode:
        return None, [f'{checkout.name}: no revision {revision} in {checkout}: {listing.stderr.strip()}']
    tree = {}
    for line in listing.stdout.splitlines():
        meta, _, path = line.partition('\t')
        tree[path] = meta.split()[2]
    expected, missing = {}, []
    for copy, source in sources.items():
        if source.endswith('/'):
            found = {copy + path[len(source):]: sha for path, sha in tree.items() if path.startswith(source)}
            expected.update(found)
            if not found:
                missing.append(f'{checkout.name}: no files under {source} at {revision}')
        elif source in tree:
            expected[copy] = tree[source]
        else:
            missing.append(f'{checkout.name}: no {source} at {revision}')
    # A license or notice file at the package's top, such as StaticSVG's THIRD_PARTY_NOTICES.md,
    # is one its redistribution terms name: copy it, or say here why not.
    missing += [f'{checkout.name}: {path} at {revision} is a license or notice file nothing copies'
                for path in sorted(tree) if '/' not in path and NOTICE_NAMES.match(path)
                and path not in sources.values()]
    return expected, missing


def compare(component, expected, actual):
    """What differs between a component's copies and the files they copy."""
    return ([f'{component}/{path}: missing' for path in sorted(expected.keys() - actual.keys())]
            + [f'{component}/{path}: copies nothing pinned' for path in sorted(actual.keys() - expected.keys())]
            + [f'{component}/{path}: differs from its source' for path in sorted(expected.keys() & actual.keys())
               if expected[path] != actual[path]])


def documented(notices):
    """Each component the notices' list names in bold, with the version or commit it gives."""
    found = {}
    for heading, rest in re.findall(r'^- \*\*(.+?)\*\*(.*)$', notices, re.MULTILINE):
        name, _, version = heading.partition(' ')
        commit = re.match(r' at `([0-9a-f]{40})`', rest)
        found[name] = version or (commit[1] if commit else '')
    return found


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--checkouts', type=Path, default=root / '.build/checkouts',
                        help="the folder holding SwiftPM's checkouts of the dependencies")
    args = parser.parse_args()
    licenses = root / LICENSES
    pins = {pin['identity']: pin for pin in json.loads((root / 'Package.resolved').read_text())['pins']}
    problems = []
    if pins.keys() != PACKAGES.keys():
        problems.append(f'Package.resolved pins {sorted(pins)}; this check copies from {sorted(PACKAGES)}')
    # Each component's files, by path in its folder, with the version or commit they come from.
    expected = {'EPUBLib': ({'LICENSE': blob((root / 'LICENSE').read_bytes())}, None),
                'foliate-js': (FOLIATE_FILES, FOLIATE_COMMIT)}
    for identity, (component, sources) in PACKAGES.items():
        if identity not in pins:
            continue
        pin = pins[identity]
        checkout = args.checkouts / pin['location'].rstrip('/').rpartition('/')[2].removesuffix('.git')
        if not checkout.is_dir():
            problems.append(f'{component}: no checkout at {checkout}; run `swift build` first')
            continue
        files, missing = pinned_files(checkout, pin['state']['revision'], sources)
        problems += missing
        if files is not None:
            expected[component] = (files, pin['state'].get('version'))
    entries = sorted(licenses.iterdir()) if licenses.is_dir() else []
    folders = {path.name for path in entries if path.is_dir()}
    problems += [f'{LICENSES}/{name}: no such component' for name in sorted(folders - COMPONENTS)]
    problems += [f'{LICENSES}/{name}: missing' for name in sorted(COMPONENTS - folders)]
    problems += [f'{LICENSES}/{path.name}: outside every component' for path in entries
                 if path.is_file() and not path.name.startswith('.')]
    for component, (files, _) in expected.items():
        if component in folders:
            problems += compare(component, files, copies(licenses / component))
    named = documented((root / 'doc/third-party-notices.md').read_text())
    for component in sorted(COMPONENTS - {'EPUBLib'}):
        version = expected.get(component, ({}, None))[1]
        if component not in named:
            problems.append(f'doc/third-party-notices.md: names no {component}')
        elif version and named[component] != version:
            problems.append(f'doc/third-party-notices.md: {component} at {named[component] or "no version"},'
                            f' pinned at {version}')
    problems += [f'doc/third-party-notices.md: {name} has no folder in {LICENSES}'
                 for name in sorted(named.keys() - COMPONENTS)]
    for line in problems:
        print(f'License texts: {line}', file=sys.stderr)
    if problems:
        return 1
    count = sum(len(files) for files, _ in expected.values())
    print(f'Verified {count} license and notice files of {len(expected)} components against their pinned'
          ' sources and the third-party notices.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
