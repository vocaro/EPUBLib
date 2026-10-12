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
                    'media-type="application/xhtml+xml"/><item id="labels" href="labels.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="image" href="square.svg" '
                    'media-type="image/svg+xml"/></manifest><spine><itemref '
                    'idref="body"/><itemref idref="labels"/></spine></package>',
 'OPS/nav.xhtml': '<?xml version="1.0" encoding="UTF-8"?><html '
                  'xmlns="http://www.w3.org/1999/xhtml" '
                  'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav '
                  'epub:type="toc"><ol><li><a href="body.xhtml">Page boundary '
                  'verification</a></li><li><a href="labels.xhtml">Hidden '
                  'labels</a></li></ol></nav></body></html>',
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
                   'paragraph.</p></body></html>',
 # What a book hides from the page and keeps for assistive technology, and what it hides from both.
 'OPS/labels.xhtml': '<?xml version="1.0" encoding="UTF-8"?><html '
                     'xmlns="http://www.w3.org/1999/xhtml"><head><title>Hidden '
                     'labels</title><style>.parked { position: absolute; left: -999em; } '
                     '.clipped { position: absolute; width: 1px; height: 1px; overflow: hidden; '
                     'clip: rect(0 0 0 0); } .unseen { position: absolute; left: -999em; '
                     'visibility: hidden; } section img { display: block; width: 96px; height: '
                     '96px; margin: 3em auto 0; }</style></head><body><section><h1 '
                     'class="parked">Parked title heading</h1><p class="parked">By the parked '
                     'author.</p><img src="square.svg" alt=""/></section><p>Shown opening words. '
                     '<span class="clipped">Clipped words in the line.</span> Shown closing '
                     'words.</p><p class="unseen">Words nobody is given.</p><p class="parked" '
                     'aria-hidden="true">Words kept from assistive technology.</p><p><a '
                     'class="parked" href="body.xhtml#link-target">Parked link to the '
                     'target</a>Shown last words.</p></body></html>'}
files["OPS/body.xhtml"] = files["OPS/body.xhtml"].replace(
    "NUMBERED_WORDS", " ".join(f"word{i:04d}" for i in range(1, 1201)))
output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, "w") as archive:
    for name, text in files.items():
        entry = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        entry.compress_type = zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED
        archive.writestr(entry, text.encode())
print(output)
