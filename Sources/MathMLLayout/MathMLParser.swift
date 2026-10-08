import Foundation

extension MathMLNode {
    /// Parses a MathML document or fragment (`<math>…</math>`) with Foundation's `XMLParser`,
    /// for callers that have no DOM of their own. Namespaces are resolved and dropped, so a
    /// prefixed `<m:math>` reads the same. Only XML's predefined and numeric character
    /// references are known. Document type declarations are refused, so no entity can expand
    /// and nothing external loads; depth and node count are bounded.
    public static func parse(xml data: Data) throws -> MathMLNode {
        guard data.count <= 4 * 1024 * 1024 else { throw MathLayoutError.limitExceeded }
        if data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!ENTITY".utf8)) != nil {
            throw MathLayoutError.invalidMarkup("DOCTYPE")
        }
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        let parsed = parser.parse()
        if let error = builder.error { throw error }
        guard parsed, let root = builder.root else {
            throw MathLayoutError.invalidMarkup(parser.parserError?.localizedDescription ?? "XML")
        }
        return root
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: MathMLNode?
    var error: MathLayoutError?
    private var stack: [MathMLNode] = []
    private var count = 0
    /// Depth of elements nested inside a token, whose text joins the token's.
    private var tokenDepth = 0

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        count += 1
        guard count <= MathLimits.nodes, stack.count < MathLimits.depth else {
            error = .limitExceeded
            parser.abortParsing()
            return
        }
        if tokenDepth > 0 || stack.last.map({ LayoutEngine.tokens.contains($0.name) }) == true {
            if tokenDepth == 0 { stack[stack.count - 1].children.append(MathMLNode(name: name)) }
            tokenDepth += 1
            return
        }
        var local: [String: String] = [:]
        for (key, value) in attributes where !key.hasPrefix("xmlns") {
            local[String(key.split(separator: ":").last ?? Substring(key))] = value
        }
        stack.append(MathMLNode(name: name, attributes: local))
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if tokenDepth > 0 { tokenDepth -= 1; return }
        guard let node = stack.popLast() else { return }
        if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }

    func parser(_ parser: XMLParser, foundCDATA data: Data) { append(String(decoding: data, as: UTF8.self)) }

    private func append(_ string: String) {
        guard let last = stack.last, LayoutEngine.tokens.contains(last.name) else { return }
        stack[stack.count - 1].text += string
    }
}
