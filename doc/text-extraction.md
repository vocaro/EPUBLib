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
subtrees are excluded, and so is a `title` wherever it stands, in a head after the body or in
the body itself: HTML hides every title, and the head's is the section's `title`. SVG's title is
read as before ([#287](https://github.com/vocaro/EPUBLib/issues/287)). XML entities and CDATA are decoded. In recovery, a comment also ends at `--!>`, and an `&#` with no initial decimal or hexadecimal digit stays literal in text and surfaced attributes, matching the native reader ([#244](https://github.com/vocaro/EPUBLib/issues/244)). Whitespace is normalized to single spaces
within lines and single newlines at block boundaries. Whitespace normalization operates on
Unicode scalars, so combining marks following a space or
no-break space remain in body text, headings, image alternatives and MathML text
([#89](https://github.com/vocaro/EPUBLib/issues/89);
[normalizing by scalar](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#normalize-text-by-scalar-and-by-byte-not-by-character)).
This is structural text extraction, not a browser's computed visible-text representation
([parser choice](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#parser-choice-can-change-text)): CSS layout, generated content, image OCR and
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
math operators. An `mglyph` contributes its whitespace-collapsed `alt` at its position inside a
token, or as a quoted value at row level; a missing or blank `alt` contributes nothing. Glyph
image paths and sizing attributes do not enter the extracted text, and a whole-formula
`alttext` still takes precedence. Other elements, presentation attributes and malformed argument counts retain their
tag structure instead of losing grouping. Literal `display="block"` formulas separate surrounding
text with line breaks. No math script, image or external resource is evaluated.

Math IDs and enclosing headings refer to the same returned UTF-8 text. IDs inside an authored
replacement point to that replacement; IDs in structural notation point to their serialized node.
Generated delimiters and escapes count toward the existing output budget and subsequent offsets.

`EPUBTextExtractionLimits` bounds input bytes (default 4 MiB), UTF-8 bytes per output field (8 MiB), nesting
(64 elements) and element count (100,000) per section. Whatever the nesting limit, libxml2 reads
no more than 257 levels, and a section nested deeper is `limitExceeded("depth")` on the strict
path as in recovery; markup that is not well-formed before that depth is still `malformedContent`
([#91](https://github.com/vocaro/EPUBLib/issues/91)). A fixed additional safety bound allows
at most 1,024 attribute occurrences on one element, including namespace declarations, duplicate
names and HTML boolean attributes. A linear preflight checks this before strict XML or HTML
parsing; extraction reports `limitExceeded("attributesPerElement")`, and native content parsing
reports the same limit name. Publication metadata/navigation XML exceeding it is `invalidXML`.
On the strict path, attribute values, comments and CDATA do not count as attributes. The HTML
preflight conservatively treats a script/style end marker as markup even inside an apparent
quoted value, comment or another raw-text element, since malformed raw-text endings can leave
libxml2 in another context. It follows its own comment, processing-instruction, end-tag and
script/style contexts after source rewriting ([#196](https://github.com/vocaro/EPUBLib/issues/196);
[screening markup](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#screen-untrusted-markup-before-any-parser-sees-it));
[testing](testing.md#attribute-parser-cost-probe) has the parser-only probe. Callers processing a whole book enforce
their own cumulative text budget while iterating. `CancellationError` propagates during parsing.
`EPUBTextExtractionError` distinguishes invalid spine indices, unsupported media types, malformed
XHTML and exceeded limits, each with a plain message for a person
([when something fails](integration.md#when-something-fails)). Named character references such as `&nbsp;` and `&rcaron;` are read
from the HTML Standard's table, the one the native reader uses, without loading a DTD
([#184](https://github.com/vocaro/EPUBLib/issues/184)). Their spelling inside CDATA and comments
is left unchanged. A name the table lacks, such as `&bogus;`, is malformed markup on the strict
path; the native reader reads such a section as HTML, and recovery keeps the name as written.
Malformed markup fails by default, and so does a name that Namespaces in XML forbids, which
libxml2 reports and reads on: an element or attribute name that begins or ends with a colon or
holds a second one (`<:p>`, `script:`, `a:b:c`), and a processing instruction's target with a
colon. The native reader reads such a section as HTML, and recovery reads it as the reader does:
`<:p>` is text and `<script:>` an unknown element ([#178](https://github.com/vocaro/EPUBLib/issues/178)).
An `xmlns:` attribute is such a name and declares nothing, so beside `xmlns` it gives the same
result on every run, whichever of the two comes first ([#213](https://github.com/vocaro/EPUBLib/issues/213)).
A prefix that is never declared names no namespace, and its element is read by its local name.
Entity declarations and internal DTD subsets always fail.
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
there, as HTML closes it. A DOCTYPE ends at its first `>`, as HTML ends it even inside a quoted
identifier, so one whose identifier has lost its closing quote no longer takes the root's start
tag with it or refuses the section; recovery writes one letter of each `PUBLIC` and `SYSTEM` in
it as a character reference, and libxml2 then reads no identifier there
([#293](https://github.com/vocaro/EPUBLib/issues/293)). As in HTML, an `xmlns` attribute puts no
element of HTML content in another namespace, so a root whose `xmlns` value has lost its closing
quote is read; `svg` and `math` are SVG's and MathML's by name, and inside them `xmlns` is read
as before. In other malformed markup the tree is libxml2's, which is not always
the HTML Standard's
([libxml2's HTML parser](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#libxml2s-html-parser-is-not-the-html-standard)):
it can end a script or style at an end tag that directly follows the start
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
body's ([#292](https://github.com/vocaro/EPUBLib/issues/292)). The first title in the document
is the section's title wherever libxml2 builds it, as `document.title` is the first in tree
order: one it builds outside the head before the body (#292), or one HTML builds in the body
([#287](https://github.com/vocaro/EPUBLib/issues/287)). HTML gives its one root each attribute
of a later `html` start tag that the root lacks, where libxml2 drops such a tag or builds a
second root beside one that its own tag closed at once, so the namespace prefixes that any
`html` start tag declares are in scope from the root (#287). A recovered tree with no body is
`malformedContent` too, which includes a head `style` or `script` with no end tag whose content
begins with `</html>` or `</body>` and goes on with text: it runs to the end of the file (HTML
gives such a document no body either). Recovery
conservatively rejects declaration keywords anywhere, even inside comments, attribute values or
end tags, any DOCTYPE internal subset, and, outside what libxml2 reads as a comment, an
unterminated CDATA section and a start tag's quoted attribute value that never ends. It reads a
DOCTYPE as far as libxml2 reads it: to its first `>`, or, where a `PUBLIC` or `SYSTEM` it has
not renamed comes before that `>`, through its quoted identifiers. A bracket in what it reads,
quoted or not, or a DOCTYPE that never ends refuses the section (#293).
Three of these refusals now withhold some sections whose text recovery read before
[#226](https://github.com/vocaro/EPUBLib/pull/226): a tree with no body, a quoted attribute
value that never ends and a CDATA section that never ends. Where #226 keeps a `<` that opens no
tag as text, markup that recovery used to discard with everything up to the next `>` comes into
view, and in these sections that markup never closes, or libxml2 builds no body from it. These
are losses accepted against recovery before #226, as the reader withholds a section cut off
inside markup ([#202](https://github.com/vocaro/EPUBLib/issues/202)): the cost is one section,
of input broken in more than one way, on a path the caller opts into; reading on would mean
guessing where markup that never closes ends, which is where a scan and a parser most easily
disagree about what the bytes are, or what is the body of a tree that has none; and a browser
showed the text read before #226 in fewer than half of the sections measured, 684 of 1,437
([#256](https://github.com/vocaro/EPUBLib/issues/256)).
Unsafe declarations, exceeded limits, cancellation and well-formed documents without the expected
XHTML structure remain errors. A parser halt at its built-in nesting cap returns
`limitExceeded("depth")` instead of partial text, even with a larger caller limit; both paths
are capped at 257 levels. UTF-8 and detectable UTF-16/32 are supported; recovery does not
guess other encodings. Recovery reads named references from the HTML Standard's table too, as the
native reader does, not from libxml2's HTML 4 one. The parser never loads external resources. This
option concerns headless text extraction; it does not change reader CFIs or navigation parsing.

Hosts own section inclusion, chunking, embeddings, persistence and citation policy. Extracting a
colophon is valid library behavior; whether it belongs in a study index is the host's decision.

## Positions

`anchors` maps the first occurrence of each body element ID to an `EPUBTextMark`. It is keyed by
`EPUBElementID`, which compares IDs code unit for code unit as `getElementById` does, so
`caf&#xE9;` and `cafe&#x301;` are two anchors; `anchors[fragment]` looks one up by a `String`
([#635](https://github.com/vocaro/EPUBLib/issues/635);
[element IDs](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#element-ids-compare-code-units-swift-strings-do-not)). `headings`
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
