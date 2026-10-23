import CoreGraphics
import EPUBCore
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
    /// An inline style or a sibling-search/filtered-position bound dropped author CSS.
    /// The builder folds this into `SectionReport.stylesTruncated`.
    let stylesTruncated: Bool
    /// The section's bound on substitution (`maximumSubstitutionWork`) left `var()`s
    /// unsubstituted in the styles computed so far. The builder folds this into
    /// `SectionReport.stylesTruncated` once it has computed them all.
    var substitutionsTruncated: Bool { substitution.isExhausted }

    static let maximumInlineStyleBytes = 16 * 1024

    private let author: CSSRuleIndex
    private let facts: ElementFacts
    private let siblingSearches = SiblingSearchMemo()
    private let selectorPositions: SelectorPositionMemo
    /// The root element's computed font size, which `rem` refers to.
    private var rootFontSize: CGFloat
    let initialValues: ComputedStyle
    let substitution: SubstitutionState

    init(document: ContentDocument, stylesheets: [CSSStyleSheet], typography: NativeTypography, fonts: FontRegistry? = nil,
         maximumSubstitutionWork: Int = StyleResolver.maximumSubstitutionWork) {
        self.document = document; self.typography = typography; self.fonts = fonts
        substitution = SubstitutionState(limit: maximumSubstitutionWork)
        facts = ElementFacts(document)
        selectorPositions = SelectorPositionMemo(document: document)
        // Only parents with more than `directWalk + 1` children can allocate a memo entry.
        // Reserve every retained suffix one entry under every such parent, including nested
        // pseudo-class searches. The production memo therefore never reaches its eviction path.
        let longParents = document.nodes.count { $0.isElement && $0.elementChildren.count > Int(SiblingSearchMemo.defaultDirectWalk) + 1 }
        let maximumSearches: Int? = longParents == 0 ? nil : SiblingSearchMemo.defaultCapacity / longParents
        // One rank cell per element child for every distinct retained `of S` list. Reserving
        // all eligible parents prevents memory exhaustion from restarting filtered scans.
        let positionCells = document.nodes.reduce(0) { total, node in
            let children = node.isElement ? node.elementChildren.count : 0
            return total + (children > SelectorPositionMemo.directWalk ? children : 0)
        }
        let maximumFilters = positionCells == 0 ? Int.max : SelectorPositionMemo.defaultCapacity / positionCells
        author = CSSRuleIndex(sheets: stylesheets, dark: typography.isDark, maximumSiblingSearches: maximumSearches,
                              maximumSelectorPositionFilters: maximumFilters)
        var initial = ComputedStyle()
        initial.fontSize = typography.fontSize
        initial.fontFamilies = ["serif"]
        initialValues = initial
        stylesTruncated = author.stylesTruncated || document.nodes.contains {
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
        style.usesBoldText = typography.boldText
        return style
    }

    /// The computed style of `element`, given its parent's computed style.
    func style(for element: ContentNode, parent: ComputedStyle) -> ComputedStyle {
        guard element.isElement else { return parent }
        let order = element.order
        let matcher = SelectorMatcher(document: document, facts: facts, siblingSearches: siblingSearches,
                                      selectorPositions: selectorPositions)
        let userAgent = UserAgentStyleSheet.index.matching(order, matcher: matcher)
        let matched = author.matching(order, matcher: matcher)
        let hints = PresentationalHints.declarations(for: element, facts: facts, document: document)
        var inline = CSSDeclarationBlock()
        if let text = element.attribute("style") {
            inline = CSSStyleSheet.block(String(decoding: text.utf8.prefix(Self.maximumInlineStyleBytes), as: UTF8.self))
        }
        func cascade(_ direction: ComputedStyle.Direction, user: [CSSDeclaration]) -> Cascade {
            var cascade = Cascade(direction: direction, separatesAppearance: author.hasAppearanceCustomProperties)
            for entry in userAgent { cascade.apply(UserAgentStyleSheet.index.entries[entry].declarations, important: false) }
            // The reader's text settings, as a user style sheet (`ReaderTextSettings`), to which
            // the book's `revert` rolls back (CSS Cascade 4 §7.3.4).
            cascade.apply(user, important: false)
            cascade.userAgent = cascade.winners
            cascade.apply(hints, important: false)
            for entry in matched { cascade.apply(author.entries[entry], at: entry, important: false) }
            cascade.apply(inline, important: false)
            for entry in matched where author.entries[entry].hasImportant {
                cascade.apply(author.entries[entry], at: entry, important: true)
            }
            cascade.apply(inline, important: true)
            for entry in userAgent where UserAgentStyleSheet.index.entries[entry].hasImportant {
                cascade.apply(UserAgentStyleSheet.index.entries[entry].declarations, important: true)
            }
            return cascade
        }
        let isRoot = element === document.root
        let rem = isRoot ? typography.fontSize : rootFontSize
        if !typography.text.isEmpty {
            return style(for: element, settings: typography.text, parent: parent, rem: rem, isRoot: isRoot,
                         generated: generatedRules(for: element, matcher: matcher), cascade: cascade)
        }
        let (result, custom) = resolvingSides({ cascade($0, user: []) }, parent: parent)
        guard let generated = generatedRules(for: element, matcher: matcher) else {
            return compute(winners: result.winners, userAgent: result.userAgent, custom: custom, parent: parent, rem: rem, isRoot: isRoot)
        }
        return style(for: element, generating: generated, winners: result.winners, userAgent: result.userAgent, custom: custom,
                     parent: parent, rem: rem, isRoot: isRoot)
    }
}

// MARK: - Cascade

extension StyleResolver {
    /// The winning value of each longhand, from declarations applied in cascade order, with the
    /// user agent's own winners for `revert`.
    struct Cascade {
        var winners = [CSSValue?](repeating: nil, count: CSSProperty.count)
        var userAgent: [CSSValue?] = []
        /// The direction that a declaration of a side by flow is mapped by.
        let direction: ComputedStyle.Direction
        /// Whether a declaration set a side by flow, so that the winners depend on `direction`.
        private(set) var isFlowRelative = false
        /// The custom properties declared for the element, which cascade apart from the others.
        private(set) var custom: CustomCascade

        init(direction: ComputedStyle.Direction, separatesAppearance: Bool = false) {
            self.direction = direction
            custom = CustomCascade(separatesAppearance: separatesAppearance)
        }

        mutating func apply(_ declarations: [CSSDeclaration], important: Bool) {
            for declaration in declarations where declaration.important == important {
                if declaration.rightToLeft != nil { isFlowRelative = true }
                winners[declaration.property(in: direction).rawValue] = declaration.value
            }
        }

        /// A rule's declarations, custom properties included, from the entry `index` of the
        /// author index.
        mutating func apply(_ entry: CSSRuleIndex.Entry, at index: Int, important: Bool) {
            apply(entry.declarations, important: important)
            if !entry.custom.isEmpty { custom.apply(entry.custom, sides: entry.customSides, important: important, entry: index) }
        }

        /// A `style` attribute's declarations, which apply in either appearance.
        mutating func apply(_ block: CSSDeclarationBlock, important: Bool) {
            apply(block.declarations, important: important)
            if !block.custom.isEmpty { custom.apply(block.custom, sides: [.light, .appearance], important: important, entry: nil) }
        }
    }

    /// The cascade `run` makes for an element, with its sides by flow mapped by the element's
    /// own direction (CSS Logical Properties 1 §4), which is also an outcome of the cascade but
    /// never depends on them. Mapped for left to right first, as nearly every element is; an
    /// element that sets a side by flow and turns out right to left is cascaded again. With it,
    /// the element's computed custom properties, which do not depend on the direction.
    func resolvingSides(_ run: (ComputedStyle.Direction) -> Cascade,
                        parent: ComputedStyle) -> (cascade: Cascade, custom: CSSCustomProperties?) {
        let ltr = run(.ltr)
        let custom = ltr.custom.isEmpty ? parent.customProperties : customProperties(ltr.custom, parent: parent.customProperties)
        guard ltr.isFlowRelative, direction(of: ltr, custom: custom, parent: parent) == .rtl else { return (ltr, custom) }
        return (run(.rtl), custom)
    }

    /// The direction `compute` gives the element from `cascade`'s winners.
    private func direction(of cascade: Cascade, custom: CSSCustomProperties?, parent: ComputedStyle) -> ComputedStyle.Direction {
        let index = CSSProperty.direction.rawValue
        var value = cascade.winners[index]
        if case .pending(let pending, let longhand)? = value {
            var memo = SubstitutionMemo()
            value = substituted(pending, longhand: longhand, in: .direction, custom: custom, memo: &memo)
        }
        if value == .revert { value = cascade.userAgent[index] }
        if case .direction(let direction)? = value { return direction }
        return value == .initial ? initialValues.direction : parent.direction
    }
}

// MARK: - Generated content

extension StyleResolver {
    /// The rules of the element's `::before` and `::after`, each the user agent's and the
    /// book's that match, or nil when none does. Most elements match none: their style is
    /// computed as before, with no frame that holds a second computed style, since styles are
    /// computed at the deepest point of nested tables on a background thread's small stack.
    private func generatedRules(for element: ContentNode, matcher: SelectorMatcher) -> [(userAgent: [Int], author: [Int])]? {
        guard UserAgentStyleSheet.index.hasGeneratedContentRules || author.hasGeneratedContentRules else { return nil }
        let order = element.order
        let rules = [CSSPseudoElement.before, .after].map { pseudoElement in
            (userAgent: UserAgentStyleSheet.index.matching(order, matcher: matcher, pseudoElement: pseudoElement),
             author: author.matching(order, matcher: matcher, pseudoElement: pseudoElement))
        }
        return rules.contains(where: { !$0.userAgent.isEmpty || !$0.author.isEmpty }) ? rules : nil
    }

    /// The element's computed style with its `::before` and `::after` (`GeneratedBoxes`), when
    /// some rule of theirs matches. A pseudo-element's cascade is its element's without
    /// presentational hints or a `style` attribute, and it inherits from the element.
    @inline(never)
    private func style(for element: ContentNode, generating rules: [(userAgent: [Int], author: [Int])], winners: [CSSValue?],
                       userAgent: [CSSValue?], custom: CSSCustomProperties?, parent: ComputedStyle, rem: CGFloat,
                       isRoot: Bool, adjust: ((inout ComputedStyle) -> Void)? = nil) -> ComputedStyle {
        var style = compute(winners: winners, userAgent: userAgent, custom: custom, parent: parent, rem: rem, isRoot: isRoot)
        adjust?(&style)
        let before = generatedStyle(of: element, userAgent: rules[0].userAgent, matched: rules[0].author, style: style)
        let after = generatedStyle(of: element, userAgent: rules[1].userAgent, matched: rules[1].author, style: style)
        if before != nil || after != nil { style.generated = GeneratedBoxes(before: before, after: after) }
        return style
    }

    private func generatedStyle(of element: ContentNode, userAgent: [Int], matched: [Int], style: ComputedStyle) -> ComputedStyle? {
        guard !userAgent.isEmpty || !matched.isEmpty else { return nil }
        let (cascade, custom) = resolvingSides({ direction in
            var cascade = Cascade(direction: direction, separatesAppearance: author.hasAppearanceCustomProperties)
            for entry in userAgent { cascade.apply(UserAgentStyleSheet.index.entries[entry].declarations, important: false) }
            cascade.userAgent = cascade.winners
            for entry in matched { cascade.apply(author.entries[entry], at: entry, important: false) }
            for entry in matched where author.entries[entry].hasImportant {
                cascade.apply(author.entries[entry], at: entry, important: true)
            }
            for entry in userAgent where UserAgentStyleSheet.index.entries[entry].hasImportant {
                cascade.apply(UserAgentStyleSheet.index.entries[entry].declarations, important: true)
            }
            return cascade
        }, parent: style)
        // `content` is not inherited, so with no declaration it is `normal`: no box.
        guard cascade.winners[CSSProperty.content.rawValue] != nil else { return nil }
        var generated = compute(winners: cascade.winners, userAgent: cascade.userAgent, custom: custom, parent: style,
                                rem: rootFontSize, isRoot: false)
        guard let items = generated.content, generated.display != .none else { return nil }
        generated.content = items.map { item in
            guard case .attribute(let name) = item else { return item }
            let value = element.attribute(name) ?? (element.isHTML ? element.attribute(name.lowercased()) : nil)
            return .string(value ?? "")
        }
        return generated
    }
}

// MARK: - Text settings

extension StyleResolver {
    /// The computed style of `element` under the host's text settings (`ReaderTextSettings`).
    /// An element the settings leave alone, and all it holds, is styled from the book's styles
    /// alone, as with no settings: each other style keeps those inherited values as the book
    /// alone gives them (`ReaderTextTrace`), for what it holds. The book's styles are computed
    /// for every element, which takes a second cascade and computation of each, only while a
    /// setting is set.
    @inline(never)
    private func style(for element: ContentNode, settings: ReaderTextSettings, parent: ComputedStyle, rem: CGFloat,
                       isRoot: Bool, generated: [(userAgent: [Int], author: [Int])]?,
                       cascade: (ComputedStyle.Direction, [CSSDeclaration]) -> Cascade) -> ComputedStyle {
        func styled(_ user: [CSSDeclaration], parent: ComputedStyle,
                    adjust: ((inout ComputedStyle) -> Void)? = nil) -> ComputedStyle {
            let (result, custom) = resolvingSides({ cascade($0, user) }, parent: parent)
            guard let generated else {
                var style = compute(winners: result.winners, userAgent: result.userAgent, custom: custom, parent: parent,
                                    rem: rem, isRoot: isRoot)
                adjust?(&style)
                return style
            }
            return self.style(for: element, generating: generated, winners: result.winners, userAgent: result.userAgent,
                              custom: custom, parent: parent, rem: rem, isRoot: isRoot, adjust: adjust)
        }
        if parent.textSettings === ReaderTextTrace.leftAlone {
            var style = styled([], parent: parent)
            style.textSettings = .leftAlone
            return style
        }
        let bookParent = parent.textSettings?.book?.applied(to: parent) ?? parent
        var book = styled([], parent: bookParent)
        if ReaderTextSettings.leavesAlone(element, style: book, parent: bookParent, document: document) {
            book.textSettings = .leftAlone
            return book
        }
        let isParagraph = element.isHTML("p")
        var set = if settings.overrides {
            styled([], parent: parent) { settings.override(&$0, isParagraph: isParagraph) }
        } else {
            styled(isRoot ? settings.rootDeclarations : isParagraph ? settings.paragraphDeclarations : [], parent: parent)
        }
        let bookText = ReaderTextTrace.BookText(book)
        // Most elements inherit all of these, and share their parent's record of them.
        set.textSettings = parent.textSettings?.book == bookText ? parent.textSettings : ReaderTextTrace(book: bookText)
        return set
    }
}

// MARK: - Rule index

/// Rules bucketed by their subject's id, class or type, so an element tests only rules that can
/// match it.
struct CSSRuleIndex: Sendable {
    struct Entry: Sendable {
        let selector: CSSComplexSelector
        let declarations: [CSSDeclaration]
        /// The rule's custom properties, and the appearance sides they take part in.
        let custom: [CSSCustomDeclaration]
        let customSides: CustomSides
        /// Specificity, then source order: the cascade's sort key within an origin.
        let key: UInt64
        let hasImportant: Bool
        /// Ancestor names' filter bits, checked before matching.
        let ancestorBits: [(UInt8, UInt8)]
    }
    private(set) var entries: [Entry] = []
    /// A selector was omitted to keep retained sibling searches and filtered ranks inside their memos.
    private(set) var stylesTruncated = false
    /// Whether some rule's custom properties take part in one side and not the other, so that
    /// an element's custom properties are computed for each (`CSSCustomProperties`). Only in
    /// the dark index: the light one's sides are one.
    private(set) var hasAppearanceCustomProperties = false

    /// The sides a custom property declaration takes part in: what is substituted into the
    /// properties that do not paint, which are resolved as in the light appearance, and what is
    /// substituted into those that paint, which follow the reader's (`CSSMediaMask.governs`).
    struct CustomSides: OptionSet, Sendable {
        let rawValue: UInt8
        static let light = CustomSides(rawValue: 1)
        static let appearance = CustomSides(rawValue: 2)
    }
    /// The rules of elements, and apart from them those of their `::before` and `::after`,
    /// which are bucketed by the originating element.
    private var buckets = Buckets()
    private var beforeBuckets = Buckets()
    private var afterBuckets = Buckets()

    /// The value by its code units, as the matcher compares it (`CodeUnitString`).
    private struct AttributeValueKey: Hashable {
        let name: String; let value: Substring
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name && CodeUnits.equal(lhs.value, rhs.value) }
        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            CodeUnits.hash(value, into: &hasher)
        }
    }

    private struct Buckets {
        var byID: [EPUBElementID: [Int32]] = [:]
        var byClass: [CodeUnitString: [Int32]] = [:]
        var byType: [String: [Int32]] = [:]
        var byAttribute: [String: [Int32]] = [:]
        var byAttributeValue: [AttributeValueKey: [Int32]] = [:]
        /// Names that `byAttribute` or `byAttributeValue` index.
        var attributeNames = Set<String>()
        var universal: [Int32] = []
        var isEmpty = true

        mutating func insert(_ index: Int32, under key: CSSBucketKey) {
            isEmpty = false
            switch key {
            case .id(let id): byID[id, default: []].append(index)
            case .className(let name): byClass[name, default: []].append(index)
            case .type(let name): byType[name, default: []].append(index)
            case .attribute(let name):
                byAttribute[name, default: []].append(index); attributeNames.insert(name)
            case .attributeValue(let name, let value):
                byAttributeValue[AttributeValueKey(name: name, value: Substring(value.string)), default: []].append(index)
                attributeNames.insert(name)
            case .universal: universal.append(index)
            }
        }
    }

    /// Whether some rule styles a `::before` or an `::after`.
    var hasGeneratedContentRules: Bool { !beforeBuckets.isEmpty || !afterBuckets.isEmpty }

    /// A nil sibling-search bound means no parent can use that memo, so parsed search identities
    /// need no interning. Filtered-position admission independently bounds retained `of S` lists.
    init(sheets: [CSSStyleSheet], dark: Bool, maximumSiblingSearches: Int? = SiblingSearchMemo.defaultCapacity,
         maximumSelectorPositionFilters: Int = Int.max) {
        var positionFilters = Set<[CSSComplexSelector]>()
        var searches = CSSSiblingSearchIndex(maximumSearches: maximumSiblingSearches ?? Int.max)
        var order: UInt64 = 0
        for sheet in sheets {
            // Every rule's selectors are admitted in either appearance, so that a bound drops the
            // same ones in both. A rule keeps the declarations that take part in `dark`
            // (`CSSMediaMask.governs`) and the custom properties that take part in either side,
            // and one left with none is not matched.
            for rule in sheet.rules where !rule.media.isEmpty {
                let declarations = rule.declarations.filter { rule.media.governs($0.property, dark: dark) }
                var sides: CustomSides = []
                if rule.media.contains(.light) { sides.insert(.light) }
                if rule.media.contains(dark: dark) { sides.insert(.appearance) }
                let custom = sides.isEmpty ? [] : rule.custom
                if !custom.isEmpty, sides != [.light, .appearance] { hasAppearanceCustomProperties = true }
                let important = declarations.contains(where: \.important) || custom.contains(where: \.important)
                for original in rule.selectors {
                    let wanted = original.selectorPositionFilters
                    guard wanted.subtracting(positionFilters).count <= maximumSelectorPositionFilters - positionFilters.count else {
                        stylesTruncated = true; continue
                    }
                    let indexed = maximumSiblingSearches == nil ? original : searches.indexed(original)
                    guard let selector = indexed else { stylesTruncated = true; continue }
                    positionFilters.formUnion(wanted)
                    let index = Int32(entries.count)
                    guard !declarations.isEmpty || !custom.isEmpty else { continue }
                    entries.append(Entry(selector: selector, declarations: declarations, custom: custom, customSides: sides,
                                         key: UInt64(selector.specificity) << 32 | order, hasImportant: important,
                                         ancestorBits: selector.ancestorNames.map(\.bits)))
                    switch selector.pseudoElement {
                    case nil: buckets.insert(index, under: selector.bucketKey)
                    case .before?: beforeBuckets.insert(index, under: selector.bucketKey)
                    case .after?: afterBuckets.insert(index, under: selector.bucketKey)
                    case .other?: break // `CSSStyleSheet` keeps none.
                    }
                }
                order += 1
            }
        }
    }

    /// Entries whose selector matches the element, in ascending cascade order: the element's own
    /// rules, or with `pseudoElement` those of its `::before` or `::after`.
    func matching(_ element: Int, matcher: SelectorMatcher, pseudoElement: CSSPseudoElement? = nil) -> [Int] {
        switch pseudoElement {
        case nil: matching(element, matcher: matcher, in: buckets)
        case .before?: beforeBuckets.isEmpty ? [] : matching(element, matcher: matcher, in: beforeBuckets)
        case .after?: afterBuckets.isEmpty ? [] : matching(element, matcher: matcher, in: afterBuckets)
        case .other?: []
        }
    }

    private func matching(_ element: Int, matcher: SelectorMatcher, in buckets: Buckets) -> [Int] {
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
        if let id = node.id { test(buckets.byID[id]) }
        if !buckets.byClass.isEmpty { for name in matcher.facts.classes[element] { test(buckets.byClass[name]) } }
        test(buckets.byType[matcher.facts.bucketNames[element]])
        if !buckets.attributeNames.isEmpty {
            for attribute in node.attributes {
                let name = CSSBucketKey.attributeName(attribute.name)
                guard buckets.attributeNames.contains(name) else { continue }
                test(buckets.byAttribute[name])
                guard !buckets.byAttributeValue.isEmpty else { continue }
                test(buckets.byAttributeValue[AttributeValueKey(name: name, value: Substring(attribute.value))])
                SelectorMatcher.forEachToken(attribute.value) { token in
                    if token.count != attribute.value.count { test(buckets.byAttributeValue[AttributeValueKey(name: name, value: token)]) }
                }
            }
        }
        test(buckets.universal)
        guard result.count > 1 else { return result }
        result.sort { entries[$0].key < entries[$1].key }
        // An element can reach one entry through two attributes or repeated tokens.
        var previous = -1
        return result.filter { defer { previous = $0 }; return $0 != previous }
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
    /// Distinct class names, told apart by their code units.
    var classes: [[CodeUnitString]]
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
            var seen = Set<CodeUnitString>()
            classes[node.order] = node.classNames.map { CodeUnitString($0) }.filter { seen.insert($0).inserted }
            // Preorder: the parent's filter is complete before its children are reached.
            var childFilter = ancestorFilters[node.order]
            childFilter.insert(.init(kind: .type, value: bucketNames[node.order]))
            if let id = node.id { childFilter.insert(.init(kind: .id, value: id)) }
            for name in classes[node.order] { childFilter.insert(.init(kind: .className, value: name.string)) }
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
/// is the walk's again. `StyleResolver` admits only as many distinct, interned left-hand
/// searches as fit under every eligible parent, so its memo never needs to forget an entry.
final class SiblingSearchMemo: Sendable {
    static let defaultDirectWalk: Int32 = 8
    static let defaultCapacity = 1 << 16
    struct Key: Hashable {
        /// Of the left-hand suffix identity, held by the rule index for its lifetime.
        let selector: ObjectIdentifier
        /// Zero for interned suffixes; the compound index for unindexed parsed selectors.
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

    init(directWalk: Int32 = SiblingSearchMemo.defaultDirectWalk, capacity: Int = SiblingSearchMemo.defaultCapacity) {
        self.directWalk = directWalk; self.capacity = capacity
    }

    var entryCount: Int { entries.withLock { $0.count } }

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

/// Ranks among one parent's element children matching one `of S` list. The resolver owns this
/// for one immutable document. Both nth directions and all An+B patterns share the same table.
final class SelectorPositionMemo: Sendable {
    static let directWalk = Int(SiblingSearchMemo.defaultDirectWalk) + 1
    /// Rank cells (4 MB), reserved at rule admission across every eligible parent and list.
    static let defaultCapacity = 1 << 20
    struct Key: Hashable, Sendable {
        let parent: Int32
        // Equality includes the whole selector value; a hash collision cannot share a table.
        let selectors: [CSSComplexSelector]
    }
    struct Table: Sendable {
        /// Indexed by structural element-child position minus one; zero means outside S.
        let ranks: [Int32]
        let count: Int32
    }
    private struct State: Sendable {
        var entries: [Key: Table] = [:]
        var cells = 0
    }
    let document: ContentDocument
    private let capacity: Int
    private let state = Mutex(State())

    init(document: ContentDocument, capacity: Int = SelectorPositionMemo.defaultCapacity) {
        self.document = document; self.capacity = capacity
    }

    var entryCount: Int { state.withLock { $0.entries.count } }
    var cellCount: Int { state.withLock { $0.cells } }

    func table(for key: Key, cells: Int, build: () -> Table) -> Table? {
        state.withLock { state in
            if let table = state.entries[key] { return table }
            guard cells <= capacity - state.cells else { return nil }
            // Parsed S lists cannot contain filtered nth pseudo-classes, so building cannot
            // recursively acquire this lock. Inner `~` searches use their own separate memo.
            let table = build()
            state.entries[key] = table
            state.cells += cells
            return table
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
    /// nil: filtered nth pseudo-classes count by a direct scan, useful as a reference in tests.
    var selectorPositions: SelectorPositionMemo?
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
            if let memo = siblingSearches, selector.identity != nil, position - 1 > memo.directWalk {
                // The previous sibling settles the search wherever the walk is quickest, and then
                // nothing is looked up.
                let result = match(selector, sibling, from: index + 1)
                if result != .failsLocally { return result }
                let key = selector.siblingSearchKey(at: index + 1, parent: facts.parents[element])!
                return walk(on: sibling, at: position - 1, selector, from: index + 1, key, memo)
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
    private func walk(on sibling: Int, at position: Int32, _ selector: CSSComplexSelector, from index: Int,
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
            result = match(selector, sibling, from: index)
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
            guard uri.matches(node.namespace) || (node.namespace.isEmpty && uri.matches(ContentNamespace.xhtml)) else { return false }
        }
        if let name = compound.name {
            guard (node.isHTML ? compound.lowercasedName ?? name : name).matches(node.name) else { return false }
        }
        for simple in compound.simple {
            switch simple {
            case .id(let id): guard node.id.map { EPUBElementID($0) } == id else { return false }
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
            let nameMatches = selector.name.matches(attribute.name) || selector.lowercasedName.matches(attribute.name)
                || (html && attribute.name.utf8.count == selector.name.string.utf8.count
                    && selector.lowercasedName.matches(attribute.name.lowercased()))
            var found: Bool
            switch selector.namespace {
            case nil, .none?: found = nameMatches && attribute.namespace.isEmpty
            case .any?: found = nameMatches || Self.prefixedName(attribute, is: selector)
            case .uri(let uri)?:
                found = (nameMatches && uri.matches(attribute.namespace))
                    || (uri.matches(attribute.prefixNamespace) && Self.prefixedName(attribute, is: selector))
            }
            if found, matches(selector, value: attribute.value) { return true }
        }
        return false
    }

    /// In a section read as HTML, whether a name such as `epub:type` is the attribute a selector
    /// names, read as XML would read it: its local name after the prefix, in the namespace the
    /// prefix stands for (`ContentAttribute.prefixNamespace`), which the caller compares. So
    /// `[ops|type]` reaches it by namespace whatever prefix either wrote (Selectors 4 §6.7).
    private static func prefixedName(_ attribute: ContentAttribute, is selector: CSSAttributeSelector) -> Bool {
        guard !attribute.prefixNamespace.isEmpty, let colon = attribute.name.utf8.firstIndex(of: UInt8(ascii: ":")) else { return false }
        return selector.lowercasedName.matches(attribute.name[attribute.name.utf8.index(after: colon)...])
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
        forEachToken(value) { if !found, CodeUnits.equal($0, token) { found = true } }
        return found
    }

    /// Code unit for code unit, as browsers compare values, with the ASCII letters alone folded
    /// under the `i` flag (Selectors 4 §6.3).
    private func matches(_ selector: CSSAttributeSelector, value: String) -> Bool {
        let value = selector.caseInsensitive ? CodeUnits.asciiLowercased(value) : value
        let expected = selector.value.string
        switch selector.operation {
        case .exists: return true
        case .equals: return CodeUnits.equal(value, expected)
        case .includes:
            return !expected.isEmpty && !expected.utf8.contains { $0 == 0x20 || ($0 >= 0x09 && $0 <= 0x0D) }
                && Self.includes(value, expected)
        case .dashMatch: return CodeUnits.equal(value, expected) || CodeUnits.hasPrefix(value, expected + "-")
        case .prefix: return !expected.isEmpty && CodeUnits.hasPrefix(value, expected)
        case .suffix: return !expected.isEmpty && CodeUnits.hasSuffix(value, expected)
        case .substring: return !expected.isEmpty && CodeUnits.contains(value, expected)
        }
    }

    private static func nth(_ a: Int, _ b: Int, _ position: Int) -> Bool {
        if a == 0 { return position == b }
        // The parser bounds A and B, but a hostile stylesheet must never trap here.
        let (difference, overflow) = position.subtractingReportingOverflow(b)
        guard !overflow else { return false }
        return difference / a >= 0 && difference % a == 0
    }

    /// Position among element siblings matching `selectors`, from the start or the end.
    private func position(of element: Int, among selectors: [CSSComplexSelector], fromEnd: Bool) -> Int? {
        let parent = Int(facts.parents[element])
        if parent >= 0, Int(facts.siblingCounts[element]) > SelectorPositionMemo.directWalk,
           let memo = selectorPositions, memo.document === document {
            let key = SelectorPositionMemo.Key(parent: Int32(parent), selectors: selectors)
            if let table = memo.table(for: key, cells: Int(facts.siblingCounts[element]), build: {
                let siblings = document.nodes[parent].elementChildren
                var ranks = [Int32](repeating: 0, count: siblings.count)
                var count: Int32 = 0
                for (index, sibling) in siblings.enumerated() where selectors.contains(where: { matches($0, sibling.order) }) {
                    count += 1
                    ranks[index] = count
                }
                return SelectorPositionMemo.Table(ranks: ranks, count: count)
            }) {
                let rank = table.ranks[Int(facts.positions[element]) - 1]
                guard rank > 0 else { return nil }
                return Int(fromEnd ? table.count - rank + 1 : rank)
            }
        }
        // Small runs do constant bounded work; an explicitly uncached matcher remains an
        // independent reference implementation, including documents with more than 1,000 siblings.
        let siblings = parent >= 0 ? document.nodes[parent].elementChildren : [document.nodes[element]]
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
            // Case-insensitive in the ASCII range alone (Selectors 4 §7.2), by code units.
            guard let language = inherited(element, { $0.language }).map(CodeUnits.asciiLowercased), !language.isEmpty else { return false }
            return ranges.contains { $0 == "*" || $0.matches(language) || CodeUnits.hasPrefix(language, $0.string + "-") }
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
