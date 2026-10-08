import Foundation

/// The namespaces a stylesheet declares with `@namespace`.
struct CSSNamespaces: Sendable {
    var prefixes: [String: String] = [:]
    /// Applies to type selectors and to compounds without one.
    var defaultNamespace: String?
}

enum CSSNamespaceConstraint: Equatable, Sendable {
    case any
    /// No namespace (`|name`).
    case none
    case uri(String)
}

enum CSSCombinator: Equatable, Sendable { case descendant, child, nextSibling, subsequentSibling }

struct CSSAttributeSelector: Equatable, Sendable {
    enum Operation: Equatable, Sendable { case exists, equals, includes, dashMatch, prefix, suffix, substring }
    let name: String
    let lowercasedName: String
    /// nil: an attribute in no namespace, the default for unprefixed attribute selectors.
    let namespace: CSSNamespaceConstraint?
    /// `prefix:name`, lowercased, which documents recovered as HTML keep as a plain attribute name.
    let prefixedName: String?
    let operation: Operation
    let value: String
    let caseInsensitive: Bool
}

indirect enum CSSPseudoClass: Equatable, Sendable {
    case firstChild, lastChild, onlyChild, firstOfType, lastOfType, onlyOfType
    case nthChild(a: Int, b: Int, of: [CSSComplexSelector]?)
    case nthLastChild(a: Int, b: Int, of: [CSSComplexSelector]?)
    case nthOfType(a: Int, b: Int), nthLastOfType(a: Int, b: Int)
    case not([CSSComplexSelector])
    /// `:is()` and `:where()` (which differ only in specificity).
    case matchesAny([CSSComplexSelector])
    case root, empty, link
    case lang([String])
    case dir(ComputedStyle.Direction)
    /// Dynamic or unsupported states (`:hover`, `:visited`, `:has()`…).
    case never
    case always
}

enum CSSSimpleSelector: Equatable, Sendable {
    case id(String)
    case className(String)
    case attribute(CSSAttributeSelector)
    case pseudo(CSSPseudoClass)
}

struct CSSCompoundSelector: Equatable, Sendable {
    var namespace: CSSNamespaceConstraint = .any
    /// nil: universal.
    var name: String?
    var lowercasedName: String?
    var simple: [CSSSimpleSelector] = []
}

/// One complex selector, stored subject first for right-to-left matching.
struct CSSComplexSelector: Equatable, Sendable {
    /// Compounds from the subject (rightmost) leftwards.
    var compounds: [CSSCompoundSelector]
    /// `combinators[i]` joins `compounds[i]` to `compounds[i + 1]`, its left neighbour.
    var combinators: [CSSCombinator]
    /// Packed (ids, classes, types), 10 bits each.
    var specificity: UInt32
    /// Selectors with pseudo-elements never match an element.
    var hasPseudoElement = false

    /// The bucket that a rule using this selector is indexed under: the subject's id, a class,
    /// an attribute value or token it requires, its type, or an attribute it requires.
    var bucketKey: CSSBucketKey {
        let subject = compounds[0]
        for case .id(let id) in subject.simple { return .id(id) }
        for case .className(let name) in subject.simple { return .className(name) }
        for case .attribute(let attribute) in subject.simple where !attribute.caseInsensitive && !attribute.value.isEmpty
            && (attribute.operation == .equals || attribute.operation == .includes) {
            return .attributeValue(attribute.lowercasedName, attribute.value)
        }
        if let name = subject.lowercasedName { return .type(name) }
        for case .attribute(let attribute) in subject.simple { return .attribute(attribute.lowercasedName) }
        return .universal
    }

    /// Ids, classes and types that some ancestor of a matching element must have: compounds
    /// reached through a descendant or child combinator.
    var ancestorNames: [AncestorFilter.Name] {
        var names: [AncestorFilter.Name] = []
        for (index, combinator) in combinators.enumerated() where combinator == .descendant || combinator == .child {
            let compound = compounds[index + 1]
            for simple in compound.simple {
                switch simple {
                case .id(let id): names.append(.init(kind: .id, value: id))
                case .className(let name): names.append(.init(kind: .className, value: name))
                default: break
                }
            }
            if let name = compound.lowercasedName { names.append(.init(kind: .type, value: name)) }
        }
        return Array(names.prefix(8))
    }
}

enum CSSBucketKey: Hashable {
    case id(String), className(String), type(String), attribute(String)
    /// An attribute's whole value (`=`) or one of its whitespace-separated tokens (`~=`).
    case attributeValue(String, String)
    case universal
}

/// A Bloom filter of the ids, classes and types of an element's ancestors, as WebKit uses to
/// reject descendant selectors without walking up the tree.
struct AncestorFilter: Sendable {
    struct Name: Hashable {
        enum Kind: UInt8 { case id, className, type }
        let kind: Kind
        let value: String
        /// Two bit positions out of 256.
        var bits: (UInt8, UInt8) {
            var hasher = Hasher()
            hasher.combine(self)
            let hash = UInt64(bitPattern: Int64(hasher.finalize()))
            return (UInt8(truncatingIfNeeded: hash), UInt8(truncatingIfNeeded: hash >> 8))
        }
    }
    private var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)

    private static func word(_ bit: UInt8) -> (Int, UInt64) { (Int(bit >> 6), 1 << UInt64(bit & 63)) }

    private mutating func set(_ bit: UInt8) {
        let (index, mask) = Self.word(bit)
        switch index {
        case 0: words.0 |= mask
        case 1: words.1 |= mask
        case 2: words.2 |= mask
        default: words.3 |= mask
        }
    }

    func contains(_ bit: UInt8) -> Bool {
        let (index, mask) = Self.word(bit)
        let word = switch index {
        case 0: words.0
        case 1: words.1
        case 2: words.2
        default: words.3
        }
        return word & mask != 0
    }

    mutating func insert(_ name: Name) {
        let (a, b) = name.bits
        set(a); set(b)
    }

    /// False only when some name is certainly absent.
    func mayContain(_ bits: [(UInt8, UInt8)]) -> Bool {
        bits.allSatisfy { contains($0.0) && contains($0.1) }
    }
}

struct CSSSpecificity: Comparable {
    var a = 0, b = 0, c = 0
    static func < (l: Self, r: Self) -> Bool { (l.a, l.b, l.c) < (r.a, r.b, r.c) }
    static func + (l: Self, r: Self) -> Self { Self(a: l.a + r.a, b: l.b + r.b, c: l.c + r.c) }
    var packed: UInt32 { UInt32(min(a, 1023)) << 20 | UInt32(min(b, 1023)) << 10 | UInt32(min(c, 1023)) }
}

/// Parses selector lists (Selectors Level 4 subset) from a rule's prelude.
struct CSSSelectorParser {
    static let maximumSelectors = 256
    static let maximumCompounds = 32
    static let maximumSimpleSelectors = 32
    static let maximumNesting = 4

    enum Failure: Error { case invalid, tooComplex }

    let namespaces: CSSNamespaces

    /// A selector list; throws when any selector is invalid, which drops the whole rule.
    func parseList(_ components: [CSSComponent], depth: Int = 0) throws(Failure) -> [CSSComplexSelector] {
        let parts = components.split(separator: .token(.comma), omittingEmptySubsequences: false)
        guard parts.count <= Self.maximumSelectors else { throw .tooComplex }
        var result: [CSSComplexSelector] = []
        for part in parts { result.append(try parseComplex(Array(part), depth: depth).selector) }
        return result
    }

    /// A forgiving list (`:is()`, `:where()`): invalid selectors are dropped individually.
    func parseForgivingList(_ components: [CSSComponent], depth: Int) throws(Failure) -> [CSSComplexSelector] {
        let parts = components.split(separator: .token(.comma), omittingEmptySubsequences: false)
        guard parts.count <= Self.maximumSelectors else { throw .tooComplex }
        var result: [CSSComplexSelector] = []
        for part in parts {
            do { result.append(try parseComplex(Array(part), depth: depth).selector) }
            catch .tooComplex { throw .tooComplex }
            catch {}
        }
        return result
    }

    private func parseComplex(_ components: [CSSComponent], depth: Int) throws(Failure) -> (selector: CSSComplexSelector, specificity: CSSSpecificity) {
        var index = 0
        var compounds: [CSSCompoundSelector] = []
        var combinators: [CSSCombinator] = []
        var specificity = CSSSpecificity()
        var hasPseudoElement = false
        func skipWhitespace() -> Bool {
            var skipped = false
            while index < components.count, components[index].isWhitespace { index += 1; skipped = true }
            return skipped
        }
        _ = skipWhitespace()
        while true {
            guard index < components.count else { throw .invalid }
            let (compound, compoundSpecificity, pseudoElement) = try parseCompound(components, &index, depth: depth)
            compounds.append(compound)
            specificity = specificity + compoundSpecificity
            hasPseudoElement = hasPseudoElement || pseudoElement
            guard compounds.count <= Self.maximumCompounds else { throw .tooComplex }
            let hadWhitespace = skipWhitespace()
            guard index < components.count else { break }
            let next = components[index]
            if next.isDelim(">") { combinators.append(.child); index += 1 }
            else if next.isDelim("+") { combinators.append(.nextSibling); index += 1 }
            else if next.isDelim("~") { combinators.append(.subsequentSibling); index += 1 }
            else if hadWhitespace { combinators.append(.descendant) }
            else { throw .invalid }
            // A pseudo-element must be last.
            if pseudoElement { throw .invalid }
            _ = skipWhitespace()
        }
        return (CSSComplexSelector(compounds: compounds.reversed(), combinators: combinators.reversed(),
                                   specificity: specificity.packed, hasPseudoElement: hasPseudoElement), specificity)
    }

    private func namespaceConstraint(prefix: String?) throws(Failure) -> CSSNamespaceConstraint {
        guard let prefix else { return namespaces.defaultNamespace.map { .uri($0) } ?? .any }
        if prefix == "*" { return .any }
        if prefix.isEmpty { return .none }
        guard let uri = namespaces.prefixes[prefix] else { throw .invalid }
        return .uri(uri)
    }

    /// A namespace prefix and local name (`ns|name`, `*|name`, `|name`, `name`, or `*`).
    private func qualifiedName(_ components: [CSSComponent], _ index: inout Int, allowUniversal: Bool) -> (prefix: String?, name: String)? {
        func name(at position: Int) -> String? {
            guard position < components.count else { return nil }
            if case .token(.ident(let value)) = components[position] { return value }
            if allowUniversal, components[position].isDelim("*") { return "*" }
            return nil
        }
        let isBar: (Int) -> Bool = { $0 < components.count && components[$0].isDelim("|") }
        let isDashMatch = { (position: Int) in position + 1 < components.count && components[position + 1].isDelim("=") }
        if isBar(index), !isDashMatch(index), let local = name(at: index + 1) {
            index += 2
            return ("", local)
        }
        let first: String?
        if let value = name(at: index) { first = value }
        else if index < components.count, components[index].isDelim("*") { first = "*" }
        else { return nil }
        if isBar(index + 1), !isDashMatch(index + 1), let local = name(at: index + 2) {
            index += 3
            return (first, local)
        }
        guard let first, first != "*" || allowUniversal else { return nil }
        index += 1
        return (nil, first)
    }

    private func parseCompound(_ components: [CSSComponent], _ index: inout Int, depth: Int) throws(Failure)
        -> (CSSCompoundSelector, CSSSpecificity, Bool) {
        var compound = CSSCompoundSelector()
        var specificity = CSSSpecificity()
        var pseudoElement = false
        var hasType = false
        if let (prefix, name) = qualifiedName(components, &index, allowUniversal: true) {
            compound.namespace = try namespaceConstraint(prefix: prefix)
            if name != "*" {
                compound.name = name; compound.lowercasedName = name.lowercased()
                specificity.c += 1
            }
            hasType = true
        } else {
            compound.namespace = try namespaceConstraint(prefix: nil)
        }
        var count = 0
        loop: while index < components.count {
            let component = components[index]
            switch component {
            case .token(.hash(let value, let isID)):
                guard isID, !pseudoElement else { throw .invalid }
                compound.simple.append(.id(value)); specificity.a += 1; index += 1
            case .token(.delim(".")):
                guard index + 1 < components.count, case .token(.ident(let name)) = components[index + 1], !pseudoElement else { throw .invalid }
                compound.simple.append(.className(name)); specificity.b += 1; index += 2
            case .block(.openSquare, let contents):
                guard !pseudoElement else { throw .invalid }
                compound.simple.append(.attribute(try parseAttribute(contents))); specificity.b += 1; index += 1
            case .token(.colon):
                index += 1
                guard index < components.count else { throw .invalid }
                if components[index] == .token(.colon) {
                    index += 1
                    guard index < components.count else { throw .invalid }
                    switch components[index] {
                    case .token(.ident), .function: break
                    default: throw .invalid
                    }
                    index += 1
                    pseudoElement = true; specificity.c += 1
                    continue loop
                }
                switch components[index] {
                case .token(.ident(let name)):
                    index += 1
                    let lower = name.lowercased()
                    if ["before", "after", "first-line", "first-letter"].contains(lower) {
                        pseudoElement = true; specificity.c += 1
                        continue loop
                    }
                    guard let pseudo = Self.simplePseudoClass(lower) else { throw .invalid }
                    if !pseudoElement { compound.simple.append(.pseudo(pseudo)) }
                    specificity.b += 1
                case .function(let name, let arguments):
                    index += 1
                    let (pseudo, argumentSpecificity) = try functionalPseudoClass(name, arguments, depth: depth)
                    if !pseudoElement { compound.simple.append(.pseudo(pseudo)) }
                    specificity = specificity + argumentSpecificity
                default: throw .invalid
                }
            default:
                break loop
            }
            count += 1
            guard count <= Self.maximumSimpleSelectors else { throw .tooComplex }
        }
        guard hasType || count > 0 else { throw .invalid }
        return (compound, specificity, pseudoElement)
    }

    private static func simplePseudoClass(_ name: String) -> CSSPseudoClass? {
        switch name {
        case "first-child": .firstChild
        case "last-child": .lastChild
        case "only-child": .onlyChild
        case "first-of-type": .firstOfType
        case "last-of-type": .lastOfType
        case "only-of-type": .onlyOfType
        case "root", "scope": .root
        case "empty": .empty
        case "link", "any-link", "-webkit-any-link": .link
        case "defined", "read-only": .always
        case "visited", "hover", "active", "focus", "focus-within", "focus-visible", "target", "target-within",
             "checked", "disabled", "enabled", "indeterminate", "default", "valid", "invalid", "in-range",
             "out-of-range", "required", "optional", "read-write", "placeholder-shown", "autofill",
             "-webkit-autofill", "playing", "paused", "fullscreen", "modal", "popover-open", "local-link",
             "user-invalid", "user-valid", "blank", "current", "past", "future", "host", "open", "closed",
             "first", "left", "right":
            .never
        default: nil
        }
    }

    private func functionalPseudoClass(_ name: String, _ arguments: [CSSComponent], depth: Int) throws(Failure)
        -> (CSSPseudoClass, CSSSpecificity) {
        let classSpecificity = CSSSpecificity(b: 1)
        func nested() throws(Failure) -> Int {
            guard depth < Self.maximumNesting else { throw .tooComplex }
            return depth + 1
        }
        func maximum(_ selectors: [CSSComplexSelector]) -> CSSSpecificity {
            selectors.map { s in CSSSpecificity(a: Int(s.specificity >> 20), b: Int(s.specificity >> 10 & 1023), c: Int(s.specificity & 1023)) }
                .max() ?? CSSSpecificity()
        }
        switch name {
        case "not":
            let list = try parseList(arguments, depth: try nested())
            return (.not(list), maximum(list))
        case "is", "matches", "-webkit-any", "-moz-any":
            let list = try parseForgivingList(arguments, depth: try nested())
            return (.matchesAny(list), maximum(list))
        case "where":
            return (.matchesAny(try parseForgivingList(arguments, depth: try nested())), CSSSpecificity())
        case "nth-child", "nth-last-child":
            var anb = arguments
            var of: [CSSComplexSelector]?
            if let ofIndex = arguments.firstIndex(where: { $0.ident == "of" }) {
                anb = Array(arguments[..<ofIndex])
                of = try parseList(Array(arguments[(ofIndex + 1)...]), depth: try nested())
            }
            guard let (a, b) = Self.parseAnB(anb.significant) else { throw .invalid }
            let specificity = classSpecificity + (of.map(maximum) ?? CSSSpecificity())
            return (name == "nth-child" ? .nthChild(a: a, b: b, of: of) : .nthLastChild(a: a, b: b, of: of), specificity)
        case "nth-of-type", "nth-last-of-type":
            guard let (a, b) = Self.parseAnB(arguments.significant) else { throw .invalid }
            return (name == "nth-of-type" ? .nthOfType(a: a, b: b) : .nthLastOfType(a: a, b: b), classSpecificity)
        case "lang":
            var ranges: [String] = []
            for part in arguments.commaSeparated {
                guard part.count == 1 else { throw .invalid }
                switch part[0] {
                case .token(.ident(let value)), .token(.string(let value)): ranges.append(value.lowercased())
                default: throw .invalid
                }
            }
            guard !ranges.isEmpty else { throw .invalid }
            return (.lang(ranges), classSpecificity)
        case "dir":
            switch arguments.significant.first?.ident {
            case "rtl": return (.dir(.rtl), classSpecificity)
            case "ltr": return (.dir(.ltr), classSpecificity)
            default: throw .invalid
            }
        case "has", "host", "host-context", "nth-col", "nth-last-col", "state", "current", "heading":
            return (.never, classSpecificity)
        default:
            throw .invalid
        }
    }

    private func parseAttribute(_ contents: [CSSComponent]) throws(Failure) -> CSSAttributeSelector {
        let components = contents.significant
        var index = 0
        guard let (prefix, name) = qualifiedName(components, &index, allowUniversal: false) else { throw .invalid }
        let namespace: CSSNamespaceConstraint?
        switch prefix {
        case nil: namespace = nil
        case "*": namespace = .any
        case "": namespace = CSSNamespaceConstraint.none
        case let prefix?:
            guard let uri = namespaces.prefixes[prefix] else { throw .invalid }
            namespace = .uri(uri)
        }
        let prefixedName = prefix.flatMap { $0.isEmpty || $0 == "*" ? nil : "\($0):\(name)".lowercased() }
        guard index < components.count else {
            return CSSAttributeSelector(name: name, lowercasedName: name.lowercased(), namespace: namespace,
                                        prefixedName: prefixedName, operation: .exists, value: "", caseInsensitive: false)
        }
        let operation: CSSAttributeSelector.Operation
        if components[index].isDelim("=") { operation = .equals; index += 1 }
        else {
            guard index + 1 < components.count, components[index + 1].isDelim("=") else { throw .invalid }
            switch components[index] {
            case .token(.delim("~")): operation = .includes
            case .token(.delim("|")): operation = .dashMatch
            case .token(.delim("^")): operation = .prefix
            case .token(.delim("$")): operation = .suffix
            case .token(.delim("*")): operation = .substring
            default: throw .invalid
            }
            index += 2
        }
        guard index < components.count else { throw .invalid }
        let value: String
        switch components[index] {
        case .token(.ident(let v)), .token(.string(let v)): value = v
        default: throw .invalid
        }
        index += 1
        var caseInsensitive = false
        if index < components.count {
            switch components[index].ident {
            case "i": caseInsensitive = true
            case "s": break
            default: throw .invalid
            }
            index += 1
        }
        guard index == components.count else { throw .invalid }
        return CSSAttributeSelector(name: name, lowercasedName: name.lowercased(), namespace: namespace,
                                    prefixedName: prefixedName, operation: operation,
                                    value: caseInsensitive ? value.lowercased() : value, caseInsensitive: caseInsensitive)
    }

    /// The An+B microsyntax (CSS Syntax §6) over whitespace-free components.
    static func parseAnB(_ components: [CSSComponent]) -> (Int, Int)? {
        func integer(_ value: Double) -> Int? {
            guard value.magnitude < 1e9 else { return nil }
            return Int(value)
        }
        // Parses "n", "n-", "n-3" style remainders after the coefficient.
        func remainder(_ unit: String, a: Int, rest: ArraySlice<CSSComponent>) -> (Int, Int)? {
            let unit = unit.lowercased()
            if unit == "n" {
                guard let first = rest.first else { return (a, 0) }
                if case .token(.number(let value, true, true)) = first, rest.count == 1, let b = integer(value) { return (a, b) }
                if first.isDelim("+") || first.isDelim("-"), rest.count == 2,
                   case .token(.number(let value, true, false)) = rest[rest.startIndex + 1], let b = integer(value) {
                    return (a, first.isDelim("-") ? -b : b)
                }
                return nil
            }
            if unit == "n-" {
                guard rest.count == 1, case .token(.number(let value, true, false)) = rest.first!, let b = integer(value) else { return nil }
                return (a, -b)
            }
            if unit.hasPrefix("n-"), rest.isEmpty, let b = Int(unit.dropFirst(2)), unit.dropFirst(2).allSatisfy(\.isNumber) {
                return (a, -b)
            }
            return nil
        }
        guard let first = components.first else { return nil }
        let rest = components.dropFirst()
        switch first {
        case .token(.ident(let value)):
            let lower = value.lowercased()
            if lower == "odd", rest.isEmpty { return (2, 1) }
            if lower == "even", rest.isEmpty { return (2, 0) }
            if lower.hasPrefix("-") { return remainder(String(lower.dropFirst()), a: -1, rest: rest) }
            return remainder(lower, a: 1, rest: rest)
        case .token(.delim("+")):
            guard let next = rest.first, case .token(.ident(let value)) = next, !value.hasPrefix("-") else { return nil }
            return remainder(value, a: 1, rest: rest.dropFirst())
        case .token(.number(let value, true, _)):
            guard rest.isEmpty, let b = integer(value) else { return nil }
            return (0, b)
        case .token(.dimension(let value, let unit, true, _)):
            guard let a = integer(value) else { return nil }
            return remainder(unit, a: a, rest: rest)
        default:
            return nil
        }
    }
}
