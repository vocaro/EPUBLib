import EPUBCore
import EPUBReading
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Builds and keeps a publication's sections for one typography.
///
/// The section the reader needs first builds alone, so it paints as soon as possible; the rest
/// then build in the background, several at a time. A typography change keeps every built
/// section on screen until its rebuild arrives: a section's characters never depend on
/// typography, so positions stay valid while old and new builds coexist.
@MainActor final class NativeBook {
    let publication: EPUBPublication
    let fonts: FontRegistry
    private let rich: any RichContentFactory
    private(set) var typography: NativeTypography
    /// The newest build of each section, possibly for an older typography.
    private var sections: [SectionText?]
    private var builtTypography: [NativeTypography?]
    private var inFlight: [Int: Task<SectionText, Never>] = [:]
    private var background: Task<Void, Never>?
    private var cachedBookText: ReaderBookText?
    private var closed = false

    /// A section (re)build arrived. `isCurrentTypography` is false for a stale build.
    var onSectionBuilt: ((Int) -> Void)?
    /// Every section is built for the current typography; `bookText` is available.
    var onBookComplete: (() -> Void)?

    init(publication: EPUBPublication, typography: NativeTypography, rich: any RichContentFactory) {
        self.publication = publication
        self.typography = typography
        self.rich = rich
        fonts = FontRegistry(publication: publication)
        sections = Array(repeating: nil, count: publication.spine.count)
        builtTypography = Array(repeating: nil, count: publication.spine.count)
    }

    var count: Int { sections.count }
    func section(_ index: Int) -> SectionText? { sections.indices.contains(index) ? sections[index] : nil }
    func isCurrent(_ index: Int) -> Bool { builtTypography[index] == typography }
    var isComplete: Bool { builtTypography.allSatisfy { $0 == typography } }

    /// The section built for the current typography, building it first if needed.
    func build(_ index: Int) async -> SectionText {
        if let section = sections[index], isCurrent(index) { return section }
        let target = typography
        let task: Task<SectionText, Never>
        if let existing = inFlight[index] { task = existing }
        else {
            let request = SectionBuildRequest(publication: publication, spineIndex: index, typography: target,
                                              fonts: fonts, rich: rich)
            task = Task.detached(priority: .userInitiated) { SectionBuilder.build(request) }
            inFlight[index] = task
        }
        let section = await task.value
        if inFlight[index] == task { inFlight[index] = nil }
        store(section, typography: target)
        if typography != target { return await build(index) }
        return section
    }

    /// Builds every remaining section in the background, a few at a time, nearest `origin` first.
    func buildRemaining(from origin: Int) {
        background?.cancel()
        let target = typography
        let pending = sections.indices.filter { builtTypography[$0] != target }
            .sorted { abs($0 - origin) < abs($1 - origin) }
        guard !pending.isEmpty else { completeIfReady(); return }
        let width = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
        let requests = pending.map {
            SectionBuildRequest(publication: publication, spineIndex: $0, typography: target, fonts: fonts, rich: rich)
        }
        background = Task { [weak self] in
            await withTaskGroup(of: SectionText.self) { group in
                var remaining = requests.makeIterator()
                for _ in 0..<width {
                    guard let request = remaining.next() else { break }
                    group.addTask { SectionBuilder.build(request) }
                }
                while let section = await group.next() {
                    guard !Task.isCancelled, let self, !self.closed, self.typography == target else {
                        group.cancelAll(); return
                    }
                    if !self.isCurrent(section.spineIndex) { self.store(section, typography: target) }
                    if let request = remaining.next() { group.addTask { SectionBuilder.build(request) } }
                }
            }
            self?.completeIfReady()
        }
    }

    /// Rebuilds for new typography. Built sections stay available until replaced.
    func setTypography(_ typography: NativeTypography) {
        guard typography != self.typography else { return }
        self.typography = typography
        cachedBookText = nil
        background?.cancel()
    }

    /// The whole book for continuous scroll: every section, each followed by one paragraph
    /// break, the next section's first paragraph spaced from it. nil until all are current.
    var bookText: ReaderBookText? {
        if let cachedBookText { return cachedBookText }
        guard isComplete else { return nil }
        let string = NSMutableAttributedString()
        var starts: [Int] = []
        for (index, section) in sections.enumerated() {
            guard let section else { return nil }
            if index > 0 {
                let separator = NSMutableParagraphStyle()
                separator.paragraphSpacing = typography.fontSize * 2
                string.append(NSAttributedString(string: "\n", attributes: [
                    .paragraphStyle: separator,
                    .font: FontRegistry.systemFont(families: ["serif"], size: typography.fontSize, weight: 400, italic: false),
                ]))
            }
            starts.append(string.length)
            string.append(section.string)
        }
        cachedBookText = ReaderBookText(string: string, sectionStarts: starts)
        return cachedBookText
    }

    /// The content document of a section for searching: the built one, else a fresh parse.
    func document(_ index: Int) async -> ContentDocument? {
        if let section = sections[index] { return section.document }
        let publication = publication
        return await Task.detached(priority: .userInitiated) {
            let resource = publication.spine[index].resource
            guard let data = try? publication.data(for: resource) else { return nil }
            return try? ContentDocument.parse(data, path: resource.path)
        }.value
    }

    func close() {
        closed = true
        background?.cancel()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        onSectionBuilt = nil
        onBookComplete = nil
    }

    private func store(_ section: SectionText, typography target: NativeTypography) {
        guard !closed else { return }
        // A build for an older typography never replaces a newer one.
        if let built = builtTypography[section.spineIndex], built == typography, target != typography { return }
        sections[section.spineIndex] = section
        builtTypography[section.spineIndex] = target
        if target == typography { cachedBookText = nil }
        onSectionBuilt?(section.spineIndex)
    }

    private func completeIfReady() {
        guard !closed, isComplete else { return }
        onBookComplete?()
    }
}
