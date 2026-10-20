import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// Nothing libxml2 says about a book reaches the host's standard error (#392): not from
/// `ContentDocument.parse`, the reader's build of a section, or the encoding reading that the
/// HTML fallback makes.
@MainActor final class LibXML2StandardErrorTests: XCTestCase {
    private typealias Markup = Fixture.NoisyMarkup

    func testTheIssuesFileIsTheReviewersFile() {
        XCTAssertEqual(Markup.repeatedID.count, 147)
        XCTAssertEqual(SHA256.hash(data: Markup.repeatedID).map { String(format: "%02x", $0) }.joined(),
                       "5865b0b6434db3b1d39baf5c8da5d9e61ef730c82e7c250301912e0d2bde6024")
    }

    func testContentDocumentParseWritesNothingToStandardError() throws {
        var inputs: [(String, Data)] = [("repeated xml:id", Markup.repeatedID), ("invalid xml:id", Markup.invalidID),
                                        ("XHTML repeated xml:id", Markup.repeatedIDXHTML), ("HTML repeated id", Markup.repeatedIDHTML)]
        inputs += Markup.otherMessages.enumerated().map { ("other message \($0.offset)", $0.element) }
        for (encoding, bytes) in Markup.undecodableEncodings {
            inputs.append(("SVG in \(encoding)", Markup.undecodableSVG(encoding, bytes)))
            inputs.append(("XHTML in \(encoding)", Markup.undecodableXHTML(encoding, bytes)))
        }
        for (name, data) in inputs {
            for asContent in [false, true] {
                let (_, output) = try StandardErrorCapture.capture {
                    try? ContentDocument.parse(data, path: "EPUB/drawing", asContent: asContent)
                }
                XCTAssertEqual(output, "", "\(name), asContent: \(asContent)")
            }
        }
    }

    func testTheIssuesFileParsesAsItDidBefore() throws {
        let document = try ContentDocument.parse(Markup.repeatedID, path: "EPUB/drawing.svg", asContent: false)
        XCTAssertEqual(document.nodes.filter { $0.name == "rect" }.count, 2)
    }

    func testHTMLSourceEncodingWritesNothingToStandardError() throws {
        for (encoding, bytes) in Markup.undecodableEncodings {
            let (decoded, output) = try StandardErrorCapture.capture {
                try HTMLSourceEncoding.utf8(Markup.undecodableXHTML(encoding, bytes), path: "EPUB/page.xhtml", limit: 1 << 20)
            }
            XCTAssertNil(decoded, encoding)
            XCTAssertEqual(output, "", encoding)
        }
    }

    func testSectionBuildOfEachSpineItemWritesNothingToStandardError() throws {
        var book = Fixture.SpecBook()
        book.add(href: "drawing.svg", id: "drawing", mediaType: "image/svg+xml", Markup.repeatedID)
        book.add(href: "invalid.svg", id: "invalid", mediaType: "image/svg+xml", Markup.invalidID)
        book.add(href: "repeated.xhtml", id: "repeated", mediaType: "application/xhtml+xml", Markup.repeatedIDXHTML)
        book.add(href: "html.xhtml", id: "html", mediaType: "application/xhtml+xml", Markup.repeatedIDHTML)
        book.add("inline", body: "<p>Before</p>" + String(decoding: Markup.repeatedID, as: UTF8.self))
        for (index, (encoding, bytes)) in Markup.undecodableEncodings.enumerated() {
            book.add(href: "encoded\(index).xhtml", id: "encoded\(index)", mediaType: "application/xhtml+xml",
                     Markup.undecodableXHTML(encoding, bytes))
            book.add(href: "encoded\(index).svg", id: "drawn\(index)", mediaType: "image/svg+xml", Markup.undecodableSVG(encoding, bytes))
        }
        let archive = try book.archive()
        let (built, output) = try StandardErrorCapture.capture { try SpecConformanceBuild(archive: archive) }
        XCTAssertEqual(output, "")
        XCTAssertEqual(built.sections.count, 9)
        XCTAssertFalse(built[0].report.withheld)
        XCTAssertEqual(built[0].specImages.count, 1, "the issue's file is drawn as it was")
    }
}
