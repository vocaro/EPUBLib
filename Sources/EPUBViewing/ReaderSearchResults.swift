import EPUBCore
import SwiftUI

// Search results in the optional controls: the model's result state and commands, the text the
// supplied views show and speak, the match navigator and the result browser.

public extension EPUBReaderControls {
    /// The completed search's results and current match, from an engine with `.searchResults`.
    /// nil while no search is complete (idle, pending, failed, cleared or closed) and for
    /// engines that only highlight.
    var searchResults: EPUBSearchResults? {
        guard supports(.searchResults), let status, status.lifecycle != .closed else { return nil }
        return status.searchResults
    }

    /// Whether there are results to step through and browse.
    var canShowSearchResults: Bool { isReady && searchResults?.isEmpty == false }

    /// Submits `.nextSearchResult`: a logical step in result order, independent of the page
    /// buttons and of the book's reading direction. Does nothing without results.
    func showNextSearchResult() { if canShowSearchResults { send(.nextSearchResult) } }
    /// Submits `.previousSearchResult`. Does nothing without results.
    func showPreviousSearchResult() { if canShowSearchResults { send(.previousSearchResult) } }
    /// Submits `.showSearchResult`. The engine refuses a result of a replaced or cleared search.
    func showSearchResult(_ result: EPUBSearchResult) {
        if supports(.searchResults) { send(.showSearchResult(result)) }
    }

    /// The search's state in a few words for a count indicator: “3 of 27”, “27 matches”,
    /// “No matches”, “Searching…” or the engine's error. nil while no search is active and
    /// after a successful search by an engine that only highlights.
    var searchResultSummary: String? {
        switch status?.search ?? .idle {
        case .idle: return nil
        case .searching: return "Searching…"
        case .failed(_, let error): return error.message
        case .completed(_, let hasMatches):
            guard let results = searchResults else { return hasMatches ? nil : "No matches" }
            guard !results.isEmpty else { return "No matches" }
            let count = results.count.formatted() + (results.isTruncated ? "+" : "")
            if let index = results.currentIndex { return "\((index + 1).formatted()) of \(count)" }
            return results.count == 1 && !results.isTruncated ? "1 match" : "\(count) matches"
        }
    }

    /// The same state in full for assistive technologies, such as “Match 27 of 27, last match,
    /// Second Chapter”. The supplied indicator and match buttons use it as their value.
    var searchResultAccessibilityValue: String? {
        switch status?.search ?? .idle {
        case .idle: return nil
        case .searching: return "Searching"
        case .failed(_, let error): return "Search failed. \(error.message)"
        case .completed(_, let hasMatches):
            guard let results = searchResults else { return hasMatches ? "Matches highlighted" : "No matches" }
            guard !results.isEmpty else { return "No matches" }
            let count = (results.isTruncated ? "at least " : "") + results.count.formatted()
            guard let index = results.currentIndex, let current = results.current else {
                return (results.count == 1 && !results.isTruncated ? "1 match" : "\(count) matches".capitalizedFirst)
                    + ", none shown yet"
            }
            var parts = ["Match \((index + 1).formatted()) of \(count)"]
            if results.count == 1 { parts.append("only match") }
            else if results.isAtFirst { parts.append("first match") }
            else if results.isAtLast { parts.append("last match") }
            if let title = current.sectionTitle, !title.isEmpty { parts.append(title) }
            return parts.joined(separator: ", ")
        }
    }

    /// “Next Match” or “Previous Match”: distinct from the page buttons' labels in either flow.
    func searchResultButtonLabel(forward: Bool) -> String { forward ? "Next Match" : "Previous Match" }

    /// The label plus what the step does at the ends: returning to the first or last match, or
    /// choosing one when none has been shown.
    func searchResultButtonHelp(forward: Bool) -> String {
        let label = searchResultButtonLabel(forward: forward)
        guard let hint = searchResultButtonHint(forward: forward) else { return label }
        return "\(label). \(hint)"
    }

    /// What a step does when it is not simply the neighbouring match. nil otherwise.
    func searchResultButtonHint(forward: Bool) -> String? {
        guard let results = searchResults, !results.isEmpty else { return nil }
        if results.count == 1 { return "This is the only match." }
        if results.currentIndex == nil { return forward ? "Shows the first match." : "Shows the last match." }
        if forward, results.isAtLast { return "Returns to the first match." }
        if !forward, results.isAtFirst { return "Returns to the last match." }
        return nil
    }

    /// A result's accessible name: its place in the list, its section and page, then the text
    /// from the occurrence onward and what precedes it, so that occurrences of the same words,
    /// even within one paragraph, can be told apart by ear.
    func searchResultAccessibilityLabel(for result: EPUBSearchResult) -> String {
        var parts = ["Match \((result.index + 1).formatted())" + (searchResults.map { " of \($0.count.formatted())" } ?? "")]
        if let title = result.sectionTitle, !title.isEmpty { parts.append(title) }
        if let page = result.location.page?.label, !page.isEmpty { parts.append("page \(page)") }
        let before = result.contextBefore.trimmingCharacters(in: .whitespaces)
        let onward = result.matchedText + result.contextAfter
        let endsSentence = onward.last.map { ".!?…。".contains($0) } ?? false
        return parts.joined(separator: ", ") + ": " + onward
            + (before.isEmpty ? "" : "\(endsSentence ? "" : ".") Preceded by: \(before)")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The current match and count with logical Previous Match and Next Match buttons, and
/// optionally a button that presents the result browser. The search pane contains one; place
/// another in a toolbar, bottom bar or overlay to keep match navigation at hand while the pane
/// is closed. Hidden for engines without `.searchResults`.
///
/// The match buttons use up and down chevrons in a fixed logical order. They never mirror for a
/// right-to-left book and never turn pages.
public struct EPUBSearchResultNavigator: View {
    private let controls: EPUBReaderControls
    private let showsResultBrowser: Bool
    /// Pending, empty and failed searches are shown too; the search pane reports those itself.
    private let showsStatus: Bool
    @State private var showingResults = false

    public init(controls: EPUBReaderControls, showsResultBrowser: Bool = true) {
        self.init(controls: controls, showsResultBrowser: showsResultBrowser, showsStatus: true)
    }

    init(controls: EPUBReaderControls, showsResultBrowser: Bool, showsStatus: Bool) {
        self.controls = controls; self.showsResultBrowser = showsResultBrowser; self.showsStatus = showsStatus
    }

    public var body: some View {
        if controls.supports(.searchResults), showsStatus || controls.searchResults?.isEmpty == false {
            // One row when it fits; the indicator above its buttons at narrow widths and
            // larger accessibility text sizes, as the control strip stacks its groups.
            ViewThatFits(in: .horizontal) {
                HStack { indicator; buttons }
                VStack(alignment: .leading) { indicator; HStack { buttons } }
            }
            .disabled(!controls.isReady)
        }
    }

    @ViewBuilder private var indicator: some View {
        if let summary = controls.searchResultSummary {
            Text(summary)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .accessibilityLabel("Search matches")
                .accessibilityValue(controls.searchResultAccessibilityValue ?? summary)
        }
    }

    @ViewBuilder private var buttons: some View {
        step(forward: false)
        step(forward: true)
        if showsResultBrowser {
            Button("Search Results", systemImage: "list.bullet.rectangle") { showingResults = true }
                .labelStyle(.iconOnly)
                .help("Search Results")
                .disabled(!controls.canShowSearchResults)
                .popover(isPresented: $showingResults) {
                    EPUBSearchResultBrowser(controls: controls) { showingResults = false }
                }
        }
    }

    private var isFailed: Bool {
        if case .failed = controls.status?.search { return true }
        return false
    }

    private func step(forward: Bool) -> some View {
        Button(controls.searchResultButtonLabel(forward: forward), systemImage: forward ? "chevron.down" : "chevron.up") {
            if forward { controls.showNextSearchResult() } else { controls.showPreviousSearchResult() }
        }
        .labelStyle(.iconOnly)
        .disabled(!controls.canShowSearchResults)
        .accessibilityLabel(controls.searchResultButtonLabel(forward: forward))
        .accessibilityValue(controls.searchResultAccessibilityValue ?? "")
        .accessibilityHint(controls.searchResultButtonHint(forward: forward) ?? "")
        .help(controls.searchResultButtonHelp(forward: forward))
    }
}

/// The result browser: every result grouped under its section, each with the text around it.
/// Choosing one submits `.showSearchResult`. Pending, empty and failed searches are stated in
/// place of the list. Present it wherever the host has room: the search pane embeds it, and
/// `EPUBSearchResultNavigator` presents it in a popover.
public struct EPUBSearchResultList: View {
    private let controls: EPUBReaderControls
    private let onSelect: (@MainActor (EPUBSearchResult) -> Void)?

    /// `onSelect` runs after a result is submitted, for example to dismiss a sheet covering the reader.
    public init(controls: EPUBReaderControls, onSelect: (@MainActor (EPUBSearchResult) -> Void)? = nil) {
        self.controls = controls; self.onSelect = onSelect
    }

    public var body: some View {
        if let results = controls.searchResults, !results.isEmpty {
            EPUBSearchResultRows(results: results, label: { controls.searchResultAccessibilityLabel(for: $0) }) { result in
                controls.showSearchResult(result)
                onSelect?(result)
            }
            .equatable()
            .disabled(!controls.isReady)
        } else {
            Text(controls.searchResultSummary ?? "No search results")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Search results")
                .accessibilityValue(controls.searchResultAccessibilityValue ?? "No search results")
        }
    }
}

/// Rows are rebuilt only when the results or the current match change, not on every relocation.
struct EPUBSearchResultRows: View, Equatable {
    struct Group: Identifiable, Equatable {
        let id: Int
        let title: String
        let range: Range<Int>
    }

    let results: EPUBSearchResults
    let label: (EPUBSearchResult) -> String
    let select: (EPUBSearchResult) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    nonisolated static func == (a: Self, b: Self) -> Bool { a.results == b.results }

    /// Consecutive results that share a section and its name.
    static func groups(_ results: [EPUBSearchResult]) -> [Group] {
        var groups: [Group] = []
        var start = 0
        while start < results.count {
            let first = results[start]
            var end = start + 1
            while end < results.count, results[end].spineIndex == first.spineIndex,
                  results[end].sectionTitle == first.sectionTitle { end += 1 }
            let title = first.sectionTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Section \(first.spineIndex + 1)"
            groups.append(Group(id: start, title: title, range: start..<end))
            start = end
        }
        return groups
    }

    var body: some View {
        ScrollViewReader { proxy in
            resultList
            .scrollDismissesKeyboard(.immediately)
            .onAppear { if let index = results.currentIndex { proxy.scrollTo(index, anchor: .center) } }
            .onChange(of: results.currentIndex) { _, index in
                if let index { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    @ViewBuilder private var resultList: some View {
        #if os(macOS)
        // Native Mac list traversal needs a selection binding and tagged rows.
        // Keep keyboard, button and accessibility choices on the same result command.
        List(selection: Binding<Int?>(get: { results.currentIndex }, set: { index in
            guard let index, index != results.currentIndex,
                  let result = results.results.first(where: { $0.index == index }) else { return }
            select(result)
        })) { listContent }
        #else
        List { listContent }
        #endif
    }

    @ViewBuilder private var listContent: some View {
        ForEach(Self.groups(results.results)) { group in
            Section(group.title) {
                ForEach(results.results[group.range]) { row($0) }
            }
        }
        if results.isTruncated {
            Text("Only the first \(results.count.formatted()) matches are listed.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func row(_ result: EPUBSearchResult) -> some View {
        #if os(macOS)
        rowButton(result).tag(result.index)
        #else
        rowButton(result)
        #endif
    }

    private func rowButton(_ result: EPUBSearchResult) -> some View {
        let isCurrent = result.index == results.currentIndex
        return Button { select(result) } label: {
            HStack(alignment: .firstTextBaseline) {
                // Accessibility text sizes get room for the whole context, not three short lines.
                Text(Self.snippet(result)).lineLimit(dynamicTypeSize.isAccessibilitySize ? 12 : 3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let page = result.location.page?.label, !page.isEmpty {
                    Text(page).font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark").opacity(isCurrent ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(result.index)
        .accessibilityLabel(label(result))
        .accessibilityValue(isCurrent ? "Current match" : "")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// The occurrence in bold within its context.
    static func snippet(_ result: EPUBSearchResult) -> AttributedString {
        var match = AttributedString(result.matchedText)
        match.inlinePresentationIntent = .stronglyEmphasized
        return AttributedString(result.contextBefore) + match + AttributedString(result.contextAfter)
    }
}

/// The browser as its own presentation: a title, the count and a close button over the list.
/// Choosing a result in a compact width, where the presentation covers the reader, closes it.
struct EPUBSearchResultBrowser: View {
    let controls: EPUBReaderControls
    let onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading) {
            // The count moves under the title where one row would truncate it.
            ViewThatFits(in: .horizontal) {
                HStack { title; Spacer(); count; close }
                VStack(alignment: .leading) {
                    HStack { title; Spacer(); close }
                    count
                }
            }
            EPUBSearchResultList(controls: controls) { _ in if sizeClass == .compact { onClose() } }
        }
        .padding()
        .frame(minWidth: 280, idealWidth: 360, minHeight: 240, idealHeight: 420)
    }

    private var title: some View {
        Text("Search Results").font(.headline).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }

    /// Shown with results only: the list itself states a pending, empty or failed search.
    @ViewBuilder private var count: some View {
        if controls.searchResults?.isEmpty == false, let summary = controls.searchResultSummary {
            Text(summary).monospacedDigit().lineLimit(1).foregroundStyle(.secondary)
                .accessibilityLabel("Search matches")
                .accessibilityValue(controls.searchResultAccessibilityValue ?? summary)
        }
    }

    private var close: some View {
        Button("Close Search Results", systemImage: "xmark", action: onClose)
            .labelStyle(.iconOnly).help("Close Search Results")
    }
}

/// What the search pane adds once a search has results: the match navigator and, when the pane
/// is its own presentation, the result list beneath it. The inline field presents the list from
/// the navigator instead. Closing the pane leaves the query, results and current match alone.
struct EPUBSearchResultPane: View {
    let controls: EPUBReaderControls
    /// Closes the pane when it is a popover or sheet. nil for the inline field.
    let onDismiss: (() -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if controls.searchResults?.isEmpty == false {
            EPUBSearchResultNavigator(controls: controls, showsResultBrowser: onDismiss == nil, showsStatus: false)
            if let onDismiss {
                EPUBSearchResultList(controls: controls) { _ in if sizeClass == .compact { onDismiss() } }
                    .frame(minWidth: 260, idealWidth: 340, minHeight: 160, idealHeight: 320, maxHeight: 480)
            }
        }
    }
}
