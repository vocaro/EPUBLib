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

/// The menu bar's reader commands (`EPUBReaderMenuCommands`, #697): each command's name, which is
/// what VoiceOver reads of its menu item, its shortcut, when it can run and what it submits,
/// against a scripted session. SwiftUI builds the menus themselves only in an app's scenes; the
/// example hosts carry them (doc/testing.md, "Reader controls probe").
@MainActor final class ReaderMenuCommandsTests: XCTestCase {
    private final class Session: EPUBReaderSession {
        let capabilities: Set<EPUBReaderCapability>
        let readerState: EPUBReaderState?
        var received: [EPUBReaderCommand] = []
        static let every: Set<EPUBReaderCapability> = [.pagination, .scrolling, .typography, .search, .searchHighlight,
                                                      .searchResults, .navigateHref, .goToProgression]
        init(_ capabilities: Set<EPUBReaderCapability> = every) {
            self.capabilities = capabilities
            let state = EPUBReaderState(status: .init(capabilities: capabilities))
            state.modify { $0.lifecycle = .ready }
            readerState = state
        }
        func makeView() -> AnyView { AnyView(EmptyView()) }
        func send(_ command: EPUBReaderCommand) async throws {
            received.append(command)
            readerState?.modify { status in
                let results = status.searchResults
                switch command {
                case .style(let style): status.style = style
                case .nextSearchResult: status.searchResults?.currentIndex = results?.steppedIndex(forward: true)
                case .previousSearchResult: status.searchResults?.currentIndex = results?.steppedIndex(forward: false)
                default: break
                }
            }
            await Task.yield()
        }
        func close() { readerState?.modify { $0.lifecycle = .closed } }
    }

    private func controls(_ session: Session) throws -> EPUBReaderControls {
        EPUBReaderControls(publication: try EPUBPublication.open(data: Fixture.epub()), session: session)
    }

    /// Runs one command as its menu item does and waits for what it submitted.
    private func perform(_ command: EPUBReaderMenuCommand, _ model: EPUBReaderControls, _ session: Session) async -> [EPUBReaderCommand] {
        let before = session.received.count
        command.perform(model)
        await model.waitForCommands()
        return Array(session.received.dropFirst(before))
    }

    private func results(_ count: Int) -> EPUBSearchResults {
        EPUBSearchResults(query: "needle", results: (0..<count).map { index in
            EPUBSearchResult(index: index, location: .init(publicationID: "book", href: "OPS/0.xhtml"), spineIndex: 0,
                             matchedText: "needle", contextBefore: "", contextAfter: "")
        })
    }

    // MARK: Names and shortcuts

    /// Each command is called what the supplied controls call it, the page turns by the reading
    /// flow as the page buttons are, and has the platform's shortcut.
    func testEachCommandHasItsControlsNameAndThePlatformsShortcut() throws {
        let session = Session(), model = try controls(session)
        let paginated: [EPUBReaderMenuCommand: String] = [
            .previousPage: "Previous Page", .nextPage: "Next Page", .bookStart: "First Page", .bookEnd: "Last Page",
            .find: "Find…", .findNext: "Find Next", .findPrevious: "Find Previous",
            .largerText: "Larger Text", .smallerText: "Smaller Text", .actualSize: "Actual Size",
            .continuousScroll: "Continuous Scroll", .paging: "Paging",
        ]
        XCTAssertEqual(Set(paginated.keys), Set(EPUBReaderMenuCommand.allCases))
        for (command, name) in paginated {
            XCTAssertEqual(command.title(model), name)
            XCTAssertEqual(command.title(nil), name, "without a reader in front a command keeps its place and its name")
        }
        for action in [EPUBPageAction.previous, .next, .bookStart, .bookEnd] {
            XCTAssertEqual(model.pageButtonLabel(for: action), [.previous: "Previous Page", .next: "Next Page",
                                                               .bookStart: "First Page", .bookEnd: "Last Page"][action],
                           "the menu and the page buttons give a command one name")
        }
        session.readerState?.modify { $0.style.flow = .scrolled }
        XCTAssertEqual([EPUBReaderMenuCommand.previousPage, .nextPage, .bookStart, .bookEnd].map { $0.title(model) },
                       ["Scroll Backward", "Scroll Forward", "Scroll to Beginning", "Scroll to End"])
        XCTAssertEqual(EPUBReaderMenuCommand.find.title(model), "Find…")

        let shortcuts: [EPUBReaderMenuCommand: (KeyEquivalent, EventModifiers)] = [
            .previousPage: (.pageUp, []), .nextPage: (.pageDown, []), .bookStart: (.home, []), .bookEnd: (.end, []),
            .find: ("f", .command), .findNext: ("g", .command), .findPrevious: ("g", [.command, .shift]),
            .largerText: ("+", .command), .smallerText: ("-", .command), .actualSize: ("0", .command),
            .continuousScroll: ("1", .command), .paging: ("2", .command),
        ]
        for (command, (key, modifiers)) in shortcuts {
            XCTAssertEqual(command.shortcut.key, key, "\(command)")
            XCTAssertEqual(command.shortcut.modifiers, modifiers, "\(command)")
        }
        XCTAssertEqual(Set(EPUBReaderMenuCommand.allCases.map { "\($0.shortcut.key.character)\($0.shortcut.modifiers.rawValue)" }).count,
                       EPUBReaderMenuCommand.allCases.count, "no two commands share a shortcut")
        // The page keys are the reader's own: with reader focus they do what the menu does.
        let reader = EPUBPageControls()
        XCTAssertEqual(reader.action(for: .pageUp, modifiers: []), .previous)
        XCTAssertEqual(reader.action(for: .pageDown, modifiers: []), .next)
        XCTAssertEqual(reader.action(for: .home, modifiers: []), .bookStart)
        XCTAssertEqual(reader.action(for: .end, modifiers: []), .bookEnd)
    }

    // MARK: When a command can run

    /// Without a reader in front, before it is ready, after it fails and once it closes, every
    /// command is dimmed and does nothing.
    func testNothingRunsWithoutAReadyReaderInFront() async throws {
        for command in EPUBReaderMenuCommand.allCases { XCTAssertFalse(command.isEnabled(nil), "\(command)") }
        let session = Session(), model = try controls(session)
        model.addFindTarget(UUID())
        session.readerState?.modify {
            $0.search = .completed(query: "needle", hasMatches: true)
            $0.searchResults = results(3)
            $0.style.fontSize = 19
        }
        let ready = EPUBReaderMenuCommand.allCases.filter { $0.isEnabled(model) }
        XCTAssertEqual(Set(ready), Set(EPUBReaderMenuCommand.allCases), "a ready reader with everything runs every command")
        for lifecycle in [EPUBReaderLifecycle.loading, .failed(.engineFailure("failed")), .closed] {
            session.readerState?.modify { $0.lifecycle = lifecycle }
            for command in EPUBReaderMenuCommand.allCases {
                XCTAssertFalse(command.isEnabled(model), "\(command) \(lifecycle)")
                command.perform(model)
            }
            await model.waitForCommands()
            XCTAssertTrue(session.received.isEmpty, "\(lifecycle)")
            XCTAssertEqual(model.findRequests, 0, "\(lifecycle)")
        }
    }

    /// An engine without a capability has its commands dimmed, whatever the reader's state.
    func testCommandsAreDimmedForWhatTheEngineCannotDo() throws {
        let cases: [(EPUBReaderCapability, [EPUBReaderMenuCommand])] = [
            (.goToProgression, [.bookStart, .bookEnd]),
            (.searchResults, [.findNext, .findPrevious]),
            (.typography, [.largerText, .smallerText, .actualSize]),
            (.scrolling, [.continuousScroll, .paging]),
        ]
        for (missing, dimmed) in cases {
            let session = Session(Session.every.subtracting([missing])), model = try controls(session)
            model.addFindTarget(UUID())
            session.readerState?.modify {
                $0.search = .completed(query: "needle", hasMatches: true)
                $0.searchResults = results(3)
                $0.style.fontSize = 19
            }
            for command in EPUBReaderMenuCommand.allCases {
                XCTAssertEqual(command.isEnabled(model), !dimmed.contains(command), "\(command) without \(missing)")
            }
            XCTAssertTrue(model.canShowContents, "without \(missing)")
        }
        XCTAssertFalse(try controls(Session(Session.every.subtracting([.navigateHref]))).canShowContents,
                       "Contents is dimmed for an engine that cannot navigate")
        let session = Session(), model = try controls(session)
        session.readerState?.modify { $0.lifecycle = .loading }
        XCTAssertFalse(model.canShowContents, "and before the reader is ready")
    }

    // MARK: Moving

    /// The page turns and the book's ends submit the page buttons' and #681's commands, and are
    /// dimmed at an end the reader knows it is at.
    func testPageCommandsTurnAndGoToTheBooksEndsWhereTheReaderIsNotAlready() async throws {
        let session = Session(), model = try controls(session)
        let moves: [(EPUBReaderMenuCommand, EPUBReaderCommand)] = [
            (.previousPage, .previousPage), (.nextPage, .nextPage), (.bookStart, .goToStart), (.bookEnd, .goToEnd),
        ]
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            session.readerState?.modify { $0.style.flow = flow; $0.canGoPrevious = nil; $0.canGoNext = nil }
            for (command, sent) in moves {
                XCTAssertTrue(command.isEnabled(model), "\(command) \(flow): an unknown end leaves it to the engine")
                let submitted = await perform(command, model, session)
                XCTAssertEqual(submitted, [sent], "\(command) \(flow)")
            }
            session.readerState?.modify { $0.canGoPrevious = false; $0.canGoNext = true }
            XCTAssertEqual(moves.map { $0.0.isEnabled(model) }, [false, true, false, true], "\(flow): at the book's start")
            session.readerState?.modify { $0.canGoPrevious = true; $0.canGoNext = false }
            XCTAssertEqual(moves.map { $0.0.isEnabled(model) }, [true, false, true, false], "\(flow): at the book's end")
            let dimmed = await perform(.bookEnd, model, session)
            XCTAssertTrue(dimmed.isEmpty, "\(flow): a dimmed command submits nothing")
        }
        // Turning needs the flow the reader is in; the ends need only a progression.
        let paging = Session([.pagination, .goToProgression]), pages = try controls(paging)
        paging.readerState?.modify { $0.style.flow = .scrolled }
        XCTAssertEqual(moves.map { $0.0.isEnabled(pages) }, [false, false, true, true])
    }

    // MARK: Finding

    /// Find shows the supplied search field that appeared last, showing hidden controls first,
    /// and is dimmed with no search field on screen or a reader that does not search.
    func testFindAsksTheLastSearchFieldOnScreenAndShowsHiddenControls() async throws {
        let session = Session(), model = try controls(session)
        XCTAssertFalse(model.canFind, "no supplied search field is on screen")
        model.find()
        XCTAssertEqual(model.findRequests, 0)
        let toolbar = UUID(), strip = UUID()
        model.addFindTarget(toolbar)
        model.addFindTarget(strip)
        XCTAssertTrue(model.canFind)
        XCTAssertEqual(model.findTargets.last, strip)
        model.hideControls()
        XCTAssertTrue(model.controlsHidden)
        let submitted = await perform(.find, model, session)
        XCTAssertEqual(model.findRequests, 1)
        XCTAssertFalse(model.controlsHidden, "Find shows hidden controls, where the field is")
        XCTAssertTrue(submitted.isEmpty, "Find submits nothing to the reader")
        model.removeFindTarget(strip)
        XCTAssertEqual(model.findTargets, [toolbar], "the field that remains answers Find")
        model.addFindTarget(toolbar)
        XCTAssertEqual(model.findTargets, [toolbar], "a field that appears again is listed once")
        model.removeFindTarget(toolbar)
        XCTAssertFalse(model.canFind)

        for capabilities: Set<EPUBReaderCapability> in [[.searchHighlight], [.search]] {
            let searching = Session(capabilities), other = try controls(searching)
            other.addFindTarget(UUID())
            XCTAssertTrue(other.canFind, "\(capabilities)")
        }
        let reading = Session([.pagination, .typography]), plain = try controls(reading)
        plain.addFindTarget(UUID())
        XCTAssertFalse(plain.canFind, "a reader that does not search")
    }

    /// Find Next and Find Previous step through the results as the match buttons do, and are
    /// dimmed while there are none.
    func testFindNextAndPreviousStepThroughTheResults() async throws {
        let session = Session(), model = try controls(session)
        XCTAssertFalse(EPUBReaderMenuCommand.findNext.isEnabled(model))
        session.readerState?.modify { $0.search = .completed(query: "needle", hasMatches: false); $0.searchResults = results(0) }
        XCTAssertFalse(EPUBReaderMenuCommand.findNext.isEnabled(model), "a search with no matches")
        session.readerState?.modify { $0.search = .completed(query: "needle", hasMatches: true); $0.searchResults = results(3) }
        var announced: [String] = []
        model.postAnnouncement = { announced.append($0) }
        let next = await perform(.findNext, model, session)
        XCTAssertEqual(next, [.nextSearchResult])
        let previous = await perform(.findPrevious, model, session)
        XCTAssertEqual(previous, [.previousSearchResult])
        XCTAssertEqual(model.searchResults?.currentIndex, 2, "the first step shows the first match, and the step back the last")
        XCTAssertEqual(announced.count, 2, "each step says the match it shows, as the match buttons do")
    }

    // MARK: Appearance

    /// Larger Text and Smaller Text step as the appearance menu does and are dimmed where no
    /// step changes the size drawn; Actual Size goes back to the style's 17 points. Each says the
    /// size then drawn.
    func testTextSizeCommandsStepAndGoBackToTheDefaultSize() async throws {
        let session = Session(), model = try controls(session)
        var announced: [String] = []
        model.postAnnouncement = { announced.append($0) }
        XCTAssertEqual(EPUBReaderStyle().fontSize, 17)
        XCTAssertFalse(EPUBReaderMenuCommand.actualSize.isEnabled(model), "already the default size")
        let larger = await perform(.largerText, model, session)
        XCTAssertEqual(larger, [.style(EPUBReaderStyle(fontSize: 19))])
        XCTAssertTrue(EPUBReaderMenuCommand.actualSize.isEnabled(model))
        let actual = await perform(.actualSize, model, session)
        XCTAssertEqual(actual, [.style(EPUBReaderStyle(fontSize: 17))])
        let smaller = await perform(.smallerText, model, session)
        XCTAssertEqual(smaller, [.style(EPUBReaderStyle(fontSize: 15))])
        XCTAssertEqual(announced, ["19 points", "17 points", "15 points"])

        session.readerState?.modify { $0.style.fontSize = 96 }
        XCTAssertFalse(EPUBReaderMenuCommand.largerText.isEnabled(model), "96 points is the largest drawn")
        XCTAssertTrue(EPUBReaderMenuCommand.smallerText.isEnabled(model))
        session.readerState?.modify { $0.style.fontSize = 12 }
        XCTAssertFalse(EPUBReaderMenuCommand.smallerText.isEnabled(model), "12 points is the smallest drawn")
        XCTAssertTrue(EPUBReaderMenuCommand.largerText.isEnabled(model))

        // Actual Size keeps the rest of the style, the system text size among it.
        session.readerState?.modify { $0.style = EPUBReaderStyle(fontSize: 40, appearance: .sepia, flow: .scrolled); $0.style.followsDynamicType = true }
        let kept = await perform(.actualSize, model, session)
        var expected = EPUBReaderStyle(fontSize: 17, appearance: .sepia, flow: .scrolled)
        expected.followsDynamicType = true
        XCTAssertEqual(kept, [.style(expected)])
    }

    /// Continuous Scroll and Paging choose their mode, are checked while it is in use, and choose
    /// nothing again for the mode already in use.
    func testReadingModeCommandsChooseTheirModeAndAreCheckedForIt() async throws {
        let session = Session(), model = try controls(session)
        XCTAssertEqual(EPUBReaderMenuCommand.continuousScroll.flow, .scrolled)
        XCTAssertEqual(EPUBReaderMenuCommand.paging.flow, .paginated)
        XCTAssertEqual(EPUBReaderMenuCommand.allCases.filter { $0.flow != nil }, [.continuousScroll, .paging])
        let again = await perform(.paging, model, session)
        XCTAssertTrue(again.isEmpty, "the reader already pages")
        session.readerState?.modify { $0.style.fontSize = 23 }
        let scrolled = await perform(.continuousScroll, model, session)
        XCTAssertEqual(scrolled, [.style(EPUBReaderStyle(fontSize: 23, flow: .scrolled))], "the rest of the style is kept")
        XCTAssertEqual(model.status?.style.flow, .scrolled)
        let paged = await perform(.paging, model, session)
        XCTAssertEqual(paged, [.style(EPUBReaderStyle(fontSize: 23, flow: .paginated))])
    }

    // MARK: Mounted search fields

    /// SwiftUI content in a real window, as `ReaderControlViewTests` hosts it.
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

        init(_ content: some View, size: CGSize = CGSize(width: 600, height: 500)) {
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

        func views<T>(_ type: T.Type) -> [T] {
            func collect(_ view: PlatformView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(collect) }
            #if os(macOS)
            hosting.layoutSubtreeIfNeeded()
            #else
            window.layoutIfNeeded()
            #endif
            return collect(root)
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

    private func wait(_ label: String, timeout: TimeInterval = 10, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    #if os(macOS)
    private typealias Field = NSTextField
    private func editing(_ field: NSTextField) -> Bool {
        guard let editor = field.currentEditor() else { return false }
        return field.window?.firstResponder === editor
    }
    #else
    private typealias Field = UITextField
    private func editing(_ field: UITextField) -> Bool { field.isFirstResponder }
    #endif

    /// A supplied search field on screen is a Find target while it is there, and Find puts the
    /// focus in it: the control strip's own field, which does not take focus as it appears.
    func testFindPutsFocusInTheStripsSearchFieldWhileItIsOnScreen() async throws {
        let session = Session(), model = try controls(session)
        let host = Host(EPUBReaderControlStrip(controls: model, groups: [.pages, .search]))
        defer { host.close() }
        try await wait("the strip's search field to be a Find target") { model.canFind }
        let field = try XCTUnwrap(host.views(Field.self).first { field in
            #if os(macOS)
            field.isEditable
            #else
            true
            #endif
        }, "the strip's search field")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(editing(field), "the strip's field does not take focus as it appears")
        EPUBReaderMenuCommand.find.perform(model)
        try await wait("Find to put focus in the field") { self.editing(field) }
        XCTAssertTrue(session.received.isEmpty)
        host.close()
        try await wait("the closed strip's field to stop being a Find target") { !model.canFind }
    }

    /// Find opens a search group's pane, whose field takes the focus: the toolbar's Search.
    func testFindOpensTheSearchPaneOfAToolbarsSearchGroup() async throws {
        let session = Session(), model = try controls(session)
        let host = Host(EPUBReaderControl(controls: model, group: .search).padding(40))
        defer { host.close() }
        try await wait("the search group to be a Find target") { model.canFind }
        XCTAssertTrue(host.views(Field.self).isEmpty, "the pane is closed")
        #if os(iOS)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(host.window.rootViewController?.presentedViewController, "the pane is closed")
        #endif
        EPUBReaderMenuCommand.find.perform(model)
        #if os(macOS)
        // The pane is a popover, in a window of its own.
        func paneField() -> NSTextField? {
            for window in NSApp.windows where window !== host.window && window.isVisible {
                func find(_ view: NSView) -> NSTextField? {
                    if let field = view as? NSTextField, field.isEditable { return field }
                    return view.subviews.lazy.compactMap(find).first
                }
                if let content = window.contentView, let field = find(content) { return field }
            }
            return nil
        }
        try await wait("the search pane") { paneField() != nil }
        let field = try XCTUnwrap(paneField())
        try await wait("the pane's field to take focus") { self.editing(field) }
        field.window?.close()
        #else
        // The pane's field takes focus as the pane opens, by the pane's own code. This test's window
        // held no text field in the presented pane's views, as a sheet or a popover; in the controls
        // probe's host on an iPad simulator the field took focus (`MenuCommandShortcuts`,
        // doc/testing.md).
        try await wait("the search pane") { host.window.rootViewController?.presentedViewController != nil }
        host.window.rootViewController?.presentedViewController?.dismiss(animated: false)
        #endif
    }
}
