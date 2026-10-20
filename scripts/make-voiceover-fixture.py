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
                    'media-type="application/xhtml+xml"/><item id="scenes" href="scenes.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="offers" href="offers.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="entries" href="entries.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="cells" href="cells.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="grids" href="grids.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="ledger" href="ledger.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="tallrow" href="tallrow.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="edges" href="edges.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="parts" href="parts.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="squares" href="squares.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="gaps" href="gaps.xhtml" '
                    'media-type="application/xhtml+xml"/><item id="image" href="square.svg" '
                    'media-type="image/svg+xml"/><item id="titled" href="titled.svg" '
                    'media-type="image/svg+xml"/></manifest><spine><itemref '
                    'idref="body"/><itemref idref="labels"/><itemref '
                    'idref="table"/><itemref idref="pictures"/><itemref '
                    'idref="scenes"/><itemref idref="offers"/><itemref idref="entries"/><itemref idref="cells"/><itemref '
                    'idref="grids"/><itemref idref="ledger"/><itemref idref="tallrow"/><itemref '
                    'idref="edges"/><itemref idref="parts"/><itemref idref="squares"/><itemref idref="gaps"/></spine></package>',
 'OPS/nav.xhtml': '<?xml version="1.0" encoding="UTF-8"?><html '
                  'xmlns="http://www.w3.org/1999/xhtml" '
                  'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav '
                  'epub:type="toc"><ol><li><a href="body.xhtml">Page boundary '
                  'verification</a></li><li><a href="labels.xhtml">Hidden '
                  'labels</a></li><li><a href="table.xhtml">Hidden heading over a '
                  'table</a></li><li><a href="pictures.xhtml">Pictures and their '
                  'words</a></li><li><a href="scenes.xhtml">Scenes set '
                  'apart</a></li><li><a href="offers.xhtml">What each line '
                  'offers</a></li><li><a href="entries.xhtml">Things inside '
                  'entries</a></li><li><a href="cells.xhtml">Jumps inside a '
                  'grid</a></li><li><a href="grids.xhtml">Tables of data</a></li><li><a '
                  'href="ledger.xhtml">A table longer than a page</a></li><li><a '
                  'href="tallrow.xhtml">A row taller than a page</a></li><li><a '
                  'href="edges.xhtml">Jumps at the edges of a grid</a></li><li><a '
                  'href="parts.xhtml">Parts below a jump</a></li><li><a '
                  'href="squares.xhtml">Squares inside grids</a></li><li><a '
                  'href="gaps.xhtml">Gaps inside grids</a></li></ol></nav></body></html>',
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
                   'id="activation-link" href="#link-target">Verification link</a>. Image: <img id="verification-image" src="square.svg" '
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
 # empty alt), or words; alone, inside a link, and in a file that has a title of its own. Then
 # pictures it keeps from assistive technology (role="presentation" or "none", aria-hidden),
 # whose words begin "Unspoken" and are never to be heard, and two it does not: aria-hidden
 # "false", and a presentational role ARIA ignores for a global ARIA attribute. No word here
 # is one VoiceOver uses for a picture or a link, so those in a transcript are its own.
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
                       'here.</p><p>Ornament <img src="square.svg" alt="Unspoken ornament words" '
                       'role="presentation"/> passed over.</p><p>Plain ornament <img src="square.svg" '
                       'role="none"/> passed over.</p><p>Kept square <img src="square.svg" '
                       'alt="Unspoken kept words" aria-hidden="true"/> passed over.</p><p>Drawn square '
                       '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" '
                       'aria-hidden="true"><title>Unspoken drawn title</title><rect width="32" '
                       'height="32" fill="#7a00cc"/></svg> passed over.</p><p>Quiet jump: <a '
                       'href="body.xhtml#link-target"><img src="square.svg" alt="Unspoken jump words" '
                       'aria-hidden="true"/></a></p><p><a href="body.xhtml#link-target"><img '
                       'src="square.svg" alt="Unspoken" role="presentation"/> Jump with an '
                       'ornament</a></p><p>Shown square <img src="square.svg" alt="Square shown to all" '
                       'aria-hidden="false"/> stands here.</p><p>Noted square <img src="square.svg" '
                       'alt="Square with a note" role="presentation" aria-describedby="picture-note"/> '
                       'stands here.</p><p id="picture-note">Last words about pictures.</p></body></html>',
 # What stands between two scenes: a rule, which HTML makes a change of subject and not a
 # picture; three the book keeps from assistive technology as ornament, with the presentation
 # role, the role none and aria-hidden; and one alone on its page, where it is all VoiceOver
 # has to stand on. No word here is one a screen reader uses for a rule, so those in a
 # transcript are VoiceOver's or the reader's own.
 'OPS/scenes.xhtml': '<?xml version="1.0" encoding="UTF-8"?><html '
                     'xmlns="http://www.w3.org/1999/xhtml"><head><title>Scenes set '
                     'apart</title><style>.alone, .after { break-before: page; '
                     '}</style></head><body><h1>Scenes set apart</h1><p>First scene '
                     'ends.</p><hr/><p>Second scene starts.</p><hr '
                     'role="presentation"/><p>Words after an ornament.</p><hr role="none"/><p>Words '
                     'after a plain ornament.</p><hr aria-hidden="true"/><p>Words after a kept '
                     'ornament.</p><div '
                     'class="alone"><hr/></div><p class="after">Last words of the '
                     'scenes.</p></body></html>',
 # What each item of a page or a screen has to offer through VoiceOver's rotor, all in sight at
 # once: lines of words, a jump inside a line, a picture with words and one without, and a
 # table row with a jump in a cell. No word here is one VoiceOver uses for an action, a picture
 # or a link, so those in a transcript are VoiceOver's or the reader's own.
 'OPS/offers.xhtml': '<?xml version="1.0" encoding="UTF-8"?><html '
                     'xmlns="http://www.w3.org/1999/xhtml"><head><title>What each line '
                     'offers</title><style>img { width: 32px; height: 32px; } td { padding: '
                     '0.25em 0.5em; }</style></head><body><h1>What each line '
                     'offers</h1><p>Plain words above.</p><p>Words before <a '
                     'href="body.xhtml#link-target">Lone jump</a> words after.</p><p>Described '
                     'picture <img src="square.svg" alt="Square with words"/> ends its '
                     'line.</p><p>Nameless picture <img src="square.svg"/> ends its '
                     'line.</p><table><tr><td>Left cell</td><td><a '
                     'href="body.xhtml#link-target">Right cell '
                     'jump</a></td></tr></table><p>Plain words '
                     'below.</p>LINES_BELOW</body></html>',
 # What a table's entry can hold besides words: a rule between two paragraphs, a formula, a
 # described picture, a hidden label, decoration, a picture nobody describes and a table of
 # its own. Each entry is a text of its own to VoiceOver on a Mac. A second formula stands
 # after the table, in the page's own text, to compare. The section has no heading, and no
 # word here is one a screen reader uses for a rule, a picture, a formula, a table or a text.
 'OPS/entries.xhtml': '<?xml version="1.0" encoding="UTF-8"?><html '
                      'xmlns="http://www.w3.org/1999/xhtml"><head><title>Things inside '
                      'entries</title><style>.parked { position: absolute; left: -999em; } td { '
                      'padding: 0.25em 0.5em; } img { width: 32px; height: 32px; '
                      '}</style></head><body><p>Entries follow.</p><table><tr><td><p>Upper part '
                      'closes.</p><hr/><p>Lower half opens.</p></td><td>Sum <math '
                      'xmlns="http://www.w3.org/1998/Math/MathML" alttext="x '
                      'squared"><msup><mi>x</mi><mn>2</mn></msup></math> '
                      'stated.</td></tr><tr><td>Drawn <img src="square.svg" alt="Blue entry '
                      'square"/> shown.</td><td><span class="parked">Parked entry '
                      'words.</span>Seen entry words.</td></tr><tr><td>Ornament <img '
                      'src="square.svg" alt=""/> passed.</td><td>Undescribed <img '
                      'src="square.svg"/> stands.</td></tr><tr><td><table><tr><td>Inner '
                      'one</td><td>Inner two</td></tr></table></td><td>Beside the inner '
                      'grid.</td></tr></table><p>Beyond them <math '
                      'xmlns="http://www.w3.org/1998/Math/MathML" alttext="y '
                      'cubed"><msup><mi>y</mi><mn>3</mn></msup></math> '
                      'ends.</p>ENTRY_LINES_AFTER</body></html>',
 # Links inside the cells of a table: one of words in a cell that runs on to more lines, one
 # that is a described picture, one that is decoration alone, one of decoration and words, and
 # one that is a hidden label. Like the section before it this one has no heading, and no
 # word here is one VoiceOver uses for a picture, a link, a table or a text, so those in a
 # transcript are VoiceOver's or the reader's own.
 'OPS/cells.xhtml': '<?xml version="1.0" encoding="UTF-8"?><html '
                    'xmlns="http://www.w3.org/1999/xhtml"><head><title>Jumps inside a '
                    'grid</title><style>.parked { position: absolute; left: -999em; } td { '
                    'padding: 0.25em 0.5em; } img { width: 32px; height: 32px; '
                    '}</style></head><body><p>Jumps inside a grid</p><p>Shown words before '
                    'the grid.</p><table><tr><td>Plain first entry.</td><td>Before the <a '
                    'href="body.xhtml#link-target">worded jump</a> after it, and then enough '
                    'further words to carry this entry on to another line.</td></tr><tr><td>Described: '
                    '<a href="body.xhtml#link-target"><img src="square.svg" alt="Described '
                    'entry jump"/></a></td><td>Bare: <a href="body.xhtml#link-target"><img '
                    'src="square.svg" alt=""/></a></td></tr><tr><td><a '
                    'href="body.xhtml#link-target"><img src="square.svg" alt=""/> Entry jump '
                    'with decoration</a></td><td><a class="parked" '
                    'href="body.xhtml#link-target">Parked entry jump</a>Shown last '
                    'entry.</td></tr></table><p>Shown words after the '
                    'grid.</p>GRID_LINES_AFTER</body></html>'}
# Tables that are data, and one that is not. The first has a caption, a header row and a header
# cell in each row, an empty cell and a link. The second has header cells that span columns and
# rows and data cells that do. The third is marked as layout, though it is ruled like the
# others. The fourth has nothing but its rules to say that it is data. No word here is one
# VoiceOver uses for a table, so "row", "column" and "table" in a transcript are its own.
CELL_STYLE = "td, th { padding: 0.25em 0.5em; border: 1px solid gray; } table { border-collapse: collapse; }"
files["OPS/grids.xhtml"] = (
    '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Tables of '
    f"data</title><style>{CELL_STYLE}</style></head><body><h1>Tables of data</h1><p>Words before the stations.</p>"
    "<table><caption>Stations on the branch</caption><thead><tr><th>Station</th><th>Opened</th><th>Depth</th></tr></thead>"
    '<tbody><tr><th id="activation-cell" scope="row">Alder</th><td>1901</td><td>Twelve metres</td></tr>'
    '<tr><th scope="row">Birch</th><td>1934</td><td></td></tr>'
    '<tr><th scope="row">Cedar</th><td><a href="body.xhtml#link-target">Reopened 1978</a></td><td>Forty metres</td></tr>'
    "</tbody></table><p>Words between the grids.</p>"
    '<table><tr><th rowspan="2">Service</th><th colspan="2">Hours</th></tr><tr><th>Leaves</th><th>Arrives</th></tr>'
    "<tr><td>Express</td><td>Nine</td><td>Noon</td></tr>"
    '<tr><td rowspan="2">Stopper</td><td>Ten</td><td>Three</td></tr><tr><td colspan="2">Nothing on Sunday</td></tr></table>'
    '<p>Words before the layout.</p><table role="presentation"><tr><td>Left side</td><td>Right side</td></tr>'
    "<tr><td>Lower left</td><td>Lower right</td></tr></table><p>Words after the layout.</p>"
    "<table><tr><td>North</td><td>Wet</td></tr><tr><td>South</td><td>Dry</td></tr></table><p>Words after the ruled grid.</p>"
    + "".join(f"<p>Line {i:02d} after the grids.</p>" for i in range(1, 41)) + "</body></html>")
# A table longer than a page or a screen, under a header row: forty numbered rows.
files["OPS/ledger.xhtml"] = (
    '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>A table longer '
    f"than a page</title><style>{CELL_STYLE}</style></head><body><h1>A table longer than a page</h1>"
    "<p>Words before the ledger.</p><table><thead><tr><th>Entry</th><th>Item</th><th>Sum</th></tr></thead><tbody>"
    + "".join(f"<tr><td>Entry {i:02d}</td><td>Item {i:02d}</td><td>Sum {i:02d}</td></tr>" for i in range(1, 41))
    + "</tbody></table><p>Words after the ledger.</p>"
    + "".join(f"<p>Line {i:02d} after the ledger.</p>" for i in range(1, 41)) + "</body></html>")
# A row taller than a page at any size the reader shrinks a table to: one cell of 2,600 numbered
# words, so each page shows a continuation of the row.
files["OPS/tallrow.xhtml"] = (
    '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>A row taller '
    f"than a page</title><style>{CELL_STYLE}</style></head><body><h1>A row taller than a page</h1>"
    "<table><tr><th>Clause</th><th>Wording</th></tr><tr><td>Tall clause</td><td>"
    + " ".join(f"t{i:04d}" for i in range(1, 2601))
    + "</td></tr><tr><td>Short clause</td><td>Short wording</td></tr></table><p>Words after the clauses.</p></body></html>")
# Jumps where a table of data has its header cells. Two rows are each headed by a cell that is
# one link and nothing else, and a third by plain words; the middle column is headed by such
# a link too, and the third row's cell under it is a link itself. The section stands before
# the one of parts below a jump and has no heading, so the book's last heading and its last
# link are where they were, and more than a screen of lines follows the table. No word here
# is one VoiceOver uses for a table, a header or a link.
files["OPS/edges.xhtml"] = (
    '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Jumps at the edges '
    f"of a grid</title><style>{CELL_STYLE}</style></head><body><p>Jumps at the edges of a grid</p>"
    '<p>Words before the routes.</p><table><thead><tr><th>Route</th><th><a href="body.xhtml#link-target">Built</a></th>'
    '<th>Length</th></tr></thead><tbody><tr><th scope="row"><a href="body.xhtml#link-target">Dogwood</a></th>'
    '<td>1912</td><td>Nine miles</td></tr><tr><th scope="row"><a href="body.xhtml#link-target">Elm</a></th>'
    '<td>1947</td><td>Four miles</td></tr><tr><th scope="row">Fir</th>'
    '<td><a href="body.xhtml#link-target">Relaid 1960</a></td><td>Six miles</td></tr></tbody></table>'
    "<p>Words after the routes.</p>"
    + "".join(f"<p>Line {i:02d} after the routes.</p>" for i in range(1, 61)) + "</body></html>")
# A jump with a heading after it on the same page, which no other section has: every other
# heading opens its section or stands pages after the jump before it. A second heading
# follows a second jump on the next page, a line down it, so that in a spread it is in the
# column beside the jump, and on one screen with it in continuous scroll. A last jump follows
# the book's last heading. The section opens with plain words, and no word here is one
# VoiceOver uses for a heading or a link, so those in a transcript are VoiceOver's or the
# reader's own.
files["OPS/parts.xhtml"] = (
    '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Parts below a '
    "jump</title><style>.turned { break-before: page; }</style></head><body><p>Parts below a jump</p>"
    '<p>First part runs here.</p><p>Before an <a href="body.xhtml#link-target">upper jump</a> and beyond.</p>'
    "<p>Earlier words finish.</p><h3>Second part opens</h3><p>Second part runs here.</p>"
    '<p>Nearing a <a href="body.xhtml#link-target">lower jump</a> and onward.</p><p class="turned">Middle words cease.</p>'
    "<h4>Third part opens</h4><p>Third part runs here.</p>"
    '<p>Toward the <a href="body.xhtml#link-target">last jump</a> and after.</p>'
    + "".join(f"<p>Line {i:02d} after the parts.</p>" for i in range(1, 61)) + "</body></html>")
# Pictures where a row has no words of its own. A table marked as
# layout has a row whose two cells show pictures nobody describes and nothing else, between two
# rows of words. A table of data, which begins a page of its own, has a described picture in
# one row's first cell and one nobody describes in the next row's. The section has no heading
# and no link, so the book's last heading and its last link are still those of the section
# before it, and no word here is one VoiceOver uses for a table, a picture or a group.
# A second table of data ends the section, on a page of its own after the sixty lines, where
# the paragraph before it is the target "crests": a described picture among a cell's words in
# one row, in the next a header cell that is a described picture and nothing else, and in the
# last a cell of decoration alone beside a cell of two described pictures and no words.
files["OPS/squares.xhtml"] = (
    '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Squares inside '
    f"grids</title><style>{CELL_STYLE} img {{ width: 32px; height: 32px; }} .signs {{ break-before: page; }}</style>"
    '</head><body><p>Words before the squares.</p><table role="presentation"><tr><td>Top near</td><td>Top far</td></tr>'
    '<tr><td><img src="square.svg"/></td><td><img src="square.svg"/></td></tr>'
    "<tr><td>Foot near</td><td>Foot far</td></tr></table><p>Words after the squares.</p>"
    '<p class="signs">Words before the signs.</p><table><tr><th>Sign</th><th>Sense</th></tr>'
    '<tr><td><img src="square.svg" alt="Blue badge"/></td><td>Open</td></tr>'
    '<tr><td><img src="square.svg"/></td><td>Shut</td></tr></table><p>Words after the signs.</p>'
    + "".join(f"<p>Line {i:02d} after the signs.</p>" for i in range(1, 61))
    + '<p class="signs" id="crests">Words before the crests.</p><table><tr><th>Crest</th><th>Rank</th></tr>'
    '<tr><td>Worn <img src="square.svg" alt="Blue crest"/> daily</td><td>High</td></tr>'
    '<tr><th scope="row"><img src="square.svg" alt="Blue shield"/></th><td>Low</td></tr>'
    '<tr><td><img src="square.svg" alt=""/></td><td><img src="square.svg" alt="Blue ring"/> '
    '<img src="square.svg" alt="Blue star"/></td></tr></table>'
    "<p>Words after the crests.</p>"
    + "".join(f"<p>Line {i:02d} after the crests.</p>" for i in range(1, 61)) + "</body></html>")
# Rows that have nothing to say: a row of two cells that hold nothing,
# a row of two that hold decoration alone, and a row of one cell that holds nothing, each
# between two rows of words, as the rows that space out a table used for layout stand. A table
# marked as layout has them, and so has a table of data, which begins a page of its own under
# a row of header cells. The section has no heading and no link either, and no word here is one
# VoiceOver uses for a table, a picture or a group, or for a place with nothing in it.
GAP_ROWS = ('<tr><td></td><td></td></tr>', '<tr><td><img src="square.svg" alt=""/></td><td><img src="square.svg" alt=""/></td></tr>',
            '<tr><td colspan="2"></td></tr>')
def gapped(rows):
    """Rows of two cells of words, with a row that has nothing to say after each but the last."""
    worded = [f"<tr><td>{near}</td><td>{far}</td></tr>" for near, far in rows]
    return worded[0] + "".join(gap + row for gap, row in zip(GAP_ROWS, worded[1:]))
files["OPS/gaps.xhtml"] = (
    '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Gaps inside '
    f"grids</title><style>{CELL_STYLE} img {{ width: 32px; height: 32px; }} .tally {{ break-before: page; }}</style>"
    '</head><body><p>Words before the gaps.</p><table role="presentation">'
    + gapped([("Upper near", "Upper far"), ("Middle near", "Middle far"), ("Lower near", "Lower far"), ("Last near", "Last far")])
    + '</table><p>Words after the gaps.</p><p class="tally">Words before the tally.</p><table><tr><th>Tree</th><th>Tally</th></tr>'
    + gapped([("Oak", "Nine"), ("Elm", "Four"), ("Ash", "Six"), ("Yew", "Two")])
    + "</table><p>Words after the tally.</p>"
    + "".join(f"<p>Line {i:02d} after the tally.</p>" for i in range(1, 61)) + "</body></html>")
# Words a book hides in the flow, the book's last section: `visibility: hidden` keeps their
# room on the page and hides them from the eye and from assistive technology alike, as
# `visibility: collapse` does outside a table. Words inside a hidden paragraph that set
# `visibility: visible` again are shown and read. Sixty numbered lines follow, so that the
# section's first line can be shown at the top in continuous scroll. It has no heading and no
# link, so the book's last heading and its last link are still those of the parts below a
# jump, and no word here is one VoiceOver uses; no shown word holds a hidden one.
files["OPS/veiled.xhtml"] = (
    '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Words hidden '
    'in the flow</title><style>.veiled { visibility: hidden; } .revealed { visibility: visible; } '
    '.collapsed { visibility: collapse; }</style></head><body><p>Words before the hidden ones.</p>'
    '<p>Shown words before <span class="veiled">concealed words in the line</span> shown words after.</p>'
    '<p class="veiled">Concealed paragraph words. <span class="revealed">Revealed words inside.</span> '
    'Concealed again.</p><p>Shown words around <span class="collapsed">collapsed concealment</span> the last gap.</p>'
    "<p>Words after the hidden ones.</p>"
    + "".join(f"<p>Line {i:02d} after the hidden words.</p>" for i in range(1, 61)) + "</body></html>")
files["OPS/package.opf"] = files["OPS/package.opf"].replace(
    '<item id="image" ', '<item id="veiled" href="veiled.xhtml" media-type="application/xhtml+xml"/><item id="image" ').replace(
    '<itemref idref="gaps"/></spine>', '<itemref idref="gaps"/><itemref idref="veiled"/></spine>')
files["OPS/nav.xhtml"] = files["OPS/nav.xhtml"].replace(
    "</ol></nav>", '<li><a href="veiled.xhtml">Words hidden in the flow</a></li></ol></nav>')

files["OPS/body.xhtml"] = files["OPS/body.xhtml"].replace(
    "NUMBERED_WORDS", " ".join(f"word{i:04d}" for i in range(1, 1201)))
# More than a screen of lines, so that the section's first line can be shown at the top.
lines_after = [f"<p>Line {i:02d} after the table.</p>" for i in range(1, 61)]
# A second table between shown lines, on the section's first page, its last cell a link.
lines_after.insert(2, '<table><tr><td>Fifth cell</td><td>Sixth cell</td></tr><tr><td>Seventh cell</td><td>'
                      '<a href="body.xhtml#link-target">Eighth cell link</a></td></tr></table>')
files["OPS/table.xhtml"] = files["OPS/table.xhtml"].replace("LINES_AFTER", "".join(lines_after))
# The same for three sections near the book's end, which continuous scroll could otherwise
# show from the end of the book.
files["OPS/offers.xhtml"] = files["OPS/offers.xhtml"].replace(
    "LINES_BELOW", "".join(f"<p>Below line {i:02d}.</p>" for i in range(1, 61)))
files["OPS/entries.xhtml"] = files["OPS/entries.xhtml"].replace(
    "ENTRY_LINES_AFTER", "".join(f"<p>Line {i:02d} after the entries.</p>" for i in range(1, 61)))
files["OPS/cells.xhtml"] = files["OPS/cells.xhtml"].replace(
    "GRID_LINES_AFTER", "".join(f"<p>Line {i:02d} after the grid.</p>" for i in range(1, 61)))

# MathML integration: generated vocabulary selection, authored text, native elementary
# layout and an inline continuation in the same ordinary reader used by speech sessions.
math_ns = 'xmlns="http://www.w3.org/1998/Math/MathML"'
math_power = '<msup><mi>x</mi><mn>2</mn></msup>'
math_body = '<h1>Math readings</h1>'
for language, name in [('en', 'English'), ('fr', 'Français'), ('de', 'Deutsch'),
                       ('es', 'Español'), ('it', 'Italiano'), ('ja', 'English fallback')]:
    math_body += f'<p xml:lang="{language}">{name}: <math {math_ns}>{math_power}</math>.</p>'
math_body += f'<p xml:lang="de">Authored: <math {math_ns} alttext="Die eigene Beschreibung">{math_power}</math>.</p>'
math_body += (f'<math {math_ns} display="block"><mstack><mscarries><mn>1</mn><none/></mscarries>'
              '<mn>19</mn><msrow><mo>+</mo><mn>2</mn></msrow><msline length="2"/>'
              '<mn>21</mn></mstack></math>')
math_sum = '<mo>+</mo>'.join(f'<msub><mi>x</mi><mn>{n}</mn></msub>' for n in range(1, 25))
math_body += f'<p>Before <math {math_ns} alttext="A sum of twenty-four terms">{math_sum}</math> after the sum.</p>'
files['OPS/math.xhtml'] = ('<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" '
                           'xml:lang="en"><head><title>Math readings</title></head><body>' + math_body + '</body></html>')
files['OPS/package.opf'] = files['OPS/package.opf'].replace('</manifest>',
    '<item id="math" href="math.xhtml" media-type="application/xhtml+xml" properties="mathml"/></manifest>').replace(
    '</spine>', '<itemref idref="math"/></spine>')
files['OPS/nav.xhtml'] = files['OPS/nav.xhtml'].replace('</ol>', '<li><a href="math.xhtml">Math readings</a></li></ol>')
# Declare the embedded content of the fixture's existing picture and entry sections too.
for name, property in [('pictures.xhtml', 'svg'), ('entries.xhtml', 'mathml')]:
    item = f'href="{name}" media-type="application/xhtml+xml"'
    files['OPS/package.opf'] = files['OPS/package.opf'].replace(item, item + f' properties="{property}"')


# A second book of ordinary paragraphs, for continuous scroll: chapters of forty, forty and six
# paragraphs, each of forty numbered words ("p017w23" is the seventeenth paragraph's
# twenty-third), so a line in the middle of a paragraph can be told from its first, and the
# end of the book is a few screens from the start of its last chapter.
chapters = {"one": range(1, 41), "two": range(41, 81), "three": range(81, 87)}
paragraphs = dict(files)
for name in ["body.xhtml", "labels.xhtml", "table.xhtml", "pictures.xhtml", "scenes.xhtml", "offers.xhtml",
             "entries.xhtml", "cells.xhtml", "grids.xhtml", "ledger.xhtml", "tallrow.xhtml", "edges.xhtml", "parts.xhtml",
             "squares.xhtml", "gaps.xhtml", "veiled.xhtml", "math.xhtml", "square.svg", "titled.svg"]:
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
