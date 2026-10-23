import Foundation

/// An opaque colour in sRGB, each component 0–1.
public struct EPUBReaderColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    /// Components outside 0–1 are clamped to it, and a component that is not a number is 0.
    public init(red: Double, green: Double, blue: Double) {
        func clamped(_ value: Double) -> Double { value.isNaN ? 0 : min(max(value, 0), 1) }
        self.red = clamped(red); self.green = clamped(green); self.blue = clamped(blue)
    }

    /// `#RRGGBB` or `RRGGBB`, in either case; nil for anything else.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// `#RRGGBB`, each component rounded to the nearest of 256 steps.
    public var hex: String {
        func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// WCAG 2.2's relative luminance: 0 for black, 1 for white.
    public var relativeLuminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.2's contrast ratio between this colour and `other`, from 1 to 21 whichever is lighter.
    public func contrastRatio(to other: EPUBReaderColor) -> Double {
        let (one, two) = (relativeLuminance, other.relativeLuminance)
        return (max(one, two) + 0.05) / (min(one, two) + 0.05)
    }

    /// This colour moved `fraction` of the way to `other`, component by component.
    public func mixed(with other: EPUBReaderColor, by fraction: Double) -> EPUBReaderColor {
        let amount = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
        return EPUBReaderColor(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                               blue: blue + (other.blue - blue) * amount)
    }

    public static let black = EPUBReaderColor(red: 0, green: 0, blue: 0)
    public static let white = EPUBReaderColor(red: 1, green: 1, blue: 1)
}

/// A reading theme's colours: the page, its text and its links.
///
/// A theme whose background is dark (`isDark`) draws as Dark does: the book's own colours and
/// backgrounds give way to the theme's, and a transparent image of dark line art is drawn on a
/// white backdrop. A light theme draws the colours a book sets for itself, as Light does, and
/// the theme's where the book sets none.
public struct EPUBReaderColors: Codable, Hashable, Sendable {
    public var background: EPUBReaderColor
    public var text: EPUBReaderColor
    public var link: EPUBReaderColor

    public init(background: EPUBReaderColor, text: EPUBReaderColor, link: EPUBReaderColor) {
        self.background = background; self.text = text; self.link = link
    }

    /// Black text on white.
    public static let light = EPUBReaderColors(background: .white, text: .black,
                                               link: EPUBReaderColor(red: 0, green: 0.36, blue: 0.85))
    /// Light grey text on the dark grey of a raised surface in iOS's own dark appearance.
    public static let dark = EPUBReaderColors(background: EPUBReaderColor(red: 28.0 / 255, green: 28.0 / 255, blue: 30.0 / 255),
                                              text: EPUBReaderColor(red: 0.92, green: 0.92, blue: 0.92),
                                              link: EPUBReaderColor(red: 0.45, green: 0.68, blue: 1))
    /// Dark brown text on warm paper.
    public static let sepia = EPUBReaderColors(background: EPUBReaderColor(hex: "#FBF0D9")!,
                                               text: EPUBReaderColor(hex: "#5F4B32")!,
                                               link: EPUBReaderColor(hex: "#1F5A9E")!)
    /// Light grey text on pure black, which an OLED screen leaves unlit.
    public static let black = EPUBReaderColors(background: .black, text: EPUBReaderColor(red: 0.92, green: 0.92, blue: 0.92),
                                               link: EPUBReaderColor(red: 0.45, green: 0.68, blue: 1))

    /// The background is dark: white has more contrast with it than black has. That is a
    /// relative luminance below about 0.18.
    public var isDark: Bool {
        background.contrastRatio(to: .white) > background.contrastRatio(to: .black)
    }

    /// The contrast WCAG 2.2 calls enhanced (success criterion 1.4.6), which text and links
    /// reach with Increase Contrast on wherever the background allows.
    public static let enhancedContrast = 7.0

    /// These colours as the reader draws them with Increase Contrast on. The background is the
    /// same; the text and the links are moved toward black on a light background, or white on
    /// a dark one, half the way there and further if they still fall short of 7:1
    /// (`enhancedContrast`). Only black or white text, already as far from the background as it
    /// can be, stays as it is.
    public var increasingContrast: EPUBReaderColors {
        EPUBReaderColors(background: background, text: Self.increasingContrast(of: text, on: background, dark: isDark),
                         link: Self.increasingContrast(of: link, on: background, dark: isDark))
    }

    private static func increasingContrast(of color: EPUBReaderColor, on background: EPUBReaderColor, dark: Bool) -> EPUBReaderColor {
        let extreme: EPUBReaderColor = dark ? .white : .black
        var fraction = 0.5
        var result = color.mixed(with: extreme, by: fraction)
        while result.contrastRatio(to: background) < enhancedContrast, fraction < 1 {
            fraction = min(1, fraction + 1.0 / 64)
            result = color.mixed(with: extreme, by: fraction)
        }
        return result
    }
}

public extension EPUBReaderStyle {
    /// The colours this style's appearance draws with, before Increase Contrast. System is
    /// Dark's when `systemIsDark`, the mounted view's colour scheme, and Light's otherwise.
    func colors(systemIsDark: Bool) -> EPUBReaderColors {
        switch appearance {
        case .system: systemIsDark ? .dark : .light
        case .light: .light
        case .dark: .dark
        case .sepia: .sepia
        case .black: .black
        case .custom: customColors ?? .light
        }
    }
}
