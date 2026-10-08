import EPUBCore
import Foundation
import libxml2

/// One node of a parsed content document: the DOM as an EPUB CFI sees it.
///
/// Only element and character-data nodes exist. Comments and processing instructions are
/// dropped and adjacent text and CDATA are merged into one text node. Neither changes a CFI:
/// the CFI step rules ignore everything but elements and character data, and a chunk's offset
/// is the sum of its text nodes' lengths (`epubcfi.js` `indexChildNodes`). Immutable once parsed.
final class ContentNode: @unchecked Sendable {
    enum Kind: Sendable { case element, text }

    let kind: Kind
    /// Local name. HTML-namespace names are lowercased. Empty for text.
    let name: String
    /// Namespace URI, or "" when none.
    let namespace: String
    let attributes: [ContentAttribute]
    /// Character data, entities decoded. Empty for elements.
    let text: String
    /// UTF-16 length of `text`, the unit of CFI character offsets.
    let utf16Length: Int
    fileprivate(set) var children: [ContentNode] = []
    fileprivate(set) weak var parent: ContentNode?
    /// Index among the parent's children (elements and text nodes only).
    fileprivate(set) var indexInParent = 0
    /// Preorder document index. `document.nodes[order] === self`.
    fileprivate(set) var order = 0
    /// Order of the last node in this node's subtree (itself when it has no children).
    fileprivate(set) var subtreeEnd = 0

    fileprivate init(element name: String, namespace: String, attributes: [ContentAttribute]) {
        kind = .element; self.name = name; self.namespace = namespace
        self.attributes = attributes; text = ""; utf16Length = 0
    }
    fileprivate init(text: String) {
        kind = .text; name = ""; namespace = ""; attributes = []
        self.text = text; utf16Length = text.utf16.count
    }

    var isElement: Bool { kind == .element }
    var isText: Bool { kind == .text }
    /// True for an element in the XHTML namespace (or with no namespace, as HTML-parsed content has).
    var isHTML: Bool { kind == .element && (namespace == ContentNamespace.xhtml || namespace.isEmpty) }
    func isHTML(_ local: String) -> Bool { isHTML && name == local }

    /// The value of an attribute by local name; `namespace` nil matches an attribute in no namespace.
    func attribute(_ local: String, namespace: String? = nil) -> String? {
        attributes.first { $0.name == local && $0.namespace == (namespace ?? "") }?.value
    }
    /// `id`, or `xml:id`.
    var id: String? { attribute("id") ?? attribute("id", namespace: ContentNamespace.xml) }
    /// `xml:lang`, else `lang`.
    var language: String? { attribute("lang", namespace: ContentNamespace.xml) ?? attribute("lang") }
    /// Whitespace-separated `epub:type` tokens.
    var epubTypes: [String] {
        (attribute("type", namespace: ContentNamespace.ops) ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }
    var classNames: [String] { (attribute("class") ?? "").split(whereSeparator: \.isWhitespace).map(String.init) }
    var elementChildren: [ContentNode] { children.filter(\.isElement) }
    /// Concatenated descendant text, in document order.
    var textContent: String {
        isText ? text : children.map(\.textContent).joined()
    }
    func isAncestor(of node: ContentNode) -> Bool { order < node.order && node.order <= subtreeEnd }
}

struct ContentAttribute: Equatable, Sendable {
    /// Local name.
    let name: String
    /// Namespace URI, or "" when none.
    let namespace: String
    let value: String
}

enum ContentNamespace {
    static let xhtml = "http://www.w3.org/1999/xhtml"
    static let ops = "http://www.idpf.org/2007/ops"
    static let xml = "http://www.w3.org/XML/1998/namespace"
    static let svg = "http://www.w3.org/2000/svg"
    static let mathML = "http://www.w3.org/1998/Math/MathML"
    static let xlink = "http://www.w3.org/1999/xlink"
    static let opf = "http://www.idpf.org/2007/opf"
}

/// A position in a content document, with DOM Range semantics restricted to what a CFI can name:
/// a UTF-16 offset in a text node, or the start (`offset == 0`) of an element.
struct DOMPosition: Hashable, Sendable {
    let node: ContentNode
    let offset: Int
    init(_ node: ContentNode, _ offset: Int = 0) { self.node = node; self.offset = offset }
    static func == (a: Self, b: Self) -> Bool { a.node === b.node && a.offset == b.offset }
    func hash(into hasher: inout Hasher) { hasher.combine(node.order); hasher.combine(offset) }
    /// Document order. An element's start precedes its descendants.
    static func < (a: Self, b: Self) -> Bool {
        a.node.order != b.node.order ? a.node.order < b.node.order : a.offset < b.offset
    }
}

struct ContentLimits: Sendable {
    var bytes = 8 * 1024 * 1024
    var depth = 200
    var nodes = 250_000
}

enum ContentDocumentError: Error, Equatable, Sendable {
    /// Entity declarations or an internal DTD subset: refused before parsing.
    case unsafeMarkup(String)
    case malformed(String)
    case limitExceeded(String)
}

/// A parsed XML or XHTML document. XHTML is parsed as XML first, with HTML's named character
/// entities (as WebKit knows them for XHTML DOCTYPEs) translated to numeric references. Markup
/// that is not well-formed falls back to libxml2's forgiving HTML parser, and `recoveredAsHTML`
/// records that; CFIs into such a document may differ from a browser's XML DOM.
final class ContentDocument: @unchecked Sendable {
    let path: String
    let root: ContentNode
    /// Every node in preorder; `nodes[n.order] === n`.
    let nodes: [ContentNode]
    let recoveredAsHTML: Bool
    private let ids: [String: ContentNode]

    private init(path: String, root: ContentNode, nodes: [ContentNode], recovered: Bool) {
        self.path = path; self.root = root; self.nodes = nodes; recoveredAsHTML = recovered
        var ids: [String: ContentNode] = [:]
        for node in nodes where node.isElement { if let id = node.id, ids[id] == nil { ids[id] = node } }
        self.ids = ids
    }

    /// First element with this `id` in document order (`getElementById`).
    func element(id: String) -> ContentNode? { ids[id] }
    var head: ContentNode? { root.elementChildren.first { $0.isHTML("head") } }
    var body: ContentNode? { root.elementChildren.first { $0.isHTML("body") } }
    /// Document language: `xml:lang`/`lang` on the root or body.
    var language: String? { root.language ?? body?.language }

    /// The first rendered-order node at or after `position`'s node that is a text node.
    func nextTextNode(from node: ContentNode) -> ContentNode? {
        nodes[node.order...].first(where: \.isText)
    }

    static func parse(_ data: Data, path: String, limits: ContentLimits = .init()) throws -> ContentDocument {
        guard data.count <= limits.bytes, data.count <= Int(Int32.max) else { throw ContentDocumentError.limitExceeded("bytes") }
        guard XMLSafety.hasSafeDeclarations(data) else { throw ContentDocumentError.unsafeMarkup(path) }
        let source = HTMLEntities.numericReferences(in: data)
        if let document = try parseXML(source, path: path, limits: limits) { return document }
        return try parseHTML(source, path: path, limits: limits)
    }

    private static let xmlOptions = Int32(XML_PARSE_NONET.rawValue | XML_PARSE_NOERROR.rawValue
        | XML_PARSE_NOWARNING.rawValue | XML_PARSE_NOCDATA.rawValue)
    private static let htmlOptions = Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue
        | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NODEFDTD.rawValue)

    private static func parseXML(_ data: Data, path: String, limits: ContentLimits) throws -> ContentDocument? {
        let doc = data.withUnsafeBytes { buffer in
            xmlReadMemory(buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buffer.count), nil, nil, xmlOptions)
        }
        guard let doc else { return nil }
        defer { xmlFreeDoc(doc) }
        return try convert(doc, path: path, limits: limits, recovered: false, html: false)
    }

    private static func parseHTML(_ data: Data, path: String, limits: ContentLimits) throws -> ContentDocument {
        let doc = data.withUnsafeBytes { buffer in
            htmlReadMemory(buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buffer.count), nil, "UTF-8", htmlOptions)
        }
        guard let doc else { throw ContentDocumentError.malformed(path) }
        defer { xmlFreeDoc(doc) }
        guard let document = try convert(doc, path: path, limits: limits, recovered: true, html: true) else {
            throw ContentDocumentError.malformed(path)
        }
        return document
    }

    private static func convert(_ doc: xmlDocPtr, path: String, limits: ContentLimits,
                                recovered: Bool, html: Bool) throws -> ContentDocument? {
        guard let rootElement = xmlDocGetRootElement(doc) else { return nil }
        var nodes: [ContentNode] = []
        func string(_ value: UnsafePointer<xmlChar>?) -> String { value.map { String(cString: $0) } ?? "" }
        func build(_ xml: xmlNodePtr, depth: Int) throws -> ContentNode {
            guard depth < limits.depth else { throw ContentDocumentError.limitExceeded("depth") }
            let namespace = html ? "" : string(xml.pointee.ns?.pointee.href)
            let rawName = string(xml.pointee.name)
            let name = namespace == ContentNamespace.xhtml || html ? rawName.lowercased() : rawName
            var attributes: [ContentAttribute] = []
            var attribute = xml.pointee.properties
            while let current = attribute {
                var value = ""
                var part = current.pointee.children
                while let text = part {
                    if let content = text.pointee.content { value += String(cString: content) }
                    part = text.pointee.next
                }
                let attributeNamespace = html ? "" : string(current.pointee.ns?.pointee.href)
                let local = string(current.pointee.name)
                attributes.append(ContentAttribute(name: html ? local.lowercased() : local,
                                                   namespace: attributeNamespace, value: value))
                attribute = current.pointee.next
            }
            let node = ContentNode(element: name, namespace: namespace, attributes: attributes)
            node.order = nodes.count
            nodes.append(node)
            guard nodes.count <= limits.nodes else { throw ContentDocumentError.limitExceeded("nodes") }
            var pendingText = ""
            var hasPendingText = false
            func flushText() {
                guard hasPendingText else { return }
                let text = ContentNode(text: pendingText)
                text.parent = node; text.indexInParent = node.children.count
                text.order = nodes.count; text.subtreeEnd = text.order
                nodes.append(text); node.children.append(text)
                pendingText = ""; hasPendingText = false
            }
            var child = xml.pointee.children
            while let current = child {
                switch current.pointee.type {
                case XML_ELEMENT_NODE:
                    flushText()
                    let element = try build(current, depth: depth + 1)
                    element.parent = node; element.indexInParent = node.children.count
                    node.children.append(element)
                case XML_TEXT_NODE, XML_CDATA_SECTION_NODE:
                    if let content = current.pointee.content { pendingText += String(cString: content) }
                    hasPendingText = true
                case XML_ENTITY_REF_NODE:
                    // Only predefined entities can remain; their expansion is the content.
                    if let content = current.pointee.children?.pointee.content {
                        pendingText += String(cString: content)
                        hasPendingText = true
                    }
                default: break // Comments, processing instructions, DTD nodes.
                }
                guard nodes.count <= limits.nodes else { throw ContentDocumentError.limitExceeded("nodes") }
                child = current.pointee.next
            }
            flushText()
            node.subtreeEnd = nodes.count - 1
            return node
        }
        let root = try build(rootElement, depth: 0)
        return ContentDocument(path: path, root: root, nodes: nodes, recovered: recovered)
    }
}

/// Named character references beyond XML's five, as numeric references, so XHTML that relies on
/// its DOCTYPE's entity set (`&nbsp;`, `&mdash;`) parses as XML without loading any DTD. CDATA
/// sections and comments are copied unchanged. Unknown names are left for the parser to reject.
enum HTMLEntities {
    static func numericReferences(in data: Data) -> Data {
        guard data.contains(0x26) else { return data } // &
        let bytes = [UInt8](data)
        var output = [UInt8](); output.reserveCapacity(bytes.count)
        var index = 0
        func starts(_ token: [UInt8], at position: Int) -> Bool {
            position + token.count <= bytes.count && Array(bytes[position..<position + token.count]) == token
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
                        continue
                    }
                }
            }
            output.append(bytes[index]); index += 1
        }
        return Data(output)
    }
}
