import EPUBCore
import SwiftUI

public enum EPUBReaderControlGroup: String, CaseIterable, Hashable, Sendable {
    case pages, search, contents, appearance, readingMode
}

/// Order and omit groups using `groups`; placement applies to each group's toolbar item.
/// Separate toolbar instances may use different placements. Hosts can add their own items.
public struct EPUBReaderToolbar: ToolbarContent {
    private let controls: EPUBReaderControls
    private let groups: [EPUBReaderControlGroup]
    private let placement: ToolbarItemPlacement
    public init(controls: EPUBReaderControls, groups: [EPUBReaderControlGroup] = EPUBReaderControlGroup.allCases,
                placement: ToolbarItemPlacement = .automatic) {
        self.controls = controls; self.groups = groups; self.placement = placement
    }
    public var body: some ToolbarContent {
        ForEach(groups, id: \.self) { group in
            if group == .pages {
                if controls.supports(.pagination) || controls.supports(.scrolling) {
                    #if os(macOS)
                    ToolbarItemGroup(placement: placement) {
                        EPUBPageButton(controls: controls, forward: controls.isRightToLeft)
                        EPUBPageButton(controls: controls, forward: !controls.isRightToLeft)
                    }
                    .visibilityPriority(.init(higherThan: .high))
                    #else
                    ToolbarItem(placement: placement) {
                        // A pinned placement accepts one item. Keep both arrows in it so
                        // neither replaces the other or overflows separately.
                        EPUBReaderControl(controls: controls, group: .pages)
                    }
                    .visibilityPriority(.init(higherThan: .high))
                    #endif
                }
            } else {
                ToolbarItem(placement: placement) {
                    EPUBReaderControl(controls: controls, group: group).labelStyle(.iconOnly)
                }
                // A segmented picker has no automatic overflow-menu representation.
                .visibilityPriority(group == .readingMode ? .high : .automatic)
            }
        }
        // Keep command progress in the controls themselves. Inserting a transient toolbar
        // item shifts the buttons and their anchored popovers on every submission.
        if controls.commandError != nil {
            ToolbarItem(placement: placement) { EPUBReaderCommandFeedback(controls: controls) }
        }
    }
}

/// An embedded alternative. At narrow widths groups stack vertically, including host items,
/// preserving text size and search focus without clipping controls into a horizontal scroller.
public struct EPUBReaderControlStrip<Extras: View>: View {
    private let controls: EPUBReaderControls
    private let groups: [EPUBReaderControlGroup]
    private let extras: Extras
    public init(controls: EPUBReaderControls, groups: [EPUBReaderControlGroup] = EPUBReaderControlGroup.allCases,
                @ViewBuilder extras: () -> Extras) {
        self.controls = controls; self.groups = groups; self.extras = extras()
    }
    public var body: some View {
        VStack(alignment: .leading) {
            ViewThatFits(in: .horizontal) {
                HStack { items }
                VStack(alignment: .leading) { items }
            }
            // The strip's own search field already states a search it refused.
            if let error = groups.contains(.search) ? controls.commandErrorBesideSearchFeedback : controls.commandError {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Button("Dismiss error") { controls.dismissError() }
                }.font(.callout)
            }
        }
    }
    @ViewBuilder private var items: some View {
        ForEach(groups, id: \.self) { group in EPUBReaderControl(controls: controls, group: group, inlineSearch: true) }
        extras
    }
}

public extension EPUBReaderControlStrip where Extras == EmptyView {
    init(controls: EPUBReaderControls, groups: [EPUBReaderControlGroup] = EPUBReaderControlGroup.allCases) {
        self.init(controls: controls, groups: groups) { EmptyView() }
    }
}

/// Individual groups let hosts customize labels/icons by composing their own buttons with
/// the public controls model, and mix built-in groups with custom toolbar/overflow items.
public struct EPUBReaderControl: View {
    private let controls: EPUBReaderControls
    private let group: EPUBReaderControlGroup
    private let inlineSearch: Bool
    @State private var showingSearch = false
    public init(controls: EPUBReaderControls, group: EPUBReaderControlGroup, inlineSearch: Bool = false) {
        self.controls = controls; self.group = group; self.inlineSearch = inlineSearch
    }
    public var body: some View {
        Group {
            switch group {
            case .pages:
                if controls.supports(.pagination) || controls.supports(.scrolling) { pages }
            case .search:
                if controls.supports(.search) || controls.supports(.searchHighlight) {
                    if inlineSearch { EPUBSearchField(controls: controls) }
                    else {
                        Button("Search", systemImage: "magnifyingglass") { showingSearch = true }
                            .popover(isPresented: $showingSearch) {
                                EPUBSearchField(controls: controls, onDismiss: { showingSearch = false }).padding()
                                    // As a sheet the pane is offered the whole height and was centred
                                    // in it: the field jumped to the top when results arrived and back
                                    // to the middle on Clear Search. A popover keeps its ideal size.
                                    .frame(maxHeight: .infinity, alignment: .top)
                            }
                    }
                }
            case .contents:
                if controls.supports(.navigateHref) { contents }
            case .appearance:
                if controls.supports(.typography) { appearance }
            case .readingMode:
                if controls.supports(.pagination) && controls.supports(.scrolling) { readingMode }
            }
        }
        .disabled(!controls.isReady)
    }
    private var pages: some View {
        HStack {
            EPUBPageButton(controls: controls, forward: false)
            EPUBPageButton(controls: controls, forward: true)
        }
        // Fixed logical order, reversed physically for RTL books, independent of UI language.
        .environment(\.layoutDirection, controls.isRightToLeft ? .rightToLeft : .leftToRight)
        .labelStyle(.iconOnly)
    }
    private var contents: some View {
        Menu("Contents", systemImage: "list.bullet") {
            if controls.publication.tableOfContents.isEmpty { Text("No contents available") }
            else { EPUBContentsItems(controls: controls, items: controls.publication.tableOfContents) }
        }
    }
    /// The supplied text sizes: what the bundled reader draws at distinct sizes, up to 36 points.
    /// It draws nothing smaller than 12, so a step below that changed the style and not the page.
    static let textSizes: ClosedRange<Double> = 12...36
    static func textSize(_ size: Double, steppedBy points: Double) -> Double {
        let drawn = min(max(size, textSizes.lowerBound), textSizes.upperBound)
        return min(max(drawn + points, textSizes.lowerBound), textSizes.upperBound)
    }
    private var appearance: some View {
        Menu("Appearance", systemImage: "textformat.size") {
            if controls.supports(.typography) {
                let size = controls.status?.style.fontSize ?? EPUBReaderStyle().fontSize
                Button("Smaller Text", systemImage: "textformat.size.smaller") {
                    controls.changeStyle { $0.fontSize = Self.textSize($0.fontSize, steppedBy: -2) }
                }
                .disabled(size <= Self.textSizes.lowerBound)
                Button("Larger Text", systemImage: "textformat.size.larger") {
                    controls.changeStyle { $0.fontSize = Self.textSize($0.fontSize, steppedBy: 2) }
                }
                .disabled(size >= Self.textSizes.upperBound)
                Picker("Appearance", selection: Binding(
                    get: { controls.status?.style.appearance ?? .system },
                    set: { appearance in controls.changeStyle { $0.appearance = appearance } }
                )) {
                    Text("System").tag(EPUBReaderAppearance.system)
                    Text("Light").tag(EPUBReaderAppearance.light)
                    Text("Dark").tag(EPUBReaderAppearance.dark)
                }
            }
            if controls.isBusy { Text("Applying commands…") }
            if let error = controls.commandError { Text(error) }
        }
    }
    private var readingMode: some View {
        Picker("Reading Mode", selection: Binding(
            get: { controls.status?.style.flow ?? .paginated },
            set: { mode in controls.changeStyle { $0.flow = mode } }
        )) {
            modeLabel("Continuous Scroll", systemImage: "scroll")
                .tag(EPUBReadingFlow.scrolled)
                .help("Continuous Scroll")
            modeLabel("Paging", systemImage: "doc.text")
                .tag(EPUBReadingFlow.paginated)
                .help("Paging")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .labelStyle(.iconOnly)
        .fixedSize(horizontal: true, vertical: false)
    }
    /// An icon-only segment is named after its image: on Mac the symbol's own description
    /// ("Text document"), whatever SwiftUI label the segment has. The image carries the mode's name.
    private func modeLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            #if os(macOS)
            if let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title) {
                Image(nsImage: image)
            } else { Image(systemName: systemImage) }
            #else
            Image(systemName: systemImage)
            #endif
        }
    }
}

private struct EPUBPageButton: View {
    let controls: EPUBReaderControls
    let forward: Bool
    @Environment(\.epubReaderPageControls) private var pageControls
    private var action: EPUBPageAction { forward ? .next : .previous }
    var body: some View {
        Button(controls.pageButtonLabel(for: action),
               systemImage: (forward != controls.isRightToLeft) ? "chevron.right" : "chevron.left") {
            controls.send(forward ? .nextPage : .previousPage)
        }
        .labelStyle(.iconOnly)
        .disabled(forward ? !controls.canGoNext : !controls.canGoPrevious)
        .accessibilityLabel(controls.pageButtonLabel(for: action))
        .help(controls.pageButtonHelp(for: action, pageControls: pageControls))
    }
}

private struct EPUBContentsItems: View {
    let controls: EPUBReaderControls
    let items: [EPUBNavigationItem]
    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.children.isEmpty { entry(item) }
            else {
                Menu(item.title) {
                    if item.href != nil { entry(item) }
                    EPUBContentsItems(controls: controls, items: item.children)
                }
            }
        }
    }
    private func entry(_ item: EPUBNavigationItem) -> some View {
        Button {
            if let href = item.href { controls.send(.navigate(href: href)) }
        } label: {
            if controls.isCurrent(item) { Label(item.title, systemImage: "checkmark") }
            else { Text(item.title) }
        }
        .disabled(item.href == nil)
        .accessibilityValue(controls.isCurrent(item) ? "Current section" : "")
    }
}

struct EPUBSearchField: View {
    @Bindable var controls: EPUBReaderControls
    var onDismiss: (() -> Void)? = nil
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Search in book", text: $controls.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit {
                        controls.submitSearch()
                        // UIKit ends editing on Return. Restore focus after that submission
                        // has settled, without moving focus to the reading surface.
                        Task { @MainActor in
                            await Task.yield()
                            focused = true
                        }
                    }
                    .accessibilityLabel("Search in book")
                    .frame(minWidth: 140, idealWidth: 220)
                Button("Search", systemImage: "magnifyingglass") { controls.submitSearch(); focused = true }
                    .labelStyle(.iconOnly).help("Search")
                if let onDismiss {
                    Button("Close Search", systemImage: "xmark") {
                        #if !os(macOS)
                        focused = false
                        #endif
                        // AppKit restores the popover's opening responder on dismissal.
                        // Clearing FocusState first discards that restoration and can also
                        // clear an intentional destination in the owner window.
                        onDismiss()
                    }
                    .labelStyle(.iconOnly).help("Close Search")
                } else {
                    Button("Clear Search", systemImage: "xmark.circle") { controls.clearSearch(); focused = true }
                        .labelStyle(.iconOnly).help("Clear Search")
                }
            }
            if onDismiss != nil {
                Button("Clear Search") { controls.clearSearch(); focused = true }
            }
            feedback.font(.callout)
            if let error = controls.commandErrorBesideSearchFeedback { Text(error).foregroundStyle(.red).font(.callout) }
            EPUBSearchResultPane(controls: controls, onDismiss: onDismiss)
        }
        // A search pane was just opened to type in. The inline field is always on screen: taking
        // focus as it appears raised the keyboard over the book as soon as it opened.
        .task { if onDismiss != nil { focused = true } }
    }
    @ViewBuilder private var feedback: some View {
        switch controls.status?.search ?? .idle {
        case .idle:
            if controls.pendingSearches > 0 { Text("Search queued…") }
        case .searching: HStack { ProgressView().controlSize(.small); Text("Searching…") }
        case .completed(_, let found):
            if !found { Text("No matches") }
        case .failed(_, let error): Text(error.message).foregroundStyle(.red)
        }
    }
}

private struct EPUBReaderCommandFeedback: View {
    let controls: EPUBReaderControls
    var body: some View {
        if let error = controls.commandError {
            Menu("Reader Error", systemImage: "exclamationmark.circle") {
                Text(error)
                Button("Dismiss error") { controls.dismissError() }
            }.labelStyle(.iconOnly).accessibilityValue(error)
        }
    }
}
