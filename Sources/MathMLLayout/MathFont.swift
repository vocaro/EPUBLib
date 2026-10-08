import CoreGraphics
import CoreText
import Foundation

/// A math font and its MATH table, shared by every layout that uses it.
///
/// Apple platforms ship STIX Two Math (SIL Open Font License 1.1): macOS in
/// `/System/Library/Fonts/Supplemental`, iOS among its Unicode-support fonts, which is also the
/// font WebKit's MathML uses there. It is not bundled. A font without a MATH table still lays
/// out, with `MathConstants.fallback` and drawn stretchy operators.
final class MathFont: @unchecked Sendable {
    /// PostScript names tried in order when the caller names no font.
    static let defaultNames = ["STIXTwoMath-Regular", "STIXTwoMath", "LatinModernMath-Regular", "CambriaMath"]
    /// The last resort when no math font is installed: a serif text font.
    static let fallbackName = "TimesNewRomanPSMT"

    /// The font at 1 point. CTFont is immutable and thread-safe.
    let base: CTFont
    let table: MathTable?
    var constants: MathConstants { table?.constants ?? .fallback }
    let unitsPerEm: CGFloat
    private let lock = NSLock()
    private var sized: [CGFloat: CTFont] = [:]

    private init(base: CTFont) {
        self.base = base
        unitsPerEm = CGFloat(CTFontGetUnitsPerEm(base))
        if let data = CTFontCopyTable(base, CTFontTableTag(kCTFontTableMATH), []) {
            table = MathTable(data: [UInt8](data as Data), unitsPerEm: unitsPerEm)
        } else { table = nil }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: MathFont] = [:]

    /// The named font when it is installed (an exact PostScript-name match), else the platform's
    /// math font, else a serif fallback.
    static func named(_ name: String?) -> MathFont {
        let key = name ?? ""
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let font = cache[key] { return font }
        let candidates = (name.map { [$0] } ?? []) + defaultNames + [fallbackName]
        var chosen: CTFont?
        for candidate in candidates {
            let font = CTFontCreateWithName(candidate as CFString, 1, nil)
            if CTFontCopyPostScriptName(font) as String == candidate { chosen = font; break }
        }
        let font = MathFont(base: chosen ?? CTFontCreateWithName(fallbackName as CFString, 1, nil))
        if cache.count > 16 { cache.removeAll() }
        cache[key] = font
        return font
    }

    /// The font at `size` points; with `scriptLevel` 1 or 2 its OpenType `ssty` script forms on.
    func font(size: CGFloat, scriptLevel: Int = 0) -> CTFont {
        let level = min(max(scriptLevel, 0), 2)
        let key = (size * 64).rounded() / 64 + CGFloat(level) * 100_000
        lock.lock(); defer { lock.unlock() }
        if let font = sized[key] { return font }
        var font = CTFontCreateCopyWithAttributes(base, size, nil, nil)
        if level > 0, table != nil {
            let feature: [CFString: Any] = [kCTFontOpenTypeFeatureTag: "ssty", kCTFontOpenTypeFeatureValue: level]
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: [feature]] as CFDictionary)
            font = CTFontCreateCopyWithAttributes(font, size, nil, descriptor)
        }
        if sized.count > 128 { sized.removeAll() }
        sized[key] = font
        return font
    }

    /// The font's glyph for one Unicode scalar, or nil when the font lacks it.
    func glyph(for scalar: Unicode.Scalar) -> CGGlyph? {
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(base, &units, &glyphs, units.count), glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }

    /// A design-unit measurement in points at `size`.
    func points(_ designUnits: CGFloat, size: CGFloat) -> CGFloat { designUnits * size / unitsPerEm }
}
