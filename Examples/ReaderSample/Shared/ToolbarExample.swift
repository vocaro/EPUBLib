import EPUBViewing
import SwiftUI

// snippet:start toolbar
struct ToolbarReader: View {
    let controls: EPUBReaderControls // Retained alongside the existing session by the host.
    let savePosition: () -> Void

    var body: some View {
        EPUBReaderView(session: controls.session)
            .toolbar {
                EPUBReaderToolbar(controls: controls, groups: [.pages, .search, .contents, .appearance])
                ToolbarItem(placement: .automatic) {
                    Button("Save Position", systemImage: "bookmark", action: savePosition)
                }
            }
    }
}
// snippet:end toolbar
