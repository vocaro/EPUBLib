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
internal `MathMLLayout` target, never EPUBText or EPUBWriting. `MathMLLayout` lays out
presentation MathML with CoreText; it imports no EPUBLib module or UI framework, so it can move
to its own package. EPUBWriting depends only on EPUBCore and ZIPFoundation, never EPUBReading or
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
Archive paths are decoded ZIP paths; manifest/navigation hrefs are URL references. The parser
resolves references relative to the containing OPF/navigation document. It exposes metadata,
manifest resources, linear/nonlinear spine entries with rendition layout, cover and nested contents. Reading resource
bytes does not execute document content. XML expansion and external entity resolution are refused. Declaration screening distinguishes
actual DTD syntax from comments, CDATA, processing instructions and quoted identifiers; it decodes
UTF-16/32 input before inspecting markup.

Default limits are 256 MiB compressed, 512 MiB expanded, 32 MiB per resource, 20,000 entries and
4 MiB per XML document, with depth/node limits. Hosts may lower or raise import limits. Resources
are retained in memory; the total memory footprint includes both compressed and expanded data.
For large books, open on a background task. Task cancellation is checked while expanding entries.
The optional import progress callback receives cumulative expanded bytes on that task's thread.
A host granting security-scoped file access must keep access active until opening completes.

Inputs need an EPUB mimetype, a container rootfile and a nonempty resolvable spine. Remote manifest
resources, unsupported encryption, archive traversal, duplicate paths, symlinks, entity declarations
and malformed metadata/navigation XML fail explicitly. The package does not repair malformed EPUBs,
validate the full EPUB specification, synthesize page numbers or provide DRM support. Standard IDPF
and Adobe font obfuscation are decoded for resource access, including the viewer's embedded fonts. Media overlays,
TTS, annotation persistence and full-text search result enumeration are outside the initial API.

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

Portable location fields contain the publication fingerprint, section href, text quote and overall
progression when known. Resource `href`, navigation hrefs and location hrefs are encoded URL
references; resource `path` is the decoded archive key. Exact restoration uses a separately tagged engine bookmark. The reader's
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
