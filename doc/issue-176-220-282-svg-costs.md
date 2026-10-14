# SVG text, stylesheets and repeated resources

Issues [#176](https://github.com/vocaro/EPUBLib/issues/176),
[#220](https://github.com/vocaro/EPUBLib/issues/220) and
[#282](https://github.com/vocaro/EPUBLib/issues/282) are screened before resvg parses a drawing.
`SVGRenderingCostScreen` returns counts and a verdict; `SVGContent` applies it alongside the
existing per-run, marker, shared-value, node, depth and byte bounds. A refusal follows the same
fallback/title/alternative-text and `svg` disclosure path as those bounds.

## What costs the renderer

The vendored resvg is 0.48.1 at `68b14c4c3bccdb60344c777406486b54c36ec1a4`, with
simplecss 0.2.2. The following is from those sources, not a reproduction of system code:

- `usvg/src/parser/text.rs` counts and iterates `str::chars()`; `text/layout.rs` tracks scalar
  offsets through shaping. Each run has its own shaping/layout, so a bound on one run cannot
  bound the sum of many runs. The issue's independent measurements found about 82 MB for one
  maximally positioned 20,000-scalar run, and 757 MB for ten such runs. The screen retains the
  20,000-per-run bound and adds 50,000 scalars across expanded content: around 2.5 maximal runs,
  leaving substantial room for diagram labels. It counts `<use>` copies and repeated resource
  content too. UTF-8 bytes and grapheme clusters are not the units Rust's text code counts.
- `simplecss/src/selector.rs`, `Selector::matches_impl`, tries each ancestor at each descendant
  combinator. An unsuccessful chain tries combinations of ancestors, including partial matches.
  The screen bounds those choices by `sum(C(depth,j), j=0...descendants)`, with saturation.
  `usvg/src/parser/svgtree/parse.rs` applies every rule to each element, and then iterates every
  declaration of a matched rule, even declarations it will drop. The work charge therefore
  includes selector bytes per element, matched ancestor-choice work, and all matched declarations,
  including unrecognized properties. Long compound selectors also pay their full byte length.
  Attribute lookup/value scanning is charged even on failed matches, using the largest source
  attribute count, query-name width and largest field queried by a selector. This bounds a long class list scanned
  once per rule and a missing field searched through many XML attributes, including ancestor
  candidates. Collection stops at 10,000 selectors and at the cloned-block storage budget before
  rule-list materialization or selector/reference multiplication can grow beyond those ceilings.
- `write_declaration` / `insert_attribute` in that same usvg source allocates an owned value on
  every matching element. `marker` expands to three attributes, `font` to as many as eighteen.
  All presentation declarations are counted on shapes, groups, `<use>` and their copies, with
  value bytes plus 64 per declaration as an upper estimate of the measured small-value storage.
  simplecss also clones each declaration block for each selector in a list; the screen charges
  that product before allocating per-selector reference lists. Every property counts for the
  block-clone cost, including names usvg later drops. The ceilings are 32 Mi work units and
  16 MiB estimated stylesheet storage. Original XML counts are checked before reference lists
  are resolved, and reference lookups have their own bounded byte counter: each ID's bytes
  for a lookup and 32 bytes for each candidate element examined, even where its type is wrong.
- `usvg/src/parser/mask.rs` shares a converted mask only if both `maskUnits` and
  `maskContentUnits` are `userSpaceOnUse`. The defaults are respectively `objectBoundingBox`
  and `userSpaceOnUse`. `clippath.rs` shares `userSpaceOnUse` clip paths, the default;
  `objectBoundingBox` clip paths convert their content again for each referencing element.
  Both insert into the cache only after successful conversion of nonempty content. An empty
  resource, a primitive whose positive Double dimension rounds to zero in f32, or failed nested
  resources can therefore be retried on every reference even in user-space units. Two failed
  references per level make that retry exponential. The screen charges every mask and clip-path
  reference in every unit system against the existing 8 MiB expanded-byte ceiling, including
  nested references, rather than attempt a proof that conversion will succeed. This deliberately
  overcharges successfully cached content and also bounds the work of drawing it repeatedly.
- `paint_server.rs`, `convert_pattern`, converts children when constructing each pattern paint;
  `filter.rs`, `convert_url`, shares filters only when both filter and primitive units are
  `userSpaceOnUse`, and only after successful conversion. Pattern fills remain refused and filter
  effects remain omitted. Supporting them in future requires analogous content/primitive work
  budgets and render-time raster budgets; the present screen is not acceptance for those features.

A source node costs 32 bytes plus its text and attribute names/values, as in the existing `<use>`
expansion bound. Resource targets, child subtrees and use targets add their saturated costs without
constructing expanded XML. Short resource loops already unlinked by usvg do not expand again;
the existing reference screen still refuses the longer loops and excessive chains it does not stop.

## Capped parse measurements

On 2026-10-13, the unmodified bundled macOS library on the Apple-silicon development Mac was linked
into a C child by `scripts/svg-cost-probe.py`. Each child parsed one generated SVG and reported
`getrusage(RUSAGE_SELF).ru_maxrss` and monotonic parse duration, then destroyed its tree. The parent
terminated a child exceeding 256 MiB RSS or ten seconds. All twelve children completed; none hit
those caps. No fonts, markers or hostile maximal inputs were involved. Each shape is a nonzero
1-by-1 rectangle; each referencing shape is 2-by-2, so conversion cannot be dismissed as empty.
These are parse/conversion measurements, not raster render measurements or test thresholds.

| Resource | Content shapes | References | Input bytes | Peak RSS bytes | Parse seconds |
| --- | ---: | ---: | ---: | ---: | ---: |
| Default mask | 100 | 1 | 2,948 | 6,373,376 | 0.000429 |
| Default mask | 100 | 100 | 7,205 | 11,468,800 | 0.003486 |
| Default mask | 1,000 | 100 | 32,405 | 54,018,048 | 0.036101 |
| User-space mask | 100 | 1 | 2,974 | 6,373,376 | 0.000107 |
| User-space mask | 100 | 100 | 7,231 | 6,586,368 | 0.000277 |
| User-space mask | 1,000 | 100 | 32,431 | 7,503,872 | 0.001097 |
| Object-bounding-box clip | 100 | 1 | 2,994 | 6,356,992 | 0.000095 |
| Object-bounding-box clip | 100 | 100 | 7,746 | 11,403,264 | 0.002399 |
| Object-bounding-box clip | 1,000 | 100 | 32,946 | 53,936,128 | 0.030060 |
| Default user-space clip | 100 | 1 | 2,961 | 6,373,376 | 0.000118 |
| Default user-space clip | 100 | 100 | 7,713 | 6,569,984 | 0.000252 |
| Default user-space clip | 1,000 | 100 | 32,913 | 7,553,024 | 0.001221 |

Mask and clip conversion are comparable: 100,000 repeated content shapes cost about 54 MB for
uncached units, versus about 7.5 MB for successful sharing. This supports charging content times
references, rather than the source's bytes alone. The 8 MiB expanded-byte ceiling admits fewer than
190,000 of these repeated rectangles, consistent with roughly 100 MB at the ceiling from these
measurements, in the same memory range as the existing SVG limits.
Timing changes with machine load and is not an assertion.

Repeat from a checkout, preserving generated SVGs, the C probe and full JSON:

```sh
python3 scripts/svg-cost-probe.py --output /private/tmp/svg-cost-probe
```

## Acceptance coverage

`RichMediaSVGRenderingCostCoverageTests` exercises the small backtracking selector, rules times
elements, declarations on shapes/groups/use copies, long selector lists, long compound selectors,
ignored declarations, failed attribute comparisons and bounded tiny-rule collection, both sides of the total-text bound, scalar accounting, text via `<use>`,
ordinary and oversized resource reuse, an exact expanded-byte boundary, CSS/inline references,
branching mask chains, marker-inherited resources and resolved gradient copies, and invalid user-space mask and clip chains. Expensive cases are given to
the screen only; pipeline refusal cases verify fallback text and the `svg` disclosure. A drawing
with fifty five-declaration exporter-style rules and 3,000 elements remains within every limit
and renders. Existing automated SVG fixture tests remain the regression suite. The old synthetic
100-run text stress fixture now uses 40,000 total characters, within the new global ceiling;
the dedicated new tests hold the exact 50,000-scalar boundary and 800-by-5,000 hostile case.

Verification on `3073b2363ba3061228ec53aecff3d0d8bc75fc0a`, based on main
`24400a9e0203f9e325ca98f5917e1d2e17955189`:
`swift test --jobs 1 --filter 'SVG|RichImageTests'` executed 149 viewing tests (two optional
corpus tests skipped), including all sixteen new cost-screen tests, and two reading tests, with
zero failures. The Mac was heavily loaded during this run; all new acceptance checks are counts,
verdicts and fallback assertions. No corpus from another project was accessed. The pinned public
corpus and integrated Mac/iOS gate remain the central qualification lanes for the combined fixes.


# Additional parse and raster work bounds

The preflight for [#230](https://github.com/vocaro/EPUBLib/issues/230),
[#251](https://github.com/vocaro/EPUBLib/issues/251), and
[#375](https://github.com/vocaro/EPUBLib/issues/375) checks hostile text without
handing it to resvg. The checked Rust boundary still handles renderer panics;
these bounds stop inputs whose expensive work would not panic.

`SVGGeometryCostScreen` reads path numbers with SVG's scientific notation,
compact signs, and adjacent arc flags. It accumulates relative coordinates and
bounds endpoints and control points to 10 million units. An elliptical arc also
pays its corrected radius: even a small authored radius can become enormous
when the renderer enlarges it to connect its endpoints. The screen overestimates
the correction using the chord length and the smaller radius, bounds the result
to 10 million units, and sums the ellipse subdivision estimate over the path
against 10,000 units. The reported huge stroked arc and far-off text path are
refused before parse. The same rule applies to paths in definitions.

An embedded image's transformed span may reach eight root canvas dimensions.
The screen includes percentages, physical units, image font-relative lengths,
ancestor transforms, nested viewport and symbol scaling, and `<use>` viewport
overrides. The larger viewport scale is charged on both axes, covering `slice`.
Competing transforms are enclosed separately rather than multiplied, so an
overridden downscale cannot hide an upscale. Linked text paths additionally pay
their transformed coordinate bounds; links to other shape types are refused.
Stylesheet transforms, relative stylesheet font sizes and font shorthands are
refused for SVGs with images or text paths: their cascade is not reproduced. Absolute font size candidates
raise the size bound. Header dimensions stand in for omitted image dimensions.
This is separate from the decoded-image pixel and byte limits.

A nested `<svg>` or `<symbol>` counts as an isolated raster layer, including
copies reached through `<use>`. [#541](https://github.com/vocaro/EPUBLib/issues/541)
records the independently found symbol accounting gap: the pinned renderer's
[`use_node` conversion](https://raw.githubusercontent.com/linebender/resvg/v0.48.1/crates/usvg/src/parser/use_node.rs)
creates a clipped group for each symbol use, while the previous Swift count
charged none for a plain symbol. The regression asserts the preflight layer
count; it makes no decode-time claim and never renders the oversized content. Marker content is kept near its viewport,
measured relative to that viewport even when its origin is far from zero. Marker
viewports are also bounded after potential host transformations and strokeWidth
scaling. The largest projected marker content area, including orientation and
strokes, multiplied by the weighted marker-instance count may reach at most 256
root canvas areas. Ordinary arrowheads retain their existing resolution. The
dedicated raster screen checks geometry, transformation alternatives, inherited
strokes and candidate stylesheet values before rendering.

Nested `<style>` elements are refused by `SVGStyleScreen` before any stylesheet
text is read, including the font-discovery and disclosure paths before
serialization. The walk charges one visit per node and stops as soon as it
finds a style inside another style. It shares the existing node and depth
ceilings. The renderer semantics were measured before this fix: after
serialization, nested levels' text is concatenated in document order and the
renderer applies that concatenation. [The recorded experiment and minimal
reproducers](https://github.com/vocaro/EPUBLib/issues/375#issuecomment-6141053142)
settle that behavior; refusal avoids reading the same descendant stylesheet for
every level.

The new tests assert verdicts, structural visit counts, geometric boundaries,
and ordinary rendering. Hostile inputs are used only by preflight tests, so a
regression cannot turn a failing assertion into a stalled renderer call. The
existing Inkscape, Mermaid, D3 and OmniGraffle rendering tests qualify ordinary
arrowheads and their raster resolution.
