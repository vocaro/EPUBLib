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
                    for (column, view) in host.canvas.textViews.enumerated() where !view.isHidden {
                        seen += view.visibleText.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("word") }.map(String.init)
                        if view.placement.visibleLength > 0 {
                            let last = try XCTUnwrap(view.lineFrame(containing: view.placement.visibleLength - 1))
                            let details = last.maxY > view.frame.height + 0.5
                                ? geometry(of: view, canvas: host.canvas, size: size, spanning: spanning, turn: turns, column: column, last: last) : ""
                            XCTAssertLessThanOrEqual(last.maxY, view.frame.height + 0.5, details)
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
    /// Capture the frozen pagination model and native line metrics only on an overflow.
    private func geometry(of view: ReaderTextView, canvas: ReaderCanvasView, size: CGSize,
                          spanning: Bool, turn: Int, column: Int, last: CGRect) -> String {
        let viewport = view.readerContainer.viewportSize
        var details = ["size=\(size), spanning=\(spanning), turn=\(turn), column=\(column), last=\(last)",
            "canvas=\(canvas.bounds), view=\(view.frame), viewport=\(viewport), container=\(view.readerContainer.size), placement=\(view.placement), nonlinear=\(view.readerContainer.hasNonlinearGeometry)"]
        if let shown = canvas.shownPage, let page = canvas.paginator(for: shown.section)?.page(at: shown.page + column) {
            details.append("page=\(shown.page + column), range=\(page.range), layoutEnd=\(page.layoutEnd), height=\(page.height), topSpacing=\(page.topSpacing), fragments=\(page.tableFragments.count), fallback=\(page.usesFlowFallback), measured=\(page.measuredLineLengths)")
        }
        if let storage = view.contentStorage.textStorage {
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
                guard let row = attributes[.attachment] as? TableRowAttachment else { return }
                let font = attributes[.font] as? PlatformFont
                let style = attributes[.paragraphStyle] as? NSParagraphStyle
                let layout = row.layout(width: viewport.width, viewportHeight: viewport.height)
                let bounds = row.layoutBounds(.init(width: viewport.width, viewport: viewport, font: font))
                let nilFontBounds = row.layoutBounds(.init(width: viewport.width, viewport: viewport))
                let native = view.lineFrame(containing: range.location)
                let fragment = row.fragment.map { "top=\($0.top), bottom=\($0.bottom), height=\($0.height), fit=\($0.fitScale), cells=\($0.cells)" } ?? "whole"
                details.append("row=\(row.row), run=\(range), native=\(String(describing: native)), scale=\(layout.scale), fragment=[\(fragment)], bounds=\(bounds), nilFontBounds=\(nilFontBounds), font=\(font?.fontName ?? "nil"), size=\(font?.pointSize ?? 0), descent=\(font?.descender ?? 0), leading=\(font?.leading ?? 0), baseline=\(String(describing: attributes[.baselineOffset])), lineMultiple=\(style?.lineHeightMultiple ?? 0), minLine=\(style?.minimumLineHeight ?? 0), maxLine=\(style?.maximumLineHeight ?? 0), lineSpacing=\(style?.lineSpacing ?? 0), before=\(style?.paragraphSpacingBefore ?? 0), after=\(style?.paragraphSpacing ?? 0)")
            }
        }
        return details.joined(separator: "\n")
    }

}
