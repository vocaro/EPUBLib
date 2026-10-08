# Native viewer

EPUBLib renders reflowable EPUB with TextKit 2 behind the unchanged `EPUBReaderEngine` seam
([vocaro/EPUBLib#3](https://github.com/vocaro/EPUBLib/issues/3)). This document is the design
and the contract between its parts. Everything below lives in the `EPUBViewing` target under
`Sources/EPUBViewing/Native/` and is internal unless marked public.

## Pipeline

```
EPUBPublication ──▶ ContentDocument ──▶ StyleResolver ──▶ SectionBuilder ──▶ SectionText
 (EPUBReading)      Document/           Style/            Text/ (+ RichContentFactory)
                                                                │
              EPUBCFI / SpineCFIs / TextSearch ◀── TextMap ◀────┘
              Position/                                          │
                                                                 ▼
            NativeSession (Session/) ──▶ ReaderCanvas (View/: UITextView / NSTextView, TextKit 2)
```

1. **Document** (`ContentDocument`). libxml2 parses each spine item into an element/text tree
   that matches what an EPUB CFI sees: comments and processing instructions dropped, adjacent
   text and CDATA merged. Named HTML entities become numeric references before an XML parse;
   markup that is not well-formed falls back to libxml2's HTML parser and is reported.
   `XMLSafety` refuses entity declarations first. No DTD or network access, depth and node limits.
2. **Style** (`StyleResolver`, `CSSStyleSheet`, `FontRegistry`). A bounded CSS parser and
   cascade over a user-agent stylesheet, the book's archive-local stylesheets and `style`
   attributes produce a `ComputedStyle` per element: the CSS subset in `ComputedStyle.swift`.
   `@font-face` fonts load from the archive with CoreText. Nothing remote is fetched.
3. **Text** (`SectionBuilder`). One walk of a section's DOM produces an `NSAttributedString`,
   a `TextMap` back to DOM positions, element anchors, note content and a `SectionReport`.
   Rich content (images, SVG, tables, MathML, rules) comes from a `RichContentFactory` as text
   attachments. A section's characters depend only on its document, never on typography.
4. **Positions** (`EPUBCFI`, `SpineCFIs`, `TextSearch`). Swift ports of foliate-js
   `epubcfi.js`, `search.js` and `text-walker.js` (MIT) over `ContentDocument`, producing and
   resolving the same CFIs foliate-js produced, and locating quotes with its matcher.
5. **Views** (`ReaderCanvas`, `ReaderCanvasView`). TextKit 2 text views: one real scroll view
   over the whole book for continuous scroll, and section pages sliced from one layout per
   column width for page turns.
6. **Session** (`NativeEngine`, `NativeSession`, `NativeBook`). The `EPUBReaderSession`:
   commands, events, capabilities, section building and caching, locations and bookmarks.

## Decisions

- **Engine identity and bookmarks.** `EPUBReader.identifier` stays `org.epubreaderlib.foliate`
  and bookmarks stay `epubcfi-v1`. A CFI names a DOM position, not a renderer state, so the
  native engine accepts every bookmark and highlight locator the WebKit reader stored and emits
  CFIs in the same form (relocations carry the visible range CFI, selections the selection's
  range CFI). No stored data is migrated. A CFI that no longer resolves (a changed book has a
  different publication ID and is rejected before that) produces a `.notice`, as before.
- **Fixed layout.** Out of scope at first: neither StudyWright catalog (50 shipped EPUBs, 87
  PDFReflowLib conversions) contains a pre-paginated book. Fixed-layout spine items render as
  reflowable text with a `.disclosure`; capabilities are not reduced.
- **Vertical writing.** TextKit 2 on iOS has no vertical layout. `writing-mode: vertical-*`
  renders horizontally, with a `.disclosure`. Ruby and right-to-left text are native.
- **MathML.** A native layout engine (CoreText) draws each `<math>` as an attachment,
  baseline-aligned inline and centred for `display="block"`. The corpus uses `mi`, `mn`, `mo`,
  `mrow`, `mfrac`, `msup`, `msub`, `msqrt` and `mstyle` (1,798 formulas, all with `alttext`);
  the engine also covers the common remainder. Anything it cannot lay out shows its `alttext`
  and is disclosed. No WebKit.
- **SVG.** Every inline SVG in the corpus wraps one `<image>` (covers and title pages); those
  render as that image with the SVG's sizing. Other SVG is shown where the platform image
  decoder supports it, else as its title or nothing, and is disclosed.
- **Tables.** Attachments drawn natively (TextKit 2 has no `NSTextTable` on iOS), one
  attachment per row group so pages can break between rows; `colspan`/`rowspan` honoured.
  Cell text is not selectable; it is searchable and readable by VoiceOver.
- **Footnotes.** EPUB 3 `noteref` links show their note in a popover. Footnote `aside`s are
  hidden from the flow; endnotes stay in place and also show in popovers.
- **Continuous scroll** is whole-book: one `UITextView`/`NSTextView` over every section, so
  nothing resets at a section boundary and the system scroll edge effects apply. Until every
  section is built it shows the current section, then swaps to the whole book in place.
- **Building** is per section and lazy for first paint: the initial section builds first and
  the session emits `.ready` once it is on screen; the rest build in the background in
  parallel. Images decode lazily, downsampled to their displayed size, under a shared cache
  budget.
- **Highlights.** New public `EPUBReaderCommand.setHighlights([EPUBHighlight])` and capability
  `.highlights` draw host highlights from their range CFIs (StudyWright #85). Search and
  highlights are TextKit 2 rendering attributes; they never change the text.
- **Book pose.** New public `View.epubReaderDivision(_:)` reserves a vertical division in the
  reader's own coordinates. Columns never depend on device idiom, orientation or screen.

## Layout

All lengths are points. These follow foliate-js's paginator defaults, so books lay out much
as they did.

- **Columns.** Paginated flow uses two columns when the page is landscape (width > height)
  and its content width, 93% of the width, is more than 720 (about 775 pt wide); otherwise one.
  The outer horizontal margin is at least 3.5% of the width each side, columns are at most 720
  wide (the content area is centred when that caps it), the column gap is 7.53% of the content
  width (foliate's `g / (1 − g)` with g = 7%), and the top and bottom margins are 48.
- **Book pose.** With a vertical division the spread always has two columns: the gutter is the
  division band plus half a gap each side, and both columns have the narrower side's width,
  aligned towards the fold. In continuous scroll the single column uses the wider side.
- **Continuous scroll.** One column at most 720 wide, centred, with the same outer margin. On
  iOS the text view has `contentInsetAdjustmentBehavior = .automatic`, `contentInset` top 48
  and bottom 64 on top of the live safe area, `textContainerInset` only horizontal, and
  `.soft` top and bottom edge effects; nothing is drawn. On macOS the scroll view uses AppKit's
  automatic content insets and the window toolbar's own edge effect.
- **Pages.** A section is laid out once per column width; pages are slices of that layout at
  line boundaries, never splitting a line, honouring `.readerPageBreakBefore` (CSS
  `break-before: page`) and keeping a `.readerKeepWithNext` paragraph with the next. A spread
  shows consecutive slices. Each column is a non-scrolling TextKit 2 text view showing its
  slice, so selection, VoiceOver and link interaction are native.
- **Right to left.** `page-progression-direction="rtl"` mirrors spreads, swipes and tap zones.

## Input and accessibility

- Paginated: 56-pt tap zones at both edges, horizontal swipes, and on macOS a horizontal or
  vertical wheel tick turns a page. Continuous scroll scrolls natively.
- Keys (all flows): Left/Page Up previous, Right/Page Down/Space next, Shift-Space previous.
  In continuous scroll a page turn scrolls by one viewport less a line.
- VoiceOver: page-turn actions via `accessibilityScrollAction` and the named "Next Page" and
  "Previous Page" actions; text reads in order from the text views.
- Selection: native selection UI with the host's `EPUBSelectionAction` in the edit or context
  menu, no length cap. `.selectionChanged` settles 150 ms after the selection stops changing.

## Commands and events

| Command | Behaviour |
| --- | --- |
| `nextPage` / `previousPage` | Page turn (paginated) or one viewport (scrolled); stops at the book's ends; skips nonlinear sections as foliate-js did. |
| `navigate(href:)` | An encoded spine or resource href with optional fragment; unknown or non-local hrefs throw `invalidCommand`. |
| `restore(location)` | Same publication, engine ID and `epubcfi-v1` format or `incompatibleLocation`; resolves the CFI and shows its start. |
| `locate(text, highlight)` | First match in reading order with foliate's matcher. `highlight` selects it natively (emitting `.selectionChanged` with the passage). A miss emits `.notice("the cited passage could not be found in this book")`. Clears search highlights. |
| `searchHighlight` / `clearSearch` | Draws every match across the book / removes them. |
| `style` | Font size 12–96, dark, flow. Size or appearance rebuilds the text; the position is kept across rebuilds and flow switches. |
| `setHighlights` | Replaces drawn host highlights. |

`.ready` is emitted once, when the first section is on screen in a mounted view. `.relocated`
carries the section href, overall progression (by section byte size, as foliate-js computed it),
the table-of-contents title for the position and the visible range's CFI. `.disclosure` text
summarises the books' `SectionReport`s and is re-emitted when it changes. `.notice` reports
refused external links, unresolved CFIs and quotes, and highlights that could not be drawn.

## Security

Books are untrusted. Nothing is executed: there is no JavaScript engine. Every reference
resolves inside the archive through `ResourceReference`; remote URLs are never fetched and are
counted for disclosure. XML, CSS and font input is bounded, and the import limits in
`EPUBReading` still apply. External links are refused with a notice.
