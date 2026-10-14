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
[MathMLLayout](https://github.com/vocaro/MathMLLayout) package (pinned exactly, like
ZIPFoundation), never EPUBText or EPUBWriting. MathMLLayout lays out presentation MathML with
CoreText and imports no EPUBLib module or UI framework. EPUBWriting depends only on EPUBCore and ZIPFoundation, never EPUBReading or
viewing. The adapter-contract helper is an internal test-support target, not a library product.

Source API compatibility with the former package is not a constraint. Publication fingerprints
retain their existing meaning. The reader's engine identifier is `org.epublib.reader` and its
bookmark format `epublib-cfi-v1` (`EPUBReader.identifier`, `EPUBReader.bookmarkFormat`); both name
the library, not a renderer. The WebKit reader's `org.epubreaderlib.foliate`/`epubcfi-v1`
bookmarks are another engine's and are refused, but their CFI values name the same positions:
a host migrates one by re-tagging it with the reader's identifier and format. The sample EPUB
remains byte-for-byte unchanged.

## Publication model

Opening copies the archive into a bounded snapshot and checks every archive entry before returning.
Archive paths are decoded ZIP paths; the container's rootfile path and manifest/navigation hrefs
are URL references. An entry's name is read as UTF-8 when its bytes are well-formed UTF-8, with or
without the ZIP language-encoding flag (general-purpose bit 11), which `zip` and `ditto` on a Mac
leave clear; any other name is read as code page 437, or refused when the flag calls it UTF-8.
The parser resolves the rootfile path from the container root and other
references relative to the containing OPF/navigation document. A rootfile path that is refused as
a URL or names no entry that way (a name's own `%`, `#` or `?` left unescaped, as older validators
required) is read as the archive path it is written as when that is a safe path naming an entry;
with an entry under each reading, the URL's is the package document. It exposes metadata,
manifest resources, linear/nonlinear spine entries with rendition layout, cover, nested contents,
landmarks (the EPUB 2 guide's references when there are none) and the page list (the NCX's
`pageList` when the navigation document has none). Reading resource
bytes does not execute document content. XML expansion and external entity resolution are refused. Declaration screening distinguishes
actual DTD syntax from comments, CDATA, processing instructions and quoted identifiers; it decodes
UTF-16/32 input before inspecting markup.

A metadata value and a navigation label are read as text: the element's and that of everything
inside it, with each run of ASCII whitespace (tab, line feed, form feed, carriage return, space)
as one space and none left at either end. EPUB Reading Systems 3.3 §5.3 requires that of Dublin
Core and `meta` values, and it is how a browser renders a link, so a title or a label its
authoring tool wrapped and indented is one line. The values are the Dublin Core title, creators,
languages and identifiers and the `rendition:layout` `meta`; the labels are a contents entry's
link or heading, a landmark's link, a page-list link and an NCX `navLabel`. White space outside
ASCII, a no-break or an ideographic space among it, is the author's character and is kept
inside and at the ends of a value that holds anything else, but a value that is nothing but
white space of any kind (Foundation's `whitespacesAndNewlines`, which counts the zero-width
space) is empty: some tools write a lone no-break space as a placeholder, and no host can show
one. A value left empty is not listed among the metadata; an entry whose label is left empty
stays, without a title. `xml:space` changes nothing. ASCII whitespace is
found as its byte, not by `Character`: a space followed by a combining mark is a space, and the
mark is kept. An attribute's value is not such text, and a guide reference's `title` is read as
written. A font obfuscation key is made from the identifier's text by its algorithm's own rule,
not from the value read here.

A path the reader keeps is relative and made of names separated by single `/`: no name is empty,
`.` or `..`, and the path holds no backslash or NUL. Entry names, the rootfile path and the path
of every resolved reference are held to that. A delimiter in a path or a reference is found as
its byte, as an archive and a file system read it, not by `Character`: a `/`, `\`, `:`, `#`, `?`
or `.` followed by a combining mark, variation selector or joiner, or preceded by a prepended
mark such as U+0600, is still that delimiter or dot. So `../` followed by U+0301 and a name is a
`..` segment followed by a name that begins with the mark, and `a/` followed by U+0301 and `b` is
the name `a` followed by a second name that begins with it. Paths are compared as Swift strings,
by canonical equivalence, so a name's precomposed and decomposed forms are one path: an entry
answers to a reference in either normalization form, and two entry names equal after
normalization are duplicates.

Default limits are 256 MiB compressed, 512 MiB expanded, 32 MiB per resource, 20,000 entries and
4 MiB per XML document, with depth/node limits. Hosts may lower or raise import limits. Resources
are retained in memory; the total memory footprint includes both compressed and expanded data.
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
begin so and hold no end record are refused after one search through them in memory.

Faults that leave a book readable are read past instead. The publication model has no channel for
warnings, so this list is where they are disclosed:

- **References.** No reference leaves the container: a leading `/` names the container root and
  `..` stops there (EPUB Reading Systems 3.3 §4.1.1). A query is dropped. The container's rootfile
  path is the exception: it names the package document or nothing, and is refused in these forms.
- **Manifest.** An item repeated verbatim counts once. An item whose file the archive lacks and a
  remote item, which is never fetched, are left out of `resources`; the spine still needs every
  document it names. An href that matches no entry names the one entry that differs only in case,
  when there is exactly one.
- **Contents.** An entry whose href does not resolve keeps its title and children, without an
  href. A landmark or page that does not resolve is left out.
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
  data descriptor follows the entry and the misstated size places it past the end.
  Opening also bounds repeated input work: local headers may account for at most the archive's
  byte count, and extraction processing steps are charged one 32 KiB chunk each against the
  archive's bytes, actual expanded bytes, and one partial chunk per entry. A reused or overlapping
  header or stream is read while that budget holds; declared compressed-range overlap alone is
  not refused. Exceeding the budget throws `limitExceeded("archive input work")`.
  The directory pre-scan charges the exact size of each local header (30 fixed bytes plus its
  name and extra field) against the archive's byte count. Real, separate headers fit that
  budget; repeated large headers cannot multiply copying and ZIP64 field scans indefinitely.
  ZIPFoundation 0.9.20's Apple decoder calls the consumer after every
  `compression_stream_process`, including steps that produce no output. Each call uses at most
  32 KiB of input and returns at most 32 KiB of output. Extraction therefore charges 32 KiB per
  consumer call, credits actual expanded bytes, and grants one 32 KiB allowance per entry for a
  partial final chunk. After admitting E entries and producing O bytes from an archive of A
  bytes, successful calls are bounded by `floor((A + O) / 32768) + E`. The existing entry-count
  and output limits still apply. The same consumer is used for stored data, whose full chunks
  cost no extra input work and whose final partial chunk uses the entry allowance. The SDK's
  `compression.h` contract says a successful processing call continues until its source is
  exhausted, destination is full, or stream ends. Full output chunks pay for their call
  entirely; input-exhausting partial output calls are covered by archive bytes, with the entry
  allowance covering the final partial input/output chunk. This is a bound on processing
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
- **Fonts.** Adobe's obfuscation key is read from a UUID with or without hyphens, in the unique
  identifier or else the first identifier that is one. A font obfuscated with a key the package
  does not give is left out of `resources`: a font is a file named as one (`.otf`, `.ttf`,
  `.woff`…) or declared with a font media type. Anything else obfuscated that way is unsupported
  encryption.
- **XML.** In the container, package, navigation and NCX documents, HTML's named character
  references (`&nbsp;`) and a `DOCTYPE` keyword in any case are read as a browser reads them in
  content. In a document that is not UTF-16 or UTF-32, both are left as the parser finds them
  when its XML declaration is written in EBCDIC, names an encoding that is not on a fixed list
  of ASCII-compatible ones, or neither names one nor ends within the document's first 1,024
  bytes. A C0 control character XML forbids, copied from PDF text into a title, reads as a
  space in an ASCII-compatible document, and so as one of the run of whitespace it stands in.

`EPUBWriting` holds what it writes to the stricter rules: a path with a colon is refused, and so
is a navigation href with a query, a leading `/` or a step above the root. The package does not
otherwise repair malformed EPUBs, validate the full EPUB specification, synthesize page numbers
or provide DRM support. Standard IDPF
and Adobe font obfuscation are decoded for resource access, including the viewer's embedded fonts. Media overlays,
TTS and annotation persistence are outside the initial API. The headless publication model enumerates no
search results; a reader session lists them as rendered (`EPUBSearchResults`, see [reader controls](reader-controls.md#search-results)).

## Engine contract

An engine constructs a session with a publication, optional selection action and event callback.
The session creates an `AnyView`, accepts typed commands, advertises capabilities and closes its
resources. An implementation can return any SwiftUI/AppKit/UIKit-backed view; `NativeEngineTests`
implements a minimal one using only SwiftUI and the public contract.

`send` acknowledges command submission, not successful navigation or paint completion. Later
position/error events describe effects. Cancellation before submission throws `CancellationError`;
a submitted page turn cannot be undone by cancelling its caller. `close` is idempotent, disables
callbacks and releases renderer references. Hosts serialize commands whose order matters and close
sessions explicitly. Views returned by a closed session contain no reader. Public readiness is
emitted exactly once; later fidelity disclosures do not restart the session lifecycle.

Portable location fields contain the publication fingerprint, section href, text quote, overall
progression and the page-list entries the range shows when known. Resource `href`, navigation
hrefs and location hrefs are encoded URL references; resource `path` is the decoded archive key. Exact restoration uses a separately tagged engine bookmark. The reader's
`epublib-cfi-v1` bookmark is accepted only for the same publication fingerprint and engine identifier.
Other engines may offer approximate navigation by href or quote; this is not automatic bookmark
conversion. The package does not promise cross-engine page, search or selection equivalence.

## Viewer isolation

Books are untrusted and nothing in them executes: the viewer has no JavaScript engine and no web
view. Content documents parse with libxml2 after `XMLSafety` refuses entity declarations and
internal DTD subsets; named HTML entities become numeric references, DTDs and the network are
never loaded, and depth and node counts are bounded. Markup that is not well-formed is read with
libxml2's forgiving HTML parser rather than refused. CSS, fonts, MathML and images are parsed with
their own bounds. Every reference resolves inside the archive snapshot; remote images, stylesheets,
fonts and media are never fetched, external links are refused with a notice, and `script`
elements are counted and disclosed but never run. Sandboxed macOS hosts need no network entitlement.

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
U+FEFF word joiners that Foundation XMLParser drops in character callbacks. External DTD loading,
entity substitution and networking are disabled. Limits and cancellation bound the walk.
The library reports all semantic roles and empty/nonlinear sections; filtering and indexing belong
to the host. No third-party dependency is added for text extraction.
