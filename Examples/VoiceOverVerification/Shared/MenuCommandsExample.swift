import EPUBViewing
import SwiftUI

// snippet:start menuCommands
/// The reader's commands in the menu bar of a Mac and an iPad.
struct ReaderScene<Content: View>: Scene {
    @ViewBuilder let content: () -> Content

    var body: some Scene {
        WindowGroup(content: content)
            .commands { EPUBReaderMenuCommands() }
    }
}

struct MenuCommandsReader: View {
    let controls: EPUBReaderControls // Retained alongside the existing session by the host.

    var body: some View {
        EPUBReaderView(session: controls.session)
            .toolbar { EPUBReaderToolbar(controls: controls) }
            // The reader the menu bar's commands act on while this window is in front.
            .epubReaderMenuCommands(controls)
    }
}
// snippet:end menuCommands
