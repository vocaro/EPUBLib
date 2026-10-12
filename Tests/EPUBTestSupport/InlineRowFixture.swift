import Foundation

public extension Fixture {
    /// Rows of sized inline blocks as shipped books set them: marks of omission, each in a box
    /// of fixed width, inside a paragraph whose prose runs on after them, and a list whose
    /// initials stand in boxes of one width. Original synthetic content. No external corpus or
    /// network.
    enum InlineRows {
        /// Paragraphs without margins, indented on their first line except after a heading: the
        /// conventions the marks are usually found among.
        public static let css = """
            body { margin: 0; }
            h2 { margin: 1em 0; text-align: center; }
            p { margin: 0; text-indent: 1em; }
            h2 + p, .letters > p { text-indent: 0; }
            .wide > span { display: inline-block; text-align: center; text-indent: 0; width: 5em; }
            .narrow > span { display: inline-block; text-align: center; text-indent: 0; width: 3em; }
            .letters > p > span { display: inline-block; text-indent: 0; width: 1.2em; }
            """

        /// `count` marks, each in a `span`, separated by the white space a book leaves between them.
        public static func marks(_ count: Int) -> String {
            Array(repeating: "<span>*</span>", count: count).joined(separator: " ")
        }

        /// Prose, nine wide marks, and more prose in the same paragraph.
        public static let torn = """
            <p id="torn" class="wide">The corner of the page was torn away just where the clerk had begun to set the answer down, \
            and all that could be copied from it was \(marks(9)) and a single word after the gap, which nobody at the \
            office could afterwards agree upon.</p>
            """

        /// Marks that open a paragraph, with its first-line indent, and close it; then marks
        /// that close one paragraph, and a paragraph that is nothing else but its last word.
        public static let ruled = """
            <p id="ruled" class="narrow">\(marks(20))—so the entry ends.</p>\
            <p id="trailing" class="narrow">The second entry was struck out in the same hand: \(marks(14))</p>\
            <p id="only" class="narrow">\(marks(6)) again.</p>
            """

        /// Each line's initial in a box of one width, the rest of the word straight after it.
        public static let letters = """
            <div class="letters"><p><span>A</span>mber</p><p><span>B</span>asalt</p><p><span>C</span>halk, and what was left of the \
            chalk after the winter</p></div>
            """

        public static let closing = "<p id=\"closing\">The ledger was put back on its shelf, and the matter rested there until the spring.</p>"

        public static let body = "<h2 id=\"heading\">The Torn Page</h2>" + torn + ruled + letters + closing

        /// A chapter of ordinary prose whose paragraphs differ in length, so that a text view
        /// shown further down has only an estimate of how tall it is.
        public static func prose(_ chapter: Int, paragraphs: Int = 90) -> String {
            let sentences = [
                "The carrier came up the lane a little before noon.",
                "Nobody had expected him so early in the week, and the gate was still shut against the cattle.",
                "He set the parcel down on the step, looked once at the sky, and asked whether the river had gone back inside its banks.",
                "It had not.",
                "The lower field was a sheet of grey water with the tops of the fence posts standing out of it in a row, and the heron that "
                    + "fished there in dry summers had moved up to the orchard wall, where it stood all day with its neck drawn in.",
                "So he stayed for his dinner.",
            ]
            var body = "<h2 id=\"chapter-\(chapter)\">Chapter \(chapter)</h2>"
            for paragraph in 0..<paragraphs {
                let count = 1 + (paragraph * 7 + chapter * 3) % 11
                let words = (0..<count).map { sentences[($0 + paragraph + chapter) % sentences.count] }.joined(separator: " ")
                body += "<p>\(words)</p>"
            }
            return body
        }
    }

    /// A book whose spine is four chapters of prose, the chapter of marks and a last chapter of
    /// prose, all under `OPS/`: in continuous scroll the marks are far below what a text view
    /// lays out first, and have enough below them to be brought to the top of the screen.
    static func inlineRows() throws -> Data {
        func page(_ title: String, _ body: String) -> String {
            "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">"
                + "<head><title>\(title)</title><style>\(InlineRows.css)</style></head><body>\(body)</body></html>"
        }
        var sections: [(name: String, title: String, markup: String)] = (1...4).map {
            ("chapter-\($0)", "Chapter \($0)", page("Chapter \($0)", InlineRows.prose($0)))
        }
        sections.append(("torn", "The Torn Page", page("The Torn Page", InlineRows.body)))
        sections.append(("chapter-5", "Chapter 5", page("Chapter 5", InlineRows.prose(5, paragraphs: 40))))
        let manifest = sections.map { "<item id=\"\($0.name)\" href=\"\($0.name).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
        let contents = sections.map { "<li><a href=\"\($0.name).xhtml\">\($0.title)</a></li>" }.joined()
        var files: [String: String] = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": """
            <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """,
            "OPS/book.opf": """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>The Torn Page</dc:title><dc:language>en</dc:language><dc:identifier id="uid">torn-page</dc:identifier></metadata><manifest>\(manifest)<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine>\(sections.map { "<itemref idref=\"\($0.name)\"/>" }.joined())</spine></package>
            """,
            "OPS/nav.xhtml": page("Contents", "<nav epub:type=\"toc\"><ol>\(contents)</ol></nav>"),
        ]
        for section in sections { files["OPS/\(section.name).xhtml"] = section.markup }
        return try archive(files)
    }
}
