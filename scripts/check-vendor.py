#!/usr/bin/env python3
"""Verify the exact bundled upstream inventory and recorded content identities."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'doc/vendor-manifest.json').read_text())
assets = root / 'Sources/EPUBViewing/Resources/epub-reader'
expected = set()
for component in manifest['components']:
    for entry in component['files']:
        name = entry['bundlePath']
        expected.add(name)
        path = assets / name
        assert not path.is_symlink() and path.is_file(), name
        data = path.read_bytes()
        assert len(data) == entry['bytes'], name
        assert hashlib.sha256(data).hexdigest() == entry['sha256'], name
        assert hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() == entry['blobSHA1'], name
actual = {str(p.relative_to(assets)) for p in (assets / 'lib').rglob('*') if p.is_file()}
assert actual == expected, (actual - expected, expected - actual)
print(f'Verified {len(expected)} vendored files and their license texts.')
