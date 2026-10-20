# Release notes

## Unreleased

- Name the language of each line, heading, link and table cell to VoiceOver on iPhone and iPad, part by part where a line mixes languages ([#65](https://github.com/vocaro/EPUBLib/issues/65)).
- Separate in text extraction the text of `details`, `summary`, `fieldset`, `legend`, `center`, `form`, `hgroup`, `option` and eight other elements HTML renders as blocks, where it ran into the text beside it ([#90](https://github.com/vocaro/EPUBLib/issues/90)).
- Write a navigation or stylesheet link as the path the writer checked, so a target spelled with an empty or dot segment, such as `EPUB//one.xhtml`, is no longer written as a link to the container root, a host or a scheme ([#240](https://github.com/vocaro/EPUBLib/issues/240)).
- Read the title, creators, languages, identifiers and cover of an EPUB 2 package that wraps them in the deprecated `dc-metadata` and `x-metadata` elements, where it opened with none and refused a book with an IDPF-obfuscated font ([#85](https://github.com/vocaro/EPUBLib/issues/85)).
- Keep an `@import` that follows an invalid rule, such as an unknown at-rule or a style rule with an invalid selector, where it was ignored ([#113](https://github.com/vocaro/EPUBLib/issues/113)).
- Refuse a `mimetype` source with any byte after `application/epub+zip`, a trailing line end included, which the archive writer wrote into an invalid EPUB when it compared only the first 20 bytes ([#97](https://github.com/vocaro/EPUBLib/issues/97)).
- Have VoiceOver say the match, its place and the text after it when Next Match, Previous Match or a chosen search result shows it ([#49](https://github.com/vocaro/EPUBLib/issues/49)).
- Keep the toolbar's search popover open on iPad when a result is chosen in it, and close the search pane or result list only where it is a sheet ([#49](https://github.com/vocaro/EPUBLib/issues/49)).
- Keep the pages as they are laid out on iPhone and iPad while a keyboard is up, so a search no longer paginates the book again as the keyboard rises and falls ([#49](https://github.com/vocaro/EPUBLib/issues/49)).
- Show a search result about a third of the way down continuous scroll, with the text before it above, and not at the top ([#49](https://github.com/vocaro/EPUBLib/issues/49)).
- Lay out a right-to-left list item's first line from the same edge as its wrapped lines, with its marker hanging in the start-side indent, in page text and in table cells ([#276](https://github.com/vocaro/EPUBLib/issues/276)).
- Resolve `inline-start` and `inline-end` sides of margins, padding, borders, `float` and `clear` against the writing direction, and indent lists and `dd` on their start side, so right-to-left content is indented on the right ([#124](https://github.com/vocaro/EPUBLib/issues/124)).
- Keep VoiceOver on Mac at the line of a place shown in pages across a resize, a text size or the text built again that comes before anything moves from it, where it went back to the top of the page ([#594](https://github.com/vocaro/EPUBLib/issues/594)).
- Keep libxml2's messages about a book off the host's standard error, where text extraction still wrote them for a repeated or malformed `xml:id` and every path for bytes a declared encoding cannot decode, and give a host's own libxml2 handlers back after a package document is read ([#392](https://github.com/vocaro/EPUBLib/issues/392)).
- Start VoiceOver on Mac at the line of a place shown in pages, as a link's target, a search result or a bookmark, where it started at the top of the page ([#383](https://github.com/vocaro/EPUBLib/issues/383)).
- End the layout of a paragraph TextKit can set on no line once it has asked a thousand times for one of its lines, lay out the rest of the section as if that paragraph had one line more than it set, and disclose the text not shown ([#288](https://github.com/vocaro/EPUBLib/issues/288)).
- Have VoiceOver on Mac say "text" and not "empty" when a page turns with its cursor on a table of data's row element ([#485](https://github.com/vocaro/EPUBLib/issues/485)).
- Remove an SVG filter wherever the bundled renderer reads one, after `!important` or a `*` in CSS and in `xlink:filter` among them, in time linear in the CSS ([#253](https://github.com/vocaro/EPUBLib/issues/253)).
- Read an SVG's CSS by Unicode scalar, so a combining mark after a quote, backslash, comma or bracket hides nothing, and write an embedded font's own family name into it only when nothing in the name can be read as CSS ([#248](https://github.com/vocaro/EPUBLib/issues/248)).
- Keep VoiceOver in the text on Mac when a page turns with its cursor on a table row's element ([#485](https://github.com/vocaro/EPUBLib/issues/485)).
- Report a ZIP entry in a method other than stored or Deflate, or whose Deflate stream is damaged, as `EPUBPublicationError.invalidArchive`, whatever size it declares, instead of ZIPFoundation's own error ([#74](https://github.com/vocaro/EPUBLib/issues/74)).
- Turn the page for VoiceOver reading on by itself past a page's last line on iPhone and iPad, and stop at the book's end ([#468](https://github.com/vocaro/EPUBLib/issues/468)).
- Keep every line of a table cell narrower than its own indent on a page when its row is split across pages, drawn inside its column, in Copy and in what VoiceOver reads ([#569](https://github.com/vocaro/EPUBLib/issues/569)).
- Paginate a section whose inline blocks or floats are taller than a page in time linear in their length, with the same pages, where a play set as one inline block per scene took minutes of main-thread work ([#573](https://github.com/vocaro/EPUBLib/issues/573)).
- Measure every page as it is shown before committing its boundary, and fit the typography fallback to the line it makes, so no character of a section is left on no visible line ([#570](https://github.com/vocaro/EPUBLib/issues/570)).
- Read as script or style in text extraction's recovery only what the HTML Standard reads as one, so the text after `<script"q>` or a `<script>` in a title, a `textarea` or a comment is kept ([#255](https://github.com/vocaro/EPUBLib/issues/255)).
- Read the rest of a recovered section after an out-of-place `<html/>`, `<head/>` or `<body/>`, a second body included, instead of truncating or refusing it ([#292](https://github.com/vocaro/EPUBLib/issues/292)).
- Keep text after a forced break out of the floats beside it, and a box's lines there inside the box ([#362](https://github.com/vocaro/EPUBLib/issues/362)).
- Plan floats and positioned boxes against the lines the section lays out, so that a page below an indented paragraph with tabs, a caption under its table or an empty paragraph is not pushed off its foot ([#377](https://github.com/vocaro/EPUBLib/issues/377)).
- Render `::before` and `::after` content with quotes and counters, and disclose what of it is not shown ([#131](https://github.com/vocaro/EPUBLib/issues/131)).
- Let a book's `prefers-color-scheme` rules change only colours and filters, so a section's characters, positions, search matches and highlights stay the same across an appearance change ([#130](https://github.com/vocaro/EPUBLib/issues/130)).
- Open a book whose archive directory loses entries without them, and report them in `EPUBPublication.lostEntries` ([#261](https://github.com/vocaro/EPUBLib/issues/261)).
- Read a ZIP data descriptor's sizes by the form of its own bytes, so stored entries marked version 4.5 over 16-byte descriptors open ([#261](https://github.com/vocaro/EPUBLib/issues/261)).
- Follow manifest fallbacks for unsupported or scripted content and images while preserving resource identity ([#78](https://github.com/vocaro/EPUBLib/issues/78)).
- Keep floated and positioned inline text in its authored passage ([#127](https://github.com/vocaro/EPUBLib/issues/127)).
- Copy authored case and line feeds through typography substitutions and native selections ([#128](https://github.com/vocaro/EPUBLib/issues/128)).
- Size percentage images against their enclosing figure content box ([#148](https://github.com/vocaro/EPUBLib/issues/148)).
- Retain strict trailing body content and align recovery comment endings ([#197](https://github.com/vocaro/EPUBLib/issues/197)).
- Verify box paragraph hits and clearance against drawn lines using signed fragment origins ([#225](https://github.com/vocaro/EPUBLib/issues/225)).
- Preserve malformed numeric-reference text in extraction and native recovery ([#244](https://github.com/vocaro/EPUBLib/issues/244)).
- Show cross-document and legacy-anchor notes with consistent table content and navigation ordering ([#257](https://github.com/vocaro/EPUBLib/issues/257)).
- Memoize filtered sibling positions without silently dropping selectors beyond 1,000 siblings ([#262](https://github.com/vocaro/EPUBLib/issues/262)).
- Restore SVG foreign names before rendering sections recovered as HTML ([#317](https://github.com/vocaro/EPUBLib/issues/317)).

- Pass over an image or a rule that a book marks `aria-hidden` or with the role `presentation` or `none` for VoiceOver, and keep
  the image's words for Copy and search ([#408](https://github.com/vocaro/EPUBLib/issues/408)).
- Keep text that `visibility: hidden` hides in the flow out of what VoiceOver, Copy and search read, while it keeps its room ([#357](https://github.com/vocaro/EPUBLib/issues/357)).
- Keep combining marks following whitespace in extracted text and alternatives ([#89](https://github.com/vocaro/EPUBLib/issues/89)).
- Preserve every metadata language and identifier when writing a publication ([#95](https://github.com/vocaro/EPUBLib/issues/95)).
- Keep compatible XHTML public identifiers on the XML path with working CFIs ([#101](https://github.com/vocaro/EPUBLib/issues/101)).
- Preserve contextual collation matches and canonically equivalent Korean and Japanese search text ([#106](https://github.com/vocaro/EPUBLib/issues/106), [#107](https://github.com/vocaro/EPUBLib/issues/107)).
- Honour CSS units in SVG dimension attributes ([#117](https://github.com/vocaro/EPUBLib/issues/117)).
- Resolve wrapped SVG image percentages in viewBox coordinates and preserve the whole image ([#187](https://github.com/vocaro/EPUBLib/issues/187)).
- Keep trailing text and CDATA characters when a section is recovered as HTML ([#237](https://github.com/vocaro/EPUBLib/issues/237)).
- Read past harmless size declarations on archive directory entries ([#260](https://github.com/vocaro/EPUBLib/issues/260)).
- Bound SVG font-size values repeatedly resolved by relative lengths ([#443](https://github.com/vocaro/EPUBLib/issues/443)).
- Pack table continuations and following content using the displayed page bounds ([#546](https://github.com/vocaro/EPUBLib/issues/546)).
- Refuse entity declarations in supported legacy encodings before parsing ([#86](https://github.com/vocaro/EPUBLib/issues/86)).
- Resolve empty text anchors once when their next text or document end is known ([#92](https://github.com/vocaro/EPUBLib/issues/92)).
- Map search matches in long tables through indexed cell intervals ([#137](https://github.com/vocaro/EPUBLib/issues/137)).
- Keep the first visible line in view when paging back after a jump past figures ([#161](https://github.com/vocaro/EPUBLib/issues/161)).
- Bound XML and recovery parser work with a fixed limit of 1,024 attributes per element ([#196](https://github.com/vocaro/EPUBLib/issues/196)).
- Bound SVG arc, text-path and transformed embedded-image geometry before rendering ([#230](https://github.com/vocaro/EPUBLib/issues/230)).
- Charge nested SVG and symbol viewports and projected marker instances to the raster budget ([#251](https://github.com/vocaro/EPUBLib/issues/251)).
- Resolve hit tests and immediate scroll reports from the text drawn after an accessibility read ([#266](https://github.com/vocaro/EPUBLib/issues/266)).
- Fit nested tables without multiplying layout passes or text shrinkage ([#299](https://github.com/vocaro/EPUBLib/issues/299)).
- Measure every line of a table cell and use intrinsic attachment widths ([#300](https://github.com/vocaro/EPUBLib/issues/300)).
- Keep recursive table construction within the production task-thread stack ([#329](https://github.com/vocaro/EPUBLib/issues/329)).
- Admit subsequent-sibling selectors within a reserved memo budget without evicting retained searches ([#341](https://github.com/vocaro/EPUBLib/issues/341)).
- Refuse nested SVG style elements before reading their descendant stylesheet text ([#375](https://github.com/vocaro/EPUBLib/issues/375)).
- Use intrinsic rule and nested-table widths during table-cell measurement ([#138](https://github.com/vocaro/EPUBLib/issues/138)).
- Count symbol uses as isolated raster layers in the SVG preflight ([#541](https://github.com/vocaro/EPUBLib/issues/541)).

- Pass over a table row that has nothing to say as VoiceOver on Mac reads the text
  ([#509](https://github.com/vocaro/EPUBLib/issues/509)).
- Keep VoiceOver's rotor on the action chosen when the page under its cursor is shown again, in
  paging on iPhone and iPad ([#516](https://github.com/vocaro/EPUBLib/issues/516)).
- Keep VoiceOver on a link in a table when Find Next Link on Mac shows it some screens below, in a
  book opened part-way down ([#517](https://github.com/vocaro/EPUBLib/issues/517)).
- Say a picture's description at its cell when VoiceOver on Mac moves through a table of data
  ([#520](https://github.com/vocaro/EPUBLib/pull/520)).
- Call a table's header cell that is a link a link to VoiceOver on Mac
  ([#510](https://github.com/vocaro/EPUBLib/issues/510)).
- Keep VoiceOver's place when a page is shown by something other than VoiceOver, in paging on iPhone
  and iPad ([#428](https://github.com/vocaro/EPUBLib/issues/428)).
- Say what a table row holds when VoiceOver on Mac reads a row that has no words, where it said
  "Table row group" ([#512](https://github.com/vocaro/EPUBLib/pull/512)).
- Say a heading's level and words when VoiceOver on Mac moves to it from a link on the same page or
  screen ([#511](https://github.com/vocaro/EPUBLib/pull/511)).
- Call a table cell that is a link a link to VoiceOver on Mac, and follow it from the cell
  ([#502](https://github.com/vocaro/EPUBLib/issues/502)).
- Say a row's words as VoiceOver on Mac reads through a table that is not data
  ([#512](https://github.com/vocaro/EPUBLib/pull/512)).
- Keep VoiceOver with the reader when the text moves by something other than VoiceOver's own double
  tap, in continuous scroll on iPhone and iPad
  ([#428](https://github.com/vocaro/EPUBLib/issues/428)).
- Reach a link below the screen with VoiceOver's Find Next Link in continuous scroll on Mac, and
  read on from it ([#425](https://github.com/vocaro/EPUBLib/issues/425)).
- Select, follow a link or act with VoiceOver in a table's cell in continuous scroll wherever the
  reader has just gone, without scrolling first
  ([#472](https://github.com/vocaro/EPUBLib/issues/472)).
- Keep VoiceOver's rotor on Next Page or Previous Page on iPhone and iPad when the page turns into a
  table of data or out of one ([#477](https://github.com/vocaro/EPUBLib/pull/477)).
- Keep the place in continuous scroll on Mac when a resize of the window ends
  ([#479](https://github.com/vocaro/EPUBLib/pull/479)).
- Show a table's text selected from VoiceOver's rotor on iPhone and iPad, have VoiceOver say that it
  is selected, and let it copy the text or give it to the host
  ([#450](https://github.com/vocaro/EPUBLib/issues/450)).
- Move from a link to the book's next heading in paging with VoiceOver on Mac, and read on from the
  heading in both flows ([#454](https://github.com/vocaro/EPUBLib/issues/454)).
- Keep a scroll step that a VoiceOver listener on Mac makes straight after entering the text in
  continuous scroll ([#464](https://github.com/vocaro/EPUBLib/issues/464)).
- Read on back through the text after the scroll bar is adjusted with VoiceOver in continuous scroll
  on iPhone and iPad ([#342](https://github.com/vocaro/EPUBLib/issues/342)).
- Give VoiceOver a table of data as a table on Mac, and read a row's words as it reads the text
  ([#476](https://github.com/vocaro/EPUBLib/pull/476)).
- Turn page after page from a line with VoiceOver on iPhone and iPad by double taps alone, once Next
  Page or Previous Page is chosen in the rotor
  ([#466](https://github.com/vocaro/EPUBLib/issues/466)).
- Give VoiceOver a table of data cell by cell on iPhone and iPad, as Safari and Apple Books do
  ([#434](https://github.com/vocaro/EPUBLib/issues/434)).
- Send VoiceOver's cursor to the page shown when a page is turned under it on iPhone and iPad
  ([#466](https://github.com/vocaro/EPUBLib/issues/466)).
- Name the links in a table's cells for VoiceOver on Mac, reach one that is a hidden label, and find
  a cell's links from the page ([#424](https://github.com/vocaro/EPUBLib/issues/424)).
- Offer the page turn to VoiceOver on Mac where its cursor is, and bring VoiceOver to the first
  column after a turn made in the second ([#447](https://github.com/vocaro/EPUBLib/issues/447)).
- Go on from the scroll bar to what follows the reader, and back from it to the last line, when
  VoiceOver reads past the end of a book in continuous scroll on iPhone and iPad
  ([#342](https://github.com/vocaro/EPUBLib/issues/342)).
- Move to the next heading from a link with VoiceOver on Mac
  ([#431](https://github.com/vocaro/EPUBLib/issues/431)).
- Read what stands in a table cell to VoiceOver on Mac: a rule, a formula, a picture or a hidden
  label ([#444](https://github.com/vocaro/EPUBLib/issues/444)).
- Turn the page from VoiceOver's rotor on iPhone and iPad while text is selected
  ([#398](https://github.com/vocaro/EPUBLib/issues/398)).
- Read a table cell's line to VoiceOver on Mac when its cursor is at the end of the cell's text
  ([#459](https://github.com/vocaro/EPUBLib/pull/459)).
- Move by heading through the whole book in paging on Mac
  ([#397](https://github.com/vocaro/EPUBLib/issues/397)).
- Offer a line of the text its own actions and no others to VoiceOver on iPhone and iPad
  ([#398](https://github.com/vocaro/EPUBLib/issues/398)).
- Tell VoiceOver on Mac that a rule is a separator, where it said nothing
  ([#417](https://github.com/vocaro/EPUBLib/pull/417)).
- Read back up the screen when VoiceOver comes into continuous scroll from below on iPhone and iPad
  ([#367](https://github.com/vocaro/EPUBLib/issues/367)).
- Show an SVG's fallback text where the bundled renderer would copy or read again more of its shared
  and inherited values than a fixed ceiling allows
  ([#252](https://github.com/vocaro/EPUBLib/issues/252)).
- Read a table once to VoiceOver on iPhone and iPad, each row where it stands among the lines of its
  page ([#356](https://github.com/vocaro/EPUBLib/issues/356)).
- Read on past the screen in continuous scroll on iPhone and iPad when VoiceOver comes into the text
  straight after a menu closes ([#339](https://github.com/vocaro/EPUBLib/issues/339)).
- Name every link for VoiceOver on Mac, reach one that is a hidden label, and announce a link that
  is a picture or a hidden label as VoiceOver reads
  ([#406](https://github.com/vocaro/EPUBLib/issues/406)).
- Tell VoiceOver which lines of a book are headings, and let it move through the book by them
  ([#355](https://github.com/vocaro/EPUBLib/issues/355)).
- Tell VoiceOver that a rule is a separator on iPhone and iPad, where it was called an image
  ([#386](https://github.com/vocaro/EPUBLib/pull/386)).
- Match a subsequent-sibling selector (`~`) over a long run of siblings in work that grows with the
  run, not with its square ([#112](https://github.com/vocaro/EPUBLib/issues/112)).
- Pass over an image that a book marks as decoration, and stop calling an image without alternative
  text "Book image" ([#354](https://github.com/vocaro/EPUBLib/issues/354)).
- Finish laying out a section in which a tab has no stop to reach
  ([#227](https://github.com/vocaro/EPUBLib/issues/227)).
- Draw the paragraph after floats, positioned boxes or a sized inline block at the top of a page or
  section with each of its lines on a row of its own
  ([#146](https://github.com/vocaro/EPUBLib/issues/146)).
- Keep the control strip's page buttons and search field on screen with the keyboard up at larger
  text sizes on iPhone and iPad ([#330](https://github.com/vocaro/EPUBLib/issues/330)).
- Start VoiceOver at a page's first line when it comes back to a column after a page turn on Mac
  ([#337](https://github.com/vocaro/EPUBLib/issues/337),
  [#373](https://github.com/vocaro/EPUBLib/issues/373)).
- Keep the place in continuous scroll when a bar shows or hides over the reader
  ([#338](https://github.com/vocaro/EPUBLib/issues/338)).
- Hide a positioned label that a book parks off screen with an `em` or `rem` offset, as one parked
  with a pixel offset already was, and read every such label to VoiceOver
  ([#63](https://github.com/vocaro/EPUBLib/issues/63)).
- Open a footnote hidden from the page for a reference to any element inside it
  ([#177](https://github.com/vocaro/EPUBLib/issues/177)).
- Start VoiceOver at the first line on screen in continuous scroll on iPhone and iPad
  ([#301](https://github.com/vocaro/EPUBLib/issues/301)).
- Keep the place in continuous scroll on a Mac through the scroll view's first display
  ([#302](https://github.com/vocaro/EPUBLib/issues/302)).
- Keep a full-page dedication or epigraph where it is shown in continuous scroll on Mac when the
  window's height changes and its width does not
  ([#313](https://github.com/vocaro/EPUBLib/issues/313)).
- Keep the rest of a section in text extraction's recovery when an early `</body>` or `</html>` runs
  into a script's or style's end tag, or stands at the start of a script or style
  ([#235](https://github.com/vocaro/EPUBLib/issues/235)).
- Keep the search pane's field and Close Search on screen at larger text sizes in an iPad's popover
  and on a small iPhone held upright ([#310](https://github.com/vocaro/EPUBLib/issues/310)).
- Build a section of nested tables without laying each table out again for every table around it
  ([#271](https://github.com/vocaro/EPUBLib/issues/271)).
- Report the line resting at the top of the reading area as the place in continuous scroll in a book
  that has a float or positioned box anywhere
  ([#305](https://github.com/vocaro/EPUBLib/issues/305)).
- Show the fallback text of an SVG whose references the bundled renderer cannot survive, where such
  a drawing ended or stalled the reader ([#229](https://github.com/vocaro/EPUBLib/issues/229)).
- Set a run of sized inline blocks side by side
  ([#147](https://github.com/vocaro/EPUBLib/issues/147)).
- Keep prose clear of floats, positioned boxes and inline blocks far into a book in continuous
  scroll ([#147](https://github.com/vocaro/EPUBLib/issues/147)).
- Keep the search pane's field and Close Search on screen at larger text sizes with the iPhone on
  its side ([#291](https://github.com/vocaro/EPUBLib/issues/291)).
- Show a full-page dedication, epigraph or title page as composed in continuous scroll from any
  position inside it ([#297](https://github.com/vocaro/EPUBLib/pull/297)).
- Keep paragraph margins, centring, right alignment and justification in a book that has a float, a
  positioned box or a sized inline block anywhere
  ([#63](https://github.com/vocaro/EPUBLib/issues/63),
  [#150](https://github.com/vocaro/EPUBLib/issues/150)).
- Start VoiceOver at the first line on screen in continuous scroll on Mac
  ([#296](https://github.com/vocaro/EPUBLib/pull/296)).
- Read a book's title, authors, languages and identifiers, and its contents, landmark, page-list and
  NCX labels, as one line of text ([#75](https://github.com/vocaro/EPUBLib/issues/75)).
- Keep opening a book that other bytes follow, however many, when they hold no ZIP end record's
  signature: a page a download was wrapped in, but not a second archive, whose end record is the one
  read ([#219](https://github.com/vocaro/EPUBLib/issues/219)).
- Show an SVG's fallback text, with the `svg` disclosure, where its text or markers would cost the
  bundled renderer far more than the file's size
  ([#170](https://github.com/vocaro/EPUBLib/issues/170)).
- Keep what a table holds outside the shapes its grid supports
  ([#139](https://github.com/vocaro/EPUBLib/issues/139)).
- Keep the place in continuous scroll after an assistive technology has read the book
  ([#263](https://github.com/vocaro/EPUBLib/pull/263)).
- State a refused search once ([#49](https://github.com/vocaro/EPUBLib/issues/49)).
- Keep the search pane's field where it is on iPhone
  ([#51](https://github.com/vocaro/EPUBLib/issues/51)).
- Escape `&`, `<`, `>` and quotes in the package and navigation documents the writer produces when a
  combining mark, variation selector or joiner follows them
  ([#203](https://github.com/vocaro/EPUBLib/issues/203)).
- Show a section that is not well-formed XML in its own characters and with all of its paragraphs
  ([#201](https://github.com/vocaro/EPUBLib/issues/201)).
- Write a resource whose file name begins with a combining mark, and find a font or style sheet
  whose reference has a `#` or `?` with such a mark after it
  ([#181](https://github.com/vocaro/EPUBLib/issues/181)).
- Release a file that is refused because its ZIP end record is cut short
  ([#217](https://github.com/vocaro/EPUBLib/issues/217)).
- Keep each occurrence of a repeated spine item's own position
  ([#108](https://github.com/vocaro/EPUBLib/issues/108)).
- Page through a book in which no spine item is linear
  ([#159](https://github.com/vocaro/EPUBLib/issues/159)).
- Report progression in a book in which no spine item is linear
  ([#232](https://github.com/vocaro/EPUBLib/issues/232)).
- Stop taking the language of a content document that declares none from the package's `dc:language`
  for generated text ([#109](https://github.com/vocaro/EPUBLib/issues/109)).
- Text extraction's recovery keeps text it used to lose: after a `<` that opens no tag (including
  before `_` and `:`), after an early `</body>` or `</html>`, and around a NUL character
  ([#93](https://github.com/vocaro/EPUBLib/issues/93),
  [#198](https://github.com/vocaro/EPUBLib/issues/198)).
- Lay out a section of many inset positioned boxes in time that grows with the square of their
  count, not the cube ([#180](https://github.com/vocaro/EPUBLib/issues/180)).
- Pin MathMLLayout 0.1.1, whose license file names Vocaro Technologies LLC as its third-party notice
  does ([#69](https://github.com/vocaro/EPUBLib/issues/69)).
- Open books with faults that used to refuse them
  ([#84](https://github.com/vocaro/EPUBLib/issues/84),
  [#171](https://github.com/vocaro/EPUBLib/issues/171)).
- Refuse a file that is not a ZIP archive at once instead of after about a fifth of a second per
  mebibyte ([#194](https://github.com/vocaro/EPUBLib/issues/194)).
- Keep the text after an unescaped `<` in a section the HTML parser reads
  ([#103](https://github.com/vocaro/EPUBLib/issues/103)).
- Read an archive entry's name as UTF-8 when its bytes are UTF-8, whether or not the ZIP
  language-encoding flag is set ([#73](https://github.com/vocaro/EPUBLib/issues/73)).
- Refuse a book whose ZIP directory declares a stored entry larger than the archive could hold,
  before anything is read ([#175](https://github.com/vocaro/EPUBLib/issues/175)).
- Open ZIP64 archives whose extra fields hold a zero: the first entry's header offset, which crashed
  opening, and an empty entry's sizes, which refused the book as over its limits
  ([#72](https://github.com/vocaro/EPUBLib/issues/72)).
- Draw a page that opens just below a float, absolute box or sized inline-block as wide as its
  column ([#145](https://github.com/vocaro/EPUBLib/issues/145)).
- Place each float or positioned box below the boxes before it in one sorted pass instead of
  rescanning them after every collision ([#155](https://github.com/vocaro/EPUBLib/issues/155)).
- Decode a percent-encoded container rootfile path
  ([#81](https://github.com/vocaro/EPUBLib/issues/81)).
- Draw the image of a single-image SVG wrapper filling its box when the `viewBox` is so small, or so
  far from the image, that the box would show less than a pixel of it
  ([#135](https://github.com/vocaro/EPUBLib/issues/135)).
- Refuse an EPUB whose ZIP end record, directory record or data descriptor points past the end of
  the archive with `EPUBPublicationError.invalidArchive`, including offsets and sizes held in ZIP64
  fields ([#71](https://github.com/vocaro/EPUBLib/issues/71)).
- Show sections whose text has an unescaped `<` followed later by an apostrophe or quotation mark,
  such as `if x < y then it's done` or a style sheet's `content: "<"`
  ([#87](https://github.com/vocaro/EPUBLib/issues/87)).
- Show the whole book in continuous scroll again after a text size or appearance is changed and
  changed back before its rebuild finished ([#156](https://github.com/vocaro/EPUBLib/issues/156)).
- Show a footnote whose reference names the paragraph inside it
  ([#126](https://github.com/vocaro/EPUBLib/issues/126)).
- Read an XHTML element named only with colons (`<:/>`) in text extraction instead of trapping
  ([#88](https://github.com/vocaro/EPUBLib/issues/88)).
- Show the inline search field's queued line only for a queued search
  ([#28](https://github.com/vocaro/EPUBLib/issues/28)).
- Leave focus alone when the control strip's inline search field appears
  ([#28](https://github.com/vocaro/EPUBLib/issues/28)).
- Give VoiceOver an iPad spread's columns in source order
  ([#28](https://github.com/vocaro/EPUBLib/issues/28)).
- Break MathML formulas wider than their line into full-size rows at relations, operators and
  authored `linebreak`s instead of shrinking them below three quarters of the text's size
  ([#25](https://github.com/vocaro/EPUBLib/issues/25)).
- Honor flex and grid alignment that keeps the reading column, in paginated and continuous-scroll
  flow ([#20](https://github.com/vocaro/EPUBLib/issues/20)).
- Repaint the text on screen whenever search or host highlights change
  ([#51](https://github.com/vocaro/EPUBLib/issues/51)).
- Name the Mac reading-mode segments Continuous Scroll and Paging for assistive technology, in place
  of their symbols' descriptions ([#51](https://github.com/vocaro/EPUBLib/issues/51)).
- Resolve ordinary paragraph percentage margins, padding and indents at the live containing width,
  retaining source positions across resizing ([#21](https://github.com/vocaro/EPUBLib/issues/21)).
- Preserve locale-tailored base-strength search distinctions, including Turkish I, Swedish letters,
  Spanish ñ and Cyrillic й, for passage location and search highlighting
  ([#26](https://github.com/vocaro/EPUBLib/issues/26)).
- Describe enabled keyboard and gesture inputs in page-button help, with host customization and
  flow-aware labels ([#50](https://github.com/vocaro/EPUBLib/issues/50)).
- Preserve SVG diagram shapes and labels when unsupported filter effects are omitted with a
  disclosure, including the networking book's TCP/IP layers
  ([#53](https://github.com/vocaro/EPUBLib/issues/53)).
- Keep labelled SVG figures mounted when a reader is resized and its text size or appearance
  changes, as a cold open at that size and style shows them
  ([#54](https://github.com/vocaro/EPUBLib/issues/54)).
- Add search results to the native reader: `EPUBSearchResults` lists every rendered match, and
  `.nextSearchResult`, `.previousSearchResult` and `.showSearchResult` move between them in both
  flows ([#49](https://github.com/vocaro/EPUBLib/issues/49)).
- Tell Mac VoiceOver which columns changed when a page is installed, so it reads the new page from
  its first line instead of repeating the previous page
  ([#55](https://github.com/vocaro/EPUBLib/issues/55)).
- Bound paginated Mac accessibility text and line queries to the visible source range
  ([#28](https://github.com/vocaro/EPUBLib/issues/28)).
- Preserve Foliate CFIs for qualified XML-shaped HTML, including whitespace around the head/body
  ([#27](https://github.com/vocaro/EPUBLib/issues/27)).
- Measure long justified continuation tails with the exact bounded displayed slice
  ([#30](https://github.com/vocaro/EPUBLib/issues/30)).
- Keep continuous-scroll section jumps on the requested passage after distant diagram visits
  ([#41](https://github.com/vocaro/EPUBLib/issues/41)).
- Wrap continuous-scroll Mac prose within the actual native scroll viewport, including space
  occupied by legacy scrollbars ([#47](https://github.com/vocaro/EPUBLib/issues/47)).
- Preserve authored MathML alternatives in headless extraction, or serialize fractions, powers,
  indices, roots and fences with explicit structure
  ([#44](https://github.com/vocaro/EPUBLib/issues/44)).
- Support XHTML named character references without loading DTDs, and add opt-in HTML recovery for
  malformed content with a `recoveredAsHTML` result flag
  ([#43](https://github.com/vocaro/EPUBLib/issues/43)).
- Make native table cell text selectable with precise CFIs, Copy, host selection actions, saved
  highlights and internal, note and external-link handling, including continued rows
  ([#23](https://github.com/vocaro/EPUBLib/issues/23)).
- Coordinate native selections across both columns in either reading direction
  ([#29](https://github.com/vocaro/EPUBLib/issues/29)).
- Render static SVG illustrations with bundled resvg on Mac, iPhone and iPad, including paths, text,
  transforms, gradients and clipping ([#22](https://github.com/vocaro/EPUBLib/issues/22)).
- Keep sample page arrows pinned at the trailing edge on iPhone/iPad instead of moving into overflow
  ([#46](https://github.com/vocaro/EPUBLib/pull/46)).
- Preserve authored nonempty XHTML image alternatives in headless text extraction, including formula
  images, truth-table headings and exercise items
  ([#37](https://github.com/vocaro/EPUBLib/issues/37)).
- Keep transparent dark diagram strokes readable in dark appearance with a faithful white backdrop
  ([#34](https://github.com/vocaro/EPUBLib/issues/34)).
- Add native image inspection with zoom, pan, fit and close controls on Mac, iPhone and iPad,
  including table images and page-image fallbacks
  ([#35](https://github.com/vocaro/EPUBLib/issues/35)).
- Default reader appearance to System, following live host/OS color scheme changes
  ([#46](https://github.com/vocaro/EPUBLib/pull/46)).
- Move Continuous Scroll/Paging into a separate `.readingMode` control group with joined mode
  buttons using `scroll` and `doc.text` symbols ([#46](https://github.com/vocaro/EPUBLib/pull/46)).
- Add `.search(text:)` and the `.search` capability for highlighting matches and opening the first
  rendered match ([#46](https://github.com/vocaro/EPUBLib/pull/46)).
- Continue oversized native table rows and rowspan text across pages without clipping glyph lines;
  preserve source offsets and read each continued word once
  ([#24](https://github.com/vocaro/EPUBLib/issues/24)).
- Wrap native prose around left/right floats, including auto-width drop caps and archive images;
  honor float clearing, positioned callout insets and sized inline-blocks beside surrounding text
  ([#19](https://github.com/vocaro/EPUBLib/issues/19)).
- Add optional `EPUBLocation.rangeBookmarks` to preserve every section of a saved selection or
  highlight while retaining existing single-section bookmarks
  ([#31](https://github.com/vocaro/EPUBLib/issues/31)).
- Add live `View.epubReaderPageControls(_:)` configuration for native page input: independent
  gesture toggles, physical edge widths and replacement keyboard bindings, with `.hostOnly` for host
  controls ([#32](https://github.com/vocaro/EPUBLib/issues/32)).
- Add optional `EPUBReaderToolbar`, `EPUBReaderControlStrip` and individually composable control
  groups, backed by a retained `EPUBReaderControls` model
  ([#33](https://github.com/vocaro/EPUBLib/issues/33)).
- Add `EPUBSearchState` and `.searchChanged` events for search pending, completion/no-match,
  validation failures and clearing ([#33](https://github.com/vocaro/EPUBLib/issues/33)).
- Replace the bundled foliate-js WebKit renderer with a native TextKit 2 viewer
  ([#3](https://github.com/vocaro/EPUBLib/issues/3)).
- `EPUBReader` has its own engine identifier, `org.epublib.reader`, and bookmark format,
  `epublib-cfi-v1`, as `EPUBReader.identifier` and the new `EPUBReader.bookmarkFormat`
  ([#6](https://github.com/vocaro/EPUBLib/pull/6)).
- Continuous scroll is one real scroll view over the whole book, running under the bars with the
  system scroll edge effects; the drawn edge fades are gone and nothing resets at a section boundary
  ([vocaro/studywright#379](https://github.com/vocaro/studywright/issues/379),
  [vocaro/studywright#73](https://github.com/vocaro/studywright/issues/73)).
- Page turns use one or two columns by the page's own size, and `View.epubReaderDivision(_:)` puts a
  two-column spread's gutter on a host-reserved fold
  ([vocaro/studywright#278](https://github.com/vocaro/studywright/issues/278)).
- Add `EPUBReaderCommand.setHighlights`, `EPUBHighlight` and the `highlights` capability, drawing
  host highlights while reading
  ([vocaro/studywright#85](https://github.com/vocaro/studywright/issues/85)).
- Render tables, images, footnote popovers and MathML natively, MathML through the new
  [MathMLLayout](https://github.com/vocaro/MathMLLayout) package
  ([#9](https://github.com/vocaro/EPUBLib/pull/9)).
- `EPUBPublication.pageProgression` exposes the spine's `page-progression-direction`
  ([#3](https://github.com/vocaro/EPUBLib/issues/3)).
- With nothing restored, the reader opens a book at its text start, as foliate-js's `showTextStart`
  did: the first `bodymatter` landmark (or EPUB 2 guide `text` reference), else the first linear
  section ([#10](https://github.com/vocaro/EPUBLib/pull/10)).
- `EPUBPublication.landmarks` lists the navigation document's landmarks, or the OPF guide's
  references in a book without them, as `EPUBLandmark` values
  ([#10](https://github.com/vocaro/EPUBLib/pull/10)).
- Read the navigation document's `epub:type` by its namespace, so a plain `type` on the same `<nav>`
  or landmark link no longer replaces it, which could empty the contents or mislabel a landmark
  ([#11](https://github.com/vocaro/EPUBLib/issues/11)).
- Read print and source page equivalents, and report the pages on screen
  ([#17](https://github.com/vocaro/EPUBLib/issues/17)).
- Open EPUBs that other converters write with three faults instead of refusing them: a repeated
  manifest item, an item whose file the archive lacks and a C0 control character in an XML document
  ([#16](https://github.com/vocaro/EPUBLib/pull/16)).
- Remove foliate-js, zip.js, the bootstrap page, scheme handler, URL patch, JavaScript bridge and
  vendor identity check ([#3](https://github.com/vocaro/EPUBLib/issues/3)).

## 0.2.5 — 2026-09-20

- Turn a scrolled-flow section on a swipe's whole travel, judged on every `touchmove` and once more
  at `touchend`, and listen on the host document as well as the section's
  ([vocaro/studywright#74](https://github.com/vocaro/studywright/issues/74)).
- Add an iOS regression that flicks with no `touchmove` at all, dispatched on the host page.
- Public APIs, dependencies and bookmark formats are unchanged.

## 0.2.4 — 2026-09-16

- Stop drawing the continuous-scroll edge fade on macOS, where the host has no chrome floating over
  the page ([vocaro/studywright#155](https://github.com/vocaro/studywright/issues/155)).
- Public APIs, dependencies and bookmark formats are unchanged.

## 0.2.3 — 2026-09-15

- Use adaptive CSS system colors for the Foliate dark-mode fallback.
- Preserve live iOS toolbar clearance and avoid redundant scroll-inset updates.
- Public APIs, dependencies and bookmark formats are unchanged.

## 0.2.2 — 2026-09-15

- Fix missing tables of contents when navigation role tokens use tabs or line breaks
  ([#1](https://github.com/vocaro/EPUBReaderLib/issues/1)).
- Accept harmless XML declaration examples in comments, CDATA and processing instructions while
  continuing to reject real entity declarations and internal DTD subsets
  ([#2](https://github.com/vocaro/EPUBReaderLib/issues/2)).
- Add eight parsing regressions, including Unicode encodings and quoted external identifiers.
- Public APIs, dependencies, rendering engines and bookmark formats are unchanged.

## 0.2.1 — 2026-09-15

- Exclude script/style/template text inside embedded foreign content such as SVG, while preserving
  diagram labels.
- Add a regression for embedded SVG text extraction. Public API signatures are unchanged.

## 0.2.0 — 2026-09-15

- Public `EPUBTextSection` and `EPUBPublication.textSection(at:limits:)` API for renderer-free XHTML
  extraction.
- Chapter/resource identity, titles, linearity and namespace-aware EPUB semantic labels.
- Structural whitespace, entity/CDATA decoding and lossless word-joiner handling.
- Explicit malformed-content/media/index failures, per-section limits and cancellation.
- Ported extraction regressions and new policy-neutral, namespace, Unicode and limit tests.

## 0.1.0 — 2026-09-14

- Initial tagged release of the publication parser, pluggable reader API and bundled Foliate
  adapter.
- iOS/iPadOS 27 and macOS 27 minimum deployment targets.
- Encoded resource hrefs and navigation/position round trips for reserved filename characters.
- Per-section layout metadata; fixed-layout sessions omit unsupported typography and scrolling.
- Synchronous import progress callbacks and cooperative cancellation during expansion.
- Parser safety regressions and exact IDPF/Adobe font obfuscation tests.
- Shared engine-contract test product with native and Foliate adapter checks.
- Mac, iPhone and iPad rendering coverage, including fixed layout, RTL, vertical writing and images.
- Runnable SwiftUI sample, checked documentation examples and release compatibility policy.

See the [release notes](https://github.com/vocaro/EPUBLib/releases/tag/0.1.0) for the OS builds and
test results.
