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

        /// The same pages as Standard Ebooks' compatible EPUB build ships them (its stylesheets
        /// are CC0; read from ten titles downloaded on 2026-10-11), with original content. The
        /// build differs from the Manual of Style rules above: class selectors stand in for
        /// `epub|type`, margins are longhands, `text-align: left` replaces `initial`, a verse
        /// line is a block `span` with a hanging indent, and the rule separating items is only
        /// there when a page has several. The title page hides its heading and byline far to
        /// the left of an image of the same words, as the imprint and the colophon hide their
        /// heading beside a logo; half-title pages are plain centred headings.
        public static let shippedCSS = """
            @charset "utf-8";
            @namespace epub "http://www.idpf.org/2007/ops";
            body{ font-variant-numeric: oldstyle-nums; hyphens: auto; -webkit-hyphens: auto; text-wrap: pretty; }
            p{ margin-top: 0; margin-right: 0; margin-bottom: 0; margin-left: 0; text-indent: 1em; }
            blockquote{ margin-top: 1em; margin-right: 2.5em; margin-bottom: 1em; margin-left: 2.5em; }
            h1, h2, hgroup{ break-after: avoid; break-inside: avoid; font-variant: small-caps; hyphens: none;
                margin-top: 3em; margin-right: 0; margin-bottom: 3em; margin-left: 0; text-align: center; }
            h2 + p, p.first-child{ hanging-punctuation: first last; text-indent: 0; }
            cite{ font-style: normal; }
            blockquote cite{ display: block; font-style: italic; text-align: right; }
            b, strong{ font-variant: small-caps; font-weight: normal; }
            section{ display: block; }
            section.epub-type-contains-word-titlepage h1,
            section.epub-type-contains-word-titlepage p,
            section.epub-type-contains-word-colophon h2,
            section.epub-type-contains-word-imprint h2{ left: -999em; position: absolute; }
            section.epub-type-contains-word-titlepage img{
                display: block; margin-top: 3em; margin-right: auto; margin-bottom: auto; margin-left: auto; width: 100%;
            }
            section.epub-type-contains-word-colophon, section.epub-type-contains-word-imprint{ text-align: center; }
            section.epub-type-contains-word-colophon header,
            section.epub-type-contains-word-imprint header{ line-height: 0; margin-top: 3em; }
            img.epub-type-contains-word-z3998-publisher-logo{ max-width: 25%; width: 220px; }
            section.epub-type-contains-word-colophon p, section.epub-type-contains-word-imprint p{
                margin-top: 1em; margin-right: auto; margin-bottom: 0; margin-left: auto; text-indent: 0;
            }
            section.epub-type-contains-word-imprint p{ font-size: smaller; text-align: justify; width: 75%; }
            .epub-type-contains-word-z3998-verse p{ text-align: left; text-indent: 0; }
            .epub-type-contains-word-z3998-verse p > span{ display: block; padding-left: 1em; text-indent: -1em; }
            .epub-type-contains-word-z3998-verse p > span + br{ display: none; }
            p span.i1{ padding-left: 2em; text-indent: -1em; }
            section.epub-type-contains-word-dedication p{ font-variant: small-caps; text-align: center; }
            section.epub-type-contains-word-dedication{ text-align: center; }
            section.epub-type-contains-word-dedication > *{
                display: inline-block; margin-top: auto; margin-right: auto; margin-bottom: auto; margin-left: auto;
                margin-top: 3em; max-width: 80%;
            }
            @supports(display: flex){
                section.epub-type-contains-word-dedication{
                    align-items: center; box-sizing: border-box; display: flex; flex-direction: column;
                    justify-content: center; min-height: calc(98vh - 3em); padding-top: 3em;
                }
                section.epub-type-contains-word-dedication > *{
                    margin-top: 0; margin-right: 0; margin-bottom: 0; margin-left: 0;
                }
            }
            .epub-type-contains-word-epigraph{ font-style: italic; hyphens: none; -webkit-hyphens: none; }
            .epub-type-contains-word-epigraph cite{ font-style: normal; font-variant: small-caps; margin-top: 1em; }
            section.epub-type-contains-word-epigraph{ text-align: center; }
            section.epub-type-contains-word-epigraph > *{
                display: inline-block; margin-top: auto; margin-right: auto; margin-bottom: auto; margin-left: auto;
                margin-top: 3em; max-width: 80%; text-align: left;
            }
            @supports(display: flex){
                section.epub-type-contains-word-epigraph{
                    align-items: center; box-sizing: border-box; display: flex; flex-direction: column;
                    justify-content: center; min-height: calc(98vh - 3em); padding-top: 3em;
                }
                section.epub-type-contains-word-epigraph > *{
                    margin-top: 0; margin-right: 0; margin-bottom: 0; margin-left: 0;
                }
            }
            """

        /// The title page's heading and byline, which it hides.
        public static let shippedTitleBody = """
            <section class="epub-type-contains-word-titlepage" id="titlepage" epub:type="titlepage">\
            <h1 epub:type="title">An Aligned Book</h1><p>By <b>Test Author</b>.</p></section>
            """

        /// The whole title page: the hidden heading and byline, and the image of the same words
        /// that it shows, `titlepage.png` beside the document (1400 by 340 pixels as shipped).
        public static let shippedTitlePageBody = """
            <section class="epub-type-contains-word-titlepage" id="titlepage" epub:type="titlepage">\
            <h1 epub:type="title">An Aligned Book</h1><p>By <b>Test Author</b>.</p>\
            <img alt="" src="titlepage.png"/></section>
            """

        /// The imprint, whose logo is `logo.png` beside the document (220 by 140 pixels as shipped).
        public static let shippedImprintBody = """
            <section class="epub-type-contains-word-imprint" id="imprint" epub:type="imprint">\
            <header><h2 epub:type="title">Imprint</h2>\
            <img alt="The publisher's logo." class="epub-type-contains-word-z3998-publisher-logo" src="logo.png"/></header>\
            <p id="notice">This edition was made for a test and is free of copyright.</p></section>
            """

        public static let shippedEpigraphBody = """
            <section class="epub-type-contains-word-epigraph" id="epigraph" role="doc-epigraph" epub:type="epigraph">\
            <blockquote class="epub-type-contains-word-z3998-verse" epub:type="z3998:verse"><p class="first-child">\
            <span id="line1">A lantern in the window, burning low,</span><br/>\
            <span class="i1" id="line2">Kept for the one who is not yet home,</span><br/>\
            <span id="line3">And every road that leaves the town will know</span><br/>\
            <span class="i1" id="line4">The way back.</span></p>\
            <cite id="poet">An Imagined Poet</cite></blockquote></section>
            """

        public static let shippedDedicationBody = """
            <section class="epub-type-contains-word-dedication" id="dedication" role="doc-dedication" epub:type="dedication">\
            <p class="first-child">For those<br/>who read<br/>to the last page</p></section>
            """

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
