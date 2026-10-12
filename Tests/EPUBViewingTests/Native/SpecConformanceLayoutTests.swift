import EPUBCore
import EPUBReading
import EPUBTestSupport
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One requirement of EPUB Reading Systems 3.3 per test, for the book as it is laid out and
/// read: the pages a section paginates into at a fixed column size, and a mounted reader driven
/// through its public commands (the reading order, non-linear and repeated spine items, the
/// table of contents, saved positions and what the host is told to disclose).
@MainActor final class SpecConformanceLayoutTests: XCTestCase {
    private typealias Book = Fixture.SpecBook
    private typealias Build = SpecConformanceBuild

    private func mount(_ book: Book) throws -> SpecConformanceReader {
        let reader = try SpecConformanceReader(book)
        addTeardownBlock { @MainActor in reader.close() }
        return reader
    }

    // MARK: Pages

    /// RS 8.2.1 (`paginated`): a reflowable section is dynamically paginated. Its pages cover
    /// its text once, in order, none taller than the column, and more of them at a larger size.
    func testASectionPaginatesIntoPagesThatCoverItsTextOnceInOrder() throws {
        var book = Book()
        book.add("chapter", body: "<h1>The Chapter</h1>" + Book.prose(80))
        var counts: [CGFloat: Int] = [:]
        for fontSize: CGFloat in [16, 24] {
            let section = try Build(book, fontSize: fontSize)[0]
            for size in [CGSize(width: 362, height: 660), CGSize(width: 480, height: 720)] {
                let (paginator, pages) = section.specPages(size)
                let label = "\(Int(size.width))x\(Int(size.height)) at \(Int(fontSize)) pt"
                XCTAssertGreaterThan(pages.count, 3, label)
                XCTAssertEqual(pages.first?.range.location, 0, label)
                XCTAssertEqual(pages.map { page in
                    (paginator.text(for: page).string as NSString).substring(with: NSRange(location: 0, length: page.range.length))
                }.joined(), section.specText, "the pages are the section, once and in order: \(label)")
                XCTAssertTrue(pages.allSatisfy { $0.range.length > 0 && $0.height + $0.topSpacing <= size.height + 0.75 }, label)
                XCTAssertEqual(paginator.pageIndex(containing: section.specLocation("The Chapter")), 0, label)
                let paragraphPages = (1...80).map { paginator.pageIndex(containing: section.specLocation("Paragraph \($0) of")) }
                XCTAssertEqual(paragraphPages, paragraphPages.sorted(), "reading order is page order: \(label)")
                XCTAssertEqual(paragraphPages.last, pages.count - 1, label)
                if size.width == 362 { counts[fontSize] = pages.count }
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(counts[24]), try XCTUnwrap(counts[16]), "larger text takes more pages")
    }

    /// CSS `break-before`, `break-after` and their `page-break-*` forms: a forced break starts
    /// a new page exactly at the element that asks for it (RS 6.3, the CSS a reading system
    /// with a viewport supports for paginated flow).
    func testForcedPageBreaksStartNewPagesAtTheElementsThatAskForThem() throws {
        var book = Book()
        book.add("chapter", body: """
            <p>Intro one.</p><p>Intro two.</p>
            <h2 style="page-break-before: always">Part Two</h2><p>Part two text.</p>
            <div style="break-before: page"><p>Part three text.</p></div>
            <p style="page-break-after: always">Ends its page.</p>
            <p>Final page.</p>
            """)
        let section = try Build(book)[0]
        XCTAssertEqual(section.specText, "Intro one.\nIntro two.\nPart Two\nPart two text.\nPart three text.\nEnds its page.\nFinal page.")
        for size in [CGSize(width: 362, height: 660), CGSize(width: 720, height: 980)] {
            let (paginator, pages) = section.specPages(size)
            XCTAssertEqual(pages.map(\.range.location),
                           ["Intro one.", "Part Two", "Part three text.", "Final page."].map { section.specLocation($0) }, "\(size)")
            XCTAssertEqual(paginator.pageIndex(containing: section.specLocation("Ends its page.")), 2)
        }
    }

    /// doc/native-viewer.md (Layout): "An attachment taller than a page gets a page of its
    /// own": a tall image is scaled to the page, keeping its shape, between the text around it.
    func testAnImageTallerThanThePageIsScaledOntoAPageOfItsOwn() throws {
        var book = Book()
        book.add("chapter", body: "<p>Before the plate.</p><p><img src=\"tall.png\" alt=\"A tall plate\"/></p><p>After the plate.</p>")
        book.resource("tall.png", id: "tall", mediaType: "image/png", Book.image(width: 200, height: 1600))
        let section = try Build(book)[0]
        let size = CGSize(width: 300, height: 400)
        let image = try XCTUnwrap(section.specImages.first)
        let shown = image.specSize(lineWidth: size.width, viewport: size)
        XCTAssertLessThanOrEqual(shown.height, size.height)
        XCTAssertEqual(shown.width / shown.height, 200.0 / 1600.0, accuracy: 0.01)
        let (paginator, pages) = section.specPages(size)
        let before = paginator.pageIndex(containing: section.specLocation("Before the plate."))
        let plate = paginator.pageIndex(containing: section.specAttachments[0].location)
        let after = paginator.pageIndex(containing: section.specLocation("After the plate."))
        XCTAssertEqual([before, plate, after], [0, 1, 2])
        XCTAssertTrue(pages.allSatisfy { $0.height + $0.topSpacing <= size.height + 0.75 })
    }

    /// RS 7: the navigation document may itself be in the spine, where it reads as a document:
    /// its links lead to their targets and what the author hid stays hidden (EPUB 3.3 7.5).
    func testANavigationDocumentInTheSpineReadsAsItsLinksWithHiddenPartsLeftOut() throws {
        var book = Book()
        book.navigation = """
            <nav epub:type="toc" id="toc"><h1>Contents</h1><ol>
              <li><a href="one.xhtml">Chapter One</a></li>
              <li hidden="hidden"><a href="one.xhtml#aside">An entry hidden in the content flow</a></li>
              <li><a href="two.xhtml#second">Chapter Two</a></li>
            </ol></nav>
            <nav epub:type="page-list" hidden=""><ol><li><a href="one.xhtml#p1">1</a></li></ol></nav>
            <nav epub:type="landmarks" hidden="hidden"><ol><li><a epub:type="bodymatter" href="one.xhtml">Start</a></li></ol></nav>
            """
        book.spine = "    <itemref idref=\"nav\"/>\n    <itemref idref=\"one\"/>\n    <itemref idref=\"two\"/>"
        book.add("one", body: "<h1>Chapter One</h1><p id=\"aside\">An aside.</p><p><span id=\"p1\"/>Text.</p>")
        book.add("two", body: "<p>Lead.</p><h1 id=\"second\">Chapter Two</h1>")
        let built = try Build(book)
        XCTAssertEqual(built.publication.spine.map(\.resource.path), ["EPUB/nav.xhtml", "EPUB/one.xhtml", "EPUB/two.xhtml"])
        XCTAssertEqual(built.publication.tableOfContents.map(\.title), ["Chapter One", "An entry hidden in the content flow", "Chapter Two"])
        XCTAssertEqual(built.publication.pageList, [EPUBPageListEntry(label: "1", href: "EPUB/one.xhtml#p1")])
        let nav = built[0]
        let shown = nav.specText.components(separatedBy: "\n").map { $0.components(separatedBy: "\t").last ?? $0 }
        XCTAssertEqual(shown, ["Contents", "Chapter One", "Chapter Two"])
        XCTAssertEqual(nav.specLink("Chapter One"), .internal(href: "EPUB/one.xhtml"))
        XCTAssertEqual(nav.specLink("Chapter Two"), .internal(href: "EPUB/two.xhtml#second"))
        XCTAssertEqual(built[2].anchors["second"], built[2].specLocation("Chapter Two"))
        XCTAssertNil(built.disclosure)
        try built.assertPositionsRoundTrip()
    }

    /// RS 5.5: "The reading system MUST treat these as distinct items for user interface (UI)
    /// purposes": a position in the second or third occurrence of a repeated spine item names
    /// that occurrence, not the first (W3C test pkg-spine-duplicate-item-ui).
    func testEachOccurrenceOfARepeatedSpineItemHasItsOwnPosition() throws {
        var book = Book()
        book.add("first", body: "<p>The first document.</p>")
        book.add("refrain", body: "<p>A refrain that returns.</p>")
        book.spine = "    <itemref idref=\"first\"/>\n    <itemref idref=\"refrain\"/>\n    <itemref idref=\"refrain\"/>\n    <itemref idref=\"refrain\"/>"
        let publication = try EPUBPublication.open(data: book.archive())
        XCTAssertEqual(publication.spine.map(\.resource.path), ["EPUB/first.xhtml", "EPUB/refrain.xhtml", "EPUB/refrain.xhtml", "EPUB/refrain.xhtml"])
        let spine = try SpineCFIs(publication: publication)
        XCTAssertEqual(Set(spine.bases).count, 4, "each occurrence has its own CFI")
        XCTAssertEqual(spine.bases.map { spine.resolve($0)?.spineIndex }, [0, 1, 2, 3])
    }

    // MARK: A mounted reader

    /// RS 5.5: the reader starts at the first linear itemref and renders the spine in order;
    /// it may skip non-linear items while paging, but "When a user activates a hyperlink to a
    /// non-linear resource ... reading systems MUST render the referenced resource".
    func testTheReaderPagesThroughTheLinearSpineAndAHyperlinkOpensANonLinearItem() async throws {
        var book = Book()
        book.add("cover", itemref: "linear=\"no\"", body: "<p>The cover, outside the reading order.</p>")
        book.add("one", body: "<h1>One</h1><p>See <a href=\"notes.xhtml#n1\">the notes</a>.</p>" + Book.prose(40, label: "First"))
        book.add("notes", itemref: "linear=\"no\"", body: "<p id=\"n1\">A note outside the reading order.</p>")
        book.add("two", body: "<h1>Two</h1>" + Book.prose(40, label: "Second"))
        book.add("three", body: "<h1>Three</h1><p>The last words of the book.</p>")
        let reader = try mount(book)
        try await reader.waitUntilReady()
        let session = reader.session
        XCTAssertEqual(session.visibleRange?.start, ReaderTextPosition(section: 1, offset: 0), "the first linear section")
        XCTAssertEqual(reader.locations.first?.href, "EPUB/one.xhtml")
        XCTAssertTrue(reader.visibleText.hasPrefix("One\nSee the notes."), reader.visibleText)
        let visited = try await reader.pageThrough()
        XCTAssertEqual(visited, [1, 3, 4], "the linear sections in spine order")
        XCTAssertTrue(reader.visibleText.contains("The last words of the book."), reader.visibleText)
        XCTAssertEqual(session.readerState?.status.canGoNext, false)
        XCTAssertEqual(reader.locations.last?.href, "EPUB/three.xhtml")
        XCTAssertEqual(reader.locations.last?.progression ?? 0, 1, accuracy: 0.001, "the book's last page")
        // The hyperlink in chapter one, activated as a tap on it would.
        let one = try XCTUnwrap(session.book.section(1))
        let link = try XCTUnwrap(one.specLink("the notes"))
        XCTAssertEqual(link, .internal(href: "EPUB/notes.xhtml#n1"))
        session.canvas(try XCTUnwrap(session.canvas), didActivate: link,
                       at: ReaderTextPosition(section: 1, offset: one.specLocation("the notes")), rect: .zero)
        try await reader.wait("the non-linear notes") { session.visibleRange?.start.section == 2 }
        XCTAssertEqual(reader.visibleText, "A note outside the reading order.")
        XCTAssertEqual(reader.locations.last?.href, "EPUB/notes.xhtml")
        try await session.send(.navigate(href: "EPUB/cover.xhtml"))
        try await reader.wait("the non-linear cover") { session.visibleRange?.start.section == 0 }
        XCTAssertTrue(reader.notices.isEmpty, "\(reader.notices)")
        XCTAssertEqual(reader.events.filter { $0 == .ready }.count, 1)
    }

    /// RS 7: "MUST move the reading position to the target when an activated link points to a
    /// publication resource": every table-of-contents entry, nested or pointing into the
    /// middle of a document, shows its target, and the position reports the entry's title.
    func testEveryContentsEntryShowsItsTargetAndNamesThePosition() async throws {
        var book = Book()
        book.add("one", body: "<h1 id=\"top\">One</h1>" + Book.prose(30, label: "Early")
            + "<h2 id=\"deep\">One, Later</h2>" + Book.prose(30, label: "Late"))
        book.add("two", body: "<h1>Two</h1>" + Book.prose(20, label: "Second") + "<h2 id=\"end part\">Two, Ending</h2><p>Closing words.</p>")
        book.navigation = """
            <nav epub:type="toc"><ol>
              <li><a href="one.xhtml#top">Chapter One</a>
                <ol><li><a href="one.xhtml#deep">Its Later Part</a></li></ol></li>
              <li><a href="two.xhtml">Chapter Two</a>
                <ol><li><a href="two.xhtml#end%20part">Its Ending</a></li></ol></li>
            </ol></nav>
            """
        let reader = try mount(book)
        try await reader.waitUntilReady()
        let session = reader.session
        func flatten(_ items: [EPUBNavigationItem]) -> [EPUBNavigationItem] { items.flatMap { [$0] + flatten($0.children) } }
        let entries = flatten(session.publication.tableOfContents)
        XCTAssertEqual(entries.map(\.title), ["Chapter One", "Its Later Part", "Chapter Two", "Its Ending"])
        let targets: [(section: Int, phrase: String)] = [(0, "One\n"), (0, "One, Later"), (1, "Two\n"), (1, "Two, Ending")]
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            try await session.send(.style(.init(flow: flow)))
            for (entry, target) in zip(entries, targets).reversed() {
                let href = try XCTUnwrap(entry.href)
                let text = try XCTUnwrap(session.book.section(target.section))
                let position = ReaderTextPosition(section: target.section, offset: text.specLocation(target.phrase))
                try await session.send(.navigate(href: href))
                try await reader.wait("\(entry.title) in \(flow)") {
                    guard let visible = session.visibleRange else { return false }
                    return visible.start <= position && position < visible.end && session.lastLocation?.title == entry.title
                }
                XCTAssertEqual(session.lastLocation?.href, session.publication.spine[target.section].resource.href, entry.title)
                XCTAssertEqual(session.lastLocation?.title, entry.title, "\(flow)")
            }
        }
        XCTAssertTrue(reader.notices.isEmpty, "\(reader.notices)")
    }

    /// RS 5.5: reading systems "MUST NOT skip spine references to duplicate manifest items when
    /// rendering the linear reading order", and following a hyperlink to a document the spine
    /// names more than once "MUST navigate to the first occurrence".
    func testRepeatedSpineItemsAreEachShownAndAHyperlinkGoesToTheFirst() async throws {
        var book = Book()
        book.add("first", body: "<p>The first document.</p>")
        book.add("refrain", body: "<p>A refrain that returns.</p>")
        book.add("last", body: "<p>The last document, with <a href=\"refrain.xhtml\">a link to the refrain</a>.</p>")
        book.spine = ["first", "refrain", "refrain", "last", "refrain"].map { "    <itemref idref=\"\($0)\"/>" }.joined(separator: "\n")
        let reader = try mount(book)
        try await reader.waitUntilReady()
        let session = reader.session
        XCTAssertEqual(session.publication.spine.count, 5)
        let visited = try await reader.pageThrough()
        XCTAssertEqual(visited, [0, 1, 2, 3, 4], "every spine reference in order")
        XCTAssertEqual(reader.visibleText, "A refrain that returns.")
        let last = try XCTUnwrap(session.book.section(3))
        let link = try XCTUnwrap(last.specLink("a link to the refrain"))
        session.canvas(try XCTUnwrap(session.canvas), didActivate: link,
                       at: ReaderTextPosition(section: 3, offset: last.specLocation("a link to the refrain")), rect: .zero)
        try await reader.wait("the first occurrence") { session.visibleRange?.start.section == 1 }
        XCTAssertEqual(session.visibleRange?.start, ReaderTextPosition(section: 1, offset: 0))
    }

    /// RS 5.5: repeats are "distinct items for user interface (UI) purposes". A position saved
    /// in a later occurrence of a repeated spine item names that occurrence, and restoring it
    /// goes back there, not to the first occurrence, in either flow.
    func testAPositionSavedInALaterRepeatRestoresToThatRepeat() async throws {
        var book = Book()
        book.add("first", body: "<h1>First</h1>" + Book.prose(30, label: "First"))
        book.add("refrain", body: "<h1>Refrain</h1>" + Book.prose(30, label: "Refrain"))
        book.spine = ["first", "refrain", "refrain", "refrain"].map { "    <itemref idref=\"\($0)\"/>" }.joined(separator: "\n")
        let reader = try mount(book)
        try await reader.waitUntilReady()
        let session = reader.session
        // Only page turns reach a later repeat: an href names the first. One page into the third itemref.
        for turn in 0..<200 where session.visibleRange.map({ $0.start.section == 2 && $0.start.offset > 0 }) != true {
            let before = session.visibleRange
            try await session.send(.nextPage)
            try await reader.wait("turn \(turn)") { session.visibleRange != before }
        }
        let start = try XCTUnwrap(session.visibleRange?.start)
        XCTAssertEqual(start.section, 2); XCTAssertGreaterThan(start.offset, 0)
        try await reader.wait("its location") { session.lastLocation?.bookmark?.value.hasPrefix("epubcfi(/6/6!") == true }
        let location = try XCTUnwrap(session.lastLocation)
        XCTAssertEqual(location.href, "EPUB/refrain.xhtml")
        XCTAssertEqual(try SpineCFIs(publication: session.publication).resolve(try XCTUnwrap(location.bookmark).value)?.spineIndex, 2)
        // Progression is by section byte size: the third itemref's share of the book, not the second's.
        let sizes = try session.publication.spine.map { Double(try session.publication.data(for: $0.resource).count) }
        let share = (sizes[0] + sizes[1]) / sizes.reduce(0, +)...(sizes[0] + sizes[1] + sizes[2]) / sizes.reduce(0, +)
        XCTAssertTrue(share.contains(try XCTUnwrap(location.progression)), "\(String(describing: location.progression)) in \(share)")
        let stored = try JSONDecoder().decode(EPUBLocation.self, from: JSONEncoder().encode(location))
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            try await session.send(.style(.init(flow: flow)))
            try await session.send(.navigate(href: "EPUB/first.xhtml"))
            try await reader.wait("the first document in \(flow)") { session.visibleRange?.start.section == 0 }
            try await session.send(.restore(stored))
            try await reader.wait("the second repeat in \(flow)") {
                guard let visible = session.visibleRange else { return false }
                return flow == .paginated ? visible.start == start : visible.start <= start && start < visible.end
            }
            try await reader.wait("its location in \(flow)") { session.lastLocation?.bookmark?.value.hasPrefix("epubcfi(/6/6!") == true }
            XCTAssertTrue(share.contains(try XCTUnwrap(session.lastLocation?.progression)), "\(flow): \(String(describing: session.lastLocation?.progression)) in \(share)")
        }
        XCTAssertTrue(reader.notices.isEmpty, "\(reader.notices)")
    }

    /// RS 3.9 recommends asking before opening a link outside the publication;
    /// doc/native-viewer.md (Security) decides: "External links are refused with a notice".
    /// Activating one tells the host and moves nothing. A link that climbs past the container
    /// root stops there (RS 4.1.1): it is a link into the book, here to a document it lacks,
    /// and moves nothing either.
    func testALinkOutsideTheBookIsRefusedWithANoticeAndThePositionStays() async throws {
        var book = Book()
        book.add("one", body: "<p>Visit <a href=\"https://example.org/\">the site</a>, <a href=\"mailto:someone@example.org\">write</a> "
            + "or follow <a href=\"../../outside.xhtml\">a leaking link</a>.</p>" + Book.prose(30))
        book.add("two", body: "<p>Second.</p>")
        let reader = try mount(book)
        try await reader.waitUntilReady()
        let session = reader.session, section = try XCTUnwrap(session.book.section(0))
        let before = session.visibleRange, located = reader.locations.count
        XCTAssertEqual(section.specLink("a leaking link"), .internal(href: "outside.xhtml"))
        for phrase in ["the site", "write", "a leaking link"] {
            let link = try XCTUnwrap(section.specLink(phrase))
            session.canvas(try XCTUnwrap(session.canvas), didActivate: link,
                           at: ReaderTextPosition(section: 0, offset: section.specLocation(phrase)), rect: .zero)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reader.notices, Array(repeating: "This reader does not open links outside the book.", count: 2))
        XCTAssertEqual(session.visibleRange, before)
        XCTAssertEqual(reader.locations.count, located)
    }

    /// RS 10 (optional behaviours): a `noteref` whose target is not a note the reader holds is
    /// still a hyperlink, and following it moves the reading position to its target (RS 7).
    func testANoterefWhoseTargetIsNoNoteNavigatesToIt() async throws {
        var book = Book()
        book.add("one", body: "<p>See<a epub:type=\"noteref\" href=\"two.xhtml#target\">*</a> the next chapter.</p>" + Book.prose(30))
        book.add("two", body: Book.prose(30) + "<p id=\"target\">An ordinary paragraph, not a note.</p>")
        let reader = try mount(book)
        try await reader.waitUntilReady()
        let session = reader.session, section = try XCTUnwrap(session.book.section(0))
        let link = try XCTUnwrap(section.specLink("*"))
        XCTAssertEqual(link, .note(href: "EPUB/two.xhtml#target"))
        XCTAssertNil(try XCTUnwrap(session.book.section(1)).notes["target"])
        session.canvas(try XCTUnwrap(session.canvas), didActivate: link, at: ReaderTextPosition(section: 0, offset: section.specLocation("*")), rect: .zero)
        let target = ReaderTextPosition(section: 1, offset: try XCTUnwrap(session.book.section(1)).specLocation("An ordinary paragraph"))
        try await reader.wait("the link's target") {
            guard let visible = session.visibleRange else { return false }
            return visible.start <= target && target < visible.end
        }
        XCTAssertTrue(reader.notices.isEmpty, "\(reader.notices)")
    }

    /// A reading position saved as an EPUB CFI (EPUB CFI 1.1; doc/native-viewer.md "Engine
    /// identity and bookmarks") names the same place after a round trip through storage, a
    /// navigation elsewhere and a change of flow.
    func testASavedPositionRestoresToTheSamePlaceInEitherFlow() async throws {
        var book = Book()
        book.add("one", body: "<h1>One</h1>" + Book.prose(30, label: "First"))
        book.add("two", body: "<h1>Two</h1>" + Book.prose(40, label: "Early") + "<p id=\"mark\">A marked passage deep in chapter two.</p>"
            + Book.prose(40, label: "Late"))
        let reader = try mount(book)
        try await reader.waitUntilReady()
        let session = reader.session
        try await session.send(.navigate(href: "EPUB/two.xhtml#mark"))
        let two = try XCTUnwrap(session.book.section(1))
        let mark = ReaderTextPosition(section: 1, offset: two.specLocation("A marked passage"))
        try await reader.wait("the marked passage") {
            guard let visible = session.visibleRange else { return false }
            return visible.start <= mark && mark < visible.end && session.lastLocation?.href == "EPUB/two.xhtml"
        }
        let start = try XCTUnwrap(session.visibleRange?.start)
        XCTAssertGreaterThan(start.offset, 0, "pages into the chapter")
        let location = try XCTUnwrap(session.lastLocation)
        let bookmark = try XCTUnwrap(location.bookmark)
        XCTAssertEqual(bookmark.engineID, EPUBReader.identifier); XCTAssertEqual(bookmark.format, EPUBReader.bookmarkFormat)
        XCTAssertTrue(bookmark.value.hasPrefix("epubcfi(/6/4!/4"), "the second itemref, then the document's body: \(bookmark.value)")
        XCTAssertTrue(EPUBCFI.isWellFormed(bookmark.value), bookmark.value)
        let progression = try XCTUnwrap(location.progression)
        XCTAssertTrue(progression > 0.3 && progression < 1, "\(progression)")
        let stored = try JSONDecoder().decode(EPUBLocation.self, from: JSONEncoder().encode(location))
        XCTAssertEqual(stored, location)
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            try await session.send(.style(.init(flow: flow)))
            try await session.send(.navigate(href: "EPUB/one.xhtml"))
            try await reader.wait("chapter one in \(flow)") { session.visibleRange?.start.section == 0 }
            try await session.send(.restore(stored))
            try await reader.wait("the restored position in \(flow)") {
                guard let visible = session.visibleRange else { return false }
                return flow == .paginated ? visible.start == start : visible.start <= start && start < visible.end
            }
        }
        XCTAssertTrue(reader.notices.isEmpty, "\(reader.notices)")
    }

    /// doc/native-viewer.md (Decisions) and doc/architecture.md: what the reader does not render
    /// as authored reaches the host as one `.disclosure`: a fixed-layout spine item (here by a
    /// spine override, RS 5.5.1), vertical writing and scripts. Capabilities are not reduced.
    func testFixedLayoutVerticalWritingAndScriptsAreDisclosedToTheHost() async throws {
        var book = Book()
        book.add("plain", body: "<p>An ordinary reflowable section.</p>")
        book.add("page", head: "<meta name=\"viewport\" content=\"width=600, height=800\"/>",
                 itemref: "properties=\"rendition:layout-pre-paginated\"", body: "<p style=\"position: absolute; top: 100px; left: 50px\">A fixed page.</p>")
        book.add("vertical", head: "<style>body { writing-mode: vertical-rl; }</style>", root: "lang=\"ja\"", body: "<p>縦書きの段落です。</p>")
        book.add("scripted", item: "properties=\"scripted\"", body: "<p>Static text.</p><script>document.title = 'x';</script>")
        let reader = try mount(book)
        try await reader.waitUntilReady()
        try await reader.wait("the whole book's disclosure") {
            reader.disclosures.last.map { text in
                ["fixed page layout is shown as reflowable text", "Vertical text is shown horizontally", "One interactive part of this document was not run"]
                    .allSatisfy { text.contains($0) }
            } ?? false
        }
        let session = reader.session
        XCTAssertEqual(session.publication.spine.map(\.layout), [.reflowable, .prePaginated, .reflowable, .reflowable])
        XCTAssertTrue(session.capabilities.isSuperset(of: [.pagination, .scrolling, .bookmarks, .navigateHref]))
        XCTAssertEqual(try XCTUnwrap(session.book.section(1)).specText, "A fixed page.")
        let visited = try await reader.pageThrough()
        XCTAssertEqual(visited, [0, 1, 2, 3], "every section stays readable")
        XCTAssertFalse(reader.events.contains { if case .failed = $0 { return true }; return false })
        XCTAssertEqual(reader.events.filter { $0 == .ready }.count, 1)
    }
}
