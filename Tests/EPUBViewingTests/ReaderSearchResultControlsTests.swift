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

/// The result model's arithmetic and the optional controls' search-result state, commands,
/// wording and supplied views, against a scripted session.
@MainActor final class ReaderSearchResultControlsTests: XCTestCase {
    /// Publishes scripted results the way an engine with `.searchResults` does.
    private final class Session: EPUBReaderSession {
        let capabilities: Set<EPUBReaderCapability>
        let readerState: EPUBReaderState?
        var received: [EPUBReaderCommand] = []
        init(results: Bool = true, navigates: Bool = true) {
            var capabilities: Set<EPUBReaderCapability> = [.pagination, .scrolling, .searchHighlight]
            if navigates { capabilities.insert(.search) }
            if results { capabilities.insert(.searchResults) }
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
                case .nextSearchResult: status.searchResults?.currentIndex = results?.steppedIndex(forward: true)
                case .previousSearchResult: status.searchResults?.currentIndex = results?.steppedIndex(forward: false)
                case .showSearchResult(let result): status.searchResults?.currentIndex = result.index
                case .clearSearch: status.search = .idle; status.searchResults = nil
                default: break
                }
            }
            await Task.yield()
        }
        func close() { readerState?.modify { $0.lifecycle = .closed } }
        func publish(_ search: EPUBSearchState, _ results: EPUBSearchResults? = nil) {
            readerState?.modify { $0.search = search; $0.searchResults = results }
        }
    }

    private static func result(_ index: Int, section: Int = 0, title: String? = "First Chapter", before: String = "Alpha comes before ",
                               after: String = " one, then more.", page: String? = nil) -> EPUBSearchResult {
        EPUBSearchResult(index: index, location: .init(publicationID: "book", href: "OPS/\(section).xhtml", title: title,
                                                       quote: "needle", page: page.map { .init(label: $0, href: "OPS/\(section).xhtml") }),
                         spineIndex: section, sectionTitle: title, matchedText: "needle", contextBefore: before, contextAfter: after)
    }
    private static func results(_ count: Int, current: Int? = nil, truncated: Bool = false) -> EPUBSearchResults {
        EPUBSearchResults(query: "needle", results: (0..<count).map { result($0, section: $0 / 2, title: $0 < 2 ? "First Chapter" : "Later Chapter \($0 / 2)") },
                          currentIndex: current, isTruncated: truncated)
    }
    private func controls(_ session: Session, rightToLeft: Bool = false) throws -> EPUBReaderControls {
        EPUBReaderControls(publication: try EPUBPublication.open(data: rightToLeft ? Fixture.rendering(.rightToLeft) : Fixture.epub()),
                           session: session)
    }

    func testStepsWrapAtTheEndsAndChooseAnEndWithoutACurrentMatch() {
        var results = Self.results(3)
        XCTAssertEqual(results.count, 3)
        XCTAssertNil(results.current)
        XCTAssertFalse(results.isAtFirst)
        XCTAssertFalse(results.isAtLast)
        XCTAssertEqual(results.steppedIndex(forward: true), 0, "no current match: forward shows the first")
        XCTAssertEqual(results.steppedIndex(forward: false), 2, "no current match: backward shows the last")
        results.currentIndex = 0
        XCTAssertTrue(results.isAtFirst)
        XCTAssertEqual(results.current?.index, 0)
        XCTAssertEqual(results.steppedIndex(forward: true), 1)
        XCTAssertEqual(results.steppedIndex(forward: false), 2, "before the first result is the last")
        results.currentIndex = 2
        XCTAssertTrue(results.isAtLast)
        XCTAssertEqual(results.steppedIndex(forward: true), 0, "after the last result is the first")
        XCTAssertEqual(results.steppedIndex(forward: false), 1)

        let single = Self.results(1, current: 0)
        XCTAssertTrue(single.isAtFirst && single.isAtLast)
        XCTAssertEqual(single.steppedIndex(forward: true), 0)
        XCTAssertEqual(single.steppedIndex(forward: false), 0)

        let empty = EPUBSearchResults(query: "needle")
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.steppedIndex(forward: true))
        XCTAssertNil(empty.steppedIndex(forward: false))
        XCTAssertFalse(empty.isAtFirst || empty.isAtLast)
        XCTAssertNil(Self.results(2, current: 5).currentIndex, "an index outside the list is no current match")
        var stray = Self.results(2)
        stray.currentIndex = 9
        XCTAssertNil(stray.current)
        XCTAssertEqual(stray.steppedIndex(forward: true), 0)
        XCTAssertEqual(Self.result(0).snippet, "Alpha comes before needle one, then more.")
        XCTAssertEqual(Self.result(4).id, 4)
    }

    func testEnginesThatOnlyHighlightKeepTheirControlsAndGainNoResultControls() async throws {
        for navigates in [true, false] {
            let session = Session(results: false, navigates: navigates), model = try controls(session)
            // Even a stray published list is ignored without the capability.
            session.publish(.completed(query: "needle", hasMatches: true), Self.results(3, current: 0))
            XCTAssertNil(model.searchResults)
            XCTAssertFalse(model.canShowSearchResults)
            XCTAssertNil(model.searchResultSummary, "a successful highlight-only search shows no count")
            XCTAssertEqual(model.searchResultAccessibilityValue, "Matches highlighted")
            XCTAssertNil(model.searchResultButtonHint(forward: true))
            model.showNextSearchResult()
            model.showPreviousSearchResult()
            model.showSearchResult(Self.result(0))
            model.searchText = "needle"
            model.submitSearch()
            model.clearSearch()
            await model.waitForCommands()
            XCTAssertEqual(session.received, [navigates ? .search(text: "needle") : .searchHighlight(text: "needle"), .clearSearch],
                           "search submission and clearing are unchanged; no result command reaches the engine")
            session.publish(.completed(query: "absent", hasMatches: false))
            XCTAssertEqual(model.searchResultSummary, "No matches")
            XCTAssertEqual(model.searchResultAccessibilityValue, "No matches")
        }
    }

    func testMatchCommandsAreLogicalQueuedAndDistinctFromPageTurns() async throws {
        for rightToLeft in [false, true] {
            let session = Session(), model = try controls(session, rightToLeft: rightToLeft)
            XCTAssertEqual(model.isRightToLeft, rightToLeft)
            model.showNextSearchResult()
            model.showPreviousSearchResult()
            XCTAssertEqual(model.pendingCommands, 0, "nothing to step through before a search has results")
            session.publish(.completed(query: "needle", hasMatches: true), Self.results(4, current: 0))
            XCTAssertTrue(model.canShowSearchResults)
            let chosen = try XCTUnwrap(model.searchResults?.results[3])
            model.showNextSearchResult()
            model.send(.nextPage)
            model.showPreviousSearchResult()
            model.showPreviousSearchResult()
            model.showSearchResult(chosen)
            await model.waitForCommands()
            XCTAssertEqual(session.received, [.nextSearchResult, .nextPage, .previousSearchResult, .previousSearchResult, .showSearchResult(chosen)],
                           "match steps and page turns are separate commands in one FIFO queue")
            XCTAssertEqual(model.searchResults?.currentIndex, 3)
            XCTAssertEqual(model.searchResultButtonLabel(forward: true), "Next Match")
            XCTAssertEqual(model.searchResultButtonLabel(forward: false), "Previous Match")
            XCTAssertNotEqual(model.searchResultButtonLabel(forward: true), model.pageButtonLabel(for: .next))
            XCTAssertNotEqual(model.searchResultButtonLabel(forward: false), model.pageButtonLabel(for: .previous))
            session.readerState?.modify { $0.style.flow = .scrolled }
            XCTAssertNotEqual(model.searchResultButtonLabel(forward: true), model.pageButtonLabel(for: .next))

            // The query and current match belong to the session, not to any view.
            model.searchText = "needle"
            session.readerState?.modify { $0.lifecycle = .loading }
            XCTAssertFalse(model.canShowSearchResults, "a detached surface disables stepping")
            model.showNextSearchResult()
            XCTAssertEqual(model.pendingCommands, 0)
            session.readerState?.modify { $0.lifecycle = .ready }
            XCTAssertEqual(model.searchText, "needle")
            XCTAssertEqual(model.searchResults?.currentIndex, 3)
            XCTAssertEqual(model.searchResultSummary, "4 of 4")

            model.clearSearch()
            await model.waitForCommands()
            XCTAssertNil(model.searchResults)
            XCTAssertNil(model.searchResultSummary)
            model.showNextSearchResult()
            await model.waitForCommands()
            XCTAssertEqual(session.received.last, .clearSearch, "no step is submitted after the results are gone")
            session.publish(.completed(query: "needle", hasMatches: true), Self.results(4, current: 0))
            session.close()
            XCTAssertNil(model.searchResults, "a closed session has no results")
            XCTAssertFalse(model.canShowSearchResults)
        }
    }

    func testIndicatorTextStatesZeroPendingFailedCountAndEnds() throws {
        let session = Session(), model = try controls(session)
        XCTAssertNil(model.searchResultSummary)
        XCTAssertNil(model.searchResultAccessibilityValue)
        XCTAssertEqual(model.searchResultButtonHelp(forward: true), "Next Match")

        session.publish(.searching(query: "needle"))
        XCTAssertEqual(model.searchResultSummary, "Searching…")
        XCTAssertEqual(model.searchResultAccessibilityValue, "Searching")
        XCTAssertFalse(model.canShowSearchResults)

        session.publish(.failed(query: " ", error: .invalidCommand("The search text is empty or too long")))
        XCTAssertEqual(model.searchResultSummary, "The search text is empty or too long")
        XCTAssertEqual(model.searchResultAccessibilityValue, "Search failed. The search text is empty or too long")

        session.publish(.completed(query: "absent", hasMatches: false), EPUBSearchResults(query: "absent"))
        XCTAssertEqual(model.searchResultSummary, "No matches")
        XCTAssertEqual(model.searchResultAccessibilityValue, "No matches")
        XCTAssertFalse(model.canShowSearchResults)
        XCTAssertNil(model.searchResultButtonHint(forward: true))

        session.publish(.completed(query: "needle", hasMatches: true), Self.results(3))
        XCTAssertEqual(model.searchResultSummary, "3 matches")
        XCTAssertEqual(model.searchResultAccessibilityValue, "3 matches, none shown yet")
        XCTAssertEqual(model.searchResultButtonHelp(forward: true), "Next Match. Shows the first match.")
        XCTAssertEqual(model.searchResultButtonHelp(forward: false), "Previous Match. Shows the last match.")

        session.publish(.completed(query: "needle", hasMatches: true), Self.results(3, current: 0))
        XCTAssertEqual(model.searchResultSummary, "1 of 3")
        XCTAssertEqual(model.searchResultAccessibilityValue, "Match 1 of 3, first match, First Chapter")
        XCTAssertEqual(model.searchResultButtonHelp(forward: true), "Next Match")
        XCTAssertEqual(model.searchResultButtonHelp(forward: false), "Previous Match. Returns to the last match.")

        session.publish(.completed(query: "needle", hasMatches: true), Self.results(3, current: 1))
        XCTAssertEqual(model.searchResultSummary, "2 of 3")
        XCTAssertEqual(model.searchResultAccessibilityValue, "Match 2 of 3, First Chapter")
        XCTAssertNil(model.searchResultButtonHint(forward: true))
        XCTAssertNil(model.searchResultButtonHint(forward: false))

        session.publish(.completed(query: "needle", hasMatches: true), Self.results(3, current: 2))
        XCTAssertEqual(model.searchResultSummary, "3 of 3")
        XCTAssertEqual(model.searchResultAccessibilityValue, "Match 3 of 3, last match, Later Chapter 1")
        XCTAssertEqual(model.searchResultButtonHelp(forward: true), "Next Match. Returns to the first match.")
        XCTAssertEqual(model.searchResultButtonHelp(forward: false), "Previous Match")

        session.publish(.completed(query: "needle", hasMatches: true), Self.results(1))
        XCTAssertEqual(model.searchResultSummary, "1 match")
        XCTAssertEqual(model.searchResultAccessibilityValue, "1 match, none shown yet")
        session.publish(.completed(query: "needle", hasMatches: true), Self.results(1, current: 0))
        XCTAssertEqual(model.searchResultSummary, "1 of 1")
        XCTAssertEqual(model.searchResultAccessibilityValue, "Match 1 of 1, only match, First Chapter")
        XCTAssertEqual(model.searchResultButtonHelp(forward: true), "Next Match. This is the only match.")
        XCTAssertEqual(model.searchResultButtonHelp(forward: false), "Previous Match. This is the only match.")

        // A bounded list says its count is a lower bound.
        session.publish(.completed(query: "needle", hasMatches: true), Self.results(4, truncated: true))
        XCTAssertEqual(model.searchResultSummary, "4+ matches")
        XCTAssertEqual(model.searchResultAccessibilityValue, "At least 4 matches, none shown yet")
        session.publish(.completed(query: "needle", hasMatches: true), Self.results(4, current: 3, truncated: true))
        XCTAssertEqual(model.searchResultSummary, "4 of 4+")
        XCTAssertEqual(model.searchResultAccessibilityValue, "Match 4 of at least 4, last match, Later Chapter 1")
    }

    func testResultNamesCarrySectionPageAndContextToTellOccurrencesApart() throws {
        let session = Session(), model = try controls(session)
        let first = Self.result(0, before: "Beta has ", after: " two and needle three close together.", page: "12")
        let second = Self.result(1, before: "Beta has needle two and ", after: " three close together.", page: "12")
        let third = Self.result(2, section: 4, title: nil, before: "", after: " alone")
        session.publish(.completed(query: "needle", hasMatches: true),
                        EPUBSearchResults(query: "needle", results: [first, second, third], currentIndex: 1))
        XCTAssertEqual(first.snippet, second.snippet, "the same paragraph holds both occurrences")
        XCTAssertEqual(model.searchResultAccessibilityLabel(for: first),
                       "Match 1 of 3, First Chapter, page 12: needle two and needle three close together. Preceded by: Beta has")
        XCTAssertEqual(model.searchResultAccessibilityLabel(for: second),
                       "Match 2 of 3, First Chapter, page 12: needle three close together. Preceded by: Beta has needle two and")
        XCTAssertEqual(model.searchResultAccessibilityLabel(for: third), "Match 3 of 3: needle alone")

        // The browser groups consecutive results under their section and names an untitled one.
        let groups = EPUBSearchResultRows.groups([first, second, third])
        XCTAssertEqual(groups.map(\.title), ["First Chapter", "Section 5"])
        XCTAssertEqual(groups.map(\.range), [0..<2, 2..<3])
        XCTAssertTrue(EPUBSearchResultRows.groups([]).isEmpty)
        let emphasized = EPUBSearchResultRows.snippet(second)
        XCTAssertEqual(String(emphasized.characters), second.snippet)
        XCTAssertEqual(emphasized.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(emphasized[$0.range].characters) }, ["needle"], "only the occurrence is emphasized")
    }

    /// An iPhone 17 Pro on its side leaves the search sheet 177 points above the keyboard and its
    /// suggestions, an iPhone SE 168 and an iPhone 17e 166. The sheet with results must fit in
    /// that at every text size, or its top is cut off, the field and Close Search with it.
    func testSearchPaneWithResultsFitsACompactHeight() async throws {
        XCTAssertEqual(EPUBSearchResultPane.minimumListHeight, 44)
        #if os(iOS)
        let session = Session(), model = try controls(session)
        session.publish(.completed(query: "needle", hasMatches: true), Self.results(7, current: 0))
        // The iPhone 17 Pro's sheet, its 874 points less the 62 at each end, the iPhone SE's and
        // the iPhone 17e's.
        let rooms = [CGSize(width: 750, height: 177), CGSize(width: 667, height: 168), CGSize(width: 750, height: 166)]
        for room in rooms {
            for textSize in DynamicTypeSize.allCases {
                let name = "\(textSize) in \(Int(room.width)) by \(Int(room.height)) points"
                let pane = try await paneHeld(to: room, .compact, textSize, model: model)
                if textSize == .large, room == rooms[0] { XCTAssertNil(pane.scroller, "at the default size the list fits there as it is") }
                if textSize == .accessibility5 { XCTAssertNotNil(pane.scroller, "\(name): the field's row and Clear Search leave no room for a list") }
            }
        }
        #endif
    }

    /// A regular height can be as short of room. Upright, an iPhone SE leaves the search sheet
    /// 387 points above the keyboard and its suggestions and an iPhone 13 mini 425, and an iPad
    /// mini on its side leaves the popover 284. With 160 points promised to the list, the pane
    /// was taller than each at some text size: than the iPad's popover by 2 points at the default.
    func testSearchPaneWithResultsFitsARegularHeight() async throws {
        #if os(iOS)
        let session = Session(), model = try controls(session)
        session.publish(.completed(query: "needle", hasMatches: true), Self.results(7, current: 0))
        // Each room, and its list's height at the default text size. The sheets gave the list
        // more than 160 points there, and it has what it had; the popover's 2 points come off it.
        let phone = CGSize(width: 375, height: 387), mini = CGSize(width: 375, height: 425), popover = CGSize(width: 372, height: 284)
        let rooms: [(CGSize, CGFloat)] = [(phone, 260), (mini, 299), (popover, 158)]
        for (room, listAtDefault) in rooms {
            for textSize in DynamicTypeSize.allCases {
                let name = "\(textSize) in \(Int(room.width)) by \(Int(room.height)) points"
                let pane = try await paneHeld(to: room, .regular, textSize, model: model)
                if textSize == .large {
                    XCTAssertNil(pane.scroller, name)
                    XCTAssertEqual(pane.list.height, listAtDefault, accuracy: 1, name)
                }
                if textSize == .accessibility5 {
                    XCTAssertLessThan(pane.list.height, 160, "\(name): the list had no 160 points to take")
                    // Upright, the list has what the keyboard leaves it. The popover has none to give.
                    XCTAssertEqual(pane.scroller != nil, room == popover, name)
                }
            }
        }
        #endif
    }

    /// A popover is as tall as its content's ideal height, to the pixel. The pane's choice
    /// between its content as it is and the same content scrolling is made by ideal height
    /// too, with the list at its least: the pane must still ask a popover for the 320 points
    /// its list had there, and must not scroll in the popover it asked for.
    func testSearchPaneIsWholeInThePopoverItAsksFor() async throws {
        XCTAssertEqual(EPUBSearchResultPane.popoverListHeight, 320)
        let session = Session(), model = try controls(session)
        let states: [(String, EPUBSearchState, EPUBSearchResults?)] = [
            ("idle", .idle, nil),
            ("failed", .failed(query: " ", error: .invalidCommand("The search text is empty or too long")), nil),
            ("empty", .completed(query: "absent", hasMatches: false), EPUBSearchResults(query: "absent")),
            ("listed", .completed(query: "needle", hasMatches: true), Self.results(7, current: 0)),
        ]
        #if os(macOS)
        let textSizes = [DynamicTypeSize.large]
        #else
        let textSizes = DynamicTypeSize.allCases
        #endif
        for (state, search, results) in states {
            session.publish(search, results)
            for textSize in textSizes {
                let name = "\(state) at \(textSize)"
                let pane = Self.searchPane(model).dynamicTypeSize(textSize)
                // Held to a size, so that the device's safe area is no part of what is measured.
                let asking = MountedView(pane, size: CGSize(width: 400, height: 400))
                try await Task.sleep(for: .milliseconds(60))
                let ideal = asking.idealSize()
                asking.close()
                let popover = MountedView(pane, size: ideal)
                defer { popover.close() }
                try await Task.sleep(for: .milliseconds(60))
                XCTAssertNil(popover.paneScroller(), "\(name): the pane scrolls in a popover of the \(ideal) it asked for")
                if results?.isEmpty == false {
                    let list = try XCTUnwrap(popover.listFrame(), name)
                    XCTAssertEqual(list.height, 320, accuracy: 0.5, name)
                    XCTAssertEqual(list.maxY, ideal.height - 16, accuracy: 0.5, name)
                    #if os(iOS)
                    // What the iPad showed before the pane could scroll: 372 × 446, the list 340 × 320.
                    if textSize == .large {
                        XCTAssertEqual(ideal.width, 372, accuracy: 0.5)
                        XCTAssertEqual(ideal.height, 446, accuracy: 1)
                        XCTAssertEqual(list.width, 340, accuracy: 0.5)
                    }
                    #endif
                } else {
                    XCTAssertNil(popover.listFrame(), name)
                    // A size rounded down by less than a point is not a reason to scroll: 2 points are.
                    let rounded = MountedView(pane, size: CGSize(width: ideal.width, height: ideal.height - 0.75))
                    let short = MountedView(pane, size: CGSize(width: ideal.width, height: ideal.height - 2))
                    defer { rounded.close(); short.close() }
                    try await Task.sleep(for: .milliseconds(60))
                    XCTAssertNil(rounded.paneScroller(), name)
                    XCTAssertNotNil(short.paneScroller(), name)
                }
            }
        }
    }

    /// What the toolbar's Search button presents: the field, its buttons, Clear Search, the
    /// navigator and the list, padded and held to the top of its sheet or popover. Disabled,
    /// which changes no size, so that the field does not take focus in the test host as it does
    /// when the pane opens.
    private static func searchPane(_ model: EPUBReaderControls) -> some View {
        EPUBSearchField(controls: model, onDismiss: {}).padding().frame(maxHeight: .infinity, alignment: .top).disabled(true)
    }

    #if os(iOS)
    /// Mounts the pane in a sheet or popover with `room` for it and checks that it is whole
    /// there: the field under its padding, and beneath it either the list with at least its
    /// minimum, or everything scrolling. Returns the list's frame and what scrolls, if anything.
    private func paneHeld(to room: CGSize, _ height: UserInterfaceSizeClass, _ textSize: DynamicTypeSize,
                          model: EPUBReaderControls) async throws -> (list: CGRect, scroller: UIScrollView?) {
        let name = "\(textSize) in \(Int(room.width)) by \(Int(room.height)) points"
        let pane = MountedView(Self.searchPane(model).environment(\.verticalSizeClass, height).dynamicTypeSize(textSize), size: room)
        defer { pane.close() }
        try await Task.sleep(for: .milliseconds(60))
        let field = try XCTUnwrap(pane.views(UITextField.self).first, name)
        let list = try XCTUnwrap(pane.listFrame(), name)
        // Content over by less than a point is not scrolled for it.
        XCTAssertLessThan(pane.height(in: room), room.height + 1, "\(name): the content is taller than its room")
        XCTAssertGreaterThan(pane.frame(of: field).minY, 15, "\(name): the field is cut off the top")
        XCTAssertLessThanOrEqual(pane.frame(of: field).maxY, room.height, name)
        let scroller = pane.paneScroller()
        if let scroller {
            let frame = pane.frame(of: scroller)
            XCTAssertTrue(try XCTUnwrap(pane.views(UICollectionView.self).first, name).isDescendant(of: scroller), name)
            XCTAssertGreaterThanOrEqual(frame.minY, pane.frame(of: field).maxY, name)
            XCTAssertLessThanOrEqual(frame.maxY, room.height, name)
            XCTAssertGreaterThan(scroller.contentSize.height, frame.height, "\(name): nothing to scroll to")
        } else {
            XCTAssertGreaterThanOrEqual(list.height, 44 - 0.5, name)
            XCTAssertEqual(list.maxY, room.height - 16, accuracy: 1, "\(name): the list ends where its room's padding begins")
        }
        return (list, scroller)
    }
    #endif

    /// Mounts the supplied views in real windows and lays each search state out: on their own,
    /// and in a navigation toolbar with the navigator placed by the host. SwiftUI builds no
    /// accessibility tree for an in-process query, so names and values are asserted on the
    /// controls model above; this exercises the views' own bodies on each platform.
    ///
    /// Set `EPUB_SNAPSHOT_DIR` (`TEST_RUNNER_EPUB_SNAPSHOT_DIR` under `xcodebuild`) to keep a PNG
    /// of each state for a visual check. Nothing is written otherwise.
    func testSuppliedViewsLayOutEverySearchState() async throws {
        let session = Session(), model = try controls(session)
        let content = VStack(alignment: .leading) {
            EPUBReaderControlStrip(controls: model, groups: [.pages, .search])
            EPUBSearchResultNavigator(controls: model)
            EPUBSearchResultPane(controls: model, onDismiss: {})
            EPUBSearchResultBrowser(controls: model, onClose: {})
        }.padding()
        let plain = MountedView(content)
        let toolbar = MountedView(NavigationStack {
            EPUBSearchResultList(controls: model)
                .toolbar {
                    EPUBReaderToolbar(controls: model, groups: [.search, .pages])
                    ToolbarItemGroup(placement: MountedView.navigatorPlacement) { EPUBSearchResultNavigator(controls: model) }
                }
        })
        // A large accessibility text size, where the navigator stacks its indicator and buttons.
        let large = MountedView(content.dynamicTypeSize(.accessibility3))
        defer { plain.close(); toolbar.close(); large.close() }
        var sizes: [String: CGSize] = [:]
        let states: [(String, EPUBSearchState, EPUBSearchResults?)] = [
            ("idle", .idle, nil), ("searching", .searching(query: "needle"), nil),
            ("failed", .failed(query: " ", error: .invalidCommand("The search text is empty or too long")), nil),
            ("empty", .completed(query: "absent", hasMatches: false), EPUBSearchResults(query: "absent")),
            ("listed", .completed(query: "needle", hasMatches: true), Self.results(7)),
            ("current", .completed(query: "needle", hasMatches: true), Self.results(7, current: 6)),
            ("truncated", .completed(query: "needle", hasMatches: true), Self.results(40, current: 0, truncated: true)),
        ]
        for (name, search, results) in states {
            session.publish(search, results)
            try await Task.sleep(for: .milliseconds(60))
            let fitted = plain.fittingSize()
            XCTAssertGreaterThan(fitted.width, 0, name)
            XCTAssertGreaterThan(fitted.height, 0, name)
            sizes[name] = fitted
            XCTAssertGreaterThan(large.fittingSize().height, 0, name)
            try await plain.snapshot("views-\(name)")
            try await toolbar.snapshot("toolbar-\(name)")
            try await large.snapshot("large-text-\(name)")
        }
        XCTAssertGreaterThan(try XCTUnwrap(sizes["listed"]).height, try XCTUnwrap(sizes["idle"]).height,
                             "results add the match navigator and the result list to the pane")
        session.close()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertGreaterThan(plain.fittingSize().height, 0)
        XCTAssertTrue(session.received.isEmpty, "laying the views out submits nothing")
    }
}

#if os(macOS)
private typealias PlatformView = NSView
private typealias PlatformScrollView = NSScrollView
#else
private typealias PlatformView = UIView
private typealias PlatformScrollView = UIScrollView
#endif

/// A SwiftUI view in a real window of the platform's own kind.
@MainActor private final class MountedView {
    #if os(macOS)
    static let navigatorPlacement = ToolbarItemPlacement.automatic
    private let window: NSWindow
    private let host: NSView
    #else
    static let navigatorPlacement = ToolbarItemPlacement.bottomBar
    private let window: UIWindow
    private let host: UIViewController
    private let fit: (CGSize) -> CGSize
    #endif

    /// With a `size`, the view is held to it as a sheet or popover of that size holds its
    /// content: whatever the window's size, and with no safe area.
    #if os(macOS)
    init(_ view: some View, size: CGSize? = nil) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: view)
        if let size {
            // As the window's content view the hosting view would resize the window to its own limits.
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 900))
            host.frame = NSRect(origin: .zero, size: size)
            root.addSubview(host)
            window.contentView = root
        } else { window.contentView = host }
        window.orderFront(nil)
    }
    #else
    init(_ view: some View, size: CGSize? = nil) {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
        let controller = UIHostingController(rootView: view)
        host = controller
        fit = { controller.sizeThatFits(in: $0) }
        if let size {
            let root = UIViewController()
            controller.safeAreaRegions = []
            root.addChild(controller)
            controller.view.frame = CGRect(origin: .zero, size: size)
            root.view.addSubview(controller.view)
            controller.didMove(toParent: root)
            window.rootViewController = root
        } else { window.rootViewController = controller }
        window.makeKeyAndVisible()
    }
    #endif

    func fittingSize() -> CGSize {
        layOut()
        #if os(macOS)
        return host.fittingSize
        #else
        return fit(CGSize(width: window.bounds.width, height: .greatestFiniteMagnitude))
        #endif
    }

    /// The size the view asks for when it is offered none, which is the size a popover takes.
    func idealSize() -> CGSize {
        layOut()
        return root.intrinsicContentSize
    }

    #if os(iOS)
    /// The height the view takes when offered `size`: more than its height when it does not fit.
    func height(in size: CGSize) -> CGFloat {
        layOut()
        return fit(size).height
    }
    #endif

    /// The platform views of one kind that SwiftUI made for the view, in tree order.
    func views<Kind: PlatformView>(_ kind: Kind.Type) -> [Kind] {
        layOut()
        var found: [Kind] = []
        func visit(_ view: PlatformView) {
            if let match = view as? Kind { found.append(match) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    /// Where one of them is in the mounted view, from its top.
    func frame(of view: PlatformView) -> CGRect { view.convert(view.bounds, to: root) }

    /// The scroll view the search pane puts under its field when its content does not fit: one
    /// that is neither a list's nor inside the field.
    func paneScroller() -> PlatformScrollView? {
        #if os(macOS)
        views(NSScrollView.self).first { !($0.documentView is NSTableView) && $0.enclosingScrollView == nil }
        #else
        views(UIScrollView.self).first { scroller in
            !(scroller is UICollectionView) && !views(UITextField.self).contains { scroller.isDescendant(of: $0) }
        }
        #endif
    }

    /// Where the result list is in the mounted view, if it has one.
    func listFrame() -> CGRect? {
        #if os(macOS)
        views(NSTableView.self).first?.enclosingScrollView.map(frame(of:))
        #else
        views(UICollectionView.self).first.map(frame(of:))
        #endif
    }

    private var root: PlatformView {
        #if os(macOS)
        host
        #else
        host.view
        #endif
    }

    private func layOut() {
        #if os(macOS)
        host.layoutSubtreeIfNeeded()
        #else
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
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

    /// Writes the window's content as a PNG when a snapshot directory is configured.
    func snapshot(_ name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["EPUB_SNAPSHOT_DIR"], !directory.isEmpty else { return }
        try await Task.sleep(for: .milliseconds(250))
        #if os(macOS)
        // The window's frame view, so a toolbar SwiftUI installs in the title bar is included.
        let view = window.contentView?.superview ?? host
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2, size = view.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { return }
        var background = NSColor.windowBackgroundColor.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        if !view.isFlipped {
            context.scaleBy(x: scale, y: scale)
        } else {
            context.translateBy(x: 0, y: size.height * scale)
            context.scaleBy(x: scale, y: -scale)
        }
        view.layer?.render(in: context)
        let data = bitmap.representation(using: .png, properties: [:])
        let platform = "mac"
        #else
        // The layer tree, as on the Mac: a test host's window is not composited to a screen.
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            UIColor.systemBackground.setFill()
            context.fill(window.bounds)
            window.layer.render(in: context.cgContext)
        }
        let data = image.pngData()
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
        try data?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(platform)-\(name).png"))
    }
}
