import EPUBViewing
import SwiftUI

// snippet:start toolbar
struct ToolbarReader: View {
    let controls: EPUBReaderControls // Retained alongside the existing session by the host.
    let savePosition: () -> Void

    var body: some View {
        EPUBReaderView(session: controls.session)
            .toolbar {
                EPUBReaderToolbar(controls: controls, groups: [.search, .contents, .appearance, .readingMode])
                ToolbarItem(placement: .automatic) {
                    Button("Save Bookmark", systemImage: "bookmark", action: savePosition)
                }
                ToolbarSpacer(.fixed)
                EPUBReaderToolbar(controls: controls, groups: [.pages])
            }
    }
}
// snippet:end toolbar
