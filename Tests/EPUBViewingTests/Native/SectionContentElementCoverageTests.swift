import CoreText
import EPUBCore
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What each HTML element an EPUB 3.3 XHTML content document may hold contributes to a section's
/// text: its characters, its default presentation (HTML "Rendering") and what is disclosed.
final class SectionContentElementCoverageTests: XCTestCase {
    private typealias H = BuilderHarness
    private typealias S = SectionContentSupport

    // MARK: Sections, headings and grouping content

    func testSectioningAndGroupingElementsAreBlocksInDocumentOrder() throws {
        let text = try H.build("""
            <main><article><header>H</header><section>S</section><aside>A</aside><footer>F</footer></article></main><nav>N</nav>
            <blockquote><p>Q</p><footer>— <cite>Src</cite></footer></blockquote><address>Addr<br/>Line</address>
            <hgroup><h2>Two</h2><p>Sub</p></hgroup><search>Find</search><div>D</div>
            """)
        XCTAssertEqual(S.paragraphs(text), ["H", "S", "A", "F", "N", "Q", "— Src", "Addr\u{2028}Line", "Two", "Sub", "Find", "D"])
        XCTAssertTrue(S.traits("Src", in: text).contains(.traitItalic))
        XCTAssertTrue(S.traits("Addr", in: text).contains(.traitItalic))
        XCTAssertEqual(H.paragraphStyle(text, at: H.location(of: "Q", in: text))?.headIndent, 40)
        S.assertTextMapContracts(text)
    }

    func testHeadingsAreBoldSizedByLevelAndKeptWithWhatFollows() throws {
        let text = try H.build("<h1>One</h1><h2>Two</h2><h3>Three</h3><h4>Four</h4><h5>Five</h5><h6>Six</h6><p>Body</p>")
        XCTAssertEqual(S.paragraphs(text), ["One", "Two", "Three", "Four", "Five", "Six", "Body"])
        let sizes: [(String, CGFloat)] = [("One", 32), ("Two", 24), ("Three", 18.72), ("Four", 16), ("Five", 13.28), ("Six", 10.72)]
        for (heading, size) in sizes {
            XCTAssertEqual(try XCTUnwrap(S.font(heading, in: text)).pointSize, size, accuracy: 0.01, heading)
            XCTAssertTrue(S.traits(heading, in: text).contains(.traitBold), heading)
            XCTAssertEqual(H.attribute(.readerKeepWithNext, of: heading, in: text) as? Bool, true, heading)
        }
        XCTAssertFalse(S.traits("Body", in: text).contains(.traitBold))
        XCTAssertNil(H.attribute(.readerKeepWithNext, of: "Body", in: text))
    }

    // MARK: Text-level semantics

    func testPhraseElementsAreInlineWithTheirDefaultStyle() throws {
        let text = try H.build("""
            <p>plain <em>em</em> <i>ital</i> <cite>cite</cite> <dfn>dfn</dfn> <var>var</var> <strong>strong</strong> <b>bold</b> \
            <code>code</code> <kbd>kbd</kbd> <samp>samp</samp> <u>under</u> <ins>ins</ins> <s>struck</s> <del>del</del> \
            <mark>mark</mark> <small>small</small> <abbr title="Title text">abbr</abbr> <time datetime="2020-01-01">time</time> \
            <data value="1">data</data> <span>span</span></p>
            """)
        XCTAssertEqual(text.string.string,
                       "plain em ital cite dfn var strong bold code kbd samp under ins struck del mark small abbr time data span")
        for word in ["em", "ital", "cite", "dfn", "var"] { XCTAssertTrue(S.traits(word, in: text).contains(.traitItalic), word) }
        for word in ["strong", "bold"] { XCTAssertTrue(S.traits(word, in: text).contains(.traitBold), word) }
        for word in ["code", "kbd", "samp"] { XCTAssertTrue(S.traits(word, in: text).contains(.traitMonoSpace), word) }
        for word in ["under", "ins"] {
            XCTAssertEqual(H.attribute(.underlineStyle, of: word, in: text) as? Int, NSUnderlineStyle.single.rawValue, word)
        }
        for word in ["struck", "del"] {
            XCTAssertEqual(H.attribute(.strikethroughStyle, of: word, in: text) as? Int, NSUnderlineStyle.single.rawValue, word)
        }
        XCTAssertNotNil(H.attribute(.backgroundColor, of: "mark", in: text))
        XCTAssertLessThan(try XCTUnwrap(S.font("small", in: text)).pointSize, 16)
        for word in ["plain", "abbr", "time", "data", "span"] {
            XCTAssertTrue(S.traits(word, in: text).isDisjoint(with: [.traitItalic, .traitBold, .traitMonoSpace]), word)
            XCTAssertNil(H.attribute(.underlineStyle, of: word, in: text), word)
            XCTAssertNil(H.attribute(.backgroundColor, of: word, in: text), word)
        }
        // Attribute values (`title`, `datetime`, `value`) are never text.
        XCTAssertFalse(text.string.string.contains("Title text"))
        XCTAssertFalse(text.string.string.contains("2020"))
        S.assertTextMapContracts(text)
    }

    func testNestedEmphasisAccumulatesAndUnnests() throws {
        let text = try H.build("<p>p1 <b>b1 <i>bi <u>biu</u></i> b2</b> <i>i1 <i>i2</i></i> <u>u1 <s>us</s></u> p2</p>")
        func style(_ word: String) -> [Bool] {
            let traits = S.traits(word, in: text)
            return [traits.contains(.traitBold), traits.contains(.traitItalic),
                    H.attribute(.underlineStyle, of: word, in: text) != nil, H.attribute(.strikethroughStyle, of: word, in: text) != nil]
        }
        XCTAssertEqual(style("p1"), [false, false, false, false])
        XCTAssertEqual(style("b1"), [true, false, false, false])
        XCTAssertEqual(style("bi"), [true, true, false, false])
        XCTAssertEqual(style("biu"), [true, true, true, false])
        XCTAssertEqual(style("b2"), [true, false, false, false])
        XCTAssertEqual(style("i1"), [false, true, false, false])
        XCTAssertEqual(style("i2"), [false, true, false, false])
        XCTAssertEqual(style("u1"), [false, false, true, false])
        XCTAssertEqual(style("us"), [false, false, true, true]) // A decoration propagates to descendants.
        XCTAssertEqual(style("p2"), [false, false, false, false])
    }

    func testSuperscriptsAndSubscriptsShiftAndNestWithinBounds() throws {
        let text = try H.build("<p>x<sup>a<sup>b</sup></sup> y<sub>c</sub> z" + String(repeating: "<sup>", count: 30) + "deep"
                               + String(repeating: "</sup>", count: 30) + "</p>")
        func offset(_ word: String) -> CGFloat { H.attribute(.baselineOffset, of: word, in: text) as? CGFloat ?? 0 }
        XCTAssertEqual(offset("x"), 0)
        XCTAssertGreaterThan(offset("a"), 0)
        XCTAssertGreaterThan(offset("b"), offset("a"))
        XCTAssertLessThan(offset("c"), 0)
        XCTAssertEqual(offset(" z"), 0)
        // Hostile nesting cannot push text off its line: at most three times the font size.
        XCTAssertLessThanOrEqual(offset("deep"), 3 * 16)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(S.font("deep", in: text)).pointSize, 4)
    }

    func testLegacyPresentationalElementsStillRender() throws {
        let text = try H.build("""
            <center>Cen</center><p><font color="red">font</font> <big>big</big> <tt>tele</tt> <strike>strike</strike> \
            <nobr>no break</nobr> <acronym title="x">AC</acronym></p>
            """)
        XCTAssertEqual(text.string.string, "Cen\nfont big tele strike no break AC")
        XCTAssertEqual(H.paragraphStyle(text, at: 0)?.alignment, .center)
        XCTAssertGreaterThan(try XCTUnwrap(S.font("big", in: text)).pointSize, 16)
        XCTAssertTrue(S.traits("tele", in: text).contains(.traitMonoSpace))
        XCTAssertNotNil(H.attribute(.strikethroughStyle, of: "strike", in: text))
    }

    // MARK: Interactive and embedded content

    func testDetailsShowTheirSummaryAndContentWhetherOpenOrNot() throws {
        // Nothing can open a closed `details` here, so its content must not be lost.
        let text = try H.build("<details><summary>Sum</summary><p>Closed body</p></details><details open=''><summary>Open</summary>shown</details>")
        XCTAssertEqual(S.paragraphs(text), ["Sum", "Closed body", "Open", "shown"])
        S.assertTextMapContracts(text)
    }

    func testDialogsShowOnlyWhenOpen() throws {
        XCTAssertEqual(try H.build("<dialog>closed</dialog><dialog open=''>opened</dialog><p>x</p>").string.string, "opened\nx")
    }

    func testFigureAndCaption() throws {
        let text = try H.build("<figure id='f'><img src='picture.png' alt='Pic'/><figcaption id='c'>Caption <em>text</em></figcaption></figure><p>After</p>")
        XCTAssertEqual(text.string.string, "[Pic]\nCaption text\nAfter")
        // The reader's documented default: captions centred at 0.9em.
        XCTAssertEqual(H.paragraphStyle(text, at: H.location(of: "Caption", in: text))?.alignment, .center)
        XCTAssertEqual(try XCTUnwrap(S.font("Caption", in: text)).pointSize, 14.4, accuracy: 0.01)
        XCTAssertEqual(text.anchors["f"], 0)
        XCTAssertEqual(text.anchors["c"], H.location(of: "Caption", in: text))
        S.assertTextMapContracts(text)
    }

    func testFormControlsAreCountedAndTextAroundThemStaysReadable() throws {
        let text = try H.build("""
            <form><fieldset><legend>Legend</legend><label>Name <input type="text" value="typed"/></label>\
            <textarea>area text</textarea><select><option>one</option><option>two</option></select><button>Go</button></fieldset></form>\
            <p><meter value="0.6">60%</meter> <progress value="3" max="10">30%</progress> <output>42</output> <label>lone</label></p>
            """)
        XCTAssertEqual(text.string.string, "Legend\nName Go\n60% 30% 42 lone")
        XCTAssertEqual(text.report.unsupportedElements, ["form": 1, "input": 1, "textarea": 1, "select": 1, "button": 1])
        S.assertTextMapContracts(text)
    }

    func testMediaShowOnlyTheirFallbackContentAndAreCounted() throws {
        let text = try H.build("""
            <p>a<audio src="a.mp3" controls=""/>b</p>\
            <p>x<video src="v.mp4"><source src="v.webm"/><track src="t.vtt"/>Fallback <a href="two.xhtml">download</a></video>y</p>\
            <p>1<iframe src="two.xhtml">frame</iframe>2<embed src="x.bin"/>3<canvas>drawn</canvas>4\
            <object data="x.bin"><param name="a" value="b"/>object text</object>5</p>
            """)
        XCTAssertEqual(text.string.string, "ab\nxFallback downloady\n123drawn4object text5")
        XCTAssertEqual(text.report.unsupportedElements, ["audio": 1, "video": 1, "iframe": 1, "embed": 1, "canvas": 1, "object": 1])
        XCTAssertEqual(S.link("download", in: text), .internal(href: "OPS/two.xhtml"))
        S.assertTextMapContracts(text)
    }

    func testPictureShowsItsImageOnceAndIgnoresItsSources() throws {
        let rich = BuilderRecordingRich()
        let text = try H.build("<picture><source srcset='a.webp' type='image/webp'/><img src='picture.png' alt=''/></picture>", rich: rich)
        XCTAssertEqual(rich.calls, ["image:img"])
        XCTAssertEqual(text.string.length, 1)
        XCTAssertEqual(text.report.unsupportedElements, [:])
    }

    func testAnImageInsideALinkCarriesTheLink() throws {
        let text = try H.build("<p><a href='two.xhtml#x'><img src='picture.png' alt=''/></a> <img src='picture.png' alt=''/></p>",
                               rich: BuilderRecordingRich())
        XCTAssertEqual((text.string.attribute(.link, at: 0, effectiveRange: nil) as? URL).flatMap(ReaderLink.init(url:)),
                       .internal(href: "OPS/two.xhtml#x"))
        XCTAssertNil(text.string.attribute(.link, at: 2, effectiveRange: nil))
    }

    func testScriptStyleTemplateAndMetadataElementsInTheBodyNeverRender() throws {
        let text = try H.build("""
            <p>a<template><b>T</b></template>b<script>var x = "s";</script>c<style>p { color: red }</style>d\
            <title>ttl</title>e<link rel="stylesheet" href="x.css"/>f<meta name="n" content="c"/>g<noscript>NS</noscript>h\
            <datalist><option>opt</option></datalist>i</p>
            """)
        // Scripting is off, so `noscript` shows its children (HTML 4.12.2).
        XCTAssertEqual(text.string.string, "abcdefgNShi")
        XCTAssertEqual(text.report.scriptsRefused, 1)
        S.assertTextMapContracts(text)
    }

    func testSwitchShowsItsDefaultUnlessACaseIsMathML() throws {
        let unknown = try H.build("""
            <p>a<epub:switch id="sw"><epub:case required-namespace="http://example.com/x"><b id="c">case</b></epub:case>\
            <epub:default><i id="d">default</i></epub:default></epub:switch>z</p>
            """)
        XCTAssertEqual(unknown.string.string, "adefaultz")
        // The branch not shown still anchors, at the next rendered character.
        XCTAssertEqual(unknown.anchors["c"], 1)
        XCTAssertEqual(unknown.anchors["d"], 1)
        S.assertTextMapContracts(unknown)
        let none = try H.build("<p>a<epub:switch><epub:case required-namespace='http://example.com/x'>case</epub:case></epub:switch>z</p>")
        XCTAssertEqual(none.string.string, "az")
    }

    func testTriggersNeverRender() throws {
        let text = try H.build("<p>a<epub:trigger xmlns:ev='http://www.w3.org/2001/xml-events' ev:observer='b' action='play'>t</epub:trigger>b</p>")
        XCTAssertEqual(text.string.string, "ab")
    }

    func testUnknownAndForeignNamespaceElementsRenderTheirChildrenInline() throws {
        let text = try H.build("<p>a <x-custom>custom <b>bold</b></x-custom> <foo:bar xmlns:foo='urn:x'>foreign <foo:baz>deep</foo:baz></foo:bar> z</p>")
        XCTAssertEqual(text.string.string, "a custom bold foreign deep z")
        XCTAssertTrue(S.traits("bold", in: text).contains(.traitBold))
        XCTAssertEqual(text.report.unsupportedElements, [:])
        S.assertTextMapContracts(text)
    }

    func testPrefixedXHTMLElementsRenderLikeUnprefixedOnes() throws {
        let text = try S.raw("""
            <h:html xmlns:h="http://www.w3.org/1999/xhtml" xmlns:e="http://www.idpf.org/2007/ops" xml:lang="en">\
            <h:head><h:title>Prefixed</h:title></h:head><h:body><h:h1 id="t">Title</h:h1>\
            <h:p>Text <h:em>em</h:em><h:a e:type="noteref" href="#n">1</h:a></h:p><h:ul><h:li>item</h:li></h:ul>\
            <h:aside e:type="footnote" id="n"><h:p>Note.</h:p></h:aside></h:body></h:html>
            """)
        XCTAssertEqual(text.string.string, "Title\nText em1\n•\titem")
        XCTAssertEqual(text.title, "Prefixed")
        XCTAssertEqual(text.notes["n"]?.string, "Note.")
        XCTAssertEqual(S.link("1", in: text), .note(href: "OPS/one.xhtml#n"))
        XCTAssertTrue(S.traits("em", in: text).contains(.traitItalic))
        XCTAssertFalse(text.report.recoveredAsHTML)
    }

    // MARK: Hidden content

    func testTheHiddenAttributeRemovesContentWhileAriaHiddenKeepsIt() throws {
        let text = try H.build("""
            <p aria-hidden="true">AH</p><p hidden="hidden">H1</p><p hidden="">H2</p><p hidden="until-found">H3</p>\
            <div hidden=""><p>H4 <span>H5</span></p></div><p>a<span hidden="">H6</span>b</p><p>end</p>
            """)
        XCTAssertEqual(text.string.string, "AH\nab\nend")
        XCTAssertEqual(H.attribute(.foregroundColor, of: "AH", in: text) as? PlatformColor, ReaderPalette.text(dark: false))
        S.assertTextMapContracts(text)
    }

    func testVisibilityHiddenKeepsCharactersInvisibleAndVisibleDescendantsShow() throws {
        let text = try S.styled("""
            <div style="visibility: hidden">gone <a href="two.xhtml">link</a> <span style="visibility: visible">shown</span></div>\
            <p style="display: none">none <span style="display: block">still none</span></p><p>after</p>
            """)
        // CSS 2 section 11.2: an invisible box still affects layout; `display: none` generates no box.
        XCTAssertEqual(text.string.string, "gone link shown\nafter")
        XCTAssertEqual(H.attribute(.foregroundColor, of: "gone", in: text) as? PlatformColor, .clear)
        XCTAssertEqual(H.attribute(.foregroundColor, of: "link", in: text) as? PlatformColor, .clear)
        XCTAssertNil(H.attribute(.link, of: "link", in: text), "an invisible link must not be followed")
        XCTAssertNil(H.attribute(.underlineStyle, of: "link", in: text))
        XCTAssertEqual(H.attribute(.foregroundColor, of: "shown", in: text) as? PlatformColor, ReaderPalette.text(dark: false))
        XCTAssertEqual(H.attribute(.foregroundColor, of: "after", in: text) as? PlatformColor, ReaderPalette.text(dark: false))
        S.assertTextMapContracts(text)
    }

    func testAVisibilityHiddenRuleDrawsNothing() throws {
        // CSS 2 section 11.2: "The generated box is invisible (fully transparent, nothing is drawn), but still affects layout."
        let text = try S.styled("<p>above</p><hr style='visibility: hidden'/><p>below</p>")
        var rules: [ReaderRuleAttachment] = []
        text.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.string.length)) { value, _, _ in
            if let rule = value as? ReaderRuleAttachment { rules.append(rule) }
        }
        let rule = try XCTUnwrap(rules.first, "the rule keeps its space")
        let size = CGSize(width: 200, height: 20)
        let image = rule.image(forBounds: CGRect(origin: .zero, size: size), textContainer: nil, characterIndex: 0)
        let visible = try S.styled("<hr/>")
        let drawn = try XCTUnwrap(visible.string.attribute(.attachment, at: 0, effectiveRange: nil) as? ReaderRuleAttachment)
        let reference = drawn.image(forBounds: CGRect(origin: .zero, size: size), textContainer: nil, characterIndex: 0)
        XCTAssertGreaterThan(try XCTUnwrap(S.maximumAlpha(of: reference, size: size)), 0, "an ordinary rule is drawn")
        XCTAssertEqual(S.maximumAlpha(of: image, size: size) ?? 0, 0, "a `visibility: hidden` rule is drawn")
    }

    /// Every kind of attachment keeps its room and draws nothing when its element is hidden: a
    /// rule, a bitmap, an SVG image, an inline drawing and a formula ([#132](https://github.com/vocaro/EPUBLib/issues/132)).
    /// Inside the same hidden box, one that sets `visibility: visible` again is drawn.
    func testVisibilityHiddenAttachmentsDrawNothingInTheirRoomUnlessShownAgain() throws {
        let drawing = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="blue"/></svg>"#
        let body = """
            <div class="v"><hr class="a"/><p><img class="a" src="photo.png" alt="Photo"/> <img class="a" src="art.svg" alt="Art"/> \
            <svg xmlns="http://www.w3.org/2000/svg" class="a" width="40" height="20"><rect width="40" height="20" fill="blue"/></svg> \
            <math xmlns="http://www.w3.org/1998/Math/MathML" class="a"><mi>x</mi><mo>+</mo><mn>1</mn></math></p></div>
            """
        let files = ["photo.png": RichFixture.image(width: 40, height: 20), "art.svg": Data(drawing.utf8)]
        let shown = try S.styled(body, files: files)
        let hidden = try S.styled(body, css: ".v { visibility: hidden }", files: files)
        let revealed = try S.styled(body, css: ".v { visibility: hidden } .a { visibility: visible }", files: files)
        XCTAssertEqual(hidden.string.string, shown.string.string, "the same characters")
        let kinds = ["rule", "bitmap", "SVG image", "inline drawing", "formula"]
        let drawn = Self.drawnAttachments(shown), unseen = Self.drawnAttachments(hidden), again = Self.drawnAttachments(revealed)
        XCTAssertEqual(drawn.map { $0.kind }, kinds)
        XCTAssertEqual(unseen.map { $0.kind }, kinds)
        XCTAssertEqual(again.map { $0.kind }, kinds)
        for (index, kind) in kinds.enumerated() where index < min(drawn.count, unseen.count, again.count) {
            XCTAssertGreaterThan(drawn[index].alpha, 0, "a \(kind) is drawn")
            XCTAssertEqual(unseen[index].bounds, drawn[index].bounds, "a hidden \(kind) keeps its room")
            XCTAssertEqual(unseen[index].alpha, 0, "a hidden \(kind) draws nothing")
            XCTAssertEqual(again[index].bounds, drawn[index].bounds)
            XCTAssertGreaterThan(again[index].alpha, 0, "a \(kind) that is visible inside a hidden box is drawn")
        }
        // An image that cannot be drawn shows its words instead: they keep its room and are not drawn either.
        let lost = "<p class='v'>a <img src='missing.png' alt='Lost picture'/> b</p>"
        let missing = try S.styled(lost, css: ".v { visibility: hidden }"), standing = try S.styled(lost)
        XCTAssertEqual(H.attribute(.foregroundColor, of: "Lost picture", in: standing) as? PlatformColor, ReaderPalette.secondaryText(dark: false))
        XCTAssertEqual(H.attribute(.foregroundColor, of: "Lost picture", in: missing) as? PlatformColor, .clear)
    }

    /// A hidden table keeps its room and draws neither its borders nor its background, nor its
    /// rows' and cells'; a cell that sets `visibility: visible` again draws its own and nothing else.
    func testAVisibilityHiddenTableDrawsOnlyTheCellsShownAgain() throws {
        let body = """
            <table class="v" style="border: 2px solid black; background-color: yellow">\
            <tr style="background-color: silver"><td style="border: 2px solid red; background-color: lime">left</td>\
            <td class="u" style="border: 2px solid blue; background-color: aqua">right</td></tr>\
            <tr><td style="border: 2px solid red">below</td><td style="border: 2px solid red">two</td></tr></table>
            """
        func rows(_ text: SectionText) -> [TableRowAttachment] {
            var rows: [TableRowAttachment] = []
            text.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.string.length)) { value, _, _ in
                if let row = value as? TableRowAttachment { rows.append(row) }
            }
            return rows
        }
        func image(_ row: TableRowAttachment) -> (bounds: CGRect, image: PlatformImage?) {
            let bounds = row.layoutBounds(line(300))
            return (bounds, row.image(forBounds: CGRect(origin: .zero, size: bounds.size), textContainer: nil, characterIndex: 0))
        }
        let shown = rows(try S.styled(body)), hidden = rows(try S.styled(body, css: ".v { visibility: hidden }"))
        let revealed = rows(try S.styled(body, css: ".v { visibility: hidden } .u { visibility: visible }"))
        XCTAssertEqual(shown.count, 2)
        XCTAssertEqual(hidden.count, 2)
        XCTAssertEqual(revealed.count, 2)
        for (index, (drawn, unseen)) in zip(shown, hidden).enumerated() {
            let (bounds, picture) = image(drawn), (hiddenBounds, hiddenPicture) = image(unseen)
            XCTAssertGreaterThan(S.maximumAlpha(of: picture, size: bounds.size) ?? 0, 0, "row \(index) is drawn")
            XCTAssertEqual(hiddenBounds, bounds, "row \(index) keeps its room")
            XCTAssertEqual(S.maximumAlpha(of: hiddenPicture, size: bounds.size) ?? 0, 0, "hidden row \(index) draws nothing")
        }
        let (bounds, picture) = image(revealed[0])
        let viewport = TableRowAttachment.viewportHeight(nil, width: bounds.width)
        let cell = try XCTUnwrap(revealed[0].spokenCells(size: bounds.size, viewportHeight: viewport).first { $0.text == "right" })
        XCTAssertGreaterThan(S.maximumAlpha(of: picture, size: bounds.size) ?? 0, 0, "the cell shown again is drawn")
        XCTAssertEqual(S.maximumAlpha(of: picture, size: bounds.size, outside: cell.frame.insetBy(dx: -1, dy: -1)) ?? 0, 0,
                       "nothing but that cell is drawn")
        let (otherBounds, other) = image(revealed[1])
        XCTAssertEqual(S.maximumAlpha(of: other, size: otherBounds.size) ?? 0, 0, "a row without one draws nothing")
    }

    /// Each attachment of a section, as laid out on a 300-point line, and the most opaque pixel
    /// it draws there. A formula is counted once, by its first row.
    private static func drawnAttachments(_ text: SectionText) -> [(kind: String, bounds: CGRect, alpha: UInt8)] {
        var result: [(kind: String, bounds: CGRect, alpha: UInt8)] = []
        text.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.string.length)) { value, _, _ in
            let kind: String, bounds: CGRect, image: PlatformImage?
            if let attachment = value as? ReaderAttachment {
                if attachment is ReaderRuleAttachment { kind = "rule" }
                else if let picture = attachment as? ReaderImageAttachment {
                    kind = picture.path.hasSuffix(".png") ? "bitmap" : picture.path.hasSuffix(".svg") ? "SVG image" : "inline drawing"
                } else { kind = "\(type(of: attachment))" }
                bounds = attachment.layoutBounds(line(300))
                image = attachment.image(forBounds: CGRect(origin: .zero, size: bounds.size), textContainer: nil, characterIndex: 0)
            } else if let formula = value as? MathAttachment {
                guard formula.row == 0 else { return }
                kind = "formula"
                bounds = formula.bounds(lineWidth: 300, height: 0)
                image = formula.image(size: bounds.size)
            } else { return }
            result.append((kind, bounds, S.maximumAlpha(of: image, size: bounds.size) ?? 0))
        }
        return result
    }

    func testVisuallyHiddenPositionedLabelsAreNotDrawnAndAreKeptForAssistiveTechnology() throws {
        let text = try S.styled("""
            <p>a<span style="position: absolute; left: -9999px">offscreen</span>b\
            <span style="position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0, 0, 0, 0)">clipped</span>c\
            <span style="position: absolute; left: -9999px; visibility: hidden">unseen and unheard</span>d</p>
            """)
        XCTAssertEqual(text.string.drawnString, "abcd")
        XCTAssertEqual(text.string.spokenLabels, ["offscreen", "clipped"])
        XCTAssertEqual(text.string.string, "a\u{FFFC}b\u{FFFC}cd", "each label is one character where its box stands")
        XCTAssertEqual(text.string.readerPlainText(), "a offscreen b clipped cd", "read and copied as words of its own")
        XCTAssertEqual(S.mapViolations(text, sameCharacters: false) + S.stringViolations(text), [])
    }

    // MARK: Page breaks and structural semantics

    func testPageBreakMarkersAnchorWithoutAddingText() throws {
        let text = try H.build("""
            <p>Before<span epub:type="pagebreak" id="p12" title="12"/>after<span role="doc-pagebreak" id="p13" aria-label="13"></span>end</p>\
            <div epub:type="pagebreak" id="p14" title="14"/><p>next</p><div epub:type="pagebreak" id="p15" title="15"/>
            """)
        XCTAssertEqual(text.string.string, "Beforeafterend\nnext")
        XCTAssertEqual(text.anchors["p12"], 6)
        XCTAssertEqual(text.anchors["p13"], 11)
        XCTAssertEqual(text.anchors["p14"], H.location(of: "next", in: text))
        XCTAssertEqual(text.anchors["p15"], text.string.length)
        S.assertTextMapContracts(text)
    }

    func testStructuralSemanticsAloneDoNotChangeWhatIsShown() throws {
        let text = try H.build("""
            <section epub:type="bodymatter chapter" role="doc-chapter"><h1 epub:type="title">T</h1>\
            <p epub:type="epigraph">E</p><p epub:type="bridgehead">B</p><span epub:type="z3998:roman">iv</span></section>
            """)
        XCTAssertEqual(S.paragraphs(text), ["T", "E", "B", "iv"])
        XCTAssertTrue(text.notes.isEmpty)
    }

    // MARK: Links

    func testLinkTargetsByKindOfReference() throws {
        let text = try H.build("""
            <p><a>bare</a> <a href="">empty</a> <a href="#">hash</a> <a href="  two.xhtml#x  ">spaced</a> \
            <a href="two.xhtml"><b>bold</b> <i>ital</i></a> <a href="sub/../two.xhtml#f%C3%BC">dots</a> <a href="nowhere.xhtml">missing</a></p>\
            <a href="two.xhtml"><p>block one</p><p>block two</p></a><h2><a href="#top">heading</a></h2>
            """)
        XCTAssertNil(S.link("bare", in: text))
        XCTAssertNil(H.attribute(.underlineStyle, of: "bare", in: text))
        XCTAssertEqual(S.link("empty", in: text), .internal(href: "OPS/one.xhtml"))
        XCTAssertEqual(S.link("hash", in: text), .internal(href: "OPS/one.xhtml#"))
        XCTAssertEqual(S.link("spaced", in: text), .internal(href: "OPS/two.xhtml#x"))
        XCTAssertEqual(S.link("dots", in: text), .internal(href: "OPS/two.xhtml#f%C3%BC"))
        XCTAssertEqual(S.link("missing", in: text), .internal(href: "OPS/nowhere.xhtml"))
        // Inline content of a link is all linked, the space between its words included.
        var range = NSRange()
        _ = text.string.attribute(.link, at: H.location(of: "bold", in: text), longestEffectiveRange: &range,
                                  in: NSRange(location: 0, length: text.string.length))
        XCTAssertEqual((text.string.string as NSString).substring(with: range), "bold ital")
        XCTAssertEqual(H.attribute(.underlineStyle, of: "bold", in: text) as? Int, NSUnderlineStyle.single.rawValue)
        // A link around blocks links each block's text, not the break between them.
        XCTAssertEqual(S.link("block one", in: text), .internal(href: "OPS/two.xhtml"))
        XCTAssertEqual(S.link("block two", in: text), .internal(href: "OPS/two.xhtml"))
        XCTAssertNil(text.string.attribute(.link, at: H.location(of: "block two", in: text) - 1, effectiveRange: nil))
        XCTAssertEqual(S.link("heading", in: text), .internal(href: "OPS/one.xhtml#top"))
        XCTAssertTrue(S.traits("heading", in: text).contains(.traitBold))
        S.assertTextMapContracts(text)
    }

    func testReferencesThatLeaveTheArchiveAreExternalWhateverTheirForm() throws {
        let targets = ["https://example.com/a", "http://example.com", "mailto:a@example.com", "tel:+15550100", "javascript:alert(1)",
                       "data:text/html,x", "file:///etc/passwd", "//example.com/x", "ftp://example.com/f", "HTTPS://EXAMPLE.COM/",
                       "http://example.com:port/x", "http://exa mple.com/x"]
        let body = targets.enumerated().map { "<a href=\"\($1.replacingOccurrences(of: "&", with: "&amp;"))\">link\($0)x</a>" }.joined(separator: " ")
        let text = try H.build("<p>\(body)</p>")
        for (index, target) in targets.enumerated() {
            XCTAssertEqual(S.link("link\(index)x", in: text), .external(target), target)
        }
        // Every link survives the URL round trip the text views put it through.
        text.string.enumerateAttribute(.link, in: NSRange(location: 0, length: text.string.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            XCTAssertNotNil(ReaderLink(url: url), "\(url)")
        }
        // A path cannot leave: `..` stops at the container root and a leading `/` names it
        // (EPUB Reading Systems 3.3 §4.1.1). A query is dropped.
        let inside = try H.build("<p><a href=\"../../../outside.xhtml\">climbing</a> <a href=\"/OPS/two.xhtml#x\">rooted</a> "
            + "<a href=\"two.xhtml?page=2#x\">queried</a></p>")
        XCTAssertEqual(S.link("climbing", in: inside), .internal(href: "outside.xhtml"))
        XCTAssertEqual(S.link("rooted", in: inside), .internal(href: "OPS/two.xhtml#x"))
        XCTAssertEqual(S.link("queried", in: inside), .internal(href: "OPS/two.xhtml#x"))
    }

    // MARK: Ruby

    func testRubyKeepsBaseTextAndAnnotatesEachBaseWithItsOwnText() throws {
        let text = try H.build("""
            <p><ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>と<ruby><rb>明</rb><rp>(</rp><rt>あ</rt><rp>)</rp><rb>日</rb><rp>(</rp><rt>す</rt><rp>)</rp></ruby>\
            と<ruby>東京<rp>（</rp><rt> とう きょう </rt><rp>）</rp></ruby></p>
            """, rootAttributes: "lang='ja'")
        XCTAssertEqual(text.string.string, "漢字と明日と東京")
        func annotation(_ location: Int) -> String? {
            guard let value = text.string.attribute(InlineStyling.rubyKey, at: location, effectiveRange: nil) else { return nil }
            return CTRubyAnnotationGetTextForPosition(value as! CTRubyAnnotation, .before) as String?
        }
        XCTAssertEqual((0..<8).map(annotation), ["かん", "じ", nil, "あ", "す", nil, "とう きょう", "とう きょう"])
        S.assertTextMapContracts(text)
    }

    func testRubyTextIsNeverInTheStringTheMapOrThePassageText() throws {
        let text = try H.build("<p>前<ruby>漢<rp>(</rp><rt id='r'>kan</rt><rp>)</rp></ruby>後</p>")
        XCTAssertEqual(text.string.string, "前漢後")
        let annotation = try XCTUnwrap(S.textNode("kan", in: text))
        XCTAssertFalse(text.map.spans.contains { $0.node == annotation.order })
        // A position inside the annotation is the next rendered character.
        XCTAssertEqual(text.map.location(of: DOMPosition(annotation, 1)), 2)
        XCTAssertEqual(text.anchors["r"], 2)
        XCTAssertEqual(text.mappedText(in: 0..<3), "前漢後")
    }

    func testRubyWithoutABaseOrOutsideRubyLosesNoBaseText() throws {
        let text = try H.build("<p><ruby><rt>alone</rt>base<rt></rt></ruby> <rp>(</rp>x<rb>stray</rb></p>")
        XCTAssertTrue(text.string.string.contains("base"))
        XCTAssertTrue(text.string.string.contains("stray"))
        S.assertTextMapContracts(text)
    }

    // MARK: Bidirectional text

    func testDirBdiAndBdoIsolateWithGeneratedCharacters() throws {
        let text = try H.build("<p>a <span dir='rtl'>b</span> <bdi>c</bdi> <bdi dir='rtl'>d</bdi> <span dir='auto'>e</span> <span dir='LTR'>f</span> "
                               + "<bdo dir='rtl'>g</bdo> <bdo dir='ltr'>h</bdo></p>")
        XCTAssertEqual(text.string.string, "a \u{2067}b\u{2069} \u{2068}c\u{2069} \u{2067}d\u{2069} \u{2068}e\u{2069} \u{2066}f\u{2069} "
                       + "\u{2067}\u{202E}g\u{202C}\u{2069} \u{2066}\u{202D}h\u{202C}\u{2069}")
        for (index, unit) in text.string.string.utf16.enumerated() where (0x2066...0x2069).contains(unit) || (0x202A...0x202E).contains(unit) {
            XCTAssertTrue(S.isGenerated(index, in: text), "isolate at \(index) is mapped")
        }
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length), "a b c d e f g h")
        S.assertTextMapContracts(text)
    }

    func testAnIsolateBrokenByABlockIsClosedAndReopenedPerParagraph() throws {
        let text = try H.build("<span dir='rtl'>one<p>two</p>three</span>")
        XCTAssertEqual(S.paragraphs(text).count, 3)
        for paragraph in S.paragraphs(text) {
            let opens = paragraph.unicodeScalars.filter { (0x2066...0x2068).contains($0.value) }.count
            let closes = paragraph.unicodeScalars.filter { $0.value == 0x2069 }.count
            XCTAssertLessThanOrEqual(closes, opens, "\(S.escape(paragraph)) closes an isolate it did not open")
        }
        S.assertTextMapContracts(text)
    }

    func testBlockDirectionComesFromDirOnAnyAncestor() throws {
        let text = try H.build("<p>ltr</p><div dir='rtl'><p>rtl</p><blockquote><p>deep</p><p dir='ltr'>back</p></blockquote></div><p dir='auto'>auto</p>")
        func direction(_ word: String) -> NSWritingDirection? { H.paragraphStyle(text, at: H.location(of: word, in: text))?.baseWritingDirection }
        XCTAssertEqual(direction("ltr"), .leftToRight)
        XCTAssertEqual(direction("rtl"), .rightToLeft)
        XCTAssertEqual(direction("deep"), .rightToLeft)
        XCTAssertEqual(direction("back"), .leftToRight)
        XCTAssertEqual(direction("auto"), .natural)
        let document = try H.build("<p>whole</p>", rootAttributes: "dir='rtl'")
        XCTAssertEqual(H.paragraphStyle(document, at: 0)?.baseWritingDirection, .rightToLeft)
    }

    // MARK: Quotations

    func testQuotationMarksNestAlternatelyAndFollowTheLanguage() throws {
        XCTAssertEqual(try H.build("<p><q>a<q>b</q></q> <q>c</q></p>").string.string, "“a‘b’” “c”")
        XCTAssertEqual(try H.build("<p lang='de'><q>a<q>b</q></q></p>").string.string, "„a‚b‘“")
        XCTAssertEqual(try H.build("<p lang='ja'><q>a<q>b</q></q></p>").string.string, "「a『b』」")
        XCTAssertEqual(try H.build("<p xml:lang='en-GB'><q>a</q></p>").string.string, "“a”")
        XCTAssertEqual(try H.build("<p lang='zh-Hant'><q>a</q></p><p lang='zh'><q>b</q></p>").string.string, "「a」\n“b”")
        XCTAssertEqual(try H.build("<p lang='pl'><q>a</q></p><p lang='sv'><q>b</q></p><p lang='it'><q>c</q></p>").string.string, "„a”\n”b”\n«c»")
        let french = try H.build("<p lang='fr'><q>a</q></p>").string.string
        XCTAssertTrue(french.hasPrefix("«") && french.hasSuffix("»") && french.contains("a"), french)
    }

    func testQuotationMarksAreGeneratedAndLeftOutOfThePassageText() throws {
        let text = try H.build("<p>He said <q>hi <q>there</q></q>.</p>")
        XCTAssertEqual(text.string.string, "He said “hi ‘there’”.")
        for mark in ["“", "‘", "’", "”"] { XCTAssertTrue(S.isGenerated(H.location(of: mark, in: text), in: text), mark) }
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length), "He said hi there.")
        S.assertTextMapContracts(text)
    }

    func testQuotationMarksForBrazilianPortugueseAndTurkishAreThoseLanguagesOwn() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/133")
        // CSS Generated Content 3 section 2.4.1 (`quotes: auto`, what `q::before { content: open-quote }` uses):
        // "A typographically appropriate quotation mark system" for the content language, for which the
        // specification points at CLDR. CLDR gives “ ” for `pt` and `tr` (« » only for `pt-PT`), as
        // `Locale(identifier:).quotationBeginDelimiter` reports.
        XCTAssertEqual(try H.build("<p lang='pt-BR'><q>a</q></p>").string.string, "“a”")
        XCTAssertEqual(try H.build("<p lang='pt-PT'><q>a</q></p>").string.string, "«a»")
        XCTAssertEqual(try H.build("<p lang='tr'><q>a</q></p>").string.string, "“a”")
    }

    // MARK: Rules, breaks and definition lists

    func testARuleInsideAParagraphSplitsItAndIsAUnit() throws {
        let text = try H.build("<p>a<br clear='all'/>b<hr id='r'/>c</p><hr/><p>x</p>")
        XCTAssertEqual(text.string.string, "a\u{2028}b\n—\nc\n—\nx")
        let rule = try XCTUnwrap(text.map.spans.first { $0.node == text.document.element(id: "r")!.order })
        XCTAssertTrue(rule.isUnit)
        XCTAssertEqual(text.anchors["r"], rule.location)
        S.assertTextMapContracts(text)
    }

    func testDefinitionListsIndentTheirDescriptions() throws {
        let text = try H.build("<dl><dt>T1</dt><dd>D1</dd><dt>T2</dt><dd><p>D2</p><p>D3</p></dd><div><dt>T3</dt><dd>D4</dd></div></dl>")
        XCTAssertEqual(S.paragraphs(text), ["T1", "D1", "T2", "D2", "D3", "T3", "D4"])
        XCTAssertEqual(H.paragraphStyle(text, at: H.location(of: "T1", in: text))?.headIndent, 0)
        for word in ["D1", "D2", "D3", "D4"] { XCTAssertEqual(H.paragraphStyle(text, at: H.location(of: word, in: text))?.headIndent, 40, word) }
        S.assertTextMapContracts(text)
    }

    // MARK: Language

    func testLanguageIsCarriedForSpeechFromTheNearestDeclaration() throws {
        let text = try H.build("""
            <p>one <span lang="fr">deux <span xml:lang="de" lang="it">drei</span> <span lang="">leer</span></span> four</p>\
            <ol lang="es"><li>cinco</li></ol><div xml:lang="ja"><p>六</p></div>
            """)
        XCTAssertEqual(S.language("one", in: text), "en") // The publication's language: the document declares none.
        XCTAssertEqual(S.language("deux", in: text), "fr")
        XCTAssertEqual(S.language("drei", in: text), "de") // `xml:lang` wins over `lang` (HTML 3.2.6.2).
        XCTAssertNil(S.language("leer", in: text)) // An empty value says the language is unknown.
        XCTAssertEqual(S.language("four", in: text), "en")
        XCTAssertEqual(S.language("cinco", in: text), "es")
        XCTAssertEqual(S.language("1.", in: text), "es")
        XCTAssertEqual(S.language("六", in: text), "ja")
        let declared = try H.build("<p>texte</p>", rootAttributes: "xml:lang='fr'")
        XCTAssertEqual(S.language("texte", in: declared), "fr")
    }

    // MARK: Styles from the book

    func testDisplayValuesFromTheStylesheetDecideBlocksAndInlines() throws {
        let text = try S.styled("""
            <p>a<span class="block">b</span>c</p><div class="inline">d</div><div class="inline">e</div><p class="inline"> f</p>\
            <span class="item">g</span><p class="none">h</p><p>i</p>
            """, css: ".block { display: block } .inline { display: inline } .item { display: list-item } .none { display: none }")
        XCTAssertEqual(S.paragraphs(text), ["a", "b", "c", "de f", "•\tg", "i"])
        S.assertTextMapContracts(text)
    }

    func testGeneratedContentFromBeforeAndAfterIsRendered() throws {
        // CSS 2 section 12.1: `::before` and `::after` with `content` insert text. EPUB Reading Systems 3.3
        // section 6.3: a reading system with a viewport "MUST support the official definition of CSS as
        // described in the CSS Snapshot".
        let text = try S.styled("<p class='note'>Take care.</p>", css: ".note::before { content: 'Note: ' } .note::after { content: ' [end]' }")
        XCTAssertEqual(text.string.string, "Note: Take care. [end]")
    }
}
