@testable import EPUBViewing
import XCTest

/// Deterministic cost and semantic checks for the stylesheet shape reported in #341.
final class SiblingSearchAdmissionTests: XCTestCase {
    /// The parser permits 256 selectors in one rule. Keep all 70,000 inside its rule bound.
    private func repeated(_ selector: String, count: Int) -> String {
        stride(from: 0, to: count, by: 256).map { start in
            Array(repeating: selector, count: min(256, count - start)).joined(separator: ",") + "{clear:both}"
        }.joined()
    }

    func testSeventyThousandRepeatedSelectorsShareOneSearchAndHaveLinearCost() throws {
        let sheet = CSSStyleSheet.parse(repeated("nav ~ p", count: 70_000), path: "OPS/one.xhtml")
        XCTAssertFalse(sheet.truncated)
        let index = CSSRuleIndex(sheets: [sheet], dark: false)
        XCTAssertEqual(index.entries.count, 70_000)
        XCTAssertFalse(index.stylesTruncated)
        for siblings in [60, 120, 240] {
            let document = try document(String(repeating: "<p>x</p>", count: siblings))
            let memo = SiblingSearchMemo()
            let tally = SelectorTally()
            let matcher = SelectorMatcher(document: document, facts: ElementFacts(document), siblingSearches: memo, tally: tally)
            for node in document.nodes where node.isElement { XCTAssertTrue(index.matching(node.order, matcher: matcher).isEmpty) }
            XCTAssertEqual(memo.entryCount, 1)
            // Positions 1...9 test 1...9 compounds: 45 per rule. Every later position
            // tests its subject and previous sibling. Only the first rule at position 10
            // walks the other eight children before sharing its result with all rules.
            XCTAssertEqual(tally.compounds, 70_000 * (2 * siblings + 27) + 8)
            print("SIBLING341 repeated=70000 siblings=\(siblings) compounds=\(tally.compounds) memo=\(memo.entryCount)")
        }
    }

    func testDistinctSuffixAdmissionCannotSaturateTheMemoAcrossParents() throws {
        let selectors = (0..<70_000).map { ".a\($0)~p" }
        let css = stride(from: 0, to: selectors.count, by: 256).map { start in
            selectors[start..<min(start + 256, selectors.count)].joined(separator: ",") + "{clear:both}"
        }.joined() + "p{font-weight:bold}"
        let sheet = CSSStyleSheet.parse(css, path: "OPS/one.xhtml")
        XCTAssertFalse(sheet.truncated)
        // Two eligible parents reserve two entries per suffix. A genuinely different suffix
        // past 32,768 is omitted as a whole; selectors without a sibling search still apply.
        let index = CSSRuleIndex(sheets: [sheet], dark: false, maximumSiblingSearches: (1 << 16) / 2)
        XCTAssertTrue(index.stylesTruncated)
        XCTAssertEqual(index.entries.count, 32_769)
        let body = String(repeating: "<div>" + String(repeating: "<p>x</p>", count: 12) + "</div>", count: 2)
        let document = try document(body)
        let resolver = StyleResolver(document: document, stylesheets: [sheet], typography: NativeTypography(fontSize: 16))
        XCTAssertTrue(resolver.stylesTruncated)
        let nine = try self.document(String(repeating: "<p>x</p>text<!--between-->", count: 9))
        let shortResolver = StyleResolver(document: nine, stylesheets: [sheet], typography: NativeTypography(fontSize: 16))
        XCTAssertFalse(shortResolver.stylesTruncated, "Nine element children need no memo reservation; text and comments do not count")
        let ten = try self.document(String(repeating: "<p>x</p>text<!--between-->", count: 10))
        let longResolver = StyleResolver(document: ten, stylesheets: [sheet], typography: NativeTypography(fontSize: 16))
        XCTAssertTrue(longResolver.stylesTruncated, "Ten element children reserve one entry per suffix")
        let memo = SiblingSearchMemo()
        let tally = SelectorTally()
        let matcher = SelectorMatcher(document: document, facts: ElementFacts(document), siblingSearches: memo, tally: tally)
        for node in document.nodes where node.isElement {
            XCTAssertEqual(index.matching(node.order, matcher: matcher).count, node.name == "p" ? 1 : 0)
        }
        XCTAssertEqual(memo.entryCount, 1 << 16)
        // Each distinct suffix walks independently once: positions 1...9 cost 45,
        // position 10 costs 10, and 11...12 cost two each, giving 59 per parent.
        // The retained ordinary p rule adds one test for each of the 24 paragraphs.
        XCTAssertEqual(tally.compounds, 32_768 * 2 * (2 * 12 + 35) + 24)
        print("SIBLING341 distinct=70000 parents=2 retained=32768 compounds=\(tally.compounds) memo=\(memo.entryCount)")
        XCTAssertLessThan(css.utf8.count, SectionStyles.maximumSheetBytes)
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body, css: css))
        let request = SectionBuildRequest(publication: publication, spineIndex: 0, typography: NativeTypography(fontSize: 16),
                                          fonts: FontRegistry(publication: publication), rich: PlaceholderRichContent())
        XCTAssertTrue(SectionBuilder.build(request).report.stylesTruncated, "The production build discloses omitted selector rules")
    }

    func testSharedSuffixDifferentSubjectsKeepCascadeAndSpecificity() throws {
        let css = "nav ~ p{color:red} nav ~ .target{color:blue} nav ~ p{font-weight:bold}"
        let body = "<nav/>" + String(repeating: "<p>x</p>", count: 10) + "<p id='target' class='target'>x</p>"
        let index = CSSRuleIndex(sheets: [CSSStyleSheet.parse(css, path: "OPS/one.xhtml")], dark: false, maximumSiblingSearches: 1)
        XCTAssertFalse(index.stylesTruncated)
        let keys = index.entries.map { $0.selector.siblingSearchKey(at: 1, parent: 1)! }
        XCTAssertEqual(Set(keys).count, 1)
        let styled = try StyleTestSupport.styled(body, css: css)
        XCTAssertEqual(styled.style("target").color, StyleTestSupport.color(0, 0, 1))
        XCTAssertEqual(styled.style("target").fontWeight, 700)
    }

    func testNamespaceAndNestedSelectorDifferencesKeepSeparateSearches() throws {
        let css = """
        @namespace h url(http://www.w3.org/1999/xhtml);
        @namespace m url(http://www.w3.org/1998/Math/MathML);
        h|nav ~ p{clear:both} m|nav ~ p{clear:both}
        :is(h|nav) ~ p{clear:both} :not(h|nav) ~ p{clear:both}
        p:is(h|nav ~ p){clear:both} p:is(m|nav ~ p){clear:both}
        p:nth-child(odd of h|nav ~ p){clear:both}
        """
        let sheet = CSSStyleSheet.parse(css, path: "OPS/one.xhtml")
        let index = CSSRuleIndex(sheets: [sheet], dark: false, maximumSiblingSearches: 4)
        XCTAssertFalse(index.stylesTruncated)
        XCTAssertEqual(index.entries.count, 7)
        let body = "<nav/>" + (0..<20).map { "<p id='p\($0)'>x</p>" }.joined()
        let document = try document(body)
        let facts = ElementFacts(document)
        let walk = SelectorMatcher(document: document, facts: facts)
        let memo = SelectorMatcher(document: document, facts: facts, siblingSearches: SiblingSearchMemo())
        for node in document.nodes where node.isElement {
            XCTAssertEqual(index.matching(node.order, matcher: memo), index.matching(node.order, matcher: walk))
        }
        let bounded = CSSRuleIndex(sheets: [sheet], dark: false, maximumSiblingSearches: 1)
        XCTAssertTrue(bounded.stylesTruncated)
        // One h|nav search is shared by the plain, nested :is and nested nth-child forms.
        XCTAssertEqual(bounded.entries.count, 3)
    }

    func testARefusedSelectorDoesNotConsumeAdmissionForLaterRules() {
        let sheet = CSSStyleSheet.parse("""
            a ~ b ~ p{clear:both}
            p:not(a ~ b):is(c ~ d){clear:both}
            a ~ p{font-weight:bold}
            """, path: "OPS/one.xhtml")
        let index = CSSRuleIndex(sheets: [sheet], dark: false, maximumSiblingSearches: 1)
        XCTAssertTrue(index.stylesTruncated)
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries.first?.selector, CSSSyntaxSupport.selectors("a ~ p")?.first,
                       "Refused top-level and nested unions leave their uncommitted identities available")
    }

    func testNoSiblingSearchNeedsNoAdmissionEvenWithZeroRoom() throws {
        let sheet = CSSStyleSheet.parse("p{clear:both} p:not(nav){font-weight:bold}", path: "OPS/one.xhtml")
        let index = CSSRuleIndex(sheets: [sheet], dark: false, maximumSiblingSearches: 0)
        XCTAssertFalse(index.stylesTruncated)
        XCTAssertEqual(index.entries.count, 2)
        let nested = CSSStyleSheet.parse("p:not(nav ~ p){clear:both} p{font-weight:bold}", path: "OPS/one.xhtml")
        let refused = CSSRuleIndex(sheets: [nested], dark: false, maximumSiblingSearches: 0)
        XCTAssertTrue(refused.stylesTruncated)
        XCTAssertEqual(refused.entries.count, 1, "A refused nested search drops its whole selector, including negation")
    }

    private func document(_ body: String) throws -> ContentDocument {
        try ContentDocument.parse(Data(StyleTestSupport.xhtml(body: body).utf8), path: "OPS/one.xhtml")
    }
}
