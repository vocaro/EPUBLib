import EPUBTestSupport
@testable import EPUBViewing
import Synchronization
import XCTest

/// Filtered nth positions share one exact list/parent table, with no silent sibling-count cap.
final class FilteredSiblingPositionTests: XCTestCase {
    private func document(_ body: String) throws -> ContentDocument {
        try ContentDocument.parse(Data(StyleTestSupport.xhtml(body: body).utf8), path: "OPS/one.xhtml")
    }

    private func run(_ count: Int, prefix: String = "p") -> String {
        "<h1>Heading</h1>" + (1...count).map { "text<!--gap--><p id='\(prefix)\($0)' class='c1'>x</p>" }.joined()
    }

    func testTheIssue262StylesMatchAt99910001001AndBeyond() throws {
        let css = "p:nth-child(2n of .c1){clear:both} p:nth-last-child(1 of p){float:left}"
        for count in [999, 1000, 1001, 2001] {
            let styled = try StyleTestSupport.styled(run(count), css: css)
            XCTAssertFalse(styled.resolver.stylesTruncated)
            XCTAssertEqual(CSSSyntaxSupport.marked(styled), stride(from: 2, through: count, by: 2).map { "p\($0)" })
            XCTAssertEqual(styled.document.nodes.compactMap { node in
                node.id.flatMap { styled.styles[node.order]?.float == .left ? $0 : nil }
            }, ["p\(count)"], "nth-last counts only matching element siblings")
        }
    }

    func testCompoundListsDuplicatesAndStructuralReverseCounts() throws {
        let body = "<div><h1 id='h'>x</h1><p id='a' class='x' title='yes'>x</p>text<!--gap-->"
            + "<span id='s'>x</span><p id='b' class='x'>x</p><p id='c' class='x' title='yes'>x</p>"
            + "<p id='d' class='x' title='yes'>x</p><p id='e'>x</p><p id='f' class='x' title='yes'>x</p>"
            + "<i>x</i><i>x</i><i>x</i></div>"
        let checks: [(String, [String])] = [
            ("p:nth-child(2n of p.x[title], #a)", ["c", "f"]),
            ("p:nth-last-child(2 of p.x[title], #a)", ["d"]),
            ("p:nth-last-child(-n+2 of p.x[title])", ["d", "f"]),
            ("p:nth-child(n of .missing)", []),
            ("#b:nth-child(1 of p.x[title])", []),
            ("p:nth-child(2 of p:not([title]))", ["e"]),
        ]
        for (selector, expected) in checks {
            XCTAssertEqual(try CSSSyntaxSupport.matched(selector, in: body), expected, selector)
        }
    }

    func testTablesKeepParentNamespaceAndNestedSiblingContextsSeparateInEveryOrder() throws {
        let body = (0..<4).map { parent in
            "<section class='s\(parent)'><div>" + (0..<36).map { child in
                if child == parent * 7 { return "<nav id='n\(parent)'/>" }
                return "<p id='p\(parent)-\(child)' class='c\(child % 3)'><i id='i\(parent)-\(child)'>x</i></p>"
            }.joined() + "</div><div>" + (0..<24).map { "<p id='q\(parent)-\($0)'>x</p>" }.joined() + "</div></section>"
        }.joined()
        let css = """
        @namespace h url(http://www.w3.org/1999/xhtml);
        @namespace m url(http://www.w3.org/1998/Math/MathML);
        p:nth-child(2n of h|nav ~ p.c1){clear:both}
        p:nth-last-child(2 of h|nav ~ p.c1){float:left}
        p:nth-child(2n of m|nav ~ p.c1){font-weight:bold}
        :is(p:nth-child(odd of section.s2 div > p)) > i{clear:both}
        p:not(:nth-last-child(odd of p.c0)){font-style:italic}
        p:nth-child(3 of p) ~ p > i{float:right}
        """
        let doc = try document(body), facts = ElementFacts(doc)
        let index = CSSRuleIndex(sheets: [CSSStyleSheet.parse(css, path: "OPS/one.xhtml")], dark: false)
        let elements = doc.nodes.filter(\.isElement).map(\.order)
        let reference = SelectorMatcher(document: doc, facts: facts)
        let expected = Dictionary(uniqueKeysWithValues: elements.map { ($0, index.matching($0, matcher: reference)) })
        XCTAssertGreaterThan(expected.values.reduce(0) { $0 + $1.count }, 100, "The comparison exercises matches")
        for order in [elements, Array(elements.reversed()), elements.sorted { ($0 * 37) % 997 < ($1 * 37) % 997 }] {
            let positions = SelectorPositionMemo(document: doc)
            let matcher = SelectorMatcher(document: doc, facts: facts, siblingSearches: SiblingSearchMemo(), selectorPositions: positions)
            for element in order { XCTAssertEqual(index.matching(element, matcher: matcher), expected[element]) }
            XCTAssertGreaterThan(positions.entryCount, 8, "Different parents and list values have distinct tables")
        }
    }

    func testDifferentAnBAndDirectionsShareTheFilterWhileCascadeKeepsSpecificity() throws {
        let doc = try document(run(30)), facts = ElementFacts(doc)
        let css = """
        p:nth-child(2n of .c1){color:red}
        p:nth-last-child(1 of .c1){font-weight:bold}
        .c1:nth-child(3n of .c1){color:blue}
        #p30{color:green}
        """
        let sheet = CSSStyleSheet.parse(css, path: "OPS/one.xhtml")
        let index = CSSRuleIndex(sheets: [sheet], dark: false, maximumSelectorPositionFilters: 1)
        XCTAssertFalse(index.stylesTruncated)
        let positions = SelectorPositionMemo(document: doc)
        let matcher = SelectorMatcher(document: doc, facts: facts, selectorPositions: positions)
        for node in doc.nodes where node.isElement { _ = index.matching(node.order, matcher: matcher) }
        XCTAssertEqual(positions.entryCount, 1)
        XCTAssertEqual(positions.cellCount, 31)
        let styled = try StyleTestSupport.styled(run(30), css: css)
        XCTAssertEqual(styled.style("p6").color, StyleTestSupport.color(0, 0, 1), "The class subject raises specificity")
        XCTAssertEqual(styled.style("p30").color, StyleTestSupport.color(0, 128 / 255, 0), "The id selector still wins")
        XCTAssertEqual(styled.style("p30").fontWeight, 700)
    }

    func testFilterAdmissionIsTransactionalAndCannotEvictRetainedTables() throws {
        let css = """
        p:nth-child(n of .a):nth-child(n of .b){clear:both}
        nav ~ p:nth-child(n of .a){clear:both}
        p:nth-last-child(n of .b){float:left}
        p{font-weight:bold}
        """
        let sheet = CSSStyleSheet.parse(css, path: "OPS/one.xhtml")
        let index = CSSRuleIndex(sheets: [sheet], dark: false, maximumSiblingSearches: 0, maximumSelectorPositionFilters: 1)
        XCTAssertTrue(index.stylesTruncated)
        XCTAssertEqual(index.entries.count, 2, "Both rejected selectors leave their filter reservations uncommitted")
        let doc = try document(run(20)), facts = ElementFacts(doc)
        let positions = SelectorPositionMemo(document: doc, capacity: 21)
        let matcher = SelectorMatcher(document: doc, facts: facts, selectorPositions: positions)
        for node in doc.nodes where node.isElement { _ = index.matching(node.order, matcher: matcher) }
        XCTAssertEqual(positions.entryCount, 1)
        XCTAssertEqual(positions.cellCount, 21)
        // A manual matcher lacking production admission can decline caching, never correctness.
        let uncached = SelectorMatcher(document: doc, facts: facts, selectorPositions: SelectorPositionMemo(document: doc, capacity: 0))
        for node in doc.nodes where node.isElement { XCTAssertEqual(index.matching(node.order, matcher: uncached), index.matching(node.order, matcher: matcher)) }
    }

    func testProductionFilterCapacityDisclosesOmittedRules() throws {
        let count = 1001
        let filters = SelectorPositionMemo.defaultCapacity / (count + 1)
        let css = (0...filters).map { "p:nth-child(n of .f\($0)){clear:both}" }.joined() + "p{font-weight:bold}"
        let doc = try document(run(count))
        let sheet = CSSStyleSheet.parse(css, path: "OPS/one.xhtml")
        XCTAssertFalse(sheet.truncated)
        let resolver = StyleResolver(document: doc, stylesheets: [sheet], typography: NativeTypography(fontSize: 16))
        XCTAssertTrue(resolver.stylesTruncated, "Unadmitted filters are disclosed instead of repeatedly rescanned")
        XCTAssertEqual(resolver.style(for: try XCTUnwrap(doc.element(id: "p1001")), parent: resolver.initialStyle).fontWeight, 700)
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: run(count), css: css))
        let request = SectionBuildRequest(publication: publication, spineIndex: 0, typography: NativeTypography(fontSize: 16),
                                          fonts: FontRegistry(publication: publication), rich: PlaceholderRichContent())
        XCTAssertTrue(SectionBuilder.build(request).report.stylesTruncated)
    }

    func testMemoNeverUsesRanksFromAnotherDocument() throws {
        let first = try document(run(20))
        let other = try document("<h1>x</h1>" + (1...20).map { "<p id='p\($0)' class='\($0 % 3 == 0 ? "c1" : "other")'>x</p>" }.joined())
        let selector = try XCTUnwrap(CSSSyntaxSupport.selectors("p:nth-child(2n of .c1)")?.first)
        let memo = SelectorPositionMemo(document: first)
        let warm = SelectorMatcher(document: first, facts: ElementFacts(first), selectorPositions: memo)
        for node in first.nodes where node.isElement { _ = warm.matches(selector, node.order) }
        let reused = SelectorMatcher(document: other, facts: ElementFacts(other), selectorPositions: memo)
        let reference = SelectorMatcher(document: other, facts: ElementFacts(other))
        for node in other.nodes where node.isElement { XCTAssertEqual(reused.matches(selector, node.order), reference.matches(selector, node.order)) }
        XCTAssertEqual(memo.entryCount, 1)
    }

    private func cost(_ count: Int, innerSibling: Bool) throws -> (cpu: Double, compounds: Int, matches: Int) {
        let doc = try document(run(count)), facts = ElementFacts(doc)
        let filter = innerSibling ? "h1 ~ p.c1[id]" : "p.c1[id]"
        let css = (1...10).map { "p:nth-child(\($0)n of \(filter)){clear:both}" }.joined()
            + "p:nth-last-child(1 of \(filter)){float:left}"
        let index = CSSRuleIndex(sheets: [CSSStyleSheet.parse(css, path: "OPS/one.xhtml")], dark: false)
        let elements = doc.nodes.filter { $0.name == "p" }.map(\.order)
        let expected = (1...10).reduce(1) { $0 + count / $1 }
        var samples: [Double] = [], compounds = 0, matches = 0
        for _ in 0..<3 {
            let tally = SelectorTally()
            let cpu = TestCPUClock.measure {
                for _ in 0..<8 {
                    let positions = SelectorPositionMemo(document: doc)
                    let matcher = SelectorMatcher(document: doc, facts: facts, siblingSearches: SiblingSearchMemo(), selectorPositions: positions, tally: tally)
                    matches = elements.reduce(0) { $0 + index.matching($1, matcher: matcher).count }
                    XCTAssertEqual(positions.entryCount, 1, "Ten patterns and two directions share the filter")
                }
            }
            XCTAssertEqual(matches, expected)
            samples.append(cpu)
            compounds = tally.compounds
        }
        return (samples.sorted()[1], compounds, matches)
    }

    func testFilteredSiblingMatchingHasLinearCompoundAndThreadCPUGrowth() throws {
        for innerSibling in [false, true] {
            let small = try cost(500, innerSibling: innerSibling), large = try cost(2000, innerSibling: innerSibling)
            XCTAssertGreaterThan(small.compounds, 0)
            XCTAssertLessThan(Double(large.compounds) / Double(small.compounds), 4.5,
                              "Four times the siblings must not square the matching work")
            XCTAssertLessThan(large.cpu / small.cpu, 6,
                              "Thread CPU ratio permits scheduling-independent noise while excluding quadratic growth")
            print("FILTERED262 innerSibling=\(innerSibling) smallCPU=\(small.cpu) largeCPU=\(large.cpu) ratio=\(large.cpu / small.cpu) compounds=\(small.compounds)/\(large.compounds)")
        }
    }

    func testOneResolverStylesFilteredPositionsConcurrently() throws {
        let body = "<div>" + run(1001) + "</div><div>" + run(1001, prefix: "q") + "</div>"
        let css = "p:nth-child(2n of h1 ~ p.c1){clear:both} p:nth-last-child(1 of p.c1){float:left}"
        let doc = try document(body), sheets = [CSSStyleSheet.parse(css, path: "OPS/one.xhtml")]
        let expected = StyleTestSupport.styleAll(doc, StyleResolver(document: doc, stylesheets: sheets, typography: NativeTypography(fontSize: 16)))
        let shared = StyleResolver(document: doc, stylesheets: sheets, typography: NativeTypography(fontSize: 16))
        let elements = doc.nodes.filter(\.isElement), differing = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: elements.count * 2) { iteration in
            let node = elements[(iteration * 37) % elements.count]
            let parent = node.parent.flatMap { expected[$0.order] } ?? shared.initialStyle
            if shared.style(for: node, parent: parent) != expected[node.order] { differing.withLock { $0 += 1 } }
        }
        XCTAssertEqual(differing.withLock { $0 }, 0)
    }
}
