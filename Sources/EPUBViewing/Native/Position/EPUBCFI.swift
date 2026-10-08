import EPUBCore
import Foundation

// A Swift port of foliate-js `epubcfi.js` (MIT License, Copyright (c) 2022 John Factotum), as
// vendored at `Sources/EPUBViewing/Resources/epub-reader/lib/epubcfi.js`, upstream commit
// 78914aef4466eb960965702401634c2cb348e9b1. The grammar, the string form and the chunk model are
// kept quirk for quirk, because every CFI the WebKit reader stored was produced by that code.
// Where foliate-js threw, these functions return nil or throw instead.

/// EPUB Canonical Fragment Identifiers, generated and resolved exactly as foliate-js does, so
/// `epubcfi-v1` bookmarks and highlight locators saved by the WebKit reader keep resolving.
///
/// Resolution yields `DOMPosition`s, which can only name a text offset or an element's start.
/// foliate-js's DOM ranges map onto them as follows, each naming the same place in the text:
/// - a step into a text chunk names that text node, its offset clamped to the node (foliate threw
///   on a stale offset, or on a merged chunk without one);
/// - a step that ends on an element, or an ID assertion that finds one, names the element's
///   start; a character offset on an element step is ignored, as the CFI grammar intends;
/// - the virtual `before` index (`/0`) names the start of the element being indexed, as foliate's
///   `setStartBefore` put the boundary just before it;
/// - the virtual `after` index (`n + 2`) names the first node after that element's subtree, or
///   the end of the document's last node when nothing follows (foliate's `setStartAfter`);
/// - the virtual `first` and `last` indices name the start of the first or last child element,
///   as foliate's `firstChild`/`lastChild` did (with a trailing comment, which `ContentDocument`
///   does not keep, foliate's `last` landed after that element instead);
/// - the missing chunk between two adjacent elements, an index past `after`, a step below a text
///   node or into an element without children, and an empty path name nothing: nil.
/// A range whose end precedes its start collapses to its end, as DOM ranges do.
///
/// `ContentDocument` matches the XML DOM WebKit built for foliate. WebKit refused a document
/// with an HTML named entity but no XHTML 1.x DOCTYPE, or with a root in no namespace, and foliate
/// re-read it as HTML, whose tree construction drops the white space before `head` and appends
/// what follows `body` to it. `ContentDocument` reads such a document as XML, so its CFIs agree
/// with foliate's except in that white space, and except where HTML tree construction reshapes
/// markup (self-closed non-void elements, tables without `tbody`, CDATA).
enum EPUBCFI {
    /// A parsed CFI: one path per indirection (`!`), or a range with a common parent.
    struct Expression: Equatable, Sendable {
        struct Step: Equatable, Sendable {
            var index: Int
            var id: String?
            var offset: Int?
            var temporal: Double?
            var spatial: [Double]?
            var text: [String]?
            var side: String?
        }
        /// `paths[0]` is the package path, `paths[1]` the content-document path.
        typealias Path = [[Step]]
        var path: Path?
        var parent: Path?
        var start: Path?
        var end: Path?
        var isRange: Bool { parent != nil }
    }

    /// The longest CFI `isWellFormed` accepts, in characters. Range CFIs locating long
    /// highlights outgrow the WebKit bridge's old 1,024-character cap.
    static let maximumLength = 4_096
    /// Input longer than this many UTF-16 units is refused by `parse`, which bounds all CFI work.
    static let maximumParseLength = 65_536

    // MARK: - Strings

    /// foliate `isCFI`, `/^epubcfi\((.*)\)$/`: wrapped, with no line terminator inside.
    static func isCFI(_ string: String) -> Bool { unwrapped(string) != nil }

    static func wrap(_ string: String) -> String { isCFI(string) ? string : "epubcfi(\(string))" }
    static func unwrap(_ string: String) -> String { unwrapped(string) ?? string }

    /// foliate `joinIndir`: the CFIs' contents joined by `!`, wrapped once.
    static func joinIndirections(_ cfis: String...) -> String {
        "epubcfi(" + cfis.map(unwrap).joined(separator: "!") + ")"
    }

    private static func unwrapped(_ string: String) -> String? {
        let scalars = string.unicodeScalars
        guard scalars.starts(with: "epubcfi(".unicodeScalars), scalars.last == ")" else { return nil }
        let inner = scalars.dropFirst(8).dropLast()
        guard !inner.contains(where: isLineTerminator) else { return nil }
        return String(Substring(inner))
    }

    /// The WebKit bridge's character rules (`ReaderEPUBCFI.isWellFormed`): wrapped once with
    /// balanced unescaped parentheses, no C0 or C1 control or line or paragraph separator, at most
    /// `maximumLength` characters. A shape check for stored locators, not a parse.
    static func isWellFormed(_ cfi: String) -> Bool {
        guard cfi.count <= maximumLength, cfi.hasPrefix("epubcfi("), cfi.hasSuffix(")"),
              cfi.count > "epubcfi()".count
        else { return false }
        var depth = 0
        var isEscaped = false
        var isClosed = false
        for scalar in cfi.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029: return false
            default: break
            }
            guard !isClosed else { return false }
            if isEscaped {
                isEscaped = false
                continue
            }
            switch scalar {
            case "^": isEscaped = true
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth < 0 { return false }
                isClosed = depth == 0
            default: break
            }
        }
        return isClosed
    }

    // MARK: - Parsing

    private enum Token: Equatable {
        case slash(Int), colon(Int), tilde(Double), at(Double)
        case bracket(String), parameter(name: String, value: String), bang, comma
    }

    private enum TokenizerState: Equatable { case bang, comma, slash, colon, tilde, at, bracket, parameter(String) }

    /// foliate `tokenizer`, including its escape flag, which only a consumed character clears.
    private static func tokenize(_ string: String) throws -> [Token] {
        var tokens: [Token] = []
        var state: TokenizerState?
        var escape = false
        var value = String.UnicodeScalarView()
        func push(_ token: Token) { tokens.append(token); state = nil; value = .init() }
        func cat(_ scalar: Unicode.Scalar?) {
            if let scalar { value.append(scalar) }
            escape = false
        }
        let scalars = jsTrimmed(string)
        var position = scalars.startIndex
        while true {
            // `nil` is foliate's trailing '' sentinel, which flushes the last token.
            let char: Unicode.Scalar? = position < scalars.endIndex ? scalars[position] : nil
            if char != nil { position = scalars.index(after: position) }
            if char == "^", !escape { escape = true; continue }
            switch state {
            case .bang?: push(.bang)
            case .comma?: push(.comma)
            case .slash?, .colon?:
                if let char, isDigit(char) { cat(char); continue }
                // Beyond 2^53 foliate's numbers were no longer exact; nothing it wrote got there.
                guard let number = Int(String(value)), number <= 1 << 53 else { throw EPUBReaderError.incompatibleLocation }
                push(state == .slash ? .slash(number) : .colon(number))
            case .tilde?:
                if let char, isDigit(char) || char == "." { cat(char); continue }
                push(.tilde(jsParseFloat(value)))
            case .at?:
                if char == ":" { push(.at(jsParseFloat(value))); state = .at; continue }
                if let char, isDigit(char) || char == "." { cat(char); continue }
                push(.at(jsParseFloat(value)))
            case .bracket?:
                if char == ";", !escape { push(.bracket(String(value))); state = .parameter("") }
                else if char == ",", !escape { push(.bracket(String(value))); state = .bracket }
                else if char == "]", !escape { push(.bracket(String(value))) }
                else { cat(char) }
                if char == nil { return tokens }
                continue
            case .parameter(let name)?:
                if char == "=", !escape { state = .parameter(String(value)); value = .init() }
                else if char == ";", !escape { push(.parameter(name: name, value: String(value))); state = .parameter("") }
                else if char == "]", !escape { push(.parameter(name: name, value: String(value))) }
                else { cat(char) }
                if char == nil { return tokens }
                continue
            case nil: break
            }
            switch char {
            case "/"?: state = .slash
            case ":"?: state = .colon
            case "~"?: state = .tilde
            case "@"?: state = .at
            case "["?: state = .bracket
            case "!"?: state = .bang
            case ","?: state = .comma
            case nil: return tokens
            default: break
            }
        }
    }

    /// foliate `parser`. Throws where foliate dereferenced a missing step.
    private static func parsePath(_ tokens: ArraySlice<Token>) throws -> [Expression.Step] {
        var parts: [Expression.Step] = []
        var previousIsSlash = false
        for token in tokens {
            if case .slash(let index) = token {
                parts.append(Expression.Step(index: index))
                previousIsSlash = true
                continue
            }
            if case .parameter(let name, _) = token, name != "s" { previousIsSlash = false; continue }
            guard !parts.isEmpty else { throw EPUBReaderError.incompatibleLocation }
            let last = parts.count - 1
            switch token {
            case .colon(let offset): parts[last].offset = offset
            case .tilde(let temporal): parts[last].temporal = temporal
            case .at(let spatial): parts[last].spatial = (parts[last].spatial ?? []) + [spatial]
            case .parameter(_, let side): parts[last].side = side
            case .bracket(let value):
                if previousIsSlash, !value.isEmpty { parts[last].id = value }
                else {
                    // A text assertion leaves the previous token type in place, as foliate's
                    // `continue` does, so `/4[][x]` still asserts the ID `x`.
                    parts[last].text = (parts[last].text ?? []) + [value]
                    continue
                }
            case .slash, .bang, .comma: break
            }
            previousIsSlash = false
        }
        return parts
    }

    /// foliate `splitAt`: the slices between the given token positions.
    private static func split(_ tokens: ArraySlice<Token>, at positions: [Int]) -> [ArraySlice<Token>] {
        var slices: [ArraySlice<Token>] = []
        var start = tokens.startIndex
        for position in positions + [tokens.endIndex] {
            slices.append(tokens[start..<position])
            start = position + 1
        }
        return slices
    }

    private static func parseIndirections(_ tokens: ArraySlice<Token>) throws -> Expression.Path {
        try split(tokens, at: tokens.indices.filter { tokens[$0] == .bang }).map(parsePath)
    }

    /// foliate `parse`. Lenient as foliate is (characters outside the grammar are skipped), but
    /// it throws for what foliate could not use: a parameter before any step, a step or offset
    /// without digits or beyond 2^53, a range without both ends, or input over
    /// `maximumParseLength`.
    static func parse(_ string: String) throws -> Expression {
        guard string.utf16.count <= maximumParseLength else { throw EPUBReaderError.incompatibleLocation }
        let tokens = try tokenize(unwrap(string))[...]
        let commas = tokens.indices.filter { tokens[$0] == .comma }
        if commas.isEmpty { return Expression(path: try parseIndirections(tokens)) }
        let groups = try split(tokens, at: commas).map(parseIndirections)
        guard groups.count >= 3 else { throw EPUBReaderError.incompatibleLocation }
        return Expression(parent: groups[0], start: groups[1], end: groups[2])
    }

    /// foliate `toString`.
    static func string(_ expression: Expression) -> String { wrap(innerString(expression)) }

    /// foliate `toInnerString`: the CFI without its `epubcfi(…)` wrapper.
    static func innerString(_ expression: Expression) -> String {
        if let parent = expression.parent {
            return [parent, expression.start ?? [], expression.end ?? []].map(pathString).joined(separator: ",")
        }
        return pathString(expression.path ?? [])
    }

    static func pathString(_ path: Expression.Path) -> String {
        path.map { $0.map(stepString).joined() }.joined(separator: "!")
    }

    /// foliate `partToString`: an offset only on a character-data (odd) step, the side bias in
    /// the ID assertion when there is one, and the side bias itself unescaped.
    private static func stepString(_ step: Expression.Step) -> String {
        let side = step.side ?? ""
        let parameter = side.isEmpty ? "" : ";s=\(side)"
        let id = step.id ?? ""
        var string = "/\(step.index)"
        if !id.isEmpty { string += "[\(escape(id))\(parameter)]" }
        if let offset = step.offset, step.index % 2 != 0 { string += ":\(offset)" }
        if let temporal = step.temporal, temporal != 0, !temporal.isNaN { string += "~\(jsNumber(temporal))" }
        if let spatial = step.spatial { string += "@" + spatial.map(jsNumber).joined(separator: ":") }
        if step.text != nil || (id.isEmpty && !side.isEmpty) {
            string += "[" + (step.text?.map(escape).joined(separator: ",") ?? "") + parameter + "]"
        }
        return string
    }

    /// foliate `escapeCFI`.
    private static func escape(_ string: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            if "^[](),;=".unicodeScalars.contains(scalar) { escaped.append("^") }
            escaped.append(scalar)
        }
        return String(escaped)
    }

    // MARK: - Ordering and ranges

    /// foliate `compare`: -1, 0 or 1 in reading order. A string that does not parse orders as an
    /// empty path, before every other CFI.
    static func compare(_ a: String, _ b: String) -> Int {
        let empty = Expression(path: [[]])
        return compare((try? parse(a)) ?? empty, (try? parse(b)) ?? empty)
    }

    static func compare(_ a: Expression, _ b: Expression) -> Int {
        if a.isRange || b.isRange {
            let start = comparePaths(collapse(a), collapse(b))
            return start != 0 ? start : comparePaths(collapse(a, toEnd: true), collapse(b, toEnd: true))
        }
        return comparePaths(a.path ?? [], b.path ?? [])
    }

    /// Steps compare by index; offsets only at the last step of the longer path, and only when
    /// both have one (foliate leaves temporal and spatial offsets uncompared).
    private static func comparePaths(_ a: Expression.Path, _ b: Expression.Path) -> Int {
        for i in 0..<max(a.count, b.count) {
            let p = i < a.count ? a[i] : [], q = i < b.count ? b[i] : []
            let maxIndex = max(p.count, q.count) - 1
            guard maxIndex >= 0 else { continue }
            for j in 0...maxIndex {
                guard j < p.count else { return -1 }
                guard j < q.count else { return 1 }
                let x = p[j], y = q[j]
                if x.index > y.index { return 1 }
                if x.index < y.index { return -1 }
                if j == maxIndex, let xOffset = x.offset, let yOffset = y.offset {
                    if xOffset > yOffset { return 1 }
                    if xOffset < yOffset { return -1 }
                }
            }
        }
        return 0
    }

    /// foliate `collapse`: a range's start (or end) as a position CFI. A string that does not
    /// parse is returned unchanged.
    static func collapse(_ string: String, toEnd: Bool = false) -> String {
        guard let expression = try? parse(string) else { return string }
        return Self.string(Expression(path: collapse(expression, toEnd: toEnd)))
    }

    static func collapse(_ expression: Expression, toEnd: Bool = false) -> Expression.Path {
        guard let parent = expression.parent else { return expression.path ?? [] }
        let local = (toEnd ? expression.end : expression.start) ?? []
        guard let last = parent.last, let first = local.first else { return parent + local }
        return Array(parent.dropLast()) + [last + first] + Array(local.dropFirst())
    }

    /// foliate `buildRange`: the leading steps both ends share (equal indices, no offset other
    /// than 0) become the parent's last path; the rest are the start and end.
    static func buildRange(from: Expression, to: Expression) -> Expression {
        let from = collapse(from), to = collapse(to, toEnd: true)
        let localFrom = from.last ?? [], localTo = to.last ?? []
        var parent: [Expression.Step] = [], start: [Expression.Step] = [], end: [Expression.Step] = []
        var pushToParent = true
        for i in 0..<max(localFrom.count, localTo.count) {
            let a = i < localFrom.count ? localFrom[i] : nil
            let b = i < localTo.count ? localTo[i] : nil
            pushToParent = pushToParent && a?.index == b?.index && (a?.offset ?? 0) == 0 && (b?.offset ?? 0) == 0
            if pushToParent, let a { parent.append(a) }
            else {
                if let a { start.append(a) }
                if let b { end.append(b) }
            }
        }
        return Expression(parent: Array(from.dropLast()) + [parent], start: [start], end: [end])
    }

    // MARK: - Content documents

    /// One entry of foliate `indexChildNodes`: child elements and text chunks alternate, with
    /// `missing` for the empty chunk between adjacent elements, and virtual ends. A chunk is one
    /// node because `ContentDocument` has already merged each chunk's text nodes.
    private enum Slot { case before, first, missing, node(ContentNode), last, after }

    /// nil where foliate threw: a node with no element or text children.
    private static func slots(of node: ContentNode) -> [Slot]? {
        let children = node.children
        guard let firstChild = children.first, let lastChild = children.last else { return nil }
        var slots: [Slot] = [.before]
        if firstChild.isElement { slots.append(.first) }
        for (position, child) in children.enumerated() {
            if position > 0, child.isElement, children[position - 1].isElement { slots.append(.missing) }
            slots.append(.node(child))
        }
        if lastChild.isElement { slots.append(.last) }
        slots.append(.after)
        return slots
    }

    /// A child's index in `slots(of: parent)`, without building them.
    private static func cfiIndex(of child: ContentNode, in parent: ContentNode) -> Int {
        let children = parent.children
        var index = children[0].isElement ? 2 : 1
        if child.indexInParent > 0 {
            for position in 1...child.indexInParent {
                index += children[position].isElement && children[position - 1].isElement ? 2 : 1
            }
        }
        return index
    }

    /// `Element.id`: the `id` attribute in no namespace, `xml:id` not included.
    private static func elementID(_ node: ContentNode) -> String? {
        guard node.isElement, let id = node.attribute("id"), !id.isEmpty else { return nil }
        return id
    }

    /// `getElementById`, which matches `id` attributes only (`element(id:)` also has `xml:id`).
    private static func element(id: String, in document: ContentDocument) -> ContentNode? {
        guard let element = document.element(id: id) else { return nil }
        if element.attribute("id") == id { return element }
        return document.nodes.first { $0.isElement && $0.attribute("id") == id }
    }

    /// foliate `nodeToParts`: the steps from the root element down to `node`.
    private static func steps(to node: ContentNode, offset: Int?) -> [Expression.Step] {
        var steps: [Expression.Step] = []
        var current = node, currentOffset = offset
        while let parent = current.parent {
            steps.append(Expression.Step(index: cfiIndex(of: current, in: parent), id: elementID(current),
                                         offset: currentOffset))
            currentOffset = nil
            guard parent.parent != nil else { break }
            current = parent
        }
        return steps.reversed()
    }

    /// A position's steps. foliate threw for the root element itself, which has no step; its
    /// start is its first child's start here.
    private static func steps(for position: DOMPosition) -> [Expression.Step] {
        var node = position.node, offset = position.offset
        if node.parent == nil {
            guard let first = node.children.first else { return [] }
            node = first; offset = 0
        }
        if node.isText { offset = min(max(offset, 0), node.utf16Length) }
        return steps(to: node, offset: offset)
    }

    /// foliate `fromRange` within one content document: a local path (no `epubcfi(` wrapper, no
    /// package step), a position when `start == end`, else a range. Reversed ends are swapped.
    static func localPath(from start: DOMPosition, to end: DOMPosition, in document: ContentDocument) -> String {
        let (start, end) = end < start ? (end, start) : (start, end)
        let startSteps = steps(for: start)
        if start == end { return pathString([startSteps]) }
        return innerString(buildRange(from: Expression(path: [startSteps]), to: Expression(path: [steps(for: end)])))
    }

    /// foliate `toRange` for a local path. nil when it names nothing in `document`.
    static func resolve(localPath: String, in document: ContentDocument) -> (start: DOMPosition, end: DOMPosition)? {
        guard let expression = try? parse(localPath) else { return nil }
        return resolve(expression, in: document)
    }

    /// foliate `toRange`. Only each end's first path is used, as foliate did.
    static func resolve(_ expression: Expression, in document: ContentDocument) -> (start: DOMPosition, end: DOMPosition)? {
        guard let startPath = collapse(expression).first, let endPath = collapse(expression, toEnd: true).first,
              let start = position(startPath, in: document), let end = position(endPath, in: document)
        else { return nil }
        return end < start ? (end, end) : (start, end)
    }

    private enum Target { case node(ContentNode, offset: Int?), before(ContentNode), after(ContentNode) }

    /// foliate `partsToNode`. An ID assertion on the last step wins when the ID exists; otherwise
    /// the indices are walked, and a virtual index ends the walk where it occurs.
    private static func target(of path: [Expression.Step], in document: ContentDocument,
                               ignoringID: Bool = false) -> Target? {
        guard let last = path.last else { return nil }
        if !ignoringID, let id = last.id, !id.isEmpty, let element = element(id: id, in: document) {
            return .node(element, offset: 0)
        }
        var node: ContentNode? = document.root
        for step in path {
            guard let current = node else { continue }
            guard let slots = slots(of: current) else { return nil }
            switch step.index >= 0 && step.index < slots.count ? slots[step.index] : nil {
            case .first?: return .node(current.children[0], offset: nil)
            case .last?: return .node(current.children[current.children.count - 1], offset: nil)
            case .before?: return .before(current)
            case .after?: return .after(current)
            case .node(let child)?: node = child
            case .missing?, nil: node = nil
            }
        }
        return node.map { .node($0, offset: last.offset) }
    }

    private static func position(_ path: [Expression.Step], in document: ContentDocument) -> DOMPosition? {
        switch target(of: path, in: document) {
        case .node(let node, let offset)?:
            guard node.isText else { return DOMPosition(node, 0) }
            return DOMPosition(node, min(max(offset ?? 0, 0), node.utf16Length))
        case .before(let node)?: return DOMPosition(node, 0)
        case .after(let node)?:
            if node.subtreeEnd + 1 < document.nodes.count { return DOMPosition(document.nodes[node.subtreeEnd + 1], 0) }
            let last = document.nodes[document.nodes.count - 1]
            return DOMPosition(last, last.utf16Length)
        case nil: return nil
        }
    }

    /// foliate `toElement` as `EPUB.resolveCFI` used it after its retry, without the ID
    /// assertion: the element the indices name, nil for text or nothing.
    static func element(at path: [Expression.Step], in document: ContentDocument) -> ContentNode? {
        switch target(of: path, in: document, ignoringID: true) {
        case .node(let node, _)?: node.isElement ? node : nil
        case .before(let node)?, .after(let node)?: node
        case nil: nil
        }
    }

    /// foliate `fromElements`: CFIs for sorted sibling elements, with their IDs asserted.
    static func fromElements(_ elements: [ContentNode]) -> [String] {
        guard let parent = elements.first?.parent, let slots = slots(of: parent) else { return [] }
        let parts = steps(to: parent, offset: nil)
        var results: [String] = []
        for (index, slot) in slots.enumerated() where results.count < elements.count {
            if case .node(let node) = slot, node === elements[results.count] {
                results.append(string(Expression(path: [parts + [Expression.Step(index: index, id: elementID(node))]])))
            }
        }
        return results
    }

    // MARK: - JavaScript semantics

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }

    private static func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}"
    }

    /// `String.prototype.trim`'s white space and line terminators (also regular expressions' `\s`).
    static func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }

    private static func jsTrimmed(_ string: String) -> Substring.UnicodeScalarView {
        let scalars = Substring(string).unicodeScalars
        guard let first = scalars.firstIndex(where: { !isJSWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isJSWhitespace($0) }) else { return scalars[scalars.endIndex...] }
        return scalars[first...last]
    }

    /// `parseFloat` of digits and dots: the longest decimal prefix, NaN when it has no digit.
    private static func jsParseFloat(_ value: String.UnicodeScalarView) -> Double {
        var prefix = "", hasDot = false, hasDigit = false
        for scalar in value {
            if isDigit(scalar) { prefix.unicodeScalars.append(scalar); hasDigit = true }
            else if scalar == ".", !hasDot { prefix += "."; hasDot = true }
            else { break }
        }
        guard hasDigit else { return .nan }
        return Double("0" + prefix + (prefix.hasSuffix(".") ? "0" : "")) ?? .nan
    }

    /// `Number.prototype.toString()`. Swift and ECMAScript both print the shortest digits that
    /// round-trip; only where the decimal point and exponent go differs.
    static func jsNumber(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return "0" }
        if value < 0 { return "-" + jsNumber(-value) }
        let parts = "\(value)".split(separator: "e", maxSplits: 1)
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let mantissa = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var digits = Array(String(mantissa[0]) + (mantissa.count > 1 ? String(mantissa[1]) : ""))
        var point = mantissa[0].count + exponent
        while digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.last == "0" { digits.removeLast() }
        let count = digits.count
        if count <= point, point <= 21 { return String(digits) + String(repeating: "0", count: point - count) }
        if point > 0, point <= 21 { return String(digits[..<point]) + "." + String(digits[point...]) }
        if point > -6, point <= 0 { return "0." + String(repeating: "0", count: -point) + String(digits) }
        let leading = count == 1 ? String(digits) : String(digits[0]) + "." + String(digits[1...])
        return leading + "e" + (point - 1 < 0 ? "-" : "+") + String(abs(point - 1))
    }
}
