# Release notes

## Unreleased

- Replace the bundled foliate-js WebKit renderer with a native TextKit 2 viewer ([#3](https://github.com/vocaro/EPUBLib/issues/3)). CFIs are generated and resolved exactly as foliate-js did, so a CFI the WebKit reader recorded names the same position. See [native viewer](native-viewer.md).
- `EPUBReader` has its own engine identifier, `org.epublib.reader`, and bookmark format, `epublib-cfi-v1`, as `EPUBReader.identifier` and the new `EPUBReader.bookmarkFormat`. Bookmarks tagged `org.epubreaderlib.foliate`/`epubcfi-v1` are refused as another engine's; nothing had shipped, so hosts migrate stored ones by replacing those two fields (the CFI value is unchanged).
- Continuous scroll is one real scroll view over the whole book, running under the bars with the system scroll edge effects; the drawn edge fades are gone and nothing resets at a section boundary. This supersedes the unreleased interim bottom-inset fix (`4b7942d`) ([vocaro/studywright#379](https://github.com/vocaro/studywright/issues/379), [#73](https://github.com/vocaro/studywright/issues/73)).
- Page turns use one or two columns by the page's own size, and `View.epubReaderDivision(_:)` puts a two-column spread's gutter on a host-reserved fold ([vocaro/studywright#278](https://github.com/vocaro/studywright/issues/278)).
- Add `EPUBReaderCommand.setHighlights`, `EPUBHighlight` and the `highlights` capability, drawing host highlights while reading ([vocaro/studywright#85](https://github.com/vocaro/studywright/issues/85)). Selections have no length cap.
- Render tables, images, footnote popovers and MathML natively; MathML through the new [MathMLLayout](https://github.com/vocaro/MathMLLayout) package (0.1.0), which began as a target here and moved to its own repository. Fixed-layout books reflow and vertical writing renders horizontally, each with a disclosure; sessions advertise every capability.
- `EPUBPublication.pageProgression` exposes the spine's `page-progression-direction`.
- With nothing restored, the reader opens a book at its text start, as foliate-js's `showTextStart` did: the first `bodymatter` landmark (or EPUB 2 guide `text` reference), else the first linear section. Standard Ebooks titles open on chapter one, not their cover or titlepage, as they did in 0.2.5. A `.restore` sent after `.ready` replaces it.
- `EPUBPublication.landmarks` lists the navigation document's landmarks, or the OPF guide's references in a book without them, as `EPUBLandmark` values. A landmark that does not resolve inside the archive is left out rather than refusing the book.
- Read the navigation document's `epub:type` by its namespace, so a plain `type` on the same `<nav>` or landmark link no longer replaces it, which could empty the contents or mislabel a landmark ([#11](https://github.com/vocaro/EPUBLib/issues/11)). Any prefix bound to the OPS namespace counts, and an undeclared `epub` prefix still does; an `epub` prefix bound to another namespace no longer does.
- Remove foliate-js, zip.js, the bootstrap page, scheme handler, URL patch, JavaScript bridge and vendor identity check. The Mac sample no longer needs the network client entitlement.

## 0.2.5

- Turn a scrolled-flow section on a swipe's whole travel, judged on every `touchmove` and once more at `touchend`, and listen on the host document as well as the section's ([vocaro/studywright#74](https://github.com/vocaro/studywright/issues/74)). WebKit can deliver one or no `touchmove` events for a quick flick, and a section shorter than the viewport leaves page around its iframe where a touch never reached the section's own document; either alone was enough to lose the swipe. Paginated flow, the wheel path and the Mac are unchanged.
- Add an iOS regression that flicks with no `touchmove` at all, dispatched on the host page.
- Public APIs, dependencies and bookmark formats are unchanged.

## 0.2.4

- Stop drawing the continuous-scroll edge fade on macOS, where the host has no chrome floating over the page ([vocaro/studywright#155](https://github.com/vocaro/studywright/issues/155)). iOS rendering is unchanged.
- Public APIs, dependencies and bookmark formats are unchanged.

## 0.2.3

- Use adaptive CSS system colors for the Foliate dark-mode fallback.
- Preserve live iOS toolbar clearance and avoid redundant scroll-inset updates.
- Public APIs, dependencies and bookmark formats are unchanged.

## 0.2.2

- Fix missing tables of contents when navigation role tokens use tabs or line breaks ([#1](https://github.com/vocaro/EPUBReaderLib/issues/1)).
- Accept harmless XML declaration examples in comments, CDATA and processing instructions while continuing to reject real entity declarations and internal DTD subsets ([#2](https://github.com/vocaro/EPUBReaderLib/issues/2)).
- Add eight parsing regressions, including Unicode encodings and quoted external identifiers.
- Public APIs, dependencies, rendering engines and bookmark formats are unchanged.

## 0.2.1

- Exclude script/style/template text inside embedded foreign content such as SVG, while preserving diagram labels.
- Add a regression for embedded SVG text extraction. Public API signatures are unchanged.

## 0.2.0

- Public `EPUBTextSection` and `EPUBPublication.textSection(at:limits:)` API for renderer-free XHTML extraction.
- Chapter/resource identity, titles, linearity and namespace-aware EPUB semantic labels.
- Structural whitespace, entity/CDATA decoding and lossless word-joiner handling.
- Explicit malformed-content/media/index failures, per-section limits and cancellation.
- Ported extraction regressions and new policy-neutral, namespace, Unicode and limit tests.

## 0.1.0

- Initial tagged release of the publication parser, pluggable reader API and bundled Foliate adapter.
- iOS/iPadOS 27 and macOS 27 minimum deployment targets.
- Encoded resource hrefs and navigation/position round trips for reserved filename characters.
- Per-section layout metadata; fixed-layout sessions omit unsupported typography and scrolling.
- Synchronous import progress callbacks and cooperative cancellation during expansion.
- Parser safety regressions and exact IDPF/Adobe font obfuscation tests.
- Shared engine-contract test product with native and Foliate adapter checks.
- Mac, iPhone and iPad rendering coverage, including fixed layout, RTL, vertical writing and images.
- Runnable SwiftUI sample, checked documentation examples and release compatibility policy.

See the [verification record](verification-0.1.0.md) for the OS builds and test results.
