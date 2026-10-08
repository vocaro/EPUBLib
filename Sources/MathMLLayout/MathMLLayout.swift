import CoreGraphics
import Foundation

// MathMLLayout lays out presentation MathML with CoreText and an OpenType MATH font. It is
// independent of EPUB and of any UI framework, so it can move to its own package.

/// A presentation-MathML element, independent of any XML parser. Token elements (`mi`, `mn`,
/// `mo`, `mtext`, `ms`) carry their character data in `text`, and their element children (an
/// `mglyph`, say) only by name; other elements carry their content in `children`.
public struct MathMLNode: Equatable, Sendable {
    /// Local name in the MathML namespace, e.g. `mfrac`.
    public var name: String
    /// Attributes by local name.
    public var attributes: [String: String]
    public var children: [MathMLNode]
    public var text: String
    public init(name: String, attributes: [String: String] = [:], children: [MathMLNode] = [], text: String = "") {
        self.name = name; self.attributes = attributes; self.children = children; self.text = text
    }
}

public struct MathStyle: Equatable, Sendable {
    /// The surrounding text's font size, in points.
    public var fontSize: CGFloat
    public var color: CGColor
    /// `display="block"` (or `displaystyle="true"` at the root).
    public var isDisplay: Bool
    /// PostScript name of an OpenType MATH font. nil, or a font that is not installed, uses
    /// the platform's STIX Two Math.
    public var fontName: String?
    public init(fontSize: CGFloat, color: CGColor, isDisplay: Bool = false, fontName: String? = nil) {
        self.fontSize = fontSize; self.color = color; self.isDisplay = isDisplay; self.fontName = fontName
    }
}

public enum MathLayoutError: Error, Equatable, Sendable {
    /// An element the engine does not lay out; callers show `alttext` instead.
    case unsupported(String)
    /// Deeper, larger or longer than the engine's bounds on untrusted input.
    case limitExceeded
    /// Markup that is not MathML the engine can read: an element with the wrong number of
    /// children, or XML that does not parse.
    case invalidMarkup(String)
}

/// A laid-out formula. Immutable and thread-safe: lay out off the main thread, draw anywhere.
///
/// Its box covers everything it draws, so a host may clip to it.
public final class MathLayout: @unchecked Sendable {
    // Unchecked: the box tree is never mutated after init, and the CoreText fonts and
    // CoreGraphics paths it holds are immutable and thread-safe.

    /// Width, and height above (`ascent`) and below (`descent`) the baseline, in points.
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    private let box: MathBox

    /// Lays out `root`, usually a `math` element (whose `display="block"` also selects display
    /// style). Throws `unsupported` for elements outside presentation MathML's common subset.
    public init(_ root: MathMLNode, style: MathStyle) throws {
        box = try LayoutEngine(fontName: style.fontName).layoutRoot(root, style: style)
        width = box.width; ascent = box.ascent; descent = box.descent
    }

    /// Draws with the baseline's left end at `baselineOrigin`, in a context whose y axis points up.
    public func draw(in context: CGContext, baselineOrigin: CGPoint) {
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        box.draw(in: context, at: baselineOrigin)
    }
}
