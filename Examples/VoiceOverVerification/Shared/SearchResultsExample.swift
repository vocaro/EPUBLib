import EPUBViewing
import SwiftUI

// snippet:start searchResults
/// Keeps the match count and stepping at hand while the search pane is closed, and lists the
/// results in a sheet the host owns. The built-in search pane already contains both.
struct SearchResultsExample: View {
    let controls: EPUBReaderControls // Retained alongside the existing session by the host.
    @State private var browsing = false

    var body: some View {
        EPUBReaderView(session: controls.session)
            .toolbar {
                EPUBReaderToolbar(controls: controls, groups: [.search, .contents])
                ToolbarItemGroup(placement: Self.placement) {
                    EPUBSearchResultNavigator(controls: controls, showsResultBrowser: false)
                    Button("Search Results", systemImage: "list.bullet.rectangle") { browsing = true }
                        .disabled(!controls.canShowSearchResults)
                }
            }
            .sheet(isPresented: $browsing) {
                EPUBSearchResultList(controls: controls) { _ in browsing = false }
            }
    }

    #if os(iOS)
    private static let placement = ToolbarItemPlacement.bottomBar
    #else
    private static let placement = ToolbarItemPlacement.automatic
    #endif
}
// snippet:end searchResults
