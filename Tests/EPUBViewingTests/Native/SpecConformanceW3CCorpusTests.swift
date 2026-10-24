import CoreText
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import ImageIO
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The W3C reading-system test suite through the real pipeline: each expanded test is packed in
/// memory, opened, and every spine section built with the production rich-content factory, then
/// held to `SpecConformanceCorpus.expectation(for:)`. Skipped unless `EPUBLIB_W3C_EPUB_TESTS`
/// names the suite's `tests` directory; `EPUBLIB_W3C_EPUB_TESTS_REPORT` keeps the per-test table.
/// The suite's files are only read: nothing in them runs.
@MainActor final class SpecConformanceW3CCorpusTests: XCTestCase {
    private typealias Corpus = SpecConformanceCorpus

    private struct Outcome {
        var id: String
        var status = "opened"
        var sections = 0
        var withheld: [Int] = []
        var recovered: [Int] = []
        var disclosures: [Corpus.Disclosure] = []
        /// Sections whose own report carries the flex and grid disclosure.
        var flexGridSections = 0
        var mapViolations = 0
        var failures: [String] = []
    }

    func testEveryTestMeetsItsExpectedOutcome() async throws {
        guard let root = ProcessInfo.processInfo.environment[Corpus.environmentKey] else {
            throw XCTSkip("Set \(Corpus.environmentKey) to the tests directory of w3c/epub-tests")
        }
        let rootURL = URL(fileURLWithPath: root)
        let directories = try Corpus.testDirectories(under: rootURL)
        XCTAssertFalse(directories.isEmpty, "No test directories under \(root)")
        var lines = ["id | requirement | scope | result | sections (withheld, repaired) | disclosed | detail"]
        var failed = 0, sections = 0
        for (id, url) in directories {
            let supportsPSD = id == "pub-foreign_bad-fallback"
                ? Self.independentlyDecodesBitmap(try Data(contentsOf: url.appending(path: "EPUB/bar.psd"))) : false
            let expectation = Corpus.expectation(for: id, supportsPSDFallback: supportsPSD)
            let outcome = await run(id, at: url, expecting: expectation)
            for failure in outcome.failures { XCTFail("\(id) [\(expectation.requirement)]: \(failure)") }
            if !outcome.failures.isEmpty { failed += 1 }
            sections += outcome.sections
            let scope = expectation.outOfScope == nil ? "in scope" : "decided"
            let detail = (outcome.failures + [expectation.note].compactMap { $0 }.map { "note: \($0)" }).joined(separator: "; ")
            let disclosed = outcome.disclosures.map { $0 == .flexGrid ? "\($0.rawValue) (sections: \(outcome.flexGridSections))" : $0.rawValue }
            lines.append("\(id) | \(expectation.requirement) | \(scope) | \(outcome.failures.isEmpty ? "as expected" : "FAILED") (\(outcome.status))"
                + " | \(outcome.sections) (\(outcome.withheld.count), \(outcome.recovered.count))"
                + " | \(disclosed.joined(separator: ",")) | \(detail)")
        }
        // A split archive's first segment is no archive: RS 3.3 section 4.2 treats it as in error.
        // It has no end record, which is in the last segment, and is refused as bytes with none are.
        for segment in try Corpus.splitArchiveSegments(under: rootURL) {
            var refusal = "opened"
            do { _ = try await Task.detached { try EPUBPublication.open(at: segment) }.value }
            catch let error as EPUBPublicationError { refusal = "refused: \(error)" }
            catch { refusal = "refused: \(error)" }
            XCTAssertEqual(refusal, "refused: notArchive", segment.lastPathComponent)
            lines.append("\(segment.lastPathComponent) | epub-rs#confreq-zip-mult | in scope | \(refusal) | | |")
        }
        let report = lines.joined(separator: "\n")
        if let output = ProcessInfo.processInfo.environment[Corpus.reportKey] {
            try report.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
        }
        print("W3C epub-tests: \(directories.count) tests, \(sections) sections, \(failed) not as expected")
    }

    private func run(_ id: String, at url: URL, expecting expectation: Corpus.Expectation) async -> Outcome {
        var outcome = Outcome(id: id)
        let publication: EPUBPublication
        do {
            let data = try Corpus.archive(ofExpandedEPUBAt: url)
            publication = try await Task.detached { try EPUBPublication.open(data: data) }.value
        } catch {
            outcome.status = "refused: \(error)"
            if let refused = expectation.refused {
                if !"\(error)".hasPrefix(refused) { outcome.failures.append("refused with \(error), expected \(refused)") }
            } else { outcome.failures.append("could not be opened: \(error)") }
            return outcome
        }
        if let refused = expectation.refused { outcome.failures.append("opened, expected the refusal \(refused)") }
        let fonts = FontRegistry(publication: publication)
        let rich = NativeEngine().rich
        let sections = publication.spine.indices.map {
            SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: $0, typography: NativeTypography(),
                                                     fonts: fonts, rich: rich))
        }
        var report = SectionReport()
        for section in sections {
            report.formUnion(section.report)
            if section.report.withheld { outcome.withheld.append(section.spineIndex) }
            if section.report.recoveredAsHTML { outcome.recovered.append(section.spineIndex) }
            if section.report.flexGridSimplified { outcome.flexGridSections += 1 }
            outcome.mapViolations += Self.mapViolations(section)
        }
        outcome.sections = sections.count
        outcome.disclosures = Corpus.Disclosure.allCases.filter { Self.discloses($0, report) }
        if Set(outcome.withheld) != expectation.withheld {
            outcome.failures.append("sections that could not be shown: \(outcome.withheld), expected \(expectation.withheld.sorted())")
        }
        if Set(outcome.recovered) != expectation.recovered {
            outcome.failures.append("sections read with the HTML parser: \(outcome.recovered), expected \(expectation.recovered.sorted())")
        }
        if outcome.mapViolations > 0 { outcome.failures.append("\(outcome.mapViolations) text-map round-trip violations") }
        for check in expectation.checks {
            if let failure = Self.failure(of: check, publication: publication, sections: sections, report: report) {
                outcome.failures.append(failure)
            }
        }
        return outcome
    }

    // MARK: Checks

    /// A bounded independent ImageIO decode, never a result from the production image loader.
    nonisolated static func independentlyDecodesBitmap(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: 128,
              ] as CFDictionary) else { return false }
        return image.width > 0 && image.height > 0
    }

    private static func discloses(_ disclosure: Corpus.Disclosure, _ report: SectionReport) -> Bool {
        switch disclosure {
        case .fixedLayout: report.fixedLayoutReflowed
        case .verticalWriting: report.verticalWritingFlattened
        case .scripts: report.scriptsRefused > 0
        case .remoteResources: report.remoteResourcesRefused > 0
        case .unsupportedElements: !report.unsupportedElements.isEmpty
        case .unreadableResources: report.unreadableResources > 0
        case .withheld: report.withheld
        case .positionsUnavailable: report.cfiUnavailable
        case .mathFallback: report.mathFallbacks > 0
        case .flexGrid: report.flexGridSimplified
        }
    }

    private static func failure(of check: Corpus.Check, publication: EPUBPublication, sections: [SectionText],
                                report: SectionReport) -> String? {
        func text(_ index: Int) -> String? { sections.indices.contains(index) ? sections[index].string.string : nil }
        func location(_ phrase: String, in index: Int) -> Int? {
            guard let text = text(index) else { return nil }
            let range = (text as NSString).range(of: phrase)
            return range.location == NSNotFound ? nil : range.location
        }
        func attachments(_ index: Int) -> [NSTextAttachment] {
            guard sections.indices.contains(index) else { return [] }
            var found: [NSTextAttachment] = []
            let string = sections[index].string
            string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { found.append(attachment) }
            }
            return found
        }
        func family(_ index: Int, at location: Int) -> String? {
            (sections[index].string.attribute(.font, at: location, effectiveRange: nil) as? PlatformFont)
                .map { CTFontCopyFamilyName($0 as CTFont) as String }
        }
        func flatten(_ items: [EPUBNavigationItem]) -> [EPUBNavigationItem] { items.flatMap { [$0] + flatten($0.children) } }
        func mismatch<Value: Equatable>(_ name: String, _ actual: Value, _ expected: Value) -> String? {
            actual == expected ? nil : "\(name) is \(actual), expected \(expected)"
        }
        func link(_ index: Int, _ phrase: String) -> ReaderLink? {
            guard let location = location(phrase, in: index),
                  let url = sections[index].string.attribute(.link, at: location, effectiveRange: nil) as? URL else { return nil }
            return ReaderLink(url: url)
        }
        switch check {
        case .title(let expected): return mismatch("title", publication.metadata.title, expected)
        case .authors(let expected): return mismatch("authors", publication.metadata.authors, expected)
        case .spine(let expected): return mismatch("spine", publication.spine.map(\.resource.path), expected)
        case .linear(let expected): return mismatch("linear", publication.spine.map(\.isLinear), expected)
        case .layouts(let expected): return mismatch("layouts", publication.spine.map { "\($0.layout)" }, expected)
        case .progression(let expected): return mismatch("page progression", publication.pageProgression.rawValue, expected)
        case .toc(let expected): return mismatch("contents", flatten(publication.tableOfContents).map(\.title), expected)
        case .tocTargets(let expected): return mismatch("contents targets", flatten(publication.tableOfContents).map { $0.href ?? "" }, expected)
        case .rendered(let index, let phrase):
            return text(index)?.contains(phrase) == true ? nil : "section \(index) does not show \(phrase.debugDescription): \((text(index) ?? "").prefix(160).debugDescription)"
        case .notRendered(let index, let phrase):
            return text(index)?.contains(phrase) == true ? "section \(index) shows \(phrase.debugDescription)" : nil
        case .renderedInOrder(let phrases):
            let book = sections.filter { publication.spine[$0.spineIndex].isLinear }.map(\.string.string).joined(separator: "\n") as NSString
            var cursor = 0
            for phrase in phrases {
                let range = book.range(of: phrase, range: NSRange(location: cursor, length: book.length - cursor))
                guard range.location != NSNotFound else { return "\(phrase.debugDescription) is not shown after the phrases before it" }
                cursor = NSMaxRange(range)
            }
            return nil
        case .image(let index, let path):
            let paths = attachments(index).compactMap { ($0 as? ReaderImageAttachment)?.path }
            return paths.contains(path) ? nil : "section \(index) shows the images \(paths), expected one from \(path)"
        case .imageCount(let index, let expected):
            return mismatch("images in section \(index)", attachments(index).filter { $0 is ReaderImageAttachment }.count, expected)
        case .formula(let index):
            return attachments(index).contains { $0 is MathAttachment } ? nil : "section \(index) lays out no formula"
        case .embeddedFont(let index, let phrase), .defaultFont(let index, let phrase):
            guard let location = location(phrase, in: index), let base = family(index, at: 0), let face = family(index, at: location) else {
                return "section \(index) does not show \(phrase.debugDescription)"
            }
            if case .embeddedFont = check { return face != base ? nil : "\(phrase.debugDescription) is set in the default \(base), not an embedded face" }
            return face == base ? nil : "\(phrase.debugDescription) is set in \(face), expected the default \(base)"
        case .link(let index, let phrase, let expected):
            guard case .internal(let href)? = link(index, phrase) else { return "\(phrase.debugDescription) in section \(index) is not an internal link" }
            let path = String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]).removingPercentEncoding
            return mismatch("the link's section", publication.spine.firstIndex { $0.resource.path == path }, Optional(expected))
        case .externalLink(let index, let phrase):
            if case .external? = link(index, phrase) { return nil }
            return "\(phrase.debugDescription) in section \(index) is not an external link"
        case .note(let index, let id, let phrase):
            guard sections.indices.contains(index), let note = sections[index].notes[id] else { return "section \(index) has no note \(id)" }
            return note.string.contains(phrase) ? nil : "note \(id) reads \(note.string.debugDescription)"
        case .noNote(let index, let id):
            guard sections.indices.contains(index), let note = sections[index].notes[id] else { return nil }
            return "section \(index) shows a note for \(id): \(note.string.debugDescription)"
        case .leftToRight(let index):
            guard sections.indices.contains(index) else { return "no section \(index)" }
            var rightToLeft = false
            let string = sections[index].string
            string.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: string.length)) { value, _, _ in
                if (value as? NSParagraphStyle)?.baseWritingDirection == .rightToLeft { rightToLeft = true }
            }
            return rightToLeft ? "section \(index) has right-to-left paragraphs" : nil
        case .disclosed(let disclosure): return discloses(disclosure, report) ? nil : "\(disclosure.rawValue) is not disclosed"
        case .notDisclosed(let disclosure): return discloses(disclosure, report) ? "\(disclosure.rawValue) is disclosed" : nil
        case .vertical(let index, let expected):
            guard sections.indices.contains(index) else { return "no section \(index)" }
            return mismatch("vertical writing in section \(index)", sections[index].report.verticalWritingFlattened, expected)
        case .distinctPositions:
            guard let spine = try? SpineCFIs(publication: publication) else { return "the package document's spine CFIs could not be read" }
            let resolved = spine.bases.map { spine.resolve($0)?.spineIndex }
            return mismatch("the spine occurrence each occurrence's position names", resolved, publication.spine.indices.map { Optional($0) })
        case .fixedPages(let expected):
            return mismatch("sections shown as fixed-layout pages", sections.filter { $0.fixedPage != nil }.map(\.spineIndex), expected)
        }
    }

    /// Every mapped rendered character maps to a DOM position that maps back into its span.
    private static func mapViolations(_ section: SectionText) -> Int {
        var violations = 0
        for span in section.map.spans {
            for location in stride(from: span.location, to: span.location + span.length, by: max(1, span.length / 16)) {
                guard let position = section.map.position(at: location, in: section.document) else { violations += 1; continue }
                if section.map.location(of: position) != (span.isExact ? location : span.location) { violations += 1 }
            }
        }
        return violations
    }
}
