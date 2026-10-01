import EPUBCore
import EPUBReading
import EPUBViewing
import EPUBTestSupport
import SwiftUI
import XCTest

/// A native SwiftUI implementation proving that the public contract needs no WebKit or JavaScript types.
@MainActor private struct NativeEngine: EPUBReaderEngine {
    let id = "test.native"
    func makeSession(publication: EPUBPublication, selectionAction: EPUBSelectionAction?,
                     onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
        NativeSession(book: publication, onEvent: onEvent)
    }
}
@MainActor private final class NativeSession: EPUBReaderSession {
    let capabilities: Set<EPUBReaderCapability> = [.pagination]
    let book: EPUBPublication
    var onEvent: ((EPUBReaderEvent) -> Void)?
    init(book: EPUBPublication, onEvent: @escaping (EPUBReaderEvent) -> Void) {
        self.book = book; self.onEvent = onEvent
    }
    func makeView() -> AnyView { AnyView(Text(book.metadata.title)) }
    func send(_ command: EPUBReaderCommand) async throws {
        try Task.checkCancellation()
        guard let onEvent else { throw EPUBReaderError.closed }
        guard command == .nextPage else { throw EPUBReaderError.unsupported(.bookmarks) }
        onEvent(.relocated(EPUBLocation(publicationID: book.id, href: book.spine[1].resource.path)))
    }
    func close() { onEvent = nil }
}
@MainActor final class NativeEngineTests: XCTestCase {
    func testNativeEngineMountsAndEmitsPortableLocation() async throws {
        let book = try EPUBPublication.open(data: Fixture.epub())
        var events: [EPUBReaderEvent] = []
        let engine: any EPUBReaderEngine = NativeEngine()
        let session = try engine.makeSession(publication: book, selectionAction: nil) { events.append($0) }
        _ = EPUBReaderView(session: session)
        try await session.send(.nextPage)
        XCTAssertEqual(events, [.relocated(EPUBLocation(publicationID: book.id, href: "OPS/two.xhtml"))])
        session.close()
        session.close()
        do { try await session.send(.nextPage); XCTFail("Closed session accepted command") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .closed) }
        XCTAssertEqual(events.count, 1)
    }
    func testCancellationPreventsSubmission() async throws {
        let book = try EPUBPublication.open(data: Fixture.epub())
        let session = try NativeEngine().makeSession(publication: book, selectionAction: nil) { _ in XCTFail("Canceled command emitted") }
        let task = Task { try await session.send(.nextPage) }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
    }
    func testLocationsRoundTripWithEngineIdentity() throws {
        let location = EPUBLocation(publicationID: "book", href: "chapter.xhtml", quote: "a passage",
            bookmark: EPUBEngineBookmark(engineID: "native", format: "paragraph-v1", value: "7"))
        XCTAssertEqual(location, try JSONDecoder().decode(EPUBLocation.self, from: JSONEncoder().encode(location)))
    }
}
