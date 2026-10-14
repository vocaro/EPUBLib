# Writing

Import `EPUBCore` and `EPUBWriting`. `EPUBPackageWriter.documents` accepts explicit
`EPUBPackageMetadata`, manifest resources, spine entries, nested contents and an optional page
list. An empty page list is omitted from navigation. It returns navigation XHTML, OPF, container
XML and the exact mimetype. The package is
EPUB 3, reflowable by default, with optional fixed-layout spine overrides. Resource paths and
navigation hrefs are archive-relative; package documents live under `EPUB/`. IDs and paths must
be unique, spine resources must be declared and navigation must resolve to a declared resource.

The producer supplies content XHTML, CSS and media. It owns chapter division, content styles,
source-page decisions and document reconstruction. Metadata and navigation are XML escaped
once by the writer, scalar by scalar: `&`, `<`, `>` and both quotes are escaped whatever stands
beside them, a combining mark included, and no value is normalized. A character XML 1.0 cannot
hold (a C0 control character other than tab, line feed and carriage return, U+FFFE or U+FFFF) is
left out. A reader does normalize what it reads: `EPUBReading`, as EPUB Reading Systems 3.3 §5.3
requires, reads a metadata value or a label with each run of ASCII whitespace as one space and
none at its ends, so a title given with a tab, a line end, doubled spaces or a space at an end
is written as given and does not read back as given. Nor does one given as nothing but white
space of any kind, a lone no-break space included: it is written, and read back as empty. The
caller chooses a stable identifier and modification date for reproducible output; package
generation does not invent document facts.

Every metadata language and identifier is written in its supplied order, including duplicates.
The navigation document uses the first language; an empty language list writes `und`.
`EPUBPackageMetadata.identifier` selects the package's unique identifier: its first byte-identical
entry in the metadata list receives `id="book-id"`, or it is prepended when absent. This keeps
additional identifiers and avoids adding another copy when a publication's metadata is written
again ([#95](https://github.com/vocaro/EPUBLib/issues/95)).

Write prepared documents and content into staging, then call `EPUBArchiveWriter.write` with
ordered file-backed entries, placing `mimetype` first. It stores the exact mimetype uncompressed,
deflates other entries, checks cancellation between entries and archive chunks, enforces the
uncompressed content-byte budget and removes an unfinished archive on failure or cancellation.
The destination must be a new local file. Progress runs in order from zero through one; consumer
publication/atomic destination handling happens after writing.

Entries default to preserving caller-owned files. `consume: true` permits deletion after a
file's final referring entry; a non-consuming reference keeps a shared file alive even when
entries use different spellings of its path. Source symbolic links are read in full, and their
target's size counts against the byte budget; consuming a link removes the link alone. A producer
owns and cleans up its workspace. The archive writer does not import PDFKit, Vision, SwiftUI,
WebKit, a reconstruction model or a reader.
