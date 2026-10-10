import XCTest
@testable import EPUBViewing

final class ReaderEPUBPageTurnInputTests: XCTestCase {
    func testDefaultsAndHostOnly() {
        let controls = EPUBPageControls()
        XCTAssertTrue(controls.edgeTapsEnabled)
        XCTAssertTrue(controls.touchSwipesEnabled)
        XCTAssertTrue(controls.wheelEnabled)
        XCTAssertEqual(controls.leftTapWidth, 56)
        XCTAssertEqual(controls.rightTapWidth, 56)
        for key: EPUBPageKey in [.leftArrow, .pageUp] {
            XCTAssertEqual(controls.direction(for: key, modifiers: []), false)
        }
        for key: EPUBPageKey in [.rightArrow, .pageDown, .space] {
            XCTAssertEqual(controls.direction(for: key, modifiers: []), true)
        }
        XCTAssertEqual(controls.direction(for: .space, modifiers: .shift), false)
        XCTAssertFalse(EPUBPageControls.hostOnly.edgeTapsEnabled)
        XCTAssertFalse(EPUBPageControls.hostOnly.touchSwipesEnabled)
        XCTAssertFalse(EPUBPageControls.hostOnly.wheelEnabled)
        XCTAssertTrue(EPUBPageControls.hostOnly.effectiveBindings.isEmpty)
    }

    func testDefaultBindingsLeaveSelectionAndSystemChords() {
        let controls = EPUBPageControls()
        XCTAssertNil(controls.direction(for: .rightArrow, modifiers: .shift))
        XCTAssertNil(controls.direction(for: .character("a"), modifiers: .command))
        XCTAssertNil(controls.direction(for: .character("c"), modifiers: .command))
        for modifier: EPUBPageKeyModifiers in [.command, .control, .option, [.shift, .command]] {
            XCTAssertNil(controls.direction(for: .space, modifiers: modifier))
            XCTAssertNil(controls.direction(for: .pageDown, modifiers: modifier))
        }
    }

    func testReplacementBindingsMatchExactModifiersAndNormalizeLetters() {
        let controls = EPUBPageControls(keyboardBindings: [
            .init(.character("N"), modifiers: [.command, .shift], action: .next),
            .init(.leftArrow, modifiers: .option, action: .next),
            .init(.character("p"), modifiers: .control, action: .previous),
        ])
        XCTAssertEqual(controls.direction(for: .character("n"), modifiers: [.shift, .command]), true)
        XCTAssertNil(controls.direction(for: .character("n"), modifiers: .command))
        XCTAssertNil(controls.direction(for: .rightArrow, modifiers: []), "removed default")
        XCTAssertEqual(controls.direction(for: .leftArrow, modifiers: .option), true)
        XCTAssertEqual(controls.direction(for: .character("P"), modifiers: .control), false)
        XCTAssertNil(EPUBPageControls(keyboardBindings: []).direction(for: .space, modifiers: []))
    }

    func testDuplicatesInvalidCharactersAndUnsupportedModifiers() {
        let controls = EPUBPageControls(keyboardBindings: [
            .init(.character("n"), action: .previous), .init(.character("N"), action: .next),
            .init(.character("!"), action: .next), .init(.character("é"), action: .next),
            .init(.space, modifiers: .init(rawValue: 128), action: .next),
            .init(.character("3"), action: .next),
        ])
        XCTAssertEqual(controls.effectiveBindings.count, 2)
        XCTAssertEqual(controls.direction(for: .character("N"), modifiers: []), false, "first duplicate wins")
        XCTAssertEqual(controls.direction(for: .character("3"), modifiers: []), true)
        XCTAssertNil(controls.direction(for: .character("!"), modifiers: []))
    }
}
