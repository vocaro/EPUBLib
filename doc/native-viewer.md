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
   A qualified subset of XML-shaped HTML uses Foliate's HTML whitespace and namespace rules.
   Unqualified HTML repairs remain readable but cannot issue or resolve CFIs: the reader
   discloses that saved positions and highlights are unavailable for those sections.
   For that parser a `<` that opens no markup (`x < y`, `p <.05`) is kept as text, as HTML
   reads it; libxml2 alone discards what follows it.
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

- **Opening position.** With nothing restored, a book opens at its text start, as foliate-js
  did with `showTextStart`: the first entry typed `bodymatter` or `text` in
  `EPUBPublication.landmarks` (the navigation document's `landmarks`, or the EPUB 2 guide's
  references in a book without them), resolved as `navigate(href:)` resolves an href, fragment
  included. A book without one, or whose text start names no section of the book, opens at its
  first linear section. A Standard Ebooks title therefore opens on its first chapter, with the
  cover and titlepage a page turn back. A host's `restore` after `.ready` replaces it.
- **Engine identity and bookmarks.** `EPUBReader.identifier` is `org.epublib.reader` and its
  bookmarks are `epublib-cfi-v1` (`EPUBReader.bookmarkFormat`): names for the library, not a
  renderer, so they outlive any change of how pages are drawn. The value is an EPUB CFI in the
  form foliate-js produced, generated and resolved by a port of its code. A range contained
  in one document carries its CFI in `bookmark`. A CFI into a spine item the spine repeats
  names the occurrence its package path lands on: each repeat keeps its own position, as EPUB
  Reading Systems 3.3 §5.5 has them "distinct items for user interface (UI) purposes". This
  departs from foliate-js, which resolved every repeat to the first; its CFIs still resolve, and
  one saved in a later repeat restores there
  ([#108](https://github.com/vocaro/EPUBLib/issues/108)). A range spanning documents also carries
  `rangeBookmarks`, ordered per-document CFIs for every nonempty included section, with
  `bookmark` equal to the first entry. Nonlinear sections omitted from continuous scroll and
  empty section endpoints or sections containing only generated markers contribute no segment. Existing single-document locations continue
  to decode and restore; the bookmark identity and format are unchanged. Bookmarks tagged with
  the WebKit reader's `org.epubreaderlib.foliate`/`epubcfi-v1` are refused as another engine's;
  nothing had shipped, so a host migrates its own stored ones by re-tagging them, since the CFI
  value names the same position. A CFI that no longer resolves (a changed book has a different
  publication ID and is rejected before that) produces a `.notice`.
- **Fixed layout.** Out of scope at first: neither StudyWright catalog (50 shipped EPUBs, 87
  PDFReflowLib conversions) contains a pre-paginated book. Fixed-layout spine items render as
  reflowable text with a `.disclosure`; capabilities are not reduced. Owner decision
  (2026-10-10): no WebKit path for fixed-layout pages for now, open to review later.
  [#5](https://github.com/vocaro/EPUBLib/issues/5) is narrowed to native rendering of pages
  that are one image or one SVG, at their declared size and in spreads, and is unscheduled.
  In nine of the ten fixed-layout titles in the W3C/IDPF EPUB 3 samples, every fixed-layout
  page is one. Pages that position HTML text keep reflowing with the disclosure.
- **Vertical writing.** `writing-mode: vertical-*` renders horizontally, with a `.disclosure`.
  Ruby and right-to-left text are native. Owner decision (2026-10-11): no WebKit path for now,
  open to review later, and no CoreText page renderer.
  [#7](https://github.com/vocaro/EPUBLib/issues/7) is narrowed to `vertical-rl` in paginated
  flow, drawn by the reader's own text views in vertical orientation, and is unscheduled:
  multi-language support is not a current priority. UIKit has no vertical layout API, but a
  spike found that TextKit 2 on iOS lays text out vertically when a text container subclass
  reports vertical orientation, and that `NSTextView` stays on TextKit 2 in vertical
  orientation on macOS. `vertical-lr` and continuous scroll are outside that route.
- **MathML.** A native layout engine, the [MathMLLayout](https://github.com/vocaro/MathMLLayout)
  package (CoreText and the OpenType MATH table), draws each `<math>` as an attachment,
  baseline-aligned inline and centred for `display="block"`. The corpus uses `mi`, `mn`, `mo`,
  `mrow`, `mfrac`, `msup`, `msub`, `msqrt` and `mstyle` (1,798 formulas, all with `alttext`);
  the engine also lays out every other MathML 3 presentation element except `mglyph` and
  elementary math. The reader covers those two around it, each disclosed as a simplified
  layout: an `mglyph` shows its `alt` where it stands (a box when it has none), and `mstack`
  and `mlongdiv` are set as a table with a column for each digit, carries small above their
  digits, crossed-out digits struck through, a rule under the rows it follows, and a division's
  divisor and result around its working. Anything else the engine cannot lay out shows its
  `alttext` and is disclosed. No WebKit.
- **Wide formulas.** A formula wider than its line shrinks to fit, to no less than three
  quarters of the text's size. Past that it breaks into rows at full size: before a relation
  or a binary operator, after a separator, and where the author's `linebreak` attribute says
  (`newline` at any width; `nobreak`, `goodbreak`, `badbreak` and `linebreakstyle="after"`
  honoured). Rows end at relations in preference to the operator after one, and continuation
  rows line up on the first relation, or indent two ems when it is not near the left edge.
  Breaks outside brackets come first: rows shrink, again to no less than three quarters, before
  a break is taken inside brackets. Fractions, roots, scripts, tables and enclosures never break.
  A formula that is one such unit shrinks to the line whole, never clipped, and is disclosed
  when a 320-point column would show it below three quarters. The rows are one attachment, so a
  section's characters, positions and CFIs do not depend on the column: a display formula's rows
  are centred as a block, and an inline formula wider than a whole line takes rows of its own.
  On the 22 wide-formula fixtures in a 320-point column (macOS 27), one row scaled to the line
  left 13 below three quarters of 17-point text (the smallest at 44%) and 17 at 28 points
  (27%); rows leave 2 and 4, each a single fraction, table or bracketed power.
- **Spoken math.** Assistive technologies read a formula's `alttext` verbatim, in the content's
  language: the nearest `xml:lang` or `lang` on the `math` element or an ancestor, else the
  publication's. Without `alttext` the reading is generated from the markup, and elementary
  math is read row by row. MathMLLayout 0.1.1 generates English only, so a generated reading is
  tagged English whatever the book's language, for an English voice to read, rather than
  handed to the book's voice as if it were its language.
- **SVG.** Inline and archive SVG illustrations render through the bundled resvg static
  renderer, including paths, text, gradients, transforms, clipping, local definitions and
  `viewBox`/`preserveAspectRatio`. A plain single-image wrapper retains the raster-image fast
  path. Archive raster references are resolved and bounded before rendering; scripts,
  animation, foreign content and external resources are omitted with a disclosure. SVG
  filter effects are omitted with a disclosure while preserving the drawing's shapes and labels.
  Pattern fills and illustrations exceeding the rendering limits show their title, description or
  drawing text instead. Title and description provide the image's accessible label. No WebKit.
  The renderer ships as an Apple XCFramework; consumers do not need Rust. Its source pins,
  rebuild script and redistribution notices are in [Vendor/Resvg](../Vendor/Resvg/README.md).
- **Image contrast.** In dark appearance, transparent images containing dark strokes receive
  a white backdrop so diagram edges and labels remain legible. Their authored colors and
  publication bytes are preserved. Opaque images and transparent light artwork retain their
  pixels; an author's explicit CSS inversion retains its own appearance treatment. Display
  renditions are cached separately by appearance under the existing image memory budget.
- **Image inspection.** Double-click or double-tap an unlinked book image to inspect it in a separate
  native zoomable scroll surface, including images drawn inside table cells. On Mac, images
  also offer an Inspect Image context-menu action; UIKit supplies an attachment action and
  menu. Linked images retain link navigation and offer inspection through the menu.
  Accessibility actions expose inspection for visible images. Zoom In, Zoom Out, Fit
  and Close controls complement pinch/trackpad magnification and panning; Escape closes the
  inspector and Command-plus/minus/zero zooms or fits it. Reader page input is suspended while
  inspecting. Closing preserves the reader's text, selection and reading position.
  Inspection decodes the original archive resource independently of its inline CSS size and
  body font size, retaining resolution up to 16 megapixels and an 8,192-pixel long side.
  Larger raster images are downsampled within those bounds; SVG retains its existing
  4,096-pixel rasterization limit. The same image contrast policy and bounded cache apply.
- **Tables.** Attachments drawn natively (TextKit 2 has no `NSTextTable` on iOS), one
  image-drawn attachment per row so pages can break between any two rows; rows a rowspan
  joins, and the header, keep with the next row and share a page when they fit. `colspan`/
  `rowspan` honoured (`rowspan="0"` spans one row, as WebKit does); a spanning cell is drawn in
  each row it covers. Oversized rows continue across pages using complete cell glyph lines;
  a line crossing a rowspan boundary is finished in its preceding row and never drawn twice.
  Continuous scroll retains full row heights. Tables too wide for the line shrink their text
  to 60%, then wrap by character. A single glyph line taller than a page is fitted as a whole.
  One-column tables, which books use as callout boxes, flow as ordinary text. Visible cells have
  native text interaction surfaces aligned to their drawn glyphs: select and Copy cell text,
  invoke the host's selection action, follow internal links and open notes. External links retain
  the reader's refusal notice. Cell selections, located passages and saved highlights use exact
  DOM-based character ranges, including Unicode and inline markup. VoiceOver reads each continuation's words, completing
  a word once if character wrapping splits it between pages. Continuations retain original
  source offsets: several pages can report the same row range. Existing bookmarks naming a
  whole table still resolve to that table; new cell ranges identify the selected characters.
  Interaction surfaces are mounted only for visible cells. Cell TextKit
  layouts and glyph metadata are retained for drawing in the table's bounded layout cache.
- **Footnotes.** EPUB 3 `noteref` links show their note in a popover, whether they name the
  note or an element that opens it, such as its first paragraph. Footnote `aside`s are
  hidden from the flow; endnotes stay in place and also show in popovers.
- **Flex and grid.** TextKit lays a section out as one column of paragraphs, so the reader
  aligns the flex and grid layouts that keep that column: a column flex container, a one-column
  grid and a row flex container with a single item
  ([Flex and grid alignment](#flex-and-grid-alignment)). That covers the patterns reflowable
  books use to centre a page: Standard Ebooks' full-page epigraphs and dedications, a title
  page centred by its `body`, a `place-items: center` grid. Items meant to sit side by side,
  wrap, reverse or be reordered stay blocks in reading order, with a `.disclosure`. Alignment is
  paragraph spacing and indents resolved at the live column size and never changes a section's
  characters, so CFIs, search, selection and highlights do not depend on it. The subset follows
  a survey of published stylesheets and this repository's fixtures, not a book corpus
  ([qualification](issue-20-flex-grid-alignment.md)).
- **Continuous scroll** is whole-book: one `UITextView`/`NSTextView` over every linear
  section, so nothing resets at a section boundary and the system scroll edge effects apply.
  Until every section is built it shows the current section, then swaps to the whole book in
  place. Nonlinear sections stay out of it, as page turns step over them; navigating to one
  shows it on its own. A book with no linear section keeps every section in both: it scrolls
  and pages through from end to end, where foliate-js stopped at the end of the first section
  ([#159](https://github.com/vocaro/EPUBLib/issues/159)), and each then counts toward
  progression by its size, where foliate-js weighed them all nothing
  ([#232](https://github.com/vocaro/EPUBLib/issues/232)).
- **Content language.** A narrow reading of EPUB Reading Systems 3.3 §3.7, which says a
  reading system "MUST NOT assume either the language or the base direction" of a content
  document from the package (owner decision, 2026-10-11,
  [#109](https://github.com/vocaro/EPUBLib/issues/109)). The package's language has two uses
  and the reader keeps one:
  - Text generated from language follows only the language the content declares, `xml:lang`
    or `lang` on the element or an ancestor: the marks around a `q`, and the case mapping of
    `text-transform` and of small capitals a font lacks. With none declared the result is the
    same whatever the package's `dc:language`: an unlabelled French book gets “ ” around a
    `q`, not « », and an unlabelled Turkish one capitalizes `i` as `I`.
  - Typesetting and speech still take the package's first `dc:language` as a hint, because
    some language has to be chosen anyway: the CoreText language attribute, which steers
    glyph choice and line breaking (every run of an unlabelled document in a Japanese book is
    tagged `ja`, so its Han characters take their Japanese forms), and the language a formula
    is spoken in (see Spoken math); body text on UIKit is to follow
    ([#65](https://github.com/vocaro/EPUBLib/issues/65)). So typesetting is not independent of
    the package, which is the sense in which the reading is narrow.

  Content that declares a language overrides the package for both, and `lang=""` (the language
  is unknown) leaves text without a language or the hint. `:lang()` selectors and the search
  locale read the document alone. The base-direction half of the requirement is met in full:
  a document that declares no direction reads the same whatever the package's `dir`.
  foliate-js gave a document without `lang` the book's language, so its `q` marks followed
  the package.
- **Building** is per section and lazy for first paint: the opening section builds first and
  the session emits `.ready` once it is on screen; the rest build in the background in
  parallel. Images decode lazily, downsampled to their displayed size, under a shared cache
  budget.
- **Release.** A typography change keeps each built section on screen until its rebuild
  arrives. A rebuilt SVG shares the font database its replaced build still holds, so a
  relayout needs no more of the font budget than the book already has. The text view drops
  replaced text's layout with the text, so its images go with it, also after a resize.
  `close()` releases the session's sections and paginations and empties its text views at
  once, as does a dismantled view. Neither waits for the platform to free the views
  ([investigation](issue-54-svg-relayout.md)).
- **Highlights.** New public `EPUBReaderCommand.setHighlights([EPUBHighlight])` and capability
  `.highlights` draw host highlights from their range CFIs, including every `rangeBookmarks`
  segment of a multi-document annotation (StudyWright #85). Search and
  highlights are TextKit 2 rendering attributes; they never change the text. The current
  search result is drawn again over its match in a darker, differently hued highlight.
  TextKit 2 redraws a laid-out fragment when its layout changes, not when a rendering
  attribute does, so each change asks for the fragments on screen to be drawn again
  ([#51](https://github.com/vocaro/EPUBLib/issues/51)).
- **Pages.** Locations report `EPUBPublication.pageList` entries: `page`, the last entry at or
  before the range's first character, and `pages`, that one followed by every entry whose
  marker falls inside the range. foliate-js reported only `pageItem`, the last page begun by
  the range's end, which is the last of `pages`. Within the range's sections the markers'
  anchors decide; a marker its section lacks sits at the section's start, where
  `navigate(href:)` shows it. Before them the page list's order does, so no earlier section is
  built to find the page a section opens on. A range across sections in continuous scroll
  skips the nonlinear ones it leaves out.
- **Sections cut off inside markup.** A section whose file ends inside markup (a tag cut in
  half, a closing `</` or `<`, or a comment, CDATA section, processing instruction or declaration
  that is never closed) is withheld: it shows "This section could not be shown.", the reader
  discloses it, and the rest of the book reads as before. HTML would show the text before the
  cut. `XMLSafety` screens a document for declarations before either parser sees it and treats
  markup left open at the end of input as unsafe, because that is where a scan and a parser
  most easily disagree about what the bytes are. The cost is one section of a file some tool
  wrote short; a download cut short is no readable archive at all
  ([#202](https://github.com/vocaro/EPUBLib/issues/202)). Text extraction's recovery reads the
  matching case the same way: a `<` that is the last byte of a file is not text.
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
- **Book pose.** With a vertical division the spread has two columns: the gutter is the
  division band plus half a gap each side, and both columns have the narrower side's width,
  aligned towards the fold. When that would be under 200 wide, and in continuous scroll, a
  single column uses the wider side.
- **Continuous scroll.** One column at most 720 wide, centred, with the same outer margin. On
  iOS the text view has `contentInsetAdjustmentBehavior = .automatic`, `contentInset` top 48
  and bottom 64 on top of the live safe area, `textContainerInset` only horizontal, and
  `.soft` top and bottom edge effects; nothing is drawn. On macOS the scroll view uses AppKit's
  automatic content insets and the window toolbar's own edge effect. On both, the text container
  is the column's width, set only when that changes, so a resize lays the text out once at most.
  On Mac, the column uses the actual scroll viewport's horizontal extent, including width
  reserved by a legacy scrollbar; a scrollbar preference change also recalculates wrapping.
  A shown position's line rests at the top of the visible area. Far from what is laid out,
  TextKit 2 only estimates where text is, and the viewport's layout estimates differently, so a
  long jump checks which line the top shows: from text before the position, it lays out through
  the position in one run and scrolls to its now exact line; from text past it, it climbs above
  it first ([#13](https://github.com/vocaro/EPUBLib/issues/13)). A resize keeps the line holding
  the position (the last one shown, or the visible start once the person has scrolled) at the
  top, through any number of resizes in quick succession. A bounded correction loop verifies
  that the requested line actually reaches the visible top, allowing a visible line at the
  document's end when scrolling is clamped. If estimates cannot align it, or TextKit 2 lays
  that line over other text, the text is loaded afresh and the position shown again
  ([#12](https://github.com/vocaro/EPUBLib/issues/12), [#41](https://github.com/vocaro/EPUBLib/issues/41)).
- **Pages.** A section is laid out once per column size; pages are slices of that layout at
  line boundaries, never splitting a line, honouring `.readerPageBreakBefore` (CSS
  `break-before: page`) and keeping a `.readerKeepWithNext` paragraph with the next (never
  past the page's first line, and only when both fit on the next page). An attachment taller than a page gets a page of its own. A
  spread shows consecutive slices. Each column is a non-scrolling TextKit 2 text view holding
  only its page's text. Native selections are coordinated across the spread's columns using
  one complete source range; Copy and host actions consume that whole range. On Mac, indexed
  accessibility text, line, style, frame and selection queries are bounded to the visible page.
  Installing a spread posts a value change for each column and a layout change naming the
  visible columns, without which VoiceOver can keep reading a column's previous page. The
  insertion point after a page's last character, and an offset an assistive client kept from
  a longer page, are on its last line.
  UIKit exposes visible line/run accessibility children with links, attachment labels and
  page actions, keeping hidden paragraph context out of its native text accessibility traversal.
  The canvas lists its columns to VoiceOver in source order; by their frames alone a column
  lowered by top spacing, or the first column of a right-to-left spread, would be read second.
  A paragraph that continues onto the next page is laid out a few lines further (or to
  a line break) and clipped, so its lines break exactly as in the measuring layout; justified
  text takes more, because CoreText justifies a paragraph of up to 8,192 characters as a whole
  and a longer one line by line. A long justified paragraph's short continuation tail receives
  a bounded second measurement of exactly the displayed source slice and its lookahead.
  These exceptional pages use that measurement's complete line boundaries and height, and
  the next page starts at the corrected source boundary. No synthetic tail padding or column
  growth is needed; authored justification, hyphenation, indentation and RTL are retained.
  Paginations are cached per section and column size; a resize,
  rotation or bar change repaginates once it ends, in steps when far into a section, with the
  old spread on screen until the new one is ready. A finished pagination keeps only its pages.
- **Right to left.** `page-progression-direction="rtl"` mirrors spreads, swipes and tap zones.

### Floats and positioned boxes

The native CSS subset wraps prose beside left/right floated figures, text and archive images,
then restores the full column below the box. Auto-width text floats use their content width,
including narrow drop caps. Horizontal margins and padding reserve space around the native
glyph column. `clear: left`, `right` and `both` move subsequent prose below the
requested float side. Sized `inline-block` text fits after its prefix when space permits,
and following prose wraps beside the box without overwriting the prefix.

Absolute callouts honor `top`, `right`, `bottom`, `left` and `inset` within their nearest
positioned ancestor, including a top inset that places them before their source location.
Relative containers honor column sizing and horizontal offsets, with positive vertical
offsets moving their content downward. Fixed callouts use the section's viewport coordinates
and appear once; they do not remain pinned while scrolling or repeat on each page. The reader
reserves space around rectangular boxes to keep prose readable rather than reproducing
arbitrary overlapping layers.

Widths, minimum/maximum widths and insets resolve points, percentages and viewport units at
the current column size in pagination and continuous scroll; auto margins center a non-floated
box. Native paragraph styles retain text alignment, direction and typography. Native text
retains selection, links, anchors, search and the same exact text-to-DOM mapping as ordinary prose. Resizing and
reader typography changes recompute geometry from source formatting and retain selection.
Requested heights do not truncate content. A box and the prose wrapping beside it stay together
when they fit a page. Oversized groups and nested complex boxes instead continue as native
blocks in reading order; fallback widths expand when necessary to leave readable lines, and
long box text can continue across pages. Up to eight nested width constraints resolve within
the enclosing box in this fallback.

A `.disclosure` explains that box layouts may be simplified. Sticky positioning, negative
relative vertical offsets, arbitrary overlap and `z-index`, and page-pinned or repeating fixed
boxes are outside the supported subset. Conventional positioned, visually hidden accessibility
labels remain omitted to avoid visible duplicate text. The offscreen heuristic recognizes only
absolute-unit top/left offsets of -1,000 CSS pixels or less, including calculations containing
only absolute units; it is evaluated from
author values independently of reader typography. Font-relative, percentage, viewport and
mixed-unit offsets remain visible unless explicitly clipped or hidden. This keeps rendered
text and saved range offsets identical across reader font-size changes. General clipping,
arbitrary offscreen geometry and transforms are outside this subset.
Fixed-layout publications still reflow and report their existing fixed-layout disclosure; this
subset does not implement fixed-page geometry.

### Flex and grid alignment

A flex or grid container renders as a block and its items as blocks in source order. Three
shapes keep the reader's single column, and the native layout aligns their items: a flex
container with `flex-direction: column`, a grid with one column, and a row flex container with
one item. A container's free space becomes paragraph spacing around and between its items; an
item narrower than its container is indented from both sides. Nothing else about the text
changes.

- **Heights.** A container has free space when its `height` or `min-height` is definite: points,
  `vh`/`vw`, a percentage of an ancestor chain of definite heights that starts at the viewport
  (`html, body { height: 100% }`), or a sum of those (`calc(98vh - 3em)`, exactly).
  `max-height` caps a definite `height`, `box-sizing: border-box` takes the vertical padding
  and border out of it, and content taller than the box is never clipped: it flows as blocks.
  The height used is at most one viewport, so a box that opens a page stays on that page.
- **Down the page.** In a column flex container the free space goes first to items with
  `flex-grow` (a grown item keeps its content at its top), then to `auto` top and bottom margins,
  then by `justify-content`: `flex-start`, `center`, `flex-end`, `space-between`, `space-around`
  and `space-evenly`. A one-column grid packs its rows by `align-content` the same way; with
  the default `normal`/`stretch` the rows share the space equally and `align-items`/`align-self`
  place each item in its row. A row container's only item is placed by `align-items`/`align-self`.
  `row-gap` and `gap` separate stacked items, with or without a definite height.
- **Across the line.** `align-items`/`align-self` (flex), `justify-items`/`justify-self` (grid),
  `justify-content` (a row's only item) and `auto` left and right margins centre an item or put
  it at the end edge. The item shrinks to its widest unwrapped paragraph, within its `width`,
  `min-width` and `max-width`, and its paragraphs keep their own `text-align` inside it: a
  centred quotation keeps its left edge and its right-aligned attribution. Start alignment and
  the default `stretch` leave the item across the line, as block flow has it.
- **Nesting.** A stretched or grown item that is itself a supported container aligns within its
  new height, up to four containers deep.
- **Paginated flow.** The viewport is one column's page, in one- and two-column spreads alike:
  `100vh` is the page's text height and `100vw` one column's width. A section never shares a
  spread with another, so a one-page epigraph leaves the second column empty. The space above
  a box's first line is the box's own: unlike a margin it is kept in full when the box starts
  a page, at a section's start, a forced break or an unforced one. A box that starts part-way
  down a page begins there, as in a browser, with its content centred in the box rather than
  on the page.
- **Continuous scroll.** The viewport is the visible reading area, as for images sized in
  `vh`: a `min-height: 98vh` section takes about one screen and its content sits in the middle
  of it. Heights follow the visible area when it changes. A position that starts an aligned
  box (a navigation to its section, a restored location) rests the box's top edge at the top
  of the visible area, not its first line, so the box is shown as composed. A box that opens
  the scrolled text has its space restored as its first fragment's top margin, since TextKit
  drops the spacing before a document's first paragraph.

Everything else stays in block flow in reading order and sets a `.disclosure`: a row with
several items (side by side in a browser), `flex-wrap` rows, reversed directions with several
items, grids with more than one column (`grid-template-columns`, `grid-template-areas`,
`grid-auto-flow: column`) or explicitly placed items, inline flex and grid containers with
several children, and containers nested more than four deep. `order` never reorders: items
keep reading order and the container is disclosed. A wrapping column of definite height stays
one column and is disclosed. A container holding a float or positioned box is not aligned:
the box keeps the layout described above, and the alignment given up is disclosed.

## Input and accessibility

`View.epubReaderPageControls(_:)` configures direct page input live; see
[integration](integration.md#configuring-page-controls) for the API, validation and examples.
The following are the defaults. Host commands and accessibility actions stay enabled.

- Paginated: a tap or click within 56 pt of either edge (except on a link, an image, a press-and-hold or
  while text is selected), a horizontal swipe (not while text is selected), and on macOS a
  trackpad gesture or wheel tick turns a page. Continuous scroll scrolls natively.
- Keys (all flows): Left/Page Up previous, Right/Page Down/Space next, Shift-Space previous.
  In continuous scroll a page turn scrolls by one viewport less a line.
- VoiceOver: page-turn actions via `accessibilityScrollAction` and the named "Next Page" and
  "Previous Page" actions; text reads in order from the text views.
- Selection: native selection UI with the host's `EPUBSelectionAction` in the edit or context
  menu, no length cap. Dragging can extend a selection across a two-column spread in either
  reading direction. A located passage is selected in every visible column and remains
  selected on its continuation pages. When part is offscreen, the reader shows a continuation
  indicator with Previous/Next controls for following the selected passage. Direct page input
  is suppressed while a selection is active; host commands and these continuation controls
  remain available. `.selectionChanged` settles 150 ms after the selection stops changing.

## Commands and events

| Command | Behaviour |
| --- | --- |
| `nextPage` / `previousPage` | Page turn (paginated) or one viewport (scrolled); stops at the book's ends; skips nonlinear sections as foliate-js did, unless no section is linear. |
| `navigate(href:)` | An encoded spine or resource href with optional fragment; unknown or non-local hrefs throw `invalidCommand`. |
| `restore(location)` | Same publication, engine ID and `epublib-cfi-v1` format or `incompatibleLocation`; validates/resolves every bookmark segment and shows the first segment's start. Does not select text or add a highlight. |
| `locate(text, highlight)` | First match in reading order with foliate's matcher. `highlight` selects it natively (emitting `.selectionChanged` with the passage). A miss emits `.notice("the cited passage could not be found in this book")`. Clears search highlights. |
| `searchHighlight` / `clearSearch` | Draws every match across the book and lists the rendered ones as `EPUBSearchResults` with no current match / removes and withdraws them. |
| `search` | Draws and lists matches, opens the first rendered match in spine order and makes it the current match; no matches preserve the position. |
| `nextSearchResult` / `previousSearchResult` | Shows the result after or before the current match, wrapping at the ends; the first or last when none is current. No effect without results. |
| `showSearchResult(result)` | Shows a listed result and makes it current; a result of a replaced or cleared search throws `invalidCommand`. |
| `style` | Font size 12–96, System/Light/Dark appearance, flow. System is the default and tracks the host color scheme live; explicit modes stay fixed. Size or resolved appearance rebuilds the text; the position is kept across rebuilds and flow switches. |
| `setHighlights` | Replaces drawn host highlights. |

`.searchResultsChanged` reports the result list before `.searchChanged(.completed)`, then each
change of the current match, and nil when a clear, another query, a failure, a cancellation or
`.locate` withdraws the list. Results are in spine order, then document order
(see [search results](reader-controls.md#search-results)).

`.ready` is emitted once, when the opening section is on screen in a mounted view, and the first
`.relocated` reports the opening position (the text start, see Decisions). `.relocated`
carries the section href, overall progression (by section byte size, as foliate-js computed it),
the table-of-contents title for the position, the page-list entries it shows (see Decisions)
and the visible range's CFIs. A nonlinear section counts nothing toward progression unless no
section is linear (see Decisions). A selection's `.selectionChanged` event and host selection action
carry the same complete passage: `text` omits nonlinear sections, and `location.rangeBookmarks`
preserves all included documents. Its `page` names the entry in effect at its start and `pages`
includes the entries it spans, omitting nonlinear pages. Save the entire `EPUBLocation` and pass
it to `.setHighlights` to restore all segments in either flow, including after typography changes.
No partial annotation is drawn while a section is building or if any segment fails to resolve.
An empty collection, a contradictory first bookmark, a foreign identity/format or malformed CFI
is incompatible; unordered/duplicate document targets, nonlinear multi-document targets or
unresolved CFIs emit one `.notice` per rejected highlight. `restore` similarly refuses an
incompatible location or emits a notice for an unresolved collection without navigating.
Sections requiring unqualified HTML tree repair do not emit bookmarks. Existing CFIs into
those sections are refused with a notice instead of restoring or highlighting a potentially
different passage. Href navigation, readable content, selection text and text search remain
available. A selection spanning an unsupported section emits its text and quote without a
partial bookmark collection. This restriction is independent of the opt-in headless
text-extraction recovery.
Strict namespaced XHTML retains its XML DOM and existing CFIs. For documents Foliate would
retry as HTML, compatibility requires UTF-8 XML-shaped markup with explicit head/body,
ordinary flow/inline elements and lists, and valid HTML nesting. Pre-head whitespace is
dropped, between-head/body whitespace retained, and trailing root whitespace merged into the
body. Self-closing nonvoids, closing void tags, table tree construction, CDATA, raw-text or
foreign elements, literal attribute tabs/line endings, and HTML numeric-reference remapping
are outside this subset. These cases require source correction or a host's explicit quote
search for migration; changing an engine/format tag alone cannot repair their positions.
`.disclosure` text summarises the books' `SectionReport`s and is re-emitted when it changes. `.notice` reports
refused external links, unresolved CFIs and quotes, and highlights that could not be drawn.

## Security

Books are untrusted. Nothing is executed: there is no JavaScript engine. Every reference
resolves inside the archive through `ResourceReference`; remote URLs are never fetched and are
counted for disclosure. XML, CSS and font input is bounded, and the import limits in
`EPUBReading` still apply. External links are refused with a notice.

## Qualification

The spike the issue asked for ran on the books StudyWright reads, with the opt-in
`NativeCorpusQualificationTests` (`EPUBLIB_CORPUS`): the 50 shipped catalog EPUBs (Standard
Ebooks, Project Gutenberg and government titles), the 87 PDFReflowLib conversions of the
review set, and, as a sample of imported EPUBs, 165 conversions of the same PDFs by two other
converters (72 of which EPUBReading opens; the rest reference resources missing from their
archives and are refused by the parser, as before).

- **Fidelity.** 213 books, 9,566 sections, 90 million rendered characters and 55,748
  attachments built with no crash, no withheld section and no text-map round-trip failure.
  All 1,798 formulas lay out natively (no `alttext` fallback); 19 sections of third-party
  conversions needed the forgiving HTML parser; 84 remote resource references in catalog
  books were refused. Computed styles were compared with WebKit's on 68,817 elements across
  the catalogs; after the reader's deliberate defaults, the remaining differences were centred
  figure captions and `ex` units. Subsequent focused sizing coverage resolves `ex` against
  CoreText's x-height for the actual system or embedded face. Centered captions at 0.9em
  are deliberate reader defaults; explicit author alignment wins. Percentage paragraph
  edges, gaps and indents are checked at 300, 600 and 900 points and 16/25-point text,
  including source-preserving scrolled relayout and paginated continuation formatting.
  See the [sizing qualification](issue-21-css-sizing.md). The original catalog-wide WebKit
  comparison has not been repeated for these changes.
- **CFI compatibility.** CFIs and search are checked against vectors recorded from foliate-js
  itself in WebKit: about 2,800 range-to-CFI conversions, 3,300 resolutions, spine bases,
  parse/print round trips and quote matches.
- **Time** (release build, Apple M5 Max, macOS 27; expect an iPhone to be several times
  slower). Opening a book: median 6 ms. Time to first paint is the first section's build:
  median 1.4 ms, 95th percentile 26 ms, worst 55 ms. Building every section in the background:
  median 8 ms, worst 183 ms. A 1 MB section shows its first page in about 8 ms and turns pages
  in about 1 ms; a 3.5 MB, 300-section book opens in continuous scroll in about 50 ms.
- **Memory.** A book's footprint is dominated by `EPUBReading`'s in-memory snapshot (its
  compressed and expanded bytes, unchanged by this work). Images are never decoded during a
  build; they decode downsampled when drawn, into a shared 96 MB cache that evicts least
  recently used and trims on memory pressure.

Go: the native viewer is the bundled engine.

## Limitations

- Fixed-layout books reflow ([#5](https://github.com/vocaro/EPUBLib/issues/5)); vertical writing
  renders horizontally ([#7](https://github.com/vocaro/EPUBLib/issues/7)); both are disclosed.
- Floats, positioned callouts and sized `inline-block` content use the rectangular native
  subset described above. Oversized groups and nested complex boxes fall back to native blocks
  in reading order without clipping text. Sticky positioning, negative relative vertical
  offsets, arbitrary overlap/`z-index` and page-pinned or repeating fixed boxes are unsupported.
  A layout disclosure accompanies books using these box styles. Common positioned accessibility
  labels hidden with zero-area `clip: rect(...)`, `clip-path: inset(50%)`, visibility or large negative
  top/left offsets in absolute units stay omitted; font-relative or mixed-unit offsets remain
  visible unless explicitly hidden or clipped. General clipping and arbitrary offscreen
  geometry are unsupported. Unsized inline-blocks remain inline. Ordinary percentage margins,
  padding and text indents resolve against the live containing content width, including
  constrained flow-box ancestors, and recalculate at resize. Mixed-unit CSS calculations
  and `min`/`max`/`clamp` branch selection still use the nominal media-query viewport;
  viewport-relative font sizes and media queries remain based on that nominal viewport.
- Whole-table bookmarks and visible row ranges retain attachment granularity. A resize or
  flow change without a precise cell endpoint returns a continued row to its source position
  rather than preserving its particular visual fragment.
- MathML is laid out by MathMLLayout 0.1.1, which has no line breaking, `mglyph`, elementary
  math or localized speech; the reader works around each as far as the engine's API allows
  ([#25](https://github.com/vocaro/EPUBLib/issues/25)):
  - A formula breaks only along its own rows (`math`, `mrow`, `mstyle`, `semantics`). A
    fraction, root, script, table, `mfenced` or enclosure wider than the line shrinks instead,
    below three quarters of the text's size when it must, with a disclosure. An inline formula
    breaks as a block of rows on a line of its own, not across the paragraph's lines. The
    reader's own lists decide what is a relation, a binary operator or a bracket; `indentalign`,
    `indentshift`, `lineleading` and `linebreakmultchar` are not read, table cells and long
    `mtext` do not wrap, and brackets split across rows stretch to their own row.
  - `mglyph` images are not drawn: the `alt` stands in, in the token's own style.
  - Elementary math is an approximation in the engine's tables: an `msline` spans the whole
    stack whatever its `length`, `position` and overhangs; carries are a row above their digits
    whatever their `location`; `charalign`, `charspacing` and `mslinethickness` are not read;
    `longdivstyle` is `lefttop`, `left/\right`, `left)(right` or `:right=right`, and the other
    six styles are drawn as `lefttop`.
  - Generated readings are English, tagged as English. Body text and `alttext` rely on the
    platform to choose a voice for their language: AppKit reports each run's language, while the
    UIKit page elements name one only for formulas.
  - One engine defect shows in these fixtures: an operator whose row has only `mtext` operands
    (`future value = principal`) is drawn without its spaces.

  Closing them needs these MathMLLayout changes:
  1. Line breaking: a layout bounded by a line width (`MathLayout(_:style:maximumWidth:)` with
     its rows' boxes and baselines exposed), following MathML 3 section 3.1.7 with the engine's
     own operator dictionary, breaking inside nested rows with matched bracket sizes and the
     `indent*`, `lineleading` and `linebreakmultchar` attributes; and, for inline formulas,
     the same rows as separately drawable fragments a host can place on consecutive text lines.
     Wrapping for `mtext` and table cells. The font's axis height on `MathLayout`.
  2. `mglyph`: attributes kept on a token's element children in `MathMLNode`, a box from
     `width`, `height` and `valign`, and an image provider on `MathStyle` (`src` to `CGImage`),
     with `alt` drawn and read when it returns none.
  3. Elementary math: `mstack`, `mlongdiv`, `msgroup`, `msrow`, `mscarries`, `mscarry` and
     `msline` as in MathML 3 section 3.6, including line lengths and overhangs, carry
     locations, character alignment and spacing, every `longdivstyle`, and spoken readings.
  4. Speech: `accessibilityDescription(locale:)` returning the reading and the language it is
     written in, English when the locale has no vocabulary.
  5. Operator spacing for a row that is an embellished operator only because its other
     children are space-like.

  The real-book corpus, whose formulas use neither `mglyph` nor elementary math, was not
  rebuilt for this change, so how many of them now break into rows is not measured. Neither
  real VoiceOver speech nor iPhone, iPad and Mac screens were observed: the evidence is the
  fixtures' layout, drawn pixels and accessibility attributes on macOS and the iOS simulators.
- SVG is static: filter effects are omitted with a disclosure, preserving the remaining diagram;
  pattern fills, animation and foreign content are unsupported. The unchanged networking
  publisher corpus renders all 33 SVG resources, including six containing shadow filters
  ([verification](issue-53-svg-diagrams.md)). Rendering limits
  include 4 MiB of SVG, 10,000 nodes, depth 64 and 8 MiB of expanded local references.
  Embedded raster images are capped at 4 megapixels each and 16 megapixels in total.
  Output is capped at 4,096 pixels on its long side and 16 megapixels, reduced further for
  isolated layers to fit the raster working-memory budget. SVG text uses outline fonts;
  embedded color-glyph tables are omitted and disclosed. Retained renderer font databases
  share a 64 MiB budget across the process. Each distinct set of fonts an SVG names is one
  database, with its own copy of the fallback faces, shared by every drawing that names
  those fonts. An SVG refused a database shows its fallback text. The networking book
  needs five databases, 58 MB on macOS 27 ([investigation](issue-54-svg-relayout.md)).
- Search uses locale-tailored primary collation for passage location and highlights.
  Locales without qualified prefilter coverage compare candidate windows directly, which
  can cost more on large sections. See the [collation qualification](issue-26-search-collation.md).
- A search completes once every section holding a match has been built, because results are
  the occurrences as rendered. On a book still building, completion waits for those sections.
  One search lists at most 10,000 results and reads at most 10,000 matches per section; past
  either bound the results say `isTruncated`. Result order, wrapping and the current match
  are described under [search results](reader-controls.md#search-results).
- Foliate CFI compatibility for HTML fallback is deliberately limited to qualified XML-shaped
  markup. HTML tree repairs outside that subset cannot issue or resolve saved CFIs; migration
  by href or an explicitly requested text search remains a host decision.
- Paginated accessibility bounds and actions have native API regression coverage. Live
  verification uses the [VoiceOver testing process](voiceover-testing.md) and isolated reader.
  Mac VoiceOver sessions on 2026-10-11 verified first and last lines, word order, end of
  text at the page boundary, line counts, the heading, link and image labels, and numbered-word
  continuity across page turns in one and two columns at 17 and 23 points, through text-size
  and window-size changes, with a value-change notification for each
  ([record](issue-55-voiceover-mac.md)). VoiceOver keeps its own text cursor for a column it
  rests on without interacting: after a page change it re-enters at its previous character
  offset, or on the last line of a shorter page, until Control-Option-Home. Sessions on a
  physical iPad and iPhone the same day verified reading order, the page boundary, link and
  image labels, the link's activation, and continuity across page turns made with the page
  buttons and with VoiceOver's Next Page and Previous Page actions, in portrait and landscape
  at 17 and 23 points, through rotation and a text-size change
  ([record](issue-28-voiceover-devices.md)). VoiceOver's three-finger scroll has API coverage
  only: XCTest cannot perform it. Simulator and API checks do not substitute for device
  sessions.
- Flex and grid alignment covers the single-column subset described above. Side-by-side row
  items, wrapping and reversed flex, multi-column and explicitly placed grids, `order` and
  inline flex or grid containers render as blocks in reading order with a disclosure. Within
  the subset: margins between items still collapse as block margins do; `flex-shrink`,
  `flex-basis`, `align-content` in flex, `column-gap`, percentage gaps, baseline alignment and
  `aspect-ratio` are not laid out; `box-sizing` applies to heights only; start-aligned items
  and items holding images, tables or formulas keep their block-flow width and placement; a
  box taller than one viewport is treated as one viewport tall; and a container holding a float
  or positioned box is left in block flow. `min()`, `max()` and `clamp()` heights choose their
  branch against the nominal viewport, as other lengths do
  ([qualification](issue-20-flex-grid-alignment.md)).
