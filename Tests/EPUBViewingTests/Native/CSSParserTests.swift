@testable import EPUBViewing
import XCTest

final class CSSParserTests: XCTestCase {
    private func tokens(_ text: String) -> [CSSToken] {
        var tokenizer = CSSTokenizer(text)
        return tokenizer.tokens().filter { $0 != .whitespace }
    }

    func testTokenizerHandlesEscapesStringsURLsAndComments() {
        XCTAssertEqual(tokens(#".a\31 b /* note */ "x\"y" 'unterminated"#),
                       [.delim("."), .ident("a1b"), .string("x\"y"), .string("unterminated")])
        XCTAssertEqual(tokens("url( fonts/a b.ttf ) url(\"q.css\") url(x(y)"),
                       [.badURL, .function("url"), .string("q.css"), .closeParen, .badURL])
        XCTAssertEqual(tokens("1.5em -2px +.5 10% 3e2 #fff #1a u+"),
                       [.dimension(1.5, unit: "em", isInteger: false, signed: false),
                        .dimension(-2, unit: "px", isInteger: true, signed: true),
                        .number(0.5, isInteger: false, signed: true), .percentage(10),
                        .number(300, isInteger: false, signed: false),
                        .hash("fff", isID: true), .hash("1a", isID: false), .ident("u"), .delim("+")])
        XCTAssertEqual(tokens("\"broken\nnext"), [.badString, .ident("next")])
        XCTAssertEqual(tokens("<!-- a --> \\0 \\110000"), [.cdo, .ident("a"), .cdc, .ident("\u{FFFD}\u{FFFD}")])
    }

    func testDeclarationsRecoverFromErrors() {
        var truncated = false
        let block = CSSParser.components("color: red; width: ; margin: 1px 2px !important; @media x { a: b } font-weight: bold; nested { a: b } float: left",
                                         truncated: &truncated)
        let declarations = CSSParser.declarations(block)
        XCTAssertEqual(declarations.map(\.name), ["color", "width", "margin", "font-weight", "float"])
        XCTAssertEqual(declarations.map(\.important), [false, false, true, false, false])
        let sheet = CSSStyleSheet.parse("""
            p { color: blue; color: rgb(300 0); text-align: middle; }
            @unknown foo { p { color: red } }
            p { font-weight: bold
            """, path: "a.css")
        XCTAssertEqual(sheet.rules.count, 2)
        XCTAssertEqual(sheet.rules[0].declarations.map(\.property), [.color])
        XCTAssertEqual(sheet.rules[1].declarations, [CSSDeclaration(property: .fontWeight, value: .fontWeight(.absolute(700)), important: false)])
    }

    func testInvalidSelectorsDropTheirRule() {
        let sheet = CSSStyleSheet.parse("""
            p, :unknown-state { color: red }
            p::before, q:after { color: red }
            p, q::first-line { color: blue }
            :is(p, :bogus) { color: green }
            undeclared|p { color: red }
            p:nth-child(2n+1 of .x) {}
            """, path: "a.css")
        XCTAssertEqual(sheet.rules.count, 2)
        XCTAssertEqual(sheet.rules[0].selectors.count, 1, "A pseudo-element selector never matches")
        guard case .pseudo(.matchesAny(let list)) = sheet.rules[1].selectors[0].compounds[0].simple[0] else { return XCTFail() }
        XCTAssertEqual(list.count, 1, ":is() forgives an invalid argument")
    }

    func testSpecificity() throws {
        func specificity(_ text: String) throws -> UInt32 {
            var truncated = false
            return try CSSSelectorParser(namespaces: CSSNamespaces()).parseList(CSSParser.components(text, truncated: &truncated))[0].specificity
        }
        func packed(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 { a << 20 | b << 10 | c }
        XCTAssertEqual(try specificity("*"), 0)
        XCTAssertEqual(try specificity("li"), packed(0, 0, 1))
        XCTAssertEqual(try specificity("ul ol+li"), packed(0, 0, 3))
        XCTAssertEqual(try specificity("h1 + *[rel=up]"), packed(0, 1, 1))
        XCTAssertEqual(try specificity("ul ol li.red"), packed(0, 1, 3))
        XCTAssertEqual(try specificity("li.red.level"), packed(0, 2, 1))
        XCTAssertEqual(try specificity("#x34y"), packed(1, 0, 0))
        XCTAssertEqual(try specificity("#s12:not(FOO)"), packed(1, 0, 1))
        XCTAssertEqual(try specificity(":is(#a, .b) p"), packed(1, 0, 1))
        XCTAssertEqual(try specificity(":where(#a, .b) p"), packed(0, 0, 1))
        XCTAssertEqual(try specificity("p:nth-child(2n of .x)"), packed(0, 2, 1))
        XCTAssertEqual(try specificity("a::before"), packed(0, 0, 2))
    }

    func testAnB() {
        func parse(_ text: String) -> [Int]? {
            var truncated = false
            return CSSSelectorParser.parseAnB(CSSParser.components(text, truncated: &truncated).significant).map { [$0.0, $0.1] }
        }
        XCTAssertEqual(parse("odd"), [2, 1])
        XCTAssertEqual(parse("EVEN"), [2, 0])
        XCTAssertEqual(parse("3"), [0, 3])
        XCTAssertEqual(parse("-n+3"), [-1, 3])
        XCTAssertEqual(parse("2n+1"), [2, 1])
        XCTAssertEqual(parse("2n - 1"), [2, -1])
        XCTAssertEqual(parse("2n-1"), [2, -1])
        XCTAssertEqual(parse("+n"), [1, 0])
        XCTAssertEqual(parse("-n-2"), [-1, -2])
        XCTAssertEqual(parse("n- 4"), [1, -4])
        XCTAssertNil(parse("2n + -1"))
        XCTAssertNil(parse("n2"))
    }

    func testSelectorComplexityIsBounded() {
        let deep = (0..<40).map { "a\($0)" }.joined(separator: " ")
        let nested = String(repeating: ":not(", count: 8) + "p" + String(repeating: ")", count: 8)
        let many = (0..<300).map { "p\($0)" }.joined(separator: ", ")
        for selector in [deep, nested, many] {
            let sheet = CSSStyleSheet.parse("\(selector) { color: red }", path: "a.css")
            XCTAssertTrue(sheet.rules.isEmpty)
            XCTAssertTrue(sheet.truncated)
        }
        let blocks = String(repeating: "(", count: 10_000)
        XCTAssertTrue(CSSStyleSheet.parse("p { color: \(blocks) }", path: "a.css").truncated)
    }

    func testMediaQueries() {
        func mask(_ query: String) -> CSSMediaMask { CSSMedia.mask(query) }
        XCTAssertEqual(mask(""), .all)
        XCTAssertEqual(mask("screen"), .all)
        XCTAssertEqual(mask("all and (min-width: 30em)"), .all)
        XCTAssertEqual(mask("print"), [])
        XCTAssertEqual(mask("amzn-kf8"), [])
        XCTAssertEqual(mask("print, handheld"), [])
        XCTAssertEqual(mask("not print"), .all)
        XCTAssertEqual(mask("all and (prefers-color-scheme: dark)"), .dark)
        XCTAssertEqual(mask("(prefers-color-scheme: light)"), .light)
        XCTAssertEqual(mask("all and (prefers-color-scheme)"), .all)
        XCTAssertEqual(mask("(max-width: 400px)"), [])
        XCTAssertEqual(mask("(400px <= width <= 700px)"), .all)
        XCTAssertEqual(mask("(width > 600px)"), [])
        XCTAssertEqual(mask("(orientation: portrait) and (min-resolution: 2dppx)"), .all)
        XCTAssertEqual(mask("not (color)"), [])
        XCTAssertEqual(mask("(scripting: none)"), .all)
        XCTAssertEqual(mask("screen and (bogus-feature)"), [])
        XCTAssertEqual(mask("garbage!"), [])
    }

    func testConditionalRules() {
        let sheet = CSSStyleSheet.parse("""
            @charset "utf-8";
            @import url(early.css) screen;
            @import "print.css" print;
            @import url(http://example.com/remote.css);
            @supports (font-size: 0) { a { color: red } }
            @import url(late.css);
            @supports not (display: flex) { b { color: red } }
            @supports (unknown-property: 1) or (hyphens: auto) { i { color: red } }
            @supports selector(p > q) { q { color: red } }
            @media print { s { color: red } }
            @media screen { @media (prefers-color-scheme: dark) { u { color: red } } }
            @page { margin: 0 }
            @keyframes k { from { color: red } }
            @layer base { em { color: red } }
            """, path: "css/a.css")
        XCTAssertEqual(sheet.imports, [CSSImport(path: "css/early.css", media: .all)], "@import after other rules is ignored")
        XCTAssertEqual(sheet.remoteReferences, 1)
        XCTAssertEqual(sheet.rules.map { $0.selectors[0].compounds[0].name }, ["a", "i", "q", "u", "em"])
        XCTAssertEqual(sheet.rules[3].media, .dark)
    }

    func testValues() {
        func values(_ name: String, _ value: String) -> [CSSProperty: CSSValue]? {
            CSSPropertyParser.parse(name: name, text: value).map { Dictionary($0.map { ($0.property, $0.value) }, uniquingKeysWith: { $1 }) }
        }
        XCTAssertNil(values("width", "300"), "Unitless lengths are invalid")
        XCTAssertNil(values("padding", "-1px"))
        XCTAssertNil(values("color", "var(--x)"))
        XCTAssertNil(values("margin", "1px 2px 3px 4px 5px"))
        XCTAssertEqual(values("width", "0")?[.width], .length(.zero))
        XCTAssertEqual(values("margin", "1px auto")?[.marginLeft], .auto)
        XCTAssertEqual(values("margin-inline", "1px 2px")?[.marginRight], .length(.value(2, .px)))
        XCTAssertEqual(values("width", "calc(100% - 2em)")?[.width],
                       .length(.calc(.sum([.value(100, .percent), .product(.value(2, .em), -1)]))))
        XCTAssertNil(values("width", "calc(100% -2em)"), "calc() needs whitespace around minus")
        XCTAssertNil(values("width", "calc(2em * 3px)"))
        XCTAssertEqual(values("font", "italic small-caps bold 12px/1.5 \"Times New Roman\", Georgia, serif"),
                       [.fontStyle: .flag(true), .fontVariantCaps: .flag(true), .fontWeight: .fontWeight(.absolute(700)),
                        .fontSize: .fontSize(.length(.value(12, .px))), .lineHeight: .lineHeight(.number(1.5)),
                        .fontFamily: .families(["times new roman", "georgia", "serif"])])
        XCTAssertNil(values("font", "bold serif"), "font needs a size")
        XCTAssertEqual(values("font-family", "Gill   Sans, 'Open Sans', sans-serif")?[.fontFamily],
                       .families(["gill sans", "open sans", "sans-serif"]))
        XCTAssertNil(values("font-family", "inherit, serif"))
        XCTAssertEqual(values("list-style", "none")?[.listStyleType], .listStyleType(.none))
        XCTAssertEqual(values("list-style", "inside \"→ \"")?[.listStyleType], .listStyleType(.string("→ ")))
        XCTAssertEqual(values("list-style", "url(x.png) square")?[.listStyleType], .listStyleType(.square))
        XCTAssertEqual(values("background", "url(a.png) no-repeat #fff")?[.backgroundColor],
                       .color(.rgba(StyleTestSupport.color(1, 1, 1))))
        XCTAssertEqual(values("background", "url(a.png)")?[.backgroundColor], .color(.rgba(StyleTestSupport.color(0, 0, 0, 0))))
        XCTAssertEqual(values("text-decoration", "underline dotted red")?[.textDecorationLine], .decoration(.underline))
        XCTAssertEqual(values("page-break-before", "always")?[.breakBefore], .breakValue(.page))
        XCTAssertEqual(values("-webkit-hyphens", "none")?[.hyphens], .hyphens(.none))
        XCTAssertEqual(values("adobe-hyphenate", "none")?[.hyphens], .hyphens(.none))
        XCTAssertEqual(values("-epub-writing-mode", "vertical-rl")?[.writingMode], .writingMode(.verticalRL))
        XCTAssertEqual(values("font-variant", "small-caps oldstyle-nums")?[.fontVariantCaps], .flag(true))
        XCTAssertEqual(values("font-variant", "oldstyle-nums")?[.fontVariantCaps], .flag(false))
        XCTAssertEqual(values("display", "flex")?[.display], .display(.block, blockifies: true))
        XCTAssertEqual(values("display", "inline-grid")?[.display], .display(.inlineBlock, blockifies: true))
        XCTAssertEqual(values("display", "inline flow-root")?[.display], .display(.inlineBlock, blockifies: false))
        XCTAssertEqual(values("border-top", "1px solid")?[.borderTopColor], .color(.currentColor))
        XCTAssertEqual(values("all", "initial")?.count, CSSProperty.count - 1)
        XCTAssertNil(values("all", "bold"))
    }

    func testColors() {
        func color(_ text: String) -> CSSColor? {
            var truncated = false
            let components = CSSParser.components(text, truncated: &truncated).significant
            return components.count == 1 ? CSSPropertyParser.color(components[0]) : nil
        }
        let c = StyleTestSupport.color
        XCTAssertEqual(color("rebeccapurple"), .rgba(c(0x66 / 255, 0x33 / 255, 0x99 / 255, 1)))
        XCTAssertEqual(color("#f00"), .rgba(c(1, 0, 0, 1)))
        XCTAssertEqual(color("#f008"), .rgba(c(1, 0, 0, 0x88 / 255)))
        XCTAssertEqual(color("#00ff0080"), .rgba(c(0, 1, 0, 0x80 / 255)))
        XCTAssertNil(color("#ff00f"))
        XCTAssertEqual(color("rgb(255, 0, 0)"), .rgba(c(1, 0, 0, 1)))
        XCTAssertEqual(color("rgba(0, 0, 255, .5)"), .rgba(c(0, 0, 1, 0.5)))
        XCTAssertEqual(color("rgb(0 255 0 / 25%)"), .rgba(c(0, 1, 0, 0.25)))
        XCTAssertEqual(color("rgb(100%, 0%, 0%)"), .rgba(c(1, 0, 0, 1)))
        XCTAssertNil(color("rgb(1, 2)"))
        XCTAssertEqual(color("hsl(120, 100%, 50%)"), .rgba(c(0, 1, 0, 1)))
        XCTAssertEqual(color("hsla(240deg 100% 50% / 0.5)"), .rgba(c(0, 0, 1, 0.5)))
        XCTAssertEqual(color("hsl(0.5turn, 100%, 25%)"), .rgba(c(0, 0.5, 0.5, 1)))
        XCTAssertEqual(color("transparent"), .rgba(c(0, 0, 0, 0)))
        XCTAssertEqual(color("currentColor"), .currentColor)
        XCTAssertEqual(color("CanvasText"), .system)
        XCTAssertNil(color("notacolor"))
    }
}

extension CSSParserTests {
    func testUserAgentStyleSheetParsesCompletely() {
        var truncated = false
        let raw = CSSParser.rules(CSSParser.components(UserAgentStyleSheet.text, truncated: &truncated), topLevel: true)
        var expectedRules = 0
        for case .qualified(let prelude, let block) in raw {
            expectedRules += 1
            for declaration in CSSParser.declarations(block) {
                XCTAssertNotNil(CSSPropertyParser.parse(name: declaration.name, value: declaration.value, important: false),
                                "\(prelude.map { "\($0)" }.joined()) \(declaration.name)")
            }
        }
        XCTAssertFalse(truncated)
        XCTAssertFalse(UserAgentStyleSheet.sheet.truncated)
        XCTAssertEqual(UserAgentStyleSheet.sheet.rules.count, expectedRules, "Every user-agent selector is valid")
    }
}
