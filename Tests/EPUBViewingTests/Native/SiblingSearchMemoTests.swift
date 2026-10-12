@testable import EPUBViewing
import Synchronization
import XCTest

/// `~` over long runs of siblings: what `SiblingSearchMemo` answers against the walk of earlier
/// siblings that it replaces there, and against what the selectors say.
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
        // Not vacuous: selectors match, and many of the matches are of `~` selectors deep in a run.
        XCTAssertGreaterThan(compared.decisions, 250_000)
        XCTAssertGreaterThan(compared.matches, 8_000)
        XCTAssertGreaterThan(compared.inLongRuns, 1_200)
    }

    /// Every selector of generated rules against every element of generated documents, by the
    /// walk alone and through a memo used four ways. `matches` counts the walk's matches, and
    /// `inLongRuns` those of selectors with a `~` at elements past the direct walk.
    private func compare(seed: UInt64, documents: Int, rules: Int) throws -> (decisions: Int, differing: Int, matches: Int, inLongRuns: Int) {
        var generator = Generator(state: seed)
        var decisions = 0, differing = 0, matches = 0, inLongRuns = 0
        for shape in 0..<documents {
            let body = generator.body(shape: shape)
            let css = (0..<rules).map { _ in generator.rule() }.joined(separator: "\n")
            let document = try ContentDocument.parse(Data(StyleTestSupport.xhtml(body: body).utf8), path: "OPS/one.xhtml")
            let index = CSSRuleIndex(sheets: [CSSStyleSheet.parse(css, path: "OPS/one.xhtml")], dark: false)
            let selectors = index.entries.map(\.selector)
            XCTAssertGreaterThan(selectors.count, rules / 2, "Most generated rules are valid")
            let facts = ElementFacts(document)
            let elements = document.nodes.filter(\.isElement).map(\.order)
            let walk = SelectorMatcher(document: document, facts: facts)
            let expected = elements.map { element in selectors.map { walk.matches($0, element) } }
            let expectedEntries = elements.map { index.matching($0, matcher: walk) }
            // As the resolver matches, with no direct walk, forgetting at every third search, and
            // asked from the last element to the first.
            let variants: [(name: String, memo: SiblingSearchMemo, backwards: Bool)] = [
                ("default", SiblingSearchMemo(), false), ("always", SiblingSearchMemo(directWalk: 0), false),
                ("forgetful", SiblingSearchMemo(directWalk: 0, capacity: 3), false), ("backwards", SiblingSearchMemo(directWalk: 0), true),
            ]
            for variant in variants {
                let matcher = SelectorMatcher(document: document, facts: facts, siblingSearches: variant.memo)
                for position in variant.backwards ? Array(elements.indices.reversed()) : Array(elements.indices) {
                    let element = elements[position]
                    for (number, selector) in selectors.enumerated() where matcher.matches(selector, element) != expected[position][number] {
                        if differing == 0 { XCTFail("\(variant.name), document \(shape): selector \(number) of\n\(css)\nat node \(element) of\n\(body)") }
                        differing += 1
                    }
                    if index.matching(element, matcher: matcher) != expectedEntries[position] {
                        if differing == 0 { XCTFail("\(variant.name), document \(shape): the rules matching node \(element) of\n\(body)\nunder\n\(css)") }
                        differing += 1
                    }
                }
                decisions += elements.count * selectors.count
            }
            matches += expected.joined().count(where: { $0 })
            for (position, element) in elements.enumerated() where facts.positions[element] - 1 > SiblingSearchMemo().directWalk {
                inLongRuns += zip(selectors, expected[position]).count(where: { $0.combinators.contains(.subsequentSibling) && $1 })
            }
        }
        return (decisions, differing, matches, inLongRuns)
    }

    func testTheFurtherProgressIsKeptAndEverythingIsForgottenAtCapacity() {
        let identity = CSSSelectorIdentity()
        let key = { (parent: Int32) in SiblingSearchMemo.Key(selector: ObjectIdentifier(identity), compound: 1, parent: parent) }
        let memo = SiblingSearchMemo(directWalk: 0, capacity: 2)
        XCTAssertEqual(memo.progress(key(1)).tested, 0)
        memo.record(.init(next: 9, tested: 5, first: 0), for: key(1))
        memo.record(.init(next: 4, tested: 3, first: 0), for: key(1))
        XCTAssertEqual(memo.progress(key(1)).next, 9, "A thread that tested fewer children does not undo one that tested more")
        memo.record(.init(next: 12, tested: 7, first: 7), for: key(1))
        XCTAssertEqual(memo.progress(key(1)).first, 7)
        memo.record(.init(next: 2, tested: 2, first: 0), for: key(2))
        XCTAssertEqual(memo.progress(key(1)).tested, 7, "Two entries fit")
        memo.record(.init(next: 3, tested: 3, first: 0), for: key(3))
        XCTAssertEqual([1, 2, 3].map { memo.progress(key($0)).tested }, [0, 0, 3], "A third makes room by forgetting the rest")
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
