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

# A second book of ordinary paragraphs, for continuous scroll: chapters of forty, forty and six
# paragraphs, each of forty numbered words ("p017w23" is the seventeenth paragraph's
# twenty-third), so a line in the middle of a paragraph can be told from its first, and the
# end of the book is a few screens from the start of its last chapter.
chapters = {"one": range(1, 41), "two": range(41, 81), "three": range(81, 87)}
paragraphs = dict(files)
del paragraphs["OPS/body.xhtml"], paragraphs["OPS/square.svg"]
paragraphs["OPS/package.opf"] = (
    '<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
    'unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier '
    'id="id">urn:uuid:5d0f8f0e-2f1c-4a57-9d0b-3c1f6c2a9e11</dc:identifier><dc:title>VoiceOver Paragraph '
    'Verification</dc:title><dc:language>en</dc:language><meta '
    'property="dcterms:modified">2026-10-12T00:00:00Z</meta></metadata><manifest><item id="nav" '
    'href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
    + "".join(f'<item id="c{n}" href="chapter{n}.xhtml" media-type="application/xhtml+xml"/>' for n in range(1, 4))
    + "</manifest><spine>" + "".join(f'<itemref idref="c{n}"/>' for n in range(1, 4)) + "</spine></package>")
paragraphs["OPS/nav.xhtml"] = (
    '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" '
    'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav '
    'epub:type="toc"><ol>'
    + "".join(f'<li><a href="chapter{n}.xhtml">Chapter {name}</a></li>' for n, name in enumerate(chapters, 1))
    + "</ol></nav></body></html>")
for n, (name, numbers) in enumerate(chapters.items(), 1):
    body = "".join("<p>" + " ".join(f"p{p:03d}w{w:02d}" for w in range(1, 41)) + "</p>" for p in numbers)
    paragraphs[f"OPS/chapter{n}.xhtml"] = (
        '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter '
        f"{name}</title></head><body><h1>Chapter {name}</h1>{body}</body></html>")

output.parent.mkdir(parents=True, exist_ok=True)
for path, book in [(output, files), (output.with_name("paragraphs.epub"), paragraphs)]:
    with zipfile.ZipFile(path, "w") as archive:
        for name, text in book.items():
            entry = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED
            archive.writestr(entry, text.encode())
    print(path)
