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
   That parser is given UTF-8, so an unclosed tag does not change a section's characters:
   UTF-16 and UTF-32 are decoded first, told by the byte-order mark or NUL pattern the screen
   tells them by, and any other encoding by the name in the XML declaration as the XML parser
   reads it, with that parser's decoder. An HTML `<meta charset>` is not read, and a
   declaration the XML parser rejects names nothing. A document that its declared encoding
   cannot decode is read as UTF-8, with U+FFFD for what is not. Bytes that only a NUL tells
   as UTF-16 or UTF-32, and that hold no markup once decoded, are not a document and are
   withheld. What was decoded by a declared encoding is screened again, and what the parser
   is given is held to the byte limit.
   U+0000 does not end the section: it is left out of text and is U+FFFD in tags, comments
   and the raw text of `script` and `style`, as HTML reads it.
   A section whose file is cut off inside markup stays withheld, with its disclosure: the
   screen refuses markup left open at the end of the input before either parser runs.
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
  handed to the book's voice as if it were its language. On Mac a formula's character carries
  an image element named by the reading, in a page's text and in a table cell's, and
  VoiceOver says the reading and then its own word for an image: "y cubed image".
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
- **Alternative text.** HTML tells an image with an empty `alt` from one with none, and the
  reader keeps the two apart (`ImageAlternative`). Words in `alt` stand for the image in
  selections, copies, search and VoiceOver, which reads them as the image's name. An empty
  `alt`, or one of white space alone, marks decoration, or a picture of words the book also
  gives as text, as a Standard Ebooks title page does beside its hidden heading and byline:
  it has no words, and VoiceOver passes over it, with no element, no name and no inspection
  action. An image with no `alt` at all may be content that nobody has described: VoiceOver
  stops on it and says that it is an image, in its own word and language, and the reader makes
  up no name for it. Both used to be announced as "Book image". An SVG file's own title and
  description name it only where the book gave no `alt`; an `<object>` or `<embed>` has no
  `alt` and is named by its `title`, and an inline SVG by its title and description.
  A link stays reachable whatever its image's `alt` says. Decoration that is all its link
  holds is the link, an image link without a name; decoration beside words in a link is
  passed over, and the words carry the link. Two cases keep decoration listed on iPhone and
  iPad, where VoiceOver turns a page or reads on from an element of the text and a view
  without one leaves it no place to do so: a page that holds decoration alone lists it, as
  images without a name, and so does a screen of decoration alone in continuous scroll,
  whatever is listed after the screen, where a picture keeps its element while VoiceOver's
  cursor is on it. On Mac the text
  area is itself the element and its keys turn the page, so decoration is always passed
  over: its character stays in the text area's value with no element of its own, VoiceOver
  says nothing for it by line or in Read All, and moving by word its cursor takes one step
  across it for which no phrase was recorded. An image without words has no help text on
  Mac, where VoiceOver reads the help of an element without a label in the label's place.
  Not read: `role="presentation"`, `aria-hidden` and `aria-label` on an image. On
  iPhone and iPad an image in a table cell is read by its words in the cell's text, and one
  without words is not announced there. On Mac a cell is a text area of its own, which
  VoiceOver reaches by interacting with the cell's row (in a table of data, with the row's
  table) and then with the cell, and an image
  there is what it is in the text around the table: VoiceOver says its words and "image",
  or "image" alone where it has no `alt`, and passes over decoration, and the image's
  element has the Inspect Image action. It said nothing at any image in a cell before
  ("Rules" below has why). An image in a cell's link is announced as the link, by its words
  ("Links for VoiceOver on Mac"). In a note's popover on iPhone and iPad the text is read by
  UIKit's own elements, which were not heard with an image in them.
- **Rules.** An `<hr>` is a break between the paragraphs it parts: a change of scene or of
  subject. A book writes one so that the break need not be seen to be known, and HTML maps
  the element to the separator role for that reason. It is drawn as a line and has no words,
  so selections, copies and search read nothing for it. On iPhone and iPad VoiceOver stops
  on it, in pages and in continuous scroll, and says "Separator". It is a stop and not
  decoration to pass over because the break is part of what the book says: someone who sees
  the page gets it from the line, and without the stop two scenes are read as one. UIKit
  has no trait for a separator, so VoiceOver has no word of its own for one, as it has for
  an image or a link. The word is the reader's (`ReaderRuleAttachment.spokenName`), the
  name of the role, and it is English whatever the language of VoiceOver or of the book, as
  the names of the page actions are. The stop has no trait: it is neither a picture nor
  words of the book. A rule used to be listed as an image without a name, and VoiceOver
  said "Image" at each one. Because a rule always has a stop, a page that holds a rule
  alone is turned from it, with no exception of the kind decoration needs, and a rule that
  is all a link holds is the link. On Mac the text area is itself the element and a rule
  stays a character of its value, so the value and every range are those of the
  characters. The character carries an element, as an image's does, and VoiceOver says
  "Separator" at it: moving by line, moving by word, where the rule is one stop, and
  reading on by itself, in pages and in continuous scroll. On a page that holds a rule
  alone it says "In text Separator" and then "end of text". Before, it said nothing in any
  of those places. The element is static text whose value is the reader's word, as a
  hidden label's is the book's. It has no label and no help, because VoiceOver reads the
  help of an element that has no label in the label's place. The word is the reader's on
  Mac too, because AppKit has no role for a break in content. The nearest is the splitter,
  which is what WebKit gives an `hr` on Mac, with the subrole `AXContentSeparator` and a
  role description of its own, "separator". To VoiceOver a splitter is the bar between two
  panes wherever it stands. At a rule with that role it said "horizontal splitter
  collapsed on top", with or without the subrole, and with all of WebKit's attributes
  "horizontal separator no action available collapsed on top": it reads the role
  description and still tells of a pane that is not there. An element of AppKit's unknown
  role with the role description "separator" was read as "separator", the same as the
  static text in every place it was heard. The static text was chosen because its word is
  what the element holds, as the stop's label is on iPhone and iPad, and because it is the
  element a hidden label already has. In a link on Mac a rule gives way to the link: one
  that is all its link holds, or that opens a link of words, has the link's element in its
  place, without a name ("Links for VoiceOver on Mac" below), and one elsewhere in a link
  has its own. No rule in a link was heard. Not read: `role="presentation"` and
  `aria-hidden` on a rule, which is announced like any other. On Mac a table cell is a
  text area of its own, which VoiceOver reaches by interacting with the row and then with
  the cell. A rule in a cell has the same element there, and VoiceOver says "Separator" at
  it by line, by word and reading on, in pages and in continuous scroll, and as it reads
  the cell on entering the row. Before, it said nothing at a rule in a cell, and nothing
  at a formula, a picture or a hidden label there either, whatever element the cell gave.
  A cell made a new element for each attachment at every read of its rich text and kept
  none, where a page's text keeps its elements from one read to the next. VoiceOver asks
  an element what it is after the read that gave it, and by then an element that nothing
  holds is gone. Two things set a cell's elements apart from a page's, and each was heard
  alone: with the elements kept and nothing else changed VoiceOver read every one, and
  with a frame for each, which they also lacked, and none kept, it read none. A cell now
  keeps its elements for as long as it stands, gives each the place its character is
  drawn at, and makes each what the page's text makes of the same attachment, through the
  same function (`NSAccessibilityElement.setReaderAttachment`): an image named by its
  words for a picture or a formula, the words of a hidden label as text, and nothing for
  decoration. A table inside a cell has no text views of its own, so each of its rows is
  its cells' words there, as text. A rule's text equivalent is empty in a cell as
  anywhere, so a copy, a selection and the row's own words have nothing in its place. On
  iPhone and iPad a rule in a cell has no words in the cell's text and is not announced
  there, and UIKit's own elements in a note's popover were not heard with a rule in them.
  A note's popover on Mac is a text area of the page's kind and was not heard either.
- **Links for VoiceOver on Mac.** AppKit gives a text view's links to an assistive client
  itself: an element for each, as the link of its characters in the text's accessibility
  string and as a child of the text. VoiceOver (macOS 27.0.1, with "When encountering a
  link/attachment" at Speak, its default) uses them in two ways. Find Next Link and Find
  Previous Link move through the children and say each one's name and "hyperlink", and
  Control-Option-Space follows the link under its cursor, or a link on the line its cursor
  is in. Reading by word, by line or in Read All it says a link's words and nothing of the
  link. All of that is so in AppKit's own text views, with TextKit 2 and with TextKit 1.
  AppKit names a link by its characters, so one that is a picture or a hidden label was
  called U+FFFC: Find Next Link said "hyperlink" and no name, for a described picture too.
  A hidden label takes no room, so its link had no size and Find Next Link did not reach
  it. The reader gives elements of its own in AppKit's place
  (`ReaderLinkAccessibilityElement`), each with AppKit's role for a link in text and a
  press that follows the link. A link is called by its words, with the text of each
  attachment in its place and decoration left out. One that holds pictures and nothing else
  says after any words that it is a picture, in the system's word for one, because an
  element that is a link cannot be an image as well. A page column gives its own page's
  links: one that crosses the page's end is the part on the page, and one in the context
  laid out after the page is not listed. The scroll view lists the links of the paragraphs
  on screen, as AppKit does. The text's headings stand among those children too, each
  where it is in the text, and after them the book's next one: with its cursor on a link
  VoiceOver finds the next heading there and nowhere else ("Input and accessibility",
  Headings).
  VoiceOver announces an element given as a character's attachment as it reads, and none at
  a character of words. So each attachment in a link, a picture, a hidden label or a
  formula, has a link element for its own: VoiceOver says "hyperlink" and the name there by
  word, by line and in Read All, and Control-Option-Space follows the link. A picture keeps
  its Inspect Image action on that element. Decoration that opens a link of words has an
  element without a name, which says "hyperlink" before the words, and decoration elsewhere
  in a link is passed over. So is a rule that is all its link holds: the link, without a
  name. A link of words alone is read as its words, as everywhere on the Mac: an element
  laid over its characters, or over the first of them, was not announced. A table row in a
  link stays the group of its cells.
  Not done: a list of links in VoiceOver's rotor. A custom rotor puts one there, and
  VoiceOver then goes by it for Find Next Link as well. With a link's characters as its
  results VoiceOver said the words without "hyperlink" and found no previous link; with the
  link elements as its results it said "Link not found". So in continuous scroll a link
  below the screen is reached by reading or scrolling to it. VoiceOver's search for
  elements cannot give it one either: an answer that is no child of the text was refused,
  and a text that offers the search is asked for much else ("Input and accessibility",
  Headings). With the next link below the screen among the children, as the next heading
  is, Find Next Link went to it and VoiceOver scrolled there; that was heard once on a
  throwaway branch and is not built
  ([#425](https://github.com/vocaro/EPUBLib/issues/425)). A note's popover keeps AppKit's
  elements, and its links do nothing.
  A table cell is a text view of its own. VoiceOver meets a row as one stop of the page's
  text, "Table row group"; interacting with it there shows the row's cells, and interacting
  with a cell reads the cell's text by word and by line as the page's is read. A cell's
  links were AppKit's. A link of words was found and followed inside its cell, but a link
  that is a picture was "￼ hyperlink", decoration beside a link's words went into its name
  as that character, and a hidden label that is a link was not reached. Moving by word,
  VoiceOver said nothing at a picture or a label in a link, whatever words it has, while a
  cell kept none of the elements it gave for its attachments. A cell
  now gives its links as the text around the table does, through the same code
  (`ReaderLinkHost`): the reader's elements as its children and as the links of its
  characters, named, placed and pressed the same way, and a link element for each attachment
  in a link, so VoiceOver says "hyperlink" and the name there. A cell gives its characters
  from the first one it shows, an attachment as one character, and its links' ranges count
  the same way. Where a row goes on over a page's end, each part of a cell gives the links
  of its own lines, and a link the page cuts is the part on the page.
  Find Next Link goes through the links of the text VoiceOver is in, and a row is one
  character of the page's text: from the page it found no link that a cell has, and said
  "Link not found" on a page whose only links are in a table. The page now lists the links
  of its cells on screen among its own children, where their rows stand, so Find Next Link
  from the page goes through them in reading order and Control-Option-Space follows the one
  it is on. They are elements of the page's own, each with its cell link's name, place and
  press, and not the cell's elements. From a link VoiceOver goes on through the children of
  that link's parent: given a cell's own element, it moved from the page to the table's
  first link and called it the last. Such a link is no character of the page's text, so
  VoiceOver's place in the text stays where it was, before the table, and moving by word
  from the link goes on from there. To read the cell around a link, interact with its row.
  An attachment in a cell that is no part of a link has the element the page's text gives
  it ("Rules" above).
- **Image inspection.** Double-click or double-tap an unlinked book image to inspect it in a separate
  native zoomable scroll surface, including images drawn inside table cells. On Mac, images
  also offer an Inspect Image context-menu action; UIKit supplies an attachment action and
  menu. Linked images retain link navigation and offer inspection through the menu.
  Accessibility actions expose inspection for the visible images VoiceOver is told of, by
  their words where they have them; on iPhone and iPad an image's own item offers it and no
  other line does. In the inspector an image is named by its words, or is
  an image without a name. Zoom In, Zoom Out, Fit
  and Close controls complement pinch/trackpad magnification and panning; Escape closes the
  inspector and Command-plus/minus/zero zooms or fits it. Reader page input is suspended while
  inspecting. Closing preserves the reader's text, selection and reading position.
  Inspection decodes the original archive resource independently of its inline CSS size and
  body font size, retaining resolution up to 16 megapixels and an 8,192-pixel long side.
  Larger raster images are downsampled within those bounds; SVG retains its existing
  4,096-pixel rasterization limit. The same image contrast policy and bounded cache apply.
- **What an item offers VoiceOver.** On iPhone and iPad each item of a page or a screen
  offers its own actions, and nothing that contains it offers any ("Input and accessibility"
  has why). Three things follow. A page turn chosen in the rotor is a command, as a host's
  is: selected text holds back a tap or a swipe, which could be meant for the selection, and
  not this. The reader's SwiftUI surface no longer names the pair there, and it was what
  still turned the page while text was selected; a line's own turn did nothing then and
  reported success. The turn fails at either end of the book. A note's popover keeps UIKit's
  own elements and passes on UIKit's actions, and the reader adds none: a note has no
  canvas to inspect an image in, and offered no inspection before either. And an item with
  no action gives no list of actions, not an empty one.
  What UIKit gives a text view was heard by itself on 2026-10-12, in a build that named every
  action for the object that gave it
  ([VoiceOver testing](voiceover-testing.md#harness-pitfalls-and-current-results)): the
  scroll view one action for each run of its text that is a link, named by the link's
  characters, "￼" for a link that holds only a picture or a hidden label, six in the
  verification book and none for a picture that is not a link; and a page column none, on a
  page that shows a link. VoiceOver ends the list of an item's actions with "Activate
  Default" and starts again. On Mac a text area has no elements for its lines, so each
  text area offers the page turn itself, the same command under the name its flow gives
  it ("Input and accessibility").
- **Tables.** Attachments drawn natively (TextKit 2 has no `NSTextTable` on iOS), one
  image-drawn attachment per row so pages can break between any two rows; rows a rowspan
  joins, and the header, keep with the next row and share a page when they fit. `colspan`/
  `rowspan` honoured (`rowspan="0"` spans one row, as WebKit does); a spanning cell is drawn in
  each row it covers. Oversized rows continue across pages using complete cell glyph lines;
  a line crossing a rowspan boundary is finished in its preceding row and never drawn twice.
  Continuous scroll retains full row heights. Tables too wide for the line shrink their text
  to 60%, then wrap by character. A single glyph line taller than a page is fitted as a whole.
  One-column tables, which books use as callout boxes, flow as ordinary text: a table is a grid
  when the cells written in its rows take more than one column. Nothing a table holds is
  dropped. XHTML is parsed as XML, which repairs no tree, so content written outside a table's
  rows and cells arrives where it was written, and a grid gives it the anonymous rows and cells
  of CSS 2.2 §17.2.1: a row around what a table or a row group holds outside its rows (text,
  other elements, cells without a row, a table, a caption in a row group), and a cell around
  what a row holds outside its cells. A row written in a row, a row group written in a row or
  a row group, and rows written in another element there (a `div`, a `form`) are such content
  too: their cells show as stacked paragraphs in one anonymous cell. Anonymous rows and cells
  have no padding or borders of their own, are located, selected and searched like any cell,
  and exist only for content that shows: white space, comments, scripts and hidden elements
  make none, and what is written in a `col` or a `colgroup` has no box. They take part in the
  grid as CSS has it, so a `rowspan` from the row above can end on an anonymous row and a
  column can widen to an anonymous cell's content. The forgiving HTML parser moves nothing out
  of a table either, so recovered markup is shown the same way, in place rather than ahead of
  the table. Every caption is shown, above or below the rows as its own `caption-side` says.
  A grid holds 200 columns and 20,000 cells. A cell whose `colspan` runs past the 200th column
  reaches the table's last column when it is the last cell of its row, and then takes one row
  whatever its `rowspan`. A cell the grid has no slot for follows the table as a paragraph of
  its own in reading order, and the `.disclosure` says so: a cell with such a span that is not
  the last of its row (the cells written after it keep their slots) or that follows another
  cell left out of that row, a cell starting past the 200th column, and every cell past the
  20,000th.
  Visible cells have
  native text interaction surfaces aligned to their drawn glyphs: select and Copy cell text,
  invoke the host's selection action, follow internal links and open notes. External links retain
  the reader's refusal notice. Cell selections, located passages and saved highlights use exact
  DOM-based character ranges, including Unicode and inline markup. VoiceOver reads a table
  where it stands among the lines of its page, and each continuation by the
  words it shows, completing a word once if character wrapping splits it between pages. On
  iPhone and iPad it is given a table that holds data cell by cell, and a table that arranges
  content row by row ("Data tables" below says which is which and what each costs). A row of
  a table that is not data is one accessibility element, in pages and in continuous scroll alike:
  text, read as its cells' words in column order, with actions for its own cells (select a
  cell's text, follow a link in it, inspect an image in it). A row that shows pictures and no
  words is an image without a name, as a picture without words in a line is, and one that
  shows nothing, or decoration alone, is no element unless its page lists nothing else. The interaction
  surfaces are hidden from assistive technology there. A text view that is merely not an
  element still offers UIKit's own elements for its text, and VoiceOver took those, every cell
  on the page, before the first line of a page column and then read the rows as well. On Mac
  a table that holds data is given as a table at each of its rows ("Data tables" below), and
  a row of any other table is a group that holds its cells' text areas. A cell's lines are those its own layout
  makes, numbered from the first it shows, and the offset after its last character is on its
  last line, as the offset after a page's last character is on the page's. VoiceOver leaves
  a text's insertion point after a word it has read, so with its cursor on a cell's last
  word, or past it, the insertion point is at that offset. While a cell had no line for it,
  VoiceOver's Read Line (Control-Option-L) said nothing there, its moves to the line above
  and the line below did nothing, and it counted "-9,223,372,036,854,775,808 lines". A
  cell's text does not change while the cell stands, so no offset past that one is the
  cell's, and none has a line.
  Continuations retain original
  source offsets: several pages can report the same row range. Existing bookmarks naming a
  whole table still resolve to that table; new cell ranges identify the selected characters.
  Interaction surfaces are mounted only for visible cells. Cell TextKit
  layouts and glyph metadata are retained for drawing in the table's bounded layout cache.
  In continuous scroll which rows are visible is read from TextKit's layout, and the scroll
  view tells of a move when its offset changes, before the text is laid out at the new place.
  Looked for then alone, the rows that layout had not reached got no surfaces. So the rows
  are looked for as the view moves and again once the reader has read where the view
  stands, which every move ends in: the reader's own, to the section a book opens at, a
  contents entry, a link's target, a step of a page or its place at a new size, and within
  150 ms a person's. Highlights and a selection that run through the cells are put on them
  at the same time. Before, the lowest rows on screen had no surface after a step of a page
  or the reader's last correction on its way to a contents entry, on Mac as on iPhone and
  iPad, and where that correction was by more than a screen none had: the section the
  VoiceOver sample book opened at on an iPad. A held finger there selected the whole row,
  as the text under the surfaces does, a cell's link could not be followed, and a row's and
  a cell's items offered an assistive technology no actions, until the person scrolled
  ([#472](https://github.com/vocaro/EPUBLib/issues/472)).
- **Data tables.** On iPhone and iPad VoiceOver is given a table of data as Safari and Apple
  Books give it an HTML table: each cell is a stop, and VoiceOver says the cell's row and
  column, the header cells of both, and where the table starts and ends, and offers Rows in
  its rotor, which moves down and up a column. A row read as its cells' words in one breath
  suits a table that sets two things side by side; in a table of figures it does not say
  where a cell ends, which column a value stands in or what heads it.
  - **Which tables.** HTML has no element that says a table is there for layout, so the
    reader decides as WebKit does (`AXTableHelpers` in WebKit's source, read on 2026-10-12),
    from what it builds and draws. A `role` on the table settles it: `presentation` or
    `none` is layout, and `table`, `grid` or `treegrid` is data. Without one a table is data
    when it has a caption, a `summary`, a `thead` or `tfoot`, a `col` or `colgroup`, or
    `rules`; a row or a cell with a table role, or a cell with `headers`, `scope`, `abbr`
    or `axis`; twenty rows, or twenty cells in a row; ten cells ruled above and below or on
    both sides; or half its cells ruled so, or ruled on any one side. The table's `border`
    attribute rules every cell; a border around the table alone rules none. Two things
    differ from WebKit. Any header cell makes a table data, where WebKit wants a first row or
    a first column of them: a `th` says what it heads, and a row cannot say that. And cells
    with a background of their own, and rows of alternating backgrounds, do not: the dark
    appearance computes no backgrounds, and a table must be the same thing to a listener in
    either appearance. Every other table is read row by row, as above. A table of one
    column was never a grid here and still flows as text.
  - **What it costs.** A table is a stop for every cell, so a table of forty rows and three
    columns is 123 moves where it was 41, and VoiceOver adds "Row 3", "Column 2" and the
    header cells' words to what the book says. For a table of data that is the point, and
    the rotor's Rows crosses it a row at a time. For a table that only looks like data to
    the rule above (twenty lines of verse beside their numbers, a ruled box with two
    things in it) it is noise the book did not ask for; `role="presentation"` is how a book
    says so, and it is rare. The rule can also miss a table of data: one with no header
    cell, fewer than twenty rows and no rules, shaded or not, is read row by row. That is
    what WebKit does with it too, except for the shading.
  - **Elements.** The table is one accessibility container where its rows stand among the
    lines (`UIAccessibilityContainerDataTable`), not a stop itself, and each cell an element
    inside it that says which rows and columns it covers. A cell that spans is one element,
    read where it starts, that answers for every slot it covers. An empty cell is a stop:
    it has a place in the grid, and VoiceOver says its headers and its column. A cell of
    pictures without words is an image, as a picture in a line is, and a cell of decoration
    alone says nothing, like an empty one. A cell whose words are one link and nothing else
    is a link. The caption is a line of its own before or after the rows, as it is drawn.
  - **Header cells.** A `th` heads its columns or its rows as HTML has it: by its `scope`,
    and without one its columns when it stands in `thead` or its rows hold header cells
    alone, and otherwise its rows when its columns hold header cells alone. UIKit asks a
    table for the header cells of a row and of a column, not of a cell, and VoiceOver says
    them before the cell it comes to, leaving out that cell itself and any it said for the
    cell before. So a header cell over a second row of header cells would be read under
    their names; the table answers with the header cells above and before the cell that
    was last asked where it stands, which is the cell VoiceOver has come to. A cell's
    `headers` attribute makes its table data and is otherwise not followed: UIKit has no
    way to give one cell headers of its own.
  - **Actions.** A cell offers what it can do itself: Select Cell Text, Follow Link with the
    link's words for each link in it, and Inspect Image for each picture; a page's cells
    also turn the page, like its lines. A cell whose words are selected offers Deselect
    Cell Text, Copy and the host's selection action in place of Select Cell Text ("A
    table's text selected with VoiceOver" below). A double tap follows the link of a cell that has
    one link, and shows the picture of a cell that is a picture. The actions come from the
    cell's interaction surface, so a cell listed past the screen has them once it is on
    screen, which is where VoiceOver's cursor brings it.
  - **Pages.** A page's table holds the cells that page shows, each with its row's number
    in the whole table, so the second page of a table starts at "Row 29" and not at 1.
    VoiceOver says "Table start" and the whole table's count of rows and columns at the
    first cell listed, and "Table end" at the last, whatever their numbers: a page that
    shows the middle of a table says both, and the row's number says where in the table
    the page is. The first cell VoiceOver comes to in a table is said without its header
    cells. The
    rows of another page are not there to move to; Next Page goes on, as from a line. The
    cursor is then on a new item with the rotor at its default, where a line's item goes
    with the page and keeps the action chosen ("A page turned under VoiceOver's cursor"
    under Input and accessibility). A
    column's header cell on another page is still named before the cells it heads: the
    table answers with an element that has the header's words and is nowhere to go. A
    row taller than a page continues: on each page its cell is the same cell of the table,
    reading the words that page shows. A cell is listed on a page where it has something
    to say: a short cell beside one several pages tall is centred in the row, so its words
    stand some pages in, and it is no stop on the pages before them. A cell that says
    nothing anywhere is listed where it starts. A cell that spans rows is listed where it
    starts, and the lines of it that later rows of the page hold are added to it there.
  - **Continuous scroll.** The rows listed follow VoiceOver's cursor as lines do (below),
    and the table keeps one element while any cell of it is listed, each cell its own, so
    VoiceOver reads on through a table longer than the screen in both directions and the
    rotor's Rows moves past the screen. Two things made that hold. VoiceOver asks a table
    for its next cell before it asks the text view for anything, so a table lists its rows
    again, for where the cursor is now, whenever it is asked; answered from the rows listed
    for the cell before, a table ended at the last of those. And the rows around a cursor
    that rests in a table the person has scrolled away from are listed in the same element
    as the rows on screen, with those between them missing, as lines are.
  - **On Mac.** VoiceOver on Mac reads a text area by line and by word, and meets a table
    only as the element the text gives at an attachment's character. A table is an
    attachment for each row, so each row's character gives AppKit's table, `AXTable`: the
    whole table, with the rows the view shows of it, its columns, its cells, each with the
    rows and the columns it covers, and a header for each column and each row, from HTML's
    header cells as `TableModel` has them. The table at a row is called by that row's words
    and says that row is selected. A table that is not data is as it was, a group for each
    row. Each part of this was heard on a hosted runner before it was kept
    ([VoiceOver testing](voiceover-testing.md), the entry of 2026-10-13 on tables of data
    on Mac):
    - **Reading the text.** By line and by word VoiceOver says a row's words and its own
      word for the role: "Alder, 1901, Twelve metres table". Every row of every table said
      "Table row group" before, and none of its words. A table of forty rows is forty
      lines, as it was. In continuous scroll a row off screen is the same element as on
      it, where a row without its cells' text views had been an image called by its words.
    - **Inside.** Control-Option-Shift-Down goes into the table at that row, and VoiceOver's
      table navigation is then its own: across a row it says the column's header and the
      cell ("Opened 1901", "Depth empty cell"), down a column the row's ("Cedar Forty
      metres"); Control-Option-C and Control-Option-R say the column's and the row's
      header. Pressed twice they read the rest of the column and of the row, which was
      heard on an earlier shape and not on this one. A cell that spans is one
      stop that answers for every slot it covers: moving down inside one, and at the
      table's last row, VoiceOver says the cell and its place, "Item 40 column 2, row 41".
      Rows above the one it came in at are there to move up to.
    - **A cell** holds its text areas while it is on screen, so Control-Option-Shift-Down
      on a cell goes into its words, by word and by line, as it did from a row's group.
      A cell off screen in continuous scroll is labelled with its words and holds nothing.
      VoiceOver's Actions menu (Control-Option-Command-Space) on a cell holds what the
      cell can do itself: Select Cell Text, Follow Link with the link's words for each
      link, and Inspect Image for each picture. A cell has no press of its own.
    - **Header cells, and VoiceOver quitting.** AppKit lets a cell name its own header
      cells, which is how HTML has them and what a web view does. Given that, VoiceOver
      quit: an exception in its own `-[SCRCell columnHeaderDescription]`, by the reports
      macOS wrote, at a move to a cell under a header or at Control-Option-C. That method
      appends the first header's description to a string without looking at it, and the
      description came back nil now and then, whatever the header was: the cell listed in
      the header's row, holding a text area, a label as well or a label alone (three
      sessions of three at two seconds a key, and two of those recorded at four), or an
      element of its own with a label (one session of seven at two seconds). Its method
      for a row's header is the same code. So no cell names a header. The table does, as
      AppKit's own tables do: one header for each column and one for each row of the whole
      table, and VoiceOver takes the one at a cell's column and at its row. With that it
      said the same headers and did not quit, in seventeen sessions at two or three
      seconds a key and ten at four. Whether to tell Apple is
      [#483](https://github.com/vocaro/EPUBLib/issues/483).
      What heads a column or a row is its one header cell, where that cell is on screen
      with its text areas: VoiceOver reads a header cell by what it holds, and does not
      read a cell under itself. Otherwise it is a static text with the words of its header
      cells, top or first one first: for a column under several header cells ("Hours,
      Leaves Nine"), a header on another page, and one far off the screen in continuous
      scroll ("Item Item 38", thirty-eight rows down). VoiceOver said nothing of a header
      that was a cell with a title or a label and nothing in it. Where nothing heads a
      column or a row the table gives an element without words, and VoiceOver says the
      number instead: "column 2 of 3", "row 1 of 4". One header for a column costs this: a
      header cell under another is read under the column's whole header, its own words
      among them, "Hours, Leaves Leaves". A cell's `headers` attribute is not followed, as
      on iPhone and iPad.
    - **Pages.** A page's table holds the rows that page shows, each with its number in
      the whole table, and its count of rows is the whole table's. The rows of another
      page are not there to move to: at a page's last row VoiceOver stays, and the page is
      turned as from a line. A page turned with VoiceOver's cursor on a table it has left,
      and not back in the text, leaves VoiceOver on the text area and not in it; with a
      row group it left the text for the window's first button, before and after
      ([#485](https://github.com/vocaro/EPUBLib/issues/485)).
    - **Continuous scroll.** One text area holds the book, and a table holds every row.
      Moving down a column VoiceOver goes on past the screen and the view follows it,
      twenty-eight rows in one session, each once and in order. Leaving the table puts
      VoiceOver back on the line it came in from, and the view goes back there with it.
    - **What it costs.** A table is one table element for each of its rows to an assistive
      client, each of them whole, and what VoiceOver remembers of its place in a table it
      remembers for the one it was in. A table says a row is selected that nobody
      selected. VoiceOver says "table" after every row's words.
      After Control-Option-Shift-Up, moving by line and going in again enters the table it
      left, not the one on the new line; moving by word first enters the new one. Row
      groups do the same, before and after. A row taller than a page is called by all the
      words it shows there, which VoiceOver reads to the end unless it is stopped.
    - **Why this shape.** Three things VoiceOver did decided it (macOS 27.0.1). Given the
      row (`AXRow`) at a row's character, with the table as its parent, VoiceOver said
      "table row", went in to "Cedar cell (1 of 3)", and said no header and took no table
      command: it was in a row and not in a table. Given one table at every row's
      character, it read the whole table at each of them; a label stopped that only with
      selected cells among the attributes too, and then it said "No selection" or read the
      selected row a second time with "column 1, row 3" after each cell. And it comes into
      a table at its selected row, or failing that at the first row on screen, so a table
      that selects the row it stands at is entered there, and says only its label and
      "table" as long as it says nothing of selected cells.
    - **Not done.** A cell offers no page turn: the text area does, one step out of the
      table. Nothing gives VoiceOver the table's caption as the table's name; it is a
      line of the text before the rows or after them, as it is drawn. Both are to be
      decided, with the header cell under another and where VoiceOver is after it leaves
      a table ([#486](https://github.com/vocaro/EPUBLib/issues/486)).
    - **Not heard.** Anyone listening, or a Mac that is not the hosted runner. What Safari
      or Books says of the same table on a Mac was not recorded, so "as Safari does" is
      true of the roles and attributes given and not of the speech. A table in a spread of
      two columns, one in a note's popover, a picture's Inspect Image chosen from a cell,
      Read All through a table, and VoiceOver in a language other than English
      ([#484](https://github.com/vocaro/EPUBLib/issues/484)).
  - **Not done.** A table inside a cell is read as its cell's words, as before. Headings
    inside a table are not found by the Headings rotor, as before.
  - **Not resolved.** On an iPhone simulator the rotor once went from Rows to Actions part
    of the way back up a column in continuous scroll. A physical iPad did not do it in
    seventy such moves, nor did the simulator in a later session of fifty-four. A cell
    offers its actions only once it is on screen, which may be why
    ([VoiceOver testing](voiceover-testing.md), the entry of 2026-10-12 on tables of data).
    And before fifty lines were listed past the screen
    ([#380](https://github.com/vocaro/EPUBLib/pull/380)), reading back into a table left
    the text on an iPad simulator in two sessions of three, where rows had not in two of
    two; with the fifty it did not in two of two. Why cells showed it and rows did not is
    not known, so a table's cells are to be taken as needing that list.
- **A table's text selected with VoiceOver.** On iPhone and iPad VoiceOver cannot select
  the reader's text as it does a text view's: a page's lines and a table's rows and cells
  are elements of the reader's own, and the text views that take touches over a table's
  cells are hidden from it. A table offers selection as an action instead, Select Table
  Text with a cell's words on a row and Select Cell Text on a cell of a table of data, and
  either selects the words the cell shows there. Rows and cells run the same code and
  differ in the names alone.
  - **Shown.** UIKit draws a text view's selection, and its handles, only while the view is
    first responder, which a touch in it makes it. A selection set in code was held,
    reported to the host and copied from, and nothing showed it: after the action the screen
    was as before, but for the selected words' ink, which the cell draws over the row's own
    and which looked a little heavier. A cell's text view now paints a selection it holds
    whenever UIKit is not drawing it, in UIKit's tint for selected text, and leaves it to
    UIKit while it is first responder. That shows every selection set in code and not this
    one alone: a located passage in a table, in each cell it runs through that cell's
    share, and a selection carried across a new layout. The reader takes no keyboard focus
    to show it, which would close a keyboard elsewhere in the window.
  - **Said.** VoiceOver says nothing of its own after an item's action, and it keeps what an
    item says and offers as it found them when its cursor came to the item: on an iPad its
    rotor went on offering Select Cell Text, and none of the three actions below, after the
    words were selected. The item of a cell whose words are selected has UIKit's selected
    trait, and after selecting or deselecting the reader posts a layout change that names
    the item. VoiceOver then reads the item again, "selected" before its words in
    VoiceOver's own language or without it, and takes the item's actions as they now are. A
    listener who comes back to the item later hears "selected" again. On a row it is the
    row that is read as selected, and its actions name the cell. The reader announces one
    thing itself, "Copied", because copying changes nothing a listener could tell: the word
    is the reader's and English, as "Separator" is at a rule, and is queued behind whatever
    VoiceOver is saying.
  - **What it is for.** A selection made by touch brings up the edit menu, with Copy and the
    host's selection action. No menu comes up for a selection set in code, and VoiceOver
    could not reach one in a view hidden from it. So the item whose cell holds selected
    words offers, where its select action stood, Deselect Table Text or Deselect Cell Text,
    Copy, and the host's selection action by its own title when the host gave one. Copy and
    the host's action are the edit menu's: the whole selection's text, and the host is told
    of the selection first if it has not settled. Deselect clears the reader's selection.
    It is the way back to turning pages by VoiceOver's scroll gesture, which selected text
    holds back as it does a swipe ("Input and accessibility"); Next Page and Previous Page
    in the rotor turn the page either way. A passage that runs through several cells of a
    row is one selection, and the row offers Copy and the host's action once.
  - **Not done.** A line outside a table offers no selection to VoiceOver, as before. On Mac
    a cell's text area is VoiceOver's own to select in and to use a selection from. A cell
    of a table of data offers Select Cell Text there and none of the three above, and
    does not offer it while its words are selected.
  - **In continuous scroll.** The sessions that first tried a cell of a table of data there
    on a device could not choose its action: in the section they opened the book at, the
    cells had no text views, so their items had no actions, with this change and without
    it. That was a fault of its own ("Tables" above;
    [#472](https://github.com/vocaro/EPUBLib/issues/472)). With it mended, in that section
    and with nothing scrolled, VoiceOver's rotor came to Actions on the cell, Select Cell
    Text was chosen and performed, the cell was read as selected with the tint behind its
    word, Copy and Use passage were offered, Use passage was performed and Deselect Cell
    Text took the selection away, as in pages
    ([VoiceOver testing](voiceover-testing.md), the entry of 2026-10-13 on a table's cells
    in continuous scroll). The unit tests perform the cell's actions in both flows.
- **Footnotes.** EPUB 3 `noteref` links show their note in a popover. Footnote `aside`s are
  hidden from the flow, whether or not anything refers to them; endnotes and other notes stay
  in place and also show in popovers.
  - A footnote hidden from the flow has nowhere else to be read, so a link may name it or
    any element inside it (its first paragraph, a later one, the text after its number) and
    the popover shows the whole note either way. A note inside such a footnote is hidden with
    it and is named the same way.
  - A note that stays in the flow is named by its own id and by the ids of its leading
    descendants (its first child, and that one's): a link may name its first paragraph or
    the number that opens it. A link to any other element inside it finds no note and
    navigates to that element, which can be read where it is. An endnotes list marked as one
    note is the case that matters: a reference to its seventeenth item goes to that item
    rather than opening the whole list from the top.
  - A table cell, row, row group, caption or column marked as a footnote
    (`role="doc-footnote"`) is not hidden on that account: unless a hidden footnote is
    around it, it is named as a note that stays in the flow. A table of two or more columns
    is drawn as a grid, which shows such a part in its place whatever its role, so a link to
    a later element inside it navigates to the table. A table of one column flows as text
    and does leave the part out; a link to a later element inside it then finds nothing to
    show. A footnote inside a cell is hidden as it is anywhere else.
  - An id inside a note nested in another names the nested note alone, and that note is left
    out of the outer note's popover. Two exceptions keep text from being lost: a nested note
    that no id names, which nothing could open, is part of the note around it; and a note
    with nothing of its own (two elements marking one note, or a wrapper around several)
    shows the notes nested in it, two levels of them. Notes nested deeper in notes that hold
    only one another are left out of the outer ones, so that such nesting cannot multiply the
    work of building a section.
  - An id used more than once names one note: one that carries it on its own element or a
    leading descendant before a hidden one that holds it elsewhere, and otherwise the first
    in the document.
  - A link without the `noteref` type acts as one when it names a note or one of its
    children, or anything inside a footnote hidden from the flow: it shows the note that id
    names, and navigates where the id names none (a later child of a note that stays in the
    flow). Deeper into a note that is in the flow it is an ordinary link and navigates.
    Inside a popover, a link to the note being shown is plain text.
  - A footnote `aside` with no id anywhere in it cannot be referred to and is not shown.
- **Flex and grid.** TextKit lays a section out as one column of paragraphs, so the reader
  aligns the flex and grid layouts that keep that column: a column flex container, a one-column
  grid and a row flex container with a single item
  ([Flex and grid alignment](#flex-and-grid-alignment)). That covers the patterns reflowable
  books use to centre a page: Standard Ebooks' full-page epigraphs and dedications, a title
  page centred by its `body`, a `place-items: center` grid. Items meant to sit side by side,
  wrap, reverse or be reordered stay blocks in reading order, with a `.disclosure`. Alignment is
  paragraph spacing and indents resolved at the live column size and never changes a section's
  characters, so CFIs, search, selection and highlights do not depend on it. The subset follows
  a survey of published stylesheets and this repository's fixtures; ten shipped Standard Ebooks
  titles were then rendered beside WebKit
  ([qualification](issue-20-flex-grid-alignment.md#shipped-books)).
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
  A legacy scrollbar appears once the text is longer than the window, which is after the
  column was first set, so the text is laid out again at the narrower width in the layout pass
  that follows, before the scroll view is first drawn.
  A shown position's line rests at the top of the visible area, or the top edge of an aligned
  box around it that fits there ([Flex and grid alignment](#flex-and-grid-alignment)). Far
  from what is laid out, TextKit 2 only estimates where text is, and the viewport's layout
  estimates differently, so a long jump checks which line the top shows: from text before the
  position, it lays out through the position in one run and scrolls to its now exact line;
  from text past it, it climbs above it first
  ([#13](https://github.com/vocaro/EPUBLib/issues/13)). A resize keeps the line holding the
  position (the last one shown, or the visible start once the person has scrolled), or that
  box's top edge, at the top, through any number of resizes in quick succession. A bounded
  correction loop verifies that the requested line actually reaches the visible top, allowing
  a visible line at the document's end when scrolling is clamped. If estimates cannot align
  it, or TextKit 2 lays that line over other text, the text is loaded afresh and the position
  shown again
  ([#12](https://github.com/vocaro/EPUBLib/issues/12), [#41](https://github.com/vocaro/EPUBLib/issues/41)).
  The scroll view tells of each scroll of such a move, and of a step of a page, when its
  offset changes, which is before the text is laid out there. What the reader mounts over the
  rows of a table on screen is therefore looked for again when the move has ended and the
  visible range is read, with the layout as it is drawn ("Tables" under Decisions;
  [#472](https://github.com/vocaro/EPUBLib/issues/472)).
  The visible range the reader reports runs from the first line mostly below the top of the
  visible area to the last mostly above its bottom. A rest is accepted within a point of the
  top, and the line above the rested one ends where it starts, so a sliver of that line can
  be on screen: a line less than half shown is not counted, and the position reported, which
  is also the visible start a resize keeps, is the one shown. Where the book has a float or
  positioned box anywhere the reader places every line itself, and the range is read from the
  lines' own frames: every line whose middle the visible area holds, wherever it is in the
  source (a float stands beside prose that follows it), and a line taller than the area that
  holds the area's middle, such as a long table row. When the area's middle is in a gap and
  that leaves no line, every line showing at all counts
  ([#305](https://github.com/vocaro/EPUBLib/issues/305)).
  An assistive technology's read can lay the whole text out behind the view: on Mac, and on
  iOS before the scroll view listed its own lines (below), VoiceOver and a UI test's
  snapshot ask where every paragraph is. That replaces the estimates the visible lines
  were placed by. UIKit goes on drawing the viewport's paragraphs where they were, over the
  place the finished layout gives other text, so the visible range is read from the paragraphs
  the viewport laid out, once it has been laid out again where the view stands. AppKit would
  draw the finished layout at the old offset, a chapter away, at the next scroll, so while the
  view has not moved since it was last read, the reader first scrolls by as much as the first
  visible line has moved. AppKit moves the view itself, by a fraction of a point, when it
  aligns the offset to the pixel grid at the scroll view's first display. A view within a point
  of where it was last read has not moved and nobody has scrolled it: its first line is still
  held, and the position kept is still the one shown, not the visible start
  ([#302](https://github.com/vocaro/EPUBLib/issues/302)).
  A layout the reader makes itself is not one behind the view, and it
  forgets where that line stood when it makes one: for new text, for a new column width, and
  when a new visible height (the window's, or the safe area's alone) resolves the book's
  boxes again. A box that takes its height from the visible area then moves its first line by
  the change in the space above it while its top edge rests where it did, and the step would
  scroll the box off its rest by as much
  ([#313](https://github.com/vocaro/EPUBLib/issues/313)). A book with no box to resolve is
  not laid out again for a new height, and its place is held as before.
  Every line below a box that follows the visible height moves with it, and its place is an
  estimate until it is laid out again. So once the boxes are resolved for a new height the
  reader rests the kept position again, as after a resize: the last one shown, or the visible
  start, read from the layout the new height replaces, once the person has scrolled or AppKit
  has moved the view by a point or more for a bar. A bar shown or hidden over a reader that
  runs under it (a host's `ignoresSafeArea()`) changes the visible height and not the
  reader's size. Without the rest an epigraph stood 81 points below the top on an iPhone
  while the navigation bar was hidden, and on the Mac, after a toolbar was shown over a
  full-size content view, the next layout drew another chapter, which the reader reported
  ([#338](https://github.com/vocaro/EPUBLib/issues/338)). On iOS the rest puts the line being
  read at the top of the taller area when a bar hides. UIKit reports the scrolling of an
  inset change once the change is over, the reader's rest included. Where that report finds
  the view as the rest left it, nobody has scrolled, and the position kept stays the one
  rested: the visible start cannot be read then, because UIKit has moved the view for the
  bar and the text under it is being laid out again. On an iPad a paragraph shown otherwise
  ended 38.6 points below the top once the bar had hidden twice. A book with no box to
  resolve is left as UIKit leaves it: when a bar hides, its text stays where it is on
  screen. On the Mac nothing lays the reader out when a toolbar changes the insets
  ([#162](https://github.com/vocaro/EPUBLib/issues/162)), so the boxes stay resolved for the
  old height until something else does: a change of appearance, or a resize.
  On Mac, VoiceOver enters a text view at its insertion point, which a read-only view does not
  draw and replaced text leaves at its end: the end of the book. New text starts with it at
  its first line, and the scroll view's is kept on the first line on screen. A move the reader
  makes itself (a shown position, a scroll step, rebuilt text) puts it there, as a page turn
  does for a column; after other scrolling it follows only while it is where the reader last
  put it, so one placed by a click or by VoiceOver, which scrolls the view as it reads, stays.
  A selection is never moved, and nothing is scrolled. Each such move also posts a layout
  change naming the text view: without it VoiceOver, back in a text it had left, returns to
  its own previous cursor and scrolls the view there. The window posts this one. That is not
  enough for a spread's columns (Pages, below) and was heard to be enough here
  ([#373](https://github.com/vocaro/EPUBLib/issues/373)).
  The layout change does not bring along a VoiceOver cursor that is inside the text: the
  insertion point's move does, and AppKit tells of that once. VoiceOver, inside the text and
  not yet moved in it, kept its cursor on its line for the one notice. It said the word
  before the insertion point and then, at the layout change or without one at its next
  command, scrolled the view back to its line by setting the scroll bar's value. The
  insertion point was still where the reader had put it, so it followed that scroll, and a
  step made straight after entering the text was undone, with a page key, with the text
  area's action and with the host's button alike. So after a move the reader makes itself
  the text view tells of the insertion point a second time, before the layout change, and
  VoiceOver goes there, as it does at the first notice once it has moved by line
  (macOS 27.0.1, [#464](https://github.com/vocaro/EPUBLib/issues/464)). Each such move costs
  an assistive client one notice that reports no change. Where the insertion point follows
  other scrolling it is told of once, as before. A page turn is left as it is: putting a
  page's text into a column already tells twice.
  On iOS, VoiceOver walks a text view's accessibility elements and, moving in from a control,
  takes the first. UIKit's own are every paragraph of the book, so it took the book's first
  paragraph and scrolled the reader back to it. The scroll view lists its lines instead, as a
  page column does, each with the links and attachments in it as elements of their own: the
  lines on screen, each by the part of it inside the area the insets leave, and the fifty
  lines after them. UIKit scrolls a line the cursor comes to until that area holds its frame
  and then 40 points further, and the first line on screen is often cut by the top inset, so
  its whole frame would move the reader as VoiceOver came in
  ([#301](https://github.com/vocaro/EPUBLib/issues/301)).
  The lines after the screen are there for the way VoiceOver moves. It asks UIKit for the
  items after the one its cursor is on, and for those before it, then moves through what it
  was given and asks again only when it has used them. As a rule it asks for two when its
  cursor lands on an item and for one more at each move. At its first move after the screen
  has changed under it, as when a menu closes, it asks for fifty each way: given the lines
  on screen alone, it read to the last of them and went on to the scroll bar and the host's
  next control. Fifty is what it asked for on iOS 27.0 and iPadOS 27.2, and the number
  listed is taken from that. While the cursor is on a line, fifty lines are listed each side
  of the screen and each side of the cursor's own line: VoiceOver moves on to them, UIKit
  scrolls the one it lands on into view, and it reads on through the book in either
  direction. Moving back into the text from below, VoiceOver takes the last line listed, so
  while its cursor is on one of the scroll view's own bars or on something below the reading
  area the list is the lines on screen alone, as it was before, and that is the last of
  them.
  VoiceOver is given that line as its cursor comes to the control below, with the scroll bar
  before it, and asks for the line above it only at its next move, the one to the bar.
  Between the two it has UIKit bring the bar into view as it would a line. The bar is as
  tall as the view, so the top inset cuts it, and the view goes back by that inset and 40
  points more, 88 points in all, wherever it has the room. The line VoiceOver holds is then
  below the screen. While the list was the screen alone that line was no longer listed,
  UIKit answered a question asked from it with the control before the text, and VoiceOver
  read the scroll bar, at best that one line, and then the host's control. So while the
  cursor is after the text the list still ends at the line it ended at when it was last
  made, with the lines between that line and the screen, as long as the view has gone back
  no further than one such move since. That holds each time the cursor goes to the bar. A
  longer move back is the person's or the reader's own, and after it, or a move forward past
  that line, the list ends at the last line on screen again
  ([#367](https://github.com/vocaro/EPUBLib/issues/367)).
  The cursor counts as on a line from the moment the line is told it has it until UIKit's
  focus notification names something that is not one of the view's lines, or VoiceOver is
  switched. A line left is told so, and a notification naming only it is posted, before the
  next line is told it has the cursor; when either was taken for the cursor leaving, the
  list shrank for a moment and VoiceOver stopped at a line it had reached above the screen.
  A line keeps its element while it is listed or under the cursor. Listing scrolls nothing
  and selects nothing, and lays out no more than the lines it lists
  ([#339](https://github.com/vocaro/EPUBLib/issues/339)).
  VoiceOver keeps what it was given, which leaves two things as they are. After a menu, a
  move back past the line it came in at, made before it has used the fifty, goes to the
  control before the text and not to the line above. A reader that is moved while VoiceOver
  holds lines it has not reached, by a scroll step with the cursor on a control, leaves it
  holding lines that are no longer listed: it says the first of them and returns to the
  control ([VoiceOver testing](voiceover-testing.md), "Harness pitfalls and current
  results").
  UIKit has no place among the lines for the scroll view's own scroll bar, and where it put
  the bar depended on how it came to it. Going through the scroll view it gave the bar after
  the last line listed: that is where VoiceOver met it, after the book's last line, and
  ahead of the last line on screen when it came in from below. Asked for the items each side
  of the bar it took the bar to stand before the first line. It keeps a scroll view's
  vertical bar among the views it calls the view's supplementary headers, and from a header
  the item after is the first element listed and the item before is whatever precedes the
  scroll view. So VoiceOver read on from the book's last line to the bar and then down the
  screen a second time from its first line, and went back from the bar to the control
  before the text. `index(ofAccessibilityElement:)` is not asked on that path, and no answer
  for the bar changes it.
  A bar hidden from assistive technology (`accessibilityElementsHidden`) is no such header,
  and UIKit gives it to nobody. So the scroll view hides its bar and lists an element of its
  own after its last line, in the bar's place. The element says what the bar says and
  adjusts as the bar adjusts, by asking the bar: its name, value and hint are UIKit's own,
  in the language UIKit has them in, and a swipe up or down on it still scrolls by a page.
  Being an element of the list like any line, it has the last line listed before it and
  whatever follows the reader after it, however VoiceOver comes to it, a touch on the bar
  included. The bar is found as the view of the scroll view's own that is an accessibility
  element, where the lines are no views. It is UIKit's view, and hiding it is all the reader
  does to it. Where no such view is found nothing is listed for it, and UIKit's bar is as it
  was.
  The element is placed where the bar is, less what the insets cover. UIKit scrolls the
  view until the area the insets leave holds the frame of the item the cursor goes to, and
  the bar's own frame is as tall as the view: that is why the view went back for the bar.
  With the element inside that area nothing moves as the cursor comes to it, from the text
  or from below, and the rule above that keeps a line listed through such a move is left
  for a bar the reader has not replaced. The element does not reach under the insets, so a
  touch on the bar's place there finds nothing, where it found the bar.
  Adjusting the element moves the view under VoiceOver's cursor. UIKit's bar takes the view
  a tenth of the way through the book at each swipe, at once, and tells VoiceOver only to
  draw its cursor again. VoiceOver holds the two lines it was given before the element when
  its cursor came there, and after the swipe those are screens away, listed no longer, and
  their elements are gone. Its own log in a simulator has what it then did. At its next move
  back it found the nearer of the two gone, asked again from the element and went to the
  last line on screen. To hold two items again it asked for one more from the further line,
  an element UIKit no longer knew, was given nothing, and noted that as the start of the
  list. Two lines up it met that mark, made the sound it makes at a screen's first item and
  stayed where it was at every further move back. Kept alive and unlisted, the two lines
  took it back to where the view had been and then to the control before the text. So
  after an adjustment the element posts a layout change that names itself. VoiceOver then
  drops everything it holds and asks again for the two items each side of the element,
  where its cursor stays, and it says nothing more than the bar's new value. A layout change
  that names nothing did the same in the simulator, and so did a screen change, with
  VoiceOver's sound for a new screen.
  A touch on the bar reached UIKit's bar, a view, before any line. The element is one among
  the lines the touch is tried against, and VoiceOver took a line that ended within a few
  points of the finger for the one touched: a paragraph's full lines run under the bar's
  place, which for accessibility is 30 points wide, ten times what is drawn. So a line on
  screen is listed by the part of it clear of the bar, as it is by the part inside the
  insets, and a touch anywhere on the bar's place finds the bar again
  ([#342](https://github.com/vocaro/EPUBLib/issues/342)).
  Two other ways were tried against a log of UIKit's requests and dropped
  ([VoiceOver testing](voiceover-testing.md), "Harness pitfalls and current results"): a
  place for the bar from `index(ofAccessibilityElement:)` alone, which UIKit does not ask
  for while the bar is a header, and the bar hidden only while VoiceOver's cursor was on
  it, which rested on the order of VoiceOver's questions and let a finger on the bar find
  the line under it.
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
  layout change is posted by the element that holds the columns, the canvas's nearest
  accessibility ancestor. Posted by the window, it left VoiceOver the text cursor it keeps in
  a column it has left: after a page turn VoiceOver came back to the column at the offset it
  had on the page before ([#337](https://github.com/vocaro/EPUBLib/issues/337)). The canvas
  is reached only through `EPUBReaderView`, and SwiftUI's hosting view makes a group of a
  window's content, so there is such an element in every host; were there none, the window
  would post and VoiceOver would keep its cursor. It was heard with the page controls beside
  the columns and in the window's toolbar. A VoiceOver cursor resting on that element itself
  moves into the left column when a spread is installed, as heard on page turns. Whether
  VoiceOver also gives up a cursor it keeps in another text area of the same group was not
  heard
  ([#373](https://github.com/vocaro/EPUBLib/issues/373)). The
  insertion point after a page's last character, and an offset an assistive client kept from
  a longer page, are on its last line.
  UIKit exposes visible line/run accessibility children with links, attachment labels and
  page actions, keeping hidden paragraph context out of its native text accessibility traversal.
  A heading is one such child however many lines it takes, with the header trait and its
  level; on Mac a column's rich text carries each heading's level and the column has a
  Headings rotor for the book (see "Input and accessibility").
  Decoration in a line is part of that line's element and adds nothing to it
  ("Alternative text" under Decisions).
  The canvas lists its columns to VoiceOver in source order; by their frames alone a column
  lowered by top spacing, or the first column of a right-to-left spread, would be read second.
  A column given to VoiceOver that way is searched inside before its own lines are taken: the
  text views over a table's cells, left visible, were read ahead of the page, which they are
  not in a text view VoiceOver finds as a subview. Nothing the reader mounts inside a text
  view is offered to assistive technology (see Tables).
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
requested float side.

A sized `inline-block` is set on its block's line. It starts where the text or the box before
it ends, a space after it where the source has white space between the two, and at the start
of the block's next line when the one it would be on is full. A box that opens its block takes
the block's `text-indent`, and a block that sets its lines from the right fills them from the
right. A run of such boxes is therefore a row that wraps as words do: the rows of asterisks
that mark an omission, an initial in a box of fixed width before the rest of its word. The
text after the run goes on from its last box, on the same line where that line has 48 points
left, and the block that follows starts below the run's last row. A box's own horizontal
margins, borders and padding stand between it and its neighbours. Each box is still a
paragraph of its own in the text, so characters, offsets and CFIs are what they were.

Three things about a row differ from a browser. Its boxes are aligned by their tops, not
their baselines, and prose beside a box taller than a line wraps beside it as beside a float.
A row starts at its line's start edge whatever the block's `text-align`. And lines fill in
turn, where a browser that honours `text-wrap: pretty` evens the rows out.

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

A text that holds any of these boxes has every one of its lines placed by the reader's text
container: one section in pages, the whole book in continuous scroll. TextKit then wraps a line
within its paragraph's indents but aligns and justifies it across the rectangle it was handed,
as if the paragraph had none. So the container hands TextKit paragraphs without indents and
gives each line a rectangle that already leaves out its paragraph's head, first-line and tail
indent. Margins, centring, right alignment, justification and list markers are then where they
are in a text without boxes, and a paragraph with its own margin beside a float starts at the
float's edge, its margin underneath it
([#63](https://github.com/vocaro/EPUBLib/issues/63),
[#150](https://github.com/vocaro/EPUBLib/issues/150)). TextKit breaks a justified paragraph's
lines a little differently where the container places them; their edges are the same.

The boxes' places are planned for the whole of that text, and TextKit lays out only what is
on screen: far into a book in continuous scroll it estimates the height of everything above,
so a line can be screens from where the plan has it. The container therefore wraps each
planned paragraph against the plan from where that paragraph's own first line is laid out,
and takes text past the plan's end to be below every box; a point is found the same way,
from the fragment laid out under it. Prose keeps clear of the boxes beside it wherever the
book is opened, and is not pushed aside by boxes that are nowhere near. A line that starts
exactly where a box ends is clear of it
([#147](https://github.com/vocaro/EPUBLib/issues/147)).

A `.disclosure` explains that box layouts may be simplified. Sticky positioning, negative
relative vertical offsets, arbitrary overlap and `z-index`, and page-pinned or repeating fixed
boxes are outside the supported subset. Conventional positioned, visually hidden accessibility
labels are not drawn, so that the page shows no duplicate text, and are kept for assistive
technology as a browser keeps them (below). The offscreen heuristic recognizes
top/left offsets of -1,000 CSS pixels or less as the book wrote them, an `em` or a `rem`
counting as 16 pixels (`-62.5em`), including calculations in those units alone. That is the em
media queries are given, not the element's font size or the reader's: `left: -999em`, where
Standard Ebooks parks the heading of a title page beside an image of the same words, hides it
at every text size, and `-62em` hides nothing at any, though it computes to more than 1,000
points from 17 points up. Percentage and viewport offsets, offsets in a face's own metrics
(`ex`, `ch`) and calculations holding one remain visible unless explicitly clipped or hidden:
a percentage is of a containing block of any width, and the viewport offset stylesheets use,
`-100vw`, is the edge of the screen and not beyond it. Reading the offset as written keeps
rendered text and saved range offsets identical across reader font-size changes. General clipping,
arbitrary offscreen geometry and transforms are outside this subset.
Fixed-layout publications still reflow and report their existing fixed-layout disclosure; this
subset does not implement fixed-page geometry.

A label hidden in one of those ways (parked off screen, or clipped with a zero-area
`clip: rect(...)` or `clip-path: inset(50%)`) is in the text as one character for each block
of its words. The character takes no room and draws nothing. VoiceOver reads the words for
it where the box stands in the document; a selection or a copy that spans it carries them,
and an occurrence found in them is a search result at that place. It stands in a line that
holds something, because a text view's own accessibility reads such lines: with UIKit's
paragraph elements, which continuous scroll on iOS had then and a note's popover has still,
VoiceOver skipped a label given a line of no height to itself. Inside a line
it stands where the box does, and the line's white space collapses across it as across any
box taken out of the flow. Between blocks it opens the line of the content that follows, in
whatever block that is, so it is read just before that content and on its page; a block
image it precedes is still set as alone on its line. Where the content that follows must
open its own paragraph (a table's rows, a float, a positioned box) the label ends the
paragraph before instead, and a label after a section's last content ends that. Only a
section that opens with labels before such content, or holds nothing else, gives them a
paragraph of their own: a line of no height against the paragraph after it, which is spaced
and indented as the section's first. In continuous scroll that line is inside the visible
area whenever the line after it is at the top, and it is never the first or last line on
screen for the place the reader reports: a title page holding nothing else would be the
place reported for the start of the section after it. VoiceOver still starts at such a line
while it stands at the top, so the labels are heard before what they stand over: on the Mac
the insertion point goes on it, and on iOS the scroll view lists it before the first line on
screen, at a place inside the reading area. A reader sent to such a line rests it at the
top with the line after it. The page is laid out exactly as it is without the
label. What a label says is its text with white space collapsed and the alternative text of
images and formulas in it, without the parts that `display: none`, `visibility: hidden` or
`aria-hidden="true"` hide and without ruby annotations. It keeps the language it declares
and, when it is a link, the link. An id on or inside it names the label, and a saved
position inside it is the label. A box that `visibility: hidden` or `aria-hidden="true"`
hides, and one with no words, is left out altogether, for assistive technology too.

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
  of it. Heights follow the visible area when it changes. A position in an aligned box that
  fits the visible area rests the box's top edge at the top of that area, not the position's
  line, so the box is shown as composed: a navigation to its section, a restored location or a
  search result inside it, and the end of its section, where turning back to its page in
  paging leaves the position before a change to continuous scroll. The box is the run of
  consecutive paragraphs tagged with the same supported container that has a `height` or
  `min-height`, the outermost one that fits where they nest, and it fits when its top edge is
  no further from the bottom of its last line than the visible area is tall. A position in a
  taller box rests its own line, which the box's top edge could put off screen. A box that opens
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
- VoiceOver: the text offers the page turn itself, and reads in order from the text views.
  On iPhone and iPad each line of a page offers Next Page and Previous Page, and the
  reader's SwiftUI surface has a page-turn `accessibilityScrollAction`. On Mac each text
  area offers the pair, named for the flow (the next item). The surface names no action on
  any platform. UIKit gives VoiceOver the actions of everything that holds an
  element along with the element's own, and SwiftUI puts a view's named actions on the
  canvas, which holds every line: with the two named there, VoiceOver said "Actions
  available" after every line of continuous scroll and offered to turn a page that flow does
  not have, and on a page it offered the pair twice. A text view that lists its lines offers
  no action for the same reason. With UIKit's actions for the links of its
  text and the reader's for its pictures there, a plain line offered the picture beside it,
  and a line of continuous scroll the links of the whole book. So a line offers what
  is in it: on a page Next Page and Previous Page; on a picture's own line Inspect Image; on
  a table's row its cells' actions; and on a line of plain text or a link in continuous
  scroll nothing, after which VoiceOver says no "Actions available". A page turn chosen in
  the rotor is a command, and a note's popover keeps UIKit's own actions ("What an item
  offers VoiceOver" under Decisions). In continuous scroll it
  starts at the first line on screen: on Mac at the insertion point kept there, on iOS at the
  first of the lines the scroll view lists (see "Continuous scroll" under Layout). Text that
  a book hides from the page and keeps for assistive technology is read where it stands, as
  text ([hidden labels](#floats-and-positioned-boxes)). An image is read by its `alt`, one
  with an empty `alt` is passed over, and one with none is announced as an image without a
  name ("Alternative text" under Decisions). At a rule VoiceOver says "Separator", from a
  stop of its own on iPhone and iPad and from an element in the text on Mac ("Rules" under
  Decisions). On Mac all of this holds inside a table cell too, whose text VoiceOver reads
  once it interacts with the cell's row and then with the cell.
- A page turned under VoiceOver's cursor, on iPhone and iPad. VoiceOver keeps its cursor on
  the item it was given, and a page's lines are items of that page: turn the page and the
  cursor is on a line that is no longer shown. After a line's Next Page it stayed drawn
  where the line had stood, and the next move went by the old item: to the book's title
  under the page, or to a line somewhere down the new page, then the line before it, then
  that line again.
  So a page column knows which of its lines the cursor is on. UIKit tells a line when the
  cursor comes to it and names every item the cursor goes to, and whatever is not a line of
  that column ends it. When a page is shown and the cursor's line is no longer on it, the
  item under the cursor becomes the line that holds the position shown: the first line of
  the page after a page turn, in the left-hand page of a spread, and the line of a link's
  target after a link. It takes that line's place in its column's list and everything a
  new item for the line would have, its words, where it stands, what it is and what it
  offers, and keeps nothing of the line it was
  (`ReaderTextView.accessibilityCursorStands(for:)`): a link that is now a line of words
  goes nowhere, and a line that is now a picture offers the picture's inspection. The
  canvas then posts a layout change with that item
  (`ReaderCanvasView.accessibilityCursorFollowsThePage`). VoiceOver reads the line and
  draws its cursor on it, so reading goes on from the top of the page, and what was chosen
  in its rotor still stands, since its cursor has not changed item: with Next Page chosen,
  each double tap after the first turns another page (iPadOS 27.2). This is so whoever
  turned the page: a line's own action, VoiceOver's scroll, a key, or the host while the
  cursor is in the text.
  The other ways were tried on the same iPad. Given a new item for the line, VoiceOver
  read it the same and its rotor was back at its default there, so each page took a flick
  down to Next Page before its double tap. Told of the change with no item named, the
  item under its cursor being the new line already, it kept the rotor and drew its cursor
  on the line, and said nothing. With the line's words announced as well it said them
  and kept the rotor, but an announcement is the reader's string and not the item read:
  of an item VoiceOver also says what it is, a heading, a link or an image.
  A data table's cell is the exception, from it or to it. A cell is an item of another
  kind, inside its table's, which no line's item can become, so there VoiceOver is given
  the new item and its rotor starts again. Three cursors are left alone.
  One that is not in the text stays where it is: after the host's Next Page button
  VoiceOver is still on the button, and moving into the text from there met the new page's
  first line before this and does now. One whose line is still on the page keeps it, as
  when the same page is shown again. And a move by heading that turns the page posts
  nothing, since VoiceOver goes to the item the rotor gives it. VoiceOver's scroll, three
  fingers swiped, announces "Page N" as before, and the cursor is sent after the
  announcement. Posted in that order after a page turned under a simulator's cursor,
  VoiceOver said "Page 2" and then the line, with a new item for the line and with the
  cursor's own item made the line; in the other order, tried with a new item, it said the
  line alone (iOS 27.0). No session has performed the gesture itself
  ([#70](https://github.com/vocaro/EPUBLib/issues/70)): XCTest has no three-finger swipe,
  so what VoiceOver does of its own accord after a scroll has not been heard. An item kept
  from an earlier list stands for its line by the line's place
  in the book (`index(ofAccessibilityElement:)`). It was matched by its characters as the
  view counts them, and a page column counts from its page's first: a line of the page
  before then stood for whichever line of the page shown had the same ones.
- VoiceOver on Mac: each text area offers the page turn as actions of its own
  (`NSAccessibilityCustomAction`), Next Page and Previous Page in pages and Scroll Forward
  and Scroll Backward in continuous scroll. Those are the names `EPUBReaderControls` gives
  the host's buttons, and `EPUBPageAction.label(in:)` is behind both. VoiceOver's Actions
  menu (Control-Option-Command-Space) holds the actions of the item under its cursor, and
  on a column and at every line and word inside it that item is the text area. The menu
  says "Actions menu 3 items" and lists Previous Page, show menu and Next Page, or Scroll
  Backward, show menu and Scroll Forward, and the names follow a change of flow made with
  the reader open (macOS 27.0.1). Choosing one turns the spread, or scrolls one viewport
  less a line, and VoiceOver's cursor is then on the first line of the new page or screen.
  It is a turn asked for by name, as a line's is on iPhone and iPad
  (`turnPageFromAccessibility`): selected text does not hold it back, it fails at either
  end of the book, and `EPUBPageControls.hostOnly`, which takes the keys away, leaves it.
  The cost is a phrase. VoiceOver says "actions available" before its hint for a text
  area ("actions available You are currently on a text area, inside of a group…"), once
  after it arrives at a column or enters its text, and not after a line or a word it moves
  to. The group that holds the columns lists in its own menu what each of its items
  offers, so that menu gains the pair once for each column.
  A page turn made from the text, by a key or by an action, brings keyboard focus to the
  first column of the spread when it was in another (`focusFirstColumnAfterTurn`).
  VoiceOver stays in the column it is in when a spread turns: after a turn made in the
  second column it was on the first line of the new second column, and the new first
  column was passed over. It follows keyboard focus to the first column and reads it from
  its first word, with its cursor on the column and no longer inside the text.
  The window gives an assistive client the hosting view's group and, under it, each
  column's text area, or in continuous scroll a scroll area that holds the one text area.
  `ReaderCanvasView`, the view the surface wraps, is not an accessibility element and is
  not among them. A named action or a scroll action that SwiftUI is given for that view
  reached none of them, so the surface has neither on Mac. The scroll area has AppKit's
  four scrolls by page, which are the only scroll actions in either flow.
  Two limits. An item of the text that takes VoiceOver's cursor by itself keeps its own
  menu, without the pair: a link reached with Find Next Link offers "press". And the
  accessibility API reports a failure for the action in continuous scroll (-25200), though
  the view scrolls and VoiceOver's own choosing works: the reader's handler returns true
  there as in pages, where the API reports success, and the failure is AppKit's answer,
  for a reason not found ([#465](https://github.com/vocaro/EPUBLib/issues/465)).
  A step in continuous scroll made straight after VoiceOver enters the text, before it has
  moved in it, holds as any other, with the action and with a page key: the reader tells
  of the insertion point twice ("Continuous scroll" under Layout). Told once, VoiceOver
  went back to the line it had entered at and took the view with it.
  [VoiceOver testing](voiceover-testing.md#harness-pitfalls-and-current-results) has the
  sessions.
- Headings: `h1` to `h6`, and any element with `role="heading"`, are headings to VoiceOver,
  at the element's level or its `aria-level` from 1 to 6. `role="heading"` alone is level 2,
  an `aria-level` past 6 leaves a heading with no level, and a heading element whose role is
  `presentation` or `none` is laid out as a heading and is none to a listener. The builder
  marks a heading's text, from its first character to its last, with one `ReaderHeading` for
  each heading element (`.readerHeading`): two headings one after the other stay two, a
  heading of several blocks or lines stays one, and one set run-in with its paragraph is its
  own words alone. A heading hidden from the page and kept for assistive technology is a
  heading too, and hidden words inside a shown heading are part of it
  ([hidden labels](#floats-and-positioned-boxes)). The mark changes no character, no span of
  the text map, no anchor and no line of any page.
  On iPhone and iPad a heading is one accessibility element with the header trait and its
  level, whole however many lines it takes; a link or an image in it is still its own
  element, a heading too. A page gives the part of a heading it shows. In continuous scroll
  a heading keeps one element whichever of its lines are on screen, listed by the part of it
  in the reading area. Its label is its words, without the break that ends its paragraph:
  VoiceOver then says "Heading" in the same phrase. It was not heard to say the level it is
  given (iOS 27). VoiceOver's own Headings rotor moves among the elements it is given, and
  a page or a screen holds few of a book's headings, so each text view gives VoiceOver that
  rotor itself (`UIAccessibilityCustomRotor`, system type heading): a move by heading goes
  to the book's next or previous heading, one stop for a heading in several elements, on
  the page or the screen when it is there and otherwise wherever it is, which the reader
  turns or scrolls to as it does for a link. The search goes by an item's place in the
  book, which each element keeps: VoiceOver asks twice for one move, the second time from
  the same item though the first answer may have turned the page it was on, and says
  "Heading not found" unless both answers are the same. A section that is not built yet
  ends the search, and so does the end of the book. A rotor is not an action: VoiceOver says
  "Actions available" of a line for the actions the line is offered, with the rotor and
  without it.
  On Mac a text area has no elements for its lines, so the heading's characters carry its
  level (`AXHeadingLevel`) in the rich text an assistive client reads, and each text view
  gives VoiceOver a Headings rotor (`NSAccessibilityCustomRotor`). VoiceOver's move to the
  next heading goes by it, and its rotor lists the headings, each by its words and level:
  VoiceOver reads a heading's words on moving to it and was not heard to say the level it
  is given in the text (macOS 27.0.1), so the list is where a listener hears it. The rotor
  holds the whole book's headings in both flows. The scroll view's are characters of its
  own text. A page column answers through the canvas, by places in the book
  (`ReaderCanvasView.headingRotorResult`): a heading that begins on the page or spread is
  given as its column and its characters there, and any other as a loading token that
  names its section and offset. VoiceOver asks the rotor's loading delegate
  (`NSAccessibilityElementLoading`) for a token's element, and then for its range, only
  when it moves to that heading, by its move to the next heading or by a choice from the
  rotor's list. The reader turns to the heading's page then, as it does for a link, and
  gives the column that shows it. A search shows nothing, since VoiceOver walks the whole
  list when its rotor opens, and neither does the request for a range. After the turn
  VoiceOver reads the page from its top, as after any page turn, with its cursor on the
  heading. The list takes in the sections page turns reach and the one on screen, and a
  section that is not built yet ends it on that side: in the seconds after a book opens
  it holds the sections built so far around the page. A heading that begins on an earlier
  page and ends on this one is listed once, where it begins.
  The search is written to how VoiceOver was seen to ask (macOS 27.0.1). It lists a
  rotor's items by asking for the one after an item that is nowhere (no element, no token,
  the first character and none of it), and then for the one after each item it is given: a
  column and characters, or a token with no element. Taken as a place in the text, nowhere
  passed over a heading that opens the text. With its cursor resting on a column, as after
  a page turn, it asks from that column at the first character and none of it, which is
  the top of that page: a heading that opens the page is the next one, and going back the
  search stands after the page's last character. Taken for nowhere, that item sent a move
  to the next heading from a page in the middle of a book back to the book's first. A
  token's result also carries a range, the heading's characters in its section. VoiceOver
  asks nothing about it, but calls the row by its label only when there is one: without
  it the list showed each label and VoiceOver read every such row out as the column's own
  text.
  With VoiceOver's cursor on a link the move to the next heading goes another way
  ([#431](https://github.com/vocaro/EPUBLib/issues/431),
  [#454](https://github.com/vocaro/EPUBLib/issues/454)). A link is an element of its own
  on Mac, a child of the text and no place in it. From there VoiceOver asks no rotor: it
  looks through the text's children for an element with the heading role after the link,
  and past the last it begins again with the first, as Find Next Link does (macOS 27.0.1).
  With no heading among the children it said "Heading not found", though headings
  followed. So each heading has an element among the text's children too
  (`ReaderHeadingAccessibilityElement`), where it stands among the links: AppKit's heading
  role, the heading's words as its label and its level as its value. VoiceOver says both,
  "heading level 2 Link target reached", where the move from the text says the words
  alone.
  The children hold the headings on screen or on the page and, after them, the book's next
  heading, so that the move from the last link there has it to go to. VoiceOver takes an
  element for a place only when it is among the children of its text, so that heading is a
  child before VoiceOver looks for it. In continuous scroll it is the next one below the
  screen, a heading of the view's own text. In paging it is on a later page: an element at
  the foot of the column, a point high, called by the heading's words
  (`ReaderCanvasView.headingAfterPage`), and the last of the column's children. A chapter
  that is not built yet ends the list, as it ends the rotor's.
  VoiceOver focuses the element it moves to, while its cursor and the keyboard focus go
  together (cursor tracking, which is on until a listener turns it off), and that is all it
  tells the reader of the move. It gives the focus to an element that says whether it has
  it: one that only took it was never given it. The reader then does three things
  (`ReaderTextView.showHeading`). It puts the insertion point on the heading. VoiceOver's
  cursor is on the element and not in the text, and its next move by word or by line starts
  from the insertion point, which was wherever VoiceOver had last read, or the first line on
  screen: with it on the heading, one move right says the heading's first word and reading
  goes on from there, and the next move by heading goes on by the rotor from the heading.
  In continuous scroll it shows a heading that has no character on screen, as it shows a
  link's target, where VoiceOver would scroll to the element by the scroll bar, which the
  reader takes for any other scroll. And in paging it turns to the page of a heading that
  is on a later one, as it does when VoiceOver loads a heading the rotor gave. The element
  VoiceOver is on becomes the heading's own in the column that then shows it, one of that
  column's children with its place there: an element that left the children would leave
  VoiceOver's cursor on the column. VoiceOver says the heading, then the first words it
  says after any page turn, then the heading again.
  What is left as it was (macOS 27.0.1):
  - Past the book's last heading the move from a link begins again with the first heading
    among the children, which is the first on screen or on the page, and says "Heading not
    found" where they hold none. From the last heading's own element, with no other on
    screen, VoiceOver says "Last heading" and stays.
  - With cursor tracking off VoiceOver focuses nothing. In continuous scroll it scrolls to
    the heading itself, and reading on starts from where it had last read. In paging it
    says the heading that is on a later page and the page stays; one move right puts it
    back in the page's text, where the move by heading goes by the rotor and turns.
  - In a spread the heading can be in the other column than the one VoiceOver was in.
    VoiceOver's cursor is on its element there, and its text cursor stays in the text it
    was in. From the left-hand column to a heading in the right-hand one, reading on by
    word or by line starts at the top of the spread, a column before the heading. From the
    right-hand column to a heading on a spread that shows one page, `line` said nothing.
    The move by heading goes on from the heading's element all the same, and from the text
    it reaches the heading by the rotor with VoiceOver's text cursor on it. Given the
    keyboard focus, the column that shows the heading took VoiceOver's cursor as an item it
    was not interacting with: `line` read the heading and one move right left the text for
    the next control.
  The rotor's Headings list is the same from a link. VoiceOver asks the text for its
  rotors as well as the link, which has none, and having walked the list it asks the
  search once more, from the link's element at the first character and none of it. The
  search takes an element that is no place in the text as it takes a cursor at rest: the
  top of the page in a column, nowhere in the scroll view. Answered with no item while a
  column's rotor still held its page alone, the list opened with no row chosen and Return
  did nothing; that was heard once.
  Two other ways were heard and left out. Given the text's rotors, a link's element was
  asked for them when the rotor opened and never for the move by heading. The other is
  VoiceOver's search for elements (`AXUIElementsForSearchPredicate`, which AppKit has named
  since macOS 26, served through the old attribute methods), which could end the move at
  the book's last heading in place of beginning again:
  - A link's or a heading's element that offers it is asked in place of being looked at,
    with no start at all, and each child after it in turn, then the first ones. None can
    tell whether VoiceOver's cursor is on it, so the first children answer for what follows
    them and the move begins again all the same.
  - A text area that offers it is asked where VoiceOver's own walk of the children finds
    nothing, with the element under its cursor as the start, and answered with nothing
    VoiceOver says "Heading not found", or "Last heading" from a heading. But it is then
    asked for every kind of item VoiceOver looks for, from the text as well, and can answer
    with elements alone. VoiceOver's moves to the next change of font or of style, and to
    the next plain text, which find the place in a text that offers no search, left the
    text for the window's other items. A search for bold text from a page, and one for a
    picture from a control outside the text, were asked without end, thousands of times
    in half a minute, until VoiceOver said the reader was not responding, and after the
    second it could not be turned off. Find Next Link was asked too: left unanswered it
    said "Link not found" or asked without end, and past the last link it said "Last link"
    and stayed where it begins again today.
  So no text and no element of the reader offers the search, and the move from a link
  past the last heading begins again.
  Not marked for VoiceOver: a heading inside a table, whose cells are read as cells, and on
  iPhone and iPad a heading inside a note's popover, which keeps UIKit's own elements.
- Selection: native selection UI with the host's `EPUBSelectionAction` in the edit or context
  menu, no length cap. Dragging can extend a selection across a two-column spread in either
  reading direction. A located passage is selected in every visible column and remains
  selected on its continuation pages. When part is offscreen, the reader shows a continuation
  indicator with Previous/Next controls for following the selected passage. Direct page input
  is suppressed while a selection is active; host commands and these continuation controls
  remain available. `.selectionChanged` settles 150 ms after the selection stops changing.
  With VoiceOver on iPhone and iPad a table's text is selected by an action of its row or
  cell. The cell draws it, VoiceOver reads the item as selected, and the item then offers
  Copy and the host's action itself ("A table's text selected with VoiceOver" under
  Decisions).

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
archives and are refused by the parser, as before). Those books belong to that project, not
to EPUBLib: this is the record of one run, and the corpora for verifying changes are the
public ones ([corpus runs](testing.md#corpus-runs)).

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
  labels hidden with zero-area `clip: rect(...)`, `clip-path: inset(50%)` or
  top/left offsets of -1,000 CSS pixels or less (16 to the `em` or `rem`, so `-62.5em`) are
  not drawn and are read by VoiceOver where they stand; percentage and viewport
  offsets remain visible unless explicitly hidden or clipped. A box parked that far to the
  left that reaches back on screen, with a `right` offset or a great width, is hidden with
  the rest. A hidden heading is read as plain text, as a shown one is. General clipping and arbitrary offscreen
  geometry are unsupported. Unsized inline-blocks remain inline. Sized ones in a row are
  aligned by their tops and from their line's start edge, not by `vertical-align` or the
  block's `text-align`. Ordinary percentage margins,
  padding and text indents resolve against the live containing content width, including
  constrained flow-box ancestors, and recalculate at resize. Mixed-unit CSS calculations
  and `min`/`max`/`clamp` branch selection still use the nominal media-query viewport;
  viewport-relative font sizes and media queries remain based on that nominal viewport.
- Whole-table bookmarks and visible row ranges retain attachment granularity. A resize or
  flow change without a precise cell endpoint returns a continued row to its source position
  rather than preserving its particular visual fragment. A table's captions, and the cells
  past its bounds that follow it, are located as the table, not by their characters. A table
  that holds only cells written outside rows flows as text, a paragraph for each cell, rather
  than as the one anonymous row CSS gives them.
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
  Two amplifications the byte and node limits do not catch are bounded too, and an SVG past
  either shows its fallback text with the `svg` disclosure, as one past the node, depth or
  byte limits does. One `<text>` run, whose layout is super-linear in its length, is held to
  20,000 characters, and an SVG that holds a `<tref>`, which SVG 2 removed and which draws
  text from elsewhere in the document into a run, is refused. Markers, whose content the
  renderer builds again at every vertex they are drawn at, are counted in the forms diagrams
  use and refused in any other, rather than modelled.
  - Supported: `marker-start`, `marker-mid` and `marker-end` as attributes, or those and
    `marker` in a `style` attribute, on a shape or on a group around it, a `<use>` of it
    included; and a `<marker>` that holds only `path`, `line`, `polyline`, `polygon`, `rect`,
    `circle` and `ellipse`, with `<g>`, `<title>` and `<desc>`, painted with colors,
    `currentColor`, `context-fill` or `context-stroke`. That is how Inkscape, Mermaid, D3 and
    OmniGraffle write arrowheads and data points.
  - Counted: each time a marker is drawn, one for each element in it, and one more for every
    64 bytes of attributes an element has or inherits; a `marker-mid` is drawn at every
    vertex, a vertex being a number in the path data or points. A dash array of 64 bytes or
    more on the shape that bears the marker, and a stylesheet declaration as long, add to each.
    A drawing tool's arrowhead counts ten to twenty with its attributes. An SVG may reach
    100,000: some thousands of arrowheads, or of data points on a line.
  - Refused: a `<style>` sheet that holds a `url(#…)` in an SVG that has a `<marker>`, so a
    marker given by a class (`.edge { marker-end: url(#arrow) }`) is to be given by attribute
    instead; a marker property, or a `fill` or `stroke` that names a gradient, on a
    `<marker>` or on an element that contains one; a `url(…)`, an `href` or a `filter` inside
    a `<marker>`, and any other element there, such as `<use>`, `<image>`, `<text>` or a
    nested `<svg>`; a shape that bears a marker inside a `<mask>`; `marker-mid` on a path
    with an elliptical arc, or on a `circle`, `ellipse` or rounded `rect` whose radius is not
    a plain number, and either of those inside a `<marker>`; and a marker that uses
    `context-fill` or `context-stroke` on a shape whose own fill or stroke is a gradient.

  The renderer draws no marker on a shape inside a `<clipPath>`, so none is counted there.

  References between a drawing's elements are held to what the renderer can follow, and an
  SVG past any of these shows its fallback text with the `svg` disclosure too. The renderer
  follows a `mask`, a `clip-path` and a `<use>` by calling itself, on a stack whose end is
  the end of the process, and it guards against loops only in part. So references count
  toward the depth limit: a chain of nesting, `<use>`, `mask` and `clip-path` may be 64
  levels deep in all, a mask or clip path one level and its content the next, which lets 31
  masks in a chain through their content draw and refuses 32. More than two masks or clip
  paths that lead back to each other are refused: the renderer unlinks a loop of one and of
  two, which still draw, and misses a longer one. A gradient whose `href` leads into a loop
  of two or more gradients that it is not one of is refused, since the renderer would walk
  that loop for ever; a loop that nothing outside it leads into, and a gradient that names
  itself, end and still draw. A linear gradient whose `spreadMethod` is `reflect` or
  `repeat` is refused as well, whether it states the spread or takes it through `href` from
  another gradient, linear or radial. The renderer panics on such a gradient that has no
  length, when the average of its stops rounds past one, and telling which gradients have no
  length would mean reproducing the renderer's resolution of lengths: units, percentages,
  coordinates taken through `href`. So the spread alone decides. A linear gradient that
  repeats or reflects shows fallback text at any length, painted or not, and so does one
  whose `href` can reach a gradient that does, even past one that pads. A linear gradient
  that pads, or whose `spreadMethod` is absent or not a value the renderer knows, still
  draws, and so does a radial gradient of any spread. A reference is found wherever the
  renderer takes one from: an attribute, a `style` attribute, a rule of a stylesheet in the
  drawing, read as the renderer's own CSS parser reads it, or `inherit`, behind a marker
  included. More is assumed than the renderer follows where telling the two apart would
  mean doing its work: a rule is taken to apply to every element its last compound selector
  could match, a declaration counts even where another overrides it, and an `id` that
  several elements share names them all.

  The renderer also copies or re-reads some shared and inherited values once per painted shape,
  which neither the byte nor the node limit catches, so a file of a few hundred kilobytes can make
  it allocate hundreds of megabytes or parse for most of a minute. Each is charged per shape, against
  a ceiling set from measurement (the worst passing drawing costs the renderer on the order of what
  the other limits allow); each shape is charged the most that it or any ancestor, through every
  `<use>` that draws it, could ask for, so the count never falls below what the renderer does. A
  stylesheet's declarations are the exception: they are charged only in part, as their entry below
  says, and what they cost the renderer is not bounded. The screen's own work is counted too, in
  steps for the gradients it looks up, the elements it walks and the CSS it reads, and a drawing
  that spends its budget of steps shows its fallback text with the same disclosure: that limits the
  screen's own reading and not what the renderer does, and it does not bound all of the screen's
  work either, since a visit to an element is one step though it goes over every child the element
  has, and what bounds that is the limit on expanded local references; the one kind of drawing
  within the other limits known to spend the budget is built to, a `<style>` inside another, whose
  CSS is read again for each `<style>` it stands in (as measured with a sheet built to be read
  eight times, megabytes of CSS two `<style>` elements deep where the drawing also holds a `<use>`
  tree to walk and, without one, megabytes three deep or some 140 KB sixty deep).
  - A gradient's stops are copied into a fresh paint server for every shape it paints by `fill` or
    `stroke`, directly or inherited, in an attribute or a `style` declaration, through a gradient
    `href` chain, and through each `<use>`; each shape is charged the stops its fill names and those
    its stroke names. A gradient with no stops of its own is charged those its `href` chain leads to,
    however long the chain. Where the chain meets an `id` that several gradients share, the renderer
    takes the last element that has the `id`: it goes on from that one when it is a gradient, and
    paints nothing when it is not. Which is last is not worked out, and the gradient is charged the
    most stops any gradient in the drawing has. A stylesheet that paints with a gradient is taken to
    reach every shape.
  - A stroke's dash array is stored for every stroked shape that has or inherits one; each shape is
    charged its dash-array bytes, an upper bound on its entries.
  - Each inherited presentation value the renderer re-parses for every shape — the `fill` and
    `stroke` paint, the numbers (`stroke-width`, the opacities, `stroke-miterlimit`, offsets) and the
    keyword enumerations alike — is charged its bytes over 64, summed down the inheritance chain. A
    `style` value is counted with its white space trimmed, as the renderer trims it before storing.
  - A stylesheet's declarations are charged only in part, and what storing them costs the renderer
    is not bounded (#282); a gradient a stylesheet paints with is still charged in full, as the
    first entry says. The renderer stores every presentation declaration of a rule on every element
    the rule matches, groups and `<use>` elements included, so that cost goes as declarations times
    matched elements. Each painted shape, and each character of a text run, is charged one value,
    the longest presentation declaration's of any `<style>`, so that a single very long value cannot
    be copied onto thousands of shapes for free. A rule of many declarations is charged as a rule of
    one, and what a rule costs on the groups and `<use>` elements it matches is not charged, so a
    drawing of a few kilobytes can still pass and cost the renderer hundreds of megabytes. An
    at-rule such as `@font-face` is not counted: the renderer never applies it to an element, so an
    embedded font a stylesheet carries in a `src: url(data:…)` does not count against a drawing, and
    ordinary Illustrator, Inkscape, Figma and chart-library output that embeds a font renders as
    before. A stylesheet that is stripped whole before rendering is not counted on either screening.
  - A `<text>` run clones its resolved style for every span (at most one span per character): the
    gradient stops its fill and stroke name, into the span and each of three text decorations; the
    dash array, into the span's stroke and, when the run is decorated, each decoration stroke; the
    font family; and the `font-variation-settings`, the worst per-span copy, a list held per span and
    again in the glyph cache. A long inherited value re-parses to a small resolved value the span
    clones cheaply, so it is not charged per character. A gradient with a handful of stops on
    thousands of shapes, dashed strokes on a large chart, a short variable-font axis list, and long
    but ordinary values (a path's `d`, a `points` list, a `transform`, an embedded `data:` image, a
    normal `font-family`) stay well within the ceiling. A `<switch>` draws one alternative but every
    one is charged, a sound over-charge. A mask's content is charged once, not once per element that
    references the mask (#220 covers that multiplication).

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
  sessions. Headings were read and moved between on 2026-10-12 on a physical iPad in both
  flows, on the hosted Mac and in the simulator lane; on a physical iPhone the heading was
  read, and no move by heading was made, because XCTest's gesture did not turn VoiceOver's
  rotor there. In paging on Mac the rotor's list and VoiceOver's move to the next heading
  were heard to go through the whole book the same day, on the hosted Mac
  ([VoiceOver testing](voiceover-testing.md)). With VoiceOver's cursor on a link on Mac, the
  move goes to the book's next heading in continuous scroll and stays on the page in
  paging, where it goes back to the page's first heading when none follows the link; from
  a link after the book's last heading it begins again with the first heading on screen
  ([#454](https://github.com/vocaro/EPUBLib/issues/454)).
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
