import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The box plan puts a section's lines where the section's layout puts them (#377).
///
/// The plan measures a planned section one paragraph at a time; the paginator, its display
/// measurement and every page view lay the section out with the plan's geometry. A page's
/// origin comes from the layout and its boxes and planned paragraphs from the plan, so where
/// the two disagree about a paragraph, everything below it is out by the difference: a page
/// that opens below it is pushed down past its clip and shows nothing, and a box's exclusion
/// meets lines it is nowhere near. They disagreed where the plan measured a paragraph
/// otherwise than the layout lays it out: above the section's first box on TextKit's
/// rectangular path, which places indented tabs, markers and attachments otherwise than the
/// box-aware path every planned layout takes; and alone, as a document's first and last
/// paragraph, without the spacing TextKit gives a paragraph only between others.
@MainActor final class BoxPlanAgreementTests: XCTestCase {
    private typealias H = BoxLayoutHarness

    /// How far apart the plan and the section's layout put the same lines: for each planned line,
    /// the distance between its top and the top of the laid-out line that starts at the same
    /// character. Nil when the section has no plan.
    static func disagreement(_ section: SectionText, viewport: CGSize) -> (worst: CGFloat, compared: Int, at: String)? {
        let resolved = ReaderBoxLayout.resolve(section.string, viewport: viewport)
        guard let plan = resolved.geometry else { return nil }
        let view = H.view(resolved.text, size: viewport)
        var laidOut: [Int: CGFloat] = [:]
        view.readerLayoutManager.enumerateTextLayoutFragments(from: view.contentStorage.documentRange.location,
                                                               options: [.ensuresLayout]) { fragment in
            let start = view.offset(of: fragment.rangeInElement.location)
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                laidOut[start + line.characterRange.location] = fragment.layoutFragmentFrame.origin.y + line.typographicBounds.minY
            }
            return true
        }
        var worst: CGFloat = 0, compared = 0, at = ""
        for paragraph in plan.paragraphs {
            for line in paragraph.lines {
                guard let top = laidOut[line.range.location] else { continue }
                compared += 1
                let distance = abs(top - line.frame.minY)
                if distance > worst { worst = distance; at = "\(line.range): planned \(line.frame.minY), laid out \(top)" }
            }
        }
        return (worst, compared, at)
    }

    private func assertAgreement(_ section: SectionText, viewport: CGSize, _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let measured = Self.disagreement(section, viewport: viewport) else {
            return XCTFail("\(label) has a box plan", file: file, line: line)
        }
        XCTAssertGreaterThan(measured.compared, 0, label, file: file, line: line)
        XCTAssertLessThan(measured.worst, 0.75, "The plan puts every line where the layout does: \(label) \(measured.at)", file: file, line: line)
    }

    private static let float = "<div style='float:left; width:28px'>F</div>"
        + "<p>Ordinary prose wraps beside the box and returns to the full column below it.</p>"
    /// A paragraph that TextKit's rectangular path lays out in more lines than the box-aware path
    /// does at 60 × 90 points and 9 points: its tabs count from the margin there, from the
    /// line's start here.
    private static let tabbed = "<p dir='rtl' style='margin-left:30px; white-space:pre-wrap'>"
        + "a&#9;returns a. trail&#9; Second.&#9;Two&#9;a column again prose.</p>"
    private static let small = CGSize(width: 60, height: 90)

    /// Paragraphs above the first box that the plan measured otherwise than the layout lays them out.
    func testParagraphsAboveTheFirstBoxArePlannedWhereTheyAreLaidOut() throws {
        let medium = CGSize(width: 200, height: 300)
        let cases: [(name: String, body: String, size: CGSize, font: CGFloat)] = [
            // On TextKit's rectangular path a tab in an indented paragraph counts from the
            // margin, on the container's from the line's start: the lines break elsewhere.
            ("indented pre", "<pre style='margin-left:30px'>a&#9;b&#9;c</pre>", Self.small, 9),
            ("right-to-left indented pre", "<pre dir='rtl' style='margin-left:30px'>a&#9;b&#9;c</pre>", Self.small, 9),
            ("right-to-left tabbed paragraph", Self.tabbed, Self.small, 9),
            ("tabbed paragraph", "<p style='margin-left:30px; white-space:pre-wrap'>a&#9;returns a. trail&#9; Second.&#9;Two&#9;a column again prose.</p>",
             Self.small, 9),
            // A table that falls back to tabbed rows, in a right-to-left table with a margin.
            ("tabbed table row", "<table dir='rtl' style='margin-left:30px'><tbody><tbody><tr><td>returns a.</td><td>Second.</td><td>Two</td></tr></tbody></tbody></table>",
             Self.small, 9),
            // The space above a caption set under its table is spacing before its paragraph,
            // which TextKit does not lay out before a document's first paragraph.
            ("caption under its table", "<table><caption style='caption-side:bottom'>Caption under the table.</caption><tr><td>One</td><td>Two</td></tr></table>",
             medium, 16),
            // An empty paragraph measured alone has an empty last line besides its own, and no
            // spacing after it.
            ("empty paragraph with a margin", "<p>Before.</p><p style='margin:0 0 23px'><br/></p>", medium, 16),
        ]
        for entry in cases {
            let section = try H.build(entry.body + Self.float, css: "", fontSize: entry.font)
            assertAgreement(section, viewport: entry.size, entry.name)
        }
    }

    /// The reduced form of #377's section: six such paragraphs, then a forced break, a float and
    /// prose. The page after the break opened as far below its top as the plan had the six
    /// paragraphs taller than the layout, 98.55 points on a 90-point page, and drew nothing.
    func testAPageOpeningBelowIndentedTabsShowsItsLines() throws {
        let body = String(repeating: Self.tabbed, count: 6) + "<p style='page-break-before:always'>After the break.</p>" + Self.float
        let section = try H.build(body, css: "", fontSize: 9)
        assertAgreement(section, viewport: Self.small, "six tabbed paragraphs")
        let paginator = ReaderPaginator(text: section.string, size: Self.small)
        let pages = paginator.allPages
        XCTAssertFalse(pages.contains(where: \.usesFlowFallback), "No page needs its boxes dropped to show its text")
        let breakAt = H.range("After the break.", in: section).location
        let page = try XCTUnwrap(pages.first { $0.range.location == breakAt })
        let lines = H.lines(in: H.pageView(paginator, page: page))
        let first = try XCTUnwrap(lines.first, "The page after the break draws its line")
        XCTAssertEqual(first.frame.minY, 0, accuracy: 0.75, "It opens at its top")
        PageTextGeometryTests.assertVisiblePages(section, size: Self.small, label: "six tabbed paragraphs")
    }

    // MARK: Generated sections

    /// Sections whose blocks lay out differently on TextKit's rectangular path and the box-aware
    /// one (indents with tabs, tabbed table rows, tables with margins, right-to-left text, drop
    /// caps and list markers) or alone and in their text (captions under their tables, empty
    /// paragraphs with margins), above, between and below floats and positioned boxes.
    static func generate(_ random: inout SectionContentRandom) -> String {
        let words = ["Ordinary", "prose", "wraps", "beside", "the", "box", "and", "returns", "to", "full", "column", "below", "it", "a"]
        let hebrew = ["\u{5E9}\u{5DC}\u{5D5}\u{5DD}", "\u{5E1}\u{5E4}\u{5E8}", "\u{5E7}\u{5D5}\u{5E8}\u{5D0}"]
        func prose(_ count: Int) -> String { (0..<max(1, count)).map { _ in random.pick(words) }.joined(separator: " ") + "." }
        func dir() -> String { random.chance(3) ? " dir='rtl'" : "" }
        func indent() -> String {
            random.pick(["margin-left:30px;", "margin-right:20%;", "margin:0 10px 0 40px;", "padding-left:3em;", "text-indent:2em;",
                         "text-indent:-1em; padding-left:1em;", ""])
        }
        func tabbed() -> String { "\(prose(1 + random.next(3)))&#9;\(prose(1 + random.next(4)))&#9;\(prose(1 + random.next(2)))" }
        func block() -> String {
            switch random.next(13) {
            case 11:
                return "<table\(dir())><caption style='caption-side:\(random.pick(["bottom", "top"]))'>Caption \(prose(1 + random.next(6)))</caption>"
                    + "<tr><td>\(prose(1 + random.next(4)))</td><td>\(prose(1 + random.next(3)))</td></tr></table>"
            case 12: return "<p style='margin:0 0 \(random.pick(["10px", "23px", "1em"]))'><br/></p>"
            case 0: return "<pre\(dir()) style='\(indent())'>\(tabbed())</pre>"
            case 1: return "<p\(dir()) style='white-space:\(random.pick(["pre-wrap", "break-spaces"])); \(indent())'>\(tabbed())</p>"
            case 2: return "<p\(dir()) style='\(indent())'>\(prose(4 + random.next(20))) <span style='white-space:pre'>a&#9;b</span> \(prose(3))</p>"
            case 3:
                let cells = (0..<(2 + random.next(2))).map { _ in "<td>\(prose(1 + random.next(5)))</td>" }.joined()
                return "<table\(dir()) style='\(random.pick(["margin-left:30px;", "margin-right:25%;", ""]))'><tbody><tbody><tr>\(cells)</tr></tbody></tbody></table>"
            case 4:
                let rows = (0..<(1 + random.next(3))).map { _ in "<tr><td>\(prose(1 + random.next(8)))</td><td>\(prose(1 + random.next(3)))</td></tr>" }.joined()
                return "<table\(dir()) style='\(random.pick(["margin-left:30px;", "margin-right:25%;", ""]))'>\(rows)</table>"
            case 5:
                let items = (0..<(1 + random.next(3))).map { _ in "<li>\(random.chance(2) ? tabbed() : prose(2 + random.next(8)))</li>" }.joined()
                return "<ul\(dir()) style='list-style-position:\(random.pick(["inside", "outside"])); \(indent())'>\(items)</ul>"
            case 6: return "<p><span style='float:left; font-size:3em'>D</span>rop \(prose(6 + random.next(20)))</p>"
            case 7: return "<p dir='rtl' style='\(indent())'>\((0..<(2 + random.next(8))).map { _ in random.pick(hebrew) }.joined(separator: " ")) \(prose(2))</p>"
            case 8:
                let side = random.pick(["left", "right"])
                return "<div style='float:\(side); width:\(random.pick(["28px", "40%", "4em"]))\(random.chance(3) ? "; height:30px" : "")'>F \(prose(1 + random.next(4)))</div>"
            case 9: return "<div style='position:absolute; \(random.pick(["left", "right"])):0; top:\(random.pick(["0", "40px", "20%"])); width:\(random.pick(["30px", "40%"]))'>A \(prose(2))</div>"
            default: return "<p style='\(indent())'>\(prose(4 + random.next(30)))</p>"
            }
        }
        // At least one block that differs by path comes before the first box.
        var body = (0..<(1 + random.next(3))).map { _ in block() }.joined()
        body += "<div style='float:\(random.pick(["left", "right"])); width:\(random.pick(["28px", "30%"]))'>F \(prose(2))</div>"
        body += (0..<(2 + random.next(6))).map { _ in block() }.joined()
        return body
    }

    static let viewports = [CGSize(width: 60, height: 90), CGSize(width: 180, height: 240), CGSize(width: 320, height: 480), CGSize(width: 400, height: 600)]
    static let fontSizes: [CGFloat] = [9, 12, 16, 21.7]

    func testGeneratedSectionsArePlannedWhereTheyAreLaidOutAndShowEveryCharacter() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["BOX_PLAN_SECTIONS"] ?? "") ?? 24
        let seed = UInt64(environment["BOX_PLAN_SEED"] ?? "") ?? 377
        var random = SectionContentRandom(state: seed)
        var planned = 0
        for index in 0..<count {
            let size = random.pick(Self.viewports), font = random.pick(Self.fontSizes)
            let body = Self.generate(&random)
            if let only = environment["BOX_PLAN_ONLY"], !only.split(separator: ",").contains(Substring(String(index))) { continue }
            let label = "seed \(seed) section \(index) at \(size) \(font) pt"
            if environment["BOX_PLAN_DIAGNOSTICS"] != nil { print("INPUT \(label) BODY \(body)") }
            let section = try H.build(body, css: "", fontSize: font)
            // A section whose boxes are all left in flow (each too tall for its page) has no plan.
            guard let measured = Self.disagreement(section, viewport: size) else { continue }
            planned += 1
            autoreleasepool {
                XCTAssertLessThan(measured.worst, 0.75, "The plan puts every line where the layout does: \(label) \(measured.at)")
                PageTextGeometryTests.assertVisiblePages(section, size: size, label: label)
            }
        }
        if environment["BOX_PLAN_ONLY"] == nil { XCTAssertGreaterThan(planned, count / 2, "Most generated sections have a box plan") }
    }
}
