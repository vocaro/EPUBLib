import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing

/// A position and a highlight saved in a book, restored in copies of it
/// (https://github.com/vocaro/EPUBLib/issues/679, #680). A location carried the SHA-256 of the
/// file's bytes and was refused in a copy downloaded again, zipped again or edited in its
/// metadata, and a book unpacked into a folder did not open. Locations now carry the book's
/// `persistentID`, which each such copy shares.
@MainActor final class PublicationIdentitySessionTests: XCTestCase {
    private func wait(_ label: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = TestDeadline(seconds: timeout)
        while !condition() {
            guard try !deadline.hasPassed() else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private struct Reader {
        let session: NativeSession
        let window: ReaderTestWindow
        let events: () -> [EPUBReaderEvent]
        func close() { session.close(); window.close() }
    }

    private func reader(_ publication: EPUBPublication) async throws -> Reader {
        var events: [EPUBReaderEvent] = []
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) {
            events.append($0)
        } as? NativeSession)
        let reader = Reader(session: session, window: ReaderTestWindow(session: session), events: { events })
        try await wait("ready") { events.contains(.ready) && session.lastLocation != nil }
        return reader
    }

    /// A position two pages into chapter two, where the page shown is the one its CFI names, and a
    /// passage on chapter two's first page, saved in `publication`.
    private func save(in publication: EPUBPublication) async throws -> (position: EPUBLocation, start: ReaderTextPosition, passage: EPUBLocation) {
        let reader = try await reader(publication)
        defer { reader.close() }
        try await reader.session.send(.navigate(href: "OPS/two.xhtml"))
        try await wait("chapter two") { reader.session.visibleRange?.start.section == 1 }
        for _ in 0..<2 {
            let before = reader.session.visibleRange?.start
            try await reader.session.send(.nextPage)
            try await wait("the next page") { reader.session.visibleRange?.start != before }
        }
        try await wait("the position") { reader.session.lastLocation?.bookmark != nil && reader.session.lastLocation?.href == "OPS/two.xhtml" }
        let position = try XCTUnwrap(reader.session.lastLocation)
        let start = try XCTUnwrap(reader.session.visibleRange?.start)
        XCTAssertGreaterThan(start.offset, 0, "a page past the chapter's first")
        try await reader.session.send(.locate(text: "The unique destination passage lives here.", highlight: true))
        try await wait("the passage") { reader.session.selection != nil }
        let passage = try XCTUnwrap(reader.events().compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let value) = event { return value }; return nil
        }.last).location
        return (position, start, passage)
    }

    /// Restores `position` and draws `passage` in `publication`, requiring the page and the
    /// highlight the book showed.
    private func restore(_ position: EPUBLocation, at start: ReaderTextPosition, passage: EPUBLocation,
                         in publication: EPUBPublication, _ name: String) async throws {
        let reader = try await reader(publication)
        defer { reader.close() }
        XCTAssertNotEqual(reader.session.visibleRange?.start, start, "\(name): the copy opens elsewhere")
        let before = reader.events().count
        do { try await reader.session.send(.restore(position)) }
        catch { return XCTFail("\(name): the position was refused: \(error)") }
        try await wait("\(name): the restored page") { reader.session.visibleRange?.start == start }
        XCTAssertEqual(reader.session.lastLocation?.bookmark, position.bookmark, name)
        XCTAssertEqual(reader.session.lastLocation?.publicationID, publication.persistentID, name)
        try await reader.session.send(.setHighlights([EPUBHighlight(id: "saved", location: passage)]))
        try await wait("\(name): the highlight") { reader.session.drawnHighlights.contains { $0.id == "saved" && $0.kind == .annotation } }
        XCTAssertFalse(reader.events().dropFirst(before).contains { if case .notice = $0 { return true }; return false },
                       "\(name): \(reader.events().dropFirst(before))")
    }

    /// The book's files, the package naming a unique identifier or not.
    private func files(uniqueIdentifier: Bool) throws -> [String: Data] {
        var files = try Fixture.files()
        if !uniqueIdentifier {
            files["OPS/book.opf"] = Data(String(decoding: files["OPS/book.opf"]!, as: UTF8.self)
                .replacingOccurrences(of: " unique-identifier=\"uid\"", with: "").utf8)
        }
        return files
    }

    private func edited(_ files: [String: Data], _ edit: (String) -> String) -> [String: Data] {
        var files = files
        files["OPS/book.opf"] = Data(edit(String(decoding: files["OPS/book.opf"]!, as: UTF8.self)).utf8)
        return files
    }

    /// Acceptance (#679): a position saved in a book restores in a copy zipped again with other
    /// compression and in a copy whose metadata alone was changed, and (#680) in the book unpacked
    /// into a folder; so does a highlight. With a unique identifier and without one.
    func testAPositionAndAHighlightRestoreInCopiesOfTheBook() async throws {
        for unique in [true, false] {
            let files = try files(uniqueIdentifier: unique)
            let book = try EPUBPublication.open(data: Fixture.archive(files))
            let (position, start, passage) = try await save(in: book)
            XCTAssertEqual(position.publicationID, book.persistentID)
            XCTAssertEqual(passage.publicationID, book.persistentID)
            let metadata = edited(files) {
                $0.replacingOccurrences(of: "<dc:title>A Test Book</dc:title>", with: "<dc:title>A Test Book (Revised)</dc:title>")
                    .replacingOccurrences(of: "</metadata>", with: "<dc:creator>An Editor</dc:creator>"
                                          + "<meta property=\"dcterms:modified\">2026-10-22T08:00:00Z</meta></metadata>")
            }
            let folder = try Fixture.folder(files)
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            let copies: [(String, EPUBPublication)] = [
                ("stored", try EPUBPublication.open(data: Fixture.rezipped(files, compression: .none))),
                ("metadata edited", try EPUBPublication.open(data: Fixture.archive(metadata))),
                ("unpacked into a folder", try EPUBPublication.open(at: folder)),
            ]
            for (name, copy) in copies {
                XCTAssertNotEqual(copy.id, book.id, name)
                try await restore(position, at: start, passage: passage, in: copy, "\(name), unique identifier \(unique)")
            }
        }
    }

    /// Acceptance (#679): another edition, with another unique identifier, is not taken for the
    /// same book: its position and its highlight are refused.
    func testAnotherEditionRefusesThePositionAndTheHighlight() async throws {
        let files = try files(uniqueIdentifier: true)
        let (position, _, passage) = try await save(in: EPUBPublication.open(data: Fixture.archive(files)))
        let edition = try EPUBPublication.open(data: Fixture.archive(edited(files) {
            $0.replacingOccurrences(of: ">test-book<", with: ">test-book-second-edition<")
        }))
        let reader = try await reader(edition)
        defer { reader.close() }
        do { try await reader.session.send(.restore(position)); XCTFail("Another edition took the position") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .incompatibleLocation) }
        try await reader.session.send(.setHighlights([EPUBHighlight(id: "saved", location: passage)]))
        XCTAssertTrue(reader.session.drawnHighlights.isEmpty)
        XCTAssertTrue(reader.events().contains(.notice("Some highlights could not be shown.")))
        XCTAssertEqual(reader.session.readerState?.status.undrawnHighlights, ["saved": .incompatibleLocation])
    }

    /// A location saved before `persistentID` carries the file's SHA-256, the book's `id`, and
    /// still restores in that file.
    func testAPositionSavedUnderTheFilesHashRestoresInThatFile() async throws {
        let book = try EPUBPublication.open(data: Fixture.archive(files(uniqueIdentifier: true)))
        var (position, start, passage) = try await save(in: book)
        position.publicationID = book.id
        passage.publicationID = book.id
        try await restore(position, at: start, passage: passage, in: book, "under the file's hash")
    }
}
