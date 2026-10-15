import CoreGraphics
import EPUBCore
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing

/// Every character of every chapter of the standard book corpora is on a visible line of some
/// page, at six reader sizes (#570). Skipped unless `EPUBLIB_GUTENBERG` or
/// `EPUBLIB_STANDARD_EBOOKS` names a corpus directory, as `scripts/fetch-corpora.sh` prints them
/// (doc/testing.md, "Corpus runs"). `EPUBLIB_PAGE_TEXT_CASES` (case names) and
/// `EPUBLIB_PAGE_TEXT_BOOKS` (file names without `.epub`) narrow a run, both comma-separated.
///
/// It lays out every page twice, as the paginator measures it and as its column shows it. On an
/// M5 Max in a release build (`swift test -c release --enable-testable-imports`), one process
/// per case with others running beside it, the Standard Ebooks corpus took 3 to 15 minutes a
/// case and Project Gutenberg's 16 to 43, the longest at 40 pt. Of Gutenberg's, 11 to 19
/// minutes a case is one book, the Cambridge Shakespeare, volume 3 (#50559), whose scenes are
/// inline blocks. A debug build is about four times slower.
@MainActor final class BookCorpusPageTextTests: XCTestCase {
    /// A viewport and text size; each is paginated at the reader's own column size for it.
    static let cases: [(name: String, viewport: CGSize, fontSize: CGFloat)] = [
        ("phone", CGSize(width: 390, height: 844), 17), ("phone-landscape", CGSize(width: 844, height: 390), 17),
        ("tablet", CGSize(width: 820, height: 1180), 19), ("mac", CGSize(width: 1024, height: 768), 16),
        ("small", CGSize(width: 320, height: 480), 17), ("phone-40pt", CGSize(width: 390, height: 844), 40),
    ]

    func testEveryCharacterOfEveryChapterIsOnAVisibleLine() throws {
        let environment = ProcessInfo.processInfo.environment
        let roots = ["EPUBLIB_GUTENBERG", "EPUBLIB_STANDARD_EBOOKS"].compactMap { environment[$0] }
        guard !roots.isEmpty else { throw XCTSkip("Set EPUBLIB_GUTENBERG or EPUBLIB_STANDARD_EBOOKS (scripts/fetch-corpora.sh)") }
        let caseNames = environment["EPUBLIB_PAGE_TEXT_CASES"].map { Set($0.split(separator: ",").map(String.init)) }
        let bookNames = environment["EPUBLIB_PAGE_TEXT_BOOKS"].map { Set($0.split(separator: ",").map(String.init)) }
        let cases = Self.cases.filter { caseNames?.contains($0.name) ?? true }
        let files = roots.flatMap { root in
            ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "epub" }
        }.filter { bookNames?.contains($0.deletingPathExtension().lastPathComponent) ?? true }.sorted { $0.path < $1.path }
        XCTAssertFalse(files.isEmpty, "No EPUB files in \(roots)")
        XCTAssertFalse(cases.isEmpty, "No case named in EPUBLIB_PAGE_TEXT_CASES")
        var chapters = 0, characters = 0
        for file in files {
            let book = file.deletingPathExtension().lastPathComponent
            let publication = try EPUBPublication.open(at: file)
            let fonts = FontRegistry(publication: publication)
            let rich = NativeRichContent()
            var built: [CGFloat: [SectionText]] = [:]
            for entry in cases {
                let sections = built[entry.fontSize] ?? autoreleasepool {
                    publication.spine.indices.map { index in
                        SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: index,
                            typography: NativeTypography(fontSize: entry.fontSize), fonts: fonts, rich: rich))
                    }
                }
                built[entry.fontSize] = sections
                let size = ReaderCanvasGeometry.spread(in: CGRect(origin: .zero, size: entry.viewport), division: nil,
                                                       isRightToLeft: false).columnSize
                for (index, section) in sections.enumerated() where section.string.length > 0 {
                    let missing = autoreleasepool { PageMeasurementTests.charactersOnNoVisibleLine(section.string, size: size).missing }
                    XCTAssertEqual(missing.count, 0, "\(book) spine item \(index) at \(entry.name): characters on no visible line \(Array(missing.rangeView.prefix(5)))")
                    chapters += 1
                    characters += section.string.length
                }
            }
        }
        print("Paged \(chapters) chapter layouts of \(files.count) books, \(characters) characters, at \(cases.map(\.name).joined(separator: ", "))")
    }
}
