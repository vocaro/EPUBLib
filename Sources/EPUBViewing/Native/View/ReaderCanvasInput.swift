import CoreGraphics
import Foundation

/// Page-turn input rules shared by both platforms' text views and canvas.
enum ReaderCanvasInput {
    /// A horizontal swipe's direction: towards the left reads forward, mirrored right to left.
    static func swipeDirection(towardsLeft: Bool, isRightToLeft: Bool) -> Bool { towardsLeft != isRightToLeft }
}

/// Turns pages from wheel and trackpad scrolling in paginated flow: one page per trackpad
/// gesture once it has moved 4 points (its momentum ignored), and for a phaseless mouse wheel a
/// tick of at least 4 points, then nothing for 450 ms, as the WebKit reader's `bootstrap.js` did.
/// A line-based wheel's lines are 40 points (`points(lines:)`), so one notch is a tick.
struct ReaderWheelPageTurner {
    static let threshold: CGFloat = 4
    static let cooldown: TimeInterval = 0.45
    /// WebKit's and Chromium's line step. One notch of a notched wheel turned slowly is a tenth
    /// of a line, which at this step is the threshold (#163).
    static let pointsPerLine: CGFloat = 40

    /// A line-based wheel's movement in points. AppKit gives lines in 16.16 fixed point, in which
    /// a tenth is 0.09999; to the nearest hundredth of a line it is a tenth again.
    static func points(lines: CGFloat) -> CGFloat { (lines * 100).rounded() * pointsPerLine / 100 }

    /// Where a scroll event is in a trackpad gesture.
    enum Phase: Sendable {
        /// A mouse wheel or other device without gestures.
        case none
        case began, changed, ended
        /// Momentum after the fingers lift.
        case momentum
    }

    private var lastTurn = -TimeInterval.infinity
    private var gestureTurned = false
    private var gestureDelta = CGVector.zero

    /// The trackpad gesture under way has turned its page, or been taken for a swipe the page
    /// follows (`takeGesture`): the rest of it turns nothing.
    var gestureHasTurned: Bool { gestureTurned }

    /// The trackpad gesture under way is a swipe the page follows, which turns the page itself.
    mutating func takeGesture() { gestureTurned = true }

    /// `deltaX`/`deltaY` follow the web's sign convention: positive scrolls right or down,
    /// towards the book's end. Returns the direction to turn, or nil.
    mutating func direction(deltaX: CGFloat, deltaY: CGFloat, phase: Phase = .none, isRightToLeft: Bool,
                            at time: TimeInterval) -> Bool? {
        switch phase {
        case .momentum:
            return nil
        case .ended:
            gestureTurned = false
            gestureDelta = .zero
            return nil
        case .began, .changed:
            if phase == .began { gestureTurned = false; gestureDelta = .zero }
            guard !gestureTurned else { return nil }
            gestureDelta.dx += deltaX
            gestureDelta.dy += deltaY
            guard let forward = Self.direction(gestureDelta.dx, gestureDelta.dy, isRightToLeft: isRightToLeft) else { return nil }
            gestureTurned = true
            lastTurn = time
            return forward
        case .none:
            guard time - lastTurn >= Self.cooldown,
                  let forward = Self.direction(deltaX, deltaY, isRightToLeft: isRightToLeft) else { return nil }
            lastTurn = time
            return forward
        }
    }

    private static func direction(_ deltaX: CGFloat, _ deltaY: CGFloat, isRightToLeft: Bool) -> Bool? {
        let horizontal = abs(deltaX) > abs(deltaY)
        let delta = horizontal ? deltaX : deltaY
        guard abs(delta) >= threshold else { return nil }
        return (delta > 0) != (horizontal && isRightToLeft)
    }
}
