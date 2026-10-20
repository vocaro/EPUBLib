#!/usr/bin/env python3
"""Generate the sample app's original, deterministic EPUB. Standard library only."""
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parents[1]
output = root / "Examples/ReaderSample/Resources/sample.epub"
output.parent.mkdir(parents=True, exist_ok=True)
# Keep the package modification timestamp fixed so regeneration is deterministic.
files = {
    "mimetype": "application/epub+zip",
    "META-INF/container.xml": '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    "book.opf": '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">epubreaderlib-original-sample</dc:identifier><dc:title>A Small Reading Journey</dc:title><dc:language>en</dc:language><dc:creator>EPUBReaderLib contributors</dc:creator><meta property="dcterms:modified">2026-10-19T00:00:00Z</meta></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>',
    "nav.xhtml": '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="one.xhtml">A quiet beginning</a></li><li><a href="two.xhtml">The next chapter</a></li></ol></nav></body></html>',
}
for name, title in [("one", "A quiet beginning"), ("two", "The next chapter")]:
    paragraphs = "".join(f"<p>Passage {i}: The reader follows a path through the garden. Each turn reveals another view, and each page makes room for a new thought.</p>" for i in range(1, 31))
    files[f"{name}.xhtml"] = f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title></head><body><h1>{title}</h1><p>This original sample belongs to EPUBReaderLib. Try changing the text size, selecting a passage, and saving your position.</p>{paragraphs}</body></html>'
with zipfile.ZipFile(output, "w") as archive:
    for name, text in files.items():
        entry = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        entry.compress_type = zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED
        archive.writestr(entry, text.encode())
print(output)
