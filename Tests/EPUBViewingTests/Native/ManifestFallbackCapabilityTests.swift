import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

@MainActor final class ManifestFallbackCapabilityTests: XCTestCase {
    func testIndependentCapabilityHoldsBothDrawableAndCorruptFallbacksToTheirOutcome() throws {
        for data in [Fixture.SpecBook.image(width: 20, height: 20), Data("not an image".utf8)] {
            let supported = SpecConformanceW3CCorpusTests.independentlyDecodesBitmap(data)
            let expected = SpecConformanceCorpus.expectation(for: "pub-foreign_bad-fallback", supportsPSDFallback: supported)
            var book = Fixture.SpecBook()
            book.add(href: "foo.dmg", id: "source", mediaType: "application/octet-stream", Data("foreign".utf8), item: "fallback='bar'")
            book.resource("bar.psd", id: "bar", mediaType: "image/psd", data)
            let built = try SpecConformanceBuild(book)
            XCTAssertEqual(built[0].report.withheld, expected.withheld.contains(0))
            if supported {
                XCTAssertEqual(built[0].specImages.map(\.path), ["EPUB/bar.psd"])
                XCTAssertFalse(built[0].report.withheld)
                XCTAssertEqual(built[0].report.unreadableResources, 0)
            } else {
                XCTAssertTrue(built[0].specImages.isEmpty)
                XCTAssertTrue(built[0].report.withheld)
            }
        }
    }

    func testIndependentCapabilityRequiresDecodableBytesAndDoesNotWeakenOtherFixtures() {
        XCTAssertTrue(SpecConformanceW3CCorpusTests.independentlyDecodesBitmap(Fixture.SpecBook.image(width: 20, height: 20)))
        XCTAssertFalse(SpecConformanceW3CCorpusTests.independentlyDecodesBitmap(Data("not an image".utf8)))
        let before = SpecConformanceCorpus.expectation(for: "pub-foreign_json-spine", supportsPSDFallback: false)
        let after = SpecConformanceCorpus.expectation(for: "pub-foreign_json-spine", supportsPSDFallback: true)
        XCTAssertEqual(before.withheld, after.withheld)
        XCTAssertEqual(before.checks, after.checks)
    }
}
