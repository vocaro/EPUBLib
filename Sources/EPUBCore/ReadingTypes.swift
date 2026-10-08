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
    public init(publicationID: String, href: String? = nil, progression: Double? = nil,
                title: String? = nil, quote: String? = nil, bookmark: EPUBEngineBookmark? = nil) {
        self.publicationID = publicationID; self.href = href; self.progression = progression
        self.title = title; self.quote = quote; self.bookmark = bookmark
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
