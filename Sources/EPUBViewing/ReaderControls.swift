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
    public func submitSearch() {
        let query = searchText
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { send(.clearSearch) }
        else { send(supports(.search) ? .search(text: query) : .searchHighlight(text: query)) }
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

    private func enqueue(isSearch: Bool = false, _ command: @escaping @MainActor () -> EPUBReaderCommand) {
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
            } catch is CancellationError {
            } catch {
                guard generation == token, status?.lifecycle != .closed else { return }
                commandError = (error as? EPUBReaderError)?.message ?? error.localizedDescription
            }
        }
    }

    /// A section-only href is exact; for fragment entries the current title disambiguates
    /// entries within a section. Unknown or ambiguous titles produce no checkmark.
    public func isCurrent(_ item: EPUBNavigationItem) -> Bool {
        guard let href = item.href, let location = status?.location,
              href.split(separator: "#", maxSplits: 1).first == location.href?.split(separator: "#", maxSplits: 1).first else { return false }
        if !href.contains("#") { return true }
        guard location.title == item.title else { return false }
        func matches(_ items: [EPUBNavigationItem]) -> Int {
            items.reduce(0) { count, candidate in
                let sameSection = candidate.href?.split(separator: "#", maxSplits: 1).first == href.split(separator: "#", maxSplits: 1).first
                return count + (sameSection && candidate.title == item.title ? 1 : 0) + matches(candidate.children)
            }
        }
        return matches(publication.tableOfContents) == 1
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
        }
    }
}
