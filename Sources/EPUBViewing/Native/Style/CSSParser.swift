import Foundation

/// A CSS component value (CSS Syntax §5): a preserved token, a function or a simple block.
indirect enum CSSComponent: Equatable, Sendable {
    case token(CSSToken)
    /// Name lowercased.
    case function(String, [CSSComponent])
    /// `open` is `.openCurly`, `.openParen` or `.openSquare`.
    case block(CSSToken, [CSSComponent])

    var isWhitespace: Bool { self == .token(.whitespace) }
    /// The lowercased value of an ident token.
    var ident: String? {
        if case .token(.ident(let value)) = self { return value.lowercased() }
        return nil
    }
    func isDelim(_ scalar: Unicode.Scalar) -> Bool { self == .token(.delim(scalar)) }
    var curlyBlock: [CSSComponent]? {
        if case .block(.openCurly, let contents) = self { return contents }
        return nil
    }
}

extension Array where Element == CSSComponent {
    /// Without whitespace tokens at this level.
    var significant: [CSSComponent] { filter { !$0.isWhitespace } }
    /// Split at top-level commas, each part without whitespace.
    var commaSeparated: [[CSSComponent]] {
        split(separator: .token(.comma), omittingEmptySubsequences: false).map { Array($0).significant }
    }
}

/// A rule as CSS Syntax parses it, before its prelude or block is interpreted.
enum CSSRawRule {
    /// Name lowercased; `block` is nil for a statement (`@import …;`).
    case at(name: String, prelude: [CSSComponent], block: [CSSComponent]?)
    case qualified(prelude: [CSSComponent], block: [CSSComponent])
}

struct CSSRawDeclaration {
    /// Lowercased.
    let name: String
    let value: [CSSComponent]
    let important: Bool
}

enum CSSParser {
    /// Nesting deeper than this is dropped (and reported) so hostile input cannot exhaust the stack.
    static let maximumNesting = 32

    /// Tokenizes `text` into component values. `truncated` is set when nesting was dropped.
    static func components(_ text: String, truncated: inout Bool) -> [CSSComponent] {
        var tokenizer = CSSTokenizer(text)
        return consumeComponents(&tokenizer, until: nil, depth: 0, truncated: &truncated)
    }

    private static func consumeComponents(_ tokenizer: inout CSSTokenizer, until close: CSSToken?, depth: Int,
                                          truncated: inout Bool) -> [CSSComponent] {
        var result: [CSSComponent] = []
        while let token = tokenizer.next() {
            if let close, token == close { return result }
            switch token {
            case .openCurly, .openParen, .openSquare, .function:
                let closing: CSSToken = token == .openCurly ? .closeCurly : token == .openSquare ? .closeSquare : .closeParen
                guard depth < maximumNesting else {
                    truncated = true
                    skipBlock(&tokenizer, close: closing)
                    continue
                }
                let contents = consumeComponents(&tokenizer, until: closing, depth: depth + 1, truncated: &truncated)
                if case .function(let name) = token { result.append(.function(name.lowercased(), contents)) }
                else { result.append(.block(token, contents)) }
            default:
                result.append(.token(token))
            }
        }
        return result
    }

    private static func skipBlock(_ tokenizer: inout CSSTokenizer, close: CSSToken) {
        var stack = [close]
        while let token = tokenizer.next(), let expected = stack.last {
            switch token {
            case .openCurly: stack.append(.closeCurly)
            case .openSquare: stack.append(.closeSquare)
            case .openParen, .function: stack.append(.closeParen)
            case expected: stack.removeLast(); if stack.isEmpty { return }
            default: break
            }
        }
    }

    /// Parses a list of rules (§5.4.1). At top level, `<!--` and `-->` are ignored.
    static func rules(_ components: [CSSComponent], topLevel: Bool) -> [CSSRawRule] {
        var rules: [CSSRawRule] = []
        var index = 0
        while index < components.count {
            let component = components[index]
            switch component {
            case .token(.whitespace), .token(.semicolon):
                index += 1
            case .token(.cdo) where topLevel, .token(.cdc) where topLevel:
                index += 1
            case .token(.atKeyword(let name)):
                index += 1
                var prelude: [CSSComponent] = []
                var block: [CSSComponent]?
                while index < components.count {
                    let next = components[index]
                    index += 1
                    if next == .token(.semicolon) { break }
                    if let contents = next.curlyBlock { block = contents; break }
                    prelude.append(next)
                }
                rules.append(.at(name: name.lowercased(), prelude: prelude, block: block))
            default:
                var prelude: [CSSComponent] = []
                var block: [CSSComponent]?
                while index < components.count {
                    let next = components[index]
                    index += 1
                    if let contents = next.curlyBlock { block = contents; break }
                    prelude.append(next)
                }
                if let block { rules.append(.qualified(prelude: prelude, block: block)) }
            }
        }
        return rules
    }

    /// Parses a declaration list (§5.4.5), skipping invalid declarations, at-rules and nested
    /// rules, which this renderer does not support.
    static func declarations(_ components: [CSSComponent]) -> [CSSRawDeclaration] {
        var declarations: [CSSRawDeclaration] = []
        var index = 0
        while index < components.count {
            let component = components[index]
            switch component {
            case .token(.whitespace), .token(.semicolon):
                index += 1
            case .token(.ident(let name)):
                var item: [CSSComponent] = []
                var nestedRule = false
                index += 1
                while index < components.count, components[index] != .token(.semicolon) {
                    let next = components[index]
                    index += 1
                    if next.curlyBlock != nil, !name.hasPrefix("--") { nestedRule = true; break }
                    item.append(next)
                }
                guard !nestedRule, let declaration = declaration(name: name, item) else { continue }
                declarations.append(declaration)
            default:
                // An at-rule or a nested rule: skip to the end of its block or statement.
                index += 1
                while index < components.count {
                    let next = components[index]
                    index += 1
                    if next == .token(.semicolon) || next.curlyBlock != nil { break }
                }
            }
        }
        return declarations
    }

    private static func declaration(name: String, _ item: [CSSComponent]) -> CSSRawDeclaration? {
        var index = 0
        while index < item.count, item[index].isWhitespace { index += 1 }
        guard index < item.count, item[index] == .token(.colon) else { return nil }
        var value = Array(item[(index + 1)...])
        while value.first?.isWhitespace == true { value.removeFirst() }
        while value.last?.isWhitespace == true { value.removeLast() }
        var important = false
        if value.last?.ident == "important" {
            var end = value.count - 2
            while end >= 0, value[end].isWhitespace { end -= 1 }
            if end >= 0, value[end].isDelim("!") {
                important = true
                value.removeSubrange(end...)
                while value.last?.isWhitespace == true { value.removeLast() }
            }
        }
        return CSSRawDeclaration(name: name.lowercased(), value: value, important: important)
    }
}
