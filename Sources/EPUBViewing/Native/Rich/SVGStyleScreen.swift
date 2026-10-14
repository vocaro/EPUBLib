import Foundation

/// Refuse nested styles before any screen materializes their descendant text.
///
/// Serialization flattens each style's text in document order, and the renderer applies that
/// concatenated CSS (https://github.com/vocaro/EPUBLib/issues/375#issuecomment-6136122040).
/// Reading the same descendants for
/// every nested style therefore costs bytes times nesting depth. Such drawings use fallback;
/// sibling styles and ordinary text inside one style remain supported.
enum SVGStyleScreen {
    struct Verdict {
        let withinLimits: Bool
        /// Nodes inspected, independent of the number of bytes in their text or attributes.
        let visitedNodes: Int
    }

    static func verdict(_ svg: ContentNode) -> Verdict {
        var visitedNodes = 0
        func visit(_ node: ContentNode, depth: Int, insideStyle: Bool) -> Bool {
            guard depth <= SVGContent.maximumDepth, visitedNodes < SVGContent.maximumNodes else { return false }
            visitedNodes += 1
            let isStyle = node.name == "style"
            guard !(insideStyle && isStyle) else { return false }
            for child in node.children {
                guard visit(child, depth: depth + 1, insideStyle: insideStyle || isStyle) else { return false }
            }
            return true
        }
        let withinLimits = visit(svg, depth: 0, insideStyle: false)
        return Verdict(withinLimits: withinLimits, visitedNodes: visitedNodes)
    }
}
