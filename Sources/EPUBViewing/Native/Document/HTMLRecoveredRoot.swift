import Foundation
import libxml2

/// The one root that the HTML Standard builds, from the roots libxml2's HTML parser builds.
///
/// libxml2 reads a root start tag that has lost the closing quote of its last attribute, and so
/// runs to the "/>" of an empty element after it, as self-closing: it closes that root at once
/// and builds what follows in another `html` element, inside the root or, after a DOCTYPE or a
/// comment, beside it. The root then holds no body, and the section showed nothing. HTML ignores
/// the "/" and reads what follows in its one root, and gives that root each attribute of a later
/// `html` start tag that it lacks. A DOCTYPE that ends at its first `>` (#293) leaves such a root
/// tag to libxml2 where it used to take the tag with it. So, while the root holds no body, the
/// content of such an `html` is moved into the root where it stands, and its attributes are
/// added where the root lacks them; what follows the root is then read into the body as before.
enum HTMLRecoveredRoot {
    static func merge(_ doc: xmlDocPtr) {
        guard let root = xmlDocGetRootElement(doc) else { return }
        while !holds("body", root), let inner = html(in: root) ?? html(after: root) {
            var attribute = inner.pointee.properties
            while let property = attribute {
                if let name = property.pointee.name, xmlHasProp(root, name) == nil {
                    var value: [UInt8] = []
                    var part = property.pointee.children
                    while let text = part {
                        if let content = text.pointee.content { value.append(contentsOf: UnsafeBufferPointer(start: content, count: Int(xmlStrlen(content)))) }
                        part = text.pointee.next
                    }
                    _ = xmlSetProp(root, name, value + [0])
                }
                attribute = property.pointee.next
            }
            let nested = inner.pointee.parent == root
            while let child = inner.pointee.children {
                xmlUnlinkNode(child)
                _ = nested ? xmlAddPrevSibling(inner, child) : xmlAddChild(root, child)
            }
            xmlUnlinkNode(inner)
            xmlFreeNode(inner)
        }
    }

    private static func isElement(_ node: xmlNodePtr, _ name: String) -> Bool {
        node.pointee.type == XML_ELEMENT_NODE && String(cString: node.pointee.name) == name
    }

    private static func holds(_ name: String, _ parent: xmlNodePtr) -> Bool {
        var child = parent.pointee.children
        while let node = child {
            if isElement(node, name) { return true }
            child = node.pointee.next
        }
        return false
    }

    private static func html(in parent: xmlNodePtr) -> xmlNodePtr? {
        var child = parent.pointee.children
        while let node = child {
            if isElement(node, "html") { return node }
            child = node.pointee.next
        }
        return nil
    }

    private static func html(after root: xmlNodePtr) -> xmlNodePtr? {
        var sibling = root.pointee.next
        while let node = sibling {
            if isElement(node, "html") { return node }
            sibling = node.pointee.next
        }
        return nil
    }
}
