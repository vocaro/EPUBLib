import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// Runs EPUBCheck's own test corpus through the publication parser and the native build:
/// every whole publication (an expanded directory, packed in memory, or an `.epub`), every lone
/// package document inside a minimal container, and every lone content document and stylesheet.
/// EPUBCheck's Gherkin scenarios say which fixtures are valid; those must open and build with
/// nothing withheld, and no fixture of either kind may hang or fail with an untyped error.
///
/// Skipped unless `EPUBLIB_EPUBCHECK_FIXTURES` names `src/test/resources` of a w3c/epubcheck
/// checkout. `EPUBLIB_EPUBCHECK_REPORT` names a directory for the JSON outcomes (default
/// `.build/epubcheck-corpus`); its `progress.log` ends with the fixture being examined, which
/// names the culprit when the process traps. `EPUBLIB_EPUBCHECK_SKIP` lists fixtures to leave
/// out, comma-separated, to run past one. The corpus is data: nothing in it is executed.
@MainActor final class EPUBCheckCorpusTests: XCTestCase {
    struct Outcome: Codable, Sendable {
        var fixture: String
        var verdict: EPUBCheckCorpus.Verdict
        var ids: [String]
        var seconds = 0.0
        var hung = false
        var openError: String?
        /// The failure is not an `EPUBPublicationError`.
        var untypedOpenError = false
        /// A refusal the architecture document names: a remote resource in the spine or encryption.
        var documentedRefusal = false
        var sections = 0
        var characters = 0
        /// Withheld sections by spine path, with the content document's parse failure.
        var withheld: [String: String] = [:]
        /// Of those, sections refused for entity declarations or an internal DTD subset, which
        /// the architecture document says are always refused.
        var withheldAsDocumented: [String] = []
        /// What each section shows, by spine path, for comparison with EPUBText's extraction.
        var text: [String: String] = [:]
        var recoveredAsHTML: [String] = []
        var cfiUnavailable: [String] = []
        var mapViolations = 0
        /// Spine items that are not XHTML, as `path (media type)`.
        var foreignSpineItems: [String] = []
        var disclosures: [String: Int] = [:]
    }

    /// Seconds one fixture may take before it is recorded as hung, and past which it is listed as slow.
    private static let watchdog = 120.0, slow = 5.0

    private var corpus: URL!
    private var reportDirectory: URL!
    private var skipped: Set<String> = []

    override func setUp() async throws {
        guard let root = EPUBCheckCorpus.root() else {
            throw XCTSkip("Set \(EPUBCheckCorpus.environmentKey) to src/test/resources of an EPUBCheck checkout")
        }
        let environment = ProcessInfo.processInfo.environment
        corpus = root
        reportDirectory = URL(fileURLWithPath: environment["EPUBLIB_EPUBCHECK_REPORT"] ?? ".build/epubcheck-corpus")
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        skipped = Set((environment["EPUBLIB_EPUBCHECK_SKIP"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    func testEveryWholePublicationOpensAndBuildsAsEPUBCheckClassifiesIt() async throws {
        let items = EPUBCheckCorpus.publications(under: corpus).filter { !skipped.contains($0.path) }
        XCTAssertGreaterThan(items.count, 400, "publications found under \(corpus.path)")
        XCTAssertGreaterThan(items.filter { $0.verdict == .valid }.count, 150, "the feature files classify the fixtures")
        let outcomes = await examine(items, as: "publications") { item in try EPUBCheckCorpus.archive(of: item) }
        assertPolicy(outcomes, kind: "publication")
    }

    func testEveryLonePackageDocumentOpensInsideAMinimalContainer() async throws {
        let items = EPUBCheckCorpus.documents(under: corpus, extensions: ["opf"]).filter { !skipped.contains($0.path) }
        XCTAssertGreaterThan(items.count, 300, "package documents found under \(corpus.path)")
        let outcomes = await examine(items, as: "packages") { item in
            EPUBCheckCorpus.container(aroundPackageDocument: try Data(contentsOf: item.url))
        }
        assertPolicy(outcomes, kind: "package document")
    }

    func testEveryLoneContentDocumentParsesAndBuilds() async throws {
        let items = EPUBCheckCorpus.documents(under: corpus, extensions: ["xhtml", "svg"]).filter { !skipped.contains($0.path) }
        XCTAssertGreaterThan(items.count, 200, "content documents found under \(corpus.path)")
        let outcomes = await examine(items, as: "documents") { item in
            let svg = item.url.pathExtension.lowercased() == "svg"
            return EPUBCheckCorpus.container(aroundContentDocument: try Data(contentsOf: item.url),
                                             name: svg ? "document.svg" : "document.xhtml",
                                             mediaType: svg ? "image/svg+xml" : "application/xhtml+xml")
        }
        assertPolicy(outcomes, kind: "content document")
    }

    func testEveryLoneStylesheetParses() async throws {
        let items = EPUBCheckCorpus.documents(under: corpus, extensions: ["css"]).filter { !skipped.contains($0.path) }
        XCTAssertFalse(items.isEmpty, "stylesheets found under \(corpus.path)")
        var hung: [String] = []
        for item in items {
            progress("stylesheet \(item.path)")
            let data = try Data(contentsOf: item.url)
            let rules = await Self.watched(Self.watchdog) { CSSStyleSheet.parse(SectionStyles.decode(data), path: "EPUB/style.css").rules.count }
            if rules == nil { hung.append(item.path) }
        }
        XCTAssertTrue(hung.isEmpty, "stylesheets that did not finish parsing in \(Self.watchdog) s: \(hung)")
    }

    // MARK: Running

    private func examine(_ items: [EPUBCheckCorpus.Item], as name: String,
                         bytes: @escaping @Sendable (EPUBCheckCorpus.Item) throws -> Data) async -> [Outcome] {
        let rich = NativeEngine().rich
        var outcomes: [Outcome] = []
        for item in items {
            progress("\(name) \(item.path)")
            let start = Date()
            var outcome = await Self.watched(Self.watchdog) { Self.examine(item, rich: rich, bytes: bytes) }
                ?? { var hung = Outcome(fixture: item.path, verdict: item.verdict, ids: item.ids); hung.hung = true; return hung }()
            outcome.seconds = Date().timeIntervalSince(start)
            outcomes.append(outcome)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(outcomes).write(to: reportDirectory.appending(path: "\(name).json"))
        let opened = outcomes.filter { $0.openError == nil && !$0.hung }
        func count(_ verdict: EPUBCheckCorpus.Verdict, _ list: [Outcome]) -> Int { list.filter { $0.verdict == verdict }.count }
        print("""
            EPUBCheck corpus, \(name): \(outcomes.count) fixtures \
            (\(count(.valid, outcomes)) valid, \(count(.invalid, outcomes)) invalid, \(count(.unclassified, outcomes)) unclassified); \
            opened \(opened.count) (\(count(.valid, opened)) valid, \(count(.invalid, opened)) invalid, \(count(.unclassified, opened)) unclassified); \
            \(outcomes.reduce(0) { $0 + $1.sections }) sections, \(outcomes.reduce(0) { $0 + $1.characters }) characters built; \
            report at \(reportDirectory.appending(path: "\(name).json").path)
            """)
        let slow = outcomes.filter { $0.seconds > Self.slow && !$0.hung }
        if !slow.isEmpty { print("EPUBCheck corpus, slow \(name): \(slow.map { "\($0.fixture) \(String(format: "%.1f", $0.seconds)) s" })") }
        return outcomes
    }

    private nonisolated static func examine(_ item: EPUBCheckCorpus.Item, rich: any RichContentFactory,
                                            bytes: (EPUBCheckCorpus.Item) throws -> Data) -> Outcome {
        var outcome = Outcome(fixture: item.path, verdict: item.verdict, ids: item.ids)
        let publication: EPUBPublication
        do { publication = try EPUBPublication.open(data: try bytes(item)) } catch {
            outcome.openError = String(describing: error)
            outcome.untypedOpenError = !(error is EPUBPublicationError)
            switch error as? EPUBPublicationError {
            case .unsupportedEncryption: outcome.documentedRefusal = true
            case .unsafePath(let href): outcome.documentedRefusal = href.firstMatch(of: #/^[A-Za-z][A-Za-z0-9+.\-]*:/#) != nil
            default: break
            }
            return outcome
        }
        let fonts = FontRegistry(publication: publication)
        var report = SectionReport()
        for index in publication.spine.indices {
            let resource = publication.spine[index].resource
            if resource.mediaType != "application/xhtml+xml" { outcome.foreignSpineItems.append("\(resource.path) (\(resource.mediaType))") }
            let section = SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: index,
                                                                   typography: NativeTypography(), fonts: fonts, rich: rich))
            outcome.sections += 1
            outcome.characters += section.string.length
            outcome.text[resource.path] = section.string.string
            if section.report.withheld {
                var reason = "no parse failure"
                do { _ = try ContentDocument.parse(publication.data(for: resource), path: resource.path) } catch {
                    reason = String(describing: error)
                    // Bytes that are not markup at all fail the same check, so only a document counts.
                    if case .unsafeMarkup = error as? ContentDocumentError,
                       ["application/xhtml+xml", "image/svg+xml"].contains(resource.mediaType) {
                        outcome.withheldAsDocumented.append(resource.path)
                    }
                }
                outcome.withheld[resource.path] = reason
            }
            if section.report.recoveredAsHTML { outcome.recoveredAsHTML.append(resource.path) }
            if section.report.cfiUnavailable { outcome.cfiUnavailable.append(resource.path) }
            outcome.mapViolations += mapViolations(section)
            report.formUnion(section.report)
        }
        outcome.disclosures = [
            "scriptsRefused": report.scriptsRefused, "remoteResourcesRefused": report.remoteResourcesRefused,
            "unsupportedElements": report.unsupportedElements.values.reduce(0, +), "unreadableResources": report.unreadableResources,
            "mathFallbacks": report.mathFallbacks, "mathApproximations": report.mathApproximations,
            "stylesTruncated": report.stylesTruncated ? 1 : 0, "fixedLayoutReflowed": report.fixedLayoutReflowed ? 1 : 0,
            "verticalWritingFlattened": report.verticalWritingFlattened ? 1 : 0,
            "flowBoxesReflowed": report.flowBoxesReflowed ? 1 : 0, "flexGridSimplified": report.flexGridSimplified ? 1 : 0,
        ].filter { $0.value != 0 }
        return outcome
    }

    /// Every character of an exact span must map to a DOM position that maps back to it, the
    /// span must lie inside the text and the map must be as long as the text.
    private nonisolated static func mapViolations(_ section: SectionText) -> Int {
        var violations = section.map.length == section.string.length ? 0 : 1
        for span in section.map.spans {
            guard span.location >= 0, span.location + span.length <= section.string.length else { violations += 1; continue }
            guard span.isExact else { continue }
            for location in stride(from: span.location, to: span.location + span.length, by: max(1, span.length / 256)) {
                guard let position = section.map.position(at: location, in: section.document) else { violations += 1; continue }
                if section.map.location(of: position) != location { violations += 1 }
            }
        }
        return violations
    }

    /// The policy: no fixture hangs or fails with an untyped error; a fixture EPUBCheck calls
    /// valid opens, unless for a documented refusal, and builds every XHTML section as
    /// well-formed XHTML with nothing withheld and a text map that round-trips.
    private func assertPolicy(_ outcomes: [Outcome], kind: String, file: StaticString = #filePath, line: UInt = #line) {
        func list(_ outcomes: [Outcome], _ detail: (Outcome) -> String) -> String {
            "\(outcomes.count):\n" + outcomes.map { "  \($0.fixture): \(detail($0))" }.joined(separator: "\n")
        }
        func check(_ failures: [Outcome], _ message: String, _ detail: @escaping (Outcome) -> String) {
            if !failures.isEmpty { XCTFail("\(message) (\(kind)), \(list(failures, detail))", file: file, line: line) }
        }
        check(outcomes.filter(\.hung), "did not finish in \(Self.watchdog) s") { _ in "hung" }
        check(outcomes.filter(\.untypedOpenError), "refused with an error that is not an EPUBPublicationError") { $0.openError ?? "" }
        check(outcomes.filter { $0.mapViolations > 0 }, "text map does not round-trip") { "\($0.mapViolations) violations" }
        let valid = outcomes.filter { $0.verdict == .valid && !$0.hung }
        check(valid.filter { $0.openError != nil && !$0.documentedRefusal }, "valid for EPUBCheck but refused") { $0.openError ?? "" }
        check(valid.filter { $0.withheld.count > $0.withheldAsDocumented.count }, "valid for EPUBCheck but a section is withheld") { outcome in
            "\(outcome.withheld.filter { !outcome.withheldAsDocumented.contains($0.key) })"
        }
        check(valid.filter { !$0.recoveredAsHTML.isEmpty }, "valid for EPUBCheck but read as malformed HTML") { "\($0.recoveredAsHTML)" }
        check(valid.filter { !$0.cfiUnavailable.isEmpty && $0.recoveredAsHTML.isEmpty }, "valid for EPUBCheck but without CFIs") { "\($0.cfiUnavailable)" }
        let documented = valid.filter(\.documentedRefusal)
        if !documented.isEmpty { print("EPUBCheck corpus, valid \(kind)s refused as documented, \(list(documented) { $0.openError ?? "" })") }
        let unsafe = valid.filter { !$0.withheldAsDocumented.isEmpty }
        if !unsafe.isEmpty { print("EPUBCheck corpus, valid \(kind)s with a section withheld as documented, \(list(unsafe) { "\($0.withheld)" })") }
        let foreign = valid.filter { !$0.foreignSpineItems.isEmpty }
        if !foreign.isEmpty { print("EPUBCheck corpus, valid \(kind)s with spine items that are not XHTML, \(list(foreign) { "\($0.foreignSpineItems)" })") }
    }

    private func progress(_ line: String) {
        let url = reportDirectory.appending(path: "progress.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
        try? handle.synchronize()
    }

    /// Runs `work` on a thread of its own (with a secondary thread's default stack, as the
    /// builds have in the reader) and returns nil when it has not finished in `seconds`. A hung
    /// thread is abandoned, not stopped.
    private nonisolated static func watched<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let gate = Gate(continuation)
            Thread.detachNewThread { gate.resume(work()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { gate.resume(nil) }
        }
    }

    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
        func resume(_ value: T?) {
            let pending = lock.withLock { () -> CheckedContinuation<T?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }
}
