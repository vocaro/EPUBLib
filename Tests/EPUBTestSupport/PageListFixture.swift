import Foundation

public extension Fixture {
    /// The labels of `pageList()`'s page list, in order.
    static let pageLabels = ["i", "1", "2", "3", "4", "5"]

    /// A book with print page equivalents: `pagebreak` markers listed by a `hidden` page-list
    /// nav. The preface's page `i` starts mid-paragraph well into it, so the book opens before
    /// its first page. Chapter one opens on a marker for page 1, has page 2's mid-paragraph and
    /// pages 3 and 4's on one short line. Chapter two opens without a marker, still on page 4,
    /// and page 5 starts mid-paragraph.
    static func pageList() throws -> Data {
        func page(_ title: String, _ body: String) -> String {
            "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">"
                + "<head><title>\(title)</title></head><body>\(body)</body></html>"
        }
        func marker(_ label: String) -> String {
            "<span epub:type=\"pagebreak\" role=\"doc-pagebreak\" id=\"page-\(label)\" title=\"\(label)\"/>"
        }
        func filler(_ count: Int) -> String {
            String(repeating: "<p>A paragraph of ordinary reading text for pagination.</p>", count: count)
        }
        let sections = ["front", "chapter-1", "chapter-2"]
        let manifest = sections.map { "<item id=\"\($0)\" href=\"\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
        let targets = ["i": "front", "1": "chapter-1", "2": "chapter-1", "3": "chapter-1", "4": "chapter-1", "5": "chapter-2"]
        let pages = pageLabels.map { "<li><a href=\"\(targets[$0]!).xhtml#page-\($0)\">\($0)</a></li>" }.joined()
        return try archive([
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": """
            <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """,
            "OPS/book.opf": """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>A Paged Book</dc:title><dc:language>en</dc:language><dc:identifier id="uid">paged-book</dc:identifier></metadata><manifest>\(manifest)<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine>\(sections.map { "<itemref idref=\"\($0)\"/>" }.joined())</spine></package>
            """,
            "OPS/nav.xhtml": page("Contents", "<nav epub:type=\"toc\"><ol><li><a href=\"front.xhtml\">Preface</a></li>"
                + "<li><a href=\"chapter-1.xhtml\">Chapter 1</a></li><li><a href=\"chapter-2.xhtml\">Chapter 2</a></li></ol></nav>"
                + "<nav epub:type=\"page-list\" hidden=\"hidden\"><h2>Pages</h2><ol>\(pages)</ol></nav>"),
            "OPS/front.xhtml": page("Preface", "<h1>Preface</h1>\(filler(30))"
                + "<p>The unnumbered pages end \(marker("i"))and the preface's own page begins.</p>\(filler(10))"),
            "OPS/chapter-1.xhtml": page("Chapter 1", "<div epub:type=\"pagebreak\" role=\"doc-pagebreak\" id=\"page-1\" title=\"1\"></div>"
                + "<h1>Chapter 1</h1>\(filler(40))"
                + "<p>Page one ends before the break \(marker("2"))and page two begins after it.</p>\(filler(40))"
                + "<p>Two ends.\(marker("3")) Three.\(marker("4")) Four.</p>\(filler(20))"),
            "OPS/chapter-2.xhtml": page("Chapter 2", "<h1>Chapter 2</h1>\(filler(40))"
                + "<p>Page four ends here \(marker("5"))and page five begins.</p>\(filler(30))"),
        ])
    }
}
