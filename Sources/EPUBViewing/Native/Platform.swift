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
    var isDark: Bool
    init(fontSize: CGFloat = 17, isDark: Bool = false) {
        self.fontSize = min(max(fontSize, Self.minimumFontSize), Self.maximumFontSize)
        self.isDark = isDark
    }
}

/// The reader's own colors. Book colors apply in light appearance only; dark appearance uses
/// these throughout, as the WebKit reader's `Canvas`/`CanvasText`/`LinkText` override did.
enum ReaderPalette {
    static func background(dark: Bool) -> PlatformColor { dark ? .black : .white }
    static func text(dark: Bool) -> PlatformColor {
        dark ? PlatformColor(white: 0.92, alpha: 1) : .black
    }
    static func secondaryText(dark: Bool) -> PlatformColor {
        dark ? PlatformColor(white: 0.62, alpha: 1) : PlatformColor(white: 0.38, alpha: 1)
    }
    static func link(dark: Bool) -> PlatformColor {
        dark ? PlatformColor(red: 0.45, green: 0.68, blue: 1, alpha: 1) : PlatformColor(red: 0, green: 0.36, blue: 0.85, alpha: 1)
    }
    static func rule(dark: Bool) -> PlatformColor {
        dark ? PlatformColor(white: 0.35, alpha: 1) : PlatformColor(white: 0.75, alpha: 1)
    }
    /// Search matches (`searchHighlight`).
    static func searchHighlight(dark: Bool) -> PlatformColor {
        dark ? PlatformColor(red: 0.55, green: 0.42, blue: 0, alpha: 0.6) : PlatformColor(red: 1, green: 0.83, blue: 0.2, alpha: 0.45)
    }
    /// Host highlights (`setHighlights`) in the default style, yellow.
    static func annotationHighlight(dark: Bool) -> PlatformColor { highlight(EPUBHighlightColor.yellow, dark: dark) }
    /// The search result last shown: darker than the other matches as well as a different
    /// hue, so it stands apart without relying on color alone.
    static func currentSearchHighlight(dark: Bool) -> PlatformColor {
        dark ? PlatformColor(red: 0.85, green: 0.35, blue: 0, alpha: 0.7) : PlatformColor(red: 1, green: 0.58, blue: 0.1, alpha: 0.7)
    }
    static func highlight(_ kind: ReaderHighlight.Kind, dark: Bool) -> PlatformColor {
        switch kind {
        case .search: searchHighlight(dark: dark)
        case .annotation: annotationHighlight(dark: dark)
        case .currentSearch: currentSearchHighlight(dark: dark)
        }
    }

    /// A host highlight's fill, in sRGB, and its opacity over the page: a pale shade of its
    /// color on a light page and a deep one on a dark page. Over the reader's own page and text
    /// colors the text keeps 4.5:1 or more (WCAG 2.2), at least 14:1 on a light page and 8:1 on
    /// a dark one (`HighlightStyleTests`). Yellow is the fill every host highlight had before
    /// styles.
    static func highlightFill(_ color: EPUBHighlightColor, dark: Bool) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        switch (color, dark) {
        case (.yellow, false): (1, 0.9, 0.3, 0.55)
        case (.green, false): (0.35, 0.85, 0.4, 0.45)
        case (.blue, false): (0.35, 0.65, 1, 0.4)
        case (.pink, false): (1, 0.45, 0.65, 0.4)
        case (.purple, false): (0.7, 0.5, 1, 0.4)
        case (.yellow, true): (0.9, 0.75, 0.1, 0.35)
        case (.green, true): (0.2, 0.7, 0.3, 0.4)
        case (.blue, true): (0.25, 0.5, 1, 0.45)
        case (.pink, true): (0.95, 0.3, 0.55, 0.4)
        case (.purple, true): (0.6, 0.4, 1, 0.45)
        }
    }

    /// The line a highlight's mark draws, opaque, in sRGB: a dark shade of its color on a light
    /// page and a light one on a dark page, 3:1 or more against the fill it is drawn over, as
    /// WCAG 2.2 asks of a graphic that carries meaning (success criterion 1.4.11).
    static func highlightMark(_ color: EPUBHighlightColor, dark: Bool) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch (color, dark) {
        case (.yellow, false): (0.55, 0.42, 0)
        case (.green, false): (0.1, 0.45, 0.15)
        case (.blue, false): (0.1, 0.33, 0.75)
        case (.pink, false): (0.7, 0.1, 0.38)
        case (.purple, false): (0.42, 0.2, 0.72)
        case (.yellow, true): (1, 0.85, 0.35)
        case (.green, true): (0.5, 0.9, 0.55)
        case (.blue, true): (0.6, 0.78, 1)
        case (.pink, true): (1, 0.62, 0.78)
        case (.purple, true): (0.8, 0.68, 1)
        }
    }

    static func highlight(_ color: EPUBHighlightColor, dark: Bool) -> PlatformColor {
        let fill = highlightFill(color, dark: dark)
        return PlatformColor(red: fill.red, green: fill.green, blue: fill.blue, alpha: fill.alpha)
    }

    static func mark(_ color: EPUBHighlightColor, dark: Bool) -> PlatformColor {
        let mark = highlightMark(color, dark: dark)
        return PlatformColor(red: mark.red, green: mark.green, blue: mark.blue, alpha: 1)
    }

    /// What `highlight` draws. A host highlight without a style is drawn in the default one.
    static func paint(_ highlight: ReaderHighlight, dark: Bool) -> ReaderHighlightPaint {
        guard highlight.kind == .annotation else { return ReaderHighlightPaint(fill: self.highlight(highlight.kind, dark: dark)) }
        let style = highlight.style ?? EPUBHighlightStyle()
        return ReaderHighlightPaint(fill: self.highlight(style.color, dark: dark), replacesMarks: true,
                                    mark: style.mark.map { ($0, mark(style.color, dark: dark)) })
    }
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
