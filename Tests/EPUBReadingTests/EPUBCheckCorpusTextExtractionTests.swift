import EPUBCore
import EPUBReading
import EPUBText
import EPUBTestSupport
import Foundation
import XCTest

/// The text-extraction half of the EPUBCheck corpus run (`EPUBCheckCorpusTests` in the viewer
/// tests is the other; the viewer's test target does not link EPUBText). Extracts every spine
/// item of every whole publication and every lone XHTML document of EPUBCheck's test corpus,
/// strictly and then with recovery. A fixture EPUBCheck calls valid must extract strictly; no
/// fixture may hang or fail with an untyped error.
///
/// Skipped unless `EPUBLIB_EPUBCHECK_FIXTURES` names `src/test/resources` of a w3c/epubcheck
/// checkout. Outcomes go to `EPUBLIB_EPUBCHECK_REPORT` (default `.build/epubcheck-corpus`) as
/// `text-publications.json` and `text-documents.json`; `text-progress.log` ends with the
/// fixture being examined. The corpus is data: nothing in it is executed.
final class EPUBCheckCorpusTextExtractionTests: XCTestCase {
    struct Outcome: Codable, Sendable {
        var fixture: String
        var verdict: EPUBCheckCorpus.Verdict
        var seconds = 0.0
        var hung = false
        var openError: String?
        var sections = 0
        var bytes = 0
        /// Strict failures by spine path. `unsupportedMediaType` is the documented answer for a
        /// spine item that is not XHTML and is kept apart in `foreign`.
        var failures: [String: String] = [:]
        /// Sections with an entity declaration or internal DTD subset, which always fail.
        var refusedAsDocumented: [String] = []
        var foreign: [String] = []
        /// Errors that are neither `EPUBTextExtractionError` nor `EPUBPublicationError`.
        var untyped: [String: String] = [:]
        /// Sections strict extraction refuses that recovery reads.
        var recovered: [String] = []
        /// Anchors or headings whose marks do not fall on a character boundary inside the text.
        var badMarks = 0
        /// The extracted text by spine path, for comparison with what the viewer builds.
        var text: [String: String] = [:]
    }

    private static let watchdog = 120.0, slow = 5.0
    private var corpus: URL!
    private var reportDirectory: URL!

    override func setUpWithError() throws {
        guard let root = EPUBCheckCorpus.root() else {
            throw XCTSkip("Set \(EPUBCheckCorpus.environmentKey) to src/test/resources of an EPUBCheck checkout")
        }
        corpus = root
        reportDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EPUBLIB_EPUBCHECK_REPORT"] ?? ".build/epubcheck-corpus")
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
    }

    func testEverySpineItemOfEveryWholePublicationExtracts() throws {
        let items = EPUBCheckCorpus.publications(under: corpus)
        XCTAssertGreaterThan(items.count, 400, "publications found under \(corpus.path)")
        assertPolicy(examine(items, as: "text-publications") { try EPUBCheckCorpus.archive(of: $0) })
    }

    func testEveryLoneXHTMLDocumentExtracts() throws {
        let items = EPUBCheckCorpus.documents(under: corpus, extensions: ["xhtml"])
        XCTAssertGreaterThan(items.count, 200, "XHTML documents found under \(corpus.path)")
        assertPolicy(examine(items, as: "text-documents") {
            EPUBCheckCorpus.container(aroundContentDocument: try Data(contentsOf: $0.url), name: "document.xhtml",
                                      mediaType: "application/xhtml+xml")
        })
    }

    private func examine(_ items: [EPUBCheckCorpus.Item], as name: String,
                         bytes: @escaping @Sendable (EPUBCheckCorpus.Item) throws -> Data) -> [Outcome] {
        var outcomes: [Outcome] = []
        for item in items {
            progress("\(name) \(item.path)")
            let start = Date()
            var outcome = Self.watched(Self.watchdog) { Self.examine(item, bytes: bytes) }
                ?? { var hung = Outcome(fixture: item.path, verdict: item.verdict); hung.hung = true; return hung }()
            outcome.seconds = Date().timeIntervalSince(start)
            outcomes.append(outcome)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(outcomes).write(to: reportDirectory.appending(path: "\(name).json"))
        let opened = outcomes.filter { $0.openError == nil && !$0.hung }
        print("""
            EPUBCheck corpus, \(name): \(outcomes.count) fixtures, \(opened.count) opened, \
            \(opened.reduce(0) { $0 + $1.sections }) sections extracted strictly (\(opened.reduce(0) { $0 + $1.bytes }) bytes of text), \
            \(opened.reduce(0) { $0 + $1.failures.count + $1.refusedAsDocumented.count }) refused strictly \
            (\(opened.reduce(0) { $0 + $1.refusedAsDocumented.count }) for declarations, as documented) of which recovery read \
            \(opened.reduce(0) { $0 + $1.recovered.count }), \(opened.reduce(0) { $0 + $1.foreign.count }) spine items not XHTML
            """)
        let slow = outcomes.filter { $0.seconds > Self.slow && !$0.hung }
        if !slow.isEmpty { print("EPUBCheck corpus, slow \(name): \(slow.map { "\($0.fixture) \(String(format: "%.1f", $0.seconds)) s" })") }
        return outcomes
    }

    private static func examine(_ item: EPUBCheckCorpus.Item, bytes: (EPUBCheckCorpus.Item) throws -> Data) -> Outcome {
        var outcome = Outcome(fixture: item.path, verdict: item.verdict)
        let publication: EPUBPublication
        do { publication = try EPUBPublication.open(data: try bytes(item)) } catch {
            outcome.openError = String(describing: error)
            return outcome
        }
        for index in publication.spine.indices {
            let path = publication.spine[index].resource.path
            do {
                let section = try publication.textSection(at: index)
                outcome.sections += 1
                outcome.bytes += section.text.utf8.count
                outcome.badMarks += badMarks(section)
                outcome.text[path] = section.text
            } catch EPUBTextExtractionError.unsupportedMediaType(let type) {
                outcome.foreign.append("\(path) (\(type))")
            } catch {
                // Entity declarations and internal DTD subsets always fail, as the contract says.
                if let data = try? publication.data(at: path), !XMLSafety.hasSafeDeclarations(data) {
                    outcome.refusedAsDocumented.append(path)
                } else {
                    outcome.failures[path] = String(describing: error)
                }
                if !(error is EPUBTextExtractionError || error is EPUBPublicationError) { outcome.untyped[path] = String(describing: error) }
                do {
                    let section = try publication.textSection(at: index, recoversMalformedMarkup: true)
                    outcome.recovered.append(path)
                    outcome.badMarks += badMarks(section)
                } catch {
                    if !(error is EPUBTextExtractionError || error is EPUBPublicationError) { outcome.untyped[path] = String(describing: error) }
                }
            }
        }
        return outcome
    }

    /// A mark counts UTF-8 bytes to a character of the text (or its end), with its separator
    /// before it; a heading's text is found at its mark.
    private static func badMarks(_ section: EPUBTextSection) -> Int {
        let utf8 = Array(section.text.utf8)
        func isBad(_ mark: EPUBTextMark) -> Bool {
            guard mark.offset >= 0, mark.offset <= utf8.count, mark.separator >= 0, mark.separator <= mark.offset else { return true }
            // Never inside a multi-byte character.
            return mark.offset < utf8.count && utf8[mark.offset] & 0xC0 == 0x80
        }
        var bad = section.anchors.values.filter(isBad).count
        for heading in section.headings {
            if isBad(heading.mark) { bad += 1; continue }
            let first = heading.text.split(separator: " ").first.map { Array($0.utf8) } ?? []
            if !utf8[heading.mark.offset...].starts(with: first) { bad += 1 }
        }
        return bad
    }

    private func assertPolicy(_ outcomes: [Outcome], file: StaticString = #filePath, line: UInt = #line) {
        func check(_ failures: [Outcome], _ message: String, _ detail: (Outcome) -> String) {
            guard !failures.isEmpty else { return }
            XCTFail("\(message), \(failures.count):\n" + failures.map { "  \($0.fixture): \(detail($0))" }.joined(separator: "\n"), file: file, line: line)
        }
        check(outcomes.filter(\.hung), "did not finish in \(Self.watchdog) s") { _ in "hung" }
        check(outcomes.filter { !$0.untyped.isEmpty }, "failed with an untyped error") { "\($0.untyped)" }
        check(outcomes.filter { $0.badMarks > 0 }, "anchors or headings do not mark the text") { "\($0.badMarks) marks" }
        check(outcomes.filter { $0.verdict == .valid && !$0.failures.isEmpty }, "valid for EPUBCheck but not extracted") { "\($0.failures)" }
    }

    private func progress(_ line: String) {
        let url = reportDirectory.appending(path: "text-progress.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
        try? handle.synchronize()
    }

    /// Runs `work` on a thread of its own and returns nil when it has not finished in `seconds`.
    /// A hung thread is abandoned, not stopped.
    private static func watched<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () -> T) -> T? {
        let box = Box<T>(), done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { box.set(work()); done.signal() }
        return done.wait(timeout: .now() + seconds) == .success ? box.value : nil
    }

    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        func set(_ value: T) { lock.withLock { stored = value } }
        var value: T? { lock.withLock { stored } }
    }
}
