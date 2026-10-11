import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing

/// The event paragraphs of `doc/native-viewer.md` and the session's life around its view:
/// published state, locations, disclosures, detaching and remounting, closing from a callback,
/// and command bursts.
@MainActor final class SessionCoverageEventTests: XCTestCase {
    private typealias Section = SessionCoverageBook.Section

    private func open(_ data: Data, onEvent: (@MainActor (EPUBReaderEvent) -> Void)? = nil) throws -> SessionCoverageReader {
        let reader = try SessionCoverageReader(data, onEvent: onEvent)
        addTeardownBlock { @MainActor in reader.close() }
        return reader
    }

    // MARK: Published state

    /// `doc/reader-controls.md`: "Update state before the corresponding event"; "Results exist
    /// only while `status.search` is `.completed`."
    func testPublishedStateAlreadyHoldsWhatEachEventReports() async throws {
        var holder: SessionCoverageReader?
        var mismatches: [String] = []
        let reader = try open(SessionCoverageBook.chapters()) { event in
            guard let status = holder?.state.status else { return }
            switch event {
            case .ready:
                if status.lifecycle != .ready { mismatches.append("ready while \(status.lifecycle)") }
            case .relocated(let location):
                if status.location != location { mismatches.append("relocated to \(location.href ?? "") while state has \(status.location?.href ?? "nothing")") }
            case .searchChanged(let search):
                if status.search != search { mismatches.append("\(search) while state has \(status.search)") }
            case .searchResultsChanged(let results):
                if status.searchResults != results { mismatches.append("results \(results?.count ?? -1) while state has \(status.searchResults?.count ?? -1)") }
            default: break
            }
            if status.searchResults != nil, case .completed = status.search {} else if status.searchResults != nil {
                mismatches.append("results published while search is \(status.search)")
            }
            if status.lifecycle != .ready { mismatches.append("\(event) while \(status.lifecycle)") }
        }
        holder = reader
        let session = reader.session, state = reader.state
        XCTAssertEqual(state.status.lifecycle, .loading)
        XCTAssertNil(state.status.location)
        XCTAssertNil(state.status.canGoNext)
        try await reader.settle()
        XCTAssertEqual(reader.events.first, .ready)
        try await session.send(.navigate(href: "OPS/two.xhtml#mid"))
        try await session.send(.nextPage)
        try await session.send(.nextPage)
        try await session.send(.search(text: "findword"))
        try await session.send(.nextSearchResult)
        let scrolled = EPUBReaderStyle(fontSize: 20, appearance: .dark, flow: .scrolled)
        try await session.send(.style(scrolled))
        XCTAssertEqual(state.status.style, scrolled)
        XCTAssertEqual(state.status.effectiveAppearance, .dark)
        try await reader.settle()
        try await session.send(.previousSearchResult)
        try await session.send(.locate(text: "No such passage anywhere.", highlight: false))
        try await session.send(.searchHighlight(text: "unique destination"))
        do { try await session.send(.search(text: " ")); XCTFail("An empty query was accepted") } catch {}
        guard case .failed(" ", .invalidCommand) = state.status.search else { return XCTFail("No failure for the refused query: \(state.status.search)") }
        XCTAssertNil(state.status.searchResults)
        try await session.send(.clearSearch)
        try await session.send(.style(EPUBReaderStyle()))
        XCTAssertEqual(state.status.effectiveAppearance, .light)
        try await reader.settle()
        try await session.send(.search(text: "findword"))
        XCTAssertEqual(mismatches, [])
        XCTAssertEqual(state.status.activeCommands, 0)
        XCTAssertEqual(state.status.location, reader.locations.last)

        let last = reader.locations.last
        session.close()
        XCTAssertEqual(state.status.lifecycle, .closed)
        XCTAssertEqual(state.status.search, .idle)
        XCTAssertNil(state.status.searchResults)
        XCTAssertEqual(state.status.location, last, "the state stays readable after close")
        XCTAssertEqual(state.status.capabilities, session.capabilities)
        XCTAssertEqual(reader.events.filter { $0 == .ready }.count, 1)
    }

    // MARK: Locations

    /// "`.relocated` carries … the table-of-contents title for the position": with entries
    /// inside one document, the one whose heading the page has reached.
    func testTheContentsTitleFollowsEntriesWithinOneDocument() async throws {
        let reader = try open(SessionCoverageBook.epub([
            Section("preface", "<p>A preface the contents do not list.</p>"),
            Section("long", "<h2 id=\"a\">Part A</h2>\(SessionCoverageBook.filler(120))<h2 id=\"b\">Part B</h2>\(SessionCoverageBook.filler(120))"),
        ], toc: "<li><a href=\"long.xhtml#a\">Part A</a></li><li><a href=\"long.xhtml#b\">Part B</a></li>"))
        try await reader.settle()
        XCTAssertEqual(reader.locations.first?.href, "OPS/preface.xhtml")
        XCTAssertNil(reader.locations.first?.title, "before the first contents entry")
        try await reader.session.send(.navigate(href: "OPS/long.xhtml"))
        try await reader.wait("the long chapter") { reader.session.lastLocation?.href == "OPS/long.xhtml" }
        XCTAssertEqual(reader.session.lastLocation?.title, "Part A")
        let partB = try reader.anchor("b", section: 1)
        try await reader.session.send(.navigate(href: "OPS/long.xhtml#b"))
        try await reader.wait("part B") { reader.isVisible(partB) && reader.locations.last == reader.session.lastLocation }
        XCTAssertEqual(reader.session.lastLocation?.title, "Part B")
        let controls = EPUBReaderControls(publication: reader.publication, session: reader.session)
        XCTAssertEqual(reader.publication.tableOfContents.map(controls.isCurrent), [false, true], "the checkmark follows the title")
        try await reader.session.send(.previousPage)
        try await reader.wait("the page before part B") { reader.session.visibleRange.map { $0.end <= partB } ?? false }
        try await reader.wait("its location") { reader.locations.last == reader.session.lastLocation }
        XCTAssertEqual(reader.session.lastLocation?.title, "Part A", "a page that ends before the heading is still part A")
        XCTAssertEqual(reader.publication.tableOfContents.map(controls.isCurrent), [true, false])
        try await reader.session.send(.nextPage)
        try await reader.wait("part B again") { reader.session.lastLocation?.title == "Part B" }
    }

    /// "overall progression (by section byte size, as foliate-js computed it)"; `NativeSession`:
    /// "A page is read to its end … the last page of a book is 1."
    func testProgressionRisesPageByPageToExactlyOneAndIsZeroAtTheTopOfAScrolledBook() async throws {
        let reader = try open(SessionCoverageBook.chapters())
        try await reader.settle()
        let progress = NativeProgress(publication: reader.publication)
        func bounds(_ section: Int) throws -> ClosedRange<Double> {
            try XCTUnwrap(progress.progression(section: section, fraction: 0))...XCTUnwrap(progress.progression(section: section, fraction: 1))
        }
        var seen: [Double] = []
        for turn in 0..<400 {
            let location = try XCTUnwrap(reader.session.lastLocation)
            let value = try XCTUnwrap(location.progression, "turn \(turn)")
            let section = try XCTUnwrap(reader.section)
            XCTAssertTrue(try bounds(section).contains(value), "turn \(turn): \(value) is outside section \(section)")
            if let last = seen.last { XCTAssertGreaterThan(value, last, "turn \(turn)") }
            seen.append(value)
            if reader.state.status.canGoNext == false { break }
            let shown = reader.session.visibleRange
            try await reader.session.send(.nextPage)
            try await reader.wait("turn \(turn + 1)") { reader.session.visibleRange != shown && reader.locations.last == reader.session.lastLocation }
        }
        XCTAssertGreaterThan(seen.count, 5)
        XCTAssertGreaterThan(try XCTUnwrap(seen.first), 0, "the first page is read to its end")
        XCTAssertEqual(seen.last, 1, "the last page of the book")
        XCTAssertEqual(reader.section, 3)

        // The nonlinear note weighs nothing: it reads as the end of the chapter before it.
        try await reader.session.send(.navigate(href: "OPS/note.xhtml"))
        try await reader.wait("the note") { reader.session.lastLocation?.href == "OPS/note.xhtml" }
        XCTAssertEqual(reader.session.lastLocation?.progression, try bounds(0).upperBound)

        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.session.send(.navigate(href: "OPS/one.xhtml"))
        try await reader.wait("the top of the scrolled book") {
            reader.session.canvas?.scrollBook != nil && reader.session.visibleRange?.start == ReaderTextPosition(section: 0, offset: 0)
                && reader.locations.last == reader.session.lastLocation
        }
        XCTAssertEqual(reader.session.lastLocation?.progression, 0, "a scrolled view is measured at its top")
        var last = 0.0
        for turn in 0..<400 where reader.state.status.canGoNext != false {
            let shown = reader.session.visibleRange
            try await reader.session.send(.nextPage)
            try await reader.wait("scrolled turn \(turn)") { reader.session.visibleRange != shown && reader.locations.last == reader.session.lastLocation }
            let value = try XCTUnwrap(reader.session.lastLocation?.progression)
            XCTAssertGreaterThanOrEqual(value, last, "scrolled turn \(turn)")
            XCTAssertLessThanOrEqual(value, 1)
            last = value
        }
        XCTAssertGreaterThan(last, 0.5, "the end of the book is past its middle")
    }

    // MARK: Failures and disclosures

    /// `doc/native-viewer.md`: entity declarations are refused; `SectionBuilder`: "so the rest
    /// of the book stays readable". The reader stays ready and says what it withheld.
    func testASectionThatCannotBeReadIsDisclosedAndTheRestOfTheBookStaysReadable() async throws {
        let refused = "<?xml version=\"1.0\"?><!DOCTYPE html [<!ENTITY bomb \"boom\">]>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>&bomb; withheldword</p></body></html>"
        for first in [false, true] {
            let sections = [
                Section("one", "<p>Readable opening with keptword.</p>"), Section("bad", raw: refused),
                Section("noise", raw: "\u{1}\u{2}\u{3} << not markup >> & nothing closes <p"), Section("void", raw: ""),
                Section("three", "<p>Readable ending with keptword.</p>"),
            ]
            let reader = try open(SessionCoverageBook.epub(first ? Array(sections.dropFirst()) : sections))
            try await reader.settle()
            let bad = first ? 0 : 1, last = first ? 3 : 4
            XCTAssertEqual(reader.session.book.section(bad)?.report.withheld, true)
            XCTAssertEqual(reader.locations.first?.href, first ? "OPS/bad.xhtml" : "OPS/one.xhtml", "the book still opens at its first section")
            try await reader.wait("the disclosure") {
                reader.events.contains { if case .disclosure(let text) = $0 { return text.contains("Some sections of this book could not be shown.") }; return false }
            }
            // Every section is still a page turn or a navigation away.
            var seen: [Int] = [try XCTUnwrap(reader.section)]
            for turn in 0..<20 where reader.state.status.canGoNext != false {
                let shown = reader.session.visibleRange
                try await reader.session.send(.nextPage)
                try await reader.wait("turn \(turn)") { reader.session.visibleRange != shown || reader.state.status.canGoNext == false }
                if let section = reader.section, seen.last != section { seen.append(section) }
            }
            XCTAssertEqual(seen, Array(0...last))
            try await reader.session.send(.navigate(href: "OPS/bad.xhtml"))
            try await reader.wait("the withheld section") { reader.session.lastLocation?.href == "OPS/bad.xhtml" }
            XCTAssertEqual(reader.session.lastLocation?.publicationID, reader.publication.id)
            // Its refused text is not searchable; the rest of the book is.
            try await reader.session.send(.search(text: "withheldword"))
            XCTAssertEqual(reader.state.status.search, .completed(query: "withheldword", hasMatches: false))
            try await reader.session.send(.search(text: "keptword"))
            XCTAssertEqual(reader.state.status.searchResults?.results.map(\.spineIndex), first ? [last] : [0, last])
            try await reader.session.send(.locate(text: "Readable ending", highlight: true))
            try await reader.wait("the last section") { reader.section == last }
            XCTAssertFalse(reader.events.contains { if case .failed = $0 { return true }; return false }, "\(reader.events)")
            XCTAssertEqual(reader.state.status.lifecycle, .ready)
            XCTAssertEqual(reader.events.filter { $0 == .ready }.count, 1)
            reader.close()
        }
    }

    /// "`.disclosure` text summarises the books' `SectionReport`s and is re-emitted when it
    /// changes" — and only then: not for a rebuild, a flow change or a navigation.
    func testADisclosureIsEmittedOnlyWhenItsTextChanges() async throws {
        func scripted(_ count: Int) -> String {
            "<p>Words beside \(count) scripts.</p>" + String(repeating: "<script>window.x = 1</script>", count: count) + SessionCoverageBook.filler(20)
        }
        let reader = try open(SessionCoverageBook.epub([Section("one", scripted(1)), Section("two", scripted(2)), Section("three", scripted(0))]))
        try await reader.settle()
        func disclosures() -> [String] { reader.events.compactMap { if case .disclosure(let text) = $0 { return text }; return nil } }
        try await reader.wait("the whole book's disclosure") { disclosures().last == "3 interactive parts of this document were not run." }
        let first = disclosures()
        XCTAssertTrue(zip(first, first.dropFirst()).allSatisfy { $0 != $1 }, "the same text twice: \(first)")
        XCTAssertLessThanOrEqual(first.count, 3)
        XCTAssertTrue(reader.events.firstIndex(of: .ready)! < reader.events.firstIndex { if case .disclosure = $0 { return true }; return false }!,
                      "a disclosure follows readiness")
        for style in [EPUBReaderStyle(fontSize: 25), EPUBReaderStyle(fontSize: 25, appearance: .dark, flow: .scrolled), EPUBReaderStyle()] {
            try await reader.session.send(.style(style))
            try await reader.wait("the rebuilt book") { reader.session.book.isComplete && reader.session.book.typography.fontSize == style.fontSize }
            try await reader.session.send(.navigate(href: "OPS/two.xhtml"))
            try await reader.session.send(.navigate(href: "OPS/three.xhtml"))
        }
        try await reader.settle()
        XCTAssertEqual(disclosures(), first, "a rebuild repeats no disclosure")
    }

    // MARK: Detaching and remounting

    /// `doc/reader-controls.md`: controls "remain disabled until ready, after close/failure or
    /// while the surface is detached"; "The native session maintains `readerState` for direct
    /// commands, input navigation, remounts and close."
    func testAReaderTakenOutOfTheHierarchyRefusesCommandsUntilItIsMountedAgain() async throws {
        let reader = try SessionCoverageReader(SessionCoverageBook.chapters(), mounted: false)
        let window = SessionCoverageStageWindow(session: reader.session)
        addTeardownBlock { @MainActor in reader.close(); window.close() }
        let session = reader.session, state = reader.state
        try await reader.settle()
        let mid = try reader.anchor("mid", section: 2)
        try await session.send(.navigate(href: "OPS/two.xhtml#mid"))
        try await session.send(.search(text: "unique destination"))
        let found = try XCTUnwrap(state.status.searchResults)
        try await session.send(.navigate(href: "OPS/two.xhtml#mid"))
        try await reader.wait("the midpoint") { reader.isVisible(mid) && reader.locations.last == session.lastLocation }
        let drawn = Set(session.drawnHighlights)
        XCTAssertFalse(drawn.isEmpty)
        let location = try XCTUnwrap(state.status.location)
        let controls = EPUBReaderControls(publication: reader.publication, session: session)
        XCTAssertTrue(controls.isReady && controls.canGoNext && controls.canShowSearchResults)

        window.stage.mounted = false
        try await reader.wait("the detached reader") { state.status.lifecycle == .loading }
        XCTAssertNil(session.canvas)
        let count = reader.events.count
        for command in [EPUBReaderCommand.nextPage, .previousPage, .navigate(href: "OPS/one.xhtml"), .restore(location), .clearSearch,
                        .nextSearchResult, .showSearchResult(found.results[0]), .style(EPUBReaderStyle(fontSize: 30)), .setHighlights([]),
                        .locate(text: "Opening words", highlight: true), .search(text: "findword")] {
            do { try await session.send(command); XCTFail("A detached reader accepted \(command)") }
            catch { XCTAssertEqual(error as? EPUBReaderError, .notReady, "\(command)") }
        }
        XCTAssertFalse(controls.isReady)
        XCTAssertFalse(controls.canGoNext || controls.canGoPrevious || controls.canShowSearchResults)
        controls.send(.nextPage)
        controls.showNextSearchResult()
        XCTAssertEqual(controls.pendingCommands, 0, "nothing is queued for a detached reader")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(reader.events.count, count, "a detached reader emitted \(reader.events.dropFirst(count))")
        XCTAssertEqual(state.status.location, location, "what was published stays readable")
        XCTAssertEqual(state.status.searchResults, found)
        XCTAssertEqual(state.status.style, EPUBReaderStyle())
        XCTAssertEqual(state.status.activeCommands, 0)

        window.stage.mounted = true
        try await reader.wait("the remounted reader") { state.status.lifecycle == .ready && session.canvas?.visibleRange != nil }
        XCTAssertEqual(reader.events.filter { $0 == .ready }.count, 1, "readiness is public once")
        try await reader.wait("the same place") { reader.isVisible(mid) }
        XCTAssertEqual(Set(session.drawnHighlights), drawn, "the same highlights")
        XCTAssertEqual(state.status.searchResults, found)
        XCTAssertTrue(controls.isReady && controls.canShowSearchResults)
        try await session.send(.navigate(href: "OPS/three.xhtml"))
        try await reader.wait("chapter three") { reader.section == 3 && session.lastLocation?.href == "OPS/three.xhtml" }

        // Closed while detached, it stays closed when its view returns.
        window.stage.mounted = false
        try await reader.wait("the detached reader") { state.status.lifecycle == .loading }
        session.close()
        XCTAssertEqual(state.status.lifecycle, .closed)
        let closed = reader.events.count
        window.stage.mounted = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(session.canvas)
        XCTAssertEqual(state.status.lifecycle, .closed)
        XCTAssertEqual(reader.events.count, closed)
    }

    /// `View.epubReaderDivision(_:)`: "Reserves a vertical division of the reader … Horizontal
    /// divisions and nil reserve nothing."
    func testAReservedDivisionReachesTheMountedReaderAndChangesLive() async throws {
        let reader = try SessionCoverageReader(SessionCoverageBook.chapters(), mounted: false)
        let window = SessionCoverageStageWindow(session: reader.session)
        addTeardownBlock { @MainActor in reader.close(); window.close() }
        try await reader.settle()
        let mid = try reader.anchor("mid", section: 2)
        try await reader.session.send(.navigate(href: "OPS/two.xhtml#mid"))
        try await reader.wait("the midpoint") { reader.isVisible(mid) }
        let canvas = try XCTUnwrap(reader.session.canvas)
        XCTAssertNil(canvas.configuration.division)
        let columns = canvas.textViews.count
        let relocations = reader.locations.count

        let fold = CGRect(x: canvas.bounds.midX - 10, y: 0, width: 20, height: canvas.bounds.height)
        window.stage.division = fold
        try await reader.wait("the fold") { canvas.configuration.division == fold }
        XCTAssertTrue(reader.session.canvas === canvas, "the reader is not remounted")
        try await reader.wait("the midpoint beside the fold") { reader.isVisible(mid) }
        if canvas.bounds.width >= 560 {
            XCTAssertEqual(canvas.textViews.count, 2, "a column on each side of the fold")
            XCTAssertTrue(canvas.textViews.allSatisfy { $0.frame.maxX <= fold.minX || $0.frame.minX >= fold.maxX }, "text never crosses it")
        }
        // A horizontal division reserves nothing.
        let hinge = CGRect(x: 0, y: canvas.bounds.midY - 10, width: canvas.bounds.width, height: 20)
        window.stage.division = hinge
        try await reader.wait("the hinge") { canvas.configuration.division == hinge }
        XCTAssertEqual(canvas.textViews.count, columns)
        window.stage.division = nil
        try await reader.wait("no division") { canvas.configuration.division == nil }
        XCTAssertEqual(canvas.textViews.count, columns)
        try await reader.wait("the midpoint") { reader.isVisible(mid) }
        XCTAssertEqual(reader.events.filter { $0 == .ready }.count, 1)
        XCTAssertTrue(reader.locations.dropFirst(relocations).allSatisfy { $0.href == "OPS/two.xhtml" })
    }

    func testTheSelectionActionsTitleAndImageReachTheMountedReader() async throws {
        var performed: [EPUBSelection] = []
        let action = EPUBSelectionAction(title: "Quote this") { performed.append($0) }
        XCTAssertEqual(action.systemImage, "text.quote")
        let reader = try SessionCoverageReader(Fixture.epub(), action: EPUBSelectionAction(title: "Cite", systemImage: "quote.opening") { performed.append($0) })
        addTeardownBlock { @MainActor in reader.close() }
        try await reader.settle()
        XCTAssertEqual(reader.session.canvas?.configuration.selectionActionTitle, "Cite")
        XCTAssertEqual(reader.session.canvas?.configuration.selectionActionImage, "quote.opening")
        // With nothing selected the action has nothing to act on.
        reader.session.canvasDidRequestSelectionAction(try XCTUnwrap(reader.session.canvas))
        XCTAssertTrue(performed.isEmpty)
        try await reader.session.send(.locate(text: "Opening words are visible.", highlight: true))
        try await reader.wait("the selection") { reader.selections().last??.text == "Opening words are visible." }
        reader.session.canvasDidRequestSelectionAction(try XCTUnwrap(reader.session.canvas))
        XCTAssertEqual(performed.map(\.text), ["Opening words are visible."])
        XCTAssertEqual(performed.first, reader.selections().last.flatMap { $0 }, "the action receives what the event reported")
        // Without an action there is none to offer.
        let plain = try open(Fixture.epub())
        try await plain.settle()
        XCTAssertNil(plain.session.canvas?.configuration.selectionActionTitle)
    }

    // MARK: Links and turns the view asks for

    /// "`.notice` reports refused external links"; `doc/architecture.md`: "external links are
    /// refused with a notice". Links inside the book navigate as `.navigate(href:)` does.
    func testActivatedLinksNavigateInsideTheBookAndAreRefusedOutsideIt() async throws {
        let reader = try open(SessionCoverageBook.chapters())
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        let origin = ReaderTextPosition(section: 0, offset: 0)
        func activate(_ link: ReaderLink) { reader.session.canvas(canvas, didActivate: link, at: origin, rect: CGRect(x: 10, y: 10, width: 40, height: 20)) }

        var count = reader.events.count
        for outside in ["https://example.invalid/page", "mailto:reader@example.invalid", "../../outside.xhtml"] {
            activate(.external(outside))
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(reader.notices(since: count), Array(repeating: "This reader does not open links outside the book.", count: 3))
        XCTAssertEqual(reader.events.count, count + 3, "a refused link does nothing else: \(reader.events.dropFirst(count))")
        XCTAssertEqual(reader.section, 0)

        let mid = try reader.anchor("mid", section: 2)
        activate(.internal(href: "OPS/two.xhtml#mid"))
        try await reader.wait("the link's target") { reader.isVisible(mid) && reader.session.lastLocation?.href == "OPS/two.xhtml" }
        // A note reference whose note the book does not hold goes to its target instead.
        activate(.note(href: "OPS/three.xhtml#no-such-note"))
        try await reader.wait("the missing note's document") { reader.section == 3 }
        XCTAssertNil(canvas.presentedNote)

        // A link to nothing in the book leaves the reader where it is.
        count = reader.events.count
        let place = reader.session.visibleRange
        for dead in ["OPS/missing.xhtml", "OPS/missing.xhtml#x", "", "OPS/nav.xhtml"] {
            activate(.internal(href: dead))
            activate(.note(href: dead))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reader.session.visibleRange, place)
        XCTAssertTrue(reader.locations(since: count).isEmpty)
        XCTAssertEqual(reader.state.status.lifecycle, .ready)

        reader.session.close()
        count = reader.events.count
        activate(.external("https://example.invalid/page"))
        activate(.internal(href: "OPS/one.xhtml"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reader.events.count, count, "a closed reader follows no link")
    }

    /// `ReaderCanvasDelegate`: "A page turn or scroll needs a section that is not built. When it
    /// is, the session shows its start (`forward`) or end." Newer navigation replaces it.
    func testASectionTheViewAsksForIsShownAtItsStartOrEndUnlessNavigationIntervenes() async throws {
        let reader = try open(SessionCoverageBook.chapters())
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        reader.session.canvas(canvas, needsSection: 2, forward: true)
        try await reader.wait("the section's start") { reader.session.visibleRange?.start == ReaderTextPosition(section: 2, offset: 0) }
        let length = try XCTUnwrap(reader.session.book.section(0)?.string.length)
        reader.session.canvas(canvas, needsSection: 0, forward: false)
        try await reader.wait("the section's end") {
            reader.session.visibleRange.map { $0.start.section == 0 && $0.end == ReaderTextPosition(section: 0, offset: length) } ?? false
        }
        XCTAssertEqual(reader.state.status.canGoPrevious, true)
        // Asked for and then overtaken by a command, it is not shown.
        reader.session.canvas(canvas, needsSection: 2, forward: true)
        try await reader.session.send(.navigate(href: "OPS/three.xhtml"))
        try await reader.wait("the navigation") { reader.section == 3 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reader.section, 3)
        XCTAssertEqual(reader.session.lastLocation?.href, "OPS/three.xhtml")
    }

    // MARK: Closing from a callback

    /// `doc/architecture.md`: "`close` is idempotent, disables callbacks and releases renderer
    /// references"; hosts "may provide their own fallback", which means closing the reader when
    /// an event says so. Closes the session inside the first event `trigger` accepts.
    private func closing(_ data: Data, on trigger: @escaping (EPUBReaderEvent) -> Bool,
                         drive: (SessionCoverageReader) async throws -> Void = { _ in }) async throws {
        var holder: SessionCoverageReader?
        var closedAt: Int?
        let reader = try open(data) { event in
            guard closedAt == nil, trigger(event), let reader = holder else { return }
            reader.session.close()
            closedAt = reader.events.count
        }
        holder = reader
        try await drive(reader)
        try await reader.wait("the event that closes the reader") { closedAt != nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(reader.events.count, closedAt, "events after close: \(reader.events.dropFirst(closedAt ?? 0))")
        XCTAssertEqual(reader.state.status.lifecycle, .closed)
        XCTAssertEqual(reader.state.status.activeCommands, 0)
        XCTAssertNil(reader.session.canvas)
        do { try await reader.session.send(.nextPage); XCTFail("A closed reader accepted a command") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .closed) }
    }

    private static func scriptedBook() throws -> Data {
        try SessionCoverageBook.epub([
            Section("one", "<p>Opening words.</p><script>window.x = 1</script>\(SessionCoverageBook.filler(30))"),
            Section("two", "<p>Second chapter with findword.</p>\(SessionCoverageBook.filler(30))"),
        ])
    }

    func testClosingInsideTheReadyEventLeavesAQuietClosedReader() async throws {
        try await closing(Self.scriptedBook(), on: { $0 == .ready })
    }

    func testClosingInsideTheFirstRelocationLeavesAQuietClosedReader() async throws {
        try await closing(Self.scriptedBook(), on: { if case .relocated = $0 { return true }; return false })
    }

    func testClosingInsideADisclosureLeavesAQuietClosedReader() async throws {
        try await closing(Self.scriptedBook(), on: { if case .disclosure = $0 { return true }; return false })
    }

    func testClosingInsideALaterRelocationLeavesAQuietClosedReader() async throws {
        var relocations = 0
        try await closing(Self.scriptedBook(), on: {
            if case .relocated = $0 { relocations += 1 }
            return relocations == 3
        }, drive: { reader in
            try await reader.wait("the reader") { reader.session.isReady && reader.session.lastLocation != nil }
            for _ in 0..<6 { try? await reader.session.send(.nextPage) }
        })
    }

    func testClosingInsideSearchEventsLeavesAQuietClosedReader() async throws {
        let triggers: [(EPUBReaderEvent) -> Bool] = [
            { if case .searchChanged(.searching) = $0 { return true }; return false },
            { if case .searchResultsChanged(.some) = $0 { return true }; return false },
            { if case .searchChanged(.completed) = $0 { return true }; return false },
        ]
        for trigger in triggers {
            try await closing(Self.scriptedBook(), on: trigger, drive: { reader in
                try await reader.settle()
                try? await reader.session.send(.search(text: "findword"))
            })
        }
    }

    func testClosingInsideSelectionAndNoticeEventsLeavesAQuietClosedReader() async throws {
        try await closing(Self.scriptedBook(), on: { if case .selectionChanged(.some) = $0 { return true }; return false }, drive: { reader in
            try await reader.settle()
            try? await reader.session.send(.locate(text: "Second chapter with findword.", highlight: true))
        })
        try await closing(Self.scriptedBook(), on: { if case .notice = $0 { return true }; return false }, drive: { reader in
            try await reader.settle()
            try? await reader.session.send(.locate(text: "No such passage.", highlight: true))
        })
    }

    // MARK: Sessions and their books

    func testTwoSessionsOnOnePublicationReadIndependently() async throws {
        let publication = try EPUBPublication.open(data: SessionCoverageBook.chapters())
        let first = try SessionCoverageReader(publication: publication), second = try SessionCoverageReader(publication: publication)
        addTeardownBlock { @MainActor in first.close(); second.close() }
        try await first.settle()
        try await second.settle()
        XCTAssertFalse(first.session.book === second.session.book)
        let untouched = second.events.count, place = second.session.visibleRange
        try await first.session.send(.style(EPUBReaderStyle(fontSize: 30, appearance: .dark, flow: .scrolled)))
        try await first.session.send(.navigate(href: "OPS/three.xhtml"))
        try await first.session.send(.searchHighlight(text: "findword"))
        try await first.settle()
        XCTAssertEqual(first.section, 3)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(second.events.count, untouched, "the other session heard \(second.events.dropFirst(untouched))")
        XCTAssertEqual(second.session.visibleRange, place)
        XCTAssertEqual(second.state.status.style, EPUBReaderStyle())
        XCTAssertEqual(second.session.book.typography, NativeTypography())
        XCTAssertNil(second.state.status.searchResults)
        XCTAssertTrue(second.session.drawnHighlights.isEmpty)

        // Closing one leaves the other reading, and a location from one restores in the other.
        let saved = try XCTUnwrap(first.session.lastLocation)
        first.close()
        try await second.session.send(.restore(saved))
        try await second.wait("the other session's place") { second.section == 3 }
        try await second.session.send(.search(text: "findword"))
        XCTAssertEqual(second.state.status.searchResults?.count, 2)
        XCTAssertEqual(first.state.status.lifecycle, .closed)
        XCTAssertEqual(second.state.status.lifecycle, .ready)
    }

    /// A host that drops a session it never mounted, without closing it, leaks neither the
    /// session nor its book: nothing the session starts holds it.
    func testASessionDroppedWithoutClosingIsReleasedWithItsBook() async throws {
        weak var session: NativeSession?
        weak var book: NativeBook?
        var events = 0
        do {
            let publication = try EPUBPublication.open(data: SessionCoverageBook.epub(
                (0..<30).map { Section("s\($0)", "<h1>Section \($0)</h1>\(SessionCoverageBook.filler(200))") }))
            let made = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in events += 1 } as? NativeSession)
            session = made
            book = made.book
            // Its first section is being built, and it has been asked for work it cannot do yet.
            do { try await made.send(.nextPage); XCTFail("An unmounted reader accepted a command") } catch {}
        }
        let deadline = Date().addingTimeInterval(20)
        while session != nil || book != nil {
            guard Date() < deadline else { return XCTFail("The dropped session is still alive: session \(session != nil), book \(book != nil)") }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(events, 0)
    }

    func testABookOfThreeHundredSectionsOpensNavigatesAndSearchesThroughout() async throws {
        let reader = try open(SessionCoverageBook.epub((0..<300).map {
            Section("s\($0)", "<h1>Section \($0)</h1><p>The marker zebraword stands in section \($0).</p>", title: "Section \($0)")
        }))
        try await reader.settle()
        XCTAssertEqual(reader.session.book.count, 300)
        XCTAssertEqual(reader.locations.first?.title, "Section 0")
        try await reader.session.send(.navigate(href: "OPS/s299.xhtml"))
        try await reader.wait("the last section") { reader.section == 299 && reader.session.lastLocation?.href == "OPS/s299.xhtml" }
        XCTAssertEqual(reader.session.lastLocation?.title, "Section 299")
        XCTAssertEqual(reader.session.lastLocation?.progression, 1)
        XCTAssertEqual(reader.state.status.canGoNext, false)
        try await reader.session.send(.previousPage)
        try await reader.wait("the section before it") { reader.section == 298 }

        try await reader.session.send(.search(text: "zebraword"))
        let found = try XCTUnwrap(reader.state.status.searchResults)
        XCTAssertEqual(found.results.map(\.spineIndex), Array(0..<300))
        XCTAssertFalse(found.isTruncated)
        XCTAssertEqual(found.results.map(\.sectionTitle), (0..<300).map { "Section \($0)" })
        let progressions = found.results.compactMap(\.location.progression)
        XCTAssertEqual(progressions.count, 300)
        XCTAssertTrue(zip(progressions, progressions.dropFirst()).allSatisfy { $0 < $1 })
        try await reader.wait("the first match") { reader.section == 0 }
        try await reader.session.send(.previousSearchResult)
        try await reader.wait("the last match") { reader.section == 299 }
        XCTAssertEqual(reader.state.status.searchResults?.currentIndex, 299)

        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book") { reader.session.canvas?.scrollBook != nil }
        XCTAssertEqual(reader.session.canvas?.scrollBook?.sectionStarts.count, 300)
        try await reader.session.send(.navigate(href: "OPS/s150.xhtml"))
        try await reader.wait("the middle of the book") { reader.session.visibleRange?.start == ReaderTextPosition(section: 150, offset: 0) }
        XCTAssertEqual(reader.events.filter { $0 == .ready }.count, 1)
        XCTAssertFalse(reader.events.contains { if case .failed = $0 { return true }; return false })
    }

    // MARK: Rebuilds and cancellation

    /// "Until every section is built it shows the current section, then swaps to the whole book
    /// in place." A text size taken back before its rebuild finished leaves sections to rebuild
    /// again; once they are, the whole book must return.
    func testContinuousScrollShowsTheWholeBookAgainAfterATextSizeIsTakenBackMidRebuild() async throws {
        // Sections of growing size, so a rebuild reaches the small ones long before the large.
        let reader = try open(SessionCoverageBook.epub((0..<10).map {
            Section("s\($0)", "<h1>Section \($0)</h1>\(SessionCoverageBook.filler(60 + $0 * 250))")
        }))
        try await reader.settle()
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book") { reader.session.canvas?.scrollBook != nil && reader.section == 0 }
        let book = reader.session.book, regular = book.typography

        // Take the larger size back as soon as its rebuild has reached a section that is not on screen.
        var reverted: Task<Void, Error>?
        var rebuildWasUnfinished: Bool?
        let report = book.onSectionBuilt
        book.onSectionBuilt = { [weak reader] index in
            report?(index)
            guard reverted == nil, index != 0, book.typography != regular, let reader else { return }
            reverted = Task {
                rebuildWasUnfinished = !book.isComplete
                try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
            }
        }
        try await reader.session.send(.style(EPUBReaderStyle(fontSize: 24, flow: .scrolled)))
        try await reader.wait("the size taken back") { reverted != nil }
        try await reverted?.value
        XCTAssertEqual(rebuildWasUnfinished, true, "the larger rebuild finished before the size was taken back; grow the fixture")
        try await reader.wait("the book at its first size") { book.isComplete && book.typography == regular }
        XCTAssertNotNil(book.bookText)
        try? await reader.wait("the whole book again", timeout: 5) { reader.session.canvas?.scrollBook != nil }
        XCTAssertNotNil(reader.session.canvas?.scrollBook,
                        "every section is built, but continuous scroll still shows section \(String(describing: reader.session.canvas?.scrollTextView?.placement.section)) alone")
    }

    /// "`.searchResultsChanged` reports … nil when a clear, another query, a failure, a
    /// cancellation or `.locate` withdraws the list"; "Results exist only while `status.search`
    /// is `.completed`." A cancellation that arrives as the results are published either comes
    /// too late or withdraws them; it cannot report an idle search beside a published list.
    func testACancellationArrivingWithTheResultsLeavesSearchStateAndResultsAgreeing() async throws {
        var search: Task<Void, Error>?
        let reader = try open(SessionCoverageBook.chapters()) { event in
            if case .searchResultsChanged(.some) = event { search?.cancel() }
        }
        try await reader.settle()
        search = Task { try await reader.session.send(.search(text: "findword")) }
        _ = await search?.result
        try await Task.sleep(for: .milliseconds(100))
        let status = reader.state.status
        XCTAssertEqual(status.activeCommands, 0)
        guard status.searchResults != nil else {
            // The cancellation won: the list was withdrawn and said to be.
            XCTAssertEqual(status.search, .idle)
            XCTAssertEqual(reader.events.last { if case .searchResultsChanged = $0 { return true }; return false }, .searchResultsChanged(nil))
            return XCTAssertTrue(reader.session.drawnHighlights.isEmpty)
        }
        // The cancellation came too late: the search completed, and reads as completed.
        XCTAssertEqual(status.search, .completed(query: "findword", hasMatches: true),
                       "\(status.searchResults?.count ?? 0) results stay published and drawn while the search reads \(status.search)")
    }

    // MARK: Bursts

    /// A page turn or a navigation into a section that is still being built shows it when it is.
    func testTurnsAndNavigationIssuedTheMomentTheReaderIsReadyArrive() async throws {
        let data = try SessionCoverageBook.epub([Section("s0", "<p>A single opening line.</p>")] + (1..<6).map {
            Section("s\($0)", "<h1>Section \($0)</h1>\(SessionCoverageBook.filler(900))")
        })
        var holder: SessionCoverageReader?
        var turned: Task<Void, Error>?
        var builtWhenTurned: Bool?
        let reader = try open(data) { event in
            guard event == .ready, let reader = holder else { return }
            turned = Task {
                builtWhenTurned = reader.session.book.section(1) != nil
                try await reader.session.send(.nextPage)
            }
        }
        holder = reader
        try await reader.wait("the turn") { turned != nil }
        try await turned?.value
        try await reader.wait("the second section (built when turned: \(String(describing: builtWhenTurned)))") {
            reader.session.visibleRange?.start == ReaderTextPosition(section: 1, offset: 0)
        }
        XCTAssertEqual(reader.locations.map(\.href).reduce(into: [String?]()) { if $0.last != $1 { $0.append($1) } }, ["OPS/s0.xhtml", "OPS/s1.xhtml"])
        reader.close()

        // A navigation issued behind a pending turn is the newer intent and wins.
        var second: SessionCoverageReader?
        var sent: Task<Void, Error>?
        let other = try open(data) { event in
            guard event == .ready, let reader = second else { return }
            sent = Task {
                try await reader.session.send(.nextPage)
                try await reader.session.send(.navigate(href: "OPS/s4.xhtml"))
            }
        }
        second = other
        try await other.wait("the commands") { sent != nil }
        try await sent?.value
        try await other.settle()
        XCTAssertEqual(other.section, 4)
        XCTAssertEqual(other.locations.last?.href, "OPS/s4.xhtml")
        XCTAssertEqual(other.state.status.activeCommands, 0)
    }

    func testStyleChangesInterleavedWithNavigationEndAtTheLastOfEach() async throws {
        let reader = try open(SessionCoverageBook.chapters())
        try await reader.wait("the reader") { reader.session.isReady }
        let targets = ["OPS/two.xhtml#mid", "OPS/one.xhtml", "OPS/three.xhtml", "OPS/note.xhtml", "OPS/two.xhtml", "OPS/one.xhtml#start"]
        let sections = ["OPS/one.xhtml": 0, "OPS/note.xhtml": 1, "OPS/two.xhtml": 2, "OPS/three.xhtml": 3]
        var style = EPUBReaderStyle()
        var href = ""
        for step in 0..<30 {
            style = EPUBReaderStyle(fontSize: 14 + Double(step % 7) * 2, appearance: step % 3 == 0 ? .dark : .light, flow: step % 4 < 2 ? .paginated : .scrolled)
            href = targets[(step * 5) % targets.count]
            try await reader.session.send(.style(style))
            try await reader.session.send(.navigate(href: href))
            if step % 6 == 2 { try await reader.session.send(.nextPage) }
        }
        let document = String(href.split(separator: "#")[0])
        let section = try XCTUnwrap(sections[document])
        XCTAssertEqual(reader.state.status.style, style)
        try await reader.wait("the last style's book") {
            reader.session.book.isComplete && reader.session.book.typography == NativeTypography(fontSize: style.fontSize, isDark: style.appearance == .dark)
        }
        try await reader.settle()
        try await reader.wait("the last navigation's section") { reader.section == section }
        XCTAssertEqual(reader.session.canvas?.configuration.flow, style.flow)
        XCTAssertEqual(reader.session.lastLocation?.href, document)
        XCTAssertEqual(reader.state.status.activeCommands, 0)
        XCTAssertEqual(reader.state.status.lifecycle, .ready)
        XCTAssertEqual(reader.events.filter { $0 == .ready }.count, 1)
        XCTAssertFalse(reader.events.contains { if case .failed = $0 { return true }; return false })
    }

    /// `doc/reader-controls.md`: "direct `session.send` calls may interleave at suspension
    /// points". Whatever the interleaving, the reader ends ready, located and consistent.
    func testCommandsFromSeveralTasksLeaveAConsistentReader() async throws {
        let reader = try open(SessionCoverageBook.chapters())
        try await reader.wait("the reader") { reader.session.isReady }
        let session = reader.session
        func commands(seed: UInt64) -> [EPUBReaderCommand] {
            var state = seed
            func next(_ bound: Int) -> Int {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Int((state >> 33) % UInt64(bound))
            }
            let hrefs = ["OPS/one.xhtml", "OPS/note.xhtml", "OPS/two.xhtml#mid", "OPS/three.xhtml", "OPS/missing.xhtml", "#nothing"]
            let queries = ["findword", "ordinary reading", "unique destination", "absent unicorn"]
            return (0..<25).map { _ in
                switch next(12) {
                case 0, 1: return .nextPage
                case 2: return .previousPage
                case 3, 4: return .navigate(href: hrefs[next(hrefs.count)])
                case 5: return .style(EPUBReaderStyle(fontSize: Double(13 + next(6) * 3), flow: next(2) == 0 ? .paginated : .scrolled))
                case 6: return .search(text: queries[next(queries.count)])
                case 7: return .searchHighlight(text: queries[next(queries.count)])
                case 8: return .clearSearch
                case 9: return next(2) == 0 ? .nextSearchResult : .previousSearchResult
                case 10: return .locate(text: next(2) == 0 ? "Closing words with findword" : "No such passage.", highlight: next(2) == 0)
                default: return .setHighlights([])
                }
            }
        }
        let tasks = (1...4).map { seed in
            Task { @MainActor in
                for command in commands(seed: UInt64(seed) &* 0x9E37_79B9) {
                    try? await session.send(command)
                    await Task.yield()
                }
            }
        }
        for task in tasks { await task.value }
        XCTAssertEqual(reader.state.status.activeCommands, 0)
        try await reader.settle()
        let status = reader.state.status
        XCTAssertEqual(status.lifecycle, .ready)
        XCTAssertEqual(status.location, reader.session.lastLocation)
        let visible = try XCTUnwrap(reader.session.visibleRange)
        for position in [visible.start, visible.end] {
            let length = try XCTUnwrap(session.book.section(position.section)?.string.length)
            XCTAssertTrue((0...length).contains(position.offset), "\(position) is outside its section")
        }
        XCTAssertTrue(visible.start <= visible.end)
        let drawn = session.drawnHighlights.filter { $0.kind == .search }.count
        switch status.search {
        case .idle:
            XCTAssertNil(status.searchResults)
            XCTAssertEqual(drawn, 0, "matches stay drawn with no search")
        case .completed(_, let hasMatches):
            let results = try XCTUnwrap(status.searchResults)
            XCTAssertEqual(hasMatches, !results.isEmpty)
            XCTAssertEqual(drawn, results.count, "each listed result is one drawn match")
            XCTAssertEqual(session.searchResultRanges.count, results.count)
        case .searching, .failed:
            XCTFail("every command has returned, yet the search reads \(status.search)")
        }
        XCTAssertEqual(reader.events.filter { $0 == .ready }.count, 1)
        XCTAssertFalse(reader.events.contains { if case .failed = $0 { return true }; return false })
        // And it still reads.
        try await session.send(.style(EPUBReaderStyle()))
        try await session.send(.navigate(href: "OPS/three.xhtml"))
        try await reader.wait("chapter three") { reader.section == 3 }
    }
}
