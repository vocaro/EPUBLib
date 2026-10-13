import Foundation

/// A deliberately small, structurally checked subset whose XML tree can be converted to the
/// HTML tree Foliate used. This is a compatibility qualification, not another forgiving parser.
/// Anything requiring HTML tree repair remains readable through libxml2, with CFIs disabled.
enum HTMLCFICompatibility {
    private static let voids: Set<String> = ["br", "hr", "img", "meta", "link"]
    private static let inline: Set<String> = ["span", "b", "i", "em", "strong", "u", "s", "small",
        "sub", "sup", "a", "br", "img", "code", "q", "cite", "abbr", "mark"]
    private static let paragraphs: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "pre"]
    private static let containers: Set<String> = ["body", "div", "section", "article", "aside", "header",
        "footer", "nav", "main", "blockquote", "figure", "figcaption", "li", "dt", "dd"]
    private static let lists: Set<String> = ["ul", "ol", "dl"]

    static func hasXHTMLDTD(_ data: Data) -> Bool {
        let source: String?
        if let (encoding, mark) = HTMLSourceEncoding.wide(data) {
            source = String(data: data.dropFirst(mark), encoding: encoding)
        } else { source = String(data: data, encoding: .utf8) }
        guard let source, let tags = tokens(source) else { return false }
        let identifiers = ["-//W3C//DTD XHTML 1.0 Strict//EN", "-//W3C//DTD XHTML 1.0 Transitional//EN",
                           "-//W3C//DTD XHTML 1.0 Frameset//EN", "-//W3C//DTD XHTML 1.1//EN"]
        return tags.contains { tag in
            guard let header = tag.range(of: #"^<!DOCTYPE\s+html\s+PUBLIC\s+"#, options: .regularExpression) else { return false }
            let tail = tag[header.upperBound...].drop(while: \.isWhitespace)
            guard let quote = tail.first, quote == "\"" || quote == "'",
                  let end = tail.dropFirst().firstIndex(of: quote) else { return false }
            return identifiers.contains(String(tail[tail.index(after: tail.startIndex)..<end]))
        }
    }

    static func accepts(_ data: Data, document: ContentDocument) -> Bool {
        guard let source = String(data: data, encoding: .utf8), let tags = tokens(source),
              !source.utf8.contains(0), document.root.name == "html",
              let head = document.head, let body = document.body,
              document.root.elementChildren.count == 2, head.indexInParent < body.indexInParent,
              document.root.children.filter(\.isText).allSatisfy({ asciiWhitespace($0.text) })
        else { return false }
        // Numeric references in the HTML error range are remapped by HTML 5 (e.g. 0x80 to €).
        // Refuse them even when XML and HTML 4 both accept the original scalar.
        if source.range(of: #"&#(?:[xX](?:0*[89][0-9a-fA-F]|0*0)|0*(?:12[89]|1[3-5][0-9]|0));"#,
                        options: .regularExpression) != nil { return false }
        for tag in tags {
            if tag.hasPrefix("<![CDATA[") { return false }
            if tag.hasPrefix("<?"), !tag.hasPrefix("<?xml ") { return false }
            if tag.hasPrefix("<?xml "),
               let encoding = tag.range(of: #"encoding\s*=\s*['\"][^'\"]+['\"]"#, options: .regularExpression) {
                let declaration = String(tag[encoding])
                let value = declaration.split(whereSeparator: { $0 == "'" || $0 == "\"" })
                guard value.count >= 2, value[1].lowercased() == "utf-8" else { return false }
            }
            if tag.hasPrefix("</") {
                let name = tag.dropFirst(2).prefix { !$0.isWhitespace && $0 != ">" }.lowercased()
                // In HTML, </br> creates another br; XML's empty <br></br> has only one.
                if voids.contains(name) { return false }
                continue
            }
            if tag.hasPrefix("<!") || tag.hasPrefix("<?") { continue }
            // XML normalizes literal attribute tabs and line endings to spaces; HTML
            // preserves them. Numeric references are intentionally not literal whitespace.
            var quote: Character?
            for character in tag {
                if let delimiter = quote {
                    if character == delimiter { quote = nil }
                    else if character == "\t" || character == "\n" || character == "\r" { return false }
                } else if character == "\"" || character == "'" { quote = character }
            }
            let name = tag.dropFirst().prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }
            // Foreign/prefixed elements and self-closing nonvoid elements have different
            // HTML namespace or insertion-mode rules, even when the XML is well formed.
            if name.contains(":"), !name.isEmpty { return false }
            if tag.dropLast().last == "/", !voids.contains(name.lowercased()) { return false }
        }
        func qualifies(_ node: ContentNode, insideAnchor: Bool = false) -> Bool {
            if node.isText { return true }
            guard node.namespace.isEmpty || node.namespace == ContentNamespace.xhtml,
                  node.attributes.allSatisfy({ $0.namespace.isEmpty || $0.namespace == ContentNamespace.xml || $0.namespace == ContentNamespace.ops })
            else { return false }
            let name = node.name
            if name == "a", insideAnchor { return false }
            let elementNames = node.elementChildren.map(\.name)
            if node === document.root {
                guard elementNames == ["head", "body"] else { return false }
            } else if node === head {
                guard elementNames.filter({ $0 == "title" }).count <= 1,
                      elementNames.allSatisfy({ ["title", "meta", "link"].contains($0) }),
                      node.children.filter(\.isText).allSatisfy({ asciiWhitespace($0.text) }) else { return false }
            } else if name == "title" {
                // RCDATA interprets character references, but literal XML '<' becomes
                // text in HTML rather than markup; reject tags and encoded less-than.
                guard node.parent === head, node.elementChildren.isEmpty,
                      !node.textContent.contains("<") else { return false }
            } else if voids.contains(name) {
                guard node.children.isEmpty,
                      ["meta", "link"].contains(name) ? node.parent === head : node.parent !== head else { return false }
            } else if inline.contains(name) || paragraphs.contains(name) {
                guard elementNames.allSatisfy(inline.contains) else { return false }
                // HTML drops one initial LF in pre, unlike XML.
                if name == "pre", node.children.first?.text.hasPrefix("\n") == true { return false }
            } else if lists.contains(name) {
                let allowed: Set<String> = name == "dl" ? ["dt", "dd"] : ["li"]
                guard elementNames.allSatisfy(allowed.contains),
                      node.children.filter(\.isText).allSatisfy({ asciiWhitespace($0.text) }) else { return false }
            } else if containers.contains(name) {
                if name == "li", !["ul", "ol"].contains(node.parent?.name ?? "") { return false }
                if ["dt", "dd"].contains(name), node.parent?.name != "dl" { return false }
                let flow = inline.union(paragraphs).union(containers.subtracting(["body", "li", "dt", "dd"])).union(lists).union(["hr"])
                guard elementNames.allSatisfy(flow.contains) else { return false }
            } else { return false }
            return node.children.allSatisfy { qualifies($0, insideAnchor: insideAnchor || name == "a") }
        }
        return qualifies(document.root)
    }

    /// XML discards whitespace outside its root. Qualified HTML moves the whitespace
    /// after that root into the body, ignoring comments that remain document children.
    /// Walk the suffix only; a closing tag written inside a comment is never a boundary.
    static func trailingWhitespace(_ data: Data) -> String {
        let bytes = Array(data)
        var end = bytes.count, reversed: [UInt8] = []
        while end > 0 {
            if [UInt8(9), 10, 13, 32].contains(bytes[end - 1]) {
                reversed.append(bytes[end - 1]); end -= 1
            } else if end >= 3, bytes[(end - 3)..<end].elementsEqual("-->".utf8) {
                var start = end - 3
                while start >= 4, !bytes[(start - 4)..<start].elementsEqual("<!--".utf8) { start -= 1 }
                guard start >= 4 else { break }
                end = start - 4
            } else { break }
        }
        return String(decoding: reversed.reversed(), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func asciiWhitespace(_ string: String) -> Bool {
        string.utf8.allSatisfy { [UInt8(9), 10, 12, 13, 32].contains($0) }
    }

    /// Markup tokens with quote-aware tag endings; comment contents never become tags.
    /// Input has already passed XMLSafety and strict XML parsing before qualification.
    private static func tokens(_ source: String) -> [String]? {
        let bytes = Array(source.utf8)
        var index = 0, result: [String] = []
        func starts(_ value: String) -> Bool { bytes[index...].starts(with: value.utf8) }
        while index < bytes.count {
            guard bytes[index] == 60 else { index += 1; continue }
            let start = index
            if starts("<!--") {
                index += 4
                while index < bytes.count, !starts("-->") { index += 1 }
                guard index < bytes.count else { return nil }
                index += 3; continue
            }
            if starts("<![CDATA[") {
                result.append("<![CDATA["); return result
            }
            var quote: UInt8?
            index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if let delimiter = quote {
                    if byte == delimiter { quote = nil }
                } else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { break }
            }
            guard index <= bytes.count, bytes[index - 1] == 62 else { return nil }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
        }
        return result
    }
}
