import CoreGraphics
import Foundation
import SwiftUI

/// Page-turn input rules shared by both platforms' text views and canvas.
enum ReaderCanvasInput {
    /// The page-turn direction (`true` forward) of a key, or nil to leave it to text selection
    /// and the system: Command, Option and Control chords (Cmd-C, Cmd-A) and Shift with
    /// anything but Space (Shift-arrow extends a selection) are never page turns.
    static func direction(for key: KeyEquivalent, shift: Bool, otherModifiers: Bool) -> Bool? {
        guard !otherModifiers, !shift || key == .space,
              let command = ReaderEPUBPageTurnKey.command(for: key, hasShift: shift) else { return nil }
        return command == .next
    }

    /// A horizontal swipe's direction: towards the left reads forward, mirrored right to left.
    static func swipeDirection(towardsLeft: Bool, isRightToLeft: Bool) -> Bool { towardsLeft != isRightToLeft }
}

/// Turns pages from wheel and trackpad scrolling in paginated flow, as the WebKit reader's
/// `bootstrap.js` did: a tick of at least 4 points turns one page, then nothing for 450 ms, so a
/// flick or its momentum turns a single page.
struct ReaderWheelPageTurner {
    static let threshold: CGFloat = 4
    static let cooldown: TimeInterval = 0.45
    private var lastTurn = -TimeInterval.infinity

    /// `deltaX`/`deltaY` follow the web's sign convention: positive scrolls right or down,
    /// towards the book's end. Returns the direction to turn, or nil.
    mutating func direction(deltaX: CGFloat, deltaY: CGFloat, isRightToLeft: Bool, at time: TimeInterval) -> Bool? {
        let horizontal = abs(deltaX) > abs(deltaY)
        let delta = horizontal ? deltaX : deltaY
        guard abs(delta) >= Self.threshold, time - lastTurn >= Self.cooldown else { return nil }
        lastTurn = time
        return (delta > 0) != (horizontal && isRightToLeft)
    }
}
