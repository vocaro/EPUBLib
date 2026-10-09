import Foundation

public extension Fixture {
    /// A book laid out like a Standard Ebooks title: a linear cover and titlepage, then two
    /// chapters, all under `OPS/text/`. `bodymatter` is the href of the navigation document's
    /// `bodymatter` landmark, listed after `cover` and `titlepage` ones, and `text` that of the OPF
    /// guide's `text` reference, after `cover` and `title-page` ones; both are relative to
    /// `OPS/`, and nil leaves out the whole list. An EPUB 2 book has no navigation document.
    /// Chapter one's `deep` anchor is several pages in.
    static func frontMatter(bodymatter: String? = "text/chapter-1.xhtml", text: String? = nil,
                            epub2: Bool = false) throws -> Data {
        func page(_ title: String, _ body: String) -> String {
            "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">"
                + "<head><title>\(title)</title></head><body>\(body)</body></html>"
        }
        let filler = String(repeating: "<p>A paragraph of ordinary reading text for pagination.</p>", count: 120)
        let landmarks = bodymatter.map { href in
            "<nav epub:type=\"landmarks\"><ol><li><a href=\"text/cover.xhtml\" epub:type=\"cover\">Cover</a></li>"
                + "<li><a href=\"text/titlepage.xhtml\" epub:type=\"titlepage\">Titlepage</a></li>"
                + "<li><a href=\"\(href)\" epub:type=\"bodymatter z3998:fiction\">A Front-Matter Book</a></li></ol></nav>"
        } ?? ""
        let guide = text.map { href in
            "<guide><reference type=\"cover\" title=\"Cover\" href=\"text/cover.xhtml\"/>"
                + "<reference type=\"title-page\" title=\"Titlepage\" href=\"text/titlepage.xhtml\"/>"
                + "<reference type=\"text\" title=\"Text\" href=\"\(href)\"/></guide>"
        } ?? ""
        let sections = ["cover", "titlepage", "chapter-1", "chapter-2"]
        let manifest = sections.map { "<item id=\"\($0)\" href=\"text/\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
        return try archive([
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": """
            <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """,
            "OPS/book.opf": """
            <package xmlns="http://www.idpf.org/2007/opf" version="\(epub2 ? "2.0" : "3.0")" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>A Front-Matter Book</dc:title><dc:language>en</dc:language><dc:identifier id="uid">front-matter-book</dc:identifier></metadata><manifest>\(manifest)<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" \(epub2 ? "" : "properties=\"nav\"")/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx">\(sections.map { "<itemref idref=\"\($0)\"/>" }.joined())</spine>\(guide)</package>
            """,
            "OPS/nav.xhtml": page("Contents", "<nav epub:type=\"toc\"><ol><li><a href=\"text/chapter-1.xhtml\">Chapter 1</a></li><li><a href=\"text/chapter-2.xhtml\">Chapter 2</a></li></ol></nav>\(landmarks)"),
            "OPS/toc.ncx": """
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap><navPoint id="c1" playOrder="1"><navLabel><text>Chapter 1</text></navLabel><content src="text/chapter-1.xhtml"/></navPoint><navPoint id="c2" playOrder="2"><navLabel><text>Chapter 2</text></navLabel><content src="text/chapter-2.xhtml"/></navPoint></navMap></ncx>
            """,
            "OPS/text/cover.xhtml": page("Cover", "<section epub:type=\"cover\"><p>The cover of the book.</p></section>"),
            "OPS/text/titlepage.xhtml": page("Titlepage", "<h1 id=\"titlepage\">A Front-Matter Book</h1><p>By Test Author</p>"),
            "OPS/text/chapter-1.xhtml": page("Chapter 1", "<h2 id=\"chapter-1\">Chapter 1</h2><p>The first chapter opens here.</p>"
                + "\(filler)<p id=\"deep\">A passage several pages into the first chapter.</p>\(filler)"),
            "OPS/text/chapter-2.xhtml": page("Chapter 2", "<h2 id=\"chapter-2\">Chapter 2</h2><p>The second chapter opens here.</p>\(filler)"),
        ])
    }
}
