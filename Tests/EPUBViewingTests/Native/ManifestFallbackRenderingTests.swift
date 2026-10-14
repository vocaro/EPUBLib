import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

@MainActor final class ManifestFallbackRenderingTests: XCTestCase {
    private typealias Book = Fixture.SpecBook
    private typealias Build = SpecConformanceBuild

    func testForeignTextBytesAreWithheldByTypeAndLeaveOtherSectionsReadable() throws {
        for (type, bytes) in [("application/json", "{\"chapter\":\"not a page\"}"),
                              ("application/pdf", "%PDF-1.4 1 0 obj"), ("application/x-foreign+xml", "<html><body>not a page</body></html>")] {
            var book = Book(); book.add("before", body: "<p>Before</p>")
            book.add(href: "foreign.bin", id: "foreign", mediaType: type, Data(bytes.utf8))
            book.add("after", body: "<p>After</p>")
            let built = try Build(book)
            XCTAssertEqual(built.sections.map(\.specText), ["Before", "This section could not be shown.", "After"], type)
            XCTAssertEqual(built.sections.map(\.report.withheld), [false, true, false], type)
        }
    }

    func testMultiHopFallbackSkipsUnavailableForeignAndRemoteHopsWithoutChangingOccurrence() throws {
        var book = Book()
        book.add(href: "source.json", id: "source", mediaType: "application/json", Data("{}".utf8),
                 item: "fallback='missing'", itemref: "linear='no' properties='rendition:layout-pre-paginated'")
        book.manifest += "<item id='missing' href='missing.bin' media-type='application/x-missing' fallback='remote'/>"
            + "<item id='remote' href='https://example.invalid/page' media-type='application/xhtml+xml' fallback='static'/>"
        book.resource("text/page.xhtml", id: "static", mediaType: "application/xhtml+xml",
                      Data(Book.xhtml(head: "<style>p { color: rgb(255, 0, 0); }</style>", body: "<p id='p'>Readable fallback</p><p><img src='image.png' alt='I'/></p>").utf8))
        book.resource("text/image.png", id: "image", mediaType: "image/png", Book.image(width: 20, height: 30))
        let built = try Build(book), section = built[0]
        XCTAssertEqual(section.specText, "Readable fallback\n\u{FFFC}")
        XCTAssertEqual(section.href, "EPUB/source.json")
        XCTAssertEqual(section.document.path, "EPUB/text/page.xhtml")
        XCTAssertEqual(section.specImages.map(\.path), ["EPUB/text/image.png"])
        XCTAssertFalse(built.publication.spine[0].isLinear)
        XCTAssertEqual(built.publication.spine[0].layout, .prePaginated)
        XCTAssertTrue(section.report.fixedLayoutReflowed)
        XCTAssertFalse(section.report.withheld)
        XCTAssertTrue(section.document.canResolveCFIs)
        XCTAssertEqual(NativeFallbacks.spineIndex(for: "EPUB/text/page.xhtml", in: built.publication), 0)
        try built.assertPositionsRoundTrip()
    }

    func testCyclesAndDanglingFallbacksWithholdInsteadOfDisplayingRawBytes() throws {
        for tail in ["source", "absent"] {
            var book = Book()
            book.add(href: "source.json", id: "source", mediaType: "application/json", Data("{}".utf8), item: "fallback='middle'")
            book.resource("middle.bin", id: "middle", mediaType: "application/x-foreign", Data("raw".utf8), item: "fallback='\(tail)'")
            let built = try Build(book)
            XCTAssertTrue(built[0].report.withheld)
            XCTAssertEqual(built[0].specText, "This section could not be shown.")
        }
    }

    func testScriptedFallbacksAreFollowedThroughMoreThanOneInteractiveDocument() throws {
        var book = Book()
        book.add("app", item: "properties='scripted' fallback='app2'", body: "<p>Unrun app</p><script>x</script>")
        book.resource("app2.xhtml", id: "app2", mediaType: "application/xhtml+xml",
                      Data(Book.xhtml(body: "<p>Another unrun app</p>").utf8), item: "properties='scripted' fallback='static'")
        book.resource("static.xhtml", id: "static", mediaType: "application/xhtml+xml", Data(Book.xhtml(body: "<p>Static equivalent</p>").utf8))
        let built = try Build(book)
        XCTAssertEqual(built[0].specText, "Static equivalent")
        XCTAssertEqual(built[0].report.scriptsRefused, 0)
        XCTAssertTrue(built[0].document.canResolveCFIs)
        var noFallback = Book()
        noFallback.add("app", item: "properties='scripted'", body: "<p>Static text</p><noscript>Alternative</noscript><script>x</script>")
        XCTAssertEqual(try Build(noFallback)[0].report.scriptsRefused, 1)
    }

    func testImageFallbacksSkipMissingForeignAndCorruptImagesAndKeepAuthoredAlt() throws {
        var book = Book(); book.add("page", body: "<p><img src='chart.xcf' alt='Authored label'/></p>")
        book.resource("chart.xcf", id: "chart", mediaType: "image/x-xcf", Data("foreign".utf8), item: "fallback='missing'")
        book.manifest += "<item id='missing' href='missing.png' media-type='image/png' fallback='corrupt'/>"
        book.resource("corrupt.png", id: "corrupt", mediaType: "image/png", Data("not PNG".utf8), item: "fallback='good'")
        book.resource("good.png", id: "good", mediaType: "image/png", Book.image(width: 40, height: 60))
        let built = try Build(book)
        XCTAssertEqual(built[0].specImages.map(\.path), ["EPUB/good.png"])
        XCTAssertEqual(built[0].specImages.map(\.sizing.intrinsic), [CGSize(width: 40, height: 60)])
        XCTAssertEqual(built[0].report.unreadableResources, 0)
        XCTAssertNil(built.disclosure)
        var bad = book; bad.files.removeValue(forKey: "good.png")
        let withheld = try Build(bad)
        XCTAssertEqual(withheld[0].specText, "Authored label")
        XCTAssertEqual(withheld[0].report.unreadableResources, 1)
    }

    func testArbitrarySVGImageEmbeddingUsesRasterAndNestedSVGFallbacks() throws {
        for vector in [false, true] {
            var book = Book()
            book.add("page", body: "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'><rect width='40' height='40' fill='white'/><image href='foreign.xcf' width='20' height='20'/></svg>")
            book.resource("foreign.xcf", id: "foreign", mediaType: "image/x-xcf", Data("foreign".utf8), item: "fallback='image'")
            if vector {
                book.resource("image.svg", id: "image", mediaType: "image/svg+xml",
                              Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'><image href='nested.png' width='20' height='20'/></svg>".utf8))
                book.resource("nested.png", id: "nested", mediaType: "image/png", Book.image(width: 20, height: 20))
            } else { book.resource("image.png", id: "image", mediaType: "image/png", Book.image(width: 20, height: 20)) }
            let built = try Build(book)
            let svg = try XCTUnwrap(built[0].document.nodes.first { $0.name == "svg" })
            let report = SectionReportBox()
            let serialized = try XCTUnwrap(SVGContent.serialize(svg, resolve: { "EPUB/" + $0 }, publication: built.publication, report: report))
            XCTAssertTrue(String(decoding: serialized, as: UTF8.self).contains("data:image/png;base64,"))
            XCTAssertEqual(report.report.unsupportedElements["svg:image"] ?? 0, 0)
            XCTAssertEqual(built[0].specText, "\u{FFFC}")
        }
    }

    func testNestedSVGImageReferenceCyclesRemainBounded() throws {
        var book = Book()
        book.add("page", body: "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'><image href='cycle.svg' width='20' height='20'/></svg>")
        book.resource("cycle.svg", id: "cycle", mediaType: "image/svg+xml",
                      Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'><image href='cycle.svg' width='20' height='20'/></svg>".utf8))
        let built = try Build(book)
        XCTAssertGreaterThan(built[0].report.unsupportedElements["svg:image"] ?? 0, 0)
        XCTAssertFalse(built[0].report.withheld)
    }

    func testRasterAndSVGSpineResourcesBecomeImagesRatherThanMarkupBytes() throws {
        var book = Book()
        book.add(href: "plate.png", id: "plate", mediaType: "image/png", Book.image(width: 60, height: 30))
        book.add(href: "drawing.svg", id: "drawing", mediaType: "image/svg+xml",
                 Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='40'><rect width='20' height='40'/></svg>".utf8))
        let built = try Build(book)
        XCTAssertEqual(built.sections.map(\.specText), ["\u{FFFC}", "\u{FFFC}"])
        XCTAssertEqual(built.sections.flatMap(\.specImages).map(\.path), ["EPUB/plate.png", ""])
        XCTAssertFalse(built.report.withheld)
        XCTAssertTrue(built.report.cfiUnavailable)
        XCTAssertFalse(built[0].document.canResolveCFIs)
        XCTAssertTrue(built[1].document.canResolveCFIs)
        XCTAssertEqual(built[1].document.path, "EPUB/drawing.svg")
        XCTAssertEqual(built[1].document.root.namespace, ContentNamespace.svg)
    }

    func testColdSearchUsesTheSameFallbackDocumentAndNeverIndexesForeignBytes() async throws {
        var book = Book()
        book.add(href: "data.json", id: "data", mediaType: "application/json", Data("foreign needle".utf8), item: "fallback='static'")
        book.resource("static.xhtml", id: "static", mediaType: "application/xhtml+xml", Data(Book.xhtml(body: "<p>fallback needle</p>").utf8))
        let publication = try EPUBPublication.open(data: book.archive())
        let native = NativeBook(publication: publication, typography: NativeTypography(), rich: NativeRichContent())
        defer { native.close() }
        let loaded = await native.document(0)
        let cold = try XCTUnwrap(loaded)
        XCTAssertEqual(cold.path, "EPUB/static.xhtml")
        XCTAssertEqual(TextSearch.matches(of: "foreign", in: cold, locale: nil).count, 0)
        XCTAssertEqual(TextSearch.matches(of: "needle", in: cold, locale: nil).count, 1)
        let hot = await native.build(0)
        XCTAssertEqual(cold.body?.textContent, hot.document.body?.textContent)
        XCTAssertEqual(cold.cfiResource, hot.document.cfiResource)
    }
}
