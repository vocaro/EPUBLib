import Foundation

// SKELETON: API for the Swift port of foliate-js `search.js`/`text-walker.js` (MIT) and the
// WebKit reader's locate normalization. The positions workstream implements it.

/// Finds text in a content document the way the WebKit reader did, so a citation that located
/// before still locates: the body's text nodes (outside `script` and `style`) are concatenated,
/// format-category characters are dropped, whitespace runs compare as one space, and graphemes
/// compare with `Intl.Collator` base sensitivity (case- and diacritic-insensitive).
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

    /// Every match of an already-normalized query in reading order. `locale` is the document's
    /// language (foliate uses `body.lang`, else the root's, else the book's, else `en`).
    static func matches(of query: String, in document: ContentDocument, locale: String?, limit: Int = .max) -> [Match] { [] }
}
