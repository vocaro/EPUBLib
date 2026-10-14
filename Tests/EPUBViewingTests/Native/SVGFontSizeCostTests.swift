import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// Relative lengths resolve each entry against every ancestor's font-size. Refused inputs are
/// screened only; capped renderer characterization lives in svg-font-size-probe.py (#443).
final class SVGFontSizeCostTests: XCTestCase {
    private let head = "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' width='200' height='100'>"
    private let path = "<path d='M0 0h50' stroke='black' stroke-dasharray='1em 1ex'/>"

    private func root(_ body: String) throws -> ContentNode {
        try ContentDocument.parse(Data((head + body + "</svg>").utf8), path: "svg", asContent: false).root
    }

    private func accepts(_ body: String) throws -> Bool {
        SVGContent.isWithinRenderingLimits(try root(body))
    }

    func testOriginalPaddedDashReproducerAndPassingNeighbour() throws {
        let dash = Array(repeating: "1em", count: 20_000).joined(separator: " ")
        let tail = "'><path d='M0 0h50' stroke='black' stroke-dasharray='\(dash)'/></g>"
        let plain = "<g font-size='12" + tail
        let padded = "<g font-size='" + String(repeating: " ", count: 100_000) + "12" + tail
        XCTAssertEqual((head + plain + "</svg>").utf8.count, 80_189)
        XCTAssertEqual((head + padded + "</svg>").utf8.count, 180_189)
        XCTAssertTrue(try accepts(plain))
        XCTAssertFalse(try accepts(padded))
        XCTAssertFalse(SVGContent.copyVerdict(try root(padded)).withinLimits)
    }

    func testFontSizeBoundaryCoversEveryRelativeLengthConsumer() throws {
        XCTAssertEqual(SVGContent.maximumFontSizeValueBytes, 64)
        let consumers = [path,
            "<path d='M0 0h50' stroke='black' stroke-width='1em' stroke-dashoffset='1ex'/>",
            "<text x='1em 2ex' y='1ex 2em' dx='1em 2ex' dy='1ex 2em'>ab</text>",
            "<text letter-spacing='1em' word-spacing='1ex'><tspan baseline-shift='1em'>a b</tspan></text>",
            "<rect x='1em' y='1ex' width='2em' height='2ex'/>"]
        for consumer in consumers {
            XCTAssertTrue(try accepts("<g font-size='\(String(repeating: " ", count: 62))12'>\(consumer)</g>"), consumer)
            XCTAssertFalse(try accepts("<g font-size='\(String(repeating: " ", count: 63))12'>\(consumer)</g>"), consumer)
        }
    }

    func testCSSFontSizeAndFontShorthandCannotBypassTheCap() throws {
        let size = "12." + String(repeating: "0", count: 61) // 64 bytes, a valid ordinary unitless size.
        for declaration in ["font-size:\(size)", "font:italic 500 \(size) serif"] {
            XCTAssertTrue(try accepts("<g style='\(declaration)'>\(path)</g>"), declaration)
            XCTAssertTrue(try accepts("<style>g{\(declaration)}</style><g>\(path)</g>"), declaration)
        }
        for declaration in ["font-size:\(size)0", "font:italic 500 \(size)0 serif"] {
            XCTAssertFalse(try accepts("<g style='\(declaration)'>\(path)</g>"), declaration)
            XCTAssertFalse(try accepts("<style>g{\(declaration)}</style><g>\(path)</g>"), declaration)
        }
        XCTAssertTrue(try accepts("<g style='font-size:\(size) !important'>\(path)</g>"))
        let padded = String(repeating: " ", count: 100_000) + "12" + String(repeating: " ", count: 100_000)
        XCTAssertTrue(try accepts("<g style='font-size:\(padded)'>\(path)</g>"), "simplecss trims padding before storing the value")
        XCTAssertTrue(try accepts("<style>g{font-size:\(padded)}</style><g>\(path)</g>"))
        let family = String(repeating: "Long Family Name ", count: 100)
        XCTAssertTrue(try accepts("<g style='font:italic 12px/14px &quot;\(family)&quot;, serif'>\(path)</g>"), "the family has its own copy bound")
    }

    func testRendererPropertyNameSyntaxCannotBypassFontSizeCap() throws {
        let size = "12." + String(repeating: "0", count: 100_000)
        let ordinary = "12." + String(repeating: "0", count: 61)
        for (property, value, neighbour) in [("font-size", size, ordinary),
                                           ("font", "italic 500 " + size + " serif", "italic 500 " + ordinary + " serif")] {
            for spelling in [property, property.uppercased(), property.prefix(1).uppercased() + property.dropFirst()] {
                for name in [spelling, "*" + spelling, spelling + "/**/", "*" + spelling + "/**/",
                             spelling + " /*:;{}*/ /**/ ", "*" + spelling + " /*:;{}*/ /**/ "] {
                    for prefix in ["", "/**/", " /*leading*/ /*second*/ "] {
                        let declaration = name + ":" + prefix + value
                        XCTAssertFalse(try accepts("<g style='\(declaration)'>\(path)</g>"), declaration.prefix(80).description)
                        XCTAssertFalse(try accepts("<style>g{\(declaration)}</style><g>\(path)</g>"), declaration.prefix(80).description)
                        let plain = name + ":" + prefix + neighbour
                        XCTAssertTrue(try accepts("<g style='\(plain)'>\(path)</g>"), plain)
                        XCTAssertTrue(try accepts("<style>g{\(plain)}</style><g>\(path)</g>"), plain)
                    }
                }
            }
        }
        let comment = "/*" + String(repeating: "x", count: 100_000) + "*/"
        XCTAssertTrue(try accepts("<g style='font-size\(comment):\(comment)12'>\(path)</g>"),
                      "comments before the colon and first value term are skipped by simplecss")
        XCTAssertTrue(try accepts("<style>g{font\(comment):\(comment)12 serif}</style><g>\(path)</g>"))
    }

    func testDefinitionsMarkersAndTextSpansAreScreened() throws {
        let value = String(repeating: " ", count: 100_000) + "12"
        for body in ["<defs><g font-size='\(value)'>\(path)</g></defs>\(path)",
                     "<defs><marker id='m'><path d='M0 0h1' style='font-size:12.\(String(repeating: "0", count: 100))'/></marker></defs><path d='M0 0h50' marker-end='url(#m)'/>",
                     "<text><tspan font-size='\(value)' x='1em'>a</tspan></text>",
                     "<defs><path id='p' d='M0 0h50'/></defs><use href='#p' font-size='\(value)'/>"] {
            XCTAssertFalse(try accepts(body))
        }
        XCTAssertTrue(try accepts("<style>@font-face{font-size:\(value)}</style>\(path)"), "at-rules never set an ancestor font-size")
        XCTAssertTrue(try accepts("<style>@import 'outside.css';g{font-size:12.\(String(repeating: "0", count: 100))}</style><g>\(path)</g>"), "serialization drops this sheet")
    }

    func testPassingFontSizeAtByteDepthAndNodeLimits() throws {
        let size = String(repeating: " ", count: 62) + "12"
        for unit in ["em", "ex"] {
            for levels in [1, 62] {
                let prefix = String(repeating: "<g font-size='\(size)'>", count: levels)
                    + "<path d='M0 0h50' stroke='black' stroke-dasharray='"
                let suffix = "'/>" + String(repeating: "</g>", count: levels)
                let overhead = (head + prefix + suffix + "</svg>").utf8.count
                let count = (SVGContent.maximumBytes - overhead + 1) / 4
                let drawing = prefix + Array(repeating: "1" + unit, count: count).joined(separator: " ") + suffix
                XCTAssertLessThanOrEqual((head + drawing + "</svg>").utf8.count, SVGContent.maximumBytes)
                XCTAssertTrue(try accepts(drawing), "maximal \(unit) dash at depth \(levels)")
            }
            for attribute in ["x", "y", "dx", "dy"] {
                let prefix = "<g font-size='\(size)'><text \(attribute)='"
                let suffix = "'>a</text></g>"
                let overhead = (head + prefix + suffix + "</svg>").utf8.count
                let count = (SVGContent.maximumBytes - overhead + 1) / 4
                let drawing = prefix + Array(repeating: "1" + unit, count: count).joined(separator: " ") + suffix
                XCTAssertTrue(try accepts(drawing), "maximal \(unit) position list: \(attribute)")
            }
        }
        for property in ["stroke-width", "stroke-dashoffset"] {
            let shape = "<path d='M0 0h50' stroke='black' \(property)='1em'/>"
            XCTAssertTrue(try accepts("<g font-size='\(size)'>" + String(repeating: shape, count: 9_998) + "</g>"))
        }
    }

    /// The same generated inputs used by the capped C probe are screened by the current Swift
    /// implementation. The resulting JSON is consumed with --screen-json; an expected verdict
    /// in the fixture manifest alone never authorizes the probe to render a drawing.
    func testGeneratedProbeFixturesMatchScreen() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifest = environment["EPUBLIB_SVG_FONT_SIZE_PROBE_MANIFEST"] else {
            throw XCTSkip("Set EPUBLIB_SVG_FONT_SIZE_PROBE_MANIFEST to opt into the generated probe screen")
        }
        let manifestURL = URL(fileURLWithPath: manifest)
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [[String: Any]])
        var results: [[String: Any]] = []
        for entry in entries {
            let name = try XCTUnwrap(entry["name"] as? String)
            let path = try XCTUnwrap(entry["file"] as? String)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, try XCTUnwrap(entry["sha256"] as? String), name)
            let document = try ContentDocument.parse(data, path: path,
                limits: .init(bytes: SVGContent.maximumBytes, depth: SVGContent.maximumDepth, nodes: SVGContent.maximumNodes), asContent: false)
            let accepted = SVGContent.isWithinRenderingLimits(document.root)
            let copy = SVGContent.copyVerdict(document.root)
            XCTAssertEqual(accepted, try XCTUnwrap(entry["expectedScreenAccepted"] as? Bool), name)
            results.append(["name": name, "inputBytes": data.count,
                "sha256": digest, "screenAccepted": accepted,
                "copies": copy.copies, "steps": copy.steps])
        }
        let destination = environment["EPUBLIB_SVG_FONT_SIZE_PROBE_VERDICTS"].map { URL(fileURLWithPath: $0) }
            ?? manifestURL.deletingLastPathComponent().appendingPathComponent("screen-verdicts.json")
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
    }

    func testPaddedFontSizeUsesFallbackAndDisclosure() throws {
        let drawing = head + "<g font-size='\(String(repeating: " ", count: 100_000))12'>\(path)</g></svg>"
        let text = try RichMediaBook(body: "<p><img src='drawing.svg' alt='Chart'/></p>", files: ["drawing.svg": Data(drawing.utf8)]).build()
        XCTAssertTrue(text.richMediaImages.isEmpty)
        XCTAssertEqual(text.richMediaPlain, "Chart")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }
}
