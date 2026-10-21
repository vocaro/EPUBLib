import Foundation

/// An element ID, or a name a URL fragment can point to, compared and hashed code unit for code
/// unit, as `getElementById`, a fragment, a CSS `#id` selector and an SVG reference compare it.
/// `String` compares by canonical equivalence, under which `caf\u{E9}` and `cafe\u{301}` are equal,
/// so a table keyed by `String` would hold one of two elements the DOM tells apart. IDs sort by
/// their code units too.
public struct EPUBElementID: Hashable, Comparable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let string: String
    public init(_ string: String) { self.string = string }
    public init(stringLiteral string: String) { self.string = string }
    public var description: String { string }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.string.utf8.elementsEqual(rhs.string.utf8) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.string.utf8.lexicographicallyPrecedes(rhs.string.utf8) }

    public func hash(into hasher: inout Hasher) {
        var string = string
        string.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}

extension Dictionary where Key == EPUBElementID {
    /// The value under the ID with these code units.
    public subscript(_ id: String) -> Value? {
        get { self[EPUBElementID(id)] }
        set { self[EPUBElementID(id)] = newValue }
    }
}
