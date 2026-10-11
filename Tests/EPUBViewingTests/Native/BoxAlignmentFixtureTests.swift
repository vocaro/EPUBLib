import EPUBCore
import EPUBReading
import EPUBTestSupport
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The alignment fixtures (`Fixture.Alignment`): expected native geometry of the layouts books
/// use, what stays in block flow and is disclosed, and that none of it changes a section's text.
@MainActor final class BoxAlignmentFixtureTests: XCTestCase {
    private typealias H = AlignmentHarness
    private typealias F = Fixture.Alignment

    /// One column's text area on a phone, a tablet in portrait and each column of a desktop spread.
    private let columns = [CGSize(width: 362, height: 660), CGSize(width: 720, height: 980), CGSize(width: 480, height: 720)]

    // MARK: Expected geometry

    func testStandardEbooksEpigraphIsCentredOnItsPageAndInTheVisibleArea() throws {
        for fontSize: CGFloat in [16, 25] {
            let section = try H.build(F.epigraphBody, css: F.epigraphCSS, fontSize: fontSize)
            XCTAssertFalse(section.report.flexGridSimplified, "the epigraph is inside the supported subset")
            XCTAssertNil(NativeDisclosure.text(for: section.report))
            for size in columns {
                let label = "\(Int(size.width))x\(Int(size.height)) at \(Int(fontSize)) pt"
                // The box is `calc(98vh - 3em)` tall with its 3em top padding inside it, so its
                // content's middle is 49vh below its top edge: the middle of the page.
                let expected = 0.49 * size.height
                // Paginated: from the top of the page's text area.
                let verse = H.paged("A quiet line stands alone.", in: section, size: size)
                let source = H.paged("An Imagined Author", in: section, size: size)
                XCTAssertEqual(verse.page, 0, label); XCTAssertEqual(source.page, 0, label)
                H.assertEqual((verse.frame.minY + source.frame.maxY) / 2, expected, label)
                H.assertEqual(verse.frame.midX, size.width / 2, "the quotation is as wide as its text, centred: \(label)")
                H.assertEqual(source.frame.maxX, verse.frame.maxX, "the attribution ends where the quotation does: \(label)")
                H.assertEqual(source.frame.minY - verse.frame.maxY, fontSize, "cite's 1em margin: \(label)")
                XCTAssertEqual(ReaderPaginator(text: section.string, size: size).allPages.count, 1, label)
                // Continuous scroll: from the box's top edge, one visible area tall.
                let view = H.scrolled(section, size: size)
                let scrolledVerse = H.frame("A quiet line stands alone.", in: section, view: view)
                let scrolledSource = H.frame("An Imagined Author", in: section, view: view)
                H.assertEqual((scrolledVerse.minY + scrolledSource.maxY) / 2, expected, label)
                H.assertEqual(scrolledVerse.midX, size.width / 2, label)
            }
        }
    }

    func testCentredTitlePageAndGridDedication() throws {
        let title = try H.build(F.titleBody, css: F.titleCSS)
        let dedication = try H.build(F.dedicationBody, css: F.dedicationCSS)
        XCTAssertFalse(title.report.flexGridSimplified); XCTAssertFalse(dedication.report.flexGridSimplified)
        for size in columns {
            let heading = H.paged("An Aligned Book", in: title, size: size), byline = H.paged("Test Author", in: title, size: size)
            H.assertEqual((heading.frame.minY + byline.frame.maxY) / 2, size.height / 2)
            H.assertEqual(heading.frame.midX, size.width / 2); H.assertEqual(byline.frame.midX, size.width / 2)
            let to = H.paged("For the patient reader.", in: dedication, size: size)
            H.assertEqual(to.frame.midY, 0.45 * size.height, "the middle of a 90vh cell")
            H.assertEqual(to.frame.midX, size.width / 2)
        }
    }

    // MARK: Fallback and disclosure

    func testUnsupportedLayoutsStayInBlockFlowInReadingOrderAndAreDisclosed() throws {
        let reset = "body { margin: 0 } p, div { margin: 0; padding: 0; text-indent: 0 } "
        let body = "<div class='c'><p>First in source.</p><p>Second in source.</p><p>Third in source.</p></div><p>After the layout.</p>"
        let phrases = ["First in source.", "Second in source.", "Third in source.", "After the layout."]
        let size = CGSize(width: 400, height: 600)
        let plain = try H.build(body, css: reset)
        XCTAssertFalse(plain.report.flexGridSimplified)
        let flow = phrases.map { H.frame($0, in: plain, view: H.scrolled(plain, size: size)) }
        let unsupported = [
            "side-by-side row": ".c { display: flex; justify-content: space-between; align-items: center; height: 300px }",
            "wrapping row": ".c { display: flex; flex-wrap: wrap; justify-content: center }",
            "reversed row": ".c { display: flex; flex-direction: row-reverse }",
            "reversed column": ".c { display: flex; flex-direction: column-reverse; justify-content: center; height: 300px }",
            "two-column grid": ".c { display: grid; grid-template-columns: 1fr 1fr; place-items: center; height: 300px }",
            "repeated tracks": ".c { display: grid; grid-template-columns: repeat(3, 1fr) }",
            "named areas": ".c { display: grid; grid-template-areas: 'a b' }",
            "column auto-flow": ".c { display: grid; grid-auto-flow: column; align-content: center; height: 300px }",
            "placed grid items": ".c { display: grid; align-content: center; height: 300px } .c p:first-child { grid-row: 3 }",
            "inline flex": ".c { display: inline-flex; justify-content: center }",
        ]
        for (name, css) in unsupported {
            let section = try H.build(body, css: reset + css)
            XCTAssertTrue(section.report.flexGridSimplified, name)
            XCTAssertEqual(section.string.string, plain.string.string, name)
            var tagged = false
            section.string.enumerateAttribute(.readerAlignment, in: NSRange(location: 0, length: section.string.length)) { value, _, _ in
                if value != nil { tagged = true }
            }
            XCTAssertFalse(tagged, "\(name): nothing is aligned")
            let view = H.scrolled(section, size: size)
            for (phrase, expected) in zip(phrases, flow) {
                let frame = H.frame(phrase, in: section, view: view)
                XCTAssertEqual(frame.minX, expected.minX, accuracy: 0.01, "\(name): \(phrase)")
                XCTAssertEqual(frame.minY, expected.minY, accuracy: 0.01, "\(name): \(phrase)")
            }
        }
        let text = try XCTUnwrap(NativeDisclosure.text(for: try H.build(body, css: reset + unsupported["two-column grid"]!).report))
        XCTAssertTrue(text.contains("flexible box or grid layouts"), text)
        // Reordered items are aligned, in reading order, and still disclosed.
        let reordered = try H.build(body, css: reset + ".c { display: flex; flex-direction: column; align-items: center } .c p:first-child { order: 2 }")
        XCTAssertTrue(reordered.report.flexGridSimplified)
        let view = H.scrolled(reordered, size: size)
        let frames = phrases.map { H.frame($0, in: reordered, view: view) }
        XCTAssertLessThan(frames[0].minY, frames[1].minY); XCTAssertLessThan(frames[1].minY, frames[2].minY)
        H.assertEqual(frames[0].midX, 200)
        // A wrapping column of definite height may break into more columns; it stays one.
        XCTAssertTrue(try H.build(body, css: reset + ".c { display: flex; flex-flow: column wrap; height: 300px }").report.flexGridSimplified)
        XCTAssertFalse(try H.build(body, css: reset + ".c { display: flex; flex-flow: column wrap }").report.flexGridSimplified)
        // Four containers deep are aligned; a fifth is laid out as a block.
        func nested(_ depth: Int) throws -> SectionText {
            try H.build(String(repeating: "<div class='n'>", count: depth) + "<p>Deep inside.</p>" + String(repeating: "</div>", count: depth),
                        css: reset + ".n { display: flex; flex-direction: column; align-items: center }")
        }
        XCTAssertFalse(try nested(4).report.flexGridSimplified)
        H.assertEqual(H.frame("Deep inside.", in: try nested(4), view: H.scrolled(try nested(4), size: size)).midX, 200)
        XCTAssertTrue(try nested(5).report.flexGridSimplified)
    }

    func testFixtureLayoutsOutsideTheSubsetReadInSourceOrder() throws {
        let section = try H.build(F.unsupportedBody, css: F.unsupportedCSS)
        XCTAssertTrue(section.report.flexGridSimplified)
        let view = H.scrolled(section, size: CGSize(width: 400, height: 600))
        let frames = ["Left item.", "Right item.", "Term.", "Its meaning.", "After both."].map { H.frame($0, in: section, view: view) }
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.minY, earlier.maxY - 0.01, "one block after another")
            XCTAssertEqual(later.minX, 0, accuracy: 0.01)
        }
    }

    func testContainersHoldingFloatsOrPositionedBoxesAreNotAligned() throws {
        let section = try H.build("<div class='c'><p><span>D</span>rop cap paragraph.</p><p>Second paragraph.</p></div>",
            css: "body { margin: 0 } p, div { margin: 0; text-indent: 0 } "
                + ".c { display: flex; flex-direction: column; justify-content: center; align-items: center; height: 300px } span { float: left }")
        XCTAssertTrue(section.report.flowBoxesReflowed)
        XCTAssertTrue(section.report.flexGridSimplified, "the alignment it would have had is disclosed")
        XCTAssertNil(section.string.attribute(.readerAlignment, at: 0, effectiveRange: nil))
        let view = H.scrolled(section, size: CGSize(width: 400, height: 600))
        XCTAssertEqual(H.frame("Second paragraph.", in: section, view: view).minX, 0, accuracy: 0.5)
        XCTAssertLessThan(H.frame("Second paragraph.", in: section, view: view).minY, 100)
    }

    // MARK: Text, map and CFIs

    /// The same markup with and without its alignment rules: the characters, the map back to
    /// the DOM, the anchors and every CFI must be identical, and resolving the layout at any
    /// size must change paragraph formatting only.
    func testAlignmentNeverChangesTextMapAnchorsOrCFIs() throws {
        let long = String(repeating: "A sentence of ordinary prose that fills its lines. ", count: 8)
        let cases: [(name: String, body: String, aligned: String, plain: String)] = [
            ("epigraph", F.epigraphBody, F.epigraphCSS, F.epigraphPlainCSS),
            ("title", F.titleBody, F.titleCSS, "html, body { margin: 0 } h1, p { margin: 0; text-indent: 0 } p { margin-top: 1em }"),
            ("dedication", F.dedicationBody, F.dedicationCSS, "body { margin: 0 } p { margin: 0; text-indent: 0 }"),
            ("unsupported", F.unsupportedBody, F.unsupportedCSS, "body { margin: 0 } p { margin: 0; text-indent: 0 }"),
            ("mixed", """
                <h1 id="h">Heading <em>with</em> emphasis</h1><div class="box"><p id="a">Bare text <a href="#h">linked</a>.</p>\
                text directly in the box<ul><li id="li">A list item</li></ul><div class="inner"><p id="b">\(long)</p>\
                <p>Line one<br/>line two</p></div></div><p id="after">After &amp; beyond.</p>
                """, """
                .box { display: flex; flex-direction: column; justify-content: space-around; align-items: center; min-height: 100vh; gap: 1em }
                .inner { display: grid; place-items: center; flex: 1 } #a { align-self: flex-end; margin-top: auto }
                """, "body { }"),
        ]
        for item in cases {
            let aligned = try H.build(item.body, css: item.aligned), plain = try H.build(item.body, css: item.plain)
            XCTAssertEqual(aligned.string.string, plain.string.string, item.name)
            XCTAssertEqual(aligned.map, plain.map, item.name)
            XCTAssertEqual(aligned.anchors, plain.anchors, item.name)
            BuilderHarness.assertMapRoundTrips(aligned)
            // Every rendered offset names the same DOM position and CFI, and resolves back.
            for location in 0...aligned.string.length {
                let position = try XCTUnwrap(aligned.map.position(at: location, in: aligned.document), item.name)
                let reference = try XCTUnwrap(plain.map.position(at: location, in: plain.document), item.name)
                let cfi = EPUBCFI.localPath(from: position, to: position, in: aligned.document)
                XCTAssertEqual(cfi, EPUBCFI.localPath(from: reference, to: reference, in: plain.document), "\(item.name) at \(location)")
                let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: cfi, in: aligned.document), "\(item.name): \(cfi)")
                XCTAssertEqual(aligned.map.location(of: resolved.start), aligned.map.location(of: position), "\(item.name): \(cfi)")
            }
            let end = aligned.string.length
            let range = EPUBCFI.localPath(from: try XCTUnwrap(aligned.map.position(at: 0, in: aligned.document)),
                                          to: try XCTUnwrap(aligned.map.endPosition(at: end, in: aligned.document)), in: aligned.document)
            XCTAssertEqual(range, EPUBCFI.localPath(from: try XCTUnwrap(plain.map.position(at: 0, in: plain.document)),
                                                    to: try XCTUnwrap(plain.map.endPosition(at: end, in: plain.document)), in: plain.document), item.name)
            for size in columns + [CGSize(width: 400, height: 600)] {
                let resolved = ReaderBoxLayout.resolve(aligned.string, viewport: size).text
                XCTAssertEqual(resolved.string, aligned.string.string, item.name)
                XCTAssertTrue(withoutParagraphFormatting(resolved).isEqual(to: withoutParagraphFormatting(aligned.string)),
                              "\(item.name): only paragraph formatting differs")
                let paginator = ReaderPaginator(text: aligned.string, size: size)
                XCTAssertEqual(paginator.allPages.map { page in
                    (paginator.text(for: page).string as NSString).substring(with: NSRange(location: 0, length: page.range.length))
                }.joined(), aligned.string.string, "\(item.name): the pages cover the text once, in order")
                XCTAssertTrue(paginator.allPages.allSatisfy { $0.height + $0.topSpacing <= size.height + 0.75 }, item.name)
            }
        }
    }

    private func withoutParagraphFormatting(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: copy.length)
        copy.removeAttribute(.paragraphStyle, range: range)
        copy.removeAttribute(.readerAlignmentLead, range: range)
        return copy
    }

    /// The fixture book end to end: every section builds, only the unsupported layouts are disclosed.
    func testFixtureBookBuildsWithOneDisclosure() throws {
        let publication = try EPUBPublication.open(data: Fixture.alignment())
        XCTAssertEqual(publication.spine.count, 5)
        var report = SectionReport()
        for index in publication.spine.indices {
            let section = SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: index,
                typography: NativeTypography(fontSize: 16), fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
            XCTAssertEqual(section.report.flexGridSimplified, section.href.hasSuffix("layouts.xhtml"), section.href)
            XCTAssertFalse(section.report.withheld)
            BuilderHarness.assertMapRoundTrips(section)
            report.formUnion(section.report)
        }
        XCTAssertEqual(NativeDisclosure.text(for: report),
                       "Some flexible box or grid layouts are shown as blocks in reading order: items meant to sit side by side, wrap or be reordered follow one another.")
    }
}
