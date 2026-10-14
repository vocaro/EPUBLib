import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing

final class ContentDocumentRecoveryTextTests: XCTestCase {
    private let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    private func page(_ body: String) -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body>\(body)</body></html>"
    }
    private func parse(_ markup: String, limits: ContentLimits = .init()) throws -> ContentDocument {
        try ContentDocument.parse(Data(markup.utf8), path: "OPS/one.xhtml", limits: limits)
    }

    func testTextAfterHTMLWithAnXMLDeclarationRemainsInTheBodyAndBuiltSection() throws {
        let markup = page("<p>one<br>two</p>") + "trailing"
        for prefix in ["", declaration, "\u{FEFF}" + declaration] {
            let document = try parse(prefix + markup)
            XCTAssertEqual(document.body?.textContent, "onetwotrailing", prefix)
            XCTAssertTrue(document.recoveredAsHTML, prefix)
            XCTAssertFalse(document.canResolveCFIs, prefix)
            let section = try SectionContentSupport.raw(prefix + markup)
            XCTAssertEqual(section.string.string, "one\u{2028}two\ntrailing", prefix)
            XCTAssertTrue(section.report.recoveredAsHTML, prefix)
            SectionContentSupport.assertTextMapContracts(section)
            let match = try XCTUnwrap(TextSearch.matches(of: "trailing", in: section.document, locale: nil).first)
            let location = (section.string.string as NSString).range(of: "trailing").location
            XCTAssertEqual(section.map.location(of: match.start), location)
            XCTAssertEqual(section.map.location(of: match.end), location + 8)
            XCTAssertEqual(EPUBCFI.localPath(from: match.start, to: match.end, in: section.document), "")
        }
    }

    func testEarlyBodyAndHTMLEndTagsKeepFollowingTextElementsAndAnchors() throws {
        for end in ["</body>", "</BODY >", "</body></HTML\n>", "</body class='x'>", "</body\"x>", "</html>"] {
            let input = declaration + "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head>"
                + "<body><p>one<br>two</p>\(end)<p id='after'>after</p>tail</html>"
            let document = try parse(input)
            XCTAssertEqual(document.body?.textContent, "onetwoaftertail", end)
            let section = try SectionContentSupport.raw(input)
            XCTAssertEqual(section.string.string, "one\u{2028}two\nafter\ntail", end)
            XCTAssertEqual(section.anchors["after"], 8, end)
            SectionContentSupport.assertTextMapContracts(section)
        }
        let literal = try parse(page("<p title='</body></html>'>a<![CDATA[</body></html>]]>b<br></p>") + "tail")
        XCTAssertEqual(literal.body?.textContent, "a</body></html>btail")
        XCTAssertEqual(literal.nodes.first { $0.isHTML("p") }?.attribute("title"), "</body></html>")
    }

    func testTrailingTreeRepairPreservesMalformedDoctypeAttributesAndRawText() throws {
        let start = "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd>\n"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en>\n"
        let doctype = start + "<head><meta charset=\"utf-8\"/><title>T</title></head>"
            + "<body><p id='one'>x</p><img id='image' src=\"a.png\" alt=\"A\"/><p id='last'>z</p></body></html>"
        let attributes = "<html><head><title>T</title></head><body " + String(repeating: "a", count: 100)
            + "1=\"x><p id='one'>x</p><script src=\"k.js\"/><p id='last'>y</p></body></html>tail"
        let raw = page("<p id='one'>a</p><script>var x='</body></html>';</script><p id='last'>b<br></p>") + "tail"
        for input in [doctype, attributes, raw] {
            XCTAssertEqual(try HTMLRecoveryText.prepared(Data(input.utf8), path: "x", limit: .max), Data(input.utf8),
                           "trailing repair must not rewrite declarations, quotes, attributes, or raw text")
            let document = try parse(input)
            XCTAssertEqual(document.head?.textContent, "T")
            XCTAssertNotNil(document.element(id: "one"))
            XCTAssertNotNil(document.element(id: "last"))
            let section = BuilderHarness.build(document: document)
            XCTAssertNotNil(section.anchors["one"])
            XCTAssertNotNil(section.anchors["last"])
            SectionContentSupport.assertTextMapContracts(section)
        }
        let document = try parse(doctype)
        XCTAssertEqual(document.element(id: "image")?.attribute("alt"), "A")
        XCTAssertEqual(document.element(id: "last")?.textContent, "z")
        XCTAssertEqual(try parse(attributes).body?.textContent, "xytail")
        XCTAssertEqual(try SectionContentSupport.raw(raw).string.string, "a\nb\ntail")
    }

    func testRecoveredCDATACharactersAreShownWithTheirSearchAndAnchorOffsets() throws {
        let input = page("<p id='p'>s<![CDATA[t & u]]> v<br></p>")
        XCTAssertEqual(try parse(input).body?.textContent, "st & u v")
        let section = try SectionContentSupport.raw(input)
        XCTAssertEqual(section.string.string, "st & u v")
        XCTAssertTrue(section.report.recoveredAsHTML)
        XCTAssertFalse(section.document.canResolveCFIs)
        XCTAssertEqual(section.anchors["p"], 0)
        SectionContentSupport.assertTextMapContracts(section)
        let match = try XCTUnwrap(TextSearch.matches(of: "t & u", in: section.document, locale: nil).first)
        XCTAssertEqual(match.start.node.text, "st & u v")
        XCTAssertEqual([match.start.offset, match.end.offset], [1, 6])
        XCTAssertEqual(section.map.location(of: match.start), 1)
        XCTAssertEqual(section.map.location(of: match.end), 6)
        XCTAssertNil(EPUBCFI.resolve(localPath: "/4/2/1:1", in: section.document))
    }

    func testCDATAIsLiteralAndAdjacentTextMergesAtDecodedUTF16Offsets() throws {
        let input = declaration + page("<p id='p'>a<![CDATA[<b>&nbsp; &amp; 😀]]>z<br></p><p id='after'>after</p>")
        let document = try parse(input)
        let paragraph = try XCTUnwrap(document.element(id: "p"))
        XCTAssertEqual(paragraph.textContent, "a<b>&nbsp; &amp; 😀z")
        XCTAssertEqual(paragraph.children.filter(\.isText).count, 1)
        let text = try XCTUnwrap(paragraph.children.first)
        XCTAssertEqual(text.utf16Length, 20)
        let match = try XCTUnwrap(TextSearch.matches(of: "😀z", in: document, locale: nil).first)
        XCTAssertEqual([match.start.offset, match.end.offset], [17, 20])
        let section = BuilderHarness.build(document: document)
        XCTAssertEqual(section.string.string, "a<b>&nbsp; &amp; 😀z\nafter")
        XCTAssertEqual(section.anchors["after"], 21)
        SectionContentSupport.assertTextMapContracts(section)
    }

    func testCDATAOpenersInAttributesCommentsAndRawTextRemainInTheirContext() throws {
        let input = page("<p title='<![CDATA[attr & x]]>'>a<!-- <![CDATA[hidden]]> -->b<br></p>"
            + "<script><![CDATA[script & x]]></script><style><![CDATA[style & x]]></style><p>after</p>")
        let document = try parse(input)
        XCTAssertEqual(document.nodes.first { $0.isHTML("p") }?.attribute("title"), "<![CDATA[attr & x]]>")
        XCTAssertEqual(document.nodes.first { $0.isHTML("script") }?.textContent, "<![CDATA[script & x]]>")
        XCTAssertEqual(document.nodes.first { $0.isHTML("style") }?.textContent, "<![CDATA[style & x]]>")
        XCTAssertEqual(BuilderHarness.build(document: document).string.string, "ab\nafter")
        let stylesheet = "<?xml-stylesheet href='x.css'?>" + input
        XCTAssertTrue(String(decoding: try HTMLRecoveryText.prepared(Data(stylesheet.utf8), path: "x", limit: .max), as: UTF8.self)
            .hasPrefix("<?xml-stylesheet"))
    }

    func testWellFormedCDATAKeepsTheXMLTreeAndWideRecoveryKeepsAllCharacters() throws {
        let well = try parse(declaration + page("<p>a<![CDATA[<b>& 😀]]>z<br/></p>"))
        XCTAssertFalse(well.recoveredAsHTML)
        XCTAssertTrue(well.canResolveCFIs)
        XCTAssertEqual(well.body?.textContent, "a<b>& 😀z")
        let input = "<?xml version='1.0' encoding='UTF-16'?>" + page("<p>a<![CDATA[<b>& 😀]]>z<br></p>") + "tail"
        let wide = Data([0xFF, 0xFE]) + (try XCTUnwrap(input.data(using: .utf16LittleEndian)))
        let document = try ContentDocument.parse(wide, path: "wide.xhtml")
        XCTAssertTrue(document.recoveredAsHTML)
        XCTAssertFalse(document.canResolveCFIs)
        XCTAssertEqual(document.body?.textContent, "a<b>& 😀ztail")
    }

    func testRecoveryTextKeepsByteTreeAndDeclarationSafetyLimits() throws {
        let input = page("<p><![CDATA[" + String(repeating: "<&>", count: 16) + "]]><br></p>")
        let prepared = try HTMLRecoveryText.prepared(Data(input.utf8), path: "OPS/one.xhtml", limit: .max)
        XCTAssertGreaterThan(prepared.count, input.utf8.count)
        var limits = ContentLimits(); limits.bytes = prepared.count
        let document = try parse(input, limits: limits)
        XCTAssertEqual(document.body?.textContent, String(repeating: "<&>", count: 16))
        limits.bytes -= 1
        XCTAssertThrowsError(try parse(input, limits: limits)) {
            XCTAssertEqual($0 as? ContentDocumentError, .limitExceeded("bytes"))
        }
        limits = ContentLimits(); limits.nodes = document.nodes.count - 1
        XCTAssertThrowsError(try parse(input, limits: limits)) {
            XCTAssertEqual($0 as? ContentDocumentError, .limitExceeded("nodes"))
        }
        limits = ContentLimits(); limits.depth = 3
        XCTAssertThrowsError(try parse(input, limits: limits)) {
            XCTAssertEqual($0 as? ContentDocumentError, .limitExceeded("depth"))
        }
        XCTAssertThrowsError(try parse("<!DOCTYPE html [<!ENTITY e 'hidden'>]>" + input)) {
            XCTAssertEqual($0 as? ContentDocumentError, .unsafeMarkup("OPS/one.xhtml"))
        }
        let literal = try parse(page("<p><![CDATA[<!ENTITY e 'hidden'>]]><br></p>"))
        XCTAssertEqual(literal.body?.textContent, "<!ENTITY e 'hidden'>", "inert CDATA stays text")
    }
}
