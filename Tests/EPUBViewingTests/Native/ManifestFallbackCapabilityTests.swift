import EPUBTestSupport
import Foundation
import XCTest

final class ManifestFallbackCapabilityTests: XCTestCase {
    func testDrawablePSDFallbackRequiresTheAuthoredImageWithoutAnImageLossNotice() {
        let expected = SpecConformanceCorpus.expectation(for: "pub-foreign_bad-fallback", supportsPSDFallback: true)
        XCTAssertTrue(expected.withheld.isEmpty)
        XCTAssertTrue(expected.checks.contains(.image(0, path: "EPUB/bar.psd")))
        XCTAssertTrue(expected.checks.contains(.notDisclosed(.withheld)))
        XCTAssertTrue(expected.checks.contains(.notDisclosed(.unreadableResources)))
        XCTAssertFalse(expected.checks.contains(.disclosed(.withheld)))
    }

    func testUndrawablePSDFallbackStillRequiresWithholdingAndDisclosure() {
        let expected = SpecConformanceCorpus.expectation(for: "pub-foreign_bad-fallback", supportsPSDFallback: false)
        XCTAssertEqual(expected.withheld, [0])
        XCTAssertEqual(expected.checks, [.disclosed(.withheld)])
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
