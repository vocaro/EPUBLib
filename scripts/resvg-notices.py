#!/usr/bin/env python3
"""Collect the pinned normal Rust dependencies' complete license and notice files."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

metadata_path, source_path, rust_path, output_path = map(Path, sys.argv[1:])
metadata = json.loads(metadata_path.read_text())
packages = {package['id']: package for package in metadata['packages']}
nodes = {node['id']: node for node in metadata['resolve']['nodes']}
root = next(key for key, package in packages.items() if package['name'] == 'resvg-capi')
seen, pending = set(), [root]
while pending:
    key = pending.pop()
    if key in seen:
        continue
    seen.add(key)
    pending.extend(dep['pkg'] for dep in nodes[key]['deps'] if any(kind['kind'] is None for kind in dep['dep_kinds']))
licenses = output_path / 'Licenses'
licenses.mkdir(parents=True, exist_ok=True)
inventory = []
for package in sorted((packages[key] for key in seen), key=lambda item: item['name']):
    directory = Path(package['manifest_path']).parent
    files = [path for path in directory.iterdir() if path.is_file() and any(word in path.name.lower() for word in ('license', 'copyright', 'notice', 'copying'))]
    if not files and package['name'] in ('resvg', 'usvg', 'resvg-capi'):
        files = [source_path / 'LICENSE-MIT', source_path / 'LICENSE-APACHE']
    assert files, f"Missing license texts: {package['name']}"
    destination = licenses / f"{package['name']}-{package['version']}"
    destination.mkdir(exist_ok=True)
    for path in files:
        shutil.copyfile(path, destination / path.name)
    inventory.append({'name': package['name'], 'version': package['version'], 'license': package['license'], 'repository': package.get('repository'), 'texts': [str((destination / path.name).relative_to(output_path)) for path in files]})
rust_destination = licenses / 'rust-1.95.0'
rust_destination.mkdir(exist_ok=True)
shutil.copyfile(rust_path / 'COPYRIGHT-library.html', rust_destination / 'COPYRIGHT-library.html')
shutil.copytree(rust_path / 'licenses', rust_destination / 'licenses', dirs_exist_ok=True)
(output_path / 'dependencies.json').write_text(json.dumps(inventory, indent=2) + '\n')
checksums = {str(path.relative_to(output_path)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted((output_path / 'Resvg.xcframework').glob('*/libresvg.a'))}
(output_path / 'checksums.json').write_text(json.dumps(checksums, indent=2) + '\n')
