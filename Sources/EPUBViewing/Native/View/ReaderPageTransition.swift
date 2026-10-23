import CoreGraphics
import QuartzCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// How a page turn in paginated flow moves (doc/native-viewer.md, "Input and accessibility"):
/// the animation the host chose, as the person's Reduce Motion setting has it. nil where one
/// page replaces the other at once.
enum ReaderPageMotion: Equatable, Sendable {
    case slide, dissolve

    init?(_ animation: EPUBPageTurnAnimation, reducesMotion: Bool) {
        switch animation.style {
        case .none: return nil
        case .slide: self = reducesMotion ? .dissolve : .slide
        case .dissolve: self = .dissolve
        }
    }

    /// How long a turn made at once takes, and a drag let go where it began.
    var duration: TimeInterval { self == .slide ? 0.3 : 0.25 }
}

/// A swipe's drag of a page, a finger's on iPhone and iPad and a trackpad's on Mac, as the
/// page's offset in points, negative to the left.
enum ReaderPageDrag {
    /// At this speed, in points a second, a drag let go turns the page the way it moves however
    /// short it is, and one moving back puts the page back however far it went.
    static let flickSpeed: CGFloat = 300

    /// The way a drag turns: towards the left reads forward, mirrored right to left, as a swipe.
    static func forward(offset: CGFloat, isRightToLeft: Bool) -> Bool {
        ReaderCanvasInput.swipeDirection(towardsLeft: offset < 0, isRightToLeft: isRightToLeft)
    }

    /// How far through the turn a drag is, from 0 to 1.
    static func progress(offset: CGFloat, width: CGFloat) -> CGFloat {
        width > 0 ? min(1, abs(offset) / width) : 0
    }

    /// Where the page stands for a drag towards no page, at an end of the book or before a
    /// section is built: it gives less the further it goes, as a scroll view past its end, and
    /// never as far as the drag.
    static func resisted(_ offset: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let given = (1 - 1 / (abs(offset) * 0.55 / width + 1)) * width
        return offset < 0 ? -given : given
    }

    /// Whether a drag let go at `offset`, moving at `velocity` points a second, turns the page:
    /// past half the width unless it is moving back fast, or moving on fast however short it is.
    static func turns(offset: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        guard offset != 0, width > 0 else { return false }
        let onward = offset < 0 ? -velocity : velocity
        if onward >= flickSpeed { return true }
        if onward <= -flickSpeed { return false }
        return progress(offset: offset, width: width) >= 0.5
    }
}

/// A page turn in motion. The canvas's columns hold the page turned to from the moment it is
/// turned, as they do with no animation, so that VoiceOver, the selection, the highlights and
/// the host find everything as they would then: only what is drawn over them moves. That is a
/// picture of the page that was shown (`outgoing`), going, while the columns are drawn coming in;
/// and for a drag, the page it brings in, drawn by columns of its own (`preview`) over the
/// canvas's, which still hold the page shown until the drag turns it.
@MainActor final class ReaderPageTransition {
    let motion: ReaderPageMotion
    /// A swipe follows this turn, and it turns the page only when the swipe lets go past its turn.
    let isDrag: Bool
    let overlay: ReaderPageTransitionView
    let outgoing: PlatformView
    /// A drag's page coming in: the preview's columns, where they stand on the canvas.
    private let incoming: ReaderPageTransitionView?
    /// The way the page a drag brings in turns, and the columns that draw it: none where no page
    /// lies that way or its section is not built.
    private(set) var dragForward: Bool?
    private(set) var preview: [ReaderTextView] = []
    /// Where a drag has the page: its offset in points, negative to the left.
    private(set) var offset: CGFloat = 0
    /// A drag has let go, and its page goes the rest of the way.
    private(set) var isSettling = false
    private(set) var isEnded = false
    /// What a turn made at once animates, and where: the canvas's columns coming in.
    private(set) var animatedLayers: [CALayer] = []
    /// Called once, when the transition ends, with the preview's columns to let go of.
    var onEnd: (([ReaderTextView]) -> Void)?
    static let animationKey = "org.epublib.reader.pageTurn"

    private var width: CGFloat { overlay.bounds.width }

    /// A turn already made: `outgoing`, the page as it was drawn, goes, and `columns`, the
    /// canvas's own showing the page turned to, come in. `forward` is the way it turned, and the
    /// page turned to comes in from the right in a book read left to right, from the left in one
    /// read right to left.
    init(turn motion: ReaderPageMotion, outgoing: PlatformView, columns: [PlatformView], in canvas: ReaderCanvasView,
         forward: Bool, isRightToLeft: Bool) {
        self.motion = motion
        isDrag = false
        self.outgoing = outgoing
        incoming = nil
        overlay = ReaderPageTransitionView(frame: canvas.bounds)
        overlay.addSubview(outgoing)
        canvas.addPageTransitionView(overlay)
        let side: CGFloat = forward != isRightToLeft ? 1 : -1
        let width = canvas.bounds.width
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.end() } }
        switch motion {
        case .slide:
            outgoing.frame.origin.x = -side * width
            animate(outgoing, offsetFrom: side * width)
            for column in columns { animate(column, offsetFrom: side * width) }
        case .dissolve:
            outgoing.setOpacity(0)
            animate(outgoing, opacityFrom: 1, to: 0)
            for column in columns { animate(column, opacityFrom: 0, to: 1) }
        }
        CATransaction.commit()
    }

    /// A turn a swipe follows. `outgoing`, the page shown as it is drawn, covers the canvas's
    /// columns on the page's own background until the drag ends.
    init(drag motion: ReaderPageMotion, outgoing: PlatformView, in canvas: ReaderCanvasView, background: PlatformColor) {
        self.motion = motion
        isDrag = true
        self.outgoing = outgoing
        overlay = ReaderPageTransitionView(frame: canvas.bounds)
        overlay.setBackground(background)
        let incoming = ReaderPageTransitionView(frame: canvas.bounds)
        incoming.isHidden = true
        self.incoming = incoming
        overlay.addSubview(incoming)
        overlay.addSubview(outgoing)
        canvas.addPageTransitionView(overlay)
    }

    /// Has a drag bring in `columns`, the page a turn towards `forward` shows (none where no
    /// page lies that way). The columns are laid out where the canvas shows them.
    func setPreview(_ columns: [ReaderTextView], forward: Bool) {
        guard isDrag, !isEnded, let incoming else { return }
        let previous = preview
        for column in previous { column.removeFromSuperview() }
        preview = columns
        dragForward = forward
        for column in columns { incoming.addSubview(column) }
        onDiscard?(previous)
    }

    /// Called with a drag's earlier preview's columns, when it brings in another page.
    var onDiscard: (([ReaderTextView]) -> Void)?

    /// Moves a drag's page to `offset`: in a slide the page shown moves with it and the page it
    /// brings in beside it, and in a dissolve the one gives way to the other as far as the drag
    /// has gone. Towards no page, a slide's page gives less and less, and a dissolve's stays.
    func follow(offset: CGFloat) {
        guard isDrag, !isEnded, !isSettling, let incoming else { return }
        self.offset = offset
        let hasPage = !preview.isEmpty
        incoming.isHidden = !hasPage
        switch motion {
        case .slide:
            let shown = hasPage ? max(-width, min(width, offset)) : ReaderPageDrag.resisted(offset, width: width)
            outgoing.frame.origin.x = shown
            incoming.frame.origin.x = shown + (offset < 0 ? width : -width)
        case .dissolve:
            let progress = hasPage ? ReaderPageDrag.progress(offset: offset, width: width) : 0
            outgoing.setOpacity(1 - progress)
            incoming.setOpacity(progress)
        }
    }

    /// A drag has let go: its page goes the rest of the way where `turned`, and back otherwise.
    /// `animated` moves it there, in the time the rest of the way takes; a trackpad's swipe
    /// has had AppKit move it there already. The transition then ends.
    func settle(turned: Bool, animated: Bool) {
        guard isDrag, !isEnded, !isSettling, let incoming else { return }
        isSettling = true
        let toward: CGFloat = offset < 0 ? -1 : 1
        let progress = ReaderPageDrag.progress(offset: offset, width: width)
        let remaining = turned ? 1 - progress : progress
        guard animated, remaining > 0.01, window != nil else { return end() }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.end() } }
        let duration = max(0.12, motion.duration * remaining)
        switch motion {
        case .slide:
            let outgoingX = turned ? toward * width : 0
            let incomingX = outgoingX - toward * width
            move(outgoing, toX: outgoingX, duration: duration)
            move(incoming, toX: incomingX, duration: duration)
        case .dissolve:
            fade(outgoing, to: turned ? 0 : 1, duration: duration)
            fade(incoming, to: turned ? 1 : 0, duration: duration)
        }
        CATransaction.commit()
    }

    private var window: AnyObject? { overlay.window }

    /// Ends the transition now, where it would have ended: the canvas's columns are drawn as they
    /// are, and what was drawn over them goes. Once only; a later call does nothing.
    func end() {
        guard !isEnded else { return }
        isEnded = true
        for layer in animatedLayers { layer.removeAnimation(forKey: Self.animationKey) }
        animatedLayers.removeAll()
        overlay.removeFromSuperview()
        let preview = self.preview
        self.preview = []
        onEnd?(preview)
        onEnd = nil
        onDiscard = nil
    }

    // MARK: Core Animation

    /// Animates a view in from `offset` points to the side of where it stands. Its frame is
    /// where it ends, as an assistive technology or a touch finds it throughout.
    private func animate(_ view: PlatformView, offsetFrom offset: CGFloat) {
        guard let layer = view.backingLayer else { return }
        let animation = CABasicAnimation(keyPath: "position")
        animation.isAdditive = true
        animation.fromValue = CGPoint(x: offset, y: 0)
        animation.toValue = CGPoint.zero
        add(animation, to: layer)
    }

    private func animate(_ view: PlatformView, opacityFrom from: Float, to: Float) {
        guard let layer = view.backingLayer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        add(animation, to: layer)
    }

    private func add(_ animation: CABasicAnimation, to layer: CALayer, duration: TimeInterval? = nil,
                     timing: CAMediaTimingFunctionName = .easeInEaseOut) {
        animation.duration = duration ?? motion.duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        layer.add(animation, forKey: Self.animationKey)
        animatedLayers.append(layer)
    }

    /// Moves a view to `x` and animates it there from where it stands.
    private func move(_ view: PlatformView, toX x: CGFloat, duration: TimeInterval) {
        let from = view.frame.origin.x
        view.frame.origin.x = x
        guard let layer = view.backingLayer else { return }
        let animation = CABasicAnimation(keyPath: "position")
        animation.isAdditive = true
        animation.fromValue = CGPoint(x: from - x, y: 0)
        animation.toValue = CGPoint.zero
        add(animation, to: layer, duration: duration, timing: .easeOut)
    }

    private func fade(_ view: PlatformView, to opacity: CGFloat, duration: TimeInterval) {
        let from = view.backingLayer?.opacity ?? 1
        view.setOpacity(opacity)
        guard let layer = view.backingLayer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = Float(opacity)
        add(animation, to: layer, duration: duration, timing: .easeOut)
    }
}

/// What the canvas draws over its columns while a page turns, and the pictures and pages in it.
/// Touches and clicks pass through it, and no assistive technology finds it or anything in it:
/// what VoiceOver reads is the canvas's columns, as with no animation.
@MainActor final class ReaderPageTransitionView: PlatformView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(iOS)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        #else
        wantsLayer = true
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
        #endif
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { nil }
    #endif

    func setBackground(_ color: PlatformColor) {
        #if os(iOS)
        backgroundColor = color
        #else
        layer?.backgroundColor = color.cgColor
        #endif
    }
}

fileprivate extension PlatformView {
    /// The view's opacity, as UIKit's alpha and AppKit's alpha value both set it.
    func setOpacity(_ opacity: CGFloat) {
        #if os(iOS)
        alpha = opacity
        #else
        alphaValue = opacity
        #endif
    }

    /// The layer that draws the view: UIKit's always, AppKit's once the view is layer-backed.
    var backingLayer: CALayer? { layer }
}
