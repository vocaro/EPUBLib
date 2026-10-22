import Foundation
import Synchronization

// The cascade's side of custom properties (CSS Variables 1): which custom declarations win for
// an element, what they compute to with their `var()`s substituted and their cycles found, and
// the substitution of the other properties' pending values at computed-value time.

extension StyleResolver {
    /// What a section may spend on substitution, for each appearance side
    /// (`CSSCustomProperties`): component values read and produced by substitutions, and
    /// entries copied into the custom properties of elements that declare some. The bound on
    /// one substitution (`CSSSubstitution.maximumTokens`) stops exponential expansion, but not
    /// a book that makes each of many elements substitute a long value, so this bounds a section
    /// as a whole, as `GeneratedContentState.maximumLength` bounds the text its styles generate,
    /// and with the same number: 1,048,576, which a book whose design system is built on custom
    /// properties stays far within (`CSSCustomPropertyTests`). Past it, what remains to
    /// substitute is invalid at computed-value time, and the section discloses that some of its
    /// styling was too large to apply.
    static let maximumSubstitutionWork = 1 << 20

    /// Elements' custom properties kept for reuse, for each appearance side: an element whose
    /// parent's custom properties and winning custom declarations are another's has its.
    static let maximumCachedCustomProperties = 4_096

    /// One appearance side's budget and cache. Each side spends its own, so that what the light
    /// side resolves, which decides everything but what paints, is the same in either appearance.
    final class SubstitutionSide: Sendable {
        let limit: Int
        private let spent = Atomic<Int>(0)
        private let cache = Mutex<[CacheKey: (parent: CSSCustomPropertyMap, map: CSSCustomPropertyMap)]>([:])

        struct CacheKey: Hashable {
            let parent: ObjectIdentifier
            let entries: [Int32]
        }

        init(limit: Int) { self.limit = limit }

        var isExhausted: Bool { spent.load(ordering: .relaxed) > limit }
        var spentWork: Int { spent.load(ordering: .relaxed) }

        /// Adds `work` to what is spent; false once that passes the limit, as it then stays.
        func spend(_ work: Int) -> Bool {
            guard !isExhausted else { return false }
            return spent.add(work, ordering: .relaxed).newValue <= limit
        }

        func cached(_ key: CacheKey, parent: CSSCustomPropertyMap) -> CSSCustomPropertyMap? {
            cache.withLock { cache in cache[key].flatMap { $0.parent === parent ? $0.map : nil } }
        }

        func store(_ map: CSSCustomPropertyMap, for key: CacheKey, parent: CSSCustomPropertyMap) {
            cache.withLock { cache in
                if cache.count >= StyleResolver.maximumCachedCustomProperties { cache.removeAll(keepingCapacity: true) }
                cache[key] = (parent, map)
            }
        }
    }

    /// The resolver's substitution state: a side for the light appearance and one for the
    /// reader's, and the empty custom properties of an element that has none.
    final class SubstitutionState: Sendable {
        let light: SubstitutionSide
        let appearance: SubstitutionSide
        let empty = CSSCustomPropertyMap([:])

        init(limit: Int) {
            light = SubstitutionSide(limit: limit); appearance = SubstitutionSide(limit: limit)
        }

        func side(appearance: Bool) -> SubstitutionSide { appearance ? self.appearance : light }
        var isExhausted: Bool { light.isExhausted || appearance.isExhausted }
    }

    /// The custom declarations the cascade leaves an element, one for each name, in the order
    /// their names were first declared: for the light side, and apart from it for the reader's
    /// appearance when the rule index separates them (`CSSRuleIndex.hasAppearanceCustomProperties`).
    struct CustomCascade {
        struct Winners {
            private(set) var declarations: [CSSCustomDeclaration] = []
            private var positions: [String: Int] = [:]
            /// The rule entries that declared some, in cascade order; nil once a `style`
            /// attribute has: with the parent's custom properties, what decides the result.
            private(set) var entries: [Int32]? = []

            var isEmpty: Bool { declarations.isEmpty }

            mutating func set(_ declaration: CSSCustomDeclaration) {
                if let position = positions[declaration.name] { declarations[position] = declaration; return }
                positions[declaration.name] = declarations.count
                declarations.append(declaration)
            }

            mutating func noteEntry(_ entry: Int?) {
                if let entry { entries?.append(Int32(entry)) } else { entries = nil }
            }
        }

        let separatesAppearance: Bool
        private(set) var light = Winners()
        private(set) var separateAppearance = Winners()
        var appearance: Winners { separatesAppearance ? separateAppearance : light }
        var isEmpty: Bool { light.isEmpty && separateAppearance.isEmpty }

        init(separatesAppearance: Bool) { self.separatesAppearance = separatesAppearance }

        /// Applies the declarations of `important`, from the rule entry `entry` (nil for a
        /// `style` attribute), on the sides `sides`.
        mutating func apply(_ declarations: [CSSCustomDeclaration], sides: CSSRuleIndex.CustomSides, important: Bool, entry: Int?) {
            var applied = false
            for declaration in declarations where declaration.important == important {
                applied = true
                if sides.contains(.light) { light.set(declaration) }
                if separatesAppearance, sides.contains(.appearance) { separateAppearance.set(declaration) }
            }
            guard applied else { return }
            if sides.contains(.light) { light.noteEntry(entry) }
            if separatesAppearance, sides.contains(.appearance) { separateAppearance.noteEntry(entry) }
        }
    }

    // MARK: Custom properties

    /// An element's computed custom properties, from its parent's and the declarations the
    /// cascade leaves it.
    @inline(never)
    func customProperties(_ cascade: CustomCascade, parent: CSSCustomProperties?) -> CSSCustomProperties? {
        let light = customPropertyMap(cascade.light, parent: parent?.light ?? substitution.empty, appearance: false)
        let appearance = cascade.separatesAppearance
            ? customPropertyMap(cascade.appearance, parent: parent?.appearance ?? substitution.empty, appearance: true) : light
        if let parent, parent.light === light, parent.appearance === appearance { return parent }
        if light === substitution.empty, appearance === substitution.empty { return nil }
        return CSSCustomProperties(light: light, appearance: appearance)
    }

    private func customPropertyMap(_ winners: CustomCascade.Winners, parent: CSSCustomPropertyMap, appearance: Bool) -> CSSCustomPropertyMap {
        guard !winners.isEmpty else { return parent }
        let side = substitution.side(appearance: appearance)
        let key = winners.entries.map { SubstitutionSide.CacheKey(parent: ObjectIdentifier(parent), entries: $0) }
        if let key, let cached = side.cached(key, parent: parent) { return cached }
        let map = resolve(winners.declarations, parent: parent, side: side)
        if let key { side.store(map, for: key, parent: parent) }
        return map
    }

    /// Computes custom properties (§2, §3): the parent's, with the element's own declarations
    /// in place and their `var()`s substituted. A property in a dependency cycle is invalid at
    /// computed-value time, as one whose substitution fails is, and has the guaranteed-invalid
    /// value. Only the references a substitution follows count: a fallback that is not used
    /// makes no cycle (§3, short-circuiting, csswg-drafts#11500).
    ///
    /// Cycles are found as Blink finds them (`CascadeResolver`): a stack holds the properties
    /// being resolved, and a reference to one of them marks every property from it to the top
    /// as in a cycle. The stack is an array, not the call stack, so a chain of references as
    /// long as a stylesheet can hold needs no recursion: a property that refers to one not yet
    /// resolved pushes it and is substituted again once it is.
    private func resolve(_ declarations: [CSSCustomDeclaration], parent: CSSCustomPropertyMap, side: SubstitutionSide) -> CSSCustomPropertyMap {
        guard side.spend(parent.values.count + declarations.count) else { return parent }
        var values = parent.values
        var pending: [String: CSSTokenRun] = [:]
        var order: [String] = []
        for declaration in declarations {
            switch declaration.value {
            case .keyword(.initial): values[declaration.name] = nil
            // `inherit` and `unset` are the parent's value, as is `revert`: the user agent sets
            // no custom property.
            case .keyword: break
            case .tokens(let run) where run.substitutes:
                pending[declaration.name] = run; order.append(declaration.name); values[declaration.name] = nil
            case .tokens(let run): values[declaration.name] = run
            }
        }
        var resolved = Set<String>()
        var stack: [String] = []
        var positions: [String: Int] = [:]
        let notFound = Int.max
        var cycleStart = notFound, cycleEnd = notFound
        var exhausted = false
        for first in order where !resolved.contains(first) {
            positions[first] = 0
            stack.append(first)
            while let top = stack.last {
                var substituter = CSSSubstitution.Substituter()
                var output: [CSSComponent] = []
                var outcome = CSSSubstitution.Outcome.invalid
                if !exhausted, let run = pending[top] {
                    outcome = substituter.substitute(run.components, level: 0, into: &output) { name in
                        if let name, pending[name] != nil, !resolved.contains(name) {
                            guard let position = positions[name] else { return .unresolved }
                            cycleStart = min(cycleStart, position)
                            cycleEnd = stack.count
                        }
                        if stack.count > cycleStart, stack.count <= cycleEnd { return .cyclic }
                        return name.flatMap { values[$0] }.map { .value($0) } ?? .invalid
                    }
                    if !side.spend(substituter.work) { exhausted = true; outcome = .invalid }
                }
                if case .needs(let name) = outcome {
                    positions[name] = stack.count
                    stack.append(name)
                    continue
                }
                var value = outcome == .substituted
                    ? CSSTokenRun(substituted: output, count: substituter.tokens, depth: substituter.depth) : nil
                if stack.count > cycleStart, stack.count <= cycleEnd { value = nil }
                if let substituted = value, let keyword = CSSSubstitution.wideKeyword(substituted.components) {
                    value = keyword == .initial ? nil : parent.values[top]
                }
                values[top] = value
                resolved.insert(top)
                stack.removeLast()
                positions[top] = nil
                if cycleEnd != notFound { cycleEnd = min(cycleEnd, stack.count) }
                if cycleEnd <= cycleStart { cycleStart = notFound; cycleEnd = notFound }
            }
        }
        return values == parent.values ? parent : CSSCustomPropertyMap(values)
    }

    // MARK: Pending substitutions

    typealias SubstitutionMemo = [CSSCustomPropertyMap.MemoKey: [CSSDeclaration]?]

    /// The value of `longhand` from a pending substitution in `property`'s place, at computed-
    /// value time: the declaration's value with its `var()`s substituted from `custom` and
    /// parsed as the property it was written for, or `unset` when that fails (§3.1). `memo`
    /// keeps an element's results, so that a shorthand is substituted once for its longhands.
    func substituted(_ pending: CSSPendingSubstitution, longhand: CSSProperty, in property: CSSProperty,
                     custom: CSSCustomProperties?, memo: inout SubstitutionMemo) -> CSSValue {
        let appearance = property.followsAppearance
        let map = custom?.map(appearance: appearance) ?? substitution.empty
        let key = CSSCustomPropertyMap.MemoKey(pending: ObjectIdentifier(pending), appearance: appearance)
        let declarations: [CSSDeclaration]?
        if let known = memo[key] {
            declarations = known
        } else if let known = map.memoized(pending, appearance: appearance) {
            declarations = known
            memo[key] = known
        } else {
            declarations = parse(pending, map: map, side: substitution.side(appearance: appearance))
            memo[key] = declarations
            map.memoize(pending, appearance: appearance, declarations)
        }
        return declarations?.first { $0.property == longhand }?.value ?? .unset
    }

    private func parse(_ pending: CSSPendingSubstitution, map: CSSCustomPropertyMap, side: SubstitutionSide) -> [CSSDeclaration]? {
        var substituter = CSSSubstitution.Substituter()
        var output: [CSSComponent] = []
        let outcome = substituter.substitute(pending.value.components, level: 0, into: &output) { name in
            name.flatMap { map.values[$0] }.map { .value($0) } ?? .invalid
        }
        guard side.spend(substituter.work), outcome == .substituted else { return nil }
        return CSSPropertyParser.parse(name: pending.name, value: output, important: false, isRuleValue: false)
    }
}
