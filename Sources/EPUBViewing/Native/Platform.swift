import CoreGraphics
import EPUBCore
#if os(iOS)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
typealias PlatformView = UIView
typealias PlatformFontDescriptor = UIFontDescriptor
#elseif os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
typealias PlatformView = NSView
typealias PlatformFontDescriptor = NSFontDescriptor
#endif

/// The reader's own typography: the host's chosen size and appearance. A section is built for one
/// value; changing either rebuilds the text but never changes its characters, so rendered
/// locations stay valid across rebuilds.
struct NativeTypography: Equatable, Hashable, Sendable {
    static let minimumFontSize: CGFloat = 12
    static let maximumFontSize: CGFloat = 96
    /// Base size in points, clamped to 12–96. CSS `1em` at the root is this size.
    var fontSize: CGFloat
    /// The theme's background is dark (`ReaderTheme.isDark`).
    var isDark: Bool { theme.isDark }
    /// The colours the text is drawn in.
    var theme: ReaderTheme
    /// The system's Bold Text: book text is drawn heavier (`ComputedStyle.usesBoldText`).
    var boldText = false
    init(fontSize: CGFloat = 17, isDark: Bool = false) {
        self.init(fontSize: fontSize, theme: isDark ? .dark : .light)
    }
    init(fontSize: CGFloat = 17, theme: ReaderTheme, boldText: Bool = false) {
        self.fontSize = min(max(fontSize, Self.minimumFontSize), Self.maximumFontSize)
        self.theme = theme
        self.boldText = boldText
    }

    /// The host's font, spacing, alignment and hyphenation (`ReaderTextSettings`).
    var text = ReaderTextSettings()
}

/// The reader's own colors in Light and Dark (`ReaderTheme.light`, `ReaderTheme.dark`). Book
/// colors apply in a light theme only; a dark one uses its own throughout, as the WebKit
/// reader's `Canvas`/`CanvasText`/`LinkText` override did.
enum ReaderPalette {
    private static func theme(_ dark: Bool) -> ReaderTheme { dark ? .dark : .light }
    static func background(dark: Bool) -> PlatformColor { theme(dark).background }
    static func text(dark: Bool) -> PlatformColor { theme(dark).text }
    static func secondaryText(dark: Bool) -> PlatformColor { theme(dark).secondaryText }
    static func link(dark: Bool) -> PlatformColor { theme(dark).link }
    static func rule(dark: Bool) -> PlatformColor { theme(dark).rule }
    /// Search matches (`searchHighlight`).
    static func searchHighlight(dark: Bool) -> PlatformColor { theme(dark).highlight(.search) }
    /// Host highlights (`setHighlights`) in the default style, yellow.
    static func annotationHighlight(dark: Bool) -> PlatformColor { theme(dark).highlight(.annotation) }
    /// The search result last shown: darker than the other matches as well as a different
    /// hue, so it stands apart without relying on color alone.
    static func currentSearchHighlight(dark: Bool) -> PlatformColor { theme(dark).highlight(.currentSearch) }
    static func highlight(_ kind: ReaderHighlight.Kind, dark: Bool) -> PlatformColor { theme(dark).highlight(kind) }
    /// A host highlight's fill in a style of `color` (`ReaderTheme.highlight(_:)`).
    static func highlight(_ color: EPUBHighlightColor, dark: Bool) -> PlatformColor { theme(dark).highlight(color) }
    /// The line of a host highlight's mark in a style of `color` (`ReaderTheme.mark(_:)`).
    static func mark(_ color: EPUBHighlightColor, dark: Bool) -> PlatformColor { theme(dark).mark(color) }
}

/// What a highlight draws over its characters: a fill, and for a host highlight the mark of its
/// style, or none. A word shows the last highlight drawn on it, so a host highlight takes the
/// place of the mark of one beneath it, with its own or with none. A search match is a fill
/// alone and leaves the mark beneath it as it is.
struct ReaderHighlightPaint {
    var fill: PlatformColor
    var replacesMarks = false
    var mark: (style: EPUBHighlightMark, color: PlatformColor)?
}
