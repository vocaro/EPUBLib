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
    /// Body text in source order, including authored image/math alternatives and bounded structural MathML notation.
    public let text: String
    /// EPUB-namespace type tokens throughout the body; no application inclusion policy.
    public let semanticTypes: Set<String>
    /// Positions in this section's normalized UTF-8 text, from the same extraction walk.
    public let anchors: [String: EPUBTextMark]
    public let headings: [EPUBTextHeading]
    /// The source was not well-formed XML and was read by the opt-in HTML recovery parser.
    /// Text, anchors and headings come from libxml2's repaired tree, not an XML DOM.
    public let recoveredAsHTML: Bool
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
    /// XHTML 1.x named character references (`&nbsp;`) are supported without loading a DTD.
    /// Markup that is not well-formed XML fails with `malformedContent`.
    public func textSection(at index: Int, limits: EPUBTextExtractionLimits = .init()) throws -> EPUBTextSection {
        try textSection(at: index, limits: limits, recoversMalformedMarkup: false)
    }

    /// As `textSection(at:limits:)`. When `recoversMalformedMarkup` is true, a document that the
    /// strict XML path rejects as not well-formed is read by libxml2's network-free HTML parser,
    /// after an HTML-specific declaration check, and the section reports `recoveredAsHTML`.
    public func textSection(at index: Int, limits: EPUBTextExtractionLimits = .init(),
                            recoversMalformedMarkup: Bool) throws -> EPUBTextSection {
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
        let reader: XHTMLTextReader
        let safety = XMLSafety.assess(data)
        guard safety != .attributeLimitExceeded else { throw EPUBTextExtractionError.limitExceeded("attributesPerElement") }
        if safety == .safe {
            do {
                let source = NamedCharacterReferences.numeric(in: data)
                let rewrittenSafety = source == data ? safety : XMLSafety.assess(source)
                guard rewrittenSafety != .attributeLimitExceeded else { throw EPUBTextExtractionError.limitExceeded("attributesPerElement") }
                guard rewrittenSafety == .safe else { throw EPUBTextExtractionError.malformedContent(item.resource.path) }
                reader = try XHTMLTextReader.read(source, path: item.resource.path, limits: limits)
            } catch XHTMLTextReader.ParseFailure.notWellFormed {
                // Only a parser verdict is recoverable; limits, cancellation and a well-formed
                // but non-XHTML structure still propagate.
                guard recoversMalformedMarkup else { throw EPUBTextExtractionError.malformedContent(item.resource.path) }
                reader = try XHTMLTextReader.recover(data, path: item.resource.path, limits: limits)
            }
        } else {
            // XMLSafety follows XML lexical rules, so malformed HTML (an attribute value whose
            // closing quote is missing) can defeat it. Such bytes never reach the XML parser.
            // Recovery applies its own stricter declaration check to the bytes it parses.
            guard recoversMalformedMarkup else { throw EPUBTextExtractionError.malformedContent(item.resource.path) }
            reader = try XHTMLTextReader.recover(data, path: item.resource.path, limits: limits)
        }
        return EPUBTextSection(spineIndex: index, resource: item.resource, isLinear: item.isLinear,
            title: reader.title.text.isEmpty ? nil : reader.title.text, text: reader.body.text,
            semanticTypes: reader.semanticTypes, anchors: reader.body.anchors, headings: reader.body.resolvedHeadings,
            recoveredAsHTML: reader.recovered)
    }
}

private struct NormalizedText {
    var text = ""
    var bytes = 0
    private var separator = ""
    var anchors: [String: EPUBTextMark] = [:]
    struct OpenHeading { var mark: EPUBTextMark?; var end = 0 }
    var headings: [OpenHeading] = []
    private var pendingIDs: Set<String> = []
    private var pendingHeadings: [Int] = []

    mutating func mark(id: String) {
        if !id.isEmpty, anchors[id] == nil { pendingIDs.insert(id) }
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
            return EPUBTextHeading(mark: mark, text: value.unicodeScalars.split(whereSeparator: { $0.properties.isWhitespace }).map(String.init).joined(separator: " "))
        }
    }

    mutating func lineBreak() { if !text.isEmpty { separator = "\n" } }

    mutating func append(_ value: String, limit: Int) throws {
        // Whitespace belongs to individual scalars. A space followed by a combining mark
        // forms one Character whose isWhitespace is true; discarding it would lose the mark.
        for scalar in value.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !text.isEmpty && separator.isEmpty { separator = " " }
            } else {
                let addition = separator + String(scalar)
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
        var root: Bool
        var title: Bool
        var suppressed: Bool
        var block: Bool
        var name: String
        var heading: Int?
        var math: MathTextNode?
        var startsMath: Bool
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
    var recovered = false
    var hasHTMLRoot = false
    var bodyCount = 0
    var body = NormalizedText()
    var title = NormalizedText()
    var semanticTypes: Set<String> = []

    init(limits: EPUBTextExtractionLimits) { self.limits = limits }

    /// The XML parser rejected the bytes (not well-formed, or an undeclared entity reference).
    enum ParseFailure: Error { case notWellFormed }

    static func read(_ data: Data, path: String, limits: EPUBTextExtractionLimits) throws -> XHTMLTextReader {
        guard data.count <= Int(Int32.max) else { throw EPUBTextExtractionError.limitExceeded("inputBytes") }
        // The reader parses as it is read, and writes a validity or decoder error to standard error.
        return try LibXML2Messages.silenced { try data.withUnsafeBytes { buffer in
            // libxml2 ships in Apple's SDKs. Its pull reader preserves U+FEFF, including numeric
            // references; Foundation XMLParser drops that character in its String callbacks.
            let options = Int32(XML_PARSE_NONET.rawValue | XML_PARSE_NOERROR.rawValue | XML_PARSE_NOWARNING.rawValue)
            guard let reader = xmlReaderForMemory(buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                Int32(data.count), nil, nil, options) else { throw ParseFailure.notWellFormed }
            defer { xmlFreeTextReader(reader) }
            let result = XHTMLTextReader(limits: limits)
            func string(_ value: UnsafePointer<xmlChar>?) -> String { value.map { String(cString: $0) } ?? "" }
            while true {
                try Task.checkCancellation()
                let status = xmlTextReaderRead(reader)
                if status == 0 { break }
                guard status == 1 else { throw ParseFailure.notWellFormed }
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
                    if empty { try result.end() }
                case Int32(XML_READER_TYPE_END_ELEMENT.rawValue): try result.end()
                case Int32(XML_READER_TYPE_TEXT.rawValue), Int32(XML_READER_TYPE_CDATA.rawValue),
                     Int32(XML_READER_TYPE_WHITESPACE.rawValue), Int32(XML_READER_TYPE_SIGNIFICANT_WHITESPACE.rawValue):
                    try result.characters(string(xmlTextReaderConstValue(reader)))
                case Int32(XML_READER_TYPE_ENTITY_REFERENCE.rawValue):
                    // A name outside XML's and XHTML's sets; its DTD is never loaded.
                    throw ParseFailure.notWellFormed
                default: break
                }
            }
            guard result.hasHTMLRoot, result.bodyCount == 1 else { throw EPUBTextExtractionError.malformedContent(path) }
            result.body.finish()
            return result
        } }
    }

    /// Reads markup that is not well-formed XML with libxml2's HTML parser, as the native viewer
    /// does, then walks the repaired tree through the same bounded extraction callbacks. The HTML
    /// parser loads no DTD or network resource and supports no entity declarations; in addition,
    /// `HTMLRecoverySource` refuses declaration syntax anywhere in the bytes it parses.
    /// Input must be UTF-8 or a detectable UTF-16/32, as EPUB requires.
    static func recover(_ data: Data, path: String, limits: EPUBTextExtractionLimits) throws -> XHTMLTextReader {
        guard let utf8 = SourceEncoding.utf8(data),
              let ampersands = HTMLLiteralAmpersands.prepared(utf8, limit: Int(Int32.max)),
              let source = HTMLRecoverySource.prepare(ampersands.data) else {
            throw EPUBTextExtractionError.malformedContent(path)
        }
        guard source.count <= Int(Int32.max) else { throw EPUBTextExtractionError.limitExceeded("inputBytes") }
        guard XMLSafety.hasBoundedAttributes(source, asHTML: true) else { throw EPUBTextExtractionError.limitExceeded("attributesPerElement") }
        let options = Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
            | HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NODEFDTD.rawValue)
        guard let context = htmlNewParserCtxt() else { throw EPUBTextExtractionError.malformedContent(path) }
        defer { htmlFreeParserCtxt(context) }
        let document = LibXML2Messages.silenced {
            source.withUnsafeBytes { buffer in
                htmlCtxtReadMemory(context, buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buffer.count), nil, "UTF-8", options)
            }
        }
        guard let document else { throw EPUBTextExtractionError.malformedContent(path) }
        defer { xmlFreeDoc(document) }
        // libxml2 halts, keeping a truncated tree, at its built-in nesting cap (256 without
        // XML_PARSE_HUGE, which is never enabled) or on resource exhaustion. Recovery errors do
        // not halt. A halted parse never yields partial text.
        if context.pointee.disableSAX != 0 {
            throw Self.treeDepth(document) >= 256 ? EPUBTextExtractionError.limitExceeded("depth")
                : EPUBTextExtractionError.malformedContent(path)
        }
        let result = XHTMLTextReader(limits: limits)
        result.recovered = true
        func string(_ value: UnsafePointer<xmlChar>?) -> String {
            HTMLLiteralAmpersands.restored(value.map { String(cString: $0) } ?? "", placeholder: ampersands.placeholder)
        }
        func qualified(_ name: UnsafePointer<xmlChar>?, _ namespace: xmlNsPtr?) -> String {
            guard let prefix = namespace?.pointee.prefix else { return string(name) }
            return string(prefix) + ":" + string(name)
        }
        // Iterative preorder walk: libxml2's tree depth never becomes Swift stack depth.
        var current = document.pointee.children
        while let node = current {
            try Task.checkCancellation()
            var descends = false
            switch node.pointee.type {
            case XML_ELEMENT_NODE:
                var attributes: [String: String] = [:]
                var attribute = node.pointee.properties
                while let property = attribute {
                    var value = ""
                    var part = property.pointee.children
                    while let text = part {
                        if let content = text.pointee.content { value += string(content) }
                        part = text.pointee.next
                    }
                    attributes[qualified(property.pointee.name, property.pointee.ns)] = value
                    attribute = property.pointee.next
                }
                try result.start(qualified(node.pointee.name, node.pointee.ns), attributes: attributes)
                descends = node.pointee.children != nil
                if !descends { try result.end() }
            case XML_TEXT_NODE, XML_CDATA_SECTION_NODE:
                if let content = node.pointee.content { try result.characters(string(content)) }
            default: break // Comments, processing instructions and the DOCTYPE.
            }
            if descends { current = node.pointee.children; continue }
            var finished = node
            while finished.pointee.next == nil {
                guard let parent = finished.pointee.parent, parent.pointee.type == XML_ELEMENT_NODE else { break }
                try result.end()
                finished = parent
            }
            current = finished.pointee.next
        }
        guard result.hasHTMLRoot, result.bodyCount == 1 else { throw EPUBTextExtractionError.malformedContent(path) }
        result.body.finish()
        return result
    }

    /// Element nesting of a libxml2 tree, root element = 1, without recursion.
    private static func treeDepth(_ document: htmlDocPtr) -> Int {
        var deepest = 0, depth = 0
        var current = document.pointee.children
        while let node = current {
            if node.pointee.type == XML_ELEMENT_NODE {
                depth += 1
                deepest = max(deepest, depth)
                if let child = node.pointee.children { current = child; continue }
                depth -= 1
            }
            var finished = node
            while finished.pointee.next == nil, let parent = finished.pointee.parent, parent.pointee.type == XML_ELEMENT_NODE {
                depth -= 1
                finished = parent
            }
            current = finished.pointee.next
        }
        return deepest
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
        // XML 1.0's Name (and libxml2's HTML parser) admit names made only of colons, which have
        // no piece to split off. Like libxml2, read such a name whole, as an unprefixed element.
        let parts = name.split(separator: ":", maxSplits: 1)
        let local = parts.last.map(String.init) ?? name
        var uri = namespaces[parts.count == 2 ? String(parts[0]) : ""] ?? ""
        if recovered, parts.count == 1, uri.isEmpty || uri == "http://www.w3.org/1999/xhtml", local == "math", stack.last?.math == nil {
            // HTML places an undeclared <math> subtree in the MathML namespace.
            namespaces[""] = MathTextNode.namespace
            uri = MathTextNode.namespace
        }
        let html = uri.isEmpty || uri == "http://www.w3.org/1999/xhtml"
        if stack.isEmpty { hasHTMLRoot = html && local == "html" }
        // The root; and in a recovered tree, an `html` element that libxml2 builds in a root:
        // once an out-of-place `<html/>` has closed the root it had open, it opens another
        // there, or beside the first after a DOCTYPE or a comment, for what follows (#292).
        let root = html && local == "html" && (stack.isEmpty || (recovered && stack.last?.root == true))
        let startsBody = html && local == "body" && stack.last?.root == true
        // In a recovered tree a second body goes on with the first: HTML gives a later `<body>`
        // tag's attributes to the body and reads on in it, where libxml2 builds a second one
        // after an out-of-place `<body/>` has closed the first (#292).
        if startsBody, bodyCount == 0 || !recovered { bodyCount += 1 }
        // Well-formed XML may put content after </body>, still inside the root. The native
        // writer walks those authored siblings too; retain their characters/marks without
        // rewriting the strict XML document or changing its source positions.
        let afterBody = bodyCount == 1 && stack.last?.root == true
        let inBody = startsBody || stack.last?.body == true || afterBody
        let suppressed = stack.last?.suppressed == true || ["script", "style", "template"].contains(local)
        // The head's title; and in a recovered tree, a title libxml2 builds in the root before
        // the body, after an out-of-place `<head/>` or `<html/>` has closed the head. HTML
        // builds it in the head.
        let startsTitle = html && local == "title" && !capturedTitle
            && ((stack.count >= 2 && stack.last?.name == "head" && stack[stack.count - 2].root)
                || (recovered && stack.last?.root == true && bodyCount == 0))
        if startsTitle { capturedTitle = true }
        let startsMath = uri == MathTextNode.namespace && local == "math" && inBody && !suppressed && stack.last?.math == nil
        let capturesMath = startsMath || stack.last?.math != nil
        let block = (html && Self.blocks.contains(local) && inBody && !suppressed && !capturesMath)
            || (startsMath && attributes["display"] == "block")
        if block { body.lineBreak() }
        if inBody {
            for (key, value) in attributes {
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[1] == "type",
                   namespaces[String(parts[0])] == "http://www.idpf.org/2007/ops" {
                    semanticTypes.formUnion(value.unicodeScalars.split(whereSeparator: { $0.properties.isWhitespace }).map(String.init))
                }
            }
        }
        var heading: Int?
        if inBody, !suppressed, !capturesMath {
            if let id = attributes["id"] { body.mark(id: id) }
            if html, ["h1", "h2", "h3", "h4", "h5", "h6"].contains(local) { heading = body.openHeading() }
        }
        var math: MathTextNode?
        if capturesMath, !suppressed {
            math = MathTextNode(name: local, namespace: uri, attributes: attributes)
            if let parent = stack.last?.math, let math { parent.children.append(.element(math)) }
        }
        stack.append(Frame(namespaces: namespaces, body: inBody, root: root,
            title: startsTitle || stack.last?.title == true, suppressed: suppressed, block: block, name: local, heading: heading, math: math, startsMath: startsMath))
        // Treat an authored image alternative as inline character data. Use the same normalizer
        // after registering this element's marks so image IDs, enclosing headings and later
        // anchors all refer to the returned text. Decorative whitespace-only alternatives must
        // not introduce a separator between surrounding characters.
        if html, local == "img", inBody, !suppressed, !capturesMath, let alternative = attributes["alt"],
           alternative.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) {
            try body.append(alternative, limit: limits.outputBytes)
        }
    }

    private func characters(_ string: String) throws {
        guard let frame = stack.last, !frame.suppressed else { return }
        if let math = frame.math {
            math.children.append(.text(string))
            return
        }
        if frame.body || (frame.root && bodyCount == 1) {
            try body.append(string, limit: limits.outputBytes)
        }
        if frame.title { try title.append(string, limit: limits.outputBytes) }
    }

    private func end() throws {
        guard let frame = stack.popLast() else { return }
        if frame.startsMath, let math = frame.math {
            try math.write(to: &body, limit: limits.outputBytes)
        }
        if let heading = frame.heading { body.closeHeading(heading) }
        if frame.block { body.lineBreak() }
    }
}

/// The Unicode encoding of an XML document's bytes, detected as `XMLSafety` does: a byte-order
/// mark or the NUL pattern of `<?xml`. `nil` means an ASCII-compatible encoding.
private enum SourceEncoding {
    static func wide(_ data: Data) -> (encoding: String.Encoding, mark: Int)? {
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

    /// UTF-8 bytes for the HTML parser, which is told their encoding explicitly. Invalid UTF-8
    /// and other ASCII-compatible encodings are not guessed.
    static func utf8(_ data: Data) -> Data? {
        if case let (encoding, mark)? = wide(data) {
            return String(data: data.dropFirst(mark), encoding: encoding).map { Data($0.utf8) }
        }
        return String(data: data, encoding: .utf8) == nil ? nil : data
    }
}

/// UTF-8 bytes prepared for libxml2's HTML parser, or `nil` when recovery must not proceed.
/// HTML treats `<![CDATA[` as a bogus comment, losing XHTML character data, so each CDATA section
/// in content becomes the same characters as escaped text. The scan follows the HTML parser's
/// lexical context: comments, tags (with HTML attribute-value quoting, where a quote opens a
/// value only directly after `=`) and script/style raw text are copied, so authored attribute
/// values keep any literal `<![CDATA[`. An unterminated CDATA section or quoted attribute value
/// is refused rather than turning the rest of the document into text.
/// The other rewrites keep text that libxml2 would drop where the HTML Standard keeps it. The
/// scan cannot always tell where libxml2 is: libxml2 pairs an attribute's quotes differently in
/// places, and leaves a script or style early in ways that depend on which elements are open.
/// So no rewrite removes a byte that could be what ends a script, a comment or a quoted value
/// for libxml2, and what each writes is inert inside one:
/// - A `<` that opens no markup becomes `&lt;`, as HTML's tag open state emits it as a
///   character; libxml2 discards everything from it through the next `>`. Markup opens at a `<`
///   before an ASCII letter, `/`, `!` or `?` and nowhere else: `_`, `:` and `.` start a name
///   for libxml2, and prose such as `a <_< b` would open an element. A `<` that ends the input
///   stays the cut-off tag it may be.
/// - End tags that libxml2 reads as `</body>` or `</html>` are given another name, their last
///   letter written as its numeric character reference (`</bod&#121;>`), and libxml2 passes over
///   them as over any end tag that closes nothing. In HTML they close nothing and later content
///   stays in the body; libxml2 pops the element and builds that content outside the body.
///   Every byte of the tag stays or is a reference to itself: one with no `>` of its own runs to
///   the next, which may be that of a script's end tag, and a declaration keyword inside one is
///   still refused. The same is done in script and style content, where it changes nothing
///   unless libxml2 has left the script and reads an end tag. Where libxml2 reads the tag as
///   part of a quoted value instead, the value decodes the reference to the letter (#255).
/// - Script and style raw text is read where the HTML Standard reads it (`HTMLRawTextMap`, #255):
///   a `<script` or `<style` that libxml2 would take for such a start tag where the Standard
///   does not (`<script"q>`, a `<script>` in a title, a comment or an attribute value) is renamed
///   the same way, so that libxml2 reads it as an element it does not know and shows what
///   follows, and the scan does not copy that as raw text. A `</scriptx` that would take the
///   script's end tag with it is renamed too.
/// - `<!-->` and `<!--->` become `<!---->` where a `<` kept as text brings them into view.
///   HTML closes the comment there and libxml2 reads on to the next `-->`, but libxml2 used to
///   skip from such a sign through the next `>`, the comment's own, and showed what follows.
///   Reading on, the scan may meet a CDATA section or a quoted value that never ends in what
///   it used to copy as comment. Such a section is scanned again with these comments left as
///   they are, not refused.
/// - U+0000, where libxml2 ends its input, is dropped from text and CDATA, as HTML ignores it
///   in body text, and becomes U+FFFD in markup, as HTML reads it there. Markup is whatever is
///   copied unchanged, and anything from a `<` copied as is to the next `>`, so that dropping a
///   NUL never completes an end tag or a comment opener.
/// The HTML parser never processes declarations, but as defense in depth the prepared bytes must
/// contain no declaration keyword anywhere (ASCII case-insensitive, even inside comments or
/// attribute values) and no DOCTYPE internal subset.
private enum HTMLRecoverySource {
    static func prepare(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        let map = HTMLRawTextMap(bytes)
        var scanned = scan(bytes, map, closingAbruptComments: true)
        if scanned.output == nil, scanned.closedComment { scanned = scan(bytes, map, closingAbruptComments: false) }
        guard let output = scanned.output else { return nil }
        return hasDeclarations(output) ? nil : Data(output)
    }

    /// The rewritten bytes, or `nil` for a CDATA section or a start tag's quoted value that never
    /// ends, and whether a `<!-->` or `<!--->` was closed on the way.
    private static func scan(_ bytes: [UInt8], _ map: HTMLRawTextMap, closingAbruptComments: Bool) -> (output: [UInt8]?, closedComment: Bool) {
        var output = [UInt8](); output.reserveCapacity(bytes.count)
        let cdataOpen = Array("<![CDATA[".utf8), cdataClose = Array("]]>".utf8)
        let commentOpen = Array("<!--".utf8)
        let replacement: [UInt8] = [0xEF, 0xBF, 0xBD] // U+FFFD
        var closedComment = false
        // From a `<` copied as is (`<!`, `</`, `<?`) to the next `>`, libxml2 may be in a
        // declaration, a processing instruction or a tag that this scan does not follow.
        var inMarkup = false
        // Whether only text has followed the last `<` kept as text, so that libxml2 used to
        // skip this far.
        var exposed = false
        // The map's letters to rename, in order; the scan only moves forward.
        var nextRenamed = 0
        func renamed(from position: Int) -> Int {
            while nextRenamed < map.renamed.count, map.renamed[nextRenamed] < position { nextRenamed += 1 }
            return nextRenamed < map.renamed.count ? map.renamed[nextRenamed] : Int.max
        }
        /// Copies `range` with each renamed letter (the map's, and `own`) written as its numeric
        /// character reference and U+0000 as U+FFFD.
        func copy(_ range: Range<Int>, renaming own: Int? = nil) {
            if own == nil, renamed(from: range.lowerBound) >= range.upperBound, !bytes[range].contains(0) {
                output.append(contentsOf: bytes[range]); return
            }
            for index in range {
                if index == own || renamed(from: index) == index { output.append(contentsOf: reference(bytes[index])) }
                else if bytes[index] == 0 { output.append(contentsOf: replacement) }
                else { output.append(bytes[index]) }
            }
        }
        func copyMarkup(_ range: Range<Int>, renaming own: Int? = nil) {
            inMarkup = false; exposed = false
            copy(range, renaming: own)
        }
        var index = 0
        while index < bytes.count {
            if closingAbruptComments, bytes[index] == 0x3C, exposed, let abrupt = abruptComments.first(where: { starts(bytes, $0, at: index) }) {
                inMarkup = false; exposed = false; closedComment = true
                output.append(contentsOf: emptyComment); index += abrupt.count
            } else if bytes[index] == 0x3C, starts(bytes, commentOpen, at: index) {
                let end = HTMLRecoveryComments.end(in: bytes, from: index + commentOpen.count)
                copyMarkup(index..<end); index = end
            } else if bytes[index] == 0x3C, let tag = tag(bytes, at: index) {
                guard let end = tag.end else { return (nil, closedComment) }
                let start = index
                // `</body` or `</html` as libxml2 reads it: its last letter is renamed.
                copyMarkup(index..<end, renaming: tag.endsBody ? index + 5 : nil)
                index = end
                // Script and style content, to the first end tag of that name in any spelling that
                // the map has not renamed. It opens where the Standard opens it (the map), or
                // where the map cannot tell, at a start tag of that name it has not renamed.
                // libxml2 may leave it sooner, at an end tag directly after the start tag, and
                // then acts on a `</body>` here, so that is renamed here as it is in text.
                let raw = map.rawText.contains(start)
                    ? HTMLRawTextMap.libxml2RawText(bytes, at: start).map { String(decoding: $0.name, as: UTF8.self).uppercased() }
                    : tag.rawText.flatMap { map.renames(start + $0.count) ? nil : $0 }
                guard let raw else { continue }
                let close = Array("</\(raw)".utf8) // Uppercase, for case-insensitive `matches`.
                var own: Int?
                while index < bytes.count, !matches(bytes, close, at: index) || map.renames(index + close.count - 1) {
                    if bytes[index] == 0 {
                        output.append(contentsOf: replacement)
                    } else if index == own || renamed(from: index) == index {
                        output.append(contentsOf: reference(bytes[index]))
                    } else {
                        if bytes[index] == 0x3C, index + 1 < bytes.count, bytes[index + 1] == 0x2F,
                           names(bytes, body, at: index + 2) || names(bytes, root, at: index + 2) {
                            own = index + 5 // </body or </html
                        }
                        output.append(bytes[index])
                    }
                    index += 1
                }
            } else if bytes[index] == 0x3C, starts(bytes, cdataOpen, at: index) {
                guard let end = find(bytes, cdataClose, from: index + cdataOpen.count) else { return (nil, closedComment) }
                for byte in bytes[(index + cdataOpen.count)..<end] {
                    switch byte {
                    case 0x26: output.append(contentsOf: Array("&amp;".utf8))
                    case 0x3C: output.append(contentsOf: Array("&lt;".utf8))
                    case 0x3E: output.append(contentsOf: Array("&gt;".utf8))
                    case 0: break
                    default: output.append(byte)
                    }
                }
                index = end + cdataClose.count; exposed = false
            } else if bytes[index] == 0x3C, index + 1 < bytes.count, ![0x21, 0x2F, 0x3F].contains(bytes[index + 1]) {
                // Before none of `!`, `/` and `?`, and not a tag: text.
                output.append(contentsOf: Array("&lt;".utf8)); index += 1; exposed = true
            } else {
                switch bytes[index] {
                case 0: if inMarkup { output.append(contentsOf: replacement) }
                case 0x3C: inMarkup = true; output.append(0x3C)
                case 0x3E: inMarkup = false; exposed = false; output.append(0x3E)
                default:
                    if renamed(from: index) == index { output.append(contentsOf: reference(bytes[index])) } else { output.append(bytes[index]) }
                }
                index += 1
            }
        }
        return (output, closedComment)
    }

    /// A byte as its numeric character reference: libxml2 decodes it in text and in attribute
    /// values, shows nothing of it in comments, processing instructions, DOCTYPEs and raw text,
    /// and ends a tag name at its `&`.
    private static func reference(_ byte: UInt8) -> [UInt8] { Array("&#\(byte);".utf8) }

    /// An HTML start or end tag at `position` (`<` then an ASCII letter, or `</` then a letter).
    /// `end` is the index after its `>` (or the input end), `nil` for an unterminated quoted value.
    /// `endsBody` marks an end tag that libxml2 reads as `</body>` or `</html>`.
    private static func tag(_ bytes: [UInt8], at position: Int) -> (end: Int?, rawText: String?, endsBody: Bool)? {
        func letter(_ index: Int) -> Bool { index < bytes.count && (bytes[index] | 0x20) >= 0x61 && (bytes[index] | 0x20) <= 0x7A }
        func space(_ index: Int) -> Bool { [0x20, 0x09, 0x0A, 0x0C, 0x0D].contains(bytes[index]) }
        let closing = position + 1 < bytes.count && bytes[position + 1] == 0x2F // /
        var index = position + (closing ? 2 : 1)
        guard letter(index) else { return nil }
        let nameStart = index
        while index < bytes.count, !space(index), bytes[index] != 0x2F, bytes[index] != 0x3E { index += 1 }
        let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).uppercased()
        let rawText = !closing && (name == "SCRIPT" || name == "STYLE") ? name : nil
        if closing {
            // libxml2 ends an end tag at the first `>`, quoted or not, and so acts on a
            // `</body>` in another end tag's quoted value.
            let endsBody = names(bytes, body, at: nameStart) || names(bytes, root, at: nameStart)
            return (bytes[index...].firstIndex(of: 0x3E).map { $0 + 1 } ?? bytes.count, nil, endsBody)
        }
        var selfClosing = false // libxml2 closes `<script/>` at once; no raw text follows.
        while index < bytes.count {
            if bytes[index] == 0x3E { return (index + 1, selfClosing ? nil : rawText, false) } // >
            if bytes[index] == 0x2F { selfClosing = true; index += 1; continue }
            if space(index) { index += 1; continue }
            selfClosing = false
            // Attribute name: at least one byte, so a leading '=' or quote cannot stall the scan.
            index += 1
            while index < bytes.count, !space(index), ![0x2F, 0x3D, 0x3E].contains(bytes[index]) { index += 1 }
            while index < bytes.count, space(index) { index += 1 }
            guard index < bytes.count, bytes[index] == 0x3D else { continue } // =
            index += 1
            while index < bytes.count, space(index) { index += 1 }
            if index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 {
                let quote = bytes[index]
                guard let close = bytes[(index + 1)...].firstIndex(of: quote) else { return (nil, rawText, false) }
                index = close + 1
            } else {
                // Unquoted: a quote here is an ordinary character, as in HTML.
                while index < bytes.count, !space(index), bytes[index] != 0x3E { index += 1 }
            }
        }
        return (bytes.count, rawText, false)
    }

    private static let root = Array("HTML".utf8), body = Array("BODY".utf8)
    private static let abruptComments = [Array("<!-->".utf8), Array("<!--->".utf8)], emptyComment = Array("<!---->".utf8)

    /// Whether libxml2 reads the tag name at `position` as `name` (uppercase, for `matches`). It
    /// ends a name at the first byte that is not an ASCII letter or digit, `:`, `-`, `_` or `.`,
    /// so `</body"x>` is `</body>` to it.
    private static func names(_ bytes: [UInt8], _ name: [UInt8], at position: Int) -> Bool {
        let next = position + name.count
        guard matches(bytes, name, at: position) else { return false }
        guard next < bytes.count else { return true }
        let byte = bytes[next]
        return !((byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || [0x3A, 0x2D, 0x5F, 0x2E].contains(byte))
    }

    private static func hasDeclarations(_ bytes: [UInt8]) -> Bool {
        let keywords = ["<!ENTITY", "<!ATTLIST", "<!ELEMENT", "<!NOTATION"].map { Array($0.utf8) }
        let doctype = Array("<!DOCTYPE".utf8)
        for index in bytes.indices where bytes[index] == 0x3C {
            if keywords.contains(where: { matches(bytes, $0, at: index) }) { return true }
            if matches(bytes, doctype, at: index) {
                // Through the DOCTYPE's actual close, outside quoted identifiers. A bracket in
                // that whole span, quoted or not, or an unterminated DOCTYPE is refused.
                var quote: UInt8?
                var position = index + doctype.count
                var closed = false
                while position < bytes.count, !closed {
                    let byte = bytes[position]
                    if byte == 0x5B { return true } // [
                    if let delimiter = quote { if byte == delimiter { quote = nil } }
                    else if byte == 0x22 || byte == 0x27 { quote = byte }
                    else if byte == 0x3E { closed = true }
                    position += 1
                }
                if !closed { return true }
            }
        }
        return false
    }

    private static func starts(_ bytes: [UInt8], _ token: [UInt8], at position: Int) -> Bool {
        position + token.count <= bytes.count && bytes[position..<position + token.count].elementsEqual(token)
    }
    /// ASCII case-insensitive; tokens are uppercase.
    private static func matches(_ bytes: [UInt8], _ token: [UInt8], at position: Int) -> Bool {
        position + token.count <= bytes.count
            && zip(bytes[position..<position + token.count], token).allSatisfy { byte, expected in
                byte == expected || (expected >= 0x41 && expected <= 0x5A && byte == expected | 0x20)
            }
    }
    private static func find(_ bytes: [UInt8], _ token: [UInt8], from position: Int) -> Int? {
        var index = position
        while index + token.count <= bytes.count {
            if starts(bytes, token, at: index) { return index }
            index += 1
        }
        return nil
    }
}

/// XHTML 1.x's named character references (`&nbsp;`, `&mdash;`) as numeric references, so
/// the XML parser decodes them without loading the DOCTYPE's DTD. This mirrors the native
/// viewer's translation. CDATA sections and comments are copied unchanged; XML's five
/// predefined names and unknown names are left for the parser. UTF-16/32 documents are
/// translated in their own encoding, retaining any byte-order mark.
private enum NamedCharacterReferences {
    static func numeric(in data: Data) -> Data {
        guard case let (encoding, mark)? = SourceEncoding.wide(data) else { return translate(data) ?? data }
        guard let text = String(data: data.dropFirst(mark), encoding: encoding),
              let translated = translate(Data(text.utf8)),
              let encoded = String(decoding: translated, as: UTF8.self).data(using: encoding) else { return data }
        return data.prefix(mark) + encoded
    }

    /// `nil` when nothing changed.
    private static func translate(_ data: Data) -> Data? {
        guard data.contains(0x26) else { return nil } // &
        let bytes = [UInt8](data)
        var output = [UInt8](); output.reserveCapacity(bytes.count)
        var changed = false
        var index = 0
        func starts(_ token: [UInt8], at position: Int) -> Bool {
            position + token.count <= bytes.count && bytes[position..<position + token.count].elementsEqual(token)
        }
        let cdataOpen = Array("<![CDATA[".utf8), cdataClose = Array("]]>".utf8)
        let commentOpen = Array("<!--".utf8), commentClose = Array("-->".utf8)
        while index < bytes.count {
            if bytes[index] == 0x3C, starts(cdataOpen, at: index) || starts(commentOpen, at: index) {
                let close = starts(cdataOpen, at: index) ? cdataClose : commentClose
                var end = index + 4
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
}

/// One bounded MathML subtree, captured by the same XML walk that checks depth/elements.
/// The tree never reads referenced resources or evaluates markup. Writing is incremental into
/// the ordinary body normalizer, so generated delimiters and escapes obey the output budget.
private final class MathTextNode {
    static let namespace = "http://www.w3.org/1998/Math/MathML"
    enum Child { case element(MathTextNode), text(String) }
    let name: String
    let namespace: String
    let attributes: [String: String]
    var children: [Child] = []

    init(name: String, namespace: String, attributes: [String: String]) {
        self.name = name; self.namespace = namespace; self.attributes = attributes
    }

    private var parameters: [String: String] {
        attributes.filter { $0.key != "id" && $0.key != "xmlns" && !$0.key.hasPrefix("xmlns:") && (namespace != Self.namespace || $0.key != "alttext") }
    }
    private var significantChildren: [Child] {
        children.filter {
            if case .text(let text) = $0 { return text.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) }
            return true
        }
    }
    private var annotation: Bool {
        namespace == Self.namespace && (name == "annotation" || name == "annotation-xml")
    }
    private var authoredAlternative: String? {
        if namespace == Self.namespace, let value = attributes["alttext"], value.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) { return value }
        if namespace == Self.namespace, name == "math", significantChildren.count == 1,
           let semantics = children.compactMap({ if case .element(let node) = $0 { return node }; return nil }).first(where: { $0.namespace == Self.namespace && $0.name == "semantics" }),
           let alternative = semantics.authoredAlternative { return alternative }
        if namespace == Self.namespace, name == "semantics" {
            for child in children {
                guard case .element(let node) = child, node.namespace == Self.namespace, node.name == "annotation",
                      ["text/plain", "application/x-tex", "application/x-latex", "application/x-asciimath"].contains(node.attributes["encoding"]?.lowercased() ?? ""),
                      node.children.allSatisfy({ if case .text = $0 { return true }; return false }) else { continue }
                let text = node.children.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
                if text.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) { return text }
            }
        }
        return nil
    }
    private func markSubtree(in output: inout NormalizedText) throws {
        try Task.checkCancellation()
        if let id = attributes["id"] { output.mark(id: id) }
        for child in children {
            if case .element(let node) = child { try node.markSubtree(in: &output) }
        }
    }

    func write(to output: inout NormalizedText, limit: Int, outermost: Bool = true) throws {
        try Task.checkCancellation()
        if let alternative = authoredAlternative {
            // Descendant IDs now refer to the one authored replacement, rather than later prose.
            try markSubtree(in: &output)
            if outermost { try output.append(alternative, limit: limit) }
            else { try quoted(alternative, to: &output, limit: limit) }
            return
        }
        if let id = attributes["id"] { output.mark(id: id) }
        if annotation {
            // Stray annotations have no selected presentation, but retain a navigable mark.
            try markSubtree(in: &output)
            return
        }
        let values = significantChildren.filter {
            if case .element(let node) = $0 { return !node.annotation }; return true
        }
        for child in children {
            if case .element(let node) = child, node.annotation { try node.markSubtree(in: &output) }
        }
        if namespace == Self.namespace, name == "semantics", parameters.isEmpty, values.count == 1,
           case .element = values[0] {
            // A valid semantics wrapper contributes one presentation, not its annotations.
            try writeChild(values[0], to: &output, limit: limit)
            return
        }
        let args = parameters
        let isMath = namespace == Self.namespace
        let arities = ["mfrac": 2, "msup": 2, "msub": 2, "msubsup": 3, "mroot": 2,
                       "munder": 2, "mover": 2, "munderover": 3]
        let names = ["mfrac": "frac", "msup": "sup", "msub": "sub", "msubsup": "subsup", "mroot": "root",
                     "munder": "under", "mover": "over", "munderover": "underover", "msqrt": "sqrt", "mrow": "row"]
        // A malformed arity or a presentation-changing attribute (e.g. a zero-thickness
        // binomial) retains its actual tag/attributes, rather than inventing ordinary division.
        let compact = isMath && args.isEmpty && (arities[name].map { expected in
            values.count == expected && values.allSatisfy { if case .element = $0 { return true }; return false }
        } ?? true)
        if compact, ["mi", "mn", "mo", "mtext", "ms"].contains(name),
           children.allSatisfy({ if case .text = $0 { return true }; return false }) {
            let text = children.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
            try quoted(text, to: &output, limit: limit)
            return
        }
        let fences = isMath && name == "mfenced" && Set(args.keys).isSubset(of: ["open", "close", "separators"])
        // Unknown source tags must not impersonate a shorthand constructor (e.g. <frac>).
        let genericElement = !isMath || names.values.contains(name) || ["fenced", "element"].contains(name)
        let label = genericElement ? "element" : (fences ? "fenced" : (compact ? names[name] ?? name : name))
        try output.append(label + "(", limit: limit)
        var named = args
        if genericElement {
            try quoted(namespace, to: &output, limit: limit)
            try output.append(", ", limit: limit)
            try quoted(name, to: &output, limit: limit)
            try output.append("; attributes(", limit: limit)
        }
        if isMath, name == "mfenced" {
            named["open"] = attributes["open"] ?? "("
            named["close"] = attributes["close"] ?? ")"
            named["separators"] = attributes["separators"] ?? ","
        }
        for (index, key) in named.keys.sorted().enumerated() {
            if index > 0 { try output.append(", ", limit: limit) }
            try output.append(key + "=", limit: limit)
            try quoted(named[key]!, to: &output, limit: limit)
        }
        if genericElement { try output.append(")", limit: limit) }
        if (genericElement || !named.isEmpty) && !values.isEmpty { try output.append("; ", limit: limit) }
        for (index, child) in values.enumerated() {
            if index > 0 { try output.append(", ", limit: limit) }
            try writeChild(child, to: &output, limit: limit)
        }
        try output.append(")", limit: limit)
    }

    private func writeChild(_ child: Child, to output: inout NormalizedText, limit: Int) throws {
        switch child {
        case .element(let node): try node.write(to: &output, limit: limit, outermost: false)
        case .text(let value): try quoted(value, to: &output, limit: limit)
        }
    }
    private func quoted(_ value: String, to output: inout NormalizedText, limit: Int) throws {
        try output.append("\"", limit: limit)
        var pendingSpace = false
        var hasText = false
        for scalar in value.unicodeScalars {
            try Task.checkCancellation()
            if scalar.properties.isWhitespace {
                if hasText { pendingSpace = true }
                continue
            }
            if pendingSpace { try output.append(" ", limit: limit); pendingSpace = false }
            let escaped: String
            switch scalar.value {
            case 0x22: escaped = "\\\""
            case 0x5C: escaped = "\\\\"
            case 0..<0x20, 0x7F, 0x2061...0x2064: escaped = "\\u{" + String(scalar.value, radix: 16) + "}"
            default: escaped = String(scalar)
            }
            try output.append(escaped, limit: limit)
            hasText = true
        }
        try output.append("\"", limit: limit)
    }
}
