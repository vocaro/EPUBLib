import CoreGraphics
import QuartzCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A scroll step of continuous scroll in motion, as the host chose to animate page turns
/// (`ReaderCanvasView.turnScrolledPage`): the text moves from where it was drawn to where the
/// step put it, a frame at a time, as the platform's own animated scroll moves it, so the lines
/// it passes are laid out and drawn on the way. Everything but the drawing is the step's end
/// from the start: the anchor, the visible range, what the host and an assistive technology are
/// told (doc/native-viewer.md, "Continuous scroll").
@MainActor final class ReaderScrollStep: NSObject {
    /// As long as a page's slide takes (`ReaderPageMotion.duration`).
    static let duration: TimeInterval = 0.3

    /// The text container Y at the top of the visible area where the step begins and ends.
    let from: CGFloat
    let target: CGFloat
    private let begin = CACurrentMediaTime()
    private weak var canvas: ReaderCanvasView?
    private var link: CADisplayLink?
    private(set) var isEnded = false
    /// Called once, when the step ends.
    var onEnd: (() -> Void)?

    /// Starts the step from `from` to `target` in `canvas`, whose scroll view stands at `from`.
    init(from: CGFloat, to target: CGFloat, in canvas: ReaderCanvasView) {
        self.from = from
        self.target = target
        self.canvas = canvas
        super.init()
        #if os(iOS)
        let link = CADisplayLink(target: self, selector: #selector(advance(_:)))
        #else
        let link = canvas.displayLink(target: self, selector: #selector(advance(_:)))
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
        // A display link draws no frame for a window off every display, or on a display asleep:
        // the step still ends.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration + 0.2))
            self?.end()
        }
    }

    /// Where the top of the visible area stands `elapsed` seconds in: eased in and out.
    static func position(from: CGFloat, to target: CGFloat, elapsed: TimeInterval) -> CGFloat {
        let time = min(1, max(0, elapsed / duration))
        let eased = time < 0.5 ? 2 * time * time : 1 - pow(-2 * time + 2, 2) / 2
        return from + (target - from) * CGFloat(eased)
    }

    @objc private func advance(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - begin
        guard elapsed < Self.duration, let canvas else { return end() }
        canvas.moveScrollStep(to: Self.position(from: from, to: target, elapsed: elapsed))
    }

    /// Ends the step now, where it would have ended: the text at its target. Once only; a later
    /// call does nothing.
    func end() {
        guard !isEnded else { return }
        isEnded = true
        link?.invalidate()
        link = nil
        canvas?.moveScrollStep(to: target)
        onEnd?()
        onEnd = nil
    }
}
