import Combine
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Hiding the supplied controls while a book is read, and bringing them back
// (doc/reader-controls.md, "Hiding the controls while reading").

public extension EPUBReaderControls {
    /// Whether the controls are hidden: asked for by `hideControls()`, and only while the reader
    /// is ready, so that a book that closes or fails shows them again with its state.
    /// `epubReaderHidesControls(_:whileReading:)` hides the bars and the toolbar for it, and the
    /// control strip hides its groups in place.
    var controlsHidden: Bool { controlsHiddenRequested && isReady }

    /// Hides the controls, until `showControls()`. Nothing while the reader is not ready.
    func hideControls() {
        guard isReady, !controlsHiddenRequested else { return }
        controlsHiddenRequested = true
    }

    /// Brings hidden controls back.
    func showControls() {
        guard controlsHiddenRequested else { return }
        controlsHiddenRequested = false
    }

    /// Hides the controls when they show, and shows them when they are hidden: what a tap in the
    /// middle of the page, VoiceOver's Magic Tap and, on iPhone and iPad, Option-Command-T do.
    func toggleControls() {
        if controlsHidden { showControls() } else { hideControls() }
    }
}

extension EPUBReaderControls {
    /// The person read on with the reader's own input: a page turned by a key, a swipe, an edge
    /// or the wheel, or continuous scroll dragged or wheeled. The controls hide, unless VoiceOver
    /// or Switch Control is running: hidden, their items are gone from what either can reach.
    func readerDidReadOn() {
        guard !assistiveTechnologyIsRunning() else { return }
        hideControls()
    }

    /// VoiceOver or Switch Control is running.
    static var assistiveTechnologyKeepsControls: Bool {
        #if os(iOS)
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        #else
        NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
        #endif
    }
}

/// What the reader under `epubReaderHidesControls(_:whileReading:)` tells the controls: a tap in
/// the middle of the page, VoiceOver's Magic Tap, and reading on. The controls are held weakly:
/// they hold the session, whose view reads this.
struct EPUBReaderControlsHiding: Equatable {
    weak var controls: EPUBReaderControls?
    var whileReading: Bool

    static func == (a: Self, b: Self) -> Bool { a.controls === b.controls && a.whileReading == b.whileReading }
}

extension EnvironmentValues {
    @Entry var epubReaderControlsHiding: EPUBReaderControlsHiding? = nil
    /// `epubReaderHidesControls` shows the Show Controls button in the room the bars left, so a
    /// control strip under it does not show a second one.
    @Entry var epubReaderShowsControlsButtonAbove = false
}

public extension View {
    #if os(macOS)
    /// Hides the reader's controls on command, and brings them back: on a Mac the window's own
    /// View > Hide Toolbar and Show Toolbar, Option-Command-T, hide and show them all.
    ///
    /// Apply it to the view that holds the reader and its controls, after (outside) its
    /// `.toolbar`, as `epubReaderPageControls(_:)` is. While `controls.controlsHidden` is true the
    /// window toolbar is hidden, as View > Hide Toolbar hides it, and a control strip hides its
    /// groups in place. The reader keeps the room the toolbar took, so the book is not laid out
    /// again and no bar ever sits over its text, and a Show Controls button stands in that room.
    ///
    /// With `whileReading`, which is false on a Mac, the controls also hide as the person reads on:
    /// a page turned by a key, an edge click or the wheel, or continuous scroll wheeled, except
    /// while VoiceOver or Switch Control is running.
    func epubReaderHidesControls(_ controls: EPUBReaderControls, whileReading: Bool = false) -> some View {
        modifier(EPUBReaderControlsHidingModifier(controls: controls, whileReading: whileReading))
    }
    #else
    /// Hides the reader's controls while the book is read, and brings them back.
    ///
    /// Apply it to the view that holds the reader and its controls, after (outside) its
    /// `.toolbar`, as `epubReaderPageControls(_:)` is. While `controls.controlsHidden` is true it
    /// hides the navigation bar, the bottom bar, the status bar and the home indicator, and a
    /// control strip hides its groups in place. The reader keeps the room the bars took, so the
    /// book is not laid out again and no bar ever sits over its text, and a Show Controls button
    /// stands in that room.
    ///
    /// With `whileReading` the controls hide as the person reads on: a page turned by a key, a
    /// swipe, an edge tap or the wheel, or continuous scroll dragged, except while VoiceOver or
    /// Switch Control is running. A tap in the middle of the page shows them and hides them again,
    /// as do VoiceOver's Magic Tap, Option-Command-T, and the Hide Controls group
    /// (`EPUBReaderControlGroup.hideControls`) and Show Controls button.
    func epubReaderHidesControls(_ controls: EPUBReaderControls, whileReading: Bool = true) -> some View {
        modifier(EPUBReaderControlsHidingModifier(controls: controls, whileReading: whileReading))
    }
    #endif
}

/// The room the bars take, kept for the reader while they are hidden.
///
/// The reader is laid out inside the safe area the bars leave it. Hidden, they would leave it
/// more, and it would be laid out again: a book paginated afresh at each tap, and VoiceOver's
/// items made new. Nor do the bars go or come back at once: the navigation bar and the bottom bar
/// change the safe area in separate layouts, and a measure of each comes a layout after it. So
/// while the controls are hidden, and until the bars are back, the reader is pinned: it is laid
/// out in the safe area measured while they last showed (`kept`), whatever the bars do, and the
/// room they leave is the host's background with the Show Controls button in it.
struct EPUBControlsRoom: Equatable {
    struct Measure: Equatable {
        var width: CGFloat
        var insets: EdgeInsets
    }

    /// The safe area while the controls last showed.
    private(set) var kept: EdgeInsets?
    /// The safe area as it is now, which the bars change.
    private(set) var live: EdgeInsets?
    private var width: CGFloat?
    /// The reader is laid out in `kept`: from when the controls hide until the bars are back.
    private(set) var pinned = false

    /// The safe area the reader is laid out in, while it is not the live one.
    func pin(hidden: Bool) -> EdgeInsets? {
        hidden || pinned ? kept : nil
    }

    /// The room the bars left at the top and the bottom, where the Show Controls button can stand.
    func room(hidden: Bool) -> (top: CGFloat, bottom: CGFloat) {
        guard let pin = pin(hidden: hidden), let live else { return (0, 0) }
        return (max(0, pin.top - live.top), max(0, pin.bottom - live.bottom))
    }

    /// Takes a measure of the live safe area. True when the width changed while the controls are
    /// hidden: what was kept is for another width, and the controls are to show again.
    mutating func measured(_ measure: Measure, hidden: Bool) -> Bool {
        let resized = width.map { abs($0 - measure.width) >= 0.5 } ?? false
        width = measure.width
        live = measure.insets
        // A new width lays the reader out again whatever is kept, as a rotation does.
        if resized || (pinned && !hidden && kept.map({ measure.insets.top >= $0.top - 0.5 && measure.insets.bottom >= $0.bottom - 0.5 }) ?? true) {
            pinned = false
        }
        if !hidden, !pinned { kept = measure.insets }
        return resized && hidden
    }

    /// The controls were hidden or shown. Shown, the reader stays pinned until the bars are back.
    mutating func controlsChanged(hidden: Bool) {
        if hidden { pinned = kept != nil }
    }

    /// The bars did not come back as they were, as when the host changed them meanwhile: the
    /// reader takes the live safe area.
    mutating func unpin() {
        guard pinned else { return }
        pinned = false
        if let live { kept = live }
    }
}

private struct EPUBReaderControlsHidingModifier: ViewModifier {
    let controls: EPUBReaderControls
    let whileReading: Bool
    @State private var room = EPUBControlsRoom()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The least room in which the Show Controls button stands. A Mac's toolbar leaves about 24
    /// points under the title bar.
    static let buttonRoom: CGFloat = 20

    func body(content: Content) -> some View {
        let hidden = controls.controlsHidden
        let pin = room.pin(hidden: hidden)
        let left = room.room(hidden: hidden)
        let buttonAbove = hidden && left.top >= Self.buttonRoom
        let buttonBelow = hidden && !buttonAbove && left.bottom >= Self.buttonRoom
        content
            .environment(\.epubReaderControlsHiding, EPUBReaderControlsHiding(controls: controls, whileReading: whileReading))
            .environment(\.epubReaderShowsControlsButtonAbove, buttonAbove || buttonBelow)
            // Pinned, the reader leaves the live safe area for the one kept. The modifiers stay
            // whether or not it is, so that the reader is never made again.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let pin { roomKept(pin.top, left: left.top, edge: .top, button: buttonAbove) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let pin { roomKept(pin.bottom, left: left.bottom, edge: .bottom, button: buttonBelow) }
            }
            .ignoresSafeArea(.container, edges: pin == nil ? [] : .vertical)
            .onGeometryChange(for: EPUBControlsRoom.Measure.self) {
                EPUBControlsRoom.Measure(width: $0.size.width, insets: $0.safeAreaInsets)
            } action: { measure in
                if room.measured(measure, hidden: controls.controlsHidden) { controls.showControls() }
            }
            .onChange(of: hidden) { _, hidden in room.controlsChanged(hidden: hidden) }
            .task(id: room.pinned && !hidden) {
                // Shown, the bars are back within their animation.
                guard room.pinned, !controls.controlsHidden else { return }
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled, !controls.controlsHidden { room.unpin() }
            }
            #if os(iOS)
            .toolbarVisibility(hidden ? .hidden : .automatic, for: .navigationBar, .bottomBar)
            .statusBarHidden(hidden)
            .persistentSystemOverlays(hidden ? .hidden : .automatic)
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
                showForAssistiveTechnology()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.switchControlStatusDidChangeNotification)) { _ in
                showForAssistiveTechnology()
            }
            #else
            .background(EPUBWindowToolbarHiding(controls: controls, hidden: hidden))
            .onReceive(NSWorkspace.shared.publisher(for: \.isVoiceOverEnabled)) { _ in showForAssistiveTechnology() }
            .onReceive(NSWorkspace.shared.publisher(for: \.isSwitchControlEnabled)) { _ in showForAssistiveTechnology() }
            #endif
            // A fade, which Reduce Motion leaves out.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: hidden)
    }

    /// The safe area kept at one edge: `height` from the edge, of which the bars left `left` next
    /// to the reader, where the Show Controls button stands.
    private func roomKept(_ height: CGFloat, left: CGFloat, edge: VerticalEdge, button: Bool) -> some View {
        VStack(spacing: 0) {
            if edge == .bottom { buttonSpace(left, button: button) }
            Spacer(minLength: 0)
            if edge == .top { buttonSpace(left, button: button) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    private func buttonSpace(_ height: CGFloat, button: Bool) -> some View {
        ZStack {
            if button { EPUBShowControlsButton(controls: controls) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    /// VoiceOver or Switch Control came on: the controls show, as they do while either runs.
    private func showForAssistiveTechnology() {
        if controls.assistiveTechnologyIsRunning() { controls.showControls() }
    }
}

#if os(macOS)
/// On a Mac the controls hide and show with the window toolbar, by the window's own command:
/// View > Hide Toolbar and Show Toolbar, `NSWindow.toggleToolbarShown(_:)`, whose Option-Command-T
/// nothing in the window takes. The toolbar going hides the controls, and coming back shows them;
/// controls hidden or shown otherwise, as by Show Controls or VoiceOver coming on, take the
/// toolbar with them by the same command.
private struct EPUBWindowToolbarHiding: NSViewRepresentable {
    let controls: EPUBReaderControls
    let hidden: Bool

    func makeNSView(context: Context) -> EPUBWindowToolbarView { EPUBWindowToolbarView() }

    func updateNSView(_ view: EPUBWindowToolbarView, context: Context) {
        view.controls = controls
        view.hidesToolbar = hidden
    }
}

final class EPUBWindowToolbarView: NSView {
    weak var controls: EPUBReaderControls?
    var hidesToolbar = false { didSet { if hidesToolbar != oldValue { apply() } } }
    private var observed: (toolbar: NSToolbar, observation: NSKeyValueObservation)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func apply() {
        guard let window, let toolbar = window.toolbar else { return }
        if toolbar.isVisible == hidesToolbar { window.toggleToolbarShown(nil) }
        guard observed?.toolbar !== toolbar else { return }
        observed = (toolbar, toolbar.observe(\.isVisible) { [weak self] toolbar, _ in
            let visible = toolbar.isVisible
            MainActor.assumeIsolated {
                guard let self, visible == self.hidesToolbar else { return }
                if visible { self.controls?.showControls() } else { self.controls?.hideControls() }
            }
        })
    }
}
#endif

/// Brings hidden controls back: by a tap or click, and on iPhone and iPad by Option-Command-T and
/// by VoiceOver's Magic Tap while it is on the button. On a Mac that key is the window's Show
/// Toolbar. It is drawn as a plain symbol in the secondary colour on the host's background, with
/// no glass.
struct EPUBShowControlsButton: View {
    let controls: EPUBReaderControls
    var body: some View {
        Button {
            controls.showControls()
        } label: {
            Label("Show Controls", systemImage: "chevron.compact.down")
                .labelStyle(.iconOnly)
                .font(.title2)
                .frame(minWidth: 44, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Show Controls")
        #if os(iOS)
        .keyboardShortcut(EPUBReaderControls.toggleShortcut)
        .accessibilityAction(.magicTap) { controls.toggleControls() }
        #endif
    }
}

extension EPUBReaderControls {
    /// Option-Command-T, the shortcut of the Mac's own Show Toolbar and Hide Toolbar, on iPhone
    /// and iPad. A Mac leaves it to that command.
    static let toggleShortcut = KeyboardShortcut("t", modifiers: [.command, .option])
}

/// The control strip while the controls are hidden: its groups stay where they are, unseen and
/// out of reach of touch, keyboard and assistive technology, so that the strip is as tall as it
/// was and the reader beside it is not laid out again. The Show Controls button stands over them,
/// unless `epubReaderHidesControls` shows one in the room the bars left.
struct EPUBControlStripHiding: ViewModifier {
    let controls: EPUBReaderControls
    @Environment(\.epubReaderShowsControlsButtonAbove) private var buttonAbove

    func body(content: Content) -> some View {
        let hidden = controls.controlsHidden
        content
            .opacity(hidden ? 0 : 1)
            .disabled(hidden)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            .overlay(alignment: .leading) {
                if hidden && !buttonAbove { EPUBShowControlsButton(controls: controls) }
            }
    }
}
