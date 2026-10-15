import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// Every page is laid out as it is shown before its boundary is committed, the typography
/// fallback fits the line it makes, and a measured page's first line must fit its clip (#570).
/// Each section here had characters on no visible line of any page before: a page that was
/// never measured laid out one more line than the section (kind 1), the fallback fitted each
/// run but not the line they made (kind 2), or measuring committed a first line taller than
/// its page (kind 3, which measuring every page would cause without the first-line check).
@MainActor final class PageMeasurementTests: XCTestCase {
    private typealias H = BoxLayoutHarness

    /// The characters of `text` on no visible line of any page at `size`: by the character rule
    /// of `PageTextGeometryTests.assertVisiblePages`, a line is visible when it lies within the
    /// page's clip, its height when it clips layout context and its column's otherwise.
    static func charactersOnNoVisibleLine(_ text: NSAttributedString, size: CGSize) -> (missing: IndexSet, pages: [ReaderPage]) {
        let paginator = ReaderPaginator(text: text, size: size)
        let pages = paginator.allPages
        var visible = IndexSet()
        for page in pages {
            autoreleasepool {
                let view = H.pageView(paginator, page: page)
                let clip = min(page.layoutEnd > page.range.upperBound ? page.height : size.height - page.topSpacing,
                               size.height - page.topSpacing)
                for line in PageTextGeometryTests.rawLines(in: view, intersecting: view.shownCharacters)
                where line.frame.minY >= -0.75 && line.frame.maxY <= clip + 0.75 {
                    let range = NSIntersectionRange(line.range, view.shownCharacters)
                    visible.insert(integersIn: (page.range.location + range.location)..<(page.range.location + range.upperBound))
                }
            }
        }
        return (IndexSet(integersIn: 0..<paginator.text.length).subtracting(visible), pages)
    }

    @discardableResult
    private func assertEveryCharacterVisible(_ section: SectionText, size: CGSize, _ label: String,
                                             file: StaticString = #filePath, line: UInt = #line) -> [ReaderPage] {
        let result = Self.charactersOnNoVisibleLine(section.string, size: size)
        XCTAssertEqual(result.missing.count, 0, "\(label): characters on no visible line \(Array(result.missing.rangeView))",
                       file: file, line: line)
        return result.pages
    }

    // MARK: Kind 1: a page laid out alone breaks differently

    /// After the losses measured on Project Gutenberg: a justified paragraph that a page ends
    /// inside, whose own layout of the page's slice, justified with the rest of the paragraph
    /// as context, takes one more line than the section's did. The last line fell below the clip
    /// and the next page began after it: two characters at 40 pt in a phone's column, five at
    /// 180 × 240 pt.
    func testAJustifiedPageThatLaysOutOneMoreLineCarriesItForward() throws {
        let css = "p { text-align: justify; text-indent: 1.5em; margin: 0 }"
        let phone = try H.build("<p>\(Self.justifiedPhone[0])</p><p>\(Self.justifiedPhone[1])</p>", css: css, fontSize: 40)
        assertEveryCharacterVisible(phone, size: CGSize(width: 362.7, height: 748), "justified, phone column at 40 pt")
        let small = try H.build("<p>\(Self.justifiedSmall)</p>", css: css, fontSize: 19.3)
        let pages = assertEveryCharacterVisible(small, size: CGSize(width: 180, height: 240), "justified, 180 × 240 at 19.3 pt")
        XCTAssertTrue(pages.allSatisfy { $0.measuredLineLengths != nil }, "every page is measured, though the section has no box plan")
    }

    /// After The Art of War on Standard Ebooks: ragged English holding short spans of Chinese.
    /// A line with a glyph from the CJK fallback font lays out differently on the page than in
    /// the section, and five characters fell below the clip.
    func testRaggedTextHoldingChineseKeepsEveryLine() throws {
        let section = try H.build("<p>\(Self.artOfWar)</p>", css: "", fontSize: 25)
        XCTAssertNil(ReaderBoxLayout.resolve(section.string, viewport: CGSize(width: 250, height: 333.3)).geometry)
        assertEveryCharacterVisible(section, size: CGSize(width: 250, height: 333.3), "Chinese spans, 250 × 333.3 at 25 pt")
    }

    /// The suite's own generator, seed 22, section 443 (#570's first reproduction): page 17
    /// continues a justified paragraph and was not measured; its view broke "of the column.
    /// Short" | "one. Disproportion…", leaving "one. " below the clip.
    func testGeneratedSeed22Section443() throws {
        var random = SectionContentRandom(state: 22)
        for index in 0...443 {
            let size = random.pick(PageTextGeometryTests.viewports), font = random.pick(PageTextGeometryTests.fontSizes)
            let generated = PageTextGeometryTests.generate(&random, viewport: size)
            guard index == 443 else { continue }
            let section = try H.build(generated.body, css: H.reset + generated.css, fontSize: font, files: generated.files)
            PageTextGeometryTests.assertVisiblePages(section, size: size, label: "seed 22 section 443")
        }
    }

    // MARK: Kind 2: the fallback fits the line, not each run

    /// A line taller than its page whose runs differ in size. The fallback fitted the large run
    /// to the clip, but with the small run's line height applied to it (`line-height: 2`), or
    /// with the small runs' text beside it, the line was still taller, and the page kept its
    /// original line: every character of it below the clip.
    func testALineOfLargeAndSmallTextTallerThanItsPageFitsAsALine() throws {
        for (body, size, font) in [
            ("<p style='line-height:2'>a <span style='font-size:1200px'>B</span> c</p><p>After.</p>", CGSize(width: 400, height: 600), CGFloat(16)),
            // #570's r87: a caption's 150 px run among 30 pt text.
            ("<p>Cap 13 it returns. <span style='font-size:150px'>s z</span> I wraps beside.</p>", CGSize(width: 1024, height: 300), 30),
            ("<table><caption>Cap 13 it returns. <span style='font-size:150px'>s z</span> I wraps beside.</caption><tr><td>a</td><td>b</td></tr></table>",
             CGSize(width: 1024, height: 300), 30),
        ] {
            let section = try H.build(body, css: "", fontSize: font)
            let pages = assertEveryCharacterVisible(section, size: size, body)
            XCTAssertTrue(pages[0].usesFlowFallback && pages[0].fallbackScale < 1,
                          "the fallback lowered its target until the line fit: \(body)")
        }
    }

    /// A table whose rows fall back to tabbed text, with a nested table in a cell: the cell's
    /// label, a tab and the nested table's tall row make one line (#570's r65). The fallback fits
    /// the row to the clip; with the label's text beside it the line was still taller.
    func testTextBesideATableRowTallerThanItsPageFitsAsALine() throws {
        let section = try H.build("<table><tbody><tbody><tr><th>Label.</th><td><table border='1'><tr><td style='width:30px'>\(Self.prose(3))</td><td>x</td></tr></table></td></tr></tbody></tbody></table>",
                                  css: "", fontSize: 16)
        let pages = assertEveryCharacterVisible(section, size: CGSize(width: 180, height: 240), "label beside a tall row")
        XCTAssertTrue(pages.contains { $0.usesFlowFallback && $0.fallbackScale < 1 })
    }

    // MARK: Kind 3: a measured page's first line must fit

    /// After #570's r88: a row's text ("Second.", then a tab) and a nested table's row 1,200 pt
    /// tall. The section breaks the row onto a line of its own, which becomes continuation pages;
    /// the page's own layout puts it on the text's line. Committing that line, as measuring
    /// without the first-line check did, would drop the row's continuation pages and leave the
    /// line below the clip. The line goes to the fallback instead.
    func testAFirstLineHoldingATallRowGoesToTheFallback() throws {
        let section = try H.build("<table><tbody><tbody><tr><th><p>I a the.</p><p>Second.</p></th><td><table border='1' style='margin-left:40px;'><tr><td style='width:30px;'>\(Self.prose(3))</td><td>\(Self.prose(3))</td></tr></table></td></tr></tbody></tbody></table>",
                                  css: "", fontSize: 16)
        let pages = assertEveryCharacterVisible(section, size: CGSize(width: 40, height: 90), "a tall row on its page's first line")
        XCTAssertTrue(pages.contains { $0.usesFlowFallback }, "the line holding the row is shown as the fallback")
        for page in pages {
            XCTAssertLessThanOrEqual(page.height, 90 - page.topSpacing + 0.75, "no page is committed taller than its column")
        }
    }

    // MARK: Generated sections without a box plan (#570, acceptance)

    static let viewports = [CGSize(width: 180, height: 240), CGSize(width: 250, height: 333.3), CGSize(width: 297.6, height: 384),
                            CGSize(width: 362.7, height: 748), CGSize(width: 362.9, height: 294), CGSize(width: 440.3, height: 672),
                            CGSize(width: 720, height: 1084)]
    static let fontSizes: [CGFloat] = [12, 16, 17, 19.3, 25, 31.4, 40]

    /// Sections of justified, tabbed and indented paragraphs that pages end inside, with no box
    /// plan, so that before #570 only a page taller than its column was measured. Every
    /// character must be on a visible line. `PAGE_MEASUREMENT_SECTIONS` (default 120) and
    /// `PAGE_MEASUREMENT_SEED` (default 570) choose the sections. Before #570, sections 52 and
    /// 105 of the default seed lost characters, and 3 of its first 300; with it, none of 1,000.
    func testGeneratedSectionsWithoutABoxPlanShowEveryCharacter() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["PAGE_MEASUREMENT_SECTIONS"] ?? "") ?? 120
        let seed = UInt64(environment["PAGE_MEASUREMENT_SEED"] ?? "") ?? 570
        var random = SectionContentRandom(state: seed)
        for index in 0..<count {
            let size = random.pick(Self.viewports), font = random.pick(Self.fontSizes)
            let body = Self.paragraphs(&random)
            let section = try H.build(body, css: random.chance(3) ? "" : H.reset, fontSize: font)
            XCTAssertNil(ReaderBoxLayout.resolve(section.string, viewport: size).geometry, "section \(index) has no box plan")
            autoreleasepool { _ = assertEveryCharacterVisible(section, size: size, "seed \(seed) section \(index) at \(size), \(font) pt") }
        }
    }

    /// Six to fourteen paragraphs, each justified, tabbed, indented or plain prose.
    static func paragraphs(_ random: inout SectionContentRandom) -> String {
        var body = ""
        for _ in 0..<(6 + random.next(9)) {
            let sentences = (0..<(2 + random.next(14))).map { _ in random.pick(PageTextGeometryTests.ltr) }
            switch random.next(6) {
            case 0, 1:
                body += "<p style='text-align:justify;\(random.pick(["", " text-indent:1.5em;", " line-height:1.15;", " hyphens:auto;"]))'>"
                    + sentences.joined(separator: " ") + "</p>"
            case 2:
                let tabbed = sentences.map { $0.replacingOccurrences(of: ", ", with: ",&#9;") }.joined(separator: "&#9;")
                body += "<p style='white-space:pre-wrap;\(random.pick(["", " tab-size:3;", " tab-size:40px;", " text-align:justify;"]))'>\(tabbed)</p>"
            case 3:
                body += "<p style='\(random.pick(["text-indent:2em", "text-indent:-2em; padding-left:2em", "margin-left:3em; margin-right:1em", "text-indent:30%"]))'>"
                    + sentences.joined(separator: " ") + "</p>"
            case 4:
                body += "<p>" + sentences.joined(separator: " <span style='white-space:pre'>a&#9;b</span> ") + "</p>"
            default:
                body += "<p>" + sentences.joined(separator: " ") + "</p>"
            }
        }
        return body
    }

    // MARK: Text

    static func prose(_ count: Int) -> String {
        Array(repeating: "Ordinary prose wraps beside the box and returns to the full column below it.", count: count).joined(separator: " ")
    }

    static let justifiedSmall = "A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. No. Words of several lengths, unremarkable and plain, fill another row or two of the column. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. No. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Words of several lengths, unremarkable and plain, fill another row or two of the column. Ordinary prose wraps beside the box and returns to the full column below it. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up."

    static let justifiedPhone = [
        "Words of several lengths, unremarkable and plain, fill another row or two of the column. Words of several lengths, unremarkable and plain, fill another row or two of the column. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Short one. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. She counted the steps twice; forty-one each time, which settled nothing at all. She counted the steps twice; forty-one each time, which settled nothing at all. No. No. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Ordinary prose wraps beside the box and returns to the full column below it. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and \u{201C}quotation marks\u{201D}.",
        "Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Words of several lengths, unremarkable and plain, fill another row or two of the column. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. No. Words of several lengths, unremarkable and plain, fill another row or two of the column. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Short one. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences.",
    ]

    /// Lionel Giles's translation of The Art of War (1910) and the Chinese it quotes, both in the
    /// public domain.
    static let artOfWar = "\u{201C}These things all serve to destroy formation and conceal one\u{2019}s condition.\u{201D} <span lang='zh-Hant'>懼人有走心</span> Tsʽao Kung throws out a hint of the meaning in his brief note: It is a matter of life and death, a road either to safety or to ruin. <span lang='zh-Hant'>知彼知己，百戰不殆。</span> All warfare is based on deception. All warfare is based on deception. <span lang='zh-Hant'>故經之以五事，校之以計，而索其情。</span> But Tu Mu is the first to put it quite plainly. <span lang='zh-Hant'>故經之以五事，校之以計，而索其情。</span> Wang Hsi says the same. <span lang='zh-Hant'>兵者，詭道也。</span>"
}
