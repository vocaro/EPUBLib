import EPUBViewing
import SwiftUI

// snippet:start hiding
struct HidingReader: View {
    let controls: EPUBReaderControls // Retained alongside the existing session by the host.

    var body: some View {
        EPUBReaderView(session: controls.session)
            .toolbar {
                EPUBReaderToolbar(controls: controls, groups: [.search, .contents, .appearance, .readingMode, .hideControls])
                #if os(iOS)
                EPUBReaderToolbar(controls: controls, groups: [.pages], placement: .topBarPinnedTrailing)
                #else
                ToolbarSpacer(.fixed)
                EPUBReaderToolbar(controls: controls, groups: [.pages])
                #endif
            }
            // After the toolbar, so that its Hide Controls group is offered.
            .epubReaderHidesControls(controls)
    }
}
// snippet:end hiding
