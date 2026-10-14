import Foundation

/// The references between an SVG's elements, screened before the bundled renderer follows them.
///
/// The renderer follows a `mask`, a `clip-path`, a marker and a `use` by calling itself, and a
/// gradient's `href` in a loop, and guards each only in part (usvg 0.48.1, `parser/svgtree`,
/// `mask.rs`, `clippath.rs`, `marker.rs`, `paint_server.rs`):
///
/// - It unlinks a mask or clip path that leads back to itself directly or through one other.
///   Three in a ring are not found, and it calls itself until the stack is spent.
/// - It skips a marker that is already being drawn, so a ring of markers ends, as deep as it
///   is long. A chain with no loop in it is followed as far as it goes.
/// - It ends an `href` walk that comes back to the gradient it began at. One that enters a
///   loop from outside never comes back, and never ends.
///
/// None of these is a panic, and a spent stack cannot be caught, so the drawing is refused
/// first. References are read as the renderer reads them, wherever it takes one from: an
/// attribute, a `style` attribute, or a rule of a stylesheet in the drawing. Where its reading
/// is costly to repeat, more is assumed than it would follow, never less: a rule applies to
/// every element its last compound selector could match, every declaration counts whatever
/// overrides it, and an `id` that several elements share names them all.
///
/// That holds for bytes `SVGContent.serialize` wrote, not for any bytes. A stylesheet is read
/// here from the whole text of a `style` element, which the parser of this tree has merged
/// across a comment, a processing instruction or a child element. The renderer's parser takes
/// only the text the element begins with, so on such bytes the two see different CSS, and a
/// rule one finds the other may not. The serializer writes a `style` element as one text, and
/// the reader hands the renderer nothing but serialized bytes, which `SVGRenderer.init`
/// screens again as it is given them: that is what removes the difference. A path that handed
/// the renderer a book's bytes as written could not rely on this screen alone.
///
/// A marker that draws a marker, or whose content names anything, is `SVGContent.markerVerdict`'s
/// to refuse, and it does. Markers are followed here for what that leaves: content that takes
/// the marker's own `mask` or `clip-path` by saying `inherit`, and so leads on from it.
///
/// The work is linear in the elements, the references and the stylesheet text, and nothing
/// here calls itself.
enum SVGReferenceScreen {
    /// Masks and clip paths that may lead to each other: the renderer unlinks a loop of one
    /// and a loop of two, and with no more than two there is no longer loop to miss.
    static let maximumLoop = 2

    /// Whether the renderer can follow every reference in a drawing, given as its nodes in
    /// document order from its root and the elements each `id` can mean
    /// (`SVGContent.elementsByID`): no loop it would not end, no `href` walk without an end,
    /// and no chain of nesting and references
    /// deeper than nesting alone may be.
    static func accepts(_ nodes: [ContentNode], ids: [String: [ContentNode]]) -> Bool {
        let elements = nodes.filter(\.isElement)
        guard !elements.isEmpty else { return true }
        let graph = Graph(elements, ids: ids)
        return graph.gradientWalksEnd && graph.chainsAreBounded
    }

    /// What an element is told to reference, by its attributes or by a rule.
    struct References {
        var targets: [(role: Role, id: String)] = []
        /// `mask` or `clip-path` is `inherit`: the parent's, or that of the `use` drawing it.
        var inherits = false

        var isEmpty: Bool { targets.isEmpty && !inherits }

        mutating func add(_ property: String, _ value: String) {
            let role: Role
            switch property {
            case "mask": role = .mask
            case "clip-path": role = .clipPath
            case "marker", "marker-start", "marker-mid", "marker-end": role = .marker
            default: return
            }
            // A value from CSS has lost the space around it, of any kind.
            let value = value.unicodeScalars.drop { $0.properties.isWhitespace }
            if let id = functionalReference(value) {
                targets.append((role, id))
            } else if role != .marker, value.starts(with: "inherit".unicodeScalars) {
                // A marker is inherited whether or not this is said.
                inherits = true
            }
        }
    }

    /// The kind of element a reference must name to be followed.
    enum Role: Hashable {
        case mask, clipPath, marker, gradient
        /// What a `use` draws: an element that is drawn where it stands, or a `symbol`.
        case drawn

        func admits(_ name: String) -> Bool {
            switch self {
            case .mask: name == "mask"
            case .clipPath: name == "clipPath"
            case .marker: name == "marker"
            case .gradient: gradients.contains(name)
            case .drawn: SVGReferenceScreen.drawn.contains(name) || name == "symbol"
            }
        }
    }

    /// Elements the renderer draws where they stand (`convert_element` in its `converter.rs`,
    /// and `a`, which it reads as `g`). It passes over any other child with all it holds: the
    /// content of a mask, clip path or marker is drawn for what references it, not in place.
    private static let drawn: Set<String> = ["a", "g", "switch", "svg", "use", "image", "text",
                                             "rect", "circle", "ellipse", "line", "polyline", "polygon", "path"]
    /// Elements that draw the markers they and their ancestors name.
    private static let shapes: Set<String> = ["rect", "circle", "ellipse", "line", "polyline", "polygon", "path"]
    /// Elements whose `href` the renderer walks for what they leave unsaid. A pattern or a
    /// filter never reaches it; their walks are the same, so they are screened the same.
    private static let gradients: Set<String> = ["linearGradient", "radialGradient", "pattern", "filter"]
    /// The renderer takes a presentation attribute from any of these namespaces.
    private static let attributeNamespaces: Set<String> = ["", ContentNamespace.svg, ContentNamespace.xlink, ContentNamespace.xml]

    /// The `id` in `url(#id)` at the start of a value, as svgtypes 0.16.1 reads a `<FuncIRI>`:
    /// optional quotes, and an unquoted name that ends at a space or the bracket. What follows
    /// the name is not checked, so a value the renderer rejects may still give one. (The `#id`
    /// of an `href` is read otherwise, by `SVGContent.fragment`.)
    private static func functionalReference(_ value: Substring.UnicodeScalarView) -> String? {
        var rest = value.drop(while: isSpace)
        guard rest.starts(with: "url(".unicodeScalars) else { return nil }
        rest = rest.dropFirst(4).drop(while: isSpace)
        var quote: Unicode.Scalar?
        if let first = rest.first, first == "'" || first == "\"" {
            quote = first
            rest = rest.dropFirst().drop(while: isSpace)
        }
        guard rest.first == "#" else { return nil }
        rest = rest.dropFirst()
        var name = quote.map { quote in rest.prefix { $0 != quote } } ?? rest.prefix { $0 != " " && $0 != ")" }
        if quote != nil { while name.last?.properties.isWhitespace == true { name = name.dropLast() } }
        return name.isEmpty || name.contains { $0 == "'" || $0 == "\"" } ? nil : String(name)
    }

    /// The space svgtypes skips.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }

    /// One way a node leads to another.
    private enum Link {
        /// A child, or what a `use` draws: one level deeper.
        case nested
        /// The same level: a step between an element and what stands for its references.
        case level
        /// A `mask` or `clip-path`, one level deeper.
        case maskOrClip
        /// A marker, one level deeper.
        case marker
        /// A gradient's `href`: walked in a loop, at no depth.
        case href

        var depth: Int { self == .level || self == .href ? 0 : 1 }
        var isNesting: Bool { self == .nested || self == .level }
    }

    private struct Edge {
        let target: Int
        let link: Link
    }

    /// Every element and what it references, as nodes in threes. For element `i`: `3i` is the
    /// element; `3i + 1` its own `mask` and `clip-path`, which a child that says `inherit`
    /// takes; `3i + 2` the markers it names, which every shape beneath it draws. A name that
    /// is referenced, a selector and a rule's block each have three of their own, laid out
    /// the same, so that neither many elements with one `id` or class nor many selectors on
    /// one block multiply the edges.
    private struct Graph {
        private var edges: [[Edge]]
        /// The element at a node that is one; nil for the rest.
        private var names: [String?]
        /// Nodes standing for a referenced name, which lead to the elements that have it.
        private var isName: [Bool]


        init(_ elements: [ContentNode], ids: [String: [ContentNode]]) {
            edges = Array(repeating: [], count: 3 * elements.count)
            names = Array(repeating: nil, count: 3 * elements.count)
            isName = Array(repeating: false, count: 3 * elements.count)
            var index: [ObjectIdentifier: Int] = [:]
            for (i, element) in elements.enumerated() {
                index[ObjectIdentifier(element)] = i
                names[3 * i] = element.name
            }
            func triple() -> Int {
                edges += [[], [], []]
                names += [nil, nil, nil]
                isName += [false, false, false]
                return edges.count - 3
            }
            func link(_ from: Int, _ to: Int, _ link: Link) { edges[from].append(Edge(target: to, link: link)) }

            // The renderer takes a stylesheet from an element named `style` in any namespace.
            let blocks = elements.filter { $0.name == "style" }.flatMap { CSSReader.rules(of: $0.textContent) }
            let inheriting = Set(blocks.filter(\.references.inherits).flatMap(\.subjects))
            let assigning = Set(blocks.flatMap(\.subjects))

            // What each element says for itself, and the selectors it could match.
            var own = Array(repeating: References(), count: elements.count)
            var subjects: [[Subject]] = Array(repeating: [], count: elements.count)
            for (i, element) in elements.enumerated() {
                var matching: [Subject] = [.any, .type(element.name)]
                for attribute in element.attributes {
                    switch attribute.name {
                    case "style":
                        for declaration in CSSReader.declarations(of: attribute.value) { own[i].add(declaration.name, declaration.value) }
                    case "class":
                        // The renderer splits a class list at spaces alone.
                        matching += attribute.value.split(separator: " ").map { .class(String($0)) }
                    case "id":
                        matching.append(.id(attribute.value))
                    default:
                        if SVGReferenceScreen.attributeNamespaces.contains(attribute.namespace) { own[i].add(attribute.name, attribute.value) }
                    }
                }
                subjects[i] = matching.filter(assigning.contains)
                if subjects[i].contains(where: inheriting.contains) { own[i].inherits = true }
            }

            var named: [Named: Int?] = [:]
            /// The node for the elements a reference names, or nil when it names none.
            func target(_ id: String, _ role: Role) -> Int? {
                let key = Named(id: id, role: role)
                if let known = named[key] { return known }
                let found = (ids[id] ?? []).filter { role.admits($0.name) }.compactMap { index[ObjectIdentifier($0)] }
                guard !found.isEmpty else {
                    named[key] = .some(nil)
                    return nil
                }
                let node = triple()
                isName[node] = true
                for j in found {
                    link(node, 3 * j, .level)
                    // A `use` passes what it would hand a child on to what it draws.
                    if role == .drawn {
                        if own[j].inherits { link(3 * j + 1, node + 1, .level) }
                        link(3 * j + 2, node + 2, .level)
                    }
                }
                named[key] = node
                return node
            }
            func attach(_ references: References, to node: Int) {
                for reference in references.targets {
                    guard let found = target(reference.id, reference.role) else { continue }
                    if reference.role == .marker { link(node + 2, found, .marker) } else { link(node + 1, found, .maskOrClip) }
                }
            }

            var selectors: [Subject: Int] = [:]
            for block in blocks where !block.references.targets.isEmpty {
                let node = triple()
                attach(block.references, to: node)
                for subject in Set(block.subjects) {
                    if selectors[subject] == nil { selectors[subject] = triple() }
                    link(selectors[subject]! + 1, node + 1, .level)
                    link(selectors[subject]! + 2, node + 2, .level)
                }
            }
            for (i, element) in elements.enumerated() {
                let node = 3 * i
                if let parent = element.parent.flatMap({ index[ObjectIdentifier($0)] }) {
                    if SVGReferenceScreen.drawn.contains(element.name) { link(3 * parent, node, .nested) }
                    link(node + 2, 3 * parent + 2, .level)
                    if own[i].inherits { link(node + 1, 3 * parent + 1, .level) }
                }
                link(node, node + 1, .level)
                if SVGReferenceScreen.shapes.contains(element.name) { link(node, node + 2, .level) }
                attach(own[i], to: node)
                for selector in subjects[i].compactMap({ selectors[$0] }) {
                    link(node + 1, selector + 1, .level)
                    link(node + 2, selector + 2, .level)
                }
                if element.name == "use", let found = SVGContent.fragment(element).flatMap({ target($0, .drawn) }) {
                    link(node, found, .nested)
                    link(found + 1, node + 1, .level)
                    link(found + 2, node + 2, .level)
                } else if SVGReferenceScreen.gradients.contains(element.name), let found = SVGContent.fragment(element).flatMap({ target($0, .gradient) }) {
                    link(node, found, .href)
                }
            }
        }

        /// Whether no `href` walk can enter a loop of two or more gradients from outside it.
        /// A gradient that names itself ends the walk, and so does a loop walked from one of
        /// its own, which is where the walk comes back to.
        var gradientWalksEnd: Bool {
            let follows: (Int, Edge) -> Bool = { node, edge in edge.link == .href || (isName[node] && edge.link == .level) }
            let (groups, group) = components(from: edges.indices, following: follows)
            let loops = groups.map { $0.count(where: { names[$0] != nil }) >= 2 }
            var inside = Array(repeating: 0, count: groups.count)
            for node in edges.indices {
                for edge in edges[node] where follows(node, edge) && loops[group[edge.target]] {
                    if group[node] != group[edge.target] { return false }
                    inside[group[node]] += 1
                }
            }
            // A loop that is one ring has an edge for each node. With more, where an `id` is
            // shared, a walk from one ring may enter another.
            return groups.indices.allSatisfy { !loops[$0] || inside[$0] == groups[$0].count }
        }

        /// Whether every loop of masks, clip paths and markers is one the renderer ends, and
        /// every chain of nesting and references from the root is within the nesting limit.
        var chainsAreBounded: Bool {
            let follows: (Int, Edge) -> Bool = { _, edge in edge.link != .href }
            let (groups, group) = components(from: CollectionOfOne(0), following: follows)
            /// The deepest chain that starts in each group.
            var depth = Array(repeating: 0, count: groups.count)
            var nesting = Nesting(count: edges.count)
            for (index, members) in groups.enumerated() {
                var within = 0
                if members.count > 1 || edges[members[0]].contains(where: { $0.target == members[0] && follows(members[0], $0) }) {
                    // The members lead to each other. A chain among them ends where the renderer
                    // ends it: at a marker it is already drawing, or where it has unlinked a mask
                    // or clip path. So it takes each marker once, and between two markers each
                    // mask or clip path once, with no more nesting between two references than
                    // the longest run of it there is. More than two masks and clip paths may
                    // make a ring the renderer does not unlink.
                    let unlinked = members.count { names[$0] == "mask" || names[$0] == "clipPath" }
                    guard unlinked <= maximumLoop else { return false }
                    let markers = members.count { names[$0] == "marker" }
                    let references = markers + (markers + 1) * unlinked
                    // Nesting that leads back to itself is a `use` of what holds it.
                    guard let longest = nesting.longest(among: members, of: index, edges: edges, group: group) else { return false }
                    within = (references + 1) * longest + references
                }
                var beyond = 0
                for member in members {
                    for edge in edges[member] where follows(member, edge) && group[edge.target] != index {
                        beyond = max(beyond, edge.link.depth + depth[group[edge.target]])
                    }
                }
                depth[index] = within + beyond
                // The root's group is the last, and leads to every other.
                guard depth[index] <= SVGContent.maximumDepth else { return false }
            }
            return true
        }

        /// The longest run of nesting within one group of nodes that lead to each other.
        private struct Nesting {
            /// 0 for a node not yet seen, 1 for one on the path being followed, 2 for one done.
            private var state: [UInt8]
            private var length: [Int]

            init(count: Int) {
                state = Array(repeating: 0, count: count)
                length = Array(repeating: 0, count: count)
            }

            /// Nil when nesting among `members` leads back to itself.
            mutating func longest(among members: [Int], of index: Int, edges: [[Edge]], group: [Int]) -> Int? {
                var longest = 0
                for start in members where state[start] == 0 {
                    var path = [(node: start, next: 0)]
                    state[start] = 1
                    while let (node, next) = path.last {
                        guard next < edges[node].count else {
                            path.removeLast()
                            state[node] = 2
                            longest = max(longest, length[node])
                            if let (parent, after) = path.last {
                                length[parent] = max(length[parent], edges[parent][after - 1].link.depth + length[node])
                            }
                            continue
                        }
                        path[path.count - 1].next += 1
                        let edge = edges[node][next]
                        guard edge.link.isNesting, group[edge.target] == index else { continue }
                        switch state[edge.target] {
                        case 0:
                            state[edge.target] = 1
                            path.append((edge.target, 0))
                        case 1: return nil
                        default: length[node] = max(length[node], edge.link.depth + length[edge.target])
                        }
                    }
                }
                return longest
            }
        }

        /// The nodes reached from `roots` along the edges `follows` keeps, in groups whose
        /// members all lead to each other, each group after every group it leads to (Tarjan's
        /// strongly connected components, without recursion), and the group of each node.
        private func components(from roots: some Sequence<Int>, following follows: (Int, Edge) -> Bool) -> (groups: [[Int]], group: [Int]) {
            var order = Array(repeating: -1, count: edges.count)
            var low = Array(repeating: 0, count: edges.count)
            var group = Array(repeating: -1, count: edges.count)
            var groups: [[Int]] = []
            var open: [Int] = []
            var path: [(node: Int, next: Int)] = []
            var count = 0
            func enter(_ node: Int) {
                order[node] = count; low[node] = count; count += 1
                open.append(node); path.append((node, 0))
            }
            for root in roots where order[root] < 0 {
                enter(root)
                while let (node, next) = path.last {
                    guard next < edges[node].count else {
                        path.removeLast()
                        if let parent = path.last?.node { low[parent] = min(low[parent], low[node]) }
                        guard low[node] == order[node] else { continue }
                        var members: [Int] = []
                        while let member = open.popLast() {
                            group[member] = groups.count
                            members.append(member)
                            if member == node { break }
                        }
                        groups.append(members)
                        continue
                    }
                    path[path.count - 1].next += 1
                    let edge = edges[node][next]
                    guard follows(node, edge) else { continue }
                    if order[edge.target] < 0 {
                        enter(edge.target)
                    } else if group[edge.target] < 0 {
                        low[node] = min(low[node], order[edge.target])
                    }
                }
            }
            return (groups, group)
        }
    }

    private struct Named: Hashable {
        let id: String
        let role: Role
    }

    static func subjects(of element: ContentNode) -> Set<Subject> {
        var result: Set<Subject> = [.any, .type(element.name)]
        for attribute in element.attributes {
            if attribute.name == "id" { result.insert(.id(attribute.value)) }
            if attribute.name == "class" {
                for name in attribute.value.split(separator: " ") { result.insert(.class(String(name))) }
            }
        }
        return result
    }

    static func references(of element: ContentNode) -> References {
        var result = References()
        for attribute in element.attributes {
            if attribute.name == "style" {
                for declaration in CSSReader.declarations(of: attribute.value) { result.add(declaration.name, declaration.value) }
            } else if attributeNamespaces.contains(attribute.namespace) { result.add(attribute.name, attribute.value) }
        }
        return result
    }

    /// What the last compound selector of a rule asks of an element, as far as it is kept: one
    /// condition of however many, so every element the rule can apply to meets it.
    enum Subject: Hashable {
        case any
        case type(String)
        case `class`(String)
        case id(String)

        /// How few elements meet it: the condition kept is the one that fewest do.
        var rank: Int {
            switch self {
            case .any: 0
            case .type: 1
            case .class: 2
            case .id: 3
            }
        }
    }

    /// CSS as the renderer's parser reads it (simplecss 0.2.2), which is not as a browser does:
    /// one step of it for each step of that parser, so that a rule or a declaration it finds
    /// is found here, where a comment, a quote or a bracket puts the two apart. It knows no
    /// escapes, drops a whole at-rule, takes a selector as far as a stray `/`, and ends a
    /// block at the first declaration it cannot read.
    struct CSSReader {
        /// The selectors of one rule that were read, and the references its block assigns.
        struct Rule {
            var subjects: [Subject]
            var references: References
            var descendants: [Int]
            var selectorBytes: [Int]
            var queriedAttributes: [[String: Int]]
            var declarationBytes: Int
            var copiedBytes: Int
            var declarations: [(name: String, value: String)] = []
        }

        private let text: [UInt8]
        private var position = 0
        private var selectorLimit = Int.max
        private var copyLimit = Int.max

        private init(_ text: String) { self.text = Array(text.utf8) }

        private var current: UInt8? { position < text.count ? text[position] : nil }
        private var following: UInt8? { position + 1 < text.count ? text[position + 1] : nil }
        private func at(_ character: Character) -> Bool { current == character.asciiValue }
        private func string(_ range: Range<Int>) -> String { String(decoding: text[range], as: UTF8.self) }

        /// The rules of a stylesheet that assign a reference.
        static func rules(of sheet: String, referencesOnly: Bool = true, maximumSelectors: Int = Int.max, maximumCopies: Int = Int.max) -> [Rule] {
            var reader = CSSReader(sheet)
            reader.selectorLimit = maximumSelectors
            reader.copyLimit = maximumCopies
            var selectors = 0
            var rules: [Rule] = []
            guard reader.skipSpacesAndComments() else { return rules }
            while reader.current != nil {
                guard reader.skipSpacesAndComments() else { break }
                let start = reader.position
                if reader.at("@") {
                    reader.position += 1
                    reader.atRule()
                } else if let rule = reader.ruleSet(), !rule.subjects.isEmpty, (!referencesOnly || !rule.references.isEmpty) {
                    rules.append(rule)
                    selectors += rule.subjects.count
                    if selectors > maximumSelectors || rule.declarationBytes * rule.subjects.count > maximumCopies { return rules }
                    reader.selectorLimit = maximumSelectors - selectors
                }
                // Every statement that parser reads moves it on; this only guards the loop.
                if reader.position == start { break }
            }
            return rules
        }

        /// The declarations of a `style` attribute, up to the first that cannot be read.
        static func declarations(of style: String, referencesOnly: Bool = true) -> [(name: String, value: String)] {
            var reader = CSSReader(style)
            var found: [(name: String, value: String)] = []
            while true {
                _ = reader.skipSpacesAndComments()
                guard reader.current != nil, let declaration = reader.declaration() else { return found }
                if !referencesOnly || reader.mayReference(declaration.name) { found.append((reader.string(declaration.name), reader.string(declaration.value))) }
            }
        }

        /// Whether a property may be one that references: `mask`, `clip-path` or a marker's.
        private func mayReference(_ name: Range<Int>) -> Bool {
            text[name.lowerBound] == UInt8(ascii: "m") || text[name.lowerBound] == UInt8(ascii: "c")
        }

        private mutating func atRule() {
            guard identifier() != nil else { return }
            while let byte = current, byte != UInt8(ascii: ";"), byte != UInt8(ascii: "{") { position += 1 }
            guard current != nil else { return }
            let block = at("{")
            position += 1
            if block { skipBlock() }
        }

        /// Selectors up to a `{`, and the block that every one of them that was read shares.
        /// Nil where the text ends before a block begins.
        private mutating func ruleSet() -> Rule? {
            var subjects: [Subject] = []
            var descendants: [Int] = []
            var selectorBytes: [Int] = []
            var queriedAttributes: [[String: Int]] = []
            while true {
                guard current != nil else { return nil }
                guard at(",") || subjects.isEmpty else { break }
                if at(",") { position += 1 }
                let start = position
                if let selector = selector() {
                    subjects.append(selector.subject); descendants.append(selector.descendants)
                    selectorBytes.append(max(1, position - start))
                    queriedAttributes.append(selector.attributes)
                    if subjects.count > selectorLimit {
                        return Rule(subjects: subjects, references: References(), descendants: descendants,
                                    selectorBytes: selectorBytes, queriedAttributes: queriedAttributes, declarationBytes: 0, copiedBytes: 0)
                    }
                }
                skipSpaces()
                guard current != nil else { return nil }
                if at("{") { break }
                if at(",") { continue }
                while current != nil, !at("{") { position += 1 }
                break
            }
            if at("{") { position += 1 }
            var references = References()
            var declarationBytes = 0
            var copiedBytes = 0
            var declarations: [(name: String, value: String)] = []
            while current != nil, !at("}") {
                guard let declaration = declaration() else {
                    skipBlock()
                    break
                }
                let name = string(declaration.name)
                declarations.append((name, string(declaration.value)))
                let bytes = 64 + declaration.value.count
                declarationBytes += bytes + declaration.name.count
                if SVGContent.copiedStyleProperties.contains(name), name != "filter" {
                    // usvg expands marker into three attributes and font into up to eighteen.
                    copiedBytes += bytes * (name == "marker" ? 3 : name == "font" ? 18 : 1)
                }
                if mayReference(declaration.name) { references.add(name, string(declaration.value)) }
                if declarationBytes * subjects.count > copyLimit { break }
            }
            if at("}") { position += 1 }
            return Rule(subjects: subjects, references: references, descendants: descendants, selectorBytes: selectorBytes, queriedAttributes: queriedAttributes, declarationBytes: declarationBytes, copiedBytes: copiedBytes, declarations: declarations)
        }

        /// To the end of a block, counting brackets wherever they stand, and past its `}`.
        private mutating func skipBlock() {
            var open = 0
            while let byte = current {
                if byte == UInt8(ascii: "{") {
                    open += 1
                } else if byte == UInt8(ascii: "}") {
                    if open == 0 { break }
                    open -= 1
                }
                position += 1
            }
            if at("}") { position += 1 }
        }

        /// One selector, up to a `,` or `{`; nil where that parser reads none. A failure
        /// leaves the position where it leaves its own.
        private mutating func selector() -> (subject: Subject, descendants: Int, attributes: [String: Int])? {
            var subject: Subject?
            var descendants = 0
            var attributes: [String: Int] = [:]
            /// A selector must follow: at the start, and after a combinator.
            var expectsSelector = true
            /// A combinator was read since the last compound selector.
            var combined = false
            var finished = false
            /// A condition on the compound selector being read, or the first of a new one.
            func condition(_ found: Subject) {
                if combined || found.rank > subject?.rank ?? -1 { subject = found }
                combined = false
            }
            while true {
                guard !finished, let byte = current else { return expectsSelector ? nil : subject.map { ($0, descendants, attributes) } }
                switch Character(Unicode.Scalar(byte)) {
                case "*":
                    guard expectsSelector else { return nil }
                    expectsSelector = false
                    position += 1
                    subject = .any
                    combined = false
                case "#", ".":
                    expectsSelector = false
                    position += 1
                    guard let name = identifier() else { return nil }
                    attributes[byte == UInt8(ascii: "#") ? "id" : "class", default: 0] += 1
                    condition(byte == UInt8(ascii: "#") ? .id(string(name)) : .class(string(name)))
                case "[":
                    expectsSelector = false
                    position += 1
                    guard let attributeName = identifier(), current != nil else { return nil }
                    attributes[string(attributeName), default: 0] += 1
                    if at("=") {
                        position += 1
                        guard quoted() else { return nil }
                    } else if at("~") || at("|") {
                        position += 1
                        guard at("=") else { return nil }
                        position += 1
                        guard quoted() else { return nil }
                    } else if !at("]") {
                        return nil
                    }
                    guard at("]") else { return nil }
                    position += 1
                    condition(.any)
                case ":":
                    expectsSelector = false
                    position += 1
                    guard let name = identifier() else { return nil }
                    if string(name) == "lang" {
                        attributes["lang", default: 0] += 1
                        guard at("(") else { return nil }
                        position += 1
                        let start = position
                        while current != nil, !at(")") { position += 1 }
                        let language = string(start..<position)
                        guard at(")") else { return nil }
                        position += 1
                        guard !language.unicodeScalars.allSatisfy(\.properties.isWhitespace) else { return nil }
                    } else if !["first-child", "link", "visited", "hover", "active", "focus"].contains(string(name)) {
                        return nil
                    }
                    condition(.any)
                case ">", "+":
                    guard !expectsSelector else { return nil }
                    position += 1
                    expectsSelector = true
                    combined = true
                case " ", "\t", "\n", "\r", "\u{C}":
                    skipSpaces()
                    if expectsSelector { continue }
                    while at("/") {
                        guard skipComment() else { return nil }
                        skipSpaces()
                    }
                    if current == nil || at(">") || at("+") || at(",") || at("{") { continue }
                    expectsSelector = true
                    combined = true
                    descendants += 1
                case "/":
                    if following == UInt8(ascii: "*") {
                        guard skipComment() else { return nil }
                    } else {
                        finished = true
                    }
                case ",", "{":
                    finished = true
                default:
                    guard let name = identifier(), expectsSelector else { return nil }
                    expectsSelector = false
                    subject = .type(string(name))
                    combined = false
                }
            }
        }

        /// A declaration's name and value; nil where that parser reads none.
        private mutating func declaration() -> (name: Range<Int>, value: Range<Int>)? {
            guard skipSpacesAndComments() else { return nil }
            if at("*") { position += 1 }
            guard let name = identifier(), skipSpacesAndComments(), at(":") else { return nil }
            position += 1
            guard skipSpacesAndComments() else { return nil }
            let start = position
            var end = position
            while term() {
                end = position
                guard skipSpacesAndComments() else { return nil }
            }
            guard skipSpacesAndComments() else { return nil }
            if at("!") {
                position += 1
                guard skipSpacesAndComments() else { return nil }
                if text[position...].starts(with: "important".utf8) { position += 9 }
            }
            guard skipSpacesAndComments() else { return nil }
            while at(";") {
                position += 1
                guard skipSpacesAndComments() else { return nil }
            }
            // A value of nothing but space is none. No term begins with a space that is ASCII,
            // but one past U+00ED is a name to that parser.
            guard start < end else { return nil }
            if text[start] >= 0x80, string(start..<end).unicodeScalars.allSatisfy(\.properties.isWhitespace) { return nil }
            return (name, start..<end)
        }

        /// One term of a value. A failure may still have moved on, as that parser's does.
        private mutating func term() -> Bool {
            guard let byte = current else { return false }
            switch Character(Unicode.Scalar(byte)) {
            case "#":
                position += 1
                if identifier() == nil {
                    while let digit = current, Character(Unicode.Scalar(digit)).isHexDigit { position += 1 }
                }
            case "+", "-", ".", "0"..."9":
                position += 1
                skipDigits()
                if at(".") {
                    position += 1
                    skipDigits()
                }
                if at("%") { position += 1 } else { _ = identifier() }
            case "'", "\"":
                return quoted()
            case ",":
                position += 1
            default:
                guard identifier() != nil else { return false }
                if at("(") {
                    while current != nil, !at(")") { position += 1 }
                    guard at(")") else { return false }
                    position += 1
                }
            }
            return true
        }

        private mutating func skipDigits() {
            while let byte = current, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") { position += 1 }
        }

        /// A name: letters, digits, `_`, `-` and any character past U+00ED, after one optional
        /// `-` and not starting with a digit or a second `-`. Nil when there is none, with
        /// that first `-` still passed.
        private mutating func identifier() -> Range<Int>? {
            let start = position
            if at("-") { position += 1 }
            var first = true
            while let byte = current {
                let isLetter = byte == UInt8(ascii: "_") || (byte | 0x20 >= UInt8(ascii: "a") && byte | 0x20 <= UInt8(ascii: "z"))
                // The lead byte of two gives its character's upper bits; three or four bytes are past U+07FF.
                let isPastLatin = byte >= 0xE0 || (byte >= 0xC2 && (Int(byte & 0x1F) << 6 | Int((following ?? 0) & 0x3F)) > 237)
                let isDigitOrHyphen = (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "-")
                guard isLetter || isPastLatin || (!first && isDigitOrHyphen) else {
                    if first { return nil }
                    break
                }
                position = min(text.count, position + (byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1))
                first = false
            }
            return position == start ? nil : start..<position
        }

        /// A quoted string, where a quote after `\` does not end it, or else a name.
        private mutating func quoted() -> Bool {
            guard let quote = current else { return false }
            guard quote == UInt8(ascii: "'") || quote == UInt8(ascii: "\"") else { return identifier() != nil }
            var previous = quote
            position += 1
            while let byte = current, byte != quote || previous == UInt8(ascii: "\\") {
                previous = byte
                position += 1
            }
            guard current == quote else { return false }
            position += 1
            return true
        }

        private mutating func skipSpaces() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C { position += 1 }
        }

        /// False at a comment that is not closed.
        private mutating func skipSpacesAndComments() -> Bool {
            skipSpaces()
            while at("/"), following == UInt8(ascii: "*") {
                guard skipComment() else { return false }
                skipSpaces()
            }
            return true
        }

        /// False, with a lone `/` passed, when no comment opens here; false at the end when
        /// one is not closed.
        private mutating func skipComment() -> Bool {
            guard at("/") else { return false }
            position += 1
            guard at("*") else { return false }
            position += 1
            while current != nil, !(at("*") && following == UInt8(ascii: "/")) { position += 1 }
            guard current != nil else { return false }
            position += 2
            return true
        }
    }
}
