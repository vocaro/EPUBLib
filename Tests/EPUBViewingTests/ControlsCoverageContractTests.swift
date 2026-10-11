import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBViewing
import EPUBViewingTestSupport
import SwiftUI
import XCTest

/// A renderer-free engine written against the public contract alone, correct for whatever
/// capabilities it is given, with one deliberate fault at a time.
@MainActor private struct ControlsCoverageContractEngine: EPUBReaderEngine {
    enum Fault {
        case none
        // Lifecycle and capabilities.
        case acceptsCommandsAfterClose, wrongErrorAfterClose, emitsOnSecondClose
        case acceptsAnUnsupportedCommand, wrongErrorForAnUnsupportedCommand, refusesAnAdvertisedCommand
        // Navigation, locations and bookmarks.
        case navigationDoesNotRelocate, restoreDoesNotRelocate, restoreGoesElsewhere
        case locationsOfAnotherPublication, bookmarksOfAnotherEngine, bookmarksWithoutAValue, bookmarksWithoutAFormat, noBookmarks
        case acceptsAForeignPublication, acceptsAForeignEngine, acceptsAForeignFormat, wrongErrorForAForeignLocation
        // Search results.
        case completesWithoutResults, resultsOutOfOrder, resultsOfAnotherPublication, resultsOfAnotherQuery, currentMatchOutsideTheList
        case nextDoesNotStep, showDoesNotSelect, doesNotWrapForward, checksOnlyAResultsIndex
        case stateDoesNotMirrorResults, stateKeepsClearedResults, publishesResultsWithoutTheCapability
    }
    static let everything: Set<EPUBReaderCapability> = [.pagination, .scrolling, .typography, .selection, .bookmarks, .locateText,
                                                        .navigateHref, .searchHighlight, .highlights, .search, .searchResults]
    let id = "coverage.contract"
    var capabilities = Self.everything
    var fault = Fault.none
    var publishesState = true
    func makeSession(publication: EPUBPublication, selectionAction: EPUBSelectionAction?,
                     onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
        ControlsCoverageContractSession(engine: self, book: publication, onEvent: onEvent)
    }
}

@MainActor private final class ControlsCoverageContractSession: EPUBReaderSession {
    let capabilities: Set<EPUBReaderCapability>
    let readerState: EPUBReaderState?
    private let book: EPUBPublication
    private let fault: ControlsCoverageContractEngine.Fault
    private var onEvent: (@MainActor (EPUBReaderEvent) -> Void)?
    private var closed = false, ready = false
    private var results: EPUBSearchResults?

    init(engine: ControlsCoverageContractEngine, book: EPUBPublication, onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) {
        capabilities = engine.capabilities
        fault = engine.fault
        self.book = book
        self.onEvent = onEvent
        readerState = engine.publishesState ? EPUBReaderState(status: EPUBReaderStatus(capabilities: engine.capabilities)) : nil
    }

    private func publish(_ change: (inout EPUBReaderStatus) -> Void) {
        guard let readerState else { return }
        var status = readerState.status
        change(&status)
        readerState.update(status)
    }

    func makeView() -> AnyView {
        guard !closed else { return AnyView(EmptyView()) }
        if !ready {
            ready = true
            publish { $0.lifecycle = .ready }
            onEvent?(.ready)
            // As a reader does, it reports where the book opens.
            relocate(book.spine.first?.resource.href)
        }
        return AnyView(Text(book.metadata.title))
    }

    private func place(_ href: String) -> EPUBLocation {
        var bookmark: EPUBEngineBookmark? = EPUBEngineBookmark(engineID: "coverage.contract", format: "href-v1", value: href)
        switch fault {
        case .bookmarksOfAnotherEngine: bookmark?.engineID = "another.engine"
        case .bookmarksWithoutAValue: bookmark?.value = ""
        case .bookmarksWithoutAFormat: bookmark?.format = ""
        case .noBookmarks: bookmark = nil
        default: break
        }
        return EPUBLocation(publicationID: fault == .locationsOfAnotherPublication ? "another publication" : book.id, href: href,
                            bookmark: capabilities.contains(.bookmarks) ? bookmark : nil)
    }

    private func relocate(_ href: String?) {
        guard let href else { return }
        let location = place(href)
        publish { $0.location = location }
        onEvent?(.relocated(location))
    }

    private func require(_ capability: EPUBReaderCapability) throws -> Bool {
        if capabilities.contains(capability) {
            if fault == .refusesAnAdvertisedCommand, capability == .highlights { throw EPUBReaderError.unsupported(capability) }
            return true
        }
        switch fault {
        case .acceptsAnUnsupportedCommand: return false
        case .wrongErrorForAnUnsupportedCommand: throw EPUBReaderError.invalidCommand("This engine cannot do that")
        default: throw EPUBReaderError.unsupported(capability)
        }
    }

    private func set(_ list: EPUBSearchResults?) {
        results = list
        switch fault {
        case .stateDoesNotMirrorResults: break
        case .stateKeepsClearedResults where list == nil: break
        default: publish { $0.searchResults = list }
        }
        onEvent?(.searchResultsChanged(list))
    }

    private func show(_ index: Int) {
        guard var list = results else { return }
        list.currentIndex = index
        set(list)
        relocate(list.current?.location.href)
    }

    private func search(_ text: String, opensFirst: Bool) {
        let lists = capabilities.contains(.searchResults) || fault == .publishesResultsWithoutTheCapability
        if results != nil { set(nil) }
        publish { $0.search = .searching(query: text) }
        onEvent?(.searchChanged(.searching(query: text)))
        let completion = EPUBSearchState.completed(query: text, hasMatches: true)
        guard lists, fault != .completesWithoutResults else {
            publish { $0.search = completion }
            onEvent?(.searchChanged(completion))
            return
        }
        var listed = book.spine.enumerated().map { index, item in
            EPUBSearchResult(index: index, location: EPUBLocation(publicationID: fault == .resultsOfAnotherPublication ? "another publication" : book.id,
                                                                  href: item.resource.href, quote: text),
                             spineIndex: index, sectionTitle: "Section \(index + 1)", matchedText: text)
        }
        if fault == .resultsOutOfOrder { listed.reverse() }
        var list = EPUBSearchResults(query: fault == .resultsOfAnotherQuery ? text + "!" : text, results: listed, currentIndex: opensFirst ? 0 : nil)
        if fault == .currentMatchOutsideTheList { list.currentIndex = listed.count + 4 }
        publish { $0.search = completion }
        set(list)
        if opensFirst { relocate(listed.first?.location.href) }
        onEvent?(.searchChanged(completion))
    }

    func send(_ command: EPUBReaderCommand) async throws {
        try Task.checkCancellation()
        if closed {
            switch fault {
            case .acceptsCommandsAfterClose: return
            case .wrongErrorAfterClose: throw EPUBReaderError.notReady
            default: throw EPUBReaderError.closed
            }
        }
        guard ready else { throw EPUBReaderError.notReady }
        switch command {
        case .nextPage, .previousPage: _ = try require(.pagination)
        case .navigate(let href):
            guard try require(.navigateHref), fault != .navigationDoesNotRelocate else { return }
            relocate(href)
        case .restore(let location):
            guard try require(.bookmarks) else { return }
            let compatible = (location.publicationID == book.id || fault == .acceptsAForeignPublication)
                && (location.bookmark?.engineID == place(location.href ?? "").bookmark?.engineID || fault == .acceptsAForeignEngine)
                && (location.bookmark?.format == place(location.href ?? "").bookmark?.format || fault == .acceptsAForeignFormat)
            guard compatible else {
                throw fault == .wrongErrorForAForeignLocation ? EPUBReaderError.invalidCommand("Not this book's") : EPUBReaderError.incompatibleLocation
            }
            switch fault {
            case .restoreDoesNotRelocate: break
            case .restoreGoesElsewhere: relocate(book.spine.last { $0.resource.href != location.href }?.resource.href)
            default: relocate(location.href)
            }
        case .locate: _ = try require(.locateText)
        case .search(let text): if try require(.search) { search(text, opensFirst: true) }
        case .searchHighlight(let text): if try require(.searchHighlight) { search(text, opensFirst: false) }
        case .clearSearch:
            guard try require(.searchHighlight) else { return }
            if results != nil { set(nil) }
            publish { $0.search = .idle }
            onEvent?(.searchChanged(.idle))
        case .nextSearchResult, .previousSearchResult:
            let forward = command == .nextSearchResult
            guard try require(.searchResults), let results, var index = results.steppedIndex(forward: forward) else { return }
            if fault == .nextDoesNotStep, forward { return }
            if fault == .doesNotWrapForward, forward, results.isAtLast { index = results.count - 1 }
            show(index)
        case .showSearchResult(let result):
            guard try require(.searchResults) else { return }
            guard let results, results.results.indices.contains(result.index),
                  fault == .checksOnlyAResultsIndex || results.results[result.index] == result else {
                throw EPUBReaderError.invalidCommand("Not a current search result")
            }
            if fault != .showDoesNotSelect { show(result.index) }
        case .setHighlights: _ = try require(.highlights)
        case .style(let style):
            if style.flow == .scrolled, try !require(.scrolling) { return }
            if style.fontSize != EPUBReaderStyle().fontSize, try !require(.typography) { return }
            publish { $0.style = style }
        }
    }

    func close() {
        if closed, fault == .emitsOnSecondClose { onEvent?(.notice("closed again")) }
        guard !closed else { return }
        closed = true
        results = nil
        publish { $0.lifecycle = .closed; $0.search = .idle; $0.searchResults = nil }
        if fault != .emitsOnSecondClose { onEvent = nil }
    }
}

/// `doc/testing.md`, Adapter contract tests: every check the verifier is documented to make,
/// against an engine that breaks exactly that clause.
@MainActor final class ControlsCoverageContractTests: XCTestCase {
    private typealias Engine = ControlsCoverageContractEngine

    /// The verifier's failure for an engine, nil when the engine passes. An error the engine
    /// itself threw through the verifier counts as a failure and is described.
    private func verdict(_ engine: Engine, text: String = "Opening words") async throws -> String? {
        do {
            try await EPUBEngineContract.verify(engine: engine, publication: EPUBPublication.open(data: Fixture.epub()),
                firstHref: "OPS/one.xhtml", secondHref: "OPS/two.xhtml", text: text, timeout: 0.3) { session in
                    _ = session.makeView()
                    return {}
                }
            return nil
        } catch let failure as EPUBEngineContract.Failure {
            XCTAssertEqual(failure.errorDescription, failure.description)
            return failure.description
        } catch { return "threw \(error)" }
    }

    private func expectRejected(_ fault: Engine.Fault, _ expected: String, capabilities: Set<EPUBReaderCapability> = Engine.everything,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let found = try await verdict(Engine(capabilities: capabilities, fault: fault))
        XCTAssertTrue(found?.contains(expected) == true, "\(fault): expected a failure naming \"\(expected)\", found \(found ?? "a pass")", file: file, line: line)
    }

    /// The faultless engine passes with every set of capabilities, so each rejection below is
    /// the fault's and not the engine's shape.
    func testACorrectEnginePassesWhateverItsCapabilities() async throws {
        let shapes: [Set<EPUBReaderCapability>] = [
            Engine.everything, [.pagination], [], [.navigateHref], [.navigateHref, .bookmarks], [.bookmarks],
            [.pagination, .typography], [.pagination, .scrolling], [.pagination, .scrolling, .typography, .locateText, .highlights, .selection],
            [.navigateHref, .bookmarks, .searchHighlight], [.navigateHref, .bookmarks, .searchHighlight, .searchResults],
            [.navigateHref, .bookmarks, .searchHighlight, .search], Engine.everything.subtracting([.searchResults]),
        ]
        for capabilities in shapes {
            let found = try await verdict(Engine(capabilities: capabilities))
            XCTAssertNil(found, "\(capabilities.map(\.rawValue).sorted())")
        }
        // An engine may publish no state at all.
        let found = try await verdict(Engine(publishesState: false))
        XCTAssertNil(found, "without published state")
    }

    /// "Close is idempotent; closed commands fail and later callbacks are suppressed."
    func testTheVerifierRejectsEnginesThatStayOpenAfterClose() async throws {
        try await expectRejected(.acceptsCommandsAfterClose, "Accepted command that should throw closed")
        try await expectRejected(.wrongErrorAfterClose, "Expected closed, received notReady")
        try await expectRejected(.emitsOnSecondClose, "Callback after close")
    }

    /// "Advertised commands can be submitted; unsupported commands return the matching
    /// capability error."
    func testTheVerifierRejectsEnginesWhoseCommandsDoNotMatchTheirCapabilities() async throws {
        // One capability missing at a time, so each command's own check is the one that fails.
        let commands: [(EPUBReaderCapability, String)] = [
            (.pagination, "pagination"), (.navigateHref, "navigateHref"), (.locateText, "locateText"), (.search, "search)"),
            (.highlights, "highlights"), (.typography, "typography"), (.scrolling, "scrolling"), (.bookmarks, "bookmarks"),
            (.searchResults, "searchResults"),
        ]
        for (capability, name) in commands {
            let capabilities = Engine.everything.subtracting([capability])
            try await expectRejected(.acceptsAnUnsupportedCommand, name, capabilities: capabilities)
            try await expectRejected(.wrongErrorForAnUnsupportedCommand, name, capabilities: capabilities)
        }
        // Without highlighting, neither a highlight-only search nor a clear is supported.
        let noHighlighting = Engine.everything.subtracting([.searchHighlight, .searchResults])
        try await expectRejected(.acceptsAnUnsupportedCommand, "searchHighlight", capabilities: noHighlighting)
        try await expectRejected(.refusesAnAdvertisedCommand, "threw unsupported")
    }

    /// "Href navigation changes sections and bookmark restoration returns to the saved section."
    func testTheVerifierRejectsEnginesThatDoNotNavigateOrRestore() async throws {
        try await expectRejected(.navigationDoesNotRelocate, "Timed out waiting for second href")
        try await expectRejected(.restoreDoesNotRelocate, "Timed out waiting for restoration")
        try await expectRejected(.restoreGoesElsewhere, "Timed out waiting for restoration")
    }

    /// "Locations carry the publication identity and a valid engine-tagged bookmark when
    /// supported."
    func testTheVerifierRejectsLocationsWithoutThePublicationOrAValidBookmark() async throws {
        try await expectRejected(.locationsOfAnotherPublication, "Wrong publication identity")
        try await expectRejected(.bookmarksOfAnotherEngine, "Missing or wrong bookmark engine identity")
        try await expectRejected(.noBookmarks, "Missing or wrong bookmark engine identity")
        try await expectRejected(.bookmarksWithoutAValue, "Invalid engine bookmark")
        try await expectRejected(.bookmarksWithoutAFormat, "Invalid engine bookmark")
        // An engine that cannot navigate by href is held to the same locations.
        try await expectRejected(.locationsOfAnotherPublication, "Location belongs to another publication", capabilities: [.bookmarks, .pagination])
    }

    /// "Foreign publication, engine and bookmark format identities are rejected", each on its own.
    func testTheVerifierRejectsEnginesThatAcceptAnyOneForeignIdentity() async throws {
        for fault in [Engine.Fault.acceptsAForeignPublication, .acceptsAForeignEngine, .acceptsAForeignFormat] {
            try await expectRejected(fault, "Accepted command that should throw incompatibleLocation")
        }
        try await expectRejected(.wrongErrorForAForeignLocation, "Expected incompatibleLocation, received invalidCommand")
    }

    /// "An engine with `.searchResults` lists the phrase's results before reporting completion,
    /// with indices in order and the publication's identity; steps … and selects …; mirrors the
    /// list in `readerState` when it has one … An engine without it … publishes no results."
    func testTheVerifierRejectsEnginesWhoseResultListIsMissingOrWrong() async throws {
        try await expectRejected(.completesWithoutResults, "Search completed without publishing results")
        try await expectRejected(.resultsOutOfOrder, "Result indices must match their order")
        try await expectRejected(.resultsOfAnotherPublication, "Result belongs to another publication")
        try await expectRejected(.resultsOfAnotherQuery, "Results name another query")
        try await expectRejected(.currentMatchOutsideTheList, "Current match is not a listed result")
        try await expectRejected(.nextDoesNotStep, "Timed out waiting for next search result")
        try await expectRejected(.showDoesNotSelect, "Timed out waiting for selected search result")
        try await expectRejected(.stateDoesNotMirrorResults, "Reader state does not mirror the published search results")
        try await expectRejected(.stateKeepsClearedResults, "Reader state kept cleared search results")
        try await expectRejected(.publishesResultsWithoutTheCapability, "Search results published without the capability",
                                 capabilities: Engine.everything.subtracting([.searchResults]))
    }

    /// "steps, wraps and selects as `EPUBSearchResults.steppedIndex(forward:)` says": a step
    /// forward from the last result returns to the first, as one backward from the first
    /// returns to the last.
    func testTheVerifierRejectsAnEngineThatDoesNotWrapForwardFromTheLastResult() async throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/160")
        let found = try await verdict(Engine(fault: .doesNotWrapForward))
        XCTAssertNotNil(found, "an engine whose Next Match stops at the last result passed the verifier")
    }

    /// "refuses an unlisted result": `.showSearchResult` is for "one of the current
    /// `EPUBSearchResults.results`", so a result kept from a replaced search, whose index is
    /// still in range, is unlisted too.
    func testTheVerifierRejectsAnEngineThatChecksOnlyAResultsIndex() async throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/160")
        let found = try await verdict(Engine(fault: .checksOnlyAResultsIndex))
        XCTAssertNotNil(found, "an engine that shows any result whose index is in range passed the verifier")
    }
}
