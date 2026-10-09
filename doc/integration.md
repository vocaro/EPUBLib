# Host integration

Keep the parsed publication and session outside SwiftUI `body`. Use a distinct view identity for
each session (including when reopening the same book) and close it when the reader leaves the screen. The host owns persistence,
selection action behavior, navigation intent, toolbars, disclosures and fallback UI.

Import `EPUBLib`, `EPUBViewing`, `Foundation` and `Observation`. The following is
the sample app's compiled lifecycle code:

<!-- snippet:lifecycle -->
```swift
@MainActor @Observable
final class BookReader {
    private(set) var publication: EPUBPublication?
    private(set) var session: (any EPUBReaderSession)?
    private(set) var ready = false
    private(set) var loading = false
    private(set) var busy = false
    private(set) var location: EPUBLocation?
    private(set) var disclosure: String?
    private(set) var notice: String?
    private(set) var selectedText: String?
    private(set) var error: String?
    private var opening: Task<Void, Never>?
    private var commands: Task<Void, Never>?
    private var generation = UUID()
    private var latestCommand = UUID()
    var sessionID: UUID { generation }

    func reportImportError(_ error: Error) { self.error = error.localizedDescription }

    func open(url: URL) {
        close()
        loading = true
        let token = generation
        opening = Task { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let work = Task.detached { try EPUBPublication.open(at: url) }
            do {
                let book = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard let self, generation == token else { return }
                try install(book, engine: EPUBReader())
            } catch is CancellationError {
                // Closing or opening another book intentionally cancels the previous import.
            } catch {
                guard let self, generation == token else { return }
                self.error = String(describing: error)
            }
            if let self, generation == token { loading = false; opening = nil }
        }
    }

    func install(_ book: EPUBPublication, engine: any EPUBReaderEngine) throws {
        let token = generation
        publication = book
        session = try engine.makeSession(publication: book,
            selectionAction: EPUBSelectionAction(title: "Use passage") { [weak self] selection in
                guard let self, generation == token else { return }
                selectedText = selection.text
            }, onEvent: { [weak self] event in
                guard let self, generation == token else { return }
                switch event {
                case .ready: ready = true
                case .relocated(let value): location = value
                case .disclosure(let value): disclosure = value
                case .notice(let value): notice = value
                case .failed(let value): error = String(describing: value); ready = false
                case .selectionChanged: break
                }
            })
    }

    func send(_ command: EPUBReaderCommand) {
        guard ready, let session else { return }
        let previous = commands
        let token = generation
        let commandID = UUID()
        latestCommand = commandID
        busy = true
        commands = Task { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                try await session.send(command)
            } catch is CancellationError {
            } catch {
                guard let self, generation == token else { return }
                self.error = String(describing: error)
            }
            if let self, generation == token, latestCommand == commandID { busy = false }
        }
    }

    func savePosition() {
        guard let location, let data = try? JSONEncoder().encode(location) else { return }
        UserDefaults.standard.set(data, forKey: "position.\(location.publicationID)")
        notice = "Position saved."
    }

    func restorePosition() {
        guard let publication,
              let data = UserDefaults.standard.data(forKey: "position.\(publication.id)"),
              let saved = try? JSONDecoder().decode(EPUBLocation.self, from: data) else {
            notice = "No saved position for this book."; return
        }
        send(.restore(saved))
    }

    func close() {
        generation = UUID()
        opening?.cancel(); opening = nil
        commands?.cancel(); commands = nil
        session?.close(); session = nil
        publication = nil; ready = false; loading = false; busy = false
        location = nil; disclosure = nil; notice = nil; selectedText = nil; error = nil
    }
}
```
<!-- /snippet -->

Construct `BookReader` in `@State` and call `reader.open(url:)`. Mount `EPUBReaderView(session: session)` when
a session exists. React to readiness before sending style, navigation or restoration commands.
For an application receiving rapid navigation changes, serialize them and associate work with
its own current document/navigation identity so old work cannot affect a newly opened book.

The sample owns security-scoped access until import finishes and cancels expansion when another
book opens. `EPUBPublication.open` also accepts an optional `onProgress` callback with cumulative
expanded bytes; it runs synchronously on the importing thread and must return promptly.

Use `EPUBResource.path` for `publication.data(at:)` and `EPUBResource.href` for navigation.
Navigation items and emitted locations also carry encoded hrefs. Decode neither before sending
`.navigate`; a literal `#`, `%` or `?` in a filename has different meaning in a URL reference.

To store a position, encode `EPUBLocation` using `JSONEncoder`. On reopen, compare its publication
ID and send `.restore(location)` only when bookmarks are supported. Compare a stored bookmark with
`EPUBReader.identifier` and `EPUBReader.bookmarkFormat` rather than literal strings. A bookmark the
former WebKit reader stored (`org.epubreaderlib.foliate`, `epubcfi-v1`) is migrated by replacing
those two fields; its CFI value names the same position. If restoration reports an
incompatible location, offer an explicit section/quote fallback where supported. EPUB files that
change have a different SHA-256 identity, even when their metadata identifier is unchanged.

A book with print or source page equivalents lists them in `EPUBPublication.pageList`; send
an entry's `href` with `.navigate` to go to that page. Its locations carry `page`, the entry in
effect where the shown range starts, and `pages`, every entry the range shows part of. To keep
another view on the matching page, such as the source PDF beside the book, move it to `page`
only when its current page is not among `pages`: navigating to a marker partway down a screen
shows the end of the page before it first.

## Adding an engine

Implement `EPUBReaderEngine` and `EPUBReaderSession` in a separate module. Choose a stable engine
ID and versioned bookmark format. Return native SwiftUI content or wrap your toolkit's native view
in a representable. Adapt its input events to the public value types and expose only capabilities
that work. Refuse unsupported commands, check task cancellation before effects, and suppress all
callbacks after close. A toolkit with different location semantics keeps them inside its bookmark.

The protocol permits other adapters, such as Readium; they require their own implementation,
platform support checks, licensing review and tests. The package ships only its native viewer.

Run the shared [engine contract checks](testing.md#adapter-contract-tests) against each adapter.
