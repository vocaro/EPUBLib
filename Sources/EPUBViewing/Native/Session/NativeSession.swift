import EPUBCore
import EPUBReading
import Foundation
import SwiftUI

/// The native TextKit 2 engine. It keeps the WebKit reader's engine identifier and bookmark
/// format: a CFI names a DOM position, not a renderer state, so every stored bookmark and
/// highlight locator stays valid (`doc/native-viewer.md`).
@MainActor struct NativeEngine: EPUBReaderEngine {
    static let identifier = "org.epubreaderlib.foliate"
    static let bookmarkFormat = "epubcfi-v1"
    var id: String { Self.identifier }
    var rich: any RichContentFactory = PlaceholderRichContent()

    func makeSession(publication: EPUBPublication, selectionAction: EPUBSelectionAction? = nil,
                     onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
        try NativeSession(publication: publication, action: selectionAction, rich: rich, onEvent: onEvent)
    }
}

@MainActor @Observable final class NativeSession: EPUBReaderSession {
    static let passageNotFound = "the cited passage could not be found in this book"
    static let maximumQuoteLength = 4_096
    static let maximumSearchLength = 512

    let capabilities: Set<EPUBReaderCapability> = [
        .navigateHref, .pagination, .scrolling, .typography, .selection, .bookmarks, .locateText,
        .searchHighlight, .highlights,
    ]
    let publication: EPUBPublication
    private(set) var closed = false
    private(set) var style = EPUBReaderStyle()
    /// The host's reserved division, from `View.epubReaderDivision(_:)`.
    var division: CGRect? { didSet { if division != oldValue { applyConfiguration() } } }

    @ObservationIgnored let book: NativeBook
    @ObservationIgnored private let spine: SpineCFIs
    @ObservationIgnored private let progress: NativeProgress
    @ObservationIgnored private let action: EPUBSelectionAction?
    @ObservationIgnored private var onEvent: (@MainActor (EPUBReaderEvent) -> Void)?
    @ObservationIgnored private(set) weak var canvas: ReaderCanvasView?
    @ObservationIgnored private(set) var isReady = false
    @ObservationIgnored private let initialSection: Int
    /// The last visible range the canvas reported.
    @ObservationIgnored private(set) var visibleRange: ReaderTextRange?
    @ObservationIgnored private(set) var lastLocation: EPUBLocation?
    @ObservationIgnored private(set) var selection: ReaderSelection?
    @ObservationIgnored private var navigation = 0
    @ObservationIgnored private var highlights: [EPUBHighlight] = []
    @ObservationIgnored private var unresolvedHighlights: Set<String> = []
    @ObservationIgnored private var searchMatches: [Int: [TextSearch.Match]] = [:]
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var publishedDisclosure: String?
    /// What the canvas was last asked to draw.
    @ObservationIgnored private(set) var drawnHighlights: [ReaderHighlight] = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(publication: EPUBPublication, action: EPUBSelectionAction?, rich: any RichContentFactory,
         onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws {
        self.publication = publication; self.action = action; self.onEvent = onEvent
        do { spine = try SpineCFIs(publication: publication) }
        catch { throw EPUBReaderError.engineFailure("The package document could not be read: \(error)") }
        progress = NativeProgress(publication: publication)
        initialSection = publication.spine.firstIndex(where: \.isLinear) ?? 0
        book = NativeBook(publication: publication, typography: NativeTypography(), rich: rich)
        book.onSectionBuilt = { [weak self] in self?.sectionBuilt($0) }
        book.onBookComplete = { [weak self] in self?.bookCompleted() }
        let first = initialSection
        tasks.append(Task { [weak self] in
            _ = await self?.book.build(first)
            self?.book.buildRemaining(from: first)
        })
    }

    func makeView() -> AnyView { AnyView(NativeSurface(session: self)) }

    func close() {
        guard !closed else { return }
        closed = true
        onEvent = nil
        for task in tasks { task.cancel() }
        tasks.removeAll()
        book.close()
        canvas?.delegate = nil
        canvas?.dataSource = nil
        canvas = nil
    }

    // MARK: - Mounting

    func attach(_ canvas: ReaderCanvasView) {
        guard !closed else { return }
        self.canvas = canvas
        canvas.dataSource = self
        canvas.delegate = self
        applyConfiguration()
        becomeReadyIfPossible()
    }

    func detach(_ canvas: ReaderCanvasView) {
        guard self.canvas === canvas else { return }
        canvas.delegate = nil
        canvas.dataSource = nil
        self.canvas = nil
    }

    private var configuration: ReaderCanvasConfiguration {
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = style.flow
        configuration.isDark = style.isDark
        configuration.isRightToLeft = publication.pageProgression == .rtl
        configuration.division = division
        configuration.selectionActionTitle = action?.title
        configuration.selectionActionImage = action?.systemImage ?? "text.quote"
        return configuration
    }

    private func applyConfiguration() {
        guard let canvas, canvas.configuration != configuration else { return }
        canvas.configuration = configuration
    }

    private func becomeReadyIfPossible() {
        guard !isReady, !closed, let canvas, book.section(initialSection) != nil else { return }
        isReady = true
        emit(.ready)
        publishDisclosure()
        canvas.show(visibleRange?.start ?? ReaderTextPosition(section: initialSection, offset: 0), selecting: nil)
    }

    // MARK: - Commands

    func send(_ command: EPUBReaderCommand) async throws {
        try Task.checkCancellation()
        guard !closed else { throw EPUBReaderError.closed }
        guard isReady, let canvas else { throw EPUBReaderError.notReady }
        switch command {
        case .nextPage: turn(canvas, forward: true)
        case .previousPage: turn(canvas, forward: false)
        case .navigate(let href): try await navigate(href)
        case .restore(let location): try await restore(location)
        case .locate(let text, let highlight): try await locate(text, highlight: highlight)
        case .searchHighlight(let text): try await search(text)
        case .clearSearch:
            searchGeneration += 1
            searchMatches = [:]
            refreshHighlights()
        case .style(let newStyle): try applyStyle(newStyle)
        case .setHighlights(let list): setHighlights(list)
        }
    }

    private func turn(_ canvas: ReaderCanvasView, forward: Bool) {
        navigation += 1
        _ = canvas.turnPage(forward: forward)
    }

    private func navigate(_ href: String) async throws {
        guard !href.isEmpty, !href.hasPrefix("#"), href.count <= 4_096 else {
            throw EPUBReaderError.invalidCommand("Empty publication href")
        }
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = String(parts[0]).removingPercentEncoding,
              publication.resources.contains(where: { $0.path == path }),
              let components = URLComponents(string: href),
              components.scheme == nil, components.host == nil, components.query == nil else {
            throw EPUBReaderError.invalidCommand("Unknown publication href")
        }
        guard let section = publication.spine.firstIndex(where: { $0.resource.path == path }) else {
            throw EPUBReaderError.invalidCommand("Not a section of this publication")
        }
        let fragment = parts.count == 2 ? String(parts[1]).removingPercentEncoding : nil
        let ticket = beginNavigation()
        let text = await book.build(section)
        guard isCurrent(ticket) else { return }
        canvas?.clearSelection()
        canvas?.show(ReaderTextPosition(section: section, offset: fragment.flatMap { text.anchors[$0] } ?? 0), selecting: nil)
    }

    private func isCompatible(_ location: EPUBLocation) -> Bool {
        guard location.publicationID == publication.id, let bookmark = location.bookmark,
              bookmark.engineID == NativeEngine.identifier, bookmark.format == NativeEngine.bookmarkFormat,
              EPUBCFI.isCFI(bookmark.value), bookmark.value.count <= 4_096 else { return false }
        return true
    }

    private func restore(_ location: EPUBLocation) async throws {
        guard isCompatible(location), let cfi = location.bookmark?.value else { throw EPUBReaderError.incompatibleLocation }
        let ticket = beginNavigation()
        guard let range = await resolve(cfi) else {
            emit(.notice("the saved position could not be found in this book"))
            return
        }
        guard isCurrent(ticket) else { return }
        canvas?.clearSelection()
        canvas?.show(range.start, selecting: nil)
    }

    /// A full CFI as a rendered range in one section, building that section if needed.
    private func resolve(_ cfi: String) async -> ReaderTextRange? {
        guard let target = spine.resolve(cfi), book.publication.spine.indices.contains(target.spineIndex) else { return nil }
        let text = await book.build(target.spineIndex)
        return range(of: target.localPath, in: text)
    }

    private func range(of localPath: String, in text: SectionText) -> ReaderTextRange? {
        guard let dom = EPUBCFI.resolve(localPath: localPath, in: text.document) else { return nil }
        let start = text.map.location(of: dom.start)
        let end = max(start, text.map.location(of: dom.end))
        return ReaderTextRange(section: text.spineIndex, start..<end)
    }

    private func locate(_ text: String, highlight: Bool) async throws {
        let quote = TextSearch.normalizeQuote(text)
        guard !quote.isEmpty, text.count <= Self.maximumQuoteLength else {
            throw EPUBReaderError.invalidCommand("The passage to locate is empty or too long")
        }
        let ticket = beginNavigation()
        searchGeneration += 1
        searchMatches = [:]
        refreshHighlights()
        for index in publication.spine.indices {
            guard isCurrent(ticket), !closed else { return }
            guard let match = await firstMatch(of: quote, inSection: index) else { continue }
            let section = await book.build(index)
            guard isCurrent(ticket) else { return }
            let start = section.map.location(of: match.start)
            let end = max(start, section.map.location(of: match.end))
            let range = ReaderTextRange(section: index, start..<end)
            canvas?.clearSelection()
            canvas?.show(range.start, selecting: highlight ? range : nil)
            return
        }
        if isCurrent(ticket) { emit(.notice(Self.passageNotFound)) }
    }

    private func language(of document: ContentDocument) -> String? {
        document.language ?? publication.metadata.languages.first
    }

    private func firstMatch(of quote: String, inSection index: Int) async -> TextSearch.Match? {
        guard let document = await book.document(index) else { return nil }
        let locale = language(of: document)
        return await Task.detached(priority: .userInitiated) {
            TextSearch.matches(of: quote, in: document, locale: locale, limit: 1).first
        }.value
    }

    private func search(_ text: String) async throws {
        let query = TextSearch.normalizeQuote(text)
        guard !query.isEmpty, text.count <= Self.maximumSearchLength else {
            throw EPUBReaderError.invalidCommand("The search text is empty or too long")
        }
        searchMatches = [:]
        searchGeneration += 1
        let ticket = searchGeneration
        var found: [Int: [TextSearch.Match]] = [:]
        for index in publication.spine.indices {
            guard !closed, ticket == searchGeneration else { return }
            guard let document = await book.document(index) else { continue }
            let locale = language(of: document)
            let matches = await Task.detached(priority: .userInitiated) {
                TextSearch.matches(of: query, in: document, locale: locale, limit: 10_000)
            }.value
            if !matches.isEmpty { found[index] = matches }
        }
        guard !closed, ticket == searchGeneration else { return }
        searchMatches = found
        refreshHighlights()
    }

    private func applyStyle(_ newStyle: EPUBReaderStyle) throws {
        guard newStyle.fontSize.isFinite else { throw EPUBReaderError.invalidCommand("Nonfinite font size") }
        let previous = style
        style = newStyle
        if newStyle.flow != previous.flow || newStyle.isDark != previous.isDark { applyConfiguration() }
        let typography = NativeTypography(fontSize: newStyle.fontSize, isDark: newStyle.isDark)
        if typography != book.typography {
            book.setTypography(typography)
            let current = visibleRange?.start.section ?? initialSection
            tasks.append(Task { [weak self] in
                _ = await self?.book.build(current)
                self?.book.buildRemaining(from: current)
            })
        }
    }

    private func setHighlights(_ list: [EPUBHighlight]) {
        highlights = list.filter { isCompatible($0.location) }
        for rejected in list where !isCompatible(rejected.location) {
            emit(.notice("a highlight belongs to another book or reader and was not drawn: \(rejected.id)"))
        }
        unresolvedHighlights = []
        refreshHighlights()
    }

    // MARK: - Navigation tickets

    private func beginNavigation() -> Int { navigation += 1; return navigation }
    private func isCurrent(_ ticket: Int) -> Bool { ticket == navigation && !closed }

    // MARK: - Highlights

    private func refreshHighlights() {
        guard let canvas else { return }
        var drawn: [ReaderHighlight] = []
        for (index, matches) in searchMatches {
            guard let section = book.section(index) else { continue }
            for (number, match) in matches.enumerated() {
                let start = section.map.location(of: match.start)
                let end = max(start, section.map.location(of: match.end))
                guard end > start else { continue }
                drawn.append(ReaderHighlight(id: "search-\(index)-\(number)", range: ReaderTextRange(section: index, start..<end), kind: .search))
            }
        }
        for highlight in highlights {
            guard let cfi = highlight.location.bookmark?.value, let target = spine.resolve(cfi) else {
                reportUnresolved(highlight); continue
            }
            guard let section = book.section(target.spineIndex) else { continue } // drawn once built
            guard let range = range(of: target.localPath, in: section), !range.isEmpty else {
                reportUnresolved(highlight); continue
            }
            drawn.append(ReaderHighlight(id: highlight.id, range: range, kind: .annotation))
        }
        drawnHighlights = drawn
        canvas.setHighlights(drawn)
    }

    private func reportUnresolved(_ highlight: EPUBHighlight) {
        guard unresolvedHighlights.insert(highlight.id).inserted else { return }
        emit(.notice("a highlight's passage could not be found in this book: \(highlight.id)"))
    }

    // MARK: - Book callbacks

    private func sectionBuilt(_ index: Int) {
        guard !closed else { return }
        if !isReady { becomeReadyIfPossible(); return }
        publishDisclosure()
        if visibleRange?.start.section == index || visibleRange?.end.section == index, book.isCurrent(index) {
            canvas?.reloadContent(keeping: nil)
        }
        if !searchMatches.isEmpty || !highlights.isEmpty { refreshHighlights() }
    }

    private func bookCompleted() {
        guard isReady, !closed else { return }
        publishDisclosure()
        if style.flow == .scrolled { canvas?.reloadContent(keeping: nil) }
        if !searchMatches.isEmpty || !highlights.isEmpty { refreshHighlights() }
    }

    private func publishDisclosure() {
        var report = SectionReport()
        for index in publication.spine.indices { if let section = book.section(index) { report.formUnion(section.report) } }
        let text = NativeDisclosure.text(for: report)
        guard isReady, let text, text != publishedDisclosure else { return }
        publishedDisclosure = text
        emit(.disclosure(text))
    }

    // MARK: - Events

    private func emit(_ event: EPUBReaderEvent) { if !closed { onEvent?(event) } }

    /// The engine bookmark for a rendered range within one section (foliate `getCFI`).
    private func cfi(for range: ReaderTextRange) -> String? {
        guard let section = book.section(range.start.section) else { return nil }
        let endOffset = range.end.section == range.start.section ? range.end.offset : section.string.length
        guard let start = section.map.position(at: range.start.offset, in: section.document),
              let end = endOffset > range.start.offset
                ? section.map.endPosition(at: endOffset, in: section.document) : start else {
            return spine.bases[range.start.section]
        }
        return spine.cfi(spineIndex: range.start.section, start: start, end: end, in: section.document)
    }

    private func location(for range: ReaderTextRange, fraction: Double?, quote: String? = nil) -> EPUBLocation {
        let index = range.start.section
        let cfi = cfi(for: range)
        return EPUBLocation(
            publicationID: publication.id, href: publication.spine[index].resource.href,
            progression: fraction.flatMap { progress.progression(section: index, fraction: $0) },
            title: fraction == nil ? nil : progress.title(at: range.start) { [book] section, fragment in
                book.section(section)?.anchors[fragment]
            },
            quote: quote,
            bookmark: cfi.map { EPUBEngineBookmark(engineID: NativeEngine.identifier, format: NativeEngine.bookmarkFormat, value: $0) })
    }

    fileprivate func performSelectionAction() {
        guard !closed, let selection, let action else { return }
        action.perform(EPUBSelection(text: selection.text, location: location(for: selection.range, fraction: nil, quote: selection.text)))
    }
}

extension NativeSession: ReaderCanvasDataSource {
    var sectionCount: Int { book.count }
    func text(forSection index: Int) -> NSAttributedString? { book.section(index)?.string }
    func isLinear(section index: Int) -> Bool { publication.spine[index].isLinear }
    var bookText: ReaderBookText? { book.bookText }
}

extension NativeSession: ReaderCanvasDelegate {
    func canvas(_ canvas: any ReaderCanvas, didShow range: ReaderTextRange, sectionProgress: Double) {
        visibleRange = range
        guard isReady, !closed else { return }
        let location = location(for: range, fraction: sectionProgress)
        guard location != lastLocation else { return }
        lastLocation = location
        emit(.relocated(location))
    }

    func canvas(_ canvas: any ReaderCanvas, didChangeSelection selection: ReaderSelection?) {
        guard selection != self.selection else { return }
        self.selection = selection
        guard isReady else { return }
        guard let selection, !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            emit(.selectionChanged(nil)); return
        }
        emit(.selectionChanged(EPUBSelection(text: selection.text,
            location: location(for: selection.range, fraction: nil, quote: selection.text))))
    }

    func canvasDidRequestSelectionAction(_ canvas: any ReaderCanvas) { performSelectionAction() }

    func canvas(_ canvas: any ReaderCanvas, didActivate link: ReaderLink, at position: ReaderTextPosition, rect: CGRect) {
        guard isReady, !closed else { return }
        switch link {
        case .external:
            emit(.notice("This reader does not open links outside the book."))
        case .internal(let href):
            Task { try? await navigate(href) }
        case .note(let href):
            Task {
                if let note = await noteContent(href) { self.canvas?.presentNote(note, from: rect) }
                else { try? await navigate(href) }
            }
        }
    }

    func canvas(_ canvas: any ReaderCanvas, needsSection index: Int, forward: Bool) {
        let ticket = beginNavigation()
        tasks.append(Task { [weak self] in
            guard let text = await self?.book.build(index), let self, self.isCurrent(ticket) else { return }
            self.canvas?.show(ReaderTextPosition(section: index, offset: forward ? 0 : text.string.length), selecting: nil)
        })
    }

    private func noteContent(_ href: String) async -> NSAttributedString? {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let path = String(parts[0]).removingPercentEncoding,
              let fragment = String(parts[1]).removingPercentEncoding,
              let index = publication.spine.firstIndex(where: { $0.resource.path == path }) else { return nil }
        return await book.build(index).notes[fragment]
    }
}

/// The session's SwiftUI view: the TextKit 2 canvas plus the paginated tap zones, page-turn keys
/// and accessibility actions, as the WebKit reader's surface had them.
private struct NativeSurface: View {
    let session: NativeSession
    @Environment(\.epubReaderDivision) private var division

    var body: some View {
        if !session.closed {
            ZStack {
                NativeCanvasHost(session: session)
                if session.style.flow == .paginated {
                    HStack(spacing: 0) {
                        zone(isLeading: true)
                        Spacer(minLength: 0)
                        zone(isLeading: false)
                    }
                }
            }
            .onAppear { session.division = division }
            .onChange(of: division) { session.division = division }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .pageUp, .pageDown, .space]) { press in
                guard let command = ReaderEPUBPageTurnKey.command(for: press.key, hasShift: press.modifiers.contains(.shift)) else { return .ignored }
                submit(command == .next ? .nextPage : .previousPage)
                return .handled
            }
            .accessibilityScrollAction { edge in
                if edge == .leading { submit(.previousPage) }
                if edge == .trailing { submit(.nextPage) }
            }
            .accessibilityAction(named: Text("Next Page")) { submit(.nextPage) }
            .accessibilityAction(named: Text("Previous Page")) { submit(.previousPage) }
        }
    }

    /// The leading zone turns back, mirrored for right-to-left page progression.
    private func zone(isLeading: Bool) -> some View {
        let rtl = session.publication.pageProgression == .rtl
        return Color.clear.frame(width: 56).contentShape(Rectangle())
            .onTapGesture { submit(isLeading != rtl ? .previousPage : .nextPage) }
            .accessibilityHidden(true)
    }

    private func submit(_ command: EPUBReaderCommand) {
        Task { @MainActor in try? await session.send(command) }
    }
}

#if os(iOS)
private struct NativeCanvasHost: UIViewRepresentable {
    let session: NativeSession
    func makeUIView(context: Context) -> ReaderCanvasView {
        let canvas = ReaderCanvasView(frame: .zero)
        session.attach(canvas)
        return canvas
    }
    func updateUIView(_ canvas: ReaderCanvasView, context: Context) {}
    static func dismantleUIView(_ canvas: ReaderCanvasView, coordinator: ()) {
        (canvas.dataSource as? NativeSession)?.detach(canvas)
    }
}
#elseif os(macOS)
private struct NativeCanvasHost: NSViewRepresentable {
    let session: NativeSession
    func makeNSView(context: Context) -> ReaderCanvasView {
        let canvas = ReaderCanvasView(frame: .zero)
        session.attach(canvas)
        return canvas
    }
    func updateNSView(_ canvas: ReaderCanvasView, context: Context) {}
    static func dismantleNSView(_ canvas: ReaderCanvasView, coordinator: ()) {
        (canvas.dataSource as? NativeSession)?.detach(canvas)
    }
}
#endif
