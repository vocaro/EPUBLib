# Architecture

EPUBLib contains five independently selectable products. `EPUBCore` owns shared publication,
resource, navigation and reader value types. `EPUBReading` owns immutable publications and
bounded archive/metadata parsing; `EPUBText` adds structural extraction, including text and anchor
positions from one libxml2 walk. `EPUBWriting` generates EPUB 3 package/navigation documents from
explicit publication facts and streams file-backed resources into an OCF archive. These targets
contain no SwiftUI, WebKit, PDFKit, Vision, application policy or reconstructed-PDF model.

`EPUBViewing` owns the reader/session interface and the native viewer: content documents,
the CSS subset, attributed text, CFIs, search and TextKit 2 views (see [native viewer](native-viewer.md)).
It uses no WebKit and runs no JavaScript. Viewing depends on EPUBReading, EPUBCore and the
[MathMLLayout](https://github.com/vocaro/MathMLLayout) and
[StaticSVG](https://github.com/vocaro/StaticSVG) packages (each pinned exactly, like
ZIPFoundation), never EPUBText or EPUBWriting. MathMLLayout lays out presentation MathML with
CoreText. StaticSVG screens, sanitizes and draws static SVG with the resvg build it bundles; it
opens no file and fetches no URL, and Viewing gives it the archive's images, fallbacks and
fonts through `PublicationSVGResources`. Neither package imports an EPUBLib module or a UI
framework. EPUBWriting depends only on EPUBCore and ZIPFoundation, never EPUBReading or
viewing. The adapter-contract helper is an internal test-support target, not a library product.

Source API compatibility with the former package is not a constraint. Publication fingerprints
(`id`) retain their existing meaning, but locations carry `persistentID` since
[#679](https://github.com/vocaro/EPUBLib/issues/679), and the reader still restores one saved
under the fingerprint. The reader's engine identifier is `org.epublib.reader` and its
bookmark format `epublib-cfi-v1` (`EPUBReader.identifier`, `EPUBReader.bookmarkFormat`); both name
the library, not a renderer. The WebKit reader's `org.epubreaderlib.foliate`/`epubcfi-v1`
bookmarks are another engine's and are refused, but their CFI values name the same positions:
a host migrates one by re-tagging it with the reader's identifier and format. When the former
sample app's book ([#700](https://github.com/vocaro/EPUBLib/issues/700)) gained the required
modification timestamp, its bytes and publication fingerprint changed, so positions saved
against the older book did not carry over ([#168](https://github.com/vocaro/EPUBLib/issues/168));
under `persistentID`, its unique identifier, they would have.

## Publication model

Opening copies the archive into a bounded snapshot and checks every archive entry before returning.
Archive paths are decoded ZIP paths; the container's rootfile path and manifest/navigation hrefs
are URL references. An entry's name is read as UTF-8 when its bytes are well-formed UTF-8, with or
without the ZIP language-encoding flag (general-purpose bit 11), which `zip` and `ditto` on a Mac
leave clear; any other name is read as code page 437, or refused when the flag calls it UTF-8,
as `invalidArchive("Entry name not UTF-8: …")` with the name's bytes escaped as a URL escapes
them. Every scalar a name spells is part of the path, a byte-order mark that opens it among them,
and a record whose name ends in `/` is a folder whatever comes before the `/`, unless the Unix
mode of the system that made it says what it is ([#207](https://github.com/vocaro/EPUBLib/issues/207)).
The parser resolves the rootfile path from the container root and other
references relative to the containing OPF/navigation document. A rootfile path that is refused as
a URL or names no entry that way (a name's own `%`, `#` or `?` left unescaped, as older validators
required) is read as the archive path it is written as when that is a safe path naming an entry;
with an entry under each reading, the URL's is the package document. It exposes metadata,
manifest resources, linear/nonlinear spine entries with rendition layout, cover, nested contents,
landmarks (the EPUB 2 guide's references when there are none) and the page list (the NCX's
`pageList` when the navigation document has none). The metadata values, the legacy cover `meta`
and the identifiers a font key is made from are read from the children of `metadata` and, where
they stand among them, from those of the `dc-metadata` and `x-metadata` elements that OPF 2.0.1
§2.2 deprecates and has a reading system allow. EPUB 3 has neither, but a package that says it
is EPUB 3 and has one is read the same ([#85](https://github.com/vocaro/EPUBLib/issues/85)).
Reading resource
bytes does not execute document content. XML expansion and external entity resolution are refused. Declaration screening distinguishes
actual DTD syntax from comments, CDATA, processing instructions and quoted identifiers. It decodes
UTF-16/32 and declared legacy encodings with libxml2's converters before inspecting markup,
and refuses ambiguous encoding switches and encodings it cannot decode
([#86](https://github.com/vocaro/EPUBLib/issues/86)). For each call into libxml2 the package
gives the calling thread's handlers to one that keeps nothing and puts the thread's own back
after, so nothing libxml2 says about a book reaches the host's standard error or its own handlers
([#392](https://github.com/vocaro/EPUBLib/issues/392);
[libxml2's error handlers](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#parser-choice-can-change-text)).

A metadata value and a navigation label are read as text: the element's and that of everything
inside it, with each run of ASCII whitespace (tab, line feed, form feed, carriage return, space)
as one space and none left at either end. EPUB Reading Systems 3.3 §5.3 requires that of Dublin
Core and `meta` values, and it is how a browser renders a link, so a title or a label its
authoring tool wrapped and indented is one line. The values are the Dublin Core title, creators,
languages and identifiers and the `rendition:layout` `meta`; the labels are a contents entry's
link or heading, a landmark's link, a page-list link, an NCX `navLabel` and an EPUB 2 guide
reference's `title` ([#269](https://github.com/vocaro/EPUBLib/issues/269)). An image, an SVG
drawing, a formula or other embedded element in a label is read as its alternative text, as EPUB
Reading Systems 3.3 §7 recommends: its `alt`, else its `title`, else a drawing's `title` element
or a formula's `alttext`. One with none of these is read by its content, such as a formula's
characters or an object's fallback, and an image without them adds nothing. A label that is empty
then is its link or heading's own `title`, read as a label is, when it has one: EPUB 3.3 §7.3 has
a link or heading holding embedded content with no text alternative carry its label there, and
foliate-js reads it
([#83](https://github.com/vocaro/EPUBLib/issues/83)). White space outside
ASCII, a no-break or an ideographic space among it, is the author's character and is kept
inside and at the ends of a value that holds anything else, but a value that is nothing but
white space of any kind is empty: some tools write a lone no-break space as a placeholder, and
no host can show one. A value left empty is not listed among the metadata; an entry whose label
is left empty stays, without a title. `xml:space` changes nothing. White space is found as
[normalizing by scalar and by byte](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#normalize-text-by-scalar-and-by-byte-not-by-character)
says. An attribute's value is not such text, but for an alternative or `title` read into
a label and a guide reference's `title`. A font obfuscation key is made from the identifier's text by its algorithm's own rule,
not from the value read here. IDPF's removes the space, tab, carriage return and line feed and
nothing else (EPUB 3.3 §4.4.3), each as its byte: other white space is part of the key, at the
identifier's ends too, and so is a mark after a space. Adobe's is the UUID whatever white space
of any kind surrounds it.

A path the reader keeps is relative and made of names separated by single `/`: no name is empty,
`.` or `..`, and the path holds no backslash or NUL. Entry names, the rootfile path and the path
of every resolved reference are held to that. A reference is split as URL parsing splits it,
at the delimiters written as themselves, before anything in it is decoded: the fragment at the
first `#`, the query at the first `?` before it, and the path into names at each `/`. A query
is found so whether or not Foundation's `URLComponents` would parse the reference
([#215](https://github.com/vocaro/EPUBLib/issues/215)). An escaped delimiter is a character of
its part: `%2E%2E` is the `..` it spells, but `%3F` and `%23` are in the name, and so is `%2F`,
which no name an entry has can hold, so `a%2Fb.xhtml` names no entry and does not resolve, as
a reference with a backslash does not. A manifest href that does not resolve so refuses the book;
a contents entry keeps its label without a target, and a landmark, page, stylesheet or image is
left out ([#660](https://github.com/vocaro/EPUBLib/issues/660)). A delimiter in a path or a
reference is found as its byte, not by `Character`, and paths are compared as Swift strings, by
canonical equivalence:
an entry answers to a reference in either normalization form, and two entry names equal after
normalization are duplicates
([archive paths](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#archive-paths-need-byte-level-delimiters-and-deliberate-normalization)).

Default limits are 256 MiB compressed, 512 MiB expanded, 32 MiB per resource, 20,000 entries and
4 MiB per XML document, with depth/node limits. Hosts may lower or raise import limits. Resources
are retained in memory; the total memory footprint includes both compressed and expanded data.
Opening holds no second copy of the archive: where ZIPFoundation is given ZIP64 values of zero
restated ([#72](https://github.com/vocaro/EPUBLib/issues/72)), the copy shares the archive's
memory page for page, and only the pages of the directory records restated are copied
([#208](https://github.com/vocaro/EPUBLib/issues/208)).
For large books, open on a background task. Task cancellation is checked while expanding entries.
The optional import progress callback receives cumulative expanded bytes on that task's thread.
A host granting security-scoped file access must keep access active until opening completes.

Inputs need an EPUB mimetype, a container rootfile and a nonempty resolvable spine. Unsupported
encryption, archive entries named outside the archive (a `..` segment, a leading `/`, a backslash),
duplicate paths, symlinks, entity declarations, malformed metadata/navigation XML, one manifest id
naming two resources and a spine that names a remote resource fail explicitly. So do bytes with
no ZIP end record in their last 65,557, as far back as one with the longest comment begins, unless
they begin with a local file header's signature as an archive does: they are refused as no
archive by those last bytes and their first four, without the rest being read. Bytes that do
begin so and hold no end record are refused after one search through them in memory. A file
that `open(at:)` opens is read no further to be refused: one longer than `archiveBytes` by its
length, read not at all, and one with no end record by those last and first bytes. A pipe, a
socket or a device, which gives no length, is read from its first byte, as far as
`archiveBytes` and one more, and refused as its bytes are
([#208](https://github.com/vocaro/EPUBLib/issues/208)). Bytes with no end record are refused as
`notArchive`, a ZIP archive with no EPUB mimetype as `notEPUB`, and other damage to the archive as
`invalidArchive` ([when something fails](integration.md#when-something-fails)).

`open(at:)` also reads a book unpacked into a folder, an OCF abstract container (EPUB 3.3 §4.2)
that the file system holds, as Apple Books keeps one on the Mac
([#680](https://github.com/vocaro/EPUBLib/issues/680)). Its files are an archive's entries by
their paths from the folder, held to the same rules for a path and the same refusals, and to the
limits of an archive's expansion: `resourceBytes` for each, by its length before it is read and by
its bytes as they come, `expandedBytes` for all of them, and `entryCount` for its files and the
folders inside it together. `archiveBytes` is not asked. `mimetype`, which EPUB 3.3 §4.2.2
reserves for a ZIP container, may be missing; one that is there must name EPUB. A symbolic link
is refused wherever it stands and whatever it points at, as a link entry is, and so is anything
but a file or a folder, such as a pipe. Every file and folder is opened by its path from the
folder with `O_NOFOLLOW_ANY`, so one replaced by a link after the folder was listed is refused
too; the folder the URL names may itself be a link. A file held under two names, a hard link, is
read under each. Only the names, the kinds of entry and each file's length are asked of the file
system, never a timestamp (#685). The publication has no `archiveData` and no `lostEntries`.

A publication's `id` is the SHA-256 of the bytes it was opened from: the file's, or the folder's
files, each with its path. Its `persistentID`, which the reader's locations carry, is the
package's unique identifier (`uniqueIdentifier`, the `dc:identifier` that `unique-identifier`
names, read as a metadata value), which EPUB 3.3 §5.5.3.1.1 asks a book's makers to keep through
minor revisions, or, without one, the SHA-256 of its content: each resource it holds, by its path
in normalization form C and its bytes, and the paths of its spine in order, but not the package
document. So a copy downloaded again, zipped again, edited in its metadata or unpacked into a
folder has the book's `persistentID`, and a different `id`
([#679](https://github.com/vocaro/EPUBLib/issues/679)). `releaseIdentifier` joins the unique
identifier and the `dcterms:modified` that refines nothing with `@`, as EPUB 3.0.1 §4.1.2 made a
release identifier, to tell one version from the next. `publicationIDs` lists every value a
location saved in the book can carry: `persistentID`, the content's SHA-256 where that is not it,
and `id`. Two publications that give one unique identifier share a `persistentID`, though EPUB
Reading Systems 3.3 §5.2 has a reading system not depend on a unique identifier being unique; a
saved position then restores in either as far as its CFI resolves there.

Faults that leave a book readable are read past instead. Apart from `lostEntries` (under
Archive), the publication model has no channel for warnings, so this list is where they are
disclosed:

- **References.** The white space round a reference is read past, as URL parsing strips the C0
  controls and spaces at its ends, so a contents link written `href=" one.xhtml"` names
  `one.xhtml`; white space inside it, outside ASCII or written as an escape is part of the name
  ([#76](https://github.com/vocaro/EPUBLib/issues/76)). No reference leaves the container: a
  leading `/` names the container root and `..` stops there (EPUB Reading Systems 3.3 §4.1.1). A
  doubled slash is an empty segment, as URL parsing has it, so a `..` after one removes it and
  `a//../b` names `a/b`; an empty segment that remains names no entry and is read past, so `a//b`
  names `a/b` too ([#605](https://github.com/vocaro/EPUBLib/issues/605)). A query is dropped.
  The container's rootfile path is the exception: it names the package document or nothing, and
  is refused in these forms. An encrypted file's `CipherReference` URI, a URL from the container
  root as the rootfile path is (EPUB 3.3 §4.2.6.2), is resolved as other references are, its
  fragment dropped as its query is: an escaped slash (`%2F`) names no entry, and `./a.ttf`,
  `x/../a.ttf` and `a.ttf?v=1` name `a.ttf`. Where that names no entry, the URI names the file it
  is written as, if one has that path: EPUBCheck before version 5 decoded the whole URI and looked
  that up, so a name's own `#` or `?` passed unescaped
  ([#753](https://github.com/vocaro/EPUBLib/issues/753)).
- **Manifest.** An item repeated verbatim counts once. An item whose file the archive lacks and a
  remote item, which is never fetched, are left out of `resources`; the spine still needs every
  document it names. An href that matches no entry names the one entry that differs only in case,
  when there is exactly one. `EPUBResource.fallbackID` retains a designated manifest fallback;
  `fallbackChain(for:)` follows declared IDs in order and stops at a missing or repeated ID.
  Manifest IDs and the references to them (the spine's `idref`, `fallback`, the NCX `toc`, the
  EPUB 2 cover and `unique-identifier`) compare code unit for code unit, as XML compares IDs:
  `caf&#xE9;` and `cafe&#x301;` are two items ([#635](https://github.com/vocaro/EPUBLib/issues/635)).
  Each is read first as XML Schema reads the name types (`NCName`, `ID`, `IDREF`) the package
  schema gives them, its white space collapsed: no XML white space (space, tab, line feed,
  carriage return) at either end, and each run of it inside one space. So `id=" one "` is the item `idref="one"` names, as EPUBCheck
  reads it, an item that differs from another only so repeats it, and an id of nothing but that
  white space is empty, as `id=""` is. Other white space, a no-break space among it, is part of
  the ID. A `dc:identifier`'s `id`, which `unique-identifier` names, is read the same way. The cover
  `meta`'s `content` is not typed as an IDREF but names an ID, and is read the same way
  ([#80](https://github.com/vocaro/EPUBLib/issues/80)).
  Missing and remote declarations remain available to chain traversal, while resource access
  still reads archive-local entries only; the authored spine entries remain unchanged
  ([#78](https://github.com/vocaro/EPUBLib/issues/78)).
- **Spine.** An itemref that overrides the package's `rendition:layout` more than once, which
  EPUB 3.3 does not allow, is laid out by the first override its `properties` writes, whatever
  stands between them, as EPUB Reading Systems 3.3 §5.5.1 has a reading system do
  ([#79](https://github.com/vocaro/EPUBLib/issues/79)).
- **Contents.** An entry whose href does not resolve keeps its title and children, without an
  href. A landmark or page that does not resolve is left out.
- **NCX.** The NCX is the item the spine's `toc` names, whatever its media type. Where `toc` is
  missing, which OPF 2.0.1 §2.4 does not allow, or names no item the archive holds, the NCX is
  the first manifest item of type `application/x-dtbncx+xml` that it does, as foliate-js finds
  it (Readium does where `toc` is missing). A book without a navigation document is refused when
  the NCX its spine names does not parse; one found by its media type was not needed to open it,
  and is ignored ([#169](https://github.com/vocaro/EPUBLib/issues/169)).
- **Archive.** The last end record in the file decides which archive is read, so bytes after a book
  are passed over, however many, when they hold no end record's signature: a page a download was
  wrapped in. Another archive after the book ends in one, and that record is followed with its
  offsets counted from the file's first byte. An archive written with such offsets is read in the
  book's place. One whose offsets count from its own first byte sends the reading into the book
  before it: the file is refused unless a directory lies there, as it does when the same file is
  run on twice. Where more bytes follow than a comment could hold, the archive is taken to end with
  the comment of that last record and is read as it would be with nothing after it. The identity
  and `archiveData` are the whole file's either way. An archive that has other bytes before it as
  well, and more than 65,535 after it, is not looked for. A deflated entry is read by its stream
  and held to its checksum: an uncompressed size its directory misstates is not believed, nor is a
  compressed size that runs past the end of the archive, and the limits count what the entry
  inflates to. The book is still refused when that compressed size is 2^63 bytes or more, or when a
  data descriptor follows the entry and the misstated size places it past the end. A data
  descriptor's sizes are four bytes or eight as its own bytes show: the form whose sizes are its
  directory record's, or else the one that ends where the next local header or the directory
  begins, whatever version the entry is marked with. Where neither tells, the record's sizes are
  taken. A stored entry's limits are checked by that size before it is read
  ([#261](https://github.com/vocaro/EPUBLib/issues/261)). Entries the directory lists that
  cannot be read are left out as files the archive lacks: from a record the end of the archive
  cuts short, one whose local header offset names no local header, or an encrypted entry,
  through the last the end record counts, and any records after the last it counts. The
  publication's `lostEntries` gives how many were lost and the paths of those whose records
  can still be read; it is nil when none was. A lost entry whose name the language-encoding flag
  declares UTF-8 and that is not, which refuses an entry that is read, is counted and has no
  path among them ([#779](https://github.com/vocaro/EPUBLib/issues/779)). The entries after a
  damaged record are not recovered. An end record that counts more records than the directory
  holds loses none.
  Directory entries have no extracted payload: misstated directory sizes do not refuse the
  book or count toward expanded-byte limits. ZIPFoundation's entry classification, read from the
  entry's directory record with its closing `/` found by byte (#207), decides that exemption
  after structural header and descriptor bounds have been checked; file sizes remain guarded
  before any extraction ([#260](https://github.com/vocaro/EPUBLib/issues/260)).
  Opening also bounds repeated input work: local headers may account for at most the archive's
  byte count, and extraction processing steps are charged one 32 KiB chunk each against the
  archive's bytes, actual expanded bytes, and one partial chunk per entry. A reused or overlapping
  header or stream is read while that budget holds; declared compressed-range overlap alone is
  not refused. Exceeding the budget throws `limitExceeded("archive input work")`.
  The directory pre-scan charges the exact size of each local header (30 fixed bytes plus its
  name and extra field) against the archive's byte count. Real, separate headers fit that
  budget; repeated large headers cannot multiply copying and ZIP64 field scans indefinitely
  ([bounding archive work](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#bound-archive-work-by-decoder-calls-not-by-output-alone)).
  A deflated entry is inflated with zlib, the system's, not by ZIPFoundation 0.9.20, whose
  decoder is
  [not deterministic on damaged streams](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#apples-compression-inflater-is-not-deterministic-on-damaged-streams)
  ([#583](https://github.com/vocaro/EPUBLib/issues/583)). zlib refuses such a stream as damage, `invalidArchive("<path>: corruptedData")`, on every
  open, as it does a stream cut short of its end. ZIPFoundation reads stored entries.
  The inflater calls the consumer after every call to zlib's `inflate`, including steps that
  produce no output. Each call uses at most 32 KiB of input and returns at most 32 KiB of
  output. Extraction therefore charges 32 KiB per consumer call, credits actual expanded bytes,
  and grants one 32 KiB allowance per entry for a partial final chunk. After admitting E
  entries and producing O bytes from an archive of A bytes, successful calls are bounded by
  `floor((A + O) / 32768) + E`. The existing entry-count and output limits still apply. The
  same consumer is used for stored data, whose full chunks cost no extra input work and whose
  final partial chunk uses the entry allowance. `zlib.h` says `inflate` continues until its
  input is used up, its output is full, or the stream ends. Full output chunks pay for their
  call entirely; input-exhausting partial output calls are covered by archive bytes, with the
  entry allowance covering the final partial input/output chunk. This is a bound on processing
  steps, not a claim to observe the decoder's exact input offset. It stops repeated empty
  streams and streams shared through distinct headers while continuing to read early-ended
  streams and declared sizes beyond the archive. Refusing declared overlap would contradict
  the read-past decision for misstated Deflate sizes
  ([#219](https://github.com/vocaro/EPUBLib/issues/219), [#171](https://github.com/vocaro/EPUBLib/issues/171)). The release measurements, without the bound and with it,
  are on [#199](https://github.com/vocaro/EPUBLib/issues/199#issuecomment-6159294787), and [testing](testing.md#archive-input-work-probe) has the probe
  that repeats them.
- **Container.** White space around the mimetype's media type and a byte-order mark before it are
  ignored. A rootfile that is not typed as a package document is passed over for the first that
  is. An entry name may hold a colon, as it may the other characters OCF forbids.
- **Fonts.** The unique identifier is the `dc:identifier` that the package's `unique-identifier`
  names; a package without the attribute, or whose attribute names no identifier, has none.
  IDPF's obfuscation key is made from it alone, and there is none when the package has no unique
  identifier or a blank one, nothing but the spaces, tabs and line ends the key leaves out. No
  other identifier is tried: any text makes a key, so a wrong one cannot be told from the right
  one ([#530](https://github.com/vocaro/EPUBLib/issues/530)). Adobe's key is read from a UUID
  with or without hyphens, in the unique identifier or else the first identifier that is one, and
  there is none when no identifier is a UUID. Under either algorithm, a font obfuscated with a key
  the package does not give is left out of `resources` and the book opens: a font is a file named
  as one (`.otf`, `.ttf`, `.woff`…) or declared with a font media type. Anything else obfuscated
  that way is unsupported encryption.
- **XML.** In the container, package, navigation and NCX documents, HTML's named character
  references and a `DOCTYPE` keyword in any case are read as a browser reads them in content:
  a name in the HTML Standard's table (`&nbsp;`, `&rcaron;`), which the viewer and text
  extraction read too, is its characters, and a name it lacks (`&bogus;`) is the text it spells,
  in an element and in an attribute value, with no document refused for one
  ([#184](https://github.com/vocaro/EPUBLib/issues/184)). In a document that is not UTF-16 or
  UTF-32, both are left as the parser finds them when its XML declaration is written in EBCDIC,
  names an encoding that is not on a fixed list of those that keep every byte below 0x80 as
  ASCII (UTF-8, US-ASCII, ISO 8859, Windows 874 and 1250 to 1258, KOI8-R, Mac OS Roman, TIS-620,
  EUC-JP, EUC-KR and GB2312), or neither names one nor ends within the document's first 1,024
  bytes. There the parser drops every named reference beyond XML's five under a DOCTYPE that
  names an external subset, and refuses the document for one without such a DOCTYPE or with
  `standalone="yes"`: so a Shift_JIS, GBK or Big5 document still loses `&eacute;` from a title
  or label, or is not read, as does one that names EUC-KR `ks_c_5601-1987` or `korean`, which the
  parser reads as Windows 949. A C0 control character XML forbids, copied from PDF text into a title, reads as a
  space in an ASCII-compatible document, and so as one of the run of whitespace it stands in.

`EPUBWriting` holds what it writes to the stricter rules: a path with a colon is refused, and so
is a navigation or stylesheet href with white space round it, a query, a leading `/` or a step
above the root. Either href is written as the declared path it was checked against, not as it
was spelled. The package
does not otherwise repair malformed EPUBs, validate the full EPUB specification, synthesize page numbers
or provide DRM support. Standard IDPF
and Adobe font obfuscation are decoded for resource access, including the viewer's embedded fonts. Media overlays,
TTS and annotation persistence are outside the initial API. The headless publication model enumerates no
search results; a reader session lists them as rendered (`EPUBSearchResults`, see [reader controls](reader-controls.md#search-results)).

### Accessibility metadata

`metadata.accessibility` (`EPUBAccessibilityMetadata`) holds the accessibility metadata the
package declares ([#676](https://github.com/vocaro/EPUBLib/issues/676)): the discovery
properties of [EPUB Accessibility 1.1](https://www.w3.org/TR/epub-a11y-11/) §2.2
(`schema:accessMode`, `schema:accessModeSufficient`, `schema:accessibilityFeature`,
`schema:accessibilityHazard`, `schema:accessibilitySummary`) and its conformance and evaluator
properties of §3.5 (`dcterms:conformsTo`, `a11y:certifiedBy`, `a11y:certifierCredential`,
`a11y:certifierReport`). These are what the
[Accessibility Metadata Display Guide 2.0](https://w3c.github.io/cg-reports/publishingcg/CG-FINAL-a11y-display-guidelines-20250422/)'s
[EPUB techniques](https://www.w3.org/community/reports/publishingcg/CG-FINAL-epub-techniques-20250422/)
read, so a host can work out each of the guide's fields from them: "Appearance can be modified"
from the feature `displayTransformability`, "Readable in read aloud or dynamic braille" from a
lone `textual` access mode or sufficient set, the hazards, the summary, and "No information is
available" where `isEmpty`. The guide's other input, whether the book is fixed layout, is the
spine items' `layout`. The library words none of it; a view that does is
[#808](https://github.com/vocaro/EPUBLib/issues/808).

- **Forms.** A property is read from EPUB 3's `meta property=` and from EPUB 2's
  `meta name= content=`, in a package of either version and in the `x-metadata` element OPF 2.0.1
  deprecates, and a claim, a credential or a report also from a `link` whose `rel` names it
  (EPUB Accessibility 1.1 §4 and §3.5.3.4; EPUBCheck allows a credential so). A text
  property is not read from a link. A property the package writes in EPUB 3's form is read from
  that form alone, so that a package repeating it as an EPUB 2 `meta` for older readers lists it
  once; one written only in EPUB 2's form is read from that.
- **Values.** Each is read as a Dublin Core value is, its ASCII whitespace stripped from its ends
  and collapsed, and one left empty is not listed. Every value is kept as written: in document
  order, in its own case, with its repeats, and whether or not the vocabulary defines it, such as
  the techniques' own `noflashingHazard`. A `schema:accessModeSufficient` is a set of modes, its
  value split at each comma and each mode without the spaces round it, so `textual, visual` is
  `["textual", "visual"]`; an empty item, and a set with none, is left out. No other value is
  split. A link's value (`EPUBMetadataValue.isLink`) is its URL: a remote one as written, without
  the white space round it, and one to a file in the book the archive-relative reference it
  resolves to from the package document, as a landmark's is, for a session to navigate to. A link
  that names no path an entry can have is not read.
- **Refinements.** The lists hold primary expressions, those without a `refines`. A claim holds
  the certifiers that refine it, a certifier the credentials and reports that refine it, and each
  of them the other properties that refine it as `refinements`, such as the `dcterms:date` of an
  evaluation (§3.5.3.2), in document order whatever order the package writes them in. A `refines`
  is read as a fragment, `#` and an ID, percent-decoded, and matches an element's `id` read as an
  XML ID, by code unit. A certifier, credential or report that refines nothing, as in EPUB 2,
  which has no `refines`, is listed on its own (`certifiers`, `certifierCredentials`,
  `certifierReports`). An expression that refines anything else is a subexpression about what it
  refines, not the book (EPUB 3.3 §5.5.4), and is not read: accessibility metadata about a manifest item, one that
  refines an ID the package lacks or a claim that itself refines something.

Its limits:

- A property is known by its name as written with its reserved prefix, as the guide's techniques
  match it; EPUB Reading Systems 3.3 §11 allows a reading system to read property values as plain
  strings. The package's `prefix` attribute is not read, so a property written with another
  prefix mapped to schema.org is not read, and one whose reserved prefix the package maps
  elsewhere is read as the reserved vocabulary's.
- Only these nine properties are read. `a11y:exemption`, which the guide's legal considerations
  field reads (#808), `a11y:contactEmail`, and the deprecated `schema:accessibilityAPI` and
  `schema:accessibilityControl` are not. Neither is a `collection`'s own metadata, nor a linked
  record (§2.3).
- A `meta` with a `property` is read by its text, not by a `content` attribute some books put on
  it.
- `EPUBWriting` does not write `accessibility` ([#809](https://github.com/vocaro/EPUBLib/issues/809)).

## Engine contract

An engine constructs a session with a publication, optional selection action and event callback.
The session creates an `AnyView`, accepts typed commands, advertises capabilities and closes its
resources. An implementation can return any SwiftUI/AppKit/UIKit-backed view; `NativeEngineTests`
implements a minimal one using only SwiftUI and the public contract.

`send` acknowledges command submission, not successful navigation or paint completion
([submission is not completion](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/command-lifecycles.md#command-submission-is-not-completion)).
Later position/error events describe effects. Cancellation before submission throws `CancellationError`;
a submitted page turn cannot be undone by cancelling its caller. `close` is idempotent, disables
callbacks and releases renderer references. Hosts serialize commands whose order matters and close
sessions explicitly. Views returned by a closed session contain no reader. Public readiness is
emitted exactly once; later fidelity disclosures do not restart the session lifecycle.

Portable location fields contain the publication's `persistentID`, section href, text quote, overall
progression and the page-list entries the range shows when known. Resource `href`, navigation
hrefs and location hrefs are encoded URL references; resource `path` is the decoded archive key. Exact restoration uses a separately tagged engine bookmark. The reader's
`epublib-cfi-v1` bookmark is accepted only for a location that carries one of the publication's
`publicationIDs`, and for the engine identifier.
Other engines may offer approximate navigation by href or quote; this is not automatic bookmark
conversion. The package does not promise cross-engine page, search or selection equivalence.

The pages of an engine's own layout are status, not location: an engine that counts them sets
`EPUBReaderStatus.layoutPage` in paginated flow, before the `.relocated` of the same pages, and
leaves it nil while it counts. `.goToProgression` takes the measure of `EPUBLocation.progression`,
so a host can send back a progression it was given; an engine without it refuses the command
with `.unsupported(.goToProgression)`, which the [contract checks](testing.md#adapter-contract-tests)
hold every adapter to ([#681](https://github.com/vocaro/EPUBLib/issues/681)).

## Viewer isolation

Books are untrusted and nothing in them executes: the viewer has no JavaScript engine and no web
view. Content documents parse with libxml2 after `XMLSafety` refuses entity declarations and
internal DTD subsets. The screen decodes declared legacy encodings with libxml2's own
converters, including UTF-7, SCSU and EBCDIC, before inspecting markup; ambiguous switches from
an initially detected wide encoding are refused. Attribute occurrences are capped at 1,024 per
element before strict or recovery parsing, including duplicates and namespace declarations;
named HTML entities become numeric references, DTDs and the network are
never loaded, and depth and node counts are bounded. Markup that is not well-formed is read with
libxml2's forgiving HTML parser rather than refused. CSS, fonts, MathML and images are parsed with
their own bounds. Every reference resolves inside the archive snapshot, but for an image in a
`data:` URL, which is read from the URL's own bytes; remote images, stylesheets,
fonts and media are never fetched, a web or email link outside the book is opened only after
the reader agrees and any other is refused with a notice
([links outside the book](native-viewer.md#security)), and `script`
elements are counted and disclosed but never run. Sandboxed macOS hosts need no network entitlement.
The general method is in
[screening untrusted markup](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#screen-untrusted-markup-before-any-parser-sees-it).

The viewer renders reflowable EPUB on iOS/iPadOS and macOS 27 with TextKit 2: continuous scroll
in one real scroll view over the whole book, and paginated columns sliced from one layout per
column width. Fixed-layout spine items render as reflowable text and vertical writing renders
horizontally, each with a `.disclosure`; sessions advertise every capability. Tests cover
reflowable, fixed-layout, RTL, vertical-writing, escaped-filename and illustrated synthetic books,
CFIs recorded from foliate-js, and real-book qualification runs (see [native viewer](native-viewer.md)).
This is regression coverage, not a general fidelity guarantee. Host apps must present
`.disclosure` and `.failed` events appropriately and may provide their own fallback.
Adapter-contract tests verify session behavior; rendering fidelity stays with the viewer tests.

## Structural text

The [text-extraction API](text-extraction.md) reads one spine occurrence at a time from the
validated snapshot. Apple’s streaming libxml2 reader preserves literal and numeric-reference
U+FEFF word joiners that Foundation XMLParser drops in character callbacks
([parser choice](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#parser-choice-can-change-text)). External DTD loading,
entity substitution and networking are disabled. Limits and cancellation bound the walk.
The library reports all semantic roles and empty/nonlinear sections; filtering and indexing belong
to the host. No third-party dependency is added for text extraction.
