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

    func testWhiteSpaceInAnNCXLabelIsCollapsed() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/75")
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
