# Flex and grid alignment qualification

The native viewer aligns the flex and grid layouts that keep its single column of TextKit
paragraphs, and leaves every other layout in block flow in reading order with a disclosure
([#20](https://github.com/vocaro/EPUBLib/issues/20)). The reader-facing rules are in the
[native viewer](native-viewer.md#flex-and-grid-alignment) document; this is how the subset was
chosen and what was checked.

## Survey

No book corpus was downloaded or read for this work. The subset rests on two sources: the
flex and grid usage in this repository's fixtures and tests, and the published conventions of
well-known stylesheets as recalled, not re-fetched.

- **This repository.** Before this change no rendering fixture used flexbox or grid. The only
  uses were a style-resolution test for the blockification of flex and grid items and parser
  tests for `display: flex` and `@supports (display: flex)`. The limitation recorded in the
  native viewer document named one concrete case: Standard Ebooks epigraphs.
- **Standard Ebooks.** Its Manual of Style gives full-page epigraphs and dedications one
  shape, which its half-title pages share as far as recalled: inside
  `@supports(display: flex)`, a `section` with `display: flex`,
  `flex-direction: column`, `justify-content: center`, `align-items: center`,
  `box-sizing: border-box`, `min-height: calc(98vh - 3em)` and `padding-top: 3em`, whose
  children have `margin: 0` and `* + * { margin-top: 3em }`. Outside `@supports` the children
  carry the older fallback (`display: inline-block; margin: auto; max-width: 80%;
  text-align: initial`), which still applies its `max-width` and `text-align` to the flex items.
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
the same markup and styles as loose parts.

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
- `BoxAlignmentSessionTests`: the fixture book through the public commands in both flows:
  disclosure, href navigation, located and selected passage, saved highlight, restore, and the
  same CFIs in either flow.

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
iPad or Mac display was inspected for this work, no VoiceOver session was run, and no
publisher corpus was rendered: the Standard Ebooks rules are reproduced from its published
conventions, not read from a shipped title.

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
