import Foundation

/// The characters a `::first-letter` takes from the start of a run of text (CSS Pseudo-Elements 4
/// §2.2.1): punctuation, with the typographic spaces between, then the first letter, number or
/// symbol (Unicode `L*`, `N*` or `S*`) as one typographic character unit, a grapheme cluster, so
/// that a combining mark stays with its base; then punctuation other than opening punctuation
/// and dashes, with the typographic spaces between that are not word separators, up to the last
/// such punctuation. Informally `(P (Zs|P)*)? (L|N|S) ((Zs|P−(Ps|Pd))* (P−(Ps|Pd)))?`, where
/// no space is U+3000 IDEOGRAPHIC SPACE.
enum FirstLetterText {
    enum Extent: Equatable {
        /// The first letter ends at this offset of the units.
        case letter(end: Int)
        /// The run holds only punctuation, and the spaces after it, that may come before a letter.
        case punctuation
        /// The run cannot begin a first letter.
        case none
    }

    /// Where the first letter ends in `units[range]`. `afterPunctuation`: punctuation before the
    /// run, in an earlier one, already began the first letter, so the run may open with a space.
    static func extent(_ units: [UInt16], _ range: Range<Int>, afterPunctuation: Bool) -> Extent {
        var offset = range.lowerBound, punctuated = afterPunctuation, letterEnd: Int?
        for character in String(decoding: units[range], as: UTF16.self) {
            guard let scalar = character.unicodeScalars.first else { break }
            let category = scalar.properties.generalCategory
            let next = offset + character.utf16.count
            if let end = letterEnd {
                if isPunctuation(category), category != .openPunctuation, category != .dashPunctuation {
                    letterEnd = next
                } else if !(category == .spaceSeparator && scalar.value != 0x3000 && !wordSeparators.contains(scalar.value)) {
                    return .letter(end: end)
                }
            } else if isPunctuation(category) {
                punctuated = true
            } else if category == .spaceSeparator, scalar.value != 0x3000 {
                guard punctuated else { return .none }
            } else if isLetterNumberOrSymbol(category) {
                letterEnd = next
            } else {
                return .none
            }
            offset = next
        }
        if let end = letterEnd { return .letter(end: end) }
        return punctuated && offset > range.lowerBound ? .punctuation : .none
    }

    /// CSS Text 3 §8.1's word separators.
    private static let wordSeparators: Set<UInt32> = [0x20, 0xA0, 0x1361, 0x10100, 0x10101, 0x1039F, 0x1091F]

    private static func isPunctuation(_ category: Unicode.GeneralCategory) -> Bool {
        switch category {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation:
            true
        default: false
        }
    }

    private static func isLetterNumberOrSymbol(_ category: Unicode.GeneralCategory) -> Bool {
        switch category {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            true
        default: false
        }
    }
}
