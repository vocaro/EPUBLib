import SwiftUI

/// Isolates the synthetic book and preferences from the normal reader sample.
@main struct VoiceOverVerificationApp: App {
    init() {
        if let book = Bundle.main.url(forResource: "sample", withExtension: "epub") {
            UserDefaults.standard.register(defaults: ["SampleBook": book.path, "SampleFlow": "paginated"])
        }
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack { ReaderScreen() }
                #if os(macOS)
                .frame(minWidth: 360, minHeight: 600)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 850)
        #endif
    }
}
