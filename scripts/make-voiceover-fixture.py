#!/usr/bin/env python3
"""Generate the original deterministic VoiceOver EPUB using the standard library."""
from pathlib import Path
import zipfile

output = Path(__file__).resolve().parents[1] / "Examples/VoiceOverVerification/Resources/sample.epub"
files = {'mimetype': 'application/epub+zip',
 'META-INF/container.xml': '<?xml version="1.0" encoding="UTF-8"?><container version="1.0" '
                           'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile '
                           'full-path="OPS/package.opf" '
                           'media-type="application/oebps-package+xml"/></rootfiles></container>',
 'OPS/package.opf': '<?xml version="1.0" encoding="UTF-8"?><package '
                    'xmlns="http://www.idpf.org/2007/opf" version="3.0" '
                    'unique-identifier="id"><metadata '
                    'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier '
                    'id="id">urn:uuid:9190a073-7dbb-4c58-a261-d7ab529b744a</dc:identifier><dc:title>VoiceOver '
                    'Page Boundary Verification</dc:title><dc:language>en</dc:language><meta '
                    'property="dcterms:modified">2026-10-11T00:00:00Z</meta></metadata><manifest><item '
                    'id="nav" href="nav.xhtml" media-type="application/xhtml+xml" '
                    'properties="nav"/><item id="body" href="body.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="image" href="square.svg" '
                    'media-type="image/svg+xml"/></manifest><spine><itemref '
                    'idref="body"/></spine></package>',
 'OPS/nav.xhtml': '<?xml version="1.0" encoding="UTF-8"?><html '
                  'xmlns="http://www.w3.org/1999/xhtml" '
                  'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav '
                  'epub:type="toc"><ol><li><a href="body.xhtml">Page boundary '
                  'verification</a></li></ol></nav></body></html>',
 'OPS/square.svg': '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 '
                   '32"><rect width="32" height="32" fill="#007acc"/></svg>',
 'OPS/body.xhtml': '<?xml version="1.0" encoding="UTF-8"?><html '
                   'xmlns="http://www.w3.org/1999/xhtml"><head><title>Page boundary '
                   'verification</title><style>p.sequence { text-align: justify; } img { width: '
                   '32px; height: 32px; }</style></head><body><h1>Page boundary '
                   'verification</h1><p>Read the numbered words across two consecutive pages. The '
                   'next page must resume at the next numbered word.</p><p><a '
                   'href="#link-target">Verification link</a>. Image: <img src="square.svg" '
                   'alt="Blue verification square"/>.</p><p class="sequence">NUMBERED_WORDS</p><h2 '
                   'id="link-target">Link target reached</h2><p>This is the end of the numbered '
                   'paragraph.</p></body></html>'}
files["OPS/body.xhtml"] = files["OPS/body.xhtml"].replace(
    "NUMBERED_WORDS", " ".join(f"word{i:04d}" for i in range(1, 1201)))
output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, "w") as archive:
    for name, text in files.items():
        entry = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        entry.compress_type = zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED
        archive.writestr(entry, text.encode())
print(output)
