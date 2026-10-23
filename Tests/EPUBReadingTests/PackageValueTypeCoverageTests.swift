import EPUBCore
import Foundation
import XCTest

/// The value types hosts store and compare: locations in JSON, raw values, search results.
final class PackageValueTypeCoverageTests: XCTestCase {
    private let bookmark = EPUBEngineBookmark(engineID: "org.epublib.reader", format: "epublib-cfi-v1", value: "epubcfi(/6/4!/4/2/1:3)")

    private func location() -> EPUBLocation {
        let second = EPUBEngineBookmark(engineID: "org.epublib.reader", format: "epublib-cfi-v1", value: "epubcfi(/6/6!/4/2,/1:0,/1:9)")
        let pages = [EPUBPageListEntry(label: "xii", href: "OPS/front.xhtml#p-xii"), EPUBPageListEntry(label: "1", href: "OPS/ch%201.xhtml#p1")]
        return EPUBLocation(publicationID: String(repeating: "ab", count: 32), href: "OPS/ch%201.xhtml#s%202", progression: 0.123456789012345,
                            title: "Chapter \u{201C}One\u{201D} \u{1F600}", quote: "a line\nwith a \"quote\" and a \\ backslash", bookmark: bookmark,
                            page: pages[0], pages: pages, rangeBookmarks: [bookmark, second])
    }

    func testALocationWithEveryFieldSurvivesJSON() throws {
        let original = location()
        for formatting: JSONEncoder.OutputFormatting in [[], [.prettyPrinted, .sortedKeys], [.withoutEscapingSlashes]] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = formatting
            XCTAssertEqual(try JSONDecoder().decode(EPUBLocation.self, from: encoder.encode(original)), original)
        }
        XCTAssertEqual(try PropertyListDecoder().decode(EPUBLocation.self, from: PropertyListEncoder().encode(original)), original)
        for progression in [0, 1, 0.5, 1e-12] {
            var edge = original; edge.progression = progression
            XCTAssertEqual(try JSONDecoder().decode(EPUBLocation.self, from: JSONEncoder().encode(edge)).progression, progression)
        }
    }

    func testAStoredLocationKeepsItsFieldNames() throws {
        // Hosts keep these documents; a renamed key would orphan every saved position.
        func keys(_ value: some Encodable) throws -> Set<String> {
            Set(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]).keys)
        }
        XCTAssertEqual(try keys(location()), ["publicationID", "href", "progression", "title", "quote", "bookmark", "rangeBookmarks", "page", "pages"])
        XCTAssertEqual(try keys(bookmark), ["engineID", "format", "value"])
        XCTAssertEqual(try keys(EPUBPageListEntry(label: "1", href: "a")), ["label", "href"])
        XCTAssertEqual(try keys(EPUBLocation(publicationID: "x")), ["publicationID"], "absent fields are left out, not written as null")
    }

    func testALocationDecodesFromItsFewestFieldsAndPastUnknownOnes() throws {
        func decode(_ json: String) throws -> EPUBLocation { try JSONDecoder().decode(EPUBLocation.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode(#"{"publicationID":"x"}"#), EPUBLocation(publicationID: "x"))
        XCTAssertEqual(try decode(#"{"publicationID":"x","href":null,"progression":null,"bookmark":null,"pages":null,"rangeBookmarks":null}"#),
                       EPUBLocation(publicationID: "x"), "nulls are absent fields")
        XCTAssertEqual(try decode(#"{"publicationID":"x","progression":1,"addedLater":{"any":["thing"]},"pages":[]}"#),
                       EPUBLocation(publicationID: "x", progression: 1, pages: []))
        for json in [#"{}"#, #"{"href":"OPS/one.xhtml"}"#, #"{"publicationID":7}"#, #"{"publicationID":"x","progression":"half"}"#,
                     #"{"publicationID":"x","bookmark":{"engineID":"e"}}"#, #"{"publicationID":"x","page":{"label":"1"}}"#, "[]", ""] {
            XCTAssertThrowsError(try decode(json), json) { XCTAssertTrue($0 is DecodingError, "\(json): \($0)") }
        }
    }

    func testRawValuesThatHostsStoreKeepTheirSpelling() throws {
        XCTAssertEqual(EPUBReadingFlow.allValues, ["paginated", "scrolled"])
        XCTAssertEqual(EPUBReaderAppearance.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual([EPUBLayout.reflowable, .prePaginated].map(\.rawValue), ["reflowable", "prePaginated"])
        XCTAssertEqual([EPUBPageProgression.ltr, .rtl, .default].map(\.rawValue), ["ltr", "rtl", "default"])
        XCTAssertEqual(try JSONDecoder().decode([EPUBReadingFlow].self, from: Data(#"["scrolled","paginated"]"#.utf8)), [.scrolled, .paginated])
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([EPUBReaderAppearance.dark, .system]), as: UTF8.self), #"["dark","system"]"#)
        XCTAssertThrowsError(try JSONDecoder().decode([EPUBReaderAppearance].self, from: Data(#"["sepia"]"#.utf8)))
        XCTAssertNil(EPUBPageProgression(rawValue: "RTL"))
        XCTAssertNil(EPUBLayout(rawValue: "pre-paginated"), "the package's spelling is not the raw value")
    }

    /// A host keeps a highlight's style with the highlight (#682): its fields and raw values are
    /// what a stored one is read back by, and a style without a mark leaves the mark out.
    func testAHighlightStyleKeepsItsFieldNamesAndRawValues() throws {
        XCTAssertEqual(EPUBHighlightColor.allCases.map(\.rawValue), ["yellow", "green", "blue", "pink", "purple"])
        XCTAssertEqual(EPUBHighlightMark.allCases.map(\.rawValue), ["underline", "doubleUnderline", "dottedUnderline", "dashedUnderline"])
        let style = EPUBHighlightStyle(color: .blue, mark: .dottedUnderline)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try encoder.encode(style), as: UTF8.self), #"{"color":"blue","mark":"dottedUnderline"}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(EPUBHighlightStyle()), as: UTF8.self), #"{"color":"yellow"}"#)
        XCTAssertEqual(try JSONDecoder().decode(EPUBHighlightStyle.self, from: Data(#"{"color":"pink"}"#.utf8)), EPUBHighlightStyle(color: .pink))
        XCTAssertEqual(try PropertyListDecoder().decode(EPUBHighlightStyle.self, from: PropertyListEncoder().encode(style)), style)
        for json in [#"{}"#, #"{"color":"orange"}"#, #"{"color":"blue","mark":"wavy"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(EPUBHighlightStyle.self, from: Data(json.utf8)), json)
        }
        // The style every highlight had before there were styles.
        let location = EPUBLocation(publicationID: "x", bookmark: bookmark)
        XCTAssertEqual(EPUBHighlight(id: "h", location: location).style, EPUBHighlightStyle(color: .yellow, mark: nil))
        XCTAssertNotEqual(EPUBHighlight(id: "h", location: location), EPUBHighlight(id: "h", location: location, style: style))
    }

    func testAReaderStyleReportsDarkOnlyForExplicitDark() {
        XCTAssertEqual(EPUBReaderStyle(), EPUBReaderStyle(fontSize: 17, appearance: .system, flow: .paginated))
        XCTAssertFalse(EPUBReaderStyle().isDark, "System is not Dark, whatever the device shows")
        XCTAssertTrue(EPUBReaderStyle(appearance: .dark).isDark)
        XCTAssertEqual(EPUBReaderStyle(fontSize: 20, isDark: true, flow: .scrolled), EPUBReaderStyle(fontSize: 20, appearance: .dark, flow: .scrolled))
        XCTAssertEqual(EPUBReaderStyle(isDark: false).appearance, .light)
        var style = EPUBReaderStyle()
        style.isDark = false
        XCTAssertEqual(style.appearance, .light, "setting it leaves System")
        style.isDark = true
        XCTAssertEqual(style.appearance, .dark)
        XCTAssertTrue(style.isDark)
    }

    func testSearchResultsStepFromWhateverTheCurrentIndexHolds() {
        func result(_ index: Int) -> EPUBSearchResult {
            EPUBSearchResult(index: index, location: EPUBLocation(publicationID: "x"), spineIndex: 0, matchedText: "match \(index)",
                             contextBefore: "before ", contextAfter: " after")
        }
        var three = EPUBSearchResults(query: "match", results: (0..<3).map(result), currentIndex: 7)
        XCTAssertNil(three.currentIndex, "an index outside the list is no current match")
        XCTAssertNil(EPUBSearchResults(query: "match", results: (0..<3).map(result), currentIndex: -1).currentIndex)
        XCTAssertEqual(EPUBSearchResults(query: "match", results: (0..<3).map(result), currentIndex: 2).current?.matchedText, "match 2")
        // The property is settable, so a stale index can arrive after the list changed.
        for stale in [3, 7, -1, Int.max, Int.min] {
            three.currentIndex = stale
            XCTAssertNil(three.current, "\(stale)")
            XCTAssertEqual(three.steppedIndex(forward: true), 0, "\(stale)")
            XCTAssertEqual(three.steppedIndex(forward: false), 2, "\(stale)")
            XCTAssertFalse(three.isAtFirst || three.isAtLast, "\(stale)")
        }
        three.currentIndex = nil
        XCTAssertEqual([three.steppedIndex(forward: true), three.steppedIndex(forward: false)], [0, 2])
        three.currentIndex = 0
        XCTAssertEqual([three.steppedIndex(forward: true), three.steppedIndex(forward: false)], [1, 2])
        XCTAssertTrue(three.isAtFirst && !three.isAtLast)
        three.currentIndex = 2
        XCTAssertEqual([three.steppedIndex(forward: true), three.steppedIndex(forward: false)], [0, 1])
        XCTAssertTrue(three.isAtLast && !three.isAtFirst)
        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(three.current?.snippet, "before match 2 after")
        XCTAssertEqual(three.current?.id, 2)

        let one = EPUBSearchResults(query: "match", results: [result(0)], currentIndex: 0)
        XCTAssertEqual([one.steppedIndex(forward: true), one.steppedIndex(forward: false)], [0, 0], "one result steps to itself")
        XCTAssertTrue(one.isAtFirst && one.isAtLast)

        var none = EPUBSearchResults(query: "match", currentIndex: 0)
        XCTAssertNil(none.currentIndex)
        none.currentIndex = -1
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(none.current)
        XCTAssertNil(none.steppedIndex(forward: true))
        XCTAssertNil(none.steppedIndex(forward: false))
        XCTAssertFalse(none.isAtFirst || none.isAtLast)
    }
}

private extension EPUBReadingFlow {
    static var allValues: [String] { [EPUBReadingFlow.paginated, .scrolled].map(\.rawValue) }
}
