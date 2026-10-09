# EPUBLib

A shared Swift package for EPUB reading, text extraction, writing and viewing on iOS/iPadOS
and macOS 27+. Requires Swift 6.2 and Xcode 27. MIT licensed.

## Products

Choose the products your consumer uses. Their target dependencies enforce the boundaries:

| Product | Responsibility | Dependencies |
| --- | --- | --- |
| `EPUBCore` | Publication/resource/navigation values and reader value types | Foundation |
| `EPUBReading` | Bounded, immutable archive import and OPF/navigation parsing | EPUBCore, ZIPFoundation |
| `EPUBText` | XHTML text, semantics, headings and UTF-8 anchor positions in one walk | EPUBCore, EPUBReading, Apple libxml2 |
| `EPUBWriting` | EPUB 3 package/navigation generation and streaming archive output | EPUBCore, ZIPFoundation |
| `EPUBViewing` | SwiftUI reader sessions and native TextKit 2 rendering | EPUBCore, EPUBReading, [MathMLLayout](https://github.com/vocaro/MathMLLayout) |

The headless products import neither SwiftUI nor WebKit. A viewer does not depend on text
extraction or writing. PDF layout reconstruction, study section policy and app chrome belong to
consumers. One package pins these cooperating products together; there is no umbrella module.

## Installation

Add `https://github.com/vocaro/EPUBLib.git`, pinned to a reviewed commit. Link `EPUBReading`
for publication parsing, `EPUBText` for structural extraction, `EPUBWriting` for generation,
and `EPUBViewing` for the reader. Import `EPUBCore` when using its value types directly.
No web view, JavaScript or asset download is involved. See [architecture](doc/architecture.md),
[text extraction](doc/text-extraction.md) and [writing](doc/writing.md).

## Reading and viewing

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

- EPUB 2 OPF/NCX and EPUB 3 OPF/navigation parsing, metadata, cover resource, landmarks, page list
  and reading order.
- Bounded archive import, path checks, CRC validation and an immutable source snapshot.
- Native TextKit 2 page turns with one or two columns (and a host-reserved fold), whole-book
  continuous scroll under the system bars, typography, local contents navigation, footnotes,
  tables, images and MathML, passage location, search and host highlights, native text
  selection, position events with the pages on screen and EPUB CFI restoration compatible with
  the former WebKit reader.
- SwiftUI on iPhone, iPad and native Mac; keyboard and accessibility page-turn actions.
- No accounts, networking service, library database, app toolbar or persistence policy.

This is an initial release, not an EPUB conformance validator. See
[architecture and limitations](doc/architecture.md) for supported inputs, security boundaries and
bookmark portability, and the [native viewer](doc/native-viewer.md) for its design and limits.

## Verification

```sh
bash scripts/check-all.sh
```

The local gate checks module boundaries and docs, compiles the sample, and runs parser, adapter
contract, security and rendering tests on Mac and dedicated iPhone/iPad simulators. Rendering
fixtures include fixed layout, RTL, vertical writing, escaped filenames and a large illustrated
book. Live Mac tests need a graphical login. See [testing](doc/testing.md) for prerequisites,
coverage boundaries and internal adapter-contract tests.

See [release and API compatibility policy](doc/releasing.md) and [release notes](doc/changelog.md).

## Licenses

The library is MIT licensed. ZIPFoundation is MIT. The CFI and text-search code is ported from
foliate-js (MIT). See [third-party notices](doc/third-party-notices.md).

## Extracting text

Use `publication.textSection(at:)` to read XHTML text, chapter titles and EPUB semantic roles
without creating a viewer. Resource hrefs and spine indices connect the result to the book.
See the [text-extraction API](doc/text-extraction.md) for limits, errors and normalization rules.
