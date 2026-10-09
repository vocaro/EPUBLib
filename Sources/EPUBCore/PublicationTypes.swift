import Foundation

/// Failures opening a publication. Rendering failures belong to `EPUBReaderError`.
public enum EPUBPublicationError: Error, Equatable, Sendable {
    case invalidArchive(String)
    case unsafePath(String)
    case limitExceeded(String)
    case missingResource(String)
    case invalidXML(String)
    case unsupportedEncryption
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
    public init(title: String, authors: [String] = [], languages: [String] = [], identifiers: [String] = []) {
        self.title = title; self.authors = authors; self.languages = languages; self.identifiers = identifiers
    }
}

public struct EPUBResource: Equatable, Sendable, Identifiable {
    public let id: String
    /// Decoded archive path, relative to the archive root.
    public let path: String
    /// URL-encoded archive-relative reference for reader navigation. `path` is for byte access.
    public var href: String {
        path.addingPercentEncoding(withAllowedCharacters:
            .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#%?")))!
    }
    public let mediaType: String
    public let properties: Set<String>
    public init(id: String, path: String, mediaType: String, properties: Set<String> = []) {
        self.id = id; self.path = path; self.mediaType = mediaType; self.properties = properties
    }
}

public enum EPUBLayout: String, Sendable { case reflowable, prePaginated }

/// The spine's `page-progression-direction`.
public enum EPUBPageProgression: String, Sendable { case ltr, rtl, `default` }

public struct EPUBSpineItem: Equatable, Sendable {
    public let resource: EPUBResource
    public let isLinear: Bool
    public let layout: EPUBLayout
    public init(resource: EPUBResource, isLinear: Bool = true, layout: EPUBLayout = .reflowable) {
        self.resource = resource; self.isLinear = isLinear; self.layout = layout
    }
}

public struct EPUBNavigationItem: Equatable, Sendable {
    public let title: String
    /// Archive-relative URL reference; may include a fragment.
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
