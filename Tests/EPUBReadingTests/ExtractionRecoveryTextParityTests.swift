import Foundation
import EPUBReading
import EPUBText
import EPUBTestSupport
import XCTest

/// The two reader recovery inputs from #237 must also retain their characters in extraction.
/// Reader section tests cover the same inputs with its own line-break representation.
final class ExtractionRecoveryTextParityTests: XCTestCase {
    private func extract(_ input: String) throws -> EPUBTextSection {
        var files = try Fixture.files()
        files["OPS/one.xhtml"] = Data(input.utf8)
        let publication = try EPUBPublication.open(data: Fixture.archive(files))
        return try publication.textSection(at: 0, recoversMalformedMarkup: true)
    }

    func testTrailingTextSurvivesRecoveryWithAndWithoutTheXMLDeclaration() throws {
        let input = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><p>one<br>two</p></body></html>trailing"
        for prefix in ["", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"] {
            let section = try extract(prefix + input)
            XCTAssertTrue(section.recoveredAsHTML)
            XCTAssertEqual(section.text, "one\ntwo\ntrailing")
        }
    }

    func testCDATACharactersSurviveRecoveredExtraction() throws {
        let input = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><p>s<![CDATA[t & u]]> v<br></p></body></html>"
        let section = try extract(input)
        XCTAssertTrue(section.recoveredAsHTML)
        XCTAssertEqual(section.text, "st & u v")
    }
}
