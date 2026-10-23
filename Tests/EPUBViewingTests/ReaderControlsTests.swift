import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#endif

@MainActor final class ReaderControlsTests: XCTestCase {
    private final class Session: EPUBReaderSession {
        let capabilities: Set<EPUBReaderCapability>
        let readerState: EPUBReaderState?
        var received: [EPUBReaderCommand] = []
        var failure: EPUBReaderError?
        init(navigatesSearch: Bool = true) {
            var capabilities: Set<EPUBReaderCapability> = [.pagination, .scrolling, .typography, .searchHighlight, .navigateHref]
            if navigatesSearch { capabilities.insert(.search) }
            self.capabilities = capabilities
            let state = EPUBReaderState(status: .init(capabilities: capabilities))
            state.modify { $0.lifecycle = .ready }
            readerState = state
        }
        func makeView() -> AnyView { AnyView(EmptyView()) }
        func send(_ command: EPUBReaderCommand) async throws {
            if let failure { throw failure }
            received.append(command)
            if case .style(let style) = command { readerState?.modify { $0.style = style } }
            await Task.yield()
        }
        func close() { readerState?.modify { $0.lifecycle = .closed } }
    }
    private func controls(_ session: Session) throws -> EPUBReaderControls {
        EPUBReaderControls(publication: try EPUBPublication.open(data: Fixture.epub()), session: session)
    }
    func testAppearanceDefaultsAndExplicitBooleanCompatibility() {
        XCTAssertEqual(EPUBReaderStyle().appearance, .system)
        XCTAssertEqual(EPUBReaderStyle(isDark: true).appearance, .dark)
        XCTAssertEqual(EPUBReaderStyle(isDark: false).appearance, .light)
        var style = EPUBReaderStyle(fontSize: 23, flow: .scrolled)
        style.isDark = true
        XCTAssertEqual(style, .init(fontSize: 23, appearance: .dark, flow: .scrolled))
        style.appearance = .system
        XCTAssertEqual(style.fontSize, 23)
        XCTAssertEqual(style.flow, .scrolled)
    }
    func testPageButtonHelpFollowsCurrentFlowSettingsAndHostCustomization() throws {
        let session = Session(), model = try controls(session)
        XCTAssertEqual(model.pageButtonLabel(for: .next), "Next Page")
        XCTAssertTrue(model.pageButtonHelp(for: .next).contains("With reader focus: Right Arrow, Page Down, Space"))
        XCTAssertTrue(model.pageButtonHelp(for: .previous).contains("Left Arrow, Page Up, Shift-Space"))
        XCTAssertEqual(model.pageButtonHelp(for: .next, pageControls: .hostOnly), "Next Page.")

        session.readerState?.modify { $0.style.flow = .scrolled }
        XCTAssertEqual(model.pageButtonLabel(for: .next), "Scroll Forward")
        XCTAssertEqual(model.pageButtonLabel(for: .previous), "Scroll Backward")
        XCTAssertEqual(model.pageButtonHelp(for: .next), "Scroll Forward. With reader focus: Right Arrow, Page Down, Space.")
        let remapped = EPUBPageControls(keyboardBindings: [.init(.character("n"), modifiers: .command, action: .next)])
        XCTAssertEqual(model.pageButtonHelp(for: .next, pageControls: remapped), "Scroll Forward. With reader focus: Command-N.")
        XCTAssertEqual(model.pageButtonHelp(for: .previous, pageControls: remapped), "Scroll Backward.")

        model.customizePageButtonHelp = { action, defaultHelp in
            defaultHelp + (action == .next ? " Host hint." : " Previous host hint.")
        }
        XCTAssertEqual(model.pageButtonHelp(for: .next, pageControls: .hostOnly), "Scroll Forward. Host hint.")
        XCTAssertEqual(model.pageButtonLabel(for: .next), "Scroll Forward", "long help does not change the accessible label")
        model.customizePageButtonHelp = { _, _ in "Host handles navigation." }
        XCTAssertEqual(model.pageButtonHelp(for: .previous), "Host handles navigation.")
        model.customizePageButtonHelp = nil
        session.readerState?.modify { $0.style.flow = .paginated }
        XCTAssertEqual(model.pageButtonHelp(for: .previous, pageControls: .hostOnly), "Previous Page.")
        XCTAssertTrue(session.received.isEmpty, "help and customization never submit commands")
    }

    func testRTLPageHelpKeepsLogicalKeyboardBindings() throws {
        let session = Session()
        let model = EPUBReaderControls(publication: try EPUBPublication.open(data: Fixture.rendering(.rightToLeft)), session: session)
        XCTAssertTrue(model.isRightToLeft)
        XCTAssertEqual(model.pageButtonLabel(for: .next), "Next Page")
        XCTAssertTrue(model.pageButtonHelp(for: .next).contains("Right Arrow, Page Down, Space"))
        XCTAssertTrue(model.pageButtonHelp(for: .next).contains("the left edge"))
        XCTAssertTrue(model.pageButtonHelp(for: .previous).contains("the right edge"))
    }
    #if os(macOS)
    func testPageHelpDoesNotInstallShortcutsWhileBuiltInSearchFieldHasFocus() async throws {
        func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.compactMap { textField(in: $0) }.first
        }
        for flow: EPUBReadingFlow in [.paginated, .scrolled] {
            let session = Session(), model = try controls(session)
            session.readerState?.modify { $0.style.flow = flow }
            var configuration = ReaderCanvasConfiguration()
            configuration.flow = flow
            let host = CanvasHost(FakeCanvasSource([CanvasText.section(0, paragraphs: 30)]), configuration: configuration)
            defer { host.close() }
            let canvas = host.canvas
            let container = NSView(frame: canvas.frame)
            canvas.removeFromSuperview()
            host.window.contentView = container
            container.addSubview(canvas)
            let strip = NSHostingView(rootView: EPUBReaderControlStrip(controls: model, groups: [.pages, .search]))
            strip.frame = CGRect(x: 0, y: 0, width: 600, height: 70)
            container.addSubview(strip)
            canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
            host.layOut()
            let mounted = TestDeadline(seconds: 10)
            while textField(in: strip) == nil, try !mounted.hasPassed() { try await Task.sleep(for: .milliseconds(20)) }
            let field = try XCTUnwrap(textField(in: strip), "the built-in search field is mounted")
            XCTAssertTrue(host.window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.string = "findword"
            editor.selectedRange = NSRange(location: 4, length: 0)
            XCTAssertFalse(canvas.hasKeyboardFocus)
            let before = try XCTUnwrap(canvas.visibleRange)
            let editingKeys: [(UInt16, String, NSEvent.ModifierFlags)] = [
                (49, " ", []), (49, " ", .shift), (124, "\u{F703}", []), (123, "\u{F702}", []),
            ]
            for (code, characters, flags) in editingKeys {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: 0, windowNumber: host.window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
                XCTAssertFalse(canvas.handlePageKeyEquivalent(event), "search editing keys do not turn pages")
                XCTAssertFalse(strip.performKeyEquivalent(with: event), "page-button help installs no shortcuts")
                editor.keyDown(with: event)
                XCTAssertEqual(canvas.visibleRange, before)
            }
            XCTAssertEqual(editor.string, "find  word", "Space and Shift-Space edit the search field")
            XCTAssertTrue(session.received.isEmpty)
        }
    }
    #endif
    func testFIFOAndRapidStyleEditsPreserveOtherFields() async throws {
        let session = Session(), model = try controls(session)
        session.readerState?.modify { $0.style = .init(fontSize: 20, isDark: true, flow: .scrolled) }
        model.changeStyle { $0.fontSize += 2 }
        model.changeStyle { $0.fontSize += 2 }
        model.changeStyle { $0.flow = .paginated }
        model.send(.nextPage)
        XCTAssertEqual(model.pendingCommands, 4)
        await model.waitForCommands()
        XCTAssertEqual(session.received, [.style(.init(fontSize: 22, isDark: true, flow: .scrolled)),
                                          .style(.init(fontSize: 24, isDark: true, flow: .scrolled)),
                                          .style(.init(fontSize: 24, isDark: true)), .nextPage])
        XCTAssertFalse(model.isBusy)
    }
    func testOnlySearchesCountTowardsSearchFeedback() async throws {
        let session = Session(), model = try controls(session)
        model.send(.nextPage)
        model.changeStyle { $0.fontSize += 2 }
        model.clearSearch()
        XCTAssertEqual(model.pendingCommands, 3)
        XCTAssertEqual(model.pendingSearches, 0,
            "a page turn must not show search feedback: its line resizes inline controls and the reader under them")
        model.searchText = "chapter"
        model.submitSearch()
        model.send(.searchHighlight(text: "chapter"))
        XCTAssertEqual(model.pendingSearches, 2)
        await model.waitForCommands()
        XCTAssertEqual(model.pendingSearches, 0)
        XCTAssertEqual(model.pendingCommands, 0)
        model.submitSearch()
        model.cancelPendingCommands()
        XCTAssertEqual(model.pendingSearches, 0)
        await Task.yield()
        XCTAssertEqual(model.pendingSearches, 0, "a canceled search does not count down twice")
    }
    func testTypingSubmitClearAndCommandErrors() async throws {
        let session = Session(), model = try controls(session)
        model.searchText = "chapter"
        XCTAssertTrue(session.received.isEmpty)
        model.submitSearch()
        model.clearSearch()
        model.searchText = " \n "
        model.submitSearch()
        await model.waitForCommands()
        XCTAssertEqual(session.received, [.search(text: "chapter"), .clearSearch, .clearSearch])
        session.failure = .invalidCommand("rejected")
        model.send(.nextPage)
        await model.waitForCommands()
        XCTAssertNotNil(model.commandError)
        XCTAssertFalse(model.isBusy)
        model.dismissError()
        XCTAssertNil(model.commandError)
    }
    func testSearchFallsBackForHighlightOnlyEngines() async throws {
        let session = Session(navigatesSearch: false), model = try controls(session)
        model.searchText = "chapter"
        model.submitSearch()
        await model.waitForCommands()
        XCTAssertEqual(session.received, [.searchHighlight(text: "chapter")])
    }
    func testClosedFailedAndCanceledQueuesDoNotSubmit() async throws {
        let session = Session(), model = try controls(session)
        model.send(.nextPage)
        session.close()
        await model.waitForCommands()
        XCTAssertTrue(session.received.isEmpty)
        XCTAssertFalse(model.canGoNext)
        session.readerState?.modify { $0.lifecycle = .failed(.engineFailure("failed")) }
        model.send(.previousPage)
        XCTAssertEqual(model.pendingCommands, 0)
        session.readerState?.modify { $0.lifecycle = .ready }
        model.send(.nextPage)
        model.cancelPendingCommands()
        await Task.yield()
        XCTAssertTrue(session.received.isEmpty)
        XCTAssertFalse(model.isBusy)
    }
    func testCapabilitiesBoundariesAndCurrentNestedContents() throws {
        let session = Session(), model = try controls(session)
        session.readerState?.modify {
            $0.canGoPrevious = false
            $0.canGoNext = true
            $0.location = .init(publicationID: model.publication.id, href: "OPS/one.xhtml", title: "First Chapter")
        }
        XCTAssertFalse(model.canGoPrevious)
        XCTAssertTrue(model.canGoNext)
        XCTAssertTrue(model.isCurrent(.init(title: "First Chapter", href: "OPS/one.xhtml#start")))
        XCTAssertFalse(model.isCurrent(.init(title: "Other", href: "OPS/one.xhtml#later")))
        XCTAssertFalse(model.isCurrent(.init(title: "First Chapter", href: "OPS/two.xhtml")))
        session.readerState?.modify { $0.capabilities = [.pagination]; $0.style.flow = .scrolled }
        XCTAssertFalse(model.canGoNext)
        XCTAssertFalse(model.supports(.searchHighlight))
    }
    func testLegacyConformerAndToolbarFreeViewRemainUsable() throws {
        final class Legacy: EPUBReaderSession {
            var capabilities: Set<EPUBReaderCapability> { [] }
            func makeView() -> AnyView { AnyView(EmptyView()) }
            func send(_ command: EPUBReaderCommand) async throws {}
            func close() {}
        }
        let legacy = Legacy()
        XCTAssertNil(legacy.readerState)
        _ = EPUBReaderView(session: legacy)
        let model = EPUBReaderControls(publication: try EPUBPublication.open(data: Fixture.epub()), session: legacy)
        XCTAssertFalse(model.isReady)
    }
}
