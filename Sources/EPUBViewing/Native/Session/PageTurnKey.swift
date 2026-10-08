import SwiftUI

enum ReaderEPUBPageTurnCommand: Equatable, Sendable {
    case next
    case previous
}

/// The page-turn keys: Left and Page Up go back, Right, Page Down and Space go forward, and
/// Shift-Space goes back. `keyCode` is the AppKit virtual key code.
enum ReaderEPUBPageTurnKey {
    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124
    private static let pageUp: UInt16 = 116
    private static let pageDown: UInt16 = 121
    private static let space: UInt16 = 49

    static func command(forKeyCode keyCode: UInt16, hasShift: Bool) -> ReaderEPUBPageTurnCommand? {
        switch keyCode {
        case leftArrow, pageUp: .previous
        case rightArrow, pageDown: .next
        case space: hasShift ? .previous : .next
        default: nil
        }
    }

    static func command(for key: KeyEquivalent, hasShift: Bool) -> ReaderEPUBPageTurnCommand? {
        switch key {
        case .leftArrow, .pageUp: .previous
        case .rightArrow, .pageDown: .next
        case .space: hasShift ? .previous : .next
        default: nil
        }
    }
}
