#!/usr/bin/env python3
"""Generate the original deterministic EPUBs of Examples/ControlsQualification. Standard library only.

controls-ltr.epub   Six documents, contents nested four deep with an unlinked heading, a page list,
                    and known search counts: "lantern" 14 times across every document (three in
                    one paragraph), "heron" once, "zzyzx" never. Its last contents entry has no
                    link, to show a disabled entry; that is its one EPUBCheck error (RSC-005).
controls-rtl.epub   An Arabic book with a right-to-left page progression and nested contents;
                    "مصباح" occurs five times in three documents.
controls-long.epub  240 documents with two "lantern" each (480), and more than 10,000 "the", so a
                    search stays pending long enough to see and a result list is truncated.
"""
from pathlib import Path
import zipfile

output = Path(__file__).resolve().parents[1] / "Examples/ControlsQualification/Resources"
XHTML = '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"{attributes}><head><title>{title}</title></head><body>{body}</body></html>'
SENTENCES = [
    "The road bends past the old sea wall, and the walkers count the posts until the tide bell rings twice across the water.",
    "A cart of apples waits beside the well while its driver argues about the weather with anyone who will listen.",
    "Nobody hurries on the long hill, because the view behind them grows wider with every slow step they take.",
    "Rain arrives from the west in a grey sheet, crosses the valley in a minute and leaves the stones shining.",
    "The ferryman keeps a ledger of every crossing and reads the oldest pages aloud when the evening is quiet.",
    "Two children race the river to the bridge, and the river, as it always does, lets them believe they have won.",
    "At the top of the pass the wind turns round, and the travellers turn their collars up without a word.",
]
ARABIC = [
    "يمشي المسافر على الطريق القديم قرب البحر.",
    "تفتح السوق أبوابها في الصباح ويأتي الناس من كل مكان.",
    "يقرأ الولد كتابًا صغيرًا تحت الشجرة.",
    "تعبر السفينة الميناء ببطء عند الغروب.",
    "يكتب المعلم الكلمات على اللوح بخط واضح.",
    "ينتظر الصياد على الجسر حتى يطلع القمر.",
]


def page(title, body, attributes=""):
    return XHTML.format(title=title, body=body, attributes=attributes)


def package(identifier, title, language, documents, spine_attributes=""):
    manifest = "".join(f'<item id="{name}" href="{name}.xhtml" media-type="application/xhtml+xml"/>' for name in documents)
    spine = "".join(f'<itemref idref="{name}"/>' for name in documents)
    return ('<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
            f'<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">{identifier}</dc:identifier>'
            f'<dc:title>{title}</dc:title><dc:language>{language}</dc:language>'
            '<meta property="dcterms:modified">2026-10-11T00:00:00Z</meta></metadata>'
            f'<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>{manifest}</manifest>'
            f'<spine{spine_attributes}>{spine}</spine></package>')


def write(name, files):
    files = {"mimetype": "application/epub+zip",
             "META-INF/container.xml": '<?xml version="1.0" encoding="UTF-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
             **files}
    output.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output / name, "w") as archive:
        for path, text in files.items():
            entry = zipfile.ZipInfo(path, date_time=(2026, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_STORED if path == "mimetype" else zipfile.ZIP_DEFLATED
            archive.writestr(entry, text.encode())
    print(output / name)


def paragraphs(code, count, extras, start=0):
    """Numbered paragraphs `code01`…; `extras` maps a number to a sentence appended to it."""
    return [f"<p>{code}{i:02d}. {SENTENCES[(start + i) % len(SENTENCES)]} {SENTENCES[(start + 3 * i + 1) % len(SENTENCES)]}"
            f"{' ' + extras[i] if i in extras else ''}</p>" for i in range(1, count + 1)]


def left_to_right():
    # (file, title, paragraph code, sentences by paragraph, headings before a paragraph)
    chapters = [
        ("front", "Before the road", "a", {3: "A lantern hangs at the gate for anyone who sets out before dawn."}, {}),
        ("harbour", "The harbour", "b", {12: "Lantern after lantern is lit along the quay, and the last lantern is the harbour master's own.",
                                         30: "The mate trims the lantern and says nothing."},
         {8: ("low-tide", "Low tide"), 24: ("ferry", "The ferry")}),
        ("market", "The market", "c", {5: "A tinsmith sells a lantern to a woman who already owns three.", 20: "A heron stands on the fish stall roof.",
                                       41: "By noon every lantern on the stall is gone."}, {}),
        ("pass", "The pass", "d", {9: "The guide carries one lantern for the whole party.", 22: "Somebody has left a lantern on the cairn.",
                                   23: "Its flame is steady: a lantern out of the wind.", 50: "They walk down by lantern light."},
         {6: ("climb", "The climb"), 21: ("cairn", "The cairn"), 36: ("descent", "The descent")}),
        ("lighthouse", "The lighthouse", "e", {15: "The keeper calls the great lamp his lantern, as keepers do.", 44: "From the gallery the town is one lantern among many."}, {}),
        ("afterword", "Afterword", "f", {2: "The lantern from the gate is still in the family."}, {}),
    ]
    files, pages = {}, []
    for file, title, code, extras, headings in chapters:
        body = [f"<h1>{title}</h1>"]
        for i, paragraph in enumerate(paragraphs(code, 8 if file in ("front", "afterword") else 56, extras), start=1):
            if i in headings: body.append(f'<h2 id="{headings[i][0]}">{headings[i][1]}</h2>')
            if i % 14 == 1:
                label = str(len(pages) + 1)
                pages.append((label, f"{file}.xhtml#page-{label}"))
                body.append(f'<span epub:type="pagebreak" role="doc-pagebreak" id="page-{label}" title="{label}"/>')
            body.append(paragraph)
        files[f"OPS/{file}.xhtml"] = page(title, "".join(body))
    contents = ('<li><a href="front.xhtml">Before the road</a></li>'
                '<li><span>Part One: The coast</span><ol>'
                '<li><a href="harbour.xhtml">The harbour</a><ol><li><a href="harbour.xhtml#low-tide">Low tide</a></li>'
                '<li><a href="harbour.xhtml#ferry">The ferry</a></li></ol></li>'
                '<li><a href="market.xhtml">The market</a></li></ol></li>'
                '<li><a href="pass.xhtml">Part Two: The hills</a><ol>'
                '<li><a href="pass.xhtml">The pass</a><ol><li><a href="pass.xhtml#climb">The climb</a><ol>'
                '<li><a href="pass.xhtml#cairn">The cairn</a></li></ol></li>'
                '<li><a href="pass.xhtml#descent">The descent</a></li></ol></li>'
                '<li><a href="lighthouse.xhtml">The lighthouse</a></li></ol></li>'
                '<li><a href="afterword.xhtml">Afterword</a></li>'
                '<li><span>A map that was never drawn</span></li>')
    page_list = "".join(f'<li><a href="{href}">{label}</a></li>' for label, href in pages)
    files["OPS/nav.xhtml"] = page("Contents", f'<nav epub:type="toc"><ol>{contents}</ol></nav>'
                                  f'<nav epub:type="page-list" hidden="hidden"><ol>{page_list}</ol></nav>')
    files["OPS/package.opf"] = package("urn:uuid:5f2f6d0c-1f0e-4c66-9a53-3f1c7f6a2b01", "The Lantern Road", "en", [c[0] for c in chapters])
    write("controls-ltr.epub", files)


def right_to_left():
    lamp = "يضيء المصباح الطريق في المساء."
    chapters = [
        ("one", "الفصل الأول: الميناء", {4: lamp, 19: "يحمل البحّار مصباحًا صغيرًا."}, {10: ("section", "القسم الثاني")}),
        ("two", "الفصل الثاني: السوق", {7: lamp, 26: "يبيع التاجر مصباحًا قديمًا."}, {}),
        ("three", "الفصل الثالث: الجبل", {12: lamp}, {}),
    ]
    files = {}
    for file, title, extras, headings in chapters:
        body = [f"<h1>{title}</h1>"]
        for i in range(1, 37):
            if i in headings: body.append(f'<h2 id="{headings[i][0]}">{headings[i][1]}</h2>')
            body.append(f"<p>الفقرة {i}. {ARABIC[i % len(ARABIC)]} {ARABIC[(3 * i + 1) % len(ARABIC)]} {ARABIC[(5 * i + 2) % len(ARABIC)]}"
                        f"{' ' + extras[i] if i in extras else ''}</p>")
        files[f"OPS/{file}.xhtml"] = page(title, "".join(body), ' dir="rtl" lang="ar"')
    contents = ('<li><a href="one.xhtml">الجزء الأول</a><ol>'
                '<li><a href="one.xhtml">الفصل الأول: الميناء</a><ol><li><a href="one.xhtml#section">القسم الثاني</a></li></ol></li>'
                '<li><a href="two.xhtml">الفصل الثاني: السوق</a></li></ol></li>'
                '<li><a href="three.xhtml">الفصل الثالث: الجبل</a></li>')
    files["OPS/nav.xhtml"] = page("المحتويات", f'<nav epub:type="toc"><ol>{contents}</ol></nav>', ' dir="rtl" lang="ar"')
    files["OPS/package.opf"] = package("urn:uuid:5f2f6d0c-1f0e-4c66-9a53-3f1c7f6a2b02", "طريق المصباح", "ar",
                                       [c[0] for c in chapters], ' page-progression-direction="rtl"')
    write("controls-rtl.epub", files)


def long_book():
    names = [f"s{i:03d}" for i in range(1, 241)]
    files = {}
    for index, name in enumerate(names, start=1):
        title = f"Stage {index}"
        extras = {4: "A lantern marks the milestone.", 21: "The lantern is trimmed again at dusk."}
        files[f"OPS/{name}.xhtml"] = page(title, f"<h1>{title}</h1>" + "".join(paragraphs(f"s{index:03d}-", 30, extras, start=index)))
    contents = "".join(f'<li><a href="{name}.xhtml">Stage {i}</a></li>' for i, name in enumerate(names, start=1))
    files["OPS/nav.xhtml"] = page("Contents", f'<nav epub:type="toc"><ol>{contents}</ol></nav>')
    files["OPS/package.opf"] = package("urn:uuid:5f2f6d0c-1f0e-4c66-9a53-3f1c7f6a2b03", "Two Hundred and Forty Stages", "en", names)
    write("controls-long.epub", files)


left_to_right()
right_to_left()
long_book()
