import EPUBCore
import Foundation
import libxml2

/// Publication facts supplied by a producer. No PDF reconstruction or reader UI policy.
public struct EPUBPackageMetadata: Sendable {
    public var metadata: EPUBMetadata
    /// The package's unique identifier. The first byte-identical entry in `metadata.identifiers`
    /// carries its XML ID; if absent, this value is prepended. Other entries retain their order
    /// and duplicates, so writing metadata read from a publication does not add another copy.
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
        // The package requires a title and an identifier, and the writer invents neither.
        guard !isEmpty(facts.metadata.title) else { throw EPUBWritingError.invalidPublication("empty title") }
        guard !isEmpty(facts.identifier) else { throw EPUBWritingError.invalidPublication("empty identifier") }
        // By byte, as `ResourceReference` reads a path: as a `Character`, the "/" before a
        // combining mark is another character, and no prefix of the path is "EPUB/".
        func inPackage(_ path: String) -> Bool { path.utf8.starts(with: "EPUB/".utf8) }
        // "nav" is the navigation document's manifest ID, and "book-id" the unique identifier's.
        // IDs compare by code unit, as an IDREF names an item: `caf\u{E9}` and `cafe\u{301}` are two.
        var ids: Set<EPUBElementID> = ["nav"]
        var paths: Set<String> = ["EPUB/nav.xhtml", "EPUB/package.opf", "META-INF/container.xml", "mimetype"]
        for resource in resources {
            guard isName(resource.id), resource.id != "book-id", ids.insert(EPUBElementID(resource.id)).inserted, !isEmpty(resource.mediaType),
                  ResourceReference.isSafePath(resource.path), inPackage(resource.path),
                  paths.insert(resource.path).inserted else {
                throw EPUBWritingError.invalidPublication("duplicate or invalid resource: \(resource.path)")
            }
        }
        for resource in resources {
            if let fallback = resource.fallbackID, !ids.contains(EPUBElementID(fallback)) {
                throw EPUBWritingError.invalidPublication("fallback references an undeclared resource: \(fallback)")
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: resources.map { (EPUBElementID($0.id), $0) })
        var checked: Set<EPUBElementID> = []
        for resource in resources {
            var next: EPUBResource? = resource, current: Set<EPUBElementID> = []
            while let item = next, !checked.contains(EPUBElementID(item.id)) {
                guard current.insert(EPUBElementID(item.id)).inserted else {
                    throw EPUBWritingError.invalidPublication("cyclic manifest fallback: \(item.id)")
                }
                next = item.fallbackID.flatMap { byID[$0] }
            }
            checked.formUnion(current)
        }
        guard spine.allSatisfy({ byID[$0.resource.id] == $0.resource }) else {
            throw EPUBWritingError.invalidPublication("spine references an undeclared resource")
        }
        // An empty value in a list is left out, as the reader leaves it out of what it reads.
        let given = facts.metadata.languages.filter { !isEmpty($0) }
        let languages = given.isEmpty ? ["und"] : given
        let language = xml(languages[0])
        func href(_ value: String) throws -> String {
            let resolved = try ResourceReference.resolve(value, relativeTo: "root.opf", strict: true)
            let path = String(resolved.split(separator: "#", maxSplits: 1)[0]).removingPercentEncoding ?? ""
            // A `Set` finds a path by canonical equivalence; the member it finds is the path declared.
            guard inPackage(value), inPackage(path), let declared = paths.firstIndex(of: path).map({ paths[$0] }),
                  inPackage(declared) else {
                throw EPUBWritingError.invalidPublication("navigation references an undeclared resource: \(value)")
            }
            // The link checked: the declared path from EPUB/nav.xhtml, encoded as its manifest href
            // is, and not the text given after "EPUB/". With an empty or dot segment in it, that
            // text is another link ("/x" names the container root, "//x" a host, "c:x/../x" a
            // scheme), and with a decomposed "é" for a declared composed one, it names by its bytes
            // no entry the archive holds.
            let fragment = resolved.utf8.firstIndex(of: 0x23).map { String(decoding: resolved.utf8[$0...], as: UTF8.self) } ?? "" // #
            return String(decoding: ResourceReference.encoded(path: declared).utf8.dropFirst(5), as: UTF8.self) + fragment
        }
        // EPUB 3.3, 7.3: each entry's link or heading has a text label, and a heading, an entry
        // without a target, is followed by the list of its entries. An entry that cannot be
        // written so is refused, not left out, so each list holds an item for each entry given.
        func items(_ entries: [EPUBNavigationItem]) throws -> String {
            try entries.map { entry in
                guard !isEmpty(entry.title) else {
                    throw EPUBWritingError.invalidPublication("navigation entry without a label" + (entry.href.map { ": \($0)" } ?? ""))
                }
                guard entry.href != nil || !entry.children.isEmpty else {
                    throw EPUBWritingError.invalidPublication("navigation entry without a target: \(entry.title)")
                }
                let nested = entry.children.isEmpty ? "" : "<ol>\(try items(entry.children))</ol>"
                if let target = entry.href {
                    return "<li><a href=\"\(xml(try href(target)))\">\(xml(entry.title))</a>\(nested)</li>"
                }
                return "<li><span>\(xml(entry.title))</span>\(nested)</li>"
            }.joined()
        }
        // The contents `nav` is required, and its list needs an entry.
        guard !contents.isEmpty else { throw EPUBWritingError.invalidPublication("empty contents") }
        let pageItems = try items(pages)
        let pageList = pageItems.isEmpty ? "" : """
        <nav epub:type="page-list" hidden="hidden"><h2>Source pages</h2><ol>\(pageItems)</ol></nav>
        """
        let nav = """
        <nav epub:type="toc" id="toc"><h1>Contents</h1><ol>\(try items(contents))</ol></nav>
        \(pageList)
        """
        let style = try stylesheet.map { "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(xml(try href($0)))\"/>" } ?? ""
        let navigation = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)" lang="\(language)">
        <head><title>Contents</title>\(style)</head><body>\(nav)</body></html>
        """
        var identifierValues = facts.metadata.identifiers.filter { !isEmpty($0) }
        let uniqueIndex: Int
        if let index = identifierValues.firstIndex(where: { $0.utf8.elementsEqual(facts.identifier.utf8) }) {
            uniqueIndex = index
        } else {
            identifierValues.insert(facts.identifier, at: 0)
            uniqueIndex = 0
        }
        let identifiers = identifierValues.enumerated().map { index, value in
            "<dc:identifier" + (index == uniqueIndex ? " id=\"book-id\"" : "") + ">\(xml(value))</dc:identifier>"
        }.joined()
        let languageMarkup = languages.map { "<dc:language>\(xml($0))</dc:language>" }.joined()
        let modified = ISO8601DateFormatter().string(from: facts.modificationDate)
        let authors = facts.metadata.authors.filter { !isEmpty($0) }.map { "<dc:creator>\(xml($0))</dc:creator>" }.joined()
        let summary = facts.summary.flatMap { isEmpty($0) ? nil : "<dc:description>\(xml($0))</dc:description>" } ?? ""
        let subjects = facts.keywords.filter { !isEmpty($0) }.map { "<dc:subject>\(xml($0))</dc:subject>" }.joined()
        let created = facts.created.map {
            "<meta property=\"dcterms:created\">\(ISO8601DateFormatter().string(from: $0))</meta>"
        } ?? ""
        let manifest = resources.map { resource in
            "<item id=\"\(xml(resource.id))\" href=\"\(xml(String(resource.href.dropFirst(5))))\" media-type=\"\(xml(resource.mediaType))\""
                + (resource.fallbackID.map { " fallback=\"\(xml($0))\"" } ?? "")
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
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\(identifiers)<dc:title>\(xml(facts.metadata.title))</dc:title>\(languageMarkup)\(authors)\(summary)\(subjects)\(created)<meta property="dcterms:modified">\(modified)</meta><meta property="rendition:layout">reflowable</meta></metadata>
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

    /// Whether `value` holds nothing a reader can show once written: with what `xml` leaves out
    /// left out, nothing but white space of any kind. EPUB 3.3 asks for no more than something
    /// beside ASCII whitespace, but `EPUBReading` reads a value of nothing but Foundation's
    /// `whitespacesAndNewlines`, a lone no-break space among them, as empty.
    private static func isEmpty(_ value: String) -> Bool {
        xml(value).unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
    }

    /// Whether `id` is an XML name without a colon, as an `id` or `idref` value must be, by the
    /// character classes of XML 1.0 before its fifth edition (Appendix B). libxml2 holds a name to
    /// them, and so does EPUBCheck's validator, character for character. The fifth edition's
    /// wider classes, which hold every name the older ones do, also take names EPUBCheck refuses
    /// (RSC-005): one with U+2170 "ⅰ", U+203F "‿" or a character outside the Basic Multilingual
    /// Plane.
    private static func isName(_ id: String) -> Bool {
        // A NUL, which is no name character, would end the name there for libxml2. It writes a
        // message to standard error of U+FFFE or U+FFFF.
        !id.utf8.contains(0) && LibXML2Messages.silenced { xmlValidateNCName(id, 0) == 0 }
    }

    /// `string` as text or an attribute value, escaped scalar by scalar. As a `Character`, and to
    /// Foundation's string search, a "<", "&" or quote with a combining mark after it is another
    /// character, and would be written as it stands. What XML 1.0 cannot hold is left out.
    private static func xml(_ string: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x26: escaped.append(contentsOf: "&amp;".unicodeScalars)
            case 0x3C: escaped.append(contentsOf: "&lt;".unicodeScalars)
            case 0x3E: escaped.append(contentsOf: "&gt;".unicodeScalars)
            case 0x22: escaped.append(contentsOf: "&quot;".unicodeScalars)
            case 0x27: escaped.append(contentsOf: "&apos;".unicodeScalars)
            case 0x09, 0x0A, 0x0D, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...: escaped.append(scalar)
            default: break
            }
        }
        return String(escaped)
    }
}
