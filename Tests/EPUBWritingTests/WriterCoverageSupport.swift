import EPUBCore
import EPUBWriting
import Foundation

/// Shared fixtures for the writer coverage suites. Content is synthetic.
enum WriterCoverage {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let chapter = EPUBResource(id: "c", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml")
    /// One scalar of each kind that `String` takes into the `Character` of a "/", "\", ":", "#" or
    /// "." written before it, so that by `Character` the separator or dot is not there: a
    /// combining accent and overlay, an enclosing mark, a variation selector of either block, the
    /// zero-width non-joiner and joiner, an emoji modifier, an Indic vowel sign and virama, a
    /// kana voicing mark and a tag.
    static let clusteringMarks = ["\u{301}", "\u{338}", "\u{20E3}", "\u{FE0F}", "\u{E0100}", "\u{200C}", "\u{200D}", "\u{1F3FB}", "\u{93E}",
                                  "\u{94D}", "\u{3099}", "\u{E0020}"]

    /// The characters the writer writes as references, in text and in attribute values.
    static let markup: [Unicode.Scalar] = ["&", "<", ">", "\"", "'"]
    /// Every scalar `String` takes into the `Character` of an "&", "<", ">", `"` or "'" written
    /// before it (`after`), and every scalar that takes one written after it into its own
    /// (`before`), found by asking `String`. `unjoined` is any combining mark with a combining
    /// class, enclosing mark, variation selector, emoji modifier or join control that is not
    /// among the first: there should be none.
    static let joiningMarkup: (after: [Unicode.Scalar], before: [Unicode.Scalar], unjoined: [Unicode.Scalar]) = {
        var after: [Unicode.Scalar] = [], before: [Unicode.Scalar] = [], unjoined: [Unicode.Scalar] = []
        func isOneCharacter(_ first: Unicode.Scalar, _ second: Unicode.Scalar) -> Bool {
            var pair = String.UnicodeScalarView()
            pair.append(first); pair.append(second)
            return String(pair).count == 1
        }
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            // Most scalars join nothing, which one string with the scalar on both sides of each
            // markup character tells of all five at once.
            var screen = String.UnicodeScalarView([scalar])
            for character in markup { screen.append(character); screen.append(scalar) }
            let joins = String(screen).count < 2 * markup.count + 1
            let follows = joins && markup.contains { isOneCharacter($0, scalar) }
            if follows { after.append(scalar) }
            if joins, markup.contains(where: { isOneCharacter(scalar, $0) }) { before.append(scalar) }
            let properties = scalar.properties
            if !follows, properties.canonicalCombiningClass != .notReordered || properties.generalCategory == .enclosingMark
                || properties.isVariationSelector || properties.isEmojiModifier || properties.isJoinControl { unjoined.append(scalar) }
        }
        return (after, before, unjoined)
    }()

    /// `text` with each byte outside ASCII percent-encoded, as a resource's href writes it.
    static func escapingNonASCII(_ text: String) -> String {
        text.utf8.map { $0 < 0x80 ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    static func facts(title: String = "A Book", authors: [String] = ["An Author"], languages: [String] = ["en"],
                      identifier: String = "urn:test:writer-coverage") -> EPUBPackageMetadata {
        .init(metadata: .init(title: title, authors: authors, languages: languages), identifier: identifier, modificationDate: date)
    }
    static func xhtml(_ body: String, title: String = "Chapter") -> Data {
        Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(title)</title></head><body>\(body)</body></html>".utf8)
    }
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writer-coverage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func file(_ name: String, _ data: Data, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
    static func mimetype(in directory: URL) throws -> URL { try file("mimetype", Data("application/epub+zip".utf8), in: directory) }
    static func document(_ path: String, in documents: [EPUBPackageWriter.Document]) throws -> String {
        guard let document = documents.first(where: { $0.path == path }) else { throw CocoaError(.fileNoSuchFile) }
        return document.content
    }
    /// Stages the package documents and content under `directory`, mimetype first, and writes the archive.
    static func archive(_ documents: [EPUBPackageWriter.Document], content: [String: Data], in directory: URL) async throws -> URL {
        let stage = directory.appendingPathComponent("stage-" + UUID().uuidString)
        var entries: [EPUBArchiveWriter.Entry] = []
        for document in documents.sorted(by: { $0.path == "mimetype" || ($1.path != "mimetype" && $0.path < $1.path) }) {
            let url = stage.appendingPathComponent(document.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(document.content.utf8).write(to: url)
            entries.append(.init(path: document.path, fileURL: url))
        }
        // Content is staged under neutral names, so odd archive paths never meet the file system.
        for (index, path) in content.keys.sorted().enumerated() {
            let url = stage.appendingPathComponent("content-\(index)")
            try content[path]!.write(to: url)
            entries.append(.init(path: path, fileURL: url))
        }
        let archive = directory.appendingPathComponent("book-" + UUID().uuidString + ".epub")
        try await EPUBArchiveWriter.write(entries: entries, to: archive, maximumContentBytes: 64 * 1024 * 1024, modificationDate: date)
        return archive
    }
}

/// The elements of a small XML document in document order, for structural assertions on writer output.
final class WriterXMLProbe: NSObject, XMLParserDelegate {
    struct Element {
        /// Qualified name, as written.
        let name: String
        let attributes: [String: String]
        var text = ""
        var children: [Int] = []
    }
    private(set) var elements: [Element] = []
    private var open: [Int] = []

    static func parse(_ string: String) throws -> WriterXMLProbe {
        let probe = WriterXMLProbe()
        let parser = XMLParser(data: Data(string.utf8))
        parser.delegate = probe
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        return probe
    }
    func named(_ name: String) -> [Element] { elements.filter { $0.name == name } }
    func children(of element: Element, named name: String) -> [Element] {
        element.children.map { elements[$0] }.filter { $0.name == name }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        elements.append(Element(name: elementName, attributes: attributes))
        if let parent = open.last { elements[parent].children.append(elements.count - 1) }
        open.append(elements.count - 1)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let index = open.last { elements[index].text += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        open.removeLast()
    }
}
