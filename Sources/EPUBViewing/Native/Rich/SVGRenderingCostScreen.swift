import Foundation

/// Amplification before and during usvg's conversion. The CSS reader is shared with the reference
/// screen so comments, malformed declarations and selector lists have the renderer's meaning.
/// All arithmetic saturates at the relevant ceiling; no hostile drawing reaches the renderer.
enum SVGRenderingCostScreen {
    static let maximumTextCharacters = 50_000
    static let maximumStylesheetWork = 8 * 1024 * 1024
    static let maximumStylesheetCopies = 16 * 1024 * 1024

    struct Verdict {
        var withinLimits: Bool
        var expandedBytes: Int
        var textCharacters: Int
        var stylesheetWork: Int
        var stylesheetCopies: Int
    }

    private struct Cost {
        var bytes = 0, text = 0, work = 0, copies = 0
        var within: Bool {
            bytes <= SVGContent.maximumExpandedBytes && text <= maximumTextCharacters
                && work <= maximumStylesheetWork && copies <= maximumStylesheetCopies
        }
        mutating func add(_ other: Cost) {
            bytes = min(SVGContent.maximumExpandedBytes + 1, bytes + other.bytes)
            text = min(maximumTextCharacters + 1, text + other.text)
            work = min(maximumStylesheetWork + 1, work + other.work)
            copies = min(maximumStylesheetCopies + 1, copies + other.copies)
        }
    }
    private struct Key: Hashable { var node: ObjectIdentifier; var depth: Int }
    private struct Resource: Hashable { var role: SVGReferenceScreen.Role; var id: String }
    private struct Style {
        var copies = 0
        var descendants: [Int: Int] = [:]
        var references = SVGReferenceScreen.References()
    }

    static func verdict(_ svg: ContentNode) -> Verdict {
        var nodes: [ContentNode] = []
        func collect(_ node: ContentNode) { nodes.append(node); for child in node.children { collect(child) } }
        collect(svg)
        return verdict(svg, nodes: nodes, ids: SVGContent.elementsByID(nodes))
    }

    static func verdict(_ svg: ContentNode, nodes: [ContentNode], ids: [String: [ContentNode]]) -> Verdict {
        typealias Subject = SVGReferenceScreen.Subject
        var styles: [Subject: Style] = [:]
        var selectors = 0
        var sheetCopies = 0
        for node in nodes where node.name == "style" && SVGContent.serializeKeepsSheet(node.textContent) {
            for rule in SVGReferenceScreen.CSSReader.rules(of: node.textContent, referencesOnly: false) {
                selectors += rule.subjects.count
                // simplecss clones a block for every selector, before matching any elements.
                sheetCopies = min(maximumStylesheetCopies + 1,
                                  sheetCopies + min(maximumStylesheetCopies + 1, rule.declarationBytes * rule.subjects.count))
                for (subject, descendants) in zip(rule.subjects, rule.descendants) {
                    var style = styles[subject, default: Style()]
                    style.copies = min(maximumStylesheetCopies + 1, style.copies + rule.copiedBytes)
                    style.descendants[descendants, default: 0] += 1
                    style.references.targets += rule.references.targets
                    style.references.inherits = style.references.inherits || rule.references.inherits
                    styles[subject] = style
                }
            }
        }
        func refused(work: Int = 0, copies: Int = 0, bytes: Int = 0) -> Verdict {
            Verdict(withinLimits: false, expandedBytes: bytes, textCharacters: 0, stylesheetWork: work, stylesheetCopies: copies)
        }
        if sheetCopies > maximumStylesheetCopies { return refused(copies: sheetCopies) }
        // Refuse the original XML's minimum matching/copying cost before resolving any reference
        // lists. This also bounds the screen's own rules-times-elements work.
        if selectors * nodes.count > maximumStylesheetWork { return refused(work: maximumStylesheetWork + 1) }
        var minimumCopies = sheetCopies
        for node in nodes where node.isElement {
            for subject in SVGReferenceScreen.subjects(of: node) {
                minimumCopies += styles[subject]?.copies ?? 0
                if minimumCopies > maximumStylesheetCopies { return refused(copies: maximumStylesheetCopies + 1) }
            }
        }
        var own: [ObjectIdentifier: SVGReferenceScreen.References] = [:]
        var allResources = Set<Resource>()
        for node in nodes where node.isElement {
            var references = SVGReferenceScreen.references(of: node)
            for subject in SVGReferenceScreen.subjects(of: node) {
                if let style = styles[subject] {
                    references.targets += style.references.targets
                    references.inherits = references.inherits || style.references.inherits
                }
            }
            own[ObjectIdentifier(node)] = references
            for target in references.targets where target.role == .mask || target.role == .clipPath {
                allResources.insert(Resource(role: target.role, id: target.id))
            }
        }
        // `inherit` may take its value from the use that draws this node, not its XML parent.
        // Assume every resource named in the drawing rather than reproduce the cascade.
        var resources: [ObjectIdentifier: [ContentNode]] = [:]
        var resourceLookups = 0
        for node in nodes where node.isElement {
            let references = own[ObjectIdentifier(node)]!
            var targets: [ObjectIdentifier: ContentNode] = [:]
            let candidates = references.targets + (references.inherits ? allResources.map { (role: $0.role, id: $0.id) } : [])
            for target in candidates where target.role == .mask || target.role == .clipPath {
                for found in ids[target.id] ?? [] where target.role.admits(found.name) {
                    resourceLookups += 1
                    if resourceLookups > SVGContent.maximumExpandedBytes / 32 {
                        return refused(bytes: SVGContent.maximumExpandedBytes + 1)
                    }
                    targets[ObjectIdentifier(found)] = found
                }
            }
            resources[ObjectIdentifier(node)] = Array(targets.values)
        }
        func cachedResource(_ node: ContentNode) -> Bool {
            // usvg mask.rs/clippath.rs share only these user-space resources. Their original
            // definition is already charged once; all other instances must pay their content again.
            func userSpace(_ name: String, byDefault: Bool) -> Bool {
                let values = node.attributes.filter { $0.name == name }
                return values.isEmpty ? byDefault : values.allSatisfy { $0.value == "userSpaceOnUse" }
            }
            if node.name == "mask" {
                return userSpace("maskUnits", byDefault: false) && userSpace("maskContentUnits", byDefault: true)
            }
            return node.name == "clipPath" && userSpace("clipPathUnits", byDefault: true)
        }
        // An unsuccessful chain of k descendant combinators explores every ancestor choice,
        // including partial matches: sum C(depth,j), 0 <= j <= k. Charge the sum, capped.
        func ancestorChoices(_ depth: Int, _ descendants: Int) -> Int {
            guard descendants > 0 else { return 0 }
            var choose = 1, total = 1
            guard depth > 0 else { return total }
            for j in 1...min(depth, descendants) {
                choose = min(maximumStylesheetWork + 1, choose * (depth - j + 1) / j)
                total = min(maximumStylesheetWork + 1, total + choose)
            }
            return total
        }
        var xmlDepth: [ObjectIdentifier: Int] = [:]
        func depths(_ node: ContentNode, depth: Int) {
            xmlDepth[ObjectIdentifier(node)] = depth
            for child in node.children { depths(child, depth: depth + 1) }
        }
        depths(svg, depth: 0)
        var memo: [Key: Cost] = [:]
        var active = Set<ObjectIdentifier>()
        func cost(_ node: ContentNode, depth: Int) -> Cost {
            let identity = ObjectIdentifier(node), key = Key(node: identity, depth: depth)
            if let found = memo[key] { return found }
            // The reference screen already refuses the loops usvg does not unlink. Short resource
            // loops are unlinked by usvg; following one again adds no converted content.
            if active.contains(identity) { return Cost() }
            guard depth <= 2 * SVGContent.maximumDepth else { return Cost(bytes: SVGContent.maximumExpandedBytes + 1) }
            active.insert(identity)
            defer { active.remove(identity) }
            var result = Cost(bytes: 32 + node.text.utf8.count + node.attributes.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count })
            if node.name == "text" { result.text = node.textContent.unicodeScalars.count }
            if node.isElement {
                result.work = selectors
                for subject in SVGReferenceScreen.subjects(of: node) {
                    if let style = styles[subject] {
                        result.copies = min(maximumStylesheetCopies + 1, result.copies + style.copies)
                        for (descendants, count) in style.descendants {
                            result.work = min(maximumStylesheetWork + 1,
                                              result.work + min(maximumStylesheetWork + 1, ancestorChoices(xmlDepth[identity] ?? 0, descendants) * count))
                        }
                    }
                }
            }
            let used = node.name == "use" ? SVGContent.fragment(node).flatMap { ids[$0] } ?? [] : []
            let referenced = (resources[identity] ?? []).filter { !cachedResource($0) }
            for child in node.children + used + referenced {
                guard result.within else { break }
                result.add(cost(child, depth: depth + 1))
            }
            memo[key] = result
            return result
        }
        var result = cost(svg, depth: 0)
        result.copies = min(maximumStylesheetCopies + 1, result.copies + sheetCopies)
        return Verdict(withinLimits: result.within, expandedBytes: result.bytes, textCharacters: result.text,
                       stylesheetWork: result.work, stylesheetCopies: result.copies)
    }
}
