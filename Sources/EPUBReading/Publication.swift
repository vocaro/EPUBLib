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
    /// The SHA-256 of the bytes the book was opened from, in hexadecimal: its file's or, for a
    /// book unpacked into a folder, those of every file the folder holds, each with its path. Any
    /// change to them changes it, so it names this copy of the book. Key a saved position on
    /// `persistentID`, which outlasts such changes.
    public let id: String
    /// The identity to key a saved position, bookmark or highlight on, which every location the
    /// reader emits carries as its `publicationID` (#679). It is the package's
    /// `uniqueIdentifier`, which EPUB 3.3 §5.5.3.1.1 asks its makers to keep through minor
    /// revisions such as an edit of the metadata, and so the same in a copy downloaded again,
    /// zipped again, whose metadata was edited or unpacked into a folder. Another edition has
    /// another unique identifier, and another `persistentID`. A package without one has the
    /// SHA-256 of its content, in hexadecimal: each resource it holds, by its path, and the order
    /// of its spine, but not the package document, so that an edit of its metadata leaves it.
    ///
    /// Two books that give one unique identifier have one `persistentID`: EPUB Reading Systems 3.3
    /// §5.2 has a reading system not depend on a unique identifier naming one publication alone.
    /// A position saved in the one is restored in the other as far as its CFI resolves there, and
    /// `releaseIdentifier`, `id` and the metadata tell the two apart.
    public let persistentID: String
    /// The `dc:identifier` that the package's `unique-identifier` names, read as a metadata value;
    /// nil when it names none, or one without a value.
    public let uniqueIdentifier: String?
    /// The unique identifier, `@` and the package's last modification date, its `dcterms:modified`
    /// (EPUB 3.3 §5.5.5): the release identifier EPUB 3.0.1 §4.1.2 defined, the same for one
    /// version of a book and another for the next. nil when the package lacks either.
    public let releaseIdentifier: String?
    /// The publication IDs a location saved in this book may carry, in the order to look a saved
    /// position up under: `persistentID`; the SHA-256 of the content where `persistentID` is the
    /// unique identifier, for a position saved before the package gave one; and `id`, which
    /// locations carried before `persistentID`. The reader restores a location, and draws a
    /// highlight, that carries any of them.
    public let publicationIDs: [String]
    /// The first `dc:title` that has a value and, in document order, every `dc:creator`,
    /// `dc:language` and `dc:identifier` that has one. A value is the element's text with each
    /// run of ASCII whitespace read as one space and none left at either end, so one its
    /// authoring tool wrapped and indented is one line; other white space, a no-break space
    /// among it, is kept inside and at the ends of a value that holds anything else, and an
    /// element that holds nothing but white space of any kind has no value. An element inside the
    /// deprecated `dc-metadata` element, which EPUB 2 packages may have, is read where it stands.
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
    /// entry kept, when the text is nothing but white space of any kind. An image, SVG drawing,
    /// formula or other embedded element in it is read as its alternative text: its `alt`, else
    /// its `title`, else a drawing's `title` element or a formula's `alttext`; one with none of
    /// these is read by its content. A title that is empty then is the link or heading's own
    /// `title`, read the same way, when it has one.
    public let tableOfContents: [EPUBNavigationItem]
    /// The navigation document's `landmarks` in order or, when it lists none, the OPF `guide`'s
    /// references. Entries whose href does not resolve inside the archive are left out. A title
    /// is the link's text read as a contents title is, or a guide reference's `title` read the
    /// same way.
    public let landmarks: [EPUBLandmark]
    /// The navigation document's `page-list` in order, `hidden` or not, or, when it lists none,
    /// the NCX's `pageList`. nil when the book lists no page. Entries whose href does not resolve
    /// inside the archive are left out. A label is read as a contents title is.
    public let pageList: [EPUBPageListEntry]?
    public let cover: EPUBResource?
    /// The direction pages advance in; `default` leaves it to the reading system.
    public let pageProgression: EPUBPageProgression
    /// Original EPUB bytes, for engines with their own container implementation. Empty for a book
    /// unpacked into a folder, which has no archive: read its files with `data(at:)`.
    public let archiveData: Data
    private let contents: [String: Data]
    /// All declared IDs, including missing and remote hops. They are never fetched. By the ID's
    /// code units, as an IDREF names it (`EPUBElementID`), once both are read as XML IDs are
    /// (`XMLNode.identifier`).
    private let manifestByID: [EPUBElementID: EPUBResource]

    /// The designated manifest chain, starting with `resource`, stopping at a missing ID or
    /// before repeating an ID. Missing/remote files remain in the chain so a host can continue
    /// to a later available fallback; the host chooses which media types it supports.
    public func fallbackChain(for resource: EPUBResource) -> [EPUBResource] {
        var chain: [EPUBResource] = [], seen: Set<EPUBElementID> = []
        var next: EPUBResource? = manifestByID[resource.id] ?? resource
        while let item = next, seen.insert(EPUBElementID(item.id)).inserted {
            chain.append(item)
            next = item.fallbackID.flatMap { manifestByID[$0] }
        }
        return chain
    }

    /// A declared local or remote resource, including one whose bytes the archive lacks.
    /// Lookup uses the resolved archive path; this does not load or fetch anything.
    public func manifestResource(at path: String) -> EPUBResource? {
        resources.first { $0.path == path } ?? manifestByID.values.filter { $0.path == path }
            .min { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
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
    ///
    /// `url` names an EPUB file or a book unpacked into a folder (`org.idpf.epub-folder`), as
    /// Apple Books keeps one on the Mac. A folder is read as an archive's entries are, with the
    /// same limits and refusals, but `mimetype` may be missing from it (`PublicationFolder`).
    public static func open(at url: URL, limits: EPUBImportLimits = .init(),
                            onProgress: (@Sendable (Int) -> Void)? = nil) throws -> Self {
        guard url.isFileURL else { throw EPUBPublicationError.unsafePath(url.absoluteString) }
        if let folder = PublicationFolder(url) {
            try Task.checkCancellation()
            try limits.admit(archiveBytes: 0)
            let files = try folder.files(limits: limits, onProgress: onProgress)
            return try open(contents: files, mimetypeRequired: false, limits: limits,
                            id: { Self.digest(files.map { (path: $0.key, data: $0.value) }) },
                            archiveData: Data(), lostEntries: nil)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard limits.archiveBytes > 0, limits.archiveBytes < Int.max else {
            throw EPUBPublicationError.limitExceeded("archiveBytes")
        }
        // A file its length or its ends refuse is refused unread beyond them (`ArchiveFile`).
        var file = ArchiveFile(handle: handle)
        return try open(data: file.bytes(limits: limits), limits: limits, onProgress: onProgress)
    }

    /// `onProgress` receives cumulative expanded bytes synchronously, after each decoded chunk.
    public static func open(data: Data, limits: EPUBImportLimits = .init(),
                            onProgress: (@Sendable (Int) -> Void)? = nil) throws -> Self {
        try Task.checkCancellation()
        try limits.admit(archiveBytes: data.count)
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
        catch Archive.ArchiveError.missingEndOfCentralDirectoryRecord { throw EPUBPublicationError.notArchive }
        catch { throw EPUBPublicationError.invalidArchive(String(describing: error)) }
        // The bytes this archive reads, whatever it was made from.
        let archiveBytes = archive.data ?? data
        let directory = try ArchiveBounds.check(archiveBytes, names: limits.entryCount)
        var contents: [String: Data] = [:]
        var paths = Set<String>()
        var total = 0
        var inputWork = ArchiveInputWork(archiveBytes: archiveBytes.count)
        for (index, entry) in archive.enumerated() {
            try Task.checkCancellation()
            // The entry's path and type, read from its directory record's own bytes.
            let name = try directory.name(at: index, in: archiveBytes)
            let path = try name.path
            guard ResourceReference.isReadablePath(path, directory: name.type == .directory), name.type != .symlink else {
                throw EPUBPublicationError.unsafePath(path)
            }
            guard paths.insert(path).inserted else {
                throw EPUBPublicationError.invalidArchive("Duplicate path: \(path)")
            }
            guard paths.count <= limits.entryCount else { throw EPUBPublicationError.limitExceeded("entry count") }
            // Directories have no data to extract or count toward expanded-byte limits.
            if name.type == .directory { continue }
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
                func consume(_ chunk: Data) throws {
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
                // A deflated entry is inflated with zlib, not by ZIPFoundation, whose decoder
                // gives the same damaged stream different results on different opens (#583).
                if let deflated = directory.deflatedData[index] {
                    crc = try archiveBytes.withUnsafeBytes {
                        try DeflateStream.inflate(UnsafeRawBufferPointer(rebasing: $0[deflated]),
                                                  chunkSize: ArchiveInputWork.chunkSize, consumer: consume)
                    }
                } else {
                    crc = try archive.extract(entry, bufferSize: ArchiveInputWork.chunkSize, consumer: consume)
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
        return try open(contents: contents, mimetypeRequired: true, limits: limits,
                        id: { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() },
                        archiveData: data, lostEntries: directory.lostEntries)
    }

    /// The book in `contents`, the files of an archive or a folder by path. `id` is the
    /// publication's `id`, asked for once the book is read. A folder may lack `mimetype`, which
    /// EPUB 3.3 §4.2.2 reserves for an OCF ZIP container; one it holds must name EPUB, as in an
    /// archive.
    private static func open(contents: [String: Data], mimetypeRequired: Bool, limits: EPUBImportLimits,
                             id: () -> String, archiveData data: Data, lostEntries: EPUBLostEntries?) throws -> Self {
        var contents = contents
        guard (!mimetypeRequired && contents["mimetype"] == nil) || isEPUBMimetype(contents["mimetype"]) else {
            throw EPUBPublicationError.notEPUB
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
        // The children of `metadata`, with those of a `dc-metadata` or `x-metadata` element in its
        // place. OEBPS 1.2 wrapped a package's Dublin Core elements in the first and its `meta`
        // elements in the second, and OPF 2.0.1 §2.2, which deprecates both, has a reading system
        // allow them. They are read in a package of any version, as the rest of it is (#85).
        let metadataElements = (opf.children.first { $0.name == "metadata" }?.children ?? []).flatMap {
            $0.name == "dc-metadata" || $0.name == "x-metadata" ? $0.children : [$0]
        }
        func values(_ name: String) -> [String] {
            metadataElements.filter { $0.name == name }.map(\.text).filter { !$0.isEmpty }
        }
        let identifiers = metadataElements.filter { $0.name == "identifier" }
        // The identifier `unique-identifier` names, by its exact code units once each is read as
        // an XML ID is. A package without the attribute names none, not the first identifier
        // that has no `id`.
        let unique = opf.identifier("unique-identifier").flatMap { id in
            identifiers.first { $0.identifier("id").map { EPUBElementID($0) } == EPUBElementID(id) }
        }
        // Paths obfuscated as fonts with a key the package does not give. A font is left out, as
        // a file the archive lacks is, rather than refusing a book over a typeface. Anything else
        // is encryption this package cannot undo: `unproven` holds the paths not named as fonts,
        // which the manifest has yet to declare as one.
        var undecoded: Set<String> = [], unproven: Set<String> = []
        if contents["META-INF/encryption.xml"] != nil {
            let encryption = try xml("META-INF/encryption.xml")
            // IDPF's key is made from the unique identifier as written, less "specifically, the
            // Unicode code points U+0020, U+0009, U+000D and U+000A" (EPUB 3.3 §4.4.3) and nothing
            // else: white space outside ASCII is part of it, at its ends too. Each is removed as its
            // UTF-8 byte, which is part of no other scalar, so a mark after a space is kept.
            let idpfIdentifier = (unique?.content ?? "").utf8.filter { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D && $0 != 0x0A }
            for encrypted in encryption.descendants("EncryptedData") {
                // The file a URI names, as a URL from the container root or else as the path it
                // is written as (`containerPath`), a font already left out among them. One that
                // names no file is encryption of something this package cannot find.
                guard let algorithm = encrypted.descendants("EncryptionMethod").first?.attribute("Algorithm"),
                      let uri = encrypted.descendants("CipherReference").first?.attribute("URI"),
                      let path = ResourceReference.containerPath(uri, isEntry: { contents[$0] != nil || undecoded.contains($0) }) else {
                    throw EPUBPublicationError.unsupportedEncryption
                }
                // A font already left out stays out, however often it is listed as obfuscated.
                if undecoded.contains(path), Self.obfuscations.contains(algorithm) { continue }
                guard var bytes = contents[path] else { throw EPUBPublicationError.unsupportedEncryption }
                let key: [UInt8]?
                let prefixLength: Int
                switch algorithm {
                case "http://www.idpf.org/2008/embedding":
                    // The key is made from the unique identifier and nothing else. Any text makes
                    // one, so another identifier could not be told right from wrong (#530).
                    key = idpfIdentifier.isEmpty ? nil : Array(Insecure.SHA1.hash(data: idpfIdentifier))
                    prefixLength = 1040
                case "http://ns.adobe.com/pdf/enc#RC":
                    // The key is the package's UUID: the unique identifier or, where that is
                    // not one, the first identifier that is.
                    key = ([unique].compactMap { $0 } + identifiers).lazy.compactMap({ uuidBytes($0.content) }).first
                    prefixLength = 1024
                default: throw EPUBPublicationError.unsupportedEncryption
                }
                guard let key else {
                    contents[path] = nil
                    undecoded.insert(path)
                    if !isFont(mediaType: nil, path: path) { unproven.insert(path) }
                    continue
                }
                for index in 0..<min(prefixLength, bytes.count) { bytes[index] ^= key[index % key.count] }
                contents[path] = bytes
            }
            guard !encryption.descendants("EncryptedData").isEmpty else {
                throw EPUBPublicationError.unsupportedEncryption
            }
        }
        var resources: [EPUBResource] = []
        // Items by their IDs' code units, as an IDREF names them.
        var byID: [EPUBElementID: EPUBResource] = [:]
        // Every item the manifest declares, including those whose file the archive lacks and,
        // under its href for a path, each remote one.
        var declared: [EPUBElementID: EPUBResource] = [:]
        var remote: Set<EPUBElementID> = []
        // Archive paths by their lower-case form, made when a manifest href first matches no entry.
        var folded: [String: [String]]?
        for item in manifest.children where item.name == "item" {
            guard let id = item.identifier("id"), !id.isEmpty,
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
                fallbackID: item.identifier("fallback").flatMap { $0.isEmpty ? nil : $0 })
            // Some converters write an item more than once; a verbatim repeat adds nothing, but one
            // id naming two different resources is ambiguous.
            if let earlier = declared[id] {
                guard earlier == resource, remote.contains(EPUBElementID(id)) == isRemote else { throw EPUBPublicationError.invalidXML("Manifest item") }
                continue
            }
            declared[id] = resource
            // An item whose file the archive lacks is left out, as a missing picture is, rather
            // than refusing the book; the spine still needs every document it names (below).
            // So is a remote item: EPUB 3 lets audio, video and fonts live outside the
            // container, and nothing is ever fetched.
            if isRemote { remote.insert(EPUBElementID(id)) }
            guard !isRemote, contents[path] != nil else { continue }
            resources.append(resource)
            byID[id] = resource
        }
        guard unproven.isEmpty else { throw EPUBPublicationError.unsupportedEncryption }
        let fixedLayout = metadataElements.contains {
            $0.name == "meta" && $0.attribute("property") == "rendition:layout" && $0.text == "pre-paginated"
        }
        // The package's synthetic-spread setting: the first `rendition:spread` that is not a
        // refinement of something else. A value outside the vocabulary leaves the default.
        let spread = metadataElements.first {
            $0.name == "meta" && $0.attribute("property") == "rendition:spread" && $0.attribute("refines") == nil
        }.flatMap { Self.spreads[$0.text] } ?? .auto
        let spine = try spineNode.children.filter { $0.name == "itemref" }.map { item in
            guard let ref = item.identifier("idref"), let named = declared[ref] else {
                throw EPUBPublicationError.invalidXML("Spine idref")
            }
            guard let resource = byID[ref] else {
                if remote.contains(EPUBElementID(ref)) { throw EPUBPublicationError.unsafePath(named.path) }
                if undecoded.contains(named.path) { throw EPUBPublicationError.unsupportedEncryption }
                throw EPUBPublicationError.missingResource(named.path)
            }
            // The item's own layout is the first override its properties write, in their order:
            // of several for one property, a reading system "MUST use only the first value"
            // (EPUB Reading Systems 3.3 §5.5.1). Without one it is the package's.
            let properties = (item.attribute("properties") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            let override = properties.lazy.compactMap { Self.layoutOverrides[$0] }.first
            // The spread overrides and the page's side take the first of each the same way.
            return EPUBSpineItem(resource: resource, isLinear: item.attribute("linear") != "no",
                                layout: override ?? (fixedLayout ? .prePaginated : .reflowable),
                                pageSpread: properties.lazy.compactMap { Self.pageSpreads[$0] }.first,
                                spread: properties.lazy.compactMap { Self.spreadOverrides[$0] }.first ?? spread)
        }
        guard !spine.isEmpty else { throw EPUBPublicationError.invalidXML("Empty spine") }
        var toc: [EPUBNavigationItem] = []
        var landmarks: [EPUBLandmark] = []
        var pages: [EPUBPageListEntry] = []
        // The NCX is the item the spine's `toc` names or, where it names none the archive holds,
        // the first of the NCX's media type that it does. OPF 2.0.1 §2.4 requires `toc`, but
        // converters leave it out or name an item that is not there (#169). The item `toc` names
        // is taken whatever media type it is declared with, as foliate-js and Readium take it. A
        // book without a navigation document is refused when the NCX it names does not parse; one
        // found by its media type was never needed to open the book, so it is ignored.
        let namedNCX = spineNode.identifier("toc").flatMap { byID[$0] }
        let ncx = namedNCX ?? resources.first {
            $0.mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/x-dtbncx+xml"
        }
        // In either page list, as among landmarks, a page whose href does not resolve is left out
        // rather than refusing the book.
        func pageTargets(_ root: XMLNode, _ path: String) -> [EPUBPageListEntry] {
            root.descendants("pageList").first?.children.filter { $0.name == "pageTarget" }.compactMap { target in
                guard let src = target.children.first(where: { $0.name == "content" })?.attribute("src"),
                      let href = try? ResourceReference.resolve(src, relativeTo: path) else { return nil }
                return EPUBPageListEntry(label: target.children.first { $0.name == "navLabel" }?.label ?? "", href: href)
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
                        let link = li.children.first { $0.name == "a" || $0.name == "span" }
                        let href = link?.attribute("href").flatMap { try? ResourceReference.resolve($0, relativeTo: nav.path) }
                        let children = li.children.filter { $0.name == "ol" }.flatMap { items($0) }
                        return EPUBNavigationItem(title: link?.label ?? "", href: href, children: children)
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
                        return EPUBLandmark(types: link.epubTypes, title: link.label, href: resolved)
                    }
            }
            if let node = root.descendants("nav").first(where: { $0.epubTypes.contains("page-list") }) {
                // The list should be flat; a nested one is read in document order.
                func entries(_ list: XMLNode) -> [EPUBPageListEntry] {
                    list.children.filter { $0.name == "li" }.flatMap { li in
                        let link = li.children.first { $0.name == "a" }
                        let entry = link.flatMap { link in
                            link.attribute("href").flatMap { try? ResourceReference.resolve($0, relativeTo: nav.path) }
                                .map { EPUBPageListEntry(label: link.label, href: $0) }
                        }
                        return [entry].compactMap { $0 } + li.children.filter { $0.name == "ol" }.flatMap(entries)
                    }
                }
                pages = node.children.filter { $0.name == "ol" }.flatMap(entries)
            }
        } else if let ncx, let root = try namedNCX.map({ try xml($0.path) }) ?? (try? xml(ncx.path)) {
            func points(_ parent: XMLNode) -> [EPUBNavigationItem] {
                parent.children.filter { $0.name == "navPoint" }.map { point in
                    let title = point.children.first { $0.name == "navLabel" }?.label ?? ""
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
                // The title, read as a navigation landmark's is, so that `landmarks` reads alike
                // from either document (#269).
                return EPUBLandmark(types: types, title: XMLNode.collapsed(reference.attribute("title") ?? ""), href: resolved)
            }
        }
        // `content` is not typed as an IDREF, but it names an item's ID and is read as one.
        let coverID = metadataElements.first {
            $0.name == "meta" && $0.attribute("name") == "cover"
        }?.identifier("content")
        // The identities a saved position is kept under (#679). The unique identifier is read as a
        // metadata value is, its ASCII whitespace collapsed and none at its ends, as EPUB 3.0.1
        // §4.1.2 has a release identifier joined without white space. The last modification date
        // is the `dcterms:modified` that refines nothing.
        let uniqueIdentifier = unique.map(\.text).flatMap { $0.isEmpty ? nil : $0 }
        let modified = metadataElements.first {
            $0.name == "meta" && $0.attribute("property") == "dcterms:modified" && $0.attribute("refines") == nil && !$0.text.isEmpty
        }?.text
        // The content, by each resource's path and bytes, and the spine's order. A path is taken in
        // normalization form C, so that one the file system holds decomposed, as HFS+ kept every
        // name, gives the same.
        var resourcePaths: [String: String] = [:]
        for resource in resources { resourcePaths[resource.path.precomposedStringWithCanonicalMapping] = resource.path }
        let content = digest(resourcePaths.map { (path: $0.key, data: contents[$0.value] ?? Data()) },
                             spine: spine.map(\.resource.path.precomposedStringWithCanonicalMapping))
        let id = id()
        var publicationIDs: [String] = []
        for candidate in [uniqueIdentifier ?? content, content, id] where !publicationIDs.contains(candidate) {
            publicationIDs.append(candidate)
        }
        return Self(id: id, persistentID: publicationIDs[0], uniqueIdentifier: uniqueIdentifier,
            releaseIdentifier: uniqueIdentifier.flatMap { identifier in modified.map { identifier + "@" + $0 } },
            publicationIDs: publicationIDs,
            metadata: EPUBMetadata(title: values("title").first ?? "", authors: values("creator"),
                                   languages: values("language"), identifiers: values("identifier")),
            resources: resources, lostEntries: lostEntries, spine: spine, tableOfContents: toc, landmarks: landmarks,
            pageList: pages.isEmpty ? nil : pages,
            cover: resources.first { $0.properties.contains("cover-image") } ?? coverID.flatMap { byID[$0] },
            pageProgression: EPUBPageProgression(rawValue: spineNode.attribute("page-progression-direction") ?? "") ?? .default,
            archiveData: data, contents: contents, manifestByID: declared)
    }

    /// The SHA-256 of `files` and `spine`, in hexadecimal: each file in the order of its path's
    /// UTF-8, as its path's UTF-8 and its bytes, then each spine path. Each is preceded by its
    /// length, and each list by its count, so that no two inputs give the same bytes to hash.
    static func digest(_ files: [(path: String, data: Data)], spine: [String] = []) -> String {
        var hash = SHA256()
        func add(_ count: Int) { withUnsafeBytes(of: UInt64(count).littleEndian) { hash.update(bufferPointer: $0) } }
        func add(_ bytes: Data) { add(bytes.count); hash.update(data: bytes) }
        let files = files.map { (path: Data($0.path.utf8), data: $0.data) }.sorted { $0.path.lexicographicallyPrecedes($1.path) }
        add(files.count)
        for file in files { add(file.path); add(file.data) }
        add(spine.count)
        for path in spine { add(Data(path.utf8)) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
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

    /// The spine overrides of `rendition:layout` and the layout each gives.
    private static let layoutOverrides: [String: EPUBLayout] = [
        "rendition:layout-pre-paginated": .prePaginated, "rendition:layout-reflowable": .reflowable,
    ]

    /// The values of `rendition:spread`. The deprecated `portrait` is read as `both`, which
    /// spreads in portrait as well.
    private static let spreads: [String: EPUBSpread] = [
        "none": .none, "landscape": .landscape, "both": .both, "auto": .auto, "portrait": .both,
    ]

    /// The spine overrides of `rendition:spread` and the setting each gives.
    private static let spreadOverrides: [String: EPUBSpread] = Dictionary(uniqueKeysWithValues: spreads.map {
        ("rendition:spread-" + $0.key, $0.value)
    })

    /// The itemref properties that put a page on one side of a spread: EPUB 3.3's own
    /// `page-spread-left` and `page-spread-right` and their deprecated `rendition:` forms, and
    /// `rendition:page-spread-center`.
    private static let pageSpreads: [String: EPUBPageSpread] = [
        "page-spread-left": .left, "page-spread-right": .right,
        "rendition:page-spread-left": .left, "rendition:page-spread-right": .right,
        "rendition:page-spread-center": .center,
    ]

    /// Whether a resource is a font: its manifest media type is one's, in any of the spellings
    /// books give them (`font/otf`, `application/x-font-ttf`, `application/vnd.ms-opentype`),
    /// or its file is named as one.
    private static func isFont(mediaType: String?, path: String) -> Bool {
        let type = mediaType?.lowercased() ?? ""
        return type.contains("font") || type.contains("opentype") || type.contains("truetype")
            || ["otf", "ttf", "ttc", "woff", "woff2", "eot"].contains((path as NSString).pathExtension.lowercased())
    }

    /// The sixteen bytes of a UUID, written with or without hyphens and with or without
    /// `urn:uuid:` before it, and with white space of any kind round it (Foundation's
    /// `whitespacesAndNewlines`, by scalar). Adobe's key is the UUID, and its algorithm gives no
    /// rule for the text round it, which adds no digit to it.
    private static func uuidBytes(_ identifier: String) -> [UInt8]? {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
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
    private(set) var children: [XMLNode] = []
    /// The text of the element and of everything inside it, as the parser gives it. A value is
    /// read from it as `text`, and a font obfuscation key is made from it by its algorithm's own
    /// rule, not from `text`.
    var content = ""
    /// The element's own text, as the parser gives it, in the runs its children divide it into:
    /// the first before the first child, each other after the child before it.
    private var runs = [""]
    /// The element's value: its text and that of everything inside it, with each run of ASCII
    /// whitespace (tab, line feed, form feed, carriage return, space) read as one space and
    /// none left at either end. EPUB Reading Systems 3.3 §5.3 requires that of Dublin Core and
    /// `meta` values, and it is how a browser renders a navigation label. White space outside
    /// ASCII, a no-break or an ideographic space, is the author's character and stays wherever
    /// it is in a value that holds anything else. A value of nothing but white space of any kind
    /// (Foundation's `whitespacesAndNewlines`, by scalar) is empty: a lone no-break space is a
    /// tool's placeholder, and no host can show one. ASCII whitespace is read by byte, not by
    /// `Character`: a space is one whatever mark follows it, and the mark stays.
    var text: String { Self.collapsed(content) }
    /// The element as a navigation label: its text read as `text` is, with each embedded element
    /// inside it read as its `alternative`, or, when that is empty, its own `title` read the same
    /// way. EPUB Reading Systems 3.3 §7 has a reading system put a non-text element's alternative
    /// text in its place in a label, and EPUB 3.3 §7.3 has a link or heading holding embedded
    /// content with no text alternative carry its label in a `title`, which foliate-js reads when
    /// the label is empty.
    var label: String {
        let label = Self.collapsed(labelContent)
        guard label.isEmpty, let title = attribute("title") else { return label }
        return Self.collapsed(title)
    }
    /// The element's text and that of everything inside it, each embedded element's `alternative`
    /// in place of its own.
    private var labelContent: String {
        var text = runs[0]
        for (child, run) in zip(children, runs.dropFirst()) { text += (child.alternative ?? child.labelContent) + run }
        return text
    }
    /// What stands for an embedded element in a label: its `alt`, else its `title` (EPUB Reading
    /// Systems 3.3 §7 prefers `alt` where both are given), else an SVG drawing's `title` element or
    /// a formula's `alttext`. nil for any other element, and for one that has none of these, which
    /// is read by its content: a formula's characters, a drawing's text, an object's fallback.
    private var alternative: String? {
        guard Self.embedded.contains(name) else { return nil }
        if let alternative = attribute("alt") ?? attribute("title") { return alternative }
        switch name {
        case "svg": return children.first { $0.name == "title" }?.content
        case "math": return attribute("alttext")
        default: return nil
        }
    }
    /// HTML's embedded content but `picture`, whose image stands for it, by local name, as the
    /// navigation reader matches every element.
    private static let embedded: Set = ["img", "svg", "math", "audio", "video", "canvas", "object", "embed", "iframe"]
    /// A value read as `text` reads `content`, and a guide reference's `title` as a label's.
    static func collapsed(_ value: String) -> String {
        guard !value.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) else { return "" }
        return joined(value) { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0C || $0 == 0x0D }
    }
    /// `value` with each run of the bytes `isSpace` names read as one space and none left at
    /// either end.
    private static func joined(_ value: String, isSpace: (UInt8) -> Bool) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.utf8.count)
        var gap = false
        for byte in value.utf8 {
            if isSpace(byte) { gap = !bytes.isEmpty; continue }
            if gap { bytes.append(0x20); gap = false }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    init(_ name: String, _ attributes: [AttributeName: String]) { self.name = name; self.attributes = attributes }
    /// Adds the next of the element's children, in document order.
    func add(_ child: XMLNode) { children.append(child); runs.append("") }
    /// Adds the next of the parser's text inside the element, not inside a child.
    func add(_ text: String) { content += text; runs[runs.count - 1] += text }
    /// The value of an attribute by local name; `namespace` nil matches an attribute in no namespace.
    func attribute(_ local: String, namespace: String? = nil) -> String? {
        attributes[AttributeName(namespace: namespace ?? "", local: local)]
    }
    /// The value of an attribute in no namespace, read as XML IDs (`id`) and the references to
    /// them (`idref`, `fallback`, `toc`, `unique-identifier`) are read: the package schema gives
    /// them XML Schema's name types (`NCName`, `ID`, `IDREF`), whose white space is collapsed
    /// (XML Schema Part 2 §4.3.6), as a parser normalizes an attribute declared as an ID (XML 1.0
    /// §3.3.3) and as EPUBCheck reads them (#80). Each run of XML white space (space, tab, line
    /// feed, carriage return) is one space and none is left at either end. Other white space, a
    /// no-break space among it, is part of the value. The parser has already read a line break
    /// written in the value as a space.
    func identifier(_ local: String) -> String? {
        attribute(local).map { Self.joined($0) { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D } }
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
        // XMLParser gives no document order, and a dictionary's changes from run to run. Two
        // prefixes for one namespace give two attributes one name, which Namespaces in XML forbids
        // and XMLParser reads on; of those, the one whose qualified name sorts last is kept (#213).
        let attributes = attributes.sorted { $0.key < $1.key }
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
        if let parent = stack.last { parent.add(node) } else { root = node }
        stack.append(node)
        scopes.append(namespaces)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.add(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.add(String(decoding: CDATABlock, as: UTF8.self))
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) {
        let node = stack.popLast()
        _ = scopes.popLast()
        if let node { stack.last?.content += node.content }
    }
}

/// What a browser reads in XHTML and an XML parser refuses, rewritten so that a navigation
/// document reads here as the same file does as a content document: a `DOCTYPE` keyword in
/// another case, and HTML's named character references (`&nbsp;`, `&rcaron;`) as numeric ones.
/// The DTD a DOCTYPE names is never read. The references follow the native viewer's and text
/// extraction's translation, from the HTML Standard's table: CDATA sections and comments are
/// copied unchanged, as processing instructions are here, XML's five predefined names are left
/// for the parser, and UTF-16/32 documents are rewritten in their own encoding, retaining any
/// byte-order mark. Unlike theirs, a name the table lacks (`&bogus;`) is not left for the parser,
/// which would drop it or refuse the document, but kept as the text it spells, in element content
/// and in an attribute value alike.
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
    /// 0x80 for its ASCII character: UTF-8, US-ASCII, the parts of ISO 8859, the Windows code
    /// pages 874 and 1250 to 1258, KOI8-R, Mac OS Roman, TIS-620, EUC-JP, EUC-KR and GB2312.
    private static let asciiTransparentEncodings: Set<String> = {
        var names: Set = ["utf-8", "utf8", "us-ascii", "ascii", "iso-8859-6-e", "iso-8859-6-i", "iso-8859-8-e", "iso-8859-8-i"]
        for part in 1...16 where part != 12 { // ISO 8859 has no part 12.
            names.formUnion(["iso-8859-\(part)", "iso_8859-\(part)", "iso8859-\(part)"])
        }
        for number in 1...10 where number != 7 { names.insert("latin\(number)") }
        for page in [874] + Array(1250...1258) { names.formUnion(["windows-\(page)", "cp\(page)", "x-cp\(page)"]) }
        // The parser reads no byte below 0x80 in these as part of a character of two or three
        // bytes, nor as anything but its ASCII character (#184). It reads `ks_c_5601-1987`,
        // `korean`, `iso-ir-149` and `csksc56011987` as Windows 949, whose second byte may be an
        // ASCII letter, so those names for EUC-KR are not here.
        names.formUnion(["koi8-r", "cskoi8r", "macintosh", "mac", "csmacintosh", "x-mac-roman", "tis-620", "tis620",
                         "euc-jp", "eucjp", "x-euc-jp", "cseucpkdfmtjapanese", "euc-kr", "euckr", "cseuckr",
                         "gb2312", "csgb2312", "euc-cn", "euccn"])
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
        // A byte of a name as XML reads one, with every byte from 0x80 on taken for part of one of
        // its characters: a letter, `_` or `:` first, and after it a digit, `-` or `.` as well.
        func isNameByte(_ byte: UInt8, first: Bool) -> Bool {
            byte >= 0x80 || byte == 0x3A || byte == 0x5F || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A)
                || (!first && (byte == 0x2D || byte == 0x2E || (byte >= 0x30 && byte <= 0x39)))
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
                while end < bytes.count, isNameByte(bytes[end], first: end == index + 1) { end += 1 }
                if end < bytes.count, bytes[end] == 0x3B, end > index + 1 { // ;
                    let name = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                    if !["amp", "lt", "gt", "quot", "apos"].contains(name) {
                        if let reference = HTMLNamedCharacterReferences.numeric[name] {
                            output.append(contentsOf: reference.utf8)
                            index = end + 1
                        } else {
                            // A name HTML does not know is kept as written, as a browser shows
                            // it, where the parser would drop it or refuse the document: its `&`
                            // is escaped and the rest copied as it stands.
                            output.append(contentsOf: "&amp;".utf8)
                            index += 1
                        }
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
