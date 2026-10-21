#if os(macOS)
import EPUBCore
import EPUBWriting
import Foundation
import UniformTypeIdentifiers
import XCTest

/// Writes a matrix of publications with EPUBWriting and has the real EPUBCheck validate each.
/// Skipped unless `EPUBLIB_EPUBCHECK_CLI` names the `epubcheck` executable. Every test requires
/// a report with no fatal error, error or warning, and names each message otherwise.
/// `EPUBLIB_EPUBCHECK_REPORT` names a directory that keeps each book and its JSON report.
final class EPUBCheckWriterValidationTests: XCTestCase {
    struct Message: Equatable, CustomStringConvertible {
        let id: String
        let severity: String
        let text: String
        let location: String
        var description: String { "\(id) \(severity) \(location): \(text)" }
    }

    private var cli: String!
    private var directory: URL!
    private var keeps = false

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["EPUBLIB_EPUBCHECK_CLI"], !path.isEmpty else {
            throw XCTSkip("Set EPUBLIB_EPUBCHECK_CLI to the epubcheck executable")
        }
        cli = path
        if let report = environment["EPUBLIB_EPUBCHECK_REPORT"] {
            let name = self.name.split(separator: " ").last.map { String($0.dropLast()) } ?? UUID().uuidString
            directory = URL(fileURLWithPath: report).appendingPathComponent("writer").appendingPathComponent(name)
            try? FileManager.default.removeItem(at: directory)
            keeps = true
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("epubcheck-writer-" + UUID().uuidString)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if !keeps, let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Writes `book`, runs `epubcheck --json` on it and returns every message it reports.
    private func messages(_ book: EPUBCheckWrittenBook) async throws -> [Message] {
        let epub = try await book.write(in: directory)
        let json = directory.appendingPathComponent("report.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["--json", json.path, epub.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any], "EPUBCheck wrote no report")
        return (report["messages"] as? [[String: Any]] ?? []).map { message in
            let location = (message["locations"] as? [[String: Any]])?.first.map {
                "\($0["path"] as? String ?? "")(\($0["line"] as? Int ?? -1),\($0["column"] as? Int ?? -1))"
            } ?? ""
            return Message(id: message["ID"] as? String ?? "", severity: message["severity"] as? String ?? "",
                           text: message["message"] as? String ?? "", location: location)
        }
    }

    /// EPUBCheck must report nothing at warning level or above, other than the ids in `inherent`
    /// (whose text contains `saying`, when given): what the test's own choice of input earns
    /// whatever the writer does.
    private func assertValid(_ book: EPUBCheckWrittenBook, inherent: Set<String> = [], saying: String = "",
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let all = try await messages(book)
        func isInherent(_ message: Message) -> Bool { inherent.contains(message.id) && (saying.isEmpty || message.text.contains(saying)) }
        let severe = all.filter { ["FATAL", "ERROR", "WARNING"].contains($0.severity) && !isInherent($0) }
        XCTAssertTrue(severe.isEmpty, "EPUBCheck reports \(severe.count): " + severe.map(\.description).joined(separator: " | "), file: file, line: line)
        if !inherent.isEmpty { XCTAssertTrue(all.contains(where: isInherent), "expected \(inherent.sorted()) for this input", file: file, line: line) }
        print("EPUBCheck writer validation, \(name): \(all.isEmpty ? "no messages" : all.map(\.description).joined(separator: " | "))")
    }

    // MARK: Structure

    func testAMinimalBookWithoutPages() async throws {
        try await assertValid(.minimal)
    }

    func testAMinimalBookWithPages() async throws {
        var book = EPUBCheckWrittenBook.minimal
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml#start")]
        try await assertValid(book)
    }

    func testNestedContents() async throws {
        var book = EPUBCheckWrittenBook()
        for index in 1...4 { book.addChapter(id: "c\(index)", path: "EPUB/text/c\(index).xhtml", title: "Chapter \(index)", listed: false) }
        book.contents = [
            .init(title: "Part One", children: [
                .init(title: "Chapter 1", href: "EPUB/text/c1.xhtml", children: [
                    .init(title: "Opening", href: "EPUB/text/c1.xhtml#start", children: [.init(title: "Deepest", href: "EPUB/text/c1.xhtml#start")]),
                ]),
                .init(title: "Chapter 2", href: "EPUB/text/c2.xhtml"),
            ]),
            .init(title: "Part Two", href: "EPUB/text/c3.xhtml", children: [.init(title: "Chapter 4", href: "EPUB/text/c4.xhtml")]),
        ]
        book.pages = [.init(title: "1", href: "EPUB/text/c1.xhtml#start")]
        try await assertValid(book)
    }

    func testAPageListAcrossChapters() async throws {
        var book = EPUBCheckWrittenBook()
        for index in 1...2 {
            let breaks = (1...3).map { "<p>Text.<span epub:type=\"pagebreak\" role=\"doc-pagebreak\" id=\"p\($0)\" aria-label=\"\($0)\"/></p>" }.joined()
            book.addChapter(id: "c\(index)", path: "EPUB/c\(index).xhtml", title: "Chapter \(index)", body: "<h1>Chapter \(index)</h1>" + breaks)
        }
        book.pages = (1...2).flatMap { chapter in
            (1...3).map { EPUBNavigationItem(title: chapter == 1 ? ["i", "ii", "iii"][$0 - 1] : "\($0)", href: "EPUB/c\(chapter).xhtml#p\($0)") }
        }
        try await assertValid(book)
    }

    func testACoverImage() async throws {
        var book = EPUBCheckWrittenBook()
        book.add(id: "cover-image", path: "EPUB/images/cover.png", mediaType: "image/png", data: try EPUBCheckWrittenBook.image(.png),
                 properties: ["cover-image"])
        book.addChapter(id: "cover", path: "EPUB/cover.xhtml", title: "Cover", body: "<p><img src=\"images/cover.png\" alt=\"The cover\"/></p>")
        book.addChapter(id: "chapter", path: "EPUB/chapter.xhtml", title: "Chapter")
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml")]
        try await assertValid(book)
    }

    func testNonlinearSpineItems() async throws {
        var book = EPUBCheckWrittenBook()
        book.addChapter(id: "chapter", path: "EPUB/chapter.xhtml", title: "Chapter",
                        body: "<h1>Chapter</h1><p>See <a href=\"aside.xhtml\">the aside</a> and <a href=\"answers.xhtml\">the answers</a>.</p>")
        book.addChapter(id: "aside", path: "EPUB/aside.xhtml", title: "Aside", linear: false)
        book.addChapter(id: "answers", path: "EPUB/answers.xhtml", title: "Answers", linear: false, listed: false)
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml")]
        try await assertValid(book)
    }

    func testAFixedLayoutSpineOverride() async throws {
        var book = EPUBCheckWrittenBook.minimal
        let plate = EPUBResource(id: "plate", path: "EPUB/plate.xhtml", mediaType: "application/xhtml+xml")
        book.files.append((plate, EPUBCheckWrittenBook.page(title: "Plate", body: "<p>A plate.</p>",
                                                           head: "<meta name=\"viewport\" content=\"width=600, height=800\"/>")))
        book.spine.append(.init(resource: plate, layout: .prePaginated))
        book.contents.append(.init(title: "Plate", href: "EPUB/plate.xhtml"))
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml")]
        try await assertValid(book)
    }

    func testASpineNamingOneResourceTwiceEarnsOnlyTheItemrefError() async throws {
        var book = EPUBCheckWrittenBook.minimal
        book.spine.append(book.spine[0])
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml")]
        // The spine is the caller's, and the writer writes it as given.
        try await assertValid(book, inherent: ["RSC-005"], saying: "same manifest entry")
    }

    func testASpineWithNoLinearItemEarnsOnlyTheSpineError() async throws {
        var book = EPUBCheckWrittenBook()
        book.addChapter(id: "chapter", path: "EPUB/chapter.xhtml", title: "Chapter", linear: false)
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml")]
        // OPF-033: the spine is the caller's, and the writer writes it as given.
        try await assertValid(book, inherent: ["OPF-033"])
    }

    func testARightToLeftBook() async throws {
        var book = EPUBCheckWrittenBook()
        book.metadata.metadata = .init(title: "كتاب الاختبار", authors: ["مؤلف الاختبار", "מחבר הבדיקה"], languages: ["ar"])
        book.metadata.rightToLeft = true
        book.addChapter(id: "c1", path: "EPUB/c1.xhtml", title: "الفصل الأول", body: "<h1 dir=\"rtl\">الفصل الأول</h1><p dir=\"rtl\">نص عربي أصلي للاختبار.</p>")
        book.pages = [.init(title: "١", href: "EPUB/c1.xhtml")]
        try await assertValid(book)
    }

    // MARK: Metadata

    func testSeveralAuthorsLanguagesAndIdentifiers() async throws {
        var book = EPUBCheckWrittenBook.minimal
        book.metadata.metadata = .init(title: "A Book by Many", authors: ["First Author", "Second Author", "Third Author"],
                                       languages: ["en", "fr", "ja"], identifiers: ["urn:isbn:9780000000002", "urn:uuid:11111111-2222-3333-4444-555555555555"])
        book.metadata.summary = "A summary of the book."
        book.metadata.keywords = ["testing", "fixtures", "ebooks"]
        book.metadata.created = Date(timeIntervalSince1970: 1_700_000_000)
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml")]
        try await assertValid(book)
    }

    func testMarkupCharactersInEveryTextField() async throws {
        let text = #"Fish & Chips <b> "quoted" 'single' ]]> &amp; &#38; <!-- --> <?pi?>"#
        var book = EPUBCheckWrittenBook()
        book.metadata.metadata = .init(title: text, authors: [text, "O'Brien & Sons"], languages: ["en"])
        book.metadata.identifier = "urn:test:" + text
        book.metadata.summary = text
        book.metadata.keywords = [text, "<tag>"]
        book.addChapter(id: "c1", path: "EPUB/c1.xhtml", title: "Chapter", listed: false)
        book.contents = [.init(title: text, href: "EPUB/c1.xhtml", children: [.init(title: "a < b > c & d", href: "EPUB/c1.xhtml#start")])]
        book.pages = [.init(title: "<1> & \"2\"", href: "EPUB/c1.xhtml#start")]
        try await assertValid(book)
    }

    func testNonASCIIAndBidirectionalText() async throws {
        let text = "Ünïcödé — 日本語 한국어 עברית العربية 🙂 e\u{301} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        var book = EPUBCheckWrittenBook()
        book.metadata.metadata = .init(title: text, authors: [text], languages: ["mul"])
        book.metadata.summary = text
        book.metadata.keywords = [text]
        book.addChapter(id: "c1", path: "EPUB/c1.xhtml", title: text, listed: false)
        book.contents = [.init(title: text, href: "EPUB/c1.xhtml")]
        book.pages = [.init(title: "٣", href: "EPUB/c1.xhtml"), .init(title: "三", href: "EPUB/c1.xhtml#start")]
        try await assertValid(book)
    }

    func testControlCharactersInTextFieldsAreNotWritten() async throws {
        var book = EPUBCheckWrittenBook.minimal
        book.metadata.metadata = .init(title: "A\u{0}B\u{8}C\u{B}D\u{1F}E\u{FFFE}F", authors: ["An\u{1}Author"], languages: ["en"])
        book.contents = [.init(title: "Chap\u{C}ter", href: "EPUB/chapter.xhtml")]
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml")]
        try await assertValid(book)
    }

    // MARK: Resource paths

    func testResourcePathsInSubdirectoriesWithNonASCIINames() async throws {
        var book = EPUBCheckWrittenBook()
        book.add(id: "style", path: "EPUB/styles/książka.css", mediaType: "text/css", data: Data("p { margin: 0; }".utf8))
        book.addChapter(id: "c1", path: "EPUB/text/première/chapitre-é.xhtml", title: "Chapitre",
                        head: "<link rel=\"stylesheet\" type=\"text/css\" href=\"../../styles/ksi%C4%85%C5%BCka.css\"/>")
        book.addChapter(id: "c2", path: "EPUB/text/第二章.xhtml", title: "第二章")
        book.stylesheet = "EPUB/styles/ksi%C4%85%C5%BCka.css"
        book.pages = [.init(title: "1", href: book.files[1].resource.href)]
        try await assertValid(book)
    }

    func testResourcePathsWithHashAndPercentSigns() async throws {
        var book = EPUBCheckWrittenBook()
        book.addChapter(id: "c1", path: "EPUB/chapter-#1.xhtml", title: "Number one")
        book.addChapter(id: "c2", path: "EPUB/100%-pure.xhtml", title: "Pure")
        book.pages = [.init(title: "1", href: book.files[0].resource.href + "#start")]
        try await assertValid(book)
    }

    func testResourcePathsWithSpacesEarnOnlyTheFilenameWarning() async throws {
        var book = EPUBCheckWrittenBook()
        book.addChapter(id: "c1", path: "EPUB/text files/chapter one.xhtml", title: "Chapter one")
        book.pages = [.init(title: "1", href: book.files[0].resource.href + "#start")]
        // PKG-010 is EPUBCheck's warning for a space in a file name, whoever writes the archive.
        try await assertValid(book, inherent: ["PKG-010"])
    }

    func testAResourcePathWithAQuestionMarkEarnsOnlyTheFilenameError() async throws {
        var book = EPUBCheckWrittenBook()
        book.addChapter(id: "c1", path: "EPUB/what?.xhtml", title: "What?")
        book.pages = [.init(title: "1", href: book.files[0].resource.href + "#start")]
        // PKG-009 is EPUBCheck's error for a character OCF forbids in a file name.
        try await assertValid(book, inherent: ["PKG-009"])
    }

    // MARK: Media types

    func testSeveralMediaTypes() async throws {
        var book = EPUBCheckWrittenBook()
        book.add(id: "css", path: "EPUB/styles/book.css", mediaType: "text/css", data: Data("""
            @font-face { font-family: "Test Sans"; src: url(../fonts/test.woff2) format("woff2"), url(../fonts/test.woff) format("woff"); }
            @font-face { font-family: "Test Serif"; src: url(../fonts/test.ttf); }
            @font-face { font-family: "Test Mono"; src: url(../fonts/test.otf); }
            body { font-family: "Test Sans", sans-serif; }
            """.utf8))
        for (kind, type) in [("woff2", "font/woff2"), ("woff", "font/woff"), ("ttf", "font/ttf"), ("otf", "font/otf")] {
            book.add(id: "font-\(kind)", path: "EPUB/fonts/test.\(kind)", mediaType: type, data: Data(repeating: 0x20, count: 64))
        }
        book.add(id: "png", path: "EPUB/images/one.png", mediaType: "image/png", data: try EPUBCheckWrittenBook.image(.png))
        book.add(id: "jpeg", path: "EPUB/images/two.jpg", mediaType: "image/jpeg", data: try EPUBCheckWrittenBook.image(.jpeg))
        book.add(id: "gif", path: "EPUB/images/three.gif", mediaType: "image/gif", data: try EPUBCheckWrittenBook.image(.gif))
        book.add(id: "svg", path: "EPUB/images/four.svg", mediaType: "image/svg+xml", data: EPUBCheckWrittenBook.svg)
        book.addChapter(id: "c1", path: "EPUB/text/c1.xhtml", title: "Pictures", body: """
            <h1>Pictures</h1><p><img src="../images/one.png" alt="One"/><img src="../images/two.jpg" alt="Two"/>\
            <img src="../images/three.gif" alt="Three"/><img src="../images/four.svg" alt="Four"/></p>
            """, head: "<link rel=\"stylesheet\" type=\"text/css\" href=\"../styles/book.css\"/>")
        book.stylesheet = "EPUB/styles/book.css"
        book.pages = [.init(title: "1", href: "EPUB/text/c1.xhtml")]
        try await assertValid(book)
    }

    func testALargeResource() async throws {
        var book = EPUBCheckWrittenBook()
        // About 12 MB that deflate cannot shrink, and 8 MB that it shrinks to almost nothing.
        book.add(id: "big", path: "EPUB/images/big.png", mediaType: "image/png", data: try EPUBCheckWrittenBook.image(.png, side: 2_000, noise: true))
        book.add(id: "css", path: "EPUB/big.css", mediaType: "text/css",
                 data: Data(String(repeating: "/* padding padding padding padding padding padding padding padding */\n", count: 120_000).utf8))
        book.addChapter(id: "c1", path: "EPUB/c1.xhtml", title: "Big", body: "<h1>Big</h1><p><img src=\"images/big.png\" alt=\"Noise\"/></p>",
                        head: "<link rel=\"stylesheet\" type=\"text/css\" href=\"big.css\"/>")
        book.pages = [.init(title: "1", href: "EPUB/c1.xhtml")]
        XCTAssertGreaterThan(book.files.reduce(0) { $0 + $1.data.count }, 16 << 20)
        try await assertValid(book)
    }

    // MARK: Empty and near-empty fields

    // The writer refuses an empty title, identifier, contents or navigation label, a contents
    // entry with neither a target nor entries, and a resource ID that is no XML name
    // (https://github.com/vocaro/EPUBLib/issues/96). Such a book is never written, so there is
    // nothing here for EPUBCheck to validate: EPUBCheckWriterOutputCoverageTests holds each
    // refusal. What the writer leaves out instead is validated below.

    func testNoAuthorsLanguagesSummaryOrKeywords() async throws {
        var book = EPUBCheckWrittenBook.minimal
        book.metadata.metadata = .init(title: "Only a Title")
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml")]
        try await assertValid(book)
    }

    func testAnEmptyAuthor() async throws {
        var book = EPUBCheckWrittenBook.minimal
        book.metadata.metadata = .init(title: "A Written Book", authors: ["", "  "], languages: ["en"])
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml")]
        try await assertValid(book)
    }

    func testAnEmptyLanguage() async throws {
        var book = EPUBCheckWrittenBook.minimal
        book.metadata.metadata = .init(title: "A Written Book", authors: ["Test Author"], languages: [""])
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml")]
        try await assertValid(book)
    }

    func testAnEmptyAdditionalIdentifier() async throws {
        var book = EPUBCheckWrittenBook.minimal
        book.metadata.metadata = .init(title: "A Written Book", authors: ["Test Author"], languages: ["en"], identifiers: ["", "urn:isbn:9780000000002", " "])
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml")]
        try await assertValid(book)
    }

    func testAnEmptySummaryAndKeyword() async throws {
        var book = EPUBCheckWrittenBook.minimal
        book.metadata.summary = ""
        book.metadata.keywords = ["", " "]
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml")]
        try await assertValid(book)
    }

    // MARK: Resource identifiers

    func testResourceIdentifiersAtTheEdgesOfAnXMLName() async throws {
        var book = EPUBCheckWrittenBook()
        for (index, id) in EPUBCheckWrittenBook.xmlNamesAtTheEdges.enumerated() {
            book.addChapter(id: id, path: "EPUB/c\(index).xhtml", title: "Chapter \(index)")
        }
        book.pages = [.init(title: "1", href: "EPUB/c0.xhtml")]
        try await assertValid(book)
    }
}
#endif
