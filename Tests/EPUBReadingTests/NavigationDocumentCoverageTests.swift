import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// The EPUB 3 navigation document: the `toc` nav's labels, nesting and hrefs, and XML bounds.
final class NavigationDocumentCoverageTests: XCTestCase {
    private typealias Item = EPUBNavigationItem
    private let xhtml11 = #"<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">"#

    /// The plain book with its navigation document replaced by one holding `body`.
    private func book(nav body: String, adding: [String: Data?] = [:]) throws -> EPUBPublication {
        try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in Fixture.navigationDocument(body) }, adding: adding))
    }

    private func contents(_ list: String) throws -> [EPUBNavigationItem] {
        try book(nav: "<nav epub:type=\"toc\">\(list)</nav>").tableOfContents
    }

    // MARK: Labels

    func testWhiteSpaceInAContentsLabelIsCollapsed() throws {
        // EPUB 3.3 §7.3 defines a label as the "concatenation of all child content and application
        // of whitespace normalization rules"; HTML renders the same link with single spaces.
        let entries = try contents("""
            <ol>
              <li>
                <a href="one.xhtml">
                  Chapter   One:
                  <span class="subtitle">The  Beginning</span>
                </a>
              </li>
              <li><a href="two.xhtml">Chapter\tTwo</a></li>
            </ol>
            """)
        XCTAssertEqual(entries.map(\.title), ["Chapter One: The Beginning", "Chapter Two"])
    }

    func testALandmarkTitleAPageLabelAndAHeadingAreCollapsedAsAContentsLinkIs() throws {
        let book = try book(nav: """
            <nav epub:type="toc"><ol><li><span>
                Part
                One</span><ol><li><a href="one.xhtml">One</a></li></ol></li></ol></nav>
            <nav epub:type="landmarks"><ol><li><a epub:type="bodymatter" href="one.xhtml">
                Start of
                <em>the   text</em>
              </a></li></ol></nav>
            <nav epub:type="page-list"><ol><li><a href="one.xhtml#p1">
                <span>page</span>\txii
              </a></li><li><a href="two.xhtml#p2"> 1 </a></li></ol></nav>
            """)
        XCTAssertEqual(book.tableOfContents, [Item(title: "Part One", children: [Item(title: "One", href: "OPS/one.xhtml")])])
        XCTAssertEqual(book.landmarks, [EPUBLandmark(types: ["bodymatter"], title: "Start of the text", href: "OPS/one.xhtml")])
        XCTAssertEqual(book.pageList, [EPUBPageListEntry(label: "page xii", href: "OPS/one.xhtml#p1"), EPUBPageListEntry(label: "1", href: "OPS/two.xhtml#p2")])
    }

    func testASCIIWhiteSpaceInALabelIsOneSpaceHoweverItIsWritten() throws {
        // A character reference gives the parser the character and a CDATA section its text; a
        // carriage return written out reaches it as a line feed. Elements end no run: the text
        // of everything inside the link is put together first.
        let entries = try contents("<ol><li><a href=\"one.xhtml\">&#9;A&#10;&#13;B&#x20;&#x9;C\r\nD\rE<![CDATA[ \t\n F \n]]><!-- a note -->  <b> <i> G</i> </b>\n</a></li>"
            + "<li><a href=\"two.xhtml\"><b>H </b><i> I</i><b>J</b></a></li></ol>")
        XCTAssertEqual(entries.map(\.title), ["A B C D E F G", "H IJ"])
        // XML holds no form feed. Written out, it is a control that reads as a space
        // (doc/architecture.md), and so as one of the run it stands in.
        let controls = try contents("<ol><li><a href=\"one.xhtml\">\u{0C}Chapter\u{0C} \u{0B}One\u{1F}</a></li></ol>")
        XCTAssertEqual(controls.map(\.title), ["Chapter One"])
    }

    func testWhiteSpaceOutsideASCIIInALabelIsTheAuthorsCharacter() throws {
        // What is collapsed is what a browser collapses: ASCII whitespace. A no-break space is
        // there to be kept, and an ideographic or em space, a next line, a line separator and a
        // zero-width space are as much the author's: in a label that holds anything else each
        // stays at an end and beside another, as in foliate-js's `normalizeWhitespace`. A label
        // of nothing else, the heading here, is empty.
        for space in Fixture.spacesOutsideASCII {
            let label = "\(space)A\(space)\(space)B \(space) C\(space)", name = "U+" + String(space.unicodeScalars.first!.value, radix: 16)
            let book = try book(nav: "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">\n  \(label) \t</a></li>"
                + "<li><span>\(space)</span><ol><li><a href=\"two.xhtml\">Two</a></li></ol></li>"
                + "<li><span>\n \(label)\t</span><ol><li><a href=\"two.xhtml\">Two</a></li></ol></li></ol></nav>"
                + "<nav epub:type=\"landmarks\"><ol><li><a epub:type=\"bodymatter\" href=\"one.xhtml\"> \(label) </a></li></ol></nav>"
                + "<nav epub:type=\"page-list\"><ol><li><a href=\"one.xhtml#p1\"> \(label) </a></li></ol></nav>")
            let read = book.tableOfContents.map(\.title) + book.landmarks.map(\.title) + (book.pageList ?? []).map(\.label)
            XCTAssertEqual(read.map { Array($0.unicodeScalars) }, [label, "", label, label, label].map { Array($0.unicodeScalars) }, name)
        }
    }

    // A `Character` holds a space together with a mark, selector or joiner after it, and is white
    // space by its first scalar. Split by it, the mark would go with the space; read as one
    // character of text, the space would stay where a run is collapsed or an end stripped.
    func testASpaceInALabelIsOneWhateverMarkFollowsIt() throws {
        for m in Fixture.clusteringMarks {
            let entries = try contents("<ol><li><a href=\"one.xhtml\">  \(m)A  \(m)B\t\(m)C\n\(m)</a></li><li><a href=\"two.xhtml\"> \(m) </a></li></ol>")
            XCTAssertEqual(entries.map { Array($0.title.unicodeScalars) }, ["\(m)A \(m)B \(m)C \(m)", m].map { Array($0.unicodeScalars) }, m.debugDescription)
        }
    }

    func testALabelOfNothingButWhiteSpaceOfAnyKindIsEmptyAndItsEntryKept() throws {
        // EPUB 3.3 §7.3 requires a label that is not empty "after concatenation of all child
        // content and application of whitespace normalization rules". One that is empty then is
        // an entry with its target and no title, not one left out. A label of nothing but a
        // no-break space, the placeholder some tools write and no host can show, is as empty.
        let book = try book(nav: "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\"> \n\t <b>  </b>\r\n</a></li><li><a href=\"two.xhtml\">&#160;</a></li>"
            + "<li><span>   </span><ol><li><a href=\"two.xhtml\">Two</a></li></ol></li></ol></nav>"
            + "<nav epub:type=\"landmarks\"><ol><li><a epub:type=\"toc\" href=\"#toc\">\n</a></li></ol></nav>"
            + "<nav epub:type=\"page-list\"><ol><li><a href=\"one.xhtml#p1\">  </a></li></ol></nav>")
        XCTAssertEqual(book.tableOfContents, [Item(title: "", href: "OPS/one.xhtml"), Item(title: "", href: "OPS/two.xhtml"),
                                              Item(title: "", children: [Item(title: "Two", href: "OPS/two.xhtml")])])
        XCTAssertEqual(book.landmarks, [EPUBLandmark(types: ["toc"], title: "", href: "OPS/nav.xhtml#toc")])
        XCTAssertEqual(book.pageList, [EPUBPageListEntry(label: "", href: "OPS/one.xhtml#p1")])
        // So is one of white space of any other kind, alone or among ASCII whitespace
        // (https://github.com/vocaro/EPUBLib/issues/75), in a contents link, a heading, a
        // landmark and a page.
        for space in Fixture.valuesOfOnlyWhiteSpace + ["&emsp;"] {
            let book = try self.book(nav: "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">\(space)</a></li>"
                + "<li><span>\(space)</span><ol><li><a href=\"two.xhtml\">Two</a></li></ol></li></ol></nav>"
                + "<nav epub:type=\"landmarks\"><ol><li><a epub:type=\"bodymatter\" href=\"one.xhtml\">\(space)</a></li></ol></nav>"
                + "<nav epub:type=\"page-list\"><ol><li><a href=\"one.xhtml#p1\">\(space)</a></li><li><a href=\"two.xhtml#p2\">2</a></li></ol></nav>")
            let name = space.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ".")
            XCTAssertEqual(book.tableOfContents, [Item(title: "", href: "OPS/one.xhtml"), Item(title: "", children: [Item(title: "Two", href: "OPS/two.xhtml")])], name)
            XCTAssertEqual(book.landmarks, [EPUBLandmark(types: ["bodymatter"], title: "", href: "OPS/one.xhtml")], name)
            XCTAssertEqual(book.pageList, [EPUBPageListEntry(label: "", href: "OPS/one.xhtml#p1"), EPUBPageListEntry(label: "2", href: "OPS/two.xhtml#p2")], name)
        }
        // White space is such by its scalar, not its `Character`: a no-break space carrying a
        // mark is how a mark is shown alone, and is a label, read whole.
        for m in Fixture.clusteringMarks {
            let book = try self.book(nav: "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">\u{A0}\(m)</a></li></ol></nav>"
                + "<nav epub:type=\"landmarks\"><ol><li><a epub:type=\"bodymatter\" href=\"one.xhtml\"> \u{3000}\(m)\u{A0} </a></li></ol></nav>"
                + "<nav epub:type=\"page-list\"><ol><li><a href=\"one.xhtml#p1\">\u{200B}\(m)</a></li></ol></nav>")
            let read = book.tableOfContents.map(\.title) + book.landmarks.map(\.title) + (book.pageList ?? []).map(\.label)
            XCTAssertEqual(read.map { Array($0.unicodeScalars) }, ["\u{A0}\(m)", "\u{3000}\(m)\u{A0}", "\u{200B}\(m)"].map { Array($0.unicodeScalars) }, m.debugDescription)
        }
    }

    func testALabelIsCollapsedWhateverXMLSpaceSays() throws {
        // `xml:space="preserve"` does not change how HTML renders text, and a label is HTML text.
        let entries = try contents("<ol xml:space=\"preserve\"><li><a href=\"one.xhtml\" xml:space=\"preserve\">  Chapter   One\n  </a></li></ol>")
        XCTAssertEqual(entries.map(\.title), ["Chapter One"])
    }

    func testALabelIsTheTextOfEverythingInsideItsLink() throws {
        let entries = try contents("<ol><li><a href=\"one.xhtml\"><span class=\"n\">1.</span> The <em>very <strong>first</strong></em> "
            + "chapter<sup>*</sup> &amp; <![CDATA[<more>]]><!-- aside --> x<sub>2</sub></a></li>"
            + "<li><a href=\"two.xhtml\" title=\"A tooltip\"><ruby>\u{6F22}<rt>kan</rt></ruby> H\u{2082}O \u{1F600}</a></li></ol>")
        XCTAssertEqual(entries.map(\.title), ["1. The very first chapter* & <more> x2", "\u{6F22}kan H\u{2082}O \u{1F600}"])
        XCTAssertEqual(entries.map(\.href), ["OPS/one.xhtml", "OPS/two.xhtml"])
    }

    func testAnImageLabelReadsAsItsAlternativeText() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/83")
        // EPUB Reading Systems 3.3 §7: outside HTML a reader should "replace unsupported non-text
        // elements in headings and labels with their alternative text" (W3C test nav-non-text_img).
        let entries = try contents("<ol><li><a href=\"one.xhtml\"><img src=\"one.png\" alt=\"The First Chapter\"/></a></li>"
            + "<li><a href=\"two.xhtml\">Part <img src=\"two.png\" alt=\"Two\"/></a></li></ol>")
        XCTAssertEqual(entries.map(\.href), ["OPS/one.xhtml", "OPS/two.xhtml"])
        XCTAssertEqual(entries.map(\.title), ["The First Chapter", "Part Two"])
    }

    func testNamedCharacterReferencesUnderAnXHTMLDoctypeDoNotVanishFromALabel() throws {
        // With an external DOCTYPE the XML parser cannot call an undeclared reference an error, and
        // it reports no text for it. Browsers know XHTML's set by this public identifier, as this
        // library's content-document parser does; the DTD itself is never read. The label must
        // come out whole, not lose its characters silently.
        let doctype = "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">"
        let document = doctype + Fixture.navigationDocument("<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">Caf&eacute;&nbsp;&mdash; 1</a></li></ol></nav>")
        XCTAssertEqual(try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in document })).tableOfContents.first?.title,
                       "Caf\u{E9}\u{A0}\u{2014} 1")
    }

    func testHTMLsNamedReferencesAreReadWhateverTheDoctype() throws {
        // `&nbsp;` under `<!DOCTYPE html>` is no XML, and it is what the same file holds as a
        // content document, where it is read. XML's five names and numeric references stay.
        let nav = Fixture.navigationDocument("<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\" title=\"A&nbsp;B\">"
            + "Caf&eacute;&nbsp;&mdash; 1 &amp; &lt;2&gt; &quot;&apos; &#x41;&#66;</a></li></ol></nav>")
        for doctype in ["<!DOCTYPE html>", "", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n",
                        "<!DOCTYPE html SYSTEM \"about:legacy-compat\">"] {
            let book = try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in doctype + nav }))
            XCTAssertEqual(book.tableOfContents.first?.title, "Caf\u{E9}\u{A0}\u{2014} 1 & <2> \"' AB", doctype)
            XCTAssertEqual(book.tableOfContents.first?.href, "OPS/one.xhtml", doctype)
        }
        for (name, encoding) in [("UTF-16, little-endian", String.Encoding.utf16LittleEndian), ("UTF-16, big-endian", .utf16BigEndian)] {
            let mark = encoding == .utf16LittleEndian ? Data([0xFF, 0xFE]) : Data([0xFE, 0xFF])
            let book = try EPUBPublication.open(data: Fixture.packageVariant(adding: ["OPS/nav.xhtml": mark + ("<!doctype html>" + nav).data(using: encoding)!]))
            XCTAssertEqual(book.tableOfContents.first?.title, "Caf\u{E9}\u{A0}\u{2014} 1 & <2> \"' AB", name)
        }
    }

    func testANamedReferenceInACharacterDataSectionOrACommentIsNotOne() throws {
        let entries = try contents("<ol><li><a href=\"one.xhtml\"><![CDATA[A&nbsp;B]]> &nbsp;C<!-- &nbsp; &bogus; --></a></li></ol>")
        XCTAssertEqual(entries.first?.title, "A&nbsp;B \u{A0}C")
    }

    func testNamedCharacterReferencesInLabelsAreDecodedWhateverTheDoctype() throws {
        // XHTML's names are read as the content-document parsers read them: from a built-in table,
        // with or without a DOCTYPE to declare them. Character data sections, comments and an
        // escaped ampersand keep what they spell.
        let navs = "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">Caf&eacute;&nbsp;&mdash; <![CDATA[&nbsp;]]><!-- &bogus; -->&amp;nbsp; 1</a></li></ol></nav>"
            + "<nav epub:type=\"landmarks\"><ol><li><a epub:type=\"bodymatter\" href=\"one.xhtml\">D&eacute;but</a></li></ol></nav>"
            + "<nav epub:type=\"page-list\"><ol><li><a href=\"one.xhtml#p1\">&sect;&thinsp;1</a></li></ol></nav>"
        for doctype in ["", "<!DOCTYPE html>", "<!DOCTYPE html SYSTEM \"about:legacy-compat\">", xhtml11,
                        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + xhtml11] {
            let book = try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in doctype + Fixture.navigationDocument(navs) }))
            XCTAssertEqual(book.tableOfContents, [Item(title: "Caf\u{E9}\u{A0}\u{2014} &nbsp;&nbsp; 1", href: "OPS/one.xhtml")], doctype)
            XCTAssertEqual(book.landmarks, [EPUBLandmark(types: ["bodymatter"], title: "D\u{E9}but", href: "OPS/one.xhtml")], doctype)
            XCTAssertEqual(book.pageList, [EPUBPageListEntry(label: "\u{A7}\u{2009}1", href: "OPS/one.xhtml#p1")], doctype)
        }
    }

    func testHTMLsNamesAreReadFromItsStandardAndAnUnknownNameIsKeptAsWritten() throws {
        // The table the content-document parsers read is the HTML Standard's, not HTML 4's:
        // `&rcaron;` and `&check;` are only in it, and `&lang;` and `&rang;` are U+27E8 and U+27E9
        // there. A name it lacks is kept as a browser shows it, in a label and in an href, not
        // dropped under a DOCTYPE nor refused without one, whatever characters its name holds
        // (https://github.com/vocaro/EPUBLib/issues/184).
        let nav = "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml#s&rcaron;&bogus;\">Dvo&rcaron;&aacute;k &check; &lang;1&rang; "
            + "&bogus; &my-name_1.x; &AMP;&amp;&lt;&#65;</a></li></ol></nav>"
        let contents = [Item(title: "Dvo\u{159}\u{E1}k \u{2713} \u{27E8}1\u{27E9} &bogus; &my-name_1.x; &&<A", href: "OPS/one.xhtml#s%C5%99&bogus;")]
        for doctype in ["", "<!DOCTYPE html>", "<!DOCTYPE html SYSTEM \"about:legacy-compat\">", xhtml11,
                        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + xhtml11] {
            let book = try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in doctype + Fixture.navigationDocument(nav) }))
            XCTAssertEqual(book.tableOfContents, contents, doctype)
        }
        for (name, encoding) in [("UTF-16, little-endian", String.Encoding.utf16LittleEndian), ("UTF-16, big-endian", .utf16BigEndian)] {
            let mark = encoding == .utf16LittleEndian ? Data([0xFF, 0xFE]) : Data([0xFE, 0xFF])
            let document = try XCTUnwrap((xhtml11 + Fixture.navigationDocument(nav)).data(using: encoding))
            let book = try EPUBPublication.open(data: Fixture.packageVariant(adding: ["OPS/nav.xhtml": mark + document]))
            XCTAssertEqual(book.tableOfContents, contents, name)
        }
    }

    func testNamedCharacterReferencesInALabelAreDecodedBesideALabelWithATildeAndBrace() throws {
        // `~{` opens a two-byte run in the HZ encoding. This document is UTF-8, so a label that
        // holds a template expression is plain text and the references before it are references.
        let nav = "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">Caf&eacute;&nbsp;&mdash; 1</a></li>"
            + "<li><a href=\"two.xhtml\">Using ~{...} fragments</a></li></ol></nav>"
        for doctype in [xhtml11, "<?xml version=\"1.0\" encoding=\"utf-8\"?>" + xhtml11, ""] {
            let book = try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in doctype + Fixture.navigationDocument(nav) }))
            XCTAssertEqual(book.tableOfContents, [
                Item(title: "Caf\u{E9}\u{A0}\u{2014} 1", href: "OPS/one.xhtml"), Item(title: "Using ~{...} fragments", href: "OPS/two.xhtml"),
            ], doctype)
        }
    }

    func testADoctypeWrittenInAnyCaseIsRead() throws {
        // HTML's own spelling is `<!doctype html>`; XML knows only the upper-case keyword.
        let nav = Fixture.navigationDocument("<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">Chapter 1</a></li></ol></nav>")
        for doctype in ["<!doctype html>", "<!DocType html>", "<!doctype html SYSTEM \"about:legacy-compat\">",
                        "<?xml version=\"1.0\"?>\n<!-- <!doctype nothing [> -->\n<!doctype html>\n",
                        "<!doctype html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">"] {
            let book = try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in doctype + nav }))
            XCTAssertEqual(book.tableOfContents, [Item(title: "Chapter 1", href: "OPS/one.xhtml")], doctype)
        }
    }

    func testADoctypeInAnotherCaseCannotCarryDeclarationsPastTheScreen() throws {
        // doc/architecture.md: "entity declarations ... fail explicitly", whatever the keyword's case.
        let nav = Fixture.navigationDocument("<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">Chapter &e;</a></li></ol></nav>")
        for doctype in ["<!doctype html [<!ENTITY e \"expanded\">]>", "<!DocType html [<!ENTITY e SYSTEM \"file:///etc/passwd\">]>",
                        "<!doctype html [<!ENTITY % p \"x\"> %p;]>", "<!doctype html []>", "<!doctype html\n  [\n]>"] {
            XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in doctype + nav })), doctype) {
                XCTAssertEqual($0 as? EPUBPublicationError, .invalidXML("OPS/nav.xhtml"), doctype)
            }
        }
    }

    func testNavigationMarkupMalformedInOtherWaysIsStillRefused() throws {
        func document(_ label: String, list: String = "</ol>") -> String {
            "<!DOCTYPE html>" + Fixture.navigationDocument("<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">\(label)</a></li>\(list)</nav>")
        }
        // A name HTML does not know is read as written (#184); a reference to what is no name is not.
        let documents = [
            "a reference to no name": document("Chapter &1st; 1"), "a bare ampersand": document("Tom & Jerry"),
            "a reference without its semicolon": document("A&nbsp B"), "an element left open": document("<em>Chapter 1"),
            "a list left open": document("Chapter 1", list: ""), "an unquoted attribute": document("<span class=x>Chapter 1</span>"),
            "a void element left open": document("Chapter<br>1"),
        ]
        for (name, document) in documents {
            XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in document })), name) {
                XCTAssertEqual($0 as? EPUBPublicationError, .invalidXML("OPS/nav.xhtml"), name)
            }
        }
    }

    // MARK: Structure

    func testHeadingsWithoutLinksKeepTheEntriesNestedUnderThem() throws {
        let entries = try contents("""
            <h1>Contents</h1>
            <ol>
              <li><span>Part I</span>
                <ol>
                  <li><a href="one.xhtml">Chapter 1</a>
                    <ol hidden="">
                      <li><a href="one.xhtml#a">Section A</a></li>
                      <li><span>Unlinked group</span><ol><li><a href="one.xhtml#b">Section B</a></li></ol></li>
                    </ol>
                  </li>
                </ol>
              </li>
              <li><a href="two.xhtml">Part II</a></li>
            </ol>
            """)
        XCTAssertEqual(entries, [
            Item(title: "Part I", children: [
                Item(title: "Chapter 1", href: "OPS/one.xhtml", children: [
                    Item(title: "Section A", href: "OPS/one.xhtml#a"),
                    Item(title: "Unlinked group", children: [Item(title: "Section B", href: "OPS/one.xhtml#b")]),
                ]),
            ]),
            Item(title: "Part II", href: "OPS/two.xhtml"),
        ])
    }

    func testTheContentsNavIsFoundAmongOtherNavsAndInsideOtherElements() throws {
        let book = try book(nav: """
            <header><nav><ol><li><a href="two.xhtml">An untyped list</a></li></ol></nav></header>
            <nav epub:type="lot"><h2>Tables</h2><ol><li><a href="two.xhtml#t1">Table 1</a></li></ol></nav>
            <main><section><div>
              <nav epub:type="toc" id="toc" role="doc-toc" hidden="hidden" aria-labelledby="h">
                <h2 id="h">Contents</h2>
                <ol><li><a href="one.xhtml">Chapter 1</a></li></ol>
              </nav>
            </div></section></main>
            <nav epub:type="toc"><ol><li><a href="two.xhtml">A second contents list</a></li></ol></nav>
            """)
        XCTAssertEqual(book.tableOfContents, [Item(title: "Chapter 1", href: "OPS/one.xhtml")], "the first toc nav, hidden or not")
        XCTAssertTrue(book.landmarks.isEmpty)
        XCTAssertNil(book.pageList)
    }

    func testXHTMLElementsUnderANamespacePrefixAreRead() throws {
        let nav = "<h:html xmlns:h=\"http://www.w3.org/1999/xhtml\" xmlns:e=\"http://www.idpf.org/2007/ops\"><h:head><h:title>Contents</h:title></h:head>"
            + "<h:body><h:nav e:type=\"toc\"><h:ol><h:li><h:a href=\"one.xhtml\">Chapter <h:em>1</h:em></h:a><h:ol><h:li><h:span>Group</h:span>"
            + "<h:ol><h:li><h:a href=\"two.xhtml\">Chapter 2</h:a></h:li></h:ol></h:li></h:ol></h:li></h:ol></h:nav>"
            + "<h:nav e:type=\"landmarks\"><h:ol><h:li><h:a e:type=\"bodymatter\" href=\"one.xhtml\">Start</h:a></h:li></h:ol></h:nav></h:body></h:html>"
        let book = try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in nav }))
        XCTAssertEqual(book.tableOfContents, [Item(title: "Chapter 1", href: "OPS/one.xhtml", children: [
            Item(title: "Group", children: [Item(title: "Chapter 2", href: "OPS/two.xhtml")]),
        ])])
        XCTAssertEqual(book.landmarks, [EPUBLandmark(types: ["bodymatter"], title: "Start", href: "OPS/one.xhtml")])
    }

    func testAnEPUB3BookWhoseNavigationFileIsAbsentReadsItsNCX() throws {
        let ncx = try EPUBPublication.open(data: Fixture.epub(epub2: true)).tableOfContents
        let book = try EPUBPublication.open(data: Fixture.packageVariant(adding: ["OPS/nav.xhtml": nil]))
        XCTAssertEqual(book.tableOfContents, ncx)
        XCTAssertFalse(book.resources.contains { $0.properties.contains("nav") })
    }

    // MARK: Hrefs

    func testEntryHrefsResolveFromTheNavigationDocumentsFolder() throws {
        let list = "<nav epub:type=\"toc\"><ol><li><a href=\"\">This list</a></li><li><a href=\"#further\">Further down</a></li>"
            + "<li><a href=\"../one.xhtml#start\">Up a folder</a></li><li><a href=\"./../text/../two.xhtml\">Round about</a></li>"
            + "<li><a href=\"appendix.xhtml\">Beside it</a></li></ol></nav>"
        let book = try EPUBPublication.open(data: Fixture.packageVariant(
            opf: { $0.replacingOccurrences(of: "href=\"nav.xhtml\"", with: "href=\"front/nav.xhtml\"") },
            adding: ["OPS/nav.xhtml": nil, "OPS/front/nav.xhtml": Data(Fixture.navigationDocument(list).utf8)]))
        XCTAssertEqual(book.tableOfContents.map(\.href), ["OPS/front/nav.xhtml", "OPS/front/nav.xhtml#further", "OPS/one.xhtml#start",
                                                         "OPS/two.xhtml", "OPS/front/appendix.xhtml"])
    }

    func testAnEntryHrefIsEncodedLikeTheHrefOfTheResourceItNames() throws {
        // However the navigation document spells it, the entry's href starts with the resource's.
        let spellings = ["chapter%20%231%20caf%C3%A9.xhtml", "chapter%20%231%20caf%c3%a9.xhtml", "chapter %231 caf\u{E9}.xhtml",
                         "./chapter%20%231%20cafe%CC%81.xhtml", "x/../chapter%20%231%20caf%C3%A9.xhtml"]
        let list = spellings.map { "<li><a href=\"\($0)#sec%201\">Chapter</a></li>" }.joined()
        let book = try EPUBPublication.open(data: Fixture.packageVariant(
            opf: { $0.replacingOccurrences(of: "href=\"one.xhtml\"", with: "href=\"chapter%20%231%20caf%C3%A9.xhtml\"") },
            nav: { _ in Fixture.navigationDocument("<nav epub:type=\"toc\"><ol>\(list)</ol></nav>") },
            adding: ["OPS/chapter #1 caf\u{E9}.xhtml": Data("<html/>".utf8)]))
        let resource = try XCTUnwrap(book.spine.first?.resource)
        XCTAssertEqual(resource.path, "OPS/chapter #1 caf\u{E9}.xhtml")
        XCTAssertEqual(resource.href, "OPS/chapter%20%231%20caf%C3%A9.xhtml")
        for (spelling, entry) in zip(spellings, book.tableOfContents) {
            let parts = try XCTUnwrap(entry.href).split(separator: "#", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(parts.count, 2, spelling)
            XCTAssertEqual(parts.first?.removingPercentEncoding, resource.path, spelling)
            XCTAssertEqual(parts.last, "sec%201", spelling)
            if !spelling.contains("%CC%81") { XCTAssertEqual(parts.first, resource.href, spelling) }
        }
    }

    // A `Character` holds a "/", "\", ":", "#" or "." together with a mark, selector or joiner
    // after it, so read that way "../" + U+0301 + "x.xhtml" has no dot segment and
    // "two.xhtml#" + U+0301 + "s" has no fragment (https://github.com/vocaro/EPUBLib/issues/181).
    func testEntryHrefsAreResolvedWhateverMarkFollowsTheirSeparatorsAndDots() throws {
        for m in Fixture.clusteringMarks {
            let e = Fixture.escapingNonASCII(m)
            let hrefs = ["../\(m)x.xhtml", "./\(m)x.xhtml#s", "a/../\(m)x.xhtml", "a/\(m)x.xhtml", "two.xhtml#\(m)s", "#\(m)s", "..%2F\(e)x.xhtml"]
            let entries = try contents("<ol>" + hrefs.map { "<li><a href=\"\($0)\">x</a></li>" }.joined() + "</ol>")
            XCTAssertEqual(entries.map(\.href), ["\(e)x.xhtml", "OPS/\(e)x.xhtml#s", "OPS/\(e)x.xhtml", "OPS/a/\(e)x.xhtml", "OPS/two.xhtml#\(e)s",
                                                "OPS/nav.xhtml#\(e)s", "\(e)x.xhtml"], m.debugDescription)
            // Read as the same href is without the mark. One that climbs past the container root
            // or opens with a slash starts at the root (https://github.com/vocaro/EPUBLib/issues/84)
            // and a colon is a character of the name; one with a backslash does not resolve, and
            // its entry stays without a target (https://github.com/vocaro/EPUBLib/issues/171).
            let others: [(href: String, resolved: String?)] = [("../../\(m)x.xhtml", "\(e)x.xhtml"), ("/\(m)x.xhtml", "\(e)x.xhtml"),
                                                               ("./a:\(m)x.xhtml", "OPS/a%3A\(e)x.xhtml"), ("a\\\(m)x.xhtml", nil)]
            for (href, resolved) in others {
                let list = "<ol><li><a href=\"\(href)\">x</a></li><li><a epub:type=\"bodymatter\" href=\"one.xhtml#p2\">kept</a></li></ol>"
                XCTAssertEqual(try contents(list), [Item(title: "x", href: resolved), Item(title: "kept", href: "OPS/one.xhtml#p2")], href.debugDescription)
                // Among landmarks and pages, one that does not resolve is left out.
                let book = try book(nav: "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">1</a></li></ol></nav>"
                    + "<nav epub:type=\"landmarks\">\(list)</nav><nav epub:type=\"page-list\">\(list)</nav>")
                XCTAssertEqual(book.landmarks.map(\.href), [resolved, "OPS/one.xhtml#p2"].compactMap { $0 }, href.debugDescription)
                XCTAssertEqual(book.pageList?.map(\.href), [resolved, "OPS/one.xhtml#p2"].compactMap { $0 }, href.debugDescription)
            }
        }
    }

    func testAnEntryHrefSurroundedBySpacesNamesItsTarget() throws {
        // An HTML href is a URL "potentially surrounded by spaces", stripped before parsing. EPUBCheck
        // passes content-model-a-with-leading-trailing-spaces-valid.xhtml, written this way
        // (https://github.com/vocaro/EPUBLib/issues/76).
        let list = "<ol><li><a href=\" one.xhtml\">Chapter 1</a></li><li><a href=\"two.xhtml#start \">Chapter 2</a></li>"
            + "<li><a href=\"\n      one.xhtml#start\n    \">Chapter 1 again</a></li><li><a href=\"&#9;two.xhtml&#13;&#10;\">Chapter 2 again</a></li></ol>"
        let targets = ["OPS/one.xhtml", "OPS/two.xhtml#start", "OPS/one.xhtml#start", "OPS/two.xhtml"]
        XCTAssertEqual(try contents(list).map(\.href), targets)
        // So is a landmark's and a page's.
        let book = try book(nav: "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">1</a></li></ol></nav>"
            + "<nav epub:type=\"landmarks\">\(list)</nav><nav epub:type=\"page-list\">\(list)</nav>")
        XCTAssertEqual(book.landmarks.map(\.href), targets)
        XCTAssertEqual(book.pageList?.map(\.href), targets)
        // White space outside ASCII is no HTML space: it is a character of the name.
        for space in Fixture.spacesOutsideASCII {
            let e = Fixture.escapingNonASCII(space)
            XCTAssertEqual(try contents("<ol><li><a href=\"\(space)one.xhtml\(space)\">x</a></li></ol>").map(\.href), ["OPS/\(e)one.xhtml\(e)"], e)
        }
    }

    func testAnEPUBCFIFragmentSurvivesInAnEntryHref() throws {
        // As EPUBCheck's nav-cfi-valid links into the package document.
        let entries = try contents("<ol><li><a href=\"book.opf#epubcfi(/6/2!/4/2/1:1)\">By position</a></li>"
            + "<li><a href=\"two.xhtml#epubcfi(/4/2[start],/1:0,/1:5)\">A range</a></li></ol>")
        XCTAssertEqual(entries.map { $0.href?.removingPercentEncoding }, ["OPS/book.opf#epubcfi(/6/2!/4/2/1:1)", "OPS/two.xhtml#epubcfi(/4/2[start],/1:0,/1:5)"])
        XCTAssertEqual(entries.first?.href, "OPS/book.opf#epubcfi(/6/2!/4/2/1:1)")
    }

    // MARK: Landmarks

    func testLandmarksAreReadFromLinksAlone() throws {
        let book = try book(nav: "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">Chapter 1</a></li></ol></nav>"
            + "<nav epub:type=\"landmarks\" hidden=\"\"><h2>Guide</h2><ol><li><a epub:type=\"toc\" href=\"#toc\">Contents</a></li>"
            + "<li><span epub:type=\"cover\">No link</span></li><li><a epub:type=\"bodymatter\">No href</a></li>"
            + "<li><a epub:type=\"backmatter  index\" href=\"two.xhtml\"> Index </a></li></ol></nav>")
        XCTAssertEqual(book.landmarks, [
            EPUBLandmark(types: ["toc"], title: "Contents", href: "OPS/nav.xhtml#toc"),
            EPUBLandmark(types: ["backmatter", "index"], title: "Index", href: "OPS/two.xhtml"),
        ])
    }

    // MARK: XML bounds

    /// A navigation document whose deepest element, the contents link, is `depth` elements deep.
    private func nested(depth: Int) -> String {
        // html, body, nav, ol, li and a are six levels.
        let wrappers = depth - 6
        return "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body>"
            + String(repeating: "<div>", count: wrappers) + "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">Deep</a></li></ol></nav>"
            + String(repeating: "</div>", count: wrappers) + "</body></html>"
    }

    func testANavigationDocumentAtTheDepthLimitIsReadAndOneLevelDeeperRefused() throws {
        let book = try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in self.nested(depth: 64) }))
        XCTAssertEqual(book.tableOfContents, [Item(title: "Deep", href: "OPS/one.xhtml")])
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in self.nested(depth: 65) }))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .invalidXML("OPS/nav.xhtml"))
        }
    }

    func testANavigationDocumentAtTheElementLimitIsReadAndOneMoreRefused() throws {
        // html, head, title, body, nav, ol, li and a are eight elements.
        func document(elements: Int) -> String {
            Fixture.navigationDocument("<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">Wide</a></li></ol></nav>"
                + String(repeating: "<i/>", count: elements - 8))
        }
        let book = try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in document(elements: 100_000) }))
        XCTAssertEqual(book.tableOfContents, [Item(title: "Wide", href: "OPS/one.xhtml")])
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in document(elements: 100_001) }))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .invalidXML("OPS/nav.xhtml"))
        }
    }

    func testAContentsListOfManyEntriesIsReadWhole() throws {
        let list = (1...20_000).map { "<li><a href=\"one.xhtml#s\($0)\">Section \($0)</a></li>" }.joined()
        let entries = try contents("<ol>\(list)</ol>")
        XCTAssertEqual(entries.count, 20_000)
        XCTAssertEqual(entries.last, Item(title: "Section 20000", href: "OPS/one.xhtml#s20000"))
    }

    func testAnEntityDeclarationInAnEncodingTheScreenDoesNotDecodeIsStillRefused() throws {
        // doc/architecture.md: "entity declarations ... fail explicitly". In UTF-7 the declaration
        // below has no `<!` byte sequence, yet the XML parser honours the declared encoding and
        // reads `+ADw-` as `<`: a DOCTYPE with an internal subset declaring an entity.
        let declaration = "<?xml version=\"1.0\" encoding=\"UTF-7\"?>"
        let html = "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol>"
            + "<li><a href=\"one.xhtml\">Chapter &amp; verse</a></li></ol></nav></body></html>"
        let utf8 = "<!DOCTYPE html [<!ENTITY e \"expanded\">]>" + html
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in utf8 })), "the control: the same document in UTF-8")
        let utf7 = declaration + "+ADw-!DOCTYPE html [+ADw-!ENTITY e \"expanded\">]>" + html
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.packageVariant(nav: { _ in utf7 })), "in UTF-7")
    }
}
