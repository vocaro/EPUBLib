@testable import EPUBViewing
import XCTest

/// Selectors Level 4 grammar, validity and specificity, and matching against XHTML documents.
final class CSSSyntaxSelectorCoverageTests: XCTestCase {
    private func matched(_ selector: String, in body: String, prelude: String = "") throws -> [String] {
        try CSSSyntaxSupport.matched(selector, in: body, prelude: prelude)
    }
    private func isValid(_ selector: String) -> Bool { CSSSyntaxSupport.selectors(selector) != nil }

    /// Text and a comment sit between the element siblings.
    private let family = """
        <div id="d"><h2 id="h">h</h2>text<p id="p1" class="a b">1</p><!-- comment --><p id="p2" class="b">2</p>text<span id="s">s</span><p id="p3" class="A">3</p></div>
        """
    private let list = """
        <ul id="ul"><li id="l1" class="x">a</li>text<li id="l2">b</li><!-- comment --><li id="l3" class="x">c</li><li id="l4" class="x">d</li><li id="l5">e</li></ul>
        <div id="mix"><h3 id="h">h</h3><p id="q1">1</p><p id="q2">2</p><span id="sp">s</span></div><div id="solo">text<p id="only">o</p>text</div>
        """
    private let titles = """
        <p id="t1" title="alpha">1</p><p id="t2" title="alpha beta">2</p><p id="t3" title="alpha-beta">3</p><p id="t4" title="">4</p>
        <p id="t5">5</p><p id="t6" title="ALPHA">6</p><p id="t7" title="betalpha">7</p>
        """

    // MARK: Combinators

    func testCombinatorsSeeOnlyElementsAndTolerateWhitespaceAndComments() throws {
        XCTAssertEqual(try matched("h2 + p", in: family), ["p1"], "Text between siblings does not separate them")
        XCTAssertEqual(try matched("p + p", in: family), ["p2"], "Nor does a comment")
        XCTAssertEqual(try matched("p + span", in: family), ["s"])
        XCTAssertEqual(try matched("span + p", in: family), ["p3"])
        XCTAssertEqual(try matched("p ~ p", in: family), ["p2", "p3"])
        XCTAssertEqual(try matched("h2~p", in: family), ["p1", "p2", "p3"])
        XCTAssertEqual(try matched("div>p+p", in: family), ["p2"])
        XCTAssertEqual(try matched("div\n>\tp /* c */ + /* c */ p", in: family), ["p2"])
        XCTAssertEqual(try matched("h2 + p + p + span", in: family), ["s"])
        XCTAssertEqual(try matched("h2 ~ span ~ p", in: family), ["p3"])
        XCTAssertEqual(try matched("div p ~ span", in: family), ["s"])
        XCTAssertEqual(try matched("html > body > div > h2", in: family), ["h"])
        XCTAssertEqual(try matched("html h2, body > div > .A", in: family), ["h", "p3"])
        XCTAssertEqual(try matched("body > p", in: family), [])
        XCTAssertEqual(try matched("p p", in: family), [])
        XCTAssertEqual(try matched("p + h2", in: family), [], "The adjacent combinator looks backwards only")
        XCTAssertEqual(try matched("span ~ h2", in: family), [])
        XCTAssertEqual(try matched("h2 + p2", in: family), [])
    }

    func testAMisplacedOrUnknownCombinatorInvalidatesTheSelector() {
        for selector in ["> p", "+ p", "~ p", "p >", "p +", "p ~", "p > > p", "p + ~ p", "p >> q", "p || q", "p ! q", "p & q", "p / q",
                         "p,", ", p", "p,,q", ",", "", " ", "p/**/q", "p q/**/i", "p (q)", "p {q}"] {
            XCTAssertFalse(isValid(selector), selector)
        }
        for selector in ["p>q", "p > q", "p\n\n>\n\nq", "p+q~i>b u", "*>*", "p/**/>/**/q", "p /**/ q", " p , q "] {
            XCTAssertTrue(isValid(selector), selector)
        }
    }

    // MARK: Type, class and id

    func testForeignElementNamesMatchExactlyAndATypeSelectorWithoutADefaultNamespaceMatchesAnyNamespace() throws {
        let body = """
            <p id="p">p</p><svg xmlns="http://www.w3.org/2000/svg" id="svg"><linearGradient id="g"/><a id="sa"/></svg><a id="a" href="#p">l</a>
            """
        XCTAssertEqual(try matched("linearGradient", in: body), ["g"])
        XCTAssertEqual(try matched("lineargradient", in: body), [], "SVG names are case-sensitive")
        XCTAssertEqual(try matched("LINEARGRADIENT", in: body), [])
        XCTAssertEqual(try matched("a", in: body), ["sa", "a"])
        XCTAssertEqual(try matched("svg a", in: body), ["sa"])
        XCTAssertEqual(try matched("svg > *", in: body), ["g", "sa"])
        XCTAssertEqual(try matched("body > *", in: body), ["p", "svg", "a"])
    }

    func testClassAndIDSelectorsAreCaseSensitiveAndRepeatable() throws {
        XCTAssertEqual(try matched(".a", in: family), ["p1"])
        XCTAssertEqual(try matched(".A", in: family), ["p3"])
        XCTAssertEqual(try matched(".b", in: family), ["p1", "p2"])
        XCTAssertEqual(try matched(".a.b", in: family), ["p1"])
        XCTAssertEqual(try matched(".b.a", in: family), ["p1"])
        XCTAssertEqual(try matched(".a.a.a", in: family), ["p1"])
        XCTAssertEqual(try matched(".a.A", in: family), [])
        XCTAssertEqual(try matched("#p1", in: family), ["p1"])
        XCTAssertEqual(try matched("#P1", in: family), [])
        XCTAssertEqual(try matched("#p1#p1", in: family), ["p1"])
        XCTAssertEqual(try matched("#p1#p2", in: family), [])
        XCTAssertEqual(try matched("p#p1.a.b", in: family), ["p1"])
        XCTAssertEqual(try matched("div#p1", in: family), [])
        XCTAssertEqual(try matched("*#p1, *.A", in: family), ["p1", "p3"])
    }

    func testEscapedAndNonASCIIClassAndIDNames() throws {
        let body = """
            <p id="1st" class="2col a:b c.d">x</p><p id="x.y" class="café 章 -lead _x">y</p><p id="sp ace" class="a/b @c">z</p>
            """
        XCTAssertEqual(try matched(#"#\31 st"#, in: body), ["1st"])
        XCTAssertEqual(try matched(#".\32 col"#, in: body), ["1st"])
        XCTAssertEqual(try matched(#".a\:b"#, in: body), ["1st"])
        XCTAssertEqual(try matched(#".c\.d"#, in: body), ["1st"])
        XCTAssertEqual(try matched(#"#x\.y"#, in: body), ["x.y"])
        XCTAssertEqual(try matched(".café", in: body), ["x.y"])
        XCTAssertEqual(try matched(#".caf\E9"#, in: body), ["x.y"])
        XCTAssertEqual(try matched(".章", in: body), ["x.y"])
        XCTAssertEqual(try matched(".-lead._x", in: body), ["x.y"])
        XCTAssertEqual(try matched(#"#sp\ ace"#, in: body), ["sp ace"])
        XCTAssertEqual(try matched(#".a\/b.\@c"#, in: body), ["sp ace"])
        XCTAssertEqual(try matched(".c", in: body), [], "An unescaped dot starts another class")
        for selector in ["#1st", ".2col", "p.", "p#", ". a", "# a", ".a:b", "#x.y.", ".-1", "..a", "#"] {
            XCTAssertFalse(isValid(selector), selector)
        }
    }

    func testClassNamesAreSeparatedByASCIIWhitespaceOnly() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/116")
        // Selectors 4 §6.6: `.x` is `[class~=x]`, a whitespace-separated list, and CSS and HTML
        // whitespace is space, tab, line feed, carriage return and form feed.
        let body = #"<p id="ascii" class="a&#9;b&#10;c&#13;d">x</p><p id="nbsp" class="x&#160;y">y</p>"#
        XCTAssertEqual(try matched(".a", in: body), ["ascii"])
        XCTAssertEqual(try matched(".b.c.d", in: body), ["ascii"])
        XCTAssertEqual(try matched("[class~=x]", in: body), [], "A no-break space does not separate tokens")
        XCTAssertEqual(try matched(".x", in: body), [], "The class selector reads the same list as [class~=x]")
        XCTAssertEqual(try matched(#".x\A0 y"#, in: body), ["nbsp"])
    }

    // MARK: Attributes

    func testEveryAttributeOperatorWithQuotedAndUnquotedOperands() throws {
        XCTAssertEqual(try matched("[title]", in: titles), ["t1", "t2", "t3", "t4", "t6", "t7"])
        XCTAssertEqual(try matched("p:not([title])", in: titles), ["t5"])
        for selector in ["[title=alpha]", #"[title="alpha"]"#, "[title='alpha']", "[ title = alpha ]", "[title=\n'alpha'\n]", "p[title=alpha]"] {
            XCTAssertEqual(try matched(selector, in: titles), ["t1"], selector)
        }
        XCTAssertEqual(try matched(#"[title="alpha beta"]"#, in: titles), ["t2"])
        XCTAssertEqual(try matched("[title~=alpha]", in: titles), ["t1", "t2"])
        XCTAssertEqual(try matched("[title~='beta']", in: titles), ["t2"])
        XCTAssertEqual(try matched("[title|=alpha]", in: titles), ["t1", "t3"])
        XCTAssertEqual(try matched("[title|=\"alpha-beta\"]", in: titles), ["t3"])
        XCTAssertEqual(try matched("[title^=alpha]", in: titles), ["t1", "t2", "t3"])
        XCTAssertEqual(try matched("[title$=beta]", in: titles), ["t2", "t3"])
        XCTAssertEqual(try matched("[title$=alpha]", in: titles), ["t1", "t7"])
        XCTAssertEqual(try matched("[title*=lph]", in: titles), ["t1", "t2", "t3", "t7"])
        XCTAssertEqual(try matched("[title*=' ']", in: titles), ["t2"])
        XCTAssertEqual(try matched(#"[title=""]"#, in: titles), ["t4"])
        XCTAssertEqual(try matched("[title^=alpha][title$=beta]", in: titles), ["t2", "t3"])
        XCTAssertEqual(try matched("[id=t1], [id~=t2], [class]", in: titles), ["t1", "t2"])
    }

    func testEmptyOperandsMatchNothingAndCaseFlagsApplyToValues() throws {
        for operation in ["^=", "$=", "*=", "~="] {
            XCTAssertEqual(try matched(#"[title\#(operation)""]"#, in: titles), [], operation)
        }
        XCTAssertEqual(try matched(#"[title~="alpha beta"]"#, in: titles), [], "A ~= operand containing whitespace never matches")
        XCTAssertEqual(try matched("[title=alpha i]", in: titles), ["t1", "t6"])
        XCTAssertEqual(try matched(#"[title="ALPHA"i]"#, in: titles), ["t1", "t6"])
        XCTAssertEqual(try matched("[title=Alpha I]", in: titles), ["t1", "t6"])
        XCTAssertEqual(try matched("[title^=ALP i]", in: titles), ["t1", "t2", "t3", "t6"])
        XCTAssertEqual(try matched("[title~=BETA i]", in: titles), ["t2"])
        XCTAssertEqual(try matched("[title=alpha s]", in: titles), ["t1"])
        XCTAssertEqual(try matched("[title=ALPHA]", in: titles), ["t6"])
    }

    func testAnAttributeNameWithNonASCIICapitalsMatchesAsWritten() throws {
        // XML names are case-sensitive and need not be ASCII: the rule index and the lookup of an
        // element's candidate rules lowercase such a name alike.
        let body = #"<p id="u" data-É="x y">u</p>"#
        XCTAssertEqual(try matched("[data-É]", in: body), ["u"])
        XCTAssertEqual(try matched(#"[data-É="x y"]"#, in: body), ["u"])
        XCTAssertEqual(try matched("[data-É~=y]", in: body), ["u"])
        XCTAssertEqual(try matched("p[data-É^=x]", in: body), ["u"])
    }

    func testMalformedAttributeSelectorsAreInvalid() {
        for selector in ["[]", "[ ]", "[=x]", "[title=]", "[title==x]", "[title~x]", "[title!=x]", "[title=a b]", "[title=x y]", "[title=1]",
                         "[title=1a]", "[1a]", "[title=x i i]", "[title=x q]", "[title x]", "[title=x,]", "[title=#x]", "[title^x]",
                         "[title=(x)]", "[title][", "[*]", "[*=x]", "[|]", "[a|]", "[a||b]"] {
            XCTAssertFalse(isValid(selector), selector)
        }
        for selector in ["[title]", "[title=x]", "[title='']", "[title=x i]", "[title=x s]", "[title=-x]", "[title=--x]", "[data-x=_y]",
                         #"[title=\31 a]"#, "[*|title]", "[|title]", "[title|=x]", "[title~=x][title]",
                         #":root[__ibooks_internal_theme_attribute__*="Night"] p"#] {
            XCTAssertTrue(isValid(selector), selector)
        }
    }

    func testNamespacedAttributeSelectorsNeedADeclaredPrefixAndPlainOnesMeanNoNamespace() throws {
        let body = """
            <aside id="n" epub:type="footnote">n</aside><aside id="r" epub:type="rearnote footnote">r</aside><p id="t" type="footnote">t</p>
            <p id="both" type="plain" epub:type="footnote">b</p><p id="l" xml:lang="fr" lang="en">l</p>
            """
        let epub = #"@namespace epub "http://www.idpf.org/2007/ops"; @namespace xml "http://www.w3.org/XML/1998/namespace";"#
        XCTAssertEqual(try matched("[epub|type]", in: body, prelude: epub), ["n", "r", "both"])
        XCTAssertEqual(try matched("[epub|type~=footnote]", in: body, prelude: epub), ["n", "r", "both"])
        XCTAssertEqual(try matched(#"[epub|type="footnote"]"#, in: body, prelude: epub), ["n", "both"])
        XCTAssertEqual(try matched("[epub|type|=rearnote]", in: body, prelude: epub), [])
        XCTAssertEqual(try matched("[epub|type^=rear]", in: body, prelude: epub), ["r"])
        XCTAssertEqual(try matched("aside[epub|type~=footnote]:not([epub|type~=rearnote])", in: body, prelude: epub), ["n"])
        XCTAssertEqual(try matched("[type]", in: body, prelude: epub), ["t", "both"], "No prefix means no namespace")
        XCTAssertEqual(try matched("[type=footnote]", in: body, prelude: epub), ["t"])
        XCTAssertEqual(try matched("[|type]", in: body, prelude: epub), ["t", "both"])
        XCTAssertEqual(try matched("[*|type]", in: body, prelude: epub), ["n", "r", "t", "both"])
        XCTAssertEqual(try matched("[*|type=footnote]", in: body, prelude: epub), ["n", "t", "both"])
        XCTAssertEqual(try matched("[*|type=plain]", in: body, prelude: epub), ["both"])
        XCTAssertEqual(try matched(#"[epub\:type]"#, in: body, prelude: epub), [], "An XML attribute is never literally named epub:type")
        XCTAssertEqual(try matched(#"[epub\:type~=footnote]"#, in: body, prelude: epub), [])
        XCTAssertEqual(try matched(#"aside[epub\:type="footnote"]"#, in: body, prelude: epub), [])
        XCTAssertEqual(try matched(#"[*|epub\:type]"#, in: body, prelude: epub), [])
        XCTAssertEqual(try matched("[lang=fr]", in: body, prelude: epub), [], "xml:lang is another attribute than lang")
        XCTAssertEqual(try matched("p[lang=en]", in: body, prelude: epub), ["l"])
        XCTAssertEqual(try matched("[xml|lang=fr]", in: body, prelude: epub), ["l"])
        XCTAssertEqual(try matched("[xml|lang|=fr]", in: body, prelude: epub), ["l"])
        // CSS reads only its own @namespace rules, never the document's xmlns:epub.
        XCTAssertEqual(try matched("[epub|type]", in: body), [])
        XCTAssertEqual(try matched("p, [epub|type]", in: body), [], "The undeclared prefix invalidates the whole list")
    }

    func testAnUndeclaredNamespacePrefixInvalidatesItsRuleButIsForgivenInsideIs() {
        let sheet = CSSSyntaxSupport.sheet("""
            @namespace svg "http://www.w3.org/2000/svg";
            p, nope|q { clear: both }
            svg|a, [nope|x] { clear: both }
            nope|* { clear: both }
            :not(nope|p) { clear: both }
            b:nth-child(1 of nope|b) { clear: both }
            svg|circle { clear: both }
            i:is(nope|i, i) { clear: both }
            u:where([nope|x]) { clear: both }
            """)
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["circle", "i", "u"])
        XCTAssertFalse(sheet.truncated, "An invalid selector is not a bound")
    }

    // MARK: Namespaces

    private let foreign = """
        <p id="p">p</p><svg xmlns="http://www.w3.org/2000/svg" id="svg"><a id="sa"/><circle id="c" class="dot"/></svg>
        <a id="a" href="#p" class="dot">l</a><m:math id="m"><m:mi id="mi">x</m:mi></m:math>
        """

    func testNamespacedTypeSelectors() throws {
        let prelude = """
            @namespace svg url(http://www.w3.org/2000/svg); @namespace h "http://www.w3.org/1999/xhtml";
            @namespace m url("http://www.w3.org/1998/Math/MathML");
            """
        XCTAssertEqual(try matched("svg|a", in: foreign, prelude: prelude), ["sa"])
        XCTAssertEqual(try matched("h|a", in: foreign, prelude: prelude), ["a"])
        XCTAssertEqual(try matched("*|a", in: foreign, prelude: prelude), ["sa", "a"])
        XCTAssertEqual(try matched("a", in: foreign, prelude: prelude), ["sa", "a"], "No default namespace: any namespace")
        XCTAssertEqual(try matched("svg|*", in: foreign, prelude: prelude), ["svg", "sa", "c"])
        XCTAssertEqual(try matched("m|*", in: foreign, prelude: prelude), ["m", "mi"])
        XCTAssertEqual(try matched("svg|*.dot", in: foreign, prelude: prelude), ["c"])
        XCTAssertEqual(try matched("*|*.dot", in: foreign, prelude: prelude), ["c", "a"])
        XCTAssertEqual(try matched("h|* > svg|svg > svg|circle", in: foreign, prelude: prelude), ["c"])
        XCTAssertEqual(try matched("|a", in: foreign, prelude: prelude), [], "Every element of an XHTML document has a namespace")
        XCTAssertEqual(try matched("|*", in: foreign, prelude: prelude), [])
        XCTAssertEqual(try matched("svg|p, m|a, h|circle", in: foreign, prelude: prelude), [])
        XCTAssertEqual(CSSSyntaxSupport.specificity("*|*"), [0, 0, 0])
        XCTAssertEqual(CSSSyntaxSupport.specificity("*|a"), [0, 0, 1])
        XCTAssertEqual(CSSSyntaxSupport.specificity("|a.x"), [0, 1, 1])
        for selector in ["svg|", "|", "*|", "a|b|c", "svg| a", "svg|.x", "svg|#x"] {
            XCTAssertNil(CSSSyntaxSupport.selectors(selector, namespaces: CSSNamespaces(prefixes: ["svg": "http://www.w3.org/2000/svg", "a": "u"])),
                         selector)
        }
    }

    func testADefaultNamespaceLimitsTypeUniversalAndTypelessCompounds() throws {
        let prelude = #"@namespace "http://www.w3.org/2000/svg"; @namespace h "http://www.w3.org/1999/xhtml";"#
        XCTAssertEqual(try matched("a", in: foreign, prelude: prelude), ["sa"])
        XCTAssertEqual(try matched("*", in: foreign, prelude: prelude), ["svg", "sa", "c"])
        XCTAssertEqual(try matched(".dot", in: foreign, prelude: prelude), ["c"])
        XCTAssertEqual(try matched("[id]", in: foreign, prelude: prelude), ["svg", "sa", "c"])
        XCTAssertEqual(try matched("#a", in: foreign, prelude: prelude), [])
        XCTAssertEqual(try matched("*|a", in: foreign, prelude: prelude), ["sa", "a"])
        XCTAssertEqual(try matched("*|*.dot", in: foreign, prelude: prelude), ["c", "a"])
        XCTAssertEqual(try matched("h|p", in: foreign, prelude: prelude), ["p"])
        XCTAssertEqual(try matched("h|* > svg", in: foreign, prelude: prelude), ["svg"])
        XCTAssertEqual(try matched("p", in: foreign, prelude: prelude), [])
        XCTAssertEqual(try matched("[class=dot]", in: foreign, prelude: prelude), ["c"], "A default namespace never applies to attribute names")
    }

    func testADefaultNamespaceDoesNotReachInsideNotAndIsWithoutAnExplicitTypeOrUniversal() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/116")
        // Selectors 4 §4.2 and §4.3: "Default namespace declarations do not affect the compound
        // selector representing the subject of any selector within a :is() [:not()] pseudo-class,
        // unless that compound selector contains an explicit universal selector or type selector."
        let prelude = #"@namespace "http://www.w3.org/1999/xhtml"; @namespace svg "http://www.w3.org/2000/svg";"#
        let body = """
            <svg xmlns="http://www.w3.org/2000/svg"><circle id="keep" class="keep"/><circle id="other"/></svg><p id="p" class="keep">p</p>
            """
        XCTAssertEqual(try matched("svg|circle:not(.keep)", in: body, prelude: prelude), ["other"])
        XCTAssertEqual(try matched("svg|circle:is(.keep)", in: body, prelude: prelude), ["keep"])
        XCTAssertEqual(try matched("*|*:is(.keep)", in: body, prelude: prelude), ["keep", "p"])
        XCTAssertEqual(try matched("*|*:is(*.keep)", in: body, prelude: prelude), ["p"], "An explicit universal selector takes the default namespace")
    }

    func testNamespaceRuleFormsRedeclarationAndPlacement() throws {
        let forms = """
            @namespace svg url(http://www.w3.org/2000/svg);
            @NAMESPACE m url("http://www.w3.org/1998/Math/MathML");
            @namespace h 'http://www.w3.org/1999/xhtml';
            @namespace twice "http://www.w3.org/2000/svg";
            @namespace twice "http://www.w3.org/1999/xhtml";
            """
        XCTAssertEqual(try matched("svg|a, m|mi", in: foreign, prelude: forms), ["sa", "mi"])
        XCTAssertEqual(try matched("twice|a", in: foreign, prelude: forms), ["a"], "The last declaration of a prefix wins")
        for malformed in ["@namespace svg;", "@namespace svg bogus;", "@namespace svg \"u\" extra;", "@namespace \"a\" \"b\";",
                          "@namespace svg \"http://www.w3.org/2000/svg\" {}", "@namespace;",
                          "@media screen { @namespace svg \"http://www.w3.org/2000/svg\"; }"] {
            XCTAssertEqual(CSSSyntaxSupport.subjects(CSSSyntaxSupport.sheet("\(malformed) svg|a { clear: both } p { clear: both }")), ["p"], malformed)
        }
        let sheet = CSSSyntaxSupport.sheet(#"@namespace epub "http://www.idpf.org/2007/ops"; @namespace url(http://www.w3.org/1999/xhtml); p { clear: both }"#)
        XCTAssertEqual(sheet.remoteReferences, 0, "A namespace name is not a resource")
        XCTAssertEqual(sheet.imports, [])
    }

    func testANamespaceRuleAfterAStyleRuleIsIgnored() {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/116")
        // CSS Namespaces §3: "Any @namespace rules must follow all @charset and @import rules and
        // precede all other non-ignored at-rules and style rules in a style sheet."
        let sheet = CSSSyntaxSupport.sheet(#"p { clear: both } @namespace svg "http://www.w3.org/2000/svg"; svg|a { clear: both }"#)
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["p"], "The late @namespace declares nothing, so svg|a has an undeclared prefix")
    }

    // MARK: Structural pseudo-classes

    func testChildAndTypePositionsCountOnlyElements() throws {
        XCTAssertEqual(try matched("li:first-child", in: list), ["l1"])
        XCTAssertEqual(try matched("li:last-child", in: list), ["l5"])
        XCTAssertEqual(try matched("li:first-child:last-child", in: list), [])
        XCTAssertEqual(try matched("p:only-child", in: list), ["only"], "Text around an only child does not count")
        XCTAssertEqual(try matched("p:first-child", in: list), ["only"])
        XCTAssertEqual(try matched("#mix > :first-child", in: list), ["h"])
        XCTAssertEqual(try matched("#mix > :last-child", in: list), ["sp"])
        XCTAssertEqual(try matched("p:first-of-type", in: list), ["q1", "only"])
        XCTAssertEqual(try matched("p:last-of-type", in: list), ["q2", "only"])
        XCTAssertEqual(try matched("p:only-of-type", in: list), ["only"])
        XCTAssertEqual(try matched("#mix > :only-of-type", in: list), ["h", "sp"])
        XCTAssertEqual(try matched("#mix > :first-of-type", in: list), ["h", "q1", "sp"])
        XCTAssertEqual(try matched("#mix > :nth-of-type(2)", in: list), ["q2"])
        XCTAssertEqual(try matched("#mix > :nth-last-of-type(2)", in: list), ["q1"])
        XCTAssertEqual(try matched("p:nth-of-type(odd)", in: list), ["q1", "only"])
        XCTAssertEqual(try matched("p:nth-last-of-type(n+2)", in: list), ["q1"])
    }

    func testSameNamedElementsOfDifferentNamespacesAreDifferentTypes() throws {
        let body = """
            <div id="box" xmlns:svg="http://www.w3.org/2000/svg"><a id="a1" href="#x">1</a><svg:a id="s1"/><a id="a2" href="#x">2</a><svg:a id="s2"/></div>
            """
        XCTAssertEqual(try matched("#box > :first-of-type", in: body), ["a1", "s1"])
        XCTAssertEqual(try matched("#box > :last-of-type", in: body), ["a2", "s2"])
        XCTAssertEqual(try matched("#box > :nth-of-type(2)", in: body), ["a2", "s2"])
        XCTAssertEqual(try matched("#box > :nth-child(2)", in: body), ["s1"])
    }

    func testEveryAnPlusBForm() throws {
        func nth(_ expression: String, _ pseudo: String = "nth-child") throws -> [String] { try matched("li:\(pseudo)(\(expression))", in: list) }
        let all = ["l1", "l2", "l3", "l4", "l5"], odd = ["l1", "l3", "l5"], even = ["l2", "l4"]
        for expression in ["odd", "ODD", "2n+1", "2N+1", " 2n + 1 ", "2n\n+\n1", "2n+ 1", "2n +1", "2n-1", "2n - 1", "2n- 1", "-2n+5", "+2n+1"] {
            XCTAssertEqual(try nth(expression), odd, expression)
        }
        for expression in ["even", "Even", "2n", "2n+0", "2n-0", "+2n", "2n+2", "-2n+4"] { XCTAssertEqual(try nth(expression), even, expression) }
        for expression in ["n", "+n", "1n", "n+0", "n+1", "n-10", "1n+0", "N"] { XCTAssertEqual(try nth(expression), all, expression) }
        for expression in ["3", "+3", "0n+3", "0n +3"] { XCTAssertEqual(try nth(expression), ["l3"], expression) }
        for expression in ["0", "-3", "6", "0n", "-n", "-n+0", "-n-1", "5n+6"] { XCTAssertEqual(try nth(expression), [], expression) }
        XCTAssertEqual(try nth("-n+3"), ["l1", "l2", "l3"])
        XCTAssertEqual(try nth("-n + 3"), ["l1", "l2", "l3"])
        XCTAssertEqual(try nth("n+4"), ["l4", "l5"])
        XCTAssertEqual(try nth("3n-1"), ["l2", "l5"])
        XCTAssertEqual(try nth("3n+ 1"), ["l1", "l4"])
        XCTAssertEqual(try nth("2", "nth-last-child"), ["l4"])
        XCTAssertEqual(try nth("-n+2", "nth-last-child"), ["l4", "l5"])
        XCTAssertEqual(try nth("odd", "nth-last-child"), odd)
        XCTAssertEqual(try nth("even", "nth-last-child"), even)
        XCTAssertEqual(try nth("n+5", "nth-last-child"), ["l1"])
        XCTAssertEqual(try nth("2n", "nth-of-type"), even)
        XCTAssertEqual(try nth("-n+2", "nth-last-of-type"), ["l4", "l5"])
        XCTAssertEqual(try matched("li:nth-child(n+2):nth-child(-n+4)", in: list), ["l2", "l3", "l4"])
    }

    func testMalformedAnPlusBIsInvalid() {
        for expression in ["", " ", "2n+", "n n", "2 n", "1.5n", "2n+1.5", "2n+1e0", "n+-1", "n + - 1", "- n", "odd even", "--n", "n1", "\"odd\"",
                           "2n,1", "2n + + 1", "n-", "2n-", "+ 2n", "(2n)", "foo", "2n+1 2", "2px", "n*2", "-", "+", "1 2", "2n 1", "e", "-n-"] {
            for pseudo in ["nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type"] {
                XCTAssertFalse(isValid("li:\(pseudo)(\(expression))"), "\(pseudo)(\(expression))")
            }
        }
        for selector in ["li:nth-child", "li:nth-of-type", "li:first-child()", "li:nth-child(2n of)", "li:nth-of-type(2n of li)", "li:nth-child(of li)"] {
            XCTAssertFalse(isValid(selector), selector)
        }
    }

    func testNthChildOfASelectorListCountsOnlyMatchingSiblings() throws {
        XCTAssertEqual(try matched("li:nth-child(2 of .x)", in: list), ["l3"])
        XCTAssertEqual(try matched("li:nth-child(odd of .x)", in: list), ["l1", "l4"])
        XCTAssertEqual(try matched("li:nth-child(n of .x)", in: list), ["l1", "l3", "l4"])
        XCTAssertEqual(try matched("li:nth-last-child(1 of .x)", in: list), ["l4"])
        XCTAssertEqual(try matched("li:nth-last-child(even of .x, #l5)", in: list), ["l1", "l4"])
        XCTAssertEqual(try matched(":nth-child(1 of li:not(.x))", in: list), ["l2"])
        XCTAssertEqual(try matched("li:nth-child(2 of li)", in: list), ["l2"])
        XCTAssertEqual(try matched("#l2:nth-child(1 of .x)", in: list), [], "An element outside the list has no position in it")
        XCTAssertEqual(CSSSyntaxSupport.specificity("li:nth-child(2 of .x)"), [0, 2, 1])
        XCTAssertEqual(CSSSyntaxSupport.specificity("li:nth-last-child(2 of #a, .x)"), [1, 1, 1])
        XCTAssertEqual(CSSSyntaxSupport.specificity("li:nth-child(2n+1)"), [0, 1, 1])
    }

    // MARK: Logical pseudo-classes

    func testNotIsAndWhereTakeListsNestAndForgiveOnlyWhereTheSpecSays() throws {
        XCTAssertEqual(try matched("li:not(.x)", in: list), ["l2", "l5"])
        XCTAssertEqual(try matched("li:not(.x, #l2)", in: list), ["l5"])
        XCTAssertEqual(try matched("li:not(.x):not(#l2)", in: list), ["l5"])
        XCTAssertEqual(try matched("li:not(:not(.x))", in: list), ["l1", "l3", "l4"])
        XCTAssertEqual(try matched("li:not(:first-child):not(:last-child)", in: list), ["l2", "l3", "l4"])
        XCTAssertEqual(try matched("li:not(ul > .x)", in: list), ["l2", "l5"], "A complex selector is allowed in :not()")
        XCTAssertEqual(try matched("li:not(*)", in: list), [])
        XCTAssertEqual(try matched("li:is(.x, #l5)", in: list), ["l1", "l3", "l4", "l5"])
        XCTAssertEqual(try matched("li:where(.x)", in: list), ["l1", "l3", "l4"])
        XCTAssertEqual(try matched(":is(ul, ol) > li:is(:first-child, :last-child)", in: list), ["l1", "l5"])
        XCTAssertEqual(try matched("li:is(.x + li, #l1)", in: list), ["l1", "l2", "l4", "l5"])
        XCTAssertEqual(try matched("li:is(:where(.x), :not(li))", in: list), ["l1", "l3", "l4"])
        XCTAssertEqual(try matched("li:is()", in: list), [], "An empty :is() is valid and matches nothing")
        XCTAssertEqual(try matched("li:where( )", in: list), [])
        XCTAssertEqual(try matched("li:is(:bogus, .x,, >)", in: list), ["l1", "l3", "l4"])
        for selector in ["li:not()", "li:not( )", "li:not(.x,)", "li:not(:bogus)", "li:not(.x, :bogus)", "li:not", "li:is", "li:not(> p)",
                         "li:not(.x) (", ":not(:is(:not(:is(:not(p)))))"] {
            XCTAssertFalse(isValid(selector), selector)
        }
        XCTAssertTrue(isValid(":not(:is(:not(:is(p))))"), "Four levels of nesting are within the bound")
    }

    func testAPseudoElementInsideIsNeverMatchesTheElementItself() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/116")
        // Selectors 4 §4.2: "Pseudo-elements cannot be represented by the matches-any pseudo-class;
        // they are not valid within :is()." The forgiving list drops that argument.
        XCTAssertEqual(try matched("li:is(.x, li::before)", in: list), ["l1", "l3", "l4"])
        XCTAssertEqual(try matched("li:is(*::before, *::after)", in: list), [])
    }

    func testSpecificityOfEachSelectorForm() {
        let cases: [(String, [UInt32])] = [
            ("*", [0, 0, 0]), ("p", [0, 0, 1]), ("p q", [0, 0, 2]), ("p > q + i ~ b", [0, 0, 4]), (".a", [0, 1, 0]), (".a.a.a", [0, 3, 0]),
            ("#a", [1, 0, 0]), ("#a#b", [2, 0, 0]), ("[a]", [0, 1, 0]), ("[a][b=c i]", [0, 2, 0]), ("p:first-child", [0, 1, 1]),
            ("p:lang(fr)", [0, 1, 1]), ("p:lang(fr, de)", [0, 1, 1]), ("p:dir(rtl)", [0, 1, 1]), ("p:nth-of-type(2n)", [0, 1, 1]),
            ("a:hover", [0, 1, 1]), ("a:link:visited", [0, 2, 1]), (":root", [0, 1, 0]), (":empty", [0, 1, 0]),
            (":not(p)", [0, 0, 1]), (":not(.a, #b)", [1, 0, 0]), (":not(:not(#b))", [1, 0, 0]), ("a:not(:hover)", [0, 1, 1]),
            (":is(.a, p)", [0, 1, 0]), (":is(p, :bogus)", [0, 0, 1]), (":is()", [0, 0, 0]), (":is(#a p, .b)", [1, 0, 1]),
            (":where(#a) .b", [0, 1, 0]), (":where(#a, .b):where(p)", [0, 0, 0]), ("p::first-line", [0, 0, 2]), ("p:before", [0, 0, 2]),
            ("*::before", [0, 0, 1]), ("ul#nav li.active > a:not(.x)", [1, 2, 3]),
        ]
        for (selector, expected) in cases { XCTAssertEqual(CSSSyntaxSupport.specificity(selector), expected, selector) }
    }

    func testTheCascadeUsesTheSpecificityOfIsNotAndWhereArguments() throws {
        let result = try StyleTestSupport.styled(#"<p id="a" class="c">a</p><p id="b" class="c">b</p><p id="c" class="c">c</p><p id="d" class="c">d</p>"#, css: """
            #a:is(#nope, p) { text-align: right } p#a.c.c.c { text-align: left }
            #b:not(#nope) { text-align: right } p#b.c.c.c { text-align: left }
            #c:where(#c.c.c) { text-align: left } #c:where(p) { text-align: left } #c { text-align: right }
            p:nth-child(n of #nope, p) { text-align: right } p#d { text-align: left }
            """)
        XCTAssertEqual(result.style("a").textAlign, .right, ":is() counts its most specific argument even when another matched")
        XCTAssertEqual(result.style("b").textAlign, .right)
        XCTAssertEqual(result.style("c").textAlign, .right, ":where() adds nothing, so order decides among equals")
        XCTAssertEqual(result.style("d").textAlign, .right, ":nth-child(… of S) adds its most specific argument to its own class")
    }

    // MARK: Pseudo-elements

    func testPseudoElementRulesNeverStyleTheirElement() throws {
        let body = #"<p id="p">x</p>"#
        for selector in ["p::before", "p::after", "p::first-letter", "p::first-line", "p:before", "p:after", "p:first-letter", "p:first-line",
                         "p::BEFORE", "p:First-Line", "p::selection", "p::marker", "p::placeholder", "p::before:hover", "*::before", "*|*::after"] {
            XCTAssertEqual(try matched(selector, in: body), [], selector)
            XCTAssertEqual(try matched("\(selector), p.none", in: body), [], selector)
            XCTAssertEqual(try matched("\(selector), #p", in: body), ["p"], "\(selector) leaves the rest of its list valid")
        }
        for selector in ["p::before span", "p::before > span", "p::before.x", "p::before#x", "p::before[x]", "p:: before", "p::", "p:::before",
                         "p: :before", "p::1", "p::\"before\"", "::before p"] {
            XCTAssertFalse(isValid(selector), selector)
        }
    }

    func testAPseudoElementAloneImpliesTheUniversalSelectorAndLeavesItsListValid() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/110")
        // Selectors 4 §3.7: "a pseudo-element immediately follows the compound selector
        // representing its originating element. If this compound selector is omitted, it is
        // assumed to be the universal selector *." Resets written `*, ::before, ::after` rely on it.
        let body = #"<p id="p">x</p><p id="q">y</p>"#
        XCTAssertEqual(try matched("#p, ::before, ::after", in: body), ["p"])
        XCTAssertEqual(try matched("#q, :before", in: body), ["q"])
        XCTAssertEqual(try matched("::selection, ::first-line, p", in: body), ["p", "q"])
        XCTAssertEqual(CSSSyntaxSupport.specificity("::before"), [0, 0, 1])
    }

    func testAnUnknownPseudoElementInvalidatesItsSelectorList() {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/116")
        // Selectors 4 §3.9: UAs must treat as invalid any pseudo-elements "for which they have no
        // usable level of support", and "a selector list containing an invalid selector is invalid".
        XCTAssertEqual(CSSSyntaxSupport.subjects(CSSSyntaxSupport.sheet("p, i::no-such-pseudo-element { clear: both } q { clear: both }")), ["q"])
    }

    // MARK: State, link, root, empty, language and direction

    func testInteractiveStatePseudoClassesAreValidButNeverMatchAndLinksAreUnvisited() throws {
        let body = ##"<a id="link" href="#x">l</a><a id="anchor">a</a><p id="p">p</p><span id="span" href="#x">s</span>"##
        for state in ["hover", "active", "focus", "focus-within", "focus-visible", "visited", "target", "checked", "disabled", "enabled",
                      "indeterminate", "required", "optional", "valid", "invalid", "read-write", "placeholder-shown", "default"] {
            XCTAssertEqual(try matched("*:\(state)", in: body), [], state)
            XCTAssertEqual(try matched("a:\(state), #p", in: body), ["p"], state)
        }
        XCTAssertEqual(try matched(":link", in: body), ["link"])
        XCTAssertEqual(try matched(":any-link", in: body), ["link"])
        XCTAssertEqual(try matched("a:not(:link)", in: body), ["anchor"])
        XCTAssertEqual(try matched("a:link:not(:visited)", in: body), ["link"])
        XCTAssertEqual(try matched("a:LINK, a:Hover", in: body), ["link"], "Pseudo-class names are case-insensitive")
        for selector in ["a:bogus", "a:", "a:1", "a: link", "a:link(", "a:hover()", "a:lang", "a:-moz-any-link", ":"] {
            XCTAssertFalse(isValid(selector), selector)
        }
    }

    func testEmptyIgnoresCommentsAndProcessingInstructionsButNotWhitespaceOrElements() throws {
        let body = """
            <div id="e1"></div><div id="e2"><!-- comment --></div><div id="e3"> </div><div id="e4"><span id="e5"/></div>
            <div id="e6"><![CDATA[]]></div><div id="e7">x</div><br id="e8"/><div id="e9"><?pi data?></div><div id="e10">&#x20;</div>
            <div id="e11"><!-- a --><!-- b --></div><div id="e12"><!-- a -->x</div>
            """
        XCTAssertEqual(try matched("div:empty, span:empty, br:empty", in: body), ["e1", "e2", "e5", "e6", "e8", "e9", "e11"])
        XCTAssertEqual(try matched("div:not(:empty)", in: body), ["e3", "e4", "e7", "e10", "e12"])
    }

    func testRootMatchesOnlyTheDocumentElement() throws {
        let section = """
            <html xmlns="http://www.w3.org/1999/xhtml" id="root"><head><title>T</title><style>
            :root { clear: both } :root > body { clear: both } html:root #inner { clear: both } :root > #other { clear: both }
            body:root, p:root { float: left } :not(:root) > #other { float: right }
            </style></head><body id="body"><p id="inner">x</p><p id="other">y</p></body></html>
            """
        let result = try CSSSyntaxSupport.styled(section: section)
        XCTAssertEqual(CSSSyntaxSupport.marked(result), ["root", "body", "inner"])
        XCTAssertEqual(result.style("body").float, ComputedStyle.Float.none)
        XCTAssertEqual(result.style("other").float, .right)
    }

    func testLangMatchesByPrefixInheritsAndPrefersXMLLang() throws {
        let body = """
            <div id="fr" xml:lang="fr-CA"><p id="frp">x<span id="unknown" lang="">y</span></p><p id="de" lang="de">z</p></div>
            <p id="en">e</p><p id="both" lang="en" xml:lang="ja">b</p><p id="zh" lang="zh-Hant-TW">c</p><p id="upper" lang="EN-GB">u</p>
            """
        XCTAssertEqual(try matched(":lang(fr)", in: body), ["fr", "frp"], "An empty lang stops inheritance; a nested lang replaces it")
        XCTAssertEqual(try matched(":lang(fr-CA)", in: body), ["fr", "frp"])
        XCTAssertEqual(try matched(":lang(FR-ca)", in: body), ["fr", "frp"])
        XCTAssertEqual(try matched(":lang(fr-FR)", in: body), [])
        XCTAssertEqual(try matched(":lang(f)", in: body), [], "A range matches whole subtags")
        XCTAssertEqual(try matched(":lang(de)", in: body), ["de"])
        XCTAssertEqual(try matched("p:lang(en)", in: body), ["en", "upper"], "The document's lang=en is inherited; xml:lang=ja wins over lang=en")
        XCTAssertEqual(try matched(":lang(ja)", in: body), ["both"])
        XCTAssertEqual(try matched(":lang(zh)", in: body), ["zh"])
        XCTAssertEqual(try matched(":lang(zh-Hant)", in: body), ["zh"])
        XCTAssertEqual(try matched(":lang(en-GB)", in: body), ["upper"])
        XCTAssertEqual(try matched(":lang(fr, de)", in: body), ["fr", "frp", "de"])
        XCTAssertEqual(try matched(#":lang("fr")"#, in: body), ["fr", "frp"])
        XCTAssertEqual(try matched("span:lang(fr), span:lang(en)", in: body), [])
        XCTAssertEqual(try matched("div:lang(fr) > p:not(:lang(fr))", in: body), ["de"])
        for selector in [":lang()", ":lang(1)", ":lang(fr de)", ":lang(fr,)", ":lang"] { XCTAssertFalse(isValid(selector), selector) }
    }

    func testDirFollowsTheDirAttributeAndInherits() throws {
        let body = """
            <div id="r" dir="rtl"><p id="rp">x<span id="rs">y</span></p><p id="l" dir="ltr">y</p><p id="upper" dir="RTL">w</p></div><p id="d">z</p>
            """
        XCTAssertEqual(try matched(":dir(rtl)", in: body), ["r", "rp", "rs", "upper"])
        XCTAssertEqual(try matched("p:dir(ltr)", in: body), ["l", "d"])
        XCTAssertEqual(try matched("p:dir( RTL )", in: body), ["rp", "upper"])
        for selector in [":dir()", ":dir(1)", ":dir(\"rtl\")", ":dir"] { XCTAssertFalse(isValid(selector), selector) }
    }

    // MARK: Documents read by the HTML parser

    private func recovered(css: String, linked: Bool) throws -> StyledDocument {
        // No XHTML namespace on the root: the reader retries the section as HTML, where
        // `epub:type` is a plain attribute whose name contains a colon.
        let style = linked ? #"<link rel="stylesheet" href="notes.css"/>"# : "<style>\(css)</style>"
        let section = """
            <html xmlns:epub="http://www.idpf.org/2007/ops"><head><title>T</title>\(style)</head><body>\
            <aside id="note" epub:type="footnote">n</aside><aside id="rear" epub:type="rearnote endnotes">r</aside><p id="p" class="Lead">p</p>\
            <p id="t" type="footnote">t</p></body></html>
            """
        let result = try CSSSyntaxSupport.styled(section: section, files: linked ? ["notes.css": css] : [:])
        XCTAssertTrue(result.document.recoveredAsHTML)
        return result
    }

    func testANamespacedAttributeSelectorMatchesThePrefixedAttributeOfAnHTMLParsedDocument() throws {
        let css = """
            @namespace epub "http://www.idpf.org/2007/ops";
            [epub|type~="footnote"], aside[epub|type^="rear"] { clear: both }
            """
        for linked in [true, false] {
            XCTAssertEqual(CSSSyntaxSupport.marked(try recovered(css: css, linked: linked)), ["note", "rear"], "linked: \(linked)")
        }
    }

    func testAnEscapedColonAttributeSelectorMatchesThePrefixedAttributeOfAnHTMLParsedDocument() throws {
        // In an HTML DOM the attribute's name is literally `epub:type`, so `[epub\:type]` is the
        // selector that addresses it (Selectors 4 §6.1 with an escaped identifier).
        for linked in [true, false] {
            func marked(_ selector: String) throws -> [String] {
                CSSSyntaxSupport.marked(try recovered(css: "\(selector) { clear: both }", linked: linked))
            }
            XCTAssertEqual(try marked(#"aside[epub\:type|="footnote"]"#), ["note"], "A type selector with |=, linked: \(linked)")
            XCTAssertEqual(try marked(#"aside[epub\:type~="footnote"]"#), ["note"], "A type selector with ~=, linked: \(linked)")
            XCTAssertEqual(try marked(#"[epub\:type~="footnote"], [epub\:type="rearnote endnotes"]"#), ["note", "rear"],
                           "Value selectors alone, linked: \(linked)")
            XCTAssertEqual(try marked(#"[epub\:type]"#), ["note", "rear"], "Presence selector, linked: \(linked)")
        }
    }

    func testEveryOperatorOnAnEscapedColonNameMatchesInAnHTMLParsedDocumentAndKeepsTypeApart() throws {
        // Alone, a rule is indexed under the attribute or the value it requires; behind `aside`,
        // under the value for `=` and `~=` and under the type otherwise.
        let cases: [(String, [String])] = [
            (#"[epub\:type]"#, ["note", "rear"]),
            (#"[epub\:type="footnote"]"#, ["note"]),
            (#"[epub\:type~="endnotes"]"#, ["rear"]),
            (#"[epub\:type|="footnote"]"#, ["note"]),
            (#"[epub\:type^="rear"]"#, ["rear"]),
            (#"[epub\:type$="notes"]"#, ["rear"]),
            (#"[epub\:type*="note"]"#, ["note", "rear"]),
            (#"[epub\:type="FOOTNOTE" i]"#, ["note"]),
            (#"[epub\:type~="ENDNOTES" i]"#, ["rear"]),
            (#"[EPUB\:Type~="footnote"]"#, ["note"]),
            (#"[|epub\:type~="footnote"]"#, ["note"]),
            (#"[*|epub\:type~="footnote"]"#, ["note"]),
        ]
        for linked in [true, false] {
            func marked(_ selector: String) throws -> [String] {
                CSSSyntaxSupport.marked(try recovered(css: "\(selector) { clear: both }", linked: linked))
            }
            for (selector, expected) in cases {
                XCTAssertEqual(try marked(selector), expected, "\(selector), linked: \(linked)")
                XCTAssertEqual(try marked("aside\(selector)"), expected, "aside\(selector), linked: \(linked)")
            }
            // `type` and `epub:type` are two attributes, though their rules share a bucket.
            XCTAssertEqual(try marked("[type]"), ["t"], "linked: \(linked)")
            XCTAssertEqual(try marked(#"[type~="footnote"]"#), ["t"], "linked: \(linked)")
            XCTAssertEqual(try marked(#"[type^="rear"]"#), [], "linked: \(linked)")
        }
    }

    func testTypeClassAndCombinatorSelectorsWorkInAnHTMLParsedDocument() throws {
        let css = "ASIDE + aside { clear: both } body > p.Lead { clear: both } p.lead { float: left } html:root > body > aside:first-child { clear: both }"
        for linked in [true, false] {
            let result = try recovered(css: css, linked: linked)
            XCTAssertEqual(CSSSyntaxSupport.marked(result), ["note", "rear", "p"], "linked: \(linked)")
            XCTAssertEqual(result.style("p").float, ComputedStyle.Float.none, "Class names stay case-sensitive")
        }
    }

    func testASelectorListContainingHasStaysValid() throws {
        XCTAssertEqual(try matched("div:has(> table), #p3", in: family), ["p3"])
        XCTAssertTrue(isValid("p:has(+ q, > i)"))
    }
}
