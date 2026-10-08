import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing

final class EPUBCFITests: XCTestCase {
    /// html: head /2, body /4. body: p#first /2, p /4 (two adjacent images), div /6 (empty).
    /// p#first: "One " /1, em /2 ("two" /1), " three" /3.
    private let document: ContentDocument = {
        let markup = #"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body>"#
            + #"<p id="first">One <em>two</em> three</p><p><img src="a.png"/><img src="b.png"/></p><div/></body></html>"#
        do { return try ContentDocument.parse(Data(markup.utf8), path: "cfi.xhtml") }
        catch { fatalError("\(error)") }
    }()

    private func node(_ text: String) -> ContentNode { document.nodes.first { $0.isText && $0.text == text }! }
    private func element(_ name: String, _ index: Int = 0) -> ContentNode {
        document.nodes.filter { $0.isElement && $0.name == name }[index]
    }
    private func resolve(_ cfi: String) -> [DOMPosition]? {
        EPUBCFI.resolve(localPath: cfi, in: document).map { [$0.start, $0.end] }
    }
    private func at(_ node: ContentNode, _ offset: Int = 0) -> [DOMPosition] {
        [DOMPosition(node, offset), DOMPosition(node, offset)]
    }

    func testStepsResolveToTextOffsetsAndElementStarts() {
        XCTAssertEqual(resolve("/4/2/1:2"), at(node("One "), 2))
        XCTAssertEqual(resolve("epubcfi(/4/2/2/1:1)"), at(node("two"), 1))
        XCTAssertEqual(resolve("/4/2/1"), at(node("One ")), "a chunk without an offset is its start")
        XCTAssertEqual(resolve("/4/2[first]"), at(element("p")))
        XCTAssertEqual(resolve("/4/99[first]"), at(element("p")), "an ID that exists wins over the indices")
        XCTAssertEqual(resolve("/4/2[gone]/1:1"), at(node("One "), 1), "an ID that does not exist is ignored")
        XCTAssertEqual(resolve("/4/2:3"), at(element("p")), "offsets on elements are ignored")
        XCTAssertEqual(resolve("/4/2,/1:1,/3:2"), [DOMPosition(node("One "), 1), DOMPosition(node(" three"), 2)])
    }

    func testStaleOffsetsAreClampedToTheirNode() {
        XCTAssertEqual(resolve("/4/2/1:99"), at(node("One "), 4))
        XCTAssertEqual(resolve("/4/2,/1:2,/3:99"), [DOMPosition(node("One "), 2), DOMPosition(node(" three"), 6)])
    }

    func testVirtualIndicesMapAsDocumented() {
        XCTAssertEqual(resolve("/4/0"), at(element("body")), "before: the indexed element's start")
        XCTAssertEqual(resolve("/4/2/2/2"), at(node(" three")), "after: the first node after the element")
        XCTAssertEqual(resolve("/4/8"), at(element("div")), "after the last subtree: the document's last node")
        XCTAssertEqual(resolve("/4/4/1"), at(element("img", 0)), "first: the first child element")
        XCTAssertEqual(resolve("/4/4/5"), at(element("img", 1)), "last: the last child element")
        XCTAssertEqual(resolve("/0/4/2"), at(element("html")), "a virtual index ends the walk")
        XCTAssertEqual(resolve("/5"), at(element("body")), "the root's last child")
    }

    func testPathsThatNameNothingResolveToNil() {
        for cfi in ["/4/4/3", "/4/4/7", "/4/6/1", "/4/6/0", "/4/2/1/1", "/4/2/1:2/3", "/4/99", "/3/1", "", "!", ",",
                    "/4/2,/1:0", "epubcfi()", "/4/a", ":3", "[x]"] {
            XCTAssertNil(resolve(cfi), cfi)
        }
        XCTAssertEqual(resolve("/4/6"), at(element("div")), "an element without children can still be named")
    }

    func testAReversedRangeCollapsesToItsEnd() {
        XCTAssertEqual(resolve("/4/2,/3:2,/1:1"), at(node("One "), 1))
    }

    func testPositionsBecomeLocalPaths() {
        func path(_ start: DOMPosition, _ end: DOMPosition? = nil) -> String {
            EPUBCFI.localPath(from: start, to: end ?? start, in: document)
        }
        XCTAssertEqual(path(DOMPosition(node("One "), 2)), "/4/2[first]/1:2")
        XCTAssertEqual(path(DOMPosition(element("p"))), "/4/2[first]")
        XCTAssertEqual(path(DOMPosition(element("img", 1))), "/4/4/4")
        XCTAssertEqual(path(DOMPosition(node("two"), 1), DOMPosition(node(" three"), 3)), "/4/2[first],/2/1:1,/3:3")
        XCTAssertEqual(path(DOMPosition(node(" three"), 3), DOMPosition(node("two"), 1)), "/4/2[first],/2/1:1,/3:3",
                       "reversed ends are swapped")
        XCTAssertEqual(path(DOMPosition(node("One "), 0), DOMPosition(node("One "), 4)), "/4/2[first],/1:0,/1:4")
        XCTAssertEqual(path(DOMPosition(node("One "), 99)), "/4/2[first]/1:4", "offsets are clamped")
        XCTAssertEqual(path(DOMPosition(element("html"))), "/2", "the root is its first child's start")
        XCTAssertEqual(EPUBCFI.localPath(from: DOMPosition(element("p")), to: DOMPosition(node(" three"), 1), in: document),
                       "/4/2[first],,/3:1")
    }

    func testEveryRangeRoundTrips() {
        var positions: [DOMPosition] = []
        for node in document.nodes.dropFirst() {
            positions += node.isText ? (0...node.utf16Length).map { DOMPosition(node, $0) } : [DOMPosition(node)]
        }
        for (index, start) in positions.enumerated() {
            for end in positions[index...] {
                let cfi = EPUBCFI.localPath(from: start, to: end, in: document)
                XCTAssertEqual(resolve(cfi), [start, end], cfi)
            }
        }
    }

    func testParsingAndPrintingFollowFoliate() throws {
        let cfi = "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10[yyy^,zz;s=b])"
        let expression = try EPUBCFI.parse(cfi)
        XCTAssertEqual(expression.path?.count, 2)
        XCTAssertEqual(expression.path?[1].last, .init(index: 3, offset: 10, text: ["yyy,zz"], side: "b"))
        XCTAssertEqual(EPUBCFI.string(expression), cfi)
        XCTAssertEqual(EPUBCFI.string(try EPUBCFI.parse("epubcfi(/6/4!/4/2:7)")), "epubcfi(/6/4!/4/2)",
                       "offsets print only on character steps")
        XCTAssertEqual(EPUBCFI.collapse("epubcfi(/6/4!/4/2,/1:0,/3:5)"), "epubcfi(/6/4!/4/2/1:0)")
        XCTAssertEqual(EPUBCFI.collapse("epubcfi(/6/4!/4/2,/1:0,/3:5)", toEnd: true), "epubcfi(/6/4!/4/2/3:5)")
        XCTAssertEqual(EPUBCFI.joinIndirections("epubcfi(/6/4)", "epubcfi(/4/2/1:3)"), "epubcfi(/6/4!/4/2/1:3)")
        XCTAssertTrue(EPUBCFI.isCFI("epubcfi(/6/4)"))
        XCTAssertFalse(EPUBCFI.isCFI("epubcfi(/6/4\n)"))
    }

    func testComparisonOrdersCFIsInReadingOrder() {
        let ordered = ["x", "epubcfi(/6/2)", "epubcfi(/6/4!/4/2)", "epubcfi(/6/4!/4/2/1:0)", "epubcfi(/6/4!/4/2/1:3)",
                       "epubcfi(/6/4!/4/2,/1:3,/1:9)", "epubcfi(/6/4!/4/2/3:0)", "epubcfi(/6/4!/4/10)", "epubcfi(/6/6!/4/2)"]
        for (i, a) in ordered.enumerated() {
            for (j, b) in ordered.enumerated() {
                XCTAssertEqual(EPUBCFI.compare(a, b), i < j ? -1 : i > j ? 1 : 0, "\(a) \(b)")
            }
        }
        XCTAssertEqual(EPUBCFI.compare("epubcfi(/6/4!/4/2/1:3)", "epubcfi(/6/4!/4/2,/1:3,/1:4)"), -1,
                       "a range after a position at its start, ordered by its end")
    }

    func testJavaScriptNumberFormatting() {
        for (value, string) in [(0.5, "0.5"), (100, "100"), (1e21, "1e+21"), (1e20, "100000000000000000000"),
                                (1e-7, "1e-7"), (0.000001, "0.000001"), (-2.5, "-2.5"), (Double("123456789012345678901234")!, "1.2345678901234569e+23"),
                                (0.1 + 0.2, "0.30000000000000004"), (.nan, "NaN"), (.infinity, "Infinity"), (5e-324, "5e-324")] {
            XCTAssertEqual(EPUBCFI.jsNumber(value), string)
        }
    }

    func testWellFormednessKeepsTheBridgesCharacterRules() {
        for cfi in ["epubcfi(/6/4!/4/10/2:3)", "epubcfi(/6/14[note^(2^)]!/4/2/10)", "epubcfi(/6/4!/4/2/1:5[;s=a])",
                    "epubcfi(/6/14[a^[b^]c^,d^;e^=f]!/4/2/10)", "epubcfi(/6/14[第二章]!/4/2/10)", "epubcfi(/6/14[a\"b]!/4/2/10)",
                    "epubcfi(" + String(repeating: "/2", count: 2_043) + ")"] {
            XCTAssertTrue(EPUBCFI.isWellFormed(cfi), cfi)
        }
        for cfi in ["", "/6/4!/4/10/2:3", "epubcfi()", "epubcfi(/6/4", "epubcfi(/6/4))", "epubcfi(/6/4)(x)", "epubcfi(/6/4)^)",
                    "epubcfi(/6/4\n)", "epubcfi(/6/4\u{2028})", "epubcfi(/6/4\u{0085})", "epubcfi(/6/4\u{0000})", "epubcfi(/6/4^)",
                    "epubcfi(/6/4^(()", "epubcfi(/6/4!/4);alert(1)//)", "epubcfi(" + String(repeating: "/2", count: 2_044) + ")",
                    "epubcfi(" + String(repeating: "^a", count: EPUBCFI.maximumLength) + ")"] {
            XCTAssertFalse(EPUBCFI.isWellFormed(cfi), cfi.debugDescription)
        }
    }

    /// Random strings over the CFI alphabet: parsing, printing, comparing and resolving must
    /// never trap, and whatever parses must print to something that parses the same way (unless
    /// it prints a NaN spatial or temporal offset, which foliate did not read back either).
    func testMalformedInputNeverCrashes() throws {
        let alphabet = Array("/:!,[]^;=~@.()0123456789 sab\u{301}\n")
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let spine = SpineCFIs(package: nil, spineCount: 3)
        for _ in 0..<5_000 {
            let body = String((0..<next(40)).map { _ in alphabet[next(alphabet.count)] })
            let cfi = next(2) == 0 ? "epubcfi(\(body))" : body
            _ = EPUBCFI.compare(cfi, "epubcfi(/6/4!/4/2/1:3)")
            _ = EPUBCFI.collapse(cfi, toEnd: next(2) == 0)
            _ = EPUBCFI.resolve(localPath: cfi, in: document)
            _ = spine.resolve(cfi)
            _ = EPUBCFI.isWellFormed(cfi)
            if let parsed = try? EPUBCFI.parse(cfi), !EPUBCFI.string(parsed).contains("NaN") {
                let printed = EPUBCFI.string(parsed)
                XCTAssertEqual(EPUBCFI.string(try EPUBCFI.parse(printed)), printed, cfi.debugDescription)
            }
        }
    }

    func testLongAndDeepCFIsStayWithinBounds() throws {
        XCTAssertThrowsError(try EPUBCFI.parse("epubcfi(" + String(repeating: "/2", count: 40_000) + ")"))
        let deep = "epubcfi(/4/3" + String(repeating: "/2", count: 30_000) + "/1:0)"
        let clock = ContinuousClock()
        let elapsed = clock.measure { XCTAssertNil(EPUBCFI.resolve(localPath: deep, in: document)) }
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertThrowsError(try EPUBCFI.parse("epubcfi(/6/99999999999999999999)"))
        XCTAssertEqual(resolve("/4/2/1:99999999999999"), at(node("One "), 4))
        XCTAssertEqual(resolve("/4/2/1:9007199254740992"), at(node("One "), 4))

        let depth = 190
        let markup = #"<html xmlns="http://www.w3.org/1999/xhtml"><body>"# + String(repeating: "<div>", count: depth) + "leaf"
            + String(repeating: "</div>", count: depth) + "</body></html>"
        let nested = try ContentDocument.parse(Data(markup.utf8), path: "deep.xhtml")
        let leaf = try XCTUnwrap(nested.nodes.last)
        let path = EPUBCFI.localPath(from: DOMPosition(leaf, 2), to: DOMPosition(leaf, 2), in: nested)
        XCTAssertEqual(path, "/2" + String(repeating: "/2", count: depth) + "/1:2")
        XCTAssertEqual(EPUBCFI.resolve(localPath: path, in: nested)?.start, DOMPosition(leaf, 2))
    }
}
