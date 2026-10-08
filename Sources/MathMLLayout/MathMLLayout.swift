import CoreGraphics
import Foundation

// SKELETON: public surface of the native MathML layout engine. Independent of EPUB: no import of
// any EPUBLib module, so it can move to its own package. The math workstream implements it.

/// A presentation-MathML element, independent of any XML parser. Token elements (`mi`, `mn`,
/// `mo`, `mtext`, `ms`) carry their character data in `text`; other elements in `children`.
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
    public init(fontSize: CGFloat, color: CGColor, isDisplay: Bool = false) {
        self.fontSize = fontSize; self.color = color; self.isDisplay = isDisplay
    }
}

public enum MathLayoutError: Error, Equatable, Sendable {
    /// An element the engine does not lay out; callers show `alttext` instead.
    case unsupported(String)
    case limitExceeded
}

/// A laid-out formula. Immutable and thread-safe: lay out off the main thread, draw anywhere.
public final class MathLayout: @unchecked Sendable {
    /// Width, and height above (`ascent`) and below (`descent`) the baseline, in points.
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat

    public init(_ root: MathMLNode, style: MathStyle) throws {
        throw MathLayoutError.unsupported(root.name)
    }

    /// Draws with the baseline's left end at `baselineOrigin`, in a context whose y axis points up.
    public func draw(in context: CGContext, baselineOrigin: CGPoint) {}
}
