import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

final class ArchiveInputWorkTests: XCTestCase {
    private final class Progress: @unchecked Sendable {
        var calls = 0
        var expanded = 0
    }

    private func assertBoundedRefusal(_ data: Data, beforeExtraction: Bool = false,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let progress = Progress()
        XCTAssertThrowsError(try EPUBPublication.open(data: data, onProgress: {
            progress.calls += 1; progress.expanded = $0
        }), file: file, line: line) {
            XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded("archive input work"), file: file, line: line)
        }
        if beforeExtraction { XCTAssertEqual(progress.calls, 0, file: file, line: line) }
        // Fixture.files has seven entries. Each admitted extra stream has 128 processing
        // steps but no output; the budget runs out during the second, long before all 2,000.
        XCTAssertLessThanOrEqual(progress.calls, (data.count + progress.expanded) / 32_768 + 16,
                                 file: file, line: line)
    }

    func testRepeatedLongLocalHeadersAreRefusedBeforeExtraction() throws {
        assertBoundedRefusal(try Fixture.sharedInputArchive(entries: 19_993, longHeader: true), beforeExtraction: true)
    }

    func testRepeatedEmptyDeflateInputIsBoundedEvenThoughNoBytesExpand() throws {
        assertBoundedRefusal(try Fixture.sharedInputArchive(entries: 2_000, streamBytes: 4 << 20))
    }

    func testDistinctOverlappingHeadersCannotMultiplyTheSameStream() throws {
        assertBoundedRefusal(try Fixture.sharedInputArchive(entries: 500, streamBytes: 4 << 20, distinctHeaders: true))
    }

    func testOneLongHeaderOrLongEmptyStreamIsStillRead() throws {
        for data in [try Fixture.sharedInputArchive(entries: 1, longHeader: true),
                     try Fixture.sharedInputArchive(entries: 1, streamBytes: 4 << 20)] {
            let book = try EPUBPublication.open(data: data)
            XCTAssertEqual(book.spine.count, 2)
            XCTAssertEqual(try book.data(at: "extra/0.bin"), Data())
        }
    }

    func testAnEarlyEndedStreamWithARepeatedOversizedDeclarationIsStillRead() throws {
        // Declared overlap alone is not costly, and #219 deliberately reads past it.
        let book = try EPUBPublication.open(data: Fixture.sharedInputArchive(entries: 2_000, streamBytes: 4 << 20, earlyEnd: true))
        XCTAssertEqual(book.spine.count, 2)
        XCTAssertEqual(try book.data(at: "extra/1999.bin"), Data())
    }

    func testManySmallEntriesKeepTheirPartialChunkAllowance() throws {
        var entries = Fixture.storedEntries(try Fixture.files())
        entries += (0..<19_993).map { Fixture.StoredEntry("extra/\($0).bin", Data([UInt8($0 % 256)])) }
        let book = try EPUBPublication.open(data: Fixture.storedArchive(entries))
        XCTAssertEqual(try book.data(at: "extra/19992.bin"), Data([UInt8(19_992 % 256)]))
    }

    func testOrdinaryDeflateInputWithManyPartialChunksAndFullChunksIsRead() throws {
        var files = try Fixture.files()
        for index in 0..<1_000 { files["extra/\(index).bin"] = Data([UInt8(index % 256)]) }
        // Reproducible incompressible data, requiring several full input and output chunks.
        var state: UInt64 = 0x123456789abcdef0
        let payload = Data((0..<(256 << 10)).map { _ -> UInt8 in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
        files["extra/full.bin"] = payload
        let data = try Fixture.archive(files)
        XCTAssertGreaterThan(data.count, payload.count)
        let book = try EPUBPublication.open(data: data)
        XCTAssertEqual(try book.data(at: "extra/full.bin"), payload)
        XCTAssertEqual(try book.data(at: "extra/999.bin"), files["extra/999.bin"])
    }
}
