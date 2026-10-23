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

A book whose archive directory is damaged opens without the entries that cannot be read, as
without files the archive lacks, and `publication.lostEntries` gives how many there were and
whichever of their paths can still be read. When it is not nil, tell the reader the book may be
incomplete.

The URL may also name a book unpacked into a folder, as Apple Books keeps one on the Mac and as
the type `org.idpf.epub-folder` names it ([#680](https://github.com/vocaro/EPUBLib/issues/680)).
A host that declares that type passes the folder's URL, with security-scoped access to the
folder. The folder is read as an archive is, with the same refusals and limits: `resourceBytes`
for each file, `expandedBytes` for all of them, and `entryCount` for its files and folders
together; `archiveBytes` limits only an archive. A symbolic link anywhere in it is refused, as a
link entry in an archive is, and so is anything but a file or a folder. It need not hold
`mimetype`, which EPUB 3.3 §4.2.2 reserves for a ZIP container. Its `archiveData` is empty, and
its `id` is the SHA-256 of its files, so read them with `data(at:)` and key positions on
`persistentID` ([positions and highlights](#positions-and-highlights)).

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
A style whose `followsDynamicType` is set has its font size scaled by the system text size, as
body text is, also while the book is open ([commands and events](native-viewer.md#commands-and-events)).
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
compiled lifecycle code, from the reader screen in `Examples/VoiceOverVerification/Shared`:

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

    func reportImportError(_ error: Error) { self.error = Self.message(for: error) }

    /// What to tell the reader: what went wrong and, where the error says, what to do about it.
    nonisolated static func message(for error: Error) -> String {
        let error = error as NSError
        return [error.localizedDescription, error.localizedRecoverySuggestion].compactMap { $0 }.joined(separator: " ")
    }

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
                self.error = Self.message(for: error)
            }
            if let self, generation == token { loading = false; opening = nil }
        }
    }

    func install(_ book: EPUBPublication, engine: any EPUBReaderEngine) throws {
        let token = generation
        publication = book
        // Saved under the book's persistentID, or under an identity it had before.
        if let data = book.publicationIDs.lazy.compactMap({ UserDefaults.standard.data(forKey: "position.\($0)") }).first {
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
                case .failed(let value): error = Self.message(for: value); ready = false
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
        for id in publication.publicationIDs { UserDefaults.standard.removeObject(forKey: "position.\(id)") }
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

That code owns security-scoped access until import finishes and cancels expansion when another
book opens. `EPUBPublication.open` also accepts an optional `onProgress` callback with cumulative
expanded bytes; it runs synchronously on the importing thread and must return promptly.

## When something fails

Every error the library throws or emits is a `LocalizedError` with a plain message that a host
shows as it is ([#698](https://github.com/vocaro/EPUBLib/issues/698)): `EPUBPublicationError`
when a book cannot be opened, `EPUBReaderError` from a session, its `.failed` event or a failed
search, `EPUBTextExtractionError` and `EPUBWritingError`. Show `localizedDescription`, and under it
`recoverySuggestion` where there is one (`localizedRecoverySuggestion` as `NSError` has it).
SwiftUI's `alert(isPresented:error:actions:message:)` takes its title from `errorDescription` and
gives the error to its message, which can show the suggestion; AppKit's `NSAlert(error:)` shows
both; the complete reader above joins them in one line. `String(describing:)` still gives the case
and its detail, for a log rather than a person.

| The file | Case | Message | Suggestion |
| --- | --- | --- | --- |
| Is protected by DRM | `unsupportedEncryption` | This book is protected by DRM and cannot be opened. The file is not damaged. | Open it in the app it came from, or get a copy without DRM. |
| Is a ZIP archive with no EPUB `mimetype`, such as another kind of document | `notEPUB` | This file is not an EPUB book. | |
| Has no ZIP end record: another kind of file, such as a PDF, or an EPUB book cut short | `notArchive` | This file is not an EPUB book, or it is damaged. | If it is an EPUB book, download it again or get another copy. |
| Is an archive damaged in any other way | `invalidArchive` | This book is damaged and cannot be opened. | Download the book again, or get another copy. |
| Is over the import limits | `limitExceeded` | This book is too large to open. | |
| Lacks a part its package names | `missingResource` | Part of this book is missing. | Download the book again, or get another copy. |
| Has a malformed container or package | `invalidXML` | This book cannot be opened because it contains errors. | Download the book again, or get another copy. |
| Names a part outside the book | `unsafePath` | This book cannot be opened because it refers to files outside the book. | |

A file with no end record may be another kind of file or an EPUB book cut short, as by a download
that did not finish, and its message says both. A file that `open(at:)` cannot read at all, one
that is absent or that the app may not read, gives Foundation's own error, whose message is plain
already. `CancellationError` is the host's own cancellation, not a failure to show.

A session's errors say that the reader does not support an action, that a saved position belongs
to another book or reader, that it cannot carry out a request (`invalidCommand`), that it is not
ready (try again in a moment), that the book is closed, or that it cannot show the book
(`engineFailure`). The reader's controls show `message` beside a refused command or search: the
same text, except that for `invalidCommand` and `engineFailure` it is the engine's own detail.

The messages are in English, in the string catalog of the module that throws them
(`Localizable.xcstrings` in `EPUBCore`, `EPUBText` and `EPUBWriting`), each with a comment for its
translator, and each is looked up in that module's resource bundle, which an app built with the
package carries as it carries ZIPFoundation's. A translation added to a catalog reaches every host
([#684](https://github.com/vocaro/EPUBLib/issues/684)).

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

The names themselves are the book's, and the host still decides what to do with them
([archive paths](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#archive-paths-need-byte-level-delimiters-and-deliberate-normalization)):

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

To store a position, encode `EPUBLocation` using `JSONEncoder` and key it on
`publication.persistentID`, which every location the reader emits carries as its `publicationID`
([#679](https://github.com/vocaro/EPUBLib/issues/679)). It is the package's unique identifier,
which EPUB 3.3 §5.5.3.1.1 asks a book's makers to keep through minor revisions such as an edit
of the metadata. So a position saved in a book restores in a copy downloaded again, zipped again
with other compression, whose metadata a library manager such as Calibre edited, or unpacked
into a folder, and another edition, which has another unique identifier, does not take it. A
package without a unique identifier is known by the SHA-256 of its content: each resource it
holds and the order of its spine, without the package document, so an edit of its metadata
leaves that too. `publication.id` is still the SHA-256 of the file's bytes, which every such
copy changes.

On reopen, look the position up under each of `publication.publicationIDs` in order:
`persistentID`, then the content's SHA-256, for a position saved before the package gave a
unique identifier, then `id`, which locations carried before `persistentID`. Send
`.restore(location)` only when bookmarks are supported. The reader restores, and draws as a
highlight, a location that carries any of them, as far as its CFI resolves in the copy at hand,
and gives a `.notice` where it does not. The complete reader screen's `BookReader`
[above](#a-complete-reader) does this.

To tell versions of a book apart, compare `publication.releaseIdentifier`: the unique identifier,
`@` and the package's `dcterms:modified`, as EPUB 3.0.1 defined a release identifier. Two books
can give one unique identifier, which EPUB Reading Systems 3.3 §5.2 has a reading system not
depend on being unique to one publication. They then share a `persistentID`, and a position saved
in the one is restored in the other as far as its CFI resolves there. A host that must keep them
apart adds the title, `releaseIdentifier` or `id` to its key, at the cost of positions that a
metadata edit or another copy would otherwise keep.

Compare a stored bookmark with
`EPUBReader.identifier` and `EPUBReader.bookmarkFormat` rather than literal strings. A bookmark the
former WebKit reader stored (`org.epubreaderlib.foliate`, `epubcfi-v1`) is migrated by replacing
those two fields; its CFI value names the same position. If restoration reports an
incompatible location, offer an explicit section/quote fallback where supported.

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
shortcuts while the book stays mounted. The verification host's reader uses the default input
settings.
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
  event's character rather than a Mac physical key code. Where Shift makes a key type
  something other than a letter or digit, a binding with `.shift` names the character the key
  types without Shift in the keyboard layout in use: `.character("1")` with `.shift` is the 1
  key with Shift, which types "!" on a US keyboard. On a French keyboard, where Shift types the
  digits, the same binding is the key whose Shift types "1", and a digit bound without `.shift`
  is typed only on the numeric keypad ([#163](https://github.com/vocaro/EPUBLib/issues/163)).
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

## Setting book text

`EPUBReaderStyle.typography` sets the font, line and paragraph spacing, letter and word
spacing, page margins, alignment and hyphenation of book text. Send it with `.style`, or
change it through `controls.changeStyle`. A value left nil keeps the book's styles and the
reader's own defaults, and the reader keeps its place across every change, as it does for a
text size. `EPUBReaderStyle.Typography` is `Codable`, for a host that keeps a reader's choices.

<!-- snippet:typography -->
```swift
/// Registers a font the app bundles, once at launch, so that the reader finds it by its family
/// name. Listing it under `UIAppFonts` (iOS) or `ATSApplicationFontsPath` (macOS) in the app's
/// Info.plist does the same.
func registerBundledFont(at url: URL) {
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}

/// Sets book text in that font with WCAG 2.2's text spacing (SC 1.4.12), ragged and unhyphenated,
/// over the book's own styles. Preformatted text, code, tables and MathML keep the book's.
@MainActor
func readWithLegibleText(_ controls: EPUBReaderControls, family: String) {
    controls.changeStyle { style in
        style.typography = EPUBReaderStyle.Typography(
            fontFamily: .named(family), lineHeight: 1.5, paragraphSpacing: 2, letterSpacing: 0.12,
            wordSpacing: 0.16, pageMargins: 0.5, alignment: .start, hyphenation: false,
            overridesBookStyles: true)
    }
}
```
<!-- /snippet -->

- **Font.** `.serif` is the reader's own, New York; `.sansSerif`, `.rounded` and `.monospace`
  are the system font's designs; `.named` takes an installed family or one the app registers,
  such as a bundled Atkinson Hyperlegible or OpenDyslexic, by its family name. A character the
  font has no glyph for is drawn in the font the text would otherwise have, then in the
  system's fallback fonts, and a family that is not available leaves the book's font. The
  package bundles no font yet ([#692](https://github.com/vocaro/EPUBLib/issues/692)).
- **Spacing** is in ems of the text's font size: a line height of 1.5, paragraph spacing of 2,
  letter spacing of 0.12 and word spacing of 0.16 are WCAG's text spacing.
- **Margins** are a multiple of the reader's own side margins, 0 for none. They are the
  reader's, and apply whatever the book declares.
- **The book's styles.** With `overridesBookStyles` off, the default, the values set stand in
  for the reader's defaults, and the book's own declarations win where it makes them. With it
  on they apply to the book's text whatever it declares, as a reader's "publisher defaults"
  switch turned off does. Either way preformatted text, code, tables, MathML, SVG and boxes the
  book sizes or places keep the book's styles.

The rules and their limits are under "Reading adjustments" in the
[native viewer's decisions](native-viewer.md#decisions). The supplied controls have no setting
for these yet; a settings sheet is [#692](https://github.com/vocaro/EPUBLib/issues/692).

## Links outside the book

The bundled reader asks before it opens a link outside the book, and an app needs no code for
it. A web page or an email address that the reader activates, in the text, a table cell or a
note's popover, by pointer, keyboard or VoiceOver, brings up "Open a link outside the book?"
with the address, and Open opens it with the view's `openURL` action: the system's, so a web
page opens in the browser and an address in the mail app. Set your own `OpenURLAction` on the
reader's view to show web pages in the app; the reader still asks first. Any other link outside
the book, such as `javascript:`, `file:` or `data:`, is never opened or given to the app, and
`.notice` says so. What the reader does and why is under
[Security](native-viewer.md#security).

`epubReaderExternalLinks(_:)` changes this on a mounted view, as `epubReaderPageControls(_:)`
does input: `.ask` is the default, `.refuse` gives every such link the `.notice` "This reader
does not open links outside the book.", and `.handle` gives the app each web or email address
without asking, to ask and open in its own way.

<!-- snippet:externalLinks -->
```swift
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
```
<!-- /snippet -->

The modifier is specific to the native reader. Remote images, fonts and style sheets are never
fetched, whatever it says.

## Privacy manifest

A host declares nothing for EPUBLib in its privacy manifest. Apple has an app give a reason for
each API it calls that reads the system boot time, file timestamps, disk space, the active
keyboards or user defaults, and the five products, and the StaticSVG package and its resvg
library that EPUBViewing links, call none of them: the iOS reader times an edge tap by the
touch's own timestamps, and resvg is built without the file reads and backtraces that would call
`stat` and `fstat` ([#685](https://github.com/vocaro/EPUBLib/issues/685); StaticSVG 0.1.1 and
later). The gate reads their compiled code for
any such call ([testing](testing.md#local-gate)). ZIPFoundation, which reads and writes the
archives, reads file timestamps and declares that in a manifest of its own, which an app built
with EPUBLib carries in ZIPFoundation's resource bundle.
