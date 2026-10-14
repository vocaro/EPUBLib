import Foundation
import Synchronization

// Ports foliate-js `search.js` (`segmenterSearch`, which `search` runs for `granularity:
// 'grapheme'` and `sensitivity: 'base'`, as the WebKit reader's locate did) and `text-walker.js`
// (MIT License, Copyright (c) 2022 John Factotum), as vendored at
// `Sources/EPUBViewing/Resources/epub-reader/lib/`.

/// Finds text in a content document the way the WebKit reader did, so a citation that located
/// before still locates: the body's text nodes (outside `script` and `style`) are concatenated,
/// format-category characters are dropped, whitespace runs compare as one space, and graphemes
/// compare with `Intl.Collator` base sensitivity (case- and diacritic-insensitive).
///
/// Comparison uses the primary level of Foundation's localized collation, preserving letters
/// a language distinguishes even when their spelling contains a combining mark. A coarse
/// prefilter accelerates locales and characters covered by the recorded reference classes;
/// windows involving unverified or contextual keys go directly to the collator.
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
    static func matches(of query: String, in document: ContentDocument, locale: String?, limit: Int = .max,
                        usePrefilter: Bool = true) -> [Match] {
        let queryGraphemes = Array(query)
        let length = queryGraphemes.count
        guard length > 0, limit > 0 else { return [] }
        let collator = Collator(query: query, locale: locale)
        var keys = KeyTable(locale: collator.locale)
        var queryKey: [UInt8] = []
        var queryCanUseKeys = true
        for grapheme in queryGraphemes {
            if grapheme.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .format }) { continue }
            if grapheme.unicodeScalars.contains(where: EPUBCFI.isJSWhitespace) { queryKey.append(0x20) }
            else {
                queryCanUseKeys = keys.supports(grapheme) && queryCanUseKeys
                keys.append(grapheme, to: &queryKey)
            }
        }
        let corpus = Corpus(document: document, collapsesWhitespace: length > 1, keys: &keys)
        guard corpus.count >= length else { return [] }
        var matches: [Match] = []
        func consider(_ first: Int) -> Bool {
            if collator.matches(corpus.window(first, length)) { matches.append(corpus.match(first, length)) }
            return matches.count < limit
        }
        guard usePrefilter && keys.isVerified && queryCanUseKeys else {
            for first in 0...(corpus.count - length) { guard consider(first) else { break } }
            return matches
        }
        // A context-free key is not proof for a contextual collation character or one outside
        // the recorded classes. Merge those windows with the key hits in reading order rather
        // than disabling the fast scan for an entire book that contains one unusual character.
        var fallbackRanges: [ClosedRange<Int>] = []
        for unit in corpus.unsafeUnits {
            let lower = max(0, unit - length + 1), upper = min(unit, corpus.count - length)
            if let last = fallbackRanges.last, lower <= last.upperBound + 1 {
                fallbackRanges[fallbackRanges.count - 1] = last.lowerBound...max(last.upperBound, upper)
            } else { fallbackRanges.append(lower...upper) }
        }
        var fallbackRange = 0
        var fallbackFirst = fallbackRanges.first?.lowerBound
        func advanceFallback() {
            guard let first = fallbackFirst else { return }
            if first < fallbackRanges[fallbackRange].upperBound { fallbackFirst = first + 1 }
            else {
                fallbackRange += 1
                fallbackFirst = fallbackRange < fallbackRanges.count ? fallbackRanges[fallbackRange].lowerBound : nil
            }
        }
        func considerCandidate(_ first: Int) -> Bool {
            while let fallback = fallbackFirst, fallback <= first {
                advanceFallback()
                guard consider(fallback) else { return false }
                if fallback == first { return true } // The same window is considered only once.
            }
            return consider(first)
        }
        func finishFallback() {
            while let fallback = fallbackFirst {
                advanceFallback()
                guard consider(fallback) else { break }
            }
        }
        let keyLength = queryKey.count
        if keyLength == 0 {
            for first in 0...(corpus.count - length) where corpus.keyStart[first + length] == corpus.keyStart[first] {
                guard considerCandidate(first) else { return matches }
            }
            finishFallback()
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
                        if Int(corpus.keyStart[first + length]) == offset + keyLength, !considerCandidate(first) { return }
                        first += 1
                    }
                }
            }
        }
        if matches.count < limit { finishFallback() }
        return matches
    }

    /// The book's own characters a match covers: the searched text nodes from the match's
    /// start to its end, joined without separators as the matcher read them, white space and
    /// format characters included. Empty unless the match's nodes belong to `document`.
    static func text(of match: Match, in document: ContentDocument) -> String {
        let first = match.start.node.order, last = match.end.node.order
        guard document.nodes.indices.contains(first), document.nodes.indices.contains(last), first <= last,
              document.nodes[first] === match.start.node, document.nodes[last] === match.end.node else { return "" }
        var string = ""
        var order = first
        while order <= last {
            let node = document.nodes[order]
            if node.isElement, node.name.utf8.count <= 6, ["script", "style"].contains(node.name.lowercased()) {
                order = node.subtreeEnd + 1
                continue
            }
            if node.isText {
                let text = node.text.utf16
                let lower = order == first ? min(max(match.start.offset, 0), node.utf16Length) : 0
                let upper = order == last ? min(max(match.end.offset, lower), node.utf16Length) : node.utf16Length
                let start = text.index(text.startIndex, offsetBy: lower)
                string += String(Substring(text[start..<text.index(start, offsetBy: upper - lower)]))
            }
            order += 1
        }
        return string
    }

    /// The prefilter key of a grapheme that is neither white space nor only format characters.
    /// Graphemes that compare equal must share it; `matches` relies on that.
    static func prefilterKey(of grapheme: Character, locale: String = "en") -> [UInt8] {
        var table = KeyTable(locale: Locale(identifier: locale)), key: [UInt8] = []
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
        // Random UTF-16 offsets into a non-ASCII Swift String can require a scan from its
        // beginning. Keep an indexed copy so fallback windows in a long paragraph stay linear
        // in the window's length, while ASCII continues to use its direct String offsets.
        var utf16Texts: [[UInt16]?] = []
        var unitText: [Int32] = []
        var unitOffset: [Int32] = []
        var unitLength: [Int32] = []
        /// `keys[keyStart[u]..<keyStart[u + 1]]` is unit `u`'s key; one more entry than units.
        var keyStart: [Int32] = [0]
        var keys: [UInt8] = []
        var unsafeUnits: [Int] = []
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
                if node.isText, node.utf16Length > 0 {
                    texts.append(node)
                    utf16Texts.append(node.utf16Length == node.text.utf8.count ? nil : Array(node.text.utf16))
                }
                order += 1
            }
            let capacity = texts.reduce(0) { $0 + $1.utf16Length }
            unitText.reserveCapacity(capacity); unitOffset.reserveCapacity(capacity)
            unitLength.reserveCapacity(capacity); keyStart.reserveCapacity(capacity + 1); keys.reserveCapacity(capacity)
            var previousIsSpace = false
            for (index, node) in texts.enumerated() {
                let text = Int32(index)
                func space(_ offset: Int) {
                    guard !(collapsesWhitespace && previousIsSpace) else { return }
                    unit(text, offset, 1); keys.append(0x20); keyStart.append(Int32(keys.count))
                    previousIsSpace = true
                }
                func ascii(_ byte: UInt8, _ offset: Int) {
                    if byte == 0x20 || (0x09...0x0D).contains(byte) { return space(offset) }
                    let key = KeyTable.asciiKeys[Int(byte)]
                    if key != 0 { keys.append(key) }
                    unit(text, offset, 1); keyStart.append(Int32(keys.count))
                    previousIsSpace = false
                }
                // ASCII text is one grapheme per byte, except CR LF.
                if node.utf16Length == node.text.utf8.count {
                    var string = node.text
                    string.withUTF8 { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            if bytes[offset] == 0x0D, offset + 1 < bytes.count, bytes[offset + 1] == 0x0A {
                                space(offset); offset += 2
                            } else { ascii(bytes[offset], offset); offset += 1 }
                        }
                    }
                    continue
                }
                var offset = 0
                for grapheme in node.text {
                    if grapheme.utf8.count == 1, let byte = grapheme.utf8.first {
                        ascii(byte, offset); offset += 1
                        continue
                    }
                    let length = grapheme.utf16.count
                    defer { offset += length }
                    let scalars = grapheme.unicodeScalars
                    if scalars.allSatisfy({ $0.properties.generalCategory == .format }) { continue }
                    if scalars.contains(where: EPUBCFI.isJSWhitespace) { space(offset); continue }
                    if !table.supports(grapheme) { unsafeUnits.append(count) }
                    table.append(grapheme, to: &keys)
                    unit(text, offset, length); keyStart.append(Int32(keys.count))
                    previousIsSpace = false
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
                let index = Int(unitText[unit]), offset = Int(unitOffset[unit]), length = Int(unitLength[unit])
                if let text = utf16Texts[index] {
                    string += String(decoding: text[offset..<offset + length], as: UTF16.self)
                } else {
                    let text = texts[index].text.utf16
                    let start = text.index(text.startIndex, offsetBy: offset)
                    let end = text.index(start, offsetBy: length)
                    string += String(Substring(text[start..<end]))
                }
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
        private let low: String
        private let high: String
        private let lowerQuery: String
        private let upperQuery: String

        init(query: String, locale identifier: String?) {
            // Foundation can order canonically equivalent Hangul/kana differently once a
            // private-use suffix is appended. Normalize the comparison copies before adding
            // suffixes; Corpus retains the original text and UTF-16 offsets.
            let query = query.precomposedStringWithCanonicalMapping
            self.query = query
            locale = identifier.map(Locale.init(identifier:)) ?? .current
            (low, high) = Self.sentinels(excluding: query)
            lowerQuery = query + low
            upperQuery = query + high
            let language = locale.language.languageCode?.identifier
            asciiQuery = query.utf8.allSatisfy({ $0 < 0x80 }) && language != "tr" && language != "az"
                ? query.utf8.map(Self.lowercased) : nil
        }

        func matches(_ window: String) -> Bool {
            if let asciiQuery, window.utf8.allSatisfy({ $0 < 0x80 }) {
                if window.utf8.count == asciiQuery.count && zip(window.utf8, asciiQuery).allSatisfy({ Self.lowercased($0) == $1 }) {
                    return true
                }
            }
            let window = window.precomposedStringWithCanonicalMapping
            if window.contains(low) || window.contains(high) {
                let (low, high) = Self.sentinels(excluding: query + window)
                return primaryEqual(query + low, query + high, window, low, high)
            }
            return primaryEqual(lowerQuery, upperQuery, window, low, high)
        }

        /// Collation compares all primary weights before secondary and tertiary weights. Two
        /// adjacent private-use characters have distinct, consecutive primary weights, no
        /// decompositions or locale contractions. Appending them in opposite orders reverses
        /// the comparison exactly when the original primary sequences are equal. Neither
        /// sentinel occurs in the originals, so a proper primary prefix cannot straddle them.
        /// This exposes primary equality through the public comparison API without stripping
        /// diacritics before a locale can assign them a primary weight (Spanish ñ, Swedish å).
        private func primaryEqual(_ lowerQuery: String, _ upperQuery: String, _ window: String,
                                  _ low: String, _ high: String) -> Bool {
            // Primary equality already ignores case and width. Supplying folding options
            // would alter the input before collation (and break ß expansions or a fullwidth
            // letter with a language-tailored combining mark).
            return lowerQuery.compare(window + high, locale: locale) == .orderedAscending
                && upperQuery.compare(window + low, locale: locale) == .orderedDescending
        }

        private static func sentinels(excluding string: String) -> (String, String) {
            let scalars = Set(string.unicodeScalars.map(\.value))
            // A public command's query has at most 512 graphemes, so the BMP range normally
            // suffices. Supplementary private use also accommodates larger internal queries.
            for range in [UInt32(0xE000)...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD] {
                for value in stride(from: range.lowerBound, to: range.upperBound, by: 2)
                    where !scalars.contains(value) && !scalars.contains(value + 1) {
                    return (String(Unicode.Scalar(value)!), String(Unicode.Scalar(value + 1)!))
                }
            }
            preconditionFailure("A search query cannot contain every private-use character")
        }

        private static func lowercased(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte | 0x20 : byte }
    }

    /// Prefilter keys, coarser than base-strength collation so that graphemes the collator
    /// equates always share a key: letters and digits fold case, diacritics, width and
    /// compatibility forms (and strokes, ligatures and kana), digits become ASCII, marks and
    /// format and control characters vanish, and all other characters share one key.
    private struct KeyTable {
        let language: String
        let isVerified: Bool
        private var tailoredCache: [Character: [UInt8]] = [:]
        private var supportedCache: [Character: Bool] = [:]

        init(locale: Locale) {
            language = locale.language.languageCode?.identifier ?? "en"
            isVerified = locale.collation == .standard && ["en", "sv", "tr", "es", "da", "de", "ja"].contains(language)
        }
        static let ascii: [[UInt8]] = (0..<128).map { key(of: Unicode.Scalar(UInt8($0))) }
        /// `ascii` as single bytes, 0 for an empty key: every ASCII key is one byte or none.
        static let asciiKeys: [UInt8] = ascii.map { $0.first ?? 0 }
        /// Keys computed so far by any search; each search copies what it uses into `cache`.
        private static let shared = Mutex<[UInt32: [UInt8]]>([:])
        private var cache: [UInt32: [UInt8]] = [:]

        /// Recorded single-character classes cannot establish context-sensitive equivalence
        /// or collation weights for unrecorded characters. A Unicode decomposition alone is
        /// not proof of a primary collation weight (Arabic presentation marks are an example).
        mutating func supports(_ grapheme: Character) -> Bool {
            if let supported = supportedCache[grapheme] { return supported }
            // Character hashing uses canonical equivalence, so make eligibility use the
            // same canonical spelling instead of whichever source form populated the cache.
            let supported = String(grapheme).precomposedStringWithCanonicalMapping.unicodeScalars.allSatisfy { scalar in
                // Kana repetition/prolongation depends on its predecessor, even across text
                // nodes. Tatweel is primary-ignorable in Arabic although it is a letter.
                if [UInt32(0x309D), 0x309E, 0x30FC, 0x30FD, 0x30FE, 0xFF70, 0x640].contains(scalar.value) { return false }
                return Self.recordedRanges.contains { $0.contains(scalar.value) }
            }
            supportedCache[grapheme] = supported
            return supported
        }

        /// The ranges recorded by CFIFixtures.collationRanges; include ASCII whitespace and
        /// controls, which the search handles separately. Do not infer support for other
        /// Unicode blocks from the fact that their letters normally decompose or fold.
        private static let recordedRanges: [ClosedRange<UInt32>] = [
            0...0x7F, 0xA1...0x2FF, 0x370...0x4FF, 0x5D0...0x5EA, 0x621...0x64A,
            0x660...0x669, 0x6F0...0x6F9, 0x905...0x939, 0x966...0x96F, 0x1E00...0x1EFF,
            0x2010...0x205E, 0x2070...0x209F, 0x20A0...0x20BF, 0x2100...0x218F, 0x2460...0x24FF,
            0x3041...0x30FF, 0xFB00...0xFB06, 0xFF01...0xFF5E, 0xFF61...0xFF9F,
        ]

        mutating func append(_ grapheme: Character, to keys: inout [UInt8]) {
            // These locales merge letters from different root classes. Keep the prefilter
            // deliberately coarse, but apply those merges to composed and decomposed spelling.
            if language == "sv" || language == "da" {
                if let key = tailoredCache[grapheme] { keys.append(contentsOf: key); return }
                var key: [UInt8] = []
                // Remove the primary-ignorable subscript before case folding can turn it
                // into a non-ignorable Greek iota, including a precomposed capital letter.
                let scalars = String(grapheme).decomposedStringWithCanonicalMapping.unicodeScalars
                let decomposed = String(String.UnicodeScalarView(scalars.filter { $0.value != 0x345 }))
                let parts = Array(decomposed
                    .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
                    .decomposedStringWithCanonicalMapping.unicodeScalars)
                for (index, scalar) in parts.enumerated() {
                    let marks = parts.dropFirst(index + 1).prefix { Self.isIgnorable($0) }
                    // A preceding mark of the same combining class blocks the locale's
                    // contraction: ü + macron belongs with y, but ū + diaeresis stays with u.
                    func primaryMark(_ mark: Unicode.Scalar) -> Bool {
                        marks.first { $0.properties.canonicalCombiningClass.rawValue >= mark.properties.canonicalCombiningClass.rawValue } == mark
                    }
                    if scalar == "u", primaryMark("\u{308}") || primaryMark("\u{30B}") { key.append(0x79) }
                    else if language == "sv", scalar == "æ" || (scalar == "e" && primaryMark("\u{328}")) { key.append(0x61) }
                    else if language == "sv", scalar == "œ" { key.append(0x6F) }
                    else if language == "da", scalar == "a", primaryMark("\u{308}") { key.append(contentsOf: [0x61, 0x65]) }
                    else { append(scalar, to: &key) }
                }
                tailoredCache[grapheme] = key
                keys.append(contentsOf: key)
                return
            }
            for scalar in grapheme.unicodeScalars {
                append(scalar, to: &keys)
            }
        }

        private mutating func append(_ scalar: Unicode.Scalar, to keys: inout [UInt8]) {
            if scalar.value < 0x80 { keys.append(contentsOf: Self.ascii[Int(scalar.value)]); return }
            if let key = cache[scalar.value] { keys.append(contentsOf: key); return }
            let key = Self.shared.withLock { shared in
                if let key = shared[scalar.value] { return key }
                let key = Self.key(of: scalar)
                if shared.count < 65_536 { shared[scalar.value] = key }
                return key
            }
            cache[scalar.value] = key
            keys.append(contentsOf: key)
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
