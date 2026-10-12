# Release notes

## Unreleased

- Keep each occurrence of a repeated spine item's own position. A bookmark, highlight or reported location in the second or third repeat named the first, so restoring it went back there. Positions saved by foliate-js still resolve ([#108](https://github.com/vocaro/EPUBLib/issues/108)).
- Page through a book in which no spine item is linear. Next Page was disabled at the end of its first section in paging, though continuous scroll showed the whole book ([#159](https://github.com/vocaro/EPUBLib/issues/159)).
- Stop taking the language of a content document that declares none from the package's `dc:language` for generated text: the marks around `q` and locale-sensitive case mapping follow only `lang` and `xml:lang` in the content, so an unlabelled French book gets “ ” around `q`, not « ». The package's language remains a hint for glyph choice and speech ([#109](https://github.com/vocaro/EPUBLib/issues/109)).
- Show the inline search field's queued line only for a queued search. It appeared for every command, briefly resizing inline controls and the reader under them, so on iPhone and iPad the first Next Page press after opening a book landed back on the same page ([#28](https://github.com/vocaro/EPUBLib/issues/28)).
- Leave focus alone when the control strip's inline search field appears. It focused itself as a search pane's field does, so opening a book on iPhone raised the keyboard over most of the page and started VoiceOver in an editing field ([#28](https://github.com/vocaro/EPUBLib/issues/28)).
- Give VoiceOver an iPad spread's columns in source order. A chapter opening's left column, lowered by its top spacing, was read after the right column ([#28](https://github.com/vocaro/EPUBLib/issues/28)).
- Break MathML formulas wider than their line into full-size rows at relations, operators and authored `linebreak`s instead of shrinking them below three quarters of the text's size; disclose the ones no row can keep readable. Show `mglyph` alternatives in place and set `mstack` and `mlongdiv` as digit-column tables, each disclosed. Read `alttext` in the content's language and tag generated English readings as English ([#25](https://github.com/vocaro/EPUBLib/issues/25)).
- Honor flex and grid alignment that keeps the reading column: center or distribute a column flex container's or one-column grid's items within a definite `height` or `min-height`, align items across the line, and place a row container's only item, in paginated and continuous-scroll flow. Standard Ebooks epigraphs, dedications and centered title pages sit in the middle of their page or visible area. Side-by-side, wrapped, reversed, reordered and multi-column layouts stay in reading order with a disclosure; text, search, selections, highlights and CFIs are unchanged. The first page of a section with floats or positioned boxes no longer doubles the space above its first line ([#20](https://github.com/vocaro/EPUBLib/issues/20)).
- Repaint the text on screen whenever search or host highlights change. Clear Search now removes the painted matches at once in paging and continuous scroll, and a highlight-only search or a host highlight on the page shown appears without waiting for a page turn or reflow ([#51](https://github.com/vocaro/EPUBLib/issues/51)).
- Name the Mac reading-mode segments Continuous Scroll and Paging for assistive technology, in place of their symbols' descriptions. Keep the supplied text-size steps within the 12–36 points the reader draws at distinct sizes, disabled at either end ([#51](https://github.com/vocaro/EPUBLib/issues/51)).
- Resolve ordinary paragraph percentage margins, padding and indents at the live containing width, retaining source positions across resizing. Use the resolved font's x-height for `ex` lengths and preserve author caption alignment ([#21](https://github.com/vocaro/EPUBLib/issues/21)).
- Preserve locale-tailored base-strength search distinctions, including Turkish I, Swedish letters, Spanish ñ and Cyrillic й, for passage location and search highlighting ([#26](https://github.com/vocaro/EPUBLib/issues/26)).
- Describe enabled keyboard and gesture inputs in page-button help, with host customization and flow-aware labels ([#50](https://github.com/vocaro/EPUBLib/issues/50)).
- Preserve SVG diagram shapes and labels when unsupported filter effects are omitted with a disclosure, including the networking book's TCP/IP layers ([#53](https://github.com/vocaro/EPUBLib/issues/53)).
- Keep labelled SVG figures mounted when a reader is resized and its text size or appearance changes, as a cold open at that size and style shows them. Share one renderer font database among drawings naming the same fonts within the existing 64 MiB budget, and release a replaced layout's and a closed reader's images at once ([#54](https://github.com/vocaro/EPUBLib/issues/54)).
- Add search results to the native reader: `EPUBSearchResults` lists every rendered match with its section, context and location, a count and the current match, and `.nextSearchResult`, `.previousSearchResult` and `.showSearchResult` move between them in both flows. The search pane gains a count indicator, Previous/Next Match buttons and a result browser, also available as `EPUBSearchResultNavigator` and `EPUBSearchResultList`. Results follow spine order, stepping wraps at the ends, and page navigation leaves the current match alone. Hosts with exhaustive switches must handle the new `.searchResults` capability, the three commands and `.searchResultsChanged`; engines that only highlight are unchanged. `.completed(hasMatches:)` now counts only matches that render. See [search results](reader-controls.md#search-results) ([#49](https://github.com/vocaro/EPUBLib/issues/49)).
- Tell Mac VoiceOver which columns changed when a page is installed, so it reads the new page from its first line instead of repeating the previous page. Keep its end-of-page and remembered text offsets on the page's last line, correcting a nonsensical visible-line count and a silent column after the page became shorter ([#55](https://github.com/vocaro/EPUBLib/issues/55)).

- Bound paginated Mac accessibility text and line queries to the visible source range. Expose visible UIKit accessibility runs with link, image, table and page actions while preserving hidden TextKit context for layout ([#28](https://github.com/vocaro/EPUBLib/issues/28)).
- Preserve Foliate CFIs for qualified XML-shaped HTML, including whitespace around the head/body. Refuse saved positions and highlights for unqualified HTML tree repairs, omit unsafe bookmarks and disclose the limitation while retaining readable content ([#27](https://github.com/vocaro/EPUBLib/issues/27)).
- Measure long justified continuation tails with the exact bounded displayed slice. Keep complete source lines within the intended page area across columns, resizing and RTL; remove synthetic padding and the column-growth workaround ([#30](https://github.com/vocaro/EPUBLib/issues/30)).
- Keep continuous-scroll section jumps on the requested passage after distant diagram visits. Correct refined TextKit estimates until the target is visibly aligned, retaining bounded work and fresh-layout recovery ([#41](https://github.com/vocaro/EPUBLib/issues/41)).
- Wrap continuous-scroll Mac prose within the actual native scroll viewport, including space occupied by legacy scrollbars. Preserve the passage through resize, recalculate wrapping after scrollbar changes, and reserve fractional native float bounds without changing the authored content width ([#47](https://github.com/vocaro/EPUBLib/issues/47)).
- Preserve authored MathML alternatives in headless extraction, or serialize fractions, powers, indices, roots and fences with explicit structure. Preserve UTF-8 anchors, headings and existing extraction limits without executing math scripts or loading resources ([#44](https://github.com/vocaro/EPUBLib/issues/44)).
- Support XHTML named character references without loading DTDs, and add opt-in HTML recovery for malformed content with a `recoveredAsHTML` result flag. Preserve extraction limits, cancellation, source bytes and declaration/network protections ([#43](https://github.com/vocaro/EPUBLib/issues/43)).
- Make native table cell text selectable with precise CFIs, Copy, host selection actions, saved highlights and internal, note and external-link handling, including continued rows ([#23](https://github.com/vocaro/EPUBLib/issues/23)).
- Coordinate native selections across both columns in either reading direction. Preserve the complete located passage, Copy text and saved range through page turns and typography changes, with controls to follow offscreen selected text ([#29](https://github.com/vocaro/EPUBLib/issues/29)).
- Render static SVG illustrations with bundled resvg on Mac, iPhone and iPad, including paths, text, transforms, gradients and clipping. Resolve archive raster resources within bounded memory; disclose unsupported filters, pattern fills, animation and foreign content with authored fallback text ([#22](https://github.com/vocaro/EPUBLib/issues/22)).
- Keep sample page arrows pinned at the trailing edge on iPhone/iPad instead of moving
  into overflow. Keep Mac page arrows in a native group with visibility priority above
  the other controls, and keep the reading-mode picker at its natural width.

- Preserve authored nonempty XHTML image alternatives in headless text extraction, including formula images, truth-table headings and exercise items. Image IDs, headings and later anchors include the alternative's UTF-8 bytes; decorative images contribute nothing ([#37](https://github.com/vocaro/EPUBLib/issues/37)).
- Keep transparent dark diagram strokes readable in dark appearance with a faithful white backdrop. Preserve original colors and source bytes, retaining explicit author inversion and the bounded image cache ([#34](https://github.com/vocaro/EPUBLib/issues/34)).
- Add native image inspection with zoom, pan, fit and close controls on Mac, iPhone and iPad, including table images and page-image fallbacks. Decode from archive pixels independently of body typography, keeping inspection bounded and preserving reader position and selection ([#35](https://github.com/vocaro/EPUBLib/issues/35)).

- Default reader appearance to System, following live host/OS color scheme changes. Add
  `EPUBReaderAppearance` (System/Light/Dark), `EPUBReaderStyle.appearance`, and resolved
  `EPUBReaderStatus.effectiveAppearance`. Explicit `isDark:` calls and writes remain supported.

- Move Continuous Scroll/Paging into a separate `.readingMode` control group with joined
  mode buttons using `scroll` and `doc.text` symbols. Successful toolbar searches no longer
  show a redundant highlight message. Keep command progress within the controls so search
  submissions do not shift the toolbar or its popover. Give the search pane an explicit X
  to close it, separate from Clear Search.

- Add `.search(text:)` and the `.search` capability for highlighting matches and opening the
  first rendered match. The reader toolbar uses this action when available; `.searchHighlight`
  remains highlight-only. Hosts with exhaustive command switches must handle the new case.

- Continue oversized native table rows and rowspan text across pages without clipping glyph lines; preserve source offsets and read each continued word once ([#24](https://github.com/vocaro/EPUBLib/issues/24)).
- Wrap native prose around left/right floats, including auto-width drop caps and archive images; honor float clearing, positioned callout insets and sized inline-blocks beside surrounding text. Preserve native selection, links and source offsets. Oversized or complex box groups continue in reading order with a layout disclosure; fixed boxes appear once, without page pinning ([#19](https://github.com/vocaro/EPUBLib/issues/19)).
- Add optional `EPUBLocation.rangeBookmarks` to preserve every section of a saved selection or highlight while retaining existing single-section bookmarks. Keep selections through typography and flow changes ([#31](https://github.com/vocaro/EPUBLib/issues/31)).
- Add live `View.epubReaderPageControls(_:)` configuration for native page input: independent gesture toggles, physical edge widths and replacement keyboard bindings, with `.hostOnly` for host controls. Commands, selection and accessibility remain available ([#32](https://github.com/vocaro/EPUBLib/issues/32)).
- Add optional `EPUBReaderToolbar`, `EPUBReaderControlStrip` and individually composable control groups, backed by a retained `EPUBReaderControls` model. Sessions expose observable lifecycle, style, location, boundaries and command activity through `readerState`; existing session conformers default to nil. See [reader controls](reader-controls.md).
- Add `EPUBSearchState` and `.searchChanged` events for search pending, completion/no-match, validation failures and clearing. Hosts with exhaustive event switches must handle the new case. The toolbar-free viewer API is unchanged.

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
- Read print and source page equivalents, and report the pages on screen ([#17](https://github.com/vocaro/EPUBLib/issues/17)). `EPUBPublication.pageList` lists the navigation document's `page-list`, `hidden` or not, or else the NCX's `pageList`, as `EPUBPageListEntry` values; it is nil for a book without one. `EPUBLocation.page` is the entry in effect where the shown (or selected) range starts, and `pages` every entry the range shows part of, so a screen holding the end of page 4 and the start of page 5 reports 4 and [4, 5]. Both are optional, so saved locations still decode.
- Open EPUBs that other converters write with three faults instead of refusing them: a manifest item repeated verbatim is read once, an item whose file the archive lacks is left out of `resources` (a spine item still needs its document), and a C0 control character in an ASCII-compatible XML document reads as a space. One manifest id naming two different resources is still refused. Of 165 EPUBs from two Mac PDF-to-EPUB converters, 93 were refused before; now only one is, whose spine is empty.
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
