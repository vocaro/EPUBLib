import EPUBCore
import EPUBViewing
import SwiftUI

// snippet:start pageControls
/// Retain the session while switching between host-only and custom built-in input.
struct PageControlsExample: View {
    let session: any EPUBReaderSession
    @State private var hostOnly = true

    static let customControls = EPUBPageControls(leftTapWidth: 32, rightTapWidth: 96,
        keyboardBindings: [
            .init(.character("n"), modifiers: [.command, .shift], action: .next),
            .init(.character("p"), modifiers: [.command, .shift], action: .previous),
        ])

    var body: some View {
        VStack {
            Toggle("Use only host page controls", isOn: $hostOnly)
            HStack {
                Button("Previous") { send(.previousPage) }
                Button("Next") { send(.nextPage) }
            }
            EPUBReaderView(session: session)
                .epubReaderPageControls(hostOnly ? .hostOnly : Self.customControls)
        }
    }

    private func send(_ command: EPUBReaderCommand) {
        Task { @MainActor in try? await session.send(command) }
    }
}
// snippet:end pageControls

// snippet:start pageTurnAnimation
/// Let the reader choose how a page turns. Under Reduce Motion a slide dissolves by itself.
struct PageTurnAnimationExample: View {
    let session: any EPUBReaderSession
    @State private var slides = true

    var body: some View {
        VStack {
            Toggle("Slide pages", isOn: $slides)
            EPUBReaderView(session: session)
                .epubReaderPageTurnAnimation(slides ? .slide : .none)
        }
    }
}
// snippet:end pageTurnAnimation
