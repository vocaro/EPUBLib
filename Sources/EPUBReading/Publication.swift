import EPUBCore
import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation

/// An immutable snapshot. Parsing and every engine read the same bytes even if the source file changes.
/// Opening validates ZIP paths, declared sizes, CRCs and actual expanded sizes before returning.
public struct EPUBPublication: Sendable {
    public let id: String
    public let metadata: EPUBMetadata
    public let resources: [EPUBResource]
    public let spine: [EPUBSpineItem]
    public let tableOfContents: [EPUBNavigationItem]
    /// The navigation document's `landmarks` in order or, when it lists none, the OPF `guide`'s
    /// references. Entries whose href does not resolve inside the archive are left out.
    public let landmarks: [EPUBLandmark]
    public let cover: EPUBResource?
    /// The direction pages advance in; `default` leaves it to the reading system.
    public let pageProgression: EPUBPageProgression
    /// Original EPUB bytes, for engines with their own container implementation.
    public let archiveData: Data
    private let contents: [String: Data]

    public func data(for resource: EPUBResource) throws -> Data {
        try data(at: resource.path)
    }

    /// Reads a decoded archive path, never a file-system path or remote URL.
    public func data(at path: String) throws -> Data {
        guard let data = contents[path] else { throw EPUBPublicationError.missingResource(path) }
        return data
    }

    /// Synchronous for CLI/background use. Call off the main actor for large books.
    /// `onProgress` receives cumulative expanded bytes on the importing thread; keep it brief.
    public static func open(at url: URL, limits: EPUBImportLimits = .init(),
                            onProgress: (@Sendable (Int) -> Void)? = nil) throws -> Self {
        guard url.isFileURL else { throw EPUBPublicationError.unsafePath(url.absoluteString) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard limits.archiveBytes > 0, limits.archiveBytes < Int.max else {
            throw EPUBPublicationError.limitExceeded("archiveBytes")
        }
        let data = try handle.read(upToCount: limits.archiveBytes + 1) ?? Data()
        return try open(data: data, limits: limits, onProgress: onProgress)
    }

    /// `onProgress` receives cumulative expanded bytes synchronously, after each decoded chunk.
    public static func open(data: Data, limits: EPUBImportLimits = .init(),
                            onProgress: (@Sendable (Int) -> Void)? = nil) throws -> Self {
        try Task.checkCancellation()
        guard limits.archiveBytes > 0, data.count <= limits.archiveBytes,
              limits.resourceBytes > 0, limits.expandedBytes > 0, limits.entryCount > 0,
              limits.xmlBytes > 0 else { throw EPUBPublicationError.limitExceeded("import limits") }
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) }
        catch { throw EPUBPublicationError.invalidArchive(String(describing: error)) }
        var contents: [String: Data] = [:]
        var paths = Set<String>()
        var total = 0
        for entry in archive {
            try Task.checkCancellation()
            let path = entry.path
            guard ResourceReference.isSafePath(path, directory: entry.type == .directory), entry.type != .symlink else {
                throw EPUBPublicationError.unsafePath(path)
            }
            guard paths.insert(path).inserted else {
                throw EPUBPublicationError.invalidArchive("Duplicate path: \(path)")
            }
            guard paths.count <= limits.entryCount else { throw EPUBPublicationError.limitExceeded("entry count") }
            guard entry.uncompressedSize <= UInt64(limits.resourceBytes),
                  entry.uncompressedSize <= UInt64(limits.expandedBytes - total) else {
                throw EPUBPublicationError.limitExceeded(path)
            }
            if entry.type == .directory { continue }
            var bytes = Data()
            let crc = try archive.extract(entry, bufferSize: 32_768) { chunk in
                try Task.checkCancellation()
                guard chunk.count <= limits.resourceBytes - bytes.count,
                      chunk.count <= limits.expandedBytes - total else {
                    throw EPUBPublicationError.limitExceeded(path)
                }
                bytes.append(chunk)
                total += chunk.count
                onProgress?(total)
                try Task.checkCancellation()
            }
            guard crc == entry.checksum else { throw EPUBPublicationError.invalidArchive("CRC: \(path)") }
            contents[path] = bytes
        }
        guard contents["mimetype"] == Data("application/epub+zip".utf8) else {
            throw EPUBPublicationError.invalidArchive("Missing EPUB mimetype")
        }
        func xml(_ path: String) throws -> XMLNode {
            guard let bytes = contents[path] else { throw EPUBPublicationError.missingResource(path) }
            guard bytes.count <= limits.xmlBytes else { throw EPUBPublicationError.limitExceeded(path) }
            return try XMLTree.parse(bytes, path: path)
        }
        let container = try xml("META-INF/container.xml")
        guard let opfPath = container.descendants("rootfile").first?.attribute("full-path"),
              ResourceReference.isSafePath(opfPath) else { throw EPUBPublicationError.invalidXML("container rootfile") }
        let opf = try xml(opfPath)
        guard opf.name == "package", let manifest = opf.children.first(where: { $0.name == "manifest" }),
              let spineNode = opf.children.first(where: { $0.name == "spine" }) else {
            throw EPUBPublicationError.invalidXML("OPF package, manifest or spine")
        }
        let metadataNode = opf.children.first { $0.name == "metadata" }
        func values(_ name: String) -> [String] {
            metadataNode?.children.filter { $0.name == name }.map(\.text).filter { !$0.isEmpty } ?? []
        }
        if contents["META-INF/encryption.xml"] != nil {
            let encryption = try xml("META-INF/encryption.xml")
            let identifier = metadataNode?.children.first {
                $0.name == "identifier" && $0.attribute("id") == opf.attribute("unique-identifier")
            }?.text ?? ""
            for encrypted in encryption.descendants("EncryptedData") {
                guard let algorithm = encrypted.descendants("EncryptionMethod").first?.attribute("Algorithm"),
                      let uri = encrypted.descendants("CipherReference").first?.attribute("URI"),
                      let path = uri.removingPercentEncoding, ResourceReference.isSafePath(path), var bytes = contents[path] else {
                    throw EPUBPublicationError.unsupportedEncryption
                }
                let key: [UInt8]
                let prefixLength: Int
                switch algorithm {
                case "http://www.idpf.org/2008/embedding":
                    let normalized = identifier.filter { !$0.isWhitespace }
                    guard !normalized.isEmpty else { throw EPUBPublicationError.unsupportedEncryption }
                    key = Array(Insecure.SHA1.hash(data: Data(normalized.utf8)))
                    prefixLength = 1040
                case "http://ns.adobe.com/pdf/enc#RC":
                    let value = identifier.replacingOccurrences(of: "urn:uuid:", with: "")
                    guard let uuid = UUID(uuidString: value) else { throw EPUBPublicationError.unsupportedEncryption }
                    var raw = uuid.uuid
                    key = withUnsafeBytes(of: &raw) { Array($0) }
                    prefixLength = 1024
                default: throw EPUBPublicationError.unsupportedEncryption
                }
                for index in 0..<min(prefixLength, bytes.count) { bytes[index] ^= key[index % key.count] }
                contents[path] = bytes
            }
            guard !encryption.descendants("EncryptedData").isEmpty else {
                throw EPUBPublicationError.unsupportedEncryption
            }
        }
        var resources: [EPUBResource] = []
        var byID: [String: EPUBResource] = [:]
        // Every item the manifest declares, including those whose file the archive lacks.
        var declared: [String: EPUBResource] = [:]
        for item in manifest.children where item.name == "item" {
            guard let id = item.attribute("id"), !id.isEmpty,
                  let href = item.attribute("href"), let type = item.attribute("media-type") else {
                throw EPUBPublicationError.invalidXML("Manifest item")
            }
            let reference = try ResourceReference.resolve(href, relativeTo: opfPath)
            let path = String(reference.split(separator: "#", maxSplits: 1)[0]).removingPercentEncoding ?? reference
            let resource = EPUBResource(id: id, path: path, mediaType: type,
                properties: Set((item.attribute("properties") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)))
            // Some converters write an item more than once; a verbatim repeat adds nothing, but one
            // id naming two different resources is ambiguous.
            if let earlier = declared[id] {
                guard earlier == resource else { throw EPUBPublicationError.invalidXML("Manifest item") }
                continue
            }
            declared[id] = resource
            // An item whose file the archive lacks is left out, as a missing picture is, rather
            // than refusing the book; the spine still needs every document it names (below).
            guard contents[path] != nil else { continue }
            resources.append(resource)
            byID[id] = resource
        }
        let fixedLayout = metadataNode?.children.contains {
            $0.name == "meta" && $0.attribute("property") == "rendition:layout" && $0.text == "pre-paginated"
        } ?? false
        let spine = try spineNode.children.filter { $0.name == "itemref" }.map { item in
            guard let ref = item.attribute("idref"), let named = declared[ref] else {
                throw EPUBPublicationError.invalidXML("Spine idref")
            }
            guard let resource = byID[ref] else { throw EPUBPublicationError.missingResource(named.path) }
            let properties = Set((item.attribute("properties") ?? "").split(whereSeparator: \.isWhitespace))
            let fixed = properties.contains("rendition:layout-pre-paginated") ||
                (fixedLayout && !properties.contains("rendition:layout-reflowable"))
            return EPUBSpineItem(resource: resource, isLinear: item.attribute("linear") != "no",
                                layout: fixed ? .prePaginated : .reflowable)
        }
        guard !spine.isEmpty else { throw EPUBPublicationError.invalidXML("Empty spine") }
        var toc: [EPUBNavigationItem] = []
        var landmarks: [EPUBLandmark] = []
        if let nav = resources.first(where: { $0.properties.contains("nav") }) {
            let root = try xml(nav.path)
            if let node = root.descendants("nav").first(where: { $0.epubTypes.contains("toc") }) {
                func items(_ node: XMLNode) throws -> [EPUBNavigationItem] {
                    try node.children.filter { $0.name == "li" }.map { li in
                        let label = li.children.first { $0.name == "a" || $0.name == "span" }
                        let href = try label?.attribute("href").map { try ResourceReference.resolve($0, relativeTo: nav.path) }
                        let children = try li.children.filter { $0.name == "ol" }.flatMap { try items($0) }
                        return EPUBNavigationItem(title: label?.text ?? "", href: href, children: children)
                    }
                }
                toc = try node.children.filter { $0.name == "ol" }.flatMap { try items($0) }
            }
            // Unlike an unsafe contents href, a landmark that does not resolve is left out rather
            // than refusing a book that opened before landmarks were read.
            if let node = root.descendants("nav").first(where: { $0.epubTypes.contains("landmarks") }) {
                landmarks = node.children.filter { $0.name == "ol" }
                    .flatMap { $0.children.filter { $0.name == "li" } }
                    .compactMap { li in
                        guard let link = li.children.first(where: { $0.name == "a" }), let href = link.attribute("href"),
                              let resolved = try? ResourceReference.resolve(href, relativeTo: nav.path) else { return nil }
                        return EPUBLandmark(types: link.epubTypes, title: link.text, href: resolved)
                    }
            }
        } else if let ncxID = spineNode.attribute("toc"), let ncx = byID[ncxID] {
            let root = try xml(ncx.path)
            func points(_ parent: XMLNode) throws -> [EPUBNavigationItem] {
                try parent.children.filter { $0.name == "navPoint" }.map { point in
                    let title = point.children.first { $0.name == "navLabel" }?.text ?? ""
                    let href = try point.children.first { $0.name == "content" }?.attribute("src").map {
                        try ResourceReference.resolve($0, relativeTo: ncx.path)
                    }
                    return EPUBNavigationItem(title: title, href: href, children: try points(point))
                }
            }
            if let map = root.descendants("navMap").first { toc = try points(map) }
        }
        if landmarks.isEmpty, let guide = opf.children.first(where: { $0.name == "guide" }) {
            landmarks = guide.children.filter { $0.name == "reference" }.compactMap { reference in
                guard let href = reference.attribute("href"),
                      let resolved = try? ResourceReference.resolve(href, relativeTo: opfPath) else { return nil }
                let types = (reference.attribute("type") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
                return EPUBLandmark(types: types, title: reference.attribute("title") ?? "", href: resolved)
            }
        }
        let coverID = metadataNode?.children.first {
            $0.name == "meta" && $0.attribute("name") == "cover"
        }?.attribute("content")
        return Self(id: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            metadata: EPUBMetadata(title: values("title").first ?? "", authors: values("creator"),
                                   languages: values("language"), identifiers: values("identifier")),
            resources: resources, spine: spine, tableOfContents: toc, landmarks: landmarks,
            cover: resources.first { $0.properties.contains("cover-image") } ?? coverID.flatMap { byID[$0] },
            pageProgression: EPUBPageProgression(rawValue: spineNode.attribute("page-progression-direction") ?? "") ?? .default,
            archiveData: data, contents: contents)
    }

}

private enum XMLNamespace {
    static let xml = "http://www.w3.org/XML/1998/namespace"
    static let ops = "http://www.idpf.org/2007/ops"
}

private final class XMLNode {
    /// An attribute's namespace URI ("" when none) and local name.
    struct AttributeName: Hashable { let namespace: String; let local: String }
    /// Local name.
    let name: String
    let attributes: [AttributeName: String]
    var children: [XMLNode] = []
    var content = ""
    var text: String { content.trimmingCharacters(in: .whitespacesAndNewlines) }
    init(_ name: String, _ attributes: [AttributeName: String]) { self.name = name; self.attributes = attributes }
    /// The value of an attribute by local name; `namespace` nil matches an attribute in no namespace.
    func attribute(_ local: String, namespace: String? = nil) -> String? {
        attributes[AttributeName(namespace: namespace ?? "", local: local)]
    }
    /// Whitespace-separated `epub:type` tokens, also from an `epub` prefix the document never
    /// declared, which keeps its prefixed name as a plain attribute.
    var epubTypes: [String] {
        (attribute("type", namespace: XMLNamespace.ops) ?? attribute("epub:type") ?? "")
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }
    func descendants(_ name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
}

/// Keys attributes by namespace and local name, so `epub:type` and an HTML `type` on the same
/// element stay apart. `XMLParser` reports qualified attribute names and passes each element's
/// `xmlns` declarations among its attributes, so prefixes are resolved here.
private final class XMLTree: NSObject, XMLParserDelegate {
    var stack: [XMLNode] = []
    /// The prefixes in scope at each open element, "" for the default namespace.
    var scopes: [[String: String]] = []
    var root: XMLNode?
    var count = 0
    static func parse(_ data: Data, path: String) throws -> XMLNode {
        guard XMLSafety.hasSafeDeclarations(data) else { throw EPUBPublicationError.invalidXML(path) }
        if let root = tree(data) { return root }
        // XML forbids most C0 controls, and some converters copy them from PDF text into titles.
        // With no NUL byte the encoding is ASCII-compatible (not UTF-16 or UTF-32), so each is one
        // byte, and a space in its place cannot change the markup. Read it once more that way.
        guard !data.contains(0), data.contains(where: isForbiddenControl),
              let root = tree(Data(data.map { isForbiddenControl($0) ? 0x20 : $0 })) else {
            throw EPUBPublicationError.invalidXML(path)
        }
        return root
    }
    private static func isForbiddenControl(_ byte: UInt8) -> Bool {
        byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D
    }
    private static func tree(_ data: Data) -> XMLNode? {
        let delegate = XMLTree()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        return parser.parse() ? delegate.root : nil
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        count += 1
        guard stack.count < 64, count <= 100_000 else { parser.abortParsing(); return }
        let local = String(name.split(separator: ":").last ?? Substring(name))
        func isDeclaration(_ key: String) -> Bool { key == "xmlns" || key.hasPrefix("xmlns:") }
        var namespaces = scopes.last ?? ["xml": XMLNamespace.xml]
        for (key, value) in attributes where isDeclaration(key) {
            namespaces[key == "xmlns" ? "" : String(key.dropFirst(6))] = value
        }
        var attrs: [XMLNode.AttributeName: String] = [:]
        for (key, value) in attributes where !isDeclaration(key) {
            // Unprefixed attributes are in no namespace, whatever the default one is.
            let parts = key.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let uri = namespaces[String(parts[0])] {
                attrs[.init(namespace: uri, local: String(parts[1]))] = value
            } else {
                attrs[.init(namespace: "", local: key)] = value
            }
        }
        let node = XMLNode(local, attrs)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
        scopes.append(namespaces)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.content += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.content += String(decoding: CDATABlock, as: UTF8.self)
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) {
        let node = stack.popLast()
        _ = scopes.popLast()
        if let node { stack.last?.content += node.content }
    }
}
