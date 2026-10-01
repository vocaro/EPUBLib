import Foundation
import XCTest
@testable import EPUBViewing

final class URLPatchTests: XCTestCase {
    func testPatchAppliesToPinnedSourceAndRefusesSourceDrift() throws {
        let source = try XCTUnwrap(ReaderEPUBAssetSource.bundled(bookURL: URL(fileURLWithPath: "/unused")))
        let bytes = try Data(contentsOf: source.libraryRoot.appending(path: "epub.js"))
        let patched = try ReaderEPUBURLPatch.apply(to: bytes)
        XCTAssertNotEqual(patched, bytes)
        XCTAssertThrowsError(try ReaderEPUBURLPatch.apply(to: patched))
        let changed = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "decodeURI(path)", with: "path")
        XCTAssertThrowsError(try ReaderEPUBURLPatch.apply(to: Data(changed.utf8)))
    }
}
