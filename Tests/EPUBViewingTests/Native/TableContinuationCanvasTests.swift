import CoreGraphics
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class TableContinuationCanvasTests: XCTestCase {
    func testPageTurnsExposeAllContinuationWordsInOneAndTwoColumnReaders() async throws {
        let words = (0..<1200).map { "word\($0)" }
        for size in [CGSize(width: 360, height: 500), CGSize(width: 1100, height: 500)] {
            for spanning in [false, true] {
                let fixture = try RichFixture("""
                <table id='t' border='1'><tr><td rowspan='\(spanning ? 3 : 1)'>\(words.joined(separator: " "))</td><td>First</td></tr>
                <tr><td>Second</td>\(spanning ? "" : "<td>Other</td>")</tr><tr><td>Third</td>\(spanning ? "" : "<td>Last</td>")</tr></table>
                """, typography: .init(fontSize: 34))
                let text = try XCTUnwrap(fixture.table("t"))
                let host = CanvasHost(FakeCanvasSource([text]), size: size)
                defer { host.close() }
                host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
                host.layOut()
                try await host.settle(30)
                XCTAssertEqual(host.canvas.textViews.count, size.width > 1000 ? 2 : 1)
                var seen: [String] = [], turns = 0
                while turns < 200 {
                    for view in host.canvas.textViews where !view.isHidden {
                        seen += view.visibleText.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("word") }.map(String.init)
                        if view.placement.visibleLength > 0 {
                            let last = try XCTUnwrap(view.lineFrame(containing: view.placement.visibleLength - 1))
                            XCTAssertLessThanOrEqual(last.maxY, view.frame.height + 0.5)
                        }
                    }
                    let result = host.canvas.turnPage(forward: true)
                    if result == .atBoundary { break }
                    XCTAssertEqual(result, .turned, "Continuation turns advance even while their source ranges coincide")
                    turns += 1
                }
                XCTAssertGreaterThan(turns, 0)
                XCTAssertLessThan(turns, 200)
                XCTAssertEqual(seen, words)
                XCTAssertEqual(host.recorder.shown.count, turns + 1)
                var back = 0
                while host.canvas.turnPage(forward: false) == .turned { back += 1 }
                XCTAssertEqual(back, turns)
            }
        }
    }
}
