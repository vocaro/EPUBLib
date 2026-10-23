import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The frames a view was laid out at, each time SwiftUI laid it out somewhere new.
@MainActor final class ControlsHidingFrameLog {
    var frames: [CGRect] = []
}

/// Hiding the controls while a book is read, and bringing them back
/// ([#696](https://github.com/vocaro/EPUBLib/issues/696)). What is asked of them is Apple's:
/// "consider temporarily hiding toolbars for a distraction-free experience… offer ways to
/// reliably restore hidden interface elements" (Human Interface Guidelines, Toolbars), with no
/// Liquid Glass over the content layer (Materials). The bars and toolbar themselves are the
/// system's; what is checked here is the model, the reader's input that reaches it, and the
/// room the reader keeps.
@MainActor final class ReaderControlsHidingTests: XCTestCase {
    private final class Session: EPUBReaderSession {
        let capabilities: Set<EPUBReaderCapability> = [.pagination, .scrolling, .typography, .search, .navigateHref]
        let readerState: EPUBReaderState?
        init(lifecycle: EPUBReaderLifecycle = .ready) {
            let state = EPUBReaderState(status: .init(capabilities: capabilities))
            state.modify { $0.lifecycle = lifecycle }
            readerState = state
        }
        func makeView() -> AnyView { AnyView(EmptyView()) }
        func send(_ command: EPUBReaderCommand) async throws {}
        func close() { readerState?.modify { $0.lifecycle = .closed } }
    }

    /// SwiftUI content in a real window.
    @MainActor private final class Host {
        #if os(macOS)
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        #else
        let window: UIWindow
        let hosting: UIHostingController<AnyView>
        #endif

        init(_ content: some View, size: CGSize = CGSize(width: 600, height: 700), toolbar: Bool = false) {
            #if os(macOS)
            // A SwiftUI window's toolbar stands over a full-size content view.
            window = makeMacTestWindow(contentRect: CGRect(origin: .zero, size: size),
                                       styleMask: toolbar ? [.titled, .fullSizeContentView] : [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.keepLightAppearance()
            hosting = NSHostingView(rootView: AnyView(content))
            if toolbar { hosting.sceneBridgingOptions = [.toolbars, .title] }
            window.contentView = hosting
            window.orderFront(nil)
            #else
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window = UIWindow(windowScene: scene)
            } else { window = UIWindow(frame: CGRect(origin: .zero, size: size)) }
            window.keepLightAppearance()
            hosting = UIHostingController(rootView: AnyView(content))
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            #endif
        }

        func views<T>(_ type: T.Type) -> [T] {
            func collect(_ view: PlatformView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(collect) }
            #if os(macOS)
            hosting.layoutSubtreeIfNeeded()
            return collect(window.contentView ?? hosting)
            #else
            window.layoutIfNeeded()
            return collect(window)
            #endif
        }

        func close() {
            #if os(macOS)
            window.close()
            window.contentView = nil
            #else
            window.isHidden = true
            window.rootViewController = nil
            #endif
        }
    }

    private func wait(_ label: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = TestDeadline(seconds: timeout)
        while !condition() {
            guard try !deadline.hasPassed() else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settle(_ seconds: Double = 0.6) async throws { try await TestDeadline.pause(.seconds(seconds)) }

    private func controls(_ session: some EPUBReaderSession) throws -> EPUBReaderControls {
        EPUBReaderControls(publication: try EPUBPublication.open(data: Fixture.epub()), session: session)
    }

    /// A native session on `Fixture.epub()` mounted under the modifier, with its controls.
    private func mountedReader(whileReading: Bool = true, flow: EPUBReadingFlow = .paginated,
                               overrides: [String: String] = [:]) async throws
        -> (session: NativeSession, controls: EPUBReaderControls, host: Host, canvas: ReaderCanvasView) {
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: overrides))
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
        let controls = EPUBReaderControls(publication: publication, session: session)
        controls.assistiveTechnologyIsRunning = { false }
        let host = Host(EPUBReaderView(session: session).epubReaderHidesControls(controls, whileReading: whileReading))
        let state = try XCTUnwrap(session.readerState)
        try await wait("ready") { state.status.lifecycle == .ready && state.status.location != nil }
        if flow != state.status.style.flow {
            controls.changeStyle { $0.flow = flow }
            await controls.waitForCommands()
            try await wait("the flow") { session.canvas?.configuration.flow == flow }
        }
        let canvas = try XCTUnwrap(session.canvas)
        try await wait("the controls attached") { canvas.configuration.togglesControls }
        return (session, controls, host, canvas)
    }

    // MARK: The model

    /// Hidden is asked for, and holds only while the reader is ready: a book that closes or
    /// fails shows its controls again, with what they say about it.
    func testControlsHideAndShowOnlyWhileTheReaderIsReady() throws {
        let loading = Session(lifecycle: .loading)
        let model = try controls(loading)
        model.hideControls()
        XCTAssertFalse(model.controlsHidden, "nothing to hide the controls of before the book is ready")

        let session = Session()
        let ready = try controls(session)
        XCTAssertFalse(ready.controlsHidden)
        ready.hideControls()
        XCTAssertTrue(ready.controlsHidden)
        ready.toggleControls()
        XCTAssertFalse(ready.controlsHidden)
        ready.toggleControls()
        XCTAssertTrue(ready.controlsHidden)
        ready.showControls()
        XCTAssertFalse(ready.controlsHidden)
        ready.hideControls()
        session.readerState?.modify { $0.lifecycle = .failed(.engineFailure("gone")) }
        XCTAssertFalse(ready.controlsHidden, "a failed reader shows its controls")
        session.close()
        XCTAssertFalse(ready.controlsHidden, "a closed reader shows its controls")
    }

    /// Reading on hides the controls, except while VoiceOver or Switch Control is running:
    /// hidden, their items are gone from what either reaches.
    func testReadingOnHidesTheControlsUnlessVoiceOverOrSwitchControlIsRunning() throws {
        let model = try controls(Session())
        var running = true
        model.assistiveTechnologyIsRunning = { running }
        model.readerDidReadOn()
        XCTAssertFalse(model.controlsHidden, "VoiceOver or Switch Control keeps the controls")
        model.hideControls()
        XCTAssertTrue(model.controlsHidden, "the person can still hide them")
        model.showControls()
        running = false
        model.readerDidReadOn()
        XCTAssertTrue(model.controlsHidden)
        model.readerDidReadOn()
        XCTAssertTrue(model.controlsHidden, "reading on never brings them back")
    }

    /// Hidden, the reader is pinned to the safe area it had while the bars showed, from the
    /// layout that hides them, through each bar going and coming back, until both are back.
    func testTheReaderIsPinnedToItsRoomWhileTheBarsComeAndGo() {
        var room = EPUBControlsRoom()
        let shown = EdgeInsets(top: 116, leading: 0, bottom: 82, trailing: 0)
        let navigationBarGone = EdgeInsets(top: 62, leading: 0, bottom: 82, trailing: 0)
        let bottomBarBack = EdgeInsets(top: 116, leading: 0, bottom: 34, trailing: 0)
        let bare = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        XCTAssertFalse(room.measured(.init(width: 402, insets: shown), hidden: false))
        XCTAssertNil(room.pin(hidden: false), "shown, the reader has the live safe area")
        XCTAssertEqual(room.pin(hidden: true), shown, "pinned in the layout that hides the bars")
        room.controlsChanged(hidden: true)
        _ = room.measured(.init(width: 402, insets: navigationBarGone), hidden: true)
        XCTAssertEqual(room.pin(hidden: true), shown)
        _ = room.measured(.init(width: 402, insets: bare), hidden: true)
        XCTAssertEqual(room.pin(hidden: true), shown)
        XCTAssertTrue(room.room(hidden: true) == (54, 48), "the room the two bars left")
        // Shown: still pinned in the layout that shows them, and until both are back.
        room.controlsChanged(hidden: false)
        XCTAssertEqual(room.pin(hidden: false), shown)
        _ = room.measured(.init(width: 402, insets: bottomBarBack), hidden: false)
        XCTAssertEqual(room.pin(hidden: false), shown)
        _ = room.measured(.init(width: 402, insets: shown), hidden: false)
        XCTAssertNil(room.pin(hidden: false))
        // A host that took a bar away meanwhile: unpinned after a while, at the live safe area.
        room.controlsChanged(hidden: true)
        _ = room.measured(.init(width: 402, insets: bare), hidden: true)
        room.controlsChanged(hidden: false)
        _ = room.measured(.init(width: 402, insets: navigationBarGone), hidden: false)
        XCTAssertEqual(room.pin(hidden: false), shown)
        room.unpin()
        XCTAssertNil(room.pin(hidden: false))
        XCTAssertEqual(room.kept, navigationBarGone)
        // A rotation while hidden: what was kept is for another width, and the controls show.
        room.controlsChanged(hidden: true)
        XCTAssertTrue(room.measured(.init(width: 874, insets: EdgeInsets()), hidden: true))
    }

    // MARK: The reader's input

    /// The reader's own page turns (a key, a swipe, an edge, the wheel) hide the controls. A turn
    /// an assistive technology or the host asks for does not, nor one under `whileReading: false`.
    func testTheReadersOwnPageTurnsHideTheControlsAndOtherTurnsDoNot() async throws {
        let (session, controls, host, canvas) = try await mountedReader()
        defer { session.close(); host.close() }
        XCTAssertTrue(canvas.turnPageFromAccessibility(forward: true))
        XCTAssertFalse(controls.controlsHidden, "VoiceOver's own page turn")
        try await session.send(.nextPage)
        XCTAssertFalse(controls.controlsHidden, "the host's command, as the page buttons send")
        canvas.turnPageFromInput(forward: true)
        XCTAssertTrue(controls.controlsHidden, "a key, swipe, edge or wheel turn")
        controls.showControls()
        controls.assistiveTechnologyIsRunning = { true }
        canvas.turnPageFromInput(forward: true)
        XCTAssertFalse(controls.controlsHidden, "VoiceOver or Switch Control is running")

        let (other, kept, otherHost, otherCanvas) = try await mountedReader(whileReading: false)
        defer { other.close(); otherHost.close() }
        otherCanvas.turnPageFromInput(forward: true)
        XCTAssertFalse(kept.controlsHidden, "whileReading: false")
        XCTAssertTrue(otherCanvas.toggleControls(), "a tap in the middle still hides them")
        XCTAssertTrue(kept.controlsHidden)
    }

    /// Continuous scroll moved by the person reads on: a finger's drag on iPhone and iPad, the
    /// wheel or trackpad on a Mac.
    func testContinuousScrollMovedByThePersonHidesTheControls() async throws {
        let (session, controls, host, canvas) = try await mountedReader(flow: .scrolled)
        defer { session.close(); host.close() }
        XCTAssertFalse(controls.controlsHidden)
        #if os(iOS)
        let view = try XCTUnwrap(canvas.scrollTextView)
        canvas.scrollViewWillBeginDragging(view)
        #else
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -30, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        let scrollView = try XCTUnwrap(canvas.scrollContainer as? NSScrollView)
        scrollView.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        #endif
        XCTAssertTrue(controls.controlsHidden)
    }

    /// A tap in the middle of the page shows and hides the controls; an edge tap turns the page,
    /// and a tap on a link follows it. VoiceOver's Magic Tap does the same from a line.
    func testATapInTheMiddleAndMagicTapToggleTheControls() async throws {
        let link = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>First Chapter</title></head><body><h1 id="start"><a href="two.xhtml">First Chapter, a link across its line</a></h1>\(String(repeating: "<p>A paragraph of ordinary reading text for pagination.</p>", count: 50))</body></html>
        """
        let (session, controls, host, canvas) = try await mountedReader(overrides: ["OPS/one.xhtml": link])
        defer { session.close(); host.close() }
        let middle = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        XCTAssertTrue(canvas.togglesControls(at: middle))
        XCTAssertFalse(canvas.togglesControls(at: CGPoint(x: canvas.bounds.minX + 10, y: canvas.bounds.midY)), "the left edge turns back")
        XCTAssertFalse(canvas.togglesControls(at: CGPoint(x: canvas.bounds.maxX - 10, y: canvas.bounds.midY)), "the right edge turns on")
        let column = try XCTUnwrap(canvas.columns.first { !$0.isHidden })
        let line = try XCTUnwrap(column.lineFrame(containing: 0))
        let onLink = column.convert(CGPoint(x: line.midX + column.containerOrigin.x, y: line.midY + column.containerOrigin.y), to: canvas)
        XCTAssertNotNil(column.link(at: canvas.convert(onLink, to: column)), "the point is on the heading's link")
        XCTAssertFalse(canvas.togglesControls(at: onLink), "a tap on a link follows it")
        XCTAssertTrue(canvas.toggleControls())
        XCTAssertTrue(controls.controlsHidden)
        XCTAssertTrue(canvas.toggleControls())
        XCTAssertFalse(controls.controlsHidden)
        #if os(iOS)
        let recognizer = try XCTUnwrap(canvas.gestureRecognizers?.first { $0 is ReaderMiddleTapRecognizer })
        XCTAssertTrue(recognizer.isEnabled)
        XCTAssertTrue(column.accessibilityPerformMagicTap(), "Magic Tap from the text")
        XCTAssertTrue(controls.controlsHidden)
        XCTAssertTrue(canvas.accessibilityPerformMagicTap())
        XCTAssertFalse(controls.controlsHidden)
        let elements = try XCTUnwrap(column.accessibilityElements as? [NSObject])
        let first = try XCTUnwrap(elements.first)
        XCTAssertTrue(first.accessibilityPerformMagicTap(), "Magic Tap from a line")
        XCTAssertTrue(controls.controlsHidden)
        #endif
    }

    /// Unasked, reading on hides the controls on iPhone and iPad and not on a Mac, where a
    /// window's toolbar hides on command (View > Hide Toolbar) and not because a page turned.
    func testByDefaultReadingOnHidesTheControlsOnIPhoneAndIPadAndNotOnAMac() async throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
        let controls = EPUBReaderControls(publication: publication, session: session)
        controls.assistiveTechnologyIsRunning = { false }
        let host = Host(EPUBReaderView(session: session).epubReaderHidesControls(controls))
        defer { session.close(); host.close() }
        try await wait("ready") { session.readerState?.status.lifecycle == .ready && session.canvas?.configuration.togglesControls == true }
        let canvas = try XCTUnwrap(session.canvas)
        canvas.turnPageFromInput(forward: true)
        #if os(macOS)
        XCTAssertFalse(controls.controlsHidden, "a Mac hides its toolbar on command")
        #else
        XCTAssertTrue(controls.controlsHidden)
        #endif
    }

    /// Without the modifier the reader's taps, Magic Tap and page turns leave the host's
    /// controls alone, and the tap recognizer is off.
    func testWithoutTheModifierTheReaderLeavesTheControlsAlone() async throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
        let controls = EPUBReaderControls(publication: publication, session: session)
        controls.assistiveTechnologyIsRunning = { false }
        let host = Host(EPUBReaderView(session: session))
        defer { session.close(); host.close() }
        try await wait("ready") { session.readerState?.status.lifecycle == .ready }
        let canvas = try XCTUnwrap(session.canvas)
        XCTAssertFalse(canvas.configuration.togglesControls)
        XCTAssertFalse(canvas.togglesControls(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)))
        XCTAssertFalse(canvas.toggleControls())
        canvas.turnPageFromInput(forward: true)
        XCTAssertFalse(controls.controlsHidden)
        #if os(iOS)
        XCTAssertFalse(canvas.accessibilityPerformMagicTap(), "Magic Tap goes on to the app")
        XCTAssertEqual(canvas.gestureRecognizers?.first { $0 is ReaderMiddleTapRecognizer }?.isEnabled, false)
        #endif
    }

    // MARK: The room kept

    /// A hidden control strip keeps its height, so the reader beside it keeps its frame, and
    /// gives up its search field's focus.
    func testAHiddenStripKeepsItsHeightAndLetsGoOfItsField() async throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
        let controls = EPUBReaderControls(publication: publication, session: session)
        controls.assistiveTechnologyIsRunning = { false }
        let log = ControlsHidingFrameLog()
        let host = Host(VStack(spacing: 0) {
            EPUBReaderControlStrip(controls: controls).padding(.horizontal).layoutPriority(1)
            EPUBReaderView(session: session)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { log.frames.append($0) }
        }.epubReaderHidesControls(controls))
        defer { session.close(); host.close() }
        try await wait("ready") { session.readerState?.status.lifecycle == .ready && session.canvas != nil }
        try await settle()
        #if os(macOS)
        let field = try XCTUnwrap(host.views(NSTextField.self).first { $0.isEditable })
        XCTAssertTrue(host.window.makeFirstResponder(field))
        func fieldHasFocus() -> Bool { (host.window.firstResponder as? NSText)?.delegate as? NSTextField === field }
        #else
        let field = try XCTUnwrap(host.views(UITextField.self).first)
        XCTAssertTrue(field.becomeFirstResponder())
        func fieldHasFocus() -> Bool { field.isFirstResponder }
        #endif
        try await wait("the field's focus") { fieldHasFocus() }
        let before = log.frames
        let frame = try XCTUnwrap(before.last)
        controls.hideControls()
        try await wait("the field to let go of focus") { !fieldHasFocus() }
        try await settle()
        controls.showControls()
        try await settle()
        XCTAssertEqual(Array(log.frames.dropFirst(before.count)).filter { !$0.equalTo(frame) }, [],
                       "the reader beside the strip was laid out at another frame")
    }

    #if os(iOS)
    /// Hidden, the navigation bar goes and the reader keeps the frame it had beside it, so the
    /// book is not laid out again and the bar, when it comes back, is over no text. Shown again,
    /// the bar returns and the reader still has that frame, at every layout between.
    func testHiddenBarsLeaveTheReaderItsFrame() async throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
        let controls = EPUBReaderControls(publication: publication, session: session)
        controls.assistiveTechnologyIsRunning = { false }
        let log = ControlsHidingFrameLog()
        let host = Host(NavigationStack {
            EPUBReaderView(session: session)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { log.frames.append($0) }
                .navigationTitle("A Test Book")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    EPUBReaderToolbar(controls: controls, groups: [.search, .contents, .hideControls], placement: .topBarTrailing)
                    EPUBReaderToolbar(controls: controls, groups: [.pages], placement: .bottomBar)
                }
                .epubReaderHidesControls(controls)
        }, size: CGSize(width: 402, height: 874))
        defer { session.close(); host.close() }
        try await wait("ready") { session.readerState?.status.lifecycle == .ready && session.canvas != nil }
        try await settle()
        let navigation = try XCTUnwrap(navigationController(in: host.hosting))
        XCTAssertFalse(navigation.isNavigationBarHidden)
        XCTAssertFalse(navigation.isToolbarHidden, "the page buttons' bottom bar")
        let before = log.frames.count
        let frame = try XCTUnwrap(log.frames.last)
        let canvas = try XCTUnwrap(session.canvas)
        let pageArea = canvas.pageArea
        for round in 1...2 {
            controls.hideControls()
            try await wait("the bars to hide") { navigation.isNavigationBarHidden && navigation.isToolbarHidden }
            try await settle()
            XCTAssertEqual(canvas.pageArea, pageArea, "round \(round): the pages kept their area while hidden")
            controls.showControls()
            try await wait("the bars to come back") { !navigation.isNavigationBarHidden && !navigation.isToolbarHidden }
            try await settle(1.2)
            XCTAssertEqual(canvas.pageArea, pageArea, "round \(round): the pages kept their area shown again")
        }
        XCTAssertEqual(Array(log.frames.dropFirst(before)).filter { !$0.equalTo(frame) }, [],
                       "the reader was laid out at another frame on the way")
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let found = navigationController(in: child) { return found }
        }
        return nil
    }
    #else
    /// The window's own View > Hide Toolbar and Show Toolbar (`toggleToolbarShown`) hide and show
    /// the controls with the toolbar, and controls hidden or shown otherwise take the toolbar with
    /// them. Hidden, the reader keeps the frame it had under the toolbar; shown again, the toolbar
    /// returns over no text, the reader's frame unchanged at every layout between.
    func testAHiddenToolbarLeavesTheReaderItsFrame() async throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
        let controls = EPUBReaderControls(publication: publication, session: session)
        controls.assistiveTechnologyIsRunning = { false }
        let log = ControlsHidingFrameLog()
        let host = Host(NavigationStack {
            EPUBReaderView(session: session)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { log.frames.append($0) }
                .navigationTitle("A Test Book")
                .toolbar { EPUBReaderToolbar(controls: controls, groups: [.search, .contents, .hideControls, .pages]) }
                .epubReaderHidesControls(controls)
        }, size: CGSize(width: 900, height: 700), toolbar: true)
        defer { session.close(); host.close() }
        try await wait("ready") { session.readerState?.status.lifecycle == .ready && session.canvas != nil }
        try await wait("the window toolbar") { host.window.toolbar?.isVisible == true }
        try await settle()
        let before = log.frames.count
        let frame = try XCTUnwrap(log.frames.last)
        let canvas = try XCTUnwrap(session.canvas)
        let pageArea = canvas.pageArea
        for round in 1...2 {
            host.window.toggleToolbarShown(nil) // View > Hide Toolbar
            try await wait("the controls to follow the toolbar") { controls.controlsHidden }
            try await settle()
            XCTAssertEqual(host.window.toolbar?.isVisible, false)
            XCTAssertEqual(canvas.pageArea, pageArea, "round \(round): the pages kept their area while hidden")
            host.window.toggleToolbarShown(nil) // View > Show Toolbar
            try await wait("the controls to follow the toolbar") { !controls.controlsHidden }
            try await settle(1.2)
            XCTAssertEqual(host.window.toolbar?.isVisible, true)
            XCTAssertEqual(canvas.pageArea, pageArea, "round \(round): the pages kept their area shown again")
        }
        // Hidden and shown by the model, as by Show Controls or VoiceOver coming on.
        controls.hideControls()
        try await wait("the toolbar to hide") { host.window.toolbar?.isVisible != true }
        try await settle()
        controls.showControls()
        try await wait("the toolbar to come back") { host.window.toolbar?.isVisible == true }
        try await settle(1.2)
        XCTAssertEqual(Array(log.frames.dropFirst(before)).filter { !$0.equalTo(frame) }, [],
                       "the reader was laid out at another frame on the way")
    }

    /// On a Mac, Option-Command-T is View > Hide Toolbar's and Show Toolbar's, the window's own
    /// command: nothing in the window takes the key before the menu, shown or hidden.
    func testOnAMacOptionCommandTIsLeftToTheWindowsToolbarCommand() async throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
        let controls = EPUBReaderControls(publication: publication, session: session)
        controls.assistiveTechnologyIsRunning = { false }
        let host = Host(VStack(spacing: 0) {
            EPUBReaderControlStrip(controls: controls, groups: [.pages, .hideControls])
            EPUBReaderView(session: session)
        }.epubReaderHidesControls(controls))
        defer { session.close(); host.close() }
        try await wait("ready") { session.readerState?.status.lifecycle == .ready && session.canvas != nil }
        try await settle()
        func optionCommandT() throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                           windowNumber: host.window.windowNumber, context: nil, characters: "†",
                                           charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        }
        XCTAssertFalse(host.window.performKeyEquivalent(with: try optionCommandT()), "shown: the window took the key")
        try await settle(0.3)
        XCTAssertFalse(controls.controlsHidden)
        controls.hideControls()
        try await settle()
        XCTAssertFalse(host.window.performKeyEquivalent(with: try optionCommandT()), "hidden: the window took the key")
        try await settle(0.3)
        XCTAssertTrue(controls.controlsHidden)
    }
    #endif
}
