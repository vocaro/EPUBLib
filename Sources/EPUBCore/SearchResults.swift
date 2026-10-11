import Foundation

/// One occurrence of a search query that the engine can show.
public struct EPUBSearchResult: Equatable, Sendable, Identifiable {
    /// Zero-based place in `EPUBSearchResults.results`.
    public var index: Int
    /// Where the occurrence is: `href` names its section, `progression` its place in the book,
    /// `title` the contents entry in effect there, `quote` the matched text and `page` the
    /// page-list entry in effect. An engine with `.bookmarks` also sets `bookmark` to exactly
    /// the occurrence, which `.restore` and `EPUBHighlight` accept.
    public var location: EPUBLocation
    /// Zero-based index of the occurrence's section in `EPUBPublication.spine`.
    public var spineIndex: Int
    /// A name for the section to show with the occurrence: the contents entry in effect, else
    /// the section document's own title. nil when the book supplies neither.
    public var sectionTitle: String?
    /// The book's text as matched. It can differ from the query in case, accents and spacing.
    public var matchedText: String
    /// The text just before the occurrence in its section, with white space collapsed. Empty
    /// at the section's start.
    public var contextBefore: String
    /// The text just after the occurrence in its section, with white space collapsed. Empty at
    /// the section's end.
    public var contextAfter: String
    public var id: Int { index }

    public init(index: Int, location: EPUBLocation, spineIndex: Int, sectionTitle: String? = nil,
                matchedText: String, contextBefore: String = "", contextAfter: String = "") {
        self.index = index; self.location = location; self.spineIndex = spineIndex
        self.sectionTitle = sectionTitle; self.matchedText = matchedText
        self.contextBefore = contextBefore; self.contextAfter = contextAfter
    }

    /// The occurrence within its surrounding text.
    public var snippet: String { contextBefore + matchedText + contextAfter }
}

/// The results of a completed search and the match the reader last showed from them.
///
/// `results` lists every occurrence the engine can show, in the engine's documented order (the
/// bundled reader: spine order, then document order). The current match changes only through
/// `.search`, `.nextSearchResult`, `.previousSearchResult` and `.showSearchResult`; turning
/// pages, scrolling or navigating elsewhere leaves it alone, so stepping continues from the
/// match last shown rather than from the visible page.
public struct EPUBSearchResults: Equatable, Sendable {
    /// The text submitted with `.search` or `.searchHighlight`.
    public var query: String
    public var results: [EPUBSearchResult]
    /// The current match's index in `results`. nil until a result has been shown: after
    /// `.searchHighlight`, or when newer navigation kept `.search` from opening its first match.
    public var currentIndex: Int?
    /// The book holds more occurrences than `results` lists, because the engine bounds the
    /// list. `count` is then a lower bound; every listed result remains navigable.
    public var isTruncated: Bool

    public init(query: String, results: [EPUBSearchResult] = [], currentIndex: Int? = nil, isTruncated: Bool = false) {
        self.query = query; self.results = results; self.isTruncated = isTruncated
        self.currentIndex = currentIndex.flatMap { results.indices.contains($0) ? $0 : nil }
    }

    public var count: Int { results.count }
    public var isEmpty: Bool { results.isEmpty }
    public var current: EPUBSearchResult? {
        currentIndex.flatMap { results.indices.contains($0) ? results[$0] : nil }
    }
    /// The current match is the first result; stepping backward returns to the last.
    public var isAtFirst: Bool { !isEmpty && currentIndex == 0 }
    /// The current match is the last result; stepping forward returns to the first.
    public var isAtLast: Bool { !isEmpty && currentIndex == count - 1 }

    /// The result a logical step shows, which is how `.nextSearchResult` and
    /// `.previousSearchResult` choose: the neighbour of the current match, wrapping from the
    /// last result to the first and from the first to the last. With no current match a forward
    /// step shows the first result and a backward step the last. nil when there are no results.
    public func steppedIndex(forward: Bool) -> Int? {
        guard !isEmpty else { return nil }
        guard let currentIndex, results.indices.contains(currentIndex) else { return forward ? 0 : count - 1 }
        return ((forward ? currentIndex + 1 : currentIndex - 1) + count) % count
    }
}
