import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// SKELETON: a non-rendering stand-in so the session compiles before the views workstream lands.
// It tracks the requested position as its visible range and draws nothing.
@MainActor final class ReaderCanvasView: PlatformView, ReaderCanvas {
    weak var delegate: (any ReaderCanvasDelegate)?
    weak var dataSource: (any ReaderCanvasDataSource)?
    var configuration = ReaderCanvasConfiguration()
    private(set) var visibleRange: ReaderTextRange?
    private(set) var currentSelection: ReaderSelection?

    func reloadContent(keeping position: ReaderTextPosition?) {
        if let position = position ?? visibleRange?.start { show(position, selecting: nil) }
    }

    func show(_ position: ReaderTextPosition, selecting range: ReaderTextRange?) {
        let length = dataSource?.text(forSection: position.section)?.length ?? 0
        visibleRange = ReaderTextRange(start: position, end: .init(section: position.section, offset: length))
        delegate?.canvas(self, didShow: visibleRange!, sectionProgress: length > 0 ? Double(position.offset) / Double(length) : 0)
        if let range {
            let text = dataSource?.text(forSection: range.start.section)?.attributedSubstring(
                from: NSRange(location: range.start.offset, length: range.end.offset - range.start.offset)).string ?? ""
            currentSelection = ReaderSelection(range: range, text: text)
            delegate?.canvas(self, didChangeSelection: currentSelection)
        }
    }

    func turnPage(forward: Bool) -> PageTurnResult {
        guard let dataSource, let current = visibleRange?.start else { return .atBoundary }
        let next = current.section + (forward ? 1 : -1)
        guard next >= 0, next < dataSource.sectionCount else { return .atBoundary }
        guard dataSource.text(forSection: next) != nil else {
            delegate?.canvas(self, needsSection: next, forward: forward)
            return .pending(section: next)
        }
        show(.init(section: next, offset: 0), selecting: nil)
        return .turned
    }

    func clearSelection() {
        guard currentSelection != nil else { return }
        currentSelection = nil
        delegate?.canvas(self, didChangeSelection: nil)
    }

    func setHighlights(_ highlights: [ReaderHighlight]) {}
    func presentNote(_ text: NSAttributedString, from rect: CGRect) {}
}
