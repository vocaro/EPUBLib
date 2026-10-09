import EPUBCore
import EPUBReading
import EPUBTestSupport
import XCTest
@testable import EPUBViewing

/// `NativeProgress.pages(in:)` with the anchors given directly, so no section is built.
final class NativeProgressTests: XCTestCase {
    /// `Fixture.pageList()`'s markers: page `i` is well into the preface, page 1 opens chapter
    /// one, 3 and 4 are ten characters apart, and chapter two opens without one.
    private let anchors = [0: ["page-i": 1_000], 1: ["page-1": 0, "page-2": 2_000, "page-3": 4_000, "page-4": 4_010],
                           2: ["page-5": 2_000]]

    private func labels(_ progress: NativeProgress, _ range: ReaderTextRange, anchors: [Int: [String: Int]]? = nil,
                        shown: Set<Int>? = nil, file: StaticString = #filePath, line: UInt = #line) -> (String?, [String]?) {
        let anchors = anchors ?? self.anchors
        let found = progress.pages(in: range, isShown: { shown?.contains($0) ?? true }) { section, fragment in
            XCTAssertGreaterThanOrEqual(section, range.start.section, "an earlier section's anchors were needed", file: file, line: line)
            return anchors[section]?[fragment]
        }
        if let page = found.page { XCTAssertEqual(found.pages?.first, page, "pages begins with page", file: file, line: line) }
        return (found.page?.label, found.pages?.map(\.label))
    }

    private func range(_ section: Int, _ offsets: Range<Int>) -> ReaderTextRange { ReaderTextRange(section: section, offsets) }

    func testTheEntryInEffectAtTheStartAndThoseInsideTheRange() throws {
        let progress = NativeProgress(publication: try EPUBPublication.open(data: Fixture.pageList()))
        XCTAssert(labels(progress, range(0, 0..<500)) == (nil, nil), "before the first entry")
        XCTAssert(labels(progress, range(0, 0..<1_500)) == (nil, ["i"]), "the first entry begins inside")
        XCTAssert(labels(progress, range(1, 0..<300)) == ("1", ["1"]), "a marker opening its section")
        XCTAssert(labels(progress, range(1, 1_500..<2_500)) == ("1", ["1", "2"]), "a marker mid-range")
        XCTAssert(labels(progress, range(1, 2_000..<2_100)) == ("2", ["2"]), "a range starting on a marker")
        XCTAssert(labels(progress, range(1, 1_999..<2_000)) == ("1", ["1"]), "a marker at the exclusive end")
        XCTAssert(labels(progress, range(1, 3_900..<4_100)) == ("2", ["2", "3", "4"]), "two markers on one screen")
        XCTAssert(labels(progress, range(1, 4_005..<4_100)) == ("3", ["3", "4"]))
        XCTAssert(labels(progress, range(2, 0..<500)) == ("4", ["4"]), "a section opening without a marker")
        XCTAssert(labels(progress, range(2, 2_500..<3_000)) == ("5", ["5"]))
    }

    /// Continuous scroll shows a range across sections, leaving nonlinear ones out.
    func testARangeAcrossSections() throws {
        let progress = NativeProgress(publication: try EPUBPublication.open(data: Fixture.pageList()))
        let across = ReaderTextRange(start: .init(section: 1, offset: 3_950), end: .init(section: 2, offset: 2_100))
        XCTAssert(labels(progress, across) == ("2", ["2", "3", "4", "5"]))
        let whole = ReaderTextRange(start: .init(section: 0, offset: 1_500), end: .init(section: 2, offset: 100))
        XCTAssert(labels(progress, whole) == ("i", ["i", "1", "2", "3", "4"]))
        XCTAssert(labels(progress, whole, shown: [0, 2]) == ("i", ["i"]), "chapter one is left out")
        let toNextStart = ReaderTextRange(start: .init(section: 1, offset: 4_050), end: .init(section: 2, offset: 0))
        XCTAssert(labels(progress, toNextStart) == ("4", ["4"]))
    }

    /// A fragment the section does not have names its start, where `.navigate(href:)` goes.
    func testAnEntryWhoseFragmentDoesNotResolveSitsAtItsSectionsStart() throws {
        let progress = NativeProgress(publication: try EPUBPublication.open(data: Fixture.pageList()))
        var anchors = self.anchors
        anchors[2] = [:]
        XCTAssert(labels(progress, range(2, 0..<500), anchors: anchors) == ("5", ["5"]))
    }

    /// Within a section the anchors decide, the page list breaking ties; before it, the page list
    /// alone does. Entries naming no section are ignored.
    func testPositionsOrderASectionsEntriesAndThePageListEarlierOnes() throws {
        let nav = String(decoding: try Fixture.files()["OPS/nav.xhtml"]!, as: UTF8.self).replacingOccurrences(of: "</body>", with: """
            <nav epub:type="page-list"><ol><li><a href="one.xhtml#late">7</a></li><li><a href="one.xhtml#early">6</a></li>\
            <li><a href="nav.xhtml">x</a></li><li><a href="two.xhtml#blank">8</a></li><li><a href="two.xhtml#blank">9</a></li></ol></nav></body>
            """)
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/nav.xhtml": nav]))
        XCTAssertEqual(publication.pageList?.count, 5)
        let progress = NativeProgress(publication: publication)
        let anchors = [0: ["early": 100, "late": 900], 1: ["blank": 50]]
        XCTAssert(labels(progress, range(0, 0..<1_000), anchors: anchors) == (nil, ["6", "7"]))
        XCTAssert(labels(progress, range(0, 500..<1_000), anchors: anchors) == ("6", ["6", "7"]))
        XCTAssert(labels(progress, range(1, 0..<40), anchors: anchors) == ("6", ["6"]), "the last listed of the earlier section")
        XCTAssert(labels(progress, range(1, 0..<100), anchors: anchors) == ("6", ["6", "8", "9"]), "a blank page")
        XCTAssert(labels(progress, range(1, 50..<100), anchors: anchors) == ("9", ["9"]))
        XCTAssert(labels(progress, range(1, 0..<40), anchors: [:]) == ("9", ["9"]))
    }
}
