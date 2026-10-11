import Foundation

public extension Fixture {
    /// Flex and grid alignment as reflowable books use it: original synthetic content styled with
    /// the published conventions of well-known stylesheets. No external corpus or network.
    enum Alignment {
        /// The full-page epigraph rules of Standard Ebooks' Manual of Style: a section at least
        /// about a page tall whose block quotation is centred both ways, with the pre-flexbox
        /// fallback that the `@supports` block overrides.
        public static let epigraphCSS = """
            @namespace epub "http://www.idpf.org/2007/ops";
            body { margin: 0; }
            p { margin: 0; text-indent: 1em; }
            p:first-child { text-indent: 0; }
            blockquote { margin: 1em 2.5em; }
            blockquote cite { display: block; text-align: right; }
            [epub|type~="epigraph"] { font-style: italic; hyphens: none; }
            [epub|type~="epigraph"] cite { margin-top: 1em; font-style: normal; font-variant: small-caps; }
            section[epub|type~="epigraph"] { text-align: center; }
            section[epub|type~="epigraph"] > * {
                display: inline-block; margin: auto; margin-top: 3em; max-width: 80%; text-align: initial;
            }
            @supports(display: flex){
                section[epub|type~="epigraph"] {
                    align-items: center; box-sizing: border-box; display: flex; flex-direction: column;
                    justify-content: center; min-height: calc(98vh - 3em); padding-top: 3em;
                }
                section[epub|type~="epigraph"] > * { margin: 0; }
                section[epub|type~="epigraph"] > * + * { margin-top: 3em; }
            }
            """

        /// The same rules without flexbox or sizing: what the layout must leave the text of.
        public static let epigraphPlainCSS = """
            @namespace epub "http://www.idpf.org/2007/ops";
            body { margin: 0; }
            p { margin: 0; text-indent: 1em; }
            p:first-child { text-indent: 0; }
            blockquote { margin: 1em 2.5em; }
            blockquote cite { display: block; text-align: right; }
            [epub|type~="epigraph"] { font-style: italic; hyphens: none; }
            [epub|type~="epigraph"] cite { margin-top: 1em; font-style: normal; font-variant: small-caps; }
            """

        public static let epigraphBody = """
            <section id="epigraph" epub:type="epigraph"><blockquote><p id="verse">A quiet line stands alone.</p>\
            <cite id="source">An Imagined Author</cite></blockquote></section>
            """

        /// A title page centred by its body, the idiom of many trade books: nothing but a
        /// full-height column container.
        public static let titleCSS = """
            html, body { height: 100%; margin: 0; }
            body { display: flex; flex-direction: column; justify-content: center; align-items: center; }
            h1, p { margin: 0; text-indent: 0; }
            p { margin-top: 1em; }
            """
        public static let titleBody = "<h1 id=\"title\">An Aligned Book</h1><p id=\"byline\">Test Author</p>"

        /// A one-cell grid centring a dedication with `place-items`.
        public static let dedicationCSS = """
            body { margin: 0; }
            p { margin: 0; text-indent: 0; }
            section { display: grid; place-items: center; min-height: 90vh; }
            """
        public static let dedicationBody = "<section id=\"dedication\"><p id=\"to\">For the patient reader.</p></section>"

        /// Layouts outside the supported subset: side-by-side flex items and a two-column grid.
        public static let unsupportedCSS = """
            body { margin: 0; }
            p { margin: 0; text-indent: 0; }
            .row { display: flex; justify-content: space-between; }
            .grid { display: grid; grid-template-columns: 1fr 2fr; gap: 1em; }
            """
        public static let unsupportedBody = """
            <div class="row"><p id="left">Left item.</p><p id="right">Right item.</p></div>\
            <div class="grid"><p id="term">Term.</p><p id="meaning">Its meaning.</p></div><p id="after">After both.</p>
            """
    }

    /// A book whose spine is a centred title page, a Standard Ebooks style epigraph, a grid
    /// dedication, unsupported layouts and a chapter of prose, all under `OPS/`.
    static func alignment() throws -> Data {
        func page(_ title: String, css: String, _ body: String) -> String {
            "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">"
                + "<head><title>\(title)</title><style>\(css)</style></head><body>\(body)</body></html>"
        }
        let prose = String(repeating: "<p>A paragraph of ordinary reading text for pagination.</p>", count: 60)
        let sections: [(name: String, title: String, markup: String)] = [
            ("titlepage", "Title", page("Title", css: Alignment.titleCSS, Alignment.titleBody)),
            ("epigraph", "Epigraph", page("Epigraph", css: Alignment.epigraphCSS, Alignment.epigraphBody)),
            ("dedication", "Dedication", page("Dedication", css: Alignment.dedicationCSS, Alignment.dedicationBody)),
            ("layouts", "Layouts", page("Layouts", css: Alignment.unsupportedCSS, Alignment.unsupportedBody)),
            ("chapter", "Chapter", page("Chapter", css: "", "<h2 id=\"chapter\">Chapter</h2><p id=\"opening\">The chapter opens here.</p>\(prose)")),
        ]
        let manifest = sections.map { "<item id=\"\($0.name)\" href=\"\($0.name).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
        let contents = sections.map { "<li><a href=\"\($0.name).xhtml\">\($0.title)</a></li>" }.joined()
        var files: [String: String] = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": """
            <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """,
            "OPS/book.opf": """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>An Aligned Book</dc:title><dc:language>en</dc:language><dc:identifier id="uid">aligned-book</dc:identifier></metadata><manifest>\(manifest)<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine>\(sections.map { "<itemref idref=\"\($0.name)\"/>" }.joined())</spine></package>
            """,
            "OPS/nav.xhtml": page("Contents", css: "", "<nav epub:type=\"toc\"><ol>\(contents)</ol></nav>"),
        ]
        for section in sections { files["OPS/\(section.name).xhtml"] = section.markup }
        return try archive(files)
    }
}
