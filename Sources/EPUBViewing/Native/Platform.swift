import CoreGraphics
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
    /// Host highlights (`setHighlights`).
    static func annotationHighlight(dark: Bool) -> PlatformColor {
        dark ? PlatformColor(red: 0.9, green: 0.75, blue: 0.1, alpha: 0.35) : PlatformColor(red: 1, green: 0.9, blue: 0.3, alpha: 0.55)
    }
}
