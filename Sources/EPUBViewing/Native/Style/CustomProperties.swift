import Foundation
import Synchronization

// Custom properties and `var()` (CSS Custom Properties for Cascading Variables 1). A custom
// property (`--name`) cascades and inherits like any inherited property; its computed value is
// its tokens with every `var()` substituted. A declaration of any other property whose value
// holds a `var()` is kept unparsed (a pending substitution) until its element's style is
// computed: then its `var()`s are substituted and the result is parsed as the property's value,
// and where that fails the declaration is invalid at computed-value time and acts as `unset`
// (§3.1). This file holds the values and the grammar; the resolver cascades and substitutes
// (`StyleSubstitution.swift`).

/// A sequence of component values with what substitution needs to know of it.
struct CSSTokenRun: Equatable, Sendable {
    let components: [CSSComponent]
    /// Component values, counting those inside functions and blocks: what the bound on a
    /// substitution counts (`CSSSubstitution.maximumTokens`).
    let count: Int
    /// How deep functions and blocks nest in it: 0 for tokens alone, 1 for `f(x)`.
    let depth: Int
    /// Whether a `var()` is in it.
    let substitutes: Bool

    init(_ components: [CSSComponent]) {
        var count = 0, depth = 0, substitutes = false
        func walk(_ components: [CSSComponent], level: Int) {
            for component in components {
                count += 1
                switch component {
                case .function(let name, let arguments):
                    if name == "var" { substitutes = true }
                    depth = max(depth, level + 1)
                    walk(arguments, level: level + 1)
                case .block(_, let contents):
                    depth = max(depth, level + 1)
                    walk(contents, level: level + 1)
                case .token:
                    break
                }
            }
        }
        walk(components, level: 0)
        self.components = components; self.count = count; self.depth = depth; self.substitutes = substitutes
    }

    init(substituted components: [CSSComponent], count: Int, depth: Int) {
        self.components = components; self.count = count; self.depth = depth; substitutes = false
    }
}

/// A custom property's declaration. Its name is case-sensitive (§2).
struct CSSCustomDeclaration: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        /// `inherit`, `initial`, `unset` or `revert`, which the cascade resolves as for any
        /// property and which are never substituted.
        case keyword(CSSValue)
        case tokens(CSSTokenRun)
    }

    /// With its two dashes, as written.
    let name: String
    let value: Value
    let important: Bool
}

/// A style rule's or a `style` attribute's declarations: those of the properties the reader
/// computes, and those of custom properties.
struct CSSDeclarationBlock: Sendable {
    var declarations: [CSSDeclaration] = []
    var custom: [CSSCustomDeclaration] = []
    var isEmpty: Bool { declarations.isEmpty && custom.isEmpty }
}

/// The value of a declaration whose value holds a `var()`: for each longhand it sets, until its
/// element's style is computed (§3, "pending-substitution value"). A shorthand's longhands share
/// one, which is substituted and parsed once.
final class CSSPendingSubstitution: Equatable, Sendable {
    /// The property as written (lowercased), so that a shorthand's value is parsed as a whole.
    let name: String
    let value: CSSTokenRun
    /// Whether it is a style rule's, which lives as long as its resolver, so that what it
    /// substitutes to against one set of custom properties may be kept
    /// (`CSSCustomPropertyMap.memo`). A `style` attribute's is the element's alone.
    let isRuleValue: Bool

    init(name: String, value: [CSSComponent], isRuleValue: Bool) {
        self.name = name; self.value = CSSTokenRun(value); self.isRuleValue = isRuleValue
    }

    static func == (lhs: CSSPendingSubstitution, rhs: CSSPendingSubstitution) -> Bool {
        lhs === rhs || (lhs.name == rhs.name && lhs.value == rhs.value)
    }
}

/// An element's computed custom properties for one appearance: each one's tokens with every
/// `var()` substituted. A name that is not here has the guaranteed-invalid value (§2.2): it was
/// never declared, was declared `initial`, or was invalid at computed-value time.
///
/// Immutable, apart from what it remembers of the declarations substituted against it, which is
/// locked: an element that declares no custom property shares its parent's.
final class CSSCustomPropertyMap: Sendable {
    let values: [String: CSSTokenRun]

    struct MemoKey: Hashable {
        let pending: ObjectIdentifier
        let appearance: Bool
    }
    /// A style rule's pending substitutions already parsed against these values, by the
    /// substitution's identity, which the entry keeps alive. nil: invalid at computed-value time.
    private let memo = Mutex<[MemoKey: (pending: CSSPendingSubstitution, declarations: [CSSDeclaration]?)]>([:])

    init(_ values: [String: CSSTokenRun]) { self.values = values }

    func memoized(_ pending: CSSPendingSubstitution, appearance: Bool) -> [CSSDeclaration]?? {
        memo.withLock { memo in
            guard let entry = memo[MemoKey(pending: ObjectIdentifier(pending), appearance: appearance)],
                  entry.pending === pending else { return nil }
            return .some(entry.declarations)
        }
    }

    func memoize(_ pending: CSSPendingSubstitution, appearance: Bool, _ declarations: [CSSDeclaration]?) {
        guard pending.isRuleValue else { return }
        memo.withLock { $0[MemoKey(pending: ObjectIdentifier(pending), appearance: appearance)] = (pending, declarations) }
    }
}

/// An element's computed custom properties: those substituted into what paints, which follow
/// the reader's appearance, and those substituted into everything else, which are the light
/// appearance's (`CSSMediaMask.governs`, #130). The two are one map unless a custom property is
/// declared in a rule for one appearance and the reader is dark.
final class CSSCustomProperties: Equatable, Sendable {
    let light: CSSCustomPropertyMap
    let appearance: CSSCustomPropertyMap

    init(light: CSSCustomPropertyMap, appearance: CSSCustomPropertyMap) {
        self.light = light; self.appearance = appearance
    }

    func map(appearance: Bool) -> CSSCustomPropertyMap { appearance ? self.appearance : light }

    static func == (lhs: CSSCustomProperties, rhs: CSSCustomProperties) -> Bool {
        lhs === rhs || ((lhs.light === rhs.light || lhs.light.values == rhs.light.values)
            && (lhs.appearance === rhs.appearance || lhs.appearance.values == rhs.appearance.values))
    }
}

// MARK: - Parsing

/// The grammar of `var()` and of the values that hold it, as CSS Variables 1 and CSS Values 5
/// define them, and the substitution itself.
enum CSSSubstitution {
    /// Component values that one substitution may produce, counting those inside its functions
    /// and blocks: WebKit's bound (`maxSubstitutionTokens`, 65,536), applied to a value as a
    /// whole, as Blink and Gecko apply theirs. A longer result is invalid at computed-value time
    /// (CSS Values 5 §long-substitution), which stops exponential expansion.
    static let maximumTokens = 65_536
    /// A substituted value nests functions and blocks no deeper than a written one may
    /// (`CSSParser.maximumNesting`), so that nothing walks it deeper than its parse did.
    static let maximumNesting = CSSParser.maximumNesting

    /// A `<custom-property-name>`: a `<dashed-ident>` other than `--`, which is reserved.
    static func isCustomPropertyName(_ name: String) -> Bool {
        name.hasPrefix("--") && name.unicodeScalars.count > 2
    }

    enum Syntax: Equatable { case plain, substitutes, invalid }

    /// Whether a declaration's value holds a `var()`, and if so whether it is valid at parse time
    /// (§3): every `var()` has a name argument, and the value is a `<declaration-value>`.
    static func syntax(of value: [CSSComponent]) -> Syntax {
        guard containsVar(value) else { return .plain }
        return isDeclarationValue(value, topLevel: true) ? .substitutes : .invalid
    }

    private static func containsVar(_ components: [CSSComponent]) -> Bool {
        components.contains { component in
            switch component {
            case .function(let name, let arguments): name == "var" || containsVar(arguments)
            case .block(_, let contents): containsVar(contents)
            case .token: false
            }
        }
    }

    /// CSS Syntax's `<declaration-value>`, with each `var()` in it valid: no bad string or URL,
    /// no closing bracket but its block's own, and no `!` at the top level (an `!important` is
    /// already taken off). `var()`'s argument grammar is CSS Values 5's for an arbitrary
    /// substitution function, which Variables 1 now uses: `var( <declaration-value> ,
    /// <declaration-value>? )`, the name argument parsed only once substituted (WPT
    /// css/css-variables/var-parsing.html, variable-reference.html).
    static func isDeclarationValue(_ components: [CSSComponent], topLevel: Bool) -> Bool {
        for component in components {
            switch component {
            case .token(.badString), .token(.badURL), .token(.closeParen), .token(.closeSquare), .token(.closeCurly):
                return false
            case .token(.delim("!")) where topLevel:
                return false
            case .token:
                continue
            case .function("var", let arguments):
                let (name, fallback) = split(arguments)
                let significant = name.significant
                guard !significant.isEmpty else { return false }
                // The name argument may be wrapped in braces, and then the braces alone
                // (CSS Values 5 §component-function-commas).
                if significant.contains(where: { $0.curlyBlock != nil }) {
                    guard significant.count == 1, let contents = significant[0].curlyBlock,
                          !contents.significant.isEmpty else { return false }
                }
                guard isDeclarationValue(name, topLevel: false), isDeclarationValue(fallback ?? [], topLevel: false) else { return false }
            case .function(_, let contents), .block(_, let contents):
                guard isDeclarationValue(contents, topLevel: false) else { return false }
            }
        }
        return true
    }

    /// A `var()`'s name argument, unwrapped from braces, and its fallback: what follows the
    /// first comma without the white space around it, which may be empty, or nil with no comma.
    static func split(_ arguments: [CSSComponent]) -> (name: [CSSComponent], fallback: [CSSComponent]?) {
        guard let comma = arguments.firstIndex(of: .token(.comma)) else { return (unwrapped(arguments), nil) }
        return (unwrapped(Array(arguments[..<comma])), Array(arguments[(comma + 1)...]).trimmingWhitespace)
    }

    private static func unwrapped(_ name: [CSSComponent]) -> [CSSComponent] {
        let significant = name.significant
        if significant.count == 1, let contents = significant[0].curlyBlock { return contents }
        return name
    }

    /// The custom property a substituted name argument names: one `<custom-property-name>`.
    static func customPropertyName(_ components: [CSSComponent]) -> String? {
        let significant = components.significant
        guard significant.count == 1, case .token(.ident(let name)) = significant[0], isCustomPropertyName(name) else { return nil }
        return name
    }

    /// A CSS-wide keyword that a substituted value consists of, which then acts as that keyword
    /// (§3: "variables can resolve to a CSS-wide keyword").
    static func wideKeyword(_ components: [CSSComponent]) -> CSSValue? {
        let significant = components.significant
        guard significant.count == 1, let keyword = significant[0].ident else { return nil }
        return CSSPropertyParser.wideKeyword(keyword)
    }

    // MARK: Substitution

    /// What a `var()` finds: a value; the guaranteed-invalid value, for which its fallback is
    /// substituted; a property not yet resolved; or that the property being substituted is in a
    /// dependency cycle, which makes it invalid whatever the reference is, and substitutes no
    /// fallback (Blink's `StyleCascade::ResolveVarInto`).
    enum Lookup { case value(CSSTokenRun), invalid, unresolved, cyclic }
    enum Outcome: Equatable { case substituted, invalid, needs(String) }

    /// One substitution: what it has produced, and the work it has done for the budget.
    struct Substituter {
        private(set) var tokens = 0
        private(set) var depth = 0
        /// Component values read, written and spliced.
        var work: Int { read + tokens }
        private var read = 0

        /// Appends `components` to `output` with each `var()` replaced (§3, "replace a var()
        /// function"): by the value of the custom property its name argument names once
        /// substituted, or else by its substituted fallback. `level` is how deep in functions and
        /// blocks `output` is. `.needs` names a custom property `lookup` has yet to resolve.
        ///
        /// A failure makes the whole value invalid, but the walk goes on to its end, as Blink's
        /// does, so that every reference outside an unused fallback is followed: a reference after
        /// a failed one still makes a cycle (WPT
        /// css/css-variables/variable-substitution-variable-declaration.html). `lookup` is given
        /// nil for a name argument that names no custom property.
        mutating func substitute(_ components: [CSSComponent], level: Int, into output: inout [CSSComponent],
                                 lookup: (String?) -> Lookup) -> Outcome {
            var failed = false
            for component in components {
                read += 1
                switch component {
                case .function("var", let arguments):
                    let (nameArgument, fallback) = CSSSubstitution.split(arguments)
                    // The name argument is substituted first (`var(var(--name))`); what that
                    // produces names a property and is not part of the value.
                    let produced = (tokens, depth)
                    var name: [CSSComponent] = []
                    let named = substitute(nameArgument, level: level, into: &name, lookup: lookup)
                    (tokens, depth) = produced
                    if case .needs = named { return named }
                    let property = named == .substituted ? CSSSubstitution.customPropertyName(name) : nil
                    var value: CSSTokenRun?
                    switch lookup(property) {
                    case .value(let run): value = run
                    case .invalid: value = nil
                    case .unresolved: return .needs(property ?? "")
                    case .cyclic:
                        failed = true
                        continue
                    }
                    if let value {
                        guard !failed, level + value.depth <= CSSSubstitution.maximumNesting,
                              tokens + value.count <= CSSSubstitution.maximumTokens else { failed = true; continue }
                        tokens += value.count
                        depth = max(depth, level + value.depth)
                        output.append(contentsOf: value.components)
                    } else if let fallback {
                        let outcome = substitute(fallback, level: level, into: &output, lookup: lookup)
                        if case .needs = outcome { return outcome }
                        if outcome == .invalid { failed = true }
                    } else {
                        failed = true
                    }
                case .function(let name, let arguments):
                    var inner: [CSSComponent] = []
                    let outcome = nested(arguments, level: level, into: &inner, lookup: lookup)
                    if case .needs = outcome { return outcome }
                    if outcome == .invalid { failed = true } else if !failed { output.append(.function(name, inner)) }
                case .block(let open, let contents):
                    var inner: [CSSComponent] = []
                    let outcome = nested(contents, level: level, into: &inner, lookup: lookup)
                    if case .needs = outcome { return outcome }
                    if outcome == .invalid { failed = true } else if !failed { output.append(.block(open, inner)) }
                case .token:
                    guard !failed, tokens < CSSSubstitution.maximumTokens else { failed = true; continue }
                    tokens += 1
                    output.append(component)
                }
            }
            return failed ? .invalid : .substituted
        }

        /// A function's or a block's contents, one level deeper than the function or block.
        private mutating func nested(_ contents: [CSSComponent], level: Int, into inner: inout [CSSComponent],
                                     lookup: (String?) -> Lookup) -> Outcome {
            let fits = level + 1 <= CSSSubstitution.maximumNesting && tokens < CSSSubstitution.maximumTokens
            if fits {
                tokens += 1
                depth = max(depth, level + 1)
            }
            let outcome = substitute(contents, level: level + 1, into: &inner, lookup: lookup)
            if case .needs = outcome { return outcome }
            return fits ? outcome : .invalid
        }
    }
}

extension CSSPropertyParser {
    /// A CSS-wide keyword, which every property takes (CSS Cascade 4 §7.3).
    static func wideKeyword(_ keyword: String) -> CSSValue? {
        switch keyword {
        case "inherit": .inherit
        case "initial": .initial
        case "unset": .unset
        case "revert", "revert-layer": .revert
        default: nil
        }
    }

    /// A custom property's declaration (§2): any `<declaration-value>`, empty included, whose
    /// `var()`s are valid, or a CSS-wide keyword. nil when invalid, so that it is ignored.
    static func parseCustom(name: String, value: [CSSComponent], important: Bool) -> CSSCustomDeclaration? {
        guard CSSSubstitution.isCustomPropertyName(name) else { return nil }
        let significant = value.significant
        if significant.count == 1, let keyword = significant[0].ident, let global = wideKeyword(keyword) {
            return CSSCustomDeclaration(name: name, value: .keyword(global), important: important)
        }
        guard CSSSubstitution.isDeclarationValue(value, topLevel: true) else { return nil }
        return CSSCustomDeclaration(name: name, value: .tokens(CSSTokenRun(value)), important: important)
    }

    /// A declaration list's declarations, custom properties apart. `isRuleValue` is false for a
    /// `style` attribute's (`CSSPendingSubstitution.isRuleValue`).
    static func block(_ declarations: [CSSRawDeclaration], isRuleValue: Bool) -> CSSDeclarationBlock {
        var block = CSSDeclarationBlock()
        for declaration in declarations {
            if declaration.name.hasPrefix("--") {
                if let custom = parseCustom(name: declaration.name, value: declaration.value, important: declaration.important) {
                    block.custom.append(custom)
                }
            } else {
                block.declarations += parse(name: declaration.name, value: declaration.value, important: declaration.important,
                                            isRuleValue: isRuleValue) ?? []
            }
        }
        return block
    }
}
