import EPUBCore
import EPUBWriting
import Foundation

/// Shared fixtures for the writer coverage suites. Content is synthetic.
enum WriterCoverage {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let chapter = EPUBResource(id: "c", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml")

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
