import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

final class ManifestFallbackTests: XCTestCase {
    private func publication(_ items: String, files: [String: Data?] = [:]) throws -> EPUBPublication {
        try EPUBPublication.open(data: Fixture.packageVariant(opf: {
            $0.replacingOccurrences(of: "<manifest>", with: "<manifest>" + items)
        }, adding: files))
    }

    func testManifestFallbackIDsRemainInTheSnapshotWithoutReplacingTheSpine() throws {
        let book = try publication("<item id='foreign' href='data.json' media-type='application/json' fallback='one'/>",
                                   files: ["OPS/data.json": Data("{}".utf8)])
        let resource = try XCTUnwrap(book.manifestResource(at: "OPS/data.json"))
        XCTAssertEqual(resource.fallbackID, "one")
        XCTAssertEqual(book.fallbackChain(for: resource).map(\.id), ["foreign", "one"])
        XCTAssertEqual(book.spine.map(\.resource.id), ["one", "two"])
        XCTAssertEqual(try book.data(for: resource), Data("{}".utf8))
        XCTAssertNil(book.spine[0].resource.fallbackID)
        XCTAssertEqual(EPUBResource(id: "old", path: "old.xhtml", mediaType: "application/xhtml+xml").fallbackID, nil)
    }

    func testMissingAndRemoteHopsRemainTraversableButAreNeverLoaded() throws {
        let book = try publication("""
        <item id='first' href='first.bin' media-type='application/octet-stream' fallback='missing'/>
        <item id='missing' href='absent.bin' media-type='application/octet-stream' fallback='remote'/>
        <item id='remote' href='https://example.invalid/chapter' media-type='application/xhtml+xml' fallback='one'/>
        """, files: ["OPS/first.bin": Data("unsupported".utf8)])
        let original = try XCTUnwrap(book.manifestResource(at: "OPS/first.bin"))
        XCTAssertEqual(book.fallbackChain(for: original).map(\.id), ["first", "missing", "remote", "one"])
        XCTAssertFalse(book.resources.contains { $0.id == "missing" || $0.id == "remote" })
        for hop in book.fallbackChain(for: original).dropFirst().prefix(2) {
            XCTAssertThrowsError(try book.data(for: hop))
        }
    }

    func testCyclicAndDanglingFallbackChainsStopAtTheFirstRepeatedOrMissingID() throws {
        let book = try publication("""
        <item id='a' href='a.bin' media-type='application/x-a' fallback='b'/>
        <item id='b' href='b.bin' media-type='application/x-b' fallback='a'/>
        <item id='c' href='c.bin' media-type='application/x-c' fallback='absent'/>
        """, files: ["OPS/a.bin": Data(), "OPS/b.bin": Data(), "OPS/c.bin": Data()])
        XCTAssertEqual(book.fallbackChain(for: try XCTUnwrap(book.manifestResource(at: "OPS/a.bin"))).map(\.id), ["a", "b"])
        XCTAssertEqual(book.fallbackChain(for: try XCTUnwrap(book.manifestResource(at: "OPS/c.bin"))).map(\.id), ["c"])
    }

    func testDuplicateManifestIDsWithDifferentFallbacksRemainAmbiguous() throws {
        XCTAssertThrowsError(try publication("""
        <item id='a' href='a.bin' media-type='application/x-a' fallback='one'/>
        <item id='a' href='a.bin' media-type='application/x-a' fallback='two'/>
        """, files: ["OPS/a.bin": Data()])) {
            XCTAssertEqual($0 as? EPUBPublicationError, .invalidXML("Manifest item"))
        }
    }
}
