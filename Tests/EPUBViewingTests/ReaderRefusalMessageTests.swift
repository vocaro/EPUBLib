import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// What a reader is told when the bundled reader refuses a request
/// (https://github.com/vocaro/EPUBLib/issues/698): a plain sentence, which the reader's controls
/// show as it is, while the error keeps the engine's detail for a developer.
@MainActor final class ReaderRefusalMessageTests: XCTestCase {
    private typealias Section = SessionCoverageBook.Section

    /// Each of the bundled reader's refusals: the detail its `invalidCommand` keeps, and the
    /// sentence a reader is shown for it.
    private static let refusals: [(detail: String, message: String)] = [
        ("Empty publication href", "That part of the book cannot be found."),
        ("Unknown publication href", "That part of the book cannot be found."),
        ("Not a section of this publication", "That part of the book cannot be shown."),
        ("The progression is not a finite number", "That place in the book cannot be found."),
        ("The passage to locate is empty or too long", "The passage to find is empty or longer than 4,096 characters."),
        ("The search text is empty or too long", "The search is empty or longer than 512 characters."),
        ("That search result is no longer available", "That search result is no longer available."),
        ("Nonfinite font size", "That text size cannot be used."),
        ("A typography setting is not a finite number", "That spacing or margin cannot be used."),
    ]

    private static func message(for detail: String) -> String? {
        refusals.first { $0.detail == detail }?.message
    }

    /// Each place the bundled reader refuses a request, reached as a host or the reader's own
    /// controls reach it: the error keeps its detail, and the controls show the sentence.
    func testEachRequestTheBundledReaderRefusesShowsItsPlainSentence() async throws {
        let reader = try SessionCoverageReader(SessionCoverageBook.epub([
            Section("one", "<h1>One</h1><p>Opening words with findword.</p>\(SessionCoverageBook.filler(20))"),
            Section("two", "<h1>Two</h1><p>Closing words with findword and otherword.</p>\(SessionCoverageBook.filler(20))"),
        ], manifest: "<item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>", files: ["OPS/style.css": "p { margin: 0 }"]))
        addTeardownBlock { @MainActor in reader.close() }
        try await reader.settle()
        let controls = EPUBReaderControls(publication: reader.publication, session: reader.session)
        XCTAssertTrue(controls.isReady)
        // The sentences name the limits.
        XCTAssertEqual(NativeSession.maximumQuoteLength, 4_096)
        XCTAssertEqual(NativeSession.maximumSearchLength, 512)

        // A result of a search that another has since replaced.
        try await reader.session.send(.search(text: "findword"))
        let stale = try XCTUnwrap(reader.state.status.searchResults?.results.first)
        try await reader.session.send(.search(text: "otherword"))
        XCTAssertEqual(reader.state.status.searchResults?.query, "otherword")

        var size = reader.session.style
        size.fontSize = .nan
        var spacing = reader.session.style
        spacing.typography.lineHeight = .infinity
        var margins = reader.session.style
        margins.typography.pageMargins = .nan
        let refused: [(label: String, command: EPUBReaderCommand, detail: String)] = [
            ("an empty href", .navigate(href: ""), "Empty publication href"),
            ("a fragment alone", .navigate(href: "#start"), "Empty publication href"),
            ("a file the book does not have", .navigate(href: "OPS/missing.xhtml"), "Unknown publication href"),
            ("a web address", .navigate(href: "https://example.invalid/OPS/two.xhtml"), "Unknown publication href"),
            ("a style sheet", .navigate(href: "OPS/style.css"), "Not a section of this publication"),
            ("a progression that is not a number", .goToProgression(.nan), "The progression is not a finite number"),
            ("an infinite progression", .goToProgression(-.infinity), "The progression is not a finite number"),
            ("an empty passage", .locate(text: " ", highlight: false), "The passage to locate is empty or too long"),
            ("a passage too long", .locate(text: String(repeating: "a", count: 4_097), highlight: true),
             "The passage to locate is empty or too long"),
            ("a replaced search's result", .showSearchResult(stale), "That search result is no longer available"),
            ("a text size that is not a number", .style(size), "Nonfinite font size"),
            ("an infinite line spacing", .style(spacing), "A typography setting is not a finite number"),
            ("margins that are not a number", .style(margins), "A typography setting is not a finite number"),
            ("a search of invisible characters", .search(text: "\u{200B}\u{2060}"), "The search text is empty or too long"),
            ("a search too long", .search(text: String(repeating: "a", count: 513)), "The search text is empty or too long"),
            ("a highlighting search too long", .searchHighlight(text: String(repeating: "a", count: 513)),
             "The search text is empty or too long"),
        ]
        XCTAssertEqual(Set(refused.map(\.detail)), Set(Self.refusals.map(\.detail)), "every refusal is made")
        for (label, command, detail) in refused {
            let message = try XCTUnwrap(Self.message(for: detail), label)
            do {
                try await reader.session.send(command)
                XCTFail("\(label): accepted")
            } catch {
                XCTAssertEqual(error as? EPUBReaderError, .invalidCommand(detail), label)
                XCTAssertEqual((error as? EPUBReaderError)?.message, message, label)
                XCTAssertTrue(String(describing: error).contains(detail), "\(label): the detail is kept for a developer: \(error)")
            }

            controls.send(command)
            await controls.waitForCommands()
            XCTAssertEqual(controls.commandError, message, label)
            switch command {
            case .search, .searchHighlight:
                // The search's own feedback states it, and the command error does not again.
                guard case .failed(_, let error) = controls.status?.search else { return XCTFail("\(label): no failed search") }
                XCTAssertEqual(error.message, message, label)
                XCTAssertEqual(controls.searchResultSummary, message, label)
                XCTAssertEqual(controls.searchResultAccessibilityValue, "Search failed. \(message)", label)
                XCTAssertNil(controls.commandErrorBesideSearchFeedback, label)
            default:
                XCTAssertEqual(controls.commandErrorBesideSearchFeedback, message, label)
            }
            controls.dismissError()
        }
    }

    /// The bundled reader's one `engineFailure`, a package it cannot read as it opens a book, and
    /// any other engine's refusal or failure give a reader `localizedDescription`: their detail is
    /// for a developer, who has it from `String(describing:)`.
    func testAnyOtherDetailGivesAReaderThePlainDescription() {
        let errors: [(EPUBReaderError, String)] = [
            (.engineFailure("The package document could not be read: invalidXML(\"OPS/book.opf\")"), "The reader cannot show this book."),
            (.engineFailure("Renderer lost"), "The reader cannot show this book."),
            // A detail of the bundled reader's names its refusal only as `invalidCommand`.
            (.engineFailure("Unknown publication href"), "The reader cannot show this book."),
            (.invalidCommand("Renderer refused"), "The reader cannot carry out this request."),
            (.invalidCommand(""), "The reader cannot carry out this request."),
            (.invalidCommand("unknown publication href"), "The reader cannot carry out this request."),
            (.unsupported(.search), "This reader does not support this action."),
            (.incompatibleLocation, "This saved position belongs to a different book or reader."),
            (.notReady, "The reader is not ready."),
            (.closed, "This book is closed."),
        ]
        for (error, message) in errors {
            XCTAssertEqual(error.message, message, "\(error)")
            XCTAssertEqual(error.message, error.localizedDescription, "\(error)")
            if case .invalidCommand(let detail) = error, !detail.isEmpty {
                XCTAssertTrue(String(describing: error).contains(detail))
            }
            if case .engineFailure(let detail) = error {
                XCTAssertTrue(String(describing: error).contains(detail.debugDescription.dropFirst().dropLast()))
            }
        }
    }

    /// Each sentence is short and plain: a sentence of the library's own, with none of the words
    /// of the detail it stands for.
    func testEachSentenceIsPlain() {
        for (detail, message) in Self.refusals {
            XCTAssertTrue(message.hasSuffix("."), message)
            XCTAssertNotEqual(message, detail)
            XCTAssertLessThanOrEqual(message.split(separator: " ").count, 12, message)
            for word in ["href", "publication", "finite", "typography", "progression", "locate", "section", "spine",
                         "invalid", "command", "nil", "CFI"] {
                XCTAssertFalse(message.localizedCaseInsensitiveContains(word), "\(word) in \(message)")
            }
        }
    }

    /// Each sentence the controls show, and each notice of the bundled reader's own
    /// (`ReaderNoticeMessageTests`), is in EPUBViewing's string catalog, with a comment for its
    /// translator, and the catalog holds no other: a sentence missing from it could not be
    /// translated (#684).
    func testEverySentenceTheControlsShowIsInTheViewingStringCatalog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Sources/EPUBViewing/Localizable.xcstrings"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["sourceLanguage"] as? String, "en")
        let catalog = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        XCTAssertEqual(Set(catalog.keys), Set(Self.refusals.map(\.message) + ["Search failed. %@"] + ReaderNoticeMessageTests.sentences))
        for (key, entry) in catalog {
            XCTAssertFalse((entry["comment"] as? String ?? "").isEmpty, key)
        }
    }

    /// Every reason the bundled reader gives for a refusal is one the tests above make and check,
    /// and each is known by its case and detail alone.
    func testEveryReasonTheBundledReaderGivesIsChecked() {
        XCTAssertEqual(NativeRefusal.allCases.map(\.rawValue), Self.refusals.map(\.detail))
        for reason in NativeRefusal.allCases {
            XCTAssertEqual(reason.message, Self.message(for: reason.rawValue), reason.rawValue)
            XCTAssertEqual(reason.error.message, reason.message, reason.rawValue)
            XCTAssertEqual(NativeRefusal(reason.error), reason)
            XCTAssertNil(NativeRefusal(.engineFailure(reason.rawValue)), reason.rawValue)
        }
    }
}
