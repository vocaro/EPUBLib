import EPUBCore
import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation
import libxml2

/// An immutable snapshot. Parsing and every engine read the same bytes even if the source file changes.
/// Opening validates ZIP paths, declared sizes, CRCs and actual expanded sizes before returning.
public struct EPUBPublication: Sendable {
    public let id: String
    /// The first `dc:title` that has a value and, in document order, every `dc:creator`,
    /// `dc:language` and `dc:identifier` that has one. A value is the element's text with each
    /// run of ASCII whitespace read as one space and none left at either end, so one its
    /// authoring tool wrapped and indented is one line; other white space, a no-break space
    /// among it, is kept inside and at the ends of a value that holds anything else, and an
    /// element that holds nothing but white space of any kind has no value.
    public let metadata: EPUBMetadata
    /// The manifest's items whose files the archive holds. A remote item is never fetched and is
    /// left out, as is a font obfuscated with a key the package does not give.
    public let resources: [EPUBResource]
    /// Entries the archive's directory lists that could not be read, which the book was opened
    /// without; nil when every entry it lists was read.
    public let lostEntries: EPUBLostEntries?
    public let spine: [EPUBSpineItem]
    /// The navigation document's `toc` or, without that document, the NCX's `navMap`. An entry
    /// whose href does not resolve inside the archive keeps its title and children, without an href.
    /// A title is the text of the entry's link or heading, or of its `navLabel`, read as a
    /// metadata value is: ASCII whitespace stripped from its ends and collapsed, and empty, its
    /// entry kept, when the text is nothing but white space of any kind.
    public let tableOfContents: [EPUBNavigationItem]
    /// The navigation document's `landmarks` in order or, when it lists none, the OPF `guide`'s
    /// references. Entries whose href does not resolve inside the archive are left out. A title
    /// is the link's text read as a contents title is, or a guide reference's `title` as written.
    public let landmarks: [EPUBLandmark]
    /// The navigation document's `page-list` in order, `hidden` or not, or, when it lists none,
    /// the NCX's `pageList`. nil when the book lists no page. Entries whose href does not resolve
    /// inside the archive are left out. A label is read as a contents title is.
    public let pageList: [EPUBPageListEntry]?
    public let cover: EPUBResource?
    /// The direction pages advance in; `default` leaves it to the reading system.
    public let pageProgression: EPUBPageProgression
    /// Original EPUB bytes, for engines with their own container implementation.
    public let archiveData: Data
    private let contents: [String: Data]
    /// All declared IDs, including missing and remote hops. They are never fetched.
    private let manifestByID: [String: EPUBResource]

    /// The designated manifest chain, starting with `resource`, stopping at a missing ID or
    /// before repeating an ID. Missing/remote files remain in the chain so a host can continue
    /// to a later available fallback; the host chooses which media types it supports.
    public func fallbackChain(for resource: EPUBResource) -> [EPUBResource] {
        var chain: [EPUBResource] = [], seen: Set<String> = []
        var next: EPUBResource? = manifestByID[resource.id] ?? resource
        while let item = next, seen.insert(item.id).inserted {
            chain.append(item)
            next = item.fallbackID.flatMap { manifestByID[$0] }
        }
        return chain
    }

    /// A declared local or remote resource, including one whose bytes the archive lacks.
    /// Lookup uses the resolved archive path; this does not load or fetch anything.
    public func manifestResource(at path: String) -> EPUBResource? {
        resources.first { $0.path == path } ?? manifestByID.values.filter { $0.path == path }.min { $0.id < $1.id }
    }

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
        do {
            // Bytes with no end record where one can be, or with one whose comment they cut
            // short, are no archive. ZIPFoundation says so only after looking for a record at
            // every offset in them, and then never lets go of them (`ArchiveEndRecord`).
            guard let length = data.withUnsafeBytes(ArchiveEndRecord.archiveLength(in:)) else {
                throw Archive.ArchiveError.missingEndOfCentralDirectoryRecord
            }
            // The archive may end before the bytes do. ZIPFoundation is given no more than the
            // archive, in the same memory, and so does not look through what follows it.
            archive = try Archive(data: ZIP64ZeroValues.inlined(in: data.prefix(length)), accessMode: .read)
        }
        catch { throw EPUBPublicationError.invalidArchive(String(describing: error)) }
        // The bytes this archive reads, whatever it was made from.
        let directory = try ArchiveBounds.check(archive.data ?? data, archive: archive, names: limits.entryCount)
        var contents: [String: Data] = [:]
        var paths = Set<String>()
        var total = 0
        var inputWork = ArchiveInputWork(archiveBytes: (archive.data ?? data).count)
        for (index, entry) in archive.enumerated() {
            try Task.checkCancellation()
            let path = EntryName.path(of: entry)
            guard ResourceReference.isReadablePath(path, directory: entry.type == .directory), entry.type != .symlink else {
                throw EPUBPublicationError.unsafePath(path)
            }
            guard paths.insert(path).inserted else {
                throw EPUBPublicationError.invalidArchive("Duplicate path: \(path)")
            }
            guard paths.count <= limits.entryCount else { throw EPUBPublicationError.limitExceeded("entry count") }
            // Directories have no data to extract or count toward expanded-byte limits.
            if entry.type == .directory { continue }
            // An entry that declares more than a limit allows is refused before it is read,
            // unless it is compressed. A compressed entry is not read by its declared size,
            // which may be wrong either way with its data whole: a deflated one is held to the
            // limits below, by what it inflates to, and one in any other method is not read.
            // A data descriptor's size is read by the form of the descriptor's own bytes, not the
            // one ZIPFoundation takes from the entry's version and ZIP64 field (`DataDescriptor`).
            let declared = directory.describedSizes[index] ?? entry.uncompressedSize
            guard entry.isCompressed || (declared <= UInt64(limits.resourceBytes)
                                         && declared <= UInt64(limits.expandedBytes - total)) else {
                throw EPUBPublicationError.limitExceeded(path)
            }
            var bytes = Data()
            inputWork.beginEntry()
            let crc: CRC32
            do {
                crc = try archive.extract(entry, bufferSize: ArchiveInputWork.chunkSize) { chunk in
                    try Task.checkCancellation()
                    guard chunk.count <= limits.resourceBytes - bytes.count,
                          chunk.count <= limits.expandedBytes - total else {
                        throw EPUBPublicationError.limitExceeded(path)
                    }
                    try inputWork.consume(outputBytes: chunk.count)
                    bytes.append(chunk)
                    total += chunk.count
                    onProgress?(total)
                    try Task.checkCancellation()
                }
            }
            catch let error as EPUBPublicationError { throw error }
            catch let error as CancellationError { throw error }
            // A method other than stored and Deflate, or a stream that does not inflate, is
            // damage in the archive however much the entry declares: what it declares is not
            // trusted, and a limit is exceeded only by bytes it inflates to (#74).
            catch { throw EPUBPublicationError.invalidArchive("\(path): \(error)") }
            guard crc == entry.checksum else { throw EPUBPublicationError.invalidArchive("CRC: \(path)") }
            contents[path] = bytes
        }
        guard isEPUBMimetype(contents["mimetype"]) else {
            throw EPUBPublicationError.invalidArchive("Missing EPUB mimetype")
        }
        func xml(_ path: String) throws -> XMLNode {
            guard let bytes = contents[path] else { throw EPUBPublicationError.missingResource(path) }
            guard bytes.count <= limits.xmlBytes else { throw EPUBPublicationError.limitExceeded(path) }
            return try XMLTree.parse(bytes, path: path)
        }
        let container = try xml("META-INF/container.xml")
        // A container may list another rendition, such as a PDF, ahead of the package document.
        // Where no rootfile is typed as a package document, the first is taken for one. Its
        // `full-path` is read as a URL and, failing that, as the archive path it is written as
        // (`rootfilePath`). The one path it yields is the document read and the base of its hrefs.
        let rootfiles = container.descendants("rootfile")
        let rootfile = rootfiles.first {
            $0.attribute("media-type")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/oebps-package+xml"
        } ?? rootfiles.first
        guard let fullPath = rootfile?.attribute("full-path"),
              let opfPath = ResourceReference.rootfilePath(fullPath, isEntry: { contents[$0] != nil }) else {
            throw EPUBPublicationError.invalidXML("container rootfile")
        }
        let opf = try xml(opfPath)
        guard opf.name == "package", let manifest = opf.children.first(where: { $0.name == "manifest" }),
              let spineNode = opf.children.first(where: { $0.name == "spine" }) else {
            throw EPUBPublicationError.invalidXML("OPF package, manifest or spine")
        }
        let metadataNode = opf.children.first { $0.name == "metadata" }
        func values(_ name: String) -> [String] {
            metadataNode?.children.filter { $0.name == name }.map(\.text).filter { !$0.isEmpty } ?? []
        }
        // Paths obfuscated as fonts with a key the package does not give. A font is left out, as
        // a file the archive lacks is, rather than refusing a book over a typeface. Anything else
        // is encryption this package cannot undo: `unproven` holds the paths not named as fonts,
        // which the manifest has yet to declare as one.
        var undecoded: Set<String> = [], unproven: Set<String> = []
        if contents["META-INF/encryption.xml"] != nil {
            let encryption = try xml("META-INF/encryption.xml")
            let identifiers = metadataNode?.children.filter { $0.name == "identifier" } ?? []
            let unique = identifiers.first { $0.attribute("id") == opf.attribute("unique-identifier") }
            let identifier = unique?.keyText ?? ""
            for encrypted in encryption.descendants("EncryptedData") {
                guard let algorithm = encrypted.descendants("EncryptionMethod").first?.attribute("Algorithm"),
                      let uri = encrypted.descendants("CipherReference").first?.attribute("URI"),
                      let path = uri.removingPercentEncoding, ResourceReference.isReadablePath(path) else {
                    throw EPUBPublicationError.unsupportedEncryption
                }
                // A font already left out stays out, however often it is listed as obfuscated.
                if undecoded.contains(path), Self.obfuscations.contains(algorithm) { continue }
                guard var bytes = contents[path] else { throw EPUBPublicationError.unsupportedEncryption }
                let key: [UInt8]
                let prefixLength: Int
                switch algorithm {
                case "http://www.idpf.org/2008/embedding":
                    let normalized = identifier.filter { !$0.isWhitespace }
                    guard !normalized.isEmpty else { throw EPUBPublicationError.unsupportedEncryption }
                    key = Array(Insecure.SHA1.hash(data: Data(normalized.utf8)))
                    prefixLength = 1040
                case "http://ns.adobe.com/pdf/enc#RC":
                    // The key is the package's UUID: the unique identifier or, where that is
                    // not one, the first identifier that is.
                    guard let uuid = ([unique].compactMap { $0 } + identifiers).lazy.compactMap({ uuidBytes($0.keyText) }).first else {
                        contents[path] = nil
                        undecoded.insert(path)
                        if !isFont(mediaType: nil, path: path) { unproven.insert(path) }
                        continue
                    }
                    key = uuid
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
        // Every item the manifest declares, including those whose file the archive lacks and,
        // under its href for a path, each remote one.
        var declared: [String: EPUBResource] = [:]
        var remote: Set<String> = []
        // Archive paths by their lower-case form, made when a manifest href first matches no entry.
        var folded: [String: [String]]?
        for item in manifest.children where item.name == "item" {
            guard let id = item.attribute("id"), !id.isEmpty,
                  let href = item.attribute("href"), let type = item.attribute("media-type") else {
                throw EPUBPublicationError.invalidXML("Manifest item")
            }
            let isRemote = ResourceReference.isRemote(href)
            var path = href
            if !isRemote {
                let reference = try ResourceReference.resolve(href, relativeTo: opfPath)
                path = String(reference.split(separator: "#", maxSplits: 1)[0]).removingPercentEncoding ?? reference
                // A file system that ignores case hides this mismatch from a book's author. The
                // one entry that differs only in case is the one meant; between two, none is.
                if contents[path] == nil {
                    let index = folded ?? Dictionary(grouping: Array(contents.keys) + undecoded) { $0.lowercased() }
                    folded = index
                    if let matches = index[path.lowercased()], matches.count == 1 { path = matches[0] }
                }
                if undecoded.contains(path) {
                    guard isFont(mediaType: type, path: path) else { throw EPUBPublicationError.unsupportedEncryption }
                    unproven.remove(path)
                }
            }
            let resource = EPUBResource(id: id, path: path, mediaType: type,
                properties: Set((item.attribute("properties") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)),
                fallbackID: item.attribute("fallback").flatMap { $0.isEmpty ? nil : $0 })
            // Some converters write an item more than once; a verbatim repeat adds nothing, but one
            // id naming two different resources is ambiguous.
            if let earlier = declared[id] {
                guard earlier == resource, remote.contains(id) == isRemote else { throw EPUBPublicationError.invalidXML("Manifest item") }
                continue
            }
            declared[id] = resource
            // An item whose file the archive lacks is left out, as a missing picture is, rather
            // than refusing the book; the spine still needs every document it names (below).
            // So is a remote item: EPUB 3 lets audio, video and fonts live outside the
            // container, and nothing is ever fetched.
            if isRemote { remote.insert(id) }
            guard !isRemote, contents[path] != nil else { continue }
            resources.append(resource)
            byID[id] = resource
        }
        guard unproven.isEmpty else { throw EPUBPublicationError.unsupportedEncryption }
        let fixedLayout = metadataNode?.children.contains {
            $0.name == "meta" && $0.attribute("property") == "rendition:layout" && $0.text == "pre-paginated"
        } ?? false
        let spine = try spineNode.children.filter { $0.name == "itemref" }.map { item in
            guard let ref = item.attribute("idref"), let named = declared[ref] else {
                throw EPUBPublicationError.invalidXML("Spine idref")
            }
            guard let resource = byID[ref] else {
                if remote.contains(ref) { throw EPUBPublicationError.unsafePath(named.path) }
                if undecoded.contains(named.path) { throw EPUBPublicationError.unsupportedEncryption }
                throw EPUBPublicationError.missingResource(named.path)
            }
            let properties = Set((item.attribute("properties") ?? "").split(whereSeparator: \.isWhitespace))
            let fixed = properties.contains("rendition:layout-pre-paginated") ||
                (fixedLayout && !properties.contains("rendition:layout-reflowable"))
            return EPUBSpineItem(resource: resource, isLinear: item.attribute("linear") != "no",
                                layout: fixed ? .prePaginated : .reflowable)
        }
        guard !spine.isEmpty else { throw EPUBPublicationError.invalidXML("Empty spine") }
        var toc: [EPUBNavigationItem] = []
        var landmarks: [EPUBLandmark] = []
        var pages: [EPUBPageListEntry] = []
        let ncx = spineNode.attribute("toc").flatMap { byID[$0] }
        // In either page list, as among landmarks, a page whose href does not resolve is left out
        // rather than refusing the book.
        func pageTargets(_ root: XMLNode, _ path: String) -> [EPUBPageListEntry] {
            root.descendants("pageList").first?.children.filter { $0.name == "pageTarget" }.compactMap { target in
                guard let src = target.children.first(where: { $0.name == "content" })?.attribute("src"),
                      let href = try? ResourceReference.resolve(src, relativeTo: path) else { return nil }
                return EPUBPageListEntry(label: target.children.first { $0.name == "navLabel" }?.text ?? "", href: href)
            } ?? []
        }
        let nav = resources.first { $0.properties.contains("nav") }
        if let nav {
            let root = try xml(nav.path)
            if let node = root.descendants("nav").first(where: { $0.epubTypes.contains("toc") }) {
                // An entry whose href does not resolve keeps its label and the entries under it,
                // without a target, as a heading does.
                func items(_ node: XMLNode) -> [EPUBNavigationItem] {
                    node.children.filter { $0.name == "li" }.map { li in
                        let label = li.children.first { $0.name == "a" || $0.name == "span" }
                        let href = label?.attribute("href").flatMap { try? ResourceReference.resolve($0, relativeTo: nav.path) }
                        let children = li.children.filter { $0.name == "ol" }.flatMap { items($0) }
                        return EPUBNavigationItem(title: label?.text ?? "", href: href, children: children)
                    }
                }
                toc = node.children.filter { $0.name == "ol" }.flatMap { items($0) }
            }
            // A landmark has nothing under it, so one that does not resolve is left out.
            if let node = root.descendants("nav").first(where: { $0.epubTypes.contains("landmarks") }) {
                landmarks = node.children.filter { $0.name == "ol" }
                    .flatMap { $0.children.filter { $0.name == "li" } }
                    .compactMap { li in
                        guard let link = li.children.first(where: { $0.name == "a" }), let href = link.attribute("href"),
                              let resolved = try? ResourceReference.resolve(href, relativeTo: nav.path) else { return nil }
                        return EPUBLandmark(types: link.epubTypes, title: link.text, href: resolved)
                    }
            }
            if let node = root.descendants("nav").first(where: { $0.epubTypes.contains("page-list") }) {
                // The list should be flat; a nested one is read in document order.
                func entries(_ list: XMLNode) -> [EPUBPageListEntry] {
                    list.children.filter { $0.name == "li" }.flatMap { li in
                        let link = li.children.first { $0.name == "a" }
                        let entry = link.flatMap { link in
                            link.attribute("href").flatMap { try? ResourceReference.resolve($0, relativeTo: nav.path) }
                                .map { EPUBPageListEntry(label: link.text, href: $0) }
                        }
                        return [entry].compactMap { $0 } + li.children.filter { $0.name == "ol" }.flatMap(entries)
                    }
                }
                pages = node.children.filter { $0.name == "ol" }.flatMap(entries)
            }
        } else if let ncx {
            let root = try xml(ncx.path)
            func points(_ parent: XMLNode) -> [EPUBNavigationItem] {
                parent.children.filter { $0.name == "navPoint" }.map { point in
                    let title = point.children.first { $0.name == "navLabel" }?.text ?? ""
                    let href = point.children.first { $0.name == "content" }?.attribute("src").flatMap {
                        try? ResourceReference.resolve($0, relativeTo: ncx.path)
                    }
                    return EPUBNavigationItem(title: title, href: href, children: points(point))
                }
            }
            if let map = root.descendants("navMap").first { toc = points(map) }
            pages = pageTargets(root, ncx.path)
        }
        // An EPUB 3 book's NCX fills a page list its navigation document lacks, as the guide fills
        // landmarks. That NCX was never needed to open the book, so one that does not parse is ignored.
        if pages.isEmpty, nav != nil, let ncx, let root = try? xml(ncx.path) { pages = pageTargets(root, ncx.path) }
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
            resources: resources, lostEntries: directory.lostEntries, spine: spine, tableOfContents: toc, landmarks: landmarks,
            pageList: pages.isEmpty ? nil : pages,
            cover: resources.first { $0.properties.contains("cover-image") } ?? coverID.flatMap { byID[$0] },
            pageProgression: EPUBPageProgression(rawValue: spineNode.attribute("page-progression-direction") ?? "") ?? .default,
            archiveData: data, contents: contents, manifestByID: declared)
    }

    /// Whether the `mimetype` entry names an EPUB. White space around the media type and a
    /// byte-order mark before it, as a text editor leaves them in a book zipped by hand, are
    /// read past.
    private static func isEPUBMimetype(_ data: Data?) -> Bool {
        guard var bytes = data.map({ $0[...] }) else { return false }
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        while let first = bytes.first, isSpace(first) { bytes = bytes.dropFirst() }
        while let last = bytes.last, isSpace(last) { bytes = bytes.dropLast() }
        return bytes.elementsEqual("application/epub+zip".utf8)
    }

    /// The font obfuscation algorithms: IDPF's and Adobe's.
    private static let obfuscations: Set = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]

    /// Whether a resource is a font: its manifest media type is one's, in any of the spellings
    /// books give them (`font/otf`, `application/x-font-ttf`, `application/vnd.ms-opentype`),
    /// or its file is named as one.
    private static func isFont(mediaType: String?, path: String) -> Bool {
        let type = mediaType?.lowercased() ?? ""
        return type.contains("font") || type.contains("opentype") || type.contains("truetype")
            || ["otf", "ttf", "ttc", "woff", "woff2", "eot"].contains((path as NSString).pathExtension.lowercased())
    }

    /// The sixteen bytes of a UUID, written with or without hyphens and with or without
    /// `urn:uuid:` before it.
    private static func uuidBytes(_ identifier: String) -> [UInt8]? {
        let text = identifier.lowercased().hasPrefix("urn:uuid:") ? identifier.dropFirst(9) : Substring(identifier)
        let digits = text.utf8.filter { $0 != 0x2D } // -
        guard digits.count == 32 else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: 32, by: 2) {
            guard let high = Character(UnicodeScalar(digits[index])).hexDigitValue,
                  let low = Character(UnicodeScalar(digits[index + 1])).hexDigitValue else { return nil }
            bytes.append(UInt8(high << 4 | low))
        }
        return bytes
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
    /// The element's value or label: its text and that of everything inside it, with each run of
    /// ASCII whitespace (tab, line feed, form feed, carriage return, space) read as one space and
    /// none left at either end. EPUB Reading Systems 3.3 §5.3 requires that of Dublin Core and
    /// `meta` values, and it is how a browser renders a navigation label. White space outside
    /// ASCII, a no-break or an ideographic space, is the author's character and stays wherever
    /// it is in a value that holds anything else. A value of nothing but white space of any kind
    /// (Foundation's `whitespacesAndNewlines`, the set `keyText` trims, by scalar) is empty: a
    /// lone no-break space is a tool's placeholder, and no host can show one. ASCII whitespace
    /// is read by byte, not by `Character`: a space is one whatever mark follows it, and the
    /// mark stays.
    var text: String {
        guard !content.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) else { return "" }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(content.utf8.count)
        var gap = false
        for byte in content.utf8 {
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D { gap = !bytes.isEmpty; continue }
            if gap { bytes.append(0x20); gap = false }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    /// The content without the white space of any kind at its ends: the identifier a font
    /// obfuscation key is made from. What a key leaves out is its algorithm's rule, not the one
    /// a value is read by, so a key does not start from `text`.
    var keyText: String { content.trimmingCharacters(in: .whitespacesAndNewlines) }
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
        // One attempt: the bytes are rewritten, then screened, then parsed, so that the screen
        // sees the declarations the parser will.
        func attempt(_ bytes: Data) throws -> XMLNode? {
            let source = BrowserMarkup.asXML(bytes)
            guard XMLSafety.hasSafeDeclarations(source) else { throw EPUBPublicationError.invalidXML(path) }
            return tree(source)
        }
        if let root = try attempt(data) { return root }
        // XML forbids most C0 controls, and some converters copy them from PDF text into titles.
        // With no NUL byte the encoding is ASCII-compatible (not UTF-16 or UTF-32), so each is one
        // byte, and a space in its place cannot change the markup. Read it once more that way,
        // from the document's own bytes: a space for a control may change what its declaration
        // says, and with it whether the bytes may be rewritten.
        guard !data.contains(0), data.contains(where: isForbiddenControl),
              let root = try attempt(Data(data.map { isForbiddenControl($0) ? 0x20 : $0 })) else {
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
        // Foundation's parser gives this thread libxml2 handlers of its own for the parse and
        // clears them after it, which would leave a host's own messages to standard error.
        return LibXML2Messages.silenced { parser.parse() } ? delegate.root : nil
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

/// What a browser reads in XHTML and an XML parser refuses, rewritten so that a navigation
/// document reads here as the same file does as a content document: a `DOCTYPE` keyword in
/// another case, and HTML's named character references (`&nbsp;`, `&eacute;`) as numeric ones.
/// The DTD a DOCTYPE names is never read. The references follow the native viewer's and text
/// extraction's translation: CDATA sections and comments are copied unchanged, as processing
/// instructions are here, XML's five predefined names and unknown names are left for the
/// parser, and UTF-16/32 documents are rewritten in their own encoding, retaining any
/// byte-order mark.
///
/// The rewrite takes each byte below 0x80 for its ASCII character, so it is kept from a document
/// whose declared encoding does not: in ISO-2022-JP, HZ or SCSU the bytes of `&pi;` may be parts
/// of other characters.
private enum BrowserMarkup {
    /// `data` rewritten, or as it stands: decided for the bytes given, those one parse attempt
    /// starts from, in one of three ways.
    ///
    /// - A document `wide` takes for UTF-16 or UTF-32, by a byte-order mark or by the NUL bytes
    ///   among its first four, is rewritten as text decoded in that encoding, if it decodes,
    ///   whatever its XML declaration says. The mark or those bytes are trusted for the whole
    ///   document. The parser stays in UTF-16 when the declaration names UTF-8, but can change
    ///   after the declaration to another encoding it names, wide or not, and a document made
    ///   that way can be rewritten wrongly: when its first 90 bytes are a UTF-16LE byte-order
    ///   mark and a declaration naming `UTF-16BE` and the rest is UTF-16BE, bytes of the rest
    ///   that spell `&pi;` in UTF-16LE are replaced, where the parser reads four other
    ///   characters. This is known and left alone.
    /// - A document that starts with the four bytes of `<?xm` in EBCDIC is never rewritten. The
    ///   parser reads such a declaration as EBCDIC and can read what follows in an encoding it
    ///   names, SCSU and HZ among them (one that names UTF-8 it goes on reading as EBCDIC, so a
    ///   document that continues in UTF-8 is refused). The name is not read here.
    /// - Any other is rewritten when `isASCIITransparent` says so, by its XML declaration read
    ///   as ASCII.
    static func asXML(_ data: Data) -> Data {
        guard case let (encoding, mark)? = wide(data) else { return isASCIITransparent(data) ? rewrite(data) ?? data : data }
        guard let text = String(data: data.dropFirst(mark), encoding: encoding),
              let rewritten = rewrite(Data(text.utf8)),
              let encoded = String(decoding: rewritten, as: UTF8.self).data(using: encoding) else { return data }
        return data.prefix(mark) + encoded
    }

    private static func wide(_ data: Data) -> (encoding: String.Encoding, mark: Int)? {
        let prefix = Array(data.prefix(4))
        if prefix.starts(with: [0, 0, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if prefix.starts(with: [0, 0, 0]) { return (.utf32BigEndian, 0) }
        if prefix.starts(with: [0xFF, 0xFE, 0, 0]) { return (.utf32LittleEndian, 4) }
        if prefix.count == 4 && prefix[1...3].allSatisfy({ $0 == 0 }) { return (.utf32LittleEndian, 0) }
        if prefix.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        if prefix.first == 0 { return (.utf16BigEndian, 0) }
        if prefix.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if prefix.count >= 2 && prefix[1] == 0 { return (.utf16LittleEndian, 0) }
        return nil
    }

    /// Whether a document that is not UTF-16 or UTF-32 keeps every byte below 0x80 for its ASCII
    /// character, by its XML declaration read as ASCII: one that names no encoding is UTF-8, and
    /// one that names an encoding must name a listed one. A declaration written in EBCDIC, and
    /// one whose encoding or end is not within `declarationLimit` bytes, may name any.
    ///
    /// The answer relies on three things:
    ///
    /// - The parser takes such a document's encoding from its declaration, whatever bytes
    ///   follow, and reads UTF-8 when there is no declaration or no `encoding` in it. The
    ///   declaration is read here at the document's first byte, or after a UTF-8 byte-order
    ///   mark.
    /// - Only the document's first `declarationLimit` bytes are read. A declaration that shows
    ///   neither an `encoding` nor its end in them is answered no, whatever it goes on to name.
    /// - An encoding is known by the spelling of its name, but for the case of ASCII letters. A
    ///   listed encoding under a spelling that `asciiTransparentEncodings` lacks is answered no.
    ///
    /// Where the answer is no the document is parsed as it stands: one of HTML's named references
    /// is dropped without an error under a DOCTYPE that names an external subset, unless the
    /// declaration says `standalone="yes"`, and is an error otherwise, as a `DOCTYPE` keyword in
    /// another case is. A declaration that is not well formed is not read here as the parser
    /// reads it, and the answer relies on the parser refusing it. `XMLTree.parse` asks again for
    /// the bytes of its second attempt, in which a space for a control character may have made
    /// such a declaration well formed.
    private static func isASCIITransparent(_ data: Data) -> Bool {
        guard !data.starts(with: [0x4C, 0x6F, 0xA7, 0x94]) else { return false } // `<?xm` in EBCDIC
        var bytes = ArraySlice(data.prefix(declarationLimit))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        func isBlank(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        // `<?xml-stylesheet` opens a processing instruction, not the declaration.
        guard bytes.starts(with: "<?xml".utf8), bytes.dropFirst(5).first.map(isBlank) == true else { return true }
        bytes = bytes.dropFirst(5)
        while true {
            bytes = bytes.drop(while: isBlank)
            if bytes.starts(with: "?>".utf8) { return true }
            // A pseudo-attribute: a name, `=` and a value in either kind of quote.
            let name = bytes.prefix { $0 != 0x3D && !isBlank($0) }
            bytes = bytes.dropFirst(name.count).drop(while: isBlank)
            guard bytes.first == 0x3D else { return false }
            bytes = bytes.dropFirst().drop(while: isBlank)
            guard let quote = bytes.first, quote == 0x22 || quote == 0x27,
                  let close = bytes.dropFirst().firstIndex(of: quote) else { return false }
            if name.elementsEqual("encoding".utf8) {
                // The parser compares encoding names without regard to the case of ASCII letters.
                let value = bytes[bytes.index(after: bytes.startIndex)..<close].map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
                return asciiTransparentEncodings.contains(String(decoding: value, as: UTF8.self))
            }
            bytes = bytes[bytes.index(after: close)...]
        }
    }
    private static let declarationLimit = 1024
    /// Names an XML declaration gives, in lower case, to encodings known to keep every byte below
    /// 0x80 for its ASCII character: UTF-8, US-ASCII, the parts of ISO 8859 and the Windows code
    /// pages 1250 to 1258.
    private static let asciiTransparentEncodings: Set<String> = {
        var names: Set = ["utf-8", "utf8", "us-ascii", "ascii", "iso-8859-6-e", "iso-8859-6-i", "iso-8859-8-e", "iso-8859-8-i"]
        for part in 1...16 where part != 12 { // ISO 8859 has no part 12.
            names.formUnion(["iso-8859-\(part)", "iso_8859-\(part)", "iso8859-\(part)"])
        }
        for number in 1...10 where number != 7 { names.insert("latin\(number)") }
        for page in 1250...1258 { names.formUnion(["windows-\(page)", "cp\(page)", "x-cp\(page)"]) }
        return names
    }()

    /// `nil` when nothing changed.
    private static func rewrite(_ data: Data) -> Data? {
        var bytes = [UInt8](data)
        var changed = upperCaseDoctype(&bytes)
        guard bytes.contains(0x26) else { return changed ? Data(bytes) : nil } // &
        var output = [UInt8](); output.reserveCapacity(bytes.count)
        var index = 0
        func starts(_ token: [UInt8], at position: Int) -> Bool {
            position + token.count <= bytes.count && bytes[position..<position + token.count].elementsEqual(token)
        }
        let verbatim = [("<![CDATA[", "]]>"), ("<!--", "-->"), ("<?", "?>")].map { (Array($0.0.utf8), Array($0.1.utf8)) }
        while index < bytes.count {
            if bytes[index] == 0x3C, let (open, close) = verbatim.first(where: { starts($0.0, at: index) }) { // <
                var end = index + open.count
                while end < bytes.count, !starts(close, at: end) { end += 1 }
                end = min(bytes.count, end + close.count)
                output.append(contentsOf: bytes[index..<end]); index = end
                continue
            }
            if bytes[index] == 0x26 {
                var end = index + 1
                while end < bytes.count, end - index <= 32,
                      (bytes[end] >= 0x30 && bytes[end] <= 0x39) || (bytes[end] | 0x20 >= 0x61 && bytes[end] | 0x20 <= 0x7A) {
                    end += 1
                }
                if end < bytes.count, bytes[end] == 0x3B, end > index + 1 { // ;
                    let name = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                    if !["amp", "lt", "gt", "quot", "apos"].contains(name),
                       let entity = name.withCString({ htmlEntityLookup(UnsafeRawPointer($0).assumingMemoryBound(to: xmlChar.self)) }) {
                        output.append(contentsOf: Array("&#\(entity.pointee.value);".utf8))
                        index = end + 1
                        changed = true
                        continue
                    }
                }
            }
            output.append(bytes[index]); index += 1
        }
        return changed ? Data(output) : nil
    }

    /// Writes the keyword of a DOCTYPE in the prolog in upper case, and says whether it was not.
    private static func upperCaseDoctype(_ bytes: inout [UInt8]) -> Bool {
        let doctype = Array("<!DOCTYPE".utf8), comment = Array("<!--".utf8)
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1; continue }
            let rest = bytes[index...]
            if rest.starts(with: [0x3C, 0x3F]) || rest.starts(with: comment) { // <?
                let close: [UInt8] = rest.starts(with: comment) ? [0x2D, 0x2D, 0x3E] : [0x3F, 0x3E] // --> ?>
                index += rest.starts(with: comment) ? comment.count : 2
                while index < bytes.count, !bytes[index...].starts(with: close) { index += 1 }
                index += close.count
                continue
            }
            let keyword = rest.prefix(doctype.count)
            guard !keyword.elementsEqual(doctype),
                  keyword.elementsEqual(doctype, by: { $0 == $1 || ($1 >= 0x41 && $1 <= 0x5A && $0 == $1 | 0x20) }) else { return false }
            bytes.replaceSubrange(index..<index + doctype.count, with: doctype)
            return true
        }
        return false
    }
}
