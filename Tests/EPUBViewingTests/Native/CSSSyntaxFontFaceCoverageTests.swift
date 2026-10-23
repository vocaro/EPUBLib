@testable import EPUBViewing
import XCTest

/// `@font-face` as the stylesheet parser reads it (CSS Fonts 4 §4): the family, the source list
/// with its format hints, and the weight and style descriptors. Loading the fonts is `FontRegistry`'s.
final class CSSSyntaxFontFaceCoverageTests: XCTestCase {
    private func faces(_ css: String) -> [CSSFontFace] { CSSSyntaxSupport.sheet(css).fontFaces }

    func testFamilySourceListFormatHintsWeightAndStyleDescriptors() {
        XCTAssertEqual(faces("""
            @font-face { font-family: "Body Serif"; src: url(../fonts/body.woff2) format("woff2"), url("../fonts/body.ttf") format("truetype");
                         font-weight: 400; font-style: normal; font-display: swap; unicode-range: U+0-7F }
            @font-face { font-family: Body Serif; src: url(../fonts/body-bold-italic.otf); font-weight: bold; font-style: italic }
            @FONT-FACE { FONT-FAMILY: 'Variable'; SRC: URL(v.ttf) FORMAT('truetype-variations'); FONT-WEIGHT: 100 900; font-style: oblique 10deg }
            @font-face { font-family: Swapped; src: url(s.ttf); font-weight: 900 100 }
            @font-face { font-family: Local; src: local("Georgia"), local(Georgia), url(l.woff) format(woff) }
            @font-face { font-family: Hints; src: url(h.eot?#iefix) format("embedded-opentype"), url(h.svg#id) format("svg"),
                         url(h.woff?v=1#x) format("woff"), url(h.ttf) format("truetype") tech(variations), url(h.ttf) format("opentype") }
            @font-face { font-family: Spaced; src: url("my%20font.otf"), url( 'sub/caf%C3%A9.ttf' ) }
            """), [
            CSSFontFace(family: "body serif", sources: ["OPS/fonts/body.woff2", "OPS/fonts/body.ttf"]),
            CSSFontFace(family: "body serif", weights: 700...700, isItalic: true, sources: ["OPS/fonts/body-bold-italic.otf"]),
            CSSFontFace(family: "variable", weights: 100...900, isItalic: true, sources: ["OPS/css/v.ttf"]),
            CSSFontFace(family: "swapped", weights: 100...900, sources: ["OPS/css/s.ttf"]),
            CSSFontFace(family: "local", sources: ["OPS/css/l.woff"]),
            CSSFontFace(family: "hints", sources: ["OPS/css/h.woff", "OPS/css/h.ttf"]),
            CSSFontFace(family: "spaced", sources: ["OPS/css/my font.otf", "OPS/css/sub/café.ttf"]),
        ])
    }

    func testAFaceWithoutAFamilyOrAnArchiveSourceIsDroppedAndTheRestKept() {
        let sheet = CSSSyntaxSupport.sheet("""
            @font-face { src: url(a.ttf) }
            @font-face { font-family: NoSource }
            @font-face { font-family: OnlyEOT; src: url(e.eot) format("embedded-opentype") }
            @font-face { font-family: OnlyLocal; src: local(Arial) }
            @font-face { font-family: Data; src: url("data:font/ttf;base64,AAEAAAA=") format("truetype") }
            @font-face { font-family: Escape; src: url("a%5Cb.ttf"), url("%zz.ttf"), url() }
            @font-face { font-family: Climbing; src: url(../../../outside.ttf), url(/fonts/rooted.ttf) }
            @font-face { font-family: 12px; src: url(n.ttf) }
            @font-face { }
            @font-face;
            @font-face { font-family: Kept; src: url(k.ttf) }
            p { clear: both }
            """)
        // `..` stops at the container root and a leading `/` names it, so Climbing's sources are
        // archive paths like any other.
        XCTAssertEqual(sheet.fontFaces, [CSSFontFace(family: "climbing", sources: ["outside.ttf", "fonts/rooted.ttf"]),
                                         CSSFontFace(family: "kept", sources: ["OPS/css/k.ttf"])])
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["p"])
        XCTAssertEqual(sheet.remoteReferences, 0, "A data: URL and a path that cannot be an entry's are not remote references")
    }

    func testRemoteSourcesAreCountedAndOnlyArchiveSourcesKept() {
        let sheet = CSSSyntaxSupport.sheet("""
            @font-face { font-family: Mixed; src: url(https://example.com/m.woff2) format("woff2"), url(//cdn.example.com/m.woff), url(m.ttf) }
            @font-face { font-family: AllRemote; src: url("http://example.com/a.ttf") }
            @font-face { font-family: Skipped; src: url(https://example.com/s.eot) format("embedded-opentype"), url(s.ttf) }
            """)
        XCTAssertEqual(sheet.fontFaces, [CSSFontFace(family: "mixed", sources: ["OPS/css/m.ttf"]), CSSFontFace(family: "skipped", sources: ["OPS/css/s.ttf"])])
        XCTAssertEqual(sheet.remoteReferences, 3, "A source in a format the reader cannot use is not looked at")
    }

    func testAFontFaceInsideAConditionalRuleFollowsItsCondition() {
        XCTAssertEqual(faces("""
            @media print { @font-face { font-family: Print; src: url(p.ttf) } }
            @media screen { @font-face { font-family: Screen; src: url(s.ttf) } }
            @media (prefers-color-scheme: dark) { @font-face { font-family: Dark; src: url(d.ttf) } }
            @supports (bogus: 1) { @font-face { font-family: Unsupported; src: url(u.ttf) } }
            @supports (clear: both) { @media not print { @font-face { font-family: Nested; src: url(n.ttf) } } }
            p { @font-face { font-family: InRule; src: url(i.ttf) } }
            """).map(\.family), ["screen", "dark", "nested"])
    }

    func testTheLastValidDescriptorWinsAndAnInvalidOneNeverClobbersIt() {
        XCTAssertEqual(faces("""
            @font-face { font-family: First; font-family: Second; src: url(a.ttf); font-weight: 300; font-weight: 700; font-style: italic; font-style: normal }
            @font-face { font-family: Kept; src: url(k.ttf); src: bogus; font-weight: 700; font-weight: heavy; font-weight: 0; font-weight: 1001 }
            @font-face { font-family: Usable; src: url(u.ttf); src: url(u.eot) format("embedded-opentype"); src: local(Nothing) }
            """), [
            CSSFontFace(family: "second", weights: 700...700, sources: ["OPS/css/a.ttf"]),
            CSSFontFace(family: "kept", weights: 700...700, sources: ["OPS/css/k.ttf"]),
            CSSFontFace(family: "usable", sources: ["OPS/css/u.ttf"]),
        ])
    }

    func testALaterSrcDescriptorReplacesAnEarlierOne() {
        // The two-`src` "bulletproof" pattern depends on CSS's ordinary rule that a later valid
        // declaration of a descriptor replaces an earlier one: the first `src` is for a browser
        // that cannot parse the second, and no other browser may read it.
        XCTAssertEqual(faces("""
            @font-face { font-family: Bullet; src: url(b.eot);
                         src: url("b.eot?#iefix") format("embedded-opentype"), url(b.woff2) format("woff2"), url(b.ttf) format("truetype") }
            """), [CSSFontFace(family: "bullet", sources: ["OPS/css/b.woff2", "OPS/css/b.ttf"])])
        let replaced = CSSSyntaxSupport.sheet("""
            @font-face { font-family: Remote; src: url(https://example.com/r.woff); src: url(r.ttf) }
            @font-face { font-family: Local; src: url(l.ttf); src: url(https://example.com/l.woff) }
            """)
        XCTAssertEqual(replaced.fontFaces, [CSSFontFace(family: "remote", sources: ["OPS/css/r.ttf"])],
                       "A remote src replaces an archive one as any other does")
        XCTAssertEqual(replaced.remoteReferences, 1, "Only the src that stands would be fetched")
    }
}
