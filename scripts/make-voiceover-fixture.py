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
                    'media-type="application/xhtml+xml"/><item id="table" href="table.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="pictures" href="pictures.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="image" href="square.svg" '
                    'media-type="image/svg+xml"/><item id="titled" href="titled.svg" '
                    'media-type="image/svg+xml"/></manifest><spine><itemref '
                    'idref="body"/><itemref idref="labels"/><itemref '
                    'idref="table"/><itemref idref="pictures"/></spine></package>',
 'OPS/nav.xhtml': '<?xml version="1.0" encoding="UTF-8"?><html '
                  'xmlns="http://www.w3.org/1999/xhtml" '
                  'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav '
                  'epub:type="toc"><ol><li><a href="body.xhtml">Page boundary '
                  'verification</a></li><li><a href="labels.xhtml">Hidden '
                  'labels</a></li><li><a href="table.xhtml">Hidden heading over a '
                  'table</a></li><li><a href="pictures.xhtml">Pictures and their '
                  'words</a></li></ol></nav></body></html>',
 'OPS/square.svg': '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 '
                   '32"><rect width="32" height="32" fill="#007acc"/></svg>',
 'OPS/titled.svg': '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 '
                   '32"><title>Square with a title of its own</title><rect width="32" height="32" '
                   'fill="#cc7a00"/></svg>',
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
                     'target</a>Shown last words.</p></body></html>',
 # A hidden heading over a table that opens a section: hidden labels alone on a line of no height.
 'OPS/table.xhtml': '<?xml version="1.0" encoding="UTF-8"?><html '
                    'xmlns="http://www.w3.org/1999/xhtml"><head><title>Hidden heading over a '
                    'table</title><style>.parked { position: absolute; left: -999em; } td { '
                    'padding: 0.25em 0.5em; }</style></head><body><h1 class="parked">Parked '
                    'table heading</h1><table><tr><td>First cell</td><td>Second '
                    'cell</td></tr><tr><td>Third cell</td><td>Fourth '
                    'cell</td></tr></table><p>Shown words after the table.</p>LINES_AFTER</body></html>',
 # What a book says a picture is to someone who cannot see it: nothing at all, decoration (an
 # empty alt), or words; alone, inside a link, and in a file that has a title of its own. No
 # word here is one VoiceOver uses for a picture or a link, so those in a transcript are its own.
 'OPS/pictures.xhtml': '<?xml version="1.0" encoding="UTF-8"?><html '
                       'xmlns="http://www.w3.org/1999/xhtml"><head><title>Pictures and their '
                       'words</title><style>img { width: 32px; height: 32px; '
                       '}</style></head><body><h1>Pictures and their words</h1><p>Undescribed '
                       'picture <img src="square.svg"/> stands here.</p><p>Decoration <img '
                       'src="square.svg" alt=""/> passed over.</p><p>Bare jump: <a '
                       'href="body.xhtml#link-target"><img src="square.svg" '
                       'alt=""/></a></p><p><a href="body.xhtml#link-target"><img '
                       'src="square.svg" alt=""/> Jump with decoration</a></p><p><a '
                       'href="body.xhtml#link-target"><img src="square.svg" alt="Described '
                       'jump"/></a></p><p>Titled decoration <img src="titled.svg" alt=""/> '
                       'passed over.</p><p>Titled picture <img src="titled.svg"/> stands '
                       'here.</p><p>Last words about pictures.</p></body></html>'}
files["OPS/body.xhtml"] = files["OPS/body.xhtml"].replace(
    "NUMBERED_WORDS", " ".join(f"word{i:04d}" for i in range(1, 1201)))
# More than a screen of lines, so that the section's first line can be shown at the top.
files["OPS/table.xhtml"] = files["OPS/table.xhtml"].replace(
    "LINES_AFTER", "".join(f"<p>Line {i:02d} after the table.</p>" for i in range(1, 61)))

# A second book of ordinary paragraphs, for continuous scroll: chapters of forty, forty and six
# paragraphs, each of forty numbered words ("p017w23" is the seventeenth paragraph's
# twenty-third), so a line in the middle of a paragraph can be told from its first, and the
# end of the book is a few screens from the start of its last chapter.
chapters = {"one": range(1, 41), "two": range(41, 81), "three": range(81, 87)}
paragraphs = dict(files)
for name in ["body.xhtml", "labels.xhtml", "table.xhtml", "pictures.xhtml", "square.svg", "titled.svg"]:
    del paragraphs["OPS/" + name]
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
