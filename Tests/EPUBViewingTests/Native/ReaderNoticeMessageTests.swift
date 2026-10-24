import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// What the bundled reader's notices say (https://github.com/vocaro/EPUBLib/issues/698): a short
/// sentence that a host shows as it is, with no highlight's `id` or other detail in it, and one
/// for each list of highlights however many of them it cannot draw. The status names those.
@MainActor final class ReaderNoticeMessageTests: XCTestCase {
    private typealias Section = SessionCoverageBook.Section

    static let savedPositionNotFound = "The saved position could not be found in this book."
    static let passageNotFound = "The passage could not be found in this book."
    static let highlightsNotDrawn = "Some highlights could not be shown."
    /// Every notice the bundled reader gives in its own words. The notices of a link outside the
    /// book are #683's, and plain already.
    static let sentences = [savedPositionNotFound, passageNotFound, highlightsNotDrawn]

    private func open() async throws -> SessionCoverageReader {
        let reader = try SessionCoverageReader(SessionCoverageBook.epub([
            Section("one", "<p>Opening words.</p>\(SessionCoverageBook.filler(20))"),
            Section("two", "<p>Closing words.</p>\(SessionCoverageBook.filler(20))"),
        ]))
        addTeardownBlock { @MainActor in reader.close() }
        try await reader.settle()
        return reader
    }

    private func location(_ reader: SessionCoverageReader, _ value: String) -> EPUBLocation {
        EPUBLocation(publicationID: reader.publication.id, bookmark: EPUBEngineBookmark(
            engineID: NativeEngine.identifier, format: NativeEngine.bookmarkFormat, value: value))
    }

    /// The first word of each section, "Opening" and "Closing".
    private static let opening = "epubcfi(/6/2!/4/2,/1:0,/1:7)"
    private static let closing = "epubcfi(/6/4!/4/2,/1:0,/1:7)"
    /// A passage in an element its section lacks, and one in a section the book lacks.
    private static let missingElement = "epubcfi(/6/2!/4/900,/1:0,/1:7)"
    private static let missingSection = "epubcfi(/6/400!/4/2,/1:0,/1:7)"

    /// A saved position the book has not got, a passage it does not hold and a highlight of
    /// another book's each give a reader a plain sentence: capitalized, ended, short, and with
    /// none of the host's own identifiers in it.
    func testEachNoticeIsAPlainSentence() async throws {
        let reader = try await open()
        var count = reader.events.count
        try await reader.session.send(.restore(location(reader, Self.missingElement)))
        try await reader.wait("the saved position's notice") { !reader.notices(since: count).isEmpty }
        XCTAssertEqual(reader.notices(since: count), [Self.savedPositionNotFound])

        count = reader.events.count
        try await reader.session.send(.locate(text: "Nothing like this sentence is in the book.", highlight: false))
        try await reader.wait("the passage's notice") { !reader.notices(since: count).isEmpty }
        XCTAssertEqual(reader.notices(since: count), [Self.passageNotFound])

        count = reader.events.count
        var foreign = location(reader, Self.opening)
        foreign.publicationID = "another book"
        let id = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        try await reader.session.send(.setHighlights([EPUBHighlight(id: id, location: foreign)]))
        XCTAssertEqual(reader.notices(since: count), [Self.highlightsNotDrawn])

        XCTAssertEqual(reader.notices(), Self.sentences)
        for notice in reader.notices() {
            XCTAssertEqual(notice.first.map { String($0) }, notice.first.map { String($0).uppercased() }, notice)
            XCTAssertTrue(notice.hasSuffix("."), notice)
            XCTAssertLessThanOrEqual(notice.split(separator: " ").count, 10, notice)
            XCTAssertFalse(notice.contains(id), notice)
            XCTAssertFalse(notice.contains(":"), notice)
            for word in ["highlight's", "cited", "CFI", "href", "id"] {
                XCTAssertFalse(notice.split(separator: " ").contains(Substring(word)), "\(word) in \(notice)")
            }
        }
    }

    /// One notice for each list of highlights, however many of it are not drawn and for whatever
    /// reason; none for a list the reader draws whole, and none again when a later layout finds
    /// the same passages missing.
    func testOneNoticeForEachListOfHighlightsHoweverManyAreNotDrawn() async throws {
        let reader = try await open()
        let kept = location(reader, Self.opening)
        var foreign = kept
        foreign.publicationID = "another book"
        var unbookmarked = kept
        unbookmarked.bookmark = nil
        let elsewhere = location(reader, Self.missingSection), absent = location(reader, Self.missingElement)
        func annotations() -> [String] { reader.session.drawnHighlights.filter { $0.kind == .annotation }.map(\.id) }

        var count = reader.events.count
        try await reader.session.send(.setHighlights([
            EPUBHighlight(id: "kept", location: kept), EPUBHighlight(id: "foreign", location: foreign),
            EPUBHighlight(id: "unbookmarked", location: unbookmarked), EPUBHighlight(id: "elsewhere", location: elsewhere),
            EPUBHighlight(id: "absent", location: absent), EPUBHighlight(id: "closing", location: location(reader, Self.closing)),
        ]))
        XCTAssertEqual(annotations(), ["kept", "closing"])
        XCTAssertEqual(reader.notices(since: count), [Self.highlightsNotDrawn], "four not drawn, one notice")

        // The next list has its own notice, and a later layout gives none.
        count = reader.events.count
        try await reader.session.send(.setHighlights([EPUBHighlight(id: "kept", location: kept), EPUBHighlight(id: "absent", location: absent)]))
        XCTAssertEqual(reader.notices(since: count), [Self.highlightsNotDrawn])
        try await reader.session.send(.style(EPUBReaderStyle(fontSize: 26)))
        try await reader.wait("the larger text") { reader.state.status.effectiveFontSize == 26 }
        try await reader.settle()
        try await TestDeadline.pause(.milliseconds(100))
        XCTAssertEqual(annotations(), ["kept"])
        XCTAssertEqual(reader.notices(since: count), [Self.highlightsNotDrawn], "a layout notices nothing again")

        // A list drawn whole, and an empty one, give none.
        count = reader.events.count
        try await reader.session.send(.setHighlights([EPUBHighlight(id: "kept", location: kept)]))
        try await reader.session.send(.setHighlights([]))
        try await TestDeadline.pause(.milliseconds(100))
        XCTAssertEqual(reader.notices(since: count), [])
    }

    /// Highlights sent the moment the reader is ready, whose passages are found missing as their
    /// sections are built one after another, still give one notice.
    func testOneNoticeWhenHighlightsAreFoundMissingAsTheirSectionsAreBuilt() async throws {
        let sections = [Section("one", "<p>Opening words.</p>")] + (0..<12).map {
            Section("later\($0)", "<h1>Later \($0)</h1>\(SessionCoverageBook.filler(150))<p>The far passage number \($0) ends here.</p>")
        }
        let data = try SessionCoverageBook.epub(sections)
        let publication = try EPUBPublication.open(data: data)
        // Elements the twelfth and thirteenth sections (`/6/24`, `/6/26`) lack.
        let highlights = [24, 26].map { step in
            EPUBHighlight(id: "far\(step)", location: EPUBLocation(publicationID: publication.id, bookmark: EPUBEngineBookmark(
                engineID: NativeEngine.identifier, format: NativeEngine.bookmarkFormat, value: "epubcfi(/6/\(step)!/4/900,/1:0,/1:8)")))
        }
        var sent: Task<Void, Error>?
        var builtWhenSent: [Bool] = []
        var holder: SessionCoverageReader?
        let reader = try SessionCoverageReader(data, onEvent: { event in
            guard event == .ready, let reader = holder else { return }
            sent = Task {
                builtWhenSent = [11, 12].map { reader.session.book.section($0) != nil }
                try await reader.session.send(.setHighlights(highlights))
            }
        })
        holder = reader
        addTeardownBlock { @MainActor in reader.close() }
        try await reader.wait("the highlight command") { sent != nil }
        try await sent?.value
        try await reader.settle()
        try await TestDeadline.pause(.milliseconds(100))
        XCTAssertTrue(reader.session.drawnHighlights.filter { $0.kind == .annotation }.isEmpty)
        XCTAssertEqual(reader.notices(), [Self.highlightsNotDrawn], "built when sent: \(builtWhenSent)")
    }

    /// The status names each highlight of the latest list that is not drawn, by its `id`, with
    /// why, before the notice says so; the next list replaces it, and a passage found missing as
    /// its section is built joins it then.
    func testTheStatusNamesEachHighlightNotDrawnAndWhy() async throws {
        let reader = try await open()
        XCTAssertEqual(reader.state.status.undrawnHighlights, [:])
        let kept = location(reader, Self.opening)
        var foreign = kept
        foreign.publicationID = "another book"
        var unbookmarked = kept
        unbookmarked.bookmark = nil
        // What the status names as each notice is given.
        final class Named { var value: [[String: EPUBHighlightFailure]] = [] }
        let named = Named()
        reader.onEvent = { [weak reader] event in
            if case .notice = event, let reader { named.value.append(reader.state.status.undrawnHighlights) }
        }
        try await reader.session.send(.setHighlights([
            EPUBHighlight(id: "kept", location: kept), EPUBHighlight(id: "foreign", location: foreign),
            EPUBHighlight(id: "unbookmarked", location: unbookmarked),
            EPUBHighlight(id: "elsewhere", location: location(reader, Self.missingSection)),
            EPUBHighlight(id: "absent", location: location(reader, Self.missingElement)),
        ]))
        XCTAssertEqual(reader.state.status.undrawnHighlights, [
            "foreign": .incompatibleLocation, "unbookmarked": .incompatibleLocation,
            "elsewhere": .passageNotFound, "absent": .passageNotFound,
        ])
        XCTAssertEqual(named.value.count, 1)
        XCTAssertFalse(named.value.first?.isEmpty ?? true, "the status names them before the notice")

        try await reader.session.send(.setHighlights([EPUBHighlight(id: "absent", location: location(reader, Self.missingElement))]))
        XCTAssertEqual(reader.state.status.undrawnHighlights, ["absent": .passageNotFound])
        try await reader.session.send(.setHighlights([EPUBHighlight(id: "kept", location: kept)]))
        XCTAssertEqual(reader.state.status.undrawnHighlights, [:])
        try await reader.session.send(.setHighlights([EPUBHighlight(id: "foreign", location: foreign)]))
        XCTAssertEqual(reader.state.status.undrawnHighlights, ["foreign": .incompatibleLocation])
        try await reader.session.send(.setHighlights([]))
        XCTAssertEqual(reader.state.status.undrawnHighlights, [:])
        XCTAssertEqual(named.value.count, 3, "one notice for each list with highlights not drawn")
    }

    /// The session's notices are these sentences, which the catalog test holds EPUBViewing's
    /// string catalog to.
    func testTheSessionGivesTheseSentences() {
        XCTAssertEqual([NativeSession.savedPositionNotFound, NativeSession.passageNotFound, NativeSession.highlightsNotDrawn],
                       Self.sentences)
    }
}
