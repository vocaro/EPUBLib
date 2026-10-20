import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

final class NativeRecoveryTextPreservationTests: XCTestCase {
    private func page(_ body: String, title: String = "T") -> String {
        "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>\(title)</title></head><body>\(body)</body></html>"
    }
    private func parse(_ xml: String, limits: ContentLimits = .init()) throws -> ContentDocument {
        try ContentDocument.parse(Data(xml.utf8), path: "one.xhtml", limits: limits)
    }

    func testStrictTrailingContentRendersWithoutMovingDOMNodesOrInvalidatingCFIs() throws {
        let xml = "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body><p>One</p></body>"
            + "<h2 id='two'>Two</h2>tail<span id='last'>!</span></html>"
        let document = try parse(xml)
        XCTAssertFalse(document.recoveredAsHTML)
        XCTAssertTrue(document.canResolveCFIs)
        let two = try XCTUnwrap(document.element(id: "two"))
        XCTAssertTrue(two.parent === document.root)
        XCTAssertEqual(document.body?.textContent, "One")
        let text = BuilderHarness.build(document: document)
        XCTAssertEqual(text.string.string, "One\nTwo\ntail!")
        XCTAssertEqual(text.anchors["two"], 4)
        XCTAssertEqual(SectionContentSupport.mapViolations(text) + SectionContentSupport.locationViolations(text), [])
        let node = try XCTUnwrap(two.children.first)
        let path = EPUBCFI.localPath(from: DOMPosition(node), to: DOMPosition(node, node.utf16Length), in: document)
        XCTAssertFalse(path.isEmpty)
        let roundTrip = try XCTUnwrap(EPUBCFI.resolve(localPath: path, in: document))
        XCTAssertTrue(roundTrip.start.node === node)
        XCTAssertEqual(roundTrip.start.offset, 0)
    }

    func testBangCommentEndsBeforeCDATAAndNullRepairInNativeFallback() throws {
        let document = try parse(page("<!-- n --!><p id='p'>p < 0.05 c</p><!-- ignored -->"
            + "<!-- n --!><p id='c'><![CDATA[a < b & c]]>\u{0} done</p>"))
        XCTAssertTrue(document.recoveredAsHTML)
        XCTAssertEqual(document.element(id: "p")?.textContent, "p < 0.05 c")
        XCTAssertEqual(document.element(id: "c")?.textContent, "a < b & c done")
        let text = BuilderHarness.build(document: document)
        XCTAssertEqual(text.string.string, "p < 0.05 c\na < b & c done")
        XCTAssertEqual(SectionContentSupport.mapViolations(text), [])
    }

    func testInvalidNumericReferencesSurviveTextAndEveryAuthoredAttributeSurface() throws {
        let literal = "&# &#x &#X &#; &#x; &#-1; &#xg; &bogus; &bogus"
        let document = try parse(page("<h2 id='h'>\(literal)</h2><p><img id='image' alt='x &# y' title='title &#x tail'/></p>"
            + "<math id='math' alttext='math &#x tail' data-value='value &#; tail'><mi>Ignored</mi>"
            + "<annotation id='annotation' encoding='text/plain'>annotation &#; tail</annotation></math>", title: "Title &# tail"))
        XCTAssertTrue(document.recoveredAsHTML)
        XCTAssertFalse(document.canResolveCFIs)
        XCTAssertEqual(document.head?.elementChildren.first { $0.isHTML("title") }?.textContent, "Title &# tail")
        XCTAssertEqual(document.element(id: "h")?.textContent, literal)
        XCTAssertEqual(document.element(id: "image")?.attribute("alt"), "x &# y")
        XCTAssertEqual(document.element(id: "image")?.attribute("title"), "title &#x tail")
        XCTAssertEqual(document.element(id: "math")?.attribute("alttext"), "math &#x tail")
        XCTAssertEqual(document.element(id: "math")?.attribute("data-value"), "value &#; tail")
        XCTAssertEqual(document.element(id: "annotation")?.textContent, "annotation &#; tail")
        XCTAssertEqual(try parse(page("<p>&#</p><p>&#x</p><p>&#;</p>")).body?.textContent, "&#&#x&#;")
    }

    func testInvalidReferenceRepairPreservesParserContextsAndAvoidsAuthoredPlaceholderCollisions() throws {
        let first = String(try XCTUnwrap(Unicode.Scalar(0xFDD0)))
        let second = String(try XCTUnwrap(Unicode.Scalar(0xFDD1)))
        let document = try parse(page("<p id='p'>\(first) &#64977; &# tail < 2</p>"
            + "<p id='c'><![CDATA[&# &amp; &#65; <tag>]]></p><!-- &# ignored --!>"
            + "<script id='s'>const x = '&#';</script><style id='style'>p::after { content:'&#x' }</style>"))
        XCTAssertEqual(document.element(id: "p")?.textContent, "\(first) \(second) &# tail < 2")
        XCTAssertEqual(document.element(id: "c")?.textContent, "&# &amp; &#65; <tag>")
        XCTAssertEqual(document.element(id: "s")?.textContent, "const x = '&#';")
        XCTAssertEqual(document.element(id: "style")?.textContent, "p::after { content:'&#x' }")
        XCTAssertEqual(try parse(page("<p>&#65; &#x41; &#65 &#x41 &amp; &bogus;</p>")).body?.textContent, "A A A A & &bogus;")
    }

    func testSharedInvalidReferencePreparationHonorsByteLimitsAndCannotHideDeclarations() throws {
        let data = Data("<p>x &# y</p>".utf8)
        let prepared = try XCTUnwrap(HTMLLiteralAmpersands.prepared(data, limit: data.count + 2))
        XCTAssertNotNil(prepared.placeholder)
        XCTAssertEqual(HTMLLiteralAmpersands.restored(String(decoding: prepared.data, as: UTF8.self), placeholder: prepared.placeholder),
            "<p>x &# y</p>")
        XCTAssertNil(HTMLLiteralAmpersands.prepared(data, limit: prepared.data.count - 1))
        for body in ["<p>&# <!ENTITY a 'b'></p>", "<!DOCTYPE html [<!ENTITY a 'b'>]><p>&# tail</p>"] {
            XCTAssertThrowsError(try parse(page(body))) {
                XCTAssertEqual($0 as? ContentDocumentError, .unsafeMarkup("one.xhtml"))
            }
        }
        // Native parsing permits declaration-looking examples inside an attribute/comment;
        // the placeholder repair does not reinterpret either as markup.
        let examples = try parse(page("<!-- &# <!ENTITY a 'b'> --!><p id='p' title='&# <!ENTITY a b>'>after</p>"))
        XCTAssertEqual(examples.element(id: "p")?.attribute("title"), "&# <!ENTITY a b>")
        XCTAssertEqual(examples.element(id: "p")?.textContent, "after")
    }

    func testUnknownAndSemicolonlessNamedReferencesDoNotTruncateTextOrAttributes() throws {
        let literal = "&amp &copy &bogus &bogus;"
        let document = try parse(page("<p id='p'>\(literal)</b> tail</p><img id='image' alt='\(literal) tail'/>", title: literal + " tail"))
        XCTAssertEqual(document.element(id: "p")?.textContent, literal + " tail")
        XCTAssertEqual(document.element(id: "image")?.attribute("alt"), literal + " tail")
        XCTAssertEqual(document.head?.elementChildren.first { $0.isHTML("title") }?.textContent, literal + " tail")
    }

    func testAllAuthoredPlaceholderCandidatesStillAllowLosslessInvalidReferenceRepair() throws {
        var scalars = String.UnicodeScalarView()
        for range in [UInt32(0xFDD0)...0xFDEF, 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD] {
            for value in range { scalars.append(try XCTUnwrap(Unicode.Scalar(value))) }
        }
        let prefix = String(try XCTUnwrap(Unicode.Scalar(0xFDD0)))
        let xml = page("<p>\(String(scalars))</p><p id='p'>\(prefix)&# tail\(prefix)</p>")
        let document = try parse(xml)
        XCTAssertTrue(document.recoveredAsHTML)
        XCTAssertEqual(document.element(id: "p")?.textContent, prefix + "&# tail" + prefix)
    }

    func testNumericReferencesCannotImpersonateRecoveryPlaceholders() throws {
        let common = (UInt32(0xFDD0)...0xFDEF).map { "&#x\(String($0, radix: 16));" }.joined()
        let privateUse = [0xE000, 0xE001, 0xE002].map { String(Unicode.Scalar($0)!) }.joined(separator: " ")
        let document = try parse(page("<p>\(common)</p><p id='p'>&#xE000; &#57345; &#xe002; x &# y</p>"
            + "<img id='image' alt='&#xE000; &# tail'/>"))
        XCTAssertEqual(document.element(id: "p")?.textContent, privateUse + " x &# y")
        XCTAssertEqual(document.element(id: "image")?.attribute("alt"), String(Unicode.Scalar(0xE000)!) + " &# tail")
        let text = BuilderHarness.build(document: document)
        XCTAssertTrue(text.string.string.contains(privateUse + " x &# y"))
        XCTAssertEqual(SectionContentSupport.mapViolations(text), [])
    }

    func testBangCommentEndingCannotHideAttributeBoundsOrDeclarations() throws {
        let attributes = (0..<1023).map { " a\($0)=''" }.joined()
        let passing = page("<!-- n --!><p id='p'\(attributes)>x &# tail</p>")
        XCTAssertEqual(try parse(passing).element(id: "p")?.textContent, "x &# tail")
        let overflowing = passing.replacingOccurrences(of: "id='p'", with: "id='p' extra=''")
        XCTAssertThrowsError(try parse(overflowing)) {
            XCTAssertEqual($0 as? ContentDocumentError, .limitExceeded("attributesPerElement"))
        }
        XCTAssertThrowsError(try parse(page("<!-- n --!><!ENTITY a 'b'><p>after</p>"))) {
            XCTAssertEqual($0 as? ContentDocumentError, .unsafeMarkup("one.xhtml"))
        }
    }
}
