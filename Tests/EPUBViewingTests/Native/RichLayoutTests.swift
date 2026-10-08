import CoreGraphics
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A TextKit 2 text view over a `ReaderTextContainer`, as the reader's views build them.
@MainActor private final class TextHost {
    let container: ReaderTextContainer
    let layoutManager = NSTextLayoutManager()
    let storage = NSTextContentStorage()
    #if os(macOS)
    let window: NSWindow
    let view: NSTextView
    #else
    let window: UIWindow
    let view: UITextView
    #endif

    init(size: CGSize, viewport: CGSize) {
        container = ReaderTextContainer(size: CGSize(width: size.width, height: 0))
        container.viewportSize = viewport
        layoutManager.textContainer = container
        storage.addTextLayoutManager(layoutManager)
        let frame = CGRect(origin: .zero, size: size)
        #if os(macOS)
        view = NSTextView(frame: frame, textContainer: container)
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        #else
        view = UITextView(frame: frame, textContainer: container)
        view.isScrollEnabled = false
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else { window = UIWindow(frame: frame) }
        window.addSubview(view)
        window.isHidden = false
        #endif
    }

    func show(_ text: NSAttributedString) {
        #if os(macOS)
        view.textStorage?.setAttributedString(text)
        #else
        view.attributedText = text
        #endif
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    /// Draws the view, and lays out its viewport until `ready` (attachment views load there).
    func display(until ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            #if os(macOS)
            view.layoutSubtreeIfNeeded()
            layoutManager.textViewportLayoutController.layoutViewport()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #else
            view.layoutIfNeeded()
            layoutManager.textViewportLayoutController.layoutViewport()
            // A display cycle's layout pass, which inserts attachment views into fragment views.
            func relayout(_ view: UIView) { view.setNeedsLayout(); view.layoutIfNeeded(); view.subviews.forEach(relayout) }
            relayout(view)
            _ = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            #endif
            if ready() { return }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
    }

    func views<View: PlatformView>(_ type: View.Type) -> [View] {
        func collect(_ view: PlatformView) -> [View] { ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap(collect) }
        return collect(view)
    }

    /// Each attachment's layout fragment frame.
    func attachmentFrames(in text: NSAttributedString) -> [(NSTextAttachment, CGRect)] {
        var frames: [(NSTextAttachment, CGRect)] = []
        let start = layoutManager.documentRange.location
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            guard let range = fragment.textElement?.elementRange else { return true }
            let lower = layoutManager.offset(from: start, to: range.location)
            let upper = layoutManager.offset(from: start, to: range.endLocation)
            text.enumerateAttribute(.attachment, in: NSRange(location: lower, length: upper - lower)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { frames.append((attachment, fragment.layoutFragmentFrame)) }
            }
            return true
        }
        return frames
    }

    func close() {
        #if os(macOS)
        window.close()
        #else
        window.isHidden = true
        #endif
    }
}

@MainActor final class RichLayoutTests: XCTestCase {
    func testTextKit2LaysOutAndDrawsRichAttachments() async throws {
        let cache = ReaderImageCache(budget: 64 << 20)
        let fixture = try RichFixture("""
        <div><img id="photo" src="photo.png" alt="Photo"/></div>
        <table id="t" border="1"><thead><tr><th>Name</th><th>Value</th></tr></thead>
        <tbody><tr><td rowspan="2">Alpha with longer text</td><td>1</td></tr><tr><td>2</td></tr><tr><td>Beta</td><td>3</td></tr></tbody></table>
        <hr id="hr"/>
        """, files: ["photo.png": RichFixture.image(width: 800, height: 400)], cache: cache)
        let font = PlatformFont.systemFont(ofSize: 16)
        let text = NSMutableAttributedString(string: "Before\n", attributes: [.font: font])
        let newline = NSAttributedString(string: "\n", attributes: [.font: font])
        text.append(try XCTUnwrap(fixture.image("photo")))
        text.append(newline)
        text.append(try XCTUnwrap(fixture.table("t")))
        text.append(newline)
        let hr = fixture.element("hr")
        text.append(fixture.factory.horizontalRule(hr, style: fixture.style(of: hr), context: fixture.context))
        text.append(NSAttributedString(string: "\nAfter", attributes: [.font: font]))

        let host = TextHost(size: CGSize(width: 400, height: 900), viewport: CGSize(width: 390, height: 600))
        defer { host.close() }
        host.show(text)
        let frames = host.attachmentFrames(in: text)
        let lineWidth = 400 - 2 * host.container.lineFragmentPadding

        let photo = try XCTUnwrap(frames.first { $0.0 is ReaderImageAttachment })
        XCTAssertEqual(photo.1.width, lineWidth, accuracy: 0.5)
        XCTAssertEqual(photo.1.height, lineWidth / 2, accuracy: 0.5, "The image's line is the image")

        let rows = frames.filter { $0.0 is TableRowsAttachment }
        XCTAssertEqual(rows.count, 3)
        let table = try XCTUnwrap((rows.first?.0 as? TableRowsAttachment)?.table)
        let layout = table.layout(available: lineWidth, viewportHeight: 600)
        for (index, row) in rows.enumerated() {
            XCTAssertEqual(row.1.width, lineWidth, accuracy: 0.5)
            if index < rows.count - 1 {
                XCTAssertEqual(row.1.height, layout.height(ofUnit: index), accuracy: 0.01, "Unit \(index) is exactly its rows")
                XCTAssertEqual(rows[index + 1].1.minY, row.1.maxY, accuracy: 0.01, "No gap between row units")
            } else {
                XCTAssertGreaterThanOrEqual(row.1.height, layout.height(ofUnit: index) - 0.01)
            }
        }
        let rule = try XCTUnwrap(frames.first { $0.0 is ReaderRuleAttachment })
        XCTAssertEqual(rule.1.width, lineWidth, accuracy: 0.5)
        XCTAssertEqual(cache.decodeCount, 0, "Layout decodes nothing")

        try await host.display { cache.decodeCount > 0 && host.views(TableRowsView.self).count >= 3 }
        XCTAssertEqual(cache.decodeCount, 1, "Drawing decoded the image once")
        let rowViews = host.views(TableRowsView.self)
        XCTAssertEqual(Set(rowViews.map { ObjectIdentifier($0.attachment) }).count, 3, "A view per row unit")
        for view in rowViews {
            XCTAssertEqual(view.bounds.width, lineWidth, accuracy: 0.5)
            XCTAssertEqual(view.bounds.height, layout.height(ofUnit: view.attachment.unit), accuracy: 0.5)
        }
        let first = try XCTUnwrap(rowViews.first { $0.attachment.unit == 1 })
        #if os(macOS)
        let cells = try XCTUnwrap(first.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(cells.compactMap { $0.accessibilityLabel() }, ["Alpha with longer text", "1", "2"])
        XCTAssertNil(first.hitTest(CGPoint(x: 5, y: 5)), "Clicks reach the text view")
        #else
        let cells = try XCTUnwrap(first.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(cells.compactMap(\.accessibilityLabel), ["Alpha with longer text", "1", "2"])
        XCTAssertFalse(first.isUserInteractionEnabled, "Taps reach the text view")
        #endif
        XCTAssertEqual(fixture.report.report, SectionReport())
    }
}
