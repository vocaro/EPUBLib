# Flex and grid alignment qualification

The native viewer aligns the flex and grid layouts that keep its single column of TextKit
paragraphs, and leaves every other layout in block flow in reading order with a disclosure
([#20](https://github.com/vocaro/EPUBLib/issues/20)). The reader-facing rules are in the
[native viewer](native-viewer.md#flex-and-grid-alignment) document; this is how the subset was
chosen and what was checked.

## Survey

No book corpus was downloaded or read when the subset was drawn. It rested on two sources: the
flex and grid usage in this repository's fixtures and tests, and the published conventions of
well-known stylesheets as recalled, not re-fetched. Ten shipped Standard Ebooks titles were
read afterwards ([Shipped books](#shipped-books)); the Standard Ebooks entry below is corrected
from them.

- **This repository.** Before this change no rendering fixture used flexbox or grid. The only
  uses were a style-resolution test for the blockification of flex and grid items and parser
  tests for `display: flex` and `@supports (display: flex)`. The limitation recorded in the
  native viewer document named one concrete case: Standard Ebooks epigraphs.
- **Standard Ebooks.** Its Manual of Style gives full-page epigraphs and dedications one
  shape: inside `@supports(display: flex)`, a `section` with `display: flex`,
  `flex-direction: column`, `justify-content: center`, `align-items: center`,
  `box-sizing: border-box`, `min-height: calc(98vh - 3em)` and `padding-top: 3em`, whose
  children have `margin: 0`, and `* + * { margin-top: 3em }` where a page has several. Outside
  `@supports` the children carry the older fallback (`display: inline-block; margin: auto;
  max-width: 80%; text-align: initial`), which still applies its `max-width` and `text-align`
  to the flex items. Its half-title pages were recalled as sharing the shape. They do not: a
  shipped half-title page is a centred heading in block flow, and a title page is an image.
- **Other reflowable books.** The recurring idioms are the same shape or a small variation on
  it: a title or part page centred by its `body` or a wrapper (`html, body { height: 100% }`
  with a column container, `min-height: 100vh`), `margin: auto` on a lone item, a one-cell
  grid with `place-items: center`, a column with `gap`, a footer pushed down with `flex: 1`
  on the content above it, and the 2009 `-webkit-box` spelling in books made for early Apple
  reading systems. Row layouts (side-by-side figures, key and value pairs, navigation bars)
  exist but are what browsers do with flexbox in general, not a page-composition pattern
  particular to reflowable books.

The line is drawn where the reader's layout model ends. A section is one column of paragraphs;
vertical space and indents are things a paragraph has, so anything that only moves or spaces
blocks within that column can be honoured without changing the text. Items side by side need
separately measured boxes at one height, which the native model has only as float and
positioned-box geometry: rectangular exclusions that page as indivisible groups and fall back
when they outgrow a page. Mapping flex item sizing (`flex-basis`, growth, shrinkage, wrapping,
baselines) or grid track sizing onto that is a layout engine, not the bounded subset the issue
asks for.

## Supported

| Pattern | Layout |
| --- | --- |
| Column flex container with a definite `height` or `min-height` | Free space by `flex-grow`, then `auto` margins, then `justify-content` (`flex-start`, `center`, `flex-end`, `space-between`, `space-around`, `space-evenly`) |
| Column flex `align-items`/`align-self`, `auto` side margins | Item shrinks to its content (within `width`, `min-width`, `max-width`) and is centred or put at the end edge |
| Row flex container with one item | `justify-content` across the line, `align-items`/`align-self` within the height; `row-reverse` starts at the far edge |
| One-column grid | `align-content` packs rows; `normal`/`stretch` rows share the height and `align-items`/`align-self` place each item; `justify-items`/`justify-self` across the line; `place-items`, `place-content`, `place-self` |
| `gap`, `row-gap`, `grid-gap` | Space between stacked items |
| Nested containers | A stretched or grown item that is a container aligns within its new height, four deep |
| Heights | Points, `vh`, `vw`, percentages of a definite ancestor chain from the viewport, exact sums such as `calc(98vh - 3em)`, `max-height`, `box-sizing: border-box`; at most one viewport |
| Legacy names | `-webkit-`, `-moz-`, `-ms-` prefixes, `-webkit-box-orient`/`-pack`/`-align`/`-flex`, `-ms-flex-pack`/`-align` |

## Block flow, disclosed

Rows with several items, `flex-wrap` rows, `row-reverse` and `column-reverse` with several
items, grids with more than one column or with placed items, `grid-auto-flow: column`, inline
flex and grid containers with several children, containers nested past four, and `order`
(items keep reading order; the container is still aligned if it is otherwise supported). A
wrapping column of definite height is laid out as one column and disclosed, and so is a
container that would be aligned but holds a float or positioned box. The disclosure is one
sentence in the reader's `.disclosure` text, from `SectionReport.flexGridSimplified`.

## Flows

Paginated flow resolves viewport units against one column's page, with one column and with
two. A box's space above its first line is kept wherever its page starts, and a box that opens
a page is kept on that page. Continuous scroll resolves them against the visible reading area,
the viewport images already use for `vh`, and re-resolves when that area changes. Navigating
to the start of an aligned box rests the box's top edge at the top of the visible area, so the
box is seen as composed; every other position rests its own line there, as before.

## Coverage

`Fixture.alignment()` is a five-section book: a title page centred by its `body` through a
percentage height chain, a Standard Ebooks style epigraph, a one-cell grid dedication,
unsupported row and two-column grid layouts, and a chapter of prose. `Fixture.Alignment` has
the same markup and styles as loose parts, and the pages as Standard Ebooks' compatible build
ships them (`shippedCSS`: class selectors, margin longhands, verse lines as block spans with
hanging indents, a title page whose heading is positioned off to the left), with original
content.

- `BoxAlignmentStyleTests`: longhands, shorthands, grid track counting, legacy names and the
  cascade, including the exact value of a mixed-unit height.
- `BoxAlignmentLayoutTests`: expected geometry for each supported pattern, within 2 points of
  the value CSS gives. That tolerance covers the point of slack shrink-to-fit adds so a
  measured line cannot wrap, and sub-point differences between TextKit and string drawing.
  Also heights at three viewport sizes, pages that start at a section's start, a forced break
  and an unforced one, rules and tables inside a box, floats elsewhere in the section, and
  relayout from source formatting without stale space.
- `BoxAlignmentFixtureTests`: the fixtures at a phone column, a tablet column and one column of
  a desktop spread, at 16- and 25-point text; every unsupported pattern against plain block
  flow, with its disclosure; and text identity. The same markup built with and without its
  alignment rules has the same characters, text map and anchors, and every rendered offset
  produces the same CFI and resolves back to itself. Resolving the layout changes paragraph
  formatting only, and the pages cover the text once in order.
- `BoxAlignmentCanvasTests`: a mounted canvas in paginated flow with one and two columns and
  in continuous scroll, with navigation, page turns, selection, highlights and resizing.
  Tolerance 2.5 points: a visible line is placed to within a point.
  The shipped pages in one continuous scroll view, whose title page and a floated initial give
  the whole book box geometry: the verse, its attribution and the dedication sit where they do
  on pages of their own, at two sizes.
- `BoxAlignmentSessionTests`: the fixture book through the public commands in both flows:
  disclosure, href navigation, located and selected passage, saved highlight, restore, and the
  same CFIs in either flow.
- `BoxGeometryIndentTests`: paragraphs with margins, a first-line or hanging indent, centred,
  right-aligned, justified and right-to-left text and a list item, in a section with a float
  and in the same section without one. In continuous scroll and in pages each line has the
  same left and right edge either way; a view that showed text with boxes shows plain text with
  its indents again.

## Verification

On macOS 27 with Apple Swift 6.4 (Xcode 27.1) the Mac suite completed 605 tests, including
eleven optional skips, with no failures on 2026-10-10: 500 viewer tests, 37 of them the
alignment tests above, 100 reading tests and 5 writing tests. The module-boundary and
documentation-snippet checks passed.

The iPad Air 13-inch (M4) simulator suite on iOS 27.0 completed 592 tests, including seven
optional skips, with no failures. The iPhone 17 Pro simulator suite completed the same 592
with one failure, `ReaderPaginatorTests.testLongSectionPaginatesQuickly`: a wall-clock bound
(the first page of a 1 MB section in under 0.25 seconds) that took 1.13 seconds while the
shared machine's load average was about 200. Run alone on a fresh iPhone 17 Pro simulator it
passed with a first page in 0.016 seconds; the Mac runs measured 0.006. All 37 alignment tests
passed on both simulators. Each simulator was created for its run and deleted afterwards.

These are deterministic native geometry and source-mapping regressions. No physical iPhone,
iPad or Mac display was inspected for that work, no VoiceOver session was run, and no
publisher corpus was rendered: the Standard Ebooks rules were reproduced from its published
conventions. Shipped titles were read and rendered afterwards, below.

## Shipped books

For [#63](https://github.com/vocaro/EPUBLib/issues/63) ten Standard Ebooks titles were
downloaded from standardebooks.org on 2026-10-11 (the compatible EPUB build), read and
rendered: *The Great Gatsby*, *Frankenstein*, *My Ántonia*, *The Sun Also Rises*, *Tristram
Shandy*, *Treasure Island*, *The Brothers Karamazov* (Garnett), *Dracula*, *Ulysses* and *The
Wind in the Willows*. The issue has their URLs, sizes and digests. The books and the captures
are not in the repository.

### What they ship

- **Epigraphs.** Six of seven are the flex shape of the survey. The build writes it with class
  selectors (`section.epub-type-contains-word-epigraph`) for `[epub|type~="epigraph"]`, margin
  longhands and `text-align: left` for `initial`, and has `> * + * { margin-top: 3em }` only
  on a page with several items (one epigraph, one dedication). A verse epigraph sets each line
  as a block `span` with `padding-left: 1em; text-indent: -1em`. *Treasure Island*'s is a poem
  in block flow.
- **Dedications.** Four of seven are the same flex container around a centred paragraph in
  small capitals, broken by `br`. *Frankenstein*'s and *Treasure Island*'s are a top margin and
  centred text in block flow; *Tristram Shandy*'s is a letter.
- **Half-title pages.** All eight are a heading with `margin: 3em 0; text-align: center` in
  block flow.
- **Title pages.** An image with `display: block; width: 100%; margin-top: 3em`. Eight also
  have a heading and a byline for assistive technology at `position: absolute; left: -999em`.
- **Elsewhere.** Row flex containers with several items in *Tristram Shandy* (rows of
  asterisks and dashes, braces between stacked phrases), *Ulysses* and *The Wind in the
  Willows*. No grid and no float in any of the ten; sized inline blocks in *Tristram Shandy*.
  The body-centred title page and the `place-items` grid of the first fixtures are trade-book
  idioms that none of the ten uses.
- **Not exercised by the first fixtures:** `text-wrap: pretty`, `hanging-punctuation: first
  last`, small capitals in a shrink-to-fit item, block spans with hanging indents inside an
  item, `margin-top: 20vh` on a section and `max-height: 100vh` on images.

### How they were rendered

A throwaway host app, kept outside the repository, mounted `EPUBReaderView` full screen, set
the style, sent `.navigate(href:)` and recorded every visible TextKit line (its box, its
glyphs' extent, its baseline) before a simulator screenshot was taken. The same app then
loaded the same content document from the unzipped book in a `WKWebView` laid exactly over
the reader's column (one column's page in paging, the visible reading area in continuous
scroll), with book scripts off, network loads blocked and the reader's defaults ahead of the
book's stylesheets (`html { font-family: ui-serif; font-size: 17px; line-height: 1.4; hyphens:
auto } body { margin: 0 }`), and measured its lines from character boxes. Lines were matched by
their text, so a block is compared even where the engines break it differently.

Each title's title page, half-title page, epigraph and dedication, where it has one, was
captured on the iPhone 17 Pro and iPad Air 13-inch (M4) simulators in paging in portrait and
landscape and in continuous scroll, at 17 and 28 points: 384 captures, each beside WebKit. Two
columns need a landscape page wider than about 775 points, so the iPad in landscape has them
and the iPhone 17 Pro (750 points between its safe-area insets) has one. On the Mac the same
was rendered for five titles in a window never put on screen (600 by 800 points for one
column and for continuous scroll, 1200 by 800 for two columns): 108 captures.

After the owner approved an on-screen session, the Mac sample app was opened once per page and
its window captured: 31 pages of *The Great Gatsby*, *The Sun Also Rises*, *Dracula*,
*Tristram Shandy* and the book written for the `150vh` check, in a window of 700 by 1,050
points for one column and continuous scroll and 1,300 by 950 for two columns. The book, the
section, the flow, the text size and the window's frame were launch arguments (`-SampleHref`
was added to the sample for this), and each launch was in the background: the app was never
made active, no key or click was sent to it, and the frontmost app was the same before and
after all 31 captures. These pages have no WebKit beside them. They agree with the off-screen
rendering: the epigraph of *The Great Gatsby* has the same five lines, 23.5 points apart, their
ink within 3 points of the recorded glyph extents once the wider window's 50 points are taken
off, and the dedication sits 23.5 points lower in continuous scroll than in paging in both.

### The Mac app, operated

The owner asked for the Mac app to be used, not only captured. On 2026-10-12 the sample app
(built at `8100232`, light appearance, a window of 1,000 by 1,000 points, *The Great Gatsby* at
17 points) was operated through its own controls: accessibility presses, pointer events and
keys delivered to its window while another app stayed frontmost. Positions are ink measured in
window captures.

- **Scrolling.** Scroll Forward and Scroll Backward, and Page Down and Page Up, move through
  the dedication, the epigraph and the half-title page with every line where the captures have
  it: the epigraph's lines start and end at the same points as in the 700-point window, 150
  points further right.
- **Selecting.** A double click selects the word under the pointer and a drag selects from
  where it starts to where it ends, in the epigraph in continuous scroll and in a column: the
  highlight covers those words and no others.
- **Turning pages.** In paging the 1,000-point window has two columns. Previous Page and Next
  Page show the dedication, the epigraph and the half-title page each alone in the left column
  and chapter 1 across both.
- **The contents.** Choosing Epigraph from the Contents menu in continuous scroll rests the
  box's top edge at the top: nothing shows above the epigraph's first line, which is 291.5
  points below the top of the reading area.
- **Resizing.** With the dedication shown in continuous scroll, making the window 200 points
  shorter moves its lines up 98 points, half of 98% of the change, and making it 200 points
  taller again puts them back exactly.
- **Changing flow.** Switching from continuous scroll to paging keeps the page being read.
  Switching from paging to continuous scroll on the dedication's page rests the box's top edge
  at the top when the page was reached by navigation. When it was reached by turning back from
  the pages after it, the reader's position is the end of the section, and the dedication's
  last line rests at the top of the reading area with the dedication's blank space scrolled
  away. See [Remaining boundaries](#remaining-boundaries).

### What was found

1. **Continuous scroll misplaced every centred page; fixed.** A text with a float, a
   positioned box or a sized inline block has all of its lines placed by the reader's text
   container, and in continuous scroll that text is the whole book. All ten titles have such
   a box. There TextKit 2 wraps a line within its paragraph's indents but aligns and justifies
   it across the rectangle it was handed, and the container narrowed that rectangle by the
   tail indent a second time. A centred flex item is two large indents, so at `main`
   (`5dbdedf`) *The Great Gatsby*'s dedication sat 70 points right of centre on the iPhone
   and wrapped two letters to a line at 28 points, and a verse epigraph wrapped early with its
   attribution at the column's edge. Any indented, centred, right-aligned or justified
   paragraph in such a text was affected, in pages too, and so was prose with its own margin
   beside a float ([#150](https://github.com/vocaro/EPUBLib/issues/150), second defect). The
   container now hands TextKit paragraphs without indents and gives each line a rectangle that
   leaves them out. The scroll column is as wide as a portrait page's, so a page should have
   its lines in the same places in both flows. At `main` 8 of the 40 flex captures in
   continuous scroll on the two simulators wrapped as the same page does in paging, and lines
   sat up to 270 points from where paging has them. Afterwards all 40 do, and all 14 on the
   Mac, with no line more than 0.1 points from its place in paging.
2. **Paging matched where the engines break lines alike.** Over the 26 flex captures with the
   same line breaks on the two simulators (of 80), the block's top and its vertical middle are
   within 0.1 points of WebKit's, its left edge within 12.3 and its right edge within 6.8. The
   horizontal figures are hanging quotation marks (below); without one the edges are within a
   point. On the Mac a line box is a third of a point shorter than WebKit's at 17 points, so a
   block's top differs by up to 1.7 while its middle agrees.
3. **Line breaks differ on 105 of 168 epigraph and dedication captures.** The books ask for
   `text-wrap: pretty`, which WebKit honours and the reader does not; in a centred
   shrink-to-fit dedication WebKit even splits a line that fits ("My Dear Friend" in
   *Dracula*). With `text-wrap: wrap` forced WebKit breaks those pages as the reader does. A
   block with a different number of lines keeps its vertical middle and moves its top by half
   a line or so.
4. **Hanging punctuation.** `hanging-punctuation: first last` hangs an opening quotation mark
   outside the block in WebKit. The reader does not hang it: *Frankenstein*'s epigraph is the
   mark's width (7.7 points at 17) wider, its first line 3.6 points right of WebKit's and the
   others 4.4 left.
5. **Baselines.** Line boxes agree; the reader sets glyphs about a tenth of an em lower within
   one (1.8 points at 17, 2.8 at 28), as it does for all text.
6. **Title pages show their hidden heading.** The reader's rule for off-screen labels takes
   offsets in absolute units, so `left: -999em` leaves the eight headings and bylines visible
   above the image that repeats them ([limitations](native-viewer.md#limitations)). Not
   changed here.
7. **A row of sized inline blocks was scattered, and overlapped in continuous scroll; fixed
   since.** *Tristram Shandy* marks omissions with runs of asterisks, each in an inline block
   of fixed width, which a browser sets as rows inside the paragraph, and in chapter 8.13 puts
   the initial of each word of an alphabet in such a block. At `main` the reader put each block
   a line lower than the last. In paging the prose after them wrapped round each one, breaking
   words across the gaps; in continuous scroll it was drawn over them (chapters 5.37, 6.34 and
   9.20). There were two causes. The planner placed an inline block after the last line of the
   paragraph before it, which for a block following another is that block's one glyph, not its
   box, so each landed inside the one before and was dropped below it; a block that opened a
   paragraph was placed after the previous paragraph's last line for the same reason. And in
   continuous scroll the boxes' places are planned for the whole book while TextKit only
   estimates the height of the text above the screen: at chapter 5.37 a line was 5,232 points
   from where the plan had it, so the prose never met the boxes beside it. The writer now
   records where each block sits on its paragraph's line, the planner sets a run along that
   line and wraps it, and the text container wraps each paragraph against the plan from where
   that paragraph is laid out ([native viewer](native-viewer.md#floats-and-positioned-boxes)).

   Captured before (`main` at `71bf8ce`) and after on the iPad Air 13-inch (M4) and iPhone 17
   Pro simulators (iOS 27.0, 17 points, a 720-point and a 374-point column), in paging and in
   continuous scroll, for chapters 5.37, 6.34, 8.13 and 9.20 and for the fixture of
   `Fixture.inlineRows()`. Before, the marks of 5.37 were on nine lines on the iPad, and in
   continuous scroll 8 pairs of lines overlapped there, 29 in 6.34 and 34 in 9.20 (8 and 36 on
   the iPhone, where 6.34's marks are below the screen). After, no two lines overlap in any of
   the 24 captures. Beside WebKit showing the same document with `text-wrap: wrap`, every mark
   is within 0.1 points of WebKit's, across and down, and the prose that follows each run
   starts within 0.4 points of WebKit's. As the books ship, with `text-wrap: pretty`, WebKit
   evens a run's rows out (eleven marks and nine where the reader has twelve and eight); the
   number of rows was the same in every capture.
8. **Ordinary sections in continuous scroll** rest their first line at the top, so a
   half-title page's 3em margin is above the screen where WebKit, showing that document alone,
   has it on screen. That is the existing rule for positions that do not start an aligned box.

### The disclosure

Three of the ten titles emit "Some flexible box or grid layouts are shown as blocks in reading
order…": *Tristram Shandy* (13 of 338 sections), *Ulysses* (1 of 25) and *The Wind in the
Willows* (1 of 16). Each of the fifteen sections has a row flex container with several items,
which a browser sets side by side and the reader sets one under another, so the sentence is
warranted in every one. The other seven titles use flex only for epigraphs and dedications,
inside the subset, and emit nothing. Two more rows in *Tristram Shandy* (chapters 1.4 and
4.27) are not disclosed: their only real item is text, which is placed, and the rules drawn by
their empty `::before` and `::after` boxes are not drawn.

The qualification corpus is not kept with the repository, and `EPUBLIB_CORPUS` is not set on
the Mac this ran on. With the owner's agreement the count was made, on 2026-10-12 at `376d94f`,
on the books the [first qualification](native-viewer.md#qualification) describes, as they are
on that Mac now: StudyWright's shelf sources (`pipeline/shelf/sources`, 55 EPUBs and 21 more
under `native-candidates`) and the exports of the PDF review set by PDFReflowLib and two other
converters (`blind-check-359/exports` in the PDFReflowLib measurements: 91, 92 and 91 EPUBs).
Of the 350 files, EPUBReading opens 347 (the others have an empty spine, an image over the
import limit and a cut-short archive), and every one of their 27,731 sections was built as
`NativeCorpusQualificationTests` builds them. None carries the disclosure. The same count on
the ten titles above gives the three named there.

### Sections with boxes

None of the ten floats anything. Their boxes are the headings that title pages, imprints and
colophons position off to the left, and in *Tristram Shandy* sized inline blocks. The first
pages of five such sections and of every title page were captured in pages and in continuous
scroll on both simulators (160 captures). No line leaves its column or page. In 7 captures,
all of *Tristram Shandy*'s asterisk rows, an asterisk and the prose after it overlapped
(finding 7, fixed since); the title pages and the imprint have no overlap.

### The four choices

Four decisions described under [Flows](#flows) and in the
[native viewer](native-viewer.md#flex-and-grid-alignment) were made without review. Each was
captured on the iPhone and iPad simulators and on the Mac with a plain description of what is
on screen. On 2026-10-12 the owner, shown them, called them minor cosmetic matters he had no
strong feelings about and left the judgement to the agent that ran this check. All four are
kept, for these reasons:

- **The viewport height in continuous scroll is the visible reading area.** A full-page
  dedication or epigraph then takes one visible screen with its text in the middle, which is
  what the book asks for: where the engines break lines alike, the block's top and middle are
  within 0.2 points of WebKit's on the simulators. It is also the viewport images already use.
  The cost is that a box is resolved again when a host shows or hides a bar: when a 54-point
  bar hides, the box grows by 53 points and the text of a dedication on screen moves 26. A
  fixed height would
  hold the text still but leave the box taller than the screen, and its text off centre,
  whenever a bar shows.
- **A position that starts an aligned box rests the box's top edge at the top.** The page is
  then seen as it was composed, as in paging. Resting the first line there instead would put a
  centred dedication at the top of the screen with all of its blank space below. The last lines
  of the section before show in the top margin, as they do above any position.
- **A box is at most one viewport, so `min-height: 150vh` behaves as `100vh`.** In paging the
  cap keeps a box and its text on one page with no blank page after it. In continuous scroll
  the box is half a screen shorter than WebKit makes it, all of it blank space. None of the ten
  titles asks for more than one viewport.
- **A one-page epigraph leaves the second column of a spread empty.** That is the paging rule
  for every section (a section starts a spread), not something the alignment added. Changing
  it would repaginate every book with a short section, which is outside this check.

### Environment

| | |
| --- | --- |
| Before | `main` at `5dbdedf` |
| After | this branch at `2431b6a` (the fix merged with `main` at `864cf18`); the Mac pages at `ccc29a1`, the same library sources; the sample app on the Mac's screen at `f4e7c51` |
| Mac | macOS 27.0 (26A428). Xcode 27.1 (27A9269), Apple Swift 6.4, for the captures and the Mac suite; Xcode 27.0 (27A266a), the default of `scripts/test-ios.sh`, for the simulator suites |
| Simulators | iOS 27.0 (24A434); iPhone 17 Pro, iPad Air 13-inch (M4); created for this and deleted |
| Appearance | Light on both sides of every comparison. The simulators were set to light, and the reader's style and the web view were set to Light. The Mac was in Dark; its off-screen window and web view were set to Aqua and the reader's style to Light, and the sample app was launched with `-NSRequiresAquaSystemAppearance YES`, so its window was captured in light |
| Tests | Mac suite at `8100232` (the branch merged with `main` at `4a4624f`): 2,265 tests, no failures. iPad Air 13-inch (M4) simulator at `2431b6a`: 2,140 tests, no failures. iPhone 17 Pro simulator at `2431b6a`: 2,140 tests, 2 failures, both time limits |

The two iPhone failures were time limits (190 nested notes in 10 seconds, 11,205 elements
styled in 3) missed while the machine's load average was in the hundreds from other work. The
first passes when run alone, and neither is in code changed here. The iPad run, straight after,
and the Mac run have no failure.

### Not verified

- No physical iPhone or iPad.
- No VoiceOver session.

## Remaining boundaries

- Margins between flex and grid items collapse as block margins do; a browser adds them.
  Standard Ebooks' rules set one margin per gap and are unaffected.
- `flex-shrink`, `flex-basis`, `align-content` in flex containers, `column-gap`, percentage
  gaps, baseline alignment and `aspect-ratio` are not laid out. `box-sizing` applies to
  heights, not widths.
- Start-aligned items keep the full line (visible only when their text is centred or
  right-aligned), and items holding images, tables or formulas keep their block-flow width
  and placement.
- A box taller than one viewport is treated as one viewport tall. `min()`, `max()` and
  `clamp()` heights choose their branch against the nominal 600 by 800 viewport.
- A container holding a float or positioned box is left in block flow, and a section with
  both an aligned box and such boxes relies on the existing box geometry for the latter.
- In continuous scroll a change of the visible height re-resolves the whole text's attributes
  when it holds an aligned box, as it already does for percentage-sized paragraphs.
- `text-wrap: pretty` and `balance` are not laid out: lines break greedily, where WebKit evens
  them out. `hanging-punctuation` is not laid out: a quotation mark a browser hangs outside
  its block is inside it, which makes the block that much wider.
- Rules that a row draws with empty `::before` and `::after` flex items are not drawn, and
  that is not disclosed (*Tristram Shandy*, chapters 1.4 and 4.27).
- A title page that parks its heading with a font-relative offset (`left: -999em`) shows it:
  the reader's rule for off-screen labels takes absolute units
  ([limitations](native-viewer.md#limitations)).
- Continuous scroll rests a box's top edge at the top only for a position at the box's start.
  A position further into the box rests its own line there, which scrolls the box's blank
  space away. That is how a dedication looks after it was reached in paging by turning back
  from the pages after it (the position is then the end of its section) and the flow is
  changed to continuous scroll: its last line is at the top of the reading area. Scrolling, or
  choosing the section from the contents, shows it as composed.
