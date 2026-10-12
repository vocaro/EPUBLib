import CoreGraphics
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Hermetic section text for the canvas and paginator tests.
enum CanvasText {
    static let words = "the quick brown fox jumps over the lazy dog while seven wizards quietly hex an amber jukebox"
        .split(separator: " ").map(String.init)

    static func bodyStyle(spacing: CGFloat = 8, alignment: NSTextAlignment = .natural,
                          hyphenates: Bool = false, indent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.2
        style.paragraphSpacing = spacing
        style.alignment = alignment
        style.firstLineHeadIndent = indent
        if hyphenates { style.hyphenationFactor = 1 }
        return style
    }

    static func body(_ text: String, style: NSParagraphStyle = bodyStyle(), size: CGFloat = 17) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: PlatformFont.systemFont(ofSize: size), .paragraphStyle: style,
            .foregroundColor: ReaderPalette.text(dark: false)])
    }

    /// A deterministic run of words.
    static func sentence(_ count: Int, seed: Int) -> String {
        (0..<count).map { words[($0 * 7 + seed * 3) % words.count] }.joined(separator: " ") + "."
    }

    static func heading(_ text: String, breakBefore: Bool = true) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 24
        style.paragraphSpacing = 12
        style.lineHeightMultiple = 1.2
        var attributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.boldSystemFont(ofSize: 28), .paragraphStyle: style, .readerKeepWithNext: true]
        if breakBefore { attributes[.readerPageBreakBefore] = true }
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// A section of `chapters` chapters, each a page-breaking heading and long paragraphs, with an
    /// internal link in the first paragraph.
    static func section(_ index: Int, chapters: Int = 2, paragraphs: Int = 8, style: NSParagraphStyle = bodyStyle())
        -> NSAttributedString {
        let text = NSMutableAttributedString()
        for chapter in 0..<chapters {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(heading("Section \(index) chapter \(chapter)"))
            for paragraph in 0..<paragraphs {
                text.append(NSAttributedString(string: "\n"))
                text.append(body("S\(index)C\(chapter)P\(paragraph) " + sentence(70, seed: index + paragraph), style: style))
                if chapter == 0, paragraph == 0 {
                    text.append(body(" "))
                    text.append(NSAttributedString(string: "a link", attributes: [
                        .font: PlatformFont.systemFont(ofSize: 17), .paragraphStyle: style,
                        .link: ReaderLink.internal(href: "OPS/two.xhtml#target").url]))
                }
            }
        }
        return text
    }

    /// A fixed-size attachment, as the rich-content factory's images are.
    static func attachment(size: CGSize) -> NSAttributedString {
        let attachment = NSTextAttachment()
        #if os(macOS)
        attachment.image = NSImage(size: size)
        #else
        attachment.image = UIGraphicsImageRenderer(size: size).image { _ in }
        #endif
        attachment.bounds = CGRect(origin: .zero, size: size)
        return NSAttributedString(attachment: attachment)
    }

    /// The whole book: sections joined by one paragraph break, as `ReaderBookText` documents,
    /// leaving out `omitting`.
    static func book(_ sections: [NSAttributedString], omitting: Set<Int> = []) -> ReaderBookText {
        let string = NSMutableAttributedString()
        var starts = Array(repeating: 0, count: sections.count)
        for (index, section) in sections.enumerated() where !omitting.contains(index) {
            if string.length > 0 { string.append(NSAttributedString(string: "\n")) }
            starts[index] = string.length
            string.append(section)
        }
        var next = string.length
        for index in starts.indices.reversed() {
            if omitting.contains(index) { starts[index] = next } else { next = starts[index] }
        }
        return ReaderBookText(string: string, sectionStarts: starts, omitted: omitting)
    }
}

/// A formula or image attachment that reads as text.
final class TextualTestAttachment: NSTextAttachment, ReaderTextualAttachment {
    var textEquivalent = ""
}

@MainActor final class FakeCanvasSource: ReaderCanvasDataSource {
    var sections: [NSAttributedString?]
    var linear: [Bool]
    var book: ReaderBookText?
    init(_ sections: [NSAttributedString?], linear: [Bool]? = nil) {
        self.sections = sections
        self.linear = linear ?? sections.map { _ in true }
    }
    var sectionCount: Int { sections.count }
    func text(forSection index: Int) -> NSAttributedString? { sections[index] }
    func isLinear(section index: Int) -> Bool { linear[index] }
    var bookText: ReaderBookText? { book }
}

@MainActor final class CanvasRecorder: ReaderCanvasDelegate {
    var shown: [(range: ReaderTextRange, progress: Double)] = []
    var selections: [ReaderSelection?] = []
    var actions = 0
    var links: [(link: ReaderLink, position: ReaderTextPosition, rect: CGRect)] = []
    var needed: [(section: Int, forward: Bool)] = []

    func canvas(_ canvas: any ReaderCanvas, didShow range: ReaderTextRange, sectionProgress: Double) {
        shown.append((range, sectionProgress))
    }
    func canvas(_ canvas: any ReaderCanvas, didChangeSelection selection: ReaderSelection?) { selections.append(selection) }
    func canvasDidRequestSelectionAction(_ canvas: any ReaderCanvas) { actions += 1 }
    func canvas(_ canvas: any ReaderCanvas, didActivate link: ReaderLink, at position: ReaderTextPosition, rect: CGRect) {
        links.append((link, position, rect))
    }
    func canvas(_ canvas: any ReaderCanvas, needsSection index: Int, forward: Bool) { needed.append((index, forward)) }
}

/// The scroll bars of a continuous scroll view. A Mac shows overlay ones with a trackpad and
/// legacy ones with a mouse attached, and a legacy one takes its width from the scroll column
/// (doc/native-viewer.md, "Layout"). A test of where lines sit across that column says which it
/// means with `CanvasHost.setScrollBars`, so that its result does not depend on what is attached
/// to the Mac it runs on. iOS has overlay ones only.
enum CanvasScrollBars: CaseIterable {
    case overlay
    #if os(macOS)
    case legacy
    #endif

    /// The width the scroll bar takes from the scroll view.
    var width: CGFloat {
        #if os(macOS)
        self == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        #else
        0
        #endif
    }
}

/// A canvas in a real window, like `ReaderTestWindow` hosts the reader.
@MainActor final class CanvasHost {
    let canvas = ReaderCanvasView(frame: .zero)
    let source: FakeCanvasSource
    let recorder = CanvasRecorder()
    #if os(macOS)
    let window: NSWindow
    private var scrollerStyle: NSKeyValueObservation?
    #else
    let window: UIWindow
    let controller = UIViewController()
    #endif

    init(_ source: FakeCanvasSource, size: CGSize = CGSize(width: 600, height: 700),
         configuration: ReaderCanvasConfiguration = .init()) {
        self.source = source
        canvas.dataSource = source
        canvas.delegate = recorder
        canvas.configuration = configuration
        #if os(macOS)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFront(nil)
        #else
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        controller.view = canvas
        window.rootViewController = controller
        window.makeKeyAndVisible()
        #endif
        layOut()
    }

    func layOut() {
        #if os(macOS)
        window.contentView?.layoutSubtreeIfNeeded()
        #else
        window.layoutIfNeeded()
        canvas.layoutIfNeeded()
        #endif
    }

    /// Gives the canvas's scroll view `bars` and holds it to them: AppKit gives every scroll view
    /// the Mac's preferred kind again whenever that changes, and a process on a Mac with a mouse
    /// learns its preference a moment after it starts.
    func setScrollBars(_ bars: CanvasScrollBars) throws {
        #if os(macOS)
        let scrollView = try XCTUnwrap(canvas.scrollContainer as? NSScrollView)
        let style: NSScroller.Style = bars == .legacy ? .legacy : .overlay
        scrollView.scrollerStyle = style
        scrollerStyle = scrollView.observe(\.scrollerStyle) { view, _ in
            MainActor.assumeIsolated { if view.scrollerStyle != style { view.scrollerStyle = style } }
        }
        layOut()
        #endif
    }

    func resize(to size: CGSize) {
        #if os(macOS)
        window.setContentSize(size)
        #else
        window.frame = CGRect(origin: .zero, size: size)
        #endif
        layOut()
    }

    func close() {
        #if os(macOS)
        scrollerStyle = nil
        window.close()
        window.contentView = nil
        #else
        window.isHidden = true
        window.rootViewController = nil
        #endif
    }

    /// Lets the canvas's 150 ms settling and throttling run.
    func settle(_ milliseconds: Int = 300) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}
