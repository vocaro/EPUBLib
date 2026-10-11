import CoreGraphics
import EPUBCore
import EPUBWriting
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A publication described for `EPUBPackageWriter` with its producer-supplied content, as the
/// EPUBCheck writer tests write it. Content is original and synthetic.
struct EPUBCheckWrittenBook {
    var metadata = EPUBPackageMetadata(metadata: .init(title: "A Written Book", authors: ["Test Author"], languages: ["en"]),
                                       identifier: "urn:uuid:6f0f1d3e-52c4-4d53-9a37-5d1b8f6f2a10",
                                       modificationDate: Date(timeIntervalSince1970: 1_750_000_000))
    var files: [(resource: EPUBResource, data: Data)] = []
    var spine: [EPUBSpineItem] = []
    var contents: [EPUBNavigationItem] = []
    var pages: [EPUBNavigationItem] = []
    var stylesheet: String?

    /// One chapter at `EPUB/chapter.xhtml`, listed in the contents, with no pages.
    static var minimal: EPUBCheckWrittenBook {
        var book = EPUBCheckWrittenBook()
        book.addChapter(id: "chapter", path: "EPUB/chapter.xhtml", title: "Chapter")
        return book
    }

    /// A valid XHTML content document.
    static func page(title: String, body: String, head: String = "", language: String = "en") -> Data {
        Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)" lang="\(language)">
            <head><meta charset="utf-8"/><title>\(escaped(title))</title>\(head)</head><body>\(body)</body></html>
            """.utf8)
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    @discardableResult
    mutating func addChapter(id: String, path: String, title: String, body: String? = nil, head: String = "",
                             linear: Bool = true, listed: Bool = true, properties: Set<String> = []) -> EPUBResource {
        let resource = EPUBResource(id: id, path: path, mediaType: "application/xhtml+xml", properties: properties)
        let heading = "<h1 id=\"start\">\(Self.escaped(title))</h1>"
        files.append((resource, Self.page(title: title, body: body ?? heading + "<p>Original synthetic text for \(Self.escaped(title)).</p>", head: head)))
        spine.append(EPUBSpineItem(resource: resource, isLinear: linear))
        if listed { contents.append(EPUBNavigationItem(title: title, href: resource.href)) }
        return resource
    }

    @discardableResult
    mutating func add(id: String, path: String, mediaType: String, data: Data, properties: Set<String> = []) -> EPUBResource {
        let resource = EPUBResource(id: id, path: path, mediaType: mediaType, properties: properties)
        files.append((resource, data))
        return resource
    }

    func documents() throws -> [EPUBPackageWriter.Document] {
        try EPUBPackageWriter.documents(metadata: metadata, resources: files.map(\.resource), spine: spine,
                                        contents: contents, pages: pages, stylesheet: stylesheet)
    }

    func document(_ path: String) throws -> String {
        try documents().first { $0.path == path }.map(\.content) ?? ""
    }

    /// Stages the prepared documents and content under `directory` and writes `book.epub` there.
    func write(in directory: URL, name: String = "book.epub") async throws -> URL {
        let staging = directory.appendingPathComponent("staging-" + UUID().uuidString)
        var entries: [EPUBArchiveWriter.Entry] = []
        func stage(_ path: String, _ data: Data) throws {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            entries.append(.init(path: path, fileURL: url))
        }
        for document in try documents().sorted(by: { $0.path == "mimetype" || ($1.path != "mimetype" && $0.path < $1.path) }) {
            try stage(document.path, Data(document.content.utf8))
        }
        for file in files { try stage(file.resource.path, file.data) }
        let archive = directory.appendingPathComponent(name)
        try await EPUBArchiveWriter.write(entries: entries, to: archive, maximumContentBytes: 1 << 30,
                                          modificationDate: metadata.modificationDate)
        return archive
    }

    // MARK: Media

    /// A real encoded image of `side` pixels square; `noise` makes it incompressible.
    static func image(_ type: UTType, side: Int = 16, noise: Bool = false) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        var state: UInt32 = 0x2545_F491
        for index in pixels.indices where index % 4 != 3 {
            if noise { state = 1_664_525 &* state &+ 1_013_904_223; pixels[index] = UInt8(state >> 24) }
            else { pixels[index] = UInt8((index / 4 % side) * 255 / max(1, side - 1)) }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    static let svg = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40" width="40" height="40"><title>A square</title>\
        <rect x="4" y="4" width="32" height="32" fill="#369"/></svg>
        """.utf8)
}

/// A parsed XML element, for asserting the structure of what the writer wrote.
final class EPUBCheckXMLElement {
    let name: String
    let attributes: [String: String]
    var children: [EPUBCheckXMLElement] = []
    var text = ""
    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }

    /// Qualified names as written (`dc:title`, `epub:type`). nil when the bytes are not well-formed XML.
    static func parse(_ string: String) -> EPUBCheckXMLElement? {
        let builder = Builder()
        let parser = XMLParser(data: Data(string.utf8))
        parser.delegate = builder
        return parser.parse() ? builder.root : nil
    }

    func descendants(_ name: String) -> [EPUBCheckXMLElement] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
    /// The element's own and its descendants' character data.
    var content: String { text + children.map(\.content).joined() }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: EPUBCheckXMLElement?
        var stack: [EPUBCheckXMLElement] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            let element = EPUBCheckXMLElement(name: name, attributes: attributes)
            if let parent = stack.last { parent.children.append(element) } else { root = element }
            stack.append(element)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    }
}
