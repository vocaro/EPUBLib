# Writing

Import `EPUBCore` and `EPUBWriting`. `EPUBPackageWriter.documents` accepts explicit
`EPUBPackageMetadata`, manifest resources, spine entries, nested contents and an optional page
list. It returns navigation XHTML, OPF, container XML and the exact mimetype. The package is
EPUB 3, reflowable by default, with optional fixed-layout spine overrides. Resource paths and
navigation hrefs are archive-relative; package documents live under `EPUB/`. IDs and paths must
be unique, spine resources must be declared and navigation must resolve to a declared resource.

The producer supplies content XHTML, CSS and media. It owns chapter division, content styles,
source-page decisions and document reconstruction. Metadata and navigation are XML escaped
once by the writer. The caller chooses a stable identifier and modification date for reproducible
output; package generation does not invent document facts.

Write prepared documents and content into staging, then call `EPUBArchiveWriter.write` with
ordered file-backed entries, placing `mimetype` first. It stores the exact mimetype uncompressed,
deflates other entries, checks cancellation between entries and archive chunks, enforces the
uncompressed content-byte budget and removes an unfinished archive on failure or cancellation.
The destination must be a new local file. Progress runs in order from zero through one; consumer
publication/atomic destination handling happens after writing.

Entries default to preserving caller-owned files. `consume: true` permits deletion after a
file's final referring entry; a non-consuming reference keeps a shared file alive. A producer
owns and cleans up its workspace. The archive writer does not import PDFKit, Vision, SwiftUI,
WebKit, a reconstruction model or a reader.
