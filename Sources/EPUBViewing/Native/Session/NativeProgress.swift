import EPUBCore
import EPUBReading
import Foundation

/// Overall progression, and the table-of-contents title and page-list entries for positions,
/// computed as foliate-js's `SectionProgress` and `TOCProgress` did: progression by section
/// byte size (nonlinear sections weigh nothing), and the title of the last contents entry at or
/// before a position. Pages are found the same way, but at a range's start (`pages(in:)`).
/// A book with no linear section keeps all of them in the reading order (`NativeBook.isOmitted`),
/// so each weighs its size. foliate-js weighed such a book nothing and gave it no progression;
/// this departs from it on purpose.
struct NativeProgress {
    private let sizes: [Double]
    private let total: Double
    private struct Entry { let title: String; let section: Int; let fragment: String? }
    private let entries: [Entry]
    private struct Page { let entry: EPUBPageListEntry; let section: Int; let fragment: String? }
    /// `EPUBPublication.pageList` by section, in page-list order within one.
    private let pages: [Page]

    init(publication: EPUBPublication) {
        let hasLinear = publication.spine.contains(where: \.isLinear)
        sizes = publication.spine.map { item in
            guard item.isLinear || !hasLinear, let data = try? publication.data(for: item.resource) else { return 0 }
            return Double(data.count)
        }
        total = sizes.reduce(0, +)
        var sectionByPath: [String: Int] = [:]
        for (index, item) in publication.spine.enumerated() where sectionByPath[item.resource.path] == nil {
            sectionByPath[item.resource.path] = index
        }
        for (index, item) in publication.spine.enumerated() {
            for fallback in publication.fallbackChain(for: item.resource).dropFirst() where sectionByPath[fallback.path] == nil {
                sectionByPath[fallback.path] = index
            }
        }
        func target(_ href: String) -> (section: Int, fragment: String?)? {
            let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            guard let section = sectionByPath[path] else { return nil }
            return (section, parts.count == 2 ? String(parts[1]).removingPercentEncoding : nil)
        }
        var entries: [Entry] = []
        func visit(_ items: [EPUBNavigationItem]) {
            for item in items {
                if let href = item.href, let target = target(href), !item.title.isEmpty {
                    entries.append(Entry(title: item.title, section: target.section, fragment: target.fragment))
                }
                visit(item.children)
            }
        }
        visit(publication.tableOfContents)
        // Reading order; navigation order breaks ties within a section until anchors are known.
        self.entries = entries.enumerated().sorted { ($0.element.section, $0.offset) < ($1.element.section, $1.offset) }.map(\.element)
        pages = (publication.pageList ?? []).compactMap { entry in
            target(entry.href).map { Page(entry: entry, section: $0.section, fragment: $0.fragment) }
        }.enumerated().sorted { ($0.element.section, $0.offset) < ($1.element.section, $1.offset) }.map(\.element)
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

    /// A range's page-list entries (`EPUBLocation.page` and `pages`): the last entry at or before
    /// its start, then those inside it, by position. The page list orders the entries of sections
    /// before the range, so `anchor` is asked only about sections the range shows, which are
    /// built; an entry whose fragment it cannot resolve sits at its section's start, where
    /// `.navigate(href:)` shows it. `isShown` says whether a section strictly inside the range is
    /// shown at all, as continuous scroll leaves nonlinear sections out.
    func pages(in range: ReaderTextRange, isShown: (Int) -> Bool,
               anchor: (Int, String) -> Int?) -> (page: EPUBPageListEntry?, pages: [EPUBPageListEntry]?) {
        var current: (entry: EPUBPageListEntry, position: ReaderTextPosition)?
        var inside: [(entry: EPUBPageListEntry, position: ReaderTextPosition, order: Int)] = []
        for (order, page) in pages.enumerated() {
            if page.section > range.end.section { break }
            let offset = page.section < range.start.section ? 0 : page.fragment.flatMap { anchor(page.section, $0) } ?? 0
            let position = ReaderTextPosition(section: page.section, offset: offset)
            if position <= range.start {
                // Later in reading order, or in the page list at the same position.
                if current.map({ $0.position <= position }) ?? true { current = (page.entry, position) }
            } else if position < range.end, page.section == range.start.section || page.section == range.end.section
                        || isShown(page.section) {
                inside.append((page.entry, position, order))
            }
        }
        let shown = (current.map { [$0.entry] } ?? [])
            + inside.sorted { ($0.position.section, $0.position.offset, $0.order) < ($1.position.section, $1.position.offset, $1.order) }
                .map(\.entry)
        return (current?.entry, shown.isEmpty ? nil : shown)
    }
}

extension NativeProgress {
    /// The contents titles and page-list entries of one built section, for naming many
    /// positions in it (search results) without walking the whole book for each.
    struct SectionMarks: Sendable {
        fileprivate var inheritedTitle: String?
        /// In navigation order, as `title(at:anchor:)` reads them.
        fileprivate var titles: [(offset: Int, title: String)] = []
        fileprivate var inheritedPage: EPUBPageListEntry?
        fileprivate var pages: [(offset: Int, entry: EPUBPageListEntry)] = []

        /// What `title(at:anchor:)` answers for an offset in the section.
        func title(at offset: Int) -> String? {
            titles.last { $0.offset <= offset }?.title ?? inheritedTitle
        }

        /// What `pages(in:isShown:anchor:)` answers as `page` for a range starting at an offset.
        func page(at offset: Int) -> EPUBPageListEntry? {
            var best: (offset: Int, entry: EPUBPageListEntry)?
            for page in pages where page.offset <= offset {
                if best.map({ $0.offset <= page.offset }) ?? true { best = page }
            }
            return best?.entry ?? inheritedPage
        }
    }

    /// `anchors` are the built section's (`SectionText.anchors`); an entry whose fragment they do
    /// not hold sits at the section's start, as it does for `title(at:anchor:)` and `pages`.
    func marks(inSection section: Int, anchors: [EPUBElementID: Int]) -> SectionMarks {
        var marks = SectionMarks()
        for entry in entries {
            if entry.section > section { break }
            if entry.section < section { marks.inheritedTitle = entry.title }
            else { marks.titles.append((entry.fragment.flatMap { anchors[$0] } ?? 0, entry.title)) }
        }
        for page in pages {
            if page.section > section { break }
            if page.section < section { marks.inheritedPage = page.entry }
            else { marks.pages.append((page.fragment.flatMap { anchors[$0] } ?? 0, page.entry)) }
        }
        return marks
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
        // A table is counted for the cells its grid has no slot for, and those are shown.
        let tables = report.unsupportedElements["table"] ?? 0
        let unsupported = report.unsupportedElements.values.reduce(0, +) - tables
        count(unsupported, one: "One part of this document, such as a video or a form, cannot be shown by this reader.",
              many: "# parts of this document, such as videos or forms, cannot be shown by this reader.")
        count(tables, one: "One table has cells that are shown after it, out of place.",
              many: "# tables have cells that are shown after them, out of place.")
        count(report.unreadableResources, one: "One image could not be shown.", many: "# images could not be shown.")
        count(report.mathFallbacks, one: "One formula is shown as plain text.", many: "# formulas are shown as plain text.")
        count(report.mathApproximations, one: "One formula is shown in a simplified layout.",
              many: "# formulas are shown in a simplified layout.")
        count(report.mathReductions, one: "One wide formula is reduced in size on narrow pages.",
              many: "# wide formulas are reduced in size on narrow pages.")
        if report.withheld { sentences.append("Some sections of this book could not be shown.") }
        if report.cfiUnavailable {
            sentences.append("Saved positions and passage highlights are unavailable in some repaired sections because their original text positions cannot be matched safely.")
        }
        if report.fixedLayoutReflowed { sentences.append("This book's fixed page layout is shown as reflowable text.") }
        if report.verticalWritingFlattened { sentences.append("Vertical text is shown horizontally.") }
        if report.flowBoxesReflowed {
            sentences.append("Some floating, positioned or inline box layouts may be simplified to keep their content readable in reading order. Fixed boxes appear once rather than staying pinned to each page.")
        }
        if report.flexGridSimplified {
            sentences.append("Some flexible box or grid layouts are shown as blocks in reading order: items meant to sit side by side, wrap or be reordered follow one another.")
        }
        if report.stylesTruncated { sentences.append("Some of this book's styling was too large to apply.") }
        if report.generatedContentOmitted {
            sentences.append("Some text or images this book's styling adds before or after its content are not shown.")
        }
        if report.textNotLaidOut { sentences.append("Some text in this book could not be laid out and is not shown.") }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
