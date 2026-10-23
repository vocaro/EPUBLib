import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBText
import Foundation
import XCTest

/// Every failure the library throws or emits has a plain message, which a host shows as it is
/// (https://github.com/vocaro/EPUBLib/issues/698). A host reads it as any error's: through
/// `localizedDescription` and, as `NSError` has it, `localizedRecoverySuggestion`.
final class ErrorMessageTests: XCTestCase {
    private typealias Message = (description: String, suggestion: String?)
    private static let anotherCopy = "Download the book again, or get another copy."

    // MARK: Opening a book

    /// The message for each case of `EPUBPublicationError`, and the case's name. The switch has no
    /// default: a case added to the enum does not compile here until its message is written down.
    private static func expected(_ error: EPUBPublicationError) -> (name: String, message: Message) {
        switch error {
        case .unsupportedEncryption:
            ("unsupportedEncryption", ("This book is protected by DRM and cannot be opened. The file is not damaged.",
                                       "Open it in the app it came from, or get a copy without DRM."))
        case .notEPUB: ("notEPUB", ("This file is not an EPUB book.", nil))
        case .notArchive:
            ("notArchive", ("This file is not an EPUB book, or it is damaged.",
                            "If it is an EPUB book, download it again or get another copy."))
        case .invalidArchive: ("invalidArchive", ("This book is damaged and cannot be opened.", anotherCopy))
        case .unsafePath: ("unsafePath", ("This book cannot be opened because it refers to files outside the book.", nil))
        case .limitExceeded: ("limitExceeded", ("This book is too large to open.", nil))
        case .missingResource: ("missingResource", ("Part of this book is missing.", anotherCopy))
        case .invalidXML: ("invalidXML", ("This book cannot be opened because it contains errors.", anotherCopy))
        }
    }

    /// Each case, with the details the library gives it.
    private static let publicationErrors: [EPUBPublicationError] = [
        .unsupportedEncryption, .notEPUB, .notArchive,
        .invalidArchive("CRC: OPS/one.xhtml"), .invalidArchive("OPS/one.xhtml: corruptedData"),
        .invalidArchive("Duplicate path: OPS/one.xhtml"), .invalidArchive("Entry data past the end of the archive"),
        .invalidArchive("Central directory past the end of the archive"), .invalidArchive("Entry name not UTF-8: OPS/\\xff.xhtml"),
        .unsafePath("../one.xhtml"), .unsafePath("https://example.com/one.xhtml"),
        .limitExceeded("archiveBytes"), .limitExceeded("import limits"), .limitExceeded("entry count"),
        .limitExceeded("archive input work"), .limitExceeded("OPS/one.xhtml"),
        .missingResource("OPS/two.xhtml"),
        .invalidXML("container rootfile"), .invalidXML("OPF package, manifest or spine"), .invalidXML("Empty spine"),
        .invalidXML("OPS/book.opf"),
    ]

    func testEachCaseOfAFailureToOpenABookHasAPlainMessage() throws {
        XCTAssertEqual(Set(Self.publicationErrors.map { Self.expected($0).name }),
                       ["unsupportedEncryption", "notEPUB", "notArchive", "invalidArchive", "unsafePath", "limitExceeded",
                        "missingResource", "invalidXML"])
        for error in Self.publicationErrors {
            assertMessage(error, Self.expected(error).message)
        }
    }

    func testOpeningABookGivesThePlainMessageForWhyItCannotBeOpened() throws {
        let files = try Fixture.files()
        // Encrypted as Adobe's DRM encrypts a book's chapters.
        let drm = try Fixture.epub(overrides: [
            "META-INF/encryption.xml": """
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">\
            <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>\
            <enc:CipherData><enc:CipherReference URI="OPS/one.xhtml"/></enc:CipherData></enc:EncryptedData></encryption>
            """,
            "META-INF/rights.xml": "<adept:rights xmlns:adept=\"http://ns.adobe.com/adept\"/>",
        ])
        // A ZIP archive that is another kind of document.
        let document = try Fixture.archive(["[Content_Types].xml": "<Types/>", "word/document.xml": "<document/>"])
        // A chapter's stored bytes changed after its checksum was written.
        var damaged = Fixture.storedArchive(Fixture.storedEntries(files))
        let words = try XCTUnwrap(damaged.range(of: Data("Opening words are visible.".utf8)))
        damaged.replaceSubrange(words, with: Data("Opening words are visibly!".utf8))
        var missing = files
        missing["OPS/two.xhtml"] = nil
        var noRootfile = files
        noRootfile["META-INF/container.xml"] = Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"/>".utf8)
        var small = EPUBImportLimits()
        small.archiveBytes = 1_000
        let book = try Fixture.epub()
        let pdf = Data("%PDF-1.7\n%âãÏÓ\n1 0 obj\n<< /Type /Catalog >>\nendobj\n".utf8)
        let outside = Fixture.storedArchive(Fixture.storedEntries(files) + [Fixture.StoredEntry("../outside.xhtml", "<p/>")])
        let cases: [(String, Data, EPUBImportLimits, EPUBPublicationError)] = [
            ("DRM", drm, .init(), .unsupportedEncryption),
            ("another kind of ZIP archive", document, .init(), .notEPUB),
            ("a PDF", pdf, .init(), .notArchive),
            ("a book cut short", book.prefix(book.count / 2), .init(), .notArchive),
            ("a damaged chapter", damaged, .init(), .invalidArchive("CRC: OPS/one.xhtml")),
            ("an entry outside the book", outside, .init(), .unsafePath("../outside.xhtml")),
            ("over the limits", book, small, .limitExceeded("import limits")),
            ("a chapter missing", try Fixture.archive(missing), .init(), .missingResource("OPS/two.xhtml")),
            ("no package named", try Fixture.archive(noRootfile), .init(), .invalidXML("container rootfile")),
        ]
        for (name, data, limits, thrown) in cases {
            XCTAssertThrowsError(try EPUBPublication.open(data: data, limits: limits), name) {
                XCTAssertEqual($0 as? EPUBPublicationError, thrown, name)
                assertMessage($0, Self.expected(thrown).message, name)
            }
        }
        XCTAssertEqual(Set(cases.map { Self.expected($0.3).name }).count, 8, "every case")
    }

    func testAFileOpenedByURLGivesThePlainMessage() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ErrorMessageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Longer than an end record reaches, so it is refused by its ends, unread between them.
        let pdf = folder.appending(path: "notes.epub")
        try (Data("%PDF-1.7\n".utf8) + Data(count: 70_000)).write(to: pdf)
        XCTAssertThrowsError(try EPUBPublication.open(at: pdf)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .notArchive)
            assertMessage($0, ("This file is not an EPUB book, or it is damaged.",
                               "If it is an EPUB book, download it again or get another copy."))
        }
        // A file that cannot be read gives Foundation's own message, which is plain already.
        XCTAssertThrowsError(try EPUBPublication.open(at: folder.appending(path: "absent.epub"))) {
            XCTAssertNil($0 as? EPUBPublicationError)
            XCTAssertFalse($0.localizedDescription.isEmpty)
        }
    }

    // MARK: Reading a book

    private static func expected(_ error: EPUBReaderError) -> (name: String, message: Message) {
        switch error {
        case .unsupported: ("unsupported", ("This reader does not support this action.", nil))
        case .incompatibleLocation: ("incompatibleLocation", ("This saved position belongs to a different book or reader.", nil))
        case .invalidCommand: ("invalidCommand", ("The reader cannot carry out this request.", nil))
        case .notReady: ("notReady", ("The reader is not ready.", "Try again in a moment."))
        case .closed: ("closed", ("This book is closed.", nil))
        case .engineFailure: ("engineFailure", ("The reader cannot show this book.", nil))
        }
    }

    private static let readerErrors: [EPUBReaderError] = [
        .unsupported(.search), .unsupported(.bookmarks), .unsupported(.searchResults), .incompatibleLocation,
        .invalidCommand("Unknown publication href"), .invalidCommand("Nonfinite font size"),
        .invalidCommand("The search text is empty or too long"), .notReady, .closed,
        .engineFailure("The package document could not be read: invalidXML(\"OPS/book.opf\")"),
    ]

    func testEachCaseOfAReaderFailureHasAPlainMessage() {
        XCTAssertEqual(Set(Self.readerErrors.map { Self.expected($0).name }),
                       ["unsupported", "incompatibleLocation", "invalidCommand", "notReady", "closed", "engineFailure"])
        for error in Self.readerErrors {
            assertMessage(error, Self.expected(error).message)
            // What the reader's controls show beside a search or a command.
            switch error {
            case .invalidCommand(let detail), .engineFailure(let detail): XCTAssertEqual(error.message, detail)
            case .unsupported, .incompatibleLocation, .notReady, .closed: XCTAssertEqual(error.message, error.localizedDescription)
            }
        }
    }

    // MARK: Text extraction

    private static func expected(_ error: EPUBTextExtractionError) -> (name: String, message: Message) {
        switch error {
        case .invalidSpineIndex: ("invalidSpineIndex", ("This part of the book does not exist.", nil))
        case .unsupportedMediaType:
            ("unsupportedMediaType", ("The text in this part of the book is in a format that cannot be read.", nil))
        case .malformedContent:
            ("malformedContent", ("The text in this part of the book cannot be read because it contains errors.", nil))
        case .limitExceeded: ("limitExceeded", ("This part of the book is too large to read as text.", nil))
        }
    }

    func testEachCaseOfAFailureToReadTextHasAPlainMessage() throws {
        let book = try EPUBPublication.open(data: Fixture.epub(overrides: [
            "OPS/two.xhtml": "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Unclosed</body></html>",
        ]))
        var tiny = EPUBTextExtractionLimits()
        tiny.inputBytes = 10
        var names = Set<String>()
        for (index, limits) in [(9, EPUBTextExtractionLimits()), (1, .init()), (0, tiny)] {
            XCTAssertThrowsError(try book.textSection(at: index, limits: limits), "\(index)") {
                guard let error = $0 as? EPUBTextExtractionError else { return XCTFail("\(index): \($0)") }
                names.insert(Self.expected(error).name)
                assertMessage(error, Self.expected(error).message, "\(index)")
            }
        }
        XCTAssertEqual(names, ["invalidSpineIndex", "malformedContent", "limitExceeded"])
        // A section in another format, which these books do not hold.
        let format = EPUBTextExtractionError.unsupportedMediaType("image/svg+xml")
        assertMessage(format, Self.expected(format).message)
    }

    // MARK: String catalogs

    /// Each message is in its module's string catalog, with a comment for its translator, and the
    /// catalog holds no other: a message missing from it could not be translated (#684).
    func testEveryMessageIsInItsModulesStringCatalog() throws {
        let core = Self.publicationErrors.map { Self.expected($0).message } + Self.readerErrors.map { Self.expected($0).message }
        let text = [EPUBTextExtractionError.invalidSpineIndex(0), .unsupportedMediaType(""), .malformedContent(""), .limitExceeded("")]
            .map { Self.expected($0).message }
        for (module, messages) in [("EPUBCore", core), ("EPUBText", text)] {
            let catalog = try Self.catalog(module)
            let strings = Set(messages.flatMap { [$0.description, $0.suggestion].compactMap { $0 } })
            XCTAssertEqual(Set(catalog.keys), strings, module)
            for (key, entry) in catalog {
                XCTAssertFalse((entry["comment"] as? String ?? "").isEmpty, "\(module): \(key)")
            }
        }
    }

    static func catalog(_ module: String, file: String = #filePath) throws -> [String: [String: Any]] {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Sources/\(module)/Localizable.xcstrings"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["sourceLanguage"] as? String, "en")
        return try XCTUnwrap(json["strings"] as? [String: [String: Any]])
    }

    // MARK: Helpers

    /// The error's message is the one expected, as a host reads it, and plain: a sentence of the
    /// library's own, with none of the error's detail, which `String(describing:)` keeps.
    private func assertMessage(_ error: Error, _ expected: Message, _ context: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        let context = "\(context) \(String(describing: error))"
        XCTAssertEqual(error.localizedDescription, expected.description, context, file: file, line: line)
        XCTAssertEqual((error as NSError).localizedRecoverySuggestion, expected.suggestion, context, file: file, line: line)
        XCTAssertEqual((error as? LocalizedError)?.errorDescription, expected.description, context, file: file, line: line)
        for message in [expected.description, expected.suggestion].compactMap({ $0 }) {
            XCTAssertTrue(message.hasSuffix("."), "a sentence: \(message)", file: file, line: line)
            for word in ["archive", "mimetype", "XML", "href", "spine", "manifest", "CRC", "ZIP", "nil"] {
                XCTAssertFalse(message.localizedCaseInsensitiveContains(word), "\(word) in \(message)", file: file, line: line)
            }
        }
        let mirror = Mirror(reflecting: error)
        for detail in mirror.children.compactMap({ $0.value as? String }) where !detail.isEmpty {
            XCTAssertFalse(expected.description.contains(detail), "detail in \(context)", file: file, line: line)
            XCTAssertTrue(String(describing: error).contains(detail.debugDescription.dropFirst().dropLast()),
                          "the detail is kept for a developer: \(context)", file: file, line: line)
        }
    }
}
