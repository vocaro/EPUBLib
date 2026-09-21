# EPUBReaderLib

A Swift library for parsing and reading EPUBs with pluggable rendering engines.

EPUBReaderLib provides publication metadata, reading order, nested contents and resource access,
plus an engine-neutral SwiftUI reader interface. **EPUBReaderFoliate** supplies the initial
[foliate-js](https://github.com/johnfactotum/foliate-js) engine. A replacement engine can use native
views, another JavaScript library or a different rendering toolkit.

Requires Xcode 27 and iOS/iPadOS 27+ or macOS 27+. The manifest uses Swift tools 6.2. MIT licensed.

## Installation

Add `https://github.com/vocaro/EPUBReaderLib.git` at version **0.2.5** to your Swift package dependencies. Link
`EPUBReaderLib` for publication parsing and reader contracts; also link `EPUBReaderFoliate` to
use the bundled engine. No JavaScript build step or asset download is required. The examples below import
`EPUBReaderLib`, `EPUBReaderFoliate` and `Foundation`.

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

Create and retain a reading session on the main actor, then mount `EPUBReaderView(session:)`:

<!-- snippet:session -->
```swift
@MainActor
func makeReader(publication: EPUBPublication,
                onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
    let engine: any EPUBReaderEngine = FoliateEngine()
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

After `.ready`, send commands with `try await session.send(...)`. For example,
`.nextPage`, `.locate(text: "a passage", highlight: true)` or `.style(.init(fontSize: 20, isDark: true))`.
Navigate using an encoded resource href, safely handling optional entries:

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

Check `session.capabilities` before offering optional features. Retain the session outside `body`,
mount it once, and call `session.close()` when leaving the book. See the
[host integration guide](doc/integration.md) for a complete lifecycle example.

## Runnable sample

The [sample app](doc/sample.md) runs on iPhone, iPad and Mac, includes an original EPUB, and supports
file import, section navigation, typography, selection and saved positions. Its shared Swift
source is also compiled as `ReaderSampleSupport`; the navigation and lifecycle examples in these
docs are checked against that source.

## Features and boundaries

- EPUB 2 OPF/NCX and EPUB 3 OPF/navigation parsing, metadata, cover resource and reading order.
- Bounded archive import, path checks, CRC validation and an immutable source snapshot.
- Foliate pagination, scrolling, typography, local contents navigation, passage location,
  search highlighting, text selection, position events and precise engine-specific restoration.
- SwiftUI on iPhone, iPad and native Mac; keyboard and accessibility page-turn actions.
- No accounts, networking service, library database, app toolbar or persistence policy.

This is an initial release, not an EPUB conformance validator. See
[architecture and limitations](doc/architecture.md) for supported inputs, security boundaries and
bookmark portability. Readium and epub.js adapters are possible extensions, not included products.

## Verification

```sh
bash scripts/check-all.sh
```

The local gate checks docs and vendor identities, compiles the sample, and runs parser, adapter
contract, security and rendering tests on Mac and dedicated iPhone/iPad simulators. Rendering
fixtures include fixed layout, RTL, vertical writing, escaped filenames and a large illustrated
book. Live Mac tests need a graphical login. See [testing](doc/testing.md) for prerequisites,
coverage boundaries and the reusable `EPUBReaderTesting` product for new adapters.

See [release and API compatibility policy](doc/releasing.md) and [release notes](doc/changelog.md).

## Licenses

The library is MIT licensed. ZIPFoundation is MIT. Bundled foliate-js is MIT and its zip.js bundle
is BSD-3-Clause. Upstream license texts ship in the resource bundle; their pinned identities are
in [the vendor manifest](doc/vendor-manifest.json). See [third-party notices](doc/third-party-notices.md).

## Extracting text

Use `publication.textSection(at:)` to read XHTML text, chapter titles and EPUB semantic roles
without creating a viewer. Resource hrefs and spine indices connect the result to the book.
See the [text-extraction API](doc/text-extraction.md) for limits, errors and normalization rules.
