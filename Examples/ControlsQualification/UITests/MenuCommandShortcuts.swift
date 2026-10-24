import XCTest
import XCUIAutomation

/// The menu bar's reader commands from an iPad's hardware keyboard (issue 697): each shortcut is
/// typed with `XCUIElement.typeKey`, through UIKit's own keyboard dispatch and the app's menu,
/// and its effect is read from the host's status line. See "Menu bar commands" in
/// doc/testing.md for the run and for what the simulator cannot type.
@MainActor final class MenuCommandShortcuts: XCTestCase {
    private var app: XCUIApplication!

    func testShortcutsActOnTheReaderInFront() throws {
        #if os(iOS)
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "org.epubreaderlib.controlsqualification")
        app.launchArguments = ["-QualificationBook", "ltr"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.descendants(matching: .any)["qualification.status"].waitForExistence(timeout: 60))
        expect("layout page 1/", "the book is open on its first page")
        // UIKit builds the app's main menu when the first key comes, and that key reached no item:
        // a first Command-+ changed nothing, and a second, typed after it, took Larger Text. The
        // first key here is Command-0, Actual Size, dimmed at the default size.
        app.typeKey("0", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        expect("| 17 pt |", "Actual Size, dimmed at the default size")

        // Larger Text, Smaller Text and Actual Size.
        app.typeKey("+", modifierFlags: .command)
        expect("| 19 pt |", "Command-+ is Larger Text")
        app.typeKey("=", modifierFlags: .command)
        expect("| 21 pt |", "Command-= is Larger Text too")
        app.typeKey("-", modifierFlags: .command)
        expect("| 19 pt |", "Command-- is Smaller Text")
        app.typeKey("0", modifierFlags: .command)
        expect("| 17 pt |", "Command-0 is Actual Size")

        // The reading modes.
        app.typeKey("1", modifierFlags: .command)
        expect("| scrolled |", "Command-1 is Continuous Scroll")
        app.typeKey("2", modifierFlags: .command)
        expect("| paginated |", "Command-2 is Paging")

        // Find opens the search pane with focus in its field, where the query is typed. Find Next
        // and Find Previous then step through the matches, with nothing in focus.
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["Search in book"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Command-F opens the search pane")
        expectTrue("the pane's field to have keyboard focus") { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        app.typeText("lantern\n")
        expect("searched lantern: matches | 1/14", "the typed search shows its first match")
        app.typeKey("g", modifierFlags: .command)
        expect("| 2/14 |", "Command-G is Find Next")
        app.typeKey("g", modifierFlags: [.command, .shift])
        expect("| 1/14 |", "Shift-Command-G is Find Previous")
        #else
        throw XCTSkip("On the Mac this would take the pointer and keyboard; doc/testing.md has the Mac's check")
        #endif
    }

    private func statusLine() -> String {
        let status = app.descendants(matching: .any)["qualification.status"]
        return status.label.isEmpty ? "\(status.value ?? "")" : status.label
    }

    /// Waits up to ten seconds for the status line to contain `text`.
    private func expect(_ text: String, _ what: String) {
        expectTrue("\(what): \"\(text)\"") { statusLine().contains(text) }
    }

    private func expectTrue(_ what: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(what). Status: \(statusLine())") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
}
