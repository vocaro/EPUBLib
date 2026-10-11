import EPUBCore
import EPUBReading
import EPUBTestSupport
import XCTest
@testable import EPUBViewing

/// `NativeBook`, `NativeProgress` and the opening position without a mounted view: what the
/// session reports and shows is computed here.
@MainActor final class SessionCoverageBookTests: XCTestCase {
    private typealias Section = SessionCoverageBook.Section

    private func wait(_ label: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw SessionCoverageTimeout(description: "Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func book(_ publication: EPUBPublication, typography: NativeTypography = NativeTypography()) -> NativeBook {
        let book = NativeBook(publication: publication, typography: typography, rich: NativeRichContent())
        addTeardownBlock { @MainActor in book.close() }
        return book
    }

    // MARK: Progression

    /// `doc/native-viewer.md`: "overall progression (by section byte size, as foliate-js computed
    /// it)"; `NativeProgress`: "nonlinear sections weigh nothing".
    func testProgressionWeighsLinearSectionsByByteSizeAndNonlinearOnesNothing() throws {
        let publication = try EPUBPublication.open(data: SessionCoverageBook.chapters())
        XCTAssertEqual(publication.spine.map(\.isLinear), [true, false, true, true])
        let sizes = try publication.spine.map { Double(try publication.data(for: $0.resource).count) }
        let total = sizes[0] + sizes[2] + sizes[3]
        let progress = NativeProgress(publication: publication)
        XCTAssertEqual(progress.progression(section: 0, fraction: 0), 0, "the book's start is exactly 0")
        XCTAssertEqual(progress.progression(section: 3, fraction: 1), 1, "the book's end is exactly 1")
        XCTAssertEqual(try XCTUnwrap(progress.progression(section: 0, fraction: 0.5)), sizes[0] / 2 / total, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(progress.progression(section: 0, fraction: 1)), sizes[0] / total, accuracy: 1e-12)
        // The nonlinear note adds nothing, wherever in it the reader is.
        for fraction in [0, 0.5, 1] {
            XCTAssertEqual(try XCTUnwrap(progress.progression(section: 1, fraction: fraction)), sizes[0] / total, accuracy: 1e-12)
        }
        XCTAssertEqual(try XCTUnwrap(progress.progression(section: 2, fraction: 0)), sizes[0] / total, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(progress.progression(section: 2, fraction: 0.25)), (sizes[0] + sizes[2] / 4) / total, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(progress.progression(section: 3, fraction: 0)), (sizes[0] + sizes[2]) / total, accuracy: 1e-12)
        // A fraction outside 0–1 is the nearer end of its section, never outside the book.
        XCTAssertEqual(progress.progression(section: 0, fraction: -3), 0)
        XCTAssertEqual(progress.progression(section: 3, fraction: 7), 1)
        XCTAssertEqual(progress.progression(section: 2, fraction: 9), progress.progression(section: 2, fraction: 1))
        XCTAssertNil(progress.progression(section: 4, fraction: 0), "no such section")
        XCTAssertNil(progress.progression(section: -1, fraction: 0), "no such section")
        // Monotonic through the book in reading order.
        var last = -1.0
        for section in publication.spine.indices {
            for step in 0...10 {
                let value = try XCTUnwrap(progress.progression(section: section, fraction: Double(step) / 10))
                XCTAssertGreaterThanOrEqual(value, last, "section \(section) at \(step)/10")
                XCTAssertTrue((0...1).contains(value))
                last = value
            }
        }
    }

    func testProgressionOfASingleSectionIsItsOwnFractionAndOfABookWithNoLinearSectionIsUnknown() throws {
        let single = NativeProgress(publication: try EPUBPublication.open(data: SessionCoverageBook.epub([Section("only", "<p>Alone.</p>")])))
        for fraction in [0, 0.125, 0.5, 1] { XCTAssertEqual(single.progression(section: 0, fraction: fraction), fraction) }
        let nonlinear = try EPUBPublication.open(data: SessionCoverageBook.epub([
            Section("a", "<p>First.</p>", linear: false), Section("b", "<p>Second.</p>", linear: false),
        ]))
        XCTAssertNil(NativeProgress(publication: nonlinear).progression(section: 0, fraction: 0.5), "nothing weighs anything")
    }

    // MARK: Contents titles

    /// Chapter two holds three contents entries in document order under three different parents;
    /// the list also names a document outside the spine, an unlinked heading and an entry
    /// without a title.
    private func titledBook(toc: String?) throws -> EPUBPublication {
        try EPUBPublication.open(data: SessionCoverageBook.epub([
            Section("one", "<p>One.</p>"), Section("note", "<p>Note.</p>", linear: false),
            Section("two", "<p id=\"a\">A.</p><p id=\"b\">B.</p><p id=\"c\">C.</p>"), Section("three", "<p>Three.</p>"),
        ], toc: toc))
    }

    private static let nestedContents = """
        <li><a href="two.xhtml#a">Part A</a><ol><li><a href="two.xhtml#b">Part B</a></li></ol></li>\
        <li><a href="one.xhtml">Chapter One</a></li>\
        <li><span>Unlinked heading</span><ol><li><a href="two.xhtml#c">Part C</a></li></ol></li>\
        <li><a href="nav.xhtml">Contents</a></li><li><a href="three.xhtml#gone"></a></li>
        """

    /// `NativeProgress`: "the title of the last contents entry at or before a position".
    func testContentsTitleIsTheLastEntryAtOrBeforeAPosition() throws {
        let publication = try titledBook(toc: Self.nestedContents)
        XCTAssertEqual(publication.tableOfContents.count, 5)
        let progress = NativeProgress(publication: publication)
        let anchors = [2: ["a": 100, "b": 500, "c": 900]]
        func title(_ section: Int, _ offset: Int) -> String? {
            progress.title(at: ReaderTextPosition(section: section, offset: offset)) { anchors[$0]?[$1] }
        }
        XCTAssertEqual(title(0, 0), "Chapter One", "reading order, not contents order, decides between sections")
        XCTAssertEqual(title(0, 10_000), "Chapter One")
        XCTAssertEqual(title(1, 0), "Chapter One", "a section without an entry keeps the one before it")
        XCTAssertEqual(title(2, 0), "Chapter One", "before chapter two's first entry")
        XCTAssertEqual(title(2, 99), "Chapter One")
        XCTAssertEqual(title(2, 100), "Part A", "an entry names its own first character")
        XCTAssertEqual(title(2, 499), "Part A")
        XCTAssertEqual(title(2, 500), "Part B", "a nested entry")
        XCTAssertEqual(title(2, 900), "Part C", "an entry under an unlinked heading")
        XCTAssertEqual(title(2, 50_000), "Part C")
        XCTAssertEqual(title(3, 0), "Part C", "an entry without a title names nothing; nor does one outside the spine")
        // Until a section is built its entries sit at its start.
        XCTAssertEqual(progress.title(at: ReaderTextPosition(section: 2, offset: 0)) { _, _ in nil }, "Part C")
    }

    func testAPositionBeforeTheFirstEntryAndABookWithoutContentsHaveNoTitle() throws {
        let late = NativeProgress(publication: try titledBook(toc: "<li><a href=\"two.xhtml#b\">Part B</a></li>"))
        let anchors = [2: ["b": 500]]
        func title(_ progress: NativeProgress, _ section: Int, _ offset: Int) -> String? {
            progress.title(at: ReaderTextPosition(section: section, offset: offset)) { anchors[$0]?[$1] }
        }
        XCTAssertNil(title(late, 0, 0))
        XCTAssertNil(title(late, 1, 40))
        XCTAssertNil(title(late, 2, 499))
        XCTAssertEqual(title(late, 2, 500), "Part B")
        XCTAssertEqual(title(late, 3, 0), "Part B")
        let none = try titledBook(toc: "")
        XCTAssertTrue(none.tableOfContents.isEmpty)
        for section in 0..<4 { XCTAssertNil(title(NativeProgress(publication: none), section, 700)) }
    }

    /// `NativeProgress.SectionMarks` documents `title(at:)` and `page(at:)` as what the book-wide
    /// lookups answer; search results are named with one and locations with the other.
    func testSectionMarksAnswerAsTheBookWideLookupsDo() throws {
        let pages = """
            <li><a href="two.xhtml#c">3</a></li><li><a href="one.xhtml">i</a></li><li><a href="two.xhtml#a">1</a></li>\
            <li><a href="two.xhtml#a">1a</a></li><li><a href="two.xhtml#b">2</a></li><li><a href="two.xhtml#lost">x</a></li>
            """
        let publication = try EPUBPublication.open(data: SessionCoverageBook.epub([
            Section("one", "<p>One.</p>"), Section("note", "<p>Note.</p>", linear: false),
            Section("two", "<p id=\"a\">A.</p><p id=\"b\">B.</p><p id=\"c\">C.</p>"), Section("three", "<p>Three.</p>"),
        ], toc: Self.nestedContents, pageList: pages))
        XCTAssertEqual(publication.pageList?.count, 6)
        let progress = NativeProgress(publication: publication)
        let anchors = [2: ["a": 100, "b": 500, "c": 900]]
        for section in publication.spine.indices {
            let marks = progress.marks(inSection: section, anchors: anchors[section] ?? [:])
            for offset in [0, 1, 99, 100, 101, 499, 500, 899, 900, 901, 40_000] {
                let position = ReaderTextPosition(section: section, offset: offset)
                XCTAssertEqual(marks.title(at: offset), progress.title(at: position) { anchors[$0]?[$1] }, "title at \(position)")
                let page = progress.pages(in: ReaderTextRange(start: position, end: position), isShown: { _ in true }) { anchors[$0]?[$1] }.page
                XCTAssertEqual(marks.page(at: offset), page, "page at \(position)")
            }
        }
        // Spot values, so the agreement above is not two wrong answers.
        let two = progress.marks(inSection: 2, anchors: anchors[2]!)
        XCTAssertEqual(two.page(at: 0)?.label, "x", "a marker its section lacks sits at the section's start")
        XCTAssertEqual(two.page(at: 100)?.label, "1a", "of two entries at one place, the later listed")
        XCTAssertEqual(two.page(at: 600)?.label, "2")
        XCTAssertEqual(two.page(at: 900)?.label, "3")
        XCTAssertEqual(progress.marks(inSection: 0, anchors: [:]).page(at: 0)?.label, "i")
        XCTAssertEqual(progress.marks(inSection: 3, anchors: [:]).page(at: 0)?.label, "x", "the last listed of the section before")
    }

    // MARK: Disclosure text

    func testDisclosureTextSaysOneOrManyOfEachCountAndNothingForACleanBook() {
        XCTAssertNil(NativeDisclosure.text(for: SectionReport()))
        var report = SectionReport()
        report.scriptsRefused = 1
        XCTAssertEqual(NativeDisclosure.text(for: report), "One interactive part of this document was not run.")
        report.scriptsRefused = 3
        XCTAssertEqual(NativeDisclosure.text(for: report), "3 interactive parts of this document were not run.")
        report = SectionReport()
        report.remoteResourcesRefused = 1
        XCTAssertEqual(NativeDisclosure.text(for: report), "One resource this document asked to load from the internet was not loaded.")
        report.remoteResourcesRefused = 12
        XCTAssertEqual(NativeDisclosure.text(for: report), "12 resources this document asked to load from the internet were not loaded.")
        report = SectionReport()
        report.unsupportedElements = ["video": 1]
        XCTAssertEqual(NativeDisclosure.text(for: report), "One part of this document, such as a video or a form, cannot be shown by this reader.")
        report.unsupportedElements = ["video": 1, "form": 2]
        XCTAssertEqual(NativeDisclosure.text(for: report), "3 parts of this document, such as videos or forms, cannot be shown by this reader.")
        report = SectionReport()
        report.unreadableResources = 1
        XCTAssertEqual(NativeDisclosure.text(for: report), "One image could not be shown.")
        report.unreadableResources = 2
        report.mathFallbacks = 1
        report.mathApproximations = 2
        report.mathReductions = 1
        report.withheld = true
        report.fixedLayoutReflowed = true
        report.verticalWritingFlattened = true
        report.stylesTruncated = true
        XCTAssertEqual(NativeDisclosure.text(for: report), [
            "2 images could not be shown.", "One formula is shown as plain text.", "2 formulas are shown in a simplified layout.",
            "One wide formula is reduced in size on narrow pages.", "Some sections of this book could not be shown.",
            "This book's fixed page layout is shown as reflowable text.", "Vertical text is shown horizontally.",
            "Some of this book's styling was too large to apply.",
        ].joined(separator: " "))
        // A report that only says a section was read forgivingly discloses nothing.
        report = SectionReport()
        report.recoveredAsHTML = true
        XCTAssertNil(NativeDisclosure.text(for: report))
    }

    // MARK: Opening position

    private func landmark(_ type: String, _ href: String) -> String { "<li><a epub:type=\"\(type)\" href=\"\(href)\">\(type)</a></li>" }

    private func frontMatter(landmarks: String? = nil, guide: String = "", linear: [Bool] = [true, true, true, true],
                             epub2: Bool = false) throws -> EPUBPublication {
        try EPUBPublication.open(data: SessionCoverageBook.epub([
            Section("cover", "<p>Cover.</p>", linear: linear[0]), Section("title", "<p>Title.</p>", linear: linear[1]),
            Section("chapter", "<h1 id=\"top\">Chapter</h1><p id=\"deep\">Deep.</p>", linear: linear[2]),
            Section("end", "<p>End.</p>", linear: linear[3]),
        ], landmarks: landmarks, guide: guide, epub2: epub2))
    }

    /// `doc/native-viewer.md`, Opening position: "the first entry typed `bodymatter` or `text`".
    func testTheFirstTextStartCandidateWinsWhateverFollowsIt() throws {
        var publication = try frontMatter(landmarks: landmark("cover", "cover.xhtml") + landmark("text", "end.xhtml")
            + landmark("bodymatter", "chapter.xhtml"))
        XCTAssertEqual(publication.landmarks.map(\.types), [["cover"], ["text"], ["bodymatter"]])
        XCTAssertEqual(NativeSession.openingTarget(of: publication).section, 3, "the earlier `text` entry, not the later `bodymatter`")
        publication = try frontMatter(landmarks: landmark("bodymatter", "chapter.xhtml#deep") + landmark("bodymatter", "end.xhtml"))
        let target = NativeSession.openingTarget(of: publication)
        XCTAssertEqual(target.section, 2)
        XCTAssertEqual(target.fragment, "deep", "fragment included")
        // A candidate among several types, and a percent-encoded fragment.
        publication = try frontMatter(landmarks: landmark("frontmatter bodymatter", "chapter.xhtml#%74op"))
        XCTAssertEqual(NativeSession.openingTarget(of: publication).section, 2)
        XCTAssertEqual(NativeSession.openingTarget(of: publication).fragment, "top")
        // Other types do not start the text.
        publication = try frontMatter(landmarks: landmark("toc", "end.xhtml") + landmark("backmatter", "end.xhtml"))
        XCTAssertEqual(NativeSession.openingTarget(of: publication).section, 0)
    }

    /// "A book without one, or whose text start names no section of the book, opens at its first
    /// linear section": the first candidate decides, even when a later one would resolve.
    func testATextStartOutsideTheSpineFallsBackToTheFirstLinearSectionWithoutTryingLaterCandidates() throws {
        let publication = try frontMatter(landmarks: landmark("bodymatter", "nav.xhtml") + landmark("bodymatter", "chapter.xhtml"),
                                          linear: [false, true, true, true])
        let target = NativeSession.openingTarget(of: publication)
        XCTAssertEqual(target.section, 1, "the first linear section")
        XCTAssertNil(target.fragment)
    }

    /// The text start is "resolved as `navigate(href:)` resolves an href", which shows a
    /// nonlinear section on its own.
    func testATextStartNamingANonlinearSectionOpensThere() throws {
        let publication = try frontMatter(landmarks: landmark("bodymatter", "chapter.xhtml"), linear: [true, true, false, true])
        XCTAssertEqual(NativeSession.openingTarget(of: publication).section, 2)
    }

    /// "the navigation document's `landmarks`, or the EPUB 2 guide's references in a book without
    /// them": a guide is not consulted beside landmarks that name no text start.
    func testTheGuideStartsTheTextOnlyInABookWithoutLandmarks() throws {
        let guide = "<guide><reference type=\"cover\" title=\"Cover\" href=\"cover.xhtml\"/>"
            + "<reference type=\"text\" title=\"Start\" href=\"chapter.xhtml#deep\"/></guide>"
        var publication = try frontMatter(guide: guide)
        XCTAssertEqual(publication.landmarks.map(\.types), [["cover"], ["text"]])
        XCTAssertEqual(NativeSession.openingTarget(of: publication).section, 2)
        XCTAssertEqual(NativeSession.openingTarget(of: publication).fragment, "deep")
        publication = try frontMatter(guide: guide, epub2: true)
        XCTAssertEqual(NativeSession.openingTarget(of: publication).section, 2, "an EPUB 2 book")
        publication = try frontMatter(landmarks: landmark("toc", "nav.xhtml"), guide: guide)
        XCTAssertEqual(publication.landmarks.map(\.types), [["toc"]])
        XCTAssertEqual(NativeSession.openingTarget(of: publication).section, 0)
    }

    func testBooksWithoutATextStartOpenAtTheirFirstLinearSectionOrTheirFirstWhenNoneIsLinear() throws {
        XCTAssertEqual(NativeSession.openingTarget(of: try frontMatter(linear: [false, false, true, true])).section, 2)
        XCTAssertEqual(NativeSession.openingTarget(of: try frontMatter(linear: [false, false, false, false])).section, 0)
        let single = try EPUBPublication.open(data: SessionCoverageBook.epub([Section("only", "<p>Alone.</p>")]))
        XCTAssertEqual(NativeSession.openingTarget(of: single).section, 0)
    }

    // MARK: NativeBook

    private func mixedBook() throws -> EPUBPublication {
        try EPUBPublication.open(data: SessionCoverageBook.epub([
            Section("a", "<h1>Alpha</h1><p>First linear words.</p>"), Section("b", "<p>Left out.</p>", linear: false),
            Section("c", "<p>Second linear words.</p>"), Section("d", "<p>Trailing aside.</p>", linear: false),
        ]))
    }

    /// `NativeBook.bookText`: "every linear section, each followed by one paragraph break …
    /// Nonlinear sections are left out … (a book with no linear section keeps all)".
    func testTheWholeBookJoinsLinearSectionsAndMapsPositionsBothWays() async throws {
        let publication = try mixedBook()
        let book = book(publication)
        XCTAssertNil(book.bookText, "nothing is built")
        for index in publication.spine.indices { _ = await book.build(index) }
        XCTAssertTrue(book.isComplete)
        XCTAssertEqual([0, 1, 2, 3].map(book.isOmitted), [false, true, false, true])
        let text = try XCTUnwrap(book.bookText)
        let first = try XCTUnwrap(book.section(0)), second = try XCTUnwrap(book.section(2))
        XCTAssertEqual(text.omitted, [1, 3])
        XCTAssertEqual(text.string.string, first.string.string + "\n" + second.string.string)
        XCTAssertEqual(text.sectionStarts, [0, first.string.length + 1, first.string.length + 1, text.string.length])
        for (section, length) in [(0, first.string.length), (2, second.string.length)] {
            for offset in [0, 1, length / 2, length - 1] {
                let position = ReaderTextPosition(section: section, offset: offset)
                XCTAssertEqual(text.position(at: text.location(of: position)), position)
            }
        }
        XCTAssertEqual(text.position(at: text.string.length), ReaderTextPosition(section: 2, offset: second.string.length),
                       "the end of the text is the end of its last included section")
        XCTAssertFalse(text.contains(section: 1))
        XCTAssertFalse(text.contains(section: 4))
        XCTAssertTrue(book.bookText?.string === text.string, "the joined text is kept until a section changes")
    }

    func testABookWithNoLinearSectionKeepsEverySectionInItsWholeText() async throws {
        let publication = try EPUBPublication.open(data: SessionCoverageBook.epub([
            Section("a", "<p>First.</p>", linear: false), Section("b", "<p>Second.</p>", linear: false),
        ]))
        let book = book(publication)
        for index in publication.spine.indices { _ = await book.build(index) }
        XCTAssertEqual([0, 1].map(book.isOmitted), [false, false])
        let text = try XCTUnwrap(book.bookText)
        XCTAssertTrue(text.omitted.isEmpty)
        XCTAssertEqual(text.string.string, "First.\nSecond.")
    }

    /// `doc/native-viewer.md`, Release: "A typography change keeps each built section on screen
    /// until its rebuild arrives"; Pipeline: "A section's characters depend only on its document".
    func testASectionIsBuiltOncePerTypographyAndKeptUntilItsRebuildArrives() async throws {
        let publication = try mixedBook()
        let book = book(publication)
        var built: [Int] = []
        book.onSectionBuilt = { built.append($0) }
        let first = await book.build(0)
        let again = await book.build(0)
        XCTAssertTrue(first.string === again.string, "a second request is answered from the cache")
        XCTAssertEqual(built, [0])
        XCTAssertTrue(book.isCurrent(0))
        XCTAssertFalse(book.isComplete)

        book.setTypography(NativeTypography(fontSize: 30, isDark: true))
        XCTAssertTrue(book.section(0)?.string === first.string, "the old build stays available")
        XCTAssertFalse(book.isCurrent(0))
        let larger = await book.build(0)
        XCTAssertFalse(larger.string === first.string)
        XCTAssertEqual(larger.string.string, first.string.string, "typography never changes a section's characters")
        XCTAssertEqual(larger.anchors, first.anchors)
        XCTAssertEqual(built, [0, 0])
        XCTAssertTrue(book.isCurrent(0))
        func sizes(_ text: SectionText) -> Set<CGFloat> {
            var sizes = Set<CGFloat>()
            text.string.enumerateAttribute(.font, in: NSRange(location: 0, length: text.string.length)) { value, _, _ in
                if let font = value as? PlatformFont { sizes.insert(font.pointSize) }
            }
            return sizes
        }
        XCTAssertGreaterThan(try XCTUnwrap(sizes(larger).min()), try XCTUnwrap(sizes(first).min()))
        // Setting the typography it already has changes nothing.
        book.setTypography(NativeTypography(fontSize: 30, isDark: true))
        XCTAssertTrue(book.isCurrent(0))
    }

    func testBackgroundBuildingReportsEverySectionOnceThenCompletionOnce() async throws {
        let publication = try EPUBPublication.open(data: SessionCoverageBook.epub(
            (0..<24).map { Section("s\($0)", "<h1>Section \($0)</h1>\(SessionCoverageBook.filler(4))") }))
        let book = book(publication)
        var built: [Int] = [], completions = 0
        book.onSectionBuilt = { built.append($0) }
        book.onBookComplete = { completions += 1 }
        _ = await book.build(11)
        book.buildRemaining(from: 11)
        try await wait("every section") { completions == 1 }
        XCTAssertTrue(book.isComplete)
        XCTAssertEqual(built.first, 11, "the section asked for comes first")
        XCTAssertEqual(built.sorted(), Array(0..<24), "each section is reported once")
        XCTAssertEqual(try XCTUnwrap(book.bookText).sectionStarts.count, 24)
        // Asking again with nothing left to build neither rebuilds nor completes a second time.
        book.buildRemaining(from: 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(built.count, 24)
        XCTAssertEqual(completions, 1)
    }

    /// `NativeBook.onBookComplete`: "Every section is built for the current typography;
    /// `bookText` is available." The session swaps continuous scroll to the whole book on it.
    func testTheBookCompletesAgainForEachTypographyItIsRebuiltFor() async throws {
        let publication = try mixedBook()
        let book = book(publication)
        var completions: [NativeTypography] = []
        book.onBookComplete = { [unowned book] in completions.append(book.typography) }
        let regular = NativeTypography(), large = NativeTypography(fontSize: 28)
        _ = await book.build(0)
        book.buildRemaining(from: 0)
        try await wait("the first build") { completions == [regular] }
        book.setTypography(large)
        XCTAssertFalse(book.isComplete)
        XCTAssertNil(book.bookText)
        _ = await book.build(0)
        book.buildRemaining(from: 0)
        try await wait("the rebuild") { book.isComplete }
        try await wait("the rebuild's completion", timeout: 5) { completions == [regular, large] }
    }

    /// A reader who makes the text larger and then smaller again before the larger rebuild has
    /// finished is back at a typography the book completed for once. Sections rebuilt in between
    /// are stale again, so the whole text is gone until they are rebuilt, and its return must be
    /// announced like any other completion.
    func testTheBookCompletesAgainAfterReturningToATypographyItHadCompletedFor() async throws {
        let publication = try mixedBook()
        let book = book(publication)
        var completions: [NativeTypography] = []
        book.onBookComplete = { [unowned book] in completions.append(book.typography) }
        let regular = NativeTypography(), large = NativeTypography(fontSize: 28)
        _ = await book.build(0)
        book.buildRemaining(from: 0)
        try await wait("the first build") { completions == [regular] }
        XCTAssertNotNil(book.bookText)

        // The larger size reaches one section, then the reader goes back.
        book.setTypography(large)
        _ = await book.build(2)
        XCTAssertFalse(book.isComplete)
        book.setTypography(regular)
        XCTAssertFalse(book.isComplete, "section 2 is built for the larger size")
        XCTAssertNil(book.bookText, "so there is no whole text to show")
        _ = await book.build(0)
        book.buildRemaining(from: 0)
        try await wait("the rebuild of the stale section") { book.isComplete }
        XCTAssertNotNil(book.bookText)
        // The completion follows the last section within the same background task.
        try? await wait("the second completion", timeout: 5) { completions.count == 2 }
        XCTAssertEqual(completions, [regular, regular], "the book became complete a second time without saying so")
    }

    /// A typography taken back before any section was rebuilt for it leaves nothing to build,
    /// yet the book had no whole text in between, and a scroll view filled then shows one
    /// section. Its return is a completion like any other, announced once however many of the
    /// superseded changes ask for the rest of the book.
    func testTheBookCompletesAgainAfterATypographyIsTakenBackBeforeAnySectionIsRebuilt() async throws {
        let publication = try mixedBook()
        let book = book(publication)
        var completions: [NativeTypography] = []
        book.onBookComplete = { [unowned book] in completions.append(book.typography) }
        let light = NativeTypography(), dark = NativeTypography(isDark: true)
        _ = await book.build(0)
        book.buildRemaining(from: 0)
        try await wait("the first build") { completions == [light] }

        book.setTypography(dark)
        XCTAssertFalse(book.isComplete)
        XCTAssertNil(book.bookText)
        book.setTypography(light)
        XCTAssertTrue(book.isComplete, "no section was rebuilt in between")
        // Each change's own task asks for the rest: the superseded one and the one that stands.
        book.buildRemaining(from: 0)
        book.buildRemaining(from: 0)
        XCTAssertEqual(completions, [light, light], "the whole text came back without the book saying so")

        // The same between two typographies the book has both completed for.
        book.setTypography(dark)
        _ = await book.build(0)
        book.buildRemaining(from: 0)
        try await wait("the dark build") { completions == [light, light, dark] }
        book.setTypography(light)
        XCTAssertFalse(book.isComplete)
        book.setTypography(dark)
        XCTAssertTrue(book.isComplete)
        book.buildRemaining(from: 0)
        XCTAssertEqual(completions, [light, light, dark, dark])
    }

    func testClosingABookDropsItsSectionsAndLaterBuildsStoreNothing() async throws {
        let publication = try mixedBook()
        let book = book(publication)
        var built = 0
        book.onSectionBuilt = { _ in built += 1 }
        for index in publication.spine.indices { _ = await book.build(index) }
        XCTAssertEqual(built, 4)
        XCTAssertNotNil(book.bookText)
        book.close()
        book.close()
        XCTAssertEqual(book.count, 4)
        XCTAssertTrue(publication.spine.indices.allSatisfy { book.section($0) == nil })
        XCTAssertNil(book.bookText)
        XCTAssertFalse(book.isComplete)
        // A caller still waiting on a build gets its text; nothing is kept or reported.
        let late = await book.build(1)
        XCTAssertEqual(late.spineIndex, 1)
        XCTAssertNil(book.section(1))
        book.buildRemaining(from: 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(built, 4)
        XCTAssertNil(book.section(99), "an index outside the spine is no section")
        XCTAssertNil(book.section(-1))
    }

    func testTheDocumentForSearchingIsTheBuiltOneOrAFreshParseOfTheSameBytes() async throws {
        let publication = try mixedBook()
        let book = book(publication)
        let fresh = await book.document(2)
        let parsed = try XCTUnwrap(fresh)
        XCTAssertNil(book.section(2), "reading a document for search builds nothing")
        let built = await book.build(2)
        let again = await book.document(2)
        let kept = try XCTUnwrap(again)
        XCTAssertTrue(kept === built.document)
        XCTAssertEqual(parsed.nodes.count, built.document.nodes.count)
        let quote = "Second linear words."
        XCTAssertEqual(TextSearch.matches(of: quote, in: parsed, locale: nil).count, 1)
        XCTAssertEqual(TextSearch.matches(of: quote, in: kept, locale: nil).count, 1)
    }
}
