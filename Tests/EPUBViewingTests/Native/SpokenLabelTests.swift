import CoreGraphics
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Hidden labels kept for assistive technology (`SpokenLabelAttachment`, "Floats and positioned
/// boxes" in `doc/native-viewer.md`): what a hidden box says, where it stands in the text, and
/// that the page is laid out exactly as the same book lays out with the box taken away.
@MainActor final class SpokenLabelTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let size = CGSize(width: 360, height: 600)

    /// The two ways books hide a label from the eye alone.
    private static let hide = ".sr { position:absolute; left:-999em } "
        + ".clip { position:absolute; width:1px; height:1px; overflow:hidden; clip:rect(0 0 0 0) } "
    /// The same book with those boxes taken out, to lay out beside it.
    private static let gone = ".sr, .clip { display:none !important } "

    private struct Line: Equatable {
        let page: Int
        let text: String
        let frame: CGRect
    }

    /// Every line that draws something, page by page: its drawn characters and its frame from the
    /// top of the page's column.
    private func drawnLines(_ section: SectionText, size: CGSize) -> [Line] {
        let (paginator, pages) = H.pages(section, size: size)
        var lines: [Line] = []
        for (index, page) in pages.enumerated() {
            let view = H.pageView(paginator, page: page)
            let storage = view.contentStorage.textStorage ?? NSTextStorage()
            for line in H.lines(in: view, intersecting: view.shownCharacters) {
                let shown = NSIntersectionRange(line.range, view.shownCharacters)
                let drawn = storage.attributedSubstring(from: shown).drawnString.trimmingCharacters(in: .newlines)
                guard !drawn.isEmpty else { continue }
                lines.append(Line(page: index, text: drawn, frame: line.frame.offsetBy(dx: 0, dy: page.topSpacing)))
            }
        }
        return lines
    }

    /// Builds `body` with its `.sr` and `.clip` boxes hidden and with them gone, and requires
    /// the same drawn characters on the same lines in the same places, page by page.
    @discardableResult
    private func assertLaidOutAsWithoutItsLabels(_ body: String, css: String = "", labels: [String], size: CGSize? = nil,
                                                 files: [String: Data] = [:], file: StaticString = #filePath,
                                                 line: UInt = #line) throws -> SectionText {
        let size = size ?? self.size
        let spoken = try H.build(body, css: H.reset + css + Self.hide, files: files)
        let plain = try H.build(body, css: H.reset + css + Self.gone, files: files)
        XCTAssertEqual(spoken.string.spokenLabels, labels, file: file, line: line)
        XCTAssertEqual(plain.string.spokenLabels, [], file: file, line: line)
        XCTAssertEqual(spoken.string.drawnString, plain.string.string, "the same drawn characters", file: file, line: line)
        XCTAssertEqual(spoken.report, plain.report, "nothing more is disclosed", file: file, line: line)
        BuilderHarness.assertMapRoundTrips(spoken, file: file, line: line)
        let with = drawnLines(spoken, size: size), without = drawnLines(plain, size: size)
        XCTAssertEqual(with.map(\.text), without.map(\.text), "the same lines", file: file, line: line)
        XCTAssertEqual(with.map(\.page), without.map(\.page), "on the same pages", file: file, line: line)
        for (a, b) in zip(with, without) {
            // A label's own line is a thousandth of a point tall.
            for (x, y) in [(a.frame.minX, b.frame.minX), (a.frame.minY, b.frame.minY), (a.frame.width, b.frame.width),
                           (a.frame.height, b.frame.height)] {
                XCTAssertEqual(x, y, accuracy: 0.25, "\(a.text) on page \(a.page + 1): \(a.frame) and \(b.frame)", file: file, line: line)
            }
        }
        return spoken
    }

    private func labels(_ body: String, css: String = "", files: [String: Data] = [:]) throws -> [SpokenLabelAttachment] {
        let section = try H.build(body, css: H.reset + Self.hide + css, files: files)
        var labels: [SpokenLabelAttachment] = []
        section.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: section.string.length)) { value, _, _ in
            if let label = value as? SpokenLabelAttachment { labels.append(label) }
        }
        return labels
    }

    // MARK: What a hidden box says

    func testAHiddenBoxSaysWhatABrowserReadsOfIt() throws {
        let image = ["map.png": RichFixture.image(width: 40, height: 30)]
        for (body, expected) in [
            // Its text, white space collapsed, through inline markup.
            ("<p class='sr'>  Chapter\n <b>the <i>first</i></b>  </p>", ["Chapter the first"]),
            ("<p>Shown <span class='clip'>and  heard</span>.</p>", ["and heard"]),
            // What stands for text is read by its alternative; a line break is a space.
            ("<p class='sr'>Figure <img alt='A map of the bay' src='map.png'/>, then<br/>more</p>", ["Figure A map of the bay , then more"]),
            ("<p class='sr'>A formula <m:math alttext='x squared'><m:msup><m:mi>x</m:mi><m:mn>2</m:mn></m:msup></m:math></p>", ["A formula x squared"]),
            ("<p class='sr'><ruby>漢<rt>kan</rt></ruby> read</p>", ["漢 read"]),
            // Each block of it is a label of its own, in order.
            ("<div class='sr'>Lead <p>One.</p><p>Two <b>bold</b>.</p> tail</div>", ["Lead", "One.", "Two bold.", "tail"]),
            ("<div class='sr'><ul><li>First</li><li>Second</li></ul></div>", ["First", "Second"]),
            // What is hidden from assistive technology too is not read.
            ("<p class='sr'>Kept<span style='display:none'> dropped</span><span style='visibility:hidden'> unseen</span>"
                + "<span aria-hidden='true'> unheard</span>.</p>", ["Kept."]),
            ("<p class='sr' aria-hidden='true'>Hidden from everyone</p><p>Shown.</p>", []),
            ("<p class='sr' style='visibility:hidden'>Hidden from everyone</p><p>Shown.</p>", []),
            ("<p class='sr' style='display:none'>Not there</p><p>Shown.</p>", []),
            // A box with no words says nothing.
            ("<p class='sr'> \n </p><p class='sr'><img alt='' src='map.png'/></p><p>Shown.</p>", []),
        ] {
            XCTAssertEqual(try labels(body, files: image).map(\.text), expected, body)
        }
    }

    func testALabelKeepsTheLanguageItDeclaresAndTheLinkItIs() throws {
        var found = try labels("<p class='sr' lang='fr'>Bonjour</p><p class='sr'>Hello</p><div class='sr' xml:lang='de'><p>Eins</p><p lang='it'>Due</p></div>")
        XCTAssertEqual(found.map(\.textLanguage), ["fr", nil, "de", "it"], "its own language, or none: the text around it has none either")
        XCTAssertEqual(found.map(\.textEquivalent), ["Bonjour", "Hello", "Eins", "Due"])
        found = try labels("<p class='sr'>Plain</p>")
        XCTAssertEqual(found[0].layoutBounds(.init(width: 300, viewport: size)), .zero, "it takes no room")
        XCTAssertEqual(found[0].contentWidths().max, 0)
        XCTAssertNil(found[0].image(forBounds: CGRect(x: 0, y: 0, width: 10, height: 10), textContainer: nil, characterIndex: 0))
        // A hidden link, such as a skip link, is still a link.
        let section = try H.build("<p><a class='sr' href='two.xhtml#top'>Skip to chapter two</a>Shown <a href='two.xhtml'><span class='sr'>inside a link</span>here</a>.</p>",
                                  css: H.reset + Self.hide)
        XCTAssertEqual(section.string.spokenLabels, ["Skip to chapter two", "inside a link"])
        var links: [ReaderLink?] = []
        section.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: section.string.length)) { value, range, _ in
            guard value is SpokenLabelAttachment else { return }
            links.append((section.string.attribute(.link, at: range.location, effectiveRange: nil) as? URL).flatMap(ReaderLink.init(url:)))
        }
        XCTAssertEqual(links, [.internal(href: "OPS/two.xhtml#top"), .internal(href: "OPS/two.xhtml")])
    }

    // MARK: In a line

    func testALabelInALineStandsWhereItsBoxDoesAndTheLineIsSetAsWithoutIt() throws {
        let prose = H.prose.split(separator: " ").map(String.init)
        let half = prose.count / 2
        for (body, css, labels) in [
            ("<p>Some <span class='sr'>hidden words</span> text on a line.</p>", "", ["hidden words"]),
            ("<p>Some<span class='sr'>hidden</span> text and <span class='clip'>clipped</span>more <span class='sr'>end</span></p><p>Next.</p>",
             "", ["hidden", "clipped", "end"]),
            ("<p><span class='sr'>lead</span> Text at the start.</p>", "", ["lead"]),
            ("<p>Line one<br/><span class='sr'>between</span>line two</p>", "", ["between"]),
            // A block-level box in a run of text does not end the line.
            ("<div>Words before <p class='sr'>a block label</p> and words after on the same line.</div>", "", ["a block label"]),
            // Wrapping, justification and centring are those of the words alone.
            ("<p>\(prose[..<half].joined(separator: " ")) <span class='sr'>in the middle</span> \(prose[half...].joined(separator: " "))</p>",
             "p { text-align:justify }", ["in the middle"]),
            ("<p><span class='clip'>before</span>Centred words<span class='sr'>after</span></p>", "p { text-align:center }", ["before", "after"]),
            ("<p>End aligned <span class='sr'>last</span></p>", "p { text-align:right }", ["last"]),
        ] {
            try assertLaidOutAsWithoutItsLabels(body, css: css, labels: labels)
        }
        let section = try H.build("<p id='p'>Some <span id='h' class='sr'>hidden <b id='b'>words</b></span> text.</p>", css: H.reset + Self.hide)
        XCTAssertEqual(section.string.string, "Some \u{FFFC}text.", "one space, and the label where the box stands")
        XCTAssertEqual(section.string.readerPlainText(), "Some hidden words text.")
        XCTAssertEqual(section.anchors["h"], 5)
        XCTAssertEqual(section.anchors["b"], 5, "an id inside the box is the label")
        let bold = try XCTUnwrap(section.document.element(id: "b")?.children.first)
        XCTAssertEqual(section.map.location(of: DOMPosition(bold, 2)), 5)
        XCTAssertEqual(section.map.location(of: DOMPosition(bold, 2), isEnd: true), 6)
        let position = try XCTUnwrap(section.map.position(at: 5, in: section.document))
        XCTAssertTrue(position.node === section.document.element(id: "h"), "the label's character is its box")
    }

    // MARK: Between blocks

    func testALabelBetweenBlocksHasALineOfNoHeightAndTheBlocksLieAsWithoutIt() throws {
        let files = ["title.png": RichFixture.image(width: 300, height: 90)]
        for (body, css, labels) in [
            // Margins collapse between the paragraphs around it.
            ("<p class='a'>One.</p><h2 class='sr'>Hidden heading</h2><p class='b'>Two.</p><p>Three.</p>",
             ".a { margin-bottom:30px } .b { margin-top:20px }", ["Hidden heading"]),
            // The section's leading gap is above it and the paragraph it precedes.
            ("<h1 class='sr'>Title</h1><p class='sr'>By someone.</p><p class='b'>First.</p><p>Second.</p>", ".b { margin-top:40px }",
             ["Title", "By someone."]),
            ("<h1 class='sr'>Title</h1><img alt='' src='title.png'/><p>After the image.</p>", "img { display:block; margin:48px auto 0; width:50% }", ["Title"]),
            // A box's first paragraph is still its first: `text-indent` and a list item's marker.
            ("<p class='i'><span class='sr' style='display:block'>Label</span>An indented first line of a paragraph that runs on for a while.</p><p class='i'>Another.</p>",
             ".i { text-indent:2em }", ["Label"]),
            ("<ol><li><p class='sr'>Hidden in the item</p>Item text</li><li><span class='sr'>Inline</span> second item</li></ol>",
             "ol { margin:0; padding-left:40px }", ["Hidden in the item", "Inline"]),
            // A box that holds nothing else is still empty: margins collapse through it.
            ("<p>One.</p><div class='box'><p class='sr'>Only a label</p></div><p>Two.</p>", ".box { margin:20px 0 }", ["Only a label"]),
            ("<p>One.</p><blockquote><h3 class='sr'>Quotation</h3><p>Quoted words.</p></blockquote><p>Two.</p>",
             "blockquote { margin:16px 32px; padding:10px }", ["Quotation"]),
            // Several blocks of a hidden box, and a label that ends the section.
            ("<p>Shown.</p><div class='sr'><p>One.</p><p>Two.</p></div><p>Also shown.</p><p class='sr'>The end</p>", "p { margin:12px 0 }",
             ["One.", "Two.", "The end"]),
            // Before a table and inside a float.
            ("<h2 class='sr'>Table of values</h2><table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table><p>After.</p>", "",
             ["Table of values"]),
            // A float is measured by its paragraphs, so in one a label joins the content after it:
            // text, or block content, which it then follows.
            ("<div class='f'><p class='sr'>Float label</p>Float words.</div><p>\(H.prose)</p>", ".f { float:left; width:120px }", ["Float label"]),
            ("<div class='f'><p class='sr'>Figure label</p><img alt='' src='title.png' style='display:block; width:60px'/></div><p>\(H.prose)</p>",
             ".f { float:left; width:120px }", ["Figure label"]),
        ] {
            try assertLaidOutAsWithoutItsLabels(body, css: css, labels: labels, files: files)
        }
        // Each block-level label is a paragraph by itself; labels met together in a line share one.
        let section = try H.build("<p id='a'>One.</p><h2 id='h' class='sr'>Heading</h2><span class='sr'>x</span><span class='clip'>y</span><p id='b'>Two.</p>",
                                  css: H.reset + Self.hide)
        XCTAssertEqual(section.string.string, "One.\n\u{FFFC}\n\u{FFFC}\u{FFFC}\nTwo.")
        XCTAssertEqual(section.string.readerPlainText(), "One.\nHeading\nx y\nTwo.")
        XCTAssertEqual(section.anchors["h"], 5)
        XCTAssertEqual(section.anchors["b"], 10)
        let style = try XCTUnwrap(section.string.attribute(.paragraphStyle, at: 5, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.maximumLineHeight, SpokenLabelAttachment.lineHeight)
        XCTAssertEqual(style.paragraphSpacing + style.paragraphSpacingBefore, 0)
        XCTAssertEqual(section.string.attribute(.readerKeepWithNext, at: 5, effectiveRange: nil) as? Bool, true, "it stays with what it precedes")
    }

    func testAHiddenBoxInAnAlignedContainerLeavesItsItemsWhereTheyWere() throws {
        typealias F = Fixture.Alignment
        // Standard Ebooks' dedication with a hidden heading opening the flex container and one between its items.
        let body = """
            <section class="epub-type-contains-word-dedication" id="dedication" epub:type="dedication">\
            <h2 class="sr">Dedication</h2><p class="first-child">For those<br/>who read</p><p class="clip">A second hidden line</p>\
            <p>to the last page</p></section>
            """
        let section = try assertLaidOutAsWithoutItsLabels(body, css: F.shippedCSS, labels: ["Dedication", "A second hidden line"],
                                                          size: CGSize(width: 400, height: 640))
        XCTAssertFalse(section.report.flexGridSimplified)
        // The box is still one run of paragraphs, the labels' lines among them: a position
        // anywhere in it finds the whole box (`ReaderAlignmentLayout.boxes`).
        let whole = NSRange(location: 0, length: section.string.length)
        XCTAssertEqual(section.string.string, "\u{FFFC}\nFor those\u{2028}who read\n\u{FFFC}\nto the last page")
        for location in [0, 4, 20, 22, section.string.length - 1] {
            XCTAssertEqual(ReaderAlignmentLayout.boxes(in: section.string, around: location), [whole], "from \(location)")
        }
        // A row of sized inline blocks goes on across a hidden box between two of them.
        try assertLaidOutAsWithoutItsLabels(
            "<p>Before <span class='b'>one</span><span class='sr'>inline label</span><span class='b'>two</span>"
                + "<span class='clip' style='display:block'>block label</span><span class='b'>three</span> after.</p>",
            css: ".b { display:inline-block; width:60px }", labels: ["inline label", "block label"])
    }

    // MARK: Pages

    func testAForcedBreakOpensAtTheLabelAndKeepsTheGapBelowIt() throws {
        let body = "<p>One.</p><section class='c'><h2 id='h' class='sr'>Chapter two</h2><p class='b'>Two.</p></section>"
        let section = try assertLaidOutAsWithoutItsLabels(body, css: ".c { break-before:page } .b { margin-top:40px }", labels: ["Chapter two"])
        let (_, pages) = H.pages(section, size: size)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[1].range.location, section.anchors["h"], "the label is read on the page it introduces")
        XCTAssertEqual(pages[1].topSpacing, 40, accuracy: 0.5, "the margin is kept after a forced break")
    }

    func testAnUnforcedBreakNeverPartsALabelFromWhatItPrecedes() throws {
        // Forty paragraphs with a hidden heading before every fifth: page breaks fall as without them.
        var body = "", headings: [String] = []
        for index in 1...40 {
            if index % 5 == 0 { body += "<h2 class='sr' id='h\(index)'>Hidden heading \(index)</h2>"; headings.append("Hidden heading \(index)") }
            body += "<p id='p\(index)'>Paragraph \(index) of ordinary prose that wraps over more than one line of this narrow column.</p>"
        }
        let size = CGSize(width: 300, height: 420)
        let section = try assertLaidOutAsWithoutItsLabels(body, css: "p { margin:0 0 14px }", labels: headings, size: size)
        let (_, pages) = H.pages(section, size: size)
        XCTAssertGreaterThan(pages.count, 3)
        for index in stride(from: 5, through: 40, by: 5) {
            let label = try XCTUnwrap(section.anchors["h\(index)"]), paragraph = try XCTUnwrap(section.anchors["p\(index)"])
            XCTAssertEqual(paragraph, label + 2)
            let page = try XCTUnwrap(pages.firstIndex { NSLocationInRange(label, $0.range) })
            XCTAssertTrue(NSLocationInRange(paragraph, pages[page].range), "heading \(index) is on the page of its paragraph")
            // The gap above them is the earlier paragraph's, so a page that opens at the label opens flush.
            if pages[page].range.location == label { XCTAssertEqual(pages[page].topSpacing, 0, "page \(page + 1)") }
        }
    }

    // MARK: Text sizes, cells and notes

    func testLabelsAreTheSameCharactersAtEveryTextSize() throws {
        let body = "<h1 class='sr'>Title</h1><p>Some <span class='clip'>hidden</span> text.</p><div class='sr'><p>One.</p><p>Two.</p></div><p>End.</p>"
        var first: SectionText?
        for fontSize: CGFloat in [12, 17, 28, 96] {
            let section = try H.build(body, css: H.reset + Self.hide, fontSize: fontSize)
            XCTAssertEqual(section.string.spokenLabels, ["Title", "hidden", "One.", "Two."], "\(fontSize)")
            H.pages(section, size: size, "\(fontSize)")
            if let first {
                XCTAssertEqual(section.string.string, first.string.string, "\(fontSize)")
                XCTAssertEqual(section.map, first.map, "\(fontSize)")
                XCTAssertEqual(section.anchors, first.anchors, "\(fontSize)")
            } else { first = section }
        }
    }

    func testALabelInATableCellOrANoteJoinsItsContentWithoutALineOfItsOwn() throws {
        let table = try H.build("<table><tr><th><p class='sr'>Column heading</p>A</th><td>b<span class='clip'>hidden in a cell</span></td></tr></table>",
                                css: H.reset + Self.hide)
        let spoken = table.string.readerPlainText()
        XCTAssertTrue(spoken.contains("Column heading") && spoken.contains("hidden in a cell"), spoken)
        let noted = try H.build("""
            <p>Text<a epub:type="noteref" href="#n">1</a>.</p>\
            <aside epub:type="footnote" id="n"><h2 class="sr">Note</h2><p>The note's words.</p><p class="clip">Its hidden close</p></aside>
            """, css: H.reset + Self.hide)
        let note = try XCTUnwrap(noted.notes["n"])
        XCTAssertEqual(note.spokenLabels, ["Note", "Its hidden close"])
        XCTAssertEqual(note.drawnString, "The note's words.", "a note's paragraphs are plain: the labels join them")
        XCTAssertEqual(note.readerPlainText(), "Note The note's words. Its hidden close")
        XCTAssertEqual(noted.string.spokenLabels, [], "the note itself is shown in its popover, not in the page")
    }
}
