import EPUBReading
import EPUBTestSupport
import StaticSVG
import XCTest
@testable import EPUBViewing

/// Reference loops and unbounded chains remain screened before they reach the renderer.
/// Repeating gradients are accepted by the screen: when their resolved geometry panics,
/// the Rust boundary contains it and the ordinary section path substitutes fallback text.
/// Inputs that spend the stack or never return are given only to the screen; contained
/// panic inputs and known-safe neighbours also exercise the real renderer.
///
/// The screens and the renderer are StaticSVG's, and so are their tests of these drawings
/// (`SVGReferenceCoverageTests`). Here are the sections a reader shows them in.
final class RichMediaSVGReferenceCoverageTests: XCTestCase {
    private static let ns = "xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'"
    /// A shape's size and paint: white, so that it shows through a mask.
    private static let box = "width='5' height='5' fill='white'"

    private func drawing(_ body: String) -> String {
        "<svg \(Self.ns) width='10' height='10'>\(body)</svg>"
    }

    /// The verdict of the rendering limits `SVGRenderer` asks before the renderer is given a
    /// byte, which include the reference screen's. It does not reach the renderer.
    private func withinRenderingLimits(_ body: String) throws -> Bool {
        let limits = ContentLimits(bytes: SVGLimits.renderer.bytes, depth: SVGLimits.renderer.depth, nodes: SVGLimits.renderer.nodes)
        let document = try ContentDocument.parse(Data(drawing(body).utf8), path: "svg", limits: limits, asContent: false)
        return try XCTUnwrap(SVGContent.document(document.root)).isWithinRenderingLimits()
    }

    /// The section a refused drawing is shown in, built as the reader builds it. The limits are
    /// asked first: were they to let the drawing through, building the section would hand it to
    /// the renderer, and the run would end there instead of failing here.
    private func refusedSection(_ body: String, as markup: (String) -> String, files: (String) -> [String: Data] = { _ in [:] },
                                file: StaticString = #filePath, line: UInt = #line) throws -> SectionText? {
        guard try !withinRenderingLimits(body) else {
            XCTFail("the drawing is let through to the renderer", file: file, line: line)
            return nil
        }
        return try RichMediaBook(body: markup(drawing(body)), files: files(drawing(body))).build()
    }

    // MARK: Drawings

    private enum Spelling: CaseIterable {
        /// On a shape in the content: `<mask id='r0'><rect mask='url(#r1)'/></mask>`.
        case content
        /// On the mask or clip path itself: `<mask id='r0' mask='url(#r1)'>`.
        case own
        /// In a `style` attribute of a shape in the content.
        case style
        /// By a stylesheet rule that selects a shape in the content by its class.
        case sheet
        /// On a shape in the definitions that the content draws with `use`.
        case use
    }

    /// `count` masks or clip paths, each leading to the next and, in a ring, the last to the
    /// first, with a rectangle that the first masks or clips.
    private func linked(_ element: String, count: Int, ring: Bool = true, _ spelling: Spelling = .content, nesting: Int = 0) -> String {
        let property = element == "mask" ? "mask" : "clip-path"
        var sheet = "", definitions = ""
        let parts = (0..<count).map { index -> String in
            guard ring || index + 1 < count else { return "<\(element) id='r\(index)'><rect \(Self.box)/></\(element)>" }
            let next = "url(#r\((index + 1) % count))"
            let open = String(repeating: "<g>", count: nesting), close = String(repeating: "</g>", count: nesting)
            switch spelling {
            case .content: return "<\(element) id='r\(index)'>\(open)<rect \(Self.box) \(property)='\(next)'/>\(close)</\(element)>"
            case .own: return "<\(element) id='r\(index)' \(property)='\(next)'><rect \(Self.box)/></\(element)>"
            case .style: return "<\(element) id='r\(index)'><rect \(Self.box) style='\(property):\(next)'/></\(element)>"
            case .sheet:
                sheet += ".k\(index){\(property):\(next)}"
                return "<\(element) id='r\(index)'><rect \(Self.box) class='k\(index)'/></\(element)>"
            case .use:
                definitions += "<rect id='s\(index)' \(Self.box) \(property)='\(next)'/>"
                return "<\(element) id='r\(index)'><use href='#s\(index)'/></\(element)>"
            }
        }
        return (sheet.isEmpty ? "" : "<style>\(sheet)</style>") + "<defs>\(definitions)</defs>" + parts.joined()
            + "<rect width='5' height='5' \(property)='url(#r0)'/>"
    }

    /// A ring of `count` gradients, entered by a chain of `tail` more that are not in it.
    private func gradients(ring count: Int, tail: Int, element: String = "linearGradient", attribute: String = "href") -> String {
        let ring = (0..<count).map { "<\(element) id='r\($0)' \(attribute)='#r\(($0 + 1) % count)'/>" }
        let tail = (0..<tail).map { "<\(element) id='t\($0)' \(attribute)='#\($0 + 1 < tail ? "t\($0 + 1)" : "r0")'/>" }
        return (ring + tail).joined() + "<rect width='5' height='5' fill='url(#\(tail.isEmpty ? "r0" : "t0"))'/>"
    }

    /// The stops of the issue's drawing: opaque white, at offsets whose sum rounds past one.
    private static let stops = "<stop offset='0.07' stop-color='#fff'/><stop offset='0.29' stop-color='#fff'/><stop offset='1' stop-color='#fff'/>"
    /// The end points of a linear gradient that has no length.
    private static let noLength = "x1='5' y1='5' x2='5' y2='5'"

    /// A rectangle filled with `g`, a linear gradient of no length that holds the issue's stops,
    /// after `definitions`. With a spread of `repeat` or `reflect` it is the issue's drawing: the
    /// renderer ends the process as it paints the rectangle.
    private func gradient(_ attributes: String = "", after definitions: String = "", fill: String = "fill='url(#g)'") -> String {
        "\(definitions)<linearGradient id='g' \(Self.noLength) \(attributes)>\(Self.stops)</linearGradient><rect width='5' height='5' \(fill)/>"
    }

    // MARK: Fallback

    func testARefusedDrawingShowsItsFallbackTextWithADisclosure() throws {
        let refused: [(String, String)] = [
            ("three masks in a ring", linked("mask", count: 3)),
            ("three clip paths in a ring, by a stylesheet", linked("clipPath", count: 3, .sheet)),
            ("a gradient walk into a loop", gradients(ring: 2, tail: 1)),
            ("a chain of 128 masks", linked("mask", count: 128, ring: false)),
        ]
        for (name, body) in refused {
            // Inline: the drawing's own title stands in for it.
            if let text = try refusedSection("<title>\(name)</title>" + body, as: { "<p>\($0)</p>" }) {
                XCTAssertTrue(text.richMediaImages.isEmpty, "\(name): nothing is drawn")
                XCTAssertEqual(text.richMediaPlain, name, "\(name): the title is shown")
                XCTAssertEqual(text.report.unsupportedElements["svg"], 1, "\(name): disclosed")
            }
            // As an archive image: its alt text does.
            if let text = try refusedSection(body, as: { _ in "<p><img src='d.svg' alt='\(name)'/></p>" }, files: { ["d.svg": Data($0.utf8)] }) {
                XCTAssertTrue(text.richMediaImages.isEmpty, "\(name): no image")
                XCTAssertEqual(text.richMediaPlain, name, "\(name): the alt text is shown")
                XCTAssertEqual(text.report.unsupportedElements["svg"], 1, "\(name): disclosed")
            }
        }
    }

    func testAScreenAcceptedGradientPanicShowsInlineAndArchiveFallbackWithDisclosure() throws {
        for (name, body) in [
            ("a gradient of no length that repeats", gradient("spreadMethod='repeat'")),
            ("a gradient that reflects through another", gradient("href='#b'", after: "<radialGradient id='b' spreadMethod='reflect'/>")),
        ] {
            // The reference screen's own verdict is StaticSVG's to test.
            XCTAssertTrue(try withinRenderingLimits(body), name)
            let inline = try RichMediaBook(body: "<p>\(drawing("<title>\(name)</title>" + body))</p>").build()
            let archive = try RichMediaBook(body: "<p><img src='d.svg' alt='\(name)'/></p>", files: ["d.svg": Data(drawing(body).utf8)]).build()
            for text in [inline, archive] {
                XCTAssertTrue(text.richMediaImages.isEmpty, name)
                XCTAssertEqual(text.richMediaPlain, name)
                XCTAssertEqual(text.report.unsupportedElements["svg"], 1, name)
            }
        }
    }

    // MARK: Drawn as the renderer reads them

    /// The issue's drawing ([#316](https://github.com/vocaro/EPUBLib/issues/316)): a gradient
    /// whose empty `href` overrides an `xlink:href` that leads to a gradient that repeats. The
    /// renderer cannot use the `href` and pads the gradient, as written and as serialized, since
    /// the serializer leaves out the `xlink:href` with it; kept, the `xlink:href` took over and led
    /// the renderer into the repeat that panics. The drawing is shown, white, inline and from the
    /// archive, and only its `href` is disclosed.
    func testAnXLinkHrefThatAnHrefOverridesIsNotFollowed() throws {
        let body = gradient("href='' xlink:href='#b'", after: "<radialGradient id='b' spreadMethod='repeat'/>")
        let inline = try RichMediaBook(body: "<p>\(drawing(body))</p>").build()
        let archive = try RichMediaBook(body: "<p><img src='d.svg' alt='Padded'/></p>", files: ["d.svg": Data(drawing(body).utf8)]).build()
        for (form, text) in [("inline", inline), ("from the archive", archive)] {
            let bitmap = try XCTUnwrap(text.richMediaImages.first?.source.decode(maxPixelSize: 10), "\(form): drawn")
            XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 2, y: 2), [255, 255, 255, 255], form)
            XCTAssertEqual(text.report.unsupportedElements, ["svg:image": 1], "\(form): the href alone is disclosed")
        }
    }

    /// A drawing's class rules reach the elements the renderer styles: class names are compared
    /// by their bytes, and a class list is split at spaces alone
    /// ([#752](https://github.com/vocaro/EPUBLib/issues/752)). A rule for the class after a space
    /// that a combining mark follows closes a ring of masks, and the drawing shows its fallback; a
    /// rule for `ñ` (U+00F1) does not reach `n&#x303;`, which `String` compares equal to it, and
    /// the drawing is drawn.
    func testAClassRuleReachesTheElementsTheRendererStylesByTheirBytes() throws {
        let ring = linked("mask", count: 3, .sheet)
        let spaced = ring.replacingOccurrences(of: "class='k1'", with: "class='k1 &#x301;z'")
        if let text = try refusedSection("<title>Masks</title>" + spaced, as: { "<p>\($0)</p>" }) {
            XCTAssertTrue(text.richMediaImages.isEmpty)
            XCTAssertEqual(text.richMediaPlain, "Masks")
            XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
        }
        let equivalent = ring.replacingOccurrences(of: "class='k1'", with: "class='n&#x303;'").replacingOccurrences(of: ".k1{", with: ".\u{F1}{")
        let text = try RichMediaBook(body: "<p>\(drawing(equivalent))</p>").build()
        let bitmap = try XCTUnwrap(text.richMediaImages.first?.source.decode(maxPixelSize: 10), "drawn, not refused")
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 2, y: 2)[3], 255, "the masked rectangle shows")
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 7, y: 7)[3], 0)
        XCTAssertEqual(text.report.unsupportedElements, [:])
    }
}
