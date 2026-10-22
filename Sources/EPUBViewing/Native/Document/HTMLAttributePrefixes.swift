import Foundation

/// What the prefix of an attribute's name stands for in a section read as HTML. There a name such
/// as `epub:type` is one name in no namespace, as a browser's HTML parser makes it, and
/// `[epub\:type]` matches it. Selectors also match it as the attribute an XML parser would have
/// read, `type` in the namespace its prefix is bound to (`ContentAttribute.prefixNamespace`), so
/// `[ops|type]` reaches `epub:type` by namespace, as in XHTML (#642). That namespace is the one
/// the book's `xmlns:` declaration in scope gives the prefix. `xml` is always the XML namespace,
/// and `epub`, where the book declares no namespace for it, is the OPS namespace, as the reader
/// already reads an undeclared `epub:type` (`ContentSemantics`).
///
/// An attribute whose prefix stands for the OPS namespace is named `epub:`, as the XML-shaped
/// route has always named it, so a book's `ops:type` is `epub:type` whichever route read the
/// section, and its notes are read the same.
enum HTMLAttributePrefixes {
    /// The declarations in scope at an element: those in scope at its parent, with the element's
    /// own `xmlns:` declarations over them, which hold for its own attributes too. An empty one
    /// unbinds its prefix, as XML 1.1 lets it.
    static func scope(_ attributes: [(name: String, value: String)], inheriting scope: [String: String]) -> [String: String] {
        var scope = scope
        for (name, value) in attributes {
            guard let (prefix, local) = split(name), prefix == "xmlns" else { continue }
            scope[local] = value.isEmpty ? nil : value
        }
        return scope
    }

    /// An element's attributes, named and lowercased as libxml2's HTML parser wrote them.
    static func attributes(_ written: [(name: String, value: String)], scope: [String: String]) -> [ContentAttribute] {
        written.map { name, value in
            // A declaration is no attribute in a namespace, as in XHTML, where the reader keeps none.
            guard let (prefix, local) = split(name), prefix != "xmlns", let uri = namespace(of: prefix, in: scope) else {
                return ContentAttribute(name: name, namespace: "", value: value)
            }
            let renamed = "epub:" + local
            // HTML keeps one attribute of a name, so one the book already wrote as `epub:` keeps it.
            let rename = uri == ContentNamespace.ops && prefix != "epub" && !written.contains { $0.name.utf8.elementsEqual(renamed.utf8) }
            return ContentAttribute(name: rename ? renamed : name, namespace: "", value: value, prefixNamespace: uri)
        }
    }

    static func namespace(of prefix: String, in scope: [String: String]) -> String? {
        if prefix == "xml" { return ContentNamespace.xml }
        return scope[prefix] ?? (prefix == "epub" ? ContentNamespace.ops : nil)
    }

    /// The prefix and local name either side of the first colon, when neither is empty.
    private static func split(_ name: String) -> (prefix: String, local: String)? {
        guard let colon = name.utf8.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        let prefix = String(name[..<colon]), local = String(name[name.utf8.index(after: colon)...])
        return prefix.isEmpty || local.isEmpty ? nil : (prefix, local)
    }
}
