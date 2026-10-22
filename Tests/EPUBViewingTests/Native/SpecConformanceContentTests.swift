import CoreText
import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One requirement of EPUB 3.3 or EPUB Reading Systems 3.3 per test, for content documents, from
/// the archive's bytes to the attributed text the reader lays out: what is shown and in what
/// order, with which paragraph formatting, attachments, links and anchors, and what is disclosed.
@MainActor final class SpecConformanceContentTests: XCTestCase {
    private typealias Book = Fixture.SpecBook
    private typealias Build = SpecConformanceBuild

    private func build(_ body: String, head: String = "", root: String = "", configure: (inout Book) -> Void = { _ in }) throws -> Build {
        var book = Book()
        book.add("chapter", head: head, root: root, body: body)
        configure(&book)
        return try Build(book)
    }

    // MARK: XHTML content documents (RS 3.3 section 6.1) and the user-agent defaults (6.3)

    /// RS 6.1 and 6.3: an XHTML content document renders with HTML's semantics and suggested
    /// default rendering: blocks in document order, headings bold and larger, quotations
    /// indented, list items marked, preformatted lines kept, a rule drawn.
    func testAnXHTMLDocumentReadsInDocumentOrderWithHTMLsDefaultRendering() throws {
        let book = try build("""

            <h1 id="title">A Title</h1>
            <p id="first">First paragraph with <em>emphasis</em> and
               <strong>strength</strong>.</p>
            <blockquote><p>A quotation.</p></blockquote>
            <ol><li>One</li><li id="two">Two<ul><li>Nested</li></ul></li></ol>
            <pre>line 1
              line 2</pre>
            <p>Before<br/>after.</p>
            <hr/>
            <p id="last">Last paragraph.</p>

            """)
        let section = book[0]
        XCTAssertEqual(section.specText, "A Title\nFirst paragraph with emphasis and strength.\nA quotation.\n1.\tOne\n2.\tTwo\n◦\tNested\n"
            + "line 1\u{2028}  line 2\nBefore\u{2028}after.\n\u{FFFC}\nLast paragraph.")
        XCTAssertEqual(section.title, "chapter")
        XCTAssertNil(book.disclosure)
        // Fonts: 2em bold heading, the body's size, italic and bold runs, a monospaced block.
        let body = section.specFont("First paragraph"), heading = section.specFont("A Title")
        XCTAssertEqual(body.pointSize, 16)
        XCTAssertEqual(heading.pointSize, 32)
        XCTAssertTrue(CTFontGetSymbolicTraits(heading as CTFont).contains(.traitBold))
        XCTAssertFalse(CTFontGetSymbolicTraits(body as CTFont).contains(.traitBold))
        XCTAssertTrue(CTFontGetSymbolicTraits(section.specFont("emphasis") as CTFont).contains(.traitItalic))
        XCTAssertTrue(CTFontGetSymbolicTraits(section.specFont("strength") as CTFont).contains(.traitBold))
        XCTAssertTrue(CTFontGetSymbolicTraits(section.specFont("line 1") as CTFont).contains(.traitMonoSpace))
        // Paragraphs: 1em between paragraphs, the heading's own margins, 40px quotation indents.
        let first = section.specParagraph("First paragraph"), quotation = section.specParagraph("A quotation.")
        XCTAssertEqual(section.specParagraph("A Title").paragraphSpacingBefore, 0.67 * 32, accuracy: 0.01)
        XCTAssertEqual(section.specParagraph("A Title").paragraphSpacing, 0.67 * 32, accuracy: 0.01, "the larger of the adjoining margins")
        XCTAssertEqual(first.paragraphSpacing, 16, accuracy: 0.01)
        XCTAssertEqual(first.headIndent, 0); XCTAssertEqual(first.firstLineHeadIndent, 0); XCTAssertEqual(first.tailIndent, 0)
        XCTAssertEqual(first.alignment, .natural)
        XCTAssertEqual(first.baseWritingDirection, .leftToRight)
        XCTAssertEqual(quotation.headIndent, 40); XCTAssertEqual(quotation.firstLineHeadIndent, 40); XCTAssertEqual(quotation.tailIndent, -40)
        // Lists: a hanging marker inside the list's 2em padding; the nested list is 2em further in.
        let one = section.specParagraph("One"), nested = section.specParagraph("Nested")
        XCTAssertEqual(one.headIndent, 32); XCTAssertLessThan(one.firstLineHeadIndent, 32)
        XCTAssertEqual(nested.headIndent, 64)
        XCTAssertEqual(section.specAttribute(.readerKeepWithNext, at: "A Title"), true, "a heading stays with what it heads")
        XCTAssertTrue(section.specAttachments.first?.attachment is ReaderRuleAttachment)
        // Anchors are where their elements' first rendered characters are.
        XCTAssertEqual(section.anchors["title"], 0)
        XCTAssertEqual(section.anchors["first"], section.specLocation("First paragraph"))
        XCTAssertEqual(section.anchors["two"], section.specLocation("2.\tTwo"))
        XCTAssertEqual(section.anchors["last"], section.specLocation("Last paragraph."))
        try book.assertPositionsRoundTrip()
    }

    /// HTML's `hidden` attribute (and `display: none`) takes content out of the flow; a link to
    /// something hidden still has somewhere to go: its anchor is the next thing rendered.
    func testHiddenContentLeavesTheFlowAndKeepsItsAnchors() throws {
        let book = try build("""
            <p>Shown first.</p>
            <p hidden="hidden" id="attribute">Hidden by its attribute.</p>
            <section hidden="" id="empty-value"><p>Hidden with <span id="inner">its section</span>.</p></section>
            <div style="display: none" id="styled">Hidden by its style.</div>
            <p id="after">Shown after.</p>
            <p hidden="hidden" id="trailing">Hidden at the end.</p>
            """)
        let section = book[0]
        XCTAssertEqual(section.specText, "Shown first.\nShown after.")
        let after = section.specLocation("Shown after.")
        for id in ["attribute", "empty-value", "inner", "styled", "after"] { XCTAssertEqual(section.anchors[id], after, id) }
        XCTAssertEqual(section.anchors["trailing"], section.string.length, "nothing follows it")
        XCTAssertNil(book.disclosure)
        try book.assertPositionsRoundTrip()
    }

    /// EPUB 2 content and what older tools still write: an XHTML 1.1 DOCTYPE whose external
    /// identifier is never fetched (RS 3.6), named character references, a stylesheet typed
    /// `text/x-oeb1-css` and named anchors (RS 12).
    func testXHTML11ContentWithNamedEntitiesAndLegacyAnchorsReads() throws {
        var book = Book()
        book.version = "2.0"
        book.add(href: "chapter.xhtml", id: "chapter", mediaType: "application/xhtml+xml", Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
            <head><title>Legacy</title><link rel="stylesheet" type="text/x-oeb1-css" href="legacy.css"/></head>
            <body><p class="c">Caf&eacute;&nbsp;&mdash;&nbsp;&copy;&nbsp;2009 &amp; &lt;after&gt;</p>
            <p><a name="named"></a><a id="identified"></a>Second paragraph.</p></body>
            </html>
            """.utf8))
        book.resource("legacy.css", id: "css", mediaType: "text/css", Data(".c { text-align: center; }".utf8))
        let built = try Build(book)
        let section = built[0]
        XCTAssertEqual(section.specText, "Café\u{A0}—\u{A0}©\u{A0}2009 & <after>\nSecond paragraph.")
        XCTAssertFalse(section.report.recoveredAsHTML)
        XCTAssertFalse(section.report.cfiUnavailable)
        XCTAssertEqual(section.specParagraph("Café").alignment, .center)
        XCTAssertEqual(section.anchors["named"], section.specLocation("Second paragraph."))
        XCTAssertEqual(section.anchors["identified"], section.specLocation("Second paragraph."))
        XCTAssertNil(built.disclosure)
        try built.assertPositionsRoundTrip()
    }

    // MARK: Images, SVG and MathML (RS 3.3 sections 3.1, 6.1.2.2, 6.1.2.3 and 6.2)

    /// RS 3.1: the image core media types are shown. Each becomes an attachment of its own
    /// pixel size, never wider than its line, with its `alt` text for copying and VoiceOver.
    func testCoreMediaTypeImagesAreShownAtTheirSizeAndScaledToTheLine() throws {
        let book = try build("""
            <p>Before <img src="../EPUB/images/inline.gif" alt="an inline mark"/> after.</p>
            <p><img id="photo" src="images/photo.jpg" alt="A wide photograph"/></p>
            <p><img src="images/plate%20one.png" alt="" width="60"/></p>
            <p><img src="images/drawing.svg" alt="A referenced drawing"/></p>
            """) { book in
            book.resource("images/inline.gif", id: "gif", mediaType: "image/gif", Book.image(width: 12, height: 12, as: .gif))
            book.resource("images/photo.jpg", id: "jpeg", mediaType: "image/jpeg", Book.image(width: 800, height: 200, as: .jpeg))
            book.resource("images/plate%20one.png", id: "png", mediaType: "image/png", Book.image(width: 120, height: 80), path: "images/plate one.png")
            book.resource("images/drawing.svg", id: "svg", mediaType: "image/svg+xml", Data(Book.svg(width: 300, height: 150).utf8))
        }
        let section = book[0], images = section.specImages
        XCTAssertEqual(section.specText, "Before \u{FFFC} after.\n\u{FFFC}\n\u{FFFC}\n\u{FFFC}")
        XCTAssertEqual(images.map(\.path), ["EPUB/images/inline.gif", "EPUB/images/photo.jpg", "EPUB/images/plate one.png", "EPUB/images/drawing.svg"])
        XCTAssertEqual(images.map(\.alt), ["an inline mark", "A wide photograph", "", "A referenced drawing"])
        XCTAssertEqual(images.map(\.sizing.intrinsic), [CGSize(width: 12, height: 12), CGSize(width: 800, height: 200),
                                                         CGSize(width: 120, height: 80), CGSize(width: 300, height: 150)])
        XCTAssertEqual(images[0].specSize(lineWidth: 400), CGSize(width: 12, height: 12))
        XCTAssertEqual(images[1].specSize(lineWidth: 400), CGSize(width: 400, height: 100), "scaled to the line, keeping its shape")
        XCTAssertEqual(images[2].specSize(lineWidth: 400), CGSize(width: 60, height: 40), "the width attribute, keeping its shape")
        XCTAssertEqual(images[3].specSize(lineWidth: 400), CGSize(width: 300, height: 150))
        XCTAssertEqual(images[3].specSize(lineWidth: 200), CGSize(width: 200, height: 100))
        XCTAssertEqual(section.anchors["photo"], section.specAttachments[1].location)
        XCTAssertNil(book.disclosure)
        try book.assertPositionsRoundTrip()
    }

    /// EPUB 3.3 section 3.7: an image may be embedded in a `data:` URL, which is then a core
    /// media type resource like any other, and RS 3.4 only forbids opening one as a top-level
    /// document (W3C test pub-data-urls_browsing-context).
    func testAnImageInADataURLIsShown() throws {
        let png = Book.image(width: 40, height: 30).base64EncodedString()
        let book = try build("<p>Before.</p><p><img src=\"data:image/png;base64,\(png)\" alt=\"An embedded square\"/></p>")
        let section = book[0]
        XCTAssertEqual(section.specText, "Before.\n\u{FFFC}")
        XCTAssertEqual(section.specImages.map(\.sizing.intrinsic), [CGSize(width: 40, height: 30)])
        XCTAssertEqual(section.report.unreadableResources, 0)
        XCTAssertNil(book.disclosure)
    }

    /// An image the archive lacks, or one that cannot be decoded, shows its alternative text
    /// (HTML's rendering for an image that is not available) and is disclosed.
    func testAnImageThatCannotBeShownGivesItsAlternativeTextAndIsDisclosed() throws {
        let book = try build("""
            <p><img src="images/missing.png" alt="A missing diagram"/></p>
            <p><img src="images/broken.png" alt="A broken diagram"/></p>
            <p>Text <img src="images/nothing.png"/>continues.</p>
            """) { $0.resource("images/broken.png", id: "broken", mediaType: "image/png", Data("not an image".utf8)) }
        XCTAssertEqual(book[0].specText, "A missing diagram\nA broken diagram\nText continues.")
        XCTAssertTrue(book[0].specImages.isEmpty)
        XCTAssertEqual(book[0].report.unreadableResources, 3)
        XCTAssertEqual(book.disclosure, "3 images could not be shown.")
        try book.assertPositionsRoundTrip()
    }

    /// RS 6.2: an SVG content document in the spine is a section of its own: one drawing at the
    /// size it declares, labelled by its title.
    func testAnSVGContentDocumentIsASectionHoldingOneDrawing() throws {
        var book = Book()
        book.add("before", body: "<p>Before the plate.</p>")
        book.add(href: "plate.svg", id: "plate", mediaType: "image/svg+xml", Data(Book.svg(width: 300, height: 200, title: "Plate I").utf8))
        book.add("after", body: "<p>After the plate.</p>")
        let built = try Build(book)
        XCTAssertEqual(built.publication.spine.map(\.resource.mediaType), ["application/xhtml+xml", "image/svg+xml", "application/xhtml+xml"])
        let plate = built[1]
        XCTAssertEqual(plate.specText, "\u{FFFC}")
        XCTAssertFalse(plate.report.withheld); XCTAssertFalse(plate.report.recoveredAsHTML)
        let image = try XCTUnwrap(plate.specImages.first)
        XCTAssertEqual(image.sizing.intrinsic, CGSize(width: 300, height: 200))
        XCTAssertEqual(image.alt, "Plate I")
        XCTAssertEqual(image.specSize(lineWidth: 400), CGSize(width: 300, height: 200))
        XCTAssertEqual(image.specSize(lineWidth: 150), CGSize(width: 150, height: 100))
        XCTAssertNil(built.disclosure)
        try built.assertPositionsRoundTrip()
    }

    /// RS 6.1.2.3: SVG embedded in XHTML by inclusion is drawn in place, sized by its own
    /// `width`, `height` and `viewBox`.
    func testInlineSVGIsDrawnInPlaceAtItsDeclaredSize() throws {
        let book = try build("""
            <p>Above the figure.</p>
            <svg xmlns="http://www.w3.org/2000/svg" id="figure" width="200" height="100" viewBox="0 0 400 200" role="img">
              <title>Two shapes</title><rect x="10" y="10" width="180" height="180" fill="teal"/><circle cx="300" cy="100" r="80" fill="orange"/>
            </svg>
            <p>Below the figure.</p>
            """)
        let section = book[0]
        XCTAssertEqual(section.specText, "Above the figure.\n\u{FFFC}\nBelow the figure.")
        let image = try XCTUnwrap(section.specImages.first)
        XCTAssertEqual(image.sizing.intrinsic, CGSize(width: 200, height: 100))
        XCTAssertEqual(image.alt, "Two shapes")
        XCTAssertEqual(image.specSize(lineWidth: 400), CGSize(width: 200, height: 100))
        XCTAssertEqual(section.anchors["figure"], section.specAttachments[0].location)
        XCTAssertNil(book.disclosure)
        try book.assertPositionsRoundTrip()
    }

    /// RS 6.1.2.2: Presentation MathML is rendered, inline on its line and centred when
    /// `display="block"`, and read by its `alttext`.
    func testPresentationMathMLIsLaidOutInlineAndAsADisplayFormula() throws {
        let book = try build("""
            <p>The ratio <math xmlns="http://www.w3.org/1998/Math/MathML" alttext="a over b"><mfrac><mi>a</mi><mi>b</mi></mfrac></math> matters.</p>
            <math xmlns="http://www.w3.org/1998/Math/MathML" display="block" id="energy" alttext="E equals m c squared">
              <mrow><mi>E</mi><mo>=</mo><mi>m</mi><msup><mi>c</mi><mn>2</mn></msup></mrow>
            </math>
            <p>After the formula.</p>
            """)
        let section = book[0]
        XCTAssertEqual(section.specText, "The ratio \u{FFFC} matters.\n\u{FFFC}\nAfter the formula.")
        let formulas = section.specAttachments.compactMap { $0.attachment as? MathAttachment }
        XCTAssertEqual(formulas.map(\.label), ["a over b", "E equals m c squared"])
        XCTAssertEqual(section.report.mathFallbacks, 0)
        XCTAssertEqual(section.specParagraph("\u{FFFC}\nAfter").alignment, .center)
        XCTAssertEqual(section.anchors["energy"], section.specAttachments[1].location)
        XCTAssertNil(book.disclosure)
        try book.assertPositionsRoundTrip()
    }

    // MARK: Fallbacks (RS 3.3 sections 3.2, 5.4 and 6.4)

    /// RS 5.4: "A reading system that does not support the MIME media type of a given
    /// publication resource MUST traverse the manifest fallback chain until it identifies a
    /// supported publication resource". A spine item that is not an EPUB content document shows
    /// its fallback, never its own bytes read as markup (W3C tests pub-foreign_json-spine,
    /// lay-pp-images-in-spine).
    func testASpineItemOfAForeignTypeShowsItsManifestFallback() throws {
        var book = Book()
        book.add(href: "data.json", id: "data", mediaType: "application/json", Data(#"{ "chapter": [ { "text": "Raw data, not for reading." } ] }"#.utf8),
                 item: "fallback=\"data-fallback\"")
        book.add(href: "plate.png", id: "plate", mediaType: "image/png", Book.image(width: 64, height: 64), item: "fallback=\"plate-fallback\"")
        book.resource("data-fallback.xhtml", id: "data-fallback", mediaType: "application/xhtml+xml",
                      Data(Book.xhtml(body: "<p>The readable form of the data.</p>").utf8))
        book.resource("plate-fallback.xhtml", id: "plate-fallback", mediaType: "application/xhtml+xml",
                      Data(Book.xhtml(body: "<p><img src=\"plate.png\" alt=\"The plate\"/></p>").utf8))
        let built = try Build(book)
        XCTAssertEqual(built[0].specText, "The readable form of the data.")
        XCTAssertEqual(built[1].specText, "\u{FFFC}", "the fallback's image (or the image itself), never its bytes as text")
        XCTAssertEqual(built[1].specImages.map(\.path), ["EPUB/plate.png"])
        XCTAssertFalse(built.report.withheld)
        XCTAssertFalse(built.report.recoveredAsHTML)
    }

    /// RS 5.4: "If a reading system does not support any resource in the fallback chain, it
    /// MUST alert the user that it could not display the content": the section is withheld and
    /// disclosed, and the rest of the book reads. This covers the conditional unsupported case
    /// in W3C pub-foreign_bad-fallback; its actual PSD fallback can be drawn by ImageIO.
    func testAnUnsupportedSpineItemWithNoUsableFallbackIsWithheldAndDisclosed() throws {
        var book = Book()
        book.add("before", body: "<p>Before.</p>")
        book.add(href: "blob.bin", id: "blob", mediaType: "application/octet-stream", Data([0x00, 0x01, 0x02, 0xFE, 0xFF, 0x00, 0x7F]),
                 item: "fallback=\"other\"")
        book.resource("other.bin", id: "other", mediaType: "application/x-unknown", Data([0xDE, 0xAD, 0xBE, 0xEF]))
        book.add("after", body: "<p>After.</p>")
        let built = try Build(book)
        XCTAssertEqual(built.sections.map(\.specText), ["Before.", "This section could not be shown.", "After."])
        XCTAssertEqual(built.sections.map(\.report.withheld), [false, true, false])
        XCTAssertEqual(built.disclosure, "Some sections of this book could not be shown.")
    }

    /// RS 5.4 and EPUB 3.3 section 3.5.2.2: an `img` may reference a foreign resource when the
    /// manifest gives it a fallback, which a reader that cannot show the resource uses.
    func testAnImageOfAForeignTypeShowsItsManifestFallback() throws {
        let book = try build("<p><img src=\"chart.xcf\" alt=\"A chart\"/></p>") { book in
            book.resource("chart.xcf", id: "chart", mediaType: "image/x-xcf", Data("gimp xcf file, which nothing here decodes".utf8),
                          item: "fallback=\"chart-png\"")
            book.resource("chart.png", id: "chart-png", mediaType: "image/png", Book.image(width: 90, height: 60))
        }
        XCTAssertEqual(book[0].specText, "\u{FFFC}")
        XCTAssertEqual(book[0].specImages.map(\.path), ["EPUB/chart.png"])
        XCTAssertEqual(book[0].specImages.map(\.sizing.intrinsic), [CGSize(width: 90, height: 60)])
        XCTAssertNil(book.disclosure)
    }

    /// RS 6.4: "If scripting is not supported: MUST process fallbacks for scripted content". A
    /// scripted spine item whose manifest item names a fallback shows the fallback (W3C test
    /// scr-support-fallback).
    func testAScriptedDocumentWithAManifestFallbackShowsTheFallback() throws {
        var book = Book()
        book.add("interactive", item: "properties=\"scripted\" fallback=\"static\"", body: """
            <p id="output">Nothing has been computed, because no script ran.</p>
            <script type="text/javascript">document.getElementById('output').textContent = 'Computed by a script.';</script>
            """)
        book.resource("static.xhtml", id: "static", mediaType: "application/xhtml+xml",
                      Data(Book.xhtml(body: "<p>The same content, written out for readers without scripting.</p>").utf8))
        let built = try Build(book)
        XCTAssertEqual(built[0].specText, "The same content, written out for readers without scripting.")
    }

    /// RS 6.4 and doc/architecture.md: nothing in a book runs. A script's text is never shown,
    /// `noscript` content is, and the scripts are counted and disclosed.
    func testScriptsNeverRunOrShowAndNoscriptContentDoes() throws {
        let book = try build("""
            <p id="target" onclick="this.textContent = 'clicked'">Static text.</p>
            <script type="text/javascript">//<![CDATA[
              document.write('<p>Written by a script.</p>');
            //]]></script>
            <noscript><p>Shown because scripts do not run.</p></noscript>
            <p>After.</p>
            <script src="scripts/app.js"></script>
            """, head: "<script>var x = 'in the head';</script>") {
            $0.resource("scripts/app.js", id: "js", mediaType: "text/javascript", Data("document.title = 'changed';".utf8))
        }
        XCTAssertEqual(book[0].specText, "Static text.\nShown because scripts do not run.\nAfter.")
        XCTAssertEqual(book[0].title, "chapter")
        XCTAssertEqual(book[0].report.scriptsRefused, 3)
        XCTAssertEqual(book.disclosure, "3 interactive parts of this document were not run.")
        try book.assertPositionsRoundTrip()
    }

    /// RS 3.1 and HTML: a reader that plays no audio or video shows the element's own fallback
    /// content, embeds nothing, and discloses what it left out.
    func testAudioVideoAndFramesShowTheirFallbackContentAndAreDisclosed() throws {
        let book = try build("""
            <audio src="media/reading.mp3" controls="controls"><p>Your reading system does not play this recording.</p></audio>
            <video controls="controls" poster="images/poster.png"><source src="media/clip.mp4" type="video/mp4"/><track src="media/clip.vtt"/>
              A description of the clip.</video>
            <iframe src="chapter.xhtml" title="A frame"></iframe>
            <p>After the media.</p>
            """) { $0.resource("media/reading.mp3", id: "mp3", mediaType: "audio/mpeg", Data([0xFF, 0xFB, 0x90, 0x00])) }
        XCTAssertEqual(book[0].specText, "Your reading system does not play this recording.\nA description of the clip.\nAfter the media.")
        XCTAssertEqual(book[0].report.unsupportedElements, ["audio": 1, "video": 1, "iframe": 1])
        XCTAssertEqual(book.disclosure, "3 parts of this document, such as videos or forms, cannot be shown by this reader.")
        XCTAssertTrue(book[0].specAttachments.isEmpty)
    }

    /// EPUB 3.0.1 content switching, deprecated but still met in books: one branch of an
    /// `epub:switch` is shown, a `case` for a namespace the reader knows (MathML), else the
    /// `default`, and an `epub:trigger` shows nothing (RS 6.1.1.2, 6.1.1.3).
    func testADeprecatedSwitchShowsOneBranchAndATriggerNothing() throws {
        let book = try build("""
            <p>Supported: <epub:switch id="known">
              <epub:case required-namespace="http://www.w3.org/1998/Math/MathML"><math xmlns="http://www.w3.org/1998/Math/MathML" alttext="x squared"><msup><mi>x</mi><mn>2</mn></msup></math></epub:case>
              <epub:default><img src="x2.png" alt="the default image"/></epub:default>
            </epub:switch>.</p>
            <p>Unsupported: <epub:switch id="unknown">
              <epub:case required-namespace="http://www.xml-cml.org/schema"><span>a chemical structure</span></epub:case>
              <epub:case required-namespace="http://example.org/another"><span>another vocabulary</span></epub:case>
              <epub:default><span id="chosen">the default text</span></epub:default>
            </epub:switch>.</p>
            <epub:trigger ev:observer="pause" ev:event="click" action="pause" ref="clip" xmlns:ev="http://www.w3.org/2001/xml-events"/>
            <p>After.</p>
            """)
        let section = book[0]
        XCTAssertEqual(section.specText, "Supported: \u{FFFC}.\nUnsupported: the default text.\nAfter.")
        XCTAssertEqual(section.specAttachments.compactMap { ($0.attachment as? MathAttachment)?.label }, ["x squared"])
        XCTAssertEqual(section.anchors["chosen"], section.specLocation("the default text"))
        XCTAssertNil(book.disclosure)
        try book.assertPositionsRoundTrip()
    }

    // MARK: Structural semantics (RS 3.3 section 10)

    /// RS 10 (optional behaviours) as doc/native-viewer.md decides them: a `noteref` shows its
    /// note in place, a footnote `aside` leaves the flow, endnotes stay; other `epub:type`
    /// values never change what is shown.
    func testNoterefsShowTheirNotesAndOtherSemanticsChangeNothing() throws {
        let book = try build("""
            <section epub:type="chapter bodymatter unknown:term" role="doc-chapter">
              <h2 epub:type="title">A Chapter</h2>
              <p>A claim<a epub:type="noteref" href="#fn1" id="ref1">1</a> and another<a epub:type="noteref" role="doc-noteref" href="#en1">2</a>.<span epub:type="pagebreak" role="doc-pagebreak" id="page-2" title="2"/></p>
              <aside epub:type="footnote" id="fn1"><p>The footnote's text.</p></aside>
              <section epub:type="endnotes" role="doc-endnotes"><ol><li id="en1" epub:type="endnote"><p>The endnote's text.</p></li></ol></section>
            </section>
            """)
        let section = book[0]
        XCTAssertEqual(section.specText, "A Chapter\nA claim1 and another2.\n1.\tThe endnote's text.")
        XCTAssertEqual(section.notes["fn1"]?.string, "The footnote's text.")
        XCTAssertEqual(section.notes["en1"]?.string, "The endnote's text.")
        XCTAssertEqual(section.specLink("1 and another"), .note(href: "EPUB/chapter.xhtml#fn1"))
        XCTAssertEqual(section.specLink("2."), .note(href: "EPUB/chapter.xhtml#en1"))
        XCTAssertEqual(section.anchors["page-2"], section.specLocation("1.\tThe endnote"), "the marker renders nothing; the next text stands for it")
        XCTAssertEqual(section.anchors["fn1"], section.specLocation("1.\tThe endnote"))
        XCTAssertNil(book.disclosure)
        try book.assertPositionsRoundTrip()
    }

    /// RS 10: "Reading systems MUST ignore terms used on elements where epub:type is not
    /// allowed". The attribute is not allowed in the `head`: a `title` typed `footnote` is no
    /// note, so nothing is shown in place of a reference to it (W3C test pss-support_ignore-title).
    func testStructuralSemanticsOnTheTitleElementAreIgnored() throws {
        var book = Book()
        book.add(href: "chapter.xhtml", id: "chapter", mediaType: "application/xhtml+xml", Data("""
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
            <head><title epub:type="footnote" id="the_note">A title mistyped as a footnote</title></head>
            <body><p>No note appears when following <a href="#the_note" epub:type="noteref">this link</a>.</p></body>
            </html>
            """.utf8))
        let section = try Build(book)[0]
        XCTAssertEqual(section.specText, "No note appears when following this link.")
        XCTAssertNil(section.notes["the_note"]?.string)
    }

    // MARK: Language and base direction (RS 3.3 section 3.7)

    /// RS 3.7: language and base direction are read from the content document: `dir` on the
    /// root, a block or a span, `bdo`, and `lang` or `xml:lang` for what depends on language.
    func testLanguageAndBaseDirectionComeFromTheContentDocument() throws {
        let book = try build("""
            <p id="rtl">فقرة عربية with English inside.</p>
            <p dir="ltr" id="ltr">An explicitly left-to-right paragraph.</p>
            <p dir="ltr">Inline <span dir="rtl">ימין</span> and <bdo dir="rtl">override</bdo> and <bdi>isolate</bdi>.</p>
            <p dir="ltr" lang="fr">Elle dit <q>bonjour <q>toi</q></q>.</p>
            <p dir="ltr" xml:lang="de">Er sagt <q>hallo</q>.</p>
            <p dir="ltr" lang="en">She says <q>hello</q>.</p>
            """, root: "dir=\"rtl\" lang=\"ar\" xml:lang=\"ar\"")
        let section = book[0]
        XCTAssertEqual(section.specParagraph("فقرة").baseWritingDirection, .rightToLeft)
        XCTAssertEqual(section.specParagraph("فقرة").alignment, .natural, "start-aligned: the right edge in a right-to-left paragraph")
        XCTAssertEqual(section.specParagraph("An explicitly").baseWritingDirection, .leftToRight)
        XCTAssertTrue(section.specText.contains("Inline \u{2067}ימין\u{2069} and \u{2067}\u{202E}override\u{202C}\u{2069} and \u{2068}isolate\u{2069}."))
        XCTAssertTrue(section.specText.contains("Elle dit «bonjour «toi»»."))
        XCTAssertTrue(section.specText.contains("Er sagt „hallo“."))
        XCTAssertTrue(section.specText.contains("She says “hello”."))
        XCTAssertNil(book.disclosure)
        try book.assertPositionsRoundTrip()
    }

    /// RS 3.7: "reading systems MUST NOT assume either the language or the base direction of
    /// that resource from information expressed in the package document". A document that
    /// declares neither reads the same whatever the package's `dir` says.
    func testThePackagesBaseDirectionIsNotAssumedForContent() throws {
        let body = "<p>A paragraph that declares no direction.</p><ul><li>An item</li></ul>"
        let plain = try build(body)
        let rightToLeft = try build(body) { book in
            book.packageAttributes = "dir=\"rtl\" xml:lang=\"he\""
            book.metadata = "<dc:title dir=\"rtl\">ספר</dc:title><dc:language>he</dc:language>"
        }
        XCTAssertEqual(rightToLeft[0].specText, plain[0].specText)
        for phrase in ["A paragraph", "An item"] {
            XCTAssertEqual(rightToLeft[0].specParagraph(phrase), plain[0].specParagraph(phrase), phrase)
            XCTAssertEqual(rightToLeft[0].specParagraph(phrase).baseWritingDirection, .leftToRight, phrase)
        }
        XCTAssertEqual(rightToLeft.publication.pageProgression, .default)
    }

    /// RS 3.7: the same MUST NOT for language. A document that declares no language is not in
    /// the package's `dc:language`: what the reader generates from language (the marks around a
    /// `q`) is the same whatever the package says (W3C test pkg-lang_but_not_content).
    func testThePackagesLanguageIsNotAssumedForContent() throws {
        let body = "<p>She said <q>the better is the enemy of the good</q>.</p>"
        var rendered: [String: String] = [:]
        for language in ["en", "fr", "de", "ja"] {
            rendered[language] = try build(body) {
                $0.metadata = "<dc:title>A Book</dc:title><dc:language>\(language)</dc:language>"
            }[0].specText
        }
        XCTAssertEqual(rendered["fr"], rendered["en"])
        XCTAssertEqual(rendered["de"], rendered["en"])
        XCTAssertEqual(rendered["ja"], rendered["en"])
    }

    /// RS 3.7, for the other text the reader generates from language: case mapping. A document
    /// that declares no language maps case the same in a Turkish book as in an English one, and
    /// one that says it is Turkish gets Turkish's dotted capital and dotless small letter.
    func testThePackagesLanguageDoesNotChooseCaseMappingForContent() throws {
        let body = """
            <p style="text-transform: uppercase">istanbul</p>
            <p style="text-transform: lowercase">ISPARTA</p>
            <p style="text-transform: capitalize">izmir</p>
            <p style="font-family: Georgia; font-variant: small-caps">Edirne ili</p>
            <div lang="tr"><p style="text-transform: uppercase">iznik</p><p style="text-transform: lowercase">IĞDIR</p>
            <p style="font-family: Georgia; font-variant: small-caps">Sinop ili</p></div>
            """
        let book = try build(body) { $0.metadata = "<dc:title>Kitap</dc:title><dc:language>tr</dc:language>" }
        let turkish = book[0].specText
        XCTAssertEqual(turkish, try build(body)[0].specText)
        for phrase in ["ISTANBUL", "isparta", "Izmir", "İZNİK", "ığdır"] {
            XCTAssertTrue(turkish.contains(phrase), "\(phrase) in \(turkish.debugDescription)")
        }
        // A family without small capitals shows lower-case letters as smaller capitals: mapped too.
        let georgia = ComputedStyle(fontFamilies: ["georgia"], fontSize: 16, isSmallCaps: true)
        if FontRegistry(publication: book.publication).needsSyntheticSmallCaps(for: georgia) {
            XCTAssertTrue(turkish.contains("EDIRNE ILI"), turkish)
            XCTAssertTrue(turkish.contains("SİNOP İLİ"), turkish)
        }
    }

    /// The reader's narrow reading of RS 3.7 (#109): the package's first `dc:language` stays a
    /// hint where some language has to be chosen anyway. CoreText chooses glyphs for a language,
    /// so every run of an unlabelled document in a Japanese book is typeset as Japanese, in the
    /// section, a table cell and a note alike, while the text generated around its `q`s is not
    /// Japanese.
    func testThePackagesLanguageStaysAHintForTypesetting() throws {
        let body = """
            <p>She wrote <q>直</q> and <q>骨 <q>inner</q></q>.</p><ul><li>An item</li></ul>
            <table><tr><td>A cell says <q>海</q>.</td><td>Another</td></tr></table>
            <aside epub:type="footnote" id="note">A note says <q>角</q>.</aside>
            """
        let japanese = try build(body) { $0.metadata = "<dc:title>本</dc:title><dc:language>ja</dc:language>" }[0]
        let unstated = try build(body) { $0.metadata = "<dc:title>A Book</dc:title>" }[0]
        func languages(_ text: NSAttributedString) -> Set<String?> {
            var found: Set<String?> = []
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
                if attributes[.attachment] == nil { found.insert(attributes[InlineStyling.languageKey] as? String) }
            }
            return found
        }
        func cell(_ section: SectionText) throws -> NSAttributedString {
            let row = try XCTUnwrap(RichFixture.attachments(in: section.string).compactMap { $0 as? TableRowAttachment }.first)
            return try XCTUnwrap(row.table.cells.first { $0.content.string.contains("A cell") }).content
        }
        XCTAssertTrue(japanese.specText.contains("She wrote “直” and “骨 ‘inner’”."), japanese.specText)
        XCTAssertEqual(languages(japanese.string), ["ja"], "paragraphs, quote marks and list markers")
        XCTAssertEqual(try cell(japanese).string, "A cell says “海”.")
        XCTAssertEqual(languages(try cell(japanese)), ["ja"])
        let note = try XCTUnwrap(japanese.notes["note"])
        XCTAssertEqual(note.string, "A note says “角”.")
        XCTAssertEqual(languages(note), ["ja"])
        // A package that names no language gives no hint, and the same text.
        XCTAssertEqual(unstated.specText, japanese.specText)
        XCTAssertEqual(languages(unstated.string), [nil])
        XCTAssertEqual(languages(try cell(unstated)), [nil])
        XCTAssertEqual(languages(try XCTUnwrap(unstated.notes["note"])), [nil])
    }

    /// A document that declares its own language is in that language for both uses, whatever
    /// the package says: its `q` marks and its glyphs are French in a Japanese book, an element
    /// inside it changes both again, and `lang=""` (the language is unknown) leaves neither a
    /// language nor the package's hint.
    func testAContentDocumentsOwnLanguageOverridesThePackagesForGeneratedTextAndTypesetting() throws {
        let body = """
            <p>Elle dit <q>bonjour</q>.</p><p xml:lang="de">Er sagt <q>hallo</q>.</p>
            <p lang="">Unknown <q>words</q>.</p>
            <table><tr><td>Une cellule dit <q>oui</q>.</td><td lang="">Cell <q>unknown</q>.</td></tr></table>
            <aside epub:type="footnote" id="note">Une note dit <q>non</q>.</aside>
            """
        let section = try build(body, root: "lang=\"fr\" xml:lang=\"fr\"") {
            $0.metadata = "<dc:title>本</dc:title><dc:language>ja</dc:language>"
        }[0]
        func language(_ phrase: String, in text: NSAttributedString) -> String? {
            let range = (text.string as NSString).range(of: phrase)
            XCTAssertNotEqual(range.location, NSNotFound, phrase)
            return range.location == NSNotFound ? nil : text.attribute(InlineStyling.languageKey, at: range.location, effectiveRange: nil) as? String
        }
        XCTAssertTrue(section.specText.contains("Elle dit «bonjour»."), section.specText)
        XCTAssertTrue(section.specText.contains("Er sagt „hallo“."), section.specText)
        XCTAssertTrue(section.specText.contains("Unknown “words”."), section.specText)
        XCTAssertEqual(language("Elle dit", in: section.string), "fr")
        XCTAssertEqual(language("«", in: section.string), "fr")
        XCTAssertEqual(language("Er sagt", in: section.string), "de")
        XCTAssertNil(language("Unknown", in: section.string))
        let row = try XCTUnwrap(RichFixture.attachments(in: section.string).compactMap { $0 as? TableRowAttachment }.first)
        let french = try XCTUnwrap(row.table.cells.first { $0.content.string.contains("Une cellule") }).content
        let unknown = try XCTUnwrap(row.table.cells.first { $0.content.string.contains("Cell") }).content
        XCTAssertEqual(french.string, "Une cellule dit «oui».")
        XCTAssertEqual(language("Une cellule", in: french), "fr")
        XCTAssertEqual(unknown.string, "Cell “unknown”.")
        XCTAssertNil(language("Cell", in: unknown))
        let note = try XCTUnwrap(section.notes["note"])
        XCTAssertEqual(note.string, "Une note dit «non».")
        XCTAssertEqual(language("Une note", in: note), "fr")
    }

    /// HTML's `ruby`: the annotation rides above its base and adds no characters to the text,
    /// so positions in a Japanese book are those of its base text.
    func testRubyAnnotatesItsBaseWithoutAddingCharacters() throws {
        let book = try build("<p><ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp>字<rp>(</rp><rt>じ</rt><rp>)</rp></ruby>を読む。</p>", root: "lang=\"ja\"")
        let section = book[0]
        XCTAssertEqual(section.specText, "漢字を読む。")
        let first: Any? = section.string.attribute(InlineStyling.rubyKey, at: 0, effectiveRange: nil)
        let second: Any? = section.string.attribute(InlineStyling.rubyKey, at: 1, effectiveRange: nil)
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        XCTAssertNil(section.string.attribute(InlineStyling.rubyKey, at: 2, effectiveRange: nil))
        XCTAssertNil(book.disclosure)
        try book.assertPositionsRoundTrip()
    }

    // MARK: URLs (EPUB 3.3 section 4.2.5, RS 3.3 sections 3.3, 3.5, 3.9 and 4.1.1)

    /// Hyperlinks are URLs relative to their document: `..` and `.` segments, percent-encoded
    /// names and fragments resolve inside the container to encoded hrefs a host can navigate to;
    /// anything with a scheme is outside the book. RS 4.1.1: `..` stops at the container root,
    /// so no path is.
    func testHyperlinksResolveAsRelativeURLsAndSchemesAreExternal() throws {
        var book = Book()
        book.add(href: "text/part%20one/chapter%201.xhtml", id: "one", mediaType: "application/xhtml+xml", Data(Book.xhtml(body: """
            <p><a href="chapter%202.xhtml">sibling</a> <a href="../part%20one/./chapter%202.xhtml#sec%20a">dotted</a>
            <a href="../../notes.xhtml#n1">parent</a> <a href="#local%20id">local</a> <a href="">self</a>
            <a href="https://example.org/a%20page?x=1#y">web</a> <a href="mailto:someone@example.org">mail</a>
            <a href="tel:+15550100">phone</a> <a href="../../../../outside.xhtml">leaking</a> <a>no target</a></p>
            <p id="local id">The local target.</p>
            """).utf8), path: "text/part one/chapter 1.xhtml")
        book.add(href: "text/part%20one/chapter%202.xhtml", id: "two", mediaType: "application/xhtml+xml",
                 Data(Book.xhtml(body: "<h2 id=\"sec a\">Section A</h2>").utf8), path: "text/part one/chapter 2.xhtml")
        book.add("notes", body: "<p id=\"n1\">A note.</p>")
        let built = try Build(book)
        let section = built[0]
        XCTAssertEqual(section.href, "EPUB/text/part%20one/chapter%201.xhtml")
        XCTAssertEqual(section.specLink("sibling"), .internal(href: "EPUB/text/part%20one/chapter%202.xhtml"))
        XCTAssertEqual(section.specLink("dotted"), .internal(href: "EPUB/text/part%20one/chapter%202.xhtml#sec%20a"))
        XCTAssertEqual(section.specLink("parent"), .internal(href: "EPUB/notes.xhtml#n1"))
        XCTAssertEqual(section.specLink("local"), .internal(href: "EPUB/text/part%20one/chapter%201.xhtml#local%20id"))
        XCTAssertEqual(section.specLink("self"), .internal(href: "EPUB/text/part%20one/chapter%201.xhtml"))
        XCTAssertEqual(section.specLink("web"), .external("https://example.org/a%20page?x=1#y"))
        XCTAssertEqual(section.specLink("mail"), .external("mailto:someone@example.org"))
        XCTAssertEqual(section.specLink("phone"), .external("tel:+15550100"))
        XCTAssertEqual(section.specLink("leaking"), .internal(href: "outside.xhtml"), "never a path outside the container")
        XCTAssertNil(section.specLink("no target"))
        // Each internal target is a section of the book and an anchor in it.
        XCTAssertEqual(built.publication.spine.map(\.resource.href),
                       ["EPUB/text/part%20one/chapter%201.xhtml", "EPUB/text/part%20one/chapter%202.xhtml", "EPUB/notes.xhtml"])
        XCTAssertEqual(built[1].anchors["sec a"], 0)
        XCTAssertEqual(built[0].anchors["local id"], section.specLocation("The local target."))
        XCTAssertEqual(built[2].anchors["n1"], 0)
    }

    /// Images, stylesheets and their own `url()` and `@import` references resolve the same way:
    /// relative to the document or stylesheet that makes them, through `..` and percent-encoding.
    func testImagesAndStyleSheetsResolveThroughParentAndPercentEncodedURLs() throws {
        var book = Book()
        book.add(href: "text/chapter.xhtml", id: "chapter", mediaType: "application/xhtml+xml", Data(Book.xhtml(
            head: "<link rel=\"stylesheet\" type=\"text/css\" href=\"../styles/main%20sheet.css\"/>",
            body: "<p class=\"imported\">Styled by an imported sheet.</p><p><img src=\"../images/my%20photo.png\" alt=\"A photo\"/></p>"
                + "<p><img src=\"./../images/./caf%C3%A9.png\" alt=\"A café\"/></p>").utf8))
        book.resource("styles/main%20sheet.css", id: "main", mediaType: "text/css",
                      Data("@import url(\"more/second%20sheet.css\");\np { text-indent: 0; }".utf8), path: "styles/main sheet.css")
        book.resource("styles/more/second%20sheet.css", id: "second", mediaType: "text/css",
                      Data("@import '../../styles/third.css'; .imported { text-align: right; }".utf8), path: "styles/more/second sheet.css")
        book.resource("styles/third.css", id: "third", mediaType: "text/css", Data(".imported { margin-left: 24px; }".utf8))
        book.resource("images/my%20photo.png", id: "photo", mediaType: "image/png", Book.image(width: 30, height: 20), path: "images/my photo.png")
        book.resource("images/caf%C3%A9.png", id: "cafe", mediaType: "image/png", Book.image(width: 20, height: 20), path: "images/café.png")
        let built = try Build(book)
        XCTAssertEqual(built[0].specImages.map(\.path), ["EPUB/images/my photo.png", "EPUB/images/café.png"])
        let styled = built[0].specParagraph("Styled by")
        XCTAssertEqual(styled.alignment, .right)
        XCTAssertEqual(styled.headIndent, 24)
        XCTAssertNil(built.disclosure)
    }

    /// RS 3.3, 3.5 and doc/native-viewer.md (Security): a reference that names a file URL or a
    /// remote host is never followed. The image's alternative text stands in, and the refusal
    /// is disclosed. RS 4.1.1: a path that climbs past the container root stops there, so it
    /// names an entry of the archive or nothing, never a file of the host.
    func testReferencesOutsideTheContainerAreNeverFollowed() throws {
        let book = try build("""
            <p><img src="https://example.org/remote.png" alt="A remote image"/></p>
            <p><img src="file:///etc/hosts" alt="A file URL"/></p>
            <p><img src="../../../../etc/passwd" alt="A leaking path"/></p>
            <p><img src="/etc/hosts" alt="A rooted path"/></p>
            <p>End.</p>
            """, head: "<link rel=\"stylesheet\" href=\"https://example.org/remote.css\"/>")
        XCTAssertEqual(book[0].specText, "A remote image\nA file URL\nA leaking path\nA rooted path\nEnd.")
        XCTAssertTrue(book[0].specAttachments.isEmpty)
        XCTAssertEqual(book[0].report.remoteResourcesRefused, 3, "the stylesheet and the two remote images")
        XCTAssertEqual(book[0].report.unreadableResources, 2, "etc/passwd and etc/hosts, which the archive does not hold")
        XCTAssertNotNil(book.disclosure)
    }

    // MARK: Cascading style sheets (RS 3.3 section 6.3)

    /// RS 6.3: the creator's style sheets apply as written, linked, embedded and inline, in
    /// cascade order over the user-agent defaults.
    func testAuthorStylesCascadeOverTheDefaultsFromLinkStyleAndAttribute() throws {
        let book = try build("""
            <h1>Heading</h1>
            <p class="lead">Lead paragraph.</p>
            <p class="lead" id="special">Special paragraph.</p>
            <p class="lead" id="inline" style="text-align: left; margin-left: 10px">Inline styled.</p>
            <p>Plain <span class="caps">shouting</span> text.</p>
            """, head: "<link rel=\"stylesheet\" href=\"book.css\"/><style>#special { text-align: center; } .caps { text-transform: uppercase; }</style>") {
            $0.resource("book.css", id: "css", mediaType: "text/css", Data("""
                @charset "utf-8";
                body { margin: 0 5%; }
                h1 { font-size: 1.5em; text-align: center; margin: 0 0 2em 0; font-weight: normal; }
                p { margin: 0; text-indent: 1.5em; text-align: justify; }
                p.lead { text-indent: 0; text-align: right; }
                """.utf8))
        }
        let section = book[0]
        XCTAssertEqual(section.specText, "Heading\nLead paragraph.\nSpecial paragraph.\nInline styled.\nPlain SHOUTING text.")
        let heading = section.specParagraph("Heading"), lead = section.specParagraph("Lead"), plain = section.specParagraph("Plain")
        XCTAssertEqual(section.specFont("Heading").pointSize, 24)
        XCTAssertFalse(CTFontGetSymbolicTraits(section.specFont("Heading") as CTFont).contains(.traitBold))
        XCTAssertEqual(heading.alignment, .center)
        XCTAssertEqual(heading.paragraphSpacing, 48, accuracy: 0.01, "2em of the heading's own 24-point size")
        XCTAssertEqual(lead.alignment, .right); XCTAssertEqual(lead.paragraphSpacing, 0)
        XCTAssertEqual(lead.firstLineHeadIndent, lead.headIndent, "text-indent: 0 from the more specific rule")
        XCTAssertEqual(section.specParagraph("Special").alignment, .center, "the embedded sheet's id rule")
        XCTAssertEqual(section.specParagraph("Inline styled").alignment, .left, "the style attribute")
        XCTAssertEqual(section.specParagraph("Inline styled").headIndent - lead.headIndent, 10, accuracy: 0.01)
        XCTAssertEqual(plain.alignment, .justified)
        XCTAssertEqual(plain.firstLineHeadIndent - plain.headIndent, 24, accuracy: 0.01, "1.5em")
        XCTAssertNil(book.disclosure)
        try book.assertPositionsRoundTrip()
    }

    /// RS 6.3 (SHOULD) and EPUB 3.3 appendix E: the `-epub-` prefixed properties the reader
    /// knows behave as their unprefixed forms, and one it does not know costs only itself: the
    /// rest of its rule still applies and the text is unchanged.
    func testPrefixedPropertiesAreHonouredOrSkippedWithoutLosingTheirRule() throws {
        let book = try build("""
            <p class="none">Hyphenation is off in this paragraph.</p>
            <p class="auto">Hyphenation is automatic in this paragraph.</p>
            <p class="unknown">Unknown prefixed properties surround a known one.</p>
            <p class="fullwidth">abc</p>
            """, head: """
            <style>
              .none { -epub-hyphens: none; }
              .auto { -epub-hyphens: auto; }
              .unknown { -epub-line-break: strict; -epub-word-break: keep-all; -epub-text-align-last: center;
                         text-align: center; -epub-text-emphasis-style: dot; -epub-text-underline-position: under;
                         -epub-ruby-position: over; -epub-text-combine-horizontal: all; margin-left: 20px; }
              .fullwidth { text-transform: -epub-fullwidth; text-align: right; }
            </style>
            """)
        let section = book[0]
        XCTAssertEqual(section.specParagraph("Hyphenation is off").hyphenationFactor, 0)
        XCTAssertEqual(section.specParagraph("Hyphenation is automatic").hyphenationFactor, 1)
        XCTAssertEqual(section.specParagraph("Unknown prefixed").alignment, .center)
        XCTAssertEqual(section.specParagraph("Unknown prefixed").headIndent, 20)
        XCTAssertEqual(section.specParagraph("abc").alignment, .right)
        XCTAssertFalse(section.report.stylesTruncated)
        XCTAssertFalse(section.report.verticalWritingFlattened)
        XCTAssertNil(book.disclosure)
    }

    /// doc/native-viewer.md (Decisions): vertical writing, here asked for with the prefixed
    /// `-epub-writing-mode`, is read horizontally in document order and disclosed.
    func testPrefixedVerticalWritingIsReadHorizontallyAndDisclosed() throws {
        let book = try build("<p>縦書きの段落です。</p><p>二つ目の段落。</p>", head: "<style>html { -epub-writing-mode: vertical-rl; }</style>", root: "lang=\"ja\"")
        XCTAssertEqual(book[0].specText, "縦書きの段落です。\n二つ目の段落。")
        XCTAssertTrue(book[0].report.verticalWritingFlattened)
        XCTAssertEqual(book.disclosure, "Vertical text is shown horizontally.")
        try book.assertPositionsRoundTrip()
    }

    /// RS 6.3: "MUST support TrueType, OpenType, WOFF and WOFF2 fonts referenced from
    /// @font-face", and 4.3: an obfuscated font is deobfuscated with the unique identifier
    /// before use. The text set in the embedded family uses the archive's face.
    func testAnObfuscatedEmbeddedFontIsUsedForItsText() throws {
        let installed = CTFontCreateWithName("Georgia-Italic" as CFString, 12, nil)
        guard CTFontCopyPostScriptName(installed) as String == "Georgia-Italic",
              let url = CTFontCopyAttribute(installed, kCTFontURLAttribute) as? URL, let font = try? Data(contentsOf: url) else {
            throw XCTSkip("Georgia Italic is not installed to stand in for a book's font")
        }
        var book = Book()
        book.identifier = "urn:uuid:0f3a1c5e-2b4d-4e6f-8a9b-1c2d3e4f5a6b"
        let key = Array(Insecure.SHA1.hash(data: Data(book.identifier.utf8)))
        var obfuscated = font
        for index in 0..<min(1040, obfuscated.count) { obfuscated[obfuscated.startIndex + index] ^= key[index % key.count] }
        XCTAssertNotEqual(obfuscated.prefix(4), font.prefix(4))
        book.add("chapter", head: """
            <style>
              @font-face { font-family: "Book Face"; src: url("../EPUB/fonts/face.ttf") format("truetype"); }
              .face { font-family: "Book Face", monospace; }
            </style>
            """, body: "<p>Default text.</p><p class=\"face\">Text in the book's face.</p>")
        book.resource("fonts/face.ttf", id: "face", mediaType: "font/ttf", obfuscated)
        book.rootFiles["META-INF/encryption.xml"] = Data("""
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
                <enc:CipherData><enc:CipherReference URI="EPUB/fonts/face.ttf"/></enc:CipherData></enc:EncryptedData>
            </encryption>
            """.utf8)
        let built = try Build(book)
        XCTAssertEqual(try built.publication.data(at: "EPUB/fonts/face.ttf"), font, "deobfuscated")
        XCTAssertEqual(built[0].specFamily("Text in the book's face."), "Georgia")
        XCTAssertNotEqual(built[0].specFamily("Default text."), "Georgia")
        XCTAssertNil(built.disclosure)
    }
}

extension SpecConformanceContentTests {
    // MARK: More of HTML

    /// HTML tables (RS 6.1): a data table is its caption and one drawn row per `tr`, each row
    /// carrying its cells' text; a one-column table, which books use as a box, flows as text.
    func testADataTableIsItsCaptionAndOneRowAttachmentPerRow() throws {
        let book = try build("""
            <p>Before the table.</p>
            <table id="scores"><caption>Table 1. Results</caption>
              <thead><tr><th>Name</th><th>Score</th></tr></thead>
              <tbody><tr><td id="cell">Ada</td><td>90</td></tr><tr><td>Grace</td><td>95</td></tr></tbody>
            </table>
            <p>After the table.</p>
            <table><tr><td><p>A one-column table is a callout box.</p></td></tr></table>
            """)
        let section = book[0]
        XCTAssertEqual(section.specText, "Before the table.\nTable 1. Results\n\u{FFFC}\n\u{FFFC}\n\u{FFFC}\nAfter the table.\nA one-column table is a callout box.")
        let rows = section.specAttachments.compactMap { $0.attachment as? TableRowAttachment }
        XCTAssertEqual(rows.map(\.textEquivalent), ["Name\tScore", "Ada\t90", "Grace\t95"])
        XCTAssertEqual(rows.map(\.row), [0, 1, 2])
        XCTAssertTrue(rows.allSatisfy { $0.table === rows[0].table })
        XCTAssertEqual(rows.first?.table.columnCount, 2)
        XCTAssertEqual(rows.first?.table.rows.map(\.isHeader), [true, false, false])
        for row in rows {
            let bounds = row.layoutBounds(ReaderAttachment.Line(width: 400, viewport: CGSize(width: 400, height: 600)))
            XCTAssertEqual(bounds.width, 400); XCTAssertGreaterThan(bounds.height, 10)
        }
        XCTAssertEqual(section.string.attribute(.readerKeepWithNext, at: section.specAttachments[0].location, effectiveRange: nil) as? Bool, true,
                       "the header row stays with the first body row")
        XCTAssertEqual(section.anchors["scores"], section.specLocation("Table 1. Results"))
        XCTAssertEqual(section.anchors["cell"], section.anchors["scores"], "an id inside the table is the table")
        XCTAssertNil(book.disclosure)
        try book.assertPositionsRoundTrip()
    }

    /// HTML's `picture`: a reader that chooses no `source` shows the `img` inside it, once.
    func testAPictureElementShowsItsImageOnce() throws {
        let book = try build("""
            <p><picture><source srcset="images/wide.webp 2x" type="image/webp" media="(min-width: 800px)"/>
              <img src="images/plain.png" alt="A plain picture"/></picture></p>
            """) { $0.resource("images/plain.png", id: "plain", mediaType: "image/png", Book.image(width: 50, height: 40)) }
        XCTAssertEqual(book[0].specText, "\u{FFFC}")
        XCTAssertEqual(book[0].specImages.map(\.path), ["EPUB/images/plain.png"])
        XCTAssertNil(book.disclosure)
    }

    // MARK: Features a reader without them must ignore

    /// RS 9: a reading system without media overlays "MUST ignore" the `media-overlay`
    /// attribute and `application/smil+xml` manifest items (W3C test mol-ignore). The book
    /// reads as it does without them.
    func testMediaOverlaysAreIgnored() throws {
        let body = "<p id=\"s1\">The first sentence.</p><p id=\"s2\">The second sentence.</p>"
        let plain = try build(body)
        let narrated = try build(body, head: "<style>.-epub-media-overlay-active { background-color: yellow; }</style>") { book in
            book.packageAttributes = "prefix=\"media: http://www.idpf.org/epub/vocab/overlays/#\""
            book.metadata += "<meta property=\"media:duration\" refines=\"#overlay\">0:00:04.000</meta><meta property=\"media:duration\">0:00:04.000</meta>"
                + "<meta property=\"media:active-class\">-epub-media-overlay-active</meta><meta property=\"media:narrator\">A Reader</meta>"
            book.sections[0].item = "media-overlay=\"overlay\""
            book.resource("overlay.smil", id: "overlay", mediaType: "application/smil+xml", Data("""
                <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0"><body>
                  <par id="p1"><text src="chapter.xhtml#s1"/><audio src="audio/narration.mp3" clipBegin="0s" clipEnd="2s"/></par>
                  <par id="p2"><text src="chapter.xhtml#s2"/><audio src="audio/narration.mp3" clipBegin="2s" clipEnd="4s"/></par>
                </body></smil>
                """.utf8))
            book.resource("audio/narration.mp3", id: "narration", mediaType: "audio/mpeg", Data([0xFF, 0xFB, 0x90, 0x00]))
        }
        XCTAssertEqual(narrated.publication.spine.map(\.resource.path), plain.publication.spine.map(\.resource.path))
        XCTAssertEqual(narrated[0].specText, plain[0].specText)
        XCTAssertEqual(narrated[0].anchors, plain[0].anchors)
        for phrase in ["The first sentence.", "The second sentence."] {
            XCTAssertEqual(narrated[0].specFont(phrase), plain[0].specFont(phrase), phrase)
            XCTAssertEqual(narrated[0].specParagraph(phrase), plain[0].specParagraph(phrase), phrase)
            let background: PlatformColor? = narrated[0].specAttribute(.backgroundColor, at: phrase)
            XCTAssertNil(background, "no overlay styling without playback")
        }
        XCTAssertNil(narrated.disclosure)
    }

    /// RS 8.3: "MUST ignore viewport meta rendering instructions, except when deriving
    /// fixed-layout ICB dimensions": in a reflowable document it changes nothing.
    func testAViewportMetaInAReflowableDocumentChangesNothing() throws {
        let body = "<h1>Heading</h1><p>A paragraph of reflowable text.</p><p><img src=\"wide.png\" alt=\"\"/></p>"
        let image = Book.image(width: 500, height: 100)
        let plain = try build(body) { $0.resource("wide.png", id: "wide", mediaType: "image/png", image) }
        let scaled = try build(body, head: "<meta name=\"viewport\" content=\"width=320, height=480, initial-scale=3, maximum-scale=1, user-scalable=no\"/>") {
            $0.resource("wide.png", id: "wide", mediaType: "image/png", image)
        }
        XCTAssertEqual(scaled.publication.spine[0].layout, .reflowable)
        XCTAssertEqual(scaled[0].specText, plain[0].specText)
        for phrase in ["Heading", "A paragraph"] {
            XCTAssertEqual(scaled[0].specFont(phrase), plain[0].specFont(phrase), phrase)
            XCTAssertEqual(scaled[0].specParagraph(phrase), plain[0].specParagraph(phrase), phrase)
        }
        XCTAssertEqual(scaled[0].specImages.first?.specSize(lineWidth: 400), CGSize(width: 400, height: 80))
        XCTAssertFalse(scaled[0].report.fixedLayoutReflowed)
        XCTAssertNil(scaled.disclosure)
    }

    // MARK: Encodings (EPUB 3.3 section 3.9, RS 3.6)

    /// EPUB 3.3: XML documents are UTF-8 or UTF-16, and XML processors read both. A content
    /// document in UTF-16, or in UTF-8 with a byte order mark, reads as the same text.
    func testContentDocumentsInUTF16OrWithAByteOrderMarkRead() throws {
        let body = "<p id=\"p\">Größe, 日本語 and an emoji 📖 — all in one paragraph.</p>"
        let utf8 = Book.xhtml(body: body)
        let utf16 = utf8.replacingOccurrences(of: "encoding=\"UTF-8\"", with: "encoding=\"UTF-16\"")
        var book = Book()
        book.add(href: "plain.xhtml", id: "plain", mediaType: "application/xhtml+xml", Data(utf8.utf8))
        book.add(href: "bom.xhtml", id: "bom", mediaType: "application/xhtml+xml", Data([0xEF, 0xBB, 0xBF]) + Data(utf8.utf8))
        book.add(href: "utf16le.xhtml", id: "utf16le", mediaType: "application/xhtml+xml", Data([0xFF, 0xFE]) + utf16.data(using: .utf16LittleEndian)!)
        book.add(href: "utf16be.xhtml", id: "utf16be", mediaType: "application/xhtml+xml", Data([0xFE, 0xFF]) + utf16.data(using: .utf16BigEndian)!)
        let built = try Build(book)
        for section in built.sections {
            XCTAssertEqual(section.specText, "Größe, 日本語 and an emoji 📖 — all in one paragraph.", section.href)
            XCTAssertFalse(section.report.recoveredAsHTML, section.href)
            XCTAssertEqual(section.anchors["p"], 0, section.href)
        }
        XCTAssertNil(built.disclosure)
        try built.assertPositionsRoundTrip()
    }
}
