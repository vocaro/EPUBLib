import CoreGraphics
import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shared measurements and fixtures for the `ViewCoverage…` tests of the reader's views.
@MainActor enum ViewCoverage {
    struct Line {
        var range: NSRange
        var top: CGFloat
        var bottom: CGFloat
    }

    /// Every non-empty line of `text` laid out on its own at `width`, as a text view lays it out.
    static func lines(of text: NSAttributedString, width: CGFloat) -> [Line] {
        let storage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        storage.addTextLayoutManager(layoutManager)
        let container = ReaderTextContainer(size: CGSize(width: width, height: 0))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        storage.attributedString = text
        var result: [Line] = []
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let start = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                result.append(Line(range: NSRange(location: start + line.characterRange.location, length: line.characterRange.length),
                                   top: fragment.layoutFragmentFrame.minY + line.typographicBounds.minY,
                                   bottom: fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY))
            }
            return true
        }
        return result
    }

    /// The height of one body line at the fixtures' 17-point size and 1.2 line height.
    static var bodyLineHeight: CGFloat {
        let line = lines(of: CanvasText.body("Line"), width: 400)[0]
        return line.bottom - line.top
    }

    /// Marks a paragraph as the section builder does: on its first character only.
    static func marked(_ paragraph: NSAttributedString, keep: Bool = false, breakBefore: Bool = false) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: paragraph)
        guard text.length > 0 else { return text }
        if keep { text.addAttribute(.readerKeepWithNext, value: true, range: NSRange(location: 0, length: 1)) }
        if breakBefore { text.addAttribute(.readerPageBreakBefore, value: true, range: NSRange(location: 0, length: 1)) }
        return text
    }

    /// One-line paragraphs "<prefix> 0", "<prefix> 1", … with no spacing between them.
    static func rows(_ prefix: String, _ count: Int, keep: Bool = false, breakBefore: Bool = false) -> NSAttributedString {
        joined((0..<count).map {
            marked(CanvasText.body("\(prefix) \($0)\n", style: CanvasText.bodyStyle(spacing: 0)), keep: keep, breakBefore: breakBefore)
        })
    }

    static func joined(_ parts: [NSAttributedString]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for part in parts { text.append(part) }
        return text
    }

    /// Pages cover the text once, in order, with no empty page.
    static func assertPartition(_ pages: [ReaderPage], of text: NSAttributedString, _ label: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pages.first?.range.location, 0, label, file: file, line: line)
        XCTAssertEqual(pages.last.map { NSMaxRange($0.range) }, text.length, label, file: file, line: line)
        for (page, next) in zip(pages, pages.dropFirst()) {
            XCTAssertEqual(NSMaxRange(page.range), next.range.location, "contiguous \(label)", file: file, line: line)
        }
        if text.length > 0 {
            for page in pages { XCTAssertGreaterThan(page.range.length, 0, "no empty page \(label)", file: file, line: line) }
        }
        XCTAssertEqual(pages.map { (text.string as NSString).substring(with: $0.range) }.joined(), text.string, label, file: file, line: line)
    }

    /// Each page's own text, laid out alone as its column lays it out, breaks into the section's
    /// lines (or the page's own measured ones), ends a line exactly at the page's end and is as
    /// tall as the page says (doc/native-viewer.md "Pages": "its lines break exactly as in the
    /// measuring layout").
    static func assertPagesLayOutLikeTheSection(_ paginator: ReaderPaginator, _ label: String = "",
                                                file: StaticString = #filePath, line: UInt = #line) {
        let size = paginator.size
        let pages = paginator.allPages
        let section = lines(of: paginator.text, width: size.width)
        for page in pages {
            let pageText = paginator.text(for: page)
            let name = "\(label) page at \(page.range.location)"
            XCTAssertEqual(pageText.length, page.layoutEnd - page.range.location, name, file: file, line: line)
            let expected = section.filter { NSLocationInRange($0.range.location, page.range) }
            let actual = lines(of: pageText, width: size.width).filter { $0.range.location < page.range.length }
            XCTAssertEqual(actual.map(\.range.length), page.measuredLineLengths ?? expected.map(\.range.length), name, file: file, line: line)
            XCTAssertEqual(actual.last.map { NSMaxRange($0.range) }, page.range.length, "a line ends at the page's end, \(name)",
                           file: file, line: line)
            XCTAssertEqual(actual.last?.bottom ?? 0, page.height, accuracy: 0.5, "height, \(name)", file: file, line: line)
        }
    }

    static func pageBoundaries(_ pages: [ReaderPage]) -> [Int] { pages.map(\.range.location) }

    /// A book image as the section builder makes one, `shownWidth` points wide on the line.
    /// `alt` is the attribute as a book writes it: words, empty for decoration, nil for none.
    static func readerImage(width: Int, height: Int, shownWidth: CGFloat, alt: String? = "Figure") throws -> ReaderImageAttachment {
        let source = try XCTUnwrap(ReaderImageSource.bitmap(RichFixture.image(width: width, height: height), path: "figure.png",
                                                             key: UUID().uuidString))
        var sizing = ImageSizing(intrinsic: source.pixelSize)
        sizing.width = .points(shownWidth)
        return ReaderImageAttachment(source: source, sizing: sizing, alternative: ImageAlternative(alt: alt), style: ComputedStyle(),
                                     cache: ReaderImageCache(budget: 96 << 20))
    }

    /// An image's attachment character with body attributes, as it stands in a paragraph.
    static func imageText(_ image: ReaderImageAttachment) -> NSAttributedString {
        NSAttributedString(attachment: image, attributes: CanvasText.body("a").attributes(at: 0, effectiveRange: nil))
    }
}

/// A canvas placed in a window as a subview, so its frame can be anything a host's layout might
/// pass through: a collapsing pane, a transition's first frame.
@MainActor final class ViewCoverageFrameHost {
    let canvas = ReaderCanvasView(frame: .zero)
    let source: FakeCanvasSource
    let recorder = CanvasRecorder()
    #if os(macOS)
    let window: NSWindow
    #else
    let window: UIWindow
    let controller = UIViewController()
    #endif

    init(_ source: FakeCanvasSource, configuration: ReaderCanvasConfiguration = .init()) {
        self.source = source
        canvas.dataSource = source
        canvas.delegate = recorder
        canvas.configuration = configuration
        #if os(macOS)
        // Never ordered in: layout needs a window, not a place on a shared screen.
        window = makeMacTestWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        window.contentView?.addSubview(canvas)
        #else
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 800, height: 800)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        }
        window.rootViewController = controller
        controller.view.addSubview(canvas)
        window.makeKeyAndVisible()
        #endif
    }

    func setFrame(_ frame: CGRect) {
        canvas.frame = frame
        #if os(macOS)
        canvas.needsLayout = true
        canvas.layoutSubtreeIfNeeded()
        #else
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()
        #endif
    }

    func close() {
        canvas.removeFromSuperview()
        #if os(macOS)
        window.close()
        window.contentView = nil
        #else
        window.isHidden = true
        window.rootViewController = nil
        #endif
    }
}

extension ReaderPage {
    /// What a column shows of the page: its top spacing and its lines.
    var extent: CGFloat { topSpacing + height }
}
