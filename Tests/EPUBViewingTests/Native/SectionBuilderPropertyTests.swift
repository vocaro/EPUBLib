import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing

/// Random documents over the markup the builder treats specially, checked against the text-map
/// and anchor contracts.
final class SectionBuilderPropertyTests: XCTestCase {
    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        mutating func pick<T>(_ values: [T]) -> T { values[next(values.count)] }
    }

    private static let words = ["alpha", "beta", "γάμμα", "דלת", "漢字", "かな", "x", "ß", "naïve", "e\u{301}", "😀", "1984"]
    private static let spaces = [" ", "  ", "\n", " \t ", "\n  ", "", "\u{00A0}"]
    private static let inline = ["em", "b", "span", "a", "q", "small", "sup", "sub", "code", "bdi"]
    private static let blocks = ["p", "div", "blockquote", "section", "pre", "li-list", "aside-note", "hidden", "dl"]

    private func content(_ generator: inout Generator, depth: Int, id: inout Int) -> String {
        var html = ""
        for _ in 0..<(1 + generator.next(4)) {
            id += 1
            switch generator.next(depth > 3 ? 3 : 10) {
            case 0, 1: html += generator.pick(Self.spaces) + generator.pick(Self.words) + generator.pick(Self.spaces)
            case 2: html += "<br/>"
            case 3, 4, 5:
                let tag = generator.pick(Self.inline)
                let attributes = tag == "a" ? " href='#e\(generator.next(max(id, 1)))'" : (generator.next(4) == 0 ? " dir='rtl'" : "")
                html += "<\(tag) id='e\(id)'\(attributes)>" + content(&generator, depth: depth + 1, id: &id) + "</\(tag)>"
            case 6: html += "<ruby id='e\(id)'>\(generator.pick(Self.words))<rp>(</rp><rt>\(generator.pick(Self.words))</rt><rp>)</rp></ruby>"
            case 7: html += "<img id='e\(id)' src='picture.png' alt=''/>"
            default:
                switch generator.pick(Self.blocks) {
                case "li-list":
                    html += "<ol id='e\(id)'>" + (0..<(1 + generator.next(3))).map { _ in
                        "<li>" + content(&generator, depth: depth + 1, id: &id) + "</li>"
                    }.joined() + "</ol>"
                case "aside-note": html += "<aside epub:type='footnote' id='e\(id)'><p>" + content(&generator, depth: depth + 1, id: &id) + "</p></aside>"
                case "hidden": html += "<div hidden='' id='e\(id)'>" + content(&generator, depth: depth + 1, id: &id) + "</div>"
                case "dl": html += "<dl id='e\(id)'><dt>\(generator.pick(Self.words))</dt><dd>" + content(&generator, depth: depth + 1, id: &id) + "</dd></dl>"
                case let tag: html += "<\(tag) id='e\(id)'>" + content(&generator, depth: depth + 1, id: &id) + "</\(tag)>"
                }
            }
        }
        return html
    }

    func testRandomDocumentsKeepTheMapAndAnchorContracts() throws {
        var generator = Generator(state: 0x5EC7_10)
        for round in 0..<150 {
            var id = 0
            let body = content(&generator, depth: 0, id: &id)
            let document = try BuilderHarness.document(body)
            let text = BuilderHarness.build(document: document, rich: BuilderRecordingRich(), rules: [
                ("pre", { $0.whiteSpace = .pre }), ("code", { $0.whiteSpace = generator.next(2) == 0 ? .preWrap : .preLine }),
            ])
            BuilderHarness.assertMapRoundTrips(text)
            XCTAssertFalse(text.string.string.hasSuffix("\n"), "round \(round): trailing paragraph break")
            // Anchors: every id, in document order, at non-decreasing locations within the text.
            var previous = 0
            for node in document.nodes where node.isElement {
                guard let id = node.id, document.element(id: id) === node else { continue }
                guard let anchor = text.anchors[id] else { XCTFail("round \(round): no anchor for \(id)"); continue }
                XCTAssertGreaterThanOrEqual(anchor, previous, "round \(round): anchor \(id) moves backwards in \(body)")
                XCTAssertLessThanOrEqual(anchor, text.string.length)
                previous = anchor
            }
            // A mapped position's element anchor never lies after the position's character.
            for span in text.map.spans {
                var ancestor = document.nodes[span.node].parent
                while let element = ancestor {
                    if let id = element.id, let anchor = text.anchors[id] {
                        XCTAssertLessThanOrEqual(anchor, span.location, "round \(round): \(id) anchors after its content")
                    }
                    ancestor = element.parent
                }
            }
        }
    }
}
