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

Before parsing, the native loader follows designated manifest fallbacks for unsupported or
scripted spine content and images. It selects an available static XHTML, SVG or raster resource,
keeps the authored spine occurrence and layout, and resolves dependencies relative to the selected
resource. Unsupported or unusable foreign chains are withheld with a disclosure; cycles stop.
Without a designated fallback, scripted XHTML retains its existing static/noscript handling.
Selected authored XML content can issue resource-qualified CFIs; synthetic raster wrappers cannot
([#78](https://github.com/vocaro/EPUBLib/issues/78)). The explicit XHTML-only text-extraction API
continues to describe the authored spine resource.

1. **Document** (`ContentDocument`). libxml2 parses each spine item into an element/text tree
   that matches what an EPUB CFI sees: comments and processing instructions dropped, adjacent
   text and CDATA merged. The full HTML named-reference set, including MathML names and
   two-scalar references, becomes numeric references before an XML parse, also in UTF-16.
   All eleven XHTML-family public identifiers accepted by WebKit retain that XML tree and
   its CFIs ([#101](https://github.com/vocaro/EPUBLib/issues/101)).
   Markup that is not well-formed falls back to libxml2's HTML parser and is reported.
   A qualified subset of XML-shaped HTML uses Foliate's HTML whitespace and namespace rules.
   Unqualified HTML repairs remain readable but cannot issue or resolve CFIs: the reader
   discloses that saved positions and highlights are unavailable for those sections.
   For that parser a `<` that opens no markup (`x < y`, `p <.05`) is kept as text, as HTML
   reads it; libxml2 alone discards what follows it
   ([libxml2's HTML parser](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#libxml2s-html-parser-is-not-the-html-standard)).
   That parser is given UTF-8, so an unclosed tag does not change a section's characters:
   UTF-16 and UTF-32 are decoded first, told by the byte-order mark or NUL pattern the screen
   tells them by, and any other encoding by the name in the XML declaration as the XML parser
   reads it, with that parser's decoder. An HTML `<meta charset>` is not read, and a
   declaration the XML parser rejects names nothing. A document that its declared encoding
   cannot decode is read as UTF-8, with U+FFFD for what is not. Bytes that only a NUL tells
   as UTF-16 or UTF-32, and that hold no markup once decoded, are not a document and are
   withheld. What was decoded by a declared encoding is screened again, and what the parser
   is given is held to the byte limit.
   HTML recovery escapes content CDATA as literal text and moves the parser's actual trailing
   nodes into its body before bounded tree conversion. This keeps text after `</html>` and CDATA characters in recovered
   sections without making those sections eligible for CFIs
   ([#237](https://github.com/vocaro/EPUBLib/issues/237)).
   A malformed numeric-reference prefix with no first digit (`&#`, `&#x`, `&#;`) remains
   literal in text and attributes; recovery and safety scans agree that a comment can end at
   `--!>`. Parsed-string restoration cannot create active markup
   ([#197](https://github.com/vocaro/EPUBLib/issues/197), [#244](https://github.com/vocaro/EPUBLib/issues/244)).
   Recovered inline SVG subtrees regain the HTML Standard's SVG namespaces and mixed-case
   names before sizing, screening and serialization; strict XML names stay as authored
   ([#317](https://github.com/vocaro/EPUBLib/issues/317)).
   U+0000 does not end the section: it is left out of text and is U+FFFD in tags, comments
   and the raw text of `script` and `style`, as HTML reads it.
   For the HTML parser a DOCTYPE ends at its first `>`, as HTML ends it even inside a quoted
   identifier: one letter of each `PUBLIC` and `SYSTEM` in it is written as a character
   reference, so that libxml2 reads no identifier past that `>`, wherever the screen read the
   DOCTYPE the same way. A section whose DOCTYPE identifier has lost its closing quote, which
   XML reads on into the document and the screen refused, never reaches the XML parser and is
   read as HTML, with its root's attributes; one with an internal subset or a declaration on
   either side of that `>` is still refused ([#293](https://github.com/vocaro/EPUBLib/issues/293)).
   HTML builds one root. Where libxml2 reads a root tag that has lost the closing quote of its
   last attribute as self-closing (the tag runs to the `/>` of a later empty element) and builds
   the rest in a second `html` beside or inside it, what that one holds is the root's, with each
   of its attributes that the root lacks, and the section is shown (#293).
   Text NULs between a `>` and a `[` would join them into the internal subset the screen
   refuses after a DOCTYPE, so once a file holds `<!DOCTYPE`, in any case, the first of them is
   given to the parser as `<!>`. What keeps the text the same is libxml2 2.9.13, which reads
   `<!>` as nothing wherever recovery writes it, `title` and `textarea` included; HTML reads it
   as an empty comment in text. A libxml2 with an HTML tokenizer (2.14 and later) reads
   `title`, `textarea`, `xmp`, `iframe`, `noembed`, `noframes`, `noscript` and `plaintext` as
   RCDATA or raw text, and would show `<!>` there as written
   ([#593](https://github.com/vocaro/EPUBLib/issues/593)). Any `>` after the file's first
   `<!DOCTYPE` counts. The screen reads a DOCTYPE in two ways and refuses a `[` directly after
   it in both: as XML reads it, in capitals and past a quoted `>`, and for the HTML parser, in
   any case to its first `>` (#293). A section reaches the HTML parser after either reading,
   and the screen also reads a DOCTYPE inside a style sheet, so recovery cannot tell which `>`
   the screen takes for a DOCTYPE's end. `<!>` holds no quote and no `-->`, `?>` or `]]>`, so
   it ends nothing the screen may be reading there (`<!---->` would end a comment the screen
   reads in a style sheet) ([#246](https://github.com/vocaro/EPUBLib/issues/246)).
   A section whose file is cut off inside markup stays withheld, with its disclosure: the
   screen refuses markup left open at the end of the input before either parser runs.
   `XMLSafety` refuses entity declarations first. No DTD or network access, depth and node limits.
2. **Style** (`StyleResolver`, `CSSStyleSheet`, `FontRegistry`). A bounded CSS parser and
   cascade over a user-agent stylesheet, the book's archive-local stylesheets and `style`
   attributes produce a `ComputedStyle` per element: the CSS subset in `ComputedStyle.swift`.
   `@font-face` fonts load from the archive with CoreText. Nothing remote is fetched.
   In a section read as HTML, `epub:type` is one attribute of that name in no namespace, as
   a browser's HTML parser makes it, and `[epub\:type]` matches it. A namespaced selector
   reaches it as in XHTML, by namespace: `[ops|type]` matches it when the sheet binds `ops` to
   the namespace the attribute's prefix stands for, whatever prefix either wrote (Selectors 4
   §6.7), and `[*|type]` matches it too. The prefix stands for the namespace the book's
   `xmlns:` declaration in scope gives it, as an XML parser would read it; `xml` is the XML
   namespace, and `epub`, where the book declares none for it, the OPS namespace, as the
   reader reads an undeclared `epub:type` for its notes (`HTMLAttributePrefixes`). Either
   route that reads a section as HTML names an attribute whose prefix stands for OPS `epub:`,
   so a book's `ops:type` is `epub:type`, for its notes and for `[epub\:type]`, whichever read
   it. A browser's HTML parser would keep `ops:type`. In XHTML only `[epub|type]` matches
   ([#111](https://github.com/vocaro/EPUBLib/issues/111), [#642](https://github.com/vocaro/EPUBLib/issues/642)).
   Media queries for the reader's appearance govern only what paints (**Appearance media**
   under [Decisions](#decisions)), so neither the reader's size nor its appearance changes
   what the next step writes.
3. **Text** (`SectionBuilder`). One walk of a section's DOM produces an `NSAttributedString`,
   a `TextMap` back to DOM positions, element anchors, note content and a `SectionReport`.
   Rich content (images, SVG, tables, MathML, rules) comes from a `RichContentFactory` as text
   attachments. A section's characters depend only on its document, never on typography.
   Passage and Copy text use authored substitutions in the text map: preserved line breaks
   return as LF and synthesized small capitals or text transforms retain source spelling.
   Layout-only separators around floated, positioned and sized inline boxes add no false DOM
   block break. Native selections, Copy and host actions use that same passage mapping,
   including precise table selections ([#127](https://github.com/vocaro/EPUBLib/issues/127),
   [#128](https://github.com/vocaro/EPUBLib/issues/128)), whose cells and the prose beside
   them are one line break apart ([#144](https://github.com/vocaro/EPUBLib/issues/144)).
4. **Positions** (`EPUBCFI`, `SpineCFIs`, `TextSearch`). Swift ports of foliate-js
   `epubcfi.js`, `search.js` and `text-walker.js` (MIT) over `ContentDocument`, producing and
   resolving the same CFIs foliate-js produced (but for the ID assertions under
   [Decisions](#decisions)), and locating quotes with its matcher.
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
  in one document carries its CFI in `bookmark`. A range ending with an image, a rule or
  another element drawn whole includes it, also when nothing follows it in the document: that
  end, the document's, is written as the virtual `after` index of the element's parent, which
  foliate-js read with `setEndAfter`, after the element
  ([#129](https://github.com/vocaro/EPUBLib/issues/129)). A CFI into a spine item the spine repeats
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
- **Element IDs.** Every lookup of an element by its ID compares the ID code unit for code unit,
  as `getElementById` does, so `caf&#xE9;` and `cafe&#x301;` are two IDs although Swift strings
  compare them equal: a section's anchors, legacy `<a name>` anchors and notes, the target of a
  link or a `navigate(href:)` fragment, the TOC and page-list positions, CSS `#id` selectors, SVG
  references, and the manifest IDs that choose a fallback. Tables of IDs are keyed by
  `EPUBElementID`, which compares and hashes an ID's UTF-8 bytes ([#635](https://github.com/vocaro/EPUBLib/issues/635);
  [element IDs](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#element-ids-compare-code-units-swift-strings-do-not)).
- **Selector strings.** A selector compares everything else it names code unit for code unit
  too, as browsers do: class names, attribute names and values under every operator, element
  names, namespace URIs and `:lang()` ranges. So `.caf\E9` does not style
  `class="cafe&#x301;"`, and `[id^="e"]` matches `id="e&#x301;x"`, whose first `Character` is
  not `e`. The `i` flag and `:lang()` fold the ASCII letters alone (Selectors 4 §6.3 and §7.2),
  so `[title="caf\C9" i]` misses `title="café"` and `:lang(k)` misses the Kelvin sign. The
  selector holds these as `CodeUnitString`, so two selectors that differ only in code units are
  never indexed, interned or memoized as one. The ancestor filter still hashes names as
  strings, which only makes it coarser than the match
  ([#640](https://github.com/vocaro/EPUBLib/issues/640)). The SVG reference screen still
  compares the classes of an SVG's own rules as strings
  ([#752](https://github.com/vocaro/EPUBLib/issues/752)).
- **ID assertions.** An ID assertion names the element whose `id` has the same code units, as
  every ID lookup does (above), so `caf&#xE9;` and `cafe&#x301;` are two IDs. Every CFI the reader issues passes the check `restore` applies to
  a bookmark (`EPUBCFI.isWellFormed`), which refuses a C0 or C1 control character, a line or
  paragraph separator, and a CFI longer than its 4,096-character budget. An ID holding one of
  those characters is therefore not asserted: the CFI grammar would take the character only as
  it is, and the step's index names the element without it. A CFI whose ID assertions take it
  past the budget is issued with none. Both depart from EPUB CFI 1.1, which has a step to an
  element with an ID assert it, and from foliate-js, which asserted every ID and nested one
  `epubcfi(…)` inside another for an ID with a line separator
  ([#105](https://github.com/vocaro/EPUBLib/issues/105)).
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
  multi-language support is not a current priority. A spike found that route open on both
  platforms
  ([vertical orientation](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#a-text-view-takes-its-layout-stack-when-it-is-made)).
  `vertical-lr` and continuous scroll are outside that route.
- **MathML.** A native layout engine, the [MathMLLayout](https://github.com/vocaro/MathMLLayout)
  package (CoreText and the OpenType MATH table), draws each `<math>` as an attachment,
  baseline-aligned inline and centred for `display="block"`. The corpus uses `mi`, `mn`, `mo`,
  `mrow`, `mfrac`, `msup`, `msub`, `msqrt` and `mstyle` (1,798 formulas, all with `alttext`);
  MathMLLayout 0.3.1 also supports `mglyph` images. The reader resolves their `src` through
  its archive image pipeline, including manifest fallbacks and sanitized SVG, and supplies
  images with their intrinsic size to the engine, which honors `width`, `height` and `valign`.
  Missing, refused or undecodable images show `alt` (a box when it has none), disclosed as a
  simplified layout; their descriptions remain available for speech, copy and search even
  when the images draw. Decodes are capped at 1024 pixels on the long side and 16 MiB per
  formula; exceeding that retained-image budget also uses the text fallback. The reader
  passes elementary math directly to the engine: `mstack`, `mlongdiv`, groups, rows, carries
  and rules retain their authored attributes, including finite rule lengths, carry locations,
  column spacing and all ten long-division styles. Anything the engine cannot lay out shows
  its `alttext` and is disclosed. No WebKit.
- **Wide formulas.** `MathLayout(_:style:maximumWidth:firstRowMaximumWidth:)` selects rows at
  the text's full size, using the engine's operator dictionary, nested structural wrapping and
  MathML line-break and indentation attributes. Fraction parts, radicands, enclosures, fenced
  rows, long `mtext` and table cells can wrap. A display formula remains one centred attachment,
  with its rows centred vertically on the font's actual math axis. It stays together on a page
  and scales uniformly if it is taller than the page. Content that cannot break (a long number,
  for example) scales to the column without clipping; a formula shown below three quarters in
  a 320-point column is disclosed.
  Long inline formulas use separately drawable engine rows on consecutive paragraph lines.
  The first row uses the space left after the preceding text and the last leaves room for
  following words. Their source reserves a bounded number of attachment slots; unused slots
  take negligible space, so resizing changes geometry without changing offsets or CFIs.
  Short inline formulas remain atomic. A formula keeps one width-aware attachment if its
  finest engine layout needs more than 256 slots, grows vertically when internal structures
  wrap, or exceeds the engine's limits. Explicit `lineleading` also keeps one attachment,
  preserving the engine's authored vertical row spacing. That attachment can contain several rows. Selection or copy of any part of an inline
  formula gives its full reading once; a continuation page also exposes one full reading.
- **Spoken math.** Assistive technologies read a formula's `alttext` verbatim, with whitespace
  collapsed, in the content's language: the nearest `xml:lang` or `lang` on the `math` element or
  an ancestor, else the publication's. Without `alttext`, `accessibilityDescription(locale:)`
  selects the engine's vocabulary: English, French, German, Spanish or Italian, including its
  supported British English variant. Regional requests fall back to their supported base
  language, unsupported languages to English. The returned language tag accompanies the
  reading so the platform can select a matching voice. Authored token text and glyph names
  are retained literally; generated vocabulary does not translate them. Elementary readings
  describe rows, column positions, carries and rule extents. On Mac a formula's character
  carries an image element named by the reading, in page text and table cells, and VoiceOver
  adds its own word for an image.
- **SVG.** Inline and archive SVG illustrations render through
  [StaticSVG](https://github.com/vocaro/StaticSVG) and the resvg static renderer it bundles,
  including paths, text, gradients, transforms, clipping, local definitions and
  `viewBox`/`preserveAspectRatio`. SVG dimension attributes retain their CSS units
  ([#117](https://github.com/vocaro/EPUBLib/issues/117)). A plain single-image wrapper retains
  the raster-image fast path for the default centred meet fit: image percentages resolve in
  viewBox coordinates, and one omitted dimension follows the image's intrinsic ratio.
  Other aspect fits, transforms and nested viewports use the SVG renderer
  ([#187](https://github.com/vocaro/EPUBLib/issues/187)). Archive raster references are resolved
  and bounded before rendering, and images in `data:` URLs read and bounded as they are
  (**Data URLs**, below); scripts,
  animation, foreign content and external resources are omitted with a disclosure. Manifest
  image fallbacks apply inside SVG as well. Recursive preparation shares one memo and work
  budget per drawing: 128 request/candidate misses, 16 MiB each of loaded source and serialized
  SVG, 64 Mi raster pixels, 8 MiB of cached PNGs, and eight ancestor paths. Cache entries retain
  their ancestor and font context, cancellation stops preparation, and exhausted budgets omit
  images with a disclosure. SVG
  filter effects are omitted with a disclosure while preserving the drawing's shapes and labels.
  The sanitizer omits filter definitions, presentation attributes in every namespace the
  renderer reads them from (`xlink:filter` among them), and CSS declarations wherever the
  renderer's tokenizer finds one, straight after `!important` or a `*` included; a last pass
  blanks any name it could still begin one at ([#253](https://github.com/vocaro/EPUBLib/issues/253)).
  `SectionReport` retains its `svg:filter` disclosure. CSS omission preserves neighboring fill,
  stroke, clipping and font declarations, including comments and quoted/function values, as the
  renderer reads them, and takes time linear in the CSS.
  Stylesheet text is sanitized together so XML text/CDATA boundaries do not split declarations.
  CSS is read by Unicode scalar, so a combining mark after a quote, backslash, comma or bracket
  hides no delimiter ([#248](https://github.com/vocaro/EPUBLib/issues/248)). The serializer
  writes a tab or carriage return in an attribute value, and a carriage return in text, as a
  character reference, so the renderer reads a class list, text and the id an `href` names as
  the book has them ([#249](https://github.com/vocaro/EPUBLib/issues/249)). An embedded font's
  own family name, which comes from the book's font file, stands for the family a drawing names
  only when it holds nothing but letters, marks, digits, spaces and `-`, `_`, `.`, `&` and `+`.
  The renderer's direct entry point continues to refuse filters, including commented and
  escaped CSS property names; it only receives the prepared drawing. The original node, depth,
  local-reference expansion and cycle checks run before omission.
  Pattern fills and illustrations exceeding the rendering limits show their title, description or
  drawing text instead. Title and description provide the image's accessible label. No WebKit.
  EPUBLib reads the archive, resolves references and picks manifest fallbacks and fonts for
  StaticSVG, which reads nothing else; it extracts inline SVG from the content document, lays out
  and inspects the attachment, and turns StaticSVG's diagnostics into the section's disclosures.
  StaticSVG ships the renderer as an Apple XCFramework, so consumers do not need Rust; its source
  pins, build, panic boundary and redistribution notices are in its
  [renderer notes](https://github.com/vocaro/StaticSVG/blob/0.1.1/doc/renderer.md).
- **Data URLs.** An image a document holds in a `data:` URL, as EPUB 3.3 §3.7 permits, is shown
  as one from the archive is: an `<img>`, and an `<object>` or `<embed>` whose `type` names an
  image ([#134](https://github.com/vocaro/EPUBLib/issues/134)); and an SVG `<image>`, in a drawing
  in the document, in one from the archive, in one inside another, and in an SVG that is that one
  image ([#657](https://github.com/vocaro/EPUBLib/issues/657)). The URL is read as browsers read
  it, by the Fetch standard's data: URL processor (`DataURL`): base64, broken by white space or
  without padding, or percent-encoded. Its type stands for a manifest's media type, so one that
  is not an image's (`text/plain`, where it names none) is not shown. Its bytes go to the same
  bitmap decoder and SVG sanitizer under the same limits, and decode to no more than the 32 MiB
  the archive holds of one resource by default; the document holding the URL is held to less.
  Inside a drawing, an image in a `data:` URL is prepared as an archive image there is: no more
  than 8 MiB, its pixels counted with the drawing's other images, its bytes and work charged to
  the drawing's preparation budget, and one URL given twice prepared once. The renderer is given
  the PNG it decodes to, as it is an archive image's, never the book's URL, and the drawing is
  screened before it is prepared and again after. A drawing in a `data:` URL has no base in the
  archive, so a reference in it names no file, inside another drawing as anywhere. A `data:` URL
  that is no usable image shows its alternative text and is disclosed as an image that could not
  be shown; inside a drawing it is left out and disclosed as an archive image there that cannot
  be decoded is, and is never counted as a resource refused from the internet. Elsewhere `data:`
  URLs are not read: in a MathML `mglyph`; in an `<object>` or `<embed>` with no image `type`;
  and in a stylesheet `<link>`, `@import` or `@font-face`. A link to one is refused as a link
  outside the book is, and so never opens as a document of its own (RS 3.3 §3.4).
- **Image contrast.** On a dark theme's page (Dark, Black, or custom colours whose background is
  dark: **Themes**), transparent images containing dark strokes receive
  a white backdrop so diagram edges and labels remain legible. Their authored colors and
  publication bytes are preserved. Opaque images and transparent light artwork retain their
  pixels; an author's explicit CSS inversion retains its own appearance treatment. Display
  renditions are cached separately by appearance under the existing image memory budget.
- **Media queries.** A `media` attribute, `@import` and `@media` are evaluated by Media
  Queries 4 against a screen of the nominal 600 × 800 CSS pixels, an `em` of 16, a resolution
  of 2dppx, colour, no scripting and the reader's appearance (**Appearance media**). A query
  has three values: a feature the reader does not know, a value or a `min-`/`max-` prefix its
  feature does not take, and parentheses around anything that is neither a condition nor a
  feature are unknown. `not` leaves unknown unknown and `and` and `or` combine it as browsers
  do, so `not (bogus)` and `not all and (min-orientation: portrait)` apply nowhere, while
  `(color) or (bogus)` applies; a query that comes to unknown is `not all`, and the others in
  its list still count ([#114](https://github.com/vocaro/EPUBLib/issues/114)). A feature's
  value is a literal: `calc()` and the lengths other than `px`, `em`, `rem` and the absolute
  units are unknown.
- **Appearance media.** `prefers-color-scheme` follows the reader's appearance only for what
  paints: `color`, `background-color`, the border colours, `text-decoration-color` and `filter`
  (`CSSProperty.followsAppearance`). Every other property in a rule for one appearance, and
  any property added later, is resolved as in the light appearance, the one a reading system
  with no preference reports. The `display`, `visibility`, `text-transform`, `white-space`,
  list styles, positions, sizes and fonts a book sets for dark appearance alone therefore
  apply in neither, and a section's characters, the text `visibility: hidden` hides and the
  map to the document are the same in both. The session keeps rendered positions, search
  matches, highlights and selections across an appearance change on the strength of that. A
  book that swaps content by appearance (an image drawn for each, say) shows its light
  content in both: dark line art stays legible by the image contrast above, and an author's
  `filter: invert()` for dark appearance, as Standard Ebooks writes it, still applies. Rules
  for either appearance are indexed in both, so a bound on author CSS drops the same
  selectors in each ([#130](https://github.com/vocaro/EPUBLib/issues/130)). A custom property
  declared for one appearance is substituted into what paints in that appearance, and into
  everything else, in either appearance, only when that is the light one (**Custom
  properties**).
- **Themes.** `EPUBReaderStyle.appearance` chooses the page's colours (`EPUBReaderColors`): Light,
  black on white; Dark, light grey (92%) on the dark grey `#1C1C1E` of a raised surface in iOS's
  dark appearance; Sepia, `#5F4B32` on `#FBF0D9`; Black, Dark's text on pure black, which is
  what Dark drew before Black was added; and Custom, the style's `customColors`, Light's when it
  has none ([#674](https://github.com/vocaro/EPUBLib/issues/674)). System is Light or Dark by
  the mounted view's colour scheme. Text and links are 4.5:1 or more against the page in every
  preset (`ReaderColorsTests`); a custom theme below that is drawn as given, as the reader's
  own choice. A theme is dark when white has more contrast with its background than black has,
  a relative luminance below about 0.18. A dark theme draws as Dark always has: the book's own
  text, border, decoration and background colours give way to the theme's, transparent dark
  line art gets its white backdrop (**Image contrast**), and `prefers-color-scheme: dark` applies
  (**Appearance media**); `effectiveAppearance` is Dark. A light theme, Sepia among them, draws
  the colours a book sets for itself, as Light does, and the theme's where it sets none. What
  the theme does not name derives from it: secondary text (words in place of a picture, a
  section that could not be shown) is the text faded toward the page as far as 4.5:1 allows;
  rules and a dark theme's table borders are a quarter of the way from the page to the text;
  highlights keep their yellow and orange, deeper on a dark page, each drawn as strongly as it
  can be while the text over it keeps 4.5:1, down to half its usual strength; the Mac's
  selection is the theme's link colour, 30% over the page, by the same rule. The page behind
  both flows, the image inspector and a note's popover is the theme's background (on the Mac
  the popover's arrow is AppKit's); on iPhone and iPad the canvas's tint, which UIKit draws the
  selection, its handles and the caret in, is the theme's link colour, and UIKit chooses how
  translucent it draws the selection. A table's cells are drawn and selected as the text around
  them. The status's `effectiveColors` gives a host the colours to draw its own controls in.
  Changing theme rebuilds the text, never its characters, so the position, search results,
  highlights and the selection are kept, and the page and the canvas change theme together
  (**One appearance on screen**).
- **Increase Contrast and Bold Text.** The reader follows both from SwiftUI's environment
  (`colorSchemeContrast` and `legibilityWeight`), so on iPhone and iPad from the window's
  traits, live, whatever the theme; turning either on or off rebuilds an open book's text and
  keeps its place. With Increase Contrast, the background stays and the theme's text and links
  move toward black on a light page or white on a dark one, half the way there and further if
  they are still short of WCAG's enhanced 7:1 (`EPUBReaderColors.increasingContrast`); text
  already black or white stays. Secondary text then keeps 7:1, rules are half the way from page
  to text and at least 3:1, and each highlight and the Mac's selection are drawn half the way
  from their usual strength to opaque, as far as the text over them keeps 4.5:1. With Bold
  Text, fonts are found for a weight 200 heavier than the book's, to at most 900, so regular
  text is drawn semibold, as iOS draws its own body text with Bold Text, and bold heavier still;
  a family without the heavier face is emboldened as for any synthetic bold. The weight is the
  reader's, carried from the root with no CSS property to reset it, so the book's own weights
  keep their order; text in a table's cells, list markers and generated content is drawn so as
  well, while a formula's glyphs and an SVG drawing's text keep their own weight. The Mac has no
  Bold Text setting of its own, and its environment reports none unless a host sets one. Not
  followed: `prefers-contrast`, which the reader's media
  queries do not know (**Media queries**), and a light theme's book colours, which Increase
  Contrast leaves as the book set them. Links drawn over a highlight are not held to 4.5:1,
  and a custom theme's highlights take Light's hues or Dark's, by whether it is dark.
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
  Mac ([an element without a name](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/accessibility.md#an-element-without-a-name-is-read-by-its-help-or-its-contents)).
  A book can also keep an image from assistive technology, whatever its `alt` says:
  with `aria-hidden="true"` on the image or on an element round it, or with the role
  `presentation` or `none` (`ContentSemantics.isHiddenFromAssistiveTechnology`). The reader
  maps both
  [as WAI-ARIA 1.2 and HTML-AAM do](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/accessibility.md#map-html-alternatives-and-hiding-as-html-aam-does),
  exceptions included, to assistive technology alone. The image is
  drawn, and its words still stand for it in selections, copies and search, as a browser
  copies them: "passed over" is told apart from "has no words" (`ImageAlternative`), and only
  VoiceOver goes without them (`spokenEquivalent`). It passes over such an image as it does
  decoration, with no element, no name and no inspection action, in a line, in a heading
  and in a link's name, and what keeps decoration listed keeps it listed, as an image
  without a name: being all its link holds, and being all a page or a screen holds on
  iPhone and iPad. The book hid the words, so the link that is such a picture alone is an
  image link without a name. A hidden label reads nothing for an
  image or an inline SVG with a presentational role. Where such an image cannot be drawn,
  its words are shown in its place as text and read as text, and so are kept from VoiceOver
  where `aria-hidden` keeps the image, as any text it keeps is. In a table cell the words of
  such an image are still read: on iPhone and iPad in the cell's text, and on Mac in what
  its row is called. They are the words a copy of the row takes
  ([#551](https://github.com/vocaro/EPUBLib/issues/551)). Shown text with `aria-hidden` is
  kept from VoiceOver too, and a formula with it is passed over as such an image is
  ([Text kept from assistive technology](#text-kept-from-assistive-technology),
  [#552](https://github.com/vocaro/EPUBLib/issues/552)). An image is
  not named by `aria-label` ([#167](https://github.com/vocaro/EPUBLib/issues/167)). On
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
  the page gets it from the line, and without the stop two scenes are read as one. On
  iPhone and iPad
  [VoiceOver has no word of its own for a separator](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/accessibility.md#voiceover-speaks-a-roles-own-words).
  The word is the reader's (`ReaderRuleAttachment.spokenName`), the
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
  Mac too, because AppKit has no role for a break in content that VoiceOver reads as one
  (the same article). The static text was chosen because its word is
  what the element holds, as the stop's label is on iPhone and iPad, and because it is the
  element a hidden label already has. In a link on Mac a rule gives way to the link: one
  that is all its link holds, or that opens a link of words, has the link's element in its
  place, without a name ("Links for VoiceOver on Mac" below), and one elsewhere in a link
  has its own. No rule in a link was heard. A rule the book keeps from assistive
  technology, as ornament and not a break, with `aria-hidden="true"` or the role
  `presentation` or `none`, under the same exceptions as an image, has no stop on iPhone
  and iPad and no element on Mac. On Mac, outside a link, it is given as a table row that
  has nothing to say is: its character and the break after it are spaces, one for one, and
  its line is part of the line after it, so VoiceOver stops on it neither by line nor by
  word, where a line of its own would be a stop in silence. One that ends a page has no
  line after it there and is a line of spaces, where VoiceOver stops once, by line and in
  Read All, and says nothing, as at such a row
  ([#529](https://github.com/vocaro/EPUBLib/issues/529)). One that is all its link holds
  is the link still, and on iPhone and iPad a page that holds such a rule alone lists it as
  a separator, since VoiceOver has no other place there to turn the page from. Until
  [#408](https://github.com/vocaro/EPUBLib/issues/408) such a rule was announced as any
  other. On Mac a table cell is a
  text area of its own, which VoiceOver reaches by interacting with the row and then with
  the cell. A rule in a cell has the same element there, and VoiceOver says "Separator" at
  it by line, by word and reading on, in pages and in continuous scroll, and as it reads
  the cell on entering the row. Before, it said nothing at a rule in a cell, and nothing
  at a formula, a picture or a hidden label there either, whatever element the cell gave.
  A cell made a new element for each attachment at every read of its rich text and kept
  none, where a page's text keeps its elements from one read to the next, and
  [VoiceOver asks an element what it is after the read that gave it](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#appkit-gives-a-client-the-text-character-for-character).
  A cell now
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
  itself, and
  [the way VoiceOver uses them](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#links-in-an-appkit-text-view-are-children-not-places)
  left a link that is a picture or a hidden label without a name or out of reach (macOS
  27.0.1, with "When encountering a link/attachment" at Speak, its default). The reader gives
  elements of its own in AppKit's place
  (`ReaderLinkAccessibilityElement`), each with AppKit's role for a link in text and a
  press that follows the link. A link is called by its words, with the text of each
  attachment in its place and decoration left out. One that holds pictures and nothing else
  says after any words that it is a picture, in the system's word for one, because an
  element that is a link cannot be an image as well. A page column gives its own page's
  links: one that crosses the page's end is the part on the page, and one in the context
  laid out after the page is not listed. The scroll view lists the links of the paragraphs
  on screen, as AppKit does, and after them the book's next link, which is below the
  screen ("A link below the screen", further on). The text's headings stand among those
  children too, each where it is in the text, and after them the book's next one: with its
  cursor on a link VoiceOver finds the next heading there and nowhere else ("Input and
  accessibility", Headings).
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
  Not done: a list of links in VoiceOver's rotor, for the reasons in the same article and under
  Headings in "Input and accessibility". A note's popover keeps AppKit's elements. A link
  inside the book does nothing there, and a press of one outside it is asked about
  ([Security](#security)).
  A link below the screen. In continuous scroll the children were the links on screen, so
  from the last of them Find Next Link began again with the first, or said "Last link"
  and stayed, and from the text after it, once VoiceOver had been on that link, it said
  "Link not found": a link further down was reached by reading or scrolling to it.
  So the scroll view's children now end with the book's next link after the screen, as they hold
  the next heading there, and Find Next Link goes on to it from the last link on screen. It is
  the link's own element, kept by its place in the text, and so the same one once the link is on
  screen, where the link after it is the next. Where the next link is in a table's cell, its row
  keeps its
  cells while it is below the screen (`ReaderTableInteraction.keepRow`): a row off screen
  has no cells, and a cell's link is listed by the page as the cell's link
  (further on). That row's links are then the next ones, and the text's own next link is
  no child until the reader has moved. No link above the screen is listed.
  VoiceOver's cursor is then on the link's element and not in the text, and its next move
  by word or by line starts from its own place in the text, where it last read. Left to
  itself it scrolled to the link by the scroll bar, and one move right took the view back
  to the top of the book. So a link's element says whether it has the keyboard focus and
  takes it, as a heading's does, since
  [VoiceOver focuses only an element that reports its focus](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#voiceover-focuses-only-an-element-that-reports-its-focus).
  For a link with none of it on screen the reader then shows the link, as it
  shows a link's target, and puts the insertion point on it, or on the row for a cell's
  link: `right` and `line` read on from the link, and from the row for a cell's link,
  "Table row group" when that was heard, before a row was called by its words.
  The reader shows the link where TextKit 2 estimates it stands, and VoiceOver then asks
  the text which line the insertion point is on, which lays out all the text above: the
  view is held to the link through that, and a row shown keeps its cells, or its link
  would leave the text's children with VoiceOver on it ("Continuous scroll").
  Told that the insertion point has moved, VoiceOver says the word beside its new place,
  and having shown a place the reader tells it that the layout changed, at which it says
  the item under its cursor again, role first. So VoiceOver says "words." and then
  "hyperlink Parked link to the target", where for a link on screen it says "Parked link
  to the target hyperlink": the last word of the paragraph before the link, and then the
  link. Before a row of a table of data the word is that table's row before it, "Birch,
  1934 table".
  A link with any of it on screen is left as it is, in pages and in continuous scroll:
  found, named and followed as before, with reading on from it starting where VoiceOver
  last read. With the insertion point put on such a link as well, VoiceOver said that word
  over the link's name: "word." and the hint were all that was recorded of "Verification
  link hyperlink", and "grid." of a cell's link. Three ways to move VoiceOver's place in
  the text without the word
  [moved nothing or said it all the same](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#voiceover-enters-a-text-view-at-its-insertion-point).
  With cursor tracking off VoiceOver focuses nothing: it says the link below the screen
  by its name, scrolls to it itself, and reads on from where it last read.
  Past the book's last link nothing is added, and Find Next Link does there what it does
  on a page: it begins again with the first link on screen, or says "Last link" and the
  link's name where that link is the only one on screen. That is VoiceOver's own way with
  the children it is given, and the reader leaves it. A child for the book's first link
  after the last one would make the move go round the whole book, and would take a
  listener from the end of a book to its start at one press more than they meant, with
  nothing said of it. In paging Find Next Link stays on its page, as before
  ([#425](https://github.com/vocaro/EPUBLib/issues/425)).
  A table cell is a text view of its own. VoiceOver meets a row of a table that is not
  data as one stop of the page's text, a group called by the row's words ("Data tables"
  below, On Mac); interacting with it there shows the row's cells, and interacting
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
  inspector and Command-plus/minus/zero zooms or fits it. The controls and the image stand
  inside the safe area, below a toolbar shown over the reader on the Mac as the pages do
  ([#162](https://github.com/vocaro/EPUBLib/issues/162)). Reader page input is suspended while
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
  What UIKit gives a text view was heard by itself on 2026-10-12
  ([VoiceOver testing](testing.md#harness-pitfalls-and-current-results)) and is
  [an action for each link of its text](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#uikit-offers-the-actions-of-every-element-that-contains-the-item).
  On Mac a text area has no elements for its lines, so each
  text area offers the page turn itself, the same command under the name its flow gives
  it ("Input and accessibility").
- **Tables.** Attachments drawn natively, with cells laid out by TextKit 1
  ([TextKit 1 and TextKit 2](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#textkit-1-and-textkit-2-apply-paragraph-indents-differently)),
  one image-drawn attachment per row so pages can break between any two rows; rows a rowspan
  joins, and the header, keep with the next row and share a page when they fit. `colspan`/
  `rowspan` honoured (`rowspan="0"` spans one row, as WebKit does); a spanning cell is drawn in
  each row it covers. A table, its columns, rows and cells take their sizes, and a cell where
  its content sits, from the cascade, where `width`, `height` and `valign` are presentational
  hints that an author rule beats (HTML §15.3.8): a table's width of zero and a cell's width
  or height of zero are no size at all ([#121](https://github.com/vocaro/EPUBLib/issues/121)),
  and a row group's alignment reaches its rows and their cells, which inherit it
  ([#142](https://github.com/vocaro/EPUBLib/issues/142)). Consecutive columns spanned by exactly the same cells, and declared by no
  `col` or `colgroup`, are laid out as one (CSS Tables 3 §3.3.2, track merging): the 98 columns
  a title row's `colspan="100"` runs past over a two-column body add one border spacing to the
  table, not 98 ([#140](https://github.com/vocaro/EPUBLib/issues/140)). The model keeps the
  columns HTML forms, and an assistive technology is given those. Oversized rows continue
  across pages using complete cell glyph lines;
  a line crossing a rowspan boundary is finished in its preceding row and never drawn twice.
  That row, or a tall row's piece whose cut such a line crosses, is drawn on to the line's
  foot: its cells' backgrounds and borders and the table's go through the band, and the next
  row's cells are left to the next row ([#141](https://github.com/vocaro/EPUBLib/issues/141)).
  A continuation sharing a page with following rows or prose uses the displayed page’s exact
  bounds; overflowing content advances to the next page once, without laying out the whole
  section again ([#546](https://github.com/vocaro/EPUBLib/issues/546)).
  A row is drawn across the content box of the block or list item its table is in, inside
  its margins, borders and padding on both sides, in either direction and with or without a
  float in the section; a list item's marker hangs in the indent beside the first row
  ([#376](https://github.com/vocaro/EPUBLib/issues/376)).
  Continuous scroll retains full row heights. Tables too wide for the line shrink their text
  to 60%, then wrap by character. Only the outer table scales: tables inside cells inherit
  that scale and wrap at their cell's width, so nesting never multiplies text reductions.
  A page-fit reduction is retained only when it makes the tallest row fit; otherwise the
  table continues at its initial scale. Tall nested rows provide complete-line portions to
  their parent, retaining their source character while their own text continues across pages.
  A place in a nested table, at any depth, is a place in that table's cell as well as the
  outer cell's, so a search result, a located passage, a bookmark or a link's target there
  opens the continuation of the outer row that holds the nested row's continuation drawing
  it, and continuous scroll brings that nested line to the top. Each named only the outer
  cell's character for the whole nested table, and opened the row's first page
  ([#544](https://github.com/vocaro/EPUBLib/issues/544)).
  A match there is read in the innermost cell as well: its highlight is painted on its own
  words, over the nested row's continuation that draws them, its search-result context and
  passage are that cell's words, and its DOM range, and so a CFI made from it, is the match's
  own. Each took the outer cell's characters, where the nested table is one unit: the
  highlight covered the nested table on screen, the context was the outer cell's text around
  it, and the CFI named the nested table element
  ([#718](https://github.com/vocaro/EPUBLib/issues/718)). A match's highlight paints only the
  nested rows the match runs through, so what a cell's matches cost to paint follows the rows
  they are in. Two things still read the outer cell's characters: a selection there is drawn
  over the whole nested table, and a match there is left out of the results, and not
  selected by `.locate`, when `visibility: hidden` hides text anywhere else in the nested
  table ([#739](https://github.com/vocaro/EPUBLib/issues/739)).
  A cell is laid out with TextKit 1. Where a paragraph's indents, a list's among them, take
  the whole column left inside the cell's padding, the paragraph keeps the glyph-wide column
  the reader's other text keeps, its left indent first
  (`ReaderTextContainer.clampingExhaustedIndents`), and a cell is measured to its last line.
  Otherwise the lines below its row's foot were on no page once the row was split
  ([#569](https://github.com/vocaro/EPUBLib/issues/569)).
  One outer layout makes at most five passes per nested table, a linear count in the number
  of nested tables ([#299](https://github.com/vocaro/EPUBLib/issues/299)). Cell max-content
  widths measure every explicit line, excluding paragraph separators so leading indents remain.
  Reader attachments contribute intrinsic widths: rules contribute zero and nested tables
  their preferred widths. Paragraph measurement visits each attachment once and never lays out
  a nested table ([#300](https://github.com/vocaro/EPUBLib/issues/300),
  [#138](https://github.com/vocaro/EPUBLib/issues/138)). Table construction keeps large style,
  preparation and placement temporaries outside recursive cell rendering
  ([small recursive frames](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/stack-and-work-bounds.md#small-recursive-frames-and-heap-cursors-keep-depth-cheap))
  to fit the production task-thread stack through both written and anonymous cells
  ([#329](https://github.com/vocaro/EPUBLib/issues/329)). Tables are drawn eight levels deep.
  Past that a cell's content is written as a shallower cell's is, with the tables in it flowing
  as text, one column as blocks and wider ones as rows of tab-separated cells: its words stay
  apart, and what the reader leaves out of it, shows for it and reports is the same
  ([#144](https://github.com/vocaro/EPUBLib/issues/144)). A single non-table glyph line taller
  than a page is fitted as a whole.
  One-column tables, which books use as callout boxes, flow as ordinary text: a table is a grid
  when the cells written in its rows take more than one column. Text flows in document order,
  so a table of one column is a grid too when its parts are written in another order than they
  are shown in: a footer group before the body (as HTML 4 had it), a header group after it, or
  a caption on the other side of the rows from where it is written
  ([#144](https://github.com/vocaro/EPUBLib/issues/144)). Nothing a table holds is
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
  invoke the host's selection action, follow internal links and open notes. A link outside the
  book is asked about as one in the text is ([Security](#security)). Cell selections, located passages and saved highlights use exact
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
  surfaces are hidden from assistive technology there, since
  [a text view that is merely not an element still offers UIKit's own elements](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#uikits-own-text-view-elements-are-every-paragraph).
  On Mac
  a table that holds data is given as a table at each of its rows ("Data tables" below), and
  a row of any other table is a group, called by its cells' words, that holds its cells'
  text areas. A row that shows nothing, or decoration alone, is nothing VoiceOver stops on
  there either, in either kind of table. A cell's lines are those its own layout
  makes, numbered from the first it shows, and
  [the offset after its last character is on its last line](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#appkit-gives-a-client-the-text-character-for-character),
  as the offset after a page's last character is on the page's.
  Continuations retain original
  source offsets: several pages can report the same row range. Existing bookmarks naming a
  whole table still resolve to that table; new cell ranges identify the selected characters.
  Search-result mapping binary-searches source-ordered cell intervals and uses the recorded
  row offset, rather than scanning every row and cell for each match in a long table
  ([#137](https://github.com/vocaro/EPUBLib/issues/137)).
  Interaction surfaces are mounted only for visible cells. Cell TextKit
  layouts and glyph metadata are retained for drawing in the table's bounded layout cache.
  In continuous scroll which rows are visible is read from TextKit's layout, which
  [lags the scroll view's report of a move](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#lay-out-through-a-far-target-before-scrolling-to-it).
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
    reader
    [decides as WebKit does](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#decide-whether-a-table-holds-data-as-webkit-does),
    from what it builds and draws. Two things differ from WebKit. Any header cell makes a table
    data, where WebKit wants a first row or a first column of them: a `th` says what it heads,
    and a row cannot say that. And cells with a background of their own, and rows of alternating
    backgrounds, do not: the dark appearance computes no backgrounds, and a table must be the
    same thing to a listener in
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
    alone, and otherwise its rows when its columns hold header cells alone. Since
    [UIKit asks for the headers of a row and of a column, not of a cell](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#uikit-asks-for-the-headers-of-a-row-and-of-a-column-not-of-a-cell),
    the table answers with the header cells above and before the cell that was last asked
    where it stands, which is the cell VoiceOver has come to. A cell's `headers` attribute
    makes its table data and is otherwise not followed.
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
    rows of another page are not there to move to; Next Page goes on, as from a line. Into
    a table and out of one the item under the cursor goes with the page and keeps the
    action chosen: a line's item becomes the cell that opens the next page, and a cell's
    item the line, and with Next Page chosen each double tap turns another page across
    them (iPadOS 27.2). From a cell to a cell, as on every later page of a table longer than
    a page, the cursor is on a new item with the rotor at its default, since that is the
    item VoiceOver reads with its row and column ("A page turned under VoiceOver's cursor"
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
    rotor's Rows moves past the screen. Two things made that hold. A table lists its rows
    again, for where the cursor is now, whenever it is asked, since
    [VoiceOver asks the table first](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#on-ios-a-data-table-is-a-container-among-the-lines);
    answered from the rows listed
    for the cell before, a table ended at the last of those. And the rows around a cursor
    that rests in a table the person has scrolled away from are listed in the same element
    as the rows on screen, with those between them missing, as lines are.
  - **On Mac.** VoiceOver on Mac reads a text area by line and by word, and
    [meets a table only as the element the text gives at an attachment's character](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#on-the-mac-voiceover-meets-a-table-only-at-an-attachment-character).
    A table is an
    attachment for each row, so each row's character gives AppKit's table, `AXTable`: the
    whole table, with the rows the view shows of it, its columns, its cells, each with the
    rows and the columns it covers, and a header for each column and each row, from HTML's
    header cells as `TableModel` has them. The table at a row is called by that row's words
    and says that row is selected. A table that is not data is a group for each row,
    called by that row's words (A table that is not data, below). A row that has nothing
    to say is neither, in either kind of table: VoiceOver passes over it (A row that has
    nothing to say, below). Each part of this was
    heard on a hosted runner before it was kept
    ([VoiceOver testing](testing.md#voiceover-testing), the entries of 2026-10-13 on tables of data
    on Mac, on a table that is not data, on rows that show pictures and on rows that have
    nothing to say):
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
      link, and Inspect Image for each picture.
    - **A cell that shows a picture.** A cell that shows pictures and nothing else holds
      an image for each of them, called by the picture's words, in place of its text
      area, as a web view's cell holds an image. VoiceOver says "Sign Blue badge image"
      along the row and "Blue badge image" down the column, and "image cell" for a
      picture nobody describes, in pages and in continuous scroll. While such a cell
      held its text area, a transcript had the column's header and the attachment's
      character there, "Sign ￼", for the described picture as for the other. The
      description was in the row's name, "Blue badge, Open table", and inside the
      cell's text, "In text Blue badge image", and not at the cell. Each of these was
      heard on a hosted runner ([VoiceOver testing](testing.md#voiceover-testing), the entry of
      2026-10-13 on a table cell that shows a picture):
      - **What VoiceOver goes by**
        ([a Mac cell is read by what it holds](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#a-mac-cell-is-read-by-what-it-holds-not-by-what-it-says-it-is)).
        At a cell it reads a text area by its characters,
        and a picture's is the attachment's character, U+FFFC. Nothing the text area
        or the cell says of itself puts the picture's words there. A label on the text
        area changed nothing. Neither did the cell's words given as the text area's
        value, which VoiceOver does read where the cell heads a row, or as the string
        of a range, which also broke reading by word inside the cell ("Blue crest
        image  da", "ily"). A label on the cell is said after what the cell holds, so
        a cell's words came twice, "Worn ￼ daily Worn Blue crest daily". An image
        that held the text area was said by the character still, "Sign ￼", where a
        link that holds one is said by the words and "hyperlink". What VoiceOver says
        at the cell is an image the cell holds itself. What it voices for the
        character nobody heard. The system's speech synthesizer, given the phrase
        outside VoiceOver, says nothing for it: `say` wrote "Sign ￼" to a file as
        long as "Sign". If VoiceOver passes the character on as it is, a listener
        heard the column's header at such a cell and no more.
      - **The image.** It has the picture's words for its label, and no label for a
        picture nobody describes, which VoiceOver says in its own word. It has no
        help. The image at a picture's character in text has the sentence about
        Inspect Image for its help, and with that VoiceOver said "Sign Blue badge
        image Double-click or choose Inspect Image to enlarge." each time it came to
        the cell. It stands where the picture is drawn and offers the picture's
        Inspect Image, as the cell does: the cell's Actions menu is what it was,
        "Inspect Image: Blue badge" and "Select Cell Text". Chosen from the cell's
        menu or the image's, Inspect Image opens the inspector.
      - **Several pictures, and decoration.** A cell of two pictures holds two images,
        "Rank Blue ring image, Blue star image", and is "cell 2 items":
        Control-Option-Shift-Down goes to the first and Control-Option-Right to the
        next. A transcript had "Rank ￼   ￼". Decoration (`alt=""`) is no image, so
        a cell of decoration alone holds nothing and VoiceOver says "empty cell", as
        of a cell with nothing in it; on iPhone and iPad such a cell says nothing,
        like an empty one. A transcript had "￼".
      - **A header cell that is a picture** is still what heads its row or its column,
        the cell itself, and VoiceOver reads it before the cells it heads by what its
        image is called: "Blue shield Low", and "Blue shield" at Control-Option-R,
        where a transcript had "￼ Low" and "￼".
      - **A picture among words.** The cell holds its text area and then the
        picture's image, and VoiceOver says the picture's words after the cell's:
        "Crest Worn ￼ daily, Blue crest image", where a transcript had "Crest Worn
        ￼ daily" and nothing of the picture. The words stay in a text area, where
        VoiceOver reads by word and reads the picture in its place, "Worn", "Blue
        crest image", "daily". What it costs: the picture's words come last wherever
        the picture stands among the cell's; the cell is "cell 2 items", at
        Control-Option-F3 and in its hint; and its words are a step further in.
        Control-Option-Shift-Down goes to the text area, "In Worn ￼ daily, Blue
        crest image cell 2 items text …", and pressed again into it, "In text Worn
        Blue crest image  daily", where one press went in; two presses of
        Control-Option-Shift-Up come back. Nothing else that was tried said the
        picture there at all. A cell without a picture is as it was.
      - **Going in.** A cell that is one picture has nothing to go into. At
        Control-Option-Shift-Down VoiceOver says "In Blue badge image image cell Blue
        badge image", the next Control-Option-Right moves on along the row, "Sense
        Open", and one Control-Option-Shift-Up then leaves the table. With the text
        area it went into the cell's text, "In text Blue badge image", which held the
        picture and nothing else.
      - **Off screen.** An image needs no text area, so a cell of pictures far off the
        screen in continuous scroll holds the images it holds on screen. A cell of
        words with a picture among them is labelled there with all of them, the
        picture's too, as any cell of words is, and holds nothing until its text area
        is on screen.
      - **Which cells.** A cell that is a link holds its link, whatever the link shows
        (A cell that is a link, below). A formula, a rule, a hidden label and a table
        inside a cell are not pictures: each is in its cell's text area, as before,
        and a cell that shows one of them and no words still holds a text area whose
        one character is the attachment's. None of these was heard.
      - **Not heard.** Anyone listening. A picture's cell off screen that VoiceOver
        moves to down a column. A header cell with a picture among its words or that
        is a picture nobody describes, and a column headed by a picture. A picture
        that stands before its cell's words. A cell of pictures continued on the next
        page, a spread of two columns, and a note's popover.
    - **A cell that is a link.** A cell whose words are one link and nothing else is
      pressed to follow that link, which is what Control-Option-Space asks of the item
      under VoiceOver's cursor, as a double tap follows it on iPhone and iPad. While a
      cell had no press, Control-Option-Space followed the fixture's link all the same, by
      means of VoiceOver's own that were not found out: a click where the cell stands,
      which follows a link only where its words are, or the press of something the cell
      holds. The cell also holds a link, with the role of the reader's
      links in text, and the link holds the cell's text areas, as a web view's cell holds
      a link around its words. That is what makes VoiceOver say that the cell is a link.
      The link is called by the cell's words too, which VoiceOver says once (A header
      cell that is a link, below).
      It says "Opened Reopened 1978 hyperlink" across the row and "Cedar Reopened 1978
      hyperlink" down the column, in pages and in continuous scroll, where it said "Opened
      Reopened 1978" and nothing of a link until the Actions menu was opened. Its hint
      says "You are currently on a hyperlink cell". "Hyperlink" is AppKit's word for a
      link in text, and what VoiceOver says of the reader's other links. Each of these was
      heard on a hosted runner
      ([VoiceOver testing](testing.md#voiceover-testing), the entry of 2026-10-13 on a table cell
      that is a link):
      - **What VoiceOver goes by.** Coming to a cell it says what the cell holds, and
        nothing of what the cell says it is. A press alone changed one thing it said: the
        Actions menu had three items where it had two. A subrole on the cell changed
        nothing. A
        role description changed the hint and Control-Option-F3, "Reopened 1978 hyperlink
        is in the VoiceOver cursor", and not what is said on coming to the cell. A cell
        with a link's role was passed over: Control-Option-Right went from "Cedar" to
        "Forty metres". A link in place of the text areas, called by the cell's words,
        said "Reopened 1978 hyperlink" and left the words out of reach, "In hyperlink
        Reopened 1978 content is empty". A link beside the text areas said the word
        twice, "hyperlink, Reopened 1978 hyperlink" with the link first and "Reopened
        1978 hyperlink, hyperlink" with it last, and made the cell "2 items". Only the
        link around the text areas said it once and kept the words.
      - **What it costs.** The cell's words are a step further in: Control-Option-Shift-
        Down says "In hyperlink Reopened 1978 text Reopened 1978", and pressed again "In
        text Reopened 1978", where one press went into a cell's text; two presses of
        Control-Option-Shift-Up come back. Control-Option-F3 says the word twice,
        "Reopened 1978 hyperlink hyperlink cell is in the VoiceOver cursor": what the
        cell holds, and VoiceOver's own name for such a cell. The Actions menu has a
        third item under Follow Link, VoiceOver's "press"; it was not chosen there.
      - **Which cells.** A cell with words beside its link, or with several links, has no
        press and holds its text areas as before: which link a press would mean is not
        the cell's to say, and each is an action by its words. In a note's popover a
        link does nothing, and a cell there has no press.
      - **A header cell that is a link.** A header cell whose words are one link, as
        where each row is headed by a link to its subject, is such a cell: it has the
        press and holds a link with its text area inside. VoiceOver says "Elm hyperlink
        column 1, row 3" down a column of them, "Built hyperlink column 2, row 1" along
        a header row and "Route Dogwood hyperlink" along its own row, where it said "Elm
        column 1, row 3", "Built column 2, row 1" and "Route Dogwood" while a header
        cell held its text area itself, and nothing of a link. It is still what heads
        its row or its column, the cell itself, which VoiceOver does not read under
        itself, and the cells it heads are read as they were: "Dogwood 1912", "Built
        Relaid 1960 hyperlink", "Built" at Control-Option-C and "Dogwood" at
        Control-Option-R. That took a title on the link. VoiceOver reads a header cell,
        before each cell it heads, by what each thing the cell holds is called, and
        looks no further in: a text area by its value, a link by its title. With the
        link that other cells then held, which had its text area inside and no title
        while that was on screen, a header cell left the cells it heads without their
        headers: "1912" for "Dogwood 1912", and "column 2 of 3" and "row 2 of 4" at
        Control-Option-C and Control-Option-R. So the link of every such cell has the
        cell's words for its title, on screen and off it. VoiceOver says them once as
        it comes to the cell, title and text area both being there, and going in says
        "In hyperlink Elm text Elm", the form it had for a link without the title. Five
        other ways were heard and not kept
        ([VoiceOver testing](testing.md#voiceover-testing), the entry of 2026-10-13 on a header
        cell that is a link). The header given by its words, as the static text that
        stands for a header off screen, or as the cell's own text area, read the cells
        it heads and said a header cell's name before the cell itself, "Elm Elm
        hyperlink" and "Built Built hyperlink": what heads the row was then no longer
        the cell. The header given as the cell's link said nothing of it. A value on
        the cell was read at Control-Option-R and not on coming to a cell it heads or
        at Control-Option-C. A label on the link read as the title does.
      - **Off screen.** A cell's press follows its link from the text area that shows
        it. A cell far off the screen in continuous scroll has none until VoiceOver's
        cursor brings it there, and its press does nothing till then. Its link holds
        nothing till then and is called by the cell's words as it is on screen; a link
        cell off screen was not itself heard. A header cell that is a link heads its
        column or its row by name while it is off screen, as any header cell does.
      - **After the link is followed.** In pages VoiceOver read the new page and was on
        its text area, a Control-Option-Shift-Down from its first line, in each of four
        sessions that pressed a cell without having gone into its words, two of them on
        the shape that was kept. Before the press, with the click, it left the text for
        the window's first button in two sessions of three. It did when the cell was
        pressed after VoiceOver had been into the cell's words and come back out (one
        session on the shape kept, three in the trial), which is the page turned under a
        table's element of [#485](https://github.com/vocaro/EPUBLib/issues/485); with the
        change for it, where the column takes the keyboard focus from a cell's text area
        that goes, VoiceOver was on the new page's text area there too, in one session
        (Data tables, Pages). In continuous scroll the view went to the link's target and
        VoiceOver was on the text area, entering at the target's line, before and after
        alike.
    - **Header cells, and VoiceOver quitting.** AppKit lets a cell name its own header
      cells, which is how HTML has them and what a web view does. Given that, VoiceOver
      [quit](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#a-cell-that-names-its-own-header-cells-makes-mac-voiceover-quit)
      at a move to a cell under a header or at Control-Option-C, whatever the header was:
      the cell listed in the header's row, holding a text area, a label as well or a label
      alone (three sessions of three at two seconds a key, and two of those recorded at
      four), or an element of its own with a label (one session of seven at two seconds).
      It quit the same way in Safari (Beside Safari, below). So no cell names a header. The
      table does, as AppKit's own tables do: one header for each column and one for each
      row of the whole table, and VoiceOver takes the one at a cell's column and at its
      row. With that it said the same headers and did not quit, in seventeen sessions at
      two or three seconds a key and ten at four. Whether to tell Apple is
      [#483](https://github.com/vocaro/EPUBLib/issues/483).
      What heads a column or a row is its one header cell, where that cell is on screen
      with its text areas: VoiceOver
      [reads a header cell by what the things it holds are called](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#mac-voiceover-reads-a-header-cell-by-what-it-holds),
      a text area by its value and a link by its title, and does not read a cell under
      itself. Otherwise it is a static text with the words of its header
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
      turned as from a line. A page turned with VoiceOver's cursor on a row's element,
      where it is once it has gone into a row and come back out, leaves it in the text, as
      a turn from a line does: for a table of data and for a row group, by the host's Next
      Page, a page key or the text area's Next Page action, and in a spread, where it
      stays in the column it was in. Its next move by line reads the new page's first line
      and by word that line's first word. At the turn VoiceOver says "text", and
      Control-Option-F3 "text is in the VoiceOver cursor": from a row group with the new
      page's first line after "text", and from a table of data without it. In a spread it
      says "2 updated items", from a row group with the first line after it, and from a
      table of data with the new first row's words before it. A table of data's element is
      still a table to VoiceOver after the turn, whatever its role: VoiceOver
      [keeps what it made of an element](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#voiceover-keeps-what-it-made-of-an-element)
      when it first met it, and finds that again by the element. Its
      table says "empty" while it has no rows, the greater of the row count and the number
      of rows given, and when asked what it is on "3 columns, 41 rows" while it has a row
      and a column. So a departed table gives one row that holds nothing, a row count of
      one and no columns, and VoiceOver says neither. With no rows it said "empty" and
      "empty text is in the VoiceOver cursor", and with the whole table's counts "text" and
      "text 3 columns, 41 rows"
      ([#485](https://github.com/vocaro/EPUBLib/issues/485#issuecomment-6272726811)
      has VoiceOver's code that decides it, read without running it, and the sessions).
      Two things keep VoiceOver in the text. VoiceOver
      keeps its cursor on an element only while the element is among the children of the
      text it is in, and a page turn gives the column the elements of other rows. So the
      row elements of the page before stay among the column's children until its text is
      replaced again (`ReaderTextView.departedRows`), each a static text with nothing in
      it, standing at the line the new page is entered at: its first, or after a place
      shown the place's line (Pages, under Layout), which was not heard with a row's
      element under the cursor. Without them VoiceOver went to the text
      area, out of the text, a Control-Option-Shift-Down from the page's first line; as an
      empty table or group it said "table" or "empty group". A layout change naming the
      column, posted by the element, by the column or by the window, at once or half a
      second later, and the insertion point told of again, each left VoiceOver where it
      went. And VoiceOver gives the keyboard focus to each text area it moves to, a row
      group's cells among them, and leaves it there when it comes back out to the row. The
      page took that text area away with the focus, the window had it, and VoiceOver,
      following it, went to the window's first button. The column that showed the cell
      takes it now (`TableCellTextView.viewWillMove(toSuperview:)`). After VoiceOver had
      gone into the words of a cell that is one link and back out, Control-Option-Space on
      the cell left it on the new page's text area, "text is in the VoiceOver cursor Line
      1", with the keyboard focus on the column, where on
      [#508](https://github.com/vocaro/EPUBLib/pull/508)'s branch it went to the window's
      first button; it is not in the text there, as its cursor was on the cell and not on
      a row's element. The cost is the word: VoiceOver says "text" for the element after
      the turn where a turn from a line says the line, the elements are among the column's
      children for the length of a page, and a departed table gives any client a static
      text with a row count and one row.
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
    - **A table that is not data.** A row of a table the book marks as layout, or that
      nothing marks as data, is a group where its character stands, which holds the text
      areas of its cells on screen. As it reads the text VoiceOver
      [says what a group is called and "group", and nothing of what the group holds](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#mac-voiceover-reads-a-group-by-its-name-and-nothing-of-what-it-holds). Called "Table row", every
      such row said "Table row group": a listener who read on by line, by word or with
      Read All passed the table's words unsaid, and heard them only by going into each
      row. The group is now called by its cells' words in column order, with a comma
      between cells and a cell without words left out, as the table at a row of a table
      of data is: "Left side, Right side group", "Lower left, Lower right group", by
      line, by word and with Read All. A cell's words are what the cell reads: a
      described picture's and a formula's among them ("Drawn Blue entry square shown.",
      "Sum x squared stated."), a hidden label's, and those of a table inside it.
      iPhone and iPad read such a row by the same words, "Left side Right side". There a
      row is one item of text with actions for its cells; on a Mac its cells are text
      areas to go into, so the row is a group and VoiceOver says so.
      Control-Option-Shift-Down goes into the row as before: "In Lower left, Lower right
      group 2 items text Lower left", then "text Lower right" at the next cell, "In text
      Lower right" on going into that cell, where VoiceOver reads by word and by line,
      and "Out of Lower left, Lower right group" on leaving the row.
      The group says what it is called and what it holds when it is asked, and is the
      same element whether or not its cells are on screen. It was made from what was on
      screen at the moment the text was asked for it: a row whose cells' text areas were
      not there was an image called by its words, with nothing to go into, and VoiceOver
      keeps the element it is given. In continuous scroll that is a row beyond the
      screen, and one session met it another way: moving by word after leaving a row,
      VoiceOver said "First cell Second cell image", a tab between the cells, of the row
      it had just been inside, where it now says "First cell, Second cell group". Why
      that row's text areas were not there at that moment was not looked into; rows the
      view had moved to without the person scrolling had none until
      [#494](https://github.com/vocaro/EPUBLib/pull/494), which that session did not
      have. With it the row says the same.
      What it costs. VoiceOver says a row's words again on going into the row, before
      the first cell's, and on leaving it: into a row of long cells that is some seconds
      before the cell's own words, which the row's began with. A row is one phrase, so a
      row of long cells is a long one, which the next key stops; in pages a row taller
      than a page is called by the words that page shows. "group" follows every row.
      A row that shows pictures nobody describes and no words has none to be called by,
      and its group has no name. VoiceOver then says what the group holds, in its own
      words and the listener's language: "text image text image group" for a row of two
      such pictures, by line, by word and with Read All; "In group 2 items text image"
      on going in, "text image" at each cell and "image" inside one; and "Out of group".
      The row was called "Table row" and said "Table row group": a name of the reader's
      own, in English, for something the book does not name, which told a listener
      nothing of the pictures. A picture nobody describes is given no name either, and
      VoiceOver says "image"; iPhone and iPad give such a row as an image without a
      name. Where the group has no name it has no help: VoiceOver reads an element's
      help in a missing name's place, and the sentence about Inspect Image would have
      been the row.
      What a row without a name costs. The phrase is as long as the row is wide, "text
      image" for each cell. In continuous scroll, with its cursor on the group it has
      just left, VoiceOver says "group" alone, and "group is in the VoiceOver cursor":
      the group holds nothing for it at that moment, where on a page it holds its
      cells. Moving on by line or by word reads the row whole again. The application
      posts a change of value as VoiceOver leaves a row there and not on a page, and
      did before the name went, so a named row may be in the same state with its name
      to hide it; why was not looked into. The hint about Inspect Image that followed
      "Table row group" is not said, though VoiceOver's own "actions available" is.
      A row with nothing to say, of empty cells or of decoration alone, was "Table row
      group" as well, and is passed over now (A row that has nothing to say, below).
      A row's pictures are offered from its group, Inspect Image with the picture's
      words. VoiceOver's Actions menu holds them while its cursor is on the group,
      which it is after going into the row and out again: the row's own actions first,
      and on a page those of each cell's text after them, "show menu" and Inspect
      Image. Chosen there, Inspect Image opens the inspector. While VoiceOver reads
      the text its cursor is on the text area, and its menu on a row's line holds the
      page actions and no picture's.
      A row of a table of data that shows a picture is its table, as its other rows
      are: "Blue badge, Open table", and "Shut table" for the row of a picture nobody
      describes, the words of the cell beside it. VoiceOver goes into the table at
      that row. It was given as a row's group, because the text looked for a row's
      pictures after its tables and put the group in the table's place. What the cell
      that holds the picture says is under A cell that shows a picture, above.
      Not heard: a row off screen that VoiceOver reads to by line before the view has
      moved; a spread of two columns; a
      note's popover; and what Safari says of the fixture's two plain tables, which
      the comparison below did not open
      ([#509](https://github.com/vocaro/EPUBLib/issues/509)).
    - **A row that has nothing to say.** A row whose cells hold nothing, or decoration
      alone (a picture with an empty `alt`), spaces out a table used for layout, and a
      table of data can have one too. iPhone and iPad list no element for such a row. On
      Mac VoiceOver is given nothing to stop on there
      ([a row with nothing to say](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#a-row-with-nothing-to-say-must-fold-into-the-next-line)).
      The text gives no element at the
      row's character, gives that character and the break after it as spaces, and gives
      the row's line as part of the line after it. Moving by line or by word, forward or
      back, and reading on with Read All, VoiceOver goes from the row of words above to
      the row of words below, "Upper near, Upper far group" and then "Middle near, Middle
      far group", in pages and in continuous scroll, and it goes into either of them as
      before. It takes all four parts, which was found on a hosted runner one at a time
      ([VoiceOver testing](testing.md#voiceover-testing), the entry of 2026-10-13 on rows that
      have nothing to say):
      - **As such rows were.** What one was turned on things a listener could not know.
        A row of a table of data gave its table, which has no name there: a bare "table"
        at each. In a table that is not data a row was a group when its text equivalent
        was not empty, and a row's is its cells' words with a tab between cells. So in
        continuous scroll a row of two empty cells was a group that holds nothing,
        "group", and going in said "In group content is empty"; a row of two cells of
        decoration was "text text group" in both flows, a text area for each cell; and a
        row of one empty cell had no element. On a page a row is given by the cells with
        lines on that page, an empty cell has none, and the row of two empty cells had
        no element either. Where the text gave no element VoiceOver stopped all the
        same: on a line with nothing said, by line and with Read All, and at a step with
        nothing said by word.
      - **No element is not enough,** as those rows show. VoiceOver stops at an
        attachment's character whatever the text gives there, and at static text without
        words it stopped in the same silence.
      - **A space for the character** is what VoiceOver passes over moving by word. The
        text's value, its string and its attributed string give one, at the attachment's
        place, so that every range still matches the text. Moving by line it still
        stopped on the row's line and said nothing.
      - **No line of its own** is what it passes over moving by line: the row's line is
        part of another, in the lines the text numbers for an assistive client. Which
        other matters. Part of the line before, the row was passed over by line, and the
        row of words in that line could no longer be gone into from a move by line:
        Control-Option-Shift-Down did nothing there, and Control-Option-Shift-Up then
        left the text. VoiceOver leaves its place at the end of a line it has read and
        goes into what stands there, which was the space. So the row is part of the line
        after it, which ends with the row of words.
      - **A space for the break** after the row is what lets VoiceOver say that line. It
        says of a line what comes before the line's first break: with the row's own break
        left in the line, it said nothing where "Middle near, Middle far group" was due,
        though it went into that row. As spaces the row and its break are the blank
        start of the next row's paragraph, and Read All, which had said a phrase with
        nothing in it for the row's paragraph, says nothing of it.
      - **Which rows.** What a row has to hold to be passed over is nothing: no words,
        and nothing besides but spaces and decoration, in the cells a page shows of it,
        and in a table inside one of its cells likewise
        (`TableRowAttachment.saysNothing`). A row that shows a picture nobody describes
        is still its group, "text image text image group". A row that holds a link is
        not passed over whatever the link holds, because a link has to be reachable, and
        neither is one that holds a rule or a formula.
      - **Inside a table of data** the row is still a row. VoiceOver goes into the table
        at a row of words, and its table navigation goes through this row's cells as
        through any others: "Tree empty cell", for a cell of decoration as for a cell
        with nothing in it (A cell, above).
      - **What it costs.** What an assistive client reads is not character for character
        what the view holds: two spaces stand where the row's attachment and its break
        do. The lines a client counts are fewer than the lines laid out, by one for each
        such row, and VoiceOver's cursor is drawn round the row and the row of words
        after it together, which are one line to it. In continuous scroll the lines are
        AppKit's and are numbered through the whole book, so the number given for a line
        is AppKit's less the rows passed over before that line, and a line asked for by
        number takes a further question to AppKit for each run of such rows on the way
        to it. The rows are found once for each text a view is given, by reading every
        table row's cells. Nothing in the text leads to such a row: its cells are
        reached only inside a table of data. Rows with no line after them, at the end of
        a page or of the book, are one line of spaces together, where VoiceOver stops
        once; so is a page that holds nothing else.
      - **Not done.** A table inside a table cell is read from the cell's own text,
        where such a row is as it was
        ([#458](https://github.com/vocaro/EPUBLib/issues/458)). A row without words
        whose one cell with anything in it holds a link or a rule is a group in
        continuous scroll where it has a second cell, and has no element on a page, as
        before ([#527](https://github.com/vocaro/EPUBLib/issues/527)).
      - **Not heard.** Rows that end a page, and a page of nothing but such rows; a row
        of spaces; a row that opens a section; two such rows together; a spread of two
        columns; a note's popover; Safari on this section; anyone listening. What the
        line numbering costs on a long book was not measured
        ([#529](https://github.com/vocaro/EPUBLib/issues/529)).
    - **Beside Safari.** The same sections were heard as web pages in Safari 27.0.1 on
      the same runner, with the same keys
      ([VoiceOver testing](testing.md#voiceover-testing), the second entry of 2026-10-13 on tables
      of data on Mac, which has both sets of phrases). Safari gives a table as one
      `AXTable` with rows, columns, cells that say which rows and columns they cover, and
      header cells for its columns and rows, which is what the reader gives at each row.
      Three things differ in what is given: Safari's table is named by its caption, its
      cells name header cells of their own, and it says which cells are selected and not
      which row. The headers are heard alike: crossing a row VoiceOver says the column's
      header and the cell, down a column the row's, each once until it changes, and
      Control-Option-C says the column's header. The rest of what VoiceOver says differs,
      and most of that is VoiceOver's: it has
      [one way of speaking for a table in a web page](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#safari-reads-tables-with-web-page-speech)
      and another for a table anywhere else (`SCRWebTable` and `SCRTable` in the reports
      macOS wrote). Two things a listener in the reader does not get, with what
      closing each would take, and two that were closed after the two were heard:
      - **The table's size, its name and its end.** Safari: "Stations on the branch
        table 3 columns, 4 rows" on coming to the table, and "end of table" past its last
        cell. The reader: the caption as a line, "Station, Opened, Depth table", and after
        the last row the next line of the text. VoiceOver says a table's size when its
        cursor comes to the table itself, and in a text it reads an attachment by what
        the attachment is called and its role. So the reader would say it: the table at
        a table's first row called by the count too, or by the caption, in words of the
        reader's own that need translating, where VoiceOver's are translated for it. The
        size is worth it, because it tells a listener whether to go in. It is to be heard
        on a runner first: what VoiceOver does with more in that label is not known.
        Whether the caption is to name the table is with
        [#486](https://github.com/vocaro/EPUBLib/issues/486); in Safari it does, and it is
        no item of its own.
      - **Where a cell stands.** Safari says "row 3 of 4" at each new row and "column 2 of
        3" at each cell. The reader says the headers, and a number only where nothing
        heads a row or a column ("column 2 of 2 Wet"), where VoiceOver cannot move on
        ("Stopper column 1, row 4"), and at Control-Option-R in a row no cell heads ("row
        4 of 41"). Down the long table that is "Item 02", "Item 03" against "row 3 of 41
        Item 02", "row 4 of 41 Item 03". It is VoiceOver's speech for a web page's table;
        nothing was tried that might bring it to another, and numbers put into each
        cell's own words would be said in the reader's English at every cell. Not worth
        closing that way.
      - **A cell that is a link.** Safari: "Opened link Reopened 1978 column 2 of 3", with
        VoiceOver's cursor on the link, whose Actions menu has "press". The reader said
        "Opened Reopened 1978", and "actions available" in the hint that followed; "link"
        was not said, and Follow Link was in the Actions menu. Control-Option-Space on the
        cell did follow the link in the two sessions that pressed it, though the cell had
        no press. Closed since: the cell has a press and holds a link around its words (A
        cell that is a link, above), and VoiceOver says "Opened Reopened 1978 hyperlink".
        What still differs is VoiceOver's: it says "hyperlink" after the cell's words
        where in a web page it says "link" before them; Control-Option-F3 says "Reopened
        1978 hyperlink hyperlink cell is in the VoiceOver cursor" where in Safari it says
        "Reopened 1978 link is in the VoiceOver cursor"; and going in says "In hyperlink
        Reopened 1978 text Reopened 1978" where in Safari it says "In link Reopened 1978
        Reopened 1978".
      - **A table that is not data.** Safari reads the four cells of the table marked as
        layout as four items with their words: "Left side", "Right side", "Lower left",
        "Lower right". Beside it the reader said "Table row group" at each row and none
        of the words, as it had for every table; they were heard only by going into each
        group. It was the largest of the four, because words of the book went unsaid to
        a listener who read on. A row's group is called by its words since (A table that
        is not data, above): "Left side, Right side group", "Lower left, Lower right
        group". What still differs is that a row is one phrase with VoiceOver's "group"
        after it, and a cell a step in from its row.

      Where the reader gives more: a row's words in one phrase as the text is read; going
      in at the row the listener has reached, where Safari goes in at the first cell;
      both header cells over a column ("Hours, Leaves Nine", where Safari said "Hours
      Nine"); and the row's header at Control-Option-R ("Birch", where Safari said "row 3
      of 4"). Safari says "spans 2 columns" of a cell that spans, where the reader reads
      such a header cell under the first of its columns, "Hours, Leaves Hours"; that is
      the cost of one header for a column, given above.
      Two things Safari did are faults of its own. It gave the cells that span rows in
      the table of spans as one row deep, so that "Leaves" stood in the first column
      under "Service": that table's rows are children of `table`, as XHTML allows, and
      WebKit's accessibility code ends a row group after each such row. So Safari did not
      show how it reads a header under another. And VoiceOver quit at Control-Option-C in
      three of ten sessions of Safari that pressed it, with the exception it raised in
      the reader, here from its method for a web page's cell
      (`-[SCRWebTableCell columnHeaderDescription]`). Safari's cells name their own
      header cells; the reader's name none, and the table gives the headers. So the fault
      can be shown to Apple with Safari and a table, and no app of ours
      ([#483](https://github.com/vocaro/EPUBLib/issues/483)).
    - **Not done.** A cell offers no page turn: the text area does, one step out of the
      table. Nothing gives VoiceOver the table's caption as the table's name; it is a
      line of the text before the rows or after them, as it is drawn. Both are to be
      decided, with the header cell under another and where VoiceOver is after it leaves
      a table ([#486](https://github.com/vocaro/EPUBLib/issues/486)).
    - **Not heard.** Anyone listening, or a Mac that is not the hosted runner. Apple Books
      on a Mac. Beside Safari, a header under another in a table whose rows stand in
      `tbody`, a link followed out of its section, and the reader in continuous scroll. A
      table in a spread of two columns, one in a note's popover, Read All through a table,
      and VoiceOver in a language other than
      English ([#484](https://github.com/vocaro/EPUBLib/issues/484)). Of a cell that is a
      link: one far off the screen in continuous scroll, one whose link is a picture, one
      continued on the next page, a header cell given a link to hold, and a link whose
      target is on the page or the screen already.
  - **Not done.** A table inside a cell is read as its cell's words, as before. Headings
    inside a table are not found by the Headings rotor, as before.
  - **Not resolved.** On an iPhone simulator the rotor once went from Rows to Actions part
    of the way back up a column in continuous scroll. A physical iPad did not do it in
    seventy such moves, nor did the simulator in a later session of fifty-four. A cell
    offers its actions only once it is on screen, which may be why
    ([VoiceOver testing](testing.md#voiceover-testing), the entry of 2026-10-12 on tables of data).
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
  - **Shown.** UIKit
    [draws a text view's selection only while the view is first responder](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#voiceover-keeps-an-items-traits-and-actions-as-it-found-them).
    A selection set in code was held, reported to the host and copied from, and nothing showed
    it: after the action the screen was as before, but for the selected words' ink, which the
    cell draws over the row's own and which looked a little heavier. A cell's text view now
    paints a selection it holds whenever UIKit is not drawing it, in UIKit's tint for selected
    text, and leaves it to
    UIKit while it is first responder. That shows every selection set in code and not this
    one alone: a located passage in a table, in each cell it runs through that cell's
    share, and a selection carried across a new layout. The reader takes no keyboard focus
    to show it, which would close a keyboard elsewhere in the window.
  - **Said.** VoiceOver keeps what an item offers as it found it (the same article): on an
    iPad its rotor went on offering Select Cell Text, and none of the three actions below, after
    the words were selected. The item of a cell whose words are selected has UIKit's selected
    trait, and after selecting or deselecting the reader posts a layout change that names the
    item. VoiceOver then reads the item again, "selected" before its words in
    VoiceOver's own language or without it, and takes the item's actions as they now are. A
    listener who comes back to the item later hears "selected" again. On a row it is the
    row that is read as selected, and its actions name the cell. The reader announces one
    thing itself, "Copied", because copying changes nothing a listener could tell: the word
    is the reader's and English, as "Separator" is at a rule, and is queued behind whatever
    VoiceOver is saying.
  - **What it is for.** A selection made by touch brings up the edit menu, with Copy and the
    host's selection action, and one set in code brings up none. So the item whose cell holds
    selected words offers, where its select action stood, Deselect Table Text or Deselect Cell
    Text, Copy, and the host's selection action by its own title when the host gave one. Copy
    and the host's action are the edit menu's: the whole selection's text, and the host is told
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
    ([VoiceOver testing](testing.md#voiceover-testing), the entry of 2026-10-13 on a table's cells
    in continuous scroll). The unit tests perform the cell's actions in both flows.
- **Footnotes.** EPUB 3 `noteref` links show their note in a popover. Footnote `aside`s are
  hidden from the flow, whether or not anything refers to them; endnotes and other notes stay
  in place and also show in popovers. Plain links into another document inspect captured notes
  before navigating, and a later activation or navigation command supersedes an earlier lookup
  ([#257](https://github.com/vocaro/EPUBLib/issues/257)).
  - A footnote hidden from the flow has nowhere else to be read, so a link may name it or
    any element inside it (its first paragraph, a later one, the text after its number) and
    the popover shows the whole note either way. A note inside such a footnote is hidden with
    it and is named the same way.
  - A note that stays in the flow is named by its own id and by the ids of its leading
    descendants (its first child, and that one's): a link may name its first paragraph or
    the number that opens it. A link to any other element inside it finds no note and
    navigates to that element, which can be read where it is. An endnotes list marked as one
    note is the case that matters: a reference to its seventeenth item goes to that item
    rather than opening the whole list from the top, and so does one to its first item. The
    leading descendants end at the first of several items: an element followed by another of
    its name that carries an id itself or on its own first element, when the element around
    them holds no text of its own. The paragraphs, list items or rows of such a list are
    items; the elements in a paragraph's text and the cells of a row are not
    ([#284](https://github.com/vocaro/EPUBLib/issues/284)).
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
    flow, or its first of several items). Deeper into a note that is in the flow it is an ordinary link and navigates.
    Inside a popover, a link to the note being shown is plain text.
  - A legacy `<a name>` names a note, and is a fragment target, as HTML 7.4.6.4 finds the
    element a fragment indicates: the element whose id it is comes first, then the first `a`
    whose `name` it is, whether or not that `a` has an id as well, so `<a id="page12"
    name="p12">` answers to both. Inside a table, formula or image the name points at it, as
    an id there does ([#133](https://github.com/vocaro/EPUBLib/issues/133)). Table cells and
    captions inside a note inherit its backlink and nested-note rules.
  - `epub:type` is read only where EPUB 3.3 allows it, and EPUB Reading Systems 3.3 §10 has a
    reading system ignore it anywhere else: not on the `head` or anything in it, nor on HTML's
    metadata content (`title`, `meta`, `link`, `base`, `style`, `script`, `noscript`,
    `template`) wherever it stands, and in SVG only on a renderable element. A
    `title` typed `footnote` is no note, and a `noteref` to it opens none (W3C test
    `pss-support_ignore-title`). A DPUB-ARIA role on one of those elements makes no note
    either: ARIA in HTML allows those HTML elements no role
    ([#133](https://github.com/vocaro/EPUBLib/issues/133)).
  - What a note holds is disclosed once. The section counts it where it shows it, in the flow
    or in a table's cell, and the note's own rendering for its popover counts only what the
    section shows nowhere else: a footnote hidden from the flow, a note in hidden content
    ([#258](https://github.com/vocaro/EPUBLib/issues/258)).
  - A footnote `aside` with neither an id nor an eligible name anywhere in it cannot be
    referred to and is not shown.
  - An empty id names nothing: a link to `#` goes to the top of its document, whatever
    carries `id=""`. A note that shows nothing, being empty or white space, opens no popover,
    and a reference to it navigates. In a note's popover a list item that shows nothing,
    because what it holds is a note shown on its own or is empty, has no marker
    ([#284](https://github.com/vocaro/EPUBLib/issues/284)).
- **Paragraph sizing.** The native section builder retains authored paragraph dimensions until
  layout. Percentage margins, padding and text indents resolve against the live containing
  content width, including constrained float and inline-block ancestors. Image percentage
  widths and min/max widths use the enclosing content box in floats, positioned boxes and
  sized inline blocks, while `vw`/`vh` retain the viewport. Intrinsic measurement defers
  percentages until that containing width is known ([#148](https://github.com/vocaro/EPUBLib/issues/148)).
  Vertical percentage
  margins and padding also use that width; adjoining margins collapse before paragraph spacing
  is installed. Insets remain bounded to preserve a readable column. Paginated layout resolves
  dimensions before measuring and removes resize metadata from page slices so continuation
  indentation and spacing do not repeat. Continuous-scroll layout starts from immutable source
  dimensions on each resize, changing attributes while preserving characters, selection ranges
  and DOM maps. A list item's first line takes its `text-indent` after an outside marker,
  which stays outside the item's box (CSS 2.2 16.1), in the item's own paragraph and in a first
  paragraph inside it. A negative indent there, which would set the line's first words over
  the marker, is not applied ([#133](https://github.com/vocaro/EPUBLib/issues/133)).

  `ex` lengths use CoreText's x-height for the face selected by the font registry, including
  embedded `@font-face` resources. An `ex` font size uses its parent's metrics. Font metric
  work runs only for actual `ex` units; ordinary lengths keep the existing inexpensive
  computation. Fonts without a usable metric fall back to half the em size.

  Centered `figcaption` text at `0.9em` is an intentional user-agent reader default. Explicit
  author alignment overrides it through the existing cascade
  ([#21](https://github.com/vocaro/EPUBLib/issues/21)).
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
  ([record](https://github.com/vocaro/EPUBLib/issues/20#issuecomment-6159295296)).
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
    some language has to be chosen anyway: the CoreText language attribute, which
    [steers glyph choice and line breaking](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/text-layout-and-unicode.md#content-language-steers-glyph-choice-and-line-breaking)
    (every run of an unlabelled document in a Japanese book is
    tagged `ja`, so its Han characters take their Japanese forms), the language a formula
    is spoken in (see Spoken math), and the language each item VoiceOver is given on iPhone
    and iPad names for its words ("Language" under Input and accessibility). So typesetting
    is not independent of the package, which is the sense in which the reading is narrow.

  Content that declares a language overrides the package for both, and `lang=""` (the language
  is unknown) leaves text without a language or the hint. `:lang()` selectors and the search
  locale read the document alone. The base-direction half of the requirement is met in full:
  a document that declares no direction reads the same whatever the package's `dir`.
  foliate-js gave a document without `lang` the book's language, so its `q` marks followed
  the package.
- **Generated content.** `::before` and `::after` generate their `content` (CSS 2 §12.1, CSS
  Generated Content 3): strings; `attr()`; `open-quote`, `close-quote` and their `no-` forms,
  with `quotes`; and `counter()` and `counters()`, with `counter-reset`, `counter-increment`
  and `counter-set` (CSS Lists 3 §4) in the counter styles `list-style-type` has
  ([#131](https://github.com/vocaro/EPUBLib/issues/131)). A pseudo-element is styled by its
  own rules and inherits from its element. One written alone, as in `*, ::before, ::after`, is
  that of any element (Selectors 4 §3.7, [#110](https://github.com/vocaro/EPUBLib/issues/110)).
  `none`, `normal`, a rule with no `content` and `display: none` generate nothing. The marks
  around a `q` are generated the same way, from the user-agent sheet's `q::before` and
  `q::after` as HTML gives them, so a book's `quotes`, and the reset stylesheets that write
  `q:before, q:after { content: none }`, apply to them as they do in a browser. Before, the
  marks were drawn whatever the book's styles said. With `quotes: auto` the marks are CLDR's
  for the content's language, script and region, outer and inner, as the platform's locale
  data has them: “ ” in Brazilian Portuguese and Turkish, « » in European Portuguese,
  «bonjour «toi»» in French, with no space added inside them, as Firefox, whose table is made
  from CLDR, shows them. Arabic and Hebrew take CLDR's marks, where Apple's locale data has
  the typewriter `"` and `'` ([#133](https://github.com/vocaro/EPUBLib/issues/133)).
  - **Where it stands.** An inline box is written in its line, and white space collapses
    across it as across the book's text. A block box is a paragraph of its own. A box that
    floats or is positioned is written in its line, with the disclosure of the boxes left in
    the flow; one that a position or a clip hides from the page is not written.
  - **The text map.** Generated characters are not the book's: they have no place in the
    document, and the text map has no span for them, as it has none for a list marker or a
    bidi isolate. A position among them is that of the book's next character, and a range of
    generated characters alone runs from the book's character before them to the one after,
    the place they are generated at ([#129](https://github.com/vocaro/EPUBLib/issues/129)). A CFI names
    the book's characters alone, the same CFI with or without the styles that generate:
    a selection that takes in generated words is saved without them and comes back without
    them. Search reads the book's text, as foliate-js's did in WebKit, and finds nothing in
    generated words, and a result's context leaves them out. The passage text a host is
    given (`.selectionChanged`, a location's `quote`, the text `.locate` looks for) and what
    Copy puts on the pasteboard are the book's own characters (the authored passage of
    [#128](https://github.com/vocaro/EPUBLib/issues/128)), as `Selection.toString()` gave
    foliate-js and as a browser copies no `::before` text, so a quote can be found again.
    What is drawn holds them: they are selected with the text around them, and VoiceOver
    reads them where they stand, as it reads a list marker and a `q`'s marks. A heading's
    text begins with the words it generates, and an element's id points at its `::before`.
  - **Counters** change in one walk of the section in document order, a table's cells and
    captions included. A table's rows and row groups, which only a grid lays out, change
    theirs where their first cell's content is rendered. A counter's scope is the element
    that instantiates it, its descendants and its following siblings with theirs. A note's
    popover counts from where the note stands, and a footnote hidden from the flow counts
    there as it would shown, so footnotes numbered by a counter are numbered in order.
    `list-item` is each list's own numbering, the values its markers show.
  - **Light and dark.** In a rule for one appearance (`prefers-color-scheme`), what decides
    generated characters is resolved as in the light appearance: from a rule for light it
    applies in both, and from a rule for dark in neither. That is `content`, `quotes` and the
    counter properties on any element, and on a `::before` or `::after` also `display`,
    `text-transform`, `white-space`, `font-variant-caps`, and the `position`, `top`, `left`,
    `clip` and `clip-path` that hide a box. What paints still follows the appearance. So a
    section has the same characters in light and dark, which saved positions, search results
    and highlights rely on; [#130](https://github.com/vocaro/EPUBLib/issues/130) resolves an
    element's own properties the same way, all but what paints.
  - **Disclosed.** What is not shown has the `.disclosure` that "some text or images this
    book's styling adds before or after its content are not shown": an image in `content`
    (`url()`, `image-set()`, a gradient), `leader()`, `target-counter()`, `target-counters()`,
    `target-text()`, `contents`, and an `attr()` with a type or a fallback; the generated
    content of a table laid out as a grid and of its rows and row groups, where that of its
    cells and captions is shown; and what passes a bound of 1,048,576 UTF-16 units of
    generated text in one section, which only a hostile stylesheet reaches.
- **Calculations.** `calc()`, `min()`, `max()` and `clamp()` follow CSS Values 4 §10 for
  numbers, lengths and percentages ([#122](https://github.com/vocaro/EPUBLib/issues/122)).
  - **Factors and divisors.** Any sub-expression that is a number can be a factor on either
    side of `*` or a divisor after `/`: a parenthesised sum, a nested function or a constant
    (`e`, `pi`, `infinity`, `-infinity`, `NaN`). A number depends on nothing, so it is worked
    out when the value is parsed.
  - **Typed arithmetic.** A product of two lengths, and a division by a length, are invalid
    ([#761](https://github.com/vocaro/EPUBLib/issues/761)).
  - **Infinity and NaN.** Division by zero gives an infinity, and zero by zero gives NaN, which
    `min()`, `max()` and `clamp()` return whatever their other arguments. At the top of a value,
    an infinity becomes the end of the range the property allows (`StyleLimits`) and NaN
    becomes 0.
  - **Where numbers go.** A math function that comes to a number stands wherever a number
    does:
    - `line-height`;
    - `font-weight`, in `font` and `@font-face` too;
    - `filter: invert()`;
    - `order`, `flex-grow` and `flex`;
    - `repeat()` counts and counter values.
    
    Where an integer is wanted it is rounded to the nearest, a half upward. Out of range it is
    clamped to the range rather than refused, as an out-of-range literal is. Colour channels
    take literals only ([#760](https://github.com/vocaro/EPUBLib/issues/760)).
- **Custom properties.** Custom properties (`--name`) and `var()` follow CSS Custom
  Properties for Cascading Variables 1 ([#119](https://github.com/vocaro/EPUBLib/issues/119)).
  A custom property is declared on any element, `:root` and pseudo-elements included, in a
  rule or a `style` attribute; it cascades with `!important`, and with `inherit`, `initial`,
  `unset` and `revert`, as any property does, and inherits; `all` leaves it alone; its name is
  case-sensitive. Its computed value is its tokens with every `var()` substituted, and
  `initial`, a cycle or a failed substitution give it the guaranteed-invalid value. A
  declaration of another property that holds a `var()` is valid at parse time when its
  `var()`s are, and is substituted and parsed at computed-value time, a shorthand as a whole
  and the sides by flow by the element's direction; `var()` substitutes tokens, not text, so
  it works inside `calc()` and `var(--n)px` is no length. When that fails, the declaration is
  invalid at computed-value time and acts as `unset`: an earlier declaration of the property
  does not apply instead. `var()`'s grammar is the one Variables 1 now takes from CSS Values 5:
  its name argument may itself hold a `var()` or be wrapped in braces, a name argument that
  is not one name takes the fallback, `var(--x,)` has an empty fallback, a fallback is
  substituted only when it is used, and a value that comes to a CSS-wide keyword acts as that
  keyword. `@supports` takes a custom property, and a declaration that holds a `var()`. HTML's
  presentational attributes are read by HTML's rules and substitute nothing; an SVG `width` or
  `height` attribute is a CSS value and does.
  - **Cycles.** A custom property in a dependency cycle is invalid at computed-value time. Only
    the references a substitution follows count, so a fallback that is not used makes no
    cycle, and once a property is in a cycle its fallbacks are not substituted, as in Blink,
    whose way of finding cycles the reader follows. The properties being resolved are held on
    a stack of the reader's own rather than the call stack
    ([heap cursors](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/stack-and-work-bounds.md#small-recursive-frames-and-heap-cursors-keep-depth-cheap)),
    so a chain of references as long as
    a stylesheet can hold needs no deeper stack than a short one.
  - **Light and dark.** A custom property declared in a rule for one appearance is
    substituted, in that appearance, into what paints, and into everything else as in the
    light appearance, as the properties it is substituted into are resolved (**Appearance
    media**). An element holds custom properties for each side when a book declares some for
    one appearance alone and the reader is dark.
  - **Bounds.** One substitution produces at most 65,536 component values, WebKit's bound,
    counted over the value as a whole as Blink and Gecko count theirs, and nests functions
    and blocks no deeper than the parser's 32 levels; a longer or deeper result is invalid at
    computed-value time, which stops a value that doubles at each reference. A section spends
    at most 1,048,576 units of work on substitution for each appearance side, the number it
    bounds generated text by: the component values substitutions read and produce, and the
    entries an element that declares custom properties copies from its parent's. Elements that
    declare the same custom properties under the same parent share what they compute to, and a
    rule's substitution against one set of custom properties is parsed once, so a book stays
    far within the bound: a design system of 340 custom properties on the root, components
    that declare their own and 100 chapters that each set one in a `style` attribute spends
    about 150,000. Past it, what remains to substitute is invalid at computed-value time, and
    the section has the `.disclosure` that some of its styling was too large to apply.
  - **Not supported.** `env()`, and `attr()` outside `content`, are not substituted: a
    declaration that holds one is dropped. Registered custom properties (`@property`, CSS
    Properties and Values API 1) are not: the rule is ignored, and every custom property takes
    any value and inherits.
- **Reading adjustments.** `EPUBReaderStyle.typography` sets the font, line height, paragraph
  spacing, letter and word spacing, page margins, alignment and hyphenation of book text
  ([#673](https://github.com/vocaro/EPUBLib/issues/673)). Each value is part of the
  typography a section is built for, apart from the margins, which are the canvas's, so a
  change rebuilds the text, which keeps its characters, or lays the columns out again, and the
  reader keeps its place as it does for a text size. Lengths are in ems: letter and word
  spacing add to the font's own, and the paragraph spacing is a `p`'s top and bottom margin,
  which collapse between paragraphs (CSS 2.2 §8.3.1). `ReaderTextSettings` bounds each value.
  - **The switch off** (`overridesBookStyles`, the default). The values set are a user style
    sheet (CSS Cascade 4 §6.2): normal declarations of the user origin, between the user
    agent's and the book's, on the root element (family, line height, letter and word
    spacing, alignment, hyphenation) and on `p` (its margins). The book's declarations win
    wherever it makes them, and its `revert` rolls back to the settings (§7.3.4); what it leaves
    to inheritance takes them. So a book's own fonts and spacing are unchanged, and a book
    with no styles of its own reads as the settings say. A letter or word spacing declared on
    the root is inherited as a length (CSS Text 3 §8), so a heading's is the root's, not its
    own ems.
  - **The switch on.** Each value set is given to every element the settings reach, after the
    cascade, over whatever the book declares, `!important` included: its family first, with
    the element's own families after it; line height; letter and word spacing in the element's
    own ems; hyphenation; and a `p`'s margins. Alignment replaces only ragged or justified
    lines (`start`, `justify`, or the start side's physical value), so a centred heading or a
    signature set to the end side keeps its place. This is what a reader's "publisher
    defaults" switch turned off does; Readium CSS's user settings, with their per-element
    selectors, are the same idea.
  - **What is left alone.** In both modes an element the settings must not change, and all it
    holds, is styled from the book's styles alone, exactly as with no settings: `pre`,
    `listing`, `plaintext`, `xmp`, and an element that keeps white space where its parent does
    not, whose columns are the book's; `code`, `kbd`, `samp` and `tt`; a table; MathML and SVG,
    which lay themselves out; and a box the book sizes or places: a float, an absolutely
    positioned box, or one with a height or maximum height other than a percentage, whose text
    is set to fit it, a drop cap among them. The root and the body are never left alone, so a
    book that sizes them to the page, or keeps white space throughout as a plain text made a
    book can, is still set. Every other style records the inherited values the book alone gives
    it (`ReaderTextTrace`), and an element left alone inherits those. With a setting set, each
    element is cascaded and computed twice, for the book's styles and for the settings'.
  - **Fonts.** `.serif`, `.sansSerif`, `.monospace` and `.rounded` are the system's designs;
    `.named` finds an installed family, or one the app registers for its process, by name, as
    a book's `font-family` does (`FontRegistry`). A family that is not available leaves the
    element's own. An installed family has the next family in the list that resolves as its
    cascade list, so a character it lacks, Greek in a Latin font, is drawn in the font the text
    would have had (CSS Fonts 4 §5), and only then in the system's fallback fonts. This holds
    for a book's installed families too; its `@font-face` faces and the system designs keep the
    system's fallback alone. The package bundles no font
    ([#692](https://github.com/vocaro/EPUBLib/issues/692)).
  - **Margins.** `pageMargins` scales the outer side margins, 3.5% of the page's width each
    side ([Layout](#layout)); 0 removes them. A column stays at most 720 points wide, the gap
    between two columns and the top and bottom margins stay as they are, and a wider margin can
    turn a two-column spread into one column.
- **Building** is per section and lazy for first paint: the opening section builds first and
  the session emits `.ready` once it is on screen, built for the appearance the reader opens
  in; the rest build in the background in parallel. Images decode lazily, downsampled to
  their displayed size, under a shared cache budget.
- **One appearance on screen.** A page's text and the canvas behind it always have the same
  appearance ([#243](https://github.com/vocaro/EPUBLib/issues/243)). A section's colours are
  part of its build, and a session builds for Light until its host reports Dark, which a host
  does when the view appears, possibly after the first build is in. The first page therefore
  waits for text built for the host's appearance, on an empty canvas of that appearance; a
  host that turns back before that build arrives opens on the build it turned back to.
  After a live change the canvas changes appearance once and never back. It keeps the old
  appearance, with the old text, until the sections on screen and those one page turn reaches
  are built for the new: the section before a section's first page and after its last, and in
  continuous scroll the section on each side. Those build together, the section on screen
  among them, so the change waits for one build; the page and the canvas then change together.
  A page turned to meanwhile is shown as built, in the old appearance, and one already built
  for the new brings the change with it. Once the canvas has changed, a page turn, a contents
  entry, a link or a search result that reaches a section still built for the old appearance
  builds it for the new first, with the page on screen kept (`ReaderCanvasDataSource.canShow`);
  that section's text still serves selection and progress meanwhile. A page turn or search
  result that waits so is dropped when the page moves before the build arrives, by a key, a
  click or tap, a swipe, the wheel, VoiceOver or a command. VoiceOver's move by heading shows
  the heading it finds at once, so it stops at a section still built for the old appearance,
  as at one not built yet, and asks for that section's build at once, ahead of the background
  rebuild (`ReaderCanvasDelegate.canvas(_:wantsSection:)`): the next move finds the heading
  once that one build is in, rather than wait on the main thread. A note is shown in the
  appearance its text was built for, the new one, whatever the page behind it shows.
  `effectiveAppearance` reports the new appearance at once. All of this holds for a theme as for
  Light and Dark: a change to Sepia, Black or custom colours, or of Increase Contrast, is a
  change of the theme a section is built in, and the canvas draws in the theme of the text it
  shows (**Themes**, [#674](https://github.com/vocaro/EPUBLib/issues/674)).
- **Release.** A typography change keeps each built section on screen until its rebuild
  arrives. A rebuilt SVG shares the font database its replaced build still holds, so a
  relayout needs no more of the font budget than the book already has. The text view drops
  replaced text's layout with the text, so its images go with it, also after a resize.
  `close()` releases the session's sections and paginations and empties its text views at
  once, as does a dismantled view. Neither waits for the platform to free the views
  ([investigation](https://github.com/vocaro/EPUBLib/issues/54#issuecomment-6159293824)).
- **Search collation.** The matcher compares primary collation weights in the document's
  language, matching Foliate's `Intl.Collator(locale, { sensitivity: 'base' })` contract.
  Turkish `ö` and `o`, Swedish `å` and `a`, Spanish `ñ` and `n`, and Cyrillic `й` and `и`
  remain distinct. Ordinary accents in untailored languages, case and width still compare
  equal. Swedish `ü` also matches `y`, including decomposed spelling. `.locate`, `.search` and
  `.searchHighlight` share `TextSearch.matches`
  ([#26](https://github.com/vocaro/EPUBLib/issues/26)).

  The matcher gets primary-strength results from public Foundation APIs with
  [swapped private-use suffixes](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/text-layout-and-unicode.md#primary-strength-collation-is-available-through-public-foundation-apis),
  comparing NFC-normalized copies while DOM text and UTF-16 endpoints keep their authored
  spelling ([#107](https://github.com/vocaro/EPUBLib/issues/107)). It has no ICU
  private-symbol or JavaScript dependency.

  The coarse key prefilter retains root equivalences and adds the cross-class merges in
  the recorded Swedish and Danish collation classes. Composed and decomposed spellings
  produce the same keys. Canonical combining-class blocking matters: `u + diaeresis + macron`
  belongs with Swedish `y`, while `u + macron + diaeresis` stays with `u`. The prefilter runs
  for standard English, Swedish, Turkish, Spanish, Danish, German and Japanese collations.
  Windows containing contextual kana marks, Arabic tatweel or characters outside the recorded
  classes go directly to the collator. Those candidates merge with key hits in reading order,
  without duplicates, so the prefilter cannot discard them
  ([#106](https://github.com/vocaro/EPUBLib/issues/106)). Non-ASCII source nodes keep an indexed
  UTF-16 copy for those comparisons, preserving source offsets without repeatedly scanning
  a long paragraph's prefix.
  Other languages or explicit collation variants compare every grapheme window, preserving
  correctness when a key table has not been qualified for that collation. Consequently, they
  can be substantially slower. A one-megabyte French section's unique 24-grapheme query took
  about 10–12.5 seconds in debug builds during parallel build activity on the development
  Mac; this is an observed cost, not a timing guarantee.

  Language tailoring leaves the rest of the search contract as it was: text-node traversal,
  script/style exclusion, whitespace collapse, format-character removal, fixed grapheme
  window length, UTF-16 DOM endpoints, inline boundaries, reading order, match limits and
  overlapping matches. The comparison is held to results recorded from foliate-js in WebKit
  ([search collation vectors](testing.md#search-collation-vectors)); those finite vectors are
  regression evidence, not a claim that every Unicode sequence or locale has been enumerated.
- **Highlights.** New public `EPUBReaderCommand.setHighlights([EPUBHighlight])` and capability
  `.highlights` draw host highlights from their range CFIs, including every `rangeBookmarks`
  segment of a multi-document annotation (StudyWright #85). Search and
  highlights are TextKit 2 rendering attributes; they never change the text. The current
  search result is drawn again over its match in a darker, differently hued highlight.
  Since
  [TextKit 2 redraws a fragment only when its layout changes](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#textkit-2-redraws-a-fragment-when-its-layout-changes-not-when-its-attributes-do),
  each change asks for the fragments on screen to be drawn again
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
  matching case the same way: a `<` that is the last byte of a file is not text. A `<` that
  NULs follow at the end of a file is not its last byte, and the screen and HTML read it as a
  character: `…<p>two <` and NULs reads `two <`, as text extraction reads the same bytes.
- **Book pose.** New public `View.epubReaderDivision(_:)` reserves a vertical division in the
  reader's own coordinates. Columns never depend on device idiom, orientation or screen.

## Layout

All lengths are points. These follow foliate-js's paginator defaults, so books lay out much
as they did.

- **Columns.** Paginated flow uses two columns when the page is landscape (width > height)
  and its content width, 93% of the width, is more than 720 (about 775 pt wide); otherwise one.
  The outer horizontal margin is at least 3.5% of the width each side, columns are at most 720
  wide (the content area is centred when that caps it), the column gap is 7.53% of the content
  width (foliate's `g / (1 − g)` with g = 7%), and the top and bottom margins are 48. A host's
  `pageMargins` scales the outer margin, and the content width and column count with it; the
  gap keeps its width ([Reading adjustments](#decisions)).
- **Keyboard.** On iPhone and iPad, while a keyboard is up over the reader's window, pages
  keep the height they were laid out at without it, and the canvas cuts off their foot where
  a host has made the reader shorter, as the keyboard covers it. The area kept is the last one
  laid out with no keyboard up outside an animation, since a host makes room for the keyboard
  in an animation that can come before the canvas is told of it. Laid out again for the
  shorter reader, the book was paginated as the keyboard rose for a search and again as the
  search put it away, and on an iPad one column became two and back
  ([#49](https://github.com/vocaro/EPUBLib/issues/49)). A change of width lays the pages out
  for it. Continuous scroll is made shorter, which lays no text out again.
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
  Since a legacy scrollbar
  [appears only after the column was first set](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#appkit-and-uikit-text-views-scroll-themselves),
  the text is laid out again at the narrower width in the layout pass that follows, before
  the scroll view is first drawn.
  A shown position's line rests at the top of the visible area, or the top edge of an aligned
  box around it that fits there ([Flex and grid alignment](#flex-and-grid-alignment)). A
  search result's line rests about a third of the way down instead: the line a third of the
  view above it, laid out in one run with it, is the position kept and rests at the top, but
  not above the start of the result's section, so that the location stays there. Where that
  would leave the result's line partly off screen, it rests at the top. VoiceOver's cursor,
  where it is in the text, goes to the result's line on iOS, and on Mac the insertion point is
  put at the start of that line, and kept there until something else is shown or the view is
  scrolled ([#49](https://github.com/vocaro/EPUBLib/issues/49)). A scroll AppKit makes as it
  lays the whole text out again, after a change of text size, is taken for the person's, and
  VoiceOver then enters at the first line on screen. A long jump
  [lays out through its target before scrolling](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#lay-out-through-a-far-target-before-scrolling-to-it)
  and checks which line the top shows: from text before the position, it lays out through the
  position in one run and scrolls to its now exact line; from text past it, it climbs above it
  first ([#13](https://github.com/vocaro/EPUBLib/issues/13)). A resize keeps the line holding
  the position (the last one shown, or the visible start once the person has scrolled), or that
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
  An assistive technology's read
  [can lay the whole text out behind the view](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#accessibility-observation-can-change-layout):
  on Mac, and on iOS before the scroll view listed its own lines (below). So the visible
  range is read from the paragraphs the viewport laid out, once it has been laid out again
  where the view stands; while the view has not moved since it was last read, the reader
  first scrolls by as much as the first visible line has moved; and a view within a point of
  where it was last read has not moved and nobody has scrolled it: its first line is still
  held, and the position kept is still the one shown, not the visible start
  ([#302](https://github.com/vocaro/EPUBLib/issues/302)).
  Point hit tests for a character, a link or an image use those viewport fragments too, so
  a tap answers for the text drawn there even when the layout holds another paragraph at
  that point. On Mac the first wheel or trackpad event holds the first line, and each bounds
  change records the new first line immediately; the location
  report remains throttled. An accessibility read straight after a person's scroll therefore
  keeps that new line, without waiting 150 ms for the report
  ([#266](https://github.com/vocaro/EPUBLib/issues/266)).
  VoiceOver's insertion-point line query can replace estimates above the viewport with
  completed layout. The stand-in read of every paragraph is stronger: it does not establish
  that VoiceOver lays out the remaining text below. The observed requests and speech are
  recorded with [#517](https://github.com/vocaro/EPUBLib/issues/517) in
  [testing](testing.md#harness-pitfalls-and-current-results).
  `ScrolledAccessibilityReadTests.testHitTestsAfterAReadAndScrollAnswerTheDrawnTextLinksAndImages`
  checks the character, link, image and fragment hit tests against the viewport's own lines
  on both platforms. Its Mac tests
  `testAScrollImmediatelyFollowedByAReadKeepsTheNewFirstLine` and
  `testWheelAndTrackpadAfterAReadKeepTheTextOnScreen` cover a read inside the report delay
  with both scroll bars and a line wheel or precise trackpad event after the read.
  The reader's own read of the screen is not the only one. The table rows on screen are
  given their cells' text views from the layout, whenever the canvas is laid out or the
  view scrolls, and on Mac an assistive client is told from it what is on screen and where:
  the text's children, the bounds of a range, a link's or a heading's place, a table row's.
  VoiceOver's question for the insertion point's line
  [lays out all the text above](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#accessibility-observation-can-change-layout).
  After Find Next Link had shown a table
  row below text that was only estimated, a row taller than the screen among it, the
  bounds VoiceOver asked for next put the row's own paragraph 1,430 points below where the
  view drew it, and left the rows after it where they were drawn. Read off that layout the
  row was off screen: it lost its cells, its link left the text's children, and VoiceOver,
  whose cursor was on that link, was left on the text area. So the view is held to its
  text before each of those reads, as before the reader's own, and the bounds of a range
  are given a second time when answering is what moved the text. Straight after such a
  layout the document can still be as tall as it was, which stops the scroll short of a
  line near its end. The viewport laid out where the scroll stopped gives the document its
  height, so the reader scrolls again until the line stands as far below the top as it
  stood. The rows on screen keep their cells through the hold: the view's offset changes
  before the viewport is laid out there, and rows looked for in the layout of the place
  before would have their cells taken away and made again, and with them the links
  VoiceOver holds ([#517](https://github.com/vocaro/EPUBLib/issues/517); [VoiceOver
  testing](testing.md#harness-pitfalls-and-current-results) has the sessions).
  AppKit's text view also
  [scrolls itself when a live resize of its window ends](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#appkit-and-uikit-text-views-scroll-themselves),
  after a drag of the window's edge and after a resize made with animation or by an assistive
  client: the paragraph under the clip view's top edge goes to that edge, from its first
  line. That edge is above the first line on screen by the text's 48-point
  top margin, and by the height of a toolbar over the reader. A reader at the top of its book
  stood 48 points down, its title above the screen, and 114 points down under a 66-point
  toolbar. Anywhere else the text went back to the start of a paragraph, 279 and 304 points
  in the tests' prose, and further at each resize: 574 and 650 points after a second and a
  third. The reader took that for a scroll by the person: it kept the new
  place, and put the insertion point VoiceOver enters at on the line then first on screen.
  The canvas is told that the resize has ended before the text view is, so it has rested the
  kept position by the time the text view scrolls. The reader reads
  where the view stands before that scroll and puts it back straight after, at the offset it
  had and then with its first line where that line was, before anything is drawn. Nobody
  has scrolled and the position kept is unchanged: in a pane whose size the resize leaves
  alone, text the person scrolled to stays where it is, a line cut by the top edge with it
  ([#479](https://github.com/vocaro/EPUBLib/pull/479)).
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
  start, read from the layout the new height replaces, once the person has scrolled. A bar
  shown or hidden over a reader that runs under it (a host's `ignoresSafeArea()`) changes the
  visible height and not the reader's size. Without the rest an epigraph stood 81 points
  below the top on an iPhone while the navigation bar was hidden, and on the Mac, after a
  toolbar was shown over a full-size content view, the next layout drew another chapter,
  which the reader reported
  ([#338](https://github.com/vocaro/EPUBLib/issues/338)). On iOS the rest puts the line being
  read at the top of the taller area when a bar hides. UIKit reports the scrolling of an
  inset change once the change is over, the reader's rest included. Where that report finds
  the view as the rest left it, nobody has scrolled, and the position kept stays the one
  rested: the visible start cannot be read then, because UIKit has moved the view for the
  bar and the text under it is being laid out again. On an iPad a paragraph shown otherwise
  ended 38.6 points below the top once the bar had hidden twice. A book with no box to
  resolve is left as UIKit leaves it: when a bar hides, its text stays where it is on
  screen. On the Mac the reader is laid out when a toolbar changes its safe area (Pages,
  below), and its layout lays out the scroll view, whose automatic insets follow the toolbar
  then. AppKit moves the view for the new inset inside that layout, which is no scroll by the
  person. In the middle of the book it moves the view by as much as the inset changed: the
  line at the top of the visible area stays there, and the text moves with the bar, 34 points
  down as a 66-point toolbar replaces the title bar alone and back up as it hides. Where the
  view is as far down as it goes, a toolbar hidden moves it by less, and an earlier line comes
  into view at the top; in a book with no box to resolve the reader then reads the screen
  again, reports that line and puts the insertion point on it. Before, nothing laid the
  reader out for a toolbar, and the boxes stayed resolved for a visible height of 620 points
  where 586 showed until a change of appearance or a resize did
  ([#162](https://github.com/vocaro/EPUBLib/issues/162)).
  On Mac, VoiceOver
  [enters a text view at its insertion point](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#voiceover-enters-a-text-view-at-its-insertion-point).
  New text starts with it at its first line, and the scroll view's is kept on the first line
  on screen. A move the reader
  makes itself (a shown position, a scroll step, rebuilt text) puts it there, as a page turn
  does for a column; after other scrolling it follows only while it is where the reader last
  put it, so one placed by a click or by VoiceOver, which scrolls the view as it reads, stays.
  A selection is never moved, and nothing is scrolled. Each such move also posts a
  [layout change naming the text view](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#post-layout-changes-from-the-element-that-holds-the-text-views).
  The window posts this one. That is not enough for a spread's columns (Pages, below) and
  was heard to be enough here ([#373](https://github.com/vocaro/EPUBLib/issues/373)).
  A VoiceOver cursor inside the text follows the insertion point and not the layout change.
  VoiceOver, inside the text and not yet moved in it, kept its cursor on its line at AppKit's
  one notice of the insertion point's move. It said the word
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
  On iOS,
  [UIKit's own text view elements are every paragraph](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#uikits-own-text-view-elements-are-every-paragraph)
  of the book, so the scroll view lists its lines instead, as a
  page column does, each with the links and attachments in it as elements of their own: the
  lines on screen, each by the part of it inside the area the insets leave, and the fifty
  lines after them. UIKit scrolls a line the cursor comes to until that area holds its frame
  and then 40 points further, and the first line on screen is often cut by the top inset, so
  its whole frame would move the reader as VoiceOver came in
  ([#301](https://github.com/vocaro/EPUBLib/issues/301)).
  The lines after the screen are there for
  [the way VoiceOver moves](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#voiceover-moves-through-a-cache-of-the-items-around-its-cursor):
  given the lines on screen alone, at its first move after a menu closed it read to the last
  of them and went on to the scroll bar and the host's next control. The fifty listed is
  what it asked for at such a move on iOS 27.0 and iPadOS 27.2. While the cursor is on a line,
  fifty lines are listed each side of the screen and each side of the cursor's own line:
  VoiceOver moves on to them, UIKit scrolls the one it lands on into view, and it reads on
  through the book in either direction. Moving back into the text from below, VoiceOver takes
  the last line listed, so
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
  VoiceOver keeps what it was given, and nothing tells it when the view moves under its
  cursor. A move the reader makes itself is a scroll step, a position shown (from the
  contents, a search, a link or a bookmark) or text built again. After one made by a key on
  a keyboard or the host's own command, VoiceOver read on from what it held and the step was
  undone.
  So after a move of its own the canvas posts a layout change, at which VoiceOver
  [drops everything it holds and asks again](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#a-layout-change-makes-voiceover-drop-its-cache-about-08-s-later).
  With the cursor outside the text
  the change names no element. The cursor stays where it is, nothing is said, and the next
  move into the text meets the first line on screen. With the cursor on a line it names the
  line that holds the position shown: the cursor goes there and VoiceOver reads it, as it
  goes to the page shown in paging ("A page turned under VoiceOver's cursor" under
  [Input and accessibility](#input-and-accessibility)). Given no element then, a
  simulator's VoiceOver went to whichever line was drawn where its cursor had stood, the
  line after a link's target in the session that tried it. Nothing is posted while
  VoiceOver's Headings rotor moves the reader, because VoiceOver takes its cursor to the
  item the rotor gives it, nor for scrolling the reader does not do: a finger's, and
  UIKit's for VoiceOver's cursor and its three-finger scroll. The Mac posts a layout change
  after the same moves, for its own reason (above)
  ([#428](https://github.com/vocaro/EPUBLib/issues/428)).
  One thing is left as it is, where VoiceOver has asked for fifty. After a menu, a move back
  past the line it came in at, made before it has used the fifty, goes to the control before
  the text and not to the line above. An iPad does so after a chapter chosen from the
  contents, with the layout change as without it. A simulator's VoiceOver no longer does
  there: the layout change for the chapter shown fills what it holds, two items each side,
  before its first move, so it does not ask for fifty and goes on above that line
  ([VoiceOver testing](testing.md#voiceover-testing), "Harness pitfalls and current results").
  UIKit has no place among the lines for the scroll view's own scroll bar:
  [the bar is a supplementary header that breaks reading order](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#the-scroll-indicator-is-a-supplementary-header-that-breaks-reading-order),
  and VoiceOver read on from the book's last line to the bar and then down the screen a
  second time.
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
  Adjusting the element moves the view a tenth of the book under VoiceOver's cursor, and
  what VoiceOver holds is then screens away and gone (the same article). Kept alive and
  unlisted, the two lines it held took it back to where the view had been and then to the
  control before the text. So after an adjustment the element posts a layout change that
  names itself, and VoiceOver says nothing more than the bar's new value. A layout change
  that names nothing did the same in the simulator, and so did a screen change, with
  VoiceOver's sound for a new screen.
  A touch on the bar reached UIKit's bar, a view, before any line. The element is one among
  the lines the touch is tried against, and VoiceOver took a line that ended within a few
  points of the finger for the one touched: a paragraph's full lines run under the bar's
  place, which for accessibility is wider than what is drawn. So a line on
  screen is listed by the part of it clear of the bar, as it is by the part inside the
  insets, and a touch anywhere on the bar's place finds the bar again
  ([#342](https://github.com/vocaro/EPUBLib/issues/342)).
  Two other ways were tried against a log of UIKit's requests and dropped
  ([VoiceOver testing](testing.md#voiceover-testing), "Harness pitfalls and current results"): a
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
  visible columns. The layout change is posted
  [by the element that holds the columns](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#post-layout-changes-from-the-element-that-holds-the-text-views),
  the canvas's nearest accessibility ancestor
  ([#337](https://github.com/vocaro/EPUBLib/issues/337)). The canvas is reached only through
  `EPUBReaderView`, so there is such an element in every host. It was heard with the page
  controls beside the columns and in the window's toolbar. A VoiceOver cursor resting on that
  element itself moves into the left column when a spread is installed, as heard on page turns.
  Whether VoiceOver also gives up a cursor it keeps in another text area of the same group was
  not
  heard
  ([#373](https://github.com/vocaro/EPUBLib/issues/373)). The
  insertion point after a page's last character, and an offset an assistive client kept from
  a longer page, are on its last line.
  Since VoiceOver
  [enters a column at its insertion point](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#voiceover-enters-a-text-view-at-its-insertion-point),
  installing a page puts that at the page's first line. After a place is shown (a link's target,
  a search result, a located passage, a bookmark, the place a book opens at) it goes to the
  start of the line that holds the place, in the column that holds it
  (`ReaderCanvasView.enterPage`), and keyboard focus in another column of the spread goes to
  that column, which VoiceOver follows as it does after a
  page turn made in the second column; focus anywhere else, as on a host's list of search
  results, stays where it is. Before, VoiceOver began at the top of the page, and a listener
  read down it to the place they went to
  ([#383](https://github.com/vocaro/EPUBLib/issues/383)). A page turn, a change of flow, the
  start or end of a section a turn reaches, and VoiceOver's own moves to a heading, where it is
  given the heading's element or characters itself, keep the first line: the session says
  which a show is (`ReaderPageEntry`). A relayout (a text size, a resize, the text built again,
  a division) shows the spread that holds the place, which is still the anchor, and enters at
  the place's line again, in whichever column holds it then, while the page stands as the
  reader left it: every column's insertion point where the reader put it, nothing selected, and
  keyboard focus in no column but the place's (`ReaderCanvasView.placeStillEntered`).
  Continuous scroll keeps its insertion point by the same rule. A host that restores a place
  while its window settles, or while its text is built for its style, keeps it. A click,
  VoiceOver's moves by line, which move the insertion point, a selection, or focus taken to
  the column beside ends it, and a relayout after that keeps the first line, as a page turn
  does ([#594](https://github.com/vocaro/EPUBLib/issues/594)). A move of VoiceOver's own cursor
  that changes neither the insertion point nor focus goes unseen, and a relayout after one
  takes VoiceOver back to the place's line. A position with no character of its own, as a
  section's end, is on no line, and its page keeps the first. Nothing else reads the
  insertion point: a selection, Copy, and the selection carried across a relayout or continued
  onto another page take a range with characters in it, and a passage selected with the place
  replaces it.
  On the hosted runner, after a link to a heading in the middle of a page, VoiceOver entered
  at the heading in one column and two, with its cursor in the text, resting on the column or
  on the search field; on `main` it read the page's first line. Told of the insertion point's
  move from inside the text, it first said "text word: Link character: L", the word and
  character there, in two sessions of four. Where the place is in the column beside the one
  VoiceOver is in, the focus
  move takes it onto that column and out of the text, as after a page turn made in the second
  column: it says "text" and the column's first words, Read Line reads the place's line, and
  interacting enters there. From the place, as from a page's first line after a turn, its
  first move down reads the place's line again, and the next goes on
  ([sessions](https://github.com/vocaro/EPUBLib/issues/383#issuecomment-6277358412)). With
  the reader opened at the heading and its window then resized, VoiceOver entered at the top of
  the page until #594, and at the heading since. At the resize, which it heard from outside the
  text, it said the words before the new insertion point, where before it read the page's
  first line ([sessions](https://github.com/vocaro/EPUBLib/issues/594#issuecomment-6278967907)).
  UIKit exposes visible line/run accessibility children with links, attachment labels and
  page actions, keeping hidden paragraph context out of its native text accessibility traversal.
  A heading is one such child however many lines it takes, with the header trait and its
  level; on Mac a column's rich text carries each heading's level and the column has a
  Headings rotor for the book (see "Input and accessibility").
  Decoration in a line is part of that line's element and adds nothing to it, nor does an
  image the book keeps from assistive technology, whose words it leaves out
  ("Alternative text" under Decisions).
  The canvas lists its columns to VoiceOver in source order; by their frames alone a column
  lowered by top spacing, or the first column of a right-to-left spread, would be read second.
  VoiceOver
  [searches inside a column given that way before taking its lines](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#uikits-own-text-view-elements-are-every-paragraph),
  so nothing the reader mounts inside a text view is offered to assistive technology (see
  Tables).
  A paragraph that continues onto the next page is laid out a few lines further (or to
  a line break) and clipped, so its lines break as in the measuring layout; justified
  text takes more, because
  [Core Text justification depends on the paragraph's length](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#core-text-justification-depends-on-the-paragraphs-length).
  A short justified paragraph's page takes its rest up to the next line break (`<br>`,
  written as U+2028) that ends a line of text, or its whole rest when none follows, since the
  lines before such a break are set the same whatever follows it
  ([#570](https://github.com/vocaro/EPUBLib/issues/570)). A break that
  ends a blank line is passed over: a lone separator laid out last takes another position, and
  sometimes another height. A section with a box plan keeps the whole rest, because there the
  lines before a break were not always placed the same without what follows it. A long
  paragraph keeps enough of its rest to stay long, since a shorter slice of it would be
  justified as a whole. That context does not make a page's slice, laid out alone,
  break as the section did: a justified paragraph is justified over the page's part of it, a
  continued paragraph starts a fresh line, and a line holding glyphs from a fallback font
  (CJK text among Latin) is laid out differently. So every page is laid out as its column
  will show it, the same bounded display slice with its lookahead, before its source boundary
  is committed, whether or not its section has a box plan. The page takes that layout's line
  boundaries and height; lines below its actual clip carry forward, and the next page starts
  at the corrected source boundary. No synthetic tail padding or column growth is needed;
  authored justification, hyphenation, indentation and RTL are retained. This is a second
  TextKit layout of every page during pagination, and it moves a few page starts from where
  the section's layout put them; the cost on the standard book corpora is on
  [#570](https://github.com/vocaro/EPUBLib/issues/570#issuecomment-6184463894).
  A first line taller than the clip, a positioned first line outside it, or a slice whose
  own layout sets none of its characters on a line (its container refused TextKit the first
  line), falls back to native in-flow text with bounded typography, on every page: committed,
  its characters would be on no visible line, and a table row laid out on that line would
  lose its continuation pages. That exceptional slice retains its characters, DOM mapping,
  links and heading roles; it can change positioning, font size, baseline shifts, paragraph
  spacing and tab intervals to make its content reachable. It fits each run, table row, image
  and formula to the clip, and gives a tab with neither a stop after it nor an interval one;
  when the line they make together is still taller (a small run's line height applied to a
  large run, text beside a row), it lowers that target by the line's overshoot, or in
  proportion if that is lower, and lays the slice out again, at most eight more times
  ([#303](https://github.com/vocaro/EPUBLib/issues/303), [#192](https://github.com/vocaro/EPUBLib/issues/192), [#242](https://github.com/vocaro/EPUBLib/issues/242), [#289](https://github.com/vocaro/EPUBLib/issues/289), [#570](https://github.com/vocaro/EPUBLib/issues/570)).
  When no height shows the first line, the page keeps the longest start of that line that
  shows, laid out alone as planned or as the fallback, and the rest carries to the next page,
  as a line below the clip does. So no page is committed whose own layout shows no line of its
  characters, unless its clip can show no glyph or no layout can show its first character
  ([#576](https://github.com/vocaro/EPUBLib/issues/576)). No content the reader makes is known
  to need that division. A character cluster that no layout shows, as an attachment of fixed
  size made outside the reader can be, is committed as planned with the white space after it
  on its line, so that pagination advances. Debug builds check each page as it is committed:
  that it starts where the page before ended (or repeats the row whose continuation it holds,
  or follows text TextKit set on no line), that it advances, and that its own layout shows a
  line of its characters, or that no layout shows its first.
  A page that is shown is laid out twice: by the paginator, to measure it, and by its column.
  Handing the measuring layout to the column was left out of #570. A column is a persistent
  `ReaderTextView` that owns its TextKit stack from its creation and keeps it across page
  turns, for selection and for VoiceOver's cursor (#337), since
  [a text view takes its layout stack when it is made](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#a-text-view-takes-its-layout-stack-when-it-is-made).
  The paginator measures pages ahead of display (page counts, positions, the next spread), so
  it would also have to keep the measured layouts of the pages about to be shown, and the
  column's own preparation (box geometry
  replanned for its viewport, attachments exposed) would have to run on them first. The
  saving is one page layout per page shown, against a pagination that measures every page.
  A forced-break paragraph's retained leading margin is included in its ordinary flow plan.
  Existing bounded preflight decides which boxes are eligible first. Only a retained rich
  plan with such a margin is replanned with corrected flow advances, carrying rejected box
  IDs forward. Each phase uses the existing bounded positioning/suppression passes. An
  already-readable in-flow fallback is not converted to a new indivisible group. Ordinary
  nonforced margins keep their established behavior.
  The page's first-line exclusion proposal includes its actual top adjustment. A negative
  fragment end is held at zero, and the following fragment compensates by the preceding
  fragment's actual held distance. Glyph queries use the signed frame origin; section page
  anchoring retains the established flow envelope. The existing indivisible-group policy
  remains, including its handling of authored breaks inside a group.
  An inset that exhausts a line leaves a visible glyph column. Justified drop caps measure
  intrinsic glyph width without full-width justification. Other alignment measurement
  remains unchanged; the centered-caption expected failure of [#148](https://github.com/vocaro/EPUBLib/issues/148) is retained.
  The typography fallback has a least clip, since TextKit has no font floor and sets a
  fitted glyph in a one-point line and box (the same article). A zero-point clip cannot
  show it; a one-point heading retains half a point of top spacing, leaving only
  half a point for that glyph. Fallback requires its measured one-point minimum drawing box
  plus the existing one-point safety inset after top spacing. Below that budget pagination
  preserves the original fonts and one-source-line progress, without claiming visible
  glyphs. No font or page-range alteration is committed for an impossible clip; at a clip
  that can show a glyph, a first line that no fitted retry shows is divided instead, as
  above. A 600-point source glyph fits its 500-point page through the fallback, and its
  original page boundaries remain unchanged
  ([record](https://github.com/vocaro/EPUBLib/issues/242#issuecomment-6159295037); [generated pages](testing.md#generated-page-text)).
  Paginations are cached per section and column size; a resize,
  rotation or bar change repaginates once it ends, in steps when far into a section, with the
  old spread on screen until the new one is ready. A finished pagination keeps only its pages.
  On the Mac a toolbar shown, hidden or made compact over a reader that runs under it, as over
  a full-size content view, changes its safe area and not its size. AppKit does not mark the
  reader as needing layout for that (a scroll view with automatic insets marks only itself),
  and tells whoever observes a view's `safeAreaInsets` (macOS 27.2); the reader observes its
  own and is laid out then, where its pages stayed 80 points down under a
  66-point toolbar until the window was resized
  ([#162](https://github.com/vocaro/EPUBLib/issues/162)).
- **Page numbers.** `EPUBReaderStatus.layoutPage` gives the pages on screen in paginated flow:
  the first one's index in the book and in its section, the book's and the section's page
  counts, and how many pages the spread shows
  ([#681](https://github.com/vocaro/EPUBLib/issues/681)). A page is one column of a spread. A
  section starts on a spread's first column, so a spread that ends a section with an odd
  number of pages shows one, and its empty column is no page. The book's pages are those of
  the sections page turns reach (not a nonlinear one, unless no section is linear); a
  nonlinear section shown by a link has its own index and count but no index in the book.
  `ReaderPageCounter` paginates every section at the spread's column size with the paginator
  the canvas shows pages from, so the count is of the pages turns pass: the section on screen
  first, by finishing the canvas's own pagination, then the sections before it, which the
  book index needs, then the rest, each with a pagination of its own that is dropped once its
  pages are counted. It runs on the main actor, as layout does, for 6 ms at a time, then lets
  the run loop serve input before it goes on, so a page turn waits for one slice at most and
  never for the count; a resize's own pagination goes before it. What is not counted yet is
  nil, and the status changes as counting goes on, without a `.relocated`. A new column size
  drops every count; a section built again for a new typography is counted again, and only a
  section built for the current one is counted. While the page on screen shows a section's
  earlier build, as it does through a change of appearance until the sections in reach are
  rebuilt ([#243](https://github.com/vocaro/EPUBLib/issues/243)), the status has no page. In
  continuous scroll it is nil. Closing the reader stops the count and drops what it holds. On
  iOS, text that ends with an attachment keeps that attachment alive after its whole layout is
  gone, until text ending with another attachment is laid out. The counter lays out each
  section's last page, so close then lays out a text that ends with an empty attachment
  (`releaseLayoutResidue`). Without it, an iPhone simulator kept the picture that ended the
  last section counted, with its SVG renderer, after the reader was closed.
- **Right to left.** `page-progression-direction="rtl"` mirrors spreads, swipes and tap zones.
  Within a page, a box's sides by flow (`margin-inline-start`, `padding-inline`,
  `border-inline-end`) are the sides the element's own `direction` maps them to, and cascade
  with those sides' physical declarations in order; `float` and `clear` with `inline-start` or
  `inline-end` take the side of the parent's direction, the containing block's
  (CSS Logical Properties 1). The reader's own stylesheet indents lists and `dd` on their start
  side, as HTML 15.3.7 does, so a right-to-left list is indented on the right
  ([#124](https://github.com/vocaro/EPUBLib/issues/124)). Vertical writing is laid out
  horizontally, so the block axis is always top to bottom, and `dir="auto"` does not yet give an
  element the direction of its content, so its sides by flow follow its parent's.
  A right-to-left item's marker hangs in that indent and each of its lines starts at the same
  edge, in page text and in table cells. A marker's tab stop is a distance from the paragraph's
  leading edge, the right in right-to-left text. TextKit 2
  [measures a right-to-left stop otherwise](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#textkit-1-and-textkit-2-apply-paragraph-indents-differently)
  and set the item's first line a first-line indent further along than its wrapped lines; the
  text container shows it the stop moved by the
  difference (`ReaderTextContainer.rightToLeftStops`,
  [#276](https://github.com/vocaro/EPUBLib/issues/276)).

### Floats and positioned boxes

The native CSS subset wraps prose beside left/right floated figures, text and archive images,
then restores the full column below the box. Auto-width text floats use their content width,
including narrow drop caps. A float whose `width` or `max-width` is narrower than a word it
holds is as wide as that word, as far as its containing block allows: CSS lets the word overflow
the float (CSS Text 3 5.2), and the reader, which draws nothing outside its column, broke it
between characters instead. The first word of a paragraph counts with the indent its first line
keeps (`text-indent`). Where the float's text hyphenates (`hyphens: auto`, the reader's default)
a line may end at a hyphenation point, so a word counts by its widest part and the hyphen set
after it, and a float wide enough for those keeps its width and hyphenates, as WebKit sets it. A
verse number in a float sized in pixels stays whole at a larger reader font. Only words count:
an image with no size of its own still shrinks to the float
([#152](https://github.com/vocaro/EPUBLib/issues/152)). Horizontal margins and padding reserve
space around the native glyph column. `clear: left`, `right` and `both` on a block start it
below the earlier floats of the requested side, with all it holds, a float it opens with
included; inside it nothing clears again, so its later lines wrap beside its own floats. An
empty block that clears moves what follows it. On a float, `clear` moves that float alone below
the earlier floats of the side (CSS 2.2 9.5.2), and on a `br` it moves the line after the break,
as browsers do ([#151](https://github.com/vocaro/EPUBLib/issues/151)). So does a `br`'s `clear`
attribute, `left`, `right`, `all` or `both` in any case, which HTML maps to the property as a
presentational hint (HTML §15.3.4, [#121](https://github.com/vocaro/EPUBLib/issues/121)).

A float, and a sized `inline-block`, is placed and sized in its containing block: the content
box of the block it is in, between the content edges where that block's own lines are set
(CSS 2.2 10.1). A drop cap in an indented block quotation stands at the quotation's edge beside
its word, and a float's percentages are of the quotation's width, whose own percentage margins
are resolved at the column's size, as for its prose. A line beside a float is shortened on the
float's side (CSS 2.2 9.5): no text is set between a left float and the line's start, or
between a right float and the line's end, so the prose after an indented block or a positioned
container is not set in its margin, on the far side of a float it holds
([#150](https://github.com/vocaro/EPUBLib/issues/150)). A line is set beside a float only where
the room there holds the line's first word, or in a paragraph that hyphenates the word's first
part and its hyphen, and is 48 points wide at least, or a third of the column where the column
is narrower than 144 points. Otherwise the line goes down past the float, as CSS 2.2 9.5 shifts
a line box too narrow for any of its content, where TextKit broke the word between any two
characters ([#152](https://github.com/vocaro/EPUBLib/issues/152)). WebKit sets hyphenated parts
in such a room too. The 48-point floor is the reader's own: a browser uses any room its content
fits. In a positioned container narrower than the column, or moved along it, the paragraphs
and floats of the blocks inside it are set in the container's content box, without the margins
of the blocks between.

A sized `inline-block` is set on its block's line. It starts where the text or the box before
it ends, a space after it where the source has white space between the two, and at the start
of the block's next line when the one it would be on is full. A box that opens its block takes
the block's `text-indent`, and a block that sets its lines from the right fills them from the
right. A run of such boxes is therefore a row that wraps as words do: the rows of asterisks
that mark an omission, an initial in a box of fixed width before the rest of its word. The
text after the run goes on from its last box, on the same line where what is left of that line
holds its first word, as beside a float, and the block that follows starts below the run's last
row. A box's own horizontal margins, borders and padding stand between it and its neighbours.
Each box is still a paragraph of its own in the text, so characters, offsets and CFIs are what
they were.

Three things about a row differ from a browser. Its boxes are aligned by their tops, not
their baselines, and prose beside a box taller than a line wraps beside it as beside a float.
A row starts at its line's start edge whatever the block's `text-align`. And lines fill in
turn, where a browser that honours `text-wrap: pretty` evens the rows out.

Absolute callouts honor `top`, `right`, `bottom`, `left` and `inset` within their nearest
positioned ancestor, including a top inset that places them before their source location.
Prose and floats written before such a callout in its containing block keep clear of it: the
layout places the callouts, then sets that text again beside them. Where a callout stands
depends only on what is above its containing block and on the callouts before it, which it
settles below, and the layout anticipates it there. So a chapter of margin notes, each written
after its paragraph in a relative container of its own, has every note placed however long it
is, where twelve containers had every note set in flow
([#209](https://github.com/vocaro/EPUBLib/issues/209)). Callouts that four layouts of the
section cannot settle are still set in flow. Such a chapter with a float before each note, on
the note's side, can be: the float keeps clear of where the layout before placed the notes in
the containers below it ([#751](https://github.com/vocaro/EPUBLib/issues/751)).
Relative containers honor column sizing and horizontal offsets, with positive vertical
offsets moving their content downward. Fixed callouts use the section's viewport coordinates
and appear once; they do not remain pinned while scrolling or repeat on each page. The reader
reserves space around rectangular boxes to keep prose readable rather than reproducing
arbitrary overlapping layers.

Widths, minimum/maximum widths and insets resolve points, percentages and viewport units at
the current column size in pagination and continuous scroll, `vmin` and `vmax` against the
smaller and the larger side of the viewport at that size; auto margins center a non-floated
box. Native paragraph styles retain text alignment, direction and typography. Native text
retains selection, links, anchors, search and the same exact text-to-DOM mapping as ordinary prose. Resizing and
reader typography changes recompute geometry from source formatting and retain selection.
Requested heights do not truncate content. A box and the prose wrapping beside it stay together
when they fit a page. Two boxes are one group when a line is in the rows of both, and not when
their rows only meet: a definition list with floated terms is a group a row, and one longer than
a page breaks between rows and keeps every float
([#149](https://github.com/vocaro/EPUBLib/issues/149)). A line that reaches into a box's rows by
less than the reader takes for a collision is set clear of the box and is not beside it. A run
of sized inline blocks, with the lines it shares, is one group, all of its rows on one page.
Oversized groups and nested complex boxes instead continue as native
blocks in reading order; fallback widths expand when necessary to leave readable lines, and
long box text can continue across pages. A box taller than a page continues so a paragraph at
a time, and from each of its paragraphs the rest of the box is tried as a box again, so that
the rest that fits a page is set as one. Its end and the max-content width of each of its
paragraphs are found once, and an attempt that the layout of the attempt before it shows to be
more than a quarter of a page too tall is not made. A play that sets each scene as one inline
block of hundreds of verse lines is then paginated in time in proportion to its length, not
its square ([#573](https://github.com/vocaro/EPUBLib/issues/573)). Up to eight nested width
constraints resolve within the enclosing box in this fallback.

A text that holds any of these boxes has every one of its lines placed by the reader's text
container: one section in pages, the whole book in continuous scroll. TextKit then
[aligns such a line as if its paragraph had no indents](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#textkit-1-and-textkit-2-apply-paragraph-indents-differently),
so the container hands TextKit paragraphs without indents and
gives each line a rectangle that already leaves out its paragraph's head, first-line and tail
indent. Margins, centring, right alignment, justification and list markers are then where they
are in a text without boxes, and a paragraph with its own margin beside a float starts at the
float's edge, its margin underneath it
([#63](https://github.com/vocaro/EPUBLib/issues/63),
[#150](https://github.com/vocaro/EPUBLib/issues/150)). An attachment is sized to the same
line, between its paragraph's indents: a table's rows are as wide as the content box of the
block or list item they are in, and so are a rule and an image of `width: 100%` where the
block is indented by less than 15% of the line
([#376](https://github.com/vocaro/EPUBLib/issues/376); further in, they are not:
[#769](https://github.com/vocaro/EPUBLib/issues/769)). Past a tab, TextKit 2
[sizes an attachment at a stop it measures from the line's start](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#textkit-2-sizes-an-attachment-past-a-tab-from-the-lines-start)
and draws it at one it measures from the paragraph's edge. Past a list item's marker the two
are the same stop, and the reader sizes the attachment where it is drawn; past any other tab an
attachment can be a few points narrower than the room left on its line
([#788](https://github.com/vocaro/EPUBLib/issues/788)). TextKit breaks a justified paragraph's
lines a little differently where the container places them; their edges are the same.
The plan measures its paragraphs one at a time, and measures each as the text lays it out:
with the container, those above the text's first box included, since where TextKit applies the
indents itself a tab, a list marker or a table row in an indented paragraph lands elsewhere and
the lines break elsewhere; and with the spacing TextKit gives a paragraph only between others,
before it (a caption set under its table) and after an empty one. A plan that measured a
paragraph otherwise put every box and page below it as far from the layout as the paragraph
was taller or shorter, and a page could open below its own foot and show nothing
([#377](https://github.com/vocaro/EPUBLib/issues/377)).

The boxes' places are planned for the whole of that text, and TextKit lays out only what is
on screen, so a line can be
[screens from where the plan has it](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#lay-out-through-a-far-target-before-scrolling-to-it).
The container therefore wraps each
planned paragraph against the plan from where that paragraph's own first line is laid out,
and takes text past the plan's end to be below every box; a point is found the same way,
from the fragment laid out under it. Prose keeps clear of the boxes beside it wherever the
book is opened, and is not pushed aside by boxes that are nowhere near. A line that starts
exactly where a box ends is clear of it
([#147](https://github.com/vocaro/EPUBLib/issues/147)).

That holds only where TextKit's lines are where the plan has them. The spacing before a
paragraph (after a forced break, its retained margin) is in the plan's flow, as above, and so
is the spacing before a box, which also keeps a box it settles under that far above it.
TextKit proposes a paragraph's first line below that spacing, and the container takes it to
the plan from there; on a page that the paragraph opens, from the page's origin plus the
spacing, which TextKit drops there. A box's first fragment takes the spacing back, so that the
box's lines stand in its region and the text after it is where the plan has it. Without these,
such a paragraph was wrapped as far above where it is drawn, and the text after such a box was
drawn that far below the floats before it; either could run across a float
([#362](https://github.com/vocaro/EPUBLib/issues/362)).

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

### Hidden text

Text in the flow that `visibility: hidden` or `visibility: collapse` hides keeps its
characters, and so the room it takes: it is drawn in a clear colour, without its link, its
decorations or its background, and its lines, pages and positions are those of the same text
shown. CSS keeps that room and gives the text to nobody
([hiding](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/accessibility.md#map-html-alternatives-and-hiding-as-html-aam-does)),
and so does the reader ([#357](https://github.com/vocaro/EPUBLib/issues/357)). Every character of it carries
`.readerHidden`, which changes no character and no span of the text map. Safari is not
quite that: its VoiceOver read hidden words inside a shown paragraph, and passed over a
`visibility: visible` child of a hidden paragraph
([the sessions](https://github.com/vocaro/EPUBLib/issues/357#issuecomment-6164199959)).

- **What is read.** `readerPlainText`, which VoiceOver's elements on iPhone and iPad, Copy,
  the selection a host is told of, a table cell's words and a search result's context read,
  leaves the hidden characters out. It keeps the breaks that end their lines and paragraphs,
  so that the lines around them stay apart, and reads one space where hidden words stand
  between two shown ones, which their room sets apart on the page. A line that holds hidden
  words alone has no element.
- **On the Mac.** Since
  [AppKit gives a client the text character for character](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#appkit-gives-a-client-the-text-character-for-character),
  each hidden character but a break is given to an assistive client as a space, in the value,
  the strings, the rich text and the selected text of a page, of continuous scroll, of a note
  and of a table cell's text, so that every range still matches the text and VoiceOver has no
  hidden word to say: by word and by line it passed over them without a stop. A line of hidden
  words alone is a line of spaces, which
  no session has moved onto.
- **Search.** An occurrence that takes in a hidden character is no result and is not drawn,
  and `.locate` goes to such a passage without selecting it, as it goes to one in a hidden
  footnote.
- **Shown again.** A descendant that sets `visibility: visible` is shown and read. A heading
  whose words are all hidden is no heading to VoiceOver.
- **Positions.** A saved position or a CFI inside hidden text names the characters it named
  before hiding them, and resolves to them.

An image, an SVG drawing, a formula, a table or a rule that `visibility: hidden` hides keeps
its room and draws nothing, nor do the words shown where an image or a formula cannot be
([#132](https://github.com/vocaro/EPUBLib/issues/132)). A hidden table draws none of its
borders and backgrounds, its rows' or its cells'. One that sets `visibility: visible` again
inside a hidden box is drawn, a table's row or cell among them; a part of an SVG drawing or
a formula is not, since the attachment the whole is drawn by is hidden.

What is read of them is what is read of hidden text
([#549](https://github.com/vocaro/EPUBLib/issues/549)). The character of a hidden image,
drawing, formula or rule carries `.readerHidden`, and so do the words shown where it cannot
be drawn, so that VoiceOver, Copy, the selection a host is told of, search and a table cell's
words leave its words out as above, and on the Mac it is a space. The attachment is also
passed over by assistive technology (`isPassedOverByAssistiveTechnology`, `passesOver`), and
nothing keeps it, as a link keeps a picture the book keeps from assistive technology: hidden
content has no link. It has no element on iPhone and iPad, not even on a page of nothing
else, where decoration is listed, nor on the Mac, nor in a table cell, and offers no Inspect
Image. A hidden rule is no stop, and on the Mac it is given as a rule the book keeps from
assistive technology is ("Rules" under Decisions): its character and the break after it are
spaces and its line is part of the line after it. A table is not hidden as a whole, since
each of its cells can be shown again: what its cells hold is marked as it is written, and a
row whose cells are all hidden reads nothing. A tap or a double click on a hidden image's
room opens nothing, and the inspector does not open for it whatever asks. Two places still
offer it, and do nothing when chosen: the Inspect Image of a text item's menu on iPhone and
iPad, and of a table cell's menu ([#775](https://github.com/vocaro/EPUBLib/issues/775)). On
the Mac a row of a table that is not data, whose cells hold a hidden formula or rule and
nothing else, is a group with no name, where a row of hidden text or hidden pictures alone is
passed over ([#774](https://github.com/vocaro/EPUBLib/issues/774)). A note's popover on
iPhone and iPad gives VoiceOver UIKit's own text accessibility, which these changes do not
reach ([#550](https://github.com/vocaro/EPUBLib/issues/550)).

### Text kept from assistive technology

Shown text that the book keeps from assistive technology with `aria-hidden="true"`, on its
element or on one round it, is hidden from VoiceOver and from nothing else, as WAI-ARIA 1.2
and HTML-AAM have it
([hiding](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/accessibility.md#map-html-alternatives-and-hiding-as-html-aam-does))
and as an image or a rule kept so is ("Alternative text" under Decisions,
[#552](https://github.com/vocaro/EPUBLib/issues/552)): a row of stars between scenes, the
big first letter of a word the line also gives whole, a mark repeated for the eye. It is
drawn and laid out as the same text without `aria-hidden`, and copied and found as it,
generated text and list markers included; `aria-hidden="false"` inside it shows nothing to
VoiceOver again. Its characters carry `.readerUnspoken`, and what VoiceOver is given
(`readerPlainText(in:spoken:)`) leaves them out as it leaves hidden text out: the breaks
stay, and kept words between two shown ones read as one space.

- **iPhone and iPad.** A line that holds kept words alone has no element, and a heading of
  kept words alone is no heading.
- **On the Mac.** Each kept character but a break is given to an assistive client as a space,
  as a hidden one is, in the value, the strings, the rich text and the selected text of a
  page, of continuous scroll, of a note and of a table cell's text area. A heading of kept
  words alone has no level, and a line of kept words alone, as a row of stars is, is a line of
  spaces, which no session has moved onto yet.
- **Links.** A link of kept words alone stays a link, without a name, as one that is all a
  picture kept so is: it has to be reachable whatever its words say. On iPhone and iPad its
  element is a link and nothing else; on the Mac the link's element has no title. Kept words
  beside others in a link leave the link to them.
- **Formulas and lost pictures.** A formula with `aria-hidden` on it or round it is passed
  over as a picture kept so is, and its words are copied. The words shown where a picture
  kept by `aria-hidden` cannot be drawn are kept text.
- **Table cells.** VoiceOver still reads kept words where it reads a cell's words, on iPhone
  and iPad in the cell's element and on the Mac in what its row is called, because those
  words are also what a copy of the row takes
  ([#551](https://github.com/vocaro/EPUBLib/issues/551)). On the Mac the cell's own text
  area gives them as spaces.

### Flex and grid alignment

A flex or grid container renders as a block and its items as blocks in source order. Three
shapes keep the reader's single column, and the native layout aligns their items: a flex
container with `flex-direction: column`, a grid with one column, and a row flex container with
one item. A container's free space becomes paragraph spacing around and between its items; an
item narrower than its container is indented from both sides. Nothing else about the text
changes.

- **Heights.** A container has free space when its `height` or `min-height` is definite: points,
  `vh`/`vw`/`vmin`/`vmax`, a percentage of an ancestor chain of definite heights that starts at the viewport
  (`html, body { height: 100% }`), or a sum of those (`calc(98vh - 3em)`, exactly).
  `max-height` caps a definite `height`, `box-sizing: border-box` takes the vertical padding
  and border out of it, and content taller than the box is never clipped: it flows as blocks.
  The height used is at most one viewport, so a box that opens a page stays on that page.
- **Items.** Every in-flow child is an item, an empty one such as a `flex: 1` spacer included.
  An item's margins collapse with nothing, as CSS Flexbox 1 (sections 3 and 4) and CSS Grid 1
  (sections 5.1 and 6) have it: not with its container's, its siblings' or those of what it
  holds, with or without a height to align in. Its margins, borders and padding, and those of
  what it holds above its first line and below its last, are content of the container, so they
  come out of the free space and are kept, as the box's own space, where the box starts a page.
  An empty item has its gaps and its own margins and padding, and takes its share of the free
  space by `flex-grow`, `auto` margins, `justify-content` and a grid's stretched rows.
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
  drops the spacing before a document's first paragraph
  ([paragraph spacing](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#textkit-1-and-textkit-2-apply-paragraph-indents-differently)).

Everything else stays in block flow in reading order and sets a `.disclosure`: a row with
several items (side by side in a browser), `flex-wrap` rows, reversed directions with several
items, grids with more than one column (`grid-template-columns`, `grid-template-areas`,
`grid-auto-flow: column`) or explicitly placed items, inline flex and grid containers with
several children, and containers nested more than four deep. `order` never reorders: items
keep reading order and the container is disclosed. A wrapping column of definite height stays
one column and is disclosed. A container holding a float or positioned box is not aligned:
the box keeps the layout described above, and the alignment given up is disclosed.

No attribute marks a box's extent. Each of a box's paragraphs already carries the tag that
names the containers around it (`.readerAlignment`), so the box around a position is the run
of consecutive paragraphs tagged with the same container (`ReaderAlignmentLayout.boxes`); it
never runs past its section. A box's top edge is its first line's top less the space kept
above it (`.readerAlignmentLead`). The lines are laid out from the box's start and the
measuring stops at the first line past the visible area's height, so a long box costs a
screen of layout at most, and a box of more than 60,000 characters is not measured at all.

The subset was drawn before any book was read, from two sources: the flex and grid usage in
this repository's fixtures and tests, and the published conventions of well-known stylesheets
as recalled, not re-fetched. Ten shipped Standard Ebooks titles were read and rendered
afterwards ([record](https://github.com/vocaro/EPUBLib/issues/20#issuecomment-6159295296)), and the Standard Ebooks entry is corrected from them.

- **This repository.** Before [#20](https://github.com/vocaro/EPUBLib/issues/20) no rendering fixture used flexbox or grid. The only
  uses were a style-resolution test for the blockification of flex and grid items and parser
  tests for `display: flex` and `@supports (display: flex)`.
- **Standard Ebooks.** Its Manual of Style gives full-page epigraphs and dedications one
  shape: inside `@supports(display: flex)`, a `section` with `display: flex`,
  `flex-direction: column`, `justify-content: center`, `align-items: center`,
  `box-sizing: border-box`, `min-height: calc(98vh - 3em)` and `padding-top: 3em`, whose
  children have `margin: 0`, and `* + * { margin-top: 3em }` where a page has several. Outside
  `@supports` the children carry the older fallback (`display: inline-block; margin: auto;
  max-width: 80%; text-align: initial`), which still applies its `max-width` and `text-align`
  to the flex items. A shipped half-title page does not share the shape: it is a centred
  heading in block flow, and a title page is an image.
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

Four of the rules above were made without review. Each was captured on the iPhone and iPad
simulators and on the Mac with a plain description of what is on screen. On 2026-10-12 the
owner, shown them, called them minor cosmetic matters he had no strong feelings about and left
the judgement to the agent that ran the check. All four are kept, for these reasons:

- **The viewport height in continuous scroll is the visible reading area.** A full-page
  dedication or epigraph then takes one visible screen with its text in the middle, which is
  what the book asks for: where the engines break lines alike, the block's top and middle are
  within 0.2 points of WebKit's on the simulators. It is also the viewport images already use.
  The cost is that a box is resolved again when a host shows or hides a bar: when a 54-point
  bar hides, the box grows by 53 points and the text of a dedication on screen moves 26. A
  fixed height would hold the text still but leave the box taller than the screen, and its
  text off centre, whenever a bar shows.
- **A position that starts an aligned box rests the box's top edge at the top.** The page is
  then seen as it was composed, as in paging. Resting the first line there instead would put a
  centred dedication at the top of the screen with all of its blank space below. The last lines
  of the section before show in the top margin, as they do above any position. The same is
  done for a position anywhere inside a box that fits the visible area.
- **A box is at most one viewport, so `min-height: 150vh` behaves as `100vh`.** In paging the
  cap keeps a box and its text on one page with no blank page after it. In continuous scroll
  the box is half a screen shorter than WebKit makes it, all of it blank space. None of the ten
  titles asks for more than one viewport.
- **A one-page epigraph leaves the second column of a spread empty.** That is the paging rule
  for every section (a section starts a spread), not something the alignment added. Changing
  it would repaginate every book with a short section.

## Input and accessibility

`View.epubReaderPageControls(_:)` configures direct page input live; see
[integration](integration.md#configuring-page-controls) for the API, validation and examples.
The following are the defaults. Host commands and accessibility actions stay enabled.

- Paginated: a tap or click within 56 pt of either edge (except on a link, an image, a press-and-hold or
  while text is selected), a horizontal swipe (not while text is selected), and on macOS a
  trackpad gesture or wheel tick turns a page. Continuous scroll scrolls natively.
  A trackpad gesture turns one page once it has moved 4 points, and its momentum none. A wheel
  tick is 4 points or more, after which the wheel turns nothing for 450 ms, as the WebKit
  reader did. A notched wheel's movement comes in lines, which count 40 points each, WebKit's
  and Chromium's line step, so one notch turned slowly, a tenth of a line, is a tick, and a
  wheel spun fast still turns a page each 450 ms
  ([#163](https://github.com/vocaro/EPUBLib/issues/163)).
- Keys (all flows): Left/Page Up previous, Right/Page Down/Space next, Shift-Space previous.
  Home and End go to the book's start and end (`EPUBPageAction.bookStart` and `.bookEnd`), as
  `.goToStart` and `.goToEnd` do, and on the Mac Command-Up and Command-Down too, which a Mac
  text view takes for a document's start and end; on the Mac they come as key equivalents, as
  every bound chord with Command does. The book's start is the first section page turns reach,
  its end the last; one not built yet is built and then shown. They are logical, as the turns
  are, and no tap, swipe or wheel goes there
  ([#681](https://github.com/vocaro/EPUBLib/issues/681)).
  A key reaches the reader only through its responders. On iPhone and iPad UIKit focuses
  nothing on its own. Before #681, on an iPad simulator, Right Arrow typed with
  `XCUIElement.typeKey` turned no page, before or after a touch on the page. With the canvas
  taking the focus it turns one, and Space does too. XCTest sends the app no press for Home or
  End there ([reader controls probe](testing.md#reader-controls-probe)). The canvas now takes
  the focus when it is shown and when a touch begins
  on it (`ReaderTouchObserver`, which recognizes nothing), while no other view in its window
  holds it (`takeKeyboardFocusIfFree`), so a field keeps its keyboard. A change of flow leaves
  that focus on the canvas, where the Mac moves it to the first text view.
  In continuous scroll a page turn scrolls by one viewport less a line. A backward turn
  refines the newly shown text through the line that was first and keeps that line at the
  new screen's bottom, so estimates for tall images above a jumped-to position cannot skip
  content. When the first mostly visible line is itself a tall image below the top, the
  backward step is shortened to keep at least half of it on screen
  ([#161](https://github.com/vocaro/EPUBLib/issues/161)).
  `ViewCoverageScrollTests.testAPageTurnBackAfterAJumpPastFiguresKeepsTheLineThatWasFirstOnScreen`
  covers a jump past figures and successive backward turns. Where the book has a float or
  positioned box anywhere the reader places every line itself, and TextKit 2 gives the text
  it has not laid out no height, so the document ends at the last line laid out, and on Mac
  a turn stopped there, short of a screen
  ([#369](https://github.com/vocaro/EPUBLib/issues/369#issuecomment-6341377089)). So before
  a scroll past that end the screen it opens is laid out, which for a turn forward is a
  screen at most. A turn back into a section before the book is built shows the section's
  end (`scrollToAnchorLine`), and lays out the whole of that section to reach it, on the main
  thread in the key press or action that turned the page; the cost grows with the section's
  length ([measured](https://github.com/vocaro/EPUBLib/issues/369#issuecomment-6341953637)).
  Laying out only its last screen is not possible: TextKit 2 estimates nothing in such a
  text, so the last screen's place is known only once everything above it is laid out
  ([#746](https://github.com/vocaro/EPUBLib/issues/746)). Once the book is built no turn
  asks for a section's end. On iOS the scroll view's content has the whole text's height
  already.
- Page turn animation ([#688](https://github.com/vocaro/EPUBLib/issues/688)):
  `View.epubReaderPageTurnAnimation(_:)` chooses how a page turns in paginated flow
  ([integration](integration.md#animating-page-turns)). `.none`, the default, replaces one page
  with the other at once, as before. `.slide` moves the page shown away and the next in beside
  it in 0.3 s, from the right in a book read left to right and from the left in one read right
  to left, and back the other way. `.dissolve` fades the one into the other where they stand,
  in 0.25 s. With Reduce Motion on, a slide dissolves, so no turn moves (`ReaderPageMotion`).
  Every turn in pages has it: an edge tap or click, a swipe, a key, the wheel and trackpad,
  VoiceOver's actions, scroll and reading on, the selected passage's continuation, the host's
  commands, and a turn into a section not yet built, which comes in once it is
  (`showTurned`). Continuous scroll scrolls as before whichever is chosen
  ([#622](https://github.com/vocaro/EPUBLib/issues/622)).
  The columns hold the page turned to as soon as the turn returns, as with no animation: the
  delegate is told at once, VoiceOver is told and its cursor sent as above, and the selection
  and highlights are those of the turn with none. Only what is drawn over them moves
  (`ReaderPageTransition`): a picture of the columns as they were drawn before the turn goes
  (`snapshotView(afterScreenUpdates: false)` on iPhone and iPad; on Mac each column drawn
  again into a bitmap, `cacheDisplay(in:to:)`), and the columns are drawn coming in by an
  animation of their layers, which leaves their frames, and so what VoiceOver and a touch
  find, where the page ends. What is drawn is no accessibility element, holds none, and lets a
  touch or click through. A turn made meanwhile, a relayout or another page shown ends the one
  in motion where it would have ended.
  A swipe follows the finger on iPhone and iPad. With an animation chosen the canvas's swipe is
  a pan across the page (`ReaderPagePanRecognizer`), and the swipe of before with none. The
  page moves with the finger, or fades as far as it has gone, and the page it moves towards
  comes in, drawn by columns of its own laid out as the turn would show them, with the
  highlights it would draw, which nothing reads or touches (`turnPreview`). Nothing is turned
  until the finger lets go: past half the width, or flicked on at 300 points a second or more,
  the page is turned to as by any swipe (`turnPageFromInput`) and goes the rest of the way in;
  short of that, or moving back that fast, it goes back to where it was, and nothing is told.
  Towards no page, at an end of the book or before the next section is built, the page gives
  less the further it goes and goes back, and a section not built is asked for and comes in
  once it is. A selection begun during the swipe puts the page back.
  On Mac a trackpad's swipe across the page is followed the same way where System Settings has
  a swipe go between pages (`NSEvent.isSwipeTrackingFromScrollEventsEnabled`): AppKit tracks
  it, moves the page with the fingers and, once they lift, on or back
  (`trackSwipeEvent(options:dampenAmountThresholdMin:max:usingHandler:)`), and the page turns
  where AppKit took it all the way (`followPageSwipe`). A trackpad moved up or down, a wheel,
  and a trackpad with no swipe between pages turn the page once it has moved, as before, with
  the animation.
  Not done: a curl ([#810](https://github.com/vocaro/EPUBLib/issues/810)). A search match and
  a selection in a data table's cell, on the page a swipe brings in, are drawn once that page
  is turned to: the swipe's columns are given no table interaction, which draws them. No
  trackpad has swiped a page on Mac: the steps AppKit's tracking gives are held in process
  (`PageTurnAnimationTests`), and an amount above zero is taken to move the page to the right,
  as WebKit's swipe between pages takes it, which only fingers on a trackpad can confirm.
- The host's controls, under `epubReaderHidesControls`
  ([reader controls](reader-controls.md#hiding-the-controls-while-reading)): on iPhone and iPad
  a tap in the middle of a page, anywhere but the edge zones, a link, a picture or selected
  text, shows or hides them once it is not the first tap of a double tap, except while VoiceOver
  is running, whose double tap on a line arrives as such a tap; VoiceOver's Magic Tap does the
  same from any line of the text. A page turned by a key, a swipe, an edge or the
  wheel, and continuous scroll dragged by a finger or moved by a Mac's wheel or trackpad, are
  reading on, which hides them where `whileReading` asks (by default on iPhone and iPad, not on
  a Mac); a turn VoiceOver or the host asks for is not. Without the
  modifier the tap's recognizer is off and Magic Tap goes on to the app
  ([#696](https://github.com/vocaro/EPUBLib/issues/696)).
- VoiceOver: the text offers the page turn itself, and reads in order from the text views.
  On iPhone and iPad each line of a page offers Next Page and Previous Page, and the
  reader's SwiftUI surface has a page-turn `accessibilityScrollAction`. On Mac each text
  area offers the pair, named for the flow (the next item). The surface names no action on
  any platform: UIKit offers
  [the actions of every element that contains the item](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#uikit-offers-the-actions-of-every-element-that-contains-the-item),
  and SwiftUI
  [puts named actions on the canvas](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/accessibility.md#swiftui-puts-named-actions-on-the-view-it-hosts),
  which holds every line. With the two named there, VoiceOver said "Actions
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
  first of the lines the scroll view lists (see "Continuous scroll" under Layout). After a
  search result is shown it starts at the result's line, which rests below the top. Text that
  a book hides from the page and keeps for assistive technology is read where it stands, as
  text ([hidden labels](#floats-and-positioned-boxes)). Text it shows and keeps from
  assistive technology with `aria-hidden` is not read
  ([Text kept from assistive technology](#text-kept-from-assistive-technology)), and nor is
  anything `visibility: hidden` hides, text, pictures, formulas or rules
  ([Hidden text](#hidden-text)). An image is read by its `alt`, one
  with an empty `alt` is passed over, and so is one the book keeps from assistive
  technology with `aria-hidden` or a presentational role, and one with no `alt` is
  announced as an image without a name ("Alternative text" under Decisions). At a rule
  VoiceOver says "Separator", from a stop of its own on iPhone and iPad and from an element
  in the text on Mac, unless the book keeps it from assistive technology ("Rules" under
  Decisions). On Mac all of this holds inside a table cell too, whose text VoiceOver reads
  once it interacts with the cell's row and then with the cell.
- A page turned under VoiceOver's cursor, on iPhone and iPad. VoiceOver
  [keeps its cursor on the element object it was given](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#the-rotor-keeps-its-place-only-on-the-same-element-object),
  and a page's lines are items of that page: turn the page and the cursor is on a line that
  is no longer shown.
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
  A data table's cell goes with the page as a line does, into a table and out of one. A
  line and a cell are one class of item, which answers whoever asks whether it is a cell
  (`UIAccessibilityContainerDataTableCell`), and whether it has a row and a column to give,
  by what it is at the time; a line asked all the same
  gives the protocol's own answer for neither. A line's item becomes the cell that opens
  the page turned to, among the cells of that page's table, and VoiceOver reads it as it
  reads a cell it comes to: "Entry 27, Row 28, Column 1, Table start, 41 rows 3 columns".
  A cell's item becomes the line that opens the next page and is read as a line, with no
  row or column said of it or of the lines after it. The rotor keeps the action each
  time, and the next double tap performs it (iPadOS 27.2). With Next Page chosen on a
  cell, a double tap read the line that opens the next page and a second the first line
  of the page after. Chosen on a heading whose next page opens with a cell, a double tap
  read the cell, with its row and column as above, and a second turned the page from
  that cell onto a page of lines.
  From a cell to a cell is the exception: VoiceOver is given the new cell's own item, and
  its rotor starts again there, so a second double tap turns nothing. Given the item it
  held, a simulator's VoiceOver kept the rotor and said the cell's words alone, "Entry
  15", where of a new item it says "Entry 15, Row 16, Column 1, Table start, 41 rows 3
  columns". When it says a cell's row and column is VoiceOver's own rule, which nothing the
  reader posted changed, and the reader does not say the place in its own words in their
  stead (iOS 27.0 simulator). A reader of a table needs the row a page begins at more than
  the rotor's place: on each later page of a table longer than a page, Next Page still
  takes its flick down.
  Three cursors are left where they are, and two of them are told of the page.
  One that is not in the text stays where it is: after the host's Next Page button
  VoiceOver is still on the button. One whose line is still on the page keeps it, as when
  the same page is shown again: the host changes the appearance, or the text is built
  again. What VoiceOver holds is not left to it in either: it
  [moves through a cache of the items around its cursor](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#voiceover-moves-through-a-cache-of-the-items-around-its-cursor),
  and nothing tells it that a page was shown under them by something it did not do, a key
  on a keyboard or the host's own command. A page shown again has new items for its lines,
  so what VoiceOver holds is gone then as it is after a turn (iOS 27.0 simulator). Back on
  the last control before the text after reading into a page
  that was then turned, or on the page button with the whole page held after a menu, its
  move into the text read the first line of the page before, and its next put it back
  on the control: the page shown was reached the second time round. On a line of a page
  that was then shown again, one move back and one forward took it out of the text, to
  the control it had touched before it began to read.
  So when a page is shown and no cursor has left it, the canvas posts a layout change with
  no element (`ReaderCanvasView.accessibilityPageWasShown`), as it does after a move of
  its own in continuous scroll. VoiceOver drops everything it holds 0.8 s later, by its own
  log, says nothing and stays where it is, and its moves from there are through the items
  of the page shown.
  A page shown again has a new item for the line under the cursor as for every other, and
  VoiceOver then set its cursor on that one as it dropped what it held, without a word,
  and its rotor was at its default there: an action chosen before the page was shown
  again took one flick down to choose again. So the item VoiceOver holds goes on as the
  item of its line when its page is shown again, as it does across a turn. It takes the
  place of the line's new item in its column's list, with everything that one has
  (`ReaderTextView.accessibilityCursorKeepsItsLine`), before the change is posted.
  VoiceOver's cursor is then on an item of the page already: its log has no `Will set
  element` at the forced update, nothing is said, the flick down after it says "Previous
  Page", the action after the one chosen, and the moves from there read the page's lines
  in order, the kept one as what it is, a heading, a link or an image (iOS 27.0
  simulator). A data table's cell keeps its item here too, where across a turn a cell
  that becomes another cell does not: the cursor comes to no other cell, and nothing is
  to be said of one. Its table's item is kept with it, for the table as it was built
  again. With the cell kept and a new item for its table, VoiceOver said the cell's
  header cells and its words whenever it came back to that cell and no longer its row or
  its column, "Depth Twelve metres" for "Depth Twelve metres Column 3" and "Alder Depth
  Twelve metres" for "Alder Depth Twelve metres Row 2 Column 3"; with both kept it says
  the place as before, and the rotor stays on a cell as on a line. A
  second such change right beside the one that sends the cursor,
  before it or after it, as a page shown again for a new size just before a turn would
  post, left what VoiceOver read and its rotor as they were in nine sessions of ten, and
  in the tenth the line was read some seconds late. On a device VoiceOver asks again by
  itself once it has activated an item, as an iPad did after its double tap on Scroll
  Forward ("Continuous scroll" above), so this is for what it did not do itself; no
  device has run it
  ([VoiceOver testing](testing.md#voiceover-testing), "Harness pitfalls and current results"). And
  a move by heading that turns the page posts
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
- VoiceOver reading on by itself in pages, on iPhone and iPad: two fingers swiped down, or
  Read All. The last item VoiceOver reads on a page, its last line or, where a table of
  data ends the page, the last cell listed, has `UIAccessibilityTraits.causesPageTurn`, and in a
  spread the last item of the right-hand page (the left-hand one in a book read right to
  left; `ReaderCanvasView.accessibilityPageTurnColumn`), since
  [Read All turns a page only after such an item](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#read-all-turns-a-page-only-after-an-item-with-causespageturn).
  The item keeps all it says and offers besides. No item has it on the book's last page in
  its reading order, nor while text is selected. So reading stops at the book's last line,
  and VoiceOver went on to the book's title under the reader and ended. The trait is asked
  of the reader each time it is read, never kept on the item, since the item under the
  cursor goes on as the next page's first line. Reading on, VoiceOver played its page sound
  at the turn and did not say the words. What it read after the turn is its own and the
  host's ([#554](https://github.com/vocaro/EPUBLib/issues/554)): in the reader screen the
  VoiceOver lanes run, whose controls stand above the reader, it read on from the top of
  the screen, the controls and then the new page from its first line, every line once and
  in order through each turn, and with no controls there it stopped after the turn. Until
  VoiceOver's cursor leaves the item its turn left it on, no other item has the trait
  (`ReaderCanvasView.accessibilityCursorAtTurn`), and VoiceOver finds none there and stops;
  on a page of one line, that item is the page's last, keeps the trait, and is read. That
  is a simulator's VoiceOver, started by its Read All key; no device has run it
  ([sessions](https://github.com/vocaro/EPUBLib/issues/468#issuecomment-6164933289), and
  [with the turn held back](https://github.com/vocaro/EPUBLib/issues/468#issuecomment-6262997758)).
- VoiceOver on Mac: each text area offers the page turn as actions of its own
  (`NSAccessibilityCustomAction`), Next Page and Previous Page in pages and Scroll Forward
  and Scroll Backward in continuous scroll. Those are the names `EPUBReaderControls` gives
  the host's buttons, and `EPUBPageAction.label(in:)` is behind both. They are on the text
  area because
  [custom actions belong there](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#custom-actions-belong-on-the-text-area).
  The menu says "Actions menu 3 items" and lists Previous Page, show menu and Next Page, or Scroll
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
  `ReaderCanvasView`, the view the surface wraps, is not an accessibility element, so a
  named action or a scroll action that SwiftUI is given for it
  [reaches no element](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/accessibility.md#swiftui-puts-named-actions-on-the-view-it-hosts)
  and the surface has neither on Mac. The scroll area has AppKit's
  four scrolls by page, which are the only scroll actions in either flow.
  Two limits. An item of the text that takes VoiceOver's cursor by itself keeps its own
  menu, without the pair: a link reached with Find Next Link offers "press". And the
  accessibility API reports a failure for the action in continuous scroll (-25200), though
  the view scrolls and VoiceOver's own choosing works: the reader's handler returns true
  there as in pages, where the API reports success
  ([#465](https://github.com/vocaro/EPUBLib/issues/465)).
  A step in continuous scroll made straight after VoiceOver enters the text, before it has
  moved in it, holds as any other, with the action and with a page key: the reader tells
  of the insertion point twice ("Continuous scroll" under Layout). Told once, VoiceOver
  went back to the line it had entered at and took the view with it.
  [VoiceOver testing](testing.md#harness-pitfalls-and-current-results) has the
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
  book, which each element keeps, so that it
  [gives the same answer twice](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#a-custom-heading-rotor-must-give-the-same-answer-twice).
  A section that is not built yet
  ends the search, as does one still built for an appearance the reader has left (**One
  appearance on screen** under [Decisions](#decisions)), and so does the end of the book. A rotor is not an action: VoiceOver says
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
  section that is not built yet, or still built for an appearance the reader has left, ends
  it on that side: in the seconds after a book opens
  it holds the sections built so far around the page. A heading that begins on an earlier
  page and ends on this one is listed once, where it begins.
  The search is written to
  [how VoiceOver was seen to ask](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#mac-headings-need-a-rotor-rich-text-levels-and-child-elements)
  (macOS 27.0.1). Asked from a column at its first character and none of it, as after a
  page turn, it starts at the top of that page: a heading that opens the page is the next
  one, and going back the search stands after the page's last character. A token's result
  also carries a range, the heading's characters in its section, and every result has a
  label.
  With VoiceOver's cursor on a link the move to the next heading goes another way, through
  the text's children and by no rotor
  ([#431](https://github.com/vocaro/EPUBLib/issues/431),
  [#454](https://github.com/vocaro/EPUBLib/issues/454)). With no heading among the children
  it said "Heading not found", though headings followed. So each heading has an element among
  the text's children too (`ReaderHeadingAccessibilityElement`), where it stands among the
  links: AppKit's heading role, the heading's words as its label and its level as its value.
  VoiceOver says both, "heading level 2 Link target reached", where the move from the text says
  the words
  alone.
  The children hold the headings on screen or on the page and, after them, the book's next
  heading, so that the move from the last link there has it to go to, a child before
  VoiceOver looks for it. In continuous scroll it is the next one below the
  screen, a heading of the view's own text. In paging it is on a later page: an element at
  the foot of the column, a point high, called by the heading's words
  (`ReaderCanvasView.headingAfterPage`), and the last of the column's children. A chapter
  that is not built yet ends the list, as it ends the rotor's.
  VoiceOver
  [focuses the element it moves to](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#voiceover-focuses-only-an-element-that-reports-its-focus),
  and that is all it tells the reader of the move. A heading it does not show, the reader
  then shows, and puts the insertion point on it (`ReaderTextView.showHeading`). In
  continuous scroll that is a heading with no character on screen. The reader shows it as
  it shows a link's target, where VoiceOver would scroll to the element by the scroll bar,
  which the reader takes for any other scroll. In paging it is a heading on a later page,
  and the reader turns to that page as it does when VoiceOver loads a heading the rotor
  gave. The element VoiceOver is on becomes the heading's own in the column that then shows
  it, one of that column's children with its place there: an element that left the children
  would leave VoiceOver's cursor on the column. VoiceOver says the heading, then the first
  words it says after any page turn, then the heading again. Its cursor is on the element
  and not in the text, and its next move by word or by line starts from the insertion
  point, which was wherever VoiceOver had last read, or the first line on screen: with it
  on the heading, one move right says the heading's first word and reading goes on from
  there, and the next move by heading goes on by the rotor from the heading.
  A heading with any of it on the page or on screen already is left as it is, the insertion
  point too. Told that the insertion point of the text it is in has moved, VoiceOver says
  the word before the new place, some 60 to 110 ms after it has begun the heading's level
  and words, and that is what a listener hears: from a link to a heading two lines under
  it, "finish.", the last word of the paragraph between them, where the heading was cut
  off or not recorded at all, in pages and in continuous scroll (macOS 27.0.1). The same
  was heard for a link ([#425](https://github.com/vocaro/EPUBLib/issues/425)). Left as it
  is, the heading is said whole, "heading level 3 Second part opens", from a link and from
  another heading's element. Where the reader has turned or scrolled it also tells
  VoiceOver that the layout changed, and VoiceOver then says the item under its cursor
  again, which is why a heading the reader had to show is heard: in continuous scroll
  "word1200" and then "heading level 2 Link target reached". In a spread, a heading in
  the column beside the one VoiceOver is in still takes that column's insertion point,
  with no page turned: VoiceOver said the heading whole and no word for the other text.
  What is left as it was (macOS 27.0.1):
  - Past the book's last heading the move from a link begins again with the first heading
    among the children, which is the first on screen or on the page, and says "Heading not
    found" where they hold none. From the last heading's own element, with no other on
    screen, VoiceOver says "Last heading" and stays; with another on screen it begins
    again with the first of them.
  - After a move to a heading that was on the page or on screen already, reading on by
    word or by line starts where VoiceOver last read in the text, on that page or screen,
    and not at the heading: `describe` names the heading, and one move right says the
    first word of the line VoiceOver was on. The move by heading from there, by the rotor,
    reaches the heading with VoiceOver's text cursor on it. Moving the insertion point to
    the heading and then telling VoiceOver that the layout changed, as the window does
    after a scroll, was heard to keep both: VoiceOver said "finish." and then "heading
    level 3 Second part opens", and one move right said "Second", in pages and in
    continuous scroll. It was left out for the word, which is then said before every
    heading a listener moves to on one screen. Posted by the element that holds the text,
    the same change brought the heading back in pages and not in continuous scroll.
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
  VoiceOver's search for elements (`AXUIElementsForSearchPredicate`), which could end the
  move at the book's last heading in place of beginning again, and which
  [nothing should offer VoiceOver](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#never-offer-voiceover-the-accessibility-element-search).
  So no text and no element of the reader offers the search, and the move from a link
  past the last heading begins again.
  Not marked for VoiceOver: a heading inside a table, whose cells are read as cells, and on
  iPhone and iPad a heading inside a note's popover, which keeps UIKit's own elements.
- Language: VoiceOver chooses a voice for the language it is given
  ([spoken language](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/text-layout-and-unicode.md#voiceover-speaks-the-language-each-item-and-range-names)).
  On iPhone and iPad each
  item of a page or of continuous scroll names the language of its words
  (`accessibilityLanguage`): the language its characters carry for typesetting, which is
  the nearest `xml:lang` or `lang` and else the package's first `dc:language` ("Content
  language" under Decisions), and none for an empty tag and for `und`, `mis`, `mul` and
  `zxx`, which name no voice (`InlineLanguage.spoken`). It is the language a formula looks
  up for its `alttext` ("Spoken math"), and a formula's item keeps its reading's language.
  An item whose words are in several languages, a line of English with a French phrase in
  it, a heading, or a row of a table read whole whose cells differ, names the language most
  of its characters are in, and each part of its label carries its own
  (`accessibilitySpeechLanguage` in its attributed label): "He said bonjour and left."
  names English, and "bonjour" in it French. White space is in the language of the words
  before it. What VoiceOver is not given weighs nothing: characters `visibility: hidden`
  hides ("Hidden text"), and the words of a picture the book keeps from assistive
  technology. The label's words, the item's traits and its actions are those of words in one
  language, and a heading keeps its level over the whole label. A cell of a table of data
  is read as one text, in the language most of it is in, and so is the name of a header
  cell VoiceOver says before it: a part of a cell in another language is not set apart. A
  picture's words name no language ([#548](https://github.com/vocaro/EPUBLib/issues/548)),
  and the reader's word for a rule, which is none of the book's, names none. A note's
  popover keeps UIKit's own elements. In the simulator lane VoiceOver speaks a line of
  French, one of German and one of Spanish each in a voice for its language, and "He said
  bonjour mes amis and left." in three parts, the middle one in its French voice; without
  the languages it spoke all of them in its English voice
  ([#65](https://github.com/vocaro/EPUBLib/issues/65#issuecomment-6164353724)).
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
| `locate(text, highlight)` | First match in reading order with foliate's matcher that renders and shows, as a search result does. `highlight` selects it natively (emitting `.selectionChanged` with the passage). A passage found only in content that renders nothing (`display: none`, a hidden note) or that `visibility: hidden` hides is shown where its first match is, wherever that sits in its section, and is never selected. A miss emits `.notice("The passage could not be found in this book.")`. Clears search highlights. |
| `searchHighlight` / `clearSearch` | Draws every match across the book and lists the rendered ones as `EPUBSearchResults` with no current match / removes and withdraws them. |
| `search` | Draws and lists matches, opens the first rendered match in spine order and makes it the current match; no matches preserve the position. |
| `nextSearchResult` / `previousSearchResult` | Shows the result after or before the current match, wrapping at the ends; the first or last when none is current. No effect without results. |
| `showSearchResult(result)` | Shows a listed result and makes it current; a result of a replaced or cleared search throws `invalidCommand`. |
| `style` | Font size 12–96, scaled by the system text size first with `followsDynamicType` (below), System/Light/Dark/Sepia/Black/Custom appearance with the style's custom colours, flow. System is the default and tracks the host color scheme live; explicit modes stay fixed. Size, resolved colours, Increase Contrast and Bold Text rebuild the text; the position is kept across rebuilds and flow switches (see Themes under Decisions). |
| `setHighlights` | Replaces drawn host highlights. |
| `goToProgression(value)` | Shows the place `value` of the way through the book by `progression`'s own measure (section byte size, nonlinear sections weighing nothing): the section where that share of the bytes ends, at the same share of its characters, entered at its page's first line. 0 or less is the first linear section's start and 1 or more the last one's end, so `goToStart` and `goToEnd` show the first and last page, or the top and bottom of continuous scroll; on a boundary between sections the later one's start. A value that is not finite throws `invalidCommand`. The page shown reports a progression at or after `value`, measured at its end ([#681](https://github.com/vocaro/EPUBLib/issues/681)). |

`.searchResultsChanged` reports the result list before `.searchChanged(.completed)`, then each
change of the current match, and nil when a clear, another query, a failure or `.locate`
withdraws the list. A search cancelled before its results are published ends with none; a
cancellation that arrives after they are published withdraws nothing, and the search completes.
Results are in spine order, then document order
(see [search results](reader-controls.md#search-results)).

`.ready` is emitted once, when the opening section is on screen in a mounted view, built for the
host's appearance (see Decisions), and the first `.relocated` reports the opening position (the text
start, see Decisions). `.relocated` carries the section href, overall progression (by section byte
size, as foliate-js computed it), the table-of-contents title for the position, the page-list
entries it shows (see Decisions) and the visible range's CFIs. A nonlinear section counts nothing
toward progression unless no section is linear (see Decisions). The pages of the layout on
screen are not in the location: `EPUBReaderStatus.layoutPage` has them, set before the
`.relocated` of the same pages and changed again, with no event, as counting goes on
([Layout](#layout), "Page numbers"). A selection's `.selectionChanged`
event and host selection action carry the same complete passage: `text` omits nonlinear sections,
and `location.rangeBookmarks` preserves all included documents. Its `page` names the entry in effect
at its start and `pages` includes the entries it spans, omitting nonlinear pages. Save the entire
`EPUBLocation` and pass it to `.setHighlights` to restore all segments in either flow, including
after typography changes.
No partial annotation is drawn while a section is building or if any segment fails to resolve.
An empty collection, a contradictory first bookmark, a foreign identity/format or malformed CFI
is incompatible; unordered/duplicate document targets, nonlinear multi-document targets or
unresolved CFIs leave a highlight undrawn, as does a passage that renders nothing, wherever it
sits in its section. `EPUBReaderStatus.undrawnHighlights` names each highlight not drawn, an
incompatible one too, by `id` with why, and the list gives one `.notice`, "Some highlights could
not be shown.", however many there are (#698). `restore` similarly refuses an incompatible location
or emits a notice without navigating for an unresolved collection, or one with a document whose
part renders nothing.
Sections requiring unqualified HTML tree repair do not emit bookmarks. Existing CFIs into
those sections are refused with a notice instead of restoring or highlighting a potentially
different passage. Href navigation, readable content, selection text and text search remain
available. A selection spanning an unsupported section emits its text and quote without a
partial bookmark collection. This restriction is independent of the opt-in headless
text-extraction recovery.
Strict namespaced XHTML retains its XML DOM and existing CFIs. For documents Foliate would
retry as HTML, compatibility requires UTF-8 XML-shaped markup with explicit head/body,
ordinary flow/inline elements and lists, and valid HTML nesting. Pre-head whitespace is
dropped, between-head/body whitespace retained, and whitespace after the body and root
merged into the body. Namespace errors fall back to HTML with CFIs disabled. Unknown namespace
URI warnings keep the XML tree: libxml2's URI-warning codes 99 and 100 are allowed;
actual namespace errors are collected per parse, so a later URI warning cannot hide an earlier
undeclared prefix or invalid QName. Self-closing nonvoids, closing void tags, table tree construction, CDATA, raw-text or
foreign elements, literal attribute tabs/line endings, and HTML numeric-reference remapping
are outside this subset. These cases require source correction or a host's explicit quote
search for migration; changing an engine/format tag alone cannot repair their positions.
For selected fallback XHTML or SVG, local-root CFI assertions carry
`vnd.epublib.resource=<SHA-256 digest of effective href>`. Resolution verifies the resource before
using offsets; an unmarked original-source CFI or a contradictory resource assertion cannot
silently address the fallback DOM. Qualified CFIs allow at most two fixed-size resource assertions within a 4,272-character wire
limit, retaining the ordinary 4,096-character underlying CFI budget. Package itemref paths and
ordinary original-document CFIs
remain unchanged ([#78](https://github.com/vocaro/EPUBLib/issues/78)).

`.disclosure` text summarises the books' `SectionReport`s and is re-emitted when it changes. `.notice` reports
refused links outside the book ([Security](#security)), unresolved CFIs and quotes, and highlights that could not be drawn,
each in a plain sentence that a host shows as it is ([integration](integration.md#when-something-fails)).

`EPUBReaderStyle.followsDynamicType`, off by default, scales the chosen font size by the system
text size before it is drawn: by the body text style's size at the mounted view's
`dynamicTypeSize` over its 17 points at Large (`DynamicTypeScale.swift`), so that book text at
the default size is as large as the system's body text. On iPhone and iPad UIKit's preferred body
font gives both sizes, which are those Apple's Human Interface Guidelines list: 17 points is
drawn at 53 at the largest accessibility size and at 14 at the smallest, and 31 or more reaches
96. `UIFontMetrics`, which scales a custom size along a curve of its own, was not used: on iOS
27.0 it scaled 17 points to 48 at the largest size and to 15 at the smallest, so book text would
have been smaller than body text at every accessibility size. What is drawn stays
within 12–96. The system text size reaches the reader as its view's `dynamicTypeSize`, from the
window's content size category, so a host's own `.dynamicTypeSize` on the reader applies too. A
change while a book is open rebuilds the text as a size command does and keeps the place read,
the canvas's anchor, in both flows. The view's size is remembered while the option is off, so
turning it on applies the latest at once. `readerState.status.effectiveFontSize` reports the
size drawn and `dynamicTypeScale` the factor, 1 while the option is off. AppKit has no Dynamic
Type metrics or content size category: on a Mac the factor comes from the same guideline sizes,
and a view's `dynamicTypeSize` is Large unless its host sets another. Whether macOS's own text
size setting reaches a SwiftUI view's `dynamicTypeSize` has not been observed, since that would
change the Mac's settings ([#675](https://github.com/vocaro/EPUBLib/issues/675)).

## Security

Books are untrusted. Nothing is executed: there is no JavaScript engine. Every reference
resolves inside the archive through `ResourceReference`, but for an image in a `data:` URL,
which is read from the URL's own bytes (**Data URLs** under [Decisions](#decisions)); remote
URLs are never fetched and are counted for disclosure. XML, CSS and font input is bounded, and
the import limits in `EPUBReading` still apply.
What `var()` substitutes is bounded for one value and for a section, so that custom properties
that expand at each reference cannot stall a build or exhaust its memory (**Custom
properties** under [Decisions](#decisions)).

**Links outside the book.** EPUB Reading Systems 3.3 §3.9 has a reading system get the
reader's consent before it opens an `http` or `https` link, and before it hands a link to the
application of its scheme. So a link outside the book that the reader activates, by pointer,
keyboard or VoiceOver, in the text, in a table cell or in a note's popover, is asked about
first ([#683](https://github.com/vocaro/EPUBLib/issues/683)): "Open a link outside the book?",
with the address, and Open and Cancel. Only on Open is it opened, with the view's `openURL`
action, the system's unless the host sets its own, so a web page opens in the browser, apart
from the reader, and an email address in the mail app. Nothing is fetched to ask, and the
position in the book does not move.

- Only a web page, an `http` or `https` URL with a host, and an email address, a `mailto` URL
  with one, are asked about. Anything else outside the book, `javascript:`, `file:`, `data:`,
  `tel:`, an app's own scheme or an address with no scheme or no host, is never opened or
  handed to a host, and the `.notice` "This reader opens only web and email links outside the
  book." says so: such a link would run the book's own content, reach the device's files, or
  have another app act on the book's behalf.
- The address shown is the URL as the system will open it: percent-encoded, with an
  international domain name in its ASCII form, so the characters a book puts in it cannot
  reorder or disguise it. Past 1,000 characters it is cut short with "…"; the scheme and host
  come first.
- On iPhone and iPad the question is an alert from the view controller on top, over a note's
  popover when one is shown, and the note is still there after it. Open is its preferred
  action, which Return chooses on a keyboard, and Cancel its cancel action, which Escape
  chooses. Its title is the question and the address on two lines, and it has no message:
  UIKit gives a message an element of its own, and VoiceOver reads only an alert's first
  element as it comes up, so with the address as the message it said the question alone and
  the address on the next swipe ([#793](https://github.com/vocaro/EPUBLib/issues/793)). After
  Cancel VoiceOver's cursor goes back to the item it was on, the link, the table's row or the
  note's text: as the alert went, VoiceOver took the first item of the screen, a control of
  the host, while the link's element was still listed. The reader names the item with a
  screen change as the answer comes, and puts the cursor back if VoiceOver comes to another
  item after it, or is still elsewhere a second later. On simulators that took VoiceOver
  straight back to a link or a row; over a note the iPhone said the popover's first item and
  was back on the note's text a second later. After Open the cursor is left to whatever was
  opened. On Mac it is a sheet on the reader's window, Open its default button (Return) and
  Cancel its second (Escape), and a note's popover is closed first: it is a window of its
  own, which would stand over the sheet.
- One question at a time: a second link activated while one is asked about replaces it, and
  the first is answered no. Closing the session, or the view leaving the window, takes the
  question away, and nothing is opened after it.
- A host chooses with `epubReaderExternalLinks(_:)`
  ([integration](integration.md#links-outside-the-book)): `.ask`, the default; `.refuse`,
  where every link outside the book gives the `.notice` "This reader does not open links outside
  the book.", as every one did before; or `.handle`, where the host is given each web or email
  address and asks, if it wants to, itself. The view's setting is read each time SwiftUI
  updates it, so a change reaches a reader already shown.
- A link inside the book in a note's popover still does nothing there.

Subsequent-sibling CSS searches (`~`) share a memo entry when their entire left-hand selector
suffix is equal, across rule declarations, right-hand subjects and nested pseudo-classes.
The rule index admits selectors in source order only while their distinct search suffixes
fit 65,536 entries after reserving one entry under every parent with more than nine element
children. Parents with nine or fewer children use the short direct walk and reserve nothing.
A selector that would exceed that bound is omitted as a whole, including any searches inside
`:not()`, `:is()` or `:nth-child(… of S)`, and sets `SectionReport.stylesTruncated`; selectors
without `~` remain eligible. No retained search is evicted during a section build, so input
above the memo's capacity cannot restore the quadratic sibling walk. The memo keeps its
approximately 4 MB bound. This conservative reservation can omit selectors even where a
particular subject would never ask under some parents. Exact matches, specificity and source
order of admitted selectors are unchanged. `SiblingSearchAdmissionTests` counts compounds
for 70,000 repeated searches over 60, 120 and 240 siblings and for 70,000 genuinely distinct
suffixes across two parents ([#341](https://github.com/vocaro/EPUBLib/issues/341)).


Filtered `:nth-child(An+B of S)` and `:nth-last-child(An+B of S)` share one sibling-rank
table per exact filter and parent, across patterns and directions, without a 1,000-sibling
cutoff. Rule admission reserves at most 1,048,576 Int32 rank cells (4 MiB), omitting a whole
selector and setting `stylesTruncated` when its tables would exceed that bound. Short parents
with at most nine element children are counted directly; retained tables are never evicted
([#262](https://github.com/vocaro/EPUBLib/issues/262)).

Layout ends whatever the text. A text container that is not a plain rectangle
[can be asked for lines forever](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#a-non-rectangular-container-can-ask-for-lines-forever),
as a tab with neither a stop after it nor a default tab interval did
([#227](https://github.com/vocaro/EPUBLib/issues/227)). Every paragraph style the builder
writes now has an interval, and `ReaderTextContainer` answers an empty rectangle once it has been
asked for a line at one character 1,000 times running, which ends the paragraph. The lines TextKit
set before it stay; the rest of the paragraph is not shown. The box plan, the pages and the
fragment's frame count the paragraph as far as TextKit sets what follows it, a line below its
last line, so later boxes and pages are where they would be had that rest been one line. The
section's `SectionReport.textNotLaidOut` is set from the layout, through a
`SectionLayoutRecord` its text carries, and the `.disclosure` says that some text could not be
laid out. In the reader's layouts of the fixture books and the corpora TextKit asks for one
character at most four times running ([#288](https://github.com/vocaro/EPUBLib/issues/288)).

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
  The focused runs are on [#21](https://github.com/vocaro/EPUBLib/issues/21#issuecomment-6159293120). The original catalog-wide WebKit
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
  viewport-relative font sizes and media queries remain based on that nominal 600 × 800
  viewport, in which `vmin` is its width and `vmax` its height whatever the reader's shape.
- Whole-table bookmarks and visible row ranges retain attachment granularity. A resize or
  flow change without a precise cell endpoint returns a continued row to its source position
  rather than preserving its particular visual fragment. A table's captions, and the cells
  past its bounds that follow it, are located as the table, not by their characters. A table
  that holds only cells written outside rows flows as text, a paragraph for each cell, rather
  than as the one anonymous row CSS gives them.
- MathML uses MathMLLayout 0.3.1 for width-aware layout, elementary math and localized
  generated readings ([#25](https://github.com/vocaro/EPUBLib/issues/25)). Unsupported elements
  retain the alternative-text fallback. The engine's remaining atomic structures can still
  require scaling, and an oversized display formula scales to remain on one page. Very large
  inline formulas can use one attachment rather than individual paragraph rows, as described
  above. `mglyph` images that cannot be resolved or decoded within the reader's limits use
  `alt` in the token's own style; without a description they show a box and have no spoken
  name. Body text and authored `alttext` are given their content's language, for VoiceOver to
  choose a voice by: AppKit reports each run's language, and on iPhone and iPad each item names
  the language of its words ("Language" under Input and accessibility). Generated readings
  carry the engine's actual selected language, which may be English fallback. The vocabulary's
  regional wording and naturalness are tracked by the upstream
  [speech review](https://github.com/vocaro/MathMLLayout/issues/63).
- SVG is static: filter effects are omitted with a disclosure, preserving the remaining diagram;
  pattern fills, animation and foreign content are unsupported. The unchanged networking
  publisher corpus renders all 33 SVG resources, including six containing shadow filters
  ([verification](https://github.com/vocaro/EPUBLib/issues/53#issuecomment-6159293638); [the book](testing.md#networking-svg-book)). StaticSVG
  screens each drawing against its rendering limits before its renderer reads it, and an SVG
  past any shows its fallback text with the `svg` disclosure. The
  [limits](https://github.com/vocaro/StaticSVG/blob/0.1.1/doc/design.md#limits) and
  [how each screen reads the drawing as the renderer does](https://github.com/vocaro/StaticSVG/blob/0.1.1/doc/screens.md)
  are StaticSVG's. Retained renderer font databases share a 64 MiB budget across the process.
  Each distinct set of fonts an SVG names is one database, with its own copy of the fallback
  faces, shared by every drawing that names those fonts. An SVG refused a database shows its fallback text. The networking book
  needs five databases, 58 MB on macOS 27 ([investigation](https://github.com/vocaro/EPUBLib/issues/54#issuecomment-6159293824)).
  The budget is shared by everything open in the process, and the renderer copies the font
  bytes it is given, which is why each database holds its own copy of the twelve fallback
  faces. That book alone uses 86% of the budget on macOS 27. A book naming more families in
  more combinations, or a second open book with other fonts, can still be refused databases,
  and its figures then show their alt text with the existing `svg` disclosure. Which figures
  lose depends on build order. Database sizes come from the system's fonts and were measured
  on macOS 27. The book's five databases also fit the budget on the iOS 27.0 simulators;
  their sizes there were not recorded. A pagination cached for a section's earlier text is
  replaced when that section is next paginated. In continuous scroll it is not, so up to
  eight replaced sections stay alive until the reader closes. Their figures share the current
  databases.
- Search uses locale-tailored primary collation for passage location and highlights.
  Locales without qualified prefilter coverage compare candidate windows directly, which
  can cost more on large sections (see "Search collation" under Decisions).
- A search completes once every section holding a match has been built, because results are
  the occurrences as rendered. On a book still building, completion waits for those sections.
  One search lists at most 10,000 results and reads at most 10,000 matches per section; past
  either bound the results say `isTruncated`. Result order, wrapping and the current match
  are described under [search results](reader-controls.md#search-results).
- Foliate CFI compatibility for HTML fallback is deliberately limited to qualified XML-shaped
  markup. HTML tree repairs outside that subset cannot issue or resolve saved CFIs; migration
  by href or an explicitly requested text search remains a host decision.
- Paginated accessibility bounds and actions have native API regression coverage. Live
  verification uses the [VoiceOver testing process](testing.md#voiceover-testing) and isolated reader.
  Mac VoiceOver sessions on 2026-10-11 verified first and last lines, word order, end of
  text at the page boundary, line counts, the heading, link and image labels, and numbered-word
  continuity across page turns in one and two columns at 17 and 23 points, through text-size
  and window-size changes, with a value-change notification for each
  ([record](https://github.com/vocaro/EPUBLib/issues/55#issuecomment-6159294286)); where
  VoiceOver re-enters a column it rests on after a page change is its
  [own text cursor](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#voiceover-enters-a-text-view-at-its-insertion-point).
  Sessions on a
  physical iPad and iPhone the same day verified reading order, the page boundary, link and
  image labels, the link's activation, and continuity across page turns made with the page
  buttons and with VoiceOver's Next Page and Previous Page actions, in portrait and landscape
  at 17 and 23 points, through rotation and a text-size change
  ([record](https://github.com/vocaro/EPUBLib/issues/28#issuecomment-6159294047)). VoiceOver's three-finger scroll has API coverage
  only: XCTest cannot perform it, and for it simulator and API checks do not substitute for a
  device session. Headings were read and moved between on 2026-10-12 on a physical iPad in both
  flows, on the hosted Mac and in the simulator lane; on a physical iPhone the heading was
  read, and no move by heading was made, because XCTest's gesture did not turn VoiceOver's
  rotor there. In paging on Mac the rotor's list and VoiceOver's move to the next heading
  were heard to go through the whole book the same day, on the hosted Mac
  ([VoiceOver testing](testing.md#voiceover-testing)). With VoiceOver's cursor on a link on Mac, the
  move goes to the book's next heading in continuous scroll and stays on the page in
  paging, where it goes back to the page's first heading when none follows the link; from
  a link after the book's last heading it begins again with the first heading on screen
  ([#454](https://github.com/vocaro/EPUBLib/issues/454)).
- Flex and grid alignment covers the single-column subset described above. Side-by-side row
  items, wrapping and reversed flex, multi-column and explicitly placed grids, `order` and
  inline flex or grid containers render as blocks in reading order with a disclosure. Within
  the subset: `flex-shrink`, `flex-basis`, `align-content` in flex, `column-gap`, percentage
  gaps, baseline alignment, `aspect-ratio` and an empty item's own `height` are not laid out;
  empty items beside a row's only item with content do not move it, which is placed as if alone;
  `box-sizing` applies to heights only; start-aligned items
  and items holding images, tables or formulas keep their block-flow width and placement; a
  box taller than one viewport is treated as one viewport tall; and a container holding a float
  or positioned box is left in block flow. `min()`, `max()` and `clamp()` heights choose their
  branch against the nominal viewport, as other lengths do
  ([record](https://github.com/vocaro/EPUBLib/issues/20#issuecomment-6159295296)). `text-wrap: pretty` and `balance` are not laid out: lines break greedily,
  where WebKit evens them out. `hanging-punctuation` is not laid out: a quotation mark a
  browser hangs outside its block is inside it, which makes the block that much wider. Rules
  that a row draws with empty `::before` and `::after` flex items are not drawn, and that is
  not disclosed. In continuous scroll a change of the visible height re-resolves the whole
  text's attributes when it holds an aligned box, as it already does for percentage-sized
  paragraphs, and the kept position is rested again afterwards. A container aligned only
  across the line or only by a gap, with no `height` or `min-height`, is not a box for the
  rule that rests a box's top edge: each of its positions rests its own line. That rule holds
  for every position the reader shows, the one a resize or a setting change keeps included:
  where the person has scrolled part of a one-screen box off the top, a resize shows the box
  whole again, moving its lines down to where the box puts them.
- Generated content ([Decisions](#decisions)) leaves out, with a disclosure, images and the
  other items of `content` the reader does not generate, and the generated content of a table
  laid out as a grid and of its rows. Without a disclosure: a `::before` or `::after` with no
  characters, drawn only for its border, background or size, is not drawn; one that a
  position or a clip hides from the page is not read by VoiceOver either, where a browser
  reads it; alternative text written after `/` in `content` is not read, and VoiceOver reads
  the characters shown; generated content inside a box hidden from the page and kept for
  VoiceOver is not read with it; `counter-reset`, `counter-increment` and `counter-set` of
  `list-item` do not change a list's numbering; and a counter style that `list-style-type`
  lacks (`@counter-style`, `symbols()`, `hiragana`…) is decimal. `::first-letter`,
  `::first-line`, `::marker` and the other pseudo-elements are not rendered: their rules are
  dropped, and that is not disclosed.
