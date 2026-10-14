# Host integration

Keep the parsed publication and session outside SwiftUI `body`. Use a distinct view identity for
each session (including when reopening the same book) and close it when the reader leaves the screen. The host owns persistence,
selection action behavior, navigation intent, disclosures and fallback UI. Optional [reader controls](reader-controls.md) provide reusable toolbar groups.

## Opening a book

`EPUBPublication.open(at:)` reads a book into an immutable snapshot. Call it off the main actor,
and keep security-scoped file access active until it returns:

<!-- snippet:parsing -->
```swift
// Call off the main actor. Keep security-scoped file access active until this returns.
func readPublication(at bookURL: URL) throws -> EPUBPublication {
    let publication = try EPUBPublication.open(at: bookURL)
    print(publication.metadata.title)
    for chapter in publication.spine {
        let bytes = try publication.data(for: chapter.resource)
        print(chapter.resource.path, bytes.count)
    }
    return publication
}
```
<!-- /snippet -->

## Showing a book

Create and retain a reading session on the main actor, then mount `EPUBReaderView(session:)`:

<!-- snippet:session -->
```swift
@MainActor
func makeReader(publication: EPUBPublication,
                onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
    let engine: any EPUBReaderEngine = EPUBReader()
    return try engine.makeSession(
        publication: publication,
        selectionAction: EPUBSelectionAction(title: "Use passage") { selection in
            print(selection.text)
        },
        onEvent: onEvent
    )
}
```
<!-- /snippet -->

After `.ready`, send commands with `try await session.send(...)`: for example `.nextPage`,
`.locate(text: "a passage", highlight: true)` or `.style(.init(fontSize: 20, appearance: .dark))`.
Check `session.capabilities` before offering an optional feature. Navigate with a resource's
encoded href, safely handling optional entries:

<!-- snippet:navigation -->
```swift
/// Call after the session emits `.ready`.
@MainActor
func navigateToFirstSection(publication: EPUBPublication, session: any EPUBReaderSession) async throws {
    guard session.capabilities.contains(.navigateHref),
          let first = publication.spine.first(where: { $0.isLinear }) else { return }
    // href is URL-encoded; path is the decoded key used for publication.data(at:).
    try await session.send(.navigate(href: first.resource.href))
}
```
<!-- /snippet -->

To turn pages with your own controls, or change the built-in gestures and keys, see
[Configuring page controls](#configuring-page-controls).

## A complete reader

Import `EPUBCore`, `EPUBReading`, `EPUBViewing`, `Foundation` and `Observation`. The following is
the sample app's compiled lifecycle code:

<!-- snippet:lifecycle -->
```swift
@MainActor @Observable
final class BookReader {
    private(set) var publication: EPUBPublication?
    private(set) var session: (any EPUBReaderSession)?
    private(set) var controls: EPUBReaderControls?
    private(set) var ready = false
    private(set) var loading = false
    var busy: Bool { controls?.isBusy == true }
    private(set) var location: EPUBLocation?
    private(set) var savedPosition: EPUBLocation?
    private(set) var disclosure: String?
    private(set) var notice: String?
    private(set) var selection: String?
    private(set) var selectedText: String?
    private(set) var error: String?
    private var opening: Task<Void, Never>?
    private var generation = UUID()
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
        if let data = UserDefaults.standard.data(forKey: "position.\(book.id)") {
            savedPosition = try? JSONDecoder().decode(EPUBLocation.self, from: data)
        }
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
                case .selectionChanged(let value): selection = value?.text
                case .searchChanged, .searchResultsChanged: break
                }
            })
        if let session { controls = EPUBReaderControls(publication: book, session: session) }
    }

    func send(_ command: EPUBReaderCommand) {
        controls?.send(command)
    }

    func savePosition() {
        guard let location else {
            notice = "Reading position is not available yet."
            return
        }
        do {
            let data = try JSONEncoder().encode(location)
            UserDefaults.standard.set(data, forKey: "position.\(location.publicationID)")
            savedPosition = location
            notice = "Bookmark saved."
        } catch {
            self.error = "Could not save the bookmark: \(error.localizedDescription)"
        }
    }

    func restorePosition() {
        guard let savedPosition else {
            notice = "No bookmark saved for this book."
            return
        }
        send(.restore(savedPosition))
    }

    func clearPosition() {
        guard let publication else { return }
        UserDefaults.standard.removeObject(forKey: "position.\(publication.id)")
        savedPosition = nil
        notice = "Bookmark cleared."
    }

    func close() {
        generation = UUID()
        opening?.cancel(); opening = nil
        controls?.cancelPendingCommands(); controls = nil
        session?.close(); session = nil
        publication = nil; ready = false; loading = false
        location = nil; disclosure = nil; notice = nil; selection = nil; selectedText = nil; error = nil
        savedPosition = nil
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

## Resource paths

Use `EPUBResource.path` for `publication.data(at:)` and `EPUBResource.href` for navigation.
Navigation items and emitted locations also carry encoded hrefs. Decode neither before sending
`.navigate`; a literal `#`, `%` or `?` in a filename has different meaning in a URL reference.

A host that writes a resource to disk may join its `path` to a directory of its own. The `path` of
every resource of an opened publication is relative; its names are separated by single `/`, none
of them is empty, `.` or `..`, and it holds no backslash and no NUL. That is true of the path's
bytes, whatever combining marks, variation selectors or joiners a name carries, and of what a file
system is given: Foundation hands it each name's canonical decomposition rather than those bytes,
and decomposing it adds no `/`, `\`, `.`, `:` or NUL. Pass the path whole to `URL` or
`FileManager`, or split it at `/` in its `utf8` or `unicodeScalars` view: by `Character`, which
`split(separator:)`, `hasPrefix` and `contains` compare on a `String`, a `/` followed by a
combining mark is not a `/`. Foundation's `components(separatedBy:)` compares that way too, as
does `range(of:)` unless told `.literal`.

The names themselves are the book's, and the host still decides what to do with them:

- **Names a platform reserves, alters or does not allow.** A name that begins with a dot or holds
  control characters; a colon, which a book's file names may hold and which Windows reads as a
  drive or stream separator; Windows device names and a closing dot or space; length limits.
- **Names made of dots and invisible characters.** `..` followed by a zero-width joiner, or dots
  mixed with other default-ignorable characters, is a name and not a dot segment, and the reader
  accepts it. APFS keeps such a name inside the host's folder. A file system that ignores those
  characters when it compares names could read one as `..`.
- **Paths seen through `URL`.** `URL.pathComponents` drops a byte-order mark (U+FEFF) that opens
  a name and reports `..` for a name of U+FEFF and two dots, though the file system is given the
  whole name. Inspect a path's bytes or scalars, not its `URL` components.
- **Names a file system holds equal.** Two paths may differ only in case, or be a file and a
  folder of one name.
- **Anything the host converts.** Keep symbolic links out of the destination, and check a path
  again after any conversion: compatibility normalization and legacy code pages turn other
  characters into `/`, `\`, `.` and `:`.

A `path` is the manifest's spelling of the name, or the archive entry's own where the two differ
only in case. It equals the entry's name as a Swift string, which is canonical equivalence, and
need not match it byte for byte.

## Positions and highlights

To store a position, encode `EPUBLocation` using `JSONEncoder`. On reopen, compare its publication
ID and send `.restore(location)` only when bookmarks are supported. Compare a stored bookmark with
`EPUBReader.identifier` and `EPUBReader.bookmarkFormat` rather than literal strings. A bookmark the
former WebKit reader stored (`org.epubreaderlib.foliate`, `epubcfi-v1`) is migrated by replacing
those two fields; its CFI value names the same position. If restoration reports an
incompatible location, offer an explicit section/quote fallback where supported. EPUB files that
change have a different SHA-256 identity, even when their metadata identifier is unchanged.

For a saved passage, persist the entire selection's `location` and pass it to
`.setHighlights([EPUBHighlight(id: ..., location: saved)])`. In continuous scroll a selection
can span documents: `rangeBookmarks` contains the ordered per-document range CFIs, while
`bookmark` remains the first segment for compatibility. Do not discard `rangeBookmarks` when
copying a location. Existing JSON without this optional field remains valid. `.restore` validates
all segments and navigates to the passage's start; it does not recreate the native selection.
Highlights restore every segment in paginated and scrolled flow and survive typography changes.
The reader draws the complete annotation once all segments are available, or emits a `.notice`
if any segment cannot be resolved; it never silently draws just its first section.

Paginated selections can span both columns. Copy and the host action receive the complete
passage, including a located passage extending onto later pages; the viewer shows continuation
controls when part of that selection is offscreen. Table-cell selections also carry precise
character CFIs, so hosts persist and highlight them through the same `EPUBLocation` API.

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

## Configuring page controls

Apply `epubReaderPageControls(_:)` to the retained `EPUBReaderView` for the bundled native
reader. `EPUBPageControls()` keeps existing behavior: 56-point edge zones, iOS horizontal
swipes, Mac wheel/trackpad turns, and Left/Page Up previous, Right/Page Down/Space next,
Shift-Space previous. `.hostOnly` disables all direct page input; buttons can still send
`.nextPage` / `.previousPage`, and VoiceOver page actions remain available: each line of a
page offers them on iPhone and iPad, and each text area on Mac, in VoiceOver's Actions menu
([native viewer](native-viewer.md#input-and-accessibility)).

<!-- snippet:pageControls -->
```swift
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
```
<!-- /snippet -->

The example switches between host-only input and custom zones with Command-Shift-N/P
shortcuts while the book stays mounted. The sample reader uses the default input settings.
The modifier is specific to the native reader; other engines can choose their own input API.

- `edgeTapsEnabled`, `touchSwipesEnabled` and `wheelEnabled` independently enable each input
  family. All gestures turn pages only in paginated flow. Disabled iOS recognizers cannot
  compete with host gestures; disabled Mac wheel handling passes events up the responder
  chain. Native scrolling, text selection, links and context menus remain available.
- `leftTapWidth` / `rightTapWidth` are physical edge widths in points, measured inward from
  the reader's bounds, including outer margins. Positive finite values are clipped to the
  current reader width. Zero, negative, NaN and infinity disable that edge. Boundaries are
  exclusive at the inner edge; in overlaps the right edge wins, including in narrow readers.
  A usable reserved vertical division is excluded across its full x band; no additional
  zones are created at the fold. Resizing uses the new bounds immediately. In RTL books,
  the physical left zone turns next and right turns previous; the widths do not swap.
  Touch swipes and horizontal wheel directions also mirror automatically. Vertical wheel
  movement retains its forward/backward direction.
- `keyboardBindings` **replaces** the default bindings. Empty disables built-in page
  shortcuts. Keys support arrows, Page Up/Down, Home/End, Space and ASCII letters/digits.
  Letters are case-insensitive; specify `.shift` explicitly. Other character keys and
  unsupported modifier bits are ignored. Modifiers (`shift`, `command`, `option`, `control`)
  match exactly; Caps Lock and the system's arrow Function/Numeric Pad flags are ignored.
  Duplicate key/modifier pairs use the first binding. Layout-specific letter keys use the
  event's character rather than a Mac physical key code.
- Keyboard actions are **logical** `.next` / `.previous` and never mirror in RTL. In
  scrolled flow they move one viewport less a line. A single native responder path handles
  a key whether the canvas or a child text view has focus. The reader does not take focus
  from another control when bindings change; focus must be within the reader for a shortcut
  to apply. On iOS the reader can receive hardware keys when its native text view has focus.
- Copy, Select All, Shift-arrow selection extension and other host/system chords remain
  native unless explicitly assigned. There are no library-reserved supported combinations,
  but OS-reserved or app-menu shortcuts may be consumed before delivery to the reader.
  Removed bindings cease claiming page keys; native text handling may still use an arrow
  for selection or scrolling. No binding is installed globally.

Changing the modifier on an already mounted session updates only input handling. It does
not rebuild text, repaginate, clear selection or highlights, or emit a relocation. The
current wheel gesture/cooldown and pending edge press are reset. Host commands and
accessibility use the same page/viewport operation regardless of direct-input configuration.
