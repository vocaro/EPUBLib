import EPUBCore
@testable import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// Deflate streams whose block header is damaged. Apple's Compression framework, which
/// ZIPFoundation 0.9.20 inflates with, decoded some of them by stack memory it had not set, so
/// the same bytes were refused one way on one open and another way on the next (#583). Opening
/// inflates with zlib (`DeflateStream`), whose result its bytes alone decide.
final class DamagedDeflateStreamTests: XCTestCase {
    private static let name = "META-INF/container.xml"
    private static let damage = "EPUBPublicationError invalidArchive(\"\(name): corruptedData\")"

    private func outcome(_ data: Data) -> String {
        do { _ = try EPUBPublication.open(data: data); return "opens" } catch { return "\(type(of: error)) \(error)" }
    }

    /// The container document's stream, as ZIPFoundation's writer deflates it.
    private func containerStream() throws -> Data {
        let book = try Fixture.epub()
        let offset = try XCTUnwrap(Fixture.dataOffset(of: Self.name, in: book))
        let record = try XCTUnwrap(Fixture.directoryOffset(of: Self.name, in: book))
        let compressed = (0..<4).reduce(0) { $0 | Int(book[record + 20 + $1]) << (8 * $1) }
        return Data(book[offset..<(offset + compressed)])
    }

    /// The test book with `stream` as its container document, deflated, in the archive's first
    /// entry, so that nothing else is read before it. The directory gives the document's checksum.
    private func archive(container stream: Data) throws -> Data {
        let files = try Fixture.files(), document = try XCTUnwrap(files[Self.name])
        let rest = Fixture.storedEntries(files).filter { $0.name != Data(Self.name.utf8) }
        var data = Fixture.storedArchive([Fixture.StoredEntry(Self.name, stream, method: 8)] + rest)
        let record = try XCTUnwrap(Fixture.directoryOffset(of: Self.name, in: data))
        data.replaceSubrange((record + 16)..<(record + 20), with: withUnsafeBytes(of: document.crc32(checksum: 0).littleEndian) { Data($0) })
        return data
    }

    func testADamagedStreamIsRefusedAsDamageOnEveryOpen() throws {
        // #74's mutant 2176 changes one byte of the stream's block header. Its mutant 4175 marks
        // the stored document as deflated, so that its text is read as a block header. Apple's
        // decoder gave the first a checksum's refusal, a limit's or damage's from one open to the
        // next, and the second a limit's in one process and damage's in another.
        var changed = try containerStream()
        changed[changed.startIndex + 3] = 0x18
        let stored = try XCTUnwrap(Fixture.files()[Self.name])
        for (name, data) in [("a changed block header", try archive(container: changed)),
                             ("stored bytes marked as deflated", try archive(container: stored))] {
            for open in 0..<50 { XCTAssertEqual(outcome(data), Self.damage, "\(name), open \(open)") }
        }
    }

    func testEveryValueOfAByteAtTheStartOfAStreamGivesOneResultOnEveryOpen() throws {
        let stream = try containerStream()
        XCTAssertEqual(outcome(try archive(container: stream)), "opens")
        // A stream this short cannot inflate past a limit. One that does not inflate to the
        // document is refused by its checksum, or as damage where it is not Deflate at all.
        let checksum = "EPUBPublicationError invalidArchive(\"CRC: \(Self.name)\")"
        var results: [String: Int] = [:]
        for position in 0..<8 {
            for value in UInt8.min...UInt8.max {
                var changed = stream
                changed[changed.startIndex + position] = value
                let data = try archive(container: changed), first = outcome(data)
                XCTAssertTrue(["opens", checksum, Self.damage].contains(first), "\(value) at \(position): \(first)")
                for _ in 0..<2 { XCTAssertEqual(outcome(data), first, "\(value) at \(position)") }
                results[first, default: 0] += 1
            }
        }
        XCTAssertGreaterThan(results[Self.damage] ?? 0, 1_000, "\(results)")
    }

    // MARK: DeflateStream

    private func inflate(_ stream: Data, chunkSize: Int) throws -> (data: Data, crc: UInt32, steps: [Int]) {
        var data = Data(), steps: [Int] = []
        let crc = try stream.withUnsafeBytes { bytes in
            try DeflateStream.inflate(bytes, chunkSize: chunkSize) { chunk in
                steps.append(chunk.count)
                data.append(chunk)
            }
        }
        return (data, crc, steps)
    }

    func testAStreamIsInflatedInStepsOfAChunkOrLess() throws {
        let document = try XCTUnwrap(Fixture.files()[Self.name]), stream = try containerStream()
        for chunkSize in [1, 7, 64, 32_768] {
            let inflated = try inflate(stream, chunkSize: chunkSize)
            XCTAssertEqual(inflated.data, document, "chunks of \(chunkSize)")
            XCTAssertEqual(inflated.crc, document.crc32(checksum: 0), "chunks of \(chunkSize)")
            XCTAssertTrue(inflated.steps.allSatisfy { $0 <= chunkSize }, "chunks of \(chunkSize)")
            // A step that gives less than a chunk has used up its input, or ends the stream:
            // there are no more of them than input chunks (`ArchiveInputWork`).
            let partial = inflated.steps.filter { $0 < chunkSize }.count
            XCTAssertLessThanOrEqual(partial, (stream.count + chunkSize - 1) / chunkSize, "chunks of \(chunkSize)")
        }
    }

    func testAStreamIsReadNoFurtherThanItEnds() throws {
        let document = try XCTUnwrap(Fixture.files()[Self.name])
        XCTAssertEqual(try inflate(containerStream() + Data(repeating: 0xFF, count: 100_000), chunkSize: 32_768).data, document)
        XCTAssertEqual(try inflate(Data([0x03, 0x00]) + Data(count: 100_000), chunkSize: 32_768).steps, [0])
    }

    func testAStreamCutShortOfItsEndIsRefusedAtEveryLength() throws {
        let stream = try containerStream()
        for length in 0..<stream.count {
            XCTAssertThrowsError(try inflate(stream.prefix(length), chunkSize: 64), "\(length) bytes") {
                guard case .corruptedData = $0 as? DeflateStream.Failure else { return XCTFail("\(length) bytes: \($0)") }
            }
        }
    }
}
