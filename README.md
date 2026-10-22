# EPUBLib

EPUBLib opens, reads and displays EPUB books in native iOS, iPadOS and macOS apps. It can also
extract a book's text and write new EPUB files. Books are read into a bounded, immutable snapshot
and shown with SwiftUI and TextKit 2, with no web view or JavaScript.

Requires iOS/iPadOS or macOS 27+, Swift 6.2 and Xcode 27.

## Features

- EPUB 2 and EPUB 3 metadata, reading order, contents, landmarks and page lists.
- Bounded archive import with path checks and CRC validation.
- Section text, headings, semantic roles and anchor positions, without a reader.
- EPUB 3 package and navigation generation with streaming archive output.
- A native reader with page turns in one or two columns and whole-book continuous scroll.
- Footnotes, tables, images, SVG and MathML.
- Search, passage location, text selection and host highlights.
- Positions saved as EPUB CFIs, compatible with the former WebKit reader.
- An optional toolbar and control strip for search, contents, appearance and reading mode.
- Page turns by tap, swipe, wheel, keyboard and VoiceOver on iPhone, iPad and Mac.

EPUBLib leaves accounts, networking, storage and library management to the app. It is not an EPUB
conformance validator. Fixed-layout books reflow and vertical writing is shown horizontally, each
with a disclosure; see the [native viewer's limitations](doc/native-viewer.md#limitations).

## Products

Link only the products you use. The headless products import neither SwiftUI nor WebKit, and the
viewer depends on neither text extraction nor writing. There is no umbrella module.

| Product | Use it to | Depends on |
| --- | --- | --- |
| `EPUBCore` | Share publication, resource, navigation and reader value types | Foundation |
| `EPUBReading` | Open and parse a book | EPUBCore, ZIPFoundation |
| `EPUBText` | Extract a section's text, headings and anchor positions | EPUBCore, EPUBReading, Apple's libxml2 |
| `EPUBWriting` | Generate an EPUB 3 package and archive | EPUBCore, ZIPFoundation |
| `EPUBViewing` | Show a book in a SwiftUI reader | EPUBCore, EPUBReading, [MathMLLayout](https://github.com/vocaro/MathMLLayout) |

## Installation

Add `https://github.com/vocaro/EPUBLib.git` to your package dependencies, pinned to a reviewed
commit, and link the products you need. See the [release policy](doc/releasing.md).

## Getting started

Open a book with `EPUBPublication.open(at:)` off the main actor. To show it, create a session with
`EPUBReader().makeSession(publication:selectionAction:onEvent:)`, retain it, and mount
`EPUBReaderView(session:)`. Once the session emits `.ready`, send it commands such as `.nextPage`
or `.navigate(href:)`. The [host integration guide](doc/integration.md) walks through each step
with compiled examples.

## Documentation

- [Host integration](doc/integration.md): opening a book, reader sessions, commands, positions and
  page controls.
- [Reader controls](doc/reader-controls.md): the optional toolbar, control strip and search results.
- [Text extraction](doc/text-extraction.md): section text, headings and positions without a reader.
- [Writing](doc/writing.md): generating EPUB 3 packages and archives.
- [Architecture](doc/architecture.md): products, the publication model, supported input and
  security.
- [Native viewer](doc/native-viewer.md): the reader's design, decisions and limitations.
- [Testing](doc/testing.md): the local gate, coverage, corpus runs and VoiceOver testing.
- [Releasing](doc/releasing.md): versioning, compatibility and persisted formats.
- [Changelog](CHANGELOG.md): release history.

## License

EPUBLib is copyright (c) 2026 Vocaro Technologies LLC and available under the
[MIT license](LICENSE). ZIPFoundation, MathMLLayout, StaticSVG and the resvg renderer it bundles,
and the code ported from foliate-js carry their own licenses; see
[third-party notices](doc/third-party-notices.md).

## Shared engineering

See [shared engineering](doc/shared-engineering.md) for common guidance, tooling, reusable
packages and new-project onboarding.
