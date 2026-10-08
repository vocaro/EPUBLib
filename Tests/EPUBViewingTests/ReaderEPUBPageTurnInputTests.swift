#if DEBUG
import XCTest
@testable import EPUBViewing

final class ReaderEPUBPageTurnInputTests: XCTestCase {

    func testArrowKeysMapToTheAdjacentPageTurnDirection() {
        XCTAssertEqual(
            ReaderEPUBPageTurnKey.command(forKeyCode: 123, hasShift: false), .previous, "Left")
        XCTAssertEqual(
            ReaderEPUBPageTurnKey.command(forKeyCode: 124, hasShift: false), .next, "Right")
    }

    func testPageUpAndPageDownMapToTheAdjacentPageTurnDirection() {
        XCTAssertEqual(
            ReaderEPUBPageTurnKey.command(forKeyCode: 116, hasShift: false), .previous, "Page Up")
        XCTAssertEqual(
            ReaderEPUBPageTurnKey.command(forKeyCode: 121, hasShift: false), .next, "Page Down")
    }

    func testSpaceTurnsForwardAndShiftSpaceTurnsBackward() {
        XCTAssertEqual(ReaderEPUBPageTurnKey.command(forKeyCode: 49, hasShift: false), .next)
        XCTAssertEqual(ReaderEPUBPageTurnKey.command(forKeyCode: 49, hasShift: true), .previous)
    }

    func testAnUnboundKeyMapsToNoCommand() {
        for keyCode: UInt16 in [0, 1, 36, 51, 53, 125, 126] {
            XCTAssertNil(
                ReaderEPUBPageTurnKey.command(forKeyCode: keyCode, hasShift: false),
                "key code \(keyCode) should not be a page-turn binding")
        }
    }

    func testTheSwiftUIKeyMappingAgreesWithTheKeyDownFallbackMapping() {
        XCTAssertEqual(ReaderEPUBPageTurnKey.command(for: .leftArrow, hasShift: false), .previous)
        XCTAssertEqual(ReaderEPUBPageTurnKey.command(for: .rightArrow, hasShift: false), .next)
        XCTAssertEqual(ReaderEPUBPageTurnKey.command(for: .pageUp, hasShift: false), .previous)
        XCTAssertEqual(ReaderEPUBPageTurnKey.command(for: .pageDown, hasShift: false), .next)
        XCTAssertEqual(ReaderEPUBPageTurnKey.command(for: .space, hasShift: false), .next)
        XCTAssertEqual(ReaderEPUBPageTurnKey.command(for: .space, hasShift: true), .previous)
        XCTAssertNil(ReaderEPUBPageTurnKey.command(for: .escape, hasShift: false))
    }
}
#endif
