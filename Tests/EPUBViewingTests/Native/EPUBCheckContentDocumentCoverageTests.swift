import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// Content document constructs EPUBCheck's scenarios check (`epub3/07-content-documents`,
/// `03-resources`, `06-layouts`, `B-external-identifiers`), built by the native pipeline with
/// its real rich-content factory: what EPUBCheck calls valid is shown, and what the documents
/// name as refused is refused without taking the rest of the book with it.
@MainActor final class EPUBCheckContentDocumentCoverageTests: XCTestCase {
    private static let container = """
        <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles>\
        <rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """

    /// A book whose spine is `spine` (manifest ids), with `manifest` items beside a navigation document.
    private func book(manifest: String, spine: [String], files: [String: Data]) throws -> EPUBPublication {
        var all = files
        all["mimetype"] = Data("application/epub+zip".utf8)
        all["META-INF/container.xml"] = Data(Self.container.utf8)
        all["EPUB/package.opf"] = Data("""
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\
            <dc:title>Content Documents</dc:title><dc:language>en</dc:language><dc:identifier id="uid">epubcheck-content</dc:identifier></metadata>\
            <manifest>\(manifest)<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>\
            <spine>\(spine.map { "<itemref idref=\"\($0)\"/>" }.joined())</spine></package>
            """.utf8)
        if all["EPUB/nav.xhtml"] == nil {
            all["EPUB/nav.xhtml"] = Data(page("<nav epub:type=\"toc\"><ol><li><a href=\"nav.xhtml\">Contents</a></li></ol></nav>").utf8)
        }
        return try EPUBPublication.open(data: Fixture.archive(all))
    }

    private func page(_ body: String, head: String = "", prolog: String = "<!DOCTYPE html>") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        \(prolog)
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">\
        <head><title>Page</title>\(head)</head><body>\(body)</body></html>
        """
    }

    /// A one-document book around `document`.
    private func book(_ document: String, files: [String: Data] = [:], manifest: String = "") throws -> EPUBPublication {
        var files = files
        files["EPUB/page.xhtml"] = Data(document.utf8)
        return try book(manifest: "<item id=\"page\" href=\"page.xhtml\" media-type=\"application/xhtml+xml\"/>" + manifest, spine: ["page"], files: files)
    }

    private func build(_ publication: EPUBPublication, _ index: Int = 0) -> SectionText {
        SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: index, typography: NativeTypography(),
                                                 fonts: FontRegistry(publication: publication), rich: NativeEngine().rich))
    }

    private func attachments(_ section: SectionText) -> Int {
        var count = 0
        section.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: section.string.length)) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }

    /// The section's characters without attachments and generated breaks, words single-spaced.
    private func words(_ section: SectionText) -> String {
        section.string.string.replacingOccurrences(of: "\u{FFFC}", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0 == "\u{2028}" || $0 == "\u{2029}" }).joined(separator: " ")
    }

    // MARK: Documents EPUBCheck calls valid

    func testADoctypeWithTheLegacyCompatStringIsReadAsXHTML() throws {
        let section = build(try book(page("<p>Call me a reader.</p>", prolog: "<!DOCTYPE html SYSTEM \"about:legacy-compat\">")))
        XCTAssertEqual(words(section), "Call me a reader.")
        XCTAssertFalse(section.report.withheld)
        XCTAssertFalse(section.report.recoveredAsHTML)
        XCTAssertFalse(section.report.cfiUnavailable)
    }

    func testAnXHTML11DoctypeWithNamedEntitiesIsReadAsXHTML() throws {
        // What EPUB 2 content documents look like.
        let prolog = "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\"\n  \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">"
        let section = build(try book(page("<p>Caf&eacute;&nbsp;&mdash; d&eacute;j&agrave; vu &amp; more.</p>", prolog: prolog)))
        XCTAssertEqual(section.string.string.trimmingCharacters(in: .whitespacesAndNewlines), "Café\u{A0}— déjà vu & more.")
        XCTAssertFalse(section.report.withheld)
        XCTAssertFalse(section.report.recoveredAsHTML)
        XCTAssertFalse(section.report.cfiUnavailable)
    }

    func testAUTF16ContentDocumentShowsItsText() throws {
        // EPUB 3.3, 3.3: XML-based resources "MUST be encoded in UTF-8 or UTF-16".
        let text = page("<h1>Überschrift</h1><p>Zwölf Boxkämpfer — 日本語 — jagen Viktor.</p>")
            .replacingOccurrences(of: "encoding=\"UTF-8\"", with: "encoding=\"UTF-16\"")
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            let mark = encoding == .utf16LittleEndian ? Data([0xFF, 0xFE]) : Data([0xFE, 0xFF])
            let publication = try book(manifest: "<item id=\"page\" href=\"page.xhtml\" media-type=\"application/xhtml+xml\"/>", spine: ["page"],
                                       files: ["EPUB/page.xhtml": mark + (try XCTUnwrap(text.data(using: encoding)))])
            let section = build(publication)
            XCTAssertEqual(words(section), "Überschrift Zwölf Boxkämpfer — 日本語 — jagen Viktor.", "\(encoding)")
            XCTAssertFalse(section.report.withheld, "\(encoding)")
            XCTAssertFalse(section.report.recoveredAsHTML, "\(encoding)")
            XCTAssertEqual(section.title, "Page", "\(encoding)")
        }
    }

    func testAContentDocumentInADeclaredLegacyEncodingShowsItsText() throws {
        // RSC-028 for EPUBCheck, and what older Windows toolchains wrote. The XML declaration
        // names the encoding, so nothing is guessed.
        for (name, encoding) in [("ISO-8859-1", String.Encoding.isoLatin1), ("windows-1252", .windowsCP1252)] {
            let text = page("<p>Café Zürich, Æsop &amp; Ñandú.</p>").replacingOccurrences(of: "encoding=\"UTF-8\"", with: "encoding=\"\(name)\"")
            let publication = try book(manifest: "<item id=\"page\" href=\"page.xhtml\" media-type=\"application/xhtml+xml\"/>", spine: ["page"],
                                       files: ["EPUB/page.xhtml": try XCTUnwrap(text.data(using: encoding))])
            let section = build(publication)
            XCTAssertEqual(words(section), "Café Zürich, Æsop & Ñandú.", name)
            XCTAssertFalse(section.report.withheld, name)
        }
    }

    func testElementsAndAttributesFromOtherNamespacesAreReadPast() throws {
        let section = build(try book(page("""
            <p xmlns:its="http://www.w3.org/2005/11/its" xmlns:my="http://example.org/ns" its:term="yes" my:flag="1" data-anything="2" \
            epub:type="bridgehead" role="doc-subtitle" vocab="http://schema.org/" typeof="Book" property="name">Shown <my:mark>and this</my:mark> \
            <span itemscope="" itemtype="http://schema.org/Thing" itemprop="about">too</span>.</p>
            """)))
        XCTAssertEqual(words(section), "Shown and this too.")
        XCTAssertFalse(section.report.withheld)
        XCTAssertFalse(section.report.recoveredAsHTML)
    }

    func testHiddenListsOfANavigationDocumentInTheSpineAreNotShown() throws {
        let nav = page("""
            <nav epub:type="toc"><h1>Contents</h1><ol><li><a href="page.xhtml">Shown</a><ol hidden=""><li><a href="page.xhtml#deep">Kept back</a></li></ol></li></ol></nav>\
            <nav epub:type="page-list" hidden="hidden"><ol><li><a href="page.xhtml#p1">Page one</a></li></ol></nav>
            """)
        let publication = try book(manifest: "<item id=\"page\" href=\"page.xhtml\" media-type=\"application/xhtml+xml\"/>", spine: ["nav", "page"],
                                   files: ["EPUB/nav.xhtml": Data(nav.utf8), "EPUB/page.xhtml": Data(page("<p id=\"deep\">Text.</p>").utf8)])
        let section = build(publication)
        XCTAssertTrue(words(section).contains("Contents"))
        XCTAssertTrue(words(section).contains("Shown"))
        XCTAssertFalse(words(section).contains("Kept back"))
        XCTAssertFalse(words(section).contains("Page one"))
        XCTAssertEqual(publication.tableOfContents.first?.children.map(\.title), ["Kept back"], "and they are still navigation")
        XCTAssertEqual(publication.pageList?.map(\.label), ["Page one"])
    }

    func testAnInlineSVGThatOnlyDefinesSymbolsShowsNoFailureNotice() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/136")
        // A sprite sheet: definitions other drawings use. A browser draws nothing for it.
        let section = build(try book(page("""
            <p>Before.</p>\
            <svg xmlns="http://www.w3.org/2000/svg" version="1.1"><defs><linearGradient id="fade"><stop offset="0" stop-color="#fff"/>\
            <stop offset="1" stop-color="#000"/></linearGradient></defs><symbol id="dot" viewBox="0 0 10 10"><circle cx="5" cy="5" r="4"/></symbol></svg>\
            <p>After.</p>
            """)))
        XCTAssertEqual(words(section), "Before. After.")
        XCTAssertFalse(section.report.withheld)
    }

    func testAnSVGSpineItemIsDrawn() throws {
        // EPUB Reading Systems 3.3, 6.2: "Reading systems MUST process SVG content documents."
        let svg = """
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100" width="200" height="100"><title>A plate</title>\
            <rect x="10" y="10" width="180" height="80" fill="#369"/><text x="100" y="55" text-anchor="middle">Plate one</text></svg>
            """
        let publication = try book(manifest: "<item id=\"plate\" href=\"plate.svg\" media-type=\"image/svg+xml\"/>", spine: ["plate"],
                                   files: ["EPUB/plate.svg": Data(svg.utf8)])
        let section = build(publication)
        XCTAssertFalse(section.report.withheld)
        XCTAssertEqual(attachments(section), 1, "the drawing, as one attachment: \(section.string.string.debugDescription)")
    }

    // MARK: Fallbacks

    func testASpineItemInAnUnsupportedTypeShowsItsXHTMLFallback() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/78")
        // EPUB Reading Systems 3.3, 5.4: "A reading system that does not support the MIME media
        // type of a given publication resource MUST traverse the manifest fallback chain until it
        // identifies a supported publication resource to use in place of the unsupported resource."
        let manifest = """
            <item id="slides" href="slides.pdf" media-type="application/pdf" fallback="slides-image"/>\
            <item id="slides-image" href="slides.bin" media-type="application/x-epubcheck-demo" fallback="slides-text"/>\
            <item id="slides-text" href="slides.xhtml" media-type="application/xhtml+xml"/>
            """
        let publication = try book(manifest: manifest, spine: ["slides"], files: [
            "EPUB/slides.pdf": Data("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8),
            "EPUB/slides.bin": Data([0, 1, 2, 3, 0xFF, 0xFE]),
            "EPUB/slides.xhtml": Data(page("<h1>Slides</h1><p>The fallback text of the slides.</p>").utf8),
        ])
        let section = build(publication)
        XCTAssertFalse(section.report.withheld, "the fallback is a supported content document")
        XCTAssertTrue(words(section).contains("The fallback text of the slides."), section.string.string.debugDescription)
    }

    func testASpineItemInAnUnsupportedTypeWithoutAFallbackIsWithheldAlone() throws {
        // OPF-043 for EPUBCheck. The section says it cannot be shown; the next one is unaffected.
        let manifest = "<item id=\"data\" href=\"data.bin\" media-type=\"application/octet-stream\"/><item id=\"page\" href=\"page.xhtml\" media-type=\"application/xhtml+xml\"/>"
        let publication = try book(manifest: manifest, spine: ["data", "page"], files: [
            "EPUB/data.bin": Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 37) }), "EPUB/page.xhtml": Data(page("<p>Still here.</p>").utf8),
        ])
        XCTAssertTrue(build(publication, 0).report.withheld)
        XCTAssertEqual(words(build(publication, 1)), "Still here.")
    }

    // MARK: Documented refusals

    func testADocumentDeclaringEntitiesInAnInternalSubsetIsWithheldAsDocumented() throws {
        // Valid for EPUBCheck, and refused as doc/architecture.md says: "XML expansion and
        // external entity resolution are refused."
        let prolog = "<!DOCTYPE html [\n  <!ENTITY publisher \"A Press\">\n]>"
        let publication = try book(manifest: """
            <item id="declared" href="declared.xhtml" media-type="application/xhtml+xml"/><item id="page" href="page.xhtml" media-type="application/xhtml+xml"/>
            """, spine: ["declared", "page"], files: [
                "EPUB/declared.xhtml": Data(page("<p>Published by &publisher;.</p>", prolog: prolog).utf8),
                "EPUB/page.xhtml": Data(page("<p>Still here.</p>").utf8),
            ])
        let section = build(publication)
        XCTAssertTrue(section.report.withheld)
        XCTAssertFalse(section.string.string.contains("A Press"))
        XCTAssertEqual(words(build(publication, 1)), "Still here.")
    }

    func testAnImageGivenAsADataURLFallsBackToItsAlternativeText() throws {
        // Valid EPUB 3 (3.7 Data URLs). The reader resolves references inside the archive only:
        // the image is counted as unreadable and its alternative text stands in.
        let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let section = build(try book(page("<p>Before <img src=\"data:image/png;base64,\(pixel)\" alt=\"a red dot\"/> after.</p>")))
        XCTAssertFalse(section.report.withheld)
        XCTAssertEqual(words(section), "Before a red dot after.")
        XCTAssertEqual(section.report.unreadableResources, 1)
        XCTAssertEqual(section.report.remoteResourcesRefused, 0)
    }
}
