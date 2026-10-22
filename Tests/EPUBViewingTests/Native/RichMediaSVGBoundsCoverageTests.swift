import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import StaticSVG
import XCTest
@testable import EPUBViewing

/// What a reader shows for an SVG past the two renderer amplifications the byte, node, depth and
/// expansion limits do not bound: one `<text>` run, whose layout is super-linear in its length,
/// and a `<marker>`, whose content the renderer converts again at every vertex it is drawn at.
/// Past its bound, each shows the fallback text with the same `svg` disclosure as the other limits
/// ([#170](https://github.com/vocaro/EPUBLib/issues/170)). The bounds themselves, the seven rules
/// of the marker check among them, are StaticSVG's and are tested there, in
/// `SVGBoundsCoverageTests`.
final class RichMediaSVGBoundsCoverageTests: XCTestCase {
    private static let ns = "xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'"

    /// An SVG whose root has few enough attributes to add nothing to the size of a marker in it.
    private func svg(_ defs: String, _ body: String, root: String = "width='200' height='50'") -> String {
        "<svg \(Self.ns) \(root)><defs>\(defs)</defs>\(body)</svg>"
    }

    /// A marker of `rects` rectangles: its size is `rects`, each element counting one.
    private func marker(_ id: String = "m", rects: Int = 1, _ attributes: String = "") -> String {
        "<marker id='\(id)' \(attributes)>" + String(repeating: "<rect width='1' height='1'/>", count: rects) + "</marker>"
    }

    /// A path whose data holds exactly `vertices` numbers, which is what the check counts it as.
    private func path(vertices: Int, _ attributes: String = "") -> String {
        precondition(vertices >= 2)
        return "<path d='M0 0" + String(repeating: "h1", count: vertices - 2) + "' \(attributes)/>"
    }

    private func parsed(_ svg: String) -> ContentNode? {
        try? ContentDocument.parse(
            Data(svg.utf8), path: "svg",
            limits: .init(bytes: SVGLimits.renderer.bytes, depth: SVGLimits.renderer.depth, nodes: SVGLimits.renderer.nodes),
            asContent: false).root
    }

    /// The whole pre-render check, without the renderer.
    private func isWithinLimits(_ svg: String) -> Bool {
        parsed(svg).flatMap { SVGContent.document($0) }?.isWithinRenderingLimits() ?? false
    }

    /// Whether the SVG renders through the production renderer entry point.
    private func renders(_ svg: String) -> Bool {
        ReaderImageSource.svg(Data(svg.utf8), path: "", key: UUID().uuidString) != nil
    }

    private func image(_ body: String, files: [String: Data] = [:]) throws -> (ReaderImageAttachment?, SectionText) {
        let text = try RichMediaBook(body: body, files: files).build()
        return (text.richMediaImages.first, text)
    }

    // MARK: One text run (doc: 20,000 characters)

    func testOverLongInlineTextRunShowsTitleFallbackAndDiscloses() throws {
        let run = String(repeating: "a", count: 20_001)
        let (attachment, text) = try image("<p><svg \(Self.ns) width='200' height='50'><title>Caption</title><text x='0' y='20'>\(run)</text></svg></p>")
        XCTAssertNil(attachment, "an over-long run is not rendered")
        XCTAssertEqual(text.richMediaPlain, "Caption", "its title stands in")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1, "and it is disclosed like the other limits")
    }

    func testOverLongArchiveTextRunShowsAltTextAndDiscloses() throws {
        let run = String(repeating: "a", count: 20_001)
        let svg = "<svg \(Self.ns) width='200' height='50'><text x='0' y='20'>\(run)</text></svg>"
        let (attachment, text) = try image("<p><img src='long.svg' alt='Diagram'/></p>", files: ["long.svg": Data(svg.utf8)])
        XCTAssertNil(attachment)
        XCTAssertEqual(text.richMediaPlain, "Diagram")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }

    /// A `<tref>` renders the text of the element it names, and SVG 2 removed it, so an SVG that
    /// holds one is refused wherever it stands: inline, its fallback stands in and it is disclosed.
    /// Where it is refused is tested in StaticSVG, in the test of the same name.
    func testTrefIsRefusedWhereverItStands() throws {
        let ns = Self.ns
        let (attachment, text) = try image("<p><svg \(ns) width='200' height='50'><title>Legend</title><defs><g id='t'>label</g></defs><text y='20'><tref xlink:href='#t'/></text></svg></p>")
        XCTAssertNil(attachment)
        XCTAssertEqual(text.richMediaPlain, "Legend", "the fallback stands in")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }

    // MARK: Rule 7: the count (doc: 100,000)

    func testMarkerBombShowsFallbackAndDiscloses() throws {
        let bomb = "<svg \(Self.ns) width='200' height='50'><desc>Network path</desc><defs>\(marker(rects: 100))</defs>\(path(vertices: 1_002, "marker-mid='url(#m)' stroke='black'"))</svg>"
        let (attachment, text) = try image("<p><img src='bomb.svg' alt='Flow'/></p>", files: ["bomb.svg": Data(bomb.utf8)])
        XCTAssertNil(attachment, "a marker bomb is not rendered")
        XCTAssertEqual(text.richMediaPlain, "Flow")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)

        let (inline, inlineText) = try image("<p>\(bomb)</p>")
        XCTAssertNil(inline)
        XCTAssertEqual(inlineText.richMediaPlain, "Network path", "inline, its description stands in")
        XCTAssertEqual(inlineText.report.unsupportedElements["svg"], 1)
    }

    /// The limits are read from the tree this module parses, and the renderer parses the bytes for
    /// itself. Bytes this module could only read by recovering them as HTML — here, UTF-8 that
    /// declares itself UTF-16, a declaration the renderer ignores — give a tree in which a prefixed
    /// name such as `xlink:href` is not the name the renderer sees, so nothing counted in it bounds
    /// what the renderer would draw. Such an SVG is refused.
    ///
    /// The marker count of the drawing it misdeclares is tested in StaticSVG, in the test of the
    /// same name.
    func testAnSVGRecoveredAsHTMLIsRefused() throws {
        let drawing = svg(marker(rects: 2) + "<g id='g'>\(path(vertices: 4, "marker-mid='url(#m)' stroke='black'"))</g>", "<use xlink:href='#g'/><use xlink:href='#g'/>")
        XCTAssertTrue(renders(drawing))
        let misdeclared = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>" + drawing
        XCTAssertEqual(parsed(misdeclared)?.name, "html", "recovered as HTML")
        XCTAssertFalse(isWithinLimits(misdeclared))
        XCTAssertFalse(renders(misdeclared))
        XCTAssertFalse(renders("<?xml version=\"1.0\" encoding=\"UTF-16\"?><svg \(Self.ns) width='9' height='9'><rect width='9' height='9'/></svg>"),
                       "with or without a marker")
    }
}
