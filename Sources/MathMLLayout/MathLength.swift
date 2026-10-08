import CoreGraphics
import Foundation

/// A parsed MathML length: a number with a unit, MathML 3 named space or pseudo-unit.
///
/// Lengths are in the caller's points, which this engine treats as CSS pixels (as Apple
/// platforms do): `1pt` is 4/3 of a point and `1in` is 96.
struct MathLength: Equatable {
    enum Unit: Equatable {
        /// Already in points.
        case points
        case em, ex
        /// Of a reference value.
        case percent
        /// A unitless multiple of a reference value (MathML 3).
        case multiple
        /// `mpadded` pseudo-units: the content's own dimensions.
        case width, height, depth
    }
    var value: CGFloat
    var unit: Unit
    /// A leading `+` or `-`: relative to the current value (`mpadded`).
    var isRelative = false

    private static let namedSpaces: [String: CGFloat] = [
        "veryverythinmathspace": 1, "verythinmathspace": 2, "thinmathspace": 3, "mediummathspace": 4,
        "thickmathspace": 5, "verythickmathspace": 6, "veryverythickmathspace": 7,
    ]
    private static let absoluteUnits: [String: CGFloat] = [
        "px": 1, "pt": 4.0 / 3, "pc": 16, "in": 96, "cm": 96 / 2.54, "mm": 9.6 / 2.54, "q": 2.4 / 2.54,
    ]

    init(value: CGFloat, unit: Unit, isRelative: Bool = false) {
        self.value = value; self.unit = unit; self.isRelative = isRelative
    }

    /// nil when the value does not parse.
    init?(_ attribute: String) {
        var text = attribute.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count < 64 else { return nil }
        if let named = Self.namedSpaces[text] { self.init(value: named / 18, unit: .em); return }
        if text.hasPrefix("negative"), let named = Self.namedSpaces[String(text.dropFirst(8))] {
            self.init(value: -named / 18, unit: .em); return
        }
        var sign: CGFloat = 1
        var relative = false
        if text.hasPrefix("+") || text.hasPrefix("-") {
            if text.hasPrefix("-") { sign = -1 }
            relative = true
            text.removeFirst()
        }
        let numberEnd = text.firstIndex { !($0.isASCII && ($0.isNumber || $0 == ".")) } ?? text.endIndex
        guard let number = Double(text[..<numberEnd]), number.isFinite else { return nil }
        let rest = text[numberEnd...].trimmingCharacters(in: .whitespaces)
        let value = sign * CGFloat(number)
        switch rest {
        case "": self.init(value: value, unit: .multiple, isRelative: relative)
        case "em": self.init(value: value, unit: .em, isRelative: relative)
        case "ex": self.init(value: value, unit: .ex, isRelative: relative)
        case "%": self.init(value: value / 100, unit: .percent, isRelative: relative)
        case "width", "%width": self.init(value: rest == "width" ? value : value / 100, unit: .width, isRelative: relative)
        case "height", "%height": self.init(value: rest == "height" ? value : value / 100, unit: .height, isRelative: relative)
        case "depth", "%depth": self.init(value: rest == "depth" ? value : value / 100, unit: .depth, isRelative: relative)
        default:
            if let scale = Self.absoluteUnits[rest] { self.init(value: value * scale, unit: .points, isRelative: relative); return }
            if rest.hasPrefix("%"), let pseudo = MathLength("\(value)\(rest.dropFirst())") {
                self.init(value: pseudo.value / 100, unit: pseudo.unit, isRelative: relative); return
            }
            return nil
        }
    }

    /// The length in points. `reference` resolves percentages and unitless multiples, and
    /// `content` (width, height, depth) resolves pseudo-units; without them those are nil.
    func resolve(em: CGFloat, ex: CGFloat, reference: CGFloat? = nil,
                 content: (width: CGFloat, height: CGFloat, depth: CGFloat)? = nil) -> CGFloat? {
        let points: CGFloat?
        switch unit {
        case .points: points = value
        case .em: points = value * em
        case .ex: points = value * ex
        case .percent, .multiple: points = reference.map { value * $0 }
        case .width: points = content.map { value * $0.width }
        case .height: points = content.map { value * $0.height }
        case .depth: points = content.map { value * $0.depth }
        }
        // Bounded, so a hostile length cannot make an enormous drawing.
        return points.map { min(max($0, -1000 * em), 1000 * em) }
    }
}

extension Dictionary where Key == String, Value == String {
    /// A MathML boolean attribute.
    func flag(_ name: String) -> Bool? {
        switch self[name]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }
}
