import Foundation

// Ports foliate-js `search.js` (`segmenterSearch`, which `search` runs for `granularity:
// 'grapheme'` and `sensitivity: 'base'`, as the WebKit reader's locate did) and `text-walker.js`
// (MIT License, Copyright (c) 2022 John Factotum), as vendored at
// `Sources/EPUBViewing/Resources/epub-reader/lib/`.

/// Finds text in a content document the way the WebKit reader did, so a citation that located
/// before still locates: the body's text nodes (outside `script` and `style`) are concatenated,
/// format-category characters are dropped, whitespace runs compare as one space, and graphemes
/// compare with `Intl.Collator` base sensitivity (case- and diacritic-insensitive).
///
/// The collator is Foundation's localized comparison with case, diacritic and width
/// insensitivity, which is ICU at primary strength like WebKit's `Intl.Collator`, except that it
/// folds decomposable diacritics before applying a language's tailoring (Swedish `å` matches
/// `a` here, not in WebKit). A prefilter on coarse per-grapheme keys keeps that comparison to
/// the few windows that can match.
enum TextSearch {
    struct Match: Equatable, Sendable {
        let start: DOMPosition
        let end: DOMPosition
    }

    /// The WebKit reader's `normalizeLocateWhitespace`: format characters removed, whitespace
    /// collapsed to single spaces, trimmed.
    static func normalizeQuote(_ quote: String) -> String {
        let kept = quote.unicodeScalars.filter { $0.properties.generalCategory != .format }
        return String(String.UnicodeScalarView(kept)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The locale foliate-js searched a document in: the body's `lang` attribute, else the root
    /// element's (`xml:lang` is not consulted). nil means the reader's default locale, which is
    /// what foliate's fallback amounted to: the book language it passed was not a locale string.
    static func locale(of document: ContentDocument) -> String? {
        let root = searchRoot(of: document)
        let body = root === document.root ? nil : root.attribute("lang")
        return [body, document.root.attribute("lang")].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Every match of an already-normalized query in reading order. `locale` is the document's
    /// language (`locale(of:)`); nil uses the current locale.
    ///
    /// As in foliate, each grapheme of each text node is a unit; a grapheme made only of format
    /// characters is skipped; one containing white space becomes a single space unless the unit
    /// before it is one; and every window of as many units as the query has graphemes that
    /// compares equal is a match, overlapping ones included. A match starts at its first unit and
    /// ends after its last (a space unit is one UTF-16 unit long).
    static func matches(of query: String, in document: ContentDocument, locale: String?, limit: Int = .max) -> [Match] {
        let queryGraphemes = Array(query)
        let length = queryGraphemes.count
        guard length > 0, limit > 0 else { return [] }
        var keys = KeyTable()
        var queryKey: [UInt8] = []
        for grapheme in queryGraphemes {
            if grapheme.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .format }) { continue }
            if grapheme.unicodeScalars.contains(where: EPUBCFI.isJSWhitespace) { queryKey.append(0x20) }
            else { keys.append(grapheme, to: &queryKey) }
        }
        let corpus = Corpus(document: document, collapsesWhitespace: length > 1, keys: &keys)
        guard corpus.count >= length else { return [] }
        let collator = Collator(query: query, locale: locale)
        var matches: [Match] = []
        func consider(_ first: Int) -> Bool {
            if collator.matches(corpus.window(first, length)) { matches.append(corpus.match(first, length)) }
            return matches.count < limit
        }
        let keyLength = queryKey.count
        if keyLength == 0 {
            for first in 0...(corpus.count - length) where corpus.keyStart[first + length] == corpus.keyStart[first] {
                guard consider(first) else { break }
            }
            return matches
        }
        corpus.keys.withUnsafeBytes { haystack in
            queryKey.withUnsafeBytes { needle in
                guard let base = haystack.baseAddress, let pattern = needle.baseAddress else { return }
                var from = 0
                while from + keyLength <= haystack.count,
                      let found = memmem(base + from, haystack.count - from, pattern, keyLength) {
                    let offset = base.distance(to: UnsafeRawPointer(found))
                    from = offset + 1
                    // Windows whose keys start exactly here and span exactly the query's key.
                    var first = corpus.firstUnit(atKeyOffset: offset)
                    while first + length <= corpus.count, Int(corpus.keyStart[first]) == offset {
                        if Int(corpus.keyStart[first + length]) == offset + keyLength, !consider(first) { return }
                        first += 1
                    }
                }
            }
        }
        return matches
    }

    /// The prefilter key of a grapheme that is neither white space nor only format characters.
    /// Graphemes that compare equal must share it; `matches` relies on that.
    static func prefilterKey(of grapheme: Character) -> [UInt8] {
        var table = KeyTable(), key: [UInt8] = []
        table.append(grapheme, to: &key)
        return key
    }

    /// text-walker's root: `document.body`, the `html` root's first `body` (or `frameset`) child,
    /// else the whole document. A root in no namespace counts: foliate re-read those as HTML.
    private static func searchRoot(of document: ContentDocument) -> ContentNode {
        let root = document.root
        guard root.isHTML("html"),
              let body = root.children.first(where: { $0.isHTML("body") || $0.isHTML("frameset") }) else { return root }
        return body
    }

    /// The units foliate's window slides over, with a prefilter key per unit.
    private struct Corpus {
        var texts: [ContentNode] = []
        var unitText: [Int32] = []
        var unitOffset: [Int32] = []
        var unitLength: [Int32] = []
        /// `keys[keyStart[u]..<keyStart[u + 1]]` is unit `u`'s key; one more entry than units.
        var keyStart: [Int32] = [0]
        var keys: [UInt8] = []
        var count: Int { unitText.count }

        init(document: ContentDocument, collapsesWhitespace: Bool, keys table: inout KeyTable) {
            let root = TextSearch.searchRoot(of: document)
            var order = root.order
            while order <= root.subtreeEnd {
                let node = document.nodes[order]
                if node.isElement, node.name.utf8.count <= 6, ["script", "style"].contains(node.name.lowercased()) {
                    order = node.subtreeEnd + 1
                    continue
                }
                if node.isText, node.utf16Length > 0 { texts.append(node) }
                order += 1
            }
            var previousIsSpace = false
            for (index, node) in texts.enumerated() {
                let text = Int32(index)
                func space(_ offset: Int) {
                    guard !(collapsesWhitespace && previousIsSpace) else { return }
                    unit(text, offset, 1); keys.append(0x20); keyStart.append(Int32(keys.count))
                    previousIsSpace = true
                }
                func kept(_ offset: Int, _ length: Int) {
                    unit(text, offset, length); keyStart.append(Int32(keys.count))
                    previousIsSpace = false
                }
                if node.utf16Length == node.text.utf8.count {
                    var bytes = Array(node.text.utf8)[...]
                    var offset = 0
                    while let byte = bytes.popFirst() {
                        if byte == 0x0D, bytes.first == 0x0A { bytes.removeFirst(); space(offset); offset += 2; continue }
                        if (0x09...0x0D).contains(byte) || byte == 0x20 { space(offset) }
                        else { keys.append(contentsOf: KeyTable.ascii[Int(byte)]); kept(offset, 1) }
                        offset += 1
                    }
                    continue
                }
                var offset = 0
                for grapheme in node.text {
                    let length = grapheme.utf16.count
                    defer { offset += length }
                    let scalars = grapheme.unicodeScalars
                    if scalars.allSatisfy({ $0.properties.generalCategory == .format }) { continue }
                    if scalars.contains(where: EPUBCFI.isJSWhitespace) { space(offset); continue }
                    table.append(grapheme, to: &keys)
                    kept(offset, length)
                }
            }
        }

        private mutating func unit(_ text: Int32, _ offset: Int, _ length: Int) {
            unitText.append(text); unitOffset.append(Int32(offset)); unitLength.append(Int32(length))
        }

        /// The first unit whose key starts at or after a key offset.
        func firstUnit(atKeyOffset offset: Int) -> Int {
            var low = 0, high = count
            while low < high {
                let middle = (low + high) / 2
                if Int(keyStart[middle]) < offset { low = middle + 1 } else { high = middle }
            }
            return low
        }

        /// The window's string as foliate compared it: its units joined, spaces as `" "`.
        func window(_ first: Int, _ length: Int) -> String {
            var string = ""
            for unit in first..<(first + length) {
                let keyRange = Int(keyStart[unit])..<Int(keyStart[unit + 1])
                if keyRange.count == 1, keys[keyRange.lowerBound] == 0x20 { string += " "; continue }
                let text = texts[Int(unitText[unit])].text.utf16
                let start = text.index(text.startIndex, offsetBy: Int(unitOffset[unit]))
                let end = text.index(start, offsetBy: Int(unitLength[unit]))
                string += String(Substring(text[start..<end]))
            }
            return string
        }

        func match(_ first: Int, _ length: Int) -> Match {
            let last = first + length - 1
            return Match(start: DOMPosition(texts[Int(unitText[first])], Int(unitOffset[first])),
                         end: DOMPosition(texts[Int(unitText[last])], Int(unitOffset[last] + unitLength[last])))
        }
    }

    /// `Intl.Collator(locale, { sensitivity: 'base' }).compare(query, window) === 0`.
    private struct Collator {
        let query: String
        let locale: Locale
        /// The query lowercased when it is ASCII and the locale has no dotted-i tailoring, so an
        /// all-ASCII window compares without the localized comparison.
        let asciiQuery: [UInt8]?

        init(query: String, locale identifier: String?) {
            self.query = query
            locale = identifier.map(Locale.init(identifier:)) ?? .current
            let language = locale.language.languageCode?.identifier
            asciiQuery = query.utf8.allSatisfy({ $0 < 0x80 }) && language != "tr" && language != "az"
                ? query.utf8.map(Self.lowercased) : nil
        }

        func matches(_ window: String) -> Bool {
            if let asciiQuery, window.utf8.allSatisfy({ $0 < 0x80 }) {
                return window.utf8.count == asciiQuery.count && zip(window.utf8, asciiQuery).allSatisfy { Self.lowercased($0) == $1 }
            }
            return query.compare(window, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                 range: nil, locale: locale) == .orderedSame
        }

        private static func lowercased(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte | 0x20 : byte }
    }

    /// Prefilter keys, coarser than base-strength collation so that graphemes the collator
    /// equates always share a key: letters and digits fold case, diacritics, width and
    /// compatibility forms (and strokes, ligatures and kana), digits become ASCII, marks and
    /// format and control characters vanish, and all other characters share one key.
    private struct KeyTable {
        static let ascii: [[UInt8]] = (0..<128).map { key(of: Unicode.Scalar(UInt8($0))) }
        private var cache: [UInt32: [UInt8]] = [:]

        mutating func append(_ grapheme: Character, to keys: inout [UInt8]) {
            for scalar in grapheme.unicodeScalars {
                if scalar.value < 0x80 { keys.append(contentsOf: Self.ascii[Int(scalar.value)]); continue }
                if let key = cache[scalar.value] { keys.append(contentsOf: key); continue }
                let key = Self.key(of: scalar)
                cache[scalar.value] = key
                keys.append(contentsOf: key)
            }
        }

        private static func isIgnorable(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .format, .control: true
            default: false
            }
        }

        private static func key(of scalar: Unicode.Scalar) -> [UInt8] {
            if isIgnorable(scalar) { return [] }
            if let base = baseLetters[String(scalar).lowercased()] { return Array(base.utf8) }
            var key: [UInt8] = [], hasOther = false
            for part in String(scalar).decomposedStringWithCompatibilityMapping.unicodeScalars where !isIgnorable(part) {
                switch part.properties.generalCategory {
                case .decimalNumber, .letterNumber, .otherNumber:
                    if let value = part.properties.numericValue, value >= 0, value == value.rounded(), value < 1e6 {
                        key.append(contentsOf: String(Int(value)).utf8)
                    } else { key.append(contentsOf: String(part).utf8) }
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                    let folded = String(part).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                                      locale: nil).lowercased()
                    for letter in folded.unicodeScalars where letter.properties.isAlphabetic {
                        let string = String(letter)
                        key.append(contentsOf: (baseLetters[string] ?? kana(letter) ?? string).utf8)
                    }
                default: hasOther = true
                }
            }
            // Punctuation and symbols share one key; letters inside a decomposition (`Ŀ`, `℅`) win.
            return key.isEmpty && hasOther ? [0x01] : key
        }

        /// Letters base-strength collation equates with others that no folding above reaches.
        private static let baseLetters: [String: String] = [
            "ø": "o", "đ": "d", "ð": "d", "ł": "l", "ħ": "h", "ŧ": "t", "ƀ": "b", "ǥ": "g", "ɨ": "i",
            "ʉ": "u", "ƶ": "z", "ȼ": "c", "ɇ": "e", "ɉ": "j", "ɍ": "r", "ɏ": "y", "ⱥ": "a", "ı": "i",
            "æ": "ae", "œ": "oe", "ĸ": "q", "ſ": "s", "ʣ": "dz", "ʦ": "ts", "ƾ": "ts", "ͺ": "ι", "ϲ": "σ",
            "ґ": "г", "ך": "כ", "ם": "מ", "ן": "נ", "ף": "פ", "ץ": "צ", "⅍": "as",
        ]

        /// Kana as full-size hiragana: base strength distinguishes neither script nor size.
        private static func kana(_ scalar: Unicode.Scalar) -> String? {
            var value = scalar.value
            if (0x30A1...0x30F6).contains(value) || (0x30FD...0x30FE).contains(value) { value -= 0x60 }
            guard (0x3041...0x3096).contains(value) || (0x309D...0x309E).contains(value) else { return nil }
            if let full = smallKana[value] { value = full }
            return Unicode.Scalar(value).map(String.init)
        }

        private static let smallKana: [UInt32: UInt32] = [
            0x3041: 0x3042, 0x3043: 0x3044, 0x3045: 0x3046, 0x3047: 0x3048, 0x3049: 0x304A, 0x3063: 0x3064,
            0x3083: 0x3084, 0x3085: 0x3086, 0x3087: 0x3088, 0x308E: 0x308F, 0x3095: 0x304B, 0x3096: 0x3051,
        ]
    }
}
