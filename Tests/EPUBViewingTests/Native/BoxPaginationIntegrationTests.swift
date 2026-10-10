import CoreGraphics
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Flow-box geometry must also work when native pages start in paragraphs or repeat the
/// source character of a continued table row. These views use the production TextKit stack.
@MainActor final class BoxPaginationIntegrationTests: XCTestCase {
    func testIndexedGroupsMatchVisualOverlapWithReorderedSourceLines() {
        let geometry = ReaderBoxGeometry()
        for index in 0..<200 {
            let range = NSRange(location: index * 10, length: 10)
            // Positioned glyph lines can appear before lines earlier in source order.
            let y = CGFloat(index * 20 - (index.isMultiple(of: 7) ? 60 : 0))
            geometry.paragraphs.append(.init(range: range, flowStart: y, flowEnd: y + 20,
                lines: [(NSRange(location: range.location, length: 5), CGRect(x: 0, y: y, width: 70, height: 10)),
                        (NSRange(location: range.location + 5, length: 5), CGRect(x: 0, y: y + 10, width: 90, height: 10))]))
        }
        for index in stride(from: 3, to: 200, by: 13) {
            geometry.regions.append(.init(range: NSRange(location: index * 10, length: 10),
                frame: CGRect(x: 100, y: CGFloat(index * 20 - 15), width: 80, height: 40), side: .left))
        }
        // A late absolute box reaches an earlier group, requiring sorting before merging.
        geometry.regions.append(.init(range: NSRange(location: 550, length: 10),
            frame: CGRect(x: 150, y: 60, width: 30, height: 15), side: .none))
        geometry.regions.append(.init(range: NSRange(location: 200, length: 5),
            frame: CGRect(x: 0, y: 390, width: 110, height: 20), side: .none, reserved: true))
        let lines = geometry.paragraphs.flatMap(\.lines)
        let candidates = geometry.regions.filter { !$0.reserved }.map { region in
            lines.reduce(region.range) { source, line in
                line.frame.maxY > region.frame.minY && line.frame.minY < region.frame.maxY
                    ? NSUnionRange(source, line.range) : source
            }
        }.sorted { $0.location < $1.location }
        var expected: [NSRange] = []
        for candidate in candidates {
            if let last = expected.last, last.upperBound >= candidate.location {
                expected[expected.count - 1] = NSUnionRange(last, candidate)
            } else { expected.append(candidate) }
        }
        geometry.formGroups()
        XCTAssertEqual(geometry.groups, expected)
        for group in expected + [NSRange(location: 777, length: 29)] {
            var bounds = CGRect.null
            for line in lines where NSIntersectionRange(line.range, group).length > 0 { bounds = bounds.union(line.frame) }
            for region in geometry.regions where NSIntersectionRange(region.range, group).length > 0 { bounds = bounds.union(region.frame) }
            XCTAssertEqual(geometry.bounds(of: group), bounds)
        }
    }

    private func section(_ body: String, font: CGFloat = 24) throws -> SectionText {
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body, css: """
            p, figure, figcaption { margin:0; }
            figure { float:left; width:35%; }
            table { border-spacing:0; }
            """))
        return SectionBuilder.build(.init(publication: publication, spineIndex: 0,
            typography: .init(fontSize: font), fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
    }

    func testFloatBeforeTallTablePreservesBoundedContinuationsAndFollowingProse() throws {
        let words = (0..<900).map { "cell\($0)" }
        for width: CGFloat in [180, 360, 500] {
            let section = try section("""
                <figure><figcaption>Short floating caption.</figcaption></figure>
                <table><tr><td>\(words.joined(separator: " "))</td><td>Side value</td></tr></table>
                <p>Following prose starts after the final table continuation.</p>
                """)
            let size = CGSize(width: width, height: 360)
            let paginator = ReaderPaginator(text: section.string, size: size)
            let pages = paginator.allPages
            let continued = pages.filter { !$0.tableFragments.isEmpty }
            XCTAssertGreaterThan(continued.count, 1)
            XCTAssertTrue(continued.contains { page in
                pages.contains { other in other.range == page.range && other.tableFragments != page.tableFragments }
            }, "The fixture must exercise pages sharing one table source character")
            var seen: [String] = [], tailSeen = false
            for (index, page) in pages.enumerated() {
                XCTAssertLessThanOrEqual(page.height + page.topSpacing, size.height + 0.75, "Width \(width), page \(index)")
                XCTAssertEqual(Set(page.tableFragments.map(\.offset)).count, page.tableFragments.count,
                               "One page cannot overwrite several continuations of one attachment")
                let view = pageView(paginator, page: page)
                assertNativeLinesFit(view, page: page, size: size, label: "Width \(width), page \(index)")
                seen += view.visibleText.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("cell") }.map(String.init)
                if view.visibleText.contains("Following prose") {
                    tailSeen = true
                    let range = (view.contentStorage.textStorage!.string as NSString).range(of: "Following prose")
                    let frame = try XCTUnwrap(view.lineFrame(containing: range.location))
                    XCTAssertGreaterThanOrEqual(frame.minY, -0.75)
                    XCTAssertLessThanOrEqual(frame.maxY, page.height + 0.75)
                }
            }
            XCTAssertEqual(seen, words, "Displayed continuations expose every word exactly once")
            XCTAssertTrue(tailSeen)
            XCTAssertEqual(pages.last?.range.upperBound, section.string.length)
        }
    }

    func testPagesBeginningInsideLongProseAfterFloatRebaseNativeLines() throws {
        let prose = (0..<1200).map { "body\($0)" }.joined(separator: " ")
        let section = try section("<figure><figcaption>Short float.</figcaption></figure><p>\(prose)</p><p>Final prose tail.</p>")
        for width: CGFloat in [180, 360, 500] {
            let size = CGSize(width: width, height: 360)
            let paginator = ReaderPaginator(text: section.string, size: size)
            let pages = paginator.allPages
            XCTAssertGreaterThanOrEqual(pages.count, 3)
            XCTAssertGreaterThan(pages.filter(\.continuesParagraph).count, 1)
            var displayed = "", cursor = 0
            for (index, page) in pages.enumerated() {
                XCTAssertEqual(page.range.location, cursor)
                cursor = page.range.upperBound
                XCTAssertLessThanOrEqual(page.height + page.topSpacing, size.height + 0.75)
                let view = pageView(paginator, page: page)
                assertNativeLinesFit(view, page: page, size: size, label: "Width \(width), page \(index)")
                displayed += view.visibleText
            }
            XCTAssertEqual(cursor, section.string.length)
            XCTAssertEqual(displayed, section.string.readerPlainText(), "Native pages preserve complete source coverage")
        }
    }

    private func pageView(_ paginator: ReaderPaginator, page: ReaderPage) -> ReaderTextView {
        let view = ReaderTextView(pageColumn: true)
        view.frame = CGRect(origin: .zero, size: CGSize(width: paginator.size.width, height: paginator.size.height - page.topSpacing))
        view.readerContainer.size = CGSize(width: paginator.size.width, height: 0)
        view.readerContainer.viewportSize = paginator.size
        view.placement = .init(section: 0, offset: page.range.location, visibleLength: page.range.length)
        view.setContent(paginator.text(for: page))
        view.ensureFullLayout()
        return view
    }

    private func assertNativeLinesFit(_ view: ReaderTextView, page: ReaderPage, size: CGSize, label: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        var visibleLines = 0
        view.readerLayoutManager.enumerateTextLayoutFragments(from: view.contentStorage.documentRange.location,
                                                              options: [.ensuresLayout]) { fragment in
            let start = view.offset(of: fragment.rangeInElement.location)
            for entry in fragment.textLineFragments {
                let range = NSRange(location: start + entry.characterRange.location, length: entry.characterRange.length)
                guard NSIntersectionRange(range, view.shownCharacters).length > 0 else { continue }
                visibleLines += 1
                let frame = entry.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
                XCTAssertGreaterThanOrEqual(frame.minY, -0.75, label, file: file, line: line)
                XCTAssertLessThanOrEqual(frame.maxY, page.height + 0.75, label, file: file, line: line)
                XCTAssertLessThanOrEqual(frame.maxY + page.topSpacing, size.height + 0.75, label, file: file, line: line)
            }
            return true
        }
        XCTAssertGreaterThan(visibleLines, 0, file: file, line: line)
    }
}
