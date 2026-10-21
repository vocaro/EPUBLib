import EPUBCore
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing

/// "A section's characters depend only on its document, never on typography" (doc/native-viewer.md,
/// pipeline step 3). The session relies on it: rendered ranges of search matches and highlights are
/// computed once and kept across font-size and appearance changes. What of the characters is
/// hidden, which search and Copy pass over, is held to it as well.
final class SectionContentInvarianceCoverageTests: XCTestCase {
    private typealias S = SectionContentSupport

    private struct Snapshot: Equatable {
        let string: String
        let map: TextMap
        let anchors: [EPUBElementID: Int]
        let notes: [EPUBElementID: String]
        /// The runs `visibility: hidden` hides (`.readerHidden`).
        let hidden: [NSRange]
        init(_ text: SectionText) {
            string = text.string.string; map = text.map; anchors = text.anchors; notes = text.notes.mapValues(\.string)
            var hidden: [NSRange] = []
            text.string.enumerateAttribute(.readerHidden, in: NSRange(location: 0, length: text.string.length)) { value, run, _ in
                if value != nil { hidden.append(run) }
            }
            self.hidden = hidden
        }
    }

    private static let typographies: [NativeTypography] = ([12, 16, 17, 23, 40, 96] as [CGFloat]).flatMap { size in
        [NativeTypography(fontSize: size, isDark: false), NativeTypography(fontSize: size, isDark: true)]
    }

    private func snapshots(_ body: String, css: String, files: [String: Data] = [:], file: StaticString = #filePath,
                           line: UInt = #line) throws -> [Snapshot] {
        try Self.typographies.map { typography in
            let text = try S.styled(body, css: css, files: files, typography: typography)
            XCTAssertFalse(text.report.withheld, file: file, line: line)
            XCTAssertEqual(S.mapViolations(text, sameCharacters: false) + S.stringViolations(text), [],
                           "\(typography)", file: file, line: line)
            return Snapshot(text)
        }
    }

    private func assertInvariant(_ body: String, css: String = "", files: [String: Data] = [:], file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        let all = try snapshots(body, css: css, files: files, file: file, line: line)
        XCTAssertFalse(all[0].string.isEmpty, file: file, line: line)
        for (snapshot, typography) in zip(all, Self.typographies).dropFirst() {
            XCTAssertEqual(snapshot.string, all[0].string, "characters at \(typography)", file: file, line: line)
            XCTAssertEqual(snapshot.map, all[0].map, "map at \(typography)", file: file, line: line)
            XCTAssertEqual(snapshot.anchors, all[0].anchors, "anchors at \(typography)", file: file, line: line)
            XCTAssertEqual(snapshot.notes, all[0].notes, "notes at \(typography)", file: file, line: line)
            XCTAssertEqual(snapshot.hidden, all[0].hidden, "hidden text at \(typography)", file: file, line: line)
        }
    }

    func testProseListsNotesAndPreformattedTextAreTheSameAtEverySizeAndAppearance() throws {
        try assertInvariant("""
            <h1 id="t">Chapter <span class="caps">the First</span></h1>
            <p id="p1"><span class="cap">I</span>t was a <em>bright</em> day<a epub:type="noteref" href="#n1">1</a>, said <q>the <q>other</q> one</q>.</p>
            <ol id="ol" start="9"><li>nine</li><li>ten<ul><li>inner</li></ul></li><li class="in">eleven</li></ol>
            <pre id="code">  let a = 1\n\tb()\n</pre>
            <p class="upper">straße <ruby>漢<rt>kan</rt></ruby> x<sup>2</sup> <bdo dir="rtl">abc</bdo> long<wbr/>word</p>
            <aside epub:type="footnote" id="n1"><p>A <b>note</b>.</p></aside>
            <dl><dt>Term</dt><dd>Definition</dd></dl><p hidden="">never</p><p class="tiny">tiny</p><p class="huge">huge</p>
            """, css: """
            .caps { font-variant: small-caps } .cap { float: left; font-size: 3em; line-height: 1 } .upper { text-transform: uppercase }
            .in { list-style-position: inside } .tiny { font-size: 1px } .huge { font-size: 30em } pre { tab-size: 4 }
            p { margin: 1em 5%; text-indent: 1.5em; letter-spacing: 0.01em; word-spacing: 0.1em } body { font-size: 110% }
            """)
    }

    func testImagesFormulasTablesAndDrawingsAreTheSameAtEverySizeAndAppearance() throws {
        try assertInvariant("""
            <p>An image <img id="i1" src="photo.png" alt="A photo"/>, a missing one <img id="i2" src="gone.png" alt="Gone"/> and
            <math xmlns="http://www.w3.org/1998/Math/MathML" id="m1"><mfrac><mi>a</mi><mn>2</mn></mfrac></math> inline.</p>
            <math xmlns="http://www.w3.org/1998/Math/MathML" display="block" id="m2"><mrow><mi>x</mi><mo>=</mo><msqrt><mn>2</mn></msqrt><mo>+</mo>
            <mi>y</mi><mo>+</mo><mi>z</mi><mo>+</mo><mi>w</mi><mo>+</mo><mfrac><mn>1</mn><mn>3</mn></mfrac></mrow></math>
            <figure id="f"><img src="photo.png" alt="" style="width: 50%"/><figcaption>A caption</figcaption></figure>
            <table id="t"><caption>Table</caption><thead><tr><th>Name</th><th>Value</th></tr></thead>
            <tbody><tr><td id="c">one</td><td>1</td></tr><tr><td>two</td><td><p>2</p><p>two</p></td></tr></tbody></table>
            <table id="callout"><tr><td><p>A one-column callout.</p></td></tr></table>
            <svg xmlns="http://www.w3.org/2000/svg" id="s" width="10em" height="4em" viewBox="0 0 100 40"><rect width="100" height="40"/>
            <text x="5" y="20">label</text></svg><hr/><p>End.</p>
            """, css: "img { max-width: 100% } table { width: 100%; font-size: 0.8em } th { padding: 0.5em }",
            files: ["photo.png": RichFixture.image(width: 64, height: 48)])
    }

    func testFontRelativeMediaQueriesOffsetsAndBoxesDoNotMakeCharactersDependOnFontSize() throws {
        // Media queries see a nominal viewport with a 16px em, and the offset that hides a positioned label counts
        // an em as the same 16px: neither looks at the reader's size.
        try assertInvariant("""
            <p>Start <span class="wide">wide</span> <span class="narrow">narrow</span> <span class="tall">tall</span>.</p>
            <p>Labels <span class="em">em-offscreen</span> <span class="near">em-near</span> <span class="px">px-offscreen</span> \
            <span class="clip">clipped</span>.</p>
            <div class="box"><p>Boxed <span class="ib">inline block</span> text.</p></div><p class="vw">viewport</p>
            """, css: """
            @media (min-width: 30em) { .wide { display: none } } @media (max-width: 30em) { .narrow { display: none } }
            @media (min-height: 60em) { .tall { display: none } }
            .em { position: absolute; left: -999em } .near { position: absolute; left: -62em } .px { position: absolute; left: -9999px }
            .clip { position: absolute; clip: rect(0 0 0 0); width: 1px; height: 1px; overflow: hidden }
            .box { position: relative; width: 20em; min-height: 10em; margin: 0 auto } .ib { display: inline-block; width: 5em }
            .vw { font-size: 5vw; margin-left: calc(10% + 2em) }
            """)
    }

    func testBookColorSchemeQueriesDoNotChangeCharactersBetweenAppearances() throws {
        // A book may show different content per appearance (a diagram drawn for each, say). The reader keeps
        // rendered ranges across an appearance change, which holds only while the characters stay the same,
        // so what a color-scheme query does to them is resolved as in the light appearance (#130).
        let body = "<p>See the <span class='for-light'>black</span><span class='for-dark'>white-on-black</span> figure.</p><p id='after'>After.</p>"
        let css = ".for-dark { display: none } @media (prefers-color-scheme: dark) { .for-light { display: none } .for-dark { display: inline } }"
        let light = try S.styled(body, css: css, typography: NativeTypography(fontSize: 16, isDark: false))
        let dark = try S.styled(body, css: css, typography: NativeTypography(fontSize: 16, isDark: true))
        XCTAssertEqual(light.string.string, "See the black figure.\nAfter.")
        XCTAssertEqual(dark.string.string, light.string.string)
        XCTAssertEqual(light.anchors["after"], 22)
        XCTAssertEqual(dark.anchors["after"], light.anchors["after"])
        XCTAssertEqual(Snapshot(dark), Snapshot(light))
        try assertInvariant(body, css: css)
    }

    func testColorSchemeQueriesCannotChangeCharactersThroughAnyPropertyThatShapesThem() throws {
        // Each rule here would change characters, what of them is hidden or how they map, in one appearance:
        // shown and hidden content, case, markers, collapsed white space, hidden text, labels kept for
        // assistive technology, flow boxes, flex items, table cells and notes.
        let body = """
            <h1 id="h">Chapter <span class="case">one</span></h1>
            <p id="p1">Some <span class="gone">gone</span> and <span class="kept">kept</span> words.</p>
            <ol id="ol"><li>first</li><li class="in">second</li></ol><ul><li>dot</li></ul>
            <p class="pre">  spaced   out
              lines  </p>
            <p>Shown <span class="vis">maybe</span> text <span class="label">label</span> and <span class="clip">clipped</span>.</p>
            <p><span class="cap">D</span>rop and <span class="box">boxed</span> text.</p>
            <div class="grid"><p>One</p><p>Two</p></div>
            <table id="t"><tr><td class="cell">a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>
            <p id="end">End <a epub:type="noteref" href="#n1">1</a>.</p><aside epub:type="footnote" id="n1"><p class="note">A Note.</p></aside>
            """
        let css = """
            .gone { display: none }
            @media (prefers-color-scheme: dark) {
              .case { text-transform: uppercase } .gone { display: inline } .kept { display: none }
              ol { list-style-type: upper-roman } .in { list-style-position: inside } ul { list-style-type: "-> " }
              .pre { white-space: pre } .vis { visibility: hidden } .label { position: absolute; left: -9999px }
              .clip { position: absolute; clip: rect(0 0 0 0); width: 1px; height: 1px; overflow: hidden }
              .cap { float: left; font-size: 3em } .box { display: inline-block; width: 5em }
              .grid { display: flex } td { border: 1px solid } .cell { display: block } #h { display: none }
              .note { text-transform: lowercase } aside { display: block }
            }
            @media (prefers-color-scheme: light) { #p1 { text-transform: capitalize } ol { list-style-type: lower-alpha } }
            @media not all and (prefers-color-scheme: light) { #end { display: list-item; list-style-type: decimal } }
            """
        try assertInvariant(body, css: css)
        let light = try S.styled(body, css: css, typography: NativeTypography(fontSize: 16, isDark: false))
        let paragraphs = S.paragraphs(light)
        XCTAssertEqual(Array(paragraphs.prefix(2)), ["Chapter one", "Some And Kept Words."], "The light appearance's rules")
        XCTAssertTrue(paragraphs[2].contains("a.") && paragraphs[2].contains("first"), S.escape(light.string.string))
        XCTAssertEqual(light.notes["n1"]?.string, "A Note.")
    }

    func testColorSchemeStylesheetsImportsAndPseudoElementsCannotChangeCharacters() throws {
        // A stylesheet linked or imported for one appearance is a rule for it, and so is generated content.
        let files = [
            "dark.css": Data(".light { display: none } .dark { display: inline }".utf8),
            "main.css": Data("@import 'night.css' (prefers-color-scheme: dark); .dark { display: none }".utf8),
            "night.css": Data("p { text-transform: uppercase } .extra::after { content: ' more' }".utf8),
        ]
        let head = """
            <link rel="stylesheet" href="main.css"/><link rel="stylesheet" href="dark.css" media="(prefers-color-scheme: dark)"/>
            <style media="(prefers-color-scheme: dark)">.extra::before { content: 'some ' } .extra { display: block }</style>
            """
        let body = "<p>A <span class='light'>light</span><span class='dark'>dark</span> <span class='extra'>word</span>.</p><p id='after'>After.</p>"
        let texts = try [false, true].map { dark in
            try S.styled(body, head: head, files: files, typography: NativeTypography(fontSize: 16, isDark: dark))
        }
        XCTAssertEqual(texts[0].string.string, "A light word.\nAfter.")
        XCTAssertEqual(Snapshot(texts[1]), Snapshot(texts[0]))
    }

    func testColorSchemeQueriesStillPaintInTheirOwnAppearance() throws {
        // Only what paints follows the appearance. Standard Ebooks inverts black-on-transparent art in dark
        // appearance, and a book's colours for dark appearance never reach the light one.
        let body = "<p>An <img id='i' src='art.png' alt='Art'/> and <span class='ink'>inked</span> words.</p>"
        let css = "@media (prefers-color-scheme: dark) { img { filter: invert(100%) } .ink { color: rgb(255, 0, 0) } }"
        let files = ["art.png": RichFixture.image(width: 8, height: 8)]
        let light = try S.styled(body, css: css, files: files, typography: NativeTypography(fontSize: 16, isDark: false))
        let dark = try S.styled(body, css: css, files: files, typography: NativeTypography(fontSize: 16, isDark: true))
        XCTAssertEqual(Snapshot(dark), Snapshot(light))
        XCTAssertEqual(light.richMediaImages.map(\.invertsColors), [false])
        XCTAssertEqual(dark.richMediaImages.map(\.invertsColors), [true])
        let ink = BuilderHarness.attribute(.foregroundColor, of: "inked", in: light) as? PlatformColor
        XCTAssertEqual(ink, ReaderPalette.text(dark: false))
    }

    func testBuildingTheSameSectionTwiceGivesTheSameText() throws {
        let body = "<h1 id='a'>T</h1><p>Some <b>text</b> with a <a href='#a'>link</a>.</p><ul><li>x</li></ul>"
        let first = try S.styled(body), second = try S.styled(body)
        XCTAssertEqual(Snapshot(first), Snapshot(second))
        XCTAssertEqual(first.report, second.report)
    }

    func testTheDocumentsOwnLanguageAndThePublicationsDoNotChangeCharacters() throws {
        // Language tailors case mappings and quotation marks; it comes from the document, never the device.
        let text = try S.raw("""
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="tr"><head><title>T</title><style>p { text-transform: uppercase }</style></head>\
            <body><p>istanbul</p><p lang="en">istanbul</p></body></html>
            """)
        XCTAssertEqual(text.string.string, "İSTANBUL\nISTANBUL")
    }
}
