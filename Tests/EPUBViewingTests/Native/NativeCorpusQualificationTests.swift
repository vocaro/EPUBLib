import EPUBCore
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing

/// Builds every section of every EPUB under `EPUBLIB_CORPUS` (a colon-separated list of
/// directories, searched recursively) and writes a qualification report to
/// `EPUBLIB_CORPUS_REPORT` (default `.build/corpus-report.json`). Skipped unless the corpus is set:
/// real books are not part of the repository.
@MainActor final class NativeCorpusQualificationTests: XCTestCase {
    private struct BookResult: Codable {
        var file: String
        var bytes: Int
        var sections = 0
        var openSeconds = 0.0
        var firstSectionSeconds = 0.0
        var allSectionsSeconds = 0.0
        var slowestSectionSeconds = 0.0
        var renderedCharacters = 0
        var attachments = 0
        var footprintMB = 0.0
        var withheldSections = 0
        var report: [String: Int] = [:]
        var mapViolations = 0
        var error: String?
    }

    func testCorpus() async throws {
        guard let roots = ProcessInfo.processInfo.environment["EPUBLIB_CORPUS"] else {
            throw XCTSkip("Set EPUBLIB_CORPUS to directories of EPUB files")
        }
        let files = roots.split(separator: ":").flatMap { root -> [URL] in
            let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: String(root)), includingPropertiesForKeys: nil)
            return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension.lowercased() == "epub" }
        }.sorted { $0.path < $1.path }
        XCTAssertFalse(files.isEmpty, "No EPUB files under \(roots)")
        var results: [BookResult] = []
        for file in files { results.append(await qualify(file)) }
        let output = ProcessInfo.processInfo.environment["EPUBLIB_CORPUS_REPORT"] ?? ".build/corpus-report.json"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: output))
        // A book EPUBReading refuses to open is the parser's verdict, not the viewer's: reported, not failed.
        let unopened = results.filter { $0.error?.hasPrefix("open:") == true }
        let failures = results.filter { ($0.error != nil && $0.error?.hasPrefix("open:") != true) || $0.mapViolations > 0 }
        XCTAssertTrue(failures.isEmpty, "Failures: \(failures.map { "\($0.file): \($0.error ?? "\($0.mapViolations) map violations")" })")
        print("Qualified \(results.count - unopened.count) books (\(unopened.count) refused by EPUBReading); report at \(output)")
    }

    private func qualify(_ file: URL) async -> BookResult {
        var result = BookResult(file: file.path, bytes: (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let start = Date()
        let publication: EPUBPublication
        do { publication = try await Task.detached { try EPUBPublication.open(at: file) }.value }
        catch { result.error = "open: \(error)"; return result }
        result.openSeconds = Date().timeIntervalSince(start)
        result.sections = publication.spine.count
        let fonts = FontRegistry(publication: publication)
        let rich = NativeEngine().rich
        let typography = NativeTypography()
        var report = SectionReport()
        let buildStart = Date()
        let sections: [(SectionText, Double)] = await withTaskGroup(of: (SectionText, Double).self) { group in
            for index in publication.spine.indices {
                let request = SectionBuildRequest(publication: publication, spineIndex: index, typography: typography,
                                                  fonts: fonts, rich: rich)
                group.addTask {
                    let begin = Date()
                    let section = SectionBuilder.build(request)
                    return (section, Date().timeIntervalSince(begin))
                }
            }
            var all: [(SectionText, Double)] = []
            for await item in group { all.append(item) }
            return all.sorted { $0.0.spineIndex < $1.0.spineIndex }
        }
        result.allSectionsSeconds = Date().timeIntervalSince(buildStart)
        result.firstSectionSeconds = sections.first?.1 ?? 0
        result.slowestSectionSeconds = sections.map(\.1).max() ?? 0
        for (section, _) in sections {
            report.formUnion(section.report)
            if section.report.withheld { result.withheldSections += 1 }
            result.renderedCharacters += section.string.length
            section.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: section.string.length)) { value, _, _ in
                if value != nil { result.attachments += 1 }
            }
            result.mapViolations += mapViolations(section)
        }
        result.footprintMB = Self.footprintMB()
        result.report = [
            "scriptsRefused": report.scriptsRefused, "remoteResourcesRefused": report.remoteResourcesRefused,
            "unsupportedElements": report.unsupportedElements.values.reduce(0, +),
            "unreadableResources": report.unreadableResources, "mathFallbacks": report.mathFallbacks,
            "recoveredAsHTML": report.recoveredAsHTML ? 1 : 0, "stylesTruncated": report.stylesTruncated ? 1 : 0,
            "verticalWritingFlattened": report.verticalWritingFlattened ? 1 : 0,
        ]
        return result
    }

    /// Every mapped rendered character must map to a DOM position that maps back into its span.
    private func mapViolations(_ section: SectionText) -> Int {
        var violations = 0
        for span in section.map.spans where span.isExact {
            for location in stride(from: span.location, to: span.location + span.length, by: max(1, span.length / 8)) {
                guard let position = section.map.position(at: location, in: section.document) else { violations += 1; continue }
                if section.map.location(of: position) != location { violations += 1 }
            }
        }
        return violations
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
