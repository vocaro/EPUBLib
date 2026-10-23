import CoreGraphics
import XCTest
@testable import EPUBViewing

/// Which reserved region `EPUBReaderView` takes for iPhone Duo's fold, and which wins when the
/// host gives a frame too (#686).
final class ReaderFoldTests: XCTestCase {
    private let upright = CGRect(x: 463, y: 0, width: 24, height: 669)
    private let across = CGRect(x: 0, y: 322, width: 951, height: 24)

    func testAnUprightFoldIsFoundActiveOrNot() {
        XCTAssertNil(ReaderFold.found(in: []))
        XCTAssertEqual(ReaderFold.found(in: [.init(frame: upright, isActive: false)]), upright, "flat")
        XCTAssertEqual(ReaderFold.found(in: [.init(frame: upright, isActive: true)]), upright, "partly folded")
    }

    func testAFoldAcrossTheReaderReservesNothing() {
        XCTAssertNil(ReaderFold.found(in: [.init(frame: across, isActive: true)]))
        XCTAssertNil(ReaderFold.found(in: [.init(frame: .null, isActive: true)]))
        XCTAssertEqual(ReaderFold.found(in: [.init(frame: across, isActive: true), .init(frame: upright, isActive: false)]), upright)
    }

    func testAnActiveFoldComesBeforeAnInactiveOne() {
        let other = upright.offsetBy(dx: 40, dy: 0)
        XCTAssertEqual(ReaderFold.found(in: [.init(frame: other, isActive: false), .init(frame: upright, isActive: true)]), upright)
        XCTAssertEqual(ReaderFold.found(in: [.init(frame: other, isActive: false), .init(frame: upright, isActive: false)]), other)
    }

    func testAFrameTheHostGivesWins() {
        let host = CGRect(x: 500, y: 0, width: 10, height: 669)
        XCTAssertEqual(ReaderFold.division(host: host, found: upright), host)
        XCTAssertEqual(ReaderFold.division(host: nil, found: upright), upright)
        XCTAssertEqual(ReaderFold.division(host: .null, found: upright), .null)
        XCTAssertNil(ReaderFold.division(host: nil, found: nil))
    }
}
