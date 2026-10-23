import Foundation

public struct EPUBEngineBookmark: Codable, Equatable, Sendable {
    public var engineID: String
    public var format: String
    public var value: String
    public init(engineID: String, format: String, value: String) {
        self.engineID = engineID; self.format = format; self.value = value
    }
}

/// Portable fields describe a reading position. `bookmark` restores an engine's precise position.
/// Engines must reject incompatible bookmarks; matching text/href is a separate, potentially approximate operation.
public struct EPUBLocation: Codable, Equatable, Sendable {
    public var publicationID: String
    /// URL-encoded archive-relative reference, compatible with `.navigate(href:)`.
    public var href: String?
    public var progression: Double?
    public var title: String?
    public var quote: String?
    public var bookmark: EPUBEngineBookmark?
    /// Ordered bookmarks covering the complete range when it spans content documents.
    /// Each bookmark names a range in one document; `bookmark` equals the first entry for
    /// compatibility with hosts that only restore a reading position. nil for one document.
    /// Preserve this field when saving a selection as a highlight. Engines must validate and
    /// resolve the entire collection, or report that the range could not be restored.
    public var rangeBookmarks: [EPUBEngineBookmark]?
    /// The `EPUBPublication.pageList` entry in effect where the shown (or selected) range
    /// starts: the last whose target is at or before its first character. nil when the book has
    /// no page list, the range starts before its first entry or the engine does not read it.
    public var page: EPUBPageListEntry?
    /// Every page-list entry the range shows part of, in order: `page`, then each entry whose
    /// target falls inside the range. A screen holding the end of page 4 and the start of page 5
    /// has `page` 4 and `pages` [4, 5]. nil when there are none.
    public var pages: [EPUBPageListEntry]?
    public init(publicationID: String, href: String? = nil, progression: Double? = nil,
                title: String? = nil, quote: String? = nil, bookmark: EPUBEngineBookmark? = nil,
                page: EPUBPageListEntry? = nil, pages: [EPUBPageListEntry]? = nil,
                rangeBookmarks: [EPUBEngineBookmark]? = nil) {
        self.publicationID = publicationID; self.href = href; self.progression = progression
        self.title = title; self.quote = quote; self.bookmark = bookmark
        self.page = page; self.pages = pages; self.rangeBookmarks = rangeBookmarks
    }
}

public struct EPUBSelection: Equatable, Sendable {
    public let text: String
    public let location: EPUBLocation
    public init(text: String, location: EPUBLocation) { self.text = text; self.location = location }
}

public enum EPUBReadingFlow: String, Codable, Sendable { case paginated, scrolled }

public enum EPUBReaderAppearance: String, CaseIterable, Codable, Sendable { case system, light, dark }

public struct EPUBReaderStyle: Equatable, Sendable {
    public var fontSize: Double
    /// System follows the mounted view's color scheme, including live OS theme changes.
    public var appearance: EPUBReaderAppearance
    public var flow: EPUBReadingFlow
    public init(fontSize: Double = 17, appearance: EPUBReaderAppearance = .system, flow: EPUBReadingFlow = .paginated) {
        self.fontSize = fontSize; self.appearance = appearance; self.flow = flow
    }
    /// Compatibility with explicit light/dark style calls. Omitting appearance now follows System.
    public init(fontSize: Double = 17, isDark: Bool, flow: EPUBReadingFlow = .paginated) {
        self.init(fontSize: fontSize, appearance: isDark ? .dark : .light, flow: flow)
    }
    /// True only for explicit Dark. Read `EPUBReaderStatus.effectiveAppearance` for the
    /// resolved System appearance. Setting this property selects an explicit mode.
    public var isDark: Bool {
        get { appearance == .dark }
        set { appearance = newValue ? .dark : .light }
    }
}

public enum EPUBReaderCapability: String, Hashable, Sendable {
    case pagination, scrolling, typography, selection, bookmarks, locateText, navigateHref, searchHighlight, highlights
    /// Whole-book highlighting with navigation to the first rendered match.
    case search
    /// A navigable result list for the completed search: `EPUBSearchResults` with a count and
    /// current match, `.searchResultsChanged`, and the `.nextSearchResult`,
    /// `.previousSearchResult` and `.showSearchResult` commands. Requires `.search` or
    /// `.searchHighlight`. Engines that only highlight omit it and refuse those commands.
    case searchResults
}

/// A host-owned highlight drawn while reading. `location.bookmark` names a passage in one
/// document; `location.rangeBookmarks` covers a multi-document selection precisely.
/// Highlights the engine cannot resolve completely are not drawn and are reported with `.notice`.
public struct EPUBHighlight: Equatable, Sendable, Identifiable {
    public var id: String
    public var location: EPUBLocation
    /// How the passage is drawn, and what an assistive technology calls it.
    public var style: EPUBHighlightStyle
    public init(id: String, location: EPUBLocation, style: EPUBHighlightStyle = EPUBHighlightStyle()) {
        self.id = id; self.location = location; self.style = style
    }
}

/// How a highlight is drawn: a color, and a mark under its text that does not depend on color.
/// The default is yellow with no mark, as every highlight was drawn before styles.
public struct EPUBHighlightStyle: Hashable, Codable, Sendable {
    public var color: EPUBHighlightColor
    /// Drawn under the passage's text as well as its color, so that a reader who cannot tell
    /// the colors apart can tell the highlights apart. nil draws the color alone.
    public var mark: EPUBHighlightMark?
    public init(color: EPUBHighlightColor = .yellow, mark: EPUBHighlightMark? = nil) {
        self.color = color; self.mark = mark
    }
    /// What VoiceOver calls a passage in this style: its color's name and "highlight",
    /// "Yellow highlight". The mark is not said: it stands for the color, which is said.
    public var spokenName: String { "\(color.name) highlight" }
}

/// A highlight's color. Each is a category, not a value: the reader draws it in a shade of its
/// own for each appearance, light enough under the text, or dark enough, that the text keeps
/// its contrast. Hosts store the raw value.
public enum EPUBHighlightColor: String, CaseIterable, Codable, Sendable {
    case yellow, green, blue, pink, purple
    /// The color's name in a host's controls and in what VoiceOver says: "Yellow".
    public var name: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .pink: "Pink"
        case .purple: "Purple"
        }
    }
}

/// A line drawn under a highlight's text, in a darker or lighter shade of its color. Each is a
/// different pattern, so the marks tell highlights apart where their colors cannot. Hosts
/// store the raw value.
public enum EPUBHighlightMark: String, CaseIterable, Codable, Sendable {
    case underline, doubleUnderline, dottedUnderline, dashedUnderline
    /// The mark's name in a host's controls: "Underline".
    public var name: String {
        switch self {
        case .underline: "Underline"
        case .doubleUnderline: "Double underline"
        case .dottedUnderline: "Dotted underline"
        case .dashedUnderline: "Dashed underline"
        }
    }
}

public enum EPUBReaderCommand: Equatable, Sendable {
    case nextPage, previousPage
    case restore(EPUBLocation)
    case navigate(href: String)
    case locate(text: String, highlight: Bool)
    /// Highlights matches and opens the first rendered match in reading order.
    case search(text: String)
    /// Highlights matches without changing the reading position.
    case searchHighlight(text: String)
    case clearSearch
    /// Shows the result after the current match and makes it current. After the last result
    /// it returns to the first; with no current match it shows the first. Nothing happens
    /// while there are no results. A logical step in result order, never a page turn.
    case nextSearchResult
    /// Shows the result before the current match and makes it current. Before the first result
    /// it returns to the last; with no current match it shows the last.
    case previousSearchResult
    /// Shows one of the current `EPUBSearchResults.results` and makes it the current match.
    /// A result of a search that has since been replaced or cleared is refused.
    case showSearchResult(EPUBSearchResult)
    case style(EPUBReaderStyle)
    /// Replaces every drawn highlight. An empty array removes them. Where highlights overlap,
    /// the later in the array is drawn over the earlier.
    case setHighlights([EPUBHighlight])
}

public enum EPUBReaderError: Error, Equatable, Sendable {
    case unsupported(EPUBReaderCapability)
    case incompatibleLocation
    case invalidCommand(String)
    case notReady
    case closed
    case engineFailure(String)
}

public extension EPUBReaderError {
    var message: String {
        switch self {
        case .unsupported: "This reader does not support this action."
        case .incompatibleLocation: "This saved position belongs to a different book or reader."
        case .invalidCommand(let message), .engineFailure(let message): message
        case .notReady: "The reader is not ready."
        case .closed: "This book is closed."
        }
    }
}

/// Search feedback, independent of relocation. Completion means the whole book has been
/// searched. Navigation depends on the command. An engine with `.searchResults` publishes
/// the matches themselves as `EPUBSearchResults`, which exist only while this is `.completed`.
public enum EPUBSearchState: Equatable, Sendable {
    case idle
    case searching(query: String)
    case completed(query: String, hasMatches: Bool)
    case failed(query: String, error: EPUBReaderError)
}

public enum EPUBReaderEvent: Equatable, Sendable {
    /// Emitted exactly once per session when commands can be submitted.
    case ready
    case relocated(EPUBLocation)
    case selectionChanged(EPUBSelection?)
    case searchChanged(EPUBSearchState)
    /// The result list or its current match changed. Results arrive before the search's
    /// `.searchChanged(.completed)`; nil withdraws them when the search is cleared, replaced,
    /// failed or cancelled. Only engines with `.searchResults` emit it.
    case searchResultsChanged(EPUBSearchResults?)
    /// Display these to disclose content the engine withheld or could not render faithfully.
    case disclosure(String)
    case notice(String)
    case failed(EPUBReaderError)
}
