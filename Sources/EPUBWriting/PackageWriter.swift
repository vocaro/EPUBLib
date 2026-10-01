import EPUBCore
import Foundation

/// Publication facts supplied by a producer. No PDF reconstruction or reader UI policy.
public struct EPUBPackageMetadata: Sendable {
    public var metadata: EPUBMetadata
    public var identifier: String
    public var modificationDate: Date
    public var summary: String?
    public var keywords: [String]
    public var created: Date?
    public var rightToLeft: Bool
    public init(metadata: EPUBMetadata, identifier: String, modificationDate: Date,
                summary: String? = nil, keywords: [String] = [], created: Date? = nil,
                rightToLeft: Bool = false) {
        self.metadata = metadata; self.identifier = identifier; self.modificationDate = modificationDate
        self.summary = summary; self.keywords = keywords; self.created = created; self.rightToLeft = rightToLeft
    }
}

public enum EPUBWritingError: Error, Equatable, Sendable {
    case invalidPublication(String)
    case resourceLimit(String)
}

/// Prepared package documents. Content producers supply their XHTML, CSS and media separately.
public enum EPUBPackageWriter {
    public struct Document: Sendable {
        public let path: String
        public let content: String
    }

    /// Resource paths and navigation hrefs are archive-relative; the package lives in EPUB/.
    public static func documents(metadata facts: EPUBPackageMetadata, resources: [EPUBResource],
                                 spine: [EPUBSpineItem], contents: [EPUBNavigationItem],
                                 pages: [EPUBNavigationItem] = [], stylesheet: String? = nil) throws -> [Document] {
        guard !spine.isEmpty else { throw EPUBWritingError.invalidPublication("empty spine") }
        var ids: Set<String> = ["nav"]
        var paths: Set<String> = ["EPUB/nav.xhtml", "EPUB/package.opf", "META-INF/container.xml", "mimetype"]
        for resource in resources {
            guard !resource.id.isEmpty, ids.insert(resource.id).inserted,
                  ResourceReference.isSafePath(resource.path), resource.path.hasPrefix("EPUB/"),
                  paths.insert(resource.path).inserted else {
                throw EPUBWritingError.invalidPublication("duplicate or invalid resource: \(resource.path)")
            }
        }
        guard spine.allSatisfy({ resources.contains($0.resource) }) else {
            throw EPUBWritingError.invalidPublication("spine references an undeclared resource")
        }
        let language = xml(facts.metadata.languages.first ?? "und")
        func href(_ value: String) throws -> String {
            let resolved = try ResourceReference.resolve(value, relativeTo: "root.opf")
            let path = String(resolved.split(separator: "#", maxSplits: 1)[0]).removingPercentEncoding ?? ""
            guard value.hasPrefix("EPUB/"), paths.contains(path), path.hasPrefix("EPUB/") else {
                throw EPUBWritingError.invalidPublication("navigation references an undeclared resource: \(value)")
            }
            return String(value.dropFirst(5))
        }
        func items(_ entries: [EPUBNavigationItem]) throws -> String {
            try entries.map { entry in
                let children = try items(entry.children)
                let nested = children.isEmpty ? "" : "<ol>\(children)</ol>"
                if let target = entry.href {
                    return "<li><a href=\"\(xml(try href(target)))\">\(xml(entry.title))</a>\(nested)</li>"
                }
                return nested.isEmpty ? "" : "<li><span>\(xml(entry.title))</span>\(nested)</li>"
            }.joined()
        }
        let nav = """
        <nav epub:type="toc" id="toc"><h1>Contents</h1><ol>\(try items(contents))</ol></nav>
        <nav epub:type="page-list" hidden="hidden"><h2>Source pages</h2><ol>\(try items(pages))</ol></nav>
        """
        let style = try stylesheet.map { "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(xml(try href($0)))\"/>" } ?? ""
        let navigation = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)" lang="\(language)">
        <head><title>Contents</title>\(style)</head><body>\(nav)</body></html>
        """
        let identifier = xml(facts.identifier)
        let modified = ISO8601DateFormatter().string(from: facts.modificationDate)
        let authors = facts.metadata.authors.map { "<dc:creator>\(xml($0))</dc:creator>" }.joined()
        let summary = facts.summary.map { "<dc:description>\(xml($0))</dc:description>" } ?? ""
        let subjects = facts.keywords.map { "<dc:subject>\(xml($0))</dc:subject>" }.joined()
        let created = facts.created.map {
            "<meta property=\"dcterms:created\">\(ISO8601DateFormatter().string(from: $0))</meta>"
        } ?? ""
        let manifest = resources.map { resource in
            "<item id=\"\(xml(resource.id))\" href=\"\(xml(String(resource.href.dropFirst(5))))\" media-type=\"\(xml(resource.mediaType))\""
                + (resource.properties.isEmpty ? "/>" : " properties=\"\(xml(resource.properties.sorted().joined(separator: " ")))\"/>")
        }.joined()
        let spineMarkup = spine.map {
            "<itemref idref=\"\(xml($0.resource.id))\"" + ($0.isLinear ? "" : " linear=\"no\"")
                + ($0.layout == .reflowable ? "" : " properties=\"rendition:layout-pre-paginated\"") + "/>"
        }.joined()
        let direction = facts.rightToLeft ? " page-progression-direction=\"rtl\"" : ""
        let package = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">\(identifier)</dc:identifier><dc:title>\(xml(facts.metadata.title))</dc:title><dc:language>\(language)</dc:language>\(authors)\(summary)\(subjects)\(created)<meta property="dcterms:modified">\(modified)</meta><meta property="rendition:layout">reflowable</meta></metadata>
        <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\(manifest)</manifest><spine\(direction)>\(spineMarkup)</spine></package>
        """
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        return [.init(path: "EPUB/nav.xhtml", content: navigation),
                .init(path: "EPUB/package.opf", content: package),
                .init(path: "META-INF/container.xml", content: container),
                .init(path: "mimetype", content: "application/epub+zip")]
    }

    private static func xml(_ string: String) -> String {
        String(String.UnicodeScalarView(string.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 ||
                (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) || $0.value >= 0x10000
        })).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
}
