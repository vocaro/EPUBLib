# Release notes

## Unreleased

- Refuse a test engine that never sends what the contract verifier waits for once the engine says it is idle, not when a limit runs out, so that the gate measures `EngineContractTests` and `ControlsCoverageContractTests` under memory pressure, where every such check was unmeasured ([#859](https://github.com/vocaro/EPUBLib/issues/859)).
- Ship the license and notice texts of EPUBLib, ZIPFoundation, the foliate-js port, MathMLLayout with MathCAT and the Speech Rule Engine, and StaticSVG with resvg, its crates and the Rust standard library in EPUBCore's resource bundle, which `EPUBLicense.all()` lists for a host's acknowledgments, where an app had to copy them out of the repository by hand ([#699](https://github.com/vocaro/EPUBLib/issues/699)).
- Pin StaticSVG 0.1.3, which lays out an `<image>` that gives no size at its drawing's or large bitmap's own size, keeps an `href` whose `#` a combining mark follows as a fragment, follows no `xlink:href` that an unusable `href` overrides, links a drawing's class rules by their bytes, walks masks and clip paths in document order, pins the copy screen's cache keying and no longer refuses a marker drawing for a clamped corner radius or an `@font-face` rule ([#704](https://github.com/vocaro/EPUBLib/issues/704), [#862](https://github.com/vocaro/EPUBLib/issues/862), [#641](https://github.com/vocaro/EPUBLib/issues/641), [#316](https://github.com/vocaro/EPUBLib/issues/316), [#752](https://github.com/vocaro/EPUBLib/issues/752), [#661](https://github.com/vocaro/EPUBLib/issues/661), [#415](https://github.com/vocaro/EPUBLib/issues/415), [#274](https://github.com/vocaro/EPUBLib/issues/274)).
- Move by paragraph, picture, table, list item and heading through the book with a Paragraphs rotor beside Headings on iPhone and iPad, in pages and in continuous scroll, where a flick moved one line and a paragraph of eight lines took eight ([#711](https://github.com/vocaro/EPUBLib/issues/711)).
- Give libxml2's HTML parser `<!>` in place of a text NUL that, left out, would join the bytes beside it into `?>`, `-->`, `--!>` or `]]>` when a section falls back to it, which libxml2 reads as nothing, so that leaving the NUL out cannot end a processing instruction, or a comment or CDATA opened in a style sheet, sooner than the screen read it and bring what it passed over into view, where `<?pi > ?`, a NUL and `> <!ENTITY e "x"> ?>` passed the screen and reached the parser with an earlier `?>` ([#733](https://github.com/vocaro/EPUBLib/issues/733)).
- Keep the bytes beside recovered CDATA apart with `<!>` where writing the section as its text would join them into an end the screen reads, a DOCTYPE's `>` and a `[`, or a stray `<` and what follows it, and screen as UTF-8 the bytes the HTML fallback reads as they are under an XML declaration that the screen read them through, in EBCDIC as IBM037 or naming UTF-16 in ASCII, where `<!DOCTYPE html><![CDATA[]]>[…]>` and an ASCII internal subset after an EBCDIC declaration passed the screen and reached the parser ([#743](https://github.com/vocaro/EPUBLib/issues/743)).
- Choose the placeholder for a stray `<` in the HTML fallback among the noncharacters the parser cannot read in the section, also once its NULs are left out and where libxml2 would assemble one from bytes that are not UTF-8, and read a section whose placeholders would take it past the byte limit with its signs as they are, where U+FDD0 so assembled or written as `&`, a NUL and `#xFDD0;` was shown as `<` and such a section was refused ([#211](https://github.com/vocaro/EPUBLib/issues/211)).
- Decode a section that text extraction recovers by the encoding its XML declaration names, with the reader's fallback's own code, as the strict path and the reader do, where an ISO-8859-1 section with an unclosed tag was refused and UTF-8 bytes declared as `windows-1252` read as UTF-8 only when recovered ([#247](https://github.com/vocaro/EPUBLib/issues/247)).
- Say why each `.relocated` was sent in `EPUBReaderStatus.relocationReason`, set before the event: a turn, the person's scrolling, a place gone to, a place restored, the place the book opens at or the same place laid out again, so that a host that saves the place as the person reads can tell a move from a relayout ([#600](https://github.com/vocaro/EPUBLib/issues/600)).
- Scroll the text of a page turn in continuous scroll where the host chose a page-turn animation with `epubReaderPageTurnAnimation(_:)`, for a key, Scroll Forward and Scroll Backward or the host's `.nextPage` and `.previousPage`, in place of a jump, with the place it lands reported at once and a step made at once under Reduce Motion, while VoiceOver is running and for an assistive technology's own scroll ([#622](https://github.com/vocaro/EPUBLib/issues/622)).
- Style a block's first letter by its `::first-letter` rules, in line or floated as a drop cap beside the lines it spans, and disclose a `::first-line` rule that matches a block shown, where both were dropped without a word ([#567](https://github.com/vocaro/EPUBLib/issues/567)).
- Let a label or a line of search feedback too long for its line in the control strip take a second on iPhone and iPad, where on an upright iPhone SE at the largest text size Appearance read "Appearan…" and each was cut short on one line ([#365](https://github.com/vocaro/EPUBLib/issues/365)).
- Have VoiceOver say the match that `submitSearch()` opens once it is shown, "Match 1 of 14, first match, Before the road: lantern hangs at the gate.", as it says a step or a chosen result, where a search said nothing ([#601](https://github.com/vocaro/EPUBLib/issues/601)).
- Leave a list item's generated marker out of a search result's context in a table cell, as in prose, with a transformed case read as the book spells it and, in a cell or prose, the item's first word kept after a marker longer than the context, where the context before a match in a list in a cell began with its bullet or number ([#735](https://github.com/vocaro/EPUBLib/issues/735)).
- Offer the reader's commands in the menu bar of a Mac and an iPad with the new `EPUBReaderMenuCommands` and `epubReaderMenuCommands(_:)`, acting on the reader of the window in front and dimmed where they cannot run: Find, Find Next and Find Previous on Command-F, Command-G and Shift-Command-G, the text size on Command-+, Command-- and Command-0, the appearances, Continuous Scroll and Paging on Command-1 and Command-2, the page turns and the book's start and end on Page Up, Page Down, Home and End, and the contents, where nothing reached the menu bar ([#697](https://github.com/vocaro/EPUBLib/issues/697)).
- Hold the gate's waits and settling pauses against the time the test process could run, report a test or simulator boot that a busy host decided as unmeasured with exit 3, and admit the gate as heavy work with bounded build workers ([#859](https://github.com/vocaro/EPUBLib/issues/859)).
- Leave `epub:type` terms on the head and what it holds, on metadata content such as `script`, `template` and `noscript`, in what a script, style or template holds, and on an SVG element that is not rendered, such as `title`, `desc` and `defs`, out of a section's extracted `semanticTypes`, as the reader ignores them ([#777](https://github.com/vocaro/EPUBLib/issues/777)).
- Check a recovered section's DOCTYPEs in one pass in text extraction, where four mebibytes of DOCTYPE openers in an unclosed comment were read again from each opener and took tens of minutes ([#783](https://github.com/vocaro/EPUBLib/issues/783)).
- Scan a recovered section once more with its abrupt comments left open where closing one leads the declaration check to refuse it, as one that leads the scan to refuse it already was, so that `< <!--> <!DO<![CDATA[]]>CTYPE html [` is read as before the comments were closed ([#333](https://github.com/vocaro/EPUBLib/issues/333)).
- Say in the text-extraction document that recovery withholds a section with no body, a quoted attribute value that never ends or a CDATA section that never ends as an accepted loss, as the reader withholds a section cut off inside markup, though it read some such sections before #226 ([#256](https://github.com/vocaro/EPUBLib/issues/256)).
- Say in the native viewer document that VoiceOver's move by heading from a link on Mac goes to the book's next heading in both flows, on a later page in paging, and that from a link after the book's last heading it begins again, which is VoiceOver's own on macOS 27.0.1, where its limits still said the move stayed on the page in paging ([#454](https://github.com/vocaro/EPUBLib/issues/454)).
- Accept a navigation or stylesheet target in the package writer by the path it resolves to, however it is spelled, so that `x/../EPUB/one.xhtml` and `%45PUB/one.xhtml` are written `one.xhtml` as `EPUB/../EPUB/one.xhtml` was, where the writer refused them ([#606](https://github.com/vocaro/EPUBLib/issues/606)).
- Write a carriage return in text as `&#13;`, and a tab, line feed and carriage return in an attribute value as `&#9;`, `&#10;` and `&#13;`, in the package and navigation documents, as Canonical XML writes them, so that each reads back as given, where a parser read a carriage return as a line feed and a media type's tab or line end as a space ([#254](https://github.com/vocaro/EPUBLib/issues/254)).
- Hide a positioned label parked at `top` or `left` of -999 CSS pixels in absolute units, as skip links and visually hidden labels are, and keep it for VoiceOver, where the off-screen rule began at -1,000 and drew it, leaving `-62.5em` the line for an offset in `em` or `rem` ([#358](https://github.com/vocaro/EPUBLib/issues/358)).
- Widen a sized inline block or an absolutely positioned box narrower than its longest word to that word, as far as its containing block allows, as a float is widened, where the word was broken between characters ([#742](https://github.com/vocaro/EPUBLib/issues/742)).
- Set the rest of an inline block too tall for a page at the box's own edge and no wider than the column, and keep any sized inline block's margins inside its block's line, where the rest started at the indent of its first verse line and ran past the column's edge ([#720](https://github.com/vocaro/EPUBLib/issues/720)).
- Read the Dublin Core elements inside `dc-metadata` in OEBPS 1.2's capitals, such as `dc:Title`, leave U+FEFF out of every metadata value and navigation label wherever the parser splits the text, and read a `br` in a label as a space, where such a package had no title, authors, languages or unique identifier, a value kept or lost the character by how it was written, and the words either side of a line break ran together ([#608](https://github.com/vocaro/EPUBLib/issues/608), [#283](https://github.com/vocaro/EPUBLib/issues/283)).
- Set a tab on the next multiple of its interval from the paragraph's edge, in either direction and with or without a float or positioned box in the section, where with a box it landed an indent further along, and right to left it was off by the difference between the paragraph's two indents ([#334](https://github.com/vocaro/EPUBLib/issues/334)).
- Take an element whose name Namespaces in XML forbids in the container, package, navigation and NCX documents for an unknown element, as libxml2 does, without refusing the book, where `<:navPoint>` was read as a navigation point, `<a:b:rootfile>` as a rootfile and an attribute `:epub:type` as `epub:type` ([#644](https://github.com/vocaro/EPUBLib/issues/644)).
- Rest the line kept in continuous scroll at the top when a bar is shown or hidden over the reader in a book with no box to resolve, as in one with boxes, where on iPhone and iPad a line shown stood 53.8 points below the top of the reading area from the first change of the bar on ([#370](https://github.com/vocaro/EPUBLib/issues/370)).
- Leave the words and pictures a book keeps from assistive technology out of what VoiceOver reads of a table cell, on iPhone and iPad in a cell's element, a row's line and its actions and on Mac in what a row is called and a cell's selected text, while a selection and a copy of the row keep them ([#551](https://github.com/vocaro/EPUBLib/issues/551))
- Name the language of a picture's words to VoiceOver, that of its `img`, `object`, `embed` or `svg` element, so that a heading or a cell whose picture's words outweigh its own is read in their language ([#548](https://github.com/vocaro/EPUBLib/issues/548))
- Apply the stylesheets an `xml-stylesheet` processing instruction associates, only the preferred set of titled stylesheets and no disabled link, and keep exactly the selectors, at-rules, `@import` and `@namespace` rules Chromium keeps ([#115](https://github.com/vocaro/EPUBLib/issues/115), [#116](https://github.com/vocaro/EPUBLib/issues/116), [#603](https://github.com/vocaro/EPUBLib/issues/603))
- Ignore a `list-style`, `content`, `filter` or `font-variant` declaration with a function the reader does not know, such as a gradient prefixed for another engine, or with arguments its function does not take, so that the declaration before it stays, as for `background`, where `list-style` and `content` took any function whose name ended in `gradient` and `filter` and `font-variant` took any function ([#643](https://github.com/vocaro/EPUBLib/issues/643)).
- Evaluate a math function in a media feature's value, and a length in any unit against the initial font and the nominal viewport, where `(min-width: calc(100px + 1em))`, `(resolution: calc(6x / 2))`, `(min-width: 10vw)`, `(max-width: 40ex)` and `(min-width: 30ch)` matched nothing, and neither did their negations ([#756](https://github.com/vocaro/EPUBLib/issues/756)).
- Take a math function in a color's channels, hue and alpha, such as `rgb(calc(255 / 2) 0 0)`, `hsl(calc(120 + 60) 50% 50%)` and `rgb(calc(50%) 0 0)`, with angles and resolutions in `calc()`, where such a color was dropped ([#760](https://github.com/vocaro/EPUBLib/issues/760)).
- Read CSS `tab-size`, a number of spaces or a length, as the interval of a block's tabs, and give a hidden label's own paragraph its box's interval, where a kept tab always advanced by eight spaces ([#378](https://github.com/vocaro/EPUBLib/issues/378)).
- Read a table cell's `colspan` and `rowspan`, a column's `span` and a table's `border` by HTML's rules for parsing non-negative integers, which skip white space and a `+` and read the digits up to whatever follows them, with HTML's bounds of 1,000 for a column span and 65,534 for a row span, where `colspan=" 2"`, `"2px"` or `"2.9"` spanned one column, a span too long for an integer was 1 and `<table border=" 0">` ruled its cells ([#143](https://github.com/vocaro/EPUBLib/issues/143)).
- Disclose a table whose grid has no slot for some of its cells only when one of those cells shows something after the table, and say so in a sentence true of one cell or many, "Part of one table is shown after it, out of place.", where `<td colspan="300"></td>` before two other cells raised the notice with nothing shown ([#272](https://github.com/vocaro/EPUBLib/issues/272)).
- Take a table's, its rows' and its cells' backgrounds, borders, padding, spacing and wrapping, a caption's side, and an image's or an SVG drawing's size from the cascade alone, in which `bgcolor`, `border`, `cellpadding`, `cellspacing`, `nowrap`, a caption's `align="bottom"`, `width` and `height` are presentational hints that any author rule beats, so that a rule setting the default, such as `td { background: none }`, `td { padding: 0 }`, `table { border-spacing: 2px }` or `img { width: auto }`, wins where it lost to the attribute ([#763](https://github.com/vocaro/EPUBLib/issues/763)).
- Refuse a `.navigate(href:)` whose escaped slash names no file, such as `OPS%2Fone.xhtml`, by splitting the href at its `#` and its `/`s before decoding any part, where the reader opened the section `OPS/one.xhtml` ([#754](https://github.com/vocaro/EPUBLib/issues/754)).
- Find the `#` of an href by its byte in `.navigate(href:)`, an SVG that shows one image and an `<object>` or `<embed>`, so that a fragment beginning with a combining mark is read as one, where navigation refused it after a path and the reader took it for a file or part of a file's name; StaticSVG's serializer still does not ([#641](https://github.com/vocaro/EPUBLib/issues/641)).
- Keep keyboard focus in the reader on Mac when a relayout or a page turn hides the column that has it, as a window narrowed from two columns to one does, by giving it to the column that holds the place entered or else the first column shown, where AppKit left it on the window and VoiceOver in no column ([#599](https://github.com/vocaro/EPUBLib/issues/599)).
- Pass over a table row on Mac whose cells hold nothing but a formula or rule that `visibility: hidden` hides, or a formula marked `aria-hidden`, as a row of hidden words is passed over, where VoiceOver stopped on a group with no name ([#774](https://github.com/vocaro/EPUBLib/issues/774)).
- Read a `CipherReference` URI in `META-INF/encryption.xml` as a URL from the container root, as EPUB 3.3 §4.2.6.2 has it, and else as the path it is written as, as a rootfile's path is read, so that `./`, `x/../`, a leading `/`, a query and a fragment name the font they resolve to and an escaped slash stays in its name, where the whole URI was decoded and looked up, which refused a book with such a URI as `unsupportedEncryption` and read `%2F` as a separator ([#753](https://github.com/vocaro/EPUBLib/issues/753)).
- Leave a lost entry whose name the ZIP language-encoding flag declares UTF-8 and that is not out of `EPUBLostEntries.paths`, as its documentation has it, and count it in `count`, where its path was given as an empty string ([#779](https://github.com/vocaro/EPUBLib/issues/779)).
- Expect the W3C corpus run's split-archive segment, `ocf-zip-mult.z01`, to be refused as `notArchive`, as bytes with no end record have been since #698, where the opt-in test still required `invalidArchive` and failed ([#825](https://github.com/vocaro/EPUBLib/issues/825)).
- Show nothing for an inline SVG that holds only what SVG never renders, such as a sprite sheet of `<defs>` and `<symbol>`s, as a browser draws nothing for it, where the reader showed "Illustration unavailable" or the drawing's title in its place and disclosed it as an SVG not drawn ([#136](https://github.com/vocaro/EPUBLib/issues/136)).
- Give a `q` nested three or more deep the inner quotation marks of its language under `quotes: auto`, «a„b„c““» in Russian, where every third level took the outer marks again ([#776](https://github.com/vocaro/EPUBLib/issues/776)).
- Offer a page-turn animation in paginated flow with `epubReaderPageTurnAnimation(_:)`, a slide or a dissolve, for every kind of turn on iPhone, iPad and Mac, with a swipe that the page follows and that puts it back when let go short of its turn and a dissolve in place of a slide under Reduce Motion, where one page always replaced the other at once ([#688](https://github.com/vocaro/EPUBLib/issues/688)).
- Show a plain sentence for each request the bundled reader refuses, such as "That part of the book cannot be found." for a contents entry that leads nowhere, and in each of its notices, from a new English string catalog in `EPUBViewing`, with `localizedDescription` for any other engine's refusal or failure, in `EPUBReaderError.message` and the reader's controls, and give one notice for a list of highlights however many of them are not drawn, naming those in the new `EPUBReaderStatus.undrawnHighlights`, where the controls showed the engine's own detail, such as "Unknown publication href", which the error keeps for `String(describing:)`, and the notices were lowercase fragments, one for each highlight with its `id` ([#698](https://github.com/vocaro/EPUBLib/issues/698)).
- Check the `mac-foreground` reservation in the Mac VoiceOver runner, which on the owner's Mac now refuses before its first key and stops before its next step unless its session holds the owner's screen within the owner's approval, while a GitHub-hosted run needs none ([#818](https://github.com/vocaro/EPUBLib/issues/818)).
- Run `swift test`, the iOS suites and the gate through the host's heavy-work admission as lanes, `swift-tests`, `ios-tests` and the exclusive `gate`, with `scripts/test-ios.sh` passing its arguments to each simulator's tests, reporting the tests each ran and failing one that ran none ([#787](https://github.com/vocaro/EPUBLib/issues/787)).
- Hide the reader's bars, toolbar and control strip under the new `epubReaderHidesControls(_:whileReading:)`, on iPhone and iPad as a page is turned or scrolled by the reader's own input or the new Hide Controls group is chosen and on a Mac by the window's own View > Hide Toolbar, and bring them back by a tap in the middle of the page, VoiceOver's Magic Tap, Option-Command-T or a Show Controls button in the room they left, keeping the reader where it was so that the book is not laid out again and no bar comes back over its text ([#696](https://github.com/vocaro/EPUBLib/issues/696)).
- Offer Sepia, Black and custom colour themes beside System, Light and Dark, whose page is now dark grey while Black keeps the black one Dark had, with text and links at 4.5:1 or more in every preset, and follow Increase Contrast and Bold Text in an open book ([#674](https://github.com/vocaro/EPUBLib/issues/674)).
- Report the page on screen and the page count of the current paginated layout, for the book and the section, in `EPUBReaderStatus.layoutPage`, counted a little at a time without holding up page turns and counted again after a resize or a text size change, go to a progression with `.goToProgression`, `.goToStart` and `.goToEnd`, and go to the book's start and end with Home and End, and on the Mac Command-Up and Command-Down, where a host could show only the progression and the keys did nothing ([#681](https://github.com/vocaro/EPUBLib/issues/681)).
- Ask before opening a web or email link outside the book that a reader activates, in the text, a table cell or a note's popover, and open it with the system on Open, with `epubReaderExternalLinks(_:)` for a host to refuse such links with the notice as before or take them itself, and never open or pass on any other scheme, where every link outside the book was refused with a notice and one in a note did nothing ([#683](https://github.com/vocaro/EPUBLib/issues/683)).
- Let book text follow the system text size with `EPUBReaderStyle.followsDynamicType`, rescaling an open book in place, and let Smaller Text and Larger Text reach 96 points, the largest size the reader draws, in larger steps above 36, saying the size drawn at each step, where book text stayed at its chosen size whatever the system text size and the controls stopped at 36 ([#675](https://github.com/vocaro/EPUBLib/issues/675)).
- Let a host set the font, line and paragraph spacing, letter and word spacing, page margins, justification and hyphenation of book text through `EPUBReaderStyle.typography`, in place of the reader's defaults or over the book's own styles, leaving preformatted text, code, tables, MathML and sized boxes as the book styles them, with a registered font's missing characters drawn in the font the text would otherwise have ([#673](https://github.com/vocaro/EPUBLib/issues/673)).
- Give every error the library throws or emits a plain, localisable message and, where one helps, a recovery suggestion, from English string catalogs in `EPUBCore`, `EPUBText` and `EPUBWriting`, so that a host shows `localizedDescription` as it is, and refuse a ZIP archive with no EPUB mimetype as `EPUBPublicationError.notEPUB` and bytes with no ZIP end record as `.notArchive`, keeping `invalidArchive` for damage, where a book protected by DRM, a damaged file or one that is not an EPUB gave "The operation couldn’t be completed" and the last two were both `invalidArchive` ([#698](https://github.com/vocaro/EPUBLib/issues/698)).
- Carry a publication's `persistentID`, its package's unique identifier or else the SHA-256 of its content, in every location the reader emits, and restore a position or draw a highlight saved under it, or under the former file hash, in a copy downloaded or zipped again, edited in its metadata or unpacked into a folder, where a location carried the SHA-256 of the file and every other copy refused it ([#679](https://github.com/vocaro/EPUBLib/issues/679)).
- Open a book unpacked into a folder (`org.idpf.epub-folder`, as Apple Books keeps one on the Mac) with `EPUBPublication.open(at:)`, under an archive's limits and refusals with symbolic links refused and `mimetype` optional, where a folder's URL was refused ([#680](https://github.com/vocaro/EPUBLib/issues/680)).
- Place every positioned box in a long run of relative containers, such as a chapter of margin notes each written after its paragraph in a container of its own, by anticipating each box where its inset puts it from its container's top as the layout finds it, where the layout found a few more boxes' places in each of its passes and twelve containers had every positioned box in the section set in flow ([#209](https://github.com/vocaro/EPUBLib/issues/209)).
- Draw a table's rows, a rule and an image across the content box of the indented block or list item they are in, in either direction and whether or not the section holds a float, where with a float each was the whole column wide and overhung the block by its indents, and without one each was narrower than the box right to left, as the first row of a list item was in either direction ([#376](https://github.com/vocaro/EPUBLib/issues/376)).
- Keep words whole in and beside floats: widen a float whose set width is narrower than a word it holds to that word, its first line's indent included, or to the word's widest part where its text hyphenates, and set a line beside a float only where its first word, or the first part of one that hyphenates, fits, and below the float otherwise as CSS 2.2 9.5 has it, where a verse number in a float sized in pixels and a word too wide for the room beside a float were broken between any two characters ([#152](https://github.com/vocaro/EPUBLib/issues/152)).
- Turn a page in continuous scroll on macOS by the visible height less a line in a book with a float or positioned box, and show a section's end when turning back into it before the book is built, by laying out the text a turn brings on screen before scrolling there, where a turn stopped at the end of the text laid out so far, 265.5 points of 629.7 from a full-page dedication and then 89 at a time, and the turn back showed the section's first lines ([#369](https://github.com/vocaro/EPUBLib/issues/369)).
- Paint a search match or highlight in a table nested in a cell on its own words, and give it the context, passage and CFI of the inner cell, at any depth, where the highlight covered the nested table, the context was the outer cell's text around it and the CFI named the nested table ([#718](https://github.com/vocaro/EPUBLib/issues/718)).
- Keep a page's text and the canvas behind it in one appearance while a section is rebuilt for another, by showing a reader opened in a Dark host once its first page is built for Dark, by changing the canvas once, when the sections the page shows and reaches by one turn are built for the new appearance, and by building a section still built for the old one before a page turn, contents entry, link or search result shows it, where a page built for Light was shown on a Dark canvas, black on black, until its Dark rebuild arrived, at opening and after a live change ([#243](https://github.com/vocaro/EPUBLib/issues/243)).
- Lay the reader out on macOS when a toolbar is shown, hidden or made compact over it and its size stays, as over a full-size content view or a reader under `ignoresSafeArea()`, so that the pages move clear of the bar, continuous scroll lays its text out for the height that shows and the image inspector's controls stay below the bar, where the first lines of each page stood under the toolbar until the window was resized ([#162](https://github.com/vocaro/EPUBLib/issues/162)).
- Keep `>` and `[` apart after a DOCTYPE, in any case, when a section falls back to the HTML parser and the NULs between them are left out, by giving the parser an empty `<!>` in their place, which libxml2 reads as nothing, so that leaving the NULs out cannot give it an internal subset the screen refuses, where `<!DOCTYPE html>`, a NUL and `[<!ATTLIST …>]>`, written so or in UTF-7, passed the screen and reached the parser without the NUL ([#246](https://github.com/vocaro/EPUBLib/issues/246)).
- Complete a search whose task is cancelled after its results are published, whatever callback or observer cancels it, where the search then read idle while its results stayed listed and drawn ([#157](https://github.com/vocaro/EPUBLib/issues/157)).
- Require a phrase with two or more search results in `EPUBEngineContract.verify`, which now fails a call whose phrase has one, where it passed its step and wrap checks without the current match moving ([#730](https://github.com/vocaro/EPUBLib/issues/730)).
- Fail an engine in `EPUBEngineContract.verify` whose next search result stays on the last result instead of returning to the first, or that shows an unlisted result because its index is in range, where the verifier stepped forward only from the first result and tried no unlisted result with a listed index ([#160](https://github.com/vocaro/EPUBLib/issues/160)).
- End a DOCTYPE at its first `>`, as the HTML Standard does inside a quoted identifier, in text extraction's recovery and in the reader, and put no element of HTML content in another namespace for its `xmlns` in recovery, where a chapter whose DOCTYPE identifier had lost its closing quote was refused as a DOCTYPE that never ends and not shown at all, and one whose root's `xmlns` value had lost its closing quote was refused in recovery ([#293](https://github.com/vocaro/EPUBLib/issues/293)).
- Keep the namespace prefixes of every `html` start tag in scope from the root in text extraction's recovery, and read no `title` as body text but take the document's first as the section's title there, where a root tag that closed at once after a DOCTYPE or a comment, or a root tag after a script that began with `</html>`, lost the section's `epub:type` values, and a title built in the body, or in a head after it on either path, was read as text ([#287](https://github.com/vocaro/EPUBLib/issues/287)).
- Leave an image, SVG drawing, formula or rule that `visibility: hidden` hides in the flow, and the words shown for a picture that cannot be drawn, out of what VoiceOver, Copy, search and a table cell read, as hidden text is, and open no inspector for a hidden image, where each was still read and a hidden image opened from its room ([#549](https://github.com/vocaro/EPUBLib/issues/549)).
- Keep shown text that `aria-hidden="true"` on it or round it marks, and a formula so marked, from VoiceOver alone, while it is drawn, copied and found as before, where VoiceOver read it as any other text ([#552](https://github.com/vocaro/EPUBLib/issues/552)).
- Refuse a file opened by URL by its length when it is longer than the archive limit, and by its last 65,557 bytes and first four when it is no ZIP archive, without reading the rest, and restate a ZIP64 value of zero in a copy that shares the archive's memory, where a 256 MiB file that was no book was read whole to be refused, and an archive with one zero to restate was copied whole when it was under 4 MiB or did not begin at a page boundary ([#208](https://github.com/vocaro/EPUBLib/issues/208)).
- Read an archive entry's name from its directory record's own bytes, keeping a byte-order mark that opens it, taking a record whose name ends in `/` for a folder whatever scalar comes before the `/`, and refusing a name that bit 11 calls UTF-8 and is not with its bytes in the error, where `EF BB BF` + `mimetype` was refused as a second `mimetype`, `OPS/` + U+0600 + `/` was a folder without the flag and a refused file with it, and the refusal was `unsafePath("")` ([#207](https://github.com/vocaro/EPUBLib/issues/207)).
- Ignore `epub:type`, and a note's role, on the `head`, on metadata content such as `title` and on SVG elements that are never drawn, find an `a` by its `name` beside its own id and inside a table or formula, take the marks around a `q` from CLDR by language, script and region, and indent a list item's first line by its `text-indent` after its marker, where a `title` typed as a footnote opened as a note, `#p12` found no `<a id="page12" name="p12">`, Brazilian Portuguese and Turkish quotations had « », and an item's first line started at the marker's stop ([#133](https://github.com/vocaro/EPUBLib/issues/133)).
- Count what a note holds once in a section's disclosure, where an unsupported element or a refused remote image in an endnote that stays in the flow, or in a note in a table's cell, was counted for the page and again for the note's popover ([#258](https://github.com/vocaro/EPUBLib/issues/258)).
- Name an element in a controls-probe step by its label first, then its identifier, placeholder and title, among the application's own elements only, refuse a step whose word names two that can be touched, and touch the keyboard's keys with a `keyboard` step of their own, where with the keyboard up `tap=Search` took the first it could touch and pressed the keyboard's Search key, whose identifier is Search, in place of the search field's button ([#366](https://github.com/vocaro/EPUBLib/issues/366)).
- Mark the contents entry for the section being read as current when it names that section in another spelling, composed or decomposed, escaped or not, or through the section's designated fallback, by finding the section of the entry and of the location as `.navigate(href:)` does, where the two hrefs were compared as written and the entry got no checkmark although choosing it opened that section ([#206](https://github.com/vocaro/EPUBLib/issues/206)).
- Show a line of each page's characters on every page, by laying out a page whose own layout sets none of them on a line as the typography fallback, fitting a formula and a tab with no stop after it there too, and dividing between pages a first line that the fallback cannot fit, where such a page was committed as the section planned it, its characters on no visible line ([#576](https://github.com/vocaro/EPUBLib/issues/576)).
- Take any number sub-expression in `calc()` as a factor or divisor, the constants `e`, `pi`, `infinity` and `NaN` included, with division by zero infinite and clamped to the property's range, and take a math function that comes to a number wherever a number is, where `calc((1 + 2) * 4px)`, `calc(12px / (1 + 2))`, `line-height: calc(24 / 16)` and `font-weight: calc(300 + 400)` were dropped ([#122](https://github.com/vocaro/EPUBLib/issues/122)).
- Map a `br`'s `clear` attribute (`left`, `right`, `all` or `both`, in any case) to `clear`, and take a table's width and a cell's width and height of zero for no size, reading dimension attributes by HTML's rules on the elements HTML §15 names and the table builder's sizes from the cascade alone, where `<br clear="all">` left the next line beside a float, `<table width="0">` and `<td width="0">` held their columns to their narrowest words, `<pre width="80">` was 80 points wide and an author's `width: auto` lost to a table's attribute ([#121](https://github.com/vocaro/EPUBLib/issues/121)).
- Let a row group's vertical alignment, from its `valign` or CSS, reach its rows and their cells, as HTML's `tr, td, th { vertical-align: inherit }` passes it down, and place a cell by its own computed alignment alone, where every row was middle whatever its group said and a row's or group's `valign` beat a cell's own `vertical-align: baseline` ([#142](https://github.com/vocaro/EPUBLib/issues/142)).
- Lay out `marquee` as an `inline-block` with its own `text-align`, as HTML §15.5.13 does, and map its `width`, `height`, `hspace`, `vspace` and `bgcolor`, where a marquee in a paragraph took a line of its own ([#607](https://github.com/vocaro/EPUBLib/issues/607)).
- Keep a percent-encoded slash inside its path segment when resolving a reference, as URL parsing does, so that `a%2Fb.xhtml` names no entry, where it named `a/b.xhtml` ([#660](https://github.com/vocaro/EPUBLib/issues/660)).
- Find a reference's query at its first `?` before any `#`, whatever else the reference holds, so that one `URLComponents` cannot parse, such as `1:x/../y?q`, has its query dropped when it is read and refused when it is written, as any other reference does, where the query was kept in the path as `y%3Fq` ([#215](https://github.com/vocaro/EPUBLib/issues/215)).
- Lay out a spine item that overrides `rendition:layout` more than once by the first override, as EPUB Reading Systems 3.3 §5.5.1 requires, where it was pre-paginated whenever either override said so ([#79](https://github.com/vocaro/EPUBLib/issues/79)).
- Read a manifest `id` and every reference to one (`idref`, `fallback`, the spine's `toc`, `unique-identifier`, a `dc:identifier`'s `id` and the EPUB 2 cover `meta`) without the XML white space round it, as XML Schema reads an ID and EPUBCheck accepts it, where `id=" one "` with `idref="one"` refused the book and a font keyed by such a unique identifier was left out ([#80](https://github.com/vocaro/EPUBLib/issues/80)).
- Strip and collapse the white space of an EPUB 2 guide reference's `title`, as a navigation landmark's title is, where it was kept as written ([#269](https://github.com/vocaro/EPUBLib/issues/269)).
- Evaluate media queries with Media Queries 4's three values, so that a feature or value the reader does not know, a prefix its feature does not take and other parenthesised terms are unknown through `not`, `and`, `or` and the query list, where `not (bogus)`, `not all and (bogus)` and `not (min-orientation: portrait)` applied everywhere ([#114](https://github.com/vocaro/EPUBLib/issues/114)).
- Match a namespaced attribute selector by namespace in a section read as HTML, as in XHTML, where `[ops|type]` compared its prefix's text and missed `epub:type`, and read the namespace a prefix stands for from the book's `xmlns:` declarations on libxml2's HTML route as the XML-shaped route reads it, so that a book's `ops:type` is `epub:type`, and its notes are read, on both routes ([#642](https://github.com/vocaro/EPUBLib/issues/642)).
- Match CSS class names, attribute names and values under every operator, element names, namespace URIs and `:lang()` ranges by their code units, as browsers do, with the `i` flag and `:lang()` folding the ASCII letters alone, where `.caf\E9` styled `class="cafe&#x301;"`, `[id^="e"]` missed `id="e&#x301;x"` and `[title="k" i]` matched the Kelvin sign ([#640](https://github.com/vocaro/EPUBLib/issues/640)).
- Draw SVG with the [StaticSVG](https://github.com/vocaro/StaticSVG) package, pinned at 0.1.1, which now holds the screens, the sanitizing serializer, image and font preparation and the resvg renderer that were EPUBLib's, the renderer binary unchanged; EPUBLib keeps archive access, manifest fallbacks, inline SVG, layout and disclosures ([#636](https://github.com/vocaro/EPUBLib/issues/636)).
- Time an edge tap on iPhone and iPad by the touch's own timestamps, and build resvg with no file read and its Rust standard library without backtraces, where the reader read the system's uptime and resvg kept `stat` and `fstat`, APIs that an app has to declare in its privacy manifest, so that an app built with EPUBLib has none of them to declare ([#685](https://github.com/vocaro/EPUBLib/issues/685)).
- Compute custom properties and substitute `var()` as CSS Custom Properties for Cascading Variables 1 does, with fallbacks, cycles, `calc()`, shorthands and the CSS-wide keywords, and within bounds on what a book can make the reader substitute, where a declaration that held a `var()` was dropped and custom properties were not kept, so a stylesheet built on them fell back to inherited or initial values ([#119](https://github.com/vocaro/EPUBLib/issues/119)).
- Place and size a float or sized inline block within the content box of the block it is in, and shorten a line beside a float on the float's side only, where a drop cap in an indented block quotation stood in the quotation's margin 40 points from its word, a float's percentages were of the whole column, and the prose after a positioned container with a margin was set in that margin, on the far side of a float the container held ([#150](https://github.com/vocaro/EPUBLib/issues/150)).
- Open the page, or scroll to the line, that draws a search result, located passage, bookmark or link target in a table nested in a cell, at any depth, where it opened the first page of the outer row, and the nested table's start in continuous scroll ([#544](https://github.com/vocaro/EPUBLib/issues/544)).
- Turn the page on macOS for one notch of a mouse wheel turned slowly, by counting a wheel's line as 40 points as WebKit and Chromium do, where it counted 10 and a notch's tenth of a line fell short of the 4-point threshold, and for a digit bound with Shift, as Shift-1, by matching the character its key types without Shift where Shift makes it type a symbol ([#163](https://github.com/vocaro/EPUBLib/issues/163)).
- Read a table of one column whose footer is written before its body, or whose header or caption is written away from where it is shown, in the order it is shown, give a passage from prose into a cell one line break between them, and write a cell nested past the eighth level as a shallower one is, where the footer was read first, the break was doubled, and the deep cell's words ran together and showed script, control and annotation text ([#144](https://github.com/vocaro/EPUBLib/issues/144)).
- Find the shared engineering toolkit beside the main checkout from a worktree of it, in `scripts/eng`, the scripts and their tests, where a session's worktree looked for it beside the worktree, so that `scripts/eng` stopped unless `VOCARO_ENGINEERING_ROOT` was set and the script tests failed even when it was ([#701](https://github.com/vocaro/EPUBLib/issues/701)).
- Navigate for a reference to an empty note, to the first of several items in a note that stays in the flow, and for a link to `#` where an element's id is empty, and leave out the marker of a list item that shows nothing in a note, where each opened an empty, whole or wrong popover or one of bare bullets ([#284](https://github.com/vocaro/EPUBLib/issues/284)).
- Inflate a deflated entry with zlib, and so refuse one whose stream has a damaged block header, or is cut short, as `invalidArchive("<path>: corruptedData")` on every open, where Apple's decoder, which ZIPFoundation inflates with, read stack memory it had not set and refused the same book by its checksum, by a limit or as damage from one open to the next ([#583](https://github.com/vocaro/EPUBLib/issues/583)).
- Count a flex or grid item's padding, border and margins, the margins inside it and empty items such as a `flex: 1` spacer as content of a column or one-column grid, keep an item's margins from collapsing with its container's, its siblings' and its content's, and drop `left` and `right` from `align-items`, `align-self` and `align-content`, where a padded item made its box taller than its height and off centre, a spacer pushed nothing down and `align-items: right` replaced an earlier valid value ([#154](https://github.com/vocaro/EPUBLib/issues/154)).
- Keep the floats of a run of float-and-text rows longer than a page, such as a definition list with floated terms, by taking rows that only meet as groups of their own, where the run was one group taller than a page and every float in it was turned off, and a float's `break-before: page` was lost when its source followed another float's ([#149](https://github.com/vocaro/EPUBLib/issues/149)).
- Draw the backgrounds and borders of a table row's cells, and the table's own, through the band a row is drawn taller by to finish a spanning cell's line that crosses into the next row, or a line that crosses a tall row's cut between pages, where the band was left bare and a shaded cell lost its colour behind half a line ([#141](https://github.com/vocaro/EPUBLib/issues/141)).
- Keep the image or rule that ends a section in a selection's CFI and highlight when nothing follows it in the document, where the range came back without it and one of the image alone could not be highlighted, and give a range of a list marker or quotation mark alone a DOM range that runs forwards ([#129](https://github.com/vocaro/EPUBLib/issues/129)).
- Draw an SVG `<image>` given in a `data:` URL, inline, in an SVG from the archive and in an SVG that is only that image, as an archive image there is and within the same bounds, where the drawing was shown without it, or its fallback text in its place, and the image was disclosed, in an SVG file as a resource refused from the internet ([#657](https://github.com/vocaro/EPUBLib/issues/657)).
- Read an image, SVG drawing, formula or other embedded element in a contents, landmark or page-list label as its alternative text (its `alt`, else its `title`, else a drawing's `title` element or a formula's `alttext`), and an empty label as its link's or heading's `title`, where an image's label came out empty and an SVG's held its description and drawn text too ([#83](https://github.com/vocaro/EPUBLib/issues/83)).
- Select the passage `.locate` finds where it renders over an earlier occurrence in content that renders nothing, wherever in its section that content sits, and refuse a highlight or saved range of such content between rendered text as one at a section's start or end is refused, where an occurrence hidden between rendered text was gone to and nothing was selected ([#158](https://github.com/vocaro/EPUBLib/issues/158)).
- Remove the sample app, keeping its reader screen and the guide's compiled examples in the VoiceOver verification host ([#700](https://github.com/vocaro/EPUBLib/issues/700)).
- Share engineering guidance and VoiceOver support tooling through the private apple-engineering toolkit ([#637](https://github.com/vocaro/EPUBLib/issues/637)).

- Read named character references in the container, package, navigation and NCX documents and in text extraction from the HTML Standard's table, as the viewer does, keep a name it lacks such as `&bogus;` as written, and decode them in a document declared in KOI8-R, Mac OS Roman, TIS-620, Windows 874, EUC-JP, EUC-KR or GB2312, where a name outside HTML 4 was dropped from a title or label or refused the book, and a KOI8-R title read `Les Misrables` ([#184](https://github.com/vocaro/EPUBLib/issues/184)).
- Leave out a font under IDPF obfuscation, and open the book, when the package gives no unique identifier or a blank one, as an Adobe-obfuscated font without a key is left out, where the book was refused or, in a package without `unique-identifier`, the font was decoded with a key made from its first identifier without an `id` ([#530](https://github.com/vocaro/EPUBLib/issues/530)).
- Read a package or navigation document the same way on every run when two prefixes for one namespace give an element two attributes of one name, such as two `epub:type`s on a `nav`, and read an element's namespace declarations in text extraction in document order, where which attribute was read, and so which `nav` gave the contents, changed from run to run ([#213](https://github.com/vocaro/EPUBLib/issues/213)).
- Report `limitExceeded("depth")` in strict text extraction for a well-formed section nested deeper than libxml2's cap of 257 levels, as recovery does, where a caller's depth limit above that gave `malformedContent` ([#91](https://github.com/vocaro/EPUBLib/issues/91)).
- Show an image given in a `data:` URL, base64 or percent-encoded, as one from the archive is and within the same bounds, where it showed its alternative text and was disclosed as an image that could not be shown ([#134](https://github.com/vocaro/EPUBLib/issues/134)).
- Honour `clear` on a block that holds other blocks, on a float and on a `br`, starting the block's content, the float or the line after the break below the earlier floats it names, where only a paragraph's own block was cleared and the rest stayed beside the float ([#151](https://github.com/vocaro/EPUBLib/issues/151)).
- Keep the tabs and carriage returns of an SVG drawing as the book writes them when it is prepared for the renderer, where one in an attribute value was read as a space and one in text as a line feed, so that a class list could change and an `href` name another element ([#249](https://github.com/vocaro/EPUBLib/issues/249)).
- Lay out as one column the consecutive columns of a table that the same cells span and no `col` declares, so a title row's `colspan="100"` over two columns adds one border spacing, where each of the 98 columns no cell starts in added its own and made the table about 200 points too wide ([#140](https://github.com/vocaro/EPUBLib/issues/140)).
- Let a `..` after a doubled slash in a reference remove the empty segment, as URL parsing does, so `a//../b` names `a/b` when read and when written, where it removed the name before it and named `b` ([#605](https://github.com/vocaro/EPUBLib/issues/605)).
- Write the `mimetype` entry from the bytes the archive writer checked, and close its source once they are checked, where the source was read again after `progress(0)` and one appended to or replaced in between was archived unchecked ([#604](https://github.com/vocaro/EPUBLib/issues/604)).
- Resolve `rem` in every property of the root element but its own `font-size` against the root's computed font size, where it was the reader's size, and a line height the root set in `rem` was passed wrong to the whole book ([#118](https://github.com/vocaro/EPUBLib/issues/118)).
- Read a pseudo-element written alone, such as `::before` in `*, ::before, ::after`, as that of any element, as Selectors 4 says, where it was an invalid selector that dropped its whole rule ([#110](https://github.com/vocaro/EPUBLib/issues/110)).
- Look up element IDs by their exact code units everywhere, as `getElementById` does: section anchors, links, notes and navigation, CSS `#id` selectors, SVG references, text extraction's `anchors` (now keyed by `EPUBElementID`) and the package's manifest IDs, which took canonically equivalent IDs such as `caf&#xE9;` and `cafe&#x301;` for one ([#635](https://github.com/vocaro/EPUBLib/issues/635)).
- Refuse an empty title, identifier, contents or navigation label, a contents entry with neither a target nor entries, and a resource ID that is not an XML name, and leave out an empty author, language, summary or keyword, where the writer wrote each into a package EPUBCheck rejects or dropped the entry without a word ([#96](https://github.com/vocaro/EPUBLib/issues/96)).
- Refuse in strict text extraction a name that Namespaces in XML forbids, such as `<:p>` or `script:`, and read it in recovery as the native reader does, where it was read as `p` or `script` and its text restructured or dropped ([#178](https://github.com/vocaro/EPUBLib/issues/178)).
- Match CFI ID assertions by their exact code units, and leave out an ID assertion that would make an issued bookmark one `restore` refuses ([#105](https://github.com/vocaro/EPUBLib/issues/105)).
- Draw nothing in the room of a rule, image, SVG drawing, formula or table that `visibility: hidden` hides, nor of the words shown where an image or formula cannot be, and draw what sets `visibility: visible` again inside it ([#132](https://github.com/vocaro/EPUBLib/issues/132)).
- Resolve `vmin` and `vmax` against the smaller and the larger side of the reading viewport, where they were read as `vw` and `vh` and wrong in a viewport wider than it is tall, and a rule's or a table's width in viewport units against that viewport rather than its own line ([#123](https://github.com/vocaro/EPUBLib/issues/123)).
- Apply a rule whose selector names `epub:type` with an escaped colon, such as `[epub\:type~="footnote"]`, in a section read as HTML, where most such rules never applied ([#111](https://github.com/vocaro/EPUBLib/issues/111)).
- Ignore a `background` declaration with a value the reader does not know, such as a gradient prefixed for another engine or an unknown keyword, so the colour an earlier declaration gave stays, where it was cleared ([#120](https://github.com/vocaro/EPUBLib/issues/120)).
- Read past the white space round a contents, landmark, page-list, NCX, guide, manifest or rootfile reference as URL parsing does, so a link written `href=" one.xhtml#start"` names `OPS/one.xhtml#start` instead of no file ([#76](https://github.com/vocaro/EPUBLib/issues/76)).
- Find a book's NCX by its media type when the spine's `toc` attribute is missing or names no item, where an EPUB 2 book opened with no contents or page list ([#169](https://github.com/vocaro/EPUBLib/issues/169)).
- Make the IDPF font obfuscation key from the unique identifier with only the space, tab, carriage return and line feed removed, as EPUB 3.3 says, where white space outside ASCII, a zero-width space at its ends and a mark after a space were removed too and the font was decoded to garbage ([#82](https://github.com/vocaro/EPUBLib/issues/82)).
- Default simulator VoiceOver activation to guarded cursor dispatch on pinned iOS 27.2 and announce link destinations through its layout handler before screen updates ([#495](https://github.com/vocaro/EPUBLib/issues/495)).
- Name the language of each line, heading, link and table cell to VoiceOver on iPhone and iPad, part by part where a line mixes languages ([#65](https://github.com/vocaro/EPUBLib/issues/65)).
- Use MathMLLayout’s native wrapping, elementary-math layout and localized generated readings, with long inline formulas flowing across text lines ([#25](https://github.com/vocaro/EPUBLib/issues/25)).
- Draw MathML glyph images from the book with alternative-text fallbacks, and include glyph alternatives in headless text extraction ([#25](https://github.com/vocaro/EPUBLib/issues/25), [#66](https://github.com/vocaro/EPUBLib/issues/66)).
- Document the native teardown that can keep a Mac corpus layout process running after its test passes, and how to keep its output visible ([#589](https://github.com/vocaro/EPUBLib/issues/589)).
- Record the simulator VoiceOver probe's build revision in its transcript when reusing a build, and mark an unrecorded build's revision unknown with the checkout revision separate ([#504](https://github.com/vocaro/EPUBLib/issues/504)).
- Check the hosted-run and VoiceOver session scripts offline as part of the local gate ([#433](https://github.com/vocaro/EPUBLib/issues/433)).
- Add the required modification timestamp to the reader sample's generated EPUB so it passes EPUBCheck ([#168](https://github.com/vocaro/EPUBLib/issues/168)).
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
