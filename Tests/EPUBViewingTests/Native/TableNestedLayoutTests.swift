import CoreGraphics
import XCTest
@testable import EPUBViewing

final class TableNestedLayoutTests: XCTestCase {
    private func fixture(depth: Int, paragraphs: Int = 200) throws -> TableModel {
        var markup = "<table><tr><td>w1</td><td>" + String(repeating: "<p>v1 v2</p>", count: paragraphs) + "</td></tr></table>"
        for _ in 0..<depth { markup = "<table><tr><td>\(markup)</td><td>x</td></tr></table>" }
        return try TableCoverage.table(markup)
    }

    private func tables(_ table: TableModel) -> [TableModel] {
        [table] + table.cells.flatMap { TableCoverage.tables(in: $0.content).flatMap(tables) }
    }

    func testNestedLayoutPassesGrowLinearlyAndCannotCompoundTextReduction() throws {
        for depth in 0...8 {
            let table = try fixture(depth: depth)
            let models = tables(table)
            XCTAssertEqual(models.count, depth + 1)
            XCTAssertEqual(models.reduce(0) { $0 + $1.layoutPassCount }, 0, "building performs no display layout")
            let layout = table.layout(available: 360, viewportHeight: 600)
            XCTAssertLessThanOrEqual(models.reduce(0) { $0 + $1.layoutPassCount }, 5 * models.count)
            XCTAssertEqual(layout.scale, 1, "a row that cannot fit stays at its initial size")
            for inner in models.dropFirst() {
                XCTAssertEqual(inner.layout(available: 360, viewportHeight: 600, nested: true).scale, 1,
                    "inner tables inherit the outer scale and wrap instead of shrinking again")
            }
        }
    }

    func testActualNestedDrawingScaleStaysAtOrAboveSixtyPercent() throws {
        var markup = "<table><tr><td>" + String(repeating: "wideword", count: 100) + "</td><td>x</td></tr></table>"
        for _ in 0..<8 { markup = "<table><tr><td>\(markup)</td><td>x</td></tr></table>" }
        let table = try TableCoverage.table(markup)
        let layout = table.layout(available: 360, viewportHeight: 600)
        XCTAssertEqual(layout.scale, TableModel.minimumScale)
        var checked = Set<Int>()
        func check(_ layout: TableLayout, inherited: CGFloat) {
            let actual = inherited * layout.scale
            XCTAssertGreaterThanOrEqual(actual, TableModel.minimumScale - 0.001)
            for cell in layout.cellText {
                for line in cell.lines {
                    if let row = line.nestedRow, checked.insert(row.table.sourceOrder).inserted {
                        let inner = row.layout(width: line.frame.width, viewportHeight: 600)
                        XCTAssertEqual(inner.scale, 1)
                        check(inner, inherited: actual)
                    }
                }
            }
        }
        check(layout, inherited: 1)
    }

    @MainActor func testFinalNestedContinuationDrawsOnlyItsTail() throws {
        let section = try TableCoverage.section("<table><tr><td><table><tr><td><p style='color:#ff0000'>Opening red</p>"
            + String(repeating: "<p>ordinary middle</p>", count: 60)
            + "<p style='color:#0000ff'>Closing blue</p></td><td>x</td></tr></table></td><td>x</td></tr></table>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let layout = table.layout(available: 350, viewportHeight: 600)
        let slice = try XCTUnwrap(layout.fragments(ofRow: 0, maximumHeight: 599).last)
        let row = TableRowAttachment(table: table, row: 0, fragment: slice, layout: layout)
        XCTAssertTrue(row.textEquivalent.contains("Closing blue"))
        XCTAssertFalse(row.textEquivalent.contains("Opening red"))
        let size = CGSize(width: 350, height: slice.height * layout.scale)
        let source = try XCTUnwrap(row.image(forBounds: CGRect(origin: .zero, size: size), textContainer: nil, characterIndex: 0))
        let image = try XCTUnwrap(RichImageTests.draw(source, size: size, scale: 1))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var red = 0, blue = 0
        for pixel in 0..<(image.width * image.height) {
            let index = pixel * 4
            if bytes[index] > 160 && bytes[index + 1] < 100 && bytes[index + 2] < 100 { red += 1 }
            if bytes[index + 2] > 160 && bytes[index] < 100 && bytes[index + 1] < 100 { blue += 1 }
        }
        XCTAssertEqual(red, 0, "the opening is never redrawn in the final continuation")
        XCTAssertGreaterThan(blue, 0, "the final continuation draws its actual tail")
    }

    func testNestedTallRowContinuesWithItsOwnTextWithoutTinyFragments() throws {
        let table = try fixture(depth: 1, paragraphs: 60)
        let layout = table.layout(available: 350, viewportHeight: 600)
        let slices = layout.fragments(ofRow: 0, maximumHeight: 599)
        XCTAssertGreaterThan(slices.count, 2)
        XCTAssertTrue(slices.allSatisfy { $0.fitScale == 1 && $0.height * layout.scale <= 599.01 })
        XCTAssertTrue(slices.allSatisfy { $0.height > 20 }, "no empty sliver before the nested row")
        let words = slices.map { TableRowAttachment(table: table, row: 0, fragment: $0, layout: layout).textEquivalent }
        XCTAssertEqual(words.joined(separator: " ").components(separatedBy: "v1").count - 1, 60)
        XCTAssertEqual(words.joined(separator: " ").components(separatedBy: "v2").count - 1, 60)
    }
}
