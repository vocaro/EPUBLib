import CoreGraphics
import EPUBCore
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Publisher markup through the builder and the reader's actual native TextKit stack.
@MainActor final class BoxGeometryTests: XCTestCase {
    private let viewport = CGSize(width: 360, height: 600)
    private var prose: String { Array(repeating: "Ordinary prose wraps beside the figure and returns to the full column below.", count: 16).joined(separator: " ") }
    private let baseCSS = "body, p, figure, figcaption, aside { margin:0; padding:0; } p { text-indent:0; }"

    private func build(_ body: String, css: String, files: [String: Data] = [:], resetMargins: Bool = true) throws -> (EPUBPublication, SectionText) {
        let book = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body,
            css: (resetMargins ? baseCSS : "") + css), files: files)
        return (book, SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: 0,
            typography: .init(fontSize: 16), fonts: FontRegistry(publication: book), rich: NativeRichContent())))
    }

    private func view(_ section: SectionText, size: CGSize? = nil) -> ReaderTextView {
        nativeView(section.string, size: size ?? viewport)
    }

    private func nativeView(_ text: NSAttributedString, size: CGSize) -> ReaderTextView {
        let view = ReaderTextView(pageColumn: true)
        view.frame = CGRect(origin: .zero, size: size)
        view.readerContainer.size = CGSize(width: size.width, height: 0)
        view.readerContainer.viewportSize = size
        view.placement = ReaderTextPlacement(section: 0, offset: 0, visibleLength: text.length)
        view.setContent(text)
        view.ensureFullLayout()
        return view
    }

    private func range(_ phrase: String, in section: SectionText) throws -> NSRange {
        let range = (section.string.string as NSString).range(of: phrase)
        XCTAssertNotEqual(range.location, NSNotFound, phrase)
        return try XCTUnwrap(range.location == NSNotFound ? nil : range)
    }

    private func lines(in view: ReaderTextView, intersecting range: NSRange) -> [(range: NSRange, frame: CGRect)] {
        var result: [(NSRange, CGRect)] = []
        view.readerLayoutManager.enumerateTextLayoutFragments(from: view.contentStorage.documentRange.location,
                                                               options: [.ensuresLayout]) { fragment in
            let start = view.offset(of: fragment.rangeInElement.location)
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                let lineRange = NSRange(location: start + line.characterRange.location, length: line.characterRange.length)
                if NSIntersectionRange(range, lineRange).length > 0 {
                    result.append((lineRange, line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                                                             dy: fragment.layoutFragmentFrame.minY)))
                }
            }
            return true
        }
        return result
    }

    func testLeftAndRightFiguresWrapNativeProseUntilTheirBottom() throws {
        for side in ["left", "right"] {
            let (_, section) = try build("<figure id='box'><figcaption>Floating caption.</figcaption></figure><p id='prose'>\(prose)</p>",
                                         css: "figure { float:\(side); width:120px; height:120px; }")
            let native = view(section)
            XCTAssertTrue(native.readerContainer.hasNonlinearGeometry, side)
            let caption = try range("Floating caption.", in: section)
            let captionFrame = try XCTUnwrap(native.segmentFrames(for: caption).first)
            let body = try range(prose, in: section)
            let bodyLines = lines(in: native, intersecting: body)
            let beside = bodyLines.filter { $0.frame.minY < captionFrame.minY + 110 }
            let below = bodyLines.filter { $0.frame.minY >= captionFrame.minY + 120 }
            XCTAssertFalse(beside.isEmpty, "Prose must share the float's visual rows: \(side)")
            XCTAssertFalse(below.isEmpty, "Prose must continue below the float: \(side)")
            if side == "left" { XCTAssertTrue(beside.allSatisfy { $0.frame.minX >= 119 }, side) }
            else { XCTAssertTrue(beside.allSatisfy { $0.frame.maxX <= 241 }, side) }
            XCTAssertFalse(beside.contains { $0.frame.intersects(captionFrame) }, side)
            XCTAssertTrue(below.contains { $0.frame.width > 280 && $0.frame.minX < 1 }, "Full column resumes: \(side)")
            let region = try XCTUnwrap(native.readerContainer.boxRegions.first { NSIntersectionRange($0.range, caption).length > 0 })
            XCTAssertEqual(region.frame.minX, side == "left" ? 0 : 240, accuracy: 1, side)
            XCTAssertEqual(region.frame.width, 120, accuracy: 1, side)
            XCTAssertGreaterThanOrEqual(captionFrame.minX, region.frame.minX - 1, side)
            XCTAssertLessThanOrEqual(captionFrame.maxX, region.frame.maxX + 1, side)
        }
    }

    func testFloatHorizontalMarginsAndPaddingReserveSpaceAroundItsNativeColumn() throws {
        for side in ["left", "right"] {
            let (_, section) = try build("<figure>Caption words.</figure><p>\(prose)</p>",
                css: "figure { float:\(side); width:100px; height:100px; margin-left:12px; margin-right:16px; padding-left:8px; padding-right:10px; }")
            let native = view(section)
            let region = try XCTUnwrap(native.readerContainer.boxRegions.first { !$0.reserved })
            XCTAssertEqual(region.frame.width, 146, accuracy: 1)
            let caption = try XCTUnwrap(native.segmentFrames(for: try range("Caption words.", in: section)).first)
            XCTAssertGreaterThanOrEqual(caption.minX, region.frame.minX + 20 - 1)
            XCTAssertLessThanOrEqual(caption.maxX, region.frame.maxX - 26 + 1)
            let adjacent = lines(in: native, intersecting: try range(prose, in: section)).filter { $0.frame.minY < region.frame.maxY }
            XCTAssertFalse(adjacent.isEmpty)
            XCTAssertFalse(adjacent.contains { $0.frame.intersects(region.frame) })
        }
    }

    func testFractionalFloatColumnsReserveNativeLineBoundsInBothDirections() throws {
        for side in ["left", "right"] {
            let caption = "Left floating figure with a caption link."
            let (_, section) = try build("<p>Before the boxes.</p><figure><figcaption>Left floating figure with <a href='#after'>a caption link</a>.</figcaption></figure><p id='after'>\(prose)</p>",
                                         css: "figure { margin:0; float:\(side); width:35%; }", resetMargins: false)
            for width: CGFloat in [374.79, 374.2, 335.31] {
                let native = view(section, size: CGSize(width: width, height: 700))
                let captionRange = try range(caption, in: section)
                let paragraph = (section.string.string as NSString).paragraphRange(for: captionRange)
                let captionFrames = native.segmentFrames(for: paragraph)
                let text = section.string.string as NSString
                // Native standard selection rectangles include hanging trailing blanks. Check
                // actual prose characters against the float, retaining those blanks in source.
                let bodyFrames = lines(in: native, intersecting: try range(prose, in: section)).flatMap { line in
                    var length = line.range.length
                    while length > 0, text.substring(with: NSRange(location: line.range.location + length - 1, length: 1)).allSatisfy(\.isWhitespace) {
                        length -= 1
                    }
                    return native.segmentFrames(for: NSRange(location: line.range.location, length: length))
                }
                XCTAssertFalse(captionFrames.isEmpty)
                XCTAssertFalse(bodyFrames.isEmpty)
                for ink in captionFrames {
                    for adjacent in bodyFrames {
                        let overlap = ink.intersection(adjacent)
                        XCTAssertTrue(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5,
                                      "\(side), \(width): native caption \(ink) and surrounding prose \(adjacent) must not overlap")
                    }
                }
                let region = try XCTUnwrap(native.readerContainer.boxRegions.first { NSIntersectionRange($0.range, captionRange).length > 0 })
                for frame in captionFrames {
                    XCTAssertGreaterThanOrEqual(frame.minX, region.frame.minX - 0.01)
                    XCTAssertLessThanOrEqual(frame.maxX, region.frame.maxX + 0.01,
                                             "The full native caption line belongs inside its reserved exclusion")
                }
                XCTAssertEqual((region.contentFrame ?? region.frame).width, width * 0.35, accuracy: 0.01,
                               "The exclusion's glyph overhang must not widen the authored content column")
                native.selectedRange = captionRange
                XCTAssertEqual(native.plainText(in: native.selectedRange), caption)
                XCTAssertEqual(native.contentStorage.textStorage?.string, section.string.string)
            }
            BuilderHarness.assertMapRoundTrips(section)
        }
    }

    func testNearPageHeightFloatWithLeadingMarginFallsBackWithoutOverflow() throws {
        let (_, section) = try build("<figure>High caption.</figure><p>Short trailing prose.</p>",
            css: "figure { float:left; width:120px; height:590px; margin-top:32px; }")
        let paginator = ReaderPaginator(text: section.string, size: viewport)
        let pages = paginator.allPages
        XCTAssertFalse(pages.isEmpty)
        XCTAssertTrue(pages.allSatisfy { $0.height + $0.topSpacing <= viewport.height + 0.75 })
        XCTAssertEqual(pages.map { page in (paginator.text(for: page).string as NSString).substring(to: page.range.length) }.joined(), section.string.string)
    }

    func testFloatWrappingRetainsDefaultParagraphMarginsWithoutNativeOverlap() throws {
        let (_, section) = try build("<p>Opening paragraph before the figure.</p><figure><figcaption>Caption words.</figcaption></figure><p>\(prose)</p><p>Trailing paragraph.</p>",
            css: "figure { float:left; width:120px; height:120px; margin-left:0; margin-right:0; } p { text-indent:0; }", resetMargins: false)
        let native = view(section)
        let caption = try range("Caption words.", in: section)
        let captionFrames = native.segmentFrames(for: caption)
        let opening = native.segmentFrames(for: try range("Opening paragraph before the figure.", in: section))
        let body = lines(in: native, intersecting: try range(prose, in: section))
        let region = try XCTUnwrap(native.readerContainer.boxRegions.first { NSIntersectionRange($0.range, caption).length > 0 })
        XCTAssertFalse(captionFrames.isEmpty)
        XCTAssertFalse(body.isEmpty)
        XCTAssertTrue(body.contains { $0.frame.minY < region.frame.maxY && $0.frame.minX >= region.frame.maxX - 1 },
                      "Native paragraph margins must preserve adjacent float wrapping")
        XCTAssertTrue(body.contains { $0.frame.minY >= region.frame.maxY && $0.frame.width > 280 && $0.frame.minX < 1 })
        for ink in captionFrames {
            XCTAssertFalse(opening.contains { $0.intersects(ink) }, "The preceding paragraph must not overlap the figure")
            XCTAssertFalse(body.contains { $0.frame.intersects(ink) }, "Native paragraph spacing must agree with the exclusion plan")
        }
        let trailing = try XCTUnwrap(native.segmentFrames(for: try range("Trailing paragraph.", in: section)).first)
        XCTAssertGreaterThanOrEqual(trailing.minY, (body.map(\.frame.maxY).max() ?? 0) - 1)
    }

    func testClearUsesTheRequestedFloatSideInActualNativeLayout() throws {
        for (clear, minimumY): (String, CGFloat) in [("left", 96), ("right", 160), ("both", 160)] {
            let (_, section) = try build("<figure id='left'>Left.</figure><figure id='right'>Right.</figure><p id='clear'>Cleared paragraph with enough words to measure.</p>",
                css: "#left { float:left; width:120px; height:96px; } #right { float:right; width:120px; height:160px; } #clear { clear:\(clear); }")
            let native = view(section)
            let frame = try XCTUnwrap(native.segmentFrames(for: try range("Cleared paragraph", in: section)).first)
            XCTAssertGreaterThanOrEqual(frame.minY, minimumY - 1, clear)
            XCTAssertLessThan(frame.minY, minimumY + 30, "Clear must not add the floats' heights together: \(clear)")
        }
    }

    func testAbsoluteLeadingAndTrailingInsetsMoveDisplayedGlyphs() throws {
        for (offsets, x, y): (String, CGFloat, CGFloat) in [("left:24px; top:72px;", 24, 72),
                                                          ("right:24px; bottom:32px;", 208, 488)] {
            let (_, section) = try build("<aside id='box'>Positioned text.</aside><p>\(prose)</p>",
                css: "aside { position:absolute; width:128px; height:80px; \(offsets) }")
            let native = view(section)
            let glyph = try XCTUnwrap(native.segmentFrames(for: try range("Positioned text.", in: section)).first)
            XCTAssertEqual(glyph.minX, x, accuracy: 1)
            XCTAssertEqual(glyph.minY, y, accuracy: 2)
            XCTAssertLessThanOrEqual(glyph.maxX, x + 128 + 1)
            let proseLines = lines(in: native, intersecting: try range(prose, in: section))
            XCTAssertFalse(proseLines.contains { $0.frame.intersects(glyph) }, "Positioned text and prose must remain readable")
        }
    }

    func testSizedInlineBoxSharesItsPrefixRowWithoutOverwritingSurroundingText() throws {
        let (_, section) = try build("<p>Before <span id='box'>Inline box.</span> After words continue around the sized inline box and beneath it.</p>",
                                    css: "span { display:inline-block; width:120px; height:64px; }")
        let native = view(section)
        let before = try XCTUnwrap(native.segmentFrames(for: try range("Before", in: section)).first)
        let box = try XCTUnwrap(native.segmentFrames(for: try range("Inline box.", in: section)).first)
        let after = native.segmentFrames(for: try range("After words continue around the sized inline box and beneath it.", in: section))
        XCTAssertEqual(box.minY, before.minY, accuracy: 2, "An inline box with available space shares the prefix row")
        XCTAssertGreaterThan(box.minX, before.maxX)
        XCTAssertFalse(after.isEmpty)
        let boxRange = try range("Inline box.", in: section)
        let region = try XCTUnwrap(native.readerContainer.boxRegions.first { NSIntersectionRange($0.range, boxRange).length > 0 })
        XCTAssertEqual(region.frame.width, 120, accuracy: 1)
        XCTAssertGreaterThanOrEqual(region.frame.height, 64)
        for frame in after {
            XCTAssertFalse(frame.intersects(before), "Following prose must not overwrite its prefix")
            XCTAssertFalse(frame.intersects(region.frame), "Following prose must respect the inline box's full height")
        }
        XCTAssertEqual(native.visibleText, section.string.string)
    }

    func testFloatedImagesHaveDisplayedSizeAndProseExclusion() throws {
        for side in ["left", "right"] {
            let (_, section) = try build("<p><img id='image' src='picture.png' alt='Floating illustration'/></p><p>\(prose)</p>",
                css: "img { float:\(side); width:120px; height:96px; }", files: ["picture.png": RichFixture.image(width: 240, height: 192)])
            let native = view(section)
            let offset = try XCTUnwrap(section.anchors["image"])
            let image = try XCTUnwrap(native.segmentFrames(for: NSRange(location: offset, length: 1)).first)
            XCTAssertEqual(image.width, 120, accuracy: 1, side)
            XCTAssertEqual(image.height, 96, accuracy: 2, side)
            XCTAssertEqual(image.minX, side == "left" ? 0 : 240, accuracy: 1, side)
            let bodyLines = lines(in: native, intersecting: try range(prose, in: section))
            XCTAssertTrue(bodyLines.contains { $0.frame.minY < image.maxY }, side)
            XCTAssertFalse(bodyLines.contains { $0.frame.intersects(image) }, side)
            XCTAssertTrue(native.plainText(in: NSRange(location: 0, length: native.textLength)).contains("Floating illustration"))
        }
    }

    func testOversizedFloatRemainsOrdinarySelectableTextWithoutTruncation() throws {
        let long = Array(repeating: "Long floating box remains readable across many screens.", count: 80).joined(separator: " ")
        let (_, section) = try build("<aside id='box'>\(long)</aside><p id='end'>Final paragraph.</p>",
                                    css: "aside { float:left; width:120px; }")
        let native = view(section, size: CGSize(width: 360, height: 180))
        XCTAssertFalse(native.readerContainer.hasNonlinearGeometry, "An oversized text box must use a pageable fallback")
        XCTAssertEqual(native.contentStorage.textStorage?.string, section.string.string)
        let final = try range("Final paragraph.", in: section)
        let frame = try XCTUnwrap(native.segmentFrames(for: final).first)
        XCTAssertGreaterThan(frame.minY, 180)
        XCTAssertEqual(native.plainText(in: final), "Final paragraph.")
        let paginator = ReaderPaginator(text: section.string, size: CGSize(width: 360, height: 180))
        let pages = paginator.allPages
        XCTAssertGreaterThan(pages.count, 3)
        XCTAssertEqual(pages.first?.range.location, 0)
        XCTAssertEqual(pages.last?.range.upperBound, section.string.length)
        for (previous, next) in zip(pages, pages.dropFirst()) {
            XCTAssertEqual(previous.range.upperBound, next.range.location)
        }
        XCTAssertEqual(pages.map { (section.string.string as NSString).substring(with: $0.range) }.joined(), section.string.string)
        XCTAssertTrue(pages.allSatisfy { $0.height <= 181 }, "Oversized fallback must fit ordinary pages")
        BuilderHarness.assertMapRoundTrips(section)
    }

    func testPagedFloatTextHasTheSameGeometryAndCompleteSourceCoverage() throws {
        let (_, section) = try build("<figure>Page caption.</figure><p>\(prose)</p>",
                                    css: "figure { float:left; width:120px; height:96px; }")
        let size = CGSize(width: 360, height: 240)
        let paginator = ReaderPaginator(text: section.string, size: size)
        let pages = paginator.allPages
        XCTAssertTrue(paginator.sourceText === section.string, "Resolved geometry must not replace the cache's source identity")
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.first?.range.location, 0)
        XCTAssertEqual(pages.last?.range.upperBound, section.string.length)
        var copied = ""
        for page in pages {
            let text = paginator.text(for: page)
            let native = nativeView(text, size: size)
            native.placement.visibleLength = page.range.length
            copied += native.visibleText
            XCTAssertLessThanOrEqual(page.height, size.height + 1)
            if page.range.location == 0 {
                let caption = try range("Page caption.", in: section)
                let glyph = try XCTUnwrap(native.segmentFrames(for: caption).first)
                XCTAssertEqual(glyph.minX, 0, accuracy: 1)
                let bodyLines = lines(in: native, intersecting: NSRange(location: caption.upperBound + 1,
                    length: max(0, min(page.range.length, text.length) - caption.upperBound - 1)))
                XCTAssertTrue(bodyLines.contains { $0.frame.minY < glyph.minY + 96 && $0.frame.minX >= 119 })
                XCTAssertFalse(bodyLines.contains { $0.frame.intersects(glyph) })
            }
        }
        XCTAssertEqual(copied, section.string.string)
    }

    func testNativeFloatHitSelectionLinksSearchAndCFIsUseTheOriginalSourceOffsets() throws {
        let (book, section) = try build("<figure id='box'><a href='#end'>Caption link</a></figure><p id='end'>Adjacent prose link target. \(prose)</p>",
                                       css: "figure { float:left; width:120px; height:100px; }")
        let native = view(section)
        let spine = try SpineCFIs(publication: book)
        for phrase in ["Caption link", "Adjacent prose link target."] {
            let sourceRange = try range(phrase, in: section)
            let frame = try XCTUnwrap(native.segmentFrames(for: sourceRange).first)
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let selections = native.readerLayoutManager.textSelectionNavigation.textSelections(
                interactingAt: point, inContainerAt: native.contentStorage.documentRange.location,
                anchors: [], modifiers: [], selecting: false, bounds: CGRect(origin: .zero, size: viewport))
            let selected = try XCTUnwrap(selections.first?.textRanges.first)
            let hit = native.offset(of: selected.location)
            XCTAssertGreaterThanOrEqual(hit, sourceRange.location, phrase)
            XCTAssertLessThanOrEqual(hit, sourceRange.upperBound, phrase)
            let start = try XCTUnwrap(section.map.position(at: sourceRange.location, in: section.document))
            let end = try XCTUnwrap(section.map.endPosition(at: sourceRange.upperBound, in: section.document))
            let cfi = spine.cfi(spineIndex: 0, start: start, end: end, in: section.document)
            let local = try XCTUnwrap(spine.resolve(cfi))
            let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: local.localPath, in: section.document))
            XCTAssertEqual(section.map.location(of: resolved.start), sourceRange.location)
            XCTAssertEqual(section.map.location(of: resolved.end, isEnd: true), sourceRange.upperBound)
            let match = try XCTUnwrap(TextSearch.matches(of: phrase, in: section.document, locale: "en").first)
            XCTAssertEqual(section.map.location(of: match.start), sourceRange.location)
        }
        let linkFrame = try XCTUnwrap(native.segmentFrames(for: try range("Caption link", in: section)).first)
        let origin = native.containerOrigin
        let url = try XCTUnwrap(native.link(at: CGPoint(x: origin.x + linkFrame.midX, y: origin.y + linkFrame.midY)))
        XCTAssertEqual(ReaderLink(url: url), .internal(href: "OPS/one.xhtml#end"))
        BuilderHarness.assertMapRoundTrips(section)
    }
}
