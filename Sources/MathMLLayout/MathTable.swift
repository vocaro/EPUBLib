import CoreGraphics

/// The layout constants of an OpenType MATH table, in ems of the font size.
///
/// Field names follow the MathConstants table of the OpenType specification
/// (https://learn.microsoft.com/typography/opentype/spec/math). Fonts without a MATH table get
/// `fallback`, values close to Latin Modern Math's, so layout still works with any font.
struct MathConstants: Sendable {
    var scriptPercentScaleDown: CGFloat = 70
    var scriptScriptPercentScaleDown: CGFloat = 50
    var delimitedSubFormulaMinHeight: CGFloat = 1.3
    var displayOperatorMinHeight: CGFloat = 1.3
    var mathLeading: CGFloat = 0.154
    var axisHeight: CGFloat = 0.25
    var accentBaseHeight: CGFloat = 0.45
    var flattenedAccentBaseHeight: CGFloat = 0.664
    var subscriptShiftDown: CGFloat = 0.247
    var subscriptTopMax: CGFloat = 0.344
    var subscriptBaselineDropMin: CGFloat = 0.2
    var superscriptShiftUp: CGFloat = 0.363
    var superscriptShiftUpCramped: CGFloat = 0.289
    var superscriptBottomMin: CGFloat = 0.108
    var superscriptBaselineDropMax: CGFloat = 0.25
    var subSuperscriptGapMin: CGFloat = 0.16
    var superscriptBottomMaxWithSubscript: CGFloat = 0.344
    var spaceAfterScript: CGFloat = 0.056
    var upperLimitGapMin: CGFloat = 0.2
    var upperLimitBaselineRiseMin: CGFloat = 0.111
    var lowerLimitGapMin: CGFloat = 0.167
    var lowerLimitBaselineDropMin: CGFloat = 0.6
    var stackTopShiftUp: CGFloat = 0.444
    var stackTopDisplayStyleShiftUp: CGFloat = 0.677
    var stackBottomShiftDown: CGFloat = 0.345
    var stackBottomDisplayStyleShiftDown: CGFloat = 0.686
    var stackGapMin: CGFloat = 0.12
    var stackDisplayStyleGapMin: CGFloat = 0.28
    var stretchStackTopShiftUp: CGFloat = 0.111
    var stretchStackBottomShiftDown: CGFloat = 0.6
    var stretchStackGapAboveMin: CGFloat = 0.2
    var stretchStackGapBelowMin: CGFloat = 0.167
    var fractionNumeratorShiftUp: CGFloat = 0.394
    var fractionNumeratorDisplayStyleShiftUp: CGFloat = 0.677
    var fractionDenominatorShiftDown: CGFloat = 0.345
    var fractionDenominatorDisplayStyleShiftDown: CGFloat = 0.686
    var fractionNumeratorGapMin: CGFloat = 0.04
    var fractionNumDisplayStyleGapMin: CGFloat = 0.12
    var fractionRuleThickness: CGFloat = 0.04
    var fractionDenominatorGapMin: CGFloat = 0.04
    var fractionDenomDisplayStyleGapMin: CGFloat = 0.12
    var skewedFractionHorizontalGap: CGFloat = 0.35
    var skewedFractionVerticalGap: CGFloat = 0.096
    var overbarVerticalGap: CGFloat = 0.12
    var overbarRuleThickness: CGFloat = 0.04
    var overbarExtraAscender: CGFloat = 0.04
    var underbarVerticalGap: CGFloat = 0.12
    var underbarRuleThickness: CGFloat = 0.04
    var underbarExtraDescender: CGFloat = 0.04
    var radicalVerticalGap: CGFloat = 0.05
    var radicalDisplayStyleVerticalGap: CGFloat = 0.148
    var radicalRuleThickness: CGFloat = 0.04
    var radicalExtraAscender: CGFloat = 0.04
    var radicalKernBeforeDegree: CGFloat = 0.278
    var radicalKernAfterDegree: CGFloat = -0.556
    var radicalDegreeBottomRaisePercent: CGFloat = 60

    static let fallback = MathConstants()

    /// The MathValueRecords in table order, after the four leading integer fields.
    nonisolated(unsafe) private static let recordFields: [WritableKeyPath<MathConstants, CGFloat>] = [
        \.mathLeading, \.axisHeight, \.accentBaseHeight, \.flattenedAccentBaseHeight,
        \.subscriptShiftDown, \.subscriptTopMax, \.subscriptBaselineDropMin, \.superscriptShiftUp,
        \.superscriptShiftUpCramped, \.superscriptBottomMin, \.superscriptBaselineDropMax,
        \.subSuperscriptGapMin, \.superscriptBottomMaxWithSubscript, \.spaceAfterScript,
        \.upperLimitGapMin, \.upperLimitBaselineRiseMin, \.lowerLimitGapMin, \.lowerLimitBaselineDropMin,
        \.stackTopShiftUp, \.stackTopDisplayStyleShiftUp, \.stackBottomShiftDown,
        \.stackBottomDisplayStyleShiftDown, \.stackGapMin, \.stackDisplayStyleGapMin,
        \.stretchStackTopShiftUp, \.stretchStackBottomShiftDown, \.stretchStackGapAboveMin,
        \.stretchStackGapBelowMin, \.fractionNumeratorShiftUp, \.fractionNumeratorDisplayStyleShiftUp,
        \.fractionDenominatorShiftDown, \.fractionDenominatorDisplayStyleShiftDown,
        \.fractionNumeratorGapMin, \.fractionNumDisplayStyleGapMin, \.fractionRuleThickness,
        \.fractionDenominatorGapMin, \.fractionDenomDisplayStyleGapMin, \.skewedFractionHorizontalGap,
        \.skewedFractionVerticalGap, \.overbarVerticalGap, \.overbarRuleThickness, \.overbarExtraAscender,
        \.underbarVerticalGap, \.underbarRuleThickness, \.underbarExtraDescender, \.radicalVerticalGap,
        \.radicalDisplayStyleVerticalGap, \.radicalRuleThickness, \.radicalExtraAscender,
        \.radicalKernBeforeDegree, \.radicalKernAfterDegree,
    ]

    /// Reads the MathConstants subtable at `offset`; nil when it is truncated.
    init?(table: MathTable, offset: Int, unitsPerEm: CGFloat) {
        guard table.contains(offset, length: 8 + 4 * Self.recordFields.count + 2) else { return nil }
        scriptPercentScaleDown = CGFloat(table.int16(offset))
        scriptScriptPercentScaleDown = CGFloat(table.int16(offset + 2))
        delimitedSubFormulaMinHeight = CGFloat(table.uint16(offset + 4)) / unitsPerEm
        displayOperatorMinHeight = CGFloat(table.uint16(offset + 6)) / unitsPerEm
        var position = offset + 8
        for field in Self.recordFields {
            self[keyPath: field] = CGFloat(table.int16(position)) / unitsPerEm
            position += 4 // value and device-table offset
        }
        radicalDegreeBottomRaisePercent = CGFloat(table.int16(position))
        if scriptPercentScaleDown <= 0 || scriptPercentScaleDown > 100 { scriptPercentScaleDown = 70 }
        if scriptScriptPercentScaleDown <= 0 || scriptScriptPercentScaleDown > 100 { scriptScriptPercentScaleDown = 50 }
    }

    init() {}
}

/// How a glyph stretches along one axis: pre-made size variants, and an assembly of parts for
/// sizes beyond the largest variant. Measurements are in font design units.
struct GlyphConstruction: Sendable {
    struct Part: Sendable {
        var glyph: CGGlyph
        var startConnector: CGFloat
        var endConnector: CGFloat
        var fullAdvance: CGFloat
        var isExtender: Bool
    }
    struct Variant: Sendable {
        var glyph: CGGlyph
        /// The variant's size along the stretch axis.
        var advance: CGFloat
    }
    /// Smallest first.
    var variants: [Variant]
    /// Bottom to top (vertical) or left to right (horizontal); empty when there is no assembly.
    var parts: [Part]
    var assemblyItalicsCorrection: CGFloat
}

/// An OpenType MATH table read from a font's bytes. Constants are read once; per-glyph data is
/// looked up by binary search in the coverage tables. Every read is bounds-checked, so a
/// malformed table yields missing data rather than a crash.
struct MathTable: Sendable {
    private let bytes: [UInt8]
    let unitsPerEm: CGFloat
    private(set) var constants = MathConstants.fallback
    private var italicsCorrection = 0
    private var topAccentAttachment = 0
    private var variants = 0

    init?(data: [UInt8], unitsPerEm: CGFloat) {
        bytes = data
        self.unitsPerEm = unitsPerEm > 0 ? unitsPerEm : 1000
        guard contains(0, length: 10), uint16(0) == 1 else { return nil }
        guard let constants = MathConstants(table: self, offset: Int(uint16(4)), unitsPerEm: self.unitsPerEm) else { return nil }
        self.constants = constants
        let glyphInfo = Int(uint16(6))
        if glyphInfo > 0, contains(glyphInfo, length: 8) {
            italicsCorrection = subtable(glyphInfo, uint16(glyphInfo))
            topAccentAttachment = subtable(glyphInfo, uint16(glyphInfo + 2))
        }
        variants = Int(uint16(8))
        if variants > 0, !contains(variants, length: 10) { variants = 0 }
    }

    private func subtable(_ base: Int, _ offset: UInt16) -> Int { offset == 0 ? 0 : base + Int(offset) }

    func contains(_ offset: Int, length: Int) -> Bool { offset >= 0 && length >= 0 && offset + length <= bytes.count }
    func uint16(_ offset: Int) -> UInt16 {
        guard contains(offset, length: 2) else { return 0 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
    func int16(_ offset: Int) -> Int16 { Int16(bitPattern: uint16(offset)) }

    /// The coverage index of `glyph` in the Coverage table at `offset`, if covered.
    private func coverageIndex(_ glyph: CGGlyph, coverage offset: Int) -> Int? {
        guard offset > 0, contains(offset, length: 4) else { return nil }
        let count = Int(uint16(offset + 2))
        var low = 0, high = count
        switch uint16(offset) {
        case 1:
            while low < high {
                let mid = (low + high) / 2
                let value = uint16(offset + 4 + mid * 2)
                if value == glyph { return mid }
                if value < glyph { low = mid + 1 } else { high = mid }
            }
        case 2:
            while low < high {
                let mid = (low + high) / 2
                let record = offset + 4 + mid * 6
                let start = uint16(record), end = uint16(record + 2)
                if glyph < start { high = mid } else if glyph > end { low = mid + 1 } else {
                    return Int(uint16(record + 4)) + Int(glyph - start)
                }
            }
        default: break
        }
        return nil
    }

    /// A coverage-keyed list of MathValueRecords: italics corrections or top accent attachments.
    private func glyphValue(_ glyph: CGGlyph, table offset: Int) -> CGFloat? {
        guard offset > 0, contains(offset, length: 4) else { return nil }
        let coverage = offset + Int(uint16(offset))
        guard let index = coverageIndex(glyph, coverage: coverage), index < Int(uint16(offset + 2)) else { return nil }
        let record = offset + 4 + index * 4
        guard contains(record, length: 2) else { return nil }
        return CGFloat(int16(record))
    }

    func italicsCorrection(_ glyph: CGGlyph) -> CGFloat? { glyphValue(glyph, table: italicsCorrection) }
    func topAccentAttachment(_ glyph: CGGlyph) -> CGFloat? { glyphValue(glyph, table: topAccentAttachment) }

    var minConnectorOverlap: CGFloat { variants > 0 ? CGFloat(uint16(variants)) : 0 }

    /// The vertical or horizontal construction of `glyph`, if the font has one.
    func construction(_ glyph: CGGlyph, vertical: Bool) -> GlyphConstruction? {
        guard variants > 0 else { return nil }
        let coverageOffset = Int(uint16(variants + (vertical ? 2 : 4)))
        guard coverageOffset > 0, let index = coverageIndex(glyph, coverage: variants + coverageOffset) else { return nil }
        let verticalCount = Int(uint16(variants + 6)), horizontalCount = Int(uint16(variants + 8))
        guard index < (vertical ? verticalCount : horizontalCount) else { return nil }
        let offset = Int(uint16(variants + 10 + 2 * (vertical ? index : verticalCount + index)))
        guard offset > 0 else { return nil }
        let construction = variants + offset
        guard contains(construction, length: 4) else { return nil }
        var result = GlyphConstruction(variants: [], parts: [], assemblyItalicsCorrection: 0)
        for item in 0..<min(Int(uint16(construction + 2)), 64) {
            let record = construction + 4 + item * 4
            guard contains(record, length: 4) else { break }
            result.variants.append(.init(glyph: uint16(record), advance: CGFloat(uint16(record + 2))))
        }
        let assemblyOffset = Int(uint16(construction))
        if assemblyOffset > 0, contains(construction + assemblyOffset, length: 6) {
            let assembly = construction + assemblyOffset
            result.assemblyItalicsCorrection = CGFloat(int16(assembly))
            for item in 0..<min(Int(uint16(assembly + 4)), 32) {
                let record = assembly + 6 + item * 10
                guard contains(record, length: 10) else { result.parts = []; break }
                result.parts.append(.init(glyph: uint16(record), startConnector: CGFloat(uint16(record + 2)),
                                          endConnector: CGFloat(uint16(record + 4)),
                                          fullAdvance: CGFloat(uint16(record + 6)),
                                          isExtender: uint16(record + 8) & 1 != 0))
            }
        }
        return result.variants.isEmpty && result.parts.isEmpty ? nil : result
    }
}
