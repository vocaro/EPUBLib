import EPUBCore
import EPUBReading
import EPUBViewing
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
typealias PlatformTestWindow = NSWindow
#else
typealias PlatformTestWindow = UIWindow
#endif

extension PlatformTestWindow {
    /// Light, whatever appearance the machine is in. A reader whose style is System takes its
    /// window's appearance, and a window that sets none takes the machine's: with automatic
    /// switching, light by day and dark in the evening.
    func keepLightAppearance() {
        #if os(macOS)
        appearance = NSAppearance(named: .aqua)
        #else
        overrideUserInterfaceStyle = .light
        #endif
    }
}

@MainActor @Observable final class TestPageControls {
    var value = EPUBPageControls()
    /// The appearance the reader's host reports. Nil is the window's own, which is light.
    var colorScheme: ColorScheme?
}

private struct ControlledTestReader: View {
    let session: any EPUBReaderSession
    let controls: TestPageControls
    @Environment(\.colorScheme) private var inheritedColorScheme
    var body: some View {
        EPUBReaderView(session: session)
            .epubReaderPageControls(controls.value)
            .environment(\.colorScheme, controls.colorScheme ?? inheritedColorScheme)
    }
}

@MainActor final class ReaderTestWindow {
    let pageControls = TestPageControls()
    #if os(macOS)
    let window: NSWindow
    #else
    let window: UIWindow
    #endif

    init(session: any EPUBReaderSession) {
        #if os(macOS)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.keepLightAppearance()
        window.contentView = NSHostingView(rootView: ControlledTestReader(session: session, controls: pageControls))
        window.orderFront(nil)
        #else
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
        window.keepLightAppearance()
        window.rootViewController = UIHostingController(rootView: ControlledTestReader(session: session, controls: pageControls))
        window.makeKeyAndVisible()
        #endif
    }

    func resize(to size: CGSize) {
        #if os(macOS)
        window.setContentSize(size)
        #else
        window.frame = CGRect(origin: .zero, size: size)
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
