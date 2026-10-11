import Foundation
import XCTest
@testable import EPUBViewing

final class HTMLCFITests: XCTestCase {
    struct Vectors: Decodable {
        let upstream: String
        let documents: [Vector]
    }
    struct Vector: Decodable {
        let name: String
        let model: [[String]]
        let cfi: String
        let quote: String
        let start: [Int]
        let end: [Int]
    }
    static let vectors = try! JSONDecoder().decode(Vectors.self, from: Data(HTMLCFIGoldenVectors.json.utf8))

    func testRecordedFoliateRangesKeepTheirQuotesOrAreRefused() throws {
        XCTAssertEqual(Self.vectors.upstream, "78914aef4466eb960965702401634c2cb348e9b1")
        XCTAssertEqual(Self.vectors.documents.map(\.name), HTMLCFIFixtures.fixtures.map(\.name))
        for (fixture, vector) in zip(HTMLCFIFixtures.fixtures, Self.vectors.documents) {
            let document = try ContentDocument.parse(Data(fixture.markup.utf8), path: "\(fixture.name).xhtml")
            XCTAssertTrue(document.recoveredAsHTML, fixture.name)
            XCTAssertEqual(document.canResolveCFIs, fixture.compatible, fixture.name)
            XCTAssertEqual(vector.quote, fixture.quote, "the recorded old CFI must select the expected quote")
            if fixture.compatible {
                let model = document.nodes.map { $0.isElement ? ["E", $0.name, $0.namespace] : ["T", $0.text] }
                XCTAssertEqual(model, vector.model, fixture.name)
                let range = try XCTUnwrap(EPUBCFI.resolve(localPath: vector.cfi, in: document), fixture.name)
                XCTAssertEqual([range.start.node.order, range.start.offset], vector.start, fixture.name)
                XCTAssertEqual([range.end.node.order, range.end.offset], vector.end, fixture.name)
                XCTAssertEqual(quote(range, document: document), vector.quote, fixture.name)
                XCTAssertEqual(EPUBCFI.localPath(from: range.start, to: range.end, in: document), EPUBCFI.unwrap(vector.cfi), fixture.name)
                let rendered = BuilderHarness.build(document: document)
                let lower = rendered.map.location(of: range.start)
                let upper = rendered.map.location(of: range.end, isEnd: true)
                XCTAssertEqual(TextSearch.normalizeQuote(rendered.string.attributedSubstring(from: NSRange(location: lower, length: upper - lower)).string),
                               TextSearch.normalizeQuote(vector.quote), fixture.name)
                BuilderHarness.assertMapRoundTrips(rendered)
            } else {
                XCTAssertNil(EPUBCFI.resolve(localPath: vector.cfi, in: document), fixture.name)
                XCTAssertNil(EPUBCFI.resolve(localPath: "/4/2[second]/1:0", in: document), "an ID assertion must not bypass the qualification")
                let text = try XCTUnwrap(document.nodes.first(where: \.isText))
                XCTAssertEqual(EPUBCFI.localPath(from: DOMPosition(text), to: DOMPosition(text, text.utf16Length), in: document), "")
                XCTAssertTrue(BuilderHarness.build(document: document).report.cfiUnavailable)
            }
        }
    }

    private func quote(_ range: (start: DOMPosition, end: DOMPosition), document: ContentDocument) -> String {
        var output = ""
        for node in document.nodes[range.start.node.order...range.end.node.order] where node.isText {
            let lower = node === range.start.node ? range.start.offset : 0
            let upper = node === range.end.node ? range.end.offset : node.utf16Length
            output += (node.text as NSString).substring(with: NSRange(location: lower, length: upper - lower))
        }
        return output
    }

    func testStrictXHTMLKeepsXMLTreeEvenWithHTMLSensitiveElements() throws {
        let markup = "<html xmlns='http://www.w3.org/1999/xhtml'>\n<head/><body><p><span/>Before <![CDATA[retained]]></p><table><tr><td>Cell</td></tr></table></body>\n</html>"
        let document = try ContentDocument.parse(Data(markup.utf8), path: "strict.xhtml")
        XCTAssertFalse(document.recoveredAsHTML)
        XCTAssertTrue(document.canResolveCFIs)
        XCTAssertTrue(document.root.children.first!.isText)
        XCTAssertEqual(document.nodes.first { $0.name == "tr" }?.parent?.name, "table")
        let text = try XCTUnwrap(document.nodes.first { $0.isText && $0.text.contains("retained") })
        let path = EPUBCFI.localPath(from: DOMPosition(text), to: DOMPosition(text, text.utf16Length), in: document)
        XCTAssertEqual(EPUBCFI.resolve(localPath: path, in: document)?.start, DOMPosition(text))
    }

    func testOPFAndContainerKeepXMLParsingWithoutNamespace() throws {
        for markup in ["<package><metadata/><manifest/><spine><itemref idref='one'/></spine></package>",
                       "<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>"] {
            let document = try ContentDocument.parse(Data(markup.utf8), path: "package.xml", asContent: false)
            XCTAssertFalse(document.recoveredAsHTML)
            XCTAssertTrue(document.canResolveCFIs)
            XCTAssertTrue(document.root.namespace.isEmpty)
        }
    }

    func testXHTMLPublicIdentifierIsReadFromThePublicFieldWithXMLWhitespace() throws {
        let publicID = "-//W3C//DTD XHTML 1.1//EN"
        let source = "<!DOCTYPE\nhtml\tPUBLIC '\(publicID)' 'https://example.invalid/xhtml.dtd'><html xmlns='http://www.w3.org/1999/xhtml'><head/><body><p>Named&nbsp;entity</p></body></html>"
        let document = try ContentDocument.parse(Data(source.utf8), path: "doctype.xhtml")
        XCTAssertFalse(document.recoveredAsHTML)
        XCTAssertTrue(document.canResolveCFIs)
        XCTAssertFalse(HTMLCFICompatibility.hasXHTMLDTD(Data("<!DOCTYPE html PUBLIC 'unknown' '\(publicID)'><html/>".utf8)),
                       "a lookalike system identifier must not qualify an unknown public DTD")
    }

    func testRecoveredPrefixAttributesRetainNativeLanguageAndSemantics() throws {
        let fixture = try XCTUnwrap(HTMLCFIFixtures.fixtures.first { $0.name == "prefixed-semantic-attributes" })
        let document = try ContentDocument.parse(Data(fixture.markup.utf8), path: "semantics.xhtml")
        XCTAssertTrue(document.canResolveCFIs)
        XCTAssertEqual(document.language, "fr")
        XCTAssertEqual(document.body?.epubTypes, ["bodymatter"])
        XCTAssertEqual(document.element(id: "chapter")?.epubTypes, ["chapter"])
        XCTAssertEqual(document.root.attribute("xml:lang"), "fr")
    }

    func testUnknownXMLEncodingAndHTMLNumericRemappingCannotIssueCFIs() throws {
        for source in ["<?xml version='1.0' encoding='ISO-8859-1'?><html><head><title>Book</title></head><body><p>caf\u{00C3}\u{00A9}</p></body></html>",
                       "<html><head><title>Book</title></head><body><p>Text &#128;</p></body></html>",
                       "<html><head><title>Book</title></head><body><p>Text &#x0080;</p></body></html>"] {
            let document = try ContentDocument.parse(Data(source.utf8), path: "ambiguous.xhtml")
            XCTAssertFalse(document.canResolveCFIs)
            XCTAssertNil(EPUBCFI.resolve(localPath: "/4/2/1:0", in: document))
        }
    }

    func testDeclarationSafetyAndLimitsStillApplyBeforeCompatibility() throws {
        for markup in ["<!DOCTYPE html [<!ENTITY e 'text'>]><html><body>&e;</body></html>",
                       "<!DOCTYPE html [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><html><body>&e;</body></html>"] {
            XCTAssertThrowsError(try ContentDocument.parse(Data(markup.utf8), path: "unsafe.xhtml"))
        }
        let fixture = HTMLCFIFixtures.fixtures[0]
        var limits = ContentLimits(); limits.bytes = 10
        XCTAssertThrowsError(try ContentDocument.parse(Data(fixture.markup.utf8), path: "bounded.xhtml", limits: limits))
        limits = ContentLimits(); limits.nodes = 4
        XCTAssertThrowsError(try ContentDocument.parse(Data(fixture.markup.utf8), path: "bounded.xhtml", limits: limits))
        limits = ContentLimits(); limits.depth = 2
        XCTAssertThrowsError(try ContentDocument.parse(Data(fixture.markup.utf8), path: "bounded.xhtml", limits: limits))
    }
}
