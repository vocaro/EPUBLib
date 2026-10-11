import CoreGraphics
import Foundation
import XCTest
@testable import EPUBViewing

/// The numbers and rules of doc/native-viewer.md "Layout" (Columns, Book pose, Continuous scroll,
/// Right to left), at and around their boundaries.
final class ViewCoverageGeometryTests: XCTestCase {
    private typealias Geometry = ReaderCanvasGeometry

    private func spread(_ width: CGFloat, _ height: CGFloat, division: CGRect? = nil, rtl: Bool = false) -> Geometry.Spread {
        Geometry.spread(in: CGRect(x: 0, y: 0, width: width, height: height), division: division, isRightToLeft: rtl)
    }

    // MARK: Columns

    func testTwoColumnsNeedAContentWidthOfMoreThan720() {
        // 93% of 774.19 is 719.997 and of 774.2 is 720.006: "more than 720 (about 775 pt wide)".
        XCTAssertEqual(spread(774.19, 600).columns.count, 1)
        XCTAssertEqual(spread(774.2, 600).columns.count, 2)
        XCTAssertEqual(spread(774, 600).columns.count, 1)
        XCTAssertEqual(spread(775, 600).columns.count, 2)
        let one = spread(774.19, 600).columns[0]
        XCTAssertEqual(one.width, 774.19 * 0.93, accuracy: 0.001, "below the threshold one column takes the content width")
        XCTAssertLessThan(one.width, 720)
        let two = spread(774.2, 600)
        XCTAssertEqual(two.columns[1].maxX - two.columns[0].minX, 774.2 * 0.93, accuracy: 0.001)
    }

    func testTwoColumnsNeedAPageWiderThanItIsTall() {
        XCTAssertEqual(spread(1000, 1000).columns.count, 1, "width == height is not landscape")
        XCTAssertEqual(spread(1000, 999.99).columns.count, 2)
        XCTAssertEqual(spread(1000, 1000.01).columns.count, 1)
        XCTAssertEqual(spread(800, 1200).columns.count, 1, "portrait, however wide")
        XCTAssertEqual(spread(3000, 3001).columns.count, 1)
        XCTAssertEqual(spread(776, 775).columns.count, 2, "barely landscape, barely wide enough")
        XCTAssertEqual(Geometry.columnCount(for: CGSize(width: 776, height: 775)), 2)
        XCTAssertEqual(Geometry.columnCount(for: CGSize(width: 774, height: 100)), 1)
    }

    func testOneColumnReachesItsCapWhereTheContentWidthDoes() {
        // Portrait pages show one column however wide: capped where 93% of the width passes 720.
        for (width, expected) in [(700.0, 651.0), (774.0, 719.82), (774.2, 720.0), (780.0, 720.0), (1200.0, 720.0)] as [(CGFloat, CGFloat)] {
            let column = spread(width, 2000).columns[0]
            XCTAssertEqual(column.width, expected, accuracy: 0.001, "\(width)")
            XCTAssertEqual(column.midX, width / 2, accuracy: 0.001, "centred at \(width)")
        }
    }

    func testTwoColumnsReachTheirCapWhereEachIs720Wide() {
        // Two 720-point columns and their gap need 1440 / (1 - 7.53%) = 1557.2 points of content,
        // which is 93% of 1674.4.
        let below = spread(1674, 900), at = spread(1675, 900), beyond = spread(4000, 900)
        XCTAssertEqual(below.columns[0].width, (1674 * 0.93) * (1 - Geometry.gapFraction) / 2, accuracy: 0.001)
        XCTAssertLessThan(below.columns[0].width, 720)
        XCTAssertEqual(below.columns[0].minX, 1674 * 0.035, accuracy: 0.001, "uncapped content starts at the margin")
        for capped in [at, beyond] {
            for column in capped.columns { XCTAssertEqual(column.width, 720, accuracy: 0.001) }
            XCTAssertEqual(capped.columns[1].minX - capped.columns[0].maxX, 1440 * Geometry.gapFraction / (1 - Geometry.gapFraction),
                           accuracy: 0.001, "the gap is 7.53% of the capped content width")
        }
        XCTAssertEqual((beyond.columns[0].minX + beyond.columns[1].maxX) / 2, 2000, accuracy: 0.001, "the capped area is centred")
    }

    /// Every rule of "Columns" over a sweep of page sizes and origins.
    func testColumnRulesHoldForEveryPageSize() {
        let widths: [CGFloat] = [1, 20, 50, 199, 320, 390, 600, 753, 774, 775, 780, 951, 1024, 1366, 1674, 1675, 2560, 5120]
        let heights: [CGFloat] = [1, 50, 96, 97, 480, 700, 774, 775, 1024, 3000]
        for origin in [CGPoint.zero, CGPoint(x: 37, y: 61), CGPoint(x: -400, y: -90)] {
            for width in widths {
                for height in heights {
                    for rtl in [false, true] {
                        let page = CGRect(origin: origin, size: CGSize(width: width, height: height))
                        let columns = Geometry.spread(in: page, division: nil, isRightToLeft: rtl).columns
                        let label = "\(page) rtl \(rtl)"
                        let landscape = width > height && width * 0.93 > 720
                        XCTAssertEqual(columns.count, landscape ? 2 : 1, label)
                        let ordered = rtl ? columns.reversed() : columns
                        guard let first = ordered.first, let last = ordered.last else { return XCTFail(label) }
                        XCTAssertGreaterThanOrEqual(first.minX, page.minX + 0.035 * width - 0.001, "left margin \(label)")
                        XCTAssertLessThanOrEqual(last.maxX, page.maxX - 0.035 * width + 0.001, "right margin \(label)")
                        XCTAssertEqual((first.minX + last.maxX) / 2, page.midX, accuracy: 0.001, "centred \(label)")
                        let content = last.maxX - first.minX
                        XCTAssertEqual(content, min(width * 0.93, columns.count == 2 ? 1440 / (1 - Geometry.gapFraction) : 720),
                                       accuracy: 0.001, "content width \(label)")
                        for column in columns {
                            XCTAssertGreaterThan(column.width, 0, label)
                            XCTAssertLessThanOrEqual(column.width, 720 + 0.001, label)
                            XCTAssertEqual(column.width, first.width, accuracy: 0.001, "equal columns \(label)")
                            XCTAssertEqual(column.minY, page.minY + 48, "top margin \(label)")
                            XCTAssertEqual(column.height, max(0, height - 96), "bottom margin \(label)")
                        }
                        if ordered.count == 2 {
                            XCTAssertEqual(ordered[1].minX - ordered[0].maxX, content * 0.07 / 0.93, accuracy: 0.001, "gap \(label)")
                        }
                    }
                }
            }
        }
    }

    func testTheGapIs7Point53PercentOfTheContentWidth() {
        XCTAssertEqual(Geometry.gapFraction, 0.07 / (1 - 0.07), accuracy: 1e-12, "foliate's g / (1 − g) with g = 7%")
        XCTAssertEqual(Geometry.gapFraction, 0.0753, accuracy: 0.00005)
        let spread = spread(1000, 700)
        let gap = spread.columns[1].minX - spread.columns[0].maxX
        XCTAssertEqual(gap / 930, 0.0753, accuracy: 0.00005, "7.53% of the 930-point content width")
        XCTAssertEqual(gap, 70, accuracy: 0.001, "as wide as the two outer margins of 35 together")
    }

    func testDegeneratePagesGiveNoNegativeOrUndefinedColumns() {
        let tiny = spread(50, 50)
        XCTAssertEqual(tiny.columns.count, 1)
        XCTAssertEqual(tiny.columns[0].minX, 1.75, accuracy: 0.001)
        XCTAssertEqual(tiny.columns[0].width, 46.5, accuracy: 0.001)
        XCTAssertEqual(tiny.columns[0].minY, 48)
        XCTAssertEqual(tiny.columns[0].height, 0, "no room between the 48-point margins")
        XCTAssertEqual(spread(0, 0).columns, [CGRect(x: 0, y: 48, width: 0, height: 0)])
        XCTAssertEqual(spread(600, 96).columnSize.height, 0)
        XCTAssertEqual(spread(600, 97).columnSize.height, 1)
        // A rectangle given with negative extents is the same page.
        let flipped = CGRect(x: 600, y: 700, width: -600, height: -700)
        XCTAssertEqual(Geometry.spread(in: flipped, division: nil, isRightToLeft: false), spread(600, 700))
        let huge = spread(1e9, 1e6)
        for column in huge.columns { XCTAssertEqual(column.width, 720, accuracy: 0.001) }
        XCTAssertEqual((huge.columns[0].minX + huge.columns[1].maxX) / 2, 5e8, accuracy: 0.01)
        XCTAssertEqual(spread(1e9, 1e9).columns.count, 1)
        for size in [CGSize(width: CGFloat.greatestFiniteMagnitude, height: 800), CGSize(width: 800, height: CGFloat.greatestFiniteMagnitude),
                     CGSize(width: CGFloat.infinity, height: 800), CGSize(width: 800, height: CGFloat.infinity),
                     CGSize(width: CGFloat.nan, height: 800), CGSize(width: 800, height: CGFloat.nan),
                     CGSize(width: CGFloat.leastNonzeroMagnitude, height: CGFloat.leastNonzeroMagnitude)] {
            let spread = Geometry.spread(in: CGRect(origin: .zero, size: size), division: nil, isRightToLeft: false)
            XCTAssertFalse(spread.columns.isEmpty, "\(size)")
            for column in spread.columns {
                XCTAssertFalse(column.width.isNaN || column.width < 0 || column.width > 720.001, "\(size): \(column)")
                XCTAssertFalse(column.height.isNaN || column.height < 0, "\(size): \(column)")
            }
            let scroll = Geometry.scrollColumn(in: CGRect(origin: .zero, size: size), division: nil)
            XCTAssertFalse(scroll.width.isNaN || scroll.width < 0 || scroll.width > 720.001, "\(size): \(scroll)")
        }
    }

    // MARK: Book pose

    private func divided(_ width: CGFloat, fold: ClosedRange<CGFloat>, rtl: Bool = false) -> Geometry.Spread {
        spread(width, 700, division: CGRect(x: fold.lowerBound, y: 0, width: fold.upperBound - fold.lowerBound, height: 700), rtl: rtl)
    }

    func testACentredDivisionGivesEqualColumnsWithTheGutterOnIt() {
        // 1000 wide: margins of 35 and a gap of 70, so half a gap of 35 each side of the fold.
        let spread = divided(1000, fold: 480...520)
        XCTAssertEqual(spread.columns.count, 2)
        XCTAssertEqual(spread.columns[0].minX, 35, accuracy: 0.001)
        XCTAssertEqual(spread.columns[0].maxX, 445, accuracy: 0.001)
        XCTAssertEqual(spread.columns[1].minX, 555, accuracy: 0.001)
        XCTAssertEqual(spread.columns[1].maxX, 965, accuracy: 0.001)
        XCTAssertEqual(spread.columns[1].minX - spread.columns[0].maxX, 40 + 70, accuracy: 0.001, "the division band plus half a gap each side")
        XCTAssertEqual(divided(1000, fold: 480...520, rtl: true).columns, spread.columns.reversed())
    }

    func testADivisionsNarrowerSideUnder200WideGivesOneColumnOnTheWiderSide() {
        // With margins of 35 and half a gap of 35, the left side is `fold.minX - 70` wide.
        for (foldStart, narrower) in [(269.0, 199.0), (269.9, 199.9)] as [(CGFloat, CGFloat)] {
            let spread = divided(1000, fold: foldStart...(foldStart + 40))
            XCTAssertEqual(spread.columns.count, 1, "\(narrower) is under 200")
            let column = spread.columns[0]
            XCTAssertEqual(column.minX, foldStart + 40 + 35, accuracy: 0.001, "half a gap right of the fold")
            XCTAssertEqual(column.maxX, 965, accuracy: 0.001, "up to the outer margin")
            XCTAssertLessThanOrEqual(column.width, 720)
        }
        for (foldStart, narrower) in [(270.1, 200.1), (271.0, 201.0), (300.0, 230.0)] as [(CGFloat, CGFloat)] {
            let spread = divided(1000, fold: foldStart...(foldStart + 40))
            XCTAssertEqual(spread.columns.count, 2, "\(narrower) is not under 200")
            for column in spread.columns { XCTAssertEqual(column.width, narrower, accuracy: 0.001, "both take the narrower side's width") }
            XCTAssertEqual(spread.columns[0].maxX, foldStart - 35, accuracy: 0.001, "aligned towards the fold")
            XCTAssertEqual(spread.columns[1].minX, foldStart + 40 + 35, accuracy: 0.001, "aligned towards the fold")
        }
        // The mirror image: a narrow right side.
        let mirrored = divided(1000, fold: 691...731)
        XCTAssertEqual(mirrored.columns.count, 1)
        XCTAssertEqual(mirrored.columns[0].maxX, 691 - 35, accuracy: 0.001)
        XCTAssertEqual(mirrored.columns[0].minX, 35, accuracy: 0.001)
    }

    func testBookPoseColumnsCapAt720() {
        let spread = divided(4000, fold: 1980...2020)
        XCTAssertEqual(spread.columns.map(\.width), [720, 720])
        let halfGap = Geometry.gapFraction * 1440 / (1 - Geometry.gapFraction) / 2
        XCTAssertEqual(spread.columns[0].maxX, 1980 - halfGap, accuracy: 0.001, "capped columns stay against the fold")
        XCTAssertEqual(spread.columns[1].minX, 2020 + halfGap, accuracy: 0.001)
    }

    func testADivisionThatDoesNotSplitThePageIsIgnored() {
        let plain = spread(1000, 700)
        func fold(_ x: CGFloat, _ width: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: width, height: 700) }
        XCTAssertEqual(spread(1000, 700, division: fold(0, 40)), plain, "at the left edge")
        XCTAssertEqual(spread(1000, 700, division: fold(960, 40)), plain, "at the right edge")
        XCTAssertEqual(spread(1000, 700, division: fold(-10, 1020)), plain, "wider than the page")
        XCTAssertEqual(spread(1000, 700, division: fold(0, 1000)), plain, "the whole page")
        XCTAssertEqual(spread(1000, 700, division: .null), plain)
        XCTAssertEqual(spread(1000, 700, division: fold(.nan, 40)), plain)
        XCTAssertEqual(spread(1000, 700, division: fold(480, .infinity)), plain)
        XCTAssertNil(Geometry.usableDivision(nil, in: CGRect(x: 0, y: 0, width: 1000, height: 700)))
        // Just inside either edge it splits the page, into a side too narrow for a column.
        for division in [fold(1, 40), fold(959, 40)] {
            let spread = spread(1000, 700, division: division)
            XCTAssertEqual(spread.columns.count, 1, "\(division)")
            XCTAssertFalse(spread.columns[0].intersects(division))
            XCTAssertGreaterThanOrEqual(spread.columns[0].minX, 35 - 0.001)
            XCTAssertLessThanOrEqual(spread.columns[0].maxX, 965 + 0.001)
        }
    }

    func testADivisionGivenWithANegativeOrZeroWidthStillSplitsThePage() {
        let expected = divided(1000, fold: 480...520)
        XCTAssertEqual(spread(1000, 700, division: CGRect(x: 520, y: 700, width: -40, height: -700)), expected)
        let line = spread(1000, 700, division: CGRect(x: 500, y: 0, width: 0, height: 700))
        XCTAssertEqual(line.columns.count, 2)
        XCTAssertEqual(line.columns[1].minX - line.columns[0].maxX, 70, accuracy: 0.001, "a fold without a band keeps the gap")
    }

    /// Book-pose rules over a sweep of pages and divisions: text never crosses the division,
    /// the outer margins hold, and no column is negative.
    func testBookPoseRulesHoldForEveryDivision() {
        for origin in [CGPoint.zero, CGPoint(x: 44, y: 20)] {
            for width in [120, 571, 600, 891, 951, 1366, 2400] as [CGFloat] {
                for band in [0, 20, 41, 120] as [CGFloat] {
                    for step in 1..<20 {
                        let page = CGRect(origin: origin, size: CGSize(width: width, height: 700))
                        let division = CGRect(x: page.minX + width * CGFloat(step) / 20 - band / 2, y: page.minY, width: band, height: 700)
                        guard Geometry.usableDivision(division, in: page) != nil else { continue }
                        let label = "\(page) \(division)"
                        let margin = 0.035 * width, halfGap = Geometry.gapFraction * min(width * 0.93, 1440 / (1 - Geometry.gapFraction)) / 2
                        let left = division.minX - halfGap - (page.minX + margin), right = page.maxX - margin - (division.maxX + halfGap)
                        let columns = Geometry.spread(in: page, division: division, isRightToLeft: false).columns
                        XCTAssertEqual(columns.count, min(left, right) >= 200 ? 2 : 1, label)
                        for column in columns {
                            XCTAssertGreaterThanOrEqual(column.width, 0, label)
                            XCTAssertLessThanOrEqual(column.width, 720 + 0.001, label)
                            XCTAssertGreaterThanOrEqual(column.minX, page.minX + margin - 0.001, label)
                            XCTAssertLessThanOrEqual(column.maxX, page.maxX - margin + 0.001, label)
                            XCTAssertTrue(column.maxX <= division.minX - halfGap + 0.001 || column.minX >= division.maxX + halfGap - 0.001,
                                          "half a gap clear of the division: \(column) \(label)")
                            XCTAssertEqual(column.minY, page.minY + 48, label)
                            XCTAssertEqual(column.height, 700 - 96, label)
                        }
                        if columns.count == 2 {
                            XCTAssertEqual(columns[0].width, min(720, left, right), accuracy: 0.001, label)
                            XCTAssertEqual(columns[1].width, columns[0].width, accuracy: 0.001, label)
                            XCTAssertEqual(columns[0].maxX, division.minX - halfGap, accuracy: 0.001, label)
                            XCTAssertEqual(columns[1].minX, division.maxX + halfGap, accuracy: 0.001, label)
                        } else if let column = columns.first {
                            let onLeft = column.maxX <= division.minX
                            XCTAssertEqual(onLeft, division.minX - page.minX >= page.maxX - division.maxX, "the wider side \(label)")
                            let scroll = Geometry.scrollColumn(in: page, division: division)
                            XCTAssertEqual(column.minX, scroll.minX, accuracy: 0.001, "the column continuous scroll uses \(label)")
                            XCTAssertEqual(column.width, scroll.width, accuracy: 0.001, label)
                        }
                    }
                }
            }
        }
    }

    // MARK: Continuous scroll

    func testTheScrollColumnKeepsTheOuterMarginUntilItsCap() {
        for width in [1, 50, 320, 600, 774, 775, 1000, 5000] as [CGFloat] {
            for minX in [0, 120] as [CGFloat] {
                let column = Geometry.scrollColumn(in: CGRect(x: minX, y: 0, width: width, height: 700), division: nil)
                XCTAssertEqual(column.width, min(720, width * 0.93), accuracy: 0.001, "\(width)")
                XCTAssertEqual(column.minX + column.width / 2, minX + width / 2, accuracy: 0.001, "centred at \(width)")
                XCTAssertGreaterThanOrEqual(column.minX, minX + 0.035 * width - 0.001)
                // The same column a one-column page gets.
                let page = Geometry.spread(in: CGRect(x: minX, y: 0, width: width, height: 10_000), division: nil, isRightToLeft: true).columns[0]
                XCTAssertEqual(page.minX, column.minX, accuracy: 0.001)
                XCTAssertEqual(page.width, column.width, accuracy: 0.001)
            }
        }
        XCTAssertEqual(Geometry.scrollColumn(in: .zero, division: nil).width, 0)
    }

    func testTheScrollColumnTakesTheWiderSideOfADivisionAndStaysHalfAGapClear() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        func column(_ fold: ClosedRange<CGFloat>) -> (minX: CGFloat, width: CGFloat) {
            Geometry.scrollColumn(in: bounds, division: CGRect(x: fold.lowerBound, y: 0, width: fold.upperBound - fold.lowerBound, height: 700))
        }
        let right = column(200...240)
        XCTAssertEqual(right.minX, 240 + 35, accuracy: 0.001)
        XCTAssertEqual(right.minX + right.width, 965, accuracy: 0.001)
        let left = column(700...740)
        XCTAssertEqual(left.minX, 35, accuracy: 0.001)
        XCTAssertEqual(left.minX + left.width, 700 - 35, accuracy: 0.001)
        let centred = column(480...520)
        XCTAssertEqual(centred.minX + centred.width, 480 - 35, accuracy: 0.001, "equal sides: the left one")
        // A side wider than the cap centres its 720-point column in that side.
        let wide = Geometry.scrollColumn(in: CGRect(x: 0, y: 0, width: 3000, height: 700), division: CGRect(x: 300, y: 0, width: 40, height: 700))
        XCTAssertEqual(wide.width, 720)
        let sideMin = 340 + Geometry.gapFraction * 1440 / (1 - Geometry.gapFraction) / 2, sideMax = 3000 * 0.965
        XCTAssertEqual(wide.minX + 360, (sideMin + sideMax) / 2, accuracy: 0.001)
        // A division that leaves no room on either side gives an empty column, never a negative one.
        let none = Geometry.scrollColumn(in: CGRect(x: 0, y: 0, width: 60, height: 700), division: CGRect(x: 2, y: 0, width: 56, height: 700))
        XCTAssertEqual(none.width, 0)
    }

    // MARK: Right to left

    func testRightToLeftMirrorsTheSpreadButNotItsGeometry() {
        for (width, height, division) in [(1100.0, 820.0, nil), (600.0, 900.0, nil), (951.0, 669.0, CGRect(x: 455, y: 0, width: 41, height: 669)),
                                          (891.0, 669.0, CGRect(x: 395, y: 0, width: 41, height: 669)),
                                          (571.0, 669.0, CGRect(x: 455, y: 0, width: 41, height: 669))] as [(CGFloat, CGFloat, CGRect?)] {
            let ltr = spread(width, height, division: division), rtl = spread(width, height, division: division, rtl: true)
            XCTAssertEqual(rtl.columns, ltr.columns.reversed(), "\(width)")
            XCTAssertEqual(rtl.columnSize, ltr.columnSize)
            if rtl.columns.count == 2 { XCTAssertGreaterThan(rtl.columns[0].minX, rtl.columns[1].maxX, "the first slice is on the right") }
        }
    }
}

/// Wheel and trackpad page turns, and swipes (doc/native-viewer.md "Input and accessibility").
final class ViewCoverageInputTests: XCTestCase {
    func testAGestureTurnsOnItsAccumulatedTravelAndStartsAfresh() {
        var turner = ReaderWheelPageTurner()
        XCTAssertNil(turner.direction(deltaX: 0, deltaY: 3, phase: .began, isRightToLeft: false, at: 0))
        XCTAssertNil(turner.direction(deltaX: 0, deltaY: 0, phase: .ended, isRightToLeft: false, at: 0.1))
        XCTAssertNil(turner.direction(deltaX: 0, deltaY: 3, phase: .began, isRightToLeft: false, at: 0.2),
                     "a gesture that ended short of the threshold leaves no travel behind")
        XCTAssertNil(turner.direction(deltaX: 0, deltaY: -5, phase: .changed, isRightToLeft: false, at: 0.3), "back to 2 points the other way")
        XCTAssertEqual(turner.direction(deltaX: 0, deltaY: -2.5, phase: .changed, isRightToLeft: false, at: 0.4), false)
        XCTAssertNil(turner.direction(deltaX: 0, deltaY: 3, phase: .began, isRightToLeft: false, at: 0.5), "a new gesture begins at zero")
        XCTAssertEqual(turner.direction(deltaX: 0, deltaY: 1, phase: .changed, isRightToLeft: false, at: 0.5), true,
                       "and is not held back by the wheel cooldown")
    }

    func testAPhaselessWheelWaitsOutTheCooldownAfterAnyTurn() {
        var turner = ReaderWheelPageTurner()
        XCTAssertEqual(ReaderWheelPageTurner.threshold, 4)
        XCTAssertEqual(ReaderWheelPageTurner.cooldown, 0.45)
        XCTAssertEqual(turner.direction(deltaX: 0, deltaY: -4, isRightToLeft: false, at: 10), false, "exactly the threshold")
        XCTAssertNil(turner.direction(deltaX: 0, deltaY: -4, isRightToLeft: false, at: 10.44))
        XCTAssertEqual(turner.direction(deltaX: 0, deltaY: -4, isRightToLeft: false, at: 10.45 + 1e-9), false)
        // A trackpad gesture's turn also starts the cooldown for a wheel tick that follows it.
        XCTAssertEqual(turner.direction(deltaX: 0, deltaY: 9, phase: .began, isRightToLeft: false, at: 20), true)
        XCTAssertNil(turner.direction(deltaX: 0, deltaY: 9, isRightToLeft: false, at: 20.2))
        XCTAssertEqual(turner.direction(deltaX: 0, deltaY: 9, isRightToLeft: false, at: 20.5), true)
        XCTAssertNil(turner.direction(deltaX: 0, deltaY: 0, isRightToLeft: false, at: 30), "no movement, no turn")
        XCTAssertNil(turner.direction(deltaX: .nan, deltaY: .nan, isRightToLeft: false, at: 31))
    }

    func testOnlyHorizontalWheelMovementMirrorsRightToLeft() {
        for rtl in [false, true] {
            var turner = ReaderWheelPageTurner()
            XCTAssertEqual(turner.direction(deltaX: 9, deltaY: 0, isRightToLeft: rtl, at: 0), !rtl, "scrolling right")
            XCTAssertEqual(turner.direction(deltaX: -9, deltaY: 0, isRightToLeft: rtl, at: 1), rtl, "scrolling left")
            XCTAssertEqual(turner.direction(deltaX: 0, deltaY: 9, isRightToLeft: rtl, at: 2), true, "down is forward")
            XCTAssertEqual(turner.direction(deltaX: 0, deltaY: -9, isRightToLeft: rtl, at: 3), false, "up is back")
            XCTAssertEqual(turner.direction(deltaX: 9, deltaY: 9, isRightToLeft: rtl, at: 4), true, "a diagonal counts as vertical")
            XCTAssertEqual(turner.direction(deltaX: -9, deltaY: 9, isRightToLeft: rtl, at: 5), true)
            XCTAssertEqual(turner.direction(deltaX: 30, deltaY: 2, phase: .began, isRightToLeft: rtl, at: 6), !rtl)
        }
    }
}

/// The whole book's string and its section positions (`ReaderBookText`).
final class ViewCoverageBookTextTests: XCTestCase {
    /// The book as the session builds it: one separator between each two included sections.
    private func book(_ sections: [String], omitting: Set<Int> = []) -> ReaderBookText {
        let string = NSMutableAttributedString()
        var starts = Array(repeating: 0, count: sections.count), included = 0
        for (index, section) in sections.enumerated() where !omitting.contains(index) {
            if included > 0 { string.append(NSAttributedString(string: "\n")) }
            included += 1
            starts[index] = string.length
            string.append(NSAttributedString(string: section))
        }
        var next = string.length
        for index in starts.indices.reversed() {
            if omitting.contains(index) { starts[index] = next } else { next = starts[index] }
        }
        return ReaderBookText(string: string, sectionStarts: starts, omitted: omitting)
    }

    func testEveryPositionOfEveryIncludedSectionRoundTrips() {
        let shapes: [([String], Set<Int>)] = [
            (["abc", "", "xyz"], []), (["", "abc"], []), (["abc", ""], []), (["", "", ""], []), (["a"], []),
            (["omit", "abc", "xyz"], [0]), (["abc", "omit", "xyz"], [1]), (["abc", "xyz", "omit"], [2]),
            (["o", "o", "abc", "o", "", "o", "xyz", "o", "o"], [0, 1, 3, 5, 7, 8]), (["abc", "o", "o", "", "o"], [1, 2, 4]),
            (["\u{1F600}x", "e\u{301}"], []),
        ]
        for (sections, omitted) in shapes {
            let book = book(sections, omitting: omitted)
            let included = sections.indices.filter { !omitted.contains($0) }
            XCTAssertEqual(book.string.length, included.map { sections[$0].utf16.count }.reduce(0, +) + max(0, included.count - 1))
            for index in sections.indices {
                XCTAssertEqual(book.contains(section: index), !omitted.contains(index))
                guard !omitted.contains(index) else { continue }
                for offset in 0...sections[index].utf16.count {
                    let position = ReaderTextPosition(section: index, offset: offset)
                    let location = book.location(of: position)
                    XCTAssertEqual(book.position(at: location), position, "\(sections) omitting \(omitted)")
                    if offset < sections[index].utf16.count {
                        XCTAssertEqual((book.string.string as NSString).character(at: location),
                                       (sections[index] as NSString).character(at: offset))
                    }
                }
            }
        }
    }

    func testLocationsOutsideTheBookClampToItsEnds() {
        let book = book(["abc", "omit", "xyz"], omitting: [1])
        XCTAssertEqual(book.position(at: -5), ReaderTextPosition(section: 0, offset: 0))
        XCTAssertEqual(book.position(at: 1_000), ReaderTextPosition(section: 2, offset: 3))
        XCTAssertEqual(book.location(of: ReaderTextPosition(section: 2, offset: 1_000)), 7, "an offset past a rebuilt section's end")
        XCTAssertFalse(book.contains(section: -1))
        XCTAssertFalse(book.contains(section: 3))
        XCTAssertEqual(book.position(at: 3), ReaderTextPosition(section: 0, offset: 3), "the separator is the end of the section before it")
        XCTAssertEqual(book.position(at: 4), ReaderTextPosition(section: 2, offset: 0))
    }
}
