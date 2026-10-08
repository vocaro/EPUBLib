import Foundation

/// A `mathvariant`: a style drawn with the Mathematical Alphanumeric Symbols block
/// (U+1D400–U+1D7FF) and the Letterlike Symbols that fill its holes, as MathML Core does.
enum MathVariant: String, Sendable {
    case normal, bold, italic, boldItalic = "bold-italic", doubleStruck = "double-struck"
    case boldFraktur = "bold-fraktur", script, boldScript = "bold-script", fraktur
    case sansSerif = "sans-serif", boldSansSerif = "bold-sans-serif"
    case sansSerifItalic = "sans-serif-italic", sansSerifBoldItalic = "sans-serif-bold-italic"
    case monospace
    // MathML 3 values without a Unicode style map to the nearest that has one.
    case initial, tailed, looped, stretched

    init?(attribute: String) {
        self.init(rawValue: attribute.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Start of the 52 Latin letters (A–Z, a–z) in this style.
    private var latin: UInt32? {
        switch self {
        case .bold: 0x1D400
        case .italic: 0x1D434
        case .boldItalic: 0x1D468
        case .script: 0x1D49C
        case .boldScript: 0x1D4D0
        case .fraktur: 0x1D504
        case .doubleStruck: 0x1D538
        case .boldFraktur: 0x1D56C
        case .sansSerif: 0x1D5A0
        case .boldSansSerif: 0x1D5D4
        case .sansSerifItalic: 0x1D608
        case .sansSerifBoldItalic: 0x1D63C
        case .monospace: 0x1D670
        default: nil
        }
    }

    /// Start of the 58 Greek symbols (Α–Ω, ϴ, ∇, α–ω, ∂, ϵ, ϑ, ϰ, ϕ, ϱ, ϖ).
    private var greek: UInt32? {
        switch self {
        case .bold: 0x1D6A8
        case .italic: 0x1D6E2
        case .boldItalic: 0x1D71C
        case .boldSansSerif: 0x1D756
        case .sansSerifBoldItalic: 0x1D790
        default: nil
        }
    }

    private var digits: UInt32? {
        switch self {
        case .bold: 0x1D7CE
        case .doubleStruck: 0x1D7D8
        case .sansSerif: 0x1D7E2
        case .boldSansSerif: 0x1D7EC
        case .monospace: 0x1D7F6
        default: nil
        }
    }

    /// Letterlike Symbols that take the place of reserved code points in the block.
    private static let holes: [UInt32: UInt32] = [
        0x1D455: 0x210E, // italic h
        0x1D49D: 0x212C, 0x1D4A0: 0x2130, 0x1D4A1: 0x2131, 0x1D4A3: 0x210B, 0x1D4A4: 0x2110,
        0x1D4A7: 0x2112, 0x1D4A8: 0x2133, 0x1D4AD: 0x211B, 0x1D4BA: 0x212F, 0x1D4BC: 0x210A,
        0x1D4C4: 0x2134, // script B E F H I L M R e g o
        0x1D506: 0x212D, 0x1D50B: 0x210C, 0x1D50C: 0x2111, 0x1D515: 0x211C, 0x1D51D: 0x2128, // fraktur C H I R Z
        0x1D53A: 0x2102, 0x1D53F: 0x210D, 0x1D545: 0x2115, 0x1D547: 0x2119, 0x1D548: 0x211A,
        0x1D549: 0x211D, 0x1D551: 0x2124, // double-struck C H N P Q R Z
    ]

    /// Greek code points in the order of the block's 58-symbol runs.
    private static func greekIndex(_ value: UInt32) -> UInt32? {
        switch value {
        case 0x391...0x3A9 where value != 0x3A2: value - 0x391
        case 0x3F4: 17 // ϴ
        case 0x2207: 25 // ∇
        case 0x3B1...0x3C9: 26 + value - 0x3B1
        case 0x2202: 51 // ∂
        case 0x3F5: 52
        case 0x3D1: 53
        case 0x3F0: 54
        case 0x3D5: 55
        case 0x3F1: 56
        case 0x3D6: 57
        default: nil
        }
    }

    func apply(to scalar: Unicode.Scalar) -> Unicode.Scalar {
        let value = scalar.value
        var mapped: UInt32?
        switch value {
        case 0x41...0x5A: mapped = latin.map { $0 + value - 0x41 }
        case 0x61...0x7A: mapped = latin.map { $0 + 26 + value - 0x61 }
        case 0x30...0x39: mapped = digits.map { $0 + value - 0x30 }
        case 0x131 where self == .italic: mapped = 0x1D6A4 // dotless i
        case 0x237 where self == .italic: mapped = 0x1D6A5 // dotless j
        default:
            if let index = Self.greekIndex(value) { mapped = greek.map { $0 + index } }
        }
        guard let mapped else { return scalar }
        return Unicode.Scalar(Self.holes[mapped] ?? mapped) ?? scalar
    }

    func apply(to text: String) -> String {
        guard self != .normal else { return text }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: text.unicodeScalars.map(apply(to:)))
        return String(result)
    }
}
