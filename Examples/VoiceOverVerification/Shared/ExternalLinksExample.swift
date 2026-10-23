import EPUBViewing
import SwiftUI

// snippet:start externalLinks
/// Links outside the book: asked about and opened with the system (the default), refused with
/// the reader's notice, or handed to the app, which here shows the address it was given.
struct ExternalLinksExample: View {
    enum Choice: String, CaseIterable { case ask = "Ask", refuse = "Refuse", app = "In the app" }
    let session: any EPUBReaderSession
    @State private var choice = Choice.ask
    @State private var given: URL?

    var body: some View {
        VStack {
            Picker("Links outside the book", selection: $choice) {
                ForEach(Choice.allCases, id: \.self) { Text($0.rawValue) }
            }
            EPUBReaderView(session: session)
                .epubReaderExternalLinks(links)
            if let given { Text("The book links to \(given.absoluteString)") }
        }
    }

    private var links: EPUBExternalLinks {
        switch choice {
        case .ask: .ask
        case .refuse: .refuse
        case .app: .handle { url in given = url }
        }
    }
}
// snippet:end externalLinks
