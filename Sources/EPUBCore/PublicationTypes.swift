import Foundation

/// Failures opening a publication. Rendering failures belong to `EPUBReaderError`.
public enum EPUBPublicationError: Error, Equatable, Sendable {
    case invalidArchive(String)
    case unsafePath(String)
    case limitExceeded(String)
    case missingResource(String)
    case invalidXML(String)
    case unsupportedEncryption
    /// A ZIP archive with no EPUB `mimetype`: another kind of file, not an EPUB book.
    case notEPUB
    /// Bytes with no ZIP end record: not a ZIP archive, or one cut short, as by a download that
    /// did not finish.
    case notArchive
}

public struct EPUBImportLimits: Sendable {
    public var archiveBytes: Int = 256 * 1024 * 1024
    public var resourceBytes: Int = 32 * 1024 * 1024
    public var expandedBytes: Int = 512 * 1024 * 1024
    public var entryCount: Int = 20_000
    public var xmlBytes: Int = 4 * 1024 * 1024
    public init() {}
}

public struct EPUBMetadata: Equatable, Sendable {
    public let title: String
    public let authors: [String]
    public let languages: [String]
    public let identifiers: [String]
    /// The EPUB Accessibility metadata the package declares, empty when it declares none.
    public let accessibility: EPUBAccessibilityMetadata
    public init(title: String, authors: [String] = [], languages: [String] = [], identifiers: [String] = [],
                accessibility: EPUBAccessibilityMetadata = .init()) {
        self.title = title; self.authors = authors; self.languages = languages; self.identifiers = identifiers
        self.accessibility = accessibility
    }
}

public struct EPUBResource: Equatable, Sendable, Identifiable {
    /// The manifest item's `id`. One read from a package is read as an XML ID is: without the XML
    /// white space (space, tab, line feed, carriage return) at its ends, each run of it inside as
    /// one space.
    public let id: String
    /// Decoded archive path, relative to the archive root.
    public let path: String
    /// URL-encoded archive-relative reference for reader navigation. `path` is for byte access.
    public var href: String { ResourceReference.encoded(path: path) }
    public let mediaType: String
    public let properties: Set<String>
    /// The manifest ID of the next resource in this item's fallback chain, when designated,
    /// read as `id` is.
    public let fallbackID: String?
    public init(id: String, path: String, mediaType: String, properties: Set<String> = [], fallbackID: String? = nil) {
        self.id = id; self.path = path; self.mediaType = mediaType; self.properties = properties
        self.fallbackID = fallbackID
    }
}

public enum EPUBLayout: String, Sendable { case reflowable, prePaginated }

/// The spine's `page-progression-direction`.
public enum EPUBPageProgression: String, Sendable { case ltr, rtl, `default` }

public struct EPUBSpineItem: Equatable, Sendable {
    public let resource: EPUBResource
    public let isLinear: Bool
    /// The itemref's own `rendition:layout` override, the first its `properties` writes when it
    /// has several (EPUB Reading Systems 3.3 §5.5.1), else the package's `rendition:layout`.
    public let layout: EPUBLayout
    public init(resource: EPUBResource, isLinear: Bool = true, layout: EPUBLayout = .reflowable) {
        self.resource = resource; self.isLinear = isLinear; self.layout = layout
    }
}

public struct EPUBNavigationItem: Equatable, Sendable {
    public let title: String
    /// Archive-relative URL reference; may include a fragment. nil for a heading, and for a
    /// link that is remote or cannot name an archive entry.
    public let href: String?
    public let children: [EPUBNavigationItem]
    public init(title: String, href: String? = nil, children: [EPUBNavigationItem] = []) {
        self.title = title; self.href = href; self.children = children
    }
}

/// A structural landmark: an entry of the EPUB 3 navigation document's `landmarks` list or of
/// the EPUB 2 OPF `guide`.
public struct EPUBLandmark: Equatable, Sendable {
    /// The entry's `epub:type` values (`bodymatter`, `toc`…) or the guide reference's `type`
    /// values (`text`, `cover`…), as written.
    public let types: [String]
    public let title: String
    /// Archive-relative URL reference; may include a fragment.
    public let href: String
    public init(types: [String], title: String, href: String) {
        self.types = types; self.title = title; self.href = href
    }
}

/// A print or source page equivalent: an entry of the EPUB 3 navigation document's `page-list`
/// or of the EPUB 2 NCX `pageList`.
public struct EPUBPageListEntry: Codable, Hashable, Sendable {
    /// The page's label, such as `xii` or `5`: the book's own text for it, with ASCII
    /// whitespace stripped from its ends and collapsed. Empty when that text is nothing but
    /// white space of any kind, a lone no-break space included.
    public let label: String
    /// Archive-relative URL reference, usually to the page's `pagebreak` marker by fragment.
    public let href: String
    public init(label: String, href: String) { self.label = label; self.href = href }
}

/// Entries the archive's directory lists that could not be read: the entry at a directory record
/// cut short by the end of the archive, or whose local header offset names no local header, and
/// every entry after it, or the records an end record leaves out of its count. A book is opened
/// without them, as without files the archive lacks: a manifest item for one is left out of
/// `resources`, and a spine that names one is refused.
public struct EPUBLostEntries: Equatable, Sendable {
    /// How many entries were lost: as many as the end record counts beyond those read, or the
    /// records found beyond its count. Directory entries are among them.
    public let count: Int
    /// The archive paths of the lost entries whose names can still be read, in directory order,
    /// decoded as the paths of entries that are read are: all of them, some or none. A name that
    /// the ZIP language-encoding flag (general-purpose bit 11) declares UTF-8 and that is not,
    /// which refuses an entry that is read, has no path: its entry is in `count` and not here.
    public let paths: [String]
    public init(count: Int, paths: [String] = []) { self.count = count; self.paths = paths }
}
