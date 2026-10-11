import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// The navigation constructs EPUBCheck's scenarios check (`epub3/08-navigation-document`,
/// `epub2/ncx-publication`), as a reader meets them.
final class EPUBCheckNavigationCoverageTests: XCTestCase {
    private func navigation(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
        <head><meta charset="utf-8"/><title>Contents</title></head><body>\(body)</body></html>
        """
    }

    private func open(nav body: String, _ overrides: [String: String] = [:]) throws -> EPUBPublication {
        try EPUBPublication.open(data: Fixture.epub(overrides: overrides.merging(["OPS/nav.xhtml": navigation(body)]) { first, _ in first }))
    }

    private func toc(_ list: String) -> String { "<nav epub:type=\"toc\" id=\"toc\"><h1>Contents</h1><ol>\(list)</ol></nav>" }

    // MARK: Links

    func testALinkWithWhitespaceAroundItsHrefNamesTheSameResource() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/76")
        // Valid for EPUBCheck (its issue 156): an HTML `href` is a URL "potentially surrounded by
        // spaces", and URL parsing strips leading and trailing whitespace.
        let book = try open(nav: toc("<li><a href=\" one.xhtml#start\">One</a></li><li><a href=\"two.xhtml \n\">Two</a></li>"))
        XCTAssertEqual(book.tableOfContents.map(\.href), ["OPS/one.xhtml#start", "OPS/two.xhtml"])
    }

    func testAContentsLinkOutsideTheBookRefusesItWithATypedError() throws {
        // NAV-010 for EPUBCheck. Unlike a landmark or a page, a contents entry that does not
        // resolve inside the archive refuses the book.
        for href in ["https://example.invalid/more", "../../outside.xhtml", "/absolute.xhtml"] {
            XCTAssertThrowsError(try open(nav: toc("<li><a href=\"one.xhtml\">One</a></li><li><a href=\"\(href)\">Elsewhere</a></li>")), href) {
                XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath(href), href)
            }
        }
    }

    func testALinkToADocumentTheArchiveLacksIsKeptAsWritten() throws {
        // RSC-007 for EPUBCheck. The reference still resolves inside the archive, so it is listed.
        let book = try open(nav: toc("<li><a href=\"one.xhtml\">One</a></li><li><a href=\"missing/three.xhtml#x\">Three</a></li>"))
        XCTAssertEqual(book.tableOfContents.map(\.href), ["OPS/one.xhtml", "OPS/missing/three.xhtml#x"])
    }

    // MARK: Labels

    func testLabelsCollapseTheirWhitespace() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/75")
        // EPUB 3.3, 7.3: a label is the element's text "after concatenation of all child content
        // and application of whitespace normalization rules". Authoring tools wrap and indent.
        let book = try open(nav: toc("""
            <li>
                <a href="one.xhtml">
                    Chapter <span class="number">1</span>:
                    The   <em>First</em>
                    One
                </a>
            </li>
            <li><span>
                Part
                Two</span><ol><li><a href="two.xhtml">Chapter\t2</a></li></ol></li>
            """))
        XCTAssertEqual(book.tableOfContents.map(\.title), ["Chapter 1: The First One", "Part Two"])
        XCTAssertEqual(book.tableOfContents.last?.children.map(\.title), ["Chapter 2"])
    }

    func testAnEntryLabelledByAnImageIsStillListedWithItsTarget() throws {
        // Valid for EPUBCheck when the image has alternative text. The alternative text is not
        // read into the title (a SHOULD of EPUB Reading Systems 3.3, 7), but the entry is kept.
        let book = try open(nav: toc("""
            <li><a href="one.xhtml" title="Chapter One"><img src="one.png" alt="Chapter One"/></a></li>\
            <li><a href="two.xhtml">Chapter <img src="two.png" alt="Two"/></a></li>
            """))
        XCTAssertEqual(book.tableOfContents.map(\.href), ["OPS/one.xhtml", "OPS/two.xhtml"])
        XCTAssertEqual(book.tableOfContents.last?.title, "Chapter")
    }

    // MARK: Structure

    func testEntriesInHiddenListsAreStillListed() throws {
        // EPUB 3.3, 7.4.4: "The hidden attribute has no effect on how reading systems render the
        // navigation data outside of the content flow".
        let book = try open(nav: """
            <nav epub:type="toc" hidden=""><ol><li><a href="one.xhtml">One</a><ol hidden="hidden"><li><a href="one.xhtml#start">Start</a></li></ol></li>\
            <li hidden=""><a href="two.xhtml">Two</a></li></ol></nav>
            """)
        XCTAssertEqual(book.tableOfContents.map(\.title), ["One", "Two"])
        XCTAssertEqual(book.tableOfContents.first?.children, [EPUBNavigationItem(title: "Start", href: "OPS/one.xhtml#start")])
    }

    func testAHeadingSpanGroupsTheEntriesUnderIt() throws {
        let book = try open(nav: toc("""
            <li><span>Part One</span><ol><li><a href="one.xhtml">One</a></li><li><span>Deeper</span><ol><li><a href="one.xhtml#start">Start</a></li></ol></li></ol></li>\
            <li><a href="two.xhtml">Two</a></li>
            """))
        XCTAssertEqual(book.tableOfContents, [
            EPUBNavigationItem(title: "Part One", children: [
                EPUBNavigationItem(title: "One", href: "OPS/one.xhtml"),
                EPUBNavigationItem(title: "Deeper", children: [EPUBNavigationItem(title: "Start", href: "OPS/one.xhtml#start")]),
            ]),
            EPUBNavigationItem(title: "Two", href: "OPS/two.xhtml"),
        ])
    }

    func testTheContentsNavIsFoundAmongOtherNavsWhereverItStands() throws {
        let book = try open(nav: """
            <header><h1>A Test Book</h1></header>
            <nav epub:type="landmarks"><ol><li><a epub:type="bodymatter" href="two.xhtml">Start</a></li></ol></nav>
            <nav aria-label="Tables"><h2>Tables</h2><ol><li><a href="two.xhtml#t1">Table 1</a></li></ol></nav>
            <nav epub:type="lot"><ol><li><a href="two.xhtml#t1">Table 1</a></li></ol></nav>
            <section><div><nav epub:type="frontmatter toc" role="doc-toc"><h2>Contents</h2><ol><li><a href="one.xhtml">One</a></li></ol></nav></div></section>
            <nav epub:type="page-list" hidden=""><ol><li><a href="one.xhtml#start">1</a></li></ol></nav>
            """)
        XCTAssertEqual(book.tableOfContents, [EPUBNavigationItem(title: "One", href: "OPS/one.xhtml")])
        XCTAssertEqual(book.landmarks.map(\.types), [["bodymatter"]])
        XCTAssertEqual(book.pageList, [EPUBPageListEntry(label: "1", href: "OPS/one.xhtml#start")])
    }

    func testANavigationDocumentWithoutAContentsNavOpensWithNoContents() throws {
        let book = try open(nav: "<nav epub:type=\"landmarks\"><ol><li><a epub:type=\"toc\" href=\"nav.xhtml\">Contents</a></li></ol></nav><p>No list here.</p>")
        XCTAssertTrue(book.tableOfContents.isEmpty)
        XCTAssertEqual(book.landmarks, [EPUBLandmark(types: ["toc"], title: "Contents", href: "OPS/nav.xhtml")])
        XCTAssertEqual(book.spine.count, 2)
    }

    func testAContentsEntryWithoutALabelElementIsKeptForItsChildren() throws {
        // RSC-005 for EPUBCheck (an `li` must start with `a` or `span`); its children still resolve.
        let book = try open(nav: toc("<li>Loose text<ol><li><a href=\"two.xhtml\">Two</a></li></ol></li><li/>"))
        XCTAssertEqual(book.tableOfContents.first?.children, [EPUBNavigationItem(title: "Two", href: "OPS/two.xhtml")])
        XCTAssertNil(book.tableOfContents.first?.href)
    }

    // MARK: NCX

    private func ncx(_ map: String, head: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="en">
          <head><meta name="dtb:uid" content="test-book"/><meta name="dtb:depth" content="2"/>\(head)</head>
          <docTitle><text>A Test Book</text></docTitle><docAuthor><text>Test Author</text></docAuthor>
          <navMap>\(map)</navMap>
        </ncx>
        """
    }

    func testNCXNavPointsNestInDocumentOrderWhateverTheirPlayOrder() throws {
        let book = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/toc.ncx": ncx("""
            <navInfo><text>The contents.</text></navInfo>
            <navPoint id="p2" playOrder="7" class="chapter">
              <navLabel>
                <text>  Second in play order  </text>
              </navLabel>
              <content src="two.xhtml"/>
              <navPoint id="p3"><navLabel><text>Inside</text></navLabel><content src="two.xhtml#inside"/></navPoint>
            </navPoint>
            <navPoint id="p1" playOrder="1"><navLabel><text>First in play order</text><audio src="label.mp3" clipBegin="0s" clipEnd="1s"/></navLabel>\
            <content src="./one.xhtml#start"/></navPoint>
            """)], epub2: true))
        XCTAssertEqual(book.tableOfContents, [
            EPUBNavigationItem(title: "Second in play order", href: "OPS/two.xhtml",
                               children: [EPUBNavigationItem(title: "Inside", href: "OPS/two.xhtml#inside")]),
            EPUBNavigationItem(title: "First in play order", href: "OPS/one.xhtml#start"),
        ])
    }

    func testAnNCXNavPointWithoutContentOrLabelIsKeptWithWhatItHas() throws {
        // RSC-005 for EPUBCheck; converters write both.
        let book = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/toc.ncx": ncx("""
            <navPoint id="p1"><navLabel><text>A heading</text></navLabel><navPoint id="p2"><content src="one.xhtml"/></navPoint></navPoint>
            """)], epub2: true))
        XCTAssertEqual(book.tableOfContents, [
            EPUBNavigationItem(title: "A heading", children: [EPUBNavigationItem(title: "", href: "OPS/one.xhtml")]),
        ])
    }

    func testAnEPUB2BookWhoseNCXIsMalformedIsATypedRefusal() throws {
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/toc.ncx": "<ncx><navMap><navPoint></navMap></ncx>"], epub2: true))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .invalidXML("OPS/toc.ncx"))
        }
    }
}
