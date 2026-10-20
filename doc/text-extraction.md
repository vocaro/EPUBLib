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
`isLinear`, optional `title`, `text`, `semanticTypes: Set<String>`, `anchors`, `headings` and
`recoveredAsHTML`. The index identifies the
exact spine occurrence, even when a resource repeats. The resource's encoded `href` is suitable
for navigation; its decoded `path` is suitable for resource access. Titles come from XHTML's
`head/title`; an absent or empty title is `nil`, leaving fallback naming to the host.

`EPUBPublication.textSection(at:limits:) throws` extracts one entry on demand. An image-only
XHTML section returns its publisher-supplied alternatives, or empty text when none are supplied.
The extraction retains nonlinear entries and all semantic roles.
It supports XHTML resources (`application/xhtml+xml`); other spine media types fail explicitly.
Semantic types are the whitespace-separated tokens on EPUB-namespace `type` attributes throughout
that section's body, including nested sections. They describe author markup; they are neither
trusted classifications nor instructions, and are not inferred from filenames or prose.

Text includes body character data and authored root content following the body in document order,
including trailing headings and anchors on the strict XML path ([#197](https://github.com/vocaro/EPUBLib/issues/197)).
It joins inline markup without inserting spaces
inside words, and separates block elements and line breaks. The block elements are those in the
body that the HTML Standard's Rendering section gives `display: block`: `address`, `article`,
`aside`, `blockquote`, `center`, `dd`, `details`, `dialog`, `dir`, `div`, `dl`, `dt`,
`fieldset`, `figcaption`, `figure`, `footer`, `form`, the headings `h1` to `h6`, `header`,
`hgroup`, `hr`, `legend`, `listing`, `main`, `menu`, `nav`, `ol`, `optgroup`, `option`, `p`,
`plaintext`, `pre`, `search`, `section`, `summary`, `ul` and `xmp`, with `li`, `table`, `tr`,
`td` and `th` ([#90](https://github.com/vocaro/EPUBLib/issues/90)). Each option of a `select`
is therefore a line of its own. A `marquee`, which HTML makes `inline-block`, is not separated.
Script, style and template
subtrees are excluded. XML entities and CDATA are decoded. In recovery, a comment also ends at `--!>`, and an `&#` with no initial decimal or hexadecimal digit stays literal in text and surfaced attributes, matching the native reader ([#244](https://github.com/vocaro/EPUBLib/issues/244)). Whitespace is normalized to single spaces
within lines and single newlines at block boundaries. Whitespace normalization operates on
Unicode scalars, so combining marks following a space or
no-break space remain in body text, headings, image alternatives and MathML text
([#89](https://github.com/vocaro/EPUBLib/issues/89)). This is structural text extraction, not a
browser's computed visible-text representation: CSS layout, generated content, image OCR and
external resources are not evaluated. The text of elements HTML does not display is therefore
included, such as that of `hidden` elements, the content of a closed `details` and a `dialog`
without `open`. No page numbers or engine-specific bookmarks are invented.

Nonempty `alt` attributes on XHTML `img` elements contribute text at the image's source position,
using the same whitespace normalization as surrounding prose. This preserves authored alternatives
for formulas, table headings and exercise items. Missing, empty and whitespace-only alternatives
contribute nothing; `title` attributes are not substituted or duplicated. Alternatives in excluded
script, style and template subtrees are also excluded. Images are never fetched or decoded for
extraction, and missing alternatives are not inferred. An image's ID and any enclosing heading mark
refer to its alternative in the returned UTF-8 text, and subsequent offsets include those bytes.

MathML formulas preserve a nonempty authored `alttext` when present. A `semantics` element can
also supply a textual alternative through an `annotation` encoded as `text/plain`,
`application/x-tex`, `application/x-latex` or `application/x-asciimath`. The selected alternative
appears once, with ordinary whitespace normalization; nonselected annotations are omitted.
Whole-formula alternatives remain literal text, while alternatives within generated notation are
quoted and escaped as child values. Without an alternative, formulas use bounded
structural notation: for example, `math(frac("x", "y"))` and `math(sup("x", "2"))` retain division
and exponent structure. Rows, roots, indices and fences remain explicit; fences retain their opening,
closing and separator attributes. Tokens are quoted, with escaped quotes, backslashes and invisible
math operators. Other elements, presentation attributes and malformed argument counts retain their
tag structure instead of losing grouping. Literal `display="block"` formulas separate surrounding
text with line breaks. No math script, image or external resource is evaluated.

Math IDs and enclosing headings refer to the same returned UTF-8 text. IDs inside an authored
replacement point to that replacement; IDs in structural notation point to their serialized node.
Generated delimiters and escapes count toward the existing output budget and subsequent offsets.

`EPUBTextExtractionLimits` bounds input bytes (default 4 MiB), UTF-8 bytes per output field (8 MiB), nesting
(64 elements) and element count (100,000) per section. A fixed additional safety bound allows
at most 1,024 attribute occurrences on one element, including namespace declarations, duplicate
names and HTML boolean attributes. A linear preflight checks this before strict XML or HTML
parsing; extraction reports `limitExceeded("attributesPerElement")`, and native content parsing
reports the same limit name. Publication metadata/navigation XML exceeding it is `invalidXML`.
On the strict path, attribute values, comments and CDATA do not count as attributes. The HTML
preflight conservatively treats a script/style end marker as markup even inside an apparent
quoted value, comment or another raw-text element, since malformed raw-text endings can leave
libxml2 in another context. It follows its own comment, processing-instruction, end-tag and
script/style contexts after source rewriting ([#196](https://github.com/vocaro/EPUBLib/issues/196));
[testing](testing.md#attribute-parser-cost-probe) has the parser-only probe. Callers processing a whole book enforce
their own cumulative text budget while iterating. `CancellationError` propagates during parsing.
`EPUBTextExtractionError` distinguishes invalid spine indices, unsupported media types, malformed
XHTML and exceeded limits. XHTML 1.x named character references such as `&nbsp;` and `&mdash;`
are supported without loading a DTD. Their spelling inside CDATA and comments is left unchanged.
Malformed markup fails by default. Entity declarations and internal DTD subsets always fail.
Ordinary external
DOCTYPE identifiers are allowed but never fetched or resolved. Declaration-looking examples inside
comments, CDATA or processing instructions are inert on the strict path; its safety check follows
XML lexical context.

Pass `recoversMalformedMarkup: true` to `textSection(at:limits:recoversMalformedMarkup:)` to
accept malformed tags or attributes through libxml2's HTML parser. `recoveredAsHTML` reports
when that parser was used. Text, IDs and headings then describe the repaired HTML tree; source
EPUB bytes remain unchanged. Recovery uses the same bounded extraction walk, excludes scripts,
styles and templates, and preserves CDATA character data, image alternatives and structural
MathML notation. Literal CDATA markers in quoted alternatives remain literal. As in the HTML
Standard, a `<` that opens no tag stays text (`p < 0.05`, `a <_< b`): a tag opens only before an
ASCII letter, `/`, `!` or `?`. A `<` that is the last byte of the file is the one exception. It
stays the cut-off tag it may be, so it is not shown, and a file that is only `<` is
`malformedContent`. An early `</body>` or `</html>` closes nothing, in a script or style as
outside one, so content after it stays in the body, as does a second document in the same
file, and U+0000 is dropped
from text and read as U+FFFD inside tags, comments and scripts instead of ending the section
there. A `<!-->` or `<!--->` that follows a `<` kept as text, with no `>` between them, is closed
there, as HTML closes it. In other malformed markup the tree is libxml2's, which is not always
the HTML Standard's: it can end a script or style at an end tag that directly follows the start
tag (any but `</body>` and `</html>`, which end nothing there either), for example, and
elsewhere reads `<!-->` as a comment that is still open. Script and style content is read where
the HTML Standard reads it: `<script"q>`, `<script=x>`, or a `<script>` in a title, a `textarea`,
a comment or an attribute value opens none, and what follows is read
([#255](https://github.com/vocaro/EPUBLib/issues/255)). Inside SVG and MathML, and in the head
but for a title's first tag, such a tag is left as libxml2 reads it. Two limits remain, both in
markup broken several ways at once: what such a tag used to hide as script, libxml2 now reads as
markup, and where it pairs quotes or builds the tree otherwise than HTML (as in
`<script 1="a b="c>`), some text or anchors that were read before can be lost; and a quoted value
that never ends there, which used to be copied as script, refuses the section
([#255](https://github.com/vocaro/EPUBLib/issues/255)). A self-closing `<html/>`,
`<head/>` or `<body/>` is left to libxml2 as well: where the tag is out of place, libxml2 ignores
it and lets its `/>` close the element that is open, which can end the body early. What libxml2
then builds after the body, in a second body, or in a root it opens again is read as the
body's, and a title it builds outside the head before the body is the section's title
([#292](https://github.com/vocaro/EPUBLib/issues/292)). A recovered tree with no body is
`malformedContent` too, which includes a head `style` or `script` with no end tag whose content
begins with `</html>` or `</body>` and goes on with text: it runs to the end of the file (HTML
gives such a document no body either). Recovery
conservatively rejects declaration keywords anywhere, even inside comments, attribute values or
end tags, any DOCTYPE internal subset, and, outside what libxml2 reads as a comment, an
unterminated CDATA section and a start tag's quoted attribute value that never ends.
Unsafe declarations, exceeded limits, cancellation and well-formed documents without the expected
XHTML structure remain errors. A parser halt at its built-in nesting cap returns
`limitExceeded("depth")` instead of partial text, even with a larger caller limit; recovery is
effectively capped at 255 levels. UTF-8 and detectable UTF-16/32 are supported; recovery does not
guess other encodings. HTML5-only named references remain literal in recovery and fail on the
strict path. The parser never loads external resources. This option concerns
headless text extraction; it does not change reader CFIs or navigation parsing.

Hosts own section inclusion, chunking, embeddings, persistence and citation policy. Extracting a
colophon is valid library behavior; whether it belongs in a study index is the host's decision.

## Positions

`anchors` maps the first occurrence of each body element ID to an `EPUBTextMark`. `headings`
contains each XHTML heading in document order, with normalized text and its mark. A mark's
`offset` counts UTF-8 bytes to the first text character after the element opens; `separator`
counts the normalized space or newline immediately before that character. An empty element
with no following text marks the document end. Script/style/template subtrees contribute neither
text nor anchors. Text and positions are emitted by the same bounded walk. Empty IDs wait in a
pending set
until the next emitted text or document end fixes their offsets, so thousands of empty anchors
do not rescan the anchors already resolved ([#92](https://github.com/vocaro/EPUBLib/issues/92)).
Consumers never need to replicate normalization to locate sections. Hosts decide which navigation
entries or headings form meaningful study sections.
