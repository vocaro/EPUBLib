@testable import EPUBViewing
import Synchronization
import XCTest

/// `~` over long runs of siblings: what `SiblingSearchMemo` answers and what it tests against the
/// walk of earlier siblings that it shortens there, and against what the selectors say.
final class SiblingSearchMemoTests: XCTestCase {
    func testLongRunsMatchWhatTheSelectorsSay() throws {
        // Forty paragraphs around a `nav`: more earlier siblings than are walked directly.
        let run = { (prefix: String) in (0..<20).map { "<p id=\"\(prefix)\($0)\"><i id=\"\(prefix)i\($0)\">x</i></p>" }.joined() }
        let body = "<h1 id=\"h\">t</h1>" + run("a") + "<nav id=\"n\">n</nav>" + run("b")
        let a = (0..<20).map { "a\($0)" }, b = (0..<20).map { "b\($0)" }
        let inner = b.map { $0.replacingOccurrences(of: "b", with: "bi") }
        let expected: [(String, [String])] = [
            ("nav ~ p", b), ("h1 ~ p", a + b), ("aside ~ p", []), ("p ~ nav", ["n"]), ("p ~ p", Array(a.dropFirst()) + b),
            ("nav ~ p ~ p", Array(b.dropFirst())), ("p ~ nav ~ p", b), ("h1 ~ nav ~ p ~ p ~ p", Array(b.dropFirst(2))),
            ("h1 + p ~ p", Array(a.dropFirst()) + b), ("nav + p ~ p", Array(b.dropFirst())), ("aside + p ~ p", []),
            ("nav ~ p + p", Array(b.dropFirst())), ("body > p ~ p", Array(a.dropFirst()) + b), ("section > p ~ p", []),
            ("html nav ~ p", b), ("section nav ~ p", []), ("nav ~ p > i", inner), ("nav ~ p i", inner), ("aside ~ p i", []),
            (":is(nav ~ p) ~ p", Array(b.dropFirst())), ("p:not(nav ~ p)", a), ("p:not(h1 ~ p)", []),
            (":not(nav ~ p) ~ :not(nav ~ p)", a + ["n"]), ("nav ~ p:nth-last-child(-n+3)", Array(b.suffix(3))),
            ("p:nth-child(2n of nav ~ p)", stride(from: 1, to: 20, by: 2).map { "b\($0)" }),
            ("p:nth-last-child(2 of p ~ nav ~ p)", ["b18"]), (":nth-child(3 of p) ~ p", Array(a.dropFirst(3)) + b),
            ("#a18 ~ p", ["a19"] + b), ("#b18 ~ p", ["b19"]), ("#b19 ~ p", []), ("[id^=b] ~ p", Array(b.dropFirst())),
        ]
        for (selector, ids) in expected {
            XCTAssertEqual(try CSSSyntaxSupport.matched(selector, in: body), ids, selector)
        }
    }

    func testMatchingEqualsTheWalkOverGeneratedDocumentsAndSelectors() throws {
        let compared = try compare(seed: 112, documents: 8, rules: 100)
        XCTAssertEqual(compared.differing, 0)
        XCTAssertEqual(compared.dearer, 0, "No question tests more compounds through the memo than the walk does")
        // Not vacuous: selectors match, and many of the matches are of `~` selectors deep in a run.
        XCTAssertGreaterThan(compared.decisions, 400_000)
        XCTAssertGreaterThan(compared.matches, 8_000)
        XCTAssertGreaterThan(compared.inLongRuns, 1_200)
        XCTAssertLessThan(compared.tested.memo * 3, compared.tested.walk * 2, "And the memo spares a third of them")
    }

    /// Every selector of generated rules against every element of generated documents, by the
    /// walk alone and through a memo used six ways, counting the compounds each question tests.
    /// `matches` counts the walk's matches, `inLongRuns` those of selectors with a `~` at
    /// elements past the direct walk, and `dearer` the questions that tested more than the walk.
    private func compare(seed: UInt64, documents: Int, rules: Int) throws
        -> (decisions: Int, differing: Int, dearer: Int, matches: Int, inLongRuns: Int, tested: (walk: Int, memo: Int)) {
        var generator = Generator(state: seed)
        var decisions = 0, differing = 0, dearer = 0, matches = 0, inLongRuns = 0, tested = (walk: 0, memo: 0)
        for shape in 0..<documents {
            let body = generator.body(shape: shape)
            let css = (0..<rules).map { _ in generator.rule() }.joined(separator: "\n")
            let document = try ContentDocument.parse(Data(StyleTestSupport.xhtml(body: body).utf8), path: "OPS/one.xhtml")
            let index = CSSRuleIndex(sheets: [CSSStyleSheet.parse(css, path: "OPS/one.xhtml")], dark: false)
            let selectors = index.entries.map(\.selector)
            XCTAssertGreaterThan(selectors.count, rules / 2, "Most generated rules are valid")
            let facts = ElementFacts(document)
            let elements = document.nodes.filter(\.isElement).map(\.order)
            let tally = SelectorTally()
            let walk = SelectorMatcher(document: document, facts: facts, tally: tally)
            var cost = [[Int]](repeating: [], count: elements.count)
            let expected = elements.indices.map { position in
                selectors.map { selector in
                    let before = tally.compounds
                    defer { cost[position].append(tally.compounds - before) }
                    return walk.matches(selector, elements[position])
                }
            }
            let expectedEntries = elements.map { index.matching($0, matcher: walk) }
            // As the resolver matches, with no direct walk, forgetting at every third search, and
            // asked from the last element to the first, in no order, and from the last third on.
            let forwards = Array(elements.indices), third = elements.count / 3
            var shuffled = forwards
            for position in shuffled.indices.dropFirst().reversed() { shuffled.swapAt(position, generator.below(position + 1)) }
            let variants: [(name: String, memo: SiblingSearchMemo, order: [Int])] = [
                ("default", SiblingSearchMemo(), forwards), ("always", SiblingSearchMemo(directWalk: 0), forwards),
                ("forgetful", SiblingSearchMemo(directWalk: 0, capacity: 3), forwards),
                ("backwards", SiblingSearchMemo(directWalk: 0), forwards.reversed()), ("shuffled", SiblingSearchMemo(directWalk: 0), shuffled),
                ("late first", SiblingSearchMemo(directWalk: 2), Array(forwards[(2 * third)...] + forwards[..<(2 * third)])),
            ]
            for variant in variants {
                let matcher = SelectorMatcher(document: document, facts: facts, siblingSearches: variant.memo, tally: tally)
                for position in variant.order {
                    let element = elements[position]
                    for (number, selector) in selectors.enumerated() {
                        let before = tally.compounds
                        if matcher.matches(selector, element) != expected[position][number] {
                            if differing == 0 { XCTFail("\(variant.name), document \(shape): selector \(number) of\n\(css)\nat node \(element) of\n\(body)") }
                            differing += 1
                        }
                        tested.memo += tally.compounds - before
                        if tally.compounds - before > cost[position][number] {
                            if dearer == 0 { XCTFail("\(variant.name), document \(shape): selector \(number) of\n\(css)\nat node \(element) tested \(tally.compounds - before) compounds, the walk \(cost[position][number]), of\n\(body)") }
                            dearer += 1
                        }
                    }
                    if index.matching(element, matcher: matcher) != expectedEntries[position] {
                        if differing == 0 { XCTFail("\(variant.name), document \(shape): the rules matching node \(element) of\n\(body)\nunder\n\(css)") }
                        differing += 1
                    }
                }
                decisions += elements.count * selectors.count
                tested.walk += cost.joined().reduce(0, +)
            }
            matches += expected.joined().count(where: { $0 })
            for (position, element) in elements.enumerated() where facts.positions[element] - 1 > SiblingSearchMemo().directWalk {
                inLongRuns += zip(selectors, expected[position]).count(where: { $0.combinators.contains(.subsequentSibling) && $1 })
            }
        }
        return (decisions, differing, dearer, matches, inLongRuns, tested)
    }

    /// The compounds tested in finding the rules that match every element of a document, in
    /// document order or in `order` of the elements' places in it, and how many rules matched.
    private func cost(body: String, css: String, order: [Int]? = nil, memos: [SiblingSearchMemo?]) throws -> [(tested: Int, matched: Int)] {
        let document = try ContentDocument.parse(Data(StyleTestSupport.xhtml(body: body).utf8), path: "OPS/one.xhtml")
        let index = CSSRuleIndex(sheets: [CSSStyleSheet.parse(css, path: "OPS/one.xhtml")], dark: false)
        let facts = ElementFacts(document)
        let elements = document.nodes.filter(\.isElement).map(\.order)
        return memos.map { memo in
            let tally = SelectorTally()
            let matcher = SelectorMatcher(document: document, facts: facts, siblingSearches: memo, tally: tally)
            let matched = (order ?? Array(elements.indices)).reduce(0) { $0 + index.matching(elements[$1], matcher: matcher).count }
            return (tally.compounds, matched)
        }
    }

    func testASearchTheWalkEndsSoonTestsNoMoreThanTheWalk() throws {
        // The walk is quick wherever a match is near the element that asks, however many siblings
        // come before both. A search that began at the parent's first child tested them all, for
        // every selector, and again for every element once the memo had forgotten the search.
        let twenties = { (selector: String, rules: Int) in
            String(repeating: Array(repeating: selector, count: 20).joined(separator: ",") + " { clear: both }\n", count: rules)
        }
        let row = "<tr>" + String(repeating: "<td>x</td>", count: 10) + "<td class=\"x\">x</td><td class=\"y\">x</td></tr>"
        // Thirty levels, each a `b`, nine more siblings and the next level's `div`. No `b` is in
        // anything titled, which fails completely: the walk then ends the search up the ancestors
        // as well, where a search answered only as failing for those siblings went on to every level.
        var levels = String(repeating: "<p>x</p>", count: 5)
        for _ in 0..<30 { levels = "<b>x</b>" + String(repeating: "<i>x</i>", count: 9) + "<div>" + levels + "</div>" }
        let shapes: [(name: String, body: String, css: String, matched: Int, walk: Int)] = [
            ("one late element", String(repeating: "<i>x</i>", count: 3_998) + "<b class=\"x\">x</b><p class=\"y\">x</p>", twenties(".x~.y", 25), 500, 1_000),
            ("more searches than are held", String(repeating: "<i>x</i>", count: 300) + String(repeating: "<b>x</b><p>x</p>", count: 10), twenties("b~p", 10), 2_000, 4_000),
            ("rows of cells", "<table>" + String(repeating: row, count: 200) + "</table>", twenties(".x~.y", 1), 4_000, 8_000),
            ("a search that fails completely", levels, twenties("[title] b ~ div p", 1), 0, 4_300),
        ]
        for shape in shapes {
            // The walk, then as the resolver holds searches, holding few, and holding few of what every walk found.
            let memos = [nil, SiblingSearchMemo(), SiblingSearchMemo(capacity: 64), SiblingSearchMemo(directWalk: 0, capacity: 64)]
            let costs = try cost(body: shape.body, css: shape.css, memos: memos)
            XCTAssertEqual(costs[0].tested, shape.walk, shape.name)
            for (memo, found) in zip(memos, costs) {
                XCTAssertEqual(found.matched, shape.matched, shape.name)
                XCTAssertLessThanOrEqual(found.tested, shape.walk, "\(shape.name), direct walk \(memo?.directWalk ?? -1), capacity \(memo?.capacity ?? 0)")
            }
        }
    }

    func testALongRunIsWalkedOnceWhateverOrderItsElementsAskIn() throws {
        // 1,000 paragraphs under selectors that walk to the first child from every one of them:
        // 500,000 siblings each. One test of each paragraph as the subject and one as a sibling,
        // for either selector, is 4,000, and the elements that walk directly add a few. In any
        // other order an element may test the sibling before it once more: 6,000.
        let body = "<h1>t</h1>" + String(repeating: "<p>x</p>", count: 1_000), css = "nav ~ p { clear: both } h1 ~ p { float: left }"
        let forwards = try cost(body: body, css: css, memos: [nil, SiblingSearchMemo()])
        XCTAssertEqual(forwards.map(\.matched), [1_000, 1_000])
        XCTAssertGreaterThan(forwards[0].tested, 1_000_000)
        XCTAssertLessThan(forwards[1].tested, 4_100)
        // From the last of the 1,005 elements to the first, then scattered: 7,919 shares no factor with 1,005.
        for order in [Array((0..<1_005).reversed()), (0..<1_005).map { $0 * 7_919 % 1_005 }] {
            XCTAssertEqual(Set(order).count, 1_005)
            let found = try cost(body: body, css: css, order: order, memos: [SiblingSearchMemo()])
            XCTAssertEqual(found[0].matched, 1_000)
            XCTAssertLessThan(found[0].tested, 6_100)
        }
    }

    func testWhatWalksFoundOnlyGrowsAndEverythingIsForgottenAtCapacity() {
        let identity = CSSSelectorIdentity()
        let key = { (parent: Int32) in SiblingSearchMemo.Key(selector: ObjectIdentifier(identity), compound: 1, parent: parent) }
        let memo = SiblingSearchMemo(directWalk: 0, capacity: 2)
        XCTAssertEqual(memo.known(key(1)), .init())
        memo.record(.init(clear: 9), for: key(1))
        memo.record(.init(clear: 5), for: key(1))
        XCTAssertEqual(memo.known(key(1)), .init(clear: 9), "A thread that walked fewer children does not undo one that walked more")
        memo.record(.init(match: 40, clear: 7, completely: true), for: key(1))
        XCTAssertEqual(memo.known(key(1)), .init(match: 40, clear: 9, completely: true))
        memo.record(.init(match: 30, clear: 20), for: key(1))
        memo.record(.init(match: 35), for: key(1))
        XCTAssertEqual(memo.known(key(1)), .init(match: 30, clear: 20, completely: true), "The earliest match, and a complete failure stays one")
        memo.record(.init(clear: 2), for: key(2))
        XCTAssertEqual(memo.known(key(1)).clear, 20, "Two entries fit")
        memo.record(.init(clear: 3), for: key(3))
        XCTAssertEqual([1, 2, 3].map { memo.known(key($0)).clear }, [0, 0, 3], "A third makes room by forgetting the rest")
        XCTAssertNotEqual(key(1), SiblingSearchMemo.Key(selector: ObjectIdentifier(CSSSelectorIdentity()), compound: 1, parent: 1))
        // The identity tells two parses of one selector apart without making them unequal.
        let twice = CSSSyntaxSupport.selectors("a ~ b, a ~ b, a b")!
        XCTAssertEqual(twice[0], twice[1])
        XCTAssertFalse(twice[0].identity === twice[1].identity)
        XCTAssertNil(twice[2].identity)
    }

    func testOneResolverStylesALongRunFromManyThreads() throws {
        let body = "<h1>t</h1>" + (0..<400).map { "<p class=\"c\($0 % 3)\">x</p>" }.joined() + "<nav/>" + String(repeating: "<p>x</p>", count: 100)
        let css = "nav ~ p { clear: both } .c1 + .c2 ~ p { float: left } :is(.c0 ~ .c1) ~ p:not(nav ~ p) { text-indent: 3px }"
        let section = StyleTestSupport.xhtml(body: body, css: css)
        let document = try ContentDocument.parse(Data(section.utf8), path: "OPS/one.xhtml")
        let sheets = [CSSStyleSheet.parse(css, path: "OPS/one.xhtml")]
        let typography = NativeTypography(fontSize: 16)
        let expected = StyleTestSupport.styleAll(document, StyleResolver(document: document, stylesheets: sheets, typography: typography))
        let elements = document.nodes.filter(\.isElement)
        XCTAssertEqual(elements.count(where: { expected[$0.order]?.clear == .both }), 100)
        XCTAssertEqual(elements.count(where: { expected[$0.order]?.float == .left }), 497)
        XCTAssertEqual(elements.count(where: { expected[$0.order]?.textIndent == .points(3) }), 398)
        let shared = StyleResolver(document: document, stylesheets: sheets, typography: typography)
        let differing = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: elements.count * 4) { iteration in
            // Each iteration starts somewhere else in the run, so searches overlap in every order.
            let node = elements[(iteration * 37) % elements.count]
            let parent = node.parent.flatMap { expected[$0.order] } ?? shared.initialStyle
            if shared.style(for: node, parent: parent) != expected[node.order] { differing.withLock { $0 += 1 } }
        }
        XCTAssertEqual(differing.withLock { $0 }, 0)
    }
}

/// SplitMix64, so the documents and selectors are the same on every run.
private struct Generator {
    var state: UInt64
    var identifier = 0

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }

    static let names = ["p", "div", "span", "i", "a"]
    static let simple = [
        ".c0", ".c1", ".c2", "#n7", "[title]", "[title=t1]", "[title^=t]", "[title$='2']", "[title*=t]", "[class~=c1]", "[lang|=en]",
        "[TITLE=T1 i]", ":first-child", ":last-child", ":only-child", ":first-of-type", ":last-of-type", ":only-of-type",
        ":nth-child(2n+1)", ":nth-child(-n+3)", ":nth-child(n+19)", ":nth-last-child(3n)", ":nth-last-child(-n+20)", ":nth-of-type(2)",
        ":nth-of-type(n+18)", ":nth-last-of-type(odd)", ":root", ":empty", ":link", ":lang(en)", ":dir(rtl)", ":hover", ":read-only",
    ]

    // MARK: Documents

    private mutating func open(_ name: String) -> String {
        var text = "<\(name)"
        if chance(45) { text += " class=\"c\(below(3))\(chance(25) ? " c\(below(3))" : "")\"" }
        if chance(10) { identifier += 1; text += " id=\"n\(identifier)\"" }
        if chance(15) { text += " title=\"t\(below(3))\"" }
        if chance(5) { text += " lang=\"\(pick(["en", "fr", "en-GB"]))\"" }
        if chance(5) { text += " dir=\"\(pick(["rtl", "ltr"]))\"" }
        if name == "a", chance(60) { text += " href=\"#n1\"" }
        return text + ">"
    }

    private mutating func leaf() -> String {
        let name = pick(Self.names)
        return open(name) + (chance(70) ? "x" : "") + "</\(name)>"
    }

    /// A subtree of at most `budget` elements more; one parent in four holds a run longer than
    /// is walked directly.
    private mutating func tree(depth: Int, budget: inout Int) -> String {
        let name = pick(Self.names)
        var text = open(name)
        if depth > 0 {
            let count = chance(25) ? 10 + below(40) : below(4)
            for _ in 0..<count where budget > 0 {
                budget -= 1
                if chance(15) { text += "t" }
                text += tree(depth: depth - 1, budget: &budget)
            }
        } else if chance(50) {
            text += "x"
        }
        return text + "</\(name)>"
    }

    /// Random trees, one long run, runs inside runs, and a deep chain with siblings at every level.
    mutating func body(shape: Int) -> String {
        identifier = 0
        switch shape % 4 {
        case 0:
            var budget = 120
            return (0..<3).map { _ in tree(depth: 5, budget: &budget) }.joined()
        case 1:
            return (0..<40).map { _ in leaf() }.joined()
        case 2:
            var run = ""
            for _ in 0..<3 {
                let inner = run
                run = (0..<14).map { child in
                    let name = pick(Self.names)
                    return child % 9 == 8 ? open(name) + inner + "</\(name)>" : leaf()
                }.joined()
            }
            return run
        default:
            var text = "x"
            for _ in 0..<30 {
                let name = pick(Self.names)
                let before = (0..<below(4)).map { _ in leaf() }.joined()
                text = before + open(name) + text + "</\(name)>" + (chance(30) ? leaf() : "")
            }
            return text
        }
    }

    // MARK: Selectors

    private mutating func compound(nesting: Int, positions: Bool) -> String {
        var text = chance(55) ? pick(Self.names) : (chance(40) ? "*" : "")
        for _ in 0..<(chance(40) ? 1 + below(2) : 0) {
            guard nesting > 0, chance(35) else { text += pick(Self.simple); continue }
            let kind = below(positions ? 5 : 3)
            // `of` inside `of` is refused, so a list under one holds none.
            let list = (0...below(2)).map { _ in complex(nesting: nesting - 1, positions: positions && kind < 3) }.joined(separator: ", ")
            switch kind {
            case 0: text += ":not(\(list))"
            case 1: text += ":is(\(list))"
            case 2: text += ":where(\(list))"
            case 3: text += ":nth-child(\(pick(["2n", "n+2", "odd", "-n+4", "3"])) of \(list))"
            default: text += ":nth-last-child(\(pick(["2n+1", "n+3", "even", "-n+5", "1"])) of \(list))"
            }
        }
        return text.isEmpty ? "*" : text
    }

    /// Up to four compounds, half of the combinators `~`.
    private mutating func complex(nesting: Int, positions: Bool) -> String {
        var text = compound(nesting: nesting, positions: positions)
        for _ in 0..<below(nesting == 2 ? 4 : 3) {
            text += pick([" ~ ", " ~ ", " ~ ", " + ", " > ", " "]) + compound(nesting: nesting, positions: positions)
        }
        return text
    }

    /// One rule of one or two selectors, now and then with a third that has a pseudo-element.
    mutating func rule() -> String {
        var selectors = [complex(nesting: 2, positions: true)]
        if chance(20) { selectors.append(complex(nesting: 2, positions: true)) }
        if chance(5) { selectors.append(complex(nesting: 1, positions: true) + pick(["::before", ":after", "::first-line"])) }
        return selectors.joined(separator: ", ") + " { clear: both }"
    }
}
