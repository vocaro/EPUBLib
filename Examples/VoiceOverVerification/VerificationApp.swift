import SwiftUI

/// Isolates the synthetic book and preferences from the normal reader sample.
@main struct VoiceOverVerificationApp: App {
    init() {
        // `-VerificationBook paragraphs` opens the book of ordinary paragraphs instead.
        let name = UserDefaults.standard.string(forKey: "VerificationBook") ?? "sample"
        if let book = Bundle.main.url(forResource: name, withExtension: "epub") {
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
