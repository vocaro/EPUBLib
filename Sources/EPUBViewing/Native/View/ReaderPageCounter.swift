import CoreGraphics
import EPUBCore
import Foundation

/// Counts the pages of every section page turns reach at the spread's column size, for
/// `EPUBLayoutPage` (doc/native-viewer.md, "Page numbers").
///
/// A section's pages are the ones `ReaderPaginator` slices it into, the same as the canvas shows
/// it: the section on screen is counted by finishing the canvas's own pagination, and the others
/// with a pagination of their own that is dropped once its pages are counted, so the layout of
/// only one section is held at a time. Counting runs on the main actor, as layout does, for at
/// most `sliceDuration` at a time, and then lets the run loop handle input before it goes on: a
/// page turn waits for one slice at most, never for the count. The section on screen is counted
/// first, then the ones before it, which its index needs, then the rest.
///
/// Counts belong to one column size and to the texts they were made from: a new size drops them,
/// and a section built again (for a new typography) is counted again. A section that is not
/// built, or not built for the current typography, waits until it is (`resume`).
@MainActor final class ReaderPageCounter {
    /// How long counting runs before it lets the run loop handle input. Counting a page can take
    /// longer: a page is never divided between slices.
    var sliceDuration: Duration = .milliseconds(6)
    /// The run loop's turn between slices.
    var pause: Duration = .milliseconds(1)

    weak var canvas: ReaderCanvasView?
    /// Told after a section's count is recorded.
    var onCount: (@MainActor () -> Void)?

    /// The column size counted for.
    private(set) var size: CGSize?
    private struct Count {
        /// Not kept alive by the count: a section built again has another text.
        weak var text: NSAttributedString?
        var pages: Int
    }
    private var counts: [Int: Count] = [:]
    /// A section partly counted with its own pagination, carried from one slice to the next.
    private var partial: (section: Int, paginator: ReaderPaginator)?
    private var task: Task<Void, Never>?
    private var generation = 0
    /// Slices run since the counter was made, for tests.
    private(set) var slices = 0

    /// Whether counting is under way or waiting for its next slice.
    var isCounting: Bool { task != nil }

    /// A section's pages at `size`, if it is counted for that text.
    func pages(inSection section: Int, text: NSAttributedString, size: CGSize) -> Int? {
        guard size == self.size, let count = counts[section], count.text === text else { return nil }
        return count.pages
    }

    /// Counts for `size` from now on, dropping the counts of any other size.
    func count(for size: CGSize) {
        guard size != self.size else { return }
        stop()
        self.size = size
    }

    /// Stops counting and forgets every count, as when the pages go.
    func stop() {
        cancel()
        counts = [:]
        partial = nil
        size = nil
    }

    /// Memory is short: the layout of a section partly counted goes. Its count starts over.
    func trimCaches() {
        partial = nil
    }

    /// Starts counting, or goes on, if anything is left to count; harmless while it runs.
    func resume() {
        guard task == nil, size != nil else { return }
        generation += 1
        let mine = generation
        task = Task { [weak self] in
            await self?.run(mine)
            if let self, self.generation == mine { self.task = nil }
        }
    }

    private func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    private func run(_ mine: Int) async {
        let clock = ContinuousClock()
        while !Task.isCancelled, generation == mine {
            // A canvas out of its window shows no pages; it counts again when it next shows some.
            guard let canvas, canvas.window != nil, let size, canvas.spread?.columnSize == size else { return }
            // A resize's own pagination goes first; the spread on screen keeps these counts.
            if canvas.pendingSpread != nil {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            guard let section = nextSection() else { return }
            slices += 1
            let deadline = clock.now.advanced(by: sliceDuration)
            if advance(section, size: size, until: deadline, clock: clock) { onCount?() }
            try? await Task.sleep(for: pause)
        }
    }

    /// The section to count next: the one on screen, then those page turns reach in reading
    /// order. nil when all that are built for the current typography are counted.
    private func nextSection() -> Int? {
        guard let canvas, let source = canvas.dataSource, let size else { return nil }
        let shown = canvas.shownPage?.section
        let order = (shown.map { [$0] } ?? []) + (0..<source.sectionCount).filter { $0 != shown && source.isLinear(section: $0) }
        return order.first { section in
            guard let text = source.text(forSection: section), source.isCurrent(section: section) else { return false }
            return pages(inSection: section, text: text, size: size) == nil
        }
    }

    /// Paginates `section` on until `deadline`; true once its count is recorded.
    private func advance(_ section: Int, size: CGSize, until deadline: ContinuousClock.Instant,
                         clock: ContinuousClock) -> Bool {
        guard let canvas, let text = canvas.dataSource?.text(forSection: section) else { return false }
        let paginator: ReaderPaginator
        if let cached = canvas.cachedPaginator(for: section, size: size) {
            // The canvas's own, which the section on screen always has: finishing it costs no
            // layout the canvas would not do itself, and releases its layout sooner. One already
            // finished is only read; its count is kept here, for the cache may drop it.
            paginator = cached
        } else if let partial, partial.section == section, partial.paginator.sourceText === text, partial.paginator.size == size {
            paginator = partial.paginator
        } else {
            paginator = ReaderPaginator(text: text, size: size)
            partial = (section, paginator)
        }
        while !paginator.isComplete, clock.now < deadline {
            _ = paginator.advance(toward: .max, pages: 1)
        }
        guard paginator.isComplete else { return false }
        counts[section] = Count(text: text, pages: paginator.pages.count)
        if partial?.section == section { partial = nil }
        return true
    }
}

extension ReaderCanvasView {
    /// The pages on screen in paginated flow (`EPUBReaderStatus.layoutPage`); nil in continuous
    /// scroll, before a spread is shown, and while the section on screen is one kept from an
    /// earlier typography until its rebuild arrives.
    var layoutPage: EPUBLayoutPage? {
        guard configuration.flow == .paginated, let shownPage, let spread, let dataSource,
              dataSource.text(forSection: shownPage.section) != nil, dataSource.isCurrent(section: shownPage.section)
        else { return nil }
        let size = spread.columnSize
        func pages(_ section: Int) -> Int? {
            guard let text = dataSource.text(forSection: section), dataSource.isCurrent(section: section) else { return nil }
            if let paginator = cachedPaginator(for: section, size: size), paginator.isComplete { return paginator.pages.count }
            return pageCounter.pages(inSection: section, text: text, size: size)
        }
        var index: Int? = dataSource.isLinear(section: shownPage.section) ? shownPage.page : nil
        var count: Int? = 0
        for section in 0..<dataSource.sectionCount where dataSource.isLinear(section: section) {
            let sectionPages = pages(section)
            if section < shownPage.section { index = index.flatMap { index in sectionPages.map { index + $0 } } }
            count = count.flatMap { count in sectionPages.map { count + $0 } }
        }
        return EPUBLayoutPage(index: index, count: count, sectionIndex: shownPage.page,
                              sectionCount: pages(shownPage.section),
                              shownCount: max(1, columns.filter { !$0.isHidden }.count))
    }

    /// The data source built a section, or the whole book: what was waiting for it is counted,
    /// and a count it replaced is no longer reported.
    func sectionsDidChange() {
        guard configuration.flow == .paginated, spread != nil else { return }
        pageCounter.resume()
        delegate?.canvasDidChangeLayoutPage(self)
    }

    /// A page key's action: a turn, or the book's start or end, which a key reaches as a host's
    /// `.goToStart` and `.goToEnd` do.
    func performPageActionFromInput(_ action: EPUBPageAction) {
        switch action {
        case .next: turnPageFromInput(forward: true)
        case .previous: turnPageFromInput(forward: false)
        case .bookStart, .bookEnd:
            guard imageInspector == nil, !hasSelection, !isDraggingSelection else { return }
            showBookBoundary(atEnd: action == .bookEnd)
            #if os(macOS)
            focusFirstColumnAfterTurn()
            #endif
        }
    }

    /// Shows the start of the first section page turns reach, or the end of the last: its first
    /// page or its last in paginated flow, the top or the bottom of continuous scroll. A section
    /// that is not built, or that a page turn would wait to have built again for the appearance
    /// on screen (`canShow`, #243), is asked for (`canvas(_:needsSection:forward:)`), which shows
    /// the same once it is.
    @discardableResult func showBookBoundary(atEnd: Bool) -> PageTurnResult {
        guard let dataSource else { return .atBoundary }
        let sections = 0..<dataSource.sectionCount
        guard let section = atEnd ? sections.last(where: { dataSource.isLinear(section: $0) })
                : sections.first(where: { dataSource.isLinear(section: $0) }) else { return .atBoundary }
        guard let text = dataSource.text(forSection: section), dataSource.canShow(section: section) else {
            delegate?.canvas(self, needsSection: section, forward: !atEnd)
            return .pending(section: section)
        }
        show(ReaderTextPosition(section: section, offset: atEnd ? text.length : 0), selecting: nil, entry: .firstLine)
        return .turned
    }
}
