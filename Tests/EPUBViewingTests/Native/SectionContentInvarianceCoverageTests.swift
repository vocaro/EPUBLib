import EPUBCore
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing

/// "A section's characters depend only on its document, never on typography" (doc/native-viewer.md,
/// pipeline step 3). The session relies on it: rendered ranges of search matches and highlights are
/// computed once and kept across font-size and appearance changes.
final class SectionContentInvarianceCoverageTests: XCTestCase {
    private typealias S = SectionContentSupport

    private struct Snapshot: Equatable {
        let string: String
        let map: TextMap
        let anchors: [String: Int]
        let notes: [String: String]
        init(_ text: SectionText) {
            string = text.string.string; map = text.map; anchors = text.anchors; notes = text.notes.mapValues(\.string)
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
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/130")
        // A book may show different content per appearance (a diagram drawn for each, say). The reader keeps
        // rendered ranges across an appearance change, which holds only while the characters stay the same.
        let body = "<p>See the <span class='for-light'>black</span><span class='for-dark'>white-on-black</span> figure.</p><p id='after'>After.</p>"
        let css = ".for-dark { display: none } @media (prefers-color-scheme: dark) { .for-light { display: none } .for-dark { display: inline } }"
        let light = try S.styled(body, css: css, typography: NativeTypography(fontSize: 16, isDark: false))
        let dark = try S.styled(body, css: css, typography: NativeTypography(fontSize: 16, isDark: true))
        XCTAssertEqual(dark.string.string, light.string.string)
        XCTAssertEqual(dark.anchors["after"], light.anchors["after"])
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
