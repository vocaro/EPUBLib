import CoreGraphics
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

/// Fixed-layout spine items that are one image or one drawing, shown as pages at their declared
/// size ([#5](https://github.com/vocaro/EPUBLib/issues/5)): which sections are pages, the size
/// each declares, the one page each paginates into, and where a spread puts its pages.
@MainActor final class FixedLayoutPageTests: XCTestCase {
    typealias Book = Fixture.SpecBook

    static func viewport(_ width: Int, _ height: Int) -> String { "\n<meta name=\"viewport\" content=\"width=\(width), height=\(height)\"/>" }

    /// A book of four fixed-layout pages, one of each shape: an XHTML page of one raster image,
    /// one of one inline SVG, an SVG document and a raster image in the spine.
    static func pages(spread: String? = nil, progression: String? = nil, sides: [String] = ["", "", "", ""]) -> Book {
        var book = Book()
        book.metadata += "\n    <meta property=\"rendition:layout\">pre-paginated</meta>"
        if let spread { book.metadata += "\n    <meta property=\"rendition:spread\">\(spread)</meta>" }
        if let progression { book.spineAttributes = "page-progression-direction=\"\(progression)\"" }
        book.resource("images/plate.png", id: "plate", mediaType: "image/png", Book.image(width: 600, height: 800))
        func itemref(_ index: Int) -> String { sides[index].isEmpty ? "" : "properties=\"\(sides[index])\"" }
        book.add("image", head: viewport(600, 800), itemref: itemref(0),
                 body: "\n<figure><img src=\"images/plate.png\" alt=\"The plate\"/></figure>\n")
        book.add("drawing", head: viewport(500, 700), item: "properties=\"svg\"", itemref: itemref(1), body: """
            <svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" viewBox="0 0 500 700"><title>The drawing</title>\
            <rect width="500" height="700" fill="#cde"/><text x="20" y="80" font-size="40">Drawing words</text></svg>
            """)
        book.add(href: "page.svg", id: "svg-page", mediaType: "image/svg+xml", Data("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 480"><title>The SVG page</title>\
            <rect width="640" height="480" fill="#edc"/><text x="20" y="80" font-size="40">SVG page words</text></svg>
            """.utf8), itemref: itemref(2))
        book.add(href: "images/wide.png", id: "wide", mediaType: "image/png", Book.image(width: 1000, height: 600), itemref: itemref(3))
        return book
    }

    // MARK: Which sections are pages

    /// Each of the four shapes is a page, of the size it declares: the viewport `meta`, the SVG
    /// document's viewBox, the raster image's pixels. Its text is the image's one character, and
    /// nothing is disclosed for the fixed layout.
    func testEachShapeOfPageIsShownAsAPageOfItsDeclaredSize() throws {
        let build = try SpecConformanceBuild(Self.pages())
        XCTAssertEqual(build.sections.map { $0.fixedPage?.size }, [CGSize(width: 600, height: 800), CGSize(width: 500, height: 700),
                                                                  CGSize(width: 640, height: 480), CGSize(width: 1000, height: 600)])
        for section in build.sections {
            XCTAssertEqual(section.specText, "\u{FFFC}", "section \(section.spineIndex)")
            XCTAssertEqual(section.specImages.count, 1, "section \(section.spineIndex)")
            XCTAssertFalse(section.report.fixedLayoutReflowed, "section \(section.spineIndex)")
            XCTAssertTrue(section.issuesCFIs, "section \(section.spineIndex)")
        }
        XCTAssertEqual(build.specAlternatives, ["The plate", "The drawing", "The SVG page", ""])
        XCTAssertFalse(build.report.fixedLayoutReflowed)
        XCTAssertFalse(build.report.cfiUnavailable, "a raster page has its spine item's CFI")
        XCTAssertNil(build.disclosure)
        XCTAssertTrue(build[3].issuesSpineCFIOnly)
        XCTAssertFalse(build[0].issuesSpineCFIOnly)
    }

    /// Anything but one image or drawing reflows, with the fixed-layout disclosure: text beside
    /// an image, two images, a page of positioned text, an empty page and a hidden image. A
    /// reflowable section of one image flows as it did.
    func testAPageOfAnythingElseReflowsAndIsDisclosed() throws {
        var book = Book()
        book.metadata += "\n    <meta property=\"rendition:layout\">pre-paginated</meta>"
        book.resource("plate.png", id: "plate", mediaType: "image/png", Book.image(width: 600, height: 800))
        let head = Self.viewport(600, 800)
        book.add("captioned", head: head, body: "<figure><img src=\"plate.png\" alt=\"Plate\"/><figcaption>A caption</figcaption></figure>")
        book.add("pair", head: head, body: "<img src=\"plate.png\" alt=\"One\"/><img src=\"plate.png\" alt=\"Two\"/>")
        book.add("positioned", head: head, body: "<p style=\"position: absolute; top: 100px; left: 50px\">A fixed page.</p>")
        book.add("empty", head: head, body: "")
        book.add("hidden", head: head, body: "<img src=\"plate.png\" alt=\"Hidden\" style=\"visibility: hidden\"/>")
        book.add("flowing", itemref: "properties=\"rendition:layout-reflowable\"", body: "<img src=\"plate.png\" alt=\"Flowing\"/>")
        let build = try SpecConformanceBuild(book)
        XCTAssertEqual(build.sections.map { $0.fixedPage == nil }, [true, true, true, true, true, true])
        XCTAssertEqual(build.sections.map(\.report.fixedLayoutReflowed), [true, true, true, true, true, false])
        XCTAssertEqual(build[0].specText, "\u{FFFC}\nA caption")
        XCTAssertTrue(build.disclosure?.contains("This book's fixed page layout is shown as reflowable text.") == true)
    }

    /// A book whose fixed-layout pages are all pages discloses nothing for them; one with a page
    /// of text as well reflows that page and discloses it (#5's acceptance).
    func testTheDisclosureStaysForABookWithAPageThatReflows() throws {
        var book = Self.pages()
        XCTAssertNil(try SpecConformanceBuild(book).disclosure)
        book.add("text", head: Self.viewport(600, 800), body: "<p>A page of text.</p>")
        let build = try SpecConformanceBuild(book)
        XCTAssertEqual(build.sections.map { $0.fixedPage != nil }, [true, true, true, true, false])
        XCTAssertEqual(build.disclosure, "This book's fixed page layout is shown as reflowable text.")
    }

    // MARK: Declared sizes

    /// The viewport `meta` as the W3C's `lay-fxl-xhtml-icb_*` tests have a reading system read
    /// it: the first width and height, units ignored, invalid properties skipped, and
    /// `device-width` and `device-height` declaring nothing.
    func testTheViewportIsReadAsTheW3CTestsReadIt() {
        func size(_ content: String) -> [CGFloat?] {
            let viewport = FixedLayoutPage.viewport(content: content)
            return [viewport.width, viewport.height]
        }
        XCTAssertEqual(size("width=900, height=600"), [900, 600])
        XCTAssertEqual(size("width=1000px, height=600mm"), [1000, 600], "lay-fxl-xhtml-icb_units")
        XCTAssertEqual(size("width=900, height=600, something, foo"), [900, 600], "lay-fxl-xhtml-icb_invalid_meta")
        XCTAssertEqual(size("width=900, height=600, width=1000, height=1000"), [900, 600], "lay-fxl-xhtml-icb_repeated-in-meta")
        XCTAssertEqual(size("width=device-width, height=device-height"), [nil, nil], "lay-fxl-xhtml-icb_device_sizes")
        XCTAssertEqual(size("width = 1200 height=1600"), [1200, 1600], "white space separates too")
        XCTAssertEqual(size("height=1600;width=1200.5"), [1200.5, 1600])
        XCTAssertEqual(size("WIDTH=300, initial-scale=1.0"), [300, nil])
        XCTAssertEqual(size("width=0, height=-5"), [nil, nil], "no positive number")
        XCTAssertEqual(size(""), [nil, nil])
    }

    /// Only the first viewport `meta` counts (`lay-fxl-xhtml-icb_multi_declarations`); a page
    /// without one takes its image's size, and a page that declares one dimension takes the
    /// other from the image's aspect.
    func testAPageTakesWhatItDoesNotDeclareFromItsImage() throws {
        var book = Book()
        book.metadata += "\n    <meta property=\"rendition:layout\">pre-paginated</meta>"
        book.resource("plate.png", id: "plate", mediaType: "image/png", Book.image(width: 300, height: 400))
        let image = "<img src=\"plate.png\" alt=\"Plate\"/>"
        book.add("twice", head: Self.viewport(1000, 600) + Self.viewport(500, 300), body: image)
        book.add("none", body: image)
        book.add("width", head: "<meta name=\"viewport\" content=\"width=600\"/>", body: image)
        book.add("device", head: "<meta name=\"viewport\" content=\"width=device-width, height=device-height\"/>", body: image)
        let build = try SpecConformanceBuild(book)
        XCTAssertEqual(build.sections.map { $0.fixedPage?.size }, [CGSize(width: 1000, height: 600), CGSize(width: 300, height: 400),
                                                                  CGSize(width: 600, height: 800), CGSize(width: 300, height: 400)])
    }

    // MARK: The page

    /// A page paginates into one page at any column size, the image as large as fits the column
    /// with its aspect kept. In a column of its own fitted size the image fills it exactly.
    func testAPageIsOnePageThatItsImageFills() throws {
        let build = try SpecConformanceBuild(Self.pages())
        for section in build.sections {
            let declared = try XCTUnwrap(section.fixedPage?.size)
            for column in [CGSize(width: 362, height: 660), CGSize(width: 720, height: 400), CGSize(width: 1000, height: 1300)] {
                let (_, pages) = section.specPages(column)
                XCTAssertEqual(pages.count, 1, "section \(section.spineIndex) at \(column)")
                XCTAssertEqual(pages.first?.range, NSRange(location: 0, length: 1))
                XCTAssertFalse(pages.first?.usesFlowFallback ?? true)
                let image = try XCTUnwrap(section.specImages.first)
                let drawn = image.specSize(lineWidth: column.width, viewport: column)
                let scale = min(column.width / declared.width, column.height / declared.height)
                XCTAssertEqual(drawn.width, declared.width * scale, accuracy: 1, "section \(section.spineIndex) at \(column)")
                XCTAssertEqual(drawn.height, declared.height * scale, accuracy: 1, "section \(section.spineIndex) at \(column)")
            }
            let fitted = ReaderCanvasGeometry.fit(declared, in: CGRect(x: 0, y: 0, width: 700, height: 500), edge: nil)
            let (_, pages) = section.specPages(fitted.size)
            XCTAssertEqual(pages.count, 1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(pages.first).height, fitted.height + 0.5)
            XCTAssertEqual(try XCTUnwrap(section.specImages.first).specSize(lineWidth: fitted.width, viewport: fitted.size).width,
                           fitted.width, accuracy: 1)
        }
    }

    // MARK: Spreads

    private func pairing(_ pages: [ReaderFixedPage?], linear: [Bool]? = nil, pairs: Bool = true,
                         rightToLeft: Bool = false) -> ReaderFixedSpread.Pairing {
        ReaderFixedSpread.Pairing(count: pages.count, page: { pages[$0] }, isLinear: { linear?[$0] ?? true },
                                  pairs: { _ in pairs }, isRightToLeft: rightToLeft)
    }

    private func spreads(_ pairing: ReaderFixedSpread.Pairing) -> [[Int?]] {
        var result: [[Int?]] = []
        var seen = Set<Int>()
        for section in 0..<pairing.count where !seen.contains(section) {
            guard let spread = pairing.spread(containing: section) else { result.append([]); continue }
            seen.formUnion(spread.sections)
            result.append(spread.isAlone ? [section] : [spread.first, spread.second])
        }
        return result
    }

    private func page(_ side: EPUBPageSpread? = nil, _ spread: EPUBSpread = .auto) -> ReaderFixedPage {
        ReaderFixedPage(size: CGSize(width: 600, height: 800), side: side, spread: spread)
    }

    /// Pages pair from the first of their run, as foliate-js paired them: a page put on the first
    /// slot's side begins a spread, one put on the second's ends one, a center page stands alone
    /// and a section that flows ends the run (`lay-fxl-page-spread-*`, `fxl-page-spread-center`).
    func testPagesPairIntoSpreadsAsTheirSidesSay() {
        XCTAssertEqual(spreads(pairing([page(), page(), page(), page(), page()])), [[0, 1], [2, 3], [4, nil]])
        XCTAssertEqual(spreads(pairing([page(), page(.left), page(.right), page()])), [[0, nil], [1, 2], [3, nil]],
                       "lay-fxl-page-spread-combined")
        XCTAssertEqual(spreads(pairing([page(.right), page(), page(), page()])), [[nil, 0], [1, 2], [3, nil]],
                       "lay-fxl-page-spread-right")
        XCTAssertEqual(spreads(pairing([page(), page(.left), page(), page()])), [[0, nil], [1, 2], [3, nil]],
                       "lay-fxl-page-spread-left")
        XCTAssertEqual(spreads(pairing([page(.center), page(), page(), page()])), [[0], [1, 2], [3, nil]],
                       "fxl-page-spread-center")
        XCTAssertEqual(spreads(pairing([page(), page(.center), page()])), [[0, nil], [1], [2, nil]])
        XCTAssertEqual(spreads(pairing([page(), nil, page(), page()])), [[0, nil], [], [2, 3]], "a section that flows ends a run")
        XCTAssertEqual(spreads(pairing([page(), page(), page()], linear: [true, false, true])), [[0, 2], [1]],
                       "a nonlinear page is passed over, and shown alone")
        XCTAssertEqual(spreads(pairing([page(), page(), page()], pairs: false)), [[0], [1], [2]], "no spreads at this size")
    }

    /// Right to left, the first slot is the right-hand one: a page put on the right begins a
    /// spread and one put on the left ends one.
    func testRightToLeftPagesPairFromTheRight() {
        XCTAssertEqual(spreads(pairing([page(.right), page(.left), page(.left), page()], rightToLeft: true)),
                       [[0, 1], [nil, 2], [3, nil]])
        XCTAssertEqual(spreads(pairing([page(), page(.right), page()], rightToLeft: true)), [[0, nil], [1, 2]])
    }

    /// Whether pages share a spread at a size: `none` never, `both` always, `landscape` and
    /// `auto` in a landscape page or across a division (`lay-fxl-spread-*`).
    func testTheSpreadSettingSaysWhenPagesShareASpread() {
        let landscape = CGRect(x: 0, y: 0, width: 1194, height: 834), portrait = CGRect(x: 0, y: 0, width: 834, height: 1194)
        let duo = CGRect(x: 0, y: 0, width: 1114, height: 705), hinge = CGRect(x: 540, y: 0, width: 34, height: 705)
        for (setting, expected) in [(EPUBSpread.none, [false, false, false]), (.both, [true, true, true]),
                                    (.landscape, [true, false, true]), (.auto, [true, false, true])] {
            XCTAssertEqual([ReaderCanvasGeometry.showsFixedSpreads(setting, in: landscape, division: nil),
                            ReaderCanvasGeometry.showsFixedSpreads(setting, in: portrait, division: nil),
                            ReaderCanvasGeometry.showsFixedSpreads(setting, in: duo, division: hinge)], expected, "\(setting)")
        }
        let narrow = CGRect(x: 150, y: 0, width: 34, height: 705)
        XCTAssertFalse(ReaderCanvasGeometry.showsFixedSpreads(.both, in: duo, division: narrow), "a side too narrow for a page")
    }

    /// A spread's pages meet at the middle, each as large as fits its half; across a division
    /// each fills its side up to the division; a page alone is centered on the whole area, or on
    /// a division's wider side. Right to left, the first page is on the right.
    func testASpreadsPagesMeetAtItsMiddleOrAtTheDivision() {
        let page = CGRect(x: 0, y: 0, width: 1194, height: 834)
        let area = ReaderCanvasGeometry.fixedArea(in: page)
        let sizes = [0: CGSize(width: 600, height: 800), 1: CGSize(width: 600, height: 800), 2: CGSize(width: 1000, height: 600)]
        let pair = ReaderCanvasGeometry.fixedPageFrames(of: ReaderFixedSpread(first: 0, second: 1), sizes: sizes, in: page,
                                                        division: nil, isRightToLeft: false)
        XCTAssertEqual(pair.map(\.section), [0, 1])
        let (left, right) = (pair[0].frame, pair[1].frame)
        XCTAssertEqual(left.maxX, right.minX, "the pages meet")
        XCTAssertEqual(left.maxX, area.midX.rounded())
        XCTAssertEqual(left.height, area.height.rounded(.down), accuracy: 1, "a portrait page in a landscape half is as tall as the area")
        XCTAssertEqual(left.width / left.height, 600.0 / 800, accuracy: 0.01)
        XCTAssertEqual(left.midY, area.midY, accuracy: 1)
        let mirrored = ReaderCanvasGeometry.fixedPageFrames(of: ReaderFixedSpread(first: 0, second: 1), sizes: sizes, in: page,
                                                            division: nil, isRightToLeft: true)
        XCTAssertEqual(mirrored.map(\.frame), [right, left], "right to left, the first page is on the right")
        let lone = ReaderCanvasGeometry.fixedPageFrames(of: ReaderFixedSpread(first: nil, second: 1), sizes: sizes, in: page,
                                                        division: nil, isRightToLeft: false)
        XCTAssertEqual(lone.map(\.frame), [right], "a page with an empty slot beside it stays in its half")
        let alone = ReaderCanvasGeometry.fixedPageFrames(of: ReaderFixedSpread(first: 2, isAlone: true), sizes: sizes, in: page,
                                                         division: nil, isRightToLeft: false)
        XCTAssertEqual(alone[0].frame.midX, area.midX, accuracy: 1)
        XCTAssertEqual(alone[0].frame.width, area.width.rounded(.down), accuracy: 1, "a landscape page alone fills the area's width")
        XCTAssertTrue(pair.allSatisfy { $0.frame == $0.frame.integral }, "frames are on whole points")

        let duo = CGRect(x: 0, y: 0, width: 1114, height: 705), hinge = CGRect(x: 540, y: 0, width: 34, height: 705)
        let book = ReaderCanvasGeometry.fixedPageFrames(of: ReaderFixedSpread(first: 0, second: 1), sizes: sizes, in: duo,
                                                        division: hinge, isRightToLeft: false)
        XCTAssertEqual(book[0].frame.maxX, hinge.minX, accuracy: 1, "the left page meets the hinge")
        XCTAssertEqual(book[1].frame.minX, hinge.maxX, accuracy: 1, "the right page meets the hinge")
        XCTAssertTrue(book.allSatisfy { $0.frame.maxX <= hinge.minX || $0.frame.minX >= hinge.maxX })
        let side = ReaderCanvasGeometry.fixedPageFrames(of: ReaderFixedSpread(first: 2, isAlone: true), sizes: sizes, in: duo,
                                                        division: hinge, isRightToLeft: false)
        XCTAssertTrue(side[0].frame.maxX <= hinge.minX || side[0].frame.minX >= hinge.maxX, "a page alone keeps to one side of the hinge")
    }
}

extension SpecConformanceBuild {
    /// Each section's one image's words.
    var specAlternatives: [String] { sections.map { $0.specImages.first?.alt ?? "-" } }
}
