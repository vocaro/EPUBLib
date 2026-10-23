import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The supplied controls as mounted views, where the platform makes them readable without an
/// assistive-technology session ([#51](https://github.com/vocaro/EPUBLib/issues/51)): the
/// platform controls SwiftUI builds for the reading-mode picker and the search field. Buttons
/// and menus that SwiftUI draws itself expose nothing to a test; their names, capabilities and
/// disabled states are checked in the model they read, here and in `ReaderControlsTests`.
@MainActor final class ReaderControlViewTests: XCTestCase {
    private final class Session: EPUBReaderSession {
        let capabilities: Set<EPUBReaderCapability>
        let readerState: EPUBReaderState?
        var received: [EPUBReaderCommand] = []
        init(_ capabilities: Set<EPUBReaderCapability> = [.pagination, .scrolling, .typography, .search, .navigateHref]) {
            self.capabilities = capabilities
            let state = EPUBReaderState(status: .init(capabilities: capabilities))
            state.modify { $0.lifecycle = .ready }
            readerState = state
        }
        func makeView() -> AnyView { AnyView(EmptyView()) }
        func send(_ command: EPUBReaderCommand) async throws {
            received.append(command)
            if case .style(let style) = command { readerState?.modify { $0.style = style } }
        }
        func close() { readerState?.modify { $0.lifecycle = .closed } }
    }

    /// SwiftUI content in a real window.
    @MainActor private final class Host {
        #if os(macOS)
        let window: NSWindow
        private let hosting: NSHostingView<AnyView>
        var root: NSView { hosting }
        #else
        let window: UIWindow
        private let hosting: UIHostingController<AnyView>
        var root: UIView { hosting.view }
        #endif

        init(_ content: some View, size: CGSize = CGSize(width: 600, height: 700)) {
            #if os(macOS)
            window = makeMacTestWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.keepLightAppearance()
            hosting = NSHostingView(rootView: AnyView(content))
            window.contentView = hosting
            window.orderFront(nil)
            #else
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window = UIWindow(windowScene: scene)
            } else { window = UIWindow(frame: CGRect(origin: .zero, size: size)) }
            window.keepLightAppearance()
            window.frame = CGRect(origin: .zero, size: size)
            hosting = UIHostingController(rootView: AnyView(content))
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            #endif
        }

        func show(_ content: some View) { hosting.rootView = AnyView(content) }

        func layOut() {
            #if os(macOS)
            hosting.layoutSubtreeIfNeeded()
            #else
            window.layoutIfNeeded()
            #endif
        }

        /// The mounted platform views of one type, in view order.
        func views<T>(_ type: T.Type) -> [T] {
            func collect(_ view: PlatformView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(collect) }
            layOut()
            return collect(root)
        }

        /// The first such view once SwiftUI has mounted it; nil when it never does.
        func find<T>(_ type: T.Type, where matches: (T) -> Bool = { _ in true }) async throws -> T? {
            for _ in 0..<150 {
                if let found = views(type).first(where: matches) { return found }
                try await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }

        func view<T>(_ type: T.Type, _ label: String, where matches: (T) -> Bool = { _ in true }) async throws -> T {
            let found = try await find(type, where: matches)
            return try XCTUnwrap(found, "\(label) is not mounted")
        }

        func close() {
            #if os(macOS)
            window.close()
            window.contentView = nil
            #else
            window.isHidden = true
            window.rootViewController = nil
            #endif
        }
    }

    private func wait(_ label: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func controls(_ session: Session) throws -> EPUBReaderControls {
        EPUBReaderControls(publication: try EPUBPublication.open(data: Fixture.epub()), session: session)
    }

    // MARK: Page buttons

    /// The names and disabled states the page buttons read from the model: short, logical in a
    /// right-to-left book, and off whenever a turn cannot be made.
    func testPageButtonNamesAndDisabledStatesAcrossFlowsDirectionsAndCapabilities() throws {
        for rightToLeft in [false, true] {
            let publication = try EPUBPublication.open(data: rightToLeft ? Fixture.rendering(.rightToLeft) : Fixture.epub())
            for flow in [EPUBReadingFlow.paginated, .scrolled] {
                let label = "\(flow)\(rightToLeft ? " right to left" : "")"
                let session = Session()
                let model = EPUBReaderControls(publication: publication, session: session)
                session.readerState?.modify { $0.style.flow = flow }
                XCTAssertEqual(model.isRightToLeft, rightToLeft)
                let names = [EPUBPageAction.previous, .next].map { model.pageButtonLabel(for: $0) }
                XCTAssertEqual(names, flow == .paginated ? ["Previous Page", "Next Page"] : ["Scroll Backward", "Scroll Forward"], label)
                for (action, name) in zip([EPUBPageAction.previous, .next], names) {
                    XCTAssertEqual(name.split(separator: " ").count, 2, "\(label): a name is two words; its help carries the rest")
                    XCTAssertTrue(model.pageButtonHelp(for: action).hasPrefix(name + "."), label)
                }

                // Unknown boundaries leave a turn to the engine; a known one disables its button.
                XCTAssertTrue(model.canGoPrevious && model.canGoNext, label)
                session.readerState?.modify { $0.canGoPrevious = false; $0.canGoNext = true }
                XCTAssertEqual([model.canGoPrevious, model.canGoNext], [false, true], "\(label): at the book's start")
                session.readerState?.modify { $0.canGoPrevious = true; $0.canGoNext = false }
                XCTAssertEqual([model.canGoPrevious, model.canGoNext], [true, false], "\(label): at the book's end")

                // Nothing turns before the reader is ready, once it has failed, or after it closes.
                session.readerState?.modify { $0.canGoPrevious = nil; $0.canGoNext = nil }
                for lifecycle in [EPUBReaderLifecycle.loading, .failed(.engineFailure("failed")), .closed] {
                    session.readerState?.modify { $0.lifecycle = lifecycle }
                    XCTAssertFalse(model.isReady, "\(label) \(lifecycle)")
                    XCTAssertEqual([model.canGoPrevious, model.canGoNext], [false, false], "\(label) \(lifecycle)")
                }
            }

            // An engine that offers only one flow turns in that flow alone; one with neither never.
            let subsets: [(Set<EPUBReaderCapability>, EPUBReadingFlow, Bool)] = [
                ([.pagination], .paginated, true), ([.pagination], .scrolled, false),
                ([.scrolling], .scrolled, true), ([.scrolling], .paginated, false),
                ([.typography, .search], .paginated, false),
            ]
            for (capabilities, flow, turns) in subsets {
                let session = Session(capabilities)
                let model = EPUBReaderControls(publication: publication, session: session)
                session.readerState?.modify { $0.style.flow = flow }
                XCTAssertEqual([model.canGoPrevious, model.canGoNext], [turns, turns], "\(capabilities) \(flow)")
                XCTAssertEqual(model.supports(.search), capabilities.contains(.search))
                XCTAssertFalse(model.supports(.navigateHref), "a capability the engine lacks hides its control")
            }
        }
    }

    // MARK: Reading mode

    #if os(macOS)
    private typealias Segmented = NSSegmentedControl
    #else
    private typealias Segmented = UISegmentedControl
    #endif

    /// Which segment is selected: the picker's current value.
    private func selection(_ control: Segmented) -> [Bool] {
        #if os(macOS)
        (0..<control.segmentCount).map { control.isSelected(forSegment: $0) }
        #else
        (0..<control.numberOfSegments).map { control.selectedSegmentIndex == $0 }
        #endif
    }

    #if os(macOS)
    /// Each segment's accessible name and value, as AppKit gives them to assistive technology.
    private func radioButtons(_ control: NSSegmentedControl) -> [(name: String?, selected: Bool)] {
        var result: [(String?, Bool)] = []
        for child in control.accessibilityChildren() ?? [] {
            guard let group = child as? NSAccessibilityProtocol else { continue }
            for item in group.accessibilityChildren() ?? [] {
                guard let segment = item as? NSAccessibilityProtocol, segment.accessibilityRole() == .radioButton else { continue }
                result.append((segment.accessibilityLabel(), (segment.accessibilityValue() as? NSNumber)?.boolValue == true))
            }
        }
        return result
    }
    #endif

    func testReadingModePickerFollowsTheFlowAndTheReadersLifecycle() async throws {
        let session = Session(), model = try controls(session)
        let host = Host(EPUBReaderControl(controls: model, group: .readingMode))
        defer { host.close() }
        let control = try await host.view(Segmented.self, "the reading-mode segmented control")
        XCTAssertEqual(selection(control), [false, true], "Continuous Scroll, then Paging, which is current when paginated")
        XCTAssertTrue(control.isEnabled)

        // The picker follows a flow the host or another control set.
        session.readerState?.modify { $0.style.flow = .scrolled }
        try await wait("the scrolled selection") { self.selection(control) == [true, false] }
        session.readerState?.modify { $0.style.flow = .paginated }
        try await wait("the paginated selection") { self.selection(control) == [false, true] }

        // Until the reader is ready, and after it closes, the picker is disabled.
        session.readerState?.modify { $0.lifecycle = .loading }
        try await wait("the disabled picker") { !control.isEnabled }
        session.readerState?.modify { $0.lifecycle = .ready }
        try await wait("the enabled picker") { control.isEnabled }
        session.close()
        try await wait("the closed picker") { !control.isEnabled }
    }

    #if os(macOS)
    /// On Mac the picker is an `NSSegmentedControl` whose segments are radio buttons. SwiftUI
    /// builds the iPhone and iPad one itself and exposes neither names nor actions to a test.
    func testReadingModeSegmentsAreNamedForTheirModesAndSubmitThem() async throws {
        let session = Session(), model = try controls(session)
        let host = Host(EPUBReaderControl(controls: model, group: .readingMode))
        defer { host.close() }
        let control = try await host.view(NSSegmentedControl.self, "the reading-mode segmented control")
        XCTAssertEqual(radioButtons(control).map(\.name), ["Continuous Scroll", "Paging"],
                       "each segment is named for its mode, not for its icon")
        XCTAssertEqual(radioButtons(control).map(\.selected), [false, true], "the current mode is the selected radio button")
        XCTAssertEqual((0..<control.segmentCount).map { control.toolTip(forSegment: $0) }, ["Continuous Scroll", "Paging"])

        // Choosing a segment submits that flow, keeping the rest of the style.
        session.readerState?.modify { $0.style.fontSize = 21 }
        control.selectedSegment = 0
        _ = control.sendAction(control.action, to: control.target)
        try await wait("the submitted flow") { !session.received.isEmpty }
        await model.waitForCommands()
        XCTAssertEqual(session.received, [.style(.init(fontSize: 21, flow: .scrolled))])
        try await wait("the scrolled selection") { self.radioButtons(control).map(\.selected) == [true, false] }

        // Naming the segments leaves the control the size plain symbol labels give it.
        let plain = Host(Picker("Reading Mode", selection: .constant(EPUBReadingFlow.paginated)) {
            Label("Continuous Scroll", systemImage: "scroll").tag(EPUBReadingFlow.scrolled)
            Label("Paging", systemImage: "doc.text").tag(EPUBReadingFlow.paginated)
        }.pickerStyle(.segmented).labelsHidden().labelStyle(.iconOnly).fixedSize(horizontal: true, vertical: false))
        defer { plain.close() }
        let reference = try await plain.view(NSSegmentedControl.self, "a plain segmented control")
        func geometry(_ control: NSSegmentedControl) -> [CGSize] {
            [control.frame.size] + (0..<control.segmentCount).map { control.image(forSegment: $0)?.size ?? .zero }
        }
        XCTAssertEqual(geometry(control), geometry(reference))
    }
    #endif

    func testReadingModeIsOfferedOnlyWhenBothFlowsAre() async throws {
        for capabilities: Set<EPUBReaderCapability> in [[.pagination, .typography], [.scrolling, .typography], [.typography]] {
            let session = Session(capabilities), model = try controls(session)
            let host = Host(EPUBReaderControlStrip(controls: model))
            defer { host.close() }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(host.views(Segmented.self).isEmpty, "\(capabilities)")
        }
        let session = Session(), model = try controls(session)
        let host = Host(EPUBReaderControlStrip(controls: model))
        defer { host.close() }
        _ = try await host.view(Segmented.self, "the strip's picker when both flows are supported")
    }

    // MARK: Text size

    func testTextSizeStepsStayWithinSizesTheBundledReaderDraws() {
        XCTAssertEqual(CGFloat(EPUBReaderControl.textSizes.lowerBound), NativeTypography.minimumFontSize)
        XCTAssertEqual(CGFloat(EPUBReaderControl.textSizes.upperBound), NativeTypography.maximumFontSize,
                       "the controls reach the largest size the reader draws (#675)")
        // Two points at a time to 36, then larger steps to 96, and back through the same sizes.
        let ladder = [12.0, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 40, 44, 48, 56, 64, 72, 80, 88, 96]
        var up = [12.0]
        while let next = EPUBReaderControl.textSize(up.last!, larger: true, scale: 1) { up.append(next) }
        XCTAssertEqual(up, ladder)
        var down = [96.0]
        while let next = EPUBReaderControl.textSize(down.last!, larger: false, scale: 1) { down.append(next) }
        XCTAssertEqual(down, ladder.reversed())
        // Every step the control leaves enabled changes the size the reader draws, at every
        // system text size, and moves the way the control says, until one end is drawn.
        for textSize in DynamicTypeSize.allCases {
            let scale = Double(NativeTypography.dynamicTypeScale(for: textSize))
            for larger in [false, true] {
                var size = EPUBReaderStyle().fontSize
                var steps = 0
                while let next = EPUBReaderControl.textSize(size, larger: larger, scale: scale) {
                    XCTAssertEqual(larger, next > size, "\(textSize): a step from \(size) to \(next)")
                    XCTAssertNotEqual(NativeTypography(fontSize: next * scale).fontSize, NativeTypography(fontSize: size * scale).fontSize,
                                      "\(textSize): a step from \(size) to \(next) draws no differently")
                    size = next
                    steps += 1
                }
                let drawn = NativeTypography(fontSize: size * scale).fontSize
                XCTAssertTrue(drawn == (larger ? 96 : 12) || size == (larger ? 96 : 12),
                              "\(textSize): the steps ended at \(size), drawn at \(drawn)")
                XCTAssertGreaterThan(steps, 0, "\(textSize)")
            }
        }
        // From the default size Larger Text reaches 96, not the 36 it stopped at before.
        var size = EPUBReaderStyle().fontSize
        while let next = EPUBReaderControl.textSize(size, larger: true, scale: 1) { size = next }
        XCTAssertEqual(size, 96)
        // A size a host set outside the range steps from what is drawn, never by a dead press,
        // and one off the ladder goes to the next size on it.
        XCTAssertEqual(EPUBReaderControl.textSize(10, larger: true, scale: 1), 14)
        XCTAssertNil(EPUBReaderControl.textSize(10, larger: false, scale: 1), "10 and 12 are both drawn at 12")
        XCTAssertEqual(EPUBReaderControl.textSize(120, larger: false, scale: 1), 88)
        XCTAssertNil(EPUBReaderControl.textSize(120, larger: true, scale: 1))
        XCTAssertEqual(EPUBReaderControl.textSize(46, larger: true, scale: 1), 48)
        XCTAssertEqual(EPUBReaderControl.textSize(38, larger: false, scale: 1), 36)
        XCTAssertEqual(EPUBReaderControl.textSize(17, larger: true, scale: 1), 19)
        // At the largest accessibility size, 53 points for 17, several chosen sizes are drawn at
        // 96: Smaller Text passes over them, and Larger Text is off once 96 is drawn.
        let largest = 53.0 / 17
        XCTAssertNil(EPUBReaderControl.textSize(32, larger: true, scale: largest))
        XCTAssertEqual(EPUBReaderControl.textSize(36, larger: false, scale: largest), 30)
        XCTAssertEqual(EPUBReaderControl.textSize(17, larger: true, scale: largest), 19)
        XCTAssertEqual(EPUBReaderControl.textSizeDescription(59.235), "59 points")
    }

    // MARK: Search field

    private struct SearchingReader: View {
        let model: EPUBReaderControls
        let searching: Bool
        var body: some View {
            VStack {
                EPUBReaderView(session: model.session)
                if searching { EPUBReaderControl(controls: model, group: .search, inlineSearch: true) }
            }
        }
    }

    private func openReader() async throws -> (NativeSession, EPUBReaderControls, Host) {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
        let model = EPUBReaderControls(publication: publication, session: session)
        let host = Host(SearchingReader(model: model, searching: true))
        try await wait("the reader") { session.isReady && session.book.isComplete && session.visibleRange != nil }
        return (session, model, host)
    }

    #if os(macOS)
    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// The supplied field beside a real reader: typing edits the query and nothing else, Return
    /// submits it, taking the field away leaves the search as it was, and only Clear ends it.
    func testSearchFieldEditsSubmitsAndOutlivesItsPane() async throws {
        let (session, model, host) = try await openReader()
        defer { session.close(); host.close() }
        let canvas = try XCTUnwrap(session.canvas)
        let state = try XCTUnwrap(session.readerState)
        let field = try await host.view(NSTextField.self, "the search field") { $0.isEditable }
        XCTAssertTrue(host.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertFalse(canvas.hasKeyboardFocus)
        let opening = try XCTUnwrap(session.visibleRange)

        // Typing, Space included, changes the query alone.
        editor.insertText("unique", replacementRange: editor.selectedRange())
        editor.keyDown(with: try key(49, " ", in: host.window))
        editor.insertText("destination", replacementRange: editor.selectedRange())
        try await wait("the typed query") { model.searchText == "unique destination" }
        XCTAssertEqual(state.status.search, .idle, "typing does not search")
        XCTAssertEqual(model.pendingCommands, 0)
        XCTAssertEqual(session.visibleRange, opening)

        // No default page key reaches the reader from the field, whatever it does there.
        let pageKeys: [(UInt16, String, NSEvent.ModifierFlags)] = [
            (49, " ", []), (49, " ", .shift), (123, "\u{F702}", []), (124, "\u{F703}", []),
            (116, "\u{F72C}", []), (121, "\u{F72D}", []),
        ]
        for (code, characters, flags) in pageKeys {
            let event = try key(code, characters, flags, in: host.window)
            XCTAssertNotNil(ReaderTextView.pageTurnDirection(for: event), "key \(code) turns pages with reader focus")
            XCTAssertFalse(canvas.handlePageKeyEquivalent(event), "key \(code)")
            XCTAssertFalse(host.root.performKeyEquivalent(with: event), "key \(code)")
            XCTAssertEqual(session.visibleRange, opening, "key \(code)")
        }
        XCTAssertEqual(model.searchText, "unique destination")

        // Return submits what was typed and opens its match in the second chapter.
        editor.keyDown(with: try key(36, "\r", in: host.window))
        try await wait("the submitted search") { state.status.search == .completed(query: "unique destination", hasMatches: true) }
        // On a Mac the field goes on being edited after Return (issue 330 changes iPhone and iPad alone).
        let kept = try XCTUnwrap(field.currentEditor(), "Return leaves the field being edited")
        XCTAssertTrue(host.window.firstResponder === kept)
        await model.waitForCommands()
        try await wait("the match") { session.visibleRange?.start.section == 1 }
        let highlights = Set(session.drawnHighlights)
        XCTAssertEqual(highlights.filter { $0.kind == .search }.count, 1)
        let found = try XCTUnwrap(session.visibleRange?.start)

        // Closing the pane takes the field away and nothing else: the page only gains its room.
        host.show(SearchingReader(model: model, searching: false))
        try await wait("the removed field") { host.views(NSTextField.self).filter(\.isEditable).isEmpty }
        XCTAssertEqual(model.searchText, "unique destination")
        XCTAssertEqual(state.status.search, .completed(query: "unique destination", hasMatches: true))
        XCTAssertEqual(Set(session.drawnHighlights), highlights)
        XCTAssertEqual(session.visibleRange?.start, found)
        XCTAssertEqual(model.pendingCommands, 0)

        // Reopened, it shows the query still in effect; Clear empties it and ends the search.
        host.show(SearchingReader(model: model, searching: true))
        let reopened = try await host.view(NSTextField.self, "the reopened search field") { $0.isEditable }
        try await wait("the kept query") { reopened.stringValue == "unique destination" }
        model.clearSearch()
        await model.waitForCommands()
        try await wait("the emptied field") { reopened.stringValue.isEmpty }
        XCTAssertEqual(state.status.search, .idle)
        XCTAssertTrue(session.drawnHighlights.isEmpty)
        XCTAssertEqual(session.visibleRange?.start, found, "clearing does not move the reader")
    }
    #else
    /// The strip's search field is always on screen. Taking focus as it appears would raise the
    /// keyboard over the book as soon as it opens, and start VoiceOver in an editing field.
    func testInlineSearchFieldLeavesFocusAloneWhenItAppears() async throws {
        let model = try controls(Session())
        let host = Host(EPUBReaderControlStrip(controls: model, groups: [.pages, .search]))
        defer { host.close() }
        let field = try await host.view(UITextField.self, "the inline search field")
        for _ in 0..<25 where !field.isFirstResponder { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(field.isFirstResponder)
    }

    /// A hardware key reaches the reader's page commands only through its own responders. The
    /// search field beside it is not among them, so Space and the arrows stay editing keys.
    func testSearchFieldIsOutsideTheReadersPageKeyCommands() async throws {
        let (session, _, host) = try await openReader()
        defer { session.close(); host.close() }
        let canvas = try XCTUnwrap(session.canvas)
        let action = #selector(ReaderCanvasView.pageTurnKeyCommand(_:))
        XCTAssertFalse(canvas.pageKeyCommands.isEmpty, "the reader itself offers page keys")
        XCTAssertTrue(canvas.textViews.allSatisfy { ($0.keyCommands ?? []).contains { $0.action == action } })
        let field = try await host.view(UITextField.self, "the search field")
        var responder: UIResponder? = field
        var length = 0
        while let current = responder {
            XCTAssertFalse(current is ReaderCanvasView || current is ReaderTextView, "\(type(of: current)) is in the field's responder chain")
            XCTAssertFalse((current.keyCommands ?? []).contains { $0.action == action }, "\(type(of: current)) offers page keys to the field")
            responder = current.next
            length += 1
        }
        XCTAssertGreaterThan(length, 1)
        XCTAssertFalse(canvas.hasKeyboardFocus)
    }
    #endif
}
