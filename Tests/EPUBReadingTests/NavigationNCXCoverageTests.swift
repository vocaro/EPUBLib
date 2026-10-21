import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// The EPUB 2 NCX: `navMap` nesting, labels, targets and what else an NCX holds.
final class NavigationNCXCoverageTests: XCTestCase {
    private typealias Item = EPUBNavigationItem

    private func ncx(_ body: String) -> String {
        "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\">\(body)</ncx>"
    }

    private func point(_ id: String, _ label: String, _ src: String, order: Int = 1, _ children: String = "") -> String {
        "<navPoint id=\"\(id)\" playOrder=\"\(order)\"><navLabel><text>\(label)</text></navLabel><content src=\"\(src)\"/>\(children)</navPoint>"
    }

    /// The EPUB 2 book with its NCX replaced.
    private func book(ncx document: String, adding: [String: Data?] = [:]) throws -> EPUBPublication {
        try EPUBPublication.open(data: Fixture.packageVariant(epub2: true, ncx: { _ in document }, adding: adding))
    }

    // OPF 2.0.1 §2.4 has the spine's `toc` name the NCX, but converters leave it out or name an
    // item that is not there. The NCX is then found by its media type, as foliate-js finds it
    // (https://github.com/vocaro/EPUBLib/issues/169).
    func testAnNCXTheSpineDoesNotNameIsFoundByItsMediaType() throws {
        let document = ncx("<navMap>" + point("a", "Only Chapter", "one.xhtml") + "</navMap><pageList><pageTarget id=\"p1\" type=\"normal\" value=\"1\">"
            + "<navLabel><text>1</text></navLabel><content src=\"two.xhtml#p1\"/></pageTarget></pageList>")
        let pages = [EPUBPageListEntry(label: "1", href: "OPS/two.xhtml#p1")]
        // Before it, an NCX whose file the archive lacks and a remote one, which are passed over.
        let elsewhere = "<item id=\"gone\" href=\"gone.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
            + "<item id=\"remote\" href=\"https://example.invalid/toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
        for spine in ["<spine>", "<spine toc=\"\">", "<spine toc=\"toc\">", "<spine toc=\"gone\">", "<spine toc=\"remote\">"] {
            for type in ["application/x-dtbncx+xml", " Application/X-DTBNCX+XML "] {
                func edit(_ opf: String) -> String {
                    opf.replacingOccurrences(of: "<spine toc=\"ncx\">", with: spine)
                        .replacingOccurrences(of: "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>",
                                              with: elsewhere + "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"\(type)\"/>")
                }
                let book = try EPUBPublication.open(data: Fixture.packageVariant(epub2: true, opf: edit, ncx: { _ in document }))
                XCTAssertEqual(book.tableOfContents, [Item(title: "Only Chapter", href: "OPS/one.xhtml")], spine + type)
                XCTAssertEqual(book.pageList, pages, spine + type)
                // An EPUB 3 book's NCX, found so, fills the page list its navigation document lacks.
                XCTAssertEqual(try EPUBPublication.open(data: Fixture.packageVariant(opf: edit, ncx: { _ in document })).pageList, pages, spine + type)
            }
        }
    }

    func testAnNCXFoundByItsMediaTypeThatDoesNotParseIsIgnored() throws {
        // The book never needed it to open. One the spine names still refuses an EPUB 2 book
        // (EPUBCheckNavigationCoverageTests.testAnEPUB2BookWhoseNCXIsMalformedIsATypedRefusal).
        let book = try EPUBPublication.open(data: Fixture.packageVariant(epub2: true, opf: {
            $0.replacingOccurrences(of: "<spine toc=\"ncx\">", with: "<spine>")
        }, ncx: { _ in "<ncx><navMap><navPoint></navMap></ncx>" }))
        XCTAssertEqual(book.tableOfContents, [])
        XCTAssertNil(book.pageList)
        XCTAssertEqual(book.spine.count, 2)
    }

    func testOfSeveralNCXsTheOneTheSpineNamesOrElseTheFirstIsRead() throws {
        // A second NCX listed before the fixture's. The spine's choice stands whatever media
        // type the item it names is declared with; without one, only an item of the NCX's media
        // type is taken for it, the first in manifest order, as foliate-js and Readium take it.
        func contents(_ spine: String, earlierType: String = "application/x-dtbncx+xml") throws -> [Item] {
            let earlier = ncx("<navMap>" + point("e", "Listed first", "two.xhtml") + "</navMap>")
            return try EPUBPublication.open(data: Fixture.packageVariant(epub2: true, opf: {
                $0.replacingOccurrences(of: "<spine toc=\"ncx\">", with: spine)
                    .replacingOccurrences(of: "<item id=\"ncx\"", with: "<item id=\"early\" href=\"early.ncx\" media-type=\"\(earlierType)\"/><item id=\"ncx\"")
            }, adding: ["OPS/early.ncx": Data(earlier.utf8)])).tableOfContents
        }
        let listedFirst = [Item(title: "Listed first", href: "OPS/two.xhtml")]
        let fixture = try EPUBPublication.open(data: Fixture.epub(epub2: true)).tableOfContents
        XCTAssertEqual(try contents("<spine>"), listedFirst)
        XCTAssertEqual(try contents("<spine toc=\"ncx\">"), fixture)
        XCTAssertEqual(try contents("<spine toc=\"early\">", earlierType: "text/xml"), listedFirst)
        XCTAssertEqual(try contents("<spine>", earlierType: "text/xml"), fixture)
    }

    func testNavPointsNestInDocumentOrderWhateverTheirPlayOrder() throws {
        let map = point("a", "Part One", "one.xhtml", order: 9,
                        point("b", "Chapter 1", "one.xhtml#start", order: 3, point("c", "Section 1.1", "one.xhtml#s1", order: 1)
                            + point("d", "Section 1.2", "one.xhtml#s2", order: 1))
                        + point("e", "Chapter 2", "two.xhtml", order: 2))
            + point("f", "Part Two", "two.xhtml#start", order: 0)
        XCTAssertEqual(try book(ncx: ncx("<navMap>\(map)</navMap>")).tableOfContents, [
            Item(title: "Part One", href: "OPS/one.xhtml", children: [
                Item(title: "Chapter 1", href: "OPS/one.xhtml#start", children: [
                    Item(title: "Section 1.1", href: "OPS/one.xhtml#s1"), Item(title: "Section 1.2", href: "OPS/one.xhtml#s2"),
                ]),
                Item(title: "Chapter 2", href: "OPS/two.xhtml"),
            ]),
            Item(title: "Part Two", href: "OPS/two.xhtml#start"),
        ])
    }

    func testAnNCXAsAuthoringToolsWriteItIsRead() throws {
        // A declaration, the DAISY DOCTYPE, the head's metas, a title and author, labels and
        // targets each on their own lines, attributes in another order and an xml:lang.
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="no"?>
            <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN"
             "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="en">
              <head>
                <meta name="dtb:uid" content="test-book"/>
                <meta name="dtb:depth" content="2"/>
                <meta name="dtb:totalPageCount" content="0"/>
                <meta name="dtb:maxPageNumber" content="0"/>
              </head>
              <docTitle>
                <text>A Test Book</text>
              </docTitle>
              <docAuthor>
                <text>Test Author</text>
              </docAuthor>
              <navMap>
                <navPoint playOrder="1" class="chapter" id="navPoint-1">
                  <navLabel>
                    <text>First Chapter</text>
                  </navLabel>
                  <content src="one.xhtml#start"/>
                  <navPoint id="navPoint-2" playOrder="2">
                    <navLabel>
                      <text>Second Chapter</text>
                    </navLabel>
                    <content src="two.xhtml"></content>
                  </navPoint>
                </navPoint>
              </navMap>
            </ncx>

            """
        XCTAssertEqual(try book(ncx: document).tableOfContents, try EPUBPublication.open(data: Fixture.epub(epub2: true)).tableOfContents)
    }

    func testAnNCXUnderANamespacePrefixIsRead() throws {
        let document = "<n:ncx xmlns:n=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><n:navMap><n:navPoint id=\"a\" playOrder=\"1\">"
            + "<n:navLabel><n:text>Prefixed</n:text></n:navLabel><n:content src=\"two.xhtml\"/></n:navPoint></n:navMap>"
            + "<n:pageList><n:pageTarget id=\"p1\" type=\"normal\" value=\"1\"><n:navLabel><n:text>1</n:text></n:navLabel>"
            + "<n:content src=\"one.xhtml#p1\"/></n:pageTarget></n:pageList></n:ncx>"
        let book = try book(ncx: document)
        XCTAssertEqual(book.tableOfContents, [Item(title: "Prefixed", href: "OPS/two.xhtml")])
        XCTAssertEqual(book.pageList, [EPUBPageListEntry(label: "1", href: "OPS/one.xhtml#p1")])
    }

    func testOnlyTheNavMapSuppliesContentsEntries() throws {
        let document = ncx("<head><meta name=\"dtb:uid\" content=\"x\"/></head><docTitle><text>Not an entry</text></docTitle>"
            + "<navMap><navInfo><text>About this list</text></navInfo><navLabel><text>Contents</text></navLabel>"
            + point("a", "Only Chapter", "one.xhtml") + "</navMap>"
            + "<pageList><navLabel><text>Pages</text></navLabel><pageTarget id=\"p\" type=\"front\" value=\"1\"><navLabel><text>i</text></navLabel>"
            + "<content src=\"one.xhtml#pi\"/></pageTarget><pageTarget id=\"q\" type=\"normal\" value=\"1\"><navLabel><text>1</text></navLabel>"
            + "<content src=\"two.xhtml#p1\"/></pageTarget></pageList>"
            + "<navList class=\"lot\"><navLabel><text>Tables</text></navLabel><navTarget id=\"t1\"><navLabel><text>Table 1</text></navLabel>"
            + "<content src=\"two.xhtml#t1\"/></navTarget></navList>")
        let book = try book(ncx: document)
        XCTAssertEqual(book.tableOfContents, [Item(title: "Only Chapter", href: "OPS/one.xhtml")])
        XCTAssertEqual(book.pageList, [EPUBPageListEntry(label: "i", href: "OPS/one.xhtml#pi"), EPUBPageListEntry(label: "1", href: "OPS/two.xhtml#p1")])
    }

    func testANavPointLackingItsLabelOrTargetStillLeadsToItsChildren() throws {
        let document = ncx("<navMap><navPoint id=\"a\"><content src=\"one.xhtml\"/>" + point("b", "Inside", "one.xhtml#in") + "</navPoint>"
            + "<navPoint id=\"c\"><navLabel><text>A heading</text></navLabel>" + point("d", "Under it", "two.xhtml") + "</navPoint></navMap>")
        let entries = try book(ncx: document).tableOfContents
        XCTAssertEqual(entries.map(\.href), ["OPS/one.xhtml", nil])
        XCTAssertEqual(entries.first?.children, [Item(title: "Inside", href: "OPS/one.xhtml#in")], "under a point without a label")
        XCTAssertEqual(entries.last, Item(title: "A heading", href: nil, children: [Item(title: "Under it", href: "OPS/two.xhtml")]),
                       "a point without a target is a heading")
    }

    func testANavPointWhoseTargetNamesNothingInTheBookIsAHeading() throws {
        for src in ["https://example.invalid/more", "//example.invalid/more", "100%.xhtml", "text\\one.xhtml"] {
            let entries = try book(ncx: ncx("<navMap>" + point("a", "One", "one.xhtml") + point("b", "Elsewhere", src, point("c", "Two", "two.xhtml"))
                + "</navMap>")).tableOfContents
            XCTAssertEqual(entries, [Item(title: "One", href: "OPS/one.xhtml"),
                                     Item(title: "Elsewhere", href: nil, children: [Item(title: "Two", href: "OPS/two.xhtml")])], src)
        }
        let inside = try book(ncx: ncx("<navMap>" + point("a", "Up", "../../outside.xhtml") + point("b", "From the root", "/OPS/two.xhtml#x")
            + point("c", "Query", "one.xhtml?page=2") + "</navMap>")).tableOfContents
        XCTAssertEqual(inside.map(\.href), ["outside.xhtml", "OPS/two.xhtml#x", "OPS/one.xhtml"], "EPUB Reading Systems 3.3 §4.1.1")
    }

    func testNCXTargetsResolveFromTheNCXFolderAndAreEncoded() throws {
        let document = ncx("<navMap>" + point("a", "Up", "../one.xhtml#start") + point("b", "Beside", "notes.xhtml")
            + point("c", "Spaced", "../my%20chapter%20%C3%A9.xhtml#a%20b") + point("d", "Unescaped", "../my chapter \u{E9}.xhtml") + "</navMap>")
        let book = try EPUBPublication.open(data: Fixture.packageVariant(epub2: true,
            opf: { $0.replacingOccurrences(of: "href=\"toc.ncx\"", with: "href=\"meta/toc.ncx\"") },
            adding: ["OPS/toc.ncx": nil, "OPS/meta/toc.ncx": Data(document.utf8)]))
        XCTAssertEqual(book.tableOfContents.map(\.href), ["OPS/one.xhtml#start", "OPS/meta/notes.xhtml", "OPS/my%20chapter%20%C3%A9.xhtml#a%20b",
                                                         "OPS/my%20chapter%20%C3%A9.xhtml"])
    }

    // By `Character` a "/", "\", ":", "#" or "." takes a mark, selector or joiner after it into
    // itself and is not found (https://github.com/vocaro/EPUBLib/issues/181).
    func testNCXAndGuideTargetsAreResolvedWhateverMarkFollowsTheirSeparatorsAndDots() throws {
        func page(_ label: String, _ src: String) -> String {
            "<pageTarget><navLabel><text>\(label)</text></navLabel><content src=\"\(src)\"/></pageTarget>"
        }
        for m in Fixture.clusteringMarks {
            let e = Fixture.escapingNonASCII(m)
            // Read as the same target is without the mark. One that climbs past the container
            // root or opens with a slash starts at the root (https://github.com/vocaro/EPUBLib/issues/84)
            // and a colon is a character of the name (https://github.com/vocaro/EPUBLib/issues/171).
            // One with a backslash does not resolve.
            let others: [(src: String, resolved: String?)] = [("../../\(m)x.xhtml", "\(e)x.xhtml"), ("/\(m)x.xhtml", "\(e)x.xhtml"),
                                                              ("./a:\(m)x.xhtml", "OPS/a%3A\(e)x.xhtml"), ("a\\\(m)x.xhtml", nil)]
            let document = ncx("<navMap>" + point("a", "Up", "../\(m)x.xhtml") + point("b", "Beside", "./\(m)x.xhtml#\(m)s") + "</navMap>"
                + "<pageList>" + others.map { page("out", $0.src) }.joined() + page("1", "a/../\(m)x.xhtml") + page("2", "one.xhtml#\(m)p") + "</pageList>")
            let guide = "<guide>" + others.map { "<reference type=\"text\" title=\"out\" href=\"\($0.src)\"/>" }.joined()
                + "<reference type=\"cover\" title=\"in\" href=\"../\(m)x.xhtml\"/></guide>"
            let book = try EPUBPublication.open(data: Fixture.packageVariant(
                epub2: true, opf: { $0.replacingOccurrences(of: "</package>", with: guide + "</package>") }, ncx: { _ in document }))
            XCTAssertEqual(book.tableOfContents.map(\.href), ["\(e)x.xhtml", "OPS/\(e)x.xhtml#\(e)s"], m.debugDescription)
            // A page or a guide reference that does not resolve is left out.
            let outside = others.compactMap(\.resolved)
            XCTAssertEqual(book.pageList, outside.map { EPUBPageListEntry(label: "out", href: $0) }
                + [EPUBPageListEntry(label: "1", href: "OPS/\(e)x.xhtml"), EPUBPageListEntry(label: "2", href: "OPS/one.xhtml#\(e)p")], m.debugDescription)
            XCTAssertEqual(book.landmarks, outside.map { EPUBLandmark(types: ["text"], title: "out", href: $0) }
                + [EPUBLandmark(types: ["cover"], title: "in", href: "\(e)x.xhtml")], m.debugDescription)
            // A point that does not resolve stays, without a target.
            for (src, resolved) in others {
                XCTAssertEqual(try self.book(ncx: ncx("<navMap>" + point("a", "Out", src) + "</navMap>")).tableOfContents,
                               [Item(title: "Out", href: resolved)], src.debugDescription)
            }
        }
    }

    func testNamedCharacterReferencesInNCXLabelsAreDecodedWithOrWithoutTheDoctype() throws {
        // EPUB 2 era tools wrote XHTML's names into labels. The DAISY DTD is never read, and under
        // its DOCTYPE the XML parser reports no text for a name it has no declaration for, so
        // XHTML's names are decoded from a built-in table.
        let doctype = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
            + "<!DOCTYPE ncx PUBLIC \"-//NISO//DTD ncx 2005-1//EN\" \"http://www.daisy.org/z3986/2005/ncx-2005-1.dtd\">\n"
        let document = ncx("<navMap>\(point("a", "Don&rsquo;t&nbsp;Panic", "one.xhtml"))</navMap><pageList><pageTarget id=\"p1\" type=\"normal\" value=\"1\">"
            + "<navLabel><text>&sect;&nbsp;1</text></navLabel><content src=\"one.xhtml#p1\"/></pageTarget></pageList>")
        for prolog in [doctype, ""] {
            let book = try book(ncx: prolog + document)
            XCTAssertEqual(book.tableOfContents, [Item(title: "Don\u{2019}t\u{A0}Panic", href: "OPS/one.xhtml")], prolog)
            XCTAssertEqual(book.pageList, [EPUBPageListEntry(label: "\u{A7}\u{A0}1", href: "OPS/one.xhtml#p1")], prolog)
        }
    }

    func testNamedCharacterReferencesInAnNCXLabelAreDecodedBesideALabelWithATildeAndBrace() throws {
        // `~{` opens a two-byte run in the HZ encoding. This document is UTF-8, as one with no
        // encoding declared or with that one is, so a label that holds a template expression is
        // plain text and the references in the label before it are references.
        let doctype = "<!DOCTYPE ncx PUBLIC \"-//NISO//DTD ncx 2005-1//EN\" \"http://www.daisy.org/z3986/2005/ncx-2005-1.dtd\">\n"
        let document = ncx("<navMap>\(point("a", "Caf&eacute;&nbsp;&mdash; 1", "one.xhtml"))\(point("b", "Using ~{...} fragments", "two.xhtml", order: 2))</navMap>")
        for prolog in [doctype, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + doctype, ""] {
            XCTAssertEqual(try book(ncx: prolog + document).tableOfContents, [
                Item(title: "Caf\u{E9}\u{A0}\u{2014} 1", href: "OPS/one.xhtml"), Item(title: "Using ~{...} fragments", href: "OPS/two.xhtml"),
            ], prolog)
        }
    }

    func testWhiteSpaceInAnNCXLabelIsCollapsed() throws {
        // As in the navigation document: a label wrapped by a pretty-printer is one line of text.
        let document = ncx("""
            <navMap>
              <navPoint id="a" playOrder="1">
                <navLabel>
                  <text>Chapter   One:
                    The  Beginning</text>
                </navLabel>
                <content src="one.xhtml"/>
              </navPoint>
            </navMap>
            """)
        XCTAssertEqual(try book(ncx: document).tableOfContents.map(\.title), ["Chapter One: The Beginning"])
    }

    func testAnNCXPageLabelIsCollapsedInAnEPUB2BookAndBesideANavigationDocument() throws {
        let document = ncx("""
            <navMap>\(point("a", "One", "one.xhtml"))</navMap>
            <pageList>
              <pageTarget id="p1" type="front" value="12">
                <navLabel>
                  <text>page
                    xii</text>
                </navLabel>
                <content src="one.xhtml#p1"/>
              </pageTarget>
              <pageTarget id="p2" type="normal" value="1"><navLabel><text>&#9;1&#13;&#10;</text></navLabel><content src="two.xhtml#p2"/></pageTarget>
              <pageTarget id="p3" type="normal" value="2"><navLabel><text>  </text></navLabel><content src="two.xhtml#p3"/></pageTarget>
            </pageList>
            """)
        let pages = [EPUBPageListEntry(label: "page xii", href: "OPS/one.xhtml#p1"), EPUBPageListEntry(label: "1", href: "OPS/two.xhtml#p2"),
                     EPUBPageListEntry(label: "", href: "OPS/two.xhtml#p3")]
        XCTAssertEqual(try book(ncx: document).pageList, pages)
        // An EPUB 3 book's NCX fills the page list its navigation document lacks.
        XCTAssertEqual(try EPUBPublication.open(data: Fixture.packageVariant(ncx: { _ in document })).pageList, pages)
    }

    func testWhiteSpaceOutsideASCIIInAnNCXLabelIsTheAuthorsCharacter() throws {
        // As in the navigation document: ASCII whitespace is collapsed and stripped, and a
        // no-break, ideographic or em space, a next line, a line separator or a zero-width space
        // stays at an end of a label that holds anything else and beside another. A label of
        // nothing else, the second here, is empty.
        for space in Fixture.spacesOutsideASCII {
            let label = "\(space)A\(space)\(space)B \(space) C\(space)", name = "U+" + String(space.unicodeScalars.first!.value, radix: 16)
            let book = try book(ncx: ncx("<navMap>\(point("a", "\n  \(label) \t", "one.xhtml"))\(point("b", space, "two.xhtml", order: 2))</navMap>"
                + "<pageList><pageTarget><navLabel>\n<text> \(label) </text>\n</navLabel><content src=\"one.xhtml#p1\"/></pageTarget></pageList>"))
            let read = book.tableOfContents.map(\.title) + (book.pageList ?? []).map(\.label)
            XCTAssertEqual(read.map { Array($0.unicodeScalars) }, [label, "", label].map { Array($0.unicodeScalars) }, name)
        }
    }

    func testAnNCXLabelOfNothingButWhiteSpaceOfAnyKindIsEmptyAndItsEntryKept() throws {
        // As in the navigation document (https://github.com/vocaro/EPUBLib/issues/75): a
        // `navLabel` of nothing but white space, a lone no-break space included, is a point or a
        // page with its target and no title, in an EPUB 2 book and where an EPUB 3 book's NCX
        // fills the page list its navigation document lacks.
        for space in Fixture.valuesOfOnlyWhiteSpace + ["  ", ""] {
            let document = ncx("<navMap>\(point("a", space, "one.xhtml", point("b", "Inside", "one.xhtml#in", order: 2)))\(point("c", "Two", "two.xhtml", order: 3))</navMap>"
                + "<pageList><pageTarget id=\"p1\"><navLabel>\n<text>\(space)</text>\n</navLabel><content src=\"one.xhtml#p1\"/></pageTarget>"
                + "<pageTarget id=\"p2\"><navLabel><text>2</text></navLabel><content src=\"two.xhtml#p2\"/></pageTarget></pageList>")
            let name = space.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ".")
            let pages = [EPUBPageListEntry(label: "", href: "OPS/one.xhtml#p1"), EPUBPageListEntry(label: "2", href: "OPS/two.xhtml#p2")]
            let book = try book(ncx: document)
            XCTAssertEqual(book.tableOfContents, [Item(title: "", href: "OPS/one.xhtml", children: [Item(title: "Inside", href: "OPS/one.xhtml#in")]),
                                                  Item(title: "Two", href: "OPS/two.xhtml")], name)
            XCTAssertEqual(book.pageList, pages, name)
            XCTAssertEqual(try EPUBPublication.open(data: Fixture.packageVariant(ncx: { _ in document })).pageList, pages, name)
        }
        // White space is such by its scalar, not its `Character`: a no-break space carrying a
        // mark is how a mark is shown alone, and is a label, read whole.
        for m in Fixture.clusteringMarks {
            let book = try book(ncx: ncx("<navMap>\(point("a", "\u{A0}\(m)", "one.xhtml"))</navMap>"
                + "<pageList><pageTarget><navLabel><text> \u{3000}\(m)\u{A0} </text></navLabel><content src=\"one.xhtml#p1\"/></pageTarget></pageList>"))
            let read = book.tableOfContents.map(\.title) + (book.pageList ?? []).map(\.label)
            XCTAssertEqual(read.map { Array($0.unicodeScalars) }, ["\u{A0}\(m)", "\u{3000}\(m)\u{A0}"].map { Array($0.unicodeScalars) }, m.debugDescription)
        }
    }

    // A `Character` holds a space together with a mark, selector or joiner after it, and is white
    // space by its first scalar. Split by it, the mark would go with the space; read as one
    // character of text, the space would stay where a run is collapsed or an end stripped.
    func testASpaceInAnNCXLabelIsOneWhateverMarkFollowsIt() throws {
        for m in Fixture.clusteringMarks {
            let entries = try book(ncx: ncx("<navMap>\(point("a", "  \(m)A  \(m)B\t\(m)C\n\(m)", "one.xhtml"))\(point("b", " \(m) ", "two.xhtml", order: 2))</navMap>"))
                .tableOfContents
            XCTAssertEqual(entries.map { Array($0.title.unicodeScalars) }, ["\(m)A \(m)B \(m)C \(m)", m].map { Array($0.unicodeScalars) }, m.debugDescription)
        }
    }

    func testAnNCXOfManyLevelsIsReadToTheBottom() throws {
        // ncx and navMap, then thirty navPoints, the last holding a navLabel and its text: 34 deep.
        var map = point("p30", "Level 30", "two.xhtml#l30")
        for level in (1..<30).reversed() { map = point("p\(level)", "Level \(level)", "one.xhtml#l\(level)", order: level, map) }
        var entry = try XCTUnwrap(try book(ncx: ncx("<navMap>\(map)</navMap>")).tableOfContents.first)
        var titles = [entry.title]
        while let child = entry.children.first { entry = child; titles.append(child.title) }
        XCTAssertEqual(titles, (1...30).map { "Level \($0)" })
        XCTAssertEqual(entry.href, "OPS/two.xhtml#l30")
    }
}
