import EPUBCore
import EPUBReading
import EPUBTestSupport
import Observation
import SwiftUI
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The public value types and the optional controls model: what a host stores, reads and shows,
/// against scripted sessions and, where the reader's own answers matter, a mounted one.
@MainActor final class ControlsCoverageModelTests: XCTestCase {
    /// A ready session that records what it is sent and can refuse, fail or hold a command.
    private final class Session: EPUBReaderSession {
        let capabilities: Set<EPUBReaderCapability>
        let readerState: EPUBReaderState?
        var received: [EPUBReaderCommand] = []
        var failure: (any Error)?
        var closesBeforeFailing = false
        /// While true, a command waits here until `release()`.
        var holds = false
        private var held: [CheckedContinuation<Void, Never>] = []
        init(_ capabilities: Set<EPUBReaderCapability> = [.pagination, .scrolling, .typography, .search, .searchHighlight,
                                                          .searchResults, .navigateHref]) {
            self.capabilities = capabilities
            let state = EPUBReaderState(status: .init(capabilities: capabilities))
            state.modify { $0.lifecycle = .ready }
            readerState = state
        }
        func makeView() -> AnyView { AnyView(EmptyView()) }
        func send(_ command: EPUBReaderCommand) async throws {
            received.append(command)
            if holds { await withCheckedContinuation { held.append($0) } }
            if closesBeforeFailing { close() }
            if let failure { throw failure }
            if case .style(let style) = command { readerState?.modify { $0.style = style } }
        }
        func release() {
            holds = false
            for continuation in held { continuation.resume() }
            held = []
        }
        func close() { readerState?.modify { $0.lifecycle = .closed } }
    }

    private func controls(_ session: Session, publication: EPUBPublication? = nil) throws -> EPUBReaderControls {
        EPUBReaderControls(publication: try publication ?? EPUBPublication.open(data: Fixture.epub()), session: session)
    }

    private func wait(_ label: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw SessionCoverageTimeout(description: "Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Value types

    func testReaderErrorsHaveAMessageForEveryCase() {
        XCTAssertEqual(EPUBReaderError.unsupported(.search).message, "This reader does not support this action.")
        XCTAssertEqual(EPUBReaderError.unsupported(.bookmarks).message, EPUBReaderError.unsupported(.search).message)
        XCTAssertEqual(EPUBReaderError.incompatibleLocation.message, "This saved position belongs to a different book or reader.")
        XCTAssertEqual(EPUBReaderError.invalidCommand("Unknown publication href").message, "Unknown publication href")
        XCTAssertEqual(EPUBReaderError.engineFailure("The package document could not be read").message, "The package document could not be read")
        XCTAssertEqual(EPUBReaderError.notReady.message, "The reader is not ready.")
        XCTAssertEqual(EPUBReaderError.closed.message, "This book is closed.")
        XCTAssertNotEqual(EPUBReaderError.invalidCommand("a"), .invalidCommand("b"))
        XCTAssertNotEqual(EPUBReaderError.invalidCommand("a"), .engineFailure("a"))
        XCTAssertNotEqual(EPUBReaderError.unsupported(.search), .unsupported(.searchHighlight))
    }

    /// `doc/integration.md`: "To store a position, encode `EPUBLocation` using `JSONEncoder`" and
    /// "Existing JSON without this optional field remains valid". The keys are what hosts have
    /// on disk.
    func testLocationsEncodeUnderStableKeysAndDecodeWithMissingNullAndUnknownOnes() throws {
        let bookmark = EPUBEngineBookmark(engineID: "org.epublib.reader", format: "epublib-cfi-v1", value: "epubcfi(/6/2!/4/2/1:0)")
        let page = EPUBPageListEntry(label: "iv", href: "OPS/one.xhtml#p4")
        let full = EPUBLocation(publicationID: "book", href: "OPS/one.xhtml", progression: 0.25, title: "First", quote: "a passage",
                                bookmark: bookmark, page: page, pages: [page], rangeBookmarks: [bookmark])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let mark = #"{"engineID":"org.epublib.reader","format":"epublib-cfi-v1","value":"epubcfi(/6/2!/4/2/1:0)"}"#
        let entry = #"{"href":"OPS/one.xhtml#p4","label":"iv"}"#
        XCTAssertEqual(String(decoding: try encoder.encode(full), as: UTF8.self),
                       #"{"bookmark":\#(mark),"href":"OPS/one.xhtml","page":\#(entry),"pages":[\#(entry)],"progression":0.25,"#
                        + #""publicationID":"book","quote":"a passage","rangeBookmarks":[\#(mark)],"title":"First"}"#)
        XCTAssertEqual(try JSONDecoder().decode(EPUBLocation.self, from: encoder.encode(full)), full)
        XCTAssertEqual(String(decoding: try encoder.encode(EPUBLocation(publicationID: "book")), as: UTF8.self), #"{"publicationID":"book"}"#,
                       "absent fields are left out, not written as null")

        func decode(_ json: String) throws -> EPUBLocation { try JSONDecoder().decode(EPUBLocation.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode(#"{"publicationID":"book"}"#), EPUBLocation(publicationID: "book"))
        XCTAssertEqual(try decode(#"{"publicationID":"book","href":null,"progression":null,"title":null,"quote":null,"bookmark":null,"#
                                    + #""page":null,"pages":null,"rangeBookmarks":null}"#), EPUBLocation(publicationID: "book"))
        XCTAssertEqual(try decode(#"{"publicationID":"book","href":"OPS/one.xhtml","a later field":{"x":[1,2]},"progression":1}"#),
                       EPUBLocation(publicationID: "book", href: "OPS/one.xhtml", progression: 1))
        for broken in [#"{}"#, #"{"href":"OPS/one.xhtml"}"#, #"{"publicationID":7}"#, #"{"publicationID":"book","progression":"half"}"#,
                       #"{"publicationID":"book","bookmark":{"engineID":"e","format":"f"}}"#, #"{"publicationID":"book","pages":{"label":"1"}}"#] {
            XCTAssertThrowsError(try decode(broken), broken)
        }
        XCTAssertEqual(Set([page, EPUBPageListEntry(label: "iv", href: "OPS/one.xhtml#p4"), EPUBPageListEntry(label: "iv", href: "OPS/two.xhtml")]).count, 2)
        var other = full
        other.rangeBookmarks = nil
        XCTAssertNotEqual(other, full, "the range collection is part of a location's identity")
    }

    func testFlowsAppearancesAndStylesKeepTheSpellingAHostStores() throws {
        XCTAssertEqual([EPUBReadingFlow.paginated, .scrolled].map(\.rawValue), ["paginated", "scrolled"])
        XCTAssertEqual(EPUBReaderAppearance.allCases.map(\.rawValue), ["system", "light", "dark", "sepia", "black", "custom"])
        XCTAssertEqual(try JSONDecoder().decode([EPUBReadingFlow].self, from: Data(#"["scrolled","paginated"]"#.utf8)), [.scrolled, .paginated])
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(EPUBReaderAppearance.allCases), as: UTF8.self),
                       #"["system","light","dark","sepia","black","custom"]"#)
        XCTAssertThrowsError(try JSONDecoder().decode([EPUBReadingFlow].self, from: Data(#"["Paginated"]"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode([EPUBReaderAppearance].self, from: Data(#"["purple"]"#.utf8)))

        let style = EPUBReaderStyle()
        XCTAssertEqual(style, EPUBReaderStyle(fontSize: 17, appearance: .system, flow: .paginated))
        XCTAssertFalse(style.isDark, "System is not explicit Dark, whatever it resolves to")
        XCTAssertFalse(EPUBReaderStyle(appearance: .light).isDark)
        XCTAssertTrue(EPUBReaderStyle(appearance: .dark).isDark)
        XCTAssertTrue(EPUBReaderStyle(fontSize: 20, isDark: true, flow: .scrolled).isDark)
        XCTAssertNotEqual(EPUBReaderStyle(fontSize: 17.5), style)

        let status = EPUBReaderStatus(capabilities: [.pagination])
        XCTAssertEqual(status.lifecycle, .loading)
        XCTAssertEqual(status.style, style)
        XCTAssertEqual(status.effectiveAppearance, .light)
        XCTAssertNil(status.location)
        XCTAssertNil(status.canGoNext)
        XCTAssertNil(status.canGoPrevious)
        XCTAssertEqual(status.search, .idle)
        XCTAssertNil(status.searchResults)
        XCTAssertEqual(status.activeCommands, 0)
        XCTAssertNotEqual(EPUBReaderLifecycle.failed(.notReady), .failed(.closed))
    }

    /// `EPUBReaderState`: hosts observe it; an update that changes nothing must not wake them.
    func testAnUnchangedStatusUpdateDoesNotInvalidateObservers() {
        final class Counter: @unchecked Sendable { var value = 0 }
        let state = EPUBReaderState(status: EPUBReaderStatus(capabilities: [.pagination]))
        let changes = Counter()
        func observe() { withObservationTracking { _ = state.status } onChange: { changes.value += 1 } }
        observe()
        state.update(state.status)
        XCTAssertEqual(changes.value, 0)
        var next = state.status
        next.activeCommands = 1
        state.update(next)
        XCTAssertEqual(changes.value, 1)
        XCTAssertEqual(state.status.activeCommands, 1)
        observe()
        state.update(next)
        XCTAssertEqual(changes.value, 1)
    }

    // MARK: Search results

    private static func result(_ index: Int, section: Int = 0, title: String? = "Chapter", before: String = "Before ", after: String = " after.") -> EPUBSearchResult {
        EPUBSearchResult(index: index, location: .init(publicationID: "book", href: "OPS/\(section).xhtml", title: title, quote: "needle"),
                         spineIndex: section, sectionTitle: title, matchedText: "needle", contextBefore: before, contextAfter: after)
    }

    /// `EPUBSearchResults.steppedIndex(forward:)`: "the neighbour of the current match, wrapping
    /// … With no current match a forward step shows the first result and a backward step the
    /// last. nil when there are no results."
    func testSteppingFromEveryCurrentIndexWrapsAndReturns() {
        for count in 0...6 {
            let listed = (0..<count).map { Self.result($0) }
            for current in [nil] + (0..<count).map(Optional.some) {
                let results = EPUBSearchResults(query: "needle", results: listed, currentIndex: current)
                XCTAssertEqual(results.currentIndex, current)
                XCTAssertEqual(results.count, count)
                XCTAssertEqual(results.isEmpty, count == 0)
                XCTAssertEqual(results.current?.index, current)
                XCTAssertEqual(results.isAtFirst, current == 0)
                XCTAssertEqual(results.isAtLast, current != nil && current == count - 1)
                guard count > 0 else {
                    XCTAssertNil(results.steppedIndex(forward: true))
                    XCTAssertNil(results.steppedIndex(forward: false))
                    continue
                }
                XCTAssertEqual(results.steppedIndex(forward: true), current.map { ($0 + 1) % count } ?? 0, "\(count) results at \(String(describing: current))")
                XCTAssertEqual(results.steppedIndex(forward: false), current.map { ($0 + count - 1) % count } ?? count - 1)
                // A whole turn through the list visits every result once and comes back.
                for forward in [true, false] {
                    var walk = results, visited: [Int] = []
                    for _ in 0..<count {
                        walk.currentIndex = walk.steppedIndex(forward: forward)
                        visited.append(walk.currentIndex ?? -1)
                    }
                    XCTAssertEqual(visited.sorted(), Array(0..<count))
                    if let current { XCTAssertEqual(walk.currentIndex, current) }
                }
            }
            // An index outside the list, however it got there, is no current match.
            for stray in [-1, count, count + 3, Int.max, Int.min] {
                XCTAssertNil(EPUBSearchResults(query: "needle", results: listed, currentIndex: stray).currentIndex)
                var results = EPUBSearchResults(query: "needle", results: listed)
                results.currentIndex = stray
                XCTAssertNil(results.current)
                XCTAssertFalse(results.isAtFirst)
                XCTAssertFalse(results.isAtLast, "\(count) results with a stray index of \(stray)")
                XCTAssertEqual(results.steppedIndex(forward: true), count == 0 ? nil : 0)
                XCTAssertEqual(results.steppedIndex(forward: false), count == 0 ? nil : count - 1)
            }
        }
    }

    func testResultGroupsFollowSectionAndTitleAndWordingScalesToTheBound() throws {
        // Consecutive results share a group only while both section and title stay the same.
        let listed = [Self.result(0, title: "X"), Self.result(1, title: "X"), Self.result(2, title: "Y"), Self.result(3, section: 1, title: "X"),
                      Self.result(4, title: "X"), Self.result(5, section: 6, title: ""), Self.result(6, section: 6, title: nil)]
        let groups = EPUBSearchResultRows.groups(listed)
        XCTAssertEqual(groups.map(\.range), [0..<2, 2..<3, 3..<4, 4..<5, 5..<6, 6..<7])
        XCTAssertEqual(groups.map(\.title), ["X", "Y", "X", "X", "Section 7", "Section 7"])
        XCTAssertEqual(groups.map(\.id), [0, 2, 3, 4, 5, 6])

        let session = Session(), model = try controls(session)
        let bound = 10_000, shown = bound.formatted()
        let many = EPUBSearchResults(query: "needle", results: (0..<bound).map { Self.result($0) }, isTruncated: true)
        session.readerState?.modify { $0.search = .completed(query: "needle", hasMatches: true); $0.searchResults = many }
        XCTAssertEqual(model.searchResultSummary, "\(shown)+ matches")
        XCTAssertEqual(model.searchResultAccessibilityValue, "At least \(shown) matches, none shown yet")
        session.readerState?.modify { $0.searchResults?.currentIndex = bound - 1 }
        XCTAssertEqual(model.searchResultSummary, "\(shown) of \(shown)+")
        XCTAssertEqual(model.searchResultAccessibilityValue, "Match \(shown) of at least \(shown), last match, Chapter")
        XCTAssertEqual(model.searchResultButtonHelp(forward: true), "Next Match. Returns to the first match.")
        XCTAssertEqual(model.searchResultAccessibilityLabel(for: many.results[bound - 1]), "Match \(shown) of \(shown), Chapter: needle after. Preceded by: Before")

        // A result's name ends its text once, whatever ends it, and names nothing that is not there.
        let question = Self.result(0, title: nil, before: "  ", after: "?")
        let open = Self.result(1, title: "", before: "Asked ", after: " twice")
        session.readerState?.modify { $0.searchResults = EPUBSearchResults(query: "needle", results: [question, open]) }
        XCTAssertEqual(model.searchResultAccessibilityLabel(for: question), "Match 1 of 2: needle?")
        XCTAssertEqual(model.searchResultAccessibilityLabel(for: open), "Match 2 of 2: needle twice. Preceded by: Asked")
        // Every failure the engine can report is stated in the indicator.
        for error in [EPUBReaderError.unsupported(.search), .notReady, .closed, .incompatibleLocation, .invalidCommand("Too long"), .engineFailure("Broke")] {
            session.readerState?.modify { $0.search = .failed(query: "needle", error: error); $0.searchResults = nil }
            XCTAssertEqual(model.searchResultSummary, error.message)
            XCTAssertEqual(model.searchResultAccessibilityValue, "Search failed. \(error.message)")
            XCTAssertFalse(model.canShowSearchResults)
        }
        // Without the capability a result is named without a count it does not have.
        let plain = Session([.pagination, .searchHighlight]), plainModel = try controls(plain)
        XCTAssertEqual(plainModel.searchResultAccessibilityLabel(for: open), "Match 2: needle twice. Preceded by: Asked")
        plainModel.showSearchResult(open)
        XCTAssertEqual(plainModel.pendingCommands, 0, "nor is it sent to an engine that lists no results")
    }

    // MARK: Page controls

    /// `doc/integration.md`: "Keys support arrows, Page Up/Down, Home/End, Space and ASCII
    /// letters/digits. Letters are case-insensitive … Other character keys and unsupported
    /// modifier bits are ignored."
    func testKeyBindingsNameEveryKeyAndModifierAndIgnoreWhatIsNotAnASCIILetterOrDigit() {
        let all: EPUBPageKeyModifiers = [.shift, .command, .option, .control]
        let controls = EPUBPageControls(keyboardBindings: [
            .init(.home, modifiers: all, action: .next), .init(.end, action: .next), .init(.upArrow, modifiers: .control, action: .next),
            .init(.downArrow, modifiers: [.option, .shift], action: .next), .init(.pageUp, modifiers: .command, action: .next),
            .init(.pageDown, action: .next), .init(.leftArrow, action: .next), .init(.rightArrow, action: .next), .init(.space, action: .next),
            .init(.character("q"), action: .next), .init(.character("7"), modifiers: .control, action: .next),
            // None of these is a key the reader binds.
            .init(.character("\u{130}"), action: .next), .init(.character("\u{DF}"), action: .next), .init(.character("\u{FF11}"), action: .next),
            .init(.character(" "), action: .next), .init(.character("\n"), action: .next), .init(.character("-"), action: .next),
            .init(.character("\u{E9}"), action: .next), .init(.character("e\u{301}"), action: .next),
            .init(.end, modifiers: EPUBPageKeyModifiers(rawValue: 1 << 4), action: .next),
            .init(.end, modifiers: [.shift, EPUBPageKeyModifiers(rawValue: 1 << 7)], action: .next),
        ])
        XCTAssertEqual(controls.helpHints(for: .next, paginated: false, isRightToLeft: false, platform: .mouse), [
            "With reader focus: Control-Option-Command-Shift-Home, End, Control-Up Arrow, Option-Shift-Down Arrow, Command-Page Up, "
                + "Page Down, Left Arrow, Right Arrow, Space, Q, Control-7",
        ])
        XCTAssertEqual(controls.effectiveBindings.count, 11)
        XCTAssertTrue(controls.helpHints(for: .previous, paginated: false, isRightToLeft: true, platform: .touch).isEmpty)
        XCTAssertEqual(controls.direction(for: .character("Q"), modifiers: []), true, "letters are case-insensitive")
        XCTAssertEqual(controls.direction(for: .home, modifiers: all), true)
        XCTAssertNil(controls.direction(for: .home, modifiers: [.shift, .command, .option]), "modifiers match exactly")
        XCTAssertNil(controls.direction(for: .end, modifiers: .shift))
        for stray: Character in ["\u{130}", "\u{DF}", "\u{FF11}", " ", "-", "\u{E9}"] {
            XCTAssertNil(controls.direction(for: .character(stray), modifiers: []), "\(stray)")
        }
        // Six turns, Home and End, and on the Mac Command-Up and Command-Down (#681).
        #if os(macOS)
        XCTAssertEqual(EPUBPageKeyBinding.defaults.count, 10)
        #else
        XCTAssertEqual(EPUBPageKeyBinding.defaults.count, 8)
        #endif
        XCTAssertEqual(EPUBPageControls(), EPUBPageControls(keyboardBindings: EPUBPageKeyBinding.defaults))
        XCTAssertNotEqual(EPUBPageControls(), .hostOnly)
        XCTAssertEqual(EPUBPageControls.hostOnly.leftTapWidth, 56, "host-only input turns the zones off, it does not resize them")
        XCTAssertEqual(EPUBPageAction.next, .next)
    }

    // MARK: Controls model

    /// `doc/reader-controls.md`: "Controls show command activity and errors"; "Commands
    /// submitted through one controls model execute in FIFO order."
    func testCommandErrorsAreShownReplacedAndNeverStopTheQueue() async throws {
        let session = Session(), model = try controls(session)
        XCTAssertNil(model.commandError)
        let failures: [(any Error, String)] = [
            (EPUBReaderError.invalidCommand("Unknown publication href"), "Unknown publication href"),
            (EPUBReaderError.unsupported(.highlights), "This reader does not support this action."),
            (EPUBReaderError.incompatibleLocation, "This saved position belongs to a different book or reader."),
            (EPUBReaderError.notReady, "The reader is not ready."), (EPUBReaderError.engineFailure("Renderer lost"), "Renderer lost"),
            (EPUBReaderError.closed, "This book is closed."),
        ]
        for (failure, message) in failures {
            session.failure = failure
            model.send(.nextPage)
            await model.waitForCommands()
            XCTAssertEqual(model.commandError, message)
            XCTAssertEqual(model.pendingCommands, 0)
        }
        struct Foreign: LocalizedError { var errorDescription: String? { "A foreign failure" } }
        session.failure = Foreign()
        model.send(.nextPage)
        await model.waitForCommands()
        XCTAssertEqual(model.commandError, "A foreign failure")

        // A failure does not hold up what was queued behind it, and the next command clears it.
        session.received = []
        model.send(.previousPage)
        model.send(.nextPage)
        model.changeStyle { $0.fontSize = 30 }
        XCTAssertEqual(model.pendingCommands, 3)
        await model.waitForCommands()
        XCTAssertEqual(session.received, [.previousPage, .nextPage, .style(EPUBReaderStyle(fontSize: 30))])
        XCTAssertEqual(model.commandError, "A foreign failure", "every one of them failed")
        session.failure = nil
        model.send(.nextPage)
        await model.waitForCommands()
        XCTAssertNil(model.commandError, "a command that succeeds clears the error before it")
        XCTAssertFalse(model.isBusy)

        // A cancelled command is not an error, and a reader that closed has none to show.
        session.failure = CancellationError()
        model.send(.nextPage)
        await model.waitForCommands()
        XCTAssertNil(model.commandError)
        session.failure = EPUBReaderError.closed
        session.closesBeforeFailing = true
        model.send(.nextPage)
        await model.waitForCommands()
        XCTAssertNil(model.commandError)
        XCTAssertFalse(model.isReady)
        XCTAssertEqual(model.pendingCommands, 0)
    }

    /// "cancellation invalidates the queue … Already submitted commands cannot be undone."
    func testCancellingDropsUnsubmittedCommandsAndTheModelStaysUsable() async throws {
        let session = Session(), model = try controls(session)
        session.holds = true
        model.send(.navigate(href: "OPS/one.xhtml"))
        model.send(.nextPage)
        model.changeStyle { $0.fontSize = 40 }
        XCTAssertEqual(model.pendingCommands, 3)
        XCTAssertTrue(model.isBusy)
        try await wait("the first submission") { session.received.count == 1 }
        model.cancelPendingCommands()
        XCTAssertEqual(model.pendingCommands, 0)
        XCTAssertFalse(model.isBusy)
        session.release()
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.received, [.navigate(href: "OPS/one.xhtml")], "what was not yet submitted never is")
        XCTAssertEqual(model.pendingCommands, 0, "the submitted command's return does not count twice")
        XCTAssertNil(model.commandError)
        XCTAssertEqual(session.readerState?.status.style, EPUBReaderStyle())

        model.send(.previousPage)
        XCTAssertEqual(model.pendingCommands, 1)
        await model.waitForCommands()
        XCTAssertEqual(session.received, [.navigate(href: "OPS/one.xhtml"), .previousPage])
        XCTAssertEqual(model.pendingCommands, 0)
        // Cancelling with nothing pending, twice, is harmless.
        model.cancelPendingCommands()
        model.cancelPendingCommands()
        await model.waitForCommands()
        XCTAssertEqual(model.pendingCommands, 0)
    }

    /// "The current contents entry receives a checkmark when it names the section being read and,
    /// for fragments, its current title matches … duplicate chapter titles can be ambiguous."
    func testTheCurrentContentsEntryNeedsItsSectionAndForFragmentsAnUnambiguousTitle() throws {
        let publication = try EPUBPublication.open(data: SessionCoverageBook.epub([
            .init("one", "<p id=\"a\">A</p><p id=\"b\">B</p><p id=\"c\">C</p>"), .init("two", "<p id=\"x\">X</p>"),
        ], toc: "<li><a href=\"one.xhtml\">Chapter</a><ol><li><a href=\"one.xhtml#a\">Part</a><ol><li><a href=\"one.xhtml#b\">Part</a></li></ol></li>"
            + "<li><a href=\"one.xhtml#c\">Coda</a></li></ol></li><li><span>Unlinked</span></li><li><a href=\"two.xhtml#x\">Part</a></li>"))
        let session = Session(), model = try controls(session, publication: publication)
        func item(_ title: String, _ href: String?) -> EPUBNavigationItem { EPUBNavigationItem(title: title, href: href) }
        XCTAssertFalse(model.isCurrent(item("Chapter", "OPS/one.xhtml")), "no location yet")

        session.readerState?.modify { $0.location = EPUBLocation(publicationID: publication.id, href: "OPS/one.xhtml", title: "Part") }
        XCTAssertTrue(model.isCurrent(item("Chapter", "OPS/one.xhtml")), "a section entry is current anywhere in its section")
        XCTAssertFalse(model.isCurrent(item("Part", "OPS/one.xhtml#a")), "two entries of this section share the title")
        XCTAssertFalse(model.isCurrent(item("Part", "OPS/one.xhtml#b")))
        XCTAssertFalse(model.isCurrent(item("Coda", "OPS/one.xhtml#c")))
        XCTAssertFalse(model.isCurrent(item("Part", "OPS/two.xhtml#x")), "another section")
        XCTAssertFalse(model.isCurrent(item("Unlinked", nil)))

        session.readerState?.modify { $0.location?.title = "Coda" }
        XCTAssertTrue(model.isCurrent(item("Coda", "OPS/one.xhtml#c")))
        XCTAssertFalse(model.isCurrent(item("Unlisted", "OPS/one.xhtml#c")))

        session.readerState?.modify { $0.location = EPUBLocation(publicationID: publication.id, href: "OPS/two.xhtml", title: "Part") }
        XCTAssertTrue(model.isCurrent(item("Part", "OPS/two.xhtml#x")), "the title is unambiguous within this section")
        XCTAssertFalse(model.isCurrent(item("Chapter", "OPS/one.xhtml")))
        // A location that itself carries a fragment still names its section.
        session.readerState?.modify { $0.location?.href = "OPS/one.xhtml#b" }
        XCTAssertTrue(model.isCurrent(item("Chapter", "OPS/one.xhtml")))
        session.readerState?.modify { $0.location?.title = nil }
        XCTAssertFalse(model.isCurrent(item("Part", "OPS/one.xhtml#a")))
        session.readerState?.modify { $0.location?.href = nil }
        XCTAssertFalse(model.isCurrent(item("Chapter", "OPS/one.xhtml")))
    }

    /// "An entry names the section that `navigate(href:)` shows for it": by its decoded path,
    /// composed or decomposed, escaped or not, as the location's is (#206).
    func testTheCurrentContentsEntryIsFoundByItsDecodedPathWhateverItsSpelling() throws {
        let publication = try EPUBPublication.open(data: SessionCoverageBook.epub([
            .init("caf\u{E9}", "<p id=\"s1\">A</p><p id=\"s2\">B</p><p id=\"s3\">C</p>"), .init("two", "<p id=\"x\">X</p>"),
        ], toc: "<li><a href=\"cafe%CC%81.xhtml\">Caf\u{E9}</a><ol><li><a href=\"cafe%CC%81.xhtml#s1\">Opening</a></li>"
            + "<li><a href=\"caf%C3%A9.xhtml#s2\">Part</a></li><li><a href=\"cafe%CC%81.xhtml#s3\">Part</a></li></ol></li>"
            + "<li><a href=\"two.xhtml\">Two</a><ol><li><a href=\"two.xhtml#x\">Part</a></li></ol></li>"))
        let section = try XCTUnwrap(publication.spine.first?.resource.href)
        XCTAssertEqual(section, "OPS/caf%C3%A9.xhtml", "the reader's location names the manifest's composed spelling")
        let cafe = publication.tableOfContents[0], two = publication.tableOfContents[1]
        let opening = cafe.children[0], composedPart = cafe.children[1], decomposedPart = cafe.children[2]
        XCTAssertEqual(cafe.href, "OPS/cafe%CC%81.xhtml", "the entry keeps its own, decomposed")
        XCTAssertEqual(opening.href, "OPS/cafe%CC%81.xhtml#s1")
        let session = Session(), model = try controls(session, publication: publication)
        func item(_ title: String, _ href: String) -> EPUBNavigationItem { EPUBNavigationItem(title: title, href: href) }

        session.readerState?.modify { $0.location = EPUBLocation(publicationID: publication.id, href: section, title: "Opening") }
        XCTAssertTrue(model.isCurrent(cafe), "a decomposed entry names the composed section")
        XCTAssertTrue(model.isCurrent(opening), "and so does one with a fragment")
        XCTAssertFalse(model.isCurrent(composedPart))
        XCTAssertFalse(model.isCurrent(two))
        // Spellings a host writes: unescaped, escaped in lower case, composed or decomposed.
        for href in ["OPS/caf\u{E9}.xhtml", "OPS/cafe\u{301}.xhtml", "OPS/caf%c3%a9.xhtml", "OPS/%63af%C3%A9.xhtml"] {
            XCTAssertTrue(model.isCurrent(item("Caf\u{E9}", href)), href)
        }
        XCTAssertTrue(model.isCurrent(item("Opening", "OPS/cafe\u{301}.xhtml#s1")))
        XCTAssertFalse(model.isCurrent(item("Caf\u{E9}", "OPS/cafe.xhtml")), "an unaccented name is another file")

        session.readerState?.modify { $0.location?.title = "Part" }
        XCTAssertFalse(model.isCurrent(composedPart), "two entries of this section share the title, in two spellings")
        XCTAssertFalse(model.isCurrent(decomposedPart))
        XCTAssertFalse(model.isCurrent(two.children[0]), "another section")

        // Another engine's location, unescaped and with a fragment, names the same section.
        session.readerState?.modify { $0.location = EPUBLocation(publicationID: publication.id, href: "OPS/caf\u{E9}.xhtml#s1", title: "Opening") }
        XCTAssertTrue(model.isCurrent(cafe))
        XCTAssertTrue(model.isCurrent(opening))
        session.readerState?.modify { $0.location?.href = "OPS/cafe%CC%81.xhtml" }
        XCTAssertTrue(model.isCurrent(item("Caf\u{E9}", section)))

        session.readerState?.modify { $0.location = EPUBLocation(publicationID: publication.id, href: "OPS/two.xhtml", title: "Part") }
        XCTAssertTrue(model.isCurrent(two.children[0]), "the title is unambiguous within this section")
        XCTAssertFalse(model.isCurrent(cafe))
    }

    /// An entry that names a spine item's designated fallback is current while that item is read,
    /// where `navigate(href:)` shows it.
    func testAContentsEntryNamingAFallbackIsCurrentInItsSpineItem() throws {
        var book = Fixture.SpecBook()
        book.add("before", body: "<p>Before</p>")
        book.add(href: "source.json", id: "source", mediaType: "application/json", Data("{}".utf8), item: "fallback='static'")
        book.resource("text/static.xhtml", id: "static", mediaType: "application/xhtml+xml",
                      Data(Fixture.SpecBook.xhtml(body: "<p id='target'>Target</p>").utf8))
        book.navigation = "<nav epub:type='toc'><ol><li><a href='before.xhtml'>Before</a></li>"
            + "<li><a href='text/static.xhtml'>Fallback</a><ol><li><a href='text/static.xhtml#target'>Target</a></li></ol></li></ol></nav>"
        let publication = try EPUBPublication.open(data: book.archive())
        let session = Session(), model = try controls(session, publication: publication)
        session.readerState?.modify { $0.location = EPUBLocation(publicationID: publication.id, href: "EPUB/source.json", title: "Target") }
        XCTAssertEqual(publication.tableOfContents.map(model.isCurrent), [false, true])
        XCTAssertEqual(publication.tableOfContents[1].children.map(model.isCurrent), [true])
    }

    /// The bundled reader, sent an entry its manifest spells otherwise, shows its section, and
    /// the controls mark that entry current, not the one before it.
    func testTheBundledReaderMarksCurrentAnEntryItsManifestSpellsOtherwise() async throws {
        let reader = try SessionCoverageReader(SessionCoverageBook.epub([
            .init("one", "<p>One</p>"), .init("caf\u{E9}", "<p id=\"s1\">Opening</p>"),
        ], toc: "<li><a href=\"one.xhtml\">One</a></li><li><a href=\"cafe%CC%81.xhtml\">Caf\u{E9}</a>"
            + "<ol><li><a href=\"cafe%CC%81.xhtml#s1\">Opening</a></li></ol></li>"))
        addTeardownBlock { @MainActor in reader.close() }
        try await reader.settle()
        let model = EPUBReaderControls(publication: reader.publication, session: reader.session)
        let contents = reader.publication.tableOfContents, opening = try XCTUnwrap(contents.last?.children.first)
        XCTAssertEqual(contents.map(model.isCurrent), [true, false])

        model.send(.navigate(href: try XCTUnwrap(opening.href)))
        await model.waitForCommands()
        XCTAssertNil(model.commandError)
        try await reader.wait("the entry's section") { reader.section == 1 && model.status?.location?.title == "Opening" }
        XCTAssertEqual(model.status?.location?.href, "OPS/caf%C3%A9.xhtml")
        XCTAssertEqual(contents.map(model.isCurrent), [false, true])
        XCTAssertTrue(model.isCurrent(opening))
    }

    /// The model over the bundled reader: its refusals reach `commandError`, its queue keeps
    /// order, and closing the session silences the controls.
    func testControlsOverTheBundledReaderReportItsRefusalsAndRecover() async throws {
        let reader = try SessionCoverageReader(Fixture.epub())
        addTeardownBlock { @MainActor in reader.close() }
        try await reader.settle()
        let model = EPUBReaderControls(publication: reader.publication, session: reader.session)
        XCTAssertTrue(model.isReady)
        XCTAssertFalse(model.canGoPrevious)
        XCTAssertTrue(model.canGoNext)
        XCTAssertEqual(reader.publication.tableOfContents.map(model.isCurrent), [true])
        XCTAssertEqual(reader.publication.tableOfContents[0].children.map(model.isCurrent), [false])

        model.send(.navigate(href: "OPS/missing.xhtml"))
        model.send(.restore(EPUBLocation(publicationID: "another book")))
        await model.waitForCommands()
        XCTAssertEqual(model.commandError, EPUBReaderError.incompatibleLocation.message, "the later refusal replaces the earlier")
        XCTAssertEqual(reader.section, 0)
        model.send(.navigate(href: "OPS/missing.xhtml"))
        model.send(.navigate(href: "OPS/two.xhtml"))
        model.changeStyle { $0.fontSize = 22 }
        model.changeStyle { $0.flow = .scrolled }
        XCTAssertEqual(model.pendingCommands, 4)
        XCTAssertTrue(model.isBusy)
        await model.waitForCommands()
        XCTAssertNil(model.commandError, "a later success clears the refusal")
        XCTAssertEqual(reader.state.status.style, EPUBReaderStyle(fontSize: 22, flow: .scrolled))
        try await reader.wait("chapter two") { reader.section == 1 && reader.session.lastLocation?.title == "Second Chapter" }
        XCTAssertEqual(reader.publication.tableOfContents.map(model.isCurrent), [false])
        XCTAssertEqual(reader.publication.tableOfContents[0].children.map(model.isCurrent), [true])
        XCTAssertEqual(model.pageButtonLabel(for: .next), "Scroll Forward")

        model.searchText = "unique destination"
        model.submitSearch()
        await model.waitForCommands()
        XCTAssertEqual(model.searchResultSummary, "1 of 1")
        XCTAssertTrue(model.canShowSearchResults)
        model.searchText = String(repeating: "x", count: 600)
        model.submitSearch()
        await model.waitForCommands()
        let refusal = try XCTUnwrap(model.commandError, "the reader's refusal of an overlong query is shown")
        XCTAssertEqual(model.searchResultSummary, refusal)
        XCTAssertNil(model.commandErrorBesideSearchFeedback, "the search field states its refusal once, not again under itself")
        XCTAssertNil(model.searchResults)
        // Another command's refusal while that search stays failed is a second thing to say.
        model.send(.navigate(href: "OPS/missing.xhtml"))
        await model.waitForCommands()
        XCTAssertEqual(model.searchResultSummary, refusal)
        XCTAssertNotEqual(model.commandError, refusal)
        XCTAssertEqual(model.commandErrorBesideSearchFeedback, model.commandError)
        model.clearSearch()
        await model.waitForCommands()
        XCTAssertEqual(model.searchText, "")
        XCTAssertNil(model.searchResultSummary)
        XCTAssertNil(model.commandError)
        XCTAssertFalse(model.isBusy)

        reader.session.close()
        XCTAssertFalse(model.isReady)
        XCTAssertFalse(model.canGoNext || model.canGoPrevious)
        model.send(.nextPage)
        model.changeStyle { $0.fontSize = 40 }
        model.submitSearch()
        XCTAssertEqual(model.pendingCommands, 0)
        await model.waitForCommands()
        XCTAssertNil(model.commandError)
        XCTAssertEqual(reader.state.status.style.fontSize, 22)
    }

    // MARK: Supplied views

    /// SwiftUI content in a real window, with its platform views in view order.
    @MainActor private final class Host {
        #if os(macOS)
        private let window: NSWindow
        private let hosting: NSHostingView<AnyView>
        private var root: NSView { hosting }
        typealias Segments = NSSegmentedControl
        #else
        private let window: UIWindow
        private let hosting: UIHostingController<AnyView>
        private var root: UIView { hosting.view }
        typealias Segments = UISegmentedControl
        #endif

        init(_ content: some View) {
            let size = CGSize(width: 700, height: 500)
            #if os(macOS)
            window = makeMacTestWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            hosting = NSHostingView(rootView: AnyView(content))
            window.contentView = hosting
            window.orderFront(nil)
            #else
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window = UIWindow(windowScene: scene)
            } else { window = UIWindow(frame: CGRect(origin: .zero, size: size)) }
            hosting = UIHostingController(rootView: AnyView(content))
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            #endif
        }

        func show(_ content: some View) { hosting.rootView = AnyView(content) }

        private func layOut() {
            #if os(macOS)
            hosting.layoutSubtreeIfNeeded()
            #else
            window.layoutIfNeeded()
            #endif
        }

        private func views<T>(_ type: T.Type) -> [T] {
            func collect(_ view: PlatformView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(collect) }
            layOut()
            return collect(root)
        }

        /// The placeholders of the editable text fields on screen.
        var fields: [String] {
            #if os(macOS)
            views(NSTextField.self).filter(\.isEditable).map { $0.placeholderString ?? "" }
            #else
            views(UITextField.self).map { $0.placeholder ?? "" }
            #endif
        }
        var segmentedControls: Int { views(Segments.self).count }

        /// What is on screen in reading order of its layout: rows from the top, then left to right.
        var order: [String] {
            var found: [(String, CGRect)] = []
            #if os(macOS)
            for field in views(NSTextField.self) where field.isEditable { found.append((field.placeholderString ?? "", field.convert(field.bounds, to: root))) }
            let flipped = root.isFlipped
            #else
            for field in views(UITextField.self) { found.append((field.placeholder ?? "", field.convert(field.bounds, to: root))) }
            let flipped = true
            #endif
            for control in views(Segments.self) { found.append(("segments", control.convert(control.bounds, to: root))) }
            return found.sorted { a, b in
                let overlap = min(a.1.maxY, b.1.maxY) - max(a.1.minY, b.1.minY)
                if overlap > 0 { return a.1.minX < b.1.minX }
                return flipped ? a.1.minY < b.1.minY : a.1.minY > b.1.minY
            }.map(\.0)
        }

        var fittingHeight: CGFloat {
            layOut()
            #if os(macOS)
            return hosting.fittingSize.height
            #else
            return hosting.sizeThatFits(in: CGSize(width: window.bounds.width, height: .greatestFiniteMagnitude)).height
            #endif
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

    /// `doc/reader-controls.md`: "Pass ordered `groups` to omit or rearrange"; the strip "stacks
    /// groups and custom views"; "Unsupported groups are hidden."
    func testTheControlStripShowsItsGroupsInTheOrderGivenThenTheHostsOwnViews() async throws {
        let session = Session(), model = try controls(session)
        let search = "Search in book"
        func strip(_ groups: [EPUBReaderControlGroup], extras: Bool = false) -> AnyView {
            extras ? AnyView(EPUBReaderControlStrip(controls: model, groups: groups) { TextField("Host field", text: .constant("")) })
                : AnyView(EPUBReaderControlStrip(controls: model, groups: groups))
        }
        let host = Host(strip([.search, .readingMode]))
        defer { host.close() }
        try await wait("the search field and the mode picker") { host.order == [search, "segments"] }
        host.show(strip([.readingMode, .search]))
        try await wait("the mode picker before the search field") { host.order == ["segments", search] }
        host.show(strip([.readingMode, .pages, .contents, .appearance]))
        try await wait("no search field") { host.order == ["segments"] }
        host.show(strip([.search, .pages], extras: true))
        try await wait("the host's field after the groups") { host.order == [search, "Host field"] }
        host.show(strip([], extras: true))
        try await wait("only the host's field") { host.order == ["Host field"] }
        host.show(strip(EPUBReaderControlGroup.allCases))
        try await wait("every group") { host.order.sorted() == [search, "segments"].sorted() }
        XCTAssertEqual(EPUBReaderControlGroup.allCases, [.pages, .search, .contents, .appearance, .readingMode])
        XCTAssertEqual(host.order, [search, "segments"], "the default order puts search before reading mode")

        // An engine without a group's capability shows nothing for it, wherever it is listed.
        let bare = Session([.pagination]), bareModel = try controls(bare)
        host.show(EPUBReaderControlStrip(controls: bareModel, groups: EPUBReaderControlGroup.allCases) { TextField("Host field", text: .constant("")) })
        try await wait("only the host's field beside a bare engine") { host.order == ["Host field"] }
        XCTAssertTrue(session.received.isEmpty && bare.received.isEmpty, "laying controls out submits nothing")
    }

    /// "Controls show command activity and errors": the strip states a failed command under its
    /// groups until the error is dismissed.
    func testTheControlStripShowsACommandErrorUntilItIsDismissed() async throws {
        let session = Session(), model = try controls(session)
        let host = Host(EPUBReaderControlStrip(controls: model, groups: [.pages, .readingMode]))
        defer { host.close() }
        try await wait("the strip") { host.segmentedControls == 1 }
        let plain = host.fittingHeight
        XCTAssertGreaterThan(plain, 0)
        session.failure = EPUBReaderError.invalidCommand("The reader refused this command")
        model.send(.nextPage)
        await model.waitForCommands()
        XCTAssertEqual(model.commandError, "The reader refused this command")
        try await wait("the error under the groups") { host.fittingHeight > plain }
        model.dismissError()
        XCTAssertNil(model.commandError)
        try await wait("the strip without the error") { abs(host.fittingHeight - plain) < 0.5 }
    }
}
