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
                page: EPUBPageListEntry? = nil, pages: [EPUBPageListEntry]? = nil) {
        self.publicationID = publicationID; self.href = href; self.progression = progression
        self.title = title; self.quote = quote; self.bookmark = bookmark
        self.page = page; self.pages = pages
    }
}

public struct EPUBSelection: Equatable, Sendable {
    public let text: String
    public let location: EPUBLocation
    public init(text: String, location: EPUBLocation) { self.text = text; self.location = location }
}

public enum EPUBReadingFlow: String, Codable, Sendable { case paginated, scrolled }

public struct EPUBReaderStyle: Equatable, Sendable {
    public var fontSize: Double
    public var isDark: Bool
    public var flow: EPUBReadingFlow
    public init(fontSize: Double = 17, isDark: Bool = false, flow: EPUBReadingFlow = .paginated) {
        self.fontSize = fontSize; self.isDark = isDark; self.flow = flow
    }
}

public enum EPUBReaderCapability: String, Hashable, Sendable {
    case pagination, scrolling, typography, selection, bookmarks, locateText, navigateHref, searchHighlight, highlights
}

/// A host-owned highlight drawn while reading. `location.bookmark` names the passage precisely
/// (a selection's range CFI for the bundled reader); highlights the engine cannot resolve are
/// not drawn and are reported with `.notice`.
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
    case searchHighlight(text: String)
    case clearSearch
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

public enum EPUBReaderEvent: Equatable, Sendable {
    /// Emitted exactly once per session when commands can be submitted.
    case ready
    case relocated(EPUBLocation)
    case selectionChanged(EPUBSelection?)
    /// Display these to disclose content the engine withheld or could not render faithfully.
    case disclosure(String)
    case notice(String)
    case failed(EPUBReaderError)
}
