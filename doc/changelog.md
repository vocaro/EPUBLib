# Release notes

## Unreleased

- In continuous scroll on iOS, keep no bottom content inset on the web view, so the page runs down to the host's bottom bar and its bottom edge fade lands there ([vocaro/studywright#379](https://github.com/vocaro/studywright/issues/379)). WebKit sizes the page to the web view's safe area and lets the scroll view place it, and the 64-point inset rested the page at the top inset instead, above the toolbar's bottom edge, leaving a band below the page where no text drew. Page turns keep the inset. The paginator's own 48-point section margin keeps a section's last line clear of the bar.
- Add an iOS regression that switches flows and checks the bottom inset each one keeps.
- Public APIs, dependencies and bookmark formats are unchanged.

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
