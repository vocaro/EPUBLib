import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBViewingTestSupport
import XCTest
@testable import EPUBViewing

@MainActor final class NativeSessionCollationTests: XCTestCase {
    private func wait(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for the reader") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testLocateAndSearchUseTheSameDocumentLanguageAndRanges() async throws {
        for (language, query, match, miss) in [
            ("sv", "åland cafe", "Åland CAFÉ", "aland cafe"),
            ("tr", "ığdır", "IĞDIR", "igdir"),
            ("es", "niño", "NIÑO", "nino"),
            ("ru", "йога", "ЙОГА", "иога"),
        ] {
            let markup = #"<html xmlns="http://www.w3.org/1999/xhtml" lang="en"><body lang="\#(language)"><p>\#(miss)|\#(match)</p></body></html>"#
            let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": markup]))
            var events: [EPUBReaderEvent] = []
            let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication) { events.append($0) } as? NativeSession)
            let window = ReaderTestWindow(session: session)
            defer { session.close(); window.close() }
            try await wait { events.contains(.ready) && session.book.isComplete }

            try await session.send(.searchHighlight(text: query))
            XCTAssertEqual(session.readerState?.status.search, .completed(query: query, hasMatches: true), language)
            let ranges = session.drawnHighlights.filter { $0.kind == .search }.map(\.range)
            XCTAssertEqual(ranges.count, 1, language)
            let range = try XCTUnwrap(ranges.first)
            try await session.send(.locate(text: query, highlight: true))
            try await wait { session.selection?.text == match }
            XCTAssertEqual(session.canvas?.currentSelection?.range, range, language)

            // A separate book containing only the untailored spelling must miss in both paths.
            let missedPublication = try EPUBPublication.open(data: Fixture.epub(overrides: [
                "OPS/one.xhtml": #"<html xmlns="http://www.w3.org/1999/xhtml" lang="\#(language)"><body><p>\#(miss)</p></body></html>"#,
            ]))
            var missedEvents: [EPUBReaderEvent] = []
            let missedSession = try XCTUnwrap(try NativeEngine().makeSession(publication: missedPublication) { missedEvents.append($0) } as? NativeSession)
            let missedWindow = ReaderTestWindow(session: missedSession)
            defer { missedSession.close(); missedWindow.close() }
            try await wait { missedEvents.contains(.ready) && missedSession.book.isComplete }
            try await missedSession.send(.searchHighlight(text: query))
            XCTAssertEqual(missedSession.readerState?.status.search, .completed(query: query, hasMatches: false), language)
            XCTAssertTrue(missedSession.drawnHighlights.filter { $0.kind == .search }.isEmpty, language)
            try await missedSession.send(.locate(text: query, highlight: true))
            XCTAssertTrue(missedEvents.contains(.notice(NativeSession.passageNotFound)), language)
            XCTAssertNil(missedSession.selection, language)
        }
    }
}
