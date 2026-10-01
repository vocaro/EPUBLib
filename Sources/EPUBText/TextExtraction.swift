import EPUBCore
import EPUBReading
import Foundation
import libxml2

/// Structural text and author-supplied semantics for one occurrence in a publication's spine.
public struct EPUBTextSection: Equatable, Sendable {
    public let spineIndex: Int
    public let resource: EPUBResource
    public let isLinear: Bool
    /// XHTML head/title, with normalized whitespace. No inferred fallback.
    public let title: String?
    public let text: String
    /// EPUB-namespace type tokens throughout the body; no application inclusion policy.
    public let semanticTypes: Set<String>
    /// Positions in this section's normalized UTF-8 text, from the same extraction walk.
    public let anchors: [String: EPUBTextMark]
    public let headings: [EPUBTextHeading]
}

public struct EPUBTextMark: Equatable, Sendable {
    public let offset: Int
    public let separator: Int
    public init(offset: Int, separator: Int) { self.offset = offset; self.separator = separator }
}

public struct EPUBTextHeading: Equatable, Sendable {
    public let mark: EPUBTextMark
    public let text: String
    public init(mark: EPUBTextMark, text: String) { self.mark = mark; self.text = text }
}

public struct EPUBTextExtractionLimits: Sendable {
    public var inputBytes = 4 * 1024 * 1024
    public var outputBytes = 8 * 1024 * 1024
    public var depth = 64
    public var elementCount = 100_000
    public init() {}
}

public enum EPUBTextExtractionError: Error, Equatable, Sendable {
    case invalidSpineIndex(Int)
    case unsupportedMediaType(String)
    case malformedContent(String)
    case limitExceeded(String)
}

extension EPUBPublication {
    /// Extracts one XHTML spine occurrence without a renderer. Call off the main actor for
    /// large documents. All roles and nonlinear entries are retained; hosts choose what to index.
    public func textSection(at index: Int, limits: EPUBTextExtractionLimits = .init()) throws -> EPUBTextSection {
        try Task.checkCancellation()
        guard spine.indices.contains(index) else { throw EPUBTextExtractionError.invalidSpineIndex(index) }
        let item = spine[index]
        guard item.resource.mediaType == "application/xhtml+xml" else {
            throw EPUBTextExtractionError.unsupportedMediaType(item.resource.mediaType)
        }
        guard limits.inputBytes > 0, limits.outputBytes > 0, limits.depth > 0, limits.elementCount > 0 else {
            throw EPUBTextExtractionError.limitExceeded("extraction limits")
        }
        let data = try data(for: item.resource)
        guard data.count <= limits.inputBytes else { throw EPUBTextExtractionError.limitExceeded("inputBytes") }
        guard XMLSafety.hasSafeDeclarations(data) else {
            throw EPUBTextExtractionError.malformedContent(item.resource.path)
        }
        let reader = try XHTMLTextReader.read(data, path: item.resource.path, limits: limits)
        return EPUBTextSection(spineIndex: index, resource: item.resource, isLinear: item.isLinear,
            title: reader.title.text.isEmpty ? nil : reader.title.text, text: reader.body.text,
            semanticTypes: reader.semanticTypes, anchors: reader.body.anchors, headings: reader.body.resolvedHeadings)
    }
}

private struct NormalizedText {
    var text = ""
    var bytes = 0
    private var separator = ""
    var anchors: [String: EPUBTextMark] = [:]
    struct OpenHeading { var mark: EPUBTextMark?; var end = 0 }
    var headings: [OpenHeading] = []
    private var pendingIDs: [String] = []
    private var pendingHeadings: [Int] = []

    mutating func mark(id: String) {
        if !id.isEmpty, anchors[id] == nil, !pendingIDs.contains(id) { pendingIDs.append(id) }
    }
    mutating func openHeading() -> Int {
        headings.append(OpenHeading())
        pendingHeadings.append(headings.count - 1)
        return headings.count - 1
    }
    mutating func closeHeading(_ index: Int) { headings[index].end = bytes }
    mutating func finish() {
        let mark = EPUBTextMark(offset: bytes, separator: 0)
        for id in pendingIDs { anchors[id] = mark }
        for index in pendingHeadings { headings[index].mark = mark }
        pendingIDs.removeAll(); pendingHeadings.removeAll()
    }
    var resolvedHeadings: [EPUBTextHeading] {
        let utf8 = Array(text.utf8)
        return headings.map { heading in
            let mark = heading.mark ?? EPUBTextMark(offset: bytes, separator: 0)
            let value = heading.end > mark.offset ? String(decoding: utf8[mark.offset..<heading.end], as: UTF8.self) : ""
            return EPUBTextHeading(mark: mark, text: value.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
    }

    mutating func lineBreak() { if !text.isEmpty { separator = "\n" } }

    mutating func append(_ value: String, limit: Int) throws {
        for character in value {
            if character.isWhitespace {
                if !text.isEmpty && separator.isEmpty { separator = " " }
            } else {
                let addition = separator + String(character)
                guard addition.utf8.count <= limit - bytes else {
                    throw EPUBTextExtractionError.limitExceeded("outputBytes")
                }
                let mark = EPUBTextMark(offset: bytes + separator.utf8.count, separator: separator.utf8.count)
                for id in pendingIDs { anchors[id] = mark }
                for index in pendingHeadings { headings[index].mark = mark }
                pendingIDs.removeAll(); pendingHeadings.removeAll()
                text += addition
                bytes += addition.utf8.count
                separator = ""
            }
        }
    }
}

private final class XHTMLTextReader {
    private struct Frame {
        var namespaces: [String: String]
        var body: Bool
        var title: Bool
        var suppressed: Bool
        var block: Bool
        var name: String
        var heading: Int?
    }
    private static let blocks: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt", "figcaption",
        "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main",
        "nav", "ol", "p", "pre", "section", "table", "td", "th", "tr", "ul",
    ]
    private let limits: EPUBTextExtractionLimits
    private var stack: [Frame] = []
    private var elements = 0
    private var capturedTitle = false
    var hasHTMLRoot = false
    var bodyCount = 0
    var body = NormalizedText()
    var title = NormalizedText()
    var semanticTypes: Set<String> = []

    init(limits: EPUBTextExtractionLimits) { self.limits = limits }

    static func read(_ data: Data, path: String, limits: EPUBTextExtractionLimits) throws -> XHTMLTextReader {
        guard data.count <= Int(Int32.max) else { throw EPUBTextExtractionError.limitExceeded("inputBytes") }
        return try data.withUnsafeBytes { buffer in
            // libxml2 ships in Apple's SDKs. Its pull reader preserves U+FEFF, including numeric
            // references; Foundation XMLParser drops that character in its String callbacks.
            let options = Int32(XML_PARSE_NONET.rawValue | XML_PARSE_NOERROR.rawValue | XML_PARSE_NOWARNING.rawValue)
            guard let reader = xmlReaderForMemory(buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                Int32(data.count), nil, nil, options) else { throw EPUBTextExtractionError.malformedContent(path) }
            defer { xmlFreeTextReader(reader) }
            let result = XHTMLTextReader(limits: limits)
            func string(_ value: UnsafePointer<xmlChar>?) -> String { value.map { String(cString: $0) } ?? "" }
            while true {
                try Task.checkCancellation()
                let status = xmlTextReaderRead(reader)
                if status == 0 { break }
                guard status == 1 else { throw EPUBTextExtractionError.malformedContent(path) }
                switch xmlTextReaderNodeType(reader) {
                case Int32(XML_READER_TYPE_ELEMENT.rawValue):
                    let name = string(xmlTextReaderConstName(reader))
                    let empty = xmlTextReaderIsEmptyElement(reader) == 1
                    var attributes: [String: String] = [:]
                    if xmlTextReaderMoveToFirstAttribute(reader) == 1 {
                        repeat {
                            attributes[string(xmlTextReaderConstName(reader))] = string(xmlTextReaderConstValue(reader))
                        } while xmlTextReaderMoveToNextAttribute(reader) == 1
                        xmlTextReaderMoveToElement(reader)
                    }
                    try result.start(name, attributes: attributes)
                    if empty { result.end() }
                case Int32(XML_READER_TYPE_END_ELEMENT.rawValue): result.end()
                case Int32(XML_READER_TYPE_TEXT.rawValue), Int32(XML_READER_TYPE_CDATA.rawValue),
                     Int32(XML_READER_TYPE_WHITESPACE.rawValue), Int32(XML_READER_TYPE_SIGNIFICANT_WHITESPACE.rawValue):
                    try result.characters(string(xmlTextReaderConstValue(reader)))
                case Int32(XML_READER_TYPE_ENTITY_REFERENCE.rawValue):
                    throw EPUBTextExtractionError.malformedContent(path)
                default: break
                }
            }
            guard result.hasHTMLRoot, result.bodyCount == 1 else { throw EPUBTextExtractionError.malformedContent(path) }
            result.body.finish()
            return result
        }
    }

    private func start(_ name: String, attributes: [String: String]) throws {
        guard stack.count < limits.depth else { throw EPUBTextExtractionError.limitExceeded("depth") }
        guard elements < limits.elementCount else { throw EPUBTextExtractionError.limitExceeded("elementCount") }
        elements += 1
        var namespaces = stack.last?.namespaces ?? [:]
        for (key, value) in attributes {
            if key == "xmlns" { namespaces[""] = value }
            else if key.hasPrefix("xmlns:") { namespaces[String(key.dropFirst(6))] = value }
        }
        let parts = name.split(separator: ":", maxSplits: 1)
        let local = String(parts.last!)
        let uri = namespaces[parts.count == 2 ? String(parts[0]) : ""] ?? ""
        let html = uri.isEmpty || uri == "http://www.w3.org/1999/xhtml"
        if stack.isEmpty { hasHTMLRoot = html && local == "html" }
        let startsBody = html && local == "body" && stack.count == 1 && stack.last?.name == "html"
        if startsBody { bodyCount += 1 }
        let inBody = startsBody || stack.last?.body == true
        let suppressed = stack.last?.suppressed == true || ["script", "style", "template"].contains(local)
        let startsTitle = html && local == "title" && stack.count == 2 && stack.last?.name == "head" && !capturedTitle
        if startsTitle { capturedTitle = true }
        let block = html && Self.blocks.contains(local) && inBody && !suppressed
        if block { body.lineBreak() }
        if inBody {
            for (key, value) in attributes {
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[1] == "type",
                   namespaces[String(parts[0])] == "http://www.idpf.org/2007/ops" {
                    semanticTypes.formUnion(value.split(whereSeparator: \.isWhitespace).map(String.init))
                }
            }
        }
        var heading: Int?
        if inBody, !suppressed {
            if let id = attributes["id"] { body.mark(id: id) }
            if html, ["h1", "h2", "h3", "h4", "h5", "h6"].contains(local) { heading = body.openHeading() }
        }
        stack.append(Frame(namespaces: namespaces, body: inBody,
            title: startsTitle || stack.last?.title == true, suppressed: suppressed, block: block, name: local, heading: heading))
    }

    private func characters(_ string: String) throws {
        guard let frame = stack.last, !frame.suppressed else { return }
        if frame.body { try body.append(string, limit: limits.outputBytes) }
        if frame.title { try title.append(string, limit: limits.outputBytes) }
    }

    private func end() {
        guard let frame = stack.popLast() else { return }
        if let heading = frame.heading { body.closeHeading(heading) }
        if frame.block { body.lineBreak() }
    }
}
