import Foundation

extension MathMLNode {
    /// An English, spoken-style reading of the formula for assistive technologies when the
    /// markup has no `alttext`: "x squared plus 1", "start fraction a over b end fraction".
    /// Bounded like layout; content past the bounds is left out.
    public var accessibilityDescription: String {
        var speaker = Speaker()
        speaker.speak(self, depth: 0)
        return speaker.words.joined(separator: " ")
    }
}

private struct Speaker {
    var words: [String] = []
    private var count = 0

    private static let operators: [String: String] = [
        "+": "plus", "\u{2212}": "minus", "-": "minus", "±": "plus or minus", "∓": "minus or plus",
        "×": "times", "·": "times", "⋅": "times", "∗": "times", "*": "times", "÷": "divided by", "/": "over",
        "=": "equals", "≠": "is not equal to", "<": "is less than", ">": "is greater than",
        "≤": "is less than or equal to", "≥": "is greater than or equal to", "≈": "is approximately equal to",
        "≡": "is equivalent to", "∼": "is similar to", "∝": "is proportional to", "→": "goes to", "←": "left arrow",
        "⇒": "implies", "⇔": "if and only if", "∈": "is in", "∉": "is not in", "⊂": "is a subset of",
        "⊆": "is a subset of or equal to", "∪": "union", "∩": "intersection", "∑": "the sum", "∏": "the product",
        "∫": "the integral", "∮": "the contour integral", "∂": "partial", "∇": "nabla", "√": "square root",
        "′": "prime", "″": "double prime", "!": "factorial", "%": "percent", "°": "degrees", "∞": "infinity",
        "(": "open paren", ")": "close paren", "[": "open bracket", "]": "close bracket",
        "{": "open brace", "}": "close brace", "|": "vertical bar", "‖": "double vertical bar",
        "⟨": "open angle bracket", "⟩": "close angle bracket", "…": "dot dot dot", "⋯": "dot dot dot",
        "∀": "for all", "∃": "there exists", "¬": "not", "∧": "and", "∨": "or",
    ]
    private static let accents: [String: String] = [
        "^": "hat", "ˆ": "hat", "\u{0302}": "hat", "~": "tilde", "˜": "tilde", "\u{0303}": "tilde",
        "¯": "bar", "‾": "bar", "\u{0305}": "bar", "_": "underbar", "˙": "dot", "\u{0307}": "dot",
        "¨": "double dot", "\u{0308}": "double dot", "→": "vector", "\u{20D7}": "vector", "ˇ": "check",
        "˘": "breve", "⏞": "overbrace", "⏟": "underbrace",
    ]

    private func text(of node: MathMLNode) -> String { LayoutEngine.normalized(node.text) }

    private func isSimple(_ node: MathMLNode) -> Bool {
        if LayoutEngine.tokens.contains(node.name) { return true }
        if ["mrow", "mstyle"].contains(node.name), node.children.count == 1 { return isSimple(node.children[0]) }
        return false
    }

    mutating func speak(_ node: MathMLNode, depth: Int) {
        count += 1
        guard depth < MathLimits.depth, count <= MathLimits.nodes else { return }
        let children = node.children
        func child(_ index: Int) { if children.indices.contains(index) { speak(children[index], depth: depth + 1) } }
        func say(_ word: String) { if !word.isEmpty { words.append(word) } }
        switch node.name {
        case "mi", "mn", "mtext", "ms":
            say(text(of: node))
        case "mo":
            let value = text(of: node)
            if ["\u{2061}", "\u{2062}", "\u{2063}", "\u{2064}"].contains(value) { return }
            say(Self.operators[value] ?? value)
        case "mfrac":
            let simple = children.count == 2 && isSimple(children[0]) && isSimple(children[1])
            if !simple { say("start fraction") }
            child(0); say("over"); child(1)
            if !simple { say("end fraction") }
        case "msup":
            child(0)
            let power = children.count > 1 ? children[1] : MathMLNode(name: "none")
            switch (power.name, text(of: power)) {
            case ("mn", "2"): say("squared")
            case ("mn", "3"): say("cubed")
            case ("mo", "′"), ("mo", "'"): say("prime")
            default:
                say("to the power of"); child(1)
                if !isSimple(power) { say("end power") }
            }
        case "msub":
            child(0); say("sub"); child(1)
        case "msubsup":
            child(0); say("sub"); child(1); say("to the power of"); child(2)
        case "msqrt":
            say("the square root of")
            for item in children { speak(item, depth: depth + 1) }
            if children.count != 1 || !isSimple(children[0]) { say("end root") }
        case "mroot":
            let index = children.count > 1 ? text(of: children[1]) : ""
            switch index {
            case "2": say("the square root of")
            case "3": say("the cube root of")
            default: say("the root with index"); child(1); say("of")
            }
            child(0); say("end root")
        case "munder", "mover", "munderover":
            child(0)
            let over = node.name == "munder" ? nil : children.last
            if node.name == "mover", let over, let accent = Self.accents[text(of: over)] {
                say(accent)
            } else {
                if node.name != "mover" { say(node.name == "munder" ? "under" : "from"); child(1) }
                if let over, node.name != "munder" { say(node.name == "mover" ? "over" : "to"); speak(over, depth: depth + 1) }
            }
        case "mmultiscripts":
            child(0)
            for item in children.dropFirst() where item.name != "none" && item.name != "mprescripts" {
                say("script"); speak(item, depth: depth + 1)
            }
        case "mtable":
            say(children.count == 1 ? "table with 1 row" : "table with \(children.count) rows")
            for (index, row) in children.enumerated() {
                say("row \(index + 1):")
                for (cellIndex, cell) in row.children.enumerated() {
                    if cellIndex > 0 { say(",") }
                    speak(cell, depth: depth + 2)
                }
            }
        case "mfenced":
            say(Self.operators[node.attributes["open"] ?? "("] ?? node.attributes["open"] ?? "")
            for (index, item) in children.enumerated() {
                if index > 0 { say(",") }
                speak(item, depth: depth + 1)
            }
            say(Self.operators[node.attributes["close"] ?? ")"] ?? node.attributes["close"] ?? "")
        case "semantics", "maction":
            child(0)
        case "mphantom", "mspace", "none", "mprescripts", "annotation", "annotation-xml":
            return
        default:
            for item in children { speak(item, depth: depth + 1) }
        }
    }
}
