#!/usr/bin/env python3
"""Verify the independently selectable EPUB products and their headless dependency boundaries."""
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
manifest = json.loads(subprocess.check_output(['swift', 'package', 'dump-package'], cwd=root, text=True))
expected = {
    'EPUBCore': set(),
    'EPUBReading': {'EPUBCore', 'ZIPFoundation'},
    'EPUBText': {'EPUBCore', 'EPUBReading'},
    'EPUBWriting': {'EPUBCore', 'ZIPFoundation'},
    'EPUBViewing': {'EPUBCore', 'EPUBReading', 'MathMLLayout'},
}
# Internal targets that ship inside a product. MathMLLayout is independent of EPUB and may move
# to its own package; it must never import an EPUBLib module or a UI framework.
internal = {'MathMLLayout': set()}
products = {product['name']: product['targets'] for product in manifest['products']}
assert products == {name: [name] for name in expected}, products
for target in manifest['targets']:
    if target['name'] not in expected:
        continue
    dependencies = {next(iter(item.values()))[0] for item in target['dependencies']}
    assert dependencies == expected[target['name']], (target['name'], dependencies)
    if target['name'] != 'EPUBViewing':
        for source in (root / 'Sources' / target['name']).glob('*.swift'):
            imports = set(re.findall(r'^import (\w+)', source.read_text(), re.MULTILINE))
            assert not imports & {'SwiftUI', 'WebKit', 'PDFKit', 'Vision', 'EPUBViewing'}, source
for target in manifest['targets']:
    if target['name'] in internal:
        dependencies = {next(iter(item.values()))[0] for item in target['dependencies']}
        assert dependencies == internal[target['name']], (target['name'], dependencies)
        for source in (root / 'Sources' / target['name']).rglob('*.swift'):
            imports = set(re.findall(r'^import (\w+)', source.read_text(), re.MULTILINE))
            assert not imports & {'SwiftUI', 'UIKit', 'AppKit', 'WebKit', 'JavaScriptCore', 'EPUBCore',
                                  'EPUBReading', 'EPUBText', 'EPUBWriting', 'EPUBViewing'}, source
print('Verified five independent products and headless dependency boundaries.')
