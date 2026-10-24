# Writing

Import `EPUBCore` and `EPUBWriting`. `EPUBPackageWriter.documents` accepts explicit
`EPUBPackageMetadata`, manifest resources, spine entries, nested contents and an optional page
list. An empty page list is omitted from navigation. It returns navigation XHTML, OPF, container
XML and the exact mimetype. The package is
EPUB 3, reflowable by default, with optional fixed-layout spine overrides. Resource paths and
navigation hrefs are archive-relative; package documents live under `EPUB/`. IDs and paths must
be unique, spine resources must be declared and navigation must resolve to a declared resource.
A resource ID must be an XML name without a colon, as an `id` and `idref` are, and may not be
`nav` or `book-id`, the IDs the writer gives its own navigation item and unique identifier; a
resource's media type may not be empty. The writer refuses any other resource, with
`"duplicate or invalid resource: "` and its path, rather than rewrite its ID, so what is read back
is the resource that was given ([#96](https://github.com/vocaro/EPUBLib/issues/96)). A name is
held to the character classes of XML 1.0 before its fifth edition (Appendix B), as libxml2 and
EPUBCheck's validator hold it, character for character. The fifth edition's wider classes also
take an ID such as `ⅰ`, `a‿b` or one with a character outside the Basic Multilingual Plane, which
EPUBCheck refuses.
A navigation or stylesheet href is written as the declared path it resolves to, relative to the
navigation document and percent-encoded as that path's manifest href is, not as it was spelled:
`EPUB//one.xhtml`, `EPUB/./one.xhtml` and `EPUB/c:x/../one.xhtml` are each written `one.xhtml`.
A target is checked by that path alone, not by its spelling: `x/../EPUB/one.xhtml`,
`%45PUB/one.xhtml` and `EPUB/../EPUB/one.xhtml` are accepted and written `one.xhtml` too, and one
that resolves outside `EPUB/`, as `EPUB/../mimetype` does, is refused however it is spelled
([#606](https://github.com/vocaro/EPUBLib/issues/606)).
A `..` after a doubled slash removes the empty segment, as URL parsing and the reader read it, so
`EPUB/a//../one.xhtml` is written `a/one.xhtml` ([#605](https://github.com/vocaro/EPUBLib/issues/605)).
A target is matched to a declared path by canonical equivalence, so one spelled with a decomposed
`é` for a path declared with a composed one is written as the manifest writes the declared path;
its fragment is percent-encoded and otherwise kept as given ([#240](https://github.com/vocaro/EPUBLib/issues/240)).

A resource may supply `fallbackID`; the writer emits that manifest relationship and refuses
undeclared targets or cycles ([#78](https://github.com/vocaro/EPUBLib/issues/78)). Resource IDs,
fallback targets and spine items are matched by the IDs' code units, as XML compares IDs:
`caf\u{E9}` and `cafe\u{301}` are two resources, and a spine item or fallback that names a
declared ID only by canonical equivalence is undeclared ([#635](https://github.com/vocaro/EPUBLib/issues/635)).

The producer supplies content XHTML, CSS and media. It owns chapter division, content styles,
source-page decisions and document reconstruction. Metadata and navigation are XML escaped
once by the writer, scalar by scalar: `&`, `<`, `>` and both quotes are escaped whatever stands
beside them, a combining mark included, and no value is normalized. A tab, line feed and
carriage return are written as Canonical XML writes them, so that an XML parser reads each back
as given, where it reads one written as it stands in an attribute value as a space and a carriage
return in text as a line feed: a carriage return in text is written `&#13;`, and a tab, line
feed and carriage return in an attribute value (a media type, a manifest property, the navigation
document's language) `&#9;`, `&#10;` and `&#13;`. A tab and a line feed in text are written as
they are ([#254](https://github.com/vocaro/EPUBLib/issues/254)). A character XML 1.0 cannot
hold (a C0 control character other than tab, line feed and carriage return, U+FFFE or U+FFFF) is
left out. A reader does normalize what it reads: `EPUBReading`, as EPUB Reading Systems 3.3 §5.3
requires, reads a metadata value or a label with each run of ASCII whitespace as one space and
none at its ends, so a title given with a tab, a line end, doubled spaces or a space at an end
is written as given and does not read back as given. The caller chooses a stable identifier and
modification date for reproducible output; package generation does not invent document facts.

A refusal is an `EPUBWritingError`, whose detail names what was refused and whose
`localizedDescription` is a plain message for a person, that the book has errors or is too large
to save as an EPUB ([when something fails](integration.md#when-something-fails)).

No value is written empty. EPUB 3.3 requires each Dublin Core value and each navigation label to
hold something once its ASCII whitespace is stripped, and a value is empty to the writer when,
with what XML cannot hold left out, it is nothing but white space of any kind (Foundation's
`whitespacesAndNewlines`, a lone no-break space included), as the reader reads it as empty
([#96](https://github.com/vocaro/EPUBLib/issues/96)):

- An empty author, language, additional identifier or keyword is left out of its list, and an
  empty summary is left out, as the reader leaves an empty value out of what it reads.
- An empty title or identifier is refused, with `EPUBWritingError.invalidPublication("empty title")`
  or `("empty identifier")`: the package requires each, and the writer invents neither. A book
  read without a title reads back with `title` empty, and needs one before it is written again.
- Contents with no entry are refused (`"empty contents"`): the contents `nav` is required and its
  list needs an entry.
- A contents or page entry with an empty label is refused (`"navigation entry without a label"`,
  followed by its href when it has one), as is one with neither a target nor entries of its own
  (`"navigation entry without a target: "` and its title). The writer leaves no entry out, so
  none is lost without the caller's knowing.

Every metadata language and identifier that is not empty is written in its supplied order,
including duplicates. The navigation document uses the first language; a list with no language
left writes `und`.
`EPUBPackageMetadata.identifier` selects the package's unique identifier: its first byte-identical
entry in the metadata list receives `id="book-id"`, or it is prepended when absent. This keeps
additional identifiers and avoids adding another copy when a publication's metadata is written
again ([#95](https://github.com/vocaro/EPUBLib/issues/95)).

Write prepared documents and content into staging, then call `EPUBArchiveWriter.write` with
ordered file-backed entries, placing `mimetype` first. The `mimetype` entry's source must be
exactly the 20 bytes `application/epub+zip`. Any other content, a trailing line end or space
included, is refused with `EPUBWritingError.invalidPublication("invalid mimetype")` before an
archive is created or a source consumed ([#97](https://github.com/vocaro/EPUBLib/issues/97)).
The entry is written from the bytes checked, and its source is closed after the check and not
read again, so a source appended to or replaced afterwards, while `progress(0)` runs, does not
change the archive ([#604](https://github.com/vocaro/EPUBLib/issues/604)).
It stores the exact mimetype uncompressed, deflates other entries, checks cancellation between
entries and archive chunks, enforces the uncompressed content-byte budget and removes an
unfinished archive on failure or cancellation. The destination must be a new local file.
Progress runs in order from zero through one; consumer publication/atomic destination handling
happens after writing.

Entries default to preserving caller-owned files. `consume: true` permits deletion after a
file's final referring entry; a non-consuming reference keeps a shared file alive even when
entries use different spellings of its path. Source symbolic links are read in full, and their
target's size counts against the byte budget; consuming a link removes the link alone. A producer
owns and cleans up its workspace. The archive writer does not import PDFKit, Vision, SwiftUI,
WebKit, a reconstruction model or a reader.
