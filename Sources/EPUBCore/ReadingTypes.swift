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
    /// The font, spacing, margins, alignment and hyphenation of book text. Its default sets
    /// nothing: the book's styles and the reader's own defaults.
    public var typography = Typography()
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

extension EPUBReaderStyle {
    /// The reading adjustments a reader expects: font, spacing, margins, alignment and
    /// hyphenation. Each value left nil keeps what the book and the reader give.
    ///
    /// With `overridesBookStyles` off, a value set takes the place of the reader's own default,
    /// as a user style sheet does (CSS Cascade 4 §6.2), and the book's own declarations win
    /// wherever it makes them. With it on, the values set apply to the book's text whatever
    /// the book declares. Either way preformatted text, code, tables, MathML, SVG and boxes the
    /// book sizes or places keep the styles the book gives them.
    public struct Typography: Hashable, Codable, Sendable {
        public enum FontFamily: Hashable, Codable, Sendable {
            /// The reader's serif, the system's serif design (New York).
            case serif
            /// The system font (San Francisco).
            case sansSerif
            /// The system font's monospaced design.
            case monospace
            /// The system font's rounded design.
            case rounded
            /// An installed family, such as "Georgia", or one the app registers, such as a
            /// bundled Atkinson Hyperlegible or OpenDyslexic: with `CTFontManagerRegisterFontsForURL`,
            /// or listed under `UIAppFonts` (iOS) or `ATSApplicationFontsPath` (macOS) in its
            /// Info.plist. Named by its family name, in any case. Characters it has no glyph for
            /// are drawn in the font the text would otherwise have; a family that is not
            /// available leaves that font.
            case named(String)
        }

        public enum Alignment: String, CaseIterable, Codable, Sendable {
            /// Ragged lines: left in left-to-right text.
            case start
            /// Lines filled to both edges.
            case justified
        }

        public var fontFamily: FontFamily?
        /// Line spacing as a multiple of the font size, as a unitless CSS `line-height`: the
        /// reader's own is 1.4. Applied within 0.5–5.
        public var lineHeight: Double?
        /// The space above and below each paragraph (`p`), in ems of its text: the reader's own
        /// is 1, and 0 runs paragraphs together. Adjoining paragraphs share it, as CSS collapses
        /// their margins. Applied within 0–5.
        public var paragraphSpacing: Double?
        /// Space added between letters, in ems: 0 is the font's own spacing. Applied within
        /// −0.25–1.
        public var letterSpacing: Double?
        /// Space added between words, in ems: 0 is the font's own spacing. Applied within
        /// −0.25–2.
        public var wordSpacing: Double?
        /// The page's side margins as a multiple of the reader's own (3.5% of the page's width
        /// each side): 0 removes them, 2 doubles them. A column stays at most 720 points wide.
        /// Applied within 0–4. These are the reader's margins and apply whatever the switch says.
        public var pageMargins: Double?
        /// Ragged or justified lines. Text the book centres or sets to its end side stays so.
        public var alignment: Alignment?
        /// Whether words break at line ends where the language's hyphenation allows (CSS
        /// `hyphens: auto`, the reader's own), or only where the book marks a soft hyphen.
        public var hyphenation: Bool?
        /// Whether the values set apply over the book's own declarations, rather than in place of
        /// the reader's defaults only: a reader's "publisher defaults" switch turned off.
        public var overridesBookStyles: Bool

        public init(fontFamily: FontFamily? = nil, lineHeight: Double? = nil, paragraphSpacing: Double? = nil,
                    letterSpacing: Double? = nil, wordSpacing: Double? = nil, pageMargins: Double? = nil,
                    alignment: Alignment? = nil, hyphenation: Bool? = nil, overridesBookStyles: Bool = false) {
            self.fontFamily = fontFamily; self.lineHeight = lineHeight; self.paragraphSpacing = paragraphSpacing
            self.letterSpacing = letterSpacing; self.wordSpacing = wordSpacing; self.pageMargins = pageMargins
            self.alignment = alignment; self.hyphenation = hyphenation; self.overridesBookStyles = overridesBookStyles
        }
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
    public init(id: String, location: EPUBLocation) { self.id = id; self.location = location }
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
    /// Replaces every drawn highlight. An empty array removes them.
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
