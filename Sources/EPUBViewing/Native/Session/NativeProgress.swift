import EPUBCore
import EPUBReading
import Foundation

/// Overall progression and table-of-contents titles for positions, computed as foliate-js's
/// `SectionProgress` and `TOCProgress` did: progression by section byte size (nonlinear
/// sections weigh nothing), and the title of the last contents entry at or before a position.
struct NativeProgress {
    private let sizes: [Double]
    private let total: Double
    private struct Entry { let title: String; let section: Int; let fragment: String? }
    private let entries: [Entry]

    init(publication: EPUBPublication) {
        sizes = publication.spine.map { item in
            guard item.isLinear, let data = try? publication.data(for: item.resource) else { return 0 }
            return Double(data.count)
        }
        total = sizes.reduce(0, +)
        var sectionByPath: [String: Int] = [:]
        for (index, item) in publication.spine.enumerated() where sectionByPath[item.resource.path] == nil {
            sectionByPath[item.resource.path] = index
        }
        var entries: [Entry] = []
        func visit(_ items: [EPUBNavigationItem]) {
            for item in items {
                if let href = item.href {
                    let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                    let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                    if let section = sectionByPath[path], !item.title.isEmpty {
                        entries.append(Entry(title: item.title, section: section,
                                             fragment: parts.count == 2 ? String(parts[1]).removingPercentEncoding : nil))
                    }
                }
                visit(item.children)
            }
        }
        visit(publication.tableOfContents)
        // Reading order; navigation order breaks ties within a section until anchors are known.
        self.entries = entries.enumerated().sorted { ($0.element.section, $0.offset) < ($1.element.section, $1.offset) }.map(\.element)
    }

    /// 0–1 through the book.
    func progression(section: Int, fraction: Double) -> Double? {
        guard total > 0, sizes.indices.contains(section) else { return nil }
        let before = sizes[..<section].reduce(0, +)
        return min(1, max(0, (before + sizes[section] * min(1, max(0, fraction))) / total))
    }

    /// The contents title for a position. `anchor` resolves an entry's fragment in its section
    /// (nil when the section is not built yet, which places the entry at the section's start).
    func title(at position: ReaderTextPosition, anchor: (Int, String) -> Int?) -> String? {
        var best: Entry?
        for entry in entries {
            if entry.section > position.section { break }
            let offset = entry.fragment.flatMap { anchor(entry.section, $0) } ?? 0
            if entry.section < position.section || offset <= position.offset { best = entry }
        }
        return best?.title
    }
}

/// The `.disclosure` text for what a book's sections withheld or simplified.
enum NativeDisclosure {
    static func text(for report: SectionReport) -> String? {
        var sentences: [String] = []
        func count(_ n: Int, one: String, many: String) {
            if n == 1 { sentences.append(one) } else if n > 1 { sentences.append(many.replacingOccurrences(of: "#", with: "\(n)")) }
        }
        count(report.scriptsRefused, one: "One interactive part of this document was not run.",
              many: "# interactive parts of this document were not run.")
        count(report.remoteResourcesRefused, one: "One resource this document asked to load from the internet was not loaded.",
              many: "# resources this document asked to load from the internet were not loaded.")
        let unsupported = report.unsupportedElements.values.reduce(0, +)
        count(unsupported, one: "One part of this document, such as a video or a form, cannot be shown by this reader.",
              many: "# parts of this document, such as videos or forms, cannot be shown by this reader.")
        count(report.unreadableResources, one: "One image could not be shown.", many: "# images could not be shown.")
        count(report.mathFallbacks, one: "One formula is shown as plain text.", many: "# formulas are shown as plain text.")
        if report.withheld { sentences.append("Some sections of this book could not be shown.") }
        if report.fixedLayoutReflowed { sentences.append("This book's fixed page layout is shown as reflowable text.") }
        if report.verticalWritingFlattened { sentences.append("Vertical text is shown horizontally.") }
        if report.stylesTruncated { sentences.append("Some of this book's styling was too large to apply.") }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
