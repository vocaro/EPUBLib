import CoreGraphics
import Foundation
import Synchronization

/// Computes styles for one content document: user-agent defaults, then author sheets in order,
/// then `style` attributes, honouring `!important`, specificity and inheritance.
///
/// Immutable after `init` except for what it remembers of sibling searches, which is locked, so
/// `style(for:parent:)` may be called from any thread.
final class StyleResolver: @unchecked Sendable {
    let typography: NativeTypography
    let document: ContentDocument
    let fonts: FontRegistry?
    /// A `style` attribute was longer than `maximumInlineStyleBytes` and was cut. The builder
    /// folds this into `SectionReport.stylesTruncated`.
    let stylesTruncated: Bool

    static let maximumInlineStyleBytes = 16 * 1024

    private let author: CSSRuleIndex
    private let facts: ElementFacts
    private let siblingSearches = SiblingSearchMemo()
    /// The root element's computed font size, which `rem` refers to.
    private var rootFontSize: CGFloat
    let initialValues: ComputedStyle

    init(document: ContentDocument, stylesheets: [CSSStyleSheet], typography: NativeTypography, fonts: FontRegistry? = nil) {
        self.document = document; self.typography = typography; self.fonts = fonts
        author = CSSRuleIndex(sheets: stylesheets, dark: typography.isDark)
        facts = ElementFacts(document)
        var initial = ComputedStyle()
        initial.fontSize = typography.fontSize
        initial.fontFamilies = ["serif"]
        initialValues = initial
        stylesTruncated = document.nodes.contains {
            $0.isElement && ($0.attribute("style")?.utf8.count ?? 0) > Self.maximumInlineStyleBytes
        }
        rootFontSize = typography.fontSize
        rootFontSize = style(for: document.root, parent: initialStyle).fontSize
    }

    /// What the root element inherits: the reader's own defaults.
    var initialStyle: ComputedStyle {
        var style = ComputedStyle()
        style.fontSize = typography.fontSize
        style.fontFamilies = ["serif"]
        style.lineHeight = .multiple(1.4)
        style.hyphens = .auto
        return style
    }

    /// The computed style of `element`, given its parent's computed style.
    func style(for element: ContentNode, parent: ComputedStyle) -> ComputedStyle {
        guard element.isElement else { return parent }
        let order = element.order
        let matcher = SelectorMatcher(document: document, facts: facts, siblingSearches: siblingSearches)
        var winners = [CSSValue?](repeating: nil, count: CSSProperty.count)

        func apply(_ declarations: [CSSDeclaration], important: Bool) {
            for declaration in declarations where declaration.important == important {
                winners[declaration.property.rawValue] = declaration.value
            }
        }
        let userAgent = UserAgentStyleSheet.index.matching(order, matcher: matcher)
        for entry in userAgent { apply(UserAgentStyleSheet.index.entries[entry].declarations, important: false) }
        let userAgentWinners = winners

        let matched = author.matching(order, matcher: matcher)
        apply(PresentationalHints.declarations(for: element, facts: facts, document: document), important: false)
        for entry in matched { apply(author.entries[entry].declarations, important: false) }
        var inline: [CSSDeclaration] = []
        if let text = element.attribute("style") {
            inline = CSSStyleSheet.declarations(String(decoding: text.utf8.prefix(Self.maximumInlineStyleBytes), as: UTF8.self))
            apply(inline, important: false)
        }
        for entry in matched where author.entries[entry].hasImportant { apply(author.entries[entry].declarations, important: true) }
        apply(inline, important: true)
        for entry in userAgent where UserAgentStyleSheet.index.entries[entry].hasImportant {
            apply(UserAgentStyleSheet.index.entries[entry].declarations, important: true)
        }

        let isRoot = element === document.root
        return compute(winners: winners, userAgent: userAgentWinners, parent: parent,
                       rem: isRoot ? typography.fontSize : rootFontSize, isRoot: isRoot)
    }
}

// MARK: - Rule index

/// Rules bucketed by their subject's id, class or type, so an element tests only rules that can
/// match it.
struct CSSRuleIndex: Sendable {
    struct Entry: Sendable {
        let selector: CSSComplexSelector
        let declarations: [CSSDeclaration]
        /// Specificity, then source order: the cascade's sort key within an origin.
        let key: UInt64
        let hasImportant: Bool
        /// Ancestor names' filter bits, checked before matching.
        let ancestorBits: [(UInt8, UInt8)]
    }
    private(set) var entries: [Entry] = []
    private var byID: [String: [Int32]] = [:]
    private var byClass: [String: [Int32]] = [:]
    private var byType: [String: [Int32]] = [:]
    private var byAttribute: [String: [Int32]] = [:]
    private var byAttributeValue: [AttributeValueKey: [Int32]] = [:]
    /// Names that `byAttribute` or `byAttributeValue` index.
    private var attributeNames = Set<String>()
    private var universal: [Int32] = []

    private struct AttributeValueKey: Hashable { let name: String; let value: Substring }

    init(sheets: [CSSStyleSheet], dark: Bool) {
        var order: UInt64 = 0
        for sheet in sheets {
            for rule in sheet.rules where rule.media.contains(dark: dark) {
                let important = rule.declarations.contains(where: \.important)
                for selector in rule.selectors {
                    let index = Int32(entries.count)
                    entries.append(Entry(selector: selector, declarations: rule.declarations,
                                         key: UInt64(selector.specificity) << 32 | order, hasImportant: important,
                                         ancestorBits: selector.ancestorNames.map(\.bits)))
                    switch selector.bucketKey {
                    case .id(let id): byID[id, default: []].append(index)
                    case .className(let name): byClass[name, default: []].append(index)
                    case .type(let name): byType[name, default: []].append(index)
                    case .attribute(let name):
                        byAttribute[name, default: []].append(index); attributeNames.insert(name)
                    case .attributeValue(let name, let value):
                        byAttributeValue[AttributeValueKey(name: name, value: Substring(value)), default: []].append(index)
                        attributeNames.insert(name)
                    case .universal: universal.append(index)
                    }
                }
                order += 1
            }
        }
    }

    /// Entries whose selector matches the element, in ascending cascade order.
    func matching(_ element: Int, matcher: SelectorMatcher) -> [Int] {
        var result: [Int] = []
        let filter = matcher.facts.ancestorFilters[element]
        func test(_ bucket: [Int32]?) {
            guard let bucket else { return }
            for index in bucket {
                let entry = entries[Int(index)]
                guard filter.mayContain(entry.ancestorBits), matcher.matches(entry.selector, element) else { continue }
                result.append(Int(index))
            }
        }
        let node = matcher.document.nodes[element]
        if let id = node.id { test(byID[id]) }
        for name in matcher.facts.classes[element] { test(byClass[name]) }
        test(byType[matcher.facts.bucketNames[element]])
        if !attributeNames.isEmpty {
            for attribute in node.attributes {
                let name = Self.bucketName(attribute.name)
                guard attributeNames.contains(name) else { continue }
                test(byAttribute[name])
                guard !byAttributeValue.isEmpty else { continue }
                test(byAttributeValue[AttributeValueKey(name: name, value: Substring(attribute.value))])
                SelectorMatcher.forEachToken(attribute.value) { token in
                    if token.count != attribute.value.count { test(byAttributeValue[AttributeValueKey(name: name, value: token)]) }
                }
            }
        }
        test(universal)
        guard result.count > 1 else { return result }
        result.sort { entries[$0].key < entries[$1].key }
        // An element can reach one entry through two attributes or repeated tokens.
        var previous = -1
        return result.filter { defer { previous = $0 }; return $0 != previous }
    }
}

extension CSSRuleIndex {
    /// An attribute's name as rules are bucketed: lowercased, without a prefix that a document
    /// recovered as HTML kept (`epub:type`).
    static func bucketName(_ name: String) -> String {
        guard name.utf8.contains(where: { ($0 >= 0x41 && $0 <= 0x5A) || $0 == 0x3A }) else { return name }
        let lower = name.lowercased()
        guard let colon = lower.lastIndex(of: ":") else { return lower }
        return String(lower[lower.index(after: colon)...])
    }
}

extension UserAgentStyleSheet {
    static let index = CSSRuleIndex(sheets: [sheet], dark: false)
}

// MARK: - Element facts

/// Per-node facts that selector matching needs repeatedly, computed once per document and
/// indexed by `ContentNode.order`.
struct ElementFacts: Sendable {
    /// Parent element's order, or -1.
    var parents: [Int32]
    var previousElements: [Int32]
    /// 1-based position among element siblings, and their count.
    var positions: [Int32]
    var siblingCounts: [Int32]
    /// The same among siblings of the same expanded name.
    var typePositions: [Int32]
    var typeCounts: [Int32]
    /// Distinct class names.
    var classes: [[String]]
    /// Lowercased local names.
    var bucketNames: [String]
    /// The ids, classes and types of each element's ancestors.
    var ancestorFilters: [AncestorFilter]

    init(_ document: ContentDocument) {
        let count = document.nodes.count
        parents = Array(repeating: -1, count: count)
        previousElements = Array(repeating: -1, count: count)
        positions = Array(repeating: 1, count: count)
        siblingCounts = Array(repeating: 1, count: count)
        typePositions = Array(repeating: 1, count: count)
        typeCounts = Array(repeating: 1, count: count)
        classes = Array(repeating: [], count: count)
        bucketNames = Array(repeating: "", count: count)
        ancestorFilters = Array(repeating: AncestorFilter(), count: count)
        struct TypeKey: Hashable { let namespace: String, name: String }
        for node in document.nodes where node.isElement {
            bucketNames[node.order] = node.name.lowercased()
            var seen = Set<String>()
            classes[node.order] = node.classNames.filter { seen.insert($0).inserted }
            // Preorder: the parent's filter is complete before its children are reached.
            var childFilter = ancestorFilters[node.order]
            childFilter.insert(.init(kind: .type, value: bucketNames[node.order]))
            if let id = node.id { childFilter.insert(.init(kind: .id, value: id)) }
            for name in classes[node.order] { childFilter.insert(.init(kind: .className, value: name)) }
            var position: Int32 = 0
            var previous: Int32 = -1
            var typeTotals: [TypeKey: Int32] = [:]
            for child in node.children where child.isElement {
                position += 1
                ancestorFilters[child.order] = childFilter
                parents[child.order] = Int32(node.order)
                previousElements[child.order] = previous
                previous = Int32(child.order)
                positions[child.order] = position
                let key = TypeKey(namespace: child.namespace, name: child.name)
                let typePosition = (typeTotals[key] ?? 0) + 1
                typeTotals[key] = typePosition
                typePositions[child.order] = typePosition
            }
            for child in node.children where child.isElement {
                siblingCounts[child.order] = position
                typeCounts[child.order] = typeTotals[TypeKey(namespace: child.namespace, name: child.name)] ?? 1
            }
        }
    }
}

// MARK: - Selector matching

/// What matching in one document has learned about `~` searches, so that an element in a long
/// run of siblings does not test every sibling before it again. For `a ~ b` the matcher walks
/// back from an element over its earlier siblings until one's result is not a local failure,
/// and that result is the answer; where every one fails locally, the search fails for all
/// siblings. For one `~` combinator and one parent this holds what such walks found of the
/// parent's children: one that matched, one that failed completely, and how many of the
/// leading children do neither. Each is true of the document whichever elements asked and in
/// whatever order.
///
/// A search through this returns what the walk alone returns, the kind of failure included, by
/// tests the walk would make: it stops only where an entry says how the walk ends. While a
/// section's searches fit `capacity`, each walks the siblings of a long run once, whichever
/// elements ask and in whatever order, apart from the sibling just before each element and
/// walks too short to keep. With more searches than that, entries are forgotten and the cost
/// is the walk's again, the square of the run (#341).
final class SiblingSearchMemo: Sendable {
    struct Key: Hashable {
        /// Of the selector's `identity`, which lives as long as the rule index that is matched.
        let selector: ObjectIdentifier
        /// Index of the compound to the combinator's left.
        let compound: Int32
        let parent: Int32
    }

    /// What is known of one search, as positions among the parent's element children, from 1.
    ///
    /// A child's result is what the matcher returns for it from the key's compound leftwards:
    /// a match, or a failure that is local, for all siblings or complete. Along one parent's
    /// children those results keep an order, whatever the selector: after a match come only
    /// matches and local failures, and after a complete failure only complete and local
    /// failures. Both hold of the leftmost compound, which only matches or fails locally, and
    /// each combinator hands them on to the compound on its right, whose result is a local
    /// failure or the one behind the combinator: behind a descendant or child combinator one
    /// result for all the children; behind `+` the previous child's; behind `~` that of the
    /// nearest earlier child that is not a local failure; and behind either of those two a
    /// failure for all siblings where there is no such child, which is before every child
    /// that has one. So a child that fails for all siblings has neither a match nor a
    /// complete failure before it.
    ///
    /// The three fields are kept true of the document, and from them a search's answer is the
    /// walk's own. Each is a fact about the children and not about who asked, so what two walks
    /// found may be combined, and all of it may be forgotten.
    struct Known: Equatable {
        /// A child whose result is a match, the earliest found, or 0. The walk from any child
        /// after it ends at a match: at this one, or at a later child, whose result is then a
        /// match as well.
        var match: Int32 = 0
        /// A child whose result is a complete failure, the earliest found, or 0. The walk from
        /// any child after it ends at a complete failure in the same way, and from a child
        /// before it this says nothing.
        var complete: Int32 = 0
        /// The results of the children at `1 ... clear` are local failures and failures for all
        /// siblings, none a match or a complete failure: a walk back from the last of them met
        /// only local failures until it came to the first child, to children already clear, or
        /// to one that fails for all siblings, which has neither before it. The walk from one
        /// of them, or from the child after them, fails for all siblings.
        var clear: Int32 = 0
    }

    /// An element with no more earlier siblings than this walks them: that costs less than a
    /// lookup, and a parent of few children then needs no entry. Nor is one made for a walk
    /// that ends within this many siblings, short of the clear children.
    let directWalk: Int32
    /// Room is made for an entry beyond this many by forgetting them all, which bounds the
    /// memory (about 4 MB). A search that was forgotten is walked from the asking element as it
    /// would be with no memo, so a section with more searches than this under way at once is
    /// matched by the walk's own tests, the square of a long run once more, with a lookup for
    /// each search besides (#341).
    let capacity: Int
    private let entries = Mutex<[Key: Known]>([:])

    init(directWalk: Int32 = 8, capacity: Int = 1 << 16) {
        self.directWalk = directWalk; self.capacity = capacity
    }

    func known(_ key: Key) -> Known { entries.withLock { $0[key] } ?? Known() }

    /// Adds what a walk found to what is held, which another thread may have added to since the
    /// walk read it: the earlier match, the earlier complete failure and the longer run of
    /// clear children.
    func record(_ found: Known, for key: Key) {
        entries.withLock { entries in
            guard var held = entries[key] else {
                if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
                entries[key] = found
                return
            }
            if found.match > 0, held.match == 0 || found.match < held.match { held.match = found.match }
            if found.complete > 0, held.complete == 0 || found.complete < held.complete { held.complete = found.complete }
            if found.clear > held.clear { held.clear = found.clear }
            entries[key] = held
        }
    }
}

/// The compounds a matcher has tested: what matching cost, whatever the machine.
final class SelectorTally {
    var compounds = 0
}

/// Right-to-left selector matching with WebKit's pruning of descendant and sibling searches.
struct SelectorMatcher {
    let document: ContentDocument
    let facts: ElementFacts
    /// nil: every `~` walks the siblings before the element.
    var siblingSearches: SiblingSearchMemo?
    /// Set by tests that hold matching to a cost.
    var tally: SelectorTally?

    /// A match, or how much a failure rules out: this element alone, it and every sibling
    /// before it, or those and every ancestor as well. The second ends a search over earlier
    /// siblings, and the third a search up the ancestors too.
    enum Result { case matches, failsLocally, failsAllSiblings, failsCompletely }

    func matches(_ selector: CSSComplexSelector, _ element: Int) -> Bool {
        match(selector, element, from: 0) == .matches
    }

    /// What `element` is to `selector` from the compound at `index` leftwards. Not private, so
    /// that tests can hold a matcher with a memo to the kind of failure one without returns.
    func match(_ selector: CSSComplexSelector, _ element: Int, from index: Int) -> Result {
        guard matches(selector.compounds[index], element) else { return .failsLocally }
        guard index + 1 < selector.compounds.count else { return .matches }
        switch selector.combinators[index] {
        case .descendant:
            var ancestor = Int(facts.parents[element])
            while ancestor >= 0 {
                let result = match(selector, ancestor, from: index + 1)
                if result == .matches || result == .failsCompletely { return result }
                ancestor = Int(facts.parents[ancestor])
            }
            return .failsCompletely
        case .child:
            let parent = Int(facts.parents[element])
            guard parent >= 0 else { return .failsCompletely }
            return match(selector, parent, from: index + 1)
        case .nextSibling:
            let sibling = Int(facts.previousElements[element])
            guard sibling >= 0 else { return .failsAllSiblings }
            return match(selector, sibling, from: index + 1)
        case .subsequentSibling:
            var sibling = Int(facts.previousElements[element])
            let position = facts.positions[element]
            if let memo = siblingSearches, let identity = selector.identity, position - 1 > memo.directWalk {
                // The previous sibling settles the search wherever the walk is quickest, and then
                // nothing is looked up.
                let result = match(selector, sibling, from: index + 1)
                if result != .failsLocally { return result }
                let key = SiblingSearchMemo.Key(selector: ObjectIdentifier(identity), compound: Int32(index + 1),
                                                parent: facts.parents[element])
                return walk(on: sibling, at: position - 1, selector, key, memo)
            }
            while sibling >= 0 {
                let result = match(selector, sibling, from: index + 1)
                if result != .failsLocally { return result }
                sibling = Int(facts.previousElements[sibling])
            }
            return .failsAllSiblings
        }
    }

    /// The rest of a `~` search through `memo`, once `sibling`, the child of `key.parent` at
    /// `position`, has failed locally: what the walk on over the siblings before it returns,
    /// the kind of failure included. It makes that walk's tests in that walk's order, back
    /// towards the first sibling whose result is not a local failure, and leaves out only
    /// those whose outcome `memo` holds: after a child known to match or to fail completely
    /// the answer is that child's, and at the clear children it is a failure for all siblings.
    private func walk(on sibling: Int, at position: Int32, _ selector: CSSComplexSelector,
                      _ key: SiblingSearchMemo.Key, _ memo: SiblingSearchMemo) -> Result {
        var known = memo.known(key)
        if known.match > 0, known.match < position { return .matches }
        if known.complete > 0, known.complete < position { return .failsCompletely }
        let clear = known.clear
        guard position > clear else { return .failsAllSiblings }
        var sibling = Int(facts.previousElements[sibling])
        var at = position - 1
        var result = Result.failsLocally
        while at > clear {
            result = match(selector, sibling, from: Int(key.compound))
            if result != .failsLocally { break }
            sibling = Int(facts.previousElements[sibling])
            at -= 1
        }
        // A walk as short as a direct one, ending above the clear children, costs less repeated
        // than kept.
        let kept = at == clear || position - at >= memo.directWalk
        switch result {
        case .matches: known.match = at
        case .failsCompletely: known.complete = at
        case .failsLocally, .failsAllSiblings:
            // It came to the clear children, or stopped at a sibling that fails for all
            // siblings, which has only local failures and failures for all siblings before it.
            // Every sibling it passed failed locally, so all are clear up to where it began.
            known.clear = position
            result = .failsAllSiblings
        }
        if kept { memo.record(known, for: key) }
        return result
    }

    private func matches(_ compound: CSSCompoundSelector, _ element: Int) -> Bool {
        tally?.compounds += 1
        let node = document.nodes[element]
        switch compound.namespace {
        case .any: break
        case .none: guard node.namespace.isEmpty else { return false }
        case .uri(let uri):
            guard node.namespace == uri || (node.namespace.isEmpty && uri == ContentNamespace.xhtml) else { return false }
        }
        if let name = compound.name {
            guard node.isHTML ? node.name == compound.lowercasedName : node.name == name else { return false }
        }
        for simple in compound.simple {
            switch simple {
            case .id(let id): guard node.id == id else { return false }
            case .className(let name): guard facts.classes[element].contains(name) else { return false }
            case .attribute(let attribute): guard matches(attribute, node) else { return false }
            case .pseudo(let pseudo): guard matches(pseudo, element, node) else { return false }
            }
        }
        return true
    }

    private func matches(_ selector: CSSAttributeSelector, _ node: ContentNode) -> Bool {
        let html = node.isHTML
        for attribute in node.attributes {
            // HTML attribute names match case-insensitively; XHTML's are almost always lowercase already.
            let nameMatches = attribute.name == selector.name || attribute.name == selector.lowercasedName
                || (html && attribute.name.utf8.count == selector.name.utf8.count && attribute.name.lowercased() == selector.lowercasedName)
            var found: Bool
            switch selector.namespace {
            case nil, .none?: found = nameMatches && attribute.namespace.isEmpty
            case .any?: found = nameMatches
            case .uri(let uri)?:
                found = nameMatches && attribute.namespace == uri
                if !found, document.recoveredAsHTML, attribute.namespace.isEmpty, let prefixed = selector.prefixedName {
                    found = attribute.name == prefixed
                }
            }
            if found, matches(selector, value: attribute.value) { return true }
        }
        return false
    }

    /// Calls `body` with each token of a whitespace-separated list (CSS whitespace is ASCII).
    static func forEachToken(_ value: String, _ body: (Substring) -> Void) {
        let utf8 = value.utf8
        var start = utf8.startIndex
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C }
        while start < utf8.endIndex {
            while start < utf8.endIndex, isSpace(utf8[start]) { start = utf8.index(after: start) }
            var end = start
            while end < utf8.endIndex, !isSpace(utf8[end]) { end = utf8.index(after: end) }
            if start < end { body(value[start..<end]) }
            start = end
        }
    }

    private static func includes(_ value: String, _ token: String) -> Bool {
        var found = false
        forEachToken(value) { if !found, $0 == token { found = true } }
        return found
    }

    private func matches(_ selector: CSSAttributeSelector, value: String) -> Bool {
        let value = selector.caseInsensitive ? value.lowercased() : value
        let expected = selector.value
        switch selector.operation {
        case .exists: return true
        case .equals: return value == expected
        case .includes:
            return !expected.isEmpty && !expected.utf8.contains { $0 == 0x20 || ($0 >= 0x09 && $0 <= 0x0D) }
                && Self.includes(value, expected)
        case .dashMatch: return value == expected || value.hasPrefix(expected + "-")
        case .prefix: return !expected.isEmpty && value.hasPrefix(expected)
        case .suffix: return !expected.isEmpty && value.hasSuffix(expected)
        case .substring: return !expected.isEmpty && value.contains(expected)
        }
    }

    private static func nth(_ a: Int, _ b: Int, _ position: Int) -> Bool {
        if a == 0 { return position == b }
        // The parser bounds A and B, but a hostile stylesheet must never trap here.
        let (difference, overflow) = position.subtractingReportingOverflow(b)
        guard !overflow else { return false }
        return difference / a >= 0 && difference % a == 0
    }

    /// `:nth-child(… of S)` re-matches siblings, so it is not evaluated among more than this many.
    static let maximumSiblingsForSelectorPositions = 1000

    /// Position among element siblings matching `selectors`, from the start or the end.
    private func position(of element: Int, among selectors: [CSSComplexSelector], fromEnd: Bool) -> Int? {
        let parent = Int(facts.parents[element])
        guard facts.siblingCounts[element] <= Self.maximumSiblingsForSelectorPositions else { return nil }
        let siblings = parent >= 0 ? document.nodes[parent].children.filter(\.isElement) : [document.nodes[element]]
        var position = 0
        for sibling in fromEnd ? siblings.reversed() : siblings {
            guard selectors.contains(where: { matches($0, sibling.order) }) else { continue }
            position += 1
            if sibling.order == element { return position }
        }
        return nil
    }

    private func matches(_ pseudo: CSSPseudoClass, _ element: Int, _ node: ContentNode) -> Bool {
        let position = Int(facts.positions[element]), count = Int(facts.siblingCounts[element])
        let typePosition = Int(facts.typePositions[element]), typeCount = Int(facts.typeCounts[element])
        switch pseudo {
        case .firstChild: return position == 1
        case .lastChild: return position == count
        case .onlyChild: return count == 1
        case .firstOfType: return typePosition == 1
        case .lastOfType: return typePosition == typeCount
        case .onlyOfType: return typeCount == 1
        case .nthChild(let a, let b, let of):
            guard let of else { return Self.nth(a, b, position) }
            return self.position(of: element, among: of, fromEnd: false).map { Self.nth(a, b, $0) } ?? false
        case .nthLastChild(let a, let b, let of):
            guard let of else { return Self.nth(a, b, count - position + 1) }
            return self.position(of: element, among: of, fromEnd: true).map { Self.nth(a, b, $0) } ?? false
        case .nthOfType(let a, let b): return Self.nth(a, b, typePosition)
        case .nthLastOfType(let a, let b): return Self.nth(a, b, typeCount - typePosition + 1)
        case .not(let selectors): return !selectors.contains { matches($0, element) }
        case .matchesAny(let selectors): return selectors.contains { matches($0, element) }
        case .root: return node === document.root
        case .empty: return node.children.allSatisfy { $0.isText && $0.text.isEmpty }
        case .link: return node.isHTML && (node.name == "a" || node.name == "area") && node.attribute("href") != nil
        case .lang(let ranges):
            guard let language = inherited(element, { $0.language })?.lowercased(), !language.isEmpty else { return false }
            return ranges.contains { $0 == "*" || language == $0 || language.hasPrefix($0 + "-") }
        case .dir(let direction):
            let value = inherited(element) { $0.isHTML ? $0.attribute("dir")?.lowercased() : nil }
            return (value == "rtl" ? .rtl : .ltr) == direction
        case .never: return false
        case .always: return true
        }
    }

    /// The nearest value on the element or an ancestor.
    private func inherited(_ element: Int, _ value: (ContentNode) -> String?) -> String? {
        var current = element
        while current >= 0 {
            if let found = value(document.nodes[current]) { return found }
            current = Int(facts.parents[current])
        }
        return nil
    }
}
