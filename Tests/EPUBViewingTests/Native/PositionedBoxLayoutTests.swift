import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class PositionedBoxLayoutTests: XCTestCase {
    private func build(_ body: String, css: String) throws -> SectionText {
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body,
            css: "body,p,div,aside { margin:0; padding:0; }" + css))
        return SectionBuilder.build(.init(publication: publication, spineIndex: 0, typography: .init(fontSize: 16),
            fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
    }
    private func view(_ section: SectionText, size: CGSize = CGSize(width: 400, height: 600)) -> ReaderTextView {
        let view = ReaderTextView(pageColumn: true)
        view.frame = CGRect(origin: .zero, size: size)
        view.readerContainer.size = CGSize(width: size.width, height: 0)
        view.readerContainer.viewportSize = size
        view.placement.visibleLength = section.string.length
        view.setContent(section.string); view.ensureFullLayout()
        return view
    }
    private func range(_ text: String, in section: SectionText) -> NSRange { (section.string.string as NSString).range(of: text) }

    func testLaterDOMCalloutUsesContainingOriginAndEarlierTextWrapsAroundIt() throws {
        let prefix = Array(repeating: "Earlier ordinary text around an archive callout.", count: 9).joined(separator: " ")
        let section = try build("<div><p>\(prefix)</p><aside>Later source callout.</aside><p>Following prose remains readable.</p></div>",
            css: "div { position:relative; width:280px; height:300px; margin-left:20px; } aside { position:absolute; top:24px; left:16px; width:100px; height:80px; }")
        let native = view(section)
        let callout = try XCTUnwrap(native.segmentFrames(for: range("Later source callout.", in: section)).first)
        XCTAssertEqual(callout.minX, 36, accuracy: 1)
        XCTAssertEqual(callout.minY, 24, accuracy: 1)
        let prefixInk = native.segmentFrames(for: range(prefix, in: section))
        XCTAssertTrue(prefixInk.contains { $0.minY < callout.minY })
        XCTAssertFalse(prefixInk.contains { $0.intersects(callout) }, "Earlier DOM text wraps around the authored earlier visual position")
        BuilderHarness.assertMapRoundTrips(section)
        let paginator = ReaderPaginator(text: section.string, size: CGSize(width: 400, height: 600))
        XCTAssertTrue(paginator.allPages.allSatisfy { $0.height <= 600.5 })
        XCTAssertEqual(paginator.allPages.map { (paginator.text(for: $0).string as NSString).substring(with: NSRange(location: 0, length: $0.range.length)) }.joined(), section.string.string)
    }

    func testRelativeContainerAndTrailingInsetsUseItsWidthAndHeight() throws {
        let section = try build("<div><p>Container text.</p><aside>Trailing inset.</aside><p>More text.</p></div>",
            css: "div { position:relative; left:24px; top:40px; width:280px; height:260px; } aside { position:absolute; right:16px; bottom:24px; width:100px; height:60px; }")
        let native = view(section)
        let parent = try XCTUnwrap(native.segmentFrames(for: range("Container text.", in: section)).first)
        let callout = try XCTUnwrap(native.segmentFrames(for: range("Trailing inset.", in: section)).first)
        XCTAssertEqual(parent.minX, 24, accuracy: 1)
        XCTAssertEqual(parent.minY, 40, accuracy: 1)
        XCTAssertEqual(callout.minX, 188, accuracy: 1)
        XCTAssertEqual(callout.minY, 216, accuracy: 1)
        XCTAssertFalse(parent.intersects(callout))
    }

    func testUpwardPositionedMultiParagraphBoxKeepsEveryGlyphAtItsPlannedPosition() throws {
        let prefix = Array(repeating: "Earlier readable paragraph before the authored callout.", count: 8).joined(separator: " ")
        let section = try build("<p>\(prefix)</p><aside><p>First callout paragraph.</p><p>Second callout paragraph.</p><p>Third callout paragraph.</p></aside><p>Following text.</p>",
            css: "aside { position:absolute; left:220px; top:24px; width:160px; }")
        let native = view(section)
        let plan = try XCTUnwrap(native.readerContainer.boxPage?.geometry)
        for phrase in ["First callout paragraph.", "Second callout paragraph.", "Third callout paragraph."] {
            let source = range(phrase, in: section)
            let glyph = try XCTUnwrap(native.segmentFrames(for: source).first)
            let expected = try XCTUnwrap(plan.paragraph(at: source.location)?.lines.first)
            XCTAssertEqual(glyph.minY, expected.frame.minY, accuracy: 1, phrase)
        }
        let callouts = native.segmentFrames(for: range("First callout paragraph.", in: section))
            + native.segmentFrames(for: range("Second callout paragraph.", in: section))
            + native.segmentFrames(for: range("Third callout paragraph.", in: section))
        let body = native.segmentFrames(for: range(prefix, in: section))
        XCTAssertFalse(body.contains { line in callouts.contains { line.intersects($0) } })
        let following = try XCTUnwrap(native.segmentFrames(for: range("Following text.", in: section)).first)
        XCTAssertGreaterThanOrEqual(following.minY + 0.5, body.map(\.maxY).max() ?? 0)
    }

    func testFixedInsetsUseTheSectionViewportInsideARelativeAncestor() throws {
        let section = try build("<div><p>Relative container.</p><aside>Viewport callout.</aside><p>Following text.</p></div>",
            css: "div { position:relative; left:24px; top:40px; width:280px; height:260px; } aside { position:fixed; right:16px; top:24px; width:100px; height:60px; }")
        let native = view(section)
        let glyph = try XCTUnwrap(native.segmentFrames(for: range("Viewport callout.", in: section)).first)
        XCTAssertEqual(glyph.minX, 284, accuracy: 1)
        XCTAssertEqual(glyph.minY, 24, accuracy: 1)
    }

    func testFixedCalloutUsesItsOwnSectionOriginInCombinedScrollText() throws {
        let first = try build("<p>First section text.</p>", css: "")
        let second = try build("<div><p>Second section text.</p><aside>Second section callout.</aside><p>Following text.</p></div>",
            css: "div { position:relative; top:40px; } aside { position:fixed; left:180px; top:24px; width:140px; height:60px; }")
        let combined = NSMutableAttributedString(attributedString: first.string)
        combined.append(second.string)
        let native = ReaderTextView(pageColumn: false)
        native.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        native.readerContainer.size = CGSize(width: 400, height: 0)
        native.readerContainer.viewportSize = CGSize(width: 400, height: 600)
        native.placement.visibleLength = combined.length
        native.setContent(combined); native.ensureFullLayout()
        let firstHeight = view(first).readerLayoutManager.usageBoundsForTextContainer.height
        let source = (combined.string as NSString).range(of: "Second section callout.")
        let glyph = try XCTUnwrap(native.segmentFrames(for: source).first)
        XCTAssertEqual(glyph.minY, firstHeight + 24, accuracy: 1)
        let region = try XCTUnwrap(native.readerContainer.boxRegions.first { NSIntersectionRange($0.range, source).length > 0 })
        XCTAssertEqual(region.frame.minY, firstHeight + 24, accuracy: 1)
        XCTAssertEqual(native.visibleText, combined.string)
    }

    func testFirstAbsoluteChildEstablishesItsRelativeContainingOrigin() throws {
        let section = try build("<p>Leading paragraph.</p><div><aside>First positioned child.</aside></div><p>Following text.</p>",
            css: "div { position:relative; left:24px; top:40px; width:280px; height:260px; } aside { position:absolute; left:16px; top:24px; width:140px; height:60px; }")
        let native = view(section)
        let glyph = try XCTUnwrap(native.segmentFrames(for: range("First positioned child.", in: section)).first)
        XCTAssertEqual(glyph.minX, 40, accuracy: 1)
        let leading = try XCTUnwrap(native.segmentFrames(for: range("Leading paragraph.", in: section)).first)
        XCTAssertEqual(glyph.minY, leading.maxY + 64, accuracy: 1)
    }

    func testUnsizedDropCapShrinksToItsNativeContentWidth() throws {
        let section = try build("<p><span>W</span>ords continue beside this large drop cap rather than starting below it. More text wraps and continues past the initial.</p>",
            css: "span { float:left; font-size:64px; } p { text-indent:0; }")
        let native = view(section)
        let cap = try XCTUnwrap(native.segmentFrames(for: range("W", in: section)).first)
        let body = try XCTUnwrap(native.segmentFrames(for: range("ords continue", in: section)).first)
        XCTAssertLessThan(cap.width, 100)
        XCTAssertGreaterThanOrEqual(body.minX, cap.maxX - 1)
        XCTAssertLessThan(body.minY, cap.maxY)
        XCTAssertFalse(body.intersects(cap))
    }
}
