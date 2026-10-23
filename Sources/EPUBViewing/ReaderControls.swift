import EPUBCore
import EPUBReading
import Observation
import Foundation

/// Retain one controls model with a publication and its existing session. All control
/// submissions run in FIFO order. A closed/failed/detached session rejects queued work.
@MainActor @Observable public final class EPUBReaderControls {
    public let publication: EPUBPublication
    public let session: any EPUBReaderSession
    public var searchText = ""
    /// Customize the built-in page buttons' help without adding keyboard shortcuts.
    /// Return the supplied default plus host hints to supplement it, or replace it entirely.
    /// Labels remain concise and independent of this longer help text.
    public var customizePageButtonHelp: (@MainActor (EPUBPageAction, String) -> String)?
    public private(set) var pendingCommands = 0
    /// Queued or running searches. The search field's feedback follows these alone: a line shown
    /// for any pending command resizes inline controls, and the reader under them, during a page turn.
    private(set) var pendingSearches = 0
    public private(set) var commandError: String?
    @ObservationIgnored private var commands: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Has an assistive technology say the words (`announceSearchResult`). The platform's own
    /// post, which a test takes in its place.
    @ObservationIgnored var postAnnouncement: @MainActor (String) -> Void = { EPUBReaderControls.postAccessibilityAnnouncement($0) }
    /// The person asked for the controls to be hidden (`hideControls()`), until they are shown
    /// again. `controlsHidden` is this while the reader is ready.
    var controlsHiddenRequested = false
    /// Whether VoiceOver or Switch Control is running, which keeps the controls from hiding by
    /// themselves (`readerDidReadOn`). The platform's own answer, which a test takes in its place.
    @ObservationIgnored var assistiveTechnologyIsRunning: @MainActor () -> Bool = { EPUBReaderControls.assistiveTechnologyKeepsControls }

    public init(publication: EPUBPublication, session: any EPUBReaderSession) {
        self.publication = publication
        self.session = session
    }

    public var status: EPUBReaderStatus? { session.readerState?.status }
    public var isReady: Bool { status?.lifecycle == .ready }
    public var isBusy: Bool { pendingCommands > 0 || (status?.activeCommands ?? 0) > 0 }
    public var isRightToLeft: Bool { publication.pageProgression == .rtl }
    public var canGoPrevious: Bool { canTurn && status?.canGoPrevious != false }
    public var canGoNext: Bool { canTurn && status?.canGoNext != false }
    private var canTurn: Bool {
        guard let status else { return false }
        return isReady && status.capabilities.contains(status.style.flow == .scrolled ? .scrolling : .pagination)
    }
    public func supports(_ capability: EPUBReaderCapability) -> Bool {
        status?.capabilities.contains(capability) == true
    }
    public func dismissError() { commandError = nil }
    /// The command error to show beside a search field's own feedback: nil while the failed
    /// search states the same refusal, which the pane printed twice and the strip three times.
    var commandErrorBesideSearchFeedback: String? {
        if case .failed(_, let error) = status?.search, error.message == commandError { return nil }
        return commandError
    }

    public func pageButtonLabel(for action: EPUBPageAction) -> String {
        action.label(in: status?.style.flow ?? .paginated)
    }

    /// Describes the bundled native reader's active input settings. Built-in buttons pass
    /// their `epubReaderPageControls` environment value; custom controls can pass the same
    /// settings explicitly. Keyboard bindings are logical, even in an RTL publication.
    public func pageButtonHelp(for action: EPUBPageAction, pageControls: EPUBPageControls = .init()) -> String {
        let label = pageButtonLabel(for: action)
        let hints = pageControls.helpHints(for: action, paginated: status?.style.flow != .scrolled,
                                          isRightToLeft: isRightToLeft, platform: .current)
        let defaultHelp = ([label] + hints).joined(separator: ". ") + "."
        return customizePageButtonHelp?(action, defaultHelp) ?? defaultHelp
    }

    public func send(_ command: EPUBReaderCommand) {
        let isSearch = switch command { case .search, .searchHighlight: true; default: false }
        enqueue(isSearch: isSearch) { command }
    }
    /// Submits a match step or a chosen result and, once the engine has shown it, says which
    /// match is current to an assistive technology, whose cursor stays on the control.
    func sendSearchResultCommand(_ command: EPUBReaderCommand) {
        enqueue(then: { [weak self] in self?.announceSearchResult() }) { command }
    }
    /// Edits the latest style when this command executes, preserving changes queued before it
    /// and style fields updated through the session by the host.
    public func changeStyle(_ change: @escaping @MainActor (inout EPUBReaderStyle) -> Void) {
        enqueue { [weak self] in
            var style = self?.status?.style ?? EPUBReaderStyle()
            change(&style)
            return .style(style)
        }
    }
    /// Submit-only search. Typing never sends a command. Whitespace-only input clears;
    /// the native engine validates its normalized query and 512-character limit. Engines
    /// advertising `.search` also open the first match; highlight-only engines retain their position.
    /// The match a search opens is said once the engine has shown it, as a step's is
    /// (`announceSearchResult`), also where it turns the page, which says nothing of its own.
    /// A search that opens none, because it found none or newer navigation kept the reader
    /// where it was, says nothing (#601).
    public func submitSearch() {
        let query = searchText
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { send(.clearSearch) }
        else if supports(.search) {
            enqueue(isSearch: true, then: { [weak self] in
                // The match this search opened, not one of a search the host made meanwhile.
                if self?.searchResults?.query == query { self?.announceSearchResult() }
            }) { .search(text: query) }
        } else { send(.searchHighlight(text: query)) }
    }
    public func clearSearch() { searchText = ""; send(.clearSearch) }

    /// Cancels work that has not been submitted. Already submitted commands cannot be undone.
    /// Call when discarding controls; close the session when leaving the book.
    public func cancelPendingCommands() {
        generation += 1
        commands?.cancel()
        commands = nil
        pendingCommands = 0
        pendingSearches = 0
    }
    public func waitForCommands() async { await commands?.value }

    /// `then` runs once the command has been carried out, and not after a refusal or cancellation.
    private func enqueue(isSearch: Bool = false, then: (@MainActor () -> Void)? = nil,
                         _ command: @escaping @MainActor () -> EPUBReaderCommand) {
        guard isReady else { return }
        let previous = commands
        let token = generation
        pendingCommands += 1
        if isSearch { pendingSearches += 1 }
        commands = Task { [weak self] in
            await previous?.value
            guard let self, generation == token else { return }
            defer {
                if generation == token {
                    pendingCommands -= 1
                    if isSearch { pendingSearches -= 1 }
                }
            }
            do {
                try Task.checkCancellation()
                guard isReady else { return }
                commandError = nil
                try await session.send(command())
                if generation == token { then?() }
            } catch is CancellationError {
            } catch {
                guard generation == token, status?.lifecycle != .closed else { return }
                commandError = (error as? EPUBReaderError)?.message ?? error.localizedDescription
            }
        }
    }

    /// A section-only href is exact; for fragment entries the current title disambiguates
    /// entries within a section. Unknown or ambiguous titles produce no checkmark. An entry and
    /// the location name the section `.navigate(href:)` shows for their hrefs, whatever their
    /// spelling: the decoded path is compared as a Swift string, by canonical equivalence, as
    /// archive paths are, and a designated fallback names its spine item's section.
    public func isCurrent(_ item: EPUBNavigationItem) -> Bool {
        guard let href = item.href, let entry = section(of: href), let location = status?.location,
              entry.section == location.href.flatMap(section(of:))?.section else { return false }
        if entry.fragment == nil { return true }
        guard location.title == item.title else { return false }
        func matches(_ items: [EPUBNavigationItem]) -> Int {
            items.reduce(0) { count, candidate in
                // The title first: it is cheaper to compare than an href is to resolve.
                let same = candidate.title == item.title && candidate.href.flatMap(section(of:))?.section == entry.section
                return count + (same ? 1 : 0) + matches(candidate.children)
            }
        }
        return matches(publication.tableOfContents) == 1
    }

    /// The spine section and decoded fragment an href names, as `.navigate(href:)` finds them;
    /// nil for an href navigation refuses.
    private func section(of href: String) -> (section: Int, fragment: String?)? {
        try? NativeSession.target(of: href, in: publication)
    }

    /// `changeStyle`, and `then` once the engine has applied the style, as a text size step
    /// says the size drawn (`stepTextSize`).
    func changeStyle(_ change: @escaping @MainActor (inout EPUBReaderStyle) -> Void, then: @escaping @MainActor () -> Void) {
        enqueue(then: then) { [weak self] in
            var style = self?.status?.style ?? EPUBReaderStyle()
            change(&style)
            return .style(style)
        }
    }
}

extension EPUBPageAction {
    /// What a control or an accessibility action that does this is called in `flow`. Continuous
    /// scroll has no pages, and a step there scrolls. The page buttons and the actions of the
    /// Mac's text areas take their names from here, so one command has one name.
    func label(in flow: EPUBReadingFlow) -> String {
        switch (flow, self) {
        case (.paginated, .next): "Next Page"
        case (.paginated, .previous): "Previous Page"
        case (.scrolled, .next): "Scroll Forward"
        case (.scrolled, .previous): "Scroll Backward"
        case (.paginated, .bookStart): "First Page"
        case (.paginated, .bookEnd): "Last Page"
        case (.scrolled, .bookStart): "Scroll to Beginning"
        case (.scrolled, .bookEnd): "Scroll to End"
        }
    }
}
