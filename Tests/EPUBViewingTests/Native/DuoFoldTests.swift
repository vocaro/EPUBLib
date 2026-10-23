#if os(iOS)
import EPUBCore
import UIKit
import XCTest
@testable import EPUBViewing

/// On an iPhone Duo simulator (iOS 27.1) that the host has posed, the reader finds the fold the
/// system reports and keeps its text off it (#686). The host sets the pose with the hinge helper
/// before the run, confirms it from the active display, and names it in
/// `TEST_RUNNER_EPUBLIB_DUO_POSE` (doc/testing.md, "iPhone Duo poses"): `closed`, `book` (partly
/// folded, the inner display wide), `flat` (open flat, the inner display wide) or `upright` (the
/// inner display held upright, as in the laptop pose). The pose is an assertion: the regions
/// are UIKit's own, read on the canvas apart from the SwiftUI reading the reader makes, and none
/// is given. Without the variable the test skips.
@MainActor final class DuoFoldTests: XCTestCase {
    func testTheReaderKeepsItsTextOffTheFoldOfThePoseTheHostSet() async throws {
        guard let pose = ProcessInfo.processInfo.environment["EPUBLIB_DUO_POSE"] else {
            throw XCTSkip("Pose an iPhone Duo simulator and set TEST_RUNNER_EPUBLIB_DUO_POSE; see \"iPhone Duo poses\" in doc/testing.md")
        }
        guard #available(iOS 27.1, *) else {
            return XCTFail("Reserved regions need iOS 27.1; this simulator runs \(UIDevice.current.systemVersion)")
        }
        XCTAssertTrue(["closed", "book", "flat", "upright"].contains(pose), "unknown pose \(pose)")
        for (label, data) in [("left to right", try SessionCoverageBook.chapters()),
                              ("right to left", try SessionCoverageBook.chapters(spine: " page-progression-direction=\"rtl\""))] {
            let reader = try SessionCoverageReader(data)
            addTeardownBlock { @MainActor in reader.close() }
            try await reader.settle()
            let mid = try reader.anchor("mid", section: 2)
            try await reader.session.send(.navigate(href: "OPS/two.xhtml#mid"))
            try await reader.wait("\(label): the midpoint") { reader.isVisible(mid) }
            try await Task.sleep(for: .milliseconds(500))
            let canvas = try XCTUnwrap(reader.session.canvas)
            let regions = canvas.reservedRegions(kind: .division, options: .includeInactive)
            let upright = regions.filter { $0.frame.height > $0.frame.width }
            let columns = canvas.textViews.map(\.frame)
            let record = "DUO-FOLD pose=\(pose) book=\(label) canvas=\(canvas.bounds) window=\(canvas.window?.bounds ?? .zero) "
                + "scale=\(canvas.traitCollection.displayScale) regions=\(regions.map { "\($0.frame) margins \($0.margins) active \($0.isActive)" }) "
                + "division=\(canvas.configuration.division.map { "\($0)" } ?? "none") columns=\(columns)"
            print(record)
            add(XCTAttachment(string: record))
            switch pose {
            case "closed":
                XCTAssertTrue(regions.isEmpty, "\(label): the outer display has no fold: \(record)")
                XCTAssertNil(canvas.configuration.division, record)
                XCTAssertEqual(columns.count, 1, "\(label): one page: \(record)")
            case "book", "flat":
                let fold = try XCTUnwrap(upright.first, "\(label): no upright fold in pose \(pose): \(record)")
                XCTAssertEqual(fold.isActive, pose == "book", record)
                let division = try XCTUnwrap(canvas.configuration.division, "\(label): the reader found no fold: \(record)")
                XCTAssertEqual(division.minX, fold.frame.minX, accuracy: 0.5, "SwiftUI's fold and UIKit's: \(record)")
                XCTAssertEqual(division.maxX, fold.frame.maxX, accuracy: 0.5, "SwiftUI's fold and UIKit's: \(record)")
                XCTAssertEqual(columns.count, 2, "\(label): a page each side of the fold: \(record)")
                XCTAssertTrue(columns.allSatisfy { $0.maxX <= fold.frame.minX || $0.minX >= fold.frame.maxX },
                              "\(label): text crosses the fold: \(record)")
                XCTAssertEqual(Set(columns.map { $0.midX < fold.frame.midX }).count, 2, record)
            default:
                XCTAssertTrue(upright.isEmpty, "\(label): \(record)")
                XCTAssertTrue(regions.contains { $0.frame.width > $0.frame.height }, "\(label): no fold across the display: \(record)")
                XCTAssertNil(canvas.configuration.division, "\(label): a fold across the reader reserves nothing (#724): \(record)")
            }
            reader.close()
        }
    }
}
#endif
