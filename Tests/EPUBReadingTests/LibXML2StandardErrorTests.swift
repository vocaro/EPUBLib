import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBText
import Foundation
import libxml2
import XCTest

/// Nothing libxml2 says about a book reaches the host's standard error (#392): not from opening
/// it, which screens and parses its XML, or from extracting its text.
final class LibXML2StandardErrorTests: XCTestCase {
    private typealias Markup = Fixture.NoisyMarkup

    func testTextExtractionWritesNothingToStandardError() throws {
        var book = Fixture.SpecBook()
        book.add(href: "repeated.xhtml", id: "repeated", mediaType: "application/xhtml+xml", Markup.repeatedIDXHTML)
        book.add(href: "html.xhtml", id: "html", mediaType: "application/xhtml+xml", Markup.repeatedIDHTML)
        for (index, (encoding, bytes)) in Markup.undecodableEncodings.enumerated() {
            book.add(href: "encoded\(index).xhtml", id: "encoded\(index)", mediaType: "application/xhtml+xml",
                     Markup.undecodableXHTML(encoding, bytes))
        }
        let publication = try EPUBPublication.open(data: book.archive())
        for index in publication.spine.indices {
            for recovers in [false, true] {
                let (_, output) = try StandardErrorCapture.capture {
                    try? publication.textSection(at: index, recoversMalformedMarkup: recovers)
                }
                XCTAssertEqual(output, "", "\(publication.spine[index].resource.path), recovers: \(recovers)")
            }
        }
        XCTAssertEqual(try publication.textSection(at: 0).text, "One\nTwo\nThree", "a repeated xml:id is read as it was")
    }

    /// The library takes libxml2's messages from this thread's handlers only while it parses: a
    /// host's own handlers are not given a book's messages, and are given the host's own after.
    func testAHostsOwnHandlersTakeItsOwnMessagesAfterward() throws {
        // A structured handler that counts its calls, and a FILE for the generic handler that
        // counts the bytes written to it.
        let counts = UnsafeMutablePointer<Int>.allocate(capacity: 2)
        counts.initialize(repeating: 0, count: 2)
        defer { counts.deallocate() }
        let file = try XCTUnwrap(funopen(counts + 1, nil, { cookie, _, length in
            cookie?.assumingMemoryBound(to: Int.self).pointee += Int(length)
            return length
        }, nil, nil))
        defer { fclose(file) }
        xmlSetStructuredErrorFunc(counts) { context, _ in context?.assumingMemoryBound(to: Int.self).pointee += 1 }
        xmlSetGenericErrorFunc(file, nil)
        defer { xmlSetStructuredErrorFunc(nil, nil); xmlSetGenericErrorFunc(nil, nil) }

        var book = Fixture.SpecBook()
        book.add(href: "repeated.xhtml", id: "repeated", mediaType: "application/xhtml+xml", Markup.repeatedIDXHTML)
        book.add(href: "encoded.xhtml", id: "encoded", mediaType: "application/xhtml+xml", Markup.undecodableXHTML())
        let publication = try EPUBPublication.open(data: book.archive())
        for index in publication.spine.indices { _ = try? publication.textSection(at: index) }
        fflush(file)
        XCTAssertEqual(counts[0], 0)
        XCTAssertEqual(counts[1], 0)

        // The host's own pull reader: a decoder's error goes to the structured handler, and the
        // push parser's line about it to the generic one.
        let data = Markup.undecodableXHTML()
        data.withUnsafeBytes { buffer in
            guard let reader = xmlReaderForMemory(buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buffer.count),
                                                  nil, nil, Int32(XML_PARSE_NONET.rawValue)) else { return }
            while xmlTextReaderRead(reader) == 1 {}
            xmlFreeTextReader(reader)
        }
        fflush(file)
        XCTAssertGreaterThan(counts[0], 0)
        XCTAssertGreaterThan(counts[1], 0)
    }

    func testOpeningWritesNothingToStandardError() throws {
        let package = String(decoding: try XCTUnwrap(Fixture.files()["OPS/book.opf"]), as: UTF8.self)
        var packages = [Data(package.replacingOccurrences(of: "<dc:title>", with: "<dc:title xml:id=\"a\">")
            .replacingOccurrences(of: "<dc:creator>", with: "<dc:creator xml:id=\"a\">").utf8)]
        for (encoding, bytes) in Markup.undecodableEncodings {
            let parts = package.components(separatedBy: "A Test Book")
            packages.append(Data("<?xml version=\"1.0\" encoding=\"\(encoding)\"?>\(parts[0])A Test ".utf8) + bytes + Data(parts[1].utf8))
        }
        for (index, data) in packages.enumerated() {
            var files = try Fixture.files()
            files["OPS/book.opf"] = data
            let archive = try Fixture.archive(files)
            let (_, output) = try StandardErrorCapture.capture { try? EPUBPublication.open(data: archive) }
            XCTAssertEqual(output, "", "package \(index)")
        }
    }
}
