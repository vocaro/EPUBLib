import XCTest
@testable import EPUBViewing

/// References between an SVG's elements that the bundled renderer cannot follow: a loop of
/// masks or clip paths it does not unlink, a gradient `href` walk that never ends, and a chain
/// of nesting and references deeper than the nesting limit. With them, a linear gradient that
/// repeats or reflects, which the renderer panics on where the gradient has no length. Each is
/// refused before the renderer parses it and shows its fallback text with the `svg` disclosure.
///
/// The renderer spends its stack, never returns or panics on most drawings here, and any of
/// the three would end the test run. So the screen is asked for its verdict, which is plain
/// Swift over the parsed drawing and never reaches the renderer. Only two kinds of drawing are
/// handed on: those the renderer was shown to draw safely, one child process a drawing, on the
/// 512 KiB stack a section is built on; and those the rendering limits have just refused,
/// which stop before it.
final class RichMediaSVGReferenceCoverageTests: XCTestCase {
    private static let ns = "xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'"
    /// A shape's size and paint: white, so that it shows through a mask.
    private static let box = "width='5' height='5' fill='white'"

    private func drawing(_ body: String) -> String {
        "<svg \(Self.ns) width='10' height='10'>\(body)</svg>"
    }

    /// The screen's verdict on a drawing, and that of the rendering limits `SVGRenderer` asks
    /// before the renderer is given a byte. Neither reaches the renderer.
    private func verdicts(_ body: String) throws -> (screen: Bool, limits: Bool) {
        let limits = ContentLimits(bytes: SVGContent.maximumBytes, depth: SVGContent.maximumDepth, nodes: SVGContent.maximumNodes)
        let document = try ContentDocument.parse(Data(drawing(body).utf8), path: "svg", limits: limits, asContent: false)
        return (SVGReferenceScreen.accepts(document.nodes, ids: SVGContent.elementsByID(document.nodes)), SVGContent.isWithinRenderingLimits(document.root))
    }

    /// Whether the screen passes a drawing. What it refuses, the rendering limits refuse.
    private func passes(_ body: String, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let (screen, limits) = try verdicts(body)
        if !screen { XCTAssertFalse(limits, "the rendering limits refuse what the screen does", file: file, line: line) }
        return screen
    }

    /// A drawing the renderer was shown to draw safely, decoded as an archive image is.
    private func source(_ body: String) -> ReaderImageSource? {
        ReaderImageSource.svg(Data(drawing(body).utf8), path: "", key: UUID().uuidString)
    }

    /// The section a refused drawing is shown in, built as the reader builds it. The limits are
    /// asked first: were they to let the drawing through, building the section would hand it to
    /// the renderer, and the run would end there instead of failing here.
    private func refusedSection(_ body: String, as markup: (String) -> String, files: (String) -> [String: Data] = { _ in [:] },
                                file: StaticString = #filePath, line: UInt = #line) throws -> SectionText? {
        let (screen, limits) = try verdicts(body)
        guard !screen, !limits else {
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

    /// `linked`, but reached only from a marker: the marker has the first as its own `mask` or
    /// `clip-path`, which its content takes by saying `inherit`, and a path draws the marker.
    /// A marker's content may name nothing itself, and this is the one way on from it.
    private func linkedThroughAMarker(_ element: String, count: Int, ring: Bool = true) -> String {
        let property = element == "mask" ? "mask" : "clip-path"
        return linked(element, count: count, ring: ring).replacingOccurrences(of: "<rect width='5' height='5' \(property)='url(#r0)'/>", with: "")
            + "<marker id='k' overflow='visible' \(property)='url(#r0)'><rect \(Self.box) \(property)='inherit'/></marker>"
            + "<path d='M0 0 L5 5' stroke='black' marker-end='url(#k)'/>"
    }

    /// A ring of `count` gradients, entered by a chain of `tail` more that are not in it.
    private func gradients(ring count: Int, tail: Int, element: String = "linearGradient", attribute: String = "href") -> String {
        let ring = (0..<count).map { "<\(element) id='r\($0)' \(attribute)='#r\(($0 + 1) % count)'/>" }
        let tail = (0..<tail).map { "<\(element) id='t\($0)' \(attribute)='#\($0 + 1 < tail ? "t\($0 + 1)" : "r0")'/>" }
        return (ring + tail).joined() + "<rect width='5' height='5' fill='url(#\(tail.isEmpty ? "r0" : "t0"))'/>"
    }

    /// Masks a, b and c, where a's content is masked by b and b's by c, and `closing` is c's
    /// content: the renderer's stack is spent exactly when it takes `closing` to be masked by a.
    private func ringClosed(by closing: String, sheet: String = "", definitions: String = "") -> String {
        "\(sheet)<mask id='a'><rect \(Self.box) mask='url(#b)'/></mask><mask id='b'><rect \(Self.box) mask='url(#c)'/></mask>"
            + "<mask id='c'>\(closing)</mask>\(definitions)<rect width='5' height='5' mask='url(#a)'/>"
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

    // MARK: Loops of masks and clip paths

    func testARingOfThreeOrMoreMasksOrClipPathsIsRefusedHoweverItIsLinked() throws {
        for element in ["mask", "clipPath"] {
            for spelling in Spelling.allCases {
                // The renderer unlinks a mask or clip path that leads back to itself, or to one that leads back to it.
                for count in [1, 2] {
                    XCTAssertTrue(try passes(linked(element, count: count, spelling)), "\(element), \(spelling): a ring of \(count) is the renderer's to unlink")
                }
                // It finds no longer ring, and follows it until its stack is spent.
                for count in [3, 4, 9] {
                    XCTAssertFalse(try passes(linked(element, count: count, spelling)), "\(element), \(spelling): a ring of \(count)")
                }
            }
        }
        // A ring of three sharing a link with a ring of two: unlinking the two may leave the three.
        let rect = "<rect \(Self.box)"
        XCTAssertFalse(try passes("<mask id='a'>\(rect) mask='url(#b)'/></mask><mask id='b'>\(rect) mask='url(#a)'/>\(rect) mask='url(#c)'/></mask><mask id='c'>\(rect) mask='url(#a)'/></mask><rect width='5' height='5' mask='url(#a)'/>"))
        // Three that lead to each other only in twos are refused as well: more than two is not told apart from a ring.
        XCTAssertFalse(try passes("<mask id='a'>\(rect) mask='url(#b)'/></mask><mask id='b'>\(rect) mask='url(#a)'/>\(rect) mask='url(#c)'/></mask><mask id='c'>\(rect) mask='url(#b)'/></mask><rect width='5' height='5' mask='url(#a)'/>"))
        // A ring that nothing drawn leads to is never followed.
        XCTAssertTrue(try passes("<defs>" + linked("mask", count: 3).replacingOccurrences(of: "<rect width='5' height='5' mask='url(#r0)'/>", with: "") + "</defs><rect width='5' height='5'/>"))
    }

    func testLoopsTheRendererEndsStillDraw() throws {
        for element in ["mask", "clipPath"] {
            for spelling in [Spelling.content, .own, .sheet] {
                for count in [1, 2] {
                    XCTAssertNotNil(source(linked(element, count: count, spelling)), "\(element), \(spelling): a ring of \(count) draws")
                }
            }
        }
    }

    func testAMaskOrClipPathThatOnlyAMarkerLeadsToIsFollowed() throws {
        for element in ["mask", "clipPath"] {
            for count in [1, 2] {
                XCTAssertNotNil(source(linkedThroughAMarker(element, count: count)), "\(element): a ring of \(count) behind a marker draws")
            }
            for count in [3, 5] {
                XCTAssertFalse(try passes(linkedThroughAMarker(element, count: count)), "\(element): a ring of \(count) behind a marker")
            }
            // The path, the marker and its rectangle are three levels before the first of the chain.
            XCTAssertNotNil(source(linkedThroughAMarker(element, count: 30, ring: false)), "\(element): 30 in a chain behind a marker draw")
            XCTAssertFalse(try passes(linkedThroughAMarker(element, count: 31, ring: false)), "\(element): 31 in a chain behind a marker")
        }
    }

    // MARK: Gradient walks

    func testAGradientWalkThatEntersALoopFromOutsideIsRefused() throws {
        // The renderer walks `href` from a gradient until it is back at that gradient: from outside a loop it never is.
        for count in [2, 3, 7] {
            for tail in [1, 4] {
                XCTAssertFalse(try passes(gradients(ring: count, tail: tail)), "a loop of \(count) entered through \(tail)")
            }
        }
        XCTAssertFalse(try passes(gradients(ring: 2, tail: 1, attribute: "xlink:href")), "by xlink:href")
        XCTAssertFalse(try passes(gradients(ring: 2, tail: 1, element: "radialGradient")), "radial gradients")
        XCTAssertFalse(try passes("<linearGradient id='t' href='#a'/><radialGradient id='a' href='#b'/><linearGradient id='b' xlink:href='#a'/><rect width='5' height='5' fill='url(#t)'/>"), "both kinds, both spellings")
        // The issue's own drawing: a walks to b, and b and c name each other.
        XCTAssertFalse(try passes("<linearGradient id='a' href='#b'/><linearGradient id='b' href='#c'/><linearGradient id='c' href='#b'/><rect width='5' height='5' fill='url(#a)'/>"))
        // A loop with no way in but its own gradients ends where it began, and one gradient naming itself ends at once.
        for count in [1, 2, 3, 7] {
            XCTAssertNotNil(source(gradients(ring: count, tail: 0)), "a loop of \(count) with nothing leading in")
        }
        XCTAssertNotNil(source(gradients(ring: 1, tail: 3)), "a chain that ends at a gradient naming itself")
        // A chain with no loop is walked to its end, however long.
        let chain = (0..<200).map { "<linearGradient id='g\($0)'" + ($0 < 199 ? " href='#g\($0 + 1)'/>" : "><stop offset='0' stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient>") }.joined()
        XCTAssertNotNil(source(chain + "<rect width='5' height='5' fill='url(#g0)'/>"))
    }

    // MARK: Gradients that repeat

    func testALinearGradientThatRepeatsOrReflectsIsRefused() throws {
        // The renderer was shown to end the process on each of these.
        let fatal: [(String, String)] = [
            ("repeat", gradient("spreadMethod='repeat'")),
            ("reflect", gradient("spreadMethod='reflect'")),
            ("xlink:spreadMethod", gradient("xlink:spreadMethod='repeat'")),
            ("xml:spreadMethod", gradient("xml:spreadMethod='reflect'")),
            ("the first of two attributes", gradient("xlink:spreadMethod='repeat' spreadMethod='pad'")),
            ("an attribute that a style contradicts", gradient("spreadMethod='repeat' style='spreadMethod:pad'")),
            ("painted on a stroke", gradient("spreadMethod='repeat'", fill: "fill='none' stroke='url(#g)'")),
            ("painted by a rule", gradient("spreadMethod='repeat'", after: "<style>rect{fill:url(#g)}</style>", fill: "")),
            // The spread it does not state is that of the first gradient its href leads to that states one.
            ("from a linear gradient", gradient("href='#b'", after: "<linearGradient id='b' spreadMethod='repeat'/>")),
            ("from a radial gradient", gradient("href='#b'", after: "<radialGradient id='b' spreadMethod='reflect'/>")),
            ("by xlink:href", gradient("xlink:href='#b'", after: "<linearGradient id='b' spreadMethod='repeat'/>")),
            ("from one defined after it", "<linearGradient id='g' \(Self.noLength) href='#b'>\(Self.stops)</linearGradient><rect width='5' height='5' fill='url(#g)'/><radialGradient id='b' spreadMethod='repeat'/>"),
            ("through another", gradient("href='#m'", after: "<radialGradient id='b' spreadMethod='repeat'/><linearGradient id='m' href='#b'/>")),
            ("through five", gradient("href='#m1'", after: "<radialGradient id='b' spreadMethod='repeat'/><linearGradient id='m4' href='#b'/><radialGradient id='m3' href='#m4'/><linearGradient id='m2' xlink:href='#m3'/><radialGradient id='m1' href='#m2'/>")),
            ("with its end points and stops", "<linearGradient id='b' \(Self.noLength) spreadMethod='repeat'>\(Self.stops)</linearGradient><linearGradient id='g' href='#b'/><rect width='5' height='5' fill='url(#g)'/>"),
            ("from the last of two with one id", gradient("href='#b'", after: "<linearGradient id='b' spreadMethod='pad'/><linearGradient id='b' spreadMethod='repeat'/>")),
            ("by xml:id", gradient("href='#b'", after: "<linearGradient xml:id='b' spreadMethod='repeat'/>")),
            ("by href where xlink:href names another", gradient("xlink:href='#p' href='#b'", after: "<linearGradient id='b' spreadMethod='repeat'/><linearGradient id='p' spreadMethod='pad'/>")),
        ]
        for (name, body) in fatal { XCTAssertFalse(try passes(body), name) }

        // The renderer draws these. Telling them from the ones above is its work: a gradient's
        // length, which of the gradients on a walk it takes the spread from, which of two
        // elements an id means. So they are refused with them.
        let drawn: [(String, String)] = [
            ("a gradient with a length", "<linearGradient id='g' x2='1' spreadMethod='repeat'><stop offset='0' stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient><rect width='5' height='5' fill='url(#g)'/>"),
            ("stripes in the units of the drawing", "<linearGradient id='g' gradientUnits='userSpaceOnUse' x1='0' x2='2' spreadMethod='reflect'><stop offset='0' stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient><rect width='5' height='5' fill='url(#g)'/>"),
            ("a gradient that paints nothing", gradient("spreadMethod='repeat'", fill: "")),
            ("a gradient in definitions that nothing names", "<defs><linearGradient spreadMethod='reflect'/></defs><rect width='5' height='5'/>"),
            ("the second of two attributes", gradient("spreadMethod='pad' xlink:spreadMethod='repeat'")),
            ("its own pad before one that repeats", gradient("href='#b' spreadMethod='pad'", after: "<linearGradient id='b' spreadMethod='repeat'/>")),
            ("a word the renderer does not know before one that repeats", gradient("href='#b' spreadMethod='tile'", after: "<radialGradient id='b' spreadMethod='repeat'/>")),
            ("a pad on the walk before one that repeats", gradient("href='#m'", after: "<radialGradient id='b' spreadMethod='repeat'/><linearGradient id='m' href='#b' spreadMethod='pad'/>")),
            ("the first of two with one id", gradient("href='#b'", after: "<linearGradient id='b' spreadMethod='repeat'/><linearGradient id='b' spreadMethod='pad'/>")),
            ("a radial gradient that takes repeat from a linear one", "<linearGradient id='b' x2='1' spreadMethod='repeat'/><radialGradient id='g' href='#b'>\(Self.stops)</radialGradient><rect width='5' height='5' fill='url(#g)'/>"),
            ("a linear gradient in another namespace", "<q:linearGradient xmlns:q='urn:q' id='g' \(Self.noLength) spreadMethod='repeat'>\(Self.stops)</q:linearGradient><rect width='5' height='5' fill='url(#g)'/>"),
        ]
        for (name, body) in drawn { XCTAssertFalse(try passes(body), name) }
    }

    func testGradientsTheRendererPadsAndRadialGradientsStillDraw() throws {
        // Each of these was shown to draw: the renderer takes the linear gradient to pad, and paints its last stop.
        let padded: [(String, String)] = [
            ("pad", gradient("spreadMethod='pad'")),
            ("no spreadMethod", gradient()),
            ("a word the renderer does not know", gradient("spreadMethod='tile'")),
            ("repeat in capitals", gradient("spreadMethod='REPEAT'")),
            ("repeat after a space", gradient("spreadMethod=' repeat'")),
            ("repeat before a space", gradient("spreadMethod='repeat '")),
            ("inherit, under a group that says repeat", "<g spreadMethod='repeat'><linearGradient id='g' \(Self.noLength) spreadMethod='inherit'>\(Self.stops)</linearGradient></g><rect width='5' height='5' fill='url(#g)'/>"),
            ("an empty value", gradient("spreadMethod=''")),
            ("the attribute's name in lower case", gradient("spreadmethod='repeat'")),
            ("the attribute in another namespace", "<linearGradient xmlns:q='urn:q' id='g' \(Self.noLength) q:spreadMethod='repeat'>\(Self.stops)</linearGradient><rect width='5' height='5' fill='url(#g)'/>"),
            // It is not a presentation attribute: the renderer drops a declaration of it.
            ("a style attribute", gradient("style='spreadMethod:repeat'")),
            ("a type rule", gradient(after: "<style>linearGradient{spreadMethod:repeat}</style>")),
            ("an id rule that is important", gradient(after: "<style>#g{spreadMethod:reflect !important}</style>")),
            // Nor is it inherited, or taken from an element that is not a gradient.
            ("repeat on a group, a stop and the shape", "<g spreadMethod='repeat'><linearGradient id='g' \(Self.noLength)><stop spreadMethod='repeat' offset='0.07' stop-color='#fff'/><stop offset='1' stop-color='#fff'/></linearGradient></g><rect width='5' height='5' fill='url(#g)' spreadMethod='repeat'/>"),
            ("an href to a shape that says repeat", gradient("href='#b'", after: "<rect id='b' spreadMethod='repeat'/>")),
            ("an href with no hash", gradient("href='b'", after: "<radialGradient id='b' spreadMethod='repeat'/>")),
            ("an href in another namespace", "<radialGradient id='b' spreadMethod='repeat'/><linearGradient xmlns:q='urn:q' id='g' \(Self.noLength) q:href='#b'>\(Self.stops)</linearGradient><rect width='5' height='5' fill='url(#g)'/>"),
            ("by xlink:href where href names another", "<radialGradient id='b' spreadMethod='repeat'/><linearGradient id='p'/><linearGradient id='g' \(Self.noLength) xlink:href='#b' href='#p'>\(Self.stops)</linearGradient><rect width='5' height='5' fill='url(#g)'/>"),
        ]
        for (name, body) in padded {
            XCTAssertTrue(try passes(body), name)
            XCTAssertNotNil(source(body), name)
        }

        // A radial gradient never takes the path that panics, whatever its spread and however little is left of it.
        let radial: [(String, String)] = [
            ("repeat", "r='0.5'"),
            ("no radius", "r='0'"),
            ("no radius, in the units of the drawing", "gradientUnits='userSpaceOnUse' cx='5' cy='5' r='0'"),
            ("a radius below the renderer's tolerance", "gradientUnits='userSpaceOnUse' cx='5' cy='5' r='0.00001'"),
            ("a focal circle that is the circle", "gradientUnits='userSpaceOnUse' cx='5' cy='5' fx='5' fy='5' r='3' fr='3'"),
            ("a focal circle that is the circle, both no size", "r='0' fr='0'"),
            ("a focal circle larger than the circle", "r='0.3' fr='0.6'"),
            ("a focus on the circle", "gradientUnits='userSpaceOnUse' cx='5' cy='5' fx='8' fy='5' r='3'"),
            ("a focus outside the circle", "gradientUnits='userSpaceOnUse' cx='5' cy='5' fx='20' fy='5' r='3'"),
            ("two circles of one size apart", "gradientUnits='userSpaceOnUse' cx='5' cy='5' fx='2' fy='5' r='3' fr='3'"),
            ("a transform that flattens it", "gradientTransform='scale(0)'"),
        ]
        for (name, attributes) in radial {
            for spread in ["repeat", "reflect"] {
                let body = "<radialGradient id='g' \(attributes) spreadMethod='\(spread)'>\(Self.stops)</radialGradient><rect width='5' height='5' fill='url(#g)'/>"
                XCTAssertTrue(try passes(body), "radial, \(spread): \(name)")
                XCTAssertNotNil(source(body), "radial, \(spread): \(name)")
            }
        }
        // A radial gradient's spread is not that of a linear gradient it leads to: the walk goes one way.
        let oneWay = "<linearGradient id='b' \(Self.noLength)>\(Self.stops)</linearGradient><radialGradient id='g' href='#b' spreadMethod='repeat'/>"
            + "<rect width='5' height='5' fill='url(#g)' stroke='url(#b)'/>"
        XCTAssertTrue(try passes(oneWay))
        XCTAssertNotNil(source(oneWay))
    }

    // MARK: Chains

    func testAChainOfNestingAndReferencesIsHeldToTheNestingLimit() throws {
        // Each mask is one level and its content another: the rectangle, then 31 pairs, is 63 levels.
        for element in ["mask", "clipPath"] {
            XCTAssertNotNil(source(linked(element, count: 31, ring: false)), "\(element): 31 in a chain draw")
            XCTAssertFalse(try passes(linked(element, count: 32, ring: false)), "\(element): 32 in a chain")
            // Linked on the masks themselves there is no content between them: one level each.
            XCTAssertTrue(try passes(linked(element, count: 62, ring: false, .own)), "\(element): 62 linked on themselves")
            XCTAssertFalse(try passes(linked(element, count: 63, ring: false, .own)), "\(element): 63 linked on themselves")
            // Nesting in the content counts with the references: four levels a mask here.
            XCTAssertTrue(try passes(linked(element, count: 16, ring: false, nesting: 2)), "\(element): 16 with nested content")
            XCTAssertFalse(try passes(linked(element, count: 17, ring: false, nesting: 2)), "\(element): 17 with nested content")
            for spelling in [Spelling.style, .sheet] {
                XCTAssertTrue(try passes(linked(element, count: 31, ring: false, spelling)), "\(element), \(spelling)")
                XCTAssertFalse(try passes(linked(element, count: 32, ring: false, spelling)), "\(element), \(spelling)")
            }
            // Through a `use` there is one level more for what it draws: three a mask.
            XCTAssertTrue(try passes(linked(element, count: 21, ring: false, .use)), "\(element) through use")
            XCTAssertFalse(try passes(linked(element, count: 22, ring: false, .use)), "\(element) through use")
        }
        // Nesting alone is as before: the parser's limit, not this screen's.
        XCTAssertNotNil(source(String(repeating: "<g>", count: 62) + "<rect width='5' height='5'/>" + String(repeating: "</g>", count: 62)))
    }

    // MARK: Where a reference is written

    func testAReferenceIsFoundWhereverTheRendererTakesOneFrom() throws {
        let rect = "<rect \(Self.box)"
        // Each closes the ring for the renderer, which was shown to spend its stack on it.
        let followed: [(String, String)] = [
            ("an attribute", ringClosed(by: "\(rect) mask='url(#a)'/>")),
            ("space inside the brackets", ringClosed(by: "\(rect) mask='url( #a )'/>")),
            ("single quotes", ringClosed(by: "\(rect) mask=\"url('#a')\"/>")),
            ("double quotes", ringClosed(by: "\(rect) mask='url(\"#a\")'/>")),
            ("a style attribute", ringClosed(by: "\(rect) style='mask:url(#a)'/>")),
            ("a style attribute with comments", ringClosed(by: "\(rect) style='/* x */ mask /* y */ : /* z */ url(#a) /* w */'/>")),
            ("an important declaration", ringClosed(by: "\(rect) style='fill:white;mask:url(#a) !important'/>")),
            ("a style that an attribute contradicts", ringClosed(by: "\(rect) mask='none' style='mask:url(#a)'/>")),
            ("a space past Latin-1 before the value", ringClosed(by: "\(rect) style='mask:\u{2003}url(#a)'/>")),
            ("xlink:mask", ringClosed(by: "\(rect) xlink:mask='url(#a)'/>")),
            ("xml:mask", ringClosed(by: "\(rect) xml:mask='url(#a)'/>")),
            ("a style attribute in another namespace", ringClosed(by: "<rect xmlns:q='urn:q' \(Self.box) q:style='mask:url(#a)'/>")),
            ("a class rule", ringClosed(by: "\(rect) class='k'/>", sheet: "<style>.k{mask:url(#a)}</style>")),
            ("a class attribute in another namespace", ringClosed(by: "<rect xmlns:q='urn:q' \(Self.box) q:class='k'/>", sheet: "<style>.k{mask:url(#a)}</style>")),
            ("a type rule", ringClosed(by: "<circle r='3' fill='white'/>", sheet: "<style>circle{mask:url(#a)}</style>")),
            ("an id rule", ringClosed(by: "\(rect) id='x'/>", sheet: "<style>#x{mask:url(#a)}</style>")),
            ("an attribute rule", ringClosed(by: "\(rect) data-x='1'/>", sheet: "<style>[data-x]{mask:url(#a)}</style>")),
            ("a descendant rule", ringClosed(by: "<circle r='3' fill='white'/>", sheet: "<style>mask circle{mask:url(#a)}</style>")),
            ("a first-child rule", ringClosed(by: "<circle r='3' fill='white'/>", sheet: "<style>#c :first-child{mask:url(#a)}</style>")),
            ("a stylesheet after the drawing", ringClosed(by: "\(rect) class='k'/>", definitions: "<style>.k{mask:url(#a)}</style>")),
            ("a stylesheet in CDATA", ringClosed(by: "\(rect) class='k'/>", sheet: "<style><![CDATA[.k{mask:url(#a)}]]></style>")),
            ("a stylesheet in metadata", ringClosed(by: "\(rect) class='k'/>", sheet: "<metadata><style>.k{mask:url(#a)}</style></metadata>")),
            ("a style element in another namespace", ringClosed(by: "\(rect) class='k'/>", sheet: "<x:style xmlns:x='urn:x'>.k{mask:url(#a)}</x:style>")),
            ("a rule after an at-rule", ringClosed(by: "\(rect) class='k'/>", sheet: "<style>@font-face{font-family:x} .k{mask:url(#a)}</style>")),
            ("a rule after an at sign alone", ringClosed(by: "\(rect) class='k'/>", sheet: "<style>@ .k{mask:url(#a)}</style>")),
            ("a selector cut short by a stroke", ringClosed(by: "\(rect) class='k'/>", sheet: "<style>.k/ .z{mask:url(#a)}</style>")),
            ("a bracket in a comment before the block", ringClosed(by: "\(rect) class='k'/>", sheet: "<style>.k /* { */ {mask:url(#a)}</style>")),
            ("a bracket in a string before the declaration", ringClosed(by: "\(rect) class='k'/>", sheet: "<style>.k{font-family:'}';mask:url(#a)}</style>")),
            ("the parent's mask, inherited", ringClosed(by: "<g mask='url(#a)'>\(rect) mask='inherit'/></g>")),
            ("the mask of the use that draws it, inherited", ringClosed(by: "<use href='#q' mask='url(#a)'/>", definitions: "<defs>\(rect) id='q' mask='inherit'/></defs>")),
            ("in a switch", ringClosed(by: "<switch>\(rect) mask='url(#a)'/></switch>")),
            ("in a nested svg", ringClosed(by: "<svg>\(rect) mask='url(#a)'/></svg>")),
            ("in a link", ringClosed(by: "<a>\(rect) mask='url(#a)'/></a>")),
            ("on a use", ringClosed(by: "<use href='#q' mask='url(#a)'/>", definitions: "<defs>\(rect) id='q'/></defs>")),
            ("through a symbol", ringClosed(by: "<use href='#s'/>", definitions: "<symbol id='s'>\(rect) mask='url(#a)'/></symbol>")),
            ("through xlink:href", ringClosed(by: "<use xlink:href='#q'/>", definitions: "<defs>\(rect) id='q' mask='url(#a)'/></defs>")),
            ("through href where xlink:href names another", ringClosed(by: "<use xlink:href='#z' href='#q'/>", definitions: "<defs>\(rect) id='q' mask='url(#a)'/>\(rect) id='z'/></defs>")),
            ("through the first of two with one id", ringClosed(by: "<use href='#q'/>", definitions: "<defs>\(rect) id='q' mask='url(#a)'/>\(rect) id='q'/></defs>")),
        ]
        for (name, body) in followed { XCTAssertFalse(try passes(body), name) }
        // The last mask with an id is the one a reference means, and xml:id is an id.
        XCTAssertFalse(try passes("<mask id='a'>\(rect)/></mask>" + ringClosed(by: "\(rect) mask='url(#a)'/>")), "the last of two masks with one id")
        XCTAssertFalse(try passes(ringClosed(by: "\(rect) mask='url(#a)'/>").replacingOccurrences(of: "<mask id='a'>", with: "<mask xml:id='a'>")), "xml:id")

        // None of these closes the ring for the renderer, and the screen can tell: the drawing is drawn.
        let ignored: [(String, String)] = [
            ("no reference", ringClosed(by: "\(rect)/>")),
            ("URL in capitals", ringClosed(by: "\(rect) mask='URL(#a)'/>")),
            ("a name without its hash", ringClosed(by: "\(rect) mask='url(a)'/>")),
            ("a file before the hash", ringClosed(by: "\(rect) mask='url(x.svg#a)'/>")),
            ("text before the reference", ringClosed(by: "\(rect) mask='none url(#a)'/>")),
            ("a property in capitals", ringClosed(by: "\(rect) style='MASK:url(#a)'/>")),
            ("a declaration after one that cannot be read", ringClosed(by: "\(rect) style='1bad:x; mask:url(#a)'/>")),
            ("an attribute in another namespace", ringClosed(by: "<rect xmlns:q='urn:q' \(Self.box) q:mask='url(#a)'/>")),
            ("a rule in an at-rule's block", ringClosed(by: "\(rect) class='k'/>", sheet: "<style>@media screen{.k{mask:url(#a)}}</style>")),
            ("a property in capitals in a rule", ringClosed(by: "\(rect) class='k'/>", sheet: "<style>.k{MASK:url(#a)}</style>")),
            ("a class after a tab, which does not end a class", ringClosed(by: "\(rect) class='j&#9;k'/>", sheet: "<style>.k{mask:url(#a)}</style>")),
            ("a rule for another class", ringClosed(by: "\(rect) class='k'/>", sheet: "<style>.z{mask:url(#a)}</style>")),
            ("a rule whose block follows an unclosed comment", ringClosed(by: "\(rect) class='k'/>", sheet: "<style>/* .k{mask:url(#a)}</style>")),
            ("a shape in definitions", ringClosed(by: "<defs>\(rect) mask='url(#a)'/></defs>\(rect)/>")),
            ("a shape in an element the renderer does not know", ringClosed(by: "<frob>\(rect) mask='url(#a)'/></frob>\(rect)/>")),
            ("a shape in a symbol nothing uses", ringClosed(by: "<symbol>\(rect) mask='url(#a)'/></symbol>\(rect)/>")),
            ("a span of text", ringClosed(by: "<text x='1' y='5' font-family='Arial' font-size='4' fill='white'>x<tspan mask='url(#a)'>y</tspan></text>\(rect)/>")),
        ]
        for (name, body) in ignored { XCTAssertNotNil(source(body), name) }
    }

    // MARK: Fallback

    func testARefusedDrawingShowsItsFallbackTextWithADisclosure() throws {
        let refused: [(String, String)] = [
            ("three masks in a ring", linked("mask", count: 3)),
            ("three clip paths in a ring, by a stylesheet", linked("clipPath", count: 3, .sheet)),
            ("a gradient walk into a loop", gradients(ring: 2, tail: 1)),
            ("a chain of 128 masks", linked("mask", count: 128, ring: false)),
            ("a gradient of no length that repeats", gradient("spreadMethod='repeat'")),
            ("a gradient that reflects through another", gradient("href='#b'", after: "<radialGradient id='b' spreadMethod='reflect'/>")),
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

    // MARK: Ordinary drawings

    func testOrdinaryDrawingsThatShareMasksClipPathsAndMarkersStillDraw() throws {
        // Clip paths assigned by class, as an illustration program writes them, each with content of a class of its own.
        let classes = (1...4).map { ".c\($0){clip-path:url(#clip\($0));}" }.joined() + ".shape{fill:none;}.ink{fill:#231f20;}"
        let clips = (1...4).map { "<clipPath id='clip\($0)'><rect class='shape' x='\($0)' width='5' height='5'/></clipPath><g class='c\($0)'><rect class='ink' width='9' height='9'/></g>" }.joined()
        XCTAssertNotNil(source("<defs><style>\(classes)</style></defs>" + clips))
        // Clip paths that draw a shared shape with `use`, and groups clipped inside groups that are clipped.
        let shared = (1...4).map { "<clipPath id='u\($0)'><use xlink:href='#frame' style='overflow:visible;'/></clipPath>" }.joined()
        XCTAssertNotNil(source("<defs><rect id='frame' width='8' height='8'/>\(shared)</defs><g clip-path='url(#u1)'><g clip-path='url(#u2)'><g clip-path='url(#u3)'><rect clip-path='url(#u4)' width='9' height='9'/></g></g></g>"))
        // Definitions inside the groups they clip.
        XCTAssertNotNil(source("<g clip-path='url(#a)'><g clip-path='url(#b)'><g clip-path='url(#c)'><defs><clipPath id='a'><rect width='9' height='9'/></clipPath><clipPath id='b'><rect width='8' height='8'/></clipPath><clipPath id='c'><rect width='7' height='7'/></clipPath></defs><rect width='9' height='9'/></g></g></g>"))
        // One mask on many shapes, and a mask whose content is itself masked and clipped.
        let masked = (0..<40).map { "<rect x='\($0 % 8)' y='\($0 / 8)' width='1' height='1' mask='url(#m)'/>" }.joined()
        XCTAssertNotNil(source("<mask id='m'><rect \(Self.box) mask='url(#inner)' clip-path='url(#edge)'/></mask><mask id='inner'><circle r='4' fill='white'/></mask><clipPath id='edge'><rect width='4' height='4'/></clipPath>" + masked))
        // Arrowheads on every path of a graph, by attribute and by style.
        let edges = (0..<12).map { "<path d='M0 \($0) L9 \($0)' stroke='black' \($0 % 2 == 0 ? "marker-end='url(#arrow)'" : "style='marker-start:url(#dot);marker-end:url(#arrow)'")/>" }.joined()
        let arrows = "<defs><marker id='arrow' orient='auto'><path d='M0 0 L2 1 L0 2 z'/></marker><marker id='dot'><circle r='1'/></marker></defs>"
        XCTAssertNotNil(source(arrows + edges))
        // A gradient that takes its stops from another, written with both spellings of the reference.
        XCTAssertNotNil(source("<linearGradient id='stops'><stop offset='0' stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient><linearGradient id='g' x2='0' y2='1' href='#stops' xlink:href='#stops'/><radialGradient id='r' xlink:href='#g'/><rect width='5' height='5' fill='url(#g)' stroke='url(#r)'/>"))
    }

    // MARK: The screen's own cost

    func testChainsAndLoopsAsLongAsTheNodeLimitAllowsAreFollowedToTheirVerdict() throws {
        // The screen walks these without calling itself: a chain here is thousands of levels deep.
        XCTAssertFalse(try passes(linked("mask", count: 4_900, ring: false)), "4,900 masks in a chain")
        XCTAssertFalse(try passes(linked("clipPath", count: 2_000, .sheet)), "2,000 clip paths in a ring, by 2,000 rules")
        XCTAssertFalse(try passes(linkedThroughAMarker("clipPath", count: 4_900)), "4,900 clip paths in a ring behind a marker")
        XCTAssertFalse(try passes(gradients(ring: 4_900, tail: 4_900)), "4,900 gradients leading into a loop of 4,900")
        XCTAssertNotNil(source(gradients(ring: 9_900, tail: 0)), "9,900 gradients in a loop of their own draw")
        // A spread is looked for along every walk at once: each gradient here leads to the one that repeats.
        let chain = (0..<4_900).map { "<linearGradient id='g\($0)' href='#g\($0 + 1)'/>" }.joined() + "<radialGradient id='g4900' spreadMethod='repeat'/>"
        XCTAssertFalse(try passes(chain + "<rect width='5' height='5' fill='url(#g0)'/>"), "4,900 gradients that lead to one that repeats")
        let loop = (0..<4_900).map { "<linearGradient id='r\($0)' href='#r\(($0 + 1) % 4_900)'\($0 == 2_450 ? " spreadMethod='reflect'" : "")/>" }.joined()
        XCTAssertFalse(try passes(loop + "<rect width='5' height='5' fill='url(#r0)'/>"), "a loop of 4,900 gradients, one of which reflects")
    }
}
