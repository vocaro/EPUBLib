# Text extraction

The publication API exposes text without creating a reader, running JavaScript, or choosing an
indexing policy. It operates on the same validated, immutable snapshot as a reading engine.

<!-- snippet:extraction -->
```swift
func readSectionText(from url: URL) throws -> [EPUBTextSection] {
    let book = try EPUBPublication.open(at: url)
    return try book.spine.indices.map { try book.textSection(at: $0) }
}
```
<!-- /snippet -->

For large books, consume each section inside the loop instead of collecting all text in memory.


## Contract

`EPUBTextSection` is a `Sendable`, `Equatable` value containing `spineIndex`, `resource`,
`isLinear`, optional `title`, `text`, `semanticTypes: Set<String>`, `anchors` and `headings`. The index identifies the
exact spine occurrence, even when a resource repeats. The resource's encoded `href` is suitable
for navigation; its decoded `path` is suitable for resource access. Titles come from XHTML's
`head/title`; an absent or empty title is `nil`, leaving fallback naming to the host.

`EPUBPublication.textSection(at:limits:) throws` extracts one entry on demand. It returns empty
text for an image-only XHTML section and retains nonlinear entries and all semantic roles.
It supports XHTML resources (`application/xhtml+xml`); other spine media types fail explicitly.
Semantic types are the whitespace-separated tokens on EPUB-namespace `type` attributes throughout
that section's body, including nested sections. They describe author markup; they are neither
trusted classifications nor instructions, and are not inferred from filenames or prose.

Text includes body character data in document order, joins inline markup without inserting spaces
inside words, and separates common block elements and line breaks. Script, style and template
subtrees are excluded. XML entities and CDATA are decoded. Whitespace is normalized to single spaces
within lines and single newlines at block boundaries. This is structural text extraction, not a
browser's computed visible-text representation: CSS layout, generated content, image OCR and
external resources are not evaluated. No page numbers or engine-specific bookmarks are invented.

`EPUBTextExtractionLimits` bounds input bytes (default 4 MiB), UTF-8 bytes per output field (8 MiB), nesting
(64 elements) and element count (100,000) per section. Callers processing a whole book enforce
their own cumulative text budget while iterating. `CancellationError` propagates during parsing.
`EPUBTextExtractionError` distinguishes invalid spine indices, unsupported media types, malformed
XHTML and exceeded limits. Malformed markup, entity declarations and internal DTD subsets fail;
there is no regex fallback that could turn scripts or styles into study text. Ordinary external
DOCTYPE identifiers are allowed but never fetched or resolved. Declaration-looking examples inside
comments, CDATA or processing instructions are inert; the safety check follows XML lexical context.

Hosts own section inclusion, chunking, embeddings, persistence and citation policy. Extracting a
colophon is valid library behavior; whether it belongs in a study index is the host's decision.

## Positions

`anchors` maps the first occurrence of each body element ID to an `EPUBTextMark`. `headings`
contains each XHTML heading in document order, with normalized text and its mark. A mark's
`offset` counts UTF-8 bytes to the first text character after the element opens; `separator`
counts the normalized space or newline immediately before that character. An empty element
with no following text marks the document end. Script/style/template subtrees contribute neither
text nor anchors. Text and positions are emitted by the same bounded walk, so consumers never
need to replicate normalization to locate sections. Hosts decide which navigation entries or
headings form meaningful study sections.
