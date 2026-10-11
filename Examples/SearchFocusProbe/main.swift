#if os(macOS)
import AppKit
import Darwin
import ApplicationServices
import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import EPUBViewing

@main struct SearchFocusProbeApp: App {
    private let probe = try! Probe()
    @State private var notes = ""
    var body: some Scene {
        WindowGroup("EPUBLib Search Focus Qualification") {
            VStack {
                EPUBReaderView(session: probe.session)
                TextField("Qualification Notes", text: $notes).padding()
            }
                .toolbar { EPUBReaderToolbar(controls: probe.controls) }
                .frame(minWidth: 1200, minHeight: 600)
                .task { await probe.run() }
        }
        .defaultSize(width: 1200, height: 600)
    }
}

@MainActor final class Probe {
    let session: any EPUBReaderSession
    let controls: EPUBReaderControls
    private var started = false
    init() throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        session = try EPUBReader().makeSession(publication: publication, selectionAction: nil, onEvent: { _ in })
        controls = EPUBReaderControls(publication: publication, session: session)
    }
    func run() async {
        guard !started else { return }; started = true
        let previous = NSWorkspace.shared.frontmostApplication
        var failed = true
        defer {
            session.close()
            if NSApp.isActive, previous?.processIdentifier != getpid() { previous?.activate() }
            for window in NSApp.windows { window.close() }
            fflush(stdout)
            Darwin.exit(failed ? 1 : 0)
        }
        do {
            try await wait("reader ready") { self.controls.isReady && self.controls.canGoNext && self.canvas?.window != nil }
            let canvas = canvas!
            let window = canvas.window!
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            try await wait("qualification window key") { window.isKeyWindow && NSApp.isActive }
            window.makeFirstResponder(canvas)
            print("ACTIVE: \(NSApp.isActive), KEY: \(window.isKeyWindow)")
            print("VIEWPORT: window=\(window.contentView!.bounds.size), reader=\(canvas.bounds.size)")
            print("BEFORE: \(type(of: window.firstResponder!))")
            let search = try find("Search")
            try press(search)
            try await wait("Search field") { self.element("Search in book") != nil }
            print("SEARCH OPEN")
            if CommandLine.arguments.contains("--results-keyboard") {
                controls.searchText = "paragraph"
                controls.submitSearch()
                try await wait("matching results") { (self.controls.searchResults?.count ?? 0) > 2 }
                let before = controls.searchResults?.currentIndex
                print("RESULT KEYBOARD READY pid=\(getpid()), current=\(String(describing: before)), count=\(controls.searchResults!.count)")
                fflush(stdout)
                guard NSApp.isFullKeyboardAccessEnabled else { throw Failure(message: "Keyboard Navigation must be enabled before launch") }
                func key(_ text: String, code: UInt16) async throws {
                    guard NSApp.isActive, let keyWindow = NSApp.keyWindow else {
                        throw Failure(message: "Native key window unavailable: active=\(NSApp.isActive), front=\(NSWorkspace.shared.frontmostApplication?.bundleURL?.lastPathComponent ?? "none"), keyWindow=\(NSApp.keyWindow != nil)")
                    }
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: keyWindow.windowNumber,
                        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
                    NSApp.sendEvent(event)
                    try await Task.sleep(for: .milliseconds(100))
                    print("KEY \(code), responder=\(keyWindow.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"), current=\(String(describing: controls.searchResults?.currentIndex))")
                }
                for _ in 0..<6 { try await key("\t", code: 48) }
                guard NSApp.keyWindow?.firstResponder.map({ String(describing: type(of: $0)) })?.contains("SwiftUIOutlineListView") == true else {
                    throw Failure(message: "Native Tab did not focus the results list")
                }
                try await key("\u{F701}", code: 125)
                try await key("\u{F701}", code: 125)
                try await key("\r", code: 36)
                try await key(" ", code: 49)
                guard controls.searchResults?.currentIndex == 1, controls.searchResults?.currentIndex != before else {
                    throw Failure(message: "Focused results list ignored Down/Return/Space")
                }
                print("PASS: native Down selects the second match")
                try await key("\u{F700}", code: 126)
                try await wait("Up selects first match") { self.controls.searchResults?.currentIndex == 0 }
                print("PASS: native Up selects the first match")
                guard let third = controls.searchResults?.results.first(where: { $0.index == 2 }) else {
                    throw Failure(message: "Third result missing")
                }
                try press(find(controls.searchResultAccessibilityLabel(for: third)))
                try await wait("AX row activation") { self.controls.searchResults?.currentIndex == 2 }
                print("PASS: AX row activation selects the third match")
                try await key("\u{F700}", code: 126)
                try await wait("Up after AX row activation") { self.controls.searchResults?.currentIndex == 1 }
                print("PASS: native selection follows programmatic result updates")
            }
            if CommandLine.arguments.contains("--escape") {
                let popup = NSApp.keyWindow!
                let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: popup.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
                NSApp.sendEvent(escape)
            } else { try press(find("Close Search")) }
            try await wait("Search closed") { self.element("Search in book") == nil }
            try await Task.sleep(for: .milliseconds(300))
            print("AFTER: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
            guard window.firstResponder === canvas else { throw Failure(message: "Search did not restore the reader responder") }
            let before = controls.status?.location
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)!
            NSApp.sendEvent(event)
            try await wait("Right Arrow page turn") { self.controls.status?.location != before }
            print("PASS: reader focus and page key restored")
            try press(find("Search"))
            try await wait("Search reopened") { self.element("Search in book") != nil }
            func editableField(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable { return field }
                return view.subviews.lazy.compactMap { editableField(in: $0) }.first
            }
            guard let notes = editableField(in: window.contentView!) else { throw Failure(message: "Notes field not mounted") }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(notes)
            let destination = window.firstResponder
            if let close = element("Close Search") { try press(close) }
            try await wait("Search closed after destination focus") { self.element("Search in book") == nil }
            try await Task.sleep(for: .milliseconds(300))
            guard window.firstResponder === destination else { throw Failure(message: "Dismissal stole intentional destination focus") }
            print("PASS: intentional destination focus preserved")
            failed = false
        } catch { print("FAIL: \(error)") }
    }
    private var canvas: NSView? {
        func find(in view: NSView) -> NSView? {
            if String(describing: type(of: view)) == "ReaderCanvasView" { return view }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return NSApp.windows.lazy.compactMap { $0.contentView.flatMap { find(in: $0) } }.first
    }
    struct Failure: Error { let message: String }
    private func wait(_ message: String, condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < end else { throw Failure(message: "Timed out: " + message) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private func press(_ element: AXUIElement) throws {
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { throw Failure(message: "AX press failed") }
    }
    private func find(_ label: String) throws -> AXUIElement {
        guard let e = element(label) else { throw Failure(message: "Missing " + label) }; return e
    }
    private func element(_ label: String) -> AXUIElement? {
        func attribute(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
            var v: CFTypeRef?; _ = AXUIElementCopyAttributeValue(e, key as CFString, &v); return v
        }
        func visit(_ e: AXUIElement) -> AXUIElement? {
            if [kAXDescriptionAttribute, kAXTitleAttribute].contains(where: { attribute(e, $0) as? String == label }) { return e }
            for child in attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { if let found = visit(child) { return found } }
            return nil
        }
        for w in attribute(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            if let found = visit(w) { return found }
        }
        return nil
    }
}

#else
@main enum UnsupportedPlatform {
    static func main() { fatalError("SearchFocusProbe requires macOS") }
}
#endif
