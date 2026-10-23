import EPUBCore
import EPUBReading
import Foundation
import SwiftUI

/// The native TextKit 2 engine. Its identifier and bookmark format name EPUBLib, not a
/// renderer, so they survive any change of how pages are drawn (`doc/native-viewer.md`).
@MainActor struct NativeEngine: EPUBReaderEngine {
    static let identifier = "org.epublib.reader"
    /// An EPUB CFI, generated and resolved as `EPUBCFI` does.
    static let bookmarkFormat = "epublib-cfi-v1"
    var id: String { Self.identifier }
    var rich: any RichContentFactory = NativeRichContent()

    func makeSession(publication: EPUBPublication, selectionAction: EPUBSelectionAction? = nil,
                     onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
        try NativeSession(publication: publication, action: selectionAction, rich: rich, onEvent: onEvent)
    }
}

@MainActor @Observable final class NativeSession: EPUBReaderSession {
    static let passageNotFound = "the cited passage could not be found in this book"
    static let maximumQuoteLength = 4_096
    static let maximumSearchLength = 512
    /// What a link outside the book says when the host has turned links outside it off.
    static let externalLinkRefused = "This reader does not open links outside the book."
    /// What a link outside the book says that is not to a web page or an email address.
    static let externalSchemeRefused = "This reader opens only web and email links outside the book."
    /// Matches read from one section. A section holding more draws and lists only these.
    nonisolated static let maximumSectionMatches = 10_000

    let capabilities: Set<EPUBReaderCapability> = [
        .navigateHref, .pagination, .scrolling, .typography, .selection, .bookmarks, .locateText,
        .search, .searchHighlight, .searchResults, .highlights,
        .goToProgression,
    ]
    let publication: EPUBPublication
    let readerState: EPUBReaderState?
    private(set) var closed = false
    private(set) var style = EPUBReaderStyle()
    @ObservationIgnored private(set) var systemIsDark = false
    /// The mounted view's Dynamic Type size, kept while the style does not follow it.
    @ObservationIgnored private(set) var systemTextSize: DynamicTypeSize = .large
    /// What the style's font size is multiplied by before it is drawn (`followsDynamicType`).
    private var dynamicTypeScale: CGFloat {
        style.followsDynamicType ? NativeTypography.dynamicTypeScale(for: systemTextSize) : 1
    }
    /// The system's Increase Contrast and Bold Text, as the mounted view's environment has them.
    @ObservationIgnored private(set) var systemIncreasesContrast = false
    @ObservationIgnored private(set) var systemBoldText = false
    /// The colours the reader draws with: the style's theme, as Increase Contrast leaves it.
    private var effectiveTheme: ReaderTheme {
        ReaderTheme(style.colors(systemIsDark: systemIsDark), increasesContrast: systemIncreasesContrast)
    }
    /// The host's reserved division, from `View.epubReaderDivision(_:)`.
    var division: CGRect? { didSet { if division != oldValue { applyConfiguration() } } }

    var pageControls = EPUBPageControls() { didSet { if pageControls != oldValue { applyConfiguration() } } }
    /// The host's controls that the reader hides and shows, from `View.epubReaderHidesControls`.
    var controlsHiding: EPUBReaderControlsHiding? { didSet { if controlsHiding != oldValue { applyConfiguration() } } }

    @ObservationIgnored let book: NativeBook
    @ObservationIgnored private let spine: SpineCFIs
    @ObservationIgnored private let progress: NativeProgress
    @ObservationIgnored private let action: EPUBSelectionAction?
    @ObservationIgnored private var onEvent: (@MainActor (EPUBReaderEvent) -> Void)?
    @ObservationIgnored private(set) weak var canvas: ReaderCanvasView?
    @ObservationIgnored private(set) var isReady = false
    /// Where the book opens: its text start, else its first linear section (`openingTarget`).
    @ObservationIgnored private let initialSection: Int
    @ObservationIgnored private let initialFragment: String?
    /// The last visible range the canvas reported.
    @ObservationIgnored private(set) var visibleRange: ReaderTextRange?
    @ObservationIgnored private(set) var lastLocation: EPUBLocation?
    @ObservationIgnored private(set) var selection: ReaderSelection?
    @ObservationIgnored private var navigation = 0
    /// How often the page on screen has changed, by a move from anywhere (a key, a click or tap,
    /// a swipe, the wheel, VoiceOver, a command) or a relayout. A page turn or search result that
    /// waits for a build is dropped if the page has changed since it was asked for.
    @ObservationIgnored private var pageChanges = 0
    @ObservationIgnored private var highlights: [EPUBHighlight] = []
    @ObservationIgnored private var unresolvedHighlights: Set<String> = []
    @ObservationIgnored private var searchMatches: [Int: [TextSearch.Match]] = [:]
    @ObservationIgnored private var searchGeneration = 0
    /// Rendered ranges never change with typography, so each is computed once, when its
    /// section first exists: search matches by section, host highlights by id.
    @ObservationIgnored private var searchRanges: [Int: [ReaderTextRange]] = [:]
    /// The completed search's public results, as last published, and where each is shown:
    /// `searchResultRanges[i]` belongs to `results[i]`. nil while no search is complete.
    @ObservationIgnored private(set) var searchResults: EPUBSearchResults?
    @ObservationIgnored private(set) var searchResultRanges: [ReaderTextRange] = []
    /// The most results one search lists; a query with more reports `isTruncated`.
    @ObservationIgnored var maximumSearchResults = 10_000
    @ObservationIgnored private var highlightTargets: [String: [(spineIndex: Int, localPath: String)]] = [:]
    @ObservationIgnored private var highlightRanges: [String: [ReaderTextRange]] = [:]
    @ObservationIgnored private var publishedDisclosure: String?
    /// What the canvas was last asked to draw.
    @ObservationIgnored private(set) var drawnHighlights: [ReaderHighlight] = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// What an activated link outside the book does: the mounted view's
    /// `epubReaderExternalLinks(_:)` (`takeLinkSettings`).
    @ObservationIgnored var externalLinks = EPUBExternalLinks.ask
    /// Opens a link outside the book once the reader has said to: the mounted view's `openURL`
    /// action. nil until a view is mounted, and then a link is refused rather than asked about.
    @ObservationIgnored var openURL: (@MainActor (URL) -> Void)?
    /// The link outside the book the reader is being asked about, until it answers.
    @ObservationIgnored private(set) var askedLink: ExternalLinkAddress?

    init(publication: EPUBPublication, action: EPUBSelectionAction?, rich: any RichContentFactory,
         onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws {
        self.publication = publication; self.action = action; self.onEvent = onEvent
        readerState = EPUBReaderState(status: EPUBReaderStatus(capabilities: capabilities))
        do { spine = try SpineCFIs(publication: publication) }
        catch { throw EPUBReaderError.engineFailure("The package document could not be read: \(error)") }
        progress = NativeProgress(publication: publication)
        (initialSection, initialFragment) = Self.openingTarget(of: publication)
        book = NativeBook(publication: publication, typography: NativeTypography(), rich: rich)
        readerState?.modify { $0.effectiveFontSize = Double(book.typography.fontSize) }
        book.onSectionBuilt = { [weak self] in self?.sectionBuilt($0) }
        book.onBookComplete = { [weak self] in self?.bookCompleted() }
        buildBook(from: initialSection)
    }

    func makeView() -> AnyView { AnyView(NativeSurface(session: self)) }

    func close() {
        guard !closed else { return }
        closed = true
        readerState?.modify { $0.lifecycle = .closed; $0.search = .idle; $0.searchResults = nil }
        searchResults = nil
        searchResultRanges = []
        onEvent = nil
        for task in tasks { task.cancel() }
        tasks.removeAll()
        book.close()
        canvas?.withdrawLinkQuestion()
        canvas?.delegate = nil
        canvas?.dataSource = nil
        canvas?.releaseContent()
        canvas = nil
    }

    // MARK: - Mounting

    func attach(_ canvas: ReaderCanvasView) {
        guard !closed else { return }
        self.canvas = canvas
        canvas.dataSource = self
        canvas.delegate = self
        applyConfiguration()
        if isReady {
            readerState?.modify { $0.lifecycle = .ready }
            // A new view for a session already reading: the same place, the same highlights.
            canvas.show(visibleRange?.start ?? initialPosition, selecting: nil)
            refreshHighlights()
        } else {
            // Never inside SwiftUI's view update, where a host's state change in `onEvent` is undefined.
            Task { @MainActor [weak self] in self?.becomeReadyIfPossible() }
        }
    }

    func detach(_ canvas: ReaderCanvasView) {
        guard self.canvas === canvas else { return }
        canvas.withdrawLinkQuestion()
        canvas.delegate = nil
        canvas.dataSource = nil
        canvas.releaseContent()
        self.canvas = nil
        if !closed { readerState?.modify { $0.lifecycle = .loading; $0.layoutPage = nil } }
    }

    private var configuration: ReaderCanvasConfiguration {
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = style.flow
        configuration.theme = shownTheme
        configuration.isRightToLeft = publication.pageProgression == .rtl
        configuration.division = division
        configuration.pageMargins = style.typography.pageMargins.map { $0.isFinite ? min(max(CGFloat($0), 0), 4) : 1 } ?? 1
        configuration.pageControls = pageControls
        configuration.selectionActionTitle = action?.title
        configuration.selectionActionImage = action?.systemImage ?? "text.quote"
        configuration.togglesControls = controlsHiding?.controls != nil
        return configuration
    }

    /// The theme of the text on screen, which the canvas draws in, so a page's text and its
    /// background never disagree (#243): Light and Dark, and as much Sepia, Black, custom colours
    /// and Increase Contrast (#674). After a change of theme the canvas keeps the old one until
    /// it shows text built for the new (`showNewAppearanceIfReady`), and from then on shows no
    /// text built for the old (`canShow`). An empty canvas takes the one asked for.
    private var shownTheme: ReaderTheme {
        guard isReady, let canvas else { return effectiveTheme }
        guard let shown = canvas.shownText else {
            // The section about to be shown, as its newest build has it.
            return book.typography(ofSection: visibleRange?.start.section ?? initialSection)?.theme ?? effectiveTheme
        }
        // Text a newer build has replaced stays on screen, in the canvas's theme, until the
        // canvas is given the newer: a section's, or continuous scroll's whole book.
        if let section = shown.section {
            guard shown.text === book.section(section)?.string, let built = book.typography(ofSection: section) else {
                return canvas.configuration.theme
            }
            return built.theme
        }
        return shown.text === book.bookText?.string ? book.typography.theme : canvas.configuration.theme
    }

    /// After a change of appearance or theme the canvas keeps the old one until the sections on
    /// screen, and those one page turn reaches from it, are built for the new. The page and the
    /// canvas then change together, once, and the next turns need not wait for a build.
    private func showNewAppearanceIfReady() {
        guard isReady, let canvas, let range = visibleRange, shownTheme != book.typography.theme,
              sections(inReachOf: range).allSatisfy(book.isCurrent) else { return }
        canvas.reloadContent(keeping: nil)
        applyConfiguration()
    }

    /// The sections `range` shows and those one page turn takes it to: the linear section before
    /// a section's first page and after its last, and in continuous scroll on each side.
    private func sections(inReachOf range: ReaderTextRange) -> [Int] {
        var sections = Array(range.start.section...max(range.start.section, range.end.section))
        let scrolled = style.flow == .scrolled
        if scrolled || range.start.offset == 0,
           let previous = stride(from: range.start.section - 1, through: 0, by: -1).first(where: { !book.isOmitted($0) }) {
            sections.append(previous)
        }
        if scrolled || range.end.offset >= book.section(range.end.section)?.string.length ?? 0,
           let next = stride(from: range.end.section + 1, to: book.count, by: 1).first(where: { !book.isOmitted($0) }) {
            sections.append(next)
        }
        return sections
    }

    private func applyConfiguration() {
        guard let canvas, canvas.configuration != configuration else { return }
        canvas.configuration = configuration
    }

    /// The opening page waits for text built for the appearance asked for: a host reports Dark
    /// on appearing, which can be after the first build, made for Light, is in.
    private func becomeReadyIfPossible() {
        guard !isReady, !closed, let canvas, book.isCurrent(initialSection) else { return }
        isReady = true
        emit(.ready)
        publishDisclosure()
        canvas.show(visibleRange?.start ?? initialPosition, selecting: nil)
    }

    /// The opening position, once its section is built. A `.restore` after `.ready` replaces it.
    private var initialPosition: ReaderTextPosition {
        ReaderTextPosition(section: initialSection,
                           offset: initialFragment.flatMap { book.section(initialSection)?.anchors[$0] } ?? 0)
    }

    /// Where a book opens when nothing is restored, as foliate-js's `goToTextStart()` chose: the
    /// first landmark typed `bodymatter` or `text` (`EPUBPublication.landmarks`, the navigation
    /// document's or else the guide's), resolved as `.navigate(href:)` resolves an href, else
    /// the first linear section.
    static func openingTarget(of publication: EPUBPublication) -> (section: Int, fragment: String?) {
        let textStart = publication.landmarks.first { $0.types.contains("bodymatter") || $0.types.contains("text") }
        if let href = textStart?.href, let target = try? target(of: href, in: publication) { return target }
        return (publication.spine.firstIndex(where: \.isLinear) ?? 0, nil)
    }

    // MARK: - Commands

    func send(_ command: EPUBReaderCommand) async throws {
        try Task.checkCancellation()
        guard !closed else { throw EPUBReaderError.closed }
        guard isReady, let canvas else { throw EPUBReaderError.notReady }
        readerState?.modify { $0.activeCommands += 1 }
        defer { readerState?.modify { $0.activeCommands -= 1 } }
        switch command {
        case .nextPage: turn(canvas, forward: true)
        case .previousPage: turn(canvas, forward: false)
        case .navigate(let href): try await navigate(href)
        case .restore(let location): try await restore(location)
        case .locate(let text, let highlight): try await locate(text, highlight: highlight)
        case .search(let text), .searchHighlight(let text):
            let navigateToMatch: Bool
            if case .search = command { navigateToMatch = true } else { navigateToMatch = false }
            do { try await search(text, navigateToMatch: navigateToMatch) }
            catch let error as EPUBReaderError {
                searchGeneration += 1
                // The earlier query's matches stay drawn; its results and current match do not.
                if withdrawSearchResults() { drawCurrentSearchResult() }
                emit(.searchChanged(.failed(query: text, error: error)))
                throw error
            }
        case .clearSearch:
            searchGeneration += 1
            searchMatches = [:]
            searchRanges = [:]
            withdrawSearchResults()
            refreshHighlights()
            emit(.searchChanged(.idle))
        case .nextSearchResult: await stepSearchResult(forward: true)
        case .previousSearchResult: await stepSearchResult(forward: false)
        case .showSearchResult(let result): try await showSearchResult(result)
        case .style(let newStyle): try applyStyle(newStyle)
        case .setHighlights(let list): setHighlights(list)
        case .goToProgression(let progression): try await go(toProgression: progression)
        }
    }

    /// Shows the place `progression` of the way through the book, as `EPUBLocation.progression`
    /// measures it (`NativeProgress.target(progression:isShown:)`). The page is entered at its
    /// first line, as after a page turn: the place asked for is a fraction, not a passage.
    private func go(toProgression progression: Double) async throws {
        guard progression.isFinite else { throw EPUBReaderError.invalidCommand("The progression is not a finite number") }
        guard let target = progress.target(progression: progression, isShown: { [book] in !book.isOmitted($0) }) else { return }
        let ticket = beginNavigation()
        let text = await book.build(target.section)
        guard isCurrent(ticket) else { return }
        let length = text.string.length
        let offset = target.fraction >= 1 ? length : min(length, Int((Double(length) * target.fraction).rounded(.down)))
        canvas?.clearSelection()
        canvas?.show(ReaderTextPosition(section: target.section, offset: offset), selecting: nil, entry: .firstLine)
    }

    private func turn(_ canvas: ReaderCanvasView, forward: Bool) {
        navigation += 1
        _ = canvas.turnPage(forward: forward)
    }

    /// The spine section and decoded fragment an encoded publication href names, for
    /// `.navigate(href:)`, the text start and the controls' current contents entry alike. An
    /// empty fragment is none: `#` is the top of the document, whatever carries an empty id.
    static func target(of href: String, in publication: EPUBPublication) throws -> (section: Int, fragment: String?) {
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
        guard let section = NativeFallbacks.spineIndex(for: path, in: publication) else {
            throw EPUBReaderError.invalidCommand("Not a section of this publication")
        }
        let fragment = parts.count == 2 ? String(parts[1]).removingPercentEncoding : nil
        return (section, fragment?.isEmpty == false ? fragment : nil)
    }

    private func navigate(_ href: String) async throws {
        let (section, fragment) = try Self.target(of: href, in: publication)
        let ticket = beginNavigation()
        let text = await book.build(section)
        guard isCurrent(ticket) else { return }
        showNavigationTarget(text, fragment: fragment)
    }

    /// Shows an already built navigation target, after its caller checks its navigation ticket.
    private func showNavigationTarget(_ text: SectionText, fragment: String?) {
        canvas?.clearSelection()
        let position = fragment.flatMap(text.document.element(id:))
            .map { text.renderedPosition(DOMPosition($0, 0)) }
            ?? ReaderTextPosition(section: text.spineIndex, offset: fragment.flatMap { text.anchors[$0] } ?? 0)
        canvas?.show(position, selecting: nil)
    }

    /// The legacy bookmark remains the first segment. Reject contradictory or foreign ranges
    /// rather than silently restoring only part of a saved selection. A location saved in this
    /// book carries one of its `publicationIDs`: its `persistentID`, which a copy downloaded or
    /// zipped again, edited in its metadata or unpacked into a folder shares, or its `id` (#679).
    private func isCompatible(_ location: EPUBLocation) -> Bool {
        guard publication.publicationIDs.contains(location.publicationID), let bookmark = location.bookmark else { return false }
        let bookmarks = location.rangeBookmarks ?? [bookmark]
        guard !bookmarks.isEmpty, bookmarks.first == bookmark else { return false }
        return bookmarks.allSatisfy {
            $0.engineID == NativeEngine.identifier && $0.format == NativeEngine.bookmarkFormat
                && EPUBCFI.isWellFormed($0.value)
        }
    }

    private func targets(for location: EPUBLocation) -> [(spineIndex: Int, localPath: String)]? {
        guard isCompatible(location), let bookmark = location.bookmark else { return nil }
        let bookmarks = location.rangeBookmarks ?? [bookmark]
        var targets: [(spineIndex: Int, localPath: String)] = []
        for bookmark in bookmarks {
            guard let target = spine.resolve(bookmark.value), publication.spine.indices.contains(target.spineIndex),
                  targets.last.map({ $0.spineIndex < target.spineIndex }) ?? true else { return nil }
            targets.append(target)
        }
        // A multi-section range follows continuous-scroll order and never includes a nonlinear
        // section, even when it lies between the endpoints in the package's spine.
        if targets.count > 1, targets.contains(where: { book.isOmitted($0.spineIndex) }) { return nil }
        return targets
    }

    private func restore(_ location: EPUBLocation) async throws {
        guard isCompatible(location) else { throw EPUBReaderError.incompatibleLocation }
        let ticket = beginNavigation()
        guard let targets = targets(for: location) else {
            emit(.notice("the saved position could not be found in this book"))
            return
        }
        var ranges: [ReaderTextRange] = []
        for target in targets {
            let section = await book.build(target.spineIndex)
            guard isCurrent(ticket) else { return }
            guard let range = range(of: target.localPath, in: section), targets.count == 1 || !range.isEmpty else {
                emit(.notice("the saved position could not be found in this book"))
                return
            }
            ranges.append(range)
        }
        guard isCurrent(ticket) else { return }
        guard let range = ranges.first else {
            emit(.notice("the saved position could not be found in this book"))
            return
        }
        canvas?.clearSelection()
        canvas?.show(range.start, selecting: nil)
    }

    private func range(of localPath: String, in text: SectionText) -> ReaderTextRange? {
        guard text.document.canResolveCFIs else { return nil }
        // A bare spine-item CFI, which a section with no mapped text produces, names its start.
        if localPath.isEmpty { return ReaderTextRange(section: text.spineIndex, 0..<0) }
        guard let dom = EPUBCFI.resolve(localPath: localPath, in: text.document) else { return nil }
        return range(from: dom.start, to: dom.end, in: text)
    }

    /// A search match's rendered range, the one its result is listed and shown at.
    private func range(of match: TextSearch.Match, in text: SectionText) -> ReaderTextRange {
        SearchResultBuilder.renderedRange(of: match, in: text)
    }

    private func range(from start: DOMPosition, to end: DOMPosition, in text: SectionText) -> ReaderTextRange {
        return ReaderTextRange(start: text.renderedPosition(start), end: text.renderedPosition(end, isEnd: true))
    }

    private func locate(_ text: String, highlight: Bool) async throws {
        let quote = TextSearch.normalizeQuote(text)
        guard !quote.isEmpty, text.count <= Self.maximumQuoteLength else {
            throw EPUBReaderError.invalidCommand("The passage to locate is empty or too long")
        }
        let ticket = beginNavigation()
        searchGeneration += 1
        searchMatches = [:]
        searchRanges = [:]
        withdrawSearchResults()
        refreshHighlights()
        emit(.searchChanged(.idle))
        // A match inside content that renders nothing of its own (a hidden footnote), or that
        // takes in text `visibility: hidden` hides, is a place to go, not a passage to select;
        // one that renders and shows, as a search result does, is preferred.
        var hidden: ReaderTextPosition?
        for index in publication.spine.indices {
            guard isCurrent(ticket), !closed else { return }
            let matches = await matches(of: quote, inSection: index, limit: 64)
            guard !matches.isEmpty else { continue }
            let section = await book.build(index)
            guard isCurrent(ticket) else { return }
            for match in matches {
                let range = range(of: match, in: section)
                guard !SearchResultBuilder.isListed(range, in: section) else {
                    canvas?.clearSelection()
                    canvas?.show(range.start, selecting: highlight ? range : nil)
                    return
                }
                if hidden == nil { hidden = range.start }
            }
        }
        guard isCurrent(ticket) else { return }
        if let hidden {
            canvas?.clearSelection()
            canvas?.show(hidden, selecting: nil)
        } else { emit(.notice(Self.passageNotFound)) }
    }

    /// The locale foliate-js searched in, so a quote matches as it did before.
    private func language(of document: ContentDocument) -> String? { TextSearch.locale(of: document) }

    private func matches(of quote: String, inSection index: Int, limit: Int) async -> [TextSearch.Match] {
        guard let document = await book.document(index) else { return [] }
        let locale = language(of: document)
        return await Task.detached(priority: .userInitiated) {
            TextSearch.matches(of: quote, in: document, locale: locale, limit: limit)
        }.value
    }

    private func search(_ text: String, navigateToMatch: Bool) async throws {
        let query = TextSearch.normalizeQuote(text)
        guard !query.isEmpty, text.count <= Self.maximumSearchLength else {
            throw EPUBReaderError.invalidCommand("The search text is empty or too long")
        }
        let navigationTicket = navigateToMatch ? beginNavigation() : nil
        withdrawSearchResults()
        emit(.searchChanged(.searching(query: text)))
        searchMatches = [:]
        searchRanges = [:]
        refreshHighlights()
        searchGeneration += 1
        let ticket = searchGeneration
        // A cancellation ends a pending search. One that arrives with the results, from an
        // observer or a callback, comes too late: the search completes beside its list.
        defer {
            if Task.isCancelled, searchResults == nil, !closed, ticket == searchGeneration { emit(.searchChanged(.idle)) }
        }
        var found: [Int: [TextSearch.Match]] = [:]
        for index in publication.spine.indices {
            try Task.checkCancellation()
            guard !closed, ticket == searchGeneration else { return }
            guard let document = await book.document(index) else { continue }
            let locale = language(of: document)
            let matches = await Task.detached(priority: .userInitiated) {
                TextSearch.matches(of: query, in: document, locale: locale, limit: Self.maximumSectionMatches)
            }.value
            if !matches.isEmpty { found[index] = matches }
        }
        guard !closed, ticket == searchGeneration else { return }
        try Task.checkCancellation()
        // Every section holding a match is read as rendered, just as `.locate` reads one.
        // Building can suspend; a newer search, clear, or close must win.
        guard let resolved = try await searchResults(for: found, ticket: ticket) else { return }
        guard !closed, ticket == searchGeneration else { return }
        try Task.checkCancellation()
        searchMatches = found
        searchRanges = [:]
        var results = EPUBSearchResults(query: text, results: resolved.results, isTruncated: resolved.isTruncated)
        // Newer navigation keeps its place: the results then have no current match.
        let first = navigationTicket.flatMap { isCurrent($0) ? resolved.ranges.first : nil }
        if first != nil { results.currentIndex = 0 }
        searchResults = results
        searchResultRanges = resolved.ranges
        refreshHighlights()
        // Published state holds results only for a completed search, so both change together;
        // the events then follow in order: the results, the relocation, the completion.
        let completion = EPUBSearchState.completed(query: text, hasMatches: !results.isEmpty)
        readerState?.modify { $0.searchResults = results; $0.search = completion }
        emit(.searchResultsChanged(results))
        if let first, let navigationTicket {
            // As a step through the results shows one (`showSearchResult(at:)`).
            let changes = pageChanges
            if !canShow(section: first.start.section) { _ = await book.build(first.start.section) }
            if isCurrent(navigationTicket), pageChanges == changes {
                canvas?.clearSelection()
                canvas?.showFound(first.start)
            }
        }
        guard !closed, ticket == searchGeneration else { return }
        emit(.searchChanged(completion))
    }

    /// The rendered occurrences of `found` in spine order, then document order, each with its
    /// rendered range. nil when a newer search, clear or close superseded this one.
    private func searchResults(for found: [Int: [TextSearch.Match]], ticket: Int) async throws
        -> (results: [EPUBSearchResult], ranges: [ReaderTextRange], isTruncated: Bool)? {
        var results: [EPUBSearchResult] = [], ranges: [ReaderTextRange] = [], isTruncated = false
        for index in found.keys.sorted() {
            guard let matches = found[index] else { continue }
            if matches.count >= Self.maximumSectionMatches { isTruncated = true }
            guard results.count < maximumSearchResults else { isTruncated = true; break }
            // A section's characters never depend on typography, so any build of it serves.
            let text: SectionText
            if let built = book.section(index) { text = built } else { text = await book.build(index) }
            try Task.checkCancellation()
            guard !closed, ticket == searchGeneration else { return nil }
            let section = SearchResultBuilder.Section(
                text: text, publicationID: publication.persistentID, engineID: NativeEngine.identifier,
                bookmarkFormat: NativeEngine.bookmarkFormat, spine: spine, progress: progress)
            let firstIndex = results.count, limit = maximumSearchResults - results.count
            let batch = await Task.detached(priority: .userInitiated) {
                SearchResultBuilder.results(for: matches, in: section, firstIndex: firstIndex, limit: limit)
            }.value
            try Task.checkCancellation()
            guard !closed, ticket == searchGeneration else { return nil }
            results += batch.results
            ranges += batch.ranges
            if batch.hasMore { isTruncated = true }
        }
        return (results, ranges, isTruncated)
    }

    /// Ends the current result list, as a clear, a new query, a failure and `.locate` do.
    /// Returns whether a current match was drawn, so its emphasis needs removing.
    @discardableResult private func withdrawSearchResults() -> Bool {
        searchResultRanges = []
        guard let results = searchResults else { return false }
        searchResults = nil
        emit(.searchResultsChanged(nil))
        return results.currentIndex != nil
    }

    /// A logical step through the results. Nothing to step through is not an error: a step
    /// submitted before a clear or a new query simply finds no results.
    private func stepSearchResult(forward: Bool) async {
        guard let index = searchResults?.steppedIndex(forward: forward) else { return }
        await showSearchResult(at: index)
    }

    private func showSearchResult(_ result: EPUBSearchResult) async throws {
        guard let results = searchResults, results.results.indices.contains(result.index),
              results.results[result.index] == result else {
            throw EPUBReaderError.invalidCommand("That search result is no longer available")
        }
        await showSearchResult(at: result.index)
    }

    /// Makes a result the current match and brings it into view: its page in paginated flow,
    /// a third of the way down the view in continuous scroll (`ReaderCanvasView.showFound`).
    /// Its section is built, or it would not be listed, though perhaps for the appearance the
    /// canvas has left: it is then built again first, with the page on screen kept (#243).
    private func showSearchResult(at index: Int) async {
        guard var results = searchResults, searchResultRanges.indices.contains(index) else { return }
        let ticket = beginNavigation()
        results.currentIndex = index
        searchResults = results
        drawCurrentSearchResult()
        emit(.searchResultsChanged(results))
        let position = searchResultRanges[index].start, changes = pageChanges
        if !canShow(section: position.section) { _ = await book.build(position.section) }
        guard isCurrent(ticket), pageChanges == changes else { return }
        canvas?.clearSelection()
        canvas?.showFound(position)
    }

    /// Moves the current match's emphasis, always the last highlight drawn, and leaves every
    /// other highlight as it is: a step through a long result list redraws one range.
    private func drawCurrentSearchResult() {
        guard let canvas else { return }
        var drawn = drawnHighlights
        if drawn.last?.kind == .currentSearch { drawn.removeLast() }
        if let current = currentSearchHighlight { drawn.append(current) }
        drawnHighlights = drawn
        canvas.setHighlights(drawn)
    }

    private var currentSearchHighlight: ReaderHighlight? {
        guard let index = searchResults?.currentIndex, searchResultRanges.indices.contains(index) else { return nil }
        return ReaderHighlight(id: "search-current", range: searchResultRanges[index], kind: .currentSearch)
    }

    private func applyStyle(_ newStyle: EPUBReaderStyle) throws {
        guard newStyle.fontSize.isFinite else { throw EPUBReaderError.invalidCommand("Nonfinite font size") }
        let typography = newStyle.typography
        guard [typography.lineHeight, typography.paragraphSpacing, typography.letterSpacing, typography.wordSpacing,
               typography.pageMargins].allSatisfy({ $0?.isFinite ?? true }) else {
            throw EPUBReaderError.invalidCommand("A typography setting is not a finite number")
        }
        style = newStyle
        updatePresentation()
    }

    /// The host's environment stays outside the canvas's explicit platform appearance.
    /// Remember it even in an explicit mode so choosing System uses the latest preference.
    func updateSystemAppearance(isDark: Bool) {
        guard !closed, systemIsDark != isDark else { return }
        systemIsDark = isDark
        if style.appearance == .system { updatePresentation() }
    }

    /// The host's Dynamic Type size, as `updateSystemAppearance` takes its appearance: remembered
    /// whatever the style, so turning `followsDynamicType` on uses the latest.
    func updateSystemTextSize(_ size: DynamicTypeSize) {
        guard !closed, systemTextSize != size else { return }
        systemTextSize = size
        if style.followsDynamicType { updatePresentation() }
    }

    /// Increase Contrast and Bold Text apply in every appearance, so either changes an open
    /// book's text whatever it is.
    func updateSystemAccessibility(increasesContrast: Bool, boldText: Bool) {
        guard !closed, systemIncreasesContrast != increasesContrast || systemBoldText != boldText else { return }
        systemIncreasesContrast = increasesContrast
        systemBoldText = boldText
        updatePresentation()
    }

    private func updatePresentation() {
        let theme = effectiveTheme
        let scale = dynamicTypeScale
        let typography = NativeTypography(fontSize: style.fontSize * scale, theme: theme, boldText: systemBoldText)
            .with(text: ReaderTextSettings(style.typography))
        readerState?.modify {
            $0.style = style
            $0.effectiveAppearance = theme.isDark ? .dark : .light
            $0.effectiveColors = theme.colors
            $0.effectiveFontSize = Double(typography.fontSize)
            $0.dynamicTypeScale = Double(scale)
        }
        applyConfiguration()
        if typography != book.typography {
            book.setTypography(typography)
            buildBook(from: visibleRange?.start.section ?? initialSection,
                      alongside: visibleRange.map { sections(inReachOf: $0) } ?? [])
        }
    }

    /// Builds `section` for the current typography, then the rest. A section already built for
    /// it, as when a host turns back to the appearance it reported before, stores nothing and
    /// reports no build, so whether the opening page can be shown is asked again here. The
    /// sections `alongside`, those in reach of the page, build at the same time: a change of
    /// appearance waits for them (`showNewAppearanceIfReady`), so for one build, not two.
    private func buildBook(from section: Int, alongside reach: [Int] = []) {
        let book = book
        tasks.append(Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for index in Set(reach + [section]) { group.addTask { _ = await book.build(index) } }
            }
            self?.becomeReadyIfPossible()
            self?.book.buildRemaining(from: section)
        })
    }

    private func setHighlights(_ list: [EPUBHighlight]) {
        highlights = list.filter { isCompatible($0.location) }
        for rejected in list where !isCompatible(rejected.location) {
            emit(.notice("a highlight belongs to another book or reader and was not drawn: \(rejected.id)"))
        }
        unresolvedHighlights = []
        highlightRanges = [:]
        highlightTargets = [:]
        for highlight in highlights {
            if let targets = targets(for: highlight.location) {
                highlightTargets[highlight.id] = targets
            } else { reportUnresolved(highlight) }
        }
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
            if searchRanges[index] == nil, let section = book.section(index) {
                searchRanges[index] = matches.map { range(of: $0, in: section) }.filter { SearchResultBuilder.isListed($0, in: section) }
            }
            for (number, range) in (searchRanges[index] ?? []).enumerated() {
                drawn.append(ReaderHighlight(id: "search-\(index)-\(number)", range: range, kind: .search))
            }
        }
        for highlight in highlights {
            guard let targets = highlightTargets[highlight.id], !unresolvedHighlights.contains(highlight.id) else { continue }
            if highlightRanges[highlight.id] == nil {
                var ranges: [ReaderTextRange] = []
                var pending = false
                for target in targets {
                    guard let section = book.section(target.spineIndex) else { pending = true; continue }
                    guard let range = range(of: target.localPath, in: section), !range.isEmpty else {
                        reportUnresolved(highlight)
                        break
                    }
                    ranges.append(range)
                }
                if !pending, ranges.count == targets.count { highlightRanges[highlight.id] = ranges }
            }
            for range in highlightRanges[highlight.id] ?? [] {
                // A host id identifies every segment of the same annotation.
                drawn.append(ReaderHighlight(id: highlight.id, range: range, kind: .annotation))
            }
        }
        // The current match is drawn again, last, over its ordinary search highlight.
        if let current = currentSearchHighlight { drawn.append(current) }
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
        // A layout can find text the build could not know will not be laid out (#288).
        book.section(index)?.layout.observe { [weak self] in
            guard let self, !self.closed else { return }
            self.publishDisclosure()
        }
        if !isReady { becomeReadyIfPossible(); return }
        publishDisclosure()
        if shownTheme != book.typography.theme { showNewAppearanceIfReady() }
        else if visibleRange?.start.section == index || visibleRange?.end.section == index, book.isCurrent(index) {
            canvas?.reloadContent(keeping: nil)
        }
        if !searchMatches.isEmpty || !highlights.isEmpty { refreshHighlights() }
        canvas?.sectionsDidChange()
    }

    private func bookCompleted() {
        guard isReady, !closed else { return }
        publishDisclosure()
        if style.flow == .scrolled { canvas?.reloadContent(keeping: nil) }
        if !searchMatches.isEmpty || !highlights.isEmpty { refreshHighlights() }
        canvas?.sectionsDidChange()
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

    private func emit(_ event: EPUBReaderEvent) {
        guard !closed else { return }
        readerState?.modify {
            switch event {
            case .ready: $0.lifecycle = .ready
            case .relocated(let location): $0.location = location
            case .searchChanged(let search): $0.search = search
            case .searchResultsChanged(let results): $0.searchResults = results
            case .failed(let error): $0.lifecycle = .failed(error)
            default: break
            }
        }
        onEvent?(event)
    }

    /// Where a range's contents title is read: its end within its first section, so a heading on
    /// the page names it, as foliate's `TOCProgress` compared against the range's end.
    private func titlePosition(of range: ReaderTextRange) -> ReaderTextPosition {
        guard range.end.section == range.start.section, range.end.offset > range.start.offset else { return range.start }
        return ReaderTextPosition(section: range.start.section, offset: range.end.offset - 1)
    }

    /// The engine bookmark for a rendered range within one section (foliate `getCFI`).
    private func cfi(for range: ReaderTextRange) -> String? {
        // A failed multi-section bookmark set must never fall back to its first segment.
        guard range.start.section == range.end.section,
              let section = book.section(range.start.section), section.document.canResolveCFIs else { return nil }
        guard let dom = section.domRange(range) else { return spine.bases[range.start.section] }
        return spine.cfi(spineIndex: range.start.section, start: dom.start, end: dom.end, in: section.document)
    }

    /// Split at document boundaries; nonlinear sections and empty endpoints contribute no CFI.
    private func bookmarks(for range: ReaderTextRange) -> [EPUBEngineBookmark] {
        var bookmarks: [EPUBEngineBookmark] = []
        for index in range.start.section...max(range.start.section, range.end.section) {
            if range.start.section != range.end.section, book.isOmitted(index) { continue }
            guard let section = book.section(index), section.document.canResolveCFIs else { return [] }
            let lower = index == range.start.section ? range.start.offset : 0
            let upper = index == range.end.section ? range.end.offset : section.string.length
            if range.start.section != range.end.section,
               !(index == range.start.section && range.start.tableCell != nil),
               !(index == range.end.section && range.end.tableCell != nil),
               !section.map.spans.contains(where: { $0.location < upper && $0.location + $0.length > lower }) { continue }
            let segment = ReaderTextRange(start: index == range.start.section ? range.start : ReaderTextPosition(section: index, offset: lower),
                end: index == range.end.section ? range.end : ReaderTextPosition(section: index, offset: max(lower, upper)))
            guard let cfi = cfi(for: segment) else { return [] }
            bookmarks.append(EPUBEngineBookmark(engineID: NativeEngine.identifier, format: NativeEngine.bookmarkFormat, value: cfi))
        }
        return bookmarks
    }

    private func location(for range: ReaderTextRange, fraction: Double?, quote: String? = nil) -> EPUBLocation {
        let bookmarks = bookmarks(for: range)
        let index = bookmarks.first.flatMap { spine.resolve($0.value)?.spineIndex } ?? range.start.section
        let anchor = { [book] (section: Int, fragment: String) in book.section(section)?.anchors[fragment] }
        // Only continuous scroll over the whole book shows a range across sections.
        let pages = progress.pages(in: range, isShown: { [book] in !book.isOmitted($0) }, anchor: anchor)
        return EPUBLocation(
            publicationID: publication.persistentID, href: publication.spine[index].resource.href,
            progression: fraction.flatMap { progress.progression(section: index, fraction: $0) },
            title: fraction == nil ? nil : progress.title(at: titlePosition(of: range), anchor: anchor),
            quote: quote,
            bookmark: bookmarks.first ?? cfi(for: range).map {
                EPUBEngineBookmark(engineID: NativeEngine.identifier, format: NativeEngine.bookmarkFormat, value: $0)
            },
            page: pages.page, pages: pages.pages, rangeBookmarks: bookmarks.count > 1 ? bookmarks : nil)
    }

    /// A passage's text as foliate's `Selection.toString()` gave it: the book's own characters
    /// and attachments' text, without generated list markers, quote marks or bidi isolates, and
    /// with line breaks between blocks. nil while a section is not built.
    private func passageText(_ range: ReaderTextRange) -> String? {
        var text = ""
        for index in range.start.section...max(range.start.section, range.end.section) {
            if range.start.section != range.end.section, book.isOmitted(index) { continue }
            guard let section = book.section(index) else { return nil }
            let lower = index == range.start.section ? range.start.offset : 0
            let upper = index == range.end.section ? range.end.offset : section.string.length
            if index != range.start.section { text += "\n" }
            let segment = ReaderTextRange(start: index == range.start.section ? range.start : ReaderTextPosition(section: index, offset: lower),
                end: index == range.end.section ? range.end : ReaderTextPosition(section: index, offset: max(lower, upper)))
            text += section.tablePassage(segment) ?? section.mappedText(in: lower..<max(lower, upper))
        }
        return text
    }

    fileprivate func performSelectionAction() {
        guard !closed, let selection, let action else { return }
        action.perform(EPUBSelection(text: selection.text, location: location(for: selection.range, fraction: nil, quote: selection.text)))
    }
}

extension NativeSession: ReaderCanvasDataSource {
    var sectionCount: Int { book.count }
    func text(forSection index: Int) -> NSAttributedString? { book.section(index)?.string }
    func selectionText(in range: ReaderTextRange) -> String? { passageText(range) }
    /// Page turns keep to the sections continuous scroll shows (`NativeBook.isOmitted`): every
    /// one when no spine item is linear. foliate-js stops such a book at the end of its first
    /// section; this departs from it on purpose, so the book reads through in either flow.
    func isLinear(section index: Int) -> Bool { !book.isOmitted(index) }
    var bookText: ReaderBookText? { book.bookText }
    /// A section whose newest build is for another theme than the canvas draws in is built
    /// again before a turn shows it, unless that build is for the theme asked for: showing it is
    /// then the canvas's change of theme (#243).
    func canShow(section index: Int) -> Bool {
        guard let built = book.typography(ofSection: index), let canvas else { return true }
        return built.theme == canvas.configuration.theme || book.isCurrent(index)
    }
    func isCurrent(section index: Int) -> Bool { book.isCurrent(index) }
}

extension NativeSession: ReaderCanvasDelegate {
    func canvas(_ canvas: any ReaderCanvas, didShow range: ReaderTextRange, sectionProgress: Double) {
        if range != visibleRange { pageChanges += 1 }
        visibleRange = range
        // A page of text built for the theme asked for brings it to the canvas (`shownTheme`).
        applyConfiguration()
        guard isReady, !closed else { return }
        readerState?.modify {
            $0.canGoPrevious = self.canvas?.canTurnPage(forward: false)
            $0.canGoNext = self.canvas?.canTurnPage(forward: true)
            // Before the `.relocated` of the same pages, which a host may read it beside.
            $0.layoutPage = self.canvas?.layoutPage
        }
        // A page is read to its end, as foliate measured it: the last page of a book is 1.
        var fraction = sectionProgress
        if style.flow == .paginated, let length = book.section(range.start.section)?.string.length, length > 0 {
            fraction = range.end.section > range.start.section ? 1 : Double(range.end.offset) / Double(length)
        }
        let location = location(for: range, fraction: fraction)
        guard location != lastLocation else { return }
        lastLocation = location
        emit(.relocated(location))
    }

    func canvas(_ canvas: any ReaderCanvas, didChangeSelection selection: ReaderSelection?) {
        let selection = selection.map { ReaderSelection(range: $0.range, text: passageText($0.range) ?? $0.text) }
        guard selection != self.selection else { return }
        guard let selection, !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let hadSelection = self.selection != nil
            self.selection = nil
            if isReady, hadSelection { emit(.selectionChanged(nil)) }
            return
        }
        self.selection = selection
        guard isReady else { return }
        emit(.selectionChanged(EPUBSelection(text: selection.text,
            location: location(for: selection.range, fraction: nil, quote: selection.text))))
    }

    func canvasDidRequestSelectionAction(_ canvas: any ReaderCanvas) { performSelectionAction() }

    func canvas(_ canvas: any ReaderCanvas, didActivate link: ReaderLink, at position: ReaderTextPosition, rect: CGRect) {
        activateLink(link, from: rect)
    }

    /// Reserves the activation's navigation order before loading its target. The returned task
    /// completes after the activation is shown or superseded by a newer navigation action.
    @discardableResult
    func activateLink(_ link: ReaderLink, from rect: CGRect) -> Task<Void, Never>? {
        guard isReady, !closed else { return nil }
        switch link {
        case .external(let href):
            activateExternalLink(href, from: rect)
            return nil
        case .internal(let href), .note(let href):
            guard let target = try? Self.target(of: href, in: publication) else { return nil }
            let ticket = beginNavigation()
            let task = Task { [weak self] in
                guard let self else { return }
                // A plain link can name a hidden note in another document. Only the target's
                // build knows that, so inspect its captured notes before navigating.
                let text = await self.book.build(target.section)
                guard self.isReady, self.isCurrent(ticket) else { return }
                if let fragment = target.fragment, let note = text.notes[fragment] {
                    // The note is built with its section, for an appearance the page may not show yet.
                    self.canvas?.presentNote(note, theme: self.book.typography.theme, from: rect)
                } else {
                    self.showNavigationTarget(text, fragment: target.fragment)
                }
            }
            tasks.append(task)
            return task
        }
    }

    /// EPUB Reading Systems 3.3 §3.9: a reading system should have the reader's consent before
    /// it opens an `http` or `https` link, and before it hands a link to the application of its
    /// scheme, as `mailto` goes to the mail app. So the reader asks, naming the address, and
    /// nothing is opened before it answers (`answerExternalLink`). A host may refuse such links
    /// or take them itself (`EPUBExternalLinks`). Every other scheme is refused, whatever the
    /// host chose: `javascript:` and `data:` would run or show the book's own content outside
    /// the reader, `file:` reaches the device, and an app's own scheme does what that app does.
    private func activateExternalLink(_ href: String, from rect: CGRect) {
        if case .refuse = externalLinks.behavior { return emit(.notice(Self.externalLinkRefused)) }
        guard let address = ExternalLinkAddress(href) else { return emit(.notice(Self.externalSchemeRefused)) }
        switch externalLinks.behavior {
        case .refuse: break
        case .handle(let open): open(address.url)
        case .ask:
            guard openURL != nil, let canvas,
                  canvas.askToOpen(ExternalLinkQuestion(address: address), from: rect, answer: { [weak self] open in
                      self?.answerExternalLink(address, open: open)
                  }) else { return emit(.notice(Self.externalLinkRefused)) }
            askedLink = address
        }
    }

    /// The reader's answer to the question about `address`: Open, or not. A question asked
    /// again, withdrawn or answered already is answered no.
    func answerExternalLink(_ address: ExternalLinkAddress, open: Bool) {
        guard askedLink == address else { return }
        askedLink = nil
        guard open, !closed, let openURL else { return }
        openURL(address.url)
    }

    /// The mounted view's settings for links outside the book, read each time SwiftUI updates it.
    fileprivate func takeLinkSettings(from environment: EnvironmentValues) {
        externalLinks = environment.epubReaderExternalLinks
        let open = environment.openURL
        openURL = { open($0) }
    }

    /// Ahead of the background rebuild, which goes nearest first, at a person's priority: the
    /// next move by heading finds what the section holds within one build (#243).
    func canvas(_ canvas: any ReaderCanvas, wantsSection index: Int) {
        guard !closed, !book.isCurrent(index) else { return }
        tasks.append(Task { [weak self] in _ = await self?.book.build(index) })
    }

    func canvasDidChangeLayoutPage(_ canvas: any ReaderCanvas) {
        guard isReady, !closed, canvas === self.canvas else { return }
        readerState?.modify { $0.layoutPage = self.canvas?.layoutPage }
    }

    func canvas(_ canvas: any ReaderCanvas, needsSection index: Int, forward: Bool) {
        let ticket = beginNavigation(), changes = pageChanges
        tasks.append(Task { [weak self] in
            guard let text = await self?.book.build(index), let self, self.isCurrent(ticket),
                  self.pageChanges == changes else { return }
            self.canvas?.show(ReaderTextPosition(section: index, offset: forward ? 0 : text.string.length), selecting: nil,
                              entry: .firstLine)
        })
    }
}

/// The session's SwiftUI view: the TextKit 2 canvas, and on iPhone and iPad VoiceOver's scroll
/// action. The page-turn keys and the paginated edge tap zones are the canvas's own, so taps on
/// links, selections and text near the edges reach the text.
///
/// No page action is named here. The text offers its own: each line of a page on iPhone and
/// iPad, and each text area on Mac (`ReaderTextView.accessibilityCustomActions`). SwiftUI puts
/// a view's named actions on the canvas. VoiceOver on iPhone and iPad offers a view's actions
/// on every element inside it: each line of continuous scroll said "Actions available" and
/// offered to turn a page it does not have, and each line of a page offered the pair twice.
/// On Mac the canvas is not an accessibility element, and neither the named actions nor the
/// scroll action reached any element of the window.
private struct NativeSurface: View {
    let session: NativeSession
    @Environment(\.epubReaderDivision) private var division
    @Environment(\.epubReaderPageControls) private var pageControls
    @Environment(\.epubReaderControlsHiding) private var controlsHiding
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Increase Contrast, on iPhone, iPad and Mac.
    @Environment(\.colorSchemeContrast) private var contrast
    /// Bold Text, on iPhone and iPad.
    @Environment(\.legibilityWeight) private var legibilityWeight

    var body: some View {
        if !session.closed {
            NativeCanvasHost(session: session)
                .onAppear {
                    session.updateSystemAppearance(isDark: colorScheme == .dark)
                    session.updateSystemTextSize(dynamicTypeSize)
                    updateSystemAccessibility()
                    session.division = division
                    session.pageControls = pageControls
                    session.controlsHiding = controlsHiding
                }
                .onChange(of: division) { session.division = division }
                .onChange(of: pageControls) { session.pageControls = pageControls }
                .onChange(of: controlsHiding) { session.controlsHiding = controlsHiding }
                .onChange(of: colorScheme) { session.updateSystemAppearance(isDark: colorScheme == .dark) }
                .onChange(of: dynamicTypeSize) { session.updateSystemTextSize(dynamicTypeSize) }
                .onChange(of: contrast) { updateSystemAccessibility() }
                .onChange(of: legibilityWeight) { updateSystemAccessibility() }
                #if os(iOS)
                .accessibilityScrollAction { edge in
                    if edge == .leading { submit(.previousPage) }
                    if edge == .trailing { submit(.nextPage) }
                }
                #endif
        }
    }

    private func updateSystemAccessibility() {
        session.updateSystemAccessibility(increasesContrast: contrast == .increased, boldText: legibilityWeight == .bold)
    }

    #if os(iOS)
    private func submit(_ command: EPUBReaderCommand) {
        Task { @MainActor in try? await session.send(command) }
    }
    #endif
}

#if os(iOS)
private struct NativeCanvasHost: UIViewRepresentable {
    let session: NativeSession
    func makeUIView(context: Context) -> ReaderCanvasView {
        let canvas = ReaderCanvasView(frame: .zero)
        session.takeLinkSettings(from: context.environment)
        session.attach(canvas)
        return canvas
    }
    func updateUIView(_ canvas: ReaderCanvasView, context: Context) { session.takeLinkSettings(from: context.environment) }
    static func dismantleUIView(_ canvas: ReaderCanvasView, coordinator: ()) {
        (canvas.dataSource as? NativeSession)?.detach(canvas)
    }
}
#elseif os(macOS)
private struct NativeCanvasHost: NSViewRepresentable {
    let session: NativeSession
    func makeNSView(context: Context) -> ReaderCanvasView {
        let canvas = ReaderCanvasView(frame: .zero)
        session.takeLinkSettings(from: context.environment)
        session.attach(canvas)
        return canvas
    }
    func updateNSView(_ canvas: ReaderCanvasView, context: Context) { session.takeLinkSettings(from: context.environment) }
    static func dismantleNSView(_ canvas: ReaderCanvasView, coordinator: ()) {
        (canvas.dataSource as? NativeSession)?.detach(canvas)
    }
}
#endif

extension NativeSession {
    /// The person read on with the reader's own input: the host's controls hide, where it asked
    /// for that (`View.epubReaderHidesControls(_:whileReading:)`).
    func canvasDidReadOn(_ canvas: any ReaderCanvas) {
        guard let controlsHiding, controlsHiding.whileReading else { return }
        controlsHiding.controls?.readerDidReadOn()
    }

    func canvasTogglesControls(_ canvas: any ReaderCanvas) -> Bool {
        guard let controls = controlsHiding?.controls else { return false }
        controls.toggleControls()
        return true
    }
}
