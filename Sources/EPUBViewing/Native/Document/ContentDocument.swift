import EPUBCore
import CryptoKit
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
    var language: String? { attribute("lang", namespace: ContentNamespace.xml) ?? attribute("xml:lang") ?? attribute("lang") }
    /// Whitespace-separated `epub:type` tokens.
    var epubTypes: [String] {
        (attribute("type", namespace: ContentNamespace.ops) ?? attribute("epub:type") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
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
/// a UTF-16 offset in a text node, or the start (`offset == 0`) of an element. The one place
/// neither names is the document's end when its last node is an element (an image or a rule
/// with nothing after it): that is the element with `offset == 1`, just after it
/// (`ContentDocument.end`).
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
/// records that. XML-shaped HTML in the qualified subset is rebuilt with Foliate's HTML
/// whitespace and namespace rules. Other repairs remain readable, but cannot issue or resolve
/// CFIs: libxml2's HTML 4 tree is not a safe substitute for WebKit's HTML 5 tree.
final class ContentDocument: @unchecked Sendable {
    enum Origin: Equatable, Sendable { case authored, syntheticRaster }
    let path: String
    /// Explicitly distinguishes the raster loader's wrapper from parsed authored markup.
    let origin: Origin
    let root: ContentNode
    /// Every node in preorder; `nodes[n.order] === n`.
    let nodes: [ContentNode]
    let recoveredAsHTML: Bool
    let canResolveCFIs: Bool
    /// A fallback XHTML DOM requires a resource assertion so its positions cannot be confused
    /// with positions in the original document under the same package spine itemref.
    let cfiResource: String?
    /// By the ID's code units, as `getElementById` compares them (`EPUBElementID`).
    private let ids: [EPUBElementID: ContentNode]

    private init(path: String, root: ContentNode, nodes: [ContentNode], recovered: Bool,
                 canResolveCFIs: Bool = true, cfiResource: String? = nil, origin: Origin = .authored) {
        self.path = path; self.root = root; self.nodes = nodes; recoveredAsHTML = recovered
        self.origin = origin
        self.canResolveCFIs = canResolveCFIs
        self.cfiResource = cfiResource
        var ids: [EPUBElementID: ContentNode] = [:]
        for node in nodes where node.isElement { if let id = node.id, ids[id] == nil { ids[id] = node } }
        self.ids = ids
    }

    /// A substituted/synthesized document can keep its own text map without accepting CFIs
    /// issued against the original spine resource's DOM.
    func withoutCFIs() -> ContentDocument {
        ContentDocument(path: path, root: root, nodes: nodes, recovered: recoveredAsHTML,
                        canResolveCFIs: false, cfiResource: cfiResource, origin: origin)
    }

    func asSyntheticRaster() -> ContentDocument {
        ContentDocument(path: path, root: root, nodes: nodes, recovered: recoveredAsHTML,
                        canResolveCFIs: false, origin: .syntheticRaster)
    }

    func withCFIResource(_ resource: String) -> ContentDocument {
        ContentDocument(path: path, root: root, nodes: nodes, recovered: recoveredAsHTML,
                        canResolveCFIs: canResolveCFIs, cfiResource: SHA256.hash(data: Data(resource.utf8))
                            .map { String(format: "%02x", $0) }.joined(), origin: origin)
    }

    /// First element with this `id` in document order, code unit for code unit (`getElementById`).
    func element(id: String) -> ContentNode? { ids[id] }
    var head: ContentNode? { root.elementChildren.first { $0.isHTML("head") } }
    var body: ContentNode? { root.elementChildren.first { $0.isHTML("body") } }
    /// Document language: `xml:lang`/`lang` on the root or body.
    var language: String? { root.language ?? body?.language }

    /// The document's end: after its last node's last character, or just after its last node
    /// when that is an element, which has no children since nothing follows it.
    var end: DOMPosition {
        let last = nodes[nodes.count - 1]
        return DOMPosition(last, last.isText ? last.utf16Length : 1)
    }

    /// The position just after `node`'s subtree: the next node's start, or the document's end.
    func position(after node: ContentNode) -> DOMPosition {
        node.subtreeEnd + 1 < nodes.count ? DOMPosition(nodes[node.subtreeEnd + 1], 0) : end
    }

    /// The first rendered-order node at or after `position`'s node that is a text node.
    func nextTextNode(from node: ContentNode) -> ContentNode? {
        nodes[node.order...].first(where: \.isText)
    }

    static func parse(_ data: Data, path: String, limits: ContentLimits = .init(),
                      asContent: Bool = true) throws -> ContentDocument {
        guard data.count <= limits.bytes, data.count <= Int(Int32.max) else { throw ContentDocumentError.limitExceeded("bytes") }
        let safety = XMLSafety.assess(data)
        guard safety != .attributeLimitExceeded else { throw ContentDocumentError.limitExceeded("attributesPerElement") }
        guard safety == .safe else { throw ContentDocumentError.unsafeMarkup(path) }
        let source = HTMLEntities.numericReferences(in: data)
        guard source.count <= limits.bytes, source.count <= Int(Int32.max) else { throw ContentDocumentError.limitExceeded("bytes") }
        let rewrittenSafety = source == data ? safety : XMLSafety.assess(source)
        guard rewrittenSafety != .attributeLimitExceeded else { throw ContentDocumentError.limitExceeded("attributesPerElement") }
        guard rewrittenSafety == .safe else { throw ContentDocumentError.unsafeMarkup(path) }
        if let document = try parseXML(source, path: path, limits: limits) {
            // Foliate's loadDocument retries a namespace-free content root as HTML. WebKit
            // also rejects named references without an XHTML 1.x public DOCTYPE. OPF and
            // other XML documents retain their existing XML behavior.
            if asContent && (document.root.namespace.isEmpty ||
                (source != data && !HTMLCFICompatibility.hasXHTMLDTD(data))) {
                if HTMLCFICompatibility.accepts(data, document: document) {
                    return try htmlShaped(document, source: data, limits: limits)
                }
                return try parseHTML(data, rewritten: source, path: path, limits: limits)
            }
            return document
        }
        return try parseHTML(data, rewritten: source, path: path, limits: limits)
    }

    static let xmlOptions = Int32(XML_PARSE_NONET.rawValue | XML_PARSE_NOERROR.rawValue
        | XML_PARSE_NOWARNING.rawValue | XML_PARSE_NOCDATA.rawValue)
    private static let htmlOptions = Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue
        | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NODEFDTD.rawValue)

    private static func parseXML(_ data: Data, path: String, limits: ContentLimits) throws -> ContentDocument? {
        // libxml2 may return a tree for namespace errors and undeclared entities under
        // an external DOCTYPE. Inspect this parse's own diagnostics, never a global
        // error or only lastError: a later URI warning can hide an earlier QName error.
        let namespaceError = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        namespaceError.initialize(to: false)
        defer { namespaceError.deinitialize(count: 1); namespaceError.deallocate() }
        guard let context = xmlNewParserCtxt() else { return nil }
        defer { xmlFreeParserCtxt(context) }
        context.pointee._private = UnsafeMutableRawPointer(namespaceError)
        context.pointee.sax?.pointee.serror = { raw, error in
            guard let raw, let error, error.pointee.domain == Int32(XML_FROM_NAMESPACE.rawValue) else { return }
            switch error.pointee.code {
            // libxml2 marks an unusual namespace URI as an error and clears
            // nsWellFormed, although an unknown URI does not invalidate a QName.
            case Int32(XML_WAR_NS_URI.rawValue), Int32(XML_WAR_NS_URI_RELATIVE.rawValue): return
            default: break
            }
            guard error.pointee.level.rawValue >= XML_ERR_ERROR.rawValue else { return }
            let parser = raw.assumingMemoryBound(to: xmlParserCtxt.self)
            parser.pointee._private?.assumingMemoryBound(to: Bool.self).pointee = true
        }
        // The handler above takes what libxml2 raises about this parse, but not a decoder's error.
        let doc = LibXML2Messages.silenced {
            data.withUnsafeBytes { buffer in
                xmlCtxtReadMemory(context, buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buffer.count), nil, nil, xmlOptions)
            }
        }
        guard let doc else { return nil }
        defer { xmlFreeDoc(doc) }
        guard context.pointee.wellFormed != 0, !namespaceError.pointee else { return nil }
        do {
            return try convert(doc, path: path, limits: limits, recovered: false, html: false)
        } catch XMLTreeError.unresolvedEntity {
            return nil
        }
    }

    private enum XMLTreeError: Error { case unresolvedEntity }

    /// `rewritten` is `data` as the XML parser was given it.
    private static func parseHTML(_ data: Data, rewritten: Data, path: String, limits: ContentLimits) throws -> ContentDocument {
        let source = try htmlSource(data, rewritten: rewritten, path: path, limits: limits)
        guard XMLSafety.hasBoundedAttributes(source.data, asHTML: true) else { throw ContentDocumentError.limitExceeded("attributesPerElement") }
        let doc = LibXML2Messages.silenced {
            source.data.withUnsafeBytes { buffer in
                htmlReadMemory(buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buffer.count), nil, "UTF-8", htmlOptions)
            }
        }
        guard let doc else { throw ContentDocumentError.malformed(path) }
        defer { xmlFreeDoc(doc) }
        retainHTMLTrailingContent(doc)
        guard let document = try convert(doc, path: path, limits: limits, recovered: true, html: true,
                                         signPlaceholder: source.placeholder, ampPlaceholder: source.ampPlaceholder) else {
            throw ContentDocumentError.malformed(path)
        }
        return document
    }

    /// libxml2 pops body/html at their end tags and can put later content beside either one.
    /// HTML keeps that content in the body. Move the parser's actual trailing nodes, rather
    /// than rewriting source tags whose apparent boundaries can lie in a quoted value or
    /// raw text to libxml2. Conversion afterwards establishes every order, parent and offset
    /// and applies the normal node/depth bounds to the complete body. Comments and PIs stay
    /// outside it because they contribute neither characters nor CFI nodes.
    private static func retainHTMLTrailingContent(_ doc: xmlDocPtr) {
        guard let root = xmlDocGetRootElement(doc) else { return }
        var child = root.pointee.children
        var body: xmlNodePtr?
        while let node = child {
            if node.pointee.type == XML_ELEMENT_NODE, String(cString: node.pointee.name) == "body" {
                body = node; break
            }
            child = node.pointee.next
        }
        guard let body else { return }
        func append(_ first: xmlNodePtr?) {
            var current = first
            while let node = current {
                current = node.pointee.next
                switch node.pointee.type {
                case XML_ELEMENT_NODE, XML_TEXT_NODE, XML_CDATA_SECTION_NODE:
                    xmlUnlinkNode(node)
                    _ = xmlAddChild(body, node)
                default: break
                }
            }
        }
        append(body.pointee.next)
        append(root.pointee.next)
    }

    /// The UTF-8 bytes the HTML parser reads for `data`, and the placeholder that stands for a
    /// stray `<` in them. A document in another encoding is decoded first, and its named
    /// references are rewritten in what was decoded, not in its own bytes. libxml2 would discard
    /// the text after a `<` that opens no markup and end the document at a NUL. What it is
    /// given stays within the byte limit decoded, after CDATA recovery, and
    /// again with those signs and NULs replaced.
    static func htmlSource(_ data: Data, rewritten: Data, path: String, limits: ContentLimits) throws -> (data: Data, placeholder: Unicode.Scalar?, ampPlaceholder: String?) {
        let limit = min(limits.bytes, Int(Int32.max))
        let text = try HTMLSourceEncoding.utf8(data, path: path, limit: limit).map { HTMLEntities.numericReferences(in: $0) } ?? rewritten
        guard let ampersands = HTMLLiteralAmpersands.prepared(text, limit: limit) else { throw ContentDocumentError.limitExceeded("bytes") }
        let recoveredText = try HTMLRecoveryText.prepared(ampersands.data, path: path, limit: limit)
        guard let signs = HTMLStraySigns.replaced(in: recoveredText, limit: limit),
              let source = HTMLNullCharacters.replaced(in: signs.data, limit: limit) else {
            throw ContentDocumentError.limitExceeded("bytes")
        }
        return (source, signs.placeholder, ampersands.placeholder)
    }

    /// `signPlaceholder` is what `HTMLStraySigns` gave the parser in place of a stray `<`.
    private static func convert(_ doc: xmlDocPtr, path: String, limits: ContentLimits,
                                recovered: Bool, html: Bool, signPlaceholder: Unicode.Scalar? = nil,
                                ampPlaceholder: String? = nil) throws -> ContentDocument? {
        guard let rootElement = xmlDocGetRootElement(doc) else { return nil }
        var nodes: [ContentNode] = []
        func string(_ value: UnsafePointer<xmlChar>?) -> String { value.map { String(cString: $0) } ?? "" }
        func restored(_ text: String) -> String {
            let signs = signPlaceholder.map { HTMLStraySigns.restored(text, from: $0) } ?? text
            return HTMLLiteralAmpersands.restored(signs, placeholder: ampPlaceholder)
        }
        func build(_ xml: xmlNodePtr, depth: Int, insideSVG: Bool = false) throws -> ContentNode {
            guard depth < limits.depth else { throw ContentDocumentError.limitExceeded("depth") }
            let rawName = string(xml.pointee.name)
            let recoveredSVG = html && (insideSVG || rawName.lowercased() == "svg")
            let namespace = html ? (recoveredSVG ? ContentNamespace.svg : "") : string(xml.pointee.ns?.pointee.href)
            let name = recoveredSVG ? HTMLSVGNames.element(rawName.lowercased())
                : namespace == ContentNamespace.xhtml || html ? rawName.lowercased() : rawName
            var attributes: [ContentAttribute] = []
            var attribute = xml.pointee.properties
            while let current = attribute {
                var value = ""
                var part = current.pointee.children
                while let text = part {
                    if !html, text.pointee.type == XML_ENTITY_REF_NODE,
                       text.pointee.children == nil { throw XMLTreeError.unresolvedEntity }
                    if let content = text.pointee.content { value += String(cString: content) }
                    part = text.pointee.next
                }
                let attributeNamespace = html ? "" : string(current.pointee.ns?.pointee.href)
                let local = string(current.pointee.name)
                attributes.append(recoveredSVG ? HTMLSVGNames.attribute(local.lowercased(), value: restored(value))
                    : ContentAttribute(name: html ? local.lowercased() : local,
                                       namespace: attributeNamespace, value: restored(value)))
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
                let text = ContentNode(text: restored(pendingText))
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
                    let element = try build(current, depth: depth + 1,
                                            insideSVG: recoveredSVG && !HTMLSVGNames.integrationPoints.contains(name))
                    element.parent = node; element.indexInParent = node.children.count
                    node.children.append(element)
                case XML_TEXT_NODE, XML_CDATA_SECTION_NODE:
                    if let content = current.pointee.content { pendingText += String(cString: content) }
                    hasPendingText = true
                case XML_ENTITY_REF_NODE:
                    // An external DTD makes an undeclared entity only a warning in
                    // libxml2. Refuse that XML tree instead of dropping its empty node.
                    if !html, current.pointee.children == nil { throw XMLTreeError.unresolvedEntity }
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
        return ContentDocument(path: path, root: root, nodes: nodes, recovered: recovered,
                               canResolveCFIs: !recovered)
    }

    /// Rebuild only the qualified XML-shaped HTML subset. HTML discards whitespace before
    /// head, keeps it between head and body, and puts trailing root whitespace in body.
    private static func htmlShaped(_ document: ContentDocument, source: Data, limits: ContentLimits) throws -> ContentDocument {
        let head = document.head!, body = document.body!
        let trailing = document.root.children.filter { $0.isText && $0.indexInParent > body.indexInParent }
            .map(\.text).joined() + HTMLCFICompatibility.trailingWhitespace(source)
        var nodes: [ContentNode] = []
        func clone(_ source: ContentNode, extraText: String = "") -> ContentNode {
            let node: ContentNode
            if source.isText { node = ContentNode(text: source.text + extraText) }
            else {
                let attributes = source.attributes.map { attribute in
                    let prefix = attribute.namespace == ContentNamespace.xml ? "xml:"
                        : attribute.namespace == ContentNamespace.ops ? "epub:" : ""
                    return ContentAttribute(name: prefix + attribute.name.lowercased(), namespace: "", value: attribute.value)
                }
                node = ContentNode(element: source.name.lowercased(), namespace: ContentNamespace.xhtml, attributes: attributes)
            }
            node.order = nodes.count; nodes.append(node)
            var children = source.children
            if source === document.root {
                children = children.filter { !($0.isText && ($0.indexInParent < head.indexInParent || $0.indexInParent > body.indexInParent)) }
            }
            for child in children {
                let copy = clone(child, extraText: source === body && child === children.last && child.isText ? trailing : "")
                copy.parent = node; copy.indexInParent = node.children.count; node.children.append(copy)
            }
            if source === body, !trailing.isEmpty, children.last?.isText != true {
                let text = ContentNode(text: trailing)
                text.parent = node; text.indexInParent = node.children.count
                text.order = nodes.count; text.subtreeEnd = text.order
                nodes.append(text); node.children.append(text)
            }
            node.subtreeEnd = nodes.count - 1
            return node
        }
        let root = clone(document.root)
        guard nodes.count <= limits.nodes else { throw ContentDocumentError.limitExceeded("nodes") }
        return ContentDocument(path: document.path, root: root, nodes: nodes, recovered: true, origin: document.origin)
    }
}

/// Named character references beyond XML's five, as numeric references, so XHTML that relies on
/// its DOCTYPE's entity set (`&nbsp;`, `&mdash;`) parses as XML without loading any DTD. CDATA
/// sections and comments are copied unchanged. Unknown names are left for the parser to reject.
enum HTMLEntities {
    static func numericReferences(in data: Data) -> Data {
        // Rewrite wide XML in its own encoding so the declaration and BOM still agree
        // with the bytes given to libxml2. Scanning UTF-16 bytes as ASCII splits names.
        if let (encoding, mark) = HTMLSourceEncoding.wide(data),
           let text = String(data: data.dropFirst(mark), encoding: encoding) {
            let utf8 = Data(text.utf8)
            let rewritten = numericReferences(in: utf8)
            guard rewritten != utf8,
                  let encoded = String(decoding: rewritten, as: UTF8.self).data(using: encoding) else { return data }
            return Data(data.prefix(mark)) + encoded
        }
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
                       let reference = HTMLNamedCharacterReferences.numeric[name] {
                        output.append(contentsOf: reference.utf8)
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
