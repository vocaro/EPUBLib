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
/// In a compact height, Contents and Appearance show their icons, retaining their accessible
/// names, and groups wrap into rows so a narrow landscape iPhone still leaves room for the book.
///
/// On iPhone and iPad the strip is as tall as its groups wherever it is offered that much, and
/// scrolls them where it is not: its own search field raises the keyboard over a stack that
/// holds the strip with the reader. It has a layout priority of 1, so that such a stack offers
/// it the height it needs before the views beside it. Padding or a frame applied to the strip
/// hides that priority from the stack: set it again after them. On a Mac the strip is as tall
/// as its groups whatever it is offered.
public struct EPUBReaderControlStrip<Extras: View>: View {
    private let controls: EPUBReaderControls
    private let groups: [EPUBReaderControlGroup]
    private let extras: Extras
    #if !os(macOS)
    @State private var fits = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    public init(controls: EPUBReaderControls, groups: [EPUBReaderControlGroup] = EPUBReaderControlGroup.allCases,
                @ViewBuilder extras: () -> Extras) {
        self.controls = controls; self.groups = groups; self.extras = extras()
    }
    public var body: some View {
        #if os(macOS)
        // On a Mac a scroll view is a scroll area in the accessibility tree, one more
        // container round the strip's controls. Nothing raises a keyboard there and text is
        // one size: only a window shorter than the strip is short of room.
        stacked
        #else
        // One scroll view, whether or not the groups fit. A second arrangement to change to as
        // the keyboard comes up would be a second field, without the focus that raised it.
        EPUBControlStripFit {
            ScrollView(.vertical) { EPUBControlStripGroups { stacked } }
                .scrollBounceBehavior(.basedOnSize)
                // With the room they need the groups neither move under a drag nor are clipped,
                // as before the strip could scroll: a control may draw past its own edge.
                .scrollDisabled(fits)
                .scrollClipDisabled(fits)
                .scrollIndicatorsFlash(trigger: fits)
                // Beside a safe area the scroll view reaches into it, and holds its content clear
                // of it with an inset.
                .onScrollGeometryChange(for: Bool.self) {
                    $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom - $0.containerSize.height < 1
                } action: { fits = $1 }
        }
        .layoutPriority(1)
        #endif
    }
    private var stacked: some View {
        VStack(alignment: .leading) {
            #if os(macOS)
            rowOrColumn
            #else
            if verticalSizeClass == .compact {
                EPUBControlStripRows { items }
            } else {
                rowOrColumn
            }
            #endif
            // The strip's own search field already states a search it refused.
            if let error = groups.contains(.search) ? controls.commandErrorBesideSearchFeedback : controls.commandError {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Button("Dismiss error") { controls.dismissError() }
                }.font(.callout)
            }
        }
    }
    private var rowOrColumn: some View {
        ViewThatFits(in: .horizontal) {
            HStack { items }
            VStack(alignment: .leading) { items }
        }
    }
    @ViewBuilder private var items: some View {
        ForEach(groups, id: \.self) { group in stripControl(group) }
        extras
    }
    @ViewBuilder private func stripControl(_ group: EPUBReaderControlGroup) -> some View {
        let control = EPUBReaderControl(controls: controls, group: group, inlineSearch: true)
        #if os(macOS)
        control
        #else
        if verticalSizeClass == .compact, group == .contents || group == .appearance {
            control.labelStyle(.iconOnly)
        } else {
            control
        }
        #endif
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
    private var appearance: some View {
        Menu("Appearance", systemImage: "textformat.size") {
            if controls.supports(.typography) {
                textSizeButton(larger: false)
                textSizeButton(larger: true)
                Toggle("Use System Text Size", isOn: Binding(
                    get: { controls.status?.style.followsDynamicType ?? false },
                    set: { follows in controls.changeStyle { $0.followsDynamicType = follows } }
                ))
                Picker("Appearance", selection: Binding(
                    get: { controls.status?.style.appearance ?? .system },
                    set: { appearance in controls.changeStyle { $0.appearance = appearance } }
                )) {
                    Text("System").tag(EPUBReaderAppearance.system)
                    Text("Light").tag(EPUBReaderAppearance.light)
                    Text("Dark").tag(EPUBReaderAppearance.dark)
                    Text("Sepia").tag(EPUBReaderAppearance.sepia)
                    Text("Black").tag(EPUBReaderAppearance.black)
                    // The reader's own colours, once a host has given some.
                    if controls.status?.style.customColors != nil || controls.status?.style.appearance == .custom {
                        Text("Custom").tag(EPUBReaderAppearance.custom)
                    }
                }
            }
            if controls.isBusy { Text("Applying commands…") }
            if let error = controls.commandError { Text(error) }
        }
    }
    /// Smaller Text or Larger Text, with the size drawn as its second line, which VoiceOver reads
    /// after its name: a menu item's accessibility value is not exposed on iPhone and iPad. A text
    /// after the label is the item's subtitle there; inside the label's title it was dropped. The
    /// menu stays open, so the size can be stepped again under the same finger or cursor; a Mac's
    /// menu closes, as SwiftUI offers no other. The new size drawn is announced once the reader
    /// has taken the style (`stepTextSize`).
    @ViewBuilder private func textSizeButton(larger: Bool) -> some View {
        let button = Button {
            controls.stepTextSize(larger: larger)
        } label: {
            Label(larger ? "Larger Text" : "Smaller Text" as LocalizedStringKey, systemImage: larger ? "textformat.size.larger" : "textformat.size.smaller")
            Text(verbatim: Self.textSizeDescription(controls.drawnTextSize))
        }
        .disabled(!controls.canStepTextSize(larger: larger))
        #if os(iOS)
        button.menuActionDismissBehavior(.disabled)
        #else
        button
        #endif
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
    /// Whether the field has focus once a search is submitted. On a Mac it does. On iPhone and
    /// iPad it gives focus up, in the control strip and in a search pane alike, which puts the
    /// keyboard away: the keyboard covers the page or the results the search is about to show,
    /// and where the strip fills what the keyboard leaves there is no page to tap to dismiss
    /// it. Clear Search returns focus to the field everywhere, to type again.
    static var keepsFocusAfterSearch: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Search in book", text: $controls.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit {
                        controls.submitSearch()
                        // UIKit ends editing on Return, which is what puts the keyboard away.
                        // On a Mac, keep focus in the field once that submission has settled,
                        // without moving it to the reading surface.
                        guard Self.keepsFocusAfterSearch else { return }
                        Task { @MainActor in
                            await Task.yield()
                            focused = true
                        }
                    }
                    .accessibilityLabel("Search in book")
                    .frame(minWidth: 140, idealWidth: 220)
                Button("Search", systemImage: "magnifyingglass") { controls.submitSearch(); focused = Self.keepsFocusAfterSearch }
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
                // The pane has what its sheet or popover leaves above the keyboard. Clear Search
                // and the match navigator grow with the text, and on an iPhone on its side they
                // outgrow that with no list at all. A sheet or popover centres content taller
                // than itself, which cut the field and Close Search off the top: what does not
                // fit under them scrolls there instead.
                EPUBSearchPaneFit(popoverRoom: EPUBSearchResultPane.popoverListRoom(controls)) {
                    ViewThatFits(in: .vertical) {
                        VStack(alignment: .leading) { belowField }
                        ScrollView {
                            VStack(alignment: .leading) { belowField }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollDismissesKeyboard(.immediately)
                    }
                }
            } else { belowField }
        }
        // A search pane was just opened to type in. The inline field is always on screen: taking
        // focus as it appears raised the keyboard over the book as soon as it opened.
        .task { if onDismiss != nil { focused = true } }
    }
    @ViewBuilder private var belowField: some View {
        if onDismiss != nil {
            Button("Clear Search") { controls.clearSearch(); focused = true }
        }
        feedback.font(.callout)
        if let error = controls.commandErrorBesideSearchFeedback { Text(error).foregroundStyle(.red).font(.callout) }
        EPUBSearchResultPane(controls: controls, onDismiss: onDismiss)
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

/// Compact-height groups keep their order in rows. A single row at the largest text size is
/// wider than an iPhone SE even with icon-only menus; a full column leaves no whole book line.
/// Measure each group at its ideal width (or the offered width for a group wider than that)
/// and wrap before the next group, keeping every group's own text size and controls whole.
private struct EPUBControlStripRows: Layout {
    private struct Arrangement {
        var frames: [CGRect] = []
        var size: CGSize = .zero
    }
    private func arrangement(width: CGFloat?, subviews: Subviews) -> Arrangement {
        let room = width ?? .greatestFiniteMagnitude
        var result = Arrangement()
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(ideal.width, room), height: nil))
            if x > 0, x + size.width > room + 0.5 {
                x = 0
                y += rowHeight + 8
                rowHeight = 0
            }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            result.frames.append(frame)
            result.size.width = max(result.size.width, frame.maxX)
            result.size.height = max(result.size.height, frame.maxY)
            rowHeight = max(rowHeight, size.height)
            x += size.width + 8
        }
        return result
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrangement(width: proposal.width ?? bounds.width, subviews: subviews)
        for (view, frame) in zip(subviews, rows.frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }
}

/// Makes the control strip, which is one scroll view of its groups, as tall as the groups
/// wherever it is offered that much and no taller than it is offered, so that the groups scroll
/// only where they do not fit.
///
/// A scroll view takes the size it is offered. Offered no height, it answers with the size of
/// its content at the width offered, and that width is the strip's too: a strip with nothing in
/// it that takes the width offered, as one without its search field, stays as wide as its groups.
///
/// Groups that are over by less than a point are given their own height, so that a height a
/// host rounded does not make them scroll.
struct EPUBControlStripFit: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let scroller = subviews.first else { return .zero }
        let groups = scroller.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        guard let height = proposal.height, groups.height - height >= 1 else { return groups }
        return CGSize(width: groups.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Holds the strip's groups inside its scroll view, which is exactly as wide as they are, and
/// offers them what a scroll view does not.
///
/// A scroll view offers its content no height, and a label that does not fit its line then
/// takes a second. In a stack that offers the strip an equal share with the reader the groups
/// had less height than that and each label kept to one line: on an iPhone SE upright at the
/// largest text size the strip was 340 points tall there, and would be 401 with Appearance on
/// two lines. So the groups are offered no height at all, and are as tall as they were.
///
/// The scroll view is a platform view: its edges are rounded to whole pixels, and its content
/// is laid out in the width that leaves, which can be a fraction of a point less than the
/// groups measure. A row of them then no longer fits and becomes a column, as one did in a
/// scroll view of 385⅓ points, and a label a hair short of its width takes a second line or
/// is cut short. So the groups are offered a point more than the scroll view has, wherever
/// they are then no more than half a point wider than it, which is as much as the rounding
/// takes. Groups that take the width they are offered, as those with a search field do, are
/// offered what there is.
struct EPUBControlStripGroups: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let groups = subviews.first else { return .zero }
        return groups.sizeThatFits(offer(proposal.width, to: groups))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let groups = subviews.first else { return }
        let width = offer(proposal.width ?? bounds.width, to: groups).width
        groups.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: bounds.height))
    }

    private func offer(_ width: CGFloat?, to groups: LayoutSubview) -> ProposedViewSize {
        // Asked for their ideal size, the groups have no width to wrap a label in.
        guard let width else { return .unspecified }
        let roomier = ProposedViewSize(width: width + 1, height: 0)
        return groups.sizeThatFits(roomier).width <= width + 0.5 ? roomier : ProposedViewSize(width: width, height: 0)
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
