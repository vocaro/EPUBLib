import SwiftUI

/// How the bundled native reader moves from one page to the next in paginated flow. Choose one
/// for a mounted view with `epubReaderPageTurnAnimation(_:)`; no book reload or change of
/// reading state is needed. Continuous scroll scrolls as before whichever is chosen.
///
/// Every page turn has it: a tap or click at an edge, a swipe, a key, the wheel or trackpad,
/// VoiceOver's own turns and the host's `.nextPage` and `.previousPage`. A swipe on iPhone and
/// iPad, and a trackpad's swipe on Mac, follows the fingers, and is put back when let go short
/// of a turn. With Reduce Motion on, a turn never slides: `slide` dissolves instead.
public struct EPUBPageTurnAnimation: Hashable, Sendable {
    enum Style: Hashable, Sendable { case none, slide, dissolve }
    let style: Style

    /// One page replaces the other at once. The default.
    public static let none = Self(style: .none)
    /// The page slides away and the next slides in beside it, from the side the book reads
    /// towards: from the right in a book read left to right, from the left in one read right to
    /// left. Under Reduce Motion it dissolves instead.
    public static let slide = Self(style: .slide)
    /// The page dissolves into the next, with no movement; also the slide's form under Reduce
    /// Motion.
    public static let dissolve = Self(style: .dissolve)
}

public extension View {
    /// Chooses how the native reader turns a page in paginated flow, including live updates.
    /// Apply it to the retained `EPUBReaderView`, or a common ancestor of it.
    func epubReaderPageTurnAnimation(_ animation: EPUBPageTurnAnimation) -> some View {
        environment(\.epubReaderPageTurnAnimation, animation)
    }
}

extension EnvironmentValues {
    @Entry var epubReaderPageTurnAnimation = EPUBPageTurnAnimation.none
}
