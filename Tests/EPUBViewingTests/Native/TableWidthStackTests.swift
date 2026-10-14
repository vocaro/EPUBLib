import CoreGraphics
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class TableWidthStackTests: XCTestCase {
    func testMaximumWidthIncludesTheLastOfSixThousandLines() {
        let attributes: [NSAttributedString.Key: Any] = [.font: PlatformFont.systemFont(ofSize: 16)]
        let wide = String(repeating: "wide ", count: 40)
        let text = NSAttributedString(string: String(repeating: "a\n", count: 6_000) + wide, attributes: attributes)
        XCTAssertEqual(TableMeasure.maximumWidth(text), TableMeasure.maximumWidth(NSAttributedString(string: wide, attributes: attributes)))
    }

    func testPlainBlockWidthsMatchUnwrappedDrawing() throws {
        let table = try TableCoverage.table("<table><tr><td><p>One</p><p>Two</p><ul><li>item</li></ul><h3>Head</h3><pre>a  b</pre>x<br/>y</td><td>side</td></tr></table>")
        let content = table.cells[0].content
        let drawn = content.boundingRect(with: CGSize(width: 100_000, height: 0), options: [.usesLineFragmentOrigin], context: nil)
        XCTAssertEqual(TableMeasure.maximumWidth(content), ceil(drawn.width))
    }

    func testMaximumWidthVisitsEachAttachmentOnceAcrossParagraphs() {
        for count in [500, 1_000, 2_000, 4_000] {
            let attachment = CountedWidthAttachment()
            let text = NSMutableAttributedString()
            for _ in 0..<count {
                text.append(NSAttributedString(attachment: attachment, attributes: [.font: PlatformFont.systemFont(ofSize: 16)]))
                text.append(NSAttributedString(string: "\n"))
            }
            XCTAssertEqual(TableMeasure.maximumWidth(text), 37)
            XCTAssertEqual(attachment.measurements, count)
            XCTAssertEqual(attachment.layouts, 0, "Intrinsic measurement never renders the source attachment")
        }
    }

    func testNestedTablesBuildOnTheProductionStackWithReleaseMargin() throws {
        let reproductions = [
            "<table><tr><td><table><tr><td><table><tr><td>a</td><td>b</td></tr></table></td><td>x</td></tr></table></td><td>x</td></tr></table>",
            "<table><tr><td>y</td><td>x</td></tr><table><tr><td>a</td><td>b</td></tr></table></table>",
        ]
        var cells = "<table><tr><td>a</td><td>b</td></tr></table>"
        var anonymous = cells
        for _ in 1...8 {
            cells = "<table><tr><td>\(cells)</td><td>x</td></tr></table>"
            anonymous = "<table><tr><td>y</td><td>x</td></tr>\(anonymous)</table>"
        }
        for (markup, expectedDepth) in zip(reproductions + [cells, anonymous], [3, 2, 9, 9]) {
            let publication = try TableCoverage.publication(markup)
            let result = BuildResult()
            let thread = Thread {
                let actualStackSize = pthread_get_stacksize_np(pthread_self())
                let section = TableCoverage.section(of: publication)
                result.condition.lock()
                result.section = section
                result.stackBytes = actualStackSize
                result.finished = true
                result.condition.signal()
                result.condition.unlock()
            }
            // Foundation rounds stack requests and adds bookkeeping. Request less than the
            // budget, then assert pthread's actual allocation fits 512 KB in debug and 384 KB
            // in release. The smaller release stack proves at least 128 KB of headroom.
            #if DEBUG
            thread.stackSize = 448 * 1_024
            #else
            thread.stackSize = 320 * 1_024
            #endif
            result.condition.lock()
            print("Building table stack fixture: \(expectedDepth) levels, anonymous=\(markup == anonymous)")
            fflush(nil)
            thread.start()
            while !result.finished { result.condition.wait() }
            let section = result.section
            let actualStackSize = result.stackBytes
            result.condition.unlock()
            #if DEBUG
            XCTAssertLessThanOrEqual(actualStackSize, 512 * 1_024)
            #else
            XCTAssertLessThanOrEqual(actualStackSize, 384 * 1_024)
            #endif
            print("Actual table-build stack: \(actualStackSize) bytes")
            let built = try XCTUnwrap(section)
            XCTAssertFalse(built.report.withheld)
            var tables = TableCoverage.tables(in: built.string)
            var depth = 0
            while let table = tables.first {
                depth += 1
                tables = table.cells.flatMap { TableCoverage.tables(in: $0.content) }
            }
            XCTAssertEqual(depth, expectedDepth, "Every nesting level remains a grid")
            XCTAssertTrue(built.string.readerPlainText().contains("a"), "Deepest table content remains readable")
        }
    }
}

private final class CountedWidthAttachment: ReaderAttachment {
    var measurements = 0
    var layouts = 0
    override func contentWidths() -> (min: CGFloat, max: CGFloat) {
        measurements += 1
        return (37, 37)
    }
    override func layoutBounds(_ line: Line) -> CGRect {
        layouts += 1
        return CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
    }
    required init?(coder: NSCoder) { nil }
    override init() { super.init() }
}

private final class BuildResult: @unchecked Sendable {
    let condition = NSCondition()
    var section: SectionText?
    var finished = false
    var stackBytes = 0
}
