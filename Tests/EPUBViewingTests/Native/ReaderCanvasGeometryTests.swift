import CoreGraphics
import XCTest
@testable import EPUBViewing

/// The column rules of doc/native-viewer.md "Layout", measured against foliate-js's paginator.
final class ReaderCanvasGeometryTests: XCTestCase {
    private typealias Geometry = ReaderCanvasGeometry

    private func spread(_ width: CGFloat, _ height: CGFloat, division: CGRect? = nil, rtl: Bool = false) -> Geometry.Spread {
        Geometry.spread(in: CGRect(x: 0, y: 0, width: width, height: height), division: division, isRightToLeft: rtl)
    }

    func testColumnCountsMatchFoliate() {
        // Measured with foliate-js on macOS and iPad: 753 × 744 gave one column, 780 × 600 two.
        XCTAssertEqual(spread(753, 744).columns.count, 1)
        XCTAssertEqual(spread(780, 600).columns.count, 2)
        XCTAssertEqual(spread(1100, 820).columns.count, 2, "a Mac reader window")
        XCTAssertEqual(spread(951, 669).columns.count, 2, "the iPhone Duo inner display")
        XCTAssertEqual(spread(700, 1000).columns.count, 1, "portrait")
        XCTAssertEqual(spread(770, 600).columns.count, 1, "content width 716 fits one column")
        XCTAssertEqual(spread(1000, 1000).columns.count, 1, "square is not landscape")
    }

    func testOneColumnHasOuterAndVerticalMargins() {
        let column = spread(400, 800).columns[0]
        XCTAssertEqual(column.minX, 14, accuracy: 0.01, "3.5% of the width")
        XCTAssertEqual(column.width, 372, accuracy: 0.01)
        XCTAssertEqual(column.minY, 48)
        XCTAssertEqual(column.height, 800 - 96)
    }

    func testColumnsCapAt720AndCentre() {
        let wide = spread(1000, 1200).columns[0]
        XCTAssertEqual(wide.width, 720)
        XCTAssertEqual(wide.midX, 500, accuracy: 0.01)

        let spread = spread(2400, 1000)
        XCTAssertEqual(spread.columns.count, 2)
        XCTAssertEqual(spread.columns[0].width, 720, accuracy: 0.01)
        XCTAssertEqual(spread.columns[1].width, 720, accuracy: 0.01)
        let area = spread.columns[1].maxX - spread.columns[0].minX
        XCTAssertEqual(spread.columns[0].minX + area / 2, 1200, accuracy: 0.01, "the capped content area is centred")
        let gap = spread.columns[1].minX - spread.columns[0].maxX
        XCTAssertEqual(gap, area * Geometry.gapFraction, accuracy: 0.01)
    }

    func testTwoColumnGapIsFoliatesShareOfTheContentWidth() {
        let spread = spread(780, 600)
        let content = 780 * 0.93
        let gap = spread.columns[1].minX - spread.columns[0].maxX
        XCTAssertEqual(Geometry.gapFraction, 0.0753, accuracy: 0.0001)
        XCTAssertEqual(gap, content * 0.07 / 0.93, accuracy: 0.01)
        XCTAssertEqual(spread.columns[0].minX, 780 * 0.035, accuracy: 0.01)
        XCTAssertEqual(spread.columns[1].maxX, 780 * 0.965, accuracy: 0.01)
        XCTAssertEqual(spread.columns[0].width, spread.columns[1].width, accuracy: 0.001)
    }

    func testDivisionPutsTheGutterOnTheFold() {
        // iPhone Duo book pose: a 41-point fold band at 455–496 of a 951-point display.
        let fold = CGRect(x: 455, y: 0, width: 41, height: 669)
        let spread = spread(951, 669, division: fold)
        XCTAssertEqual(spread.columns.count, 2)
        let halfGap = Geometry.gapFraction * 951 * 0.93 / 2
        XCTAssertEqual(spread.columns[0].maxX, fold.minX - halfGap, accuracy: 0.01)
        XCTAssertEqual(spread.columns[1].minX, fold.maxX + halfGap, accuracy: 0.01)
        XCTAssertFalse(spread.columns.contains { $0.intersects(fold) }, "text never crosses the fold")
    }

    func testOffCentreDivisionUsesTheNarrowerSideForBothColumns() {
        // A vertical toolbar strip on one side moves the fold off the reader's centre.
        let fold = CGRect(x: 395, y: 0, width: 41, height: 669)
        let spread = spread(891, 669, division: fold)
        let margin = 891 * 0.035, halfGap = Geometry.gapFraction * 891 * 0.93 / 2
        let narrower = fold.minX - halfGap - margin
        XCTAssertEqual(spread.columns[0].width, narrower, accuracy: 0.01)
        XCTAssertEqual(spread.columns[1].width, narrower, accuracy: 0.01)
        XCTAssertEqual(spread.columns[0].maxX, fold.minX - halfGap, accuracy: 0.01, "aligned towards the fold")
        XCTAssertEqual(spread.columns[1].minX, fold.maxX + halfGap, accuracy: 0.01, "aligned towards the fold")
    }

    func testDivisionAlwaysGivesTwoColumnsEvenInPortrait() {
        let spread = spread(600, 900, division: CGRect(x: 290, y: 0, width: 20, height: 900))
        XCTAssertEqual(spread.columns.count, 2)
    }

    func testDivisionOutsideThePageIsIgnored() {
        XCTAssertEqual(spread(600, 900, division: CGRect(x: 700, y: 0, width: 20, height: 900)), spread(600, 900))
        XCTAssertEqual(spread(600, 900, division: CGRect(x: -30, y: 0, width: 20, height: 900)), spread(600, 900))
    }

    func testRightToLeftSpreadsReadFromTheRight() {
        let ltr = spread(1100, 820), rtl = spread(1100, 820, rtl: true)
        XCTAssertEqual(rtl.columns, ltr.columns.reversed())
        XCTAssertGreaterThan(rtl.columns[0].minX, rtl.columns[1].minX, "the first slice is on the right")
        let fold = CGRect(x: 455, y: 0, width: 41, height: 669)
        let book = spread(951, 669, division: fold, rtl: true)
        XCTAssertGreaterThan(book.columns[0].minX, fold.maxX)
    }

    func testScrollColumnIsCentredAndCapped() {
        let wide = Geometry.scrollColumn(in: CGRect(x: 0, y: 0, width: 1000, height: 800), division: nil)
        XCTAssertEqual(wide.width, 720)
        XCTAssertEqual(wide.minX, 140, accuracy: 0.01)
        let narrow = Geometry.scrollColumn(in: CGRect(x: 0, y: 0, width: 400, height: 800), division: nil)
        XCTAssertEqual(narrow.width, 372, accuracy: 0.01)
        XCTAssertEqual(narrow.minX, 14, accuracy: 0.01)
    }

    func testScrollColumnUsesTheWiderSideOfADivision() {
        let fold = CGRect(x: 395, y: 0, width: 41, height: 669)
        let column = Geometry.scrollColumn(in: CGRect(x: 0, y: 0, width: 891, height: 669), division: fold)
        XCTAssertGreaterThanOrEqual(column.minX, fold.maxX)
        XCTAssertLessThanOrEqual(column.minX + column.width, 891 * 0.965 + 0.01)
        let left = Geometry.scrollColumn(in: CGRect(x: 0, y: 0, width: 891, height: 669),
                                         division: CGRect(x: 500, y: 0, width: 41, height: 669))
        XCTAssertLessThanOrEqual(left.minX + left.width, 500)
    }
}

/// Page-turn input rules: keys through `ReaderEPUBPageTurnKey`, wheel ticks, swipes.
final class ReaderCanvasInputTests: XCTestCase {
    func testKeysMapToPageTurnsWithoutTakingSelectionShortcuts() {
        XCTAssertEqual(ReaderCanvasInput.direction(for: .leftArrow, shift: false, otherModifiers: false), false)
        XCTAssertEqual(ReaderCanvasInput.direction(for: .pageUp, shift: false, otherModifiers: false), false)
        XCTAssertEqual(ReaderCanvasInput.direction(for: .rightArrow, shift: false, otherModifiers: false), true)
        XCTAssertEqual(ReaderCanvasInput.direction(for: .pageDown, shift: false, otherModifiers: false), true)
        XCTAssertEqual(ReaderCanvasInput.direction(for: .space, shift: false, otherModifiers: false), true)
        XCTAssertEqual(ReaderCanvasInput.direction(for: .space, shift: true, otherModifiers: false), false)
        XCTAssertNil(ReaderCanvasInput.direction(for: .leftArrow, shift: true, otherModifiers: false),
                     "Shift-arrow extends a selection")
        XCTAssertNil(ReaderCanvasInput.direction(for: .rightArrow, shift: false, otherModifiers: true),
                     "Command-arrow is the system's")
        XCTAssertNil(ReaderCanvasInput.direction(for: "a", shift: false, otherModifiers: true), "Cmd-A selects all")
        XCTAssertNil(ReaderCanvasInput.direction(for: "c", shift: false, otherModifiers: true), "Cmd-C copies")
    }

    func testWheelTicksTurnOncePerCooldown() {
        var turner = ReaderWheelPageTurner()
        XCTAssertNil(turner.direction(deltaX: 0, deltaY: 3.9, isRightToLeft: false, at: 0), "below the threshold")
        XCTAssertEqual(turner.direction(deltaX: 0, deltaY: 4, isRightToLeft: false, at: 1), true)
        XCTAssertNil(turner.direction(deltaX: 0, deltaY: 40, isRightToLeft: false, at: 1.2), "momentum inside the cooldown")
        XCTAssertEqual(turner.direction(deltaX: 0, deltaY: -10, isRightToLeft: false, at: 1.46), false)
        XCTAssertEqual(turner.direction(deltaX: 12, deltaY: 3, isRightToLeft: false, at: 2), true, "horizontal wins")
        XCTAssertEqual(turner.direction(deltaX: 12, deltaY: 3, isRightToLeft: true, at: 3), false, "mirrored right to left")
        XCTAssertEqual(turner.direction(deltaX: 0, deltaY: 12, isRightToLeft: true, at: 4), true, "vertical is never mirrored")
    }

    func testSwipesMirrorRightToLeft() {
        XCTAssertTrue(ReaderCanvasInput.swipeDirection(towardsLeft: true, isRightToLeft: false))
        XCTAssertFalse(ReaderCanvasInput.swipeDirection(towardsLeft: false, isRightToLeft: false))
        XCTAssertFalse(ReaderCanvasInput.swipeDirection(towardsLeft: true, isRightToLeft: true))
        XCTAssertTrue(ReaderCanvasInput.swipeDirection(towardsLeft: false, isRightToLeft: true))
    }
}
