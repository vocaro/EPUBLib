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

/// Real publisher CSS through the section builder and both native layout paths.
@MainActor final class FlowBoxTests: XCTestCase {
    private func build(fontSize: CGFloat = 16) throws -> (EPUBPublication, SectionText) {
        let xhtml = StyleTestSupport.xhtml(body: """
            <p id="before">Before the boxes.</p>
            <figure id="left"><figcaption>Left floating figure with <a href="#after">a caption link</a>.</figcaption></figure>
            <p>Adjacent prose follows the left figure without overlapping it.</p>
            <figure id="right"><figcaption>Right floating figure caption.</figcaption></figure>
            <p>Adjacent prose after the right figure.</p>
            <aside id="callout">Positioned callout with <a href="two.xhtml">a callout link</a>.</aside>
            <p>Before inline <span id="inline">Sized inline block content wraps at its requested width.</span> after inline.</p>
            <aside id="fixed">Fixed callout stays in reading order.</aside>
            <p id="after">After the boxes.</p>
            """, css: """
            figure { margin: 0; width: 35%; }
            #left { float: left; }
            #right { float: right; }
            #callout { position: absolute; left: 24px; top: 80px; width: 160px; }
            #inline { display: inline-block; width: 150px; height: 30px; }
            #fixed { position: fixed; width: 50%; }
            """)
        let publication = try StyleTestSupport.publication(section: xhtml)
        let section = SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0,
            typography: NativeTypography(fontSize: fontSize), fonts: FontRegistry(publication: publication),
            rich: NativeRichContent()))
        return (publication, section)
    }

    func testTextAnchorsLinksSearchAndCFIsSurviveFlowBoxFallback() throws {
        let (publication, section) = try build()
        XCTAssertTrue(section.report.flowBoxesReflowed)
        XCTAssertTrue(try XCTUnwrap(NativeDisclosure.text(for: section.report)).contains("reading order"))
        BuilderHarness.assertMapRoundTrips(section)
        let spine = try SpineCFIs(publication: publication)
        for (id, phrase) in [("left", "Left floating figure"), ("right", "Right floating figure"),
                             ("callout", "Positioned callout"), ("inline", "Sized inline block"),
                             ("fixed", "Fixed callout"), ("after", "After the boxes.")] {
            let range = (section.string.string as NSString).range(of: phrase)
            XCTAssertNotEqual(range.location, NSNotFound, id)
            XCTAssertEqual(section.anchors[id], range.location, id)
            let start = try XCTUnwrap(section.map.position(at: range.location, in: section.document))
            let end = try XCTUnwrap(section.map.endPosition(at: NSMaxRange(range), in: section.document))
            let cfi = spine.cfi(spineIndex: 0, start: start, end: end, in: section.document)
            let local = try XCTUnwrap(spine.resolve(cfi))
            let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: local.localPath, in: section.document))
            XCTAssertEqual(section.map.location(of: resolved.start), range.location)
            XCTAssertEqual(section.map.location(of: resolved.end, isEnd: true), NSMaxRange(range))
            XCTAssertEqual(section.mappedText(in: range.location..<NSMaxRange(range)), phrase)
            let match = try XCTUnwrap(TextSearch.matches(of: phrase, in: section.document, locale: "en").first)
            XCTAssertEqual(section.map.location(of: match.start), range.location)
            XCTAssertEqual(section.map.location(of: match.end, isEnd: true), NSMaxRange(range))
        }
        for (label, href) in [("a caption link", "OPS/one.xhtml#after"), ("a callout link", "OPS/two.xhtml")] {
            let url = try XCTUnwrap(BuilderHarness.attribute(.link, of: label, in: section) as? URL)
            XCTAssertEqual(ReaderLink(url: url), .internal(href: href))
        }
        XCTAssertEqual(try build(fontSize: 32).1.string.string, section.string.string,
                       "Reader typography changes formatting, never mapped characters")
    }

    func testConventionalHiddenPositionedLabelsAreNotDrawn() throws {
        let body = """
            <p>Visible caption.</p>
            <span id="offscreen">Duplicate offscreen caption.</span>
            <span id="rect">Duplicate clipped caption.</span>
            <span id="inset">Duplicate clipped path caption.</span>
            <span id="hidden">Hidden caption.</span>
            <span id="none">Display none caption.</span>
            <span id="visible">Slightly offset callout.</span>
            <span id="unclipped">Unclipped callout.</span>
            <span id="override">Restored unclipped callout.</span>
            <span id="invalid">Invalid clipping stays visible.</span><p id="next">Next paragraph.</p>
            """
        let css = """
            span { position:absolute; }
            #offscreen { left:-9999px; }
            #rect { width:1px; height:1px; clip:rect(0, 0, 0, 0); }
            #inset { width:1px; height:1px; clip-path:inset(50%); }
            #hidden { visibility:hidden; }
            #none { display:none; }
            #visible { left:-8px; }
            #unclipped { clip:rect(auto, auto, auto, auto); }
            #override { clip:rect(0, 0, 0, 0); clip:rect(auto, auto, auto, auto); clip-path:inset(50%); clip-path:inset(0%); }
            #invalid { clip:rect(0,,, 0,,, 0,,, 0); }
            """
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body, css: css))
        let section = SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0,
            typography: .init(fontSize: 16), fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
        XCTAssertEqual(section.string.drawnString, "Visible caption.\nSlightly offset callout.\nUnclipped callout.\nRestored unclipped callout.\nInvalid clipping stays visible.\nNext paragraph.")
        // What is parked or clipped away is kept for assistive technology, on a line of no height;
        // `visibility: hidden` and `display: none` hide from that too.
        XCTAssertEqual(section.string.spokenLabels, ["Duplicate offscreen caption.", "Duplicate clipped caption.", "Duplicate clipped path caption."])
        BuilderHarness.assertMapRoundTrips(section)
        let labels = ("Visible caption.\n" as NSString).length
        for (index, id) in ["offscreen", "rect", "inset"].enumerated() {
            XCTAssertEqual(section.anchors[id], labels + index, "\(id) is its own label")
            XCTAssertTrue(section.string.attribute(.attachment, at: labels + index, effectiveRange: nil) is SpokenLabelAttachment)
        }
        for id in ["hidden", "none"] { XCTAssertEqual(section.anchors[id], section.anchors["visible"]) }
    }

    func testHiddenLabelClassificationNeverChangesMappedTextWithReaderTypography() throws {
        let body = """
            <p id="begin">Before labels.</p>
            <span id="em">Font relative offset.</span>
            <span id="rem">Root relative offset.</span>
            <span id="mixed">Mixed calculation offset.</span>
            <span id="relativeCalc">Font relative calculation offset.</span>
            <span id="absolute">Absolute offscreen label.</span>
            <span id="absoluteCalc">Absolute calculation offscreen label.</span>
            <div id="inheritedRelative"><span id="relativeChild">Inherited font relative offset.</span></div>
            <div id="inheritedAbsolute"><span id="absoluteChild">Inherited absolute offscreen label.</span></div>
            <span id="initial">Reset offscreen label.</span>
            <span id="clippedRelative">Clipped font relative label.</span>
            <span id="farEm">Far font relative label.</span>
            <span id="farRem">Far root relative label.</span>
            <span id="farCalc">Far font relative calculation label.</span>
            <div id="inheritedFar"><span id="farChild">Inherited far font relative label.</span></div>
            <p id="end">After labels.</p>
            """
        // An em or a rem counts as 16 pixels whatever the size: 62 of them are 992 pixels and stay
        // visible at 96 points, where they compute to the 1,000-point limit; 63 are 1,008 and stay
        // hidden at 12 points, where a quarter-size em makes them 189.
        let css = """
            span { position:absolute; }
            #em { left:-62em; }
            #rem { top:-62rem; }
            #mixed { left:calc(-9999px + 50%); }
            #relativeCalc { top:calc(-31em * 2); }
            #absolute { left:-9999px; }
            #absoluteCalc { top:calc(-1200px + 100px); }
            #inheritedRelative { left:-62em; font-size:2em; }
            #relativeChild { left:inherit; }
            #inheritedAbsolute { top:calc(-9999px + 100px); font-size:2em; }
            #absoluteChild { top:inherit; }
            #initial { left:-9999px; left:initial; }
            #clippedRelative { left:-62em; clip:rect(0,0,0,0); }
            #farEm { left:-999em; }
            #farRem { top:-63rem; }
            #farCalc { left:calc(-999em - 10px); }
            #inheritedFar { left:-63em; font-size:0.25em; }
            #farChild { left:inherit; }
            """
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body, css: css))
        let spine = try SpineCFIs(publication: publication)
        var baseline: SectionText?
        for fontSize: CGFloat in [12, 17, 32, 96] {
            let section = SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0,
                typography: .init(fontSize: fontSize), fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
            if let baseline {
                XCTAssertEqual(section.string.string, baseline.string.string, "Font size \(fontSize)")
                XCTAssertEqual(section.map, baseline.map, "Font size \(fontSize)")
                XCTAssertEqual(section.anchors, baseline.anchors, "Font size \(fontSize)")
            } else { baseline = section }
            for phrase in ["Font relative offset.", "Root relative offset.", "Mixed calculation offset.",
                           "Font relative calculation offset.", "Inherited font relative offset.", "Reset offscreen label."] {
                XCTAssertTrue(section.string.string.contains(phrase), "Font size \(fontSize): \(phrase)")
            }
            let hidden = ["Absolute offscreen label.", "Absolute calculation offscreen label.",
                          "Inherited absolute offscreen label.", "Clipped font relative label.", "Far font relative label.",
                          "Far root relative label.", "Far font relative calculation label.", "Inherited far font relative label."]
            for phrase in hidden { XCTAssertFalse(section.string.string.contains(phrase), "Font size \(fontSize): \(phrase)") }
            XCTAssertEqual(section.string.spokenLabels.sorted(), hidden.sorted(), "each is kept for assistive technology at \(fontSize) points")
            let range = (section.string.string as NSString).range(of: "After labels.")
            let start = try XCTUnwrap(section.map.position(at: range.location, in: section.document))
            let end = try XCTUnwrap(section.map.endPosition(at: NSMaxRange(range), in: section.document))
            let cfi = spine.cfi(spineIndex: 0, start: start, end: end, in: section.document)
            let local = try XCTUnwrap(spine.resolve(cfi))
            let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: local.localPath, in: section.document))
            XCTAssertEqual(section.map.location(of: resolved.start), range.location)
            XCTAssertEqual(section.map.location(of: resolved.end, isEnd: true), NSMaxRange(range))
            BuilderHarness.assertMapRoundTrips(section)
        }
    }

    func testWidthsAndRightFloatPlacementResolveAgainstActualColumn() throws {
        let section = try build().1
        for column: CGFloat in [180, 360, 600] {
            let text = ReaderFlowBoxLayout.applying(to: section.string, viewport: CGSize(width: column, height: 700))
            for id in ["left", "right", "callout", "inline", "fixed"] {
                let start = try XCTUnwrap(section.anchors[id])
                let style = try XCTUnwrap(text.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)
                let width = column - style.headIndent + style.tailIndent
                XCTAssertGreaterThanOrEqual(width, min(column / 3, 64), id)
                XCTAssertLessThanOrEqual(width, column, id)
                switch id {
                case "left": XCTAssertEqual(width, column * 0.35, accuracy: 0.1)
                case "right":
                    XCTAssertEqual(width, column * 0.35, accuracy: 0.1)
                    XCTAssertGreaterThan(style.headIndent, 0)
                    XCTAssertEqual(style.tailIndent, 0, accuracy: 0.1)
                case "inline": XCTAssertEqual(width, min(column, max(column / 3, 150)), accuracy: 0.1)
                default: break
                }
            }
        }
    }

    func testNestedWidthLimitsAndRTLPlacementStayWithinTheColumn() throws {
        let body = """
            <div id="outer"><span id="nested">Nested box words.</span></div>
            <p><span id="minimum">Minimum width words.</span></p>
            <p><span id="maximum">Maximum width words.</span></p>
            <p><span id="rtl" dir="rtl">نص داخل مربع</span></p>
            """
        let css = """
            #outer { display:inline-block; width:80%; }
            #nested { display:inline-block; width:50%; }
            #minimum { display:inline-block; width:50px; min-width:150px; max-width:180px; }
            #maximum { display:inline-block; max-width:50%; }
            #rtl { float:right; width:50%; margin-left:auto; margin-right:auto; }
            """
        let book = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body, css: css))
        let section = SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: 0, typography: .init(fontSize: 16),
            fonts: FontRegistry(publication: book), rich: NativeRichContent()))
        let text = ReaderFlowBoxLayout.applying(to: section.string, viewport: CGSize(width: 300, height: 500))
        func style(_ id: String) throws -> NSParagraphStyle {
            let offset = try XCTUnwrap(section.anchors[id])
            return try XCTUnwrap(text.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)
        }
        let nested = try style("nested"), minimum = try style("minimum"), maximum = try style("maximum"), rtl = try style("rtl")
        XCTAssertEqual(300 - nested.headIndent + nested.tailIndent, 120, accuracy: 0.1)
        XCTAssertEqual(300 - minimum.headIndent + minimum.tailIndent, 150, accuracy: 0.1)
        XCTAssertEqual(300 - maximum.headIndent + maximum.tailIndent, 150, accuracy: 0.1)
        XCTAssertEqual(rtl.headIndent, 0, accuracy: 0.1, "The physical right edge is the RTL head")
        XCTAssertEqual(rtl.tailIndent, -150, accuracy: 0.1, "Floats ignore auto margins")
        BuilderHarness.assertMapRoundTrips(section)
    }

    func testBoxedSectionsReusePaginationAcrossPageTurns() throws {
        let section = try build().1
        let host = CanvasHost(FakeCanvasSource([section.string]), size: CGSize(width: 360, height: 300))
        defer { host.close() }
        host.canvas.show(.init(section: 0, offset: 0), selecting: nil)
        let paginator = try XCTUnwrap(host.canvas.paginator(for: 0))
        XCTAssertTrue(paginator.sourceText === section.string)
        for _ in 0..<3 {
            _ = host.canvas.turnPage(forward: true)
            XCTAssertTrue(host.canvas.paginator(for: 0) === paginator)
        }
    }

    func testNativePagesAndScrollKeepBoxesSelectableAndDoNotOverlap() async throws {
        let section = try build().1
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            var configuration = ReaderCanvasConfiguration()
            configuration.flow = flow
            let source = FakeCanvasSource([section.string])
            if flow == .scrolled { source.book = CanvasText.book([section.string]) }
            let host = CanvasHost(source, size: CGSize(width: 420, height: 420), configuration: configuration)
            defer { host.close() }
            for id in ["left", "right", "callout", "inline", "fixed"] {
                let offset = try XCTUnwrap(section.anchors[id])
                let phrase = id == "callout" ? "Positioned callout" : id == "inline" ? "Sized inline block" : nil
                let range = ReaderTextRange(section: 0, offset..<(offset + (phrase?.utf16.count ?? 4)))
                host.canvas.show(range.start, selecting: range)
                host.layOut()
                try await host.settle(30)
                let view = try XCTUnwrap(host.canvas.textViews.first)
                let selected = view.selectedRange
                XCTAssertGreaterThan(selected.length, 0, "\(flow) \(id)")
                if let phrase { XCTAssertEqual(view.plainText(in: selected), phrase) }
                XCTAssertFalse(view.segmentFrames(for: selected).isEmpty, "\(flow) \(id)")
                host.canvas.setHighlights([ReaderHighlight(id: id, range: range, kind: .search)])
                var highlights: [NSRange] = []
                let manager = view.readerLayoutManager
                manager.enumerateRenderingAttributes(from: manager.documentRange.location, reverse: false) { _, attributes, range in
                    if attributes[.backgroundColor] != nil {
                        highlights.append(NSRange(location: view.offset(of: range.location),
                            length: view.offset(of: range.endLocation) - view.offset(of: range.location)))
                    }
                    return true
                }
                XCTAssertEqual(highlights, [selected], "\(flow) \(id)")
                view.ensureFullLayout()
                let storage = try XCTUnwrap(view.contentStorage.textStorage)
                let visible = (storage.string as NSString).substring(with: view.shownCharacters) as NSString
                var cursor = 0
                var preceding: [CGRect] = []
                while cursor < visible.length {
                    let paragraph = visible.paragraphRange(for: NSRange(location: cursor, length: 0))
                    let frames = view.segmentFrames(for: paragraph)
                    for rect in frames {
                        for earlier in preceding {
                            let intersection = rect.intersection(earlier)
                            XCTAssertTrue(intersection.isNull || intersection.width < 0.5 || intersection.height < 0.5,
                                          "Glyphs overlap: \(flow) \(id) \(earlier) \(rect)")
                        }
                    }
                    preceding.append(contentsOf: frames)
                    cursor = NSMaxRange(paragraph)
                }
            }
            // Scroll width updates recompute from the original box styles, keeping selection.
            if flow == .scrolled {
                let view = try XCTUnwrap(host.canvas.textViews.first)
                let original = view.selectedRange
                host.resize(to: CGSize(width: 600, height: 420))
                XCTAssertEqual(view.selectedRange, original)
                let right = try XCTUnwrap(section.anchors["right"])
                let rect = try XCTUnwrap(view.lineFrame(containing: right))
                XCTAssertGreaterThan(rect.minX, 0)
                host.resize(to: CGSize(width: 420, height: 420))
                XCTAssertEqual(view.selectedRange, original)
            }
        }
        for fontSize: CGFloat in [16, 32] {
            let section = try build(fontSize: fontSize).1
            for size in [CGSize(width: 180, height: 240), CGSize(width: 360, height: 420)] {
                let paginator = ReaderPaginator(text: section.string, size: size)
                let pages = paginator.allPages
                XCTAssertEqual(pages.first?.range.location, 0)
                XCTAssertEqual(pages.last?.range.upperBound, section.string.length)
                for pair in zip(pages, pages.dropFirst()) { XCTAssertEqual(pair.0.range.upperBound, pair.1.range.location) }
                for page in pages { XCTAssertLessThanOrEqual(page.height, size.height + 1) }
            }
        }
    }
}
