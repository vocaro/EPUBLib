import EPUBCore
import SwiftUI

// The reader's commands in the menu bar of a Mac and an iPad, with their shortcuts
// (doc/reader-controls.md, "Menu bar commands").

/// The reader's commands in the menu bar on a Mac and on an iPad, each in a fixed place, dimmed
/// while it cannot run, and acting on the reader of the window in front:
///
/// - Edit > Find: Find… (Command-F), Find Next (Command-G) and Find Previous (Shift-Command-G).
/// - View: Larger Text (Command-+), Smaller Text (Command--), Actual Size (Command-0), Use System
///   Text Size, the Appearance submenu, and Continuous Scroll (Command-1) and Paging (Command-2).
/// - Go: Previous Page (Page Up), Next Page (Page Down), First Page (Home), Last Page (End), and
///   the Contents submenu. In continuous scroll the four are named as the page buttons are there.
///
/// Add it to the scene with `.commands { EPUBReaderMenuCommands() }`, and apply
/// `epubReaderMenuCommands(_:)` to the view that holds each reader, which names the controls the
/// commands act on while its window is in front.
public struct EPUBReaderMenuCommands: Commands {
    @FocusedValue(EPUBReaderControls.self) private var controls

    public init() {}

    public var body: some Commands {
        // After the pasteboard's items, not after `.textEditing`: on an iPad a group placed by
        // `.textEditing` has SwiftUI add the system's own Find, Find Next and Find Previous, with
        // these shortcuts, and UIKit's menu builder then refused these items for having them.
        CommandGroup(after: .pasteboard) {
            Section {
                Menu("Find") {
                    EPUBReaderMenuItem(.find, controls)
                    EPUBReaderMenuItem(.findNext, controls)
                    EPUBReaderMenuItem(.findPrevious, controls)
                }
            }
        }
        CommandGroup(before: .toolbar) {
            EPUBReaderViewMenuItems(controls: controls)
        }
        CommandMenu("Go") {
            EPUBReaderGoMenuItems(controls: controls)
        }
    }
}

public extension View {
    /// Has `EPUBReaderMenuCommands` act on `controls` while this view's window is in front. Apply
    /// it to the view that holds the reader and its controls, once for each reader: it is
    /// `focusedSceneValue(controls)`, which a host's own commands read with
    /// `@FocusedValue(EPUBReaderControls.self)`.
    func epubReaderMenuCommands(_ controls: EPUBReaderControls) -> some View {
        focusedSceneValue(controls)
    }
}

public extension EPUBReaderControls {
    /// Whether Find has a search field to show: the reader is ready and searches, and a supplied
    /// search group (`EPUBReaderControlGroup.search`) is on screen, in a toolbar or a strip.
    var canFind: Bool {
        isReady && (supports(.search) || supports(.searchHighlight)) && !findTargets.isEmpty
    }

    /// Find: opens the search group's pane, or puts focus in a control strip's search field. Of
    /// several search groups on screen, the one that appeared last. Hidden controls show first.
    /// Nothing happens while `canFind` is false.
    func find() {
        guard canFind else { return }
        showControls()
        findRequests += 1
    }
}

extension EPUBReaderControls {
    /// Whether the text size and the appearance can be changed: the reader is ready and takes
    /// typography.
    var canChangeStyle: Bool { isReady && supports(.typography) }

    /// Whether the reading mode can be changed: the reader is ready and has both modes.
    var canChangeFlow: Bool { isReady && supports(.pagination) && supports(.scrolling) }

    /// Whether the book's first page can be shown: the reader goes to a progression and is not
    /// known to be there already.
    var canGoToBookStart: Bool { isReady && supports(.goToProgression) && status?.canGoPrevious != false }

    /// Whether the book's last page can be shown.
    var canGoToBookEnd: Bool { isReady && supports(.goToProgression) && status?.canGoNext != false }

    /// Whether the contents entries can be shown.
    var canShowContents: Bool { isReady && supports(.navigateHref) }

    func addFindTarget(_ id: UUID) {
        findTargets.removeAll { $0 == id }
        findTargets.append(id)
    }

    func removeFindTarget(_ id: UUID) {
        findTargets.removeAll { $0 == id }
    }
}

/// A command of `EPUBReaderMenuCommands` with a shortcut: what it is called, its key, whether it
/// can run and what it does. Each is called what the supplied controls call the same command, so
/// one command has one name, and that name is what VoiceOver reads of the menu item.
enum EPUBReaderMenuCommand: CaseIterable, Hashable {
    case previousPage, nextPage, bookStart, bookEnd
    case find, findNext, findPrevious
    case largerText, smallerText, actualSize
    case continuousScroll, paging

    /// The page turns are named by the reading flow, as the page buttons are: Previous Page, or
    /// Scroll Backward in continuous scroll. Without a reader they have their paginated names.
    @MainActor func title(_ controls: EPUBReaderControls?) -> String {
        let flow = controls?.status?.style.flow ?? .paginated
        return switch self {
        case .previousPage: EPUBPageAction.previous.label(in: flow)
        case .nextPage: EPUBPageAction.next.label(in: flow)
        case .bookStart: EPUBPageAction.bookStart.label(in: flow)
        case .bookEnd: EPUBPageAction.bookEnd.label(in: flow)
        case .find: "Find…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .largerText: "Larger Text"
        case .smallerText: "Smaller Text"
        case .actualSize: "Actual Size"
        case .continuousScroll: "Continuous Scroll"
        case .paging: "Paging"
        }
    }

    /// The platform's own: Find, Find Next and Find Previous have the Edit menu's, and the text
    /// size the Command-+, Command-- and Command-0 of Zoom In, Zoom Out and Actual Size in Preview's
    /// View menu, where Continuous Scroll and Single Page have Command-1 and Command-2. The page
    /// keys are those of the reader's own (`EPUBPageKeyBinding.defaults`) that no text field edits
    /// with, as Preview's Go menu takes Page Up and Page Down. A Mac offers a menu's Command chords
    /// before the keys of the view with focus, and the arrows, Space, Command-Up and Command-Down
    /// move a field's cursor or type in it.
    var shortcut: KeyboardShortcut {
        switch self {
        case .previousPage: KeyboardShortcut(.pageUp, modifiers: [])
        case .nextPage: KeyboardShortcut(.pageDown, modifiers: [])
        case .bookStart: KeyboardShortcut(.home, modifiers: [])
        case .bookEnd: KeyboardShortcut(.end, modifiers: [])
        case .find: KeyboardShortcut("f")
        case .findNext: KeyboardShortcut("g")
        case .findPrevious: KeyboardShortcut("g", modifiers: [.command, .shift])
        case .largerText: KeyboardShortcut("+")
        case .smallerText: KeyboardShortcut("-")
        case .actualSize: KeyboardShortcut("0")
        case .continuousScroll: KeyboardShortcut("1")
        case .paging: KeyboardShortcut("2")
        }
    }

    /// Whether it can run for the reader in front. Nothing runs without one.
    @MainActor func isEnabled(_ controls: EPUBReaderControls?) -> Bool {
        guard let controls else { return false }
        return switch self {
        case .previousPage: controls.canGoPrevious
        case .nextPage: controls.canGoNext
        case .bookStart: controls.canGoToBookStart
        case .bookEnd: controls.canGoToBookEnd
        case .find: controls.canFind
        case .findNext, .findPrevious: controls.canShowSearchResults
        case .largerText: controls.canChangeStyle && controls.canStepTextSize(larger: true)
        case .smallerText: controls.canChangeStyle && controls.canStepTextSize(larger: false)
        case .actualSize: controls.canResetTextSize
        case .continuousScroll, .paging: controls.canChangeFlow
        }
    }

    /// The reading mode it chooses, for a menu item checked while that mode is in use.
    var flow: EPUBReadingFlow? {
        switch self {
        case .continuousScroll: .scrolled
        case .paging: .paginated
        default: nil
        }
    }

    /// Submits the command through the controls' queue. Nothing where it cannot run, or for the
    /// reading mode already in use.
    @MainActor func perform(_ controls: EPUBReaderControls) {
        guard isEnabled(controls) else { return }
        switch self {
        case .previousPage: controls.send(.previousPage)
        case .nextPage: controls.send(.nextPage)
        case .bookStart: controls.send(.goToStart)
        case .bookEnd: controls.send(.goToEnd)
        case .find: controls.find()
        case .findNext: controls.showNextSearchResult()
        case .findPrevious: controls.showPreviousSearchResult()
        case .largerText: controls.stepTextSize(larger: true)
        case .smallerText: controls.stepTextSize(larger: false)
        case .actualSize: controls.resetTextSize()
        case .continuousScroll, .paging:
            guard let flow, controls.status?.style.flow != flow else { return }
            controls.changeStyle { $0.flow = flow }
        }
    }
}

/// One command as a menu item with its shortcut: a button, or for a reading mode an item
/// checked while the mode is in use.
private struct EPUBReaderMenuItem: View {
    let command: EPUBReaderMenuCommand
    let controls: EPUBReaderControls?

    init(_ command: EPUBReaderMenuCommand, _ controls: EPUBReaderControls?) {
        self.command = command; self.controls = controls
    }

    var body: some View {
        Group {
            if let flow = command.flow {
                Toggle(command.title(controls), isOn: Binding(
                    get: { controls?.status?.style.flow == flow },
                    set: { _ in perform() }
                ))
            } else {
                Button(command.title(controls)) { perform() }
            }
        }
        .keyboardShortcut(command.shortcut)
        .disabled(!command.isEnabled(controls))
    }

    private func perform() {
        if let controls { command.perform(controls) }
    }
}

/// The View menu's items: the text size, the appearance and the reading mode, each a section. On
/// an iPad the items of a group placed before the toolbar's went into the toolbar's own section
/// one at a time, last first, and a picker's choices stood in the View menu without its name.
private struct EPUBReaderViewMenuItems: View {
    let controls: EPUBReaderControls?

    var body: some View {
        Section {
            EPUBReaderMenuItem(.largerText, controls)
            EPUBReaderMenuItem(.smallerText, controls)
            EPUBReaderMenuItem(.actualSize, controls)
            Toggle("Use System Text Size", isOn: Binding(
                get: { controls?.status?.style.followsDynamicType ?? false },
                set: { follows in controls?.changeStyle { $0.followsDynamicType = follows } }
            ))
            .disabled(controls?.canChangeStyle != true)
        }
        Section {
            Picker("Appearance", selection: Binding(
                get: { controls?.status?.style.appearance ?? .system },
                set: { appearance in controls?.changeStyle { $0.appearance = appearance } }
            )) {
                EPUBAppearanceChoices(controls: controls)
            }
            .pickerStyle(.menu)
            .disabled(controls?.canChangeStyle != true)
        }
        Section {
            EPUBReaderMenuItem(.continuousScroll, controls)
            EPUBReaderMenuItem(.paging, controls)
        }
    }
}

/// The Go menu's items: the page turns, the book's start and end, and its contents.
private struct EPUBReaderGoMenuItems: View {
    let controls: EPUBReaderControls?

    var body: some View {
        EPUBReaderMenuItem(.previousPage, controls)
        EPUBReaderMenuItem(.nextPage, controls)
        EPUBReaderMenuItem(.bookStart, controls)
        EPUBReaderMenuItem(.bookEnd, controls)
        Divider()
        // A submenu stays enabled on a Mac, to be looked into: its items are what is dimmed, and
        // with no reader in front it holds one, dimmed, rather than nothing.
        Menu("Contents") {
            if let controls, !controls.publication.tableOfContents.isEmpty {
                EPUBContentsItems(controls: controls, items: controls.publication.tableOfContents)
            } else {
                Button("No contents available") {}.disabled(true)
            }
        }
        .disabled(controls?.canShowContents != true)
    }
}

/// Registers a search group as a Find target while it is on screen, and does what Find asks of it.
struct EPUBFindTarget: ViewModifier {
    let controls: EPUBReaderControls
    let id: UUID
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { controls.addFindTarget(id) }
            .onDisappear { controls.removeFindTarget(id) }
            .onChange(of: controls.findRequests) {
                guard controls.findTargets.last == id else { return }
                // A turn later, so that a toolbar Find has just shown again can present the pane.
                Task { @MainActor in
                    await Task.yield()
                    action()
                }
            }
    }
}
