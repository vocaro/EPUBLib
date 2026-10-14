# Page text and flow qualification

The changes address #303, #192, #242 and #289. A planned page is measured as the same bounded display slice before its source boundary is committed. Lines below its actual clip carry forward. A positioned first line outside the clip, or a line taller than the column, falls back to native in-flow text with bounded typography. That exceptional slice retains its characters, DOM mapping, links and heading roles; it can change positioning, font size, baseline shifts and paragraph spacing to make its content reachable.

A forced-break paragraph's retained leading margin is included in its ordinary flow plan. Existing bounded preflight decides which boxes are eligible first. Only a retained rich plan with such a margin is replanned with corrected flow advances, carrying rejected box IDs forward. Each phase uses the existing bounded positioning/suppression passes. An already-readable in-flow fallback is not converted to a new indivisible group. Ordinary nonforced margins keep their established behavior.

The page's first-line exclusion proposal includes its actual top adjustment. A negative fragment end is held at zero, and the following fragment compensates by the preceding fragment's actual held distance. Glyph queries use the signed frame origin; section page anchoring retains the established flow envelope. The existing indivisible-group policy remains, including its handling of authored breaks inside a group.

An inset that exhausts a line leaves a visible glyph column. Justified drop caps measure intrinsic glyph width without full-width justification. Other alignment measurement remains unchanged; #148's centered-caption expected failure is retained.

## Qualification on 2026-10-13

The source was based on immutable main `24400a9e0203f9e325ca98f5917e1d2e17955189`; the final preverification fetch still named that commit. Tests ran locally on macOS, with one compiler job, without a debugger or simulator screen. The Mac was shared and did not establish the quiet interval required for timing acceptance. These runs establish deterministic geometry and content behavior; the integration gate separately qualifies performance and iOS.

153 targeted tests passed, including the adjacent float, positioned-box, pagination, table-continuation and long-paragraph suites. Two different generated corpora each covered 500 sections, seed 12. `PageTextGeometryTests.testGeneratedBoxPagesExposeAllSectionCharacters` uses indexed reset selection. `testFrozenReviewGeneratorExposesEveryCharacterAndTableWord` consumes the reset draw before generation, exactly as the reviewer generator recorded on #242 does. Their section numbers are not interchangeable.

Every generated page checks actual native line and glyph-edge rectangles against its effective clip. Source offsets alone are insufficient for tables: each original row's complete word tokens are compared with the accumulated tokens of its visible continuation attachments, grouped by original source offset. Missing or duplicated cell words fail independently of source-character coverage. The tall-table integration test additionally holds 900 unique words across narrow and wide columns. Oversized headings and extreme positive/negative baseline shifts retain their source and semantic roles. A genuine negative-height final fragment of a multi-paragraph positioned box holds hit testing, links, visible ranges, line boundaries and CFI restoration against raw glyph coordinates.

A separate diagnostic copied the reviewer generator onto an archive of exact24400 and onto the candidate. It compared actual displayed x/y/width/height, without adding `layoutTop`, line/source ranges, visible table attachment source offsets, fragment cell ranges and words. Canonical qualification includes width and height, not only x/y. The probe selected only synthetic inputs and did not read another project's books.

| Frozen500-section review plus10 named inputs | Main24400 | Candidate |
|---|---:|---:|
| Pages |4956|4945|
| Pages with clipped or overlapping native lines |45|0|
| Readable main pages matching full section geometry |4350|—|
| Matching readable source ranges |—|4255|
| Identical displayed rectangles and visible table content |—|4252|
| Classified retained-margin corrections |—|3|
| Repartitioned formerly-readable pages |—|95|

The three matching-range changes are g12#200 (a retained 12-point margin), g12#365 (a forced heading margin; its observed native/exclusion displacement is 26.92818 points) and g12#457 (5.5 points). The latter's fixed box now settles at section Y690, the bottom of the full-width absolute box ending at 700−10, instead of erroneously retaining the earlier 5.5-point margin. Of 30 repartitioned sections, 28 change downstream of a main page already noncanonical or clipped. g12#180 and g12#217 restore retained forced margins of 9.5 and5.25+⅓ points respectively.

Every actual rectangle and boundary of g12#275's four existing in-flow pages is unchanged. All five pages of the original multi-paragraph-box regression, and all three delayed-table regression scenarios, are unchanged. Permanent `PageTextPreservationTests` stores frozen actual pixel vectors for the critical opening pages and every g275 page. In particular the named fixed box stays at page Y44.95 and cleared prose at 304.66849, rather than hiding a 35.45-point physical move by adding a new section origin.

## Repeating the assertions

```sh
PAGE_TEXT_SECTIONS=500 PAGE_TEXT_REVIEW_SECTIONS=500 PAGE_TEXT_SEED=12 \
  swift test --jobs 1 --filter 'PageTextGeometryTests|PageTextPreservationTests|ExhaustedLineInsetTests|BoxPaginationIntegrationTests|LongParagraphPaginationTests'
```

The generated tests default to 24 sections for the ordinary gate. The historical diagnostic reports are evidence, not an alternative runtime oracle; production preserves the established eligibility decisions and tests its actual native output.

## Minimum fallback clip and degenerate viewports

The integration gate exposed two older pagination contracts. A 600-point source glyph now
fits its 500-point page through the #303 typography fallback; its original page boundaries
remain unchanged. The old assertion that its page must be taller than the clip contradicted
that repair. Its test now checks every native glyph rectangle, source partition and page lookup.

The zero- and one-point viewport failures were a real regression. A native probe found no
three-point font floor: a fitted 0.84909-point font produces a one-point TextKit line and glyph
box. A zero-point clip cannot show it; a one-point heading retains half a point of top spacing,
leaving only half a point for that glyph. The earlier half-point tolerance accepted this loss.
Fallback now requires its measured one-point minimum drawing box plus the existing one-point
safety inset after top spacing. Below that budget pagination preserves the original fonts and
one-source-line progress, without claiming visible glyphs. A failed fitted retry also preserves
the original page. No font or page-range alteration is committed for an impossible clip.

Permanent tests check the two-point effective-clip threshold and just below it, both with and
without retained top spacing. At viable 12/24-point page heights and 500-point oversized-glyph
pages, every nonwhitespace source character's native segment rectangle must fit the effective
clip within 0.01 points; complete source partitions and boundary/interior/end page lookups
remain checked. The temporary probe was removed after recording these findings here.

The bounded follow-up ran `ViewCoveragePaginationTests|PageTextPreservationTests|PageTextGeometryTests`
with one build worker, then repeated without rebuilding after fetching unchanged main24400.
Both final runs passed all37 tests (23 pagination,11 geometry,3 preservation). The normal-sized
500-section and frozen displayed-rectangle qualification above remains unchanged; this guard
only declines an infeasible fallback drawing budget. Full integration and iOS qualification
remain the integration gate's responsibility.

## UIKit qualification against frozen main

The first full iPhone and iPad gates found three tests using macOS page boundaries or font
metrics as UIKit oracles. Production remained unchanged. The portable diagnostic and all
paired raw ranges, displayed rectangles and visible table words are preserved on
[#242](https://github.com/vocaro/EPUBLib/issues/242#issuecomment-6158528238), with a patch applying
to exact main24400, and in [the companion JSON](issue-192-242-uikit-frozen-geometry.json).

All 104 archived production source files matched their git blob IDs at
`24400a9e0203f9e325ca98f5917e1d2e17955189`. The same probe ran sequentially against that archive
and candidate `6d74d19d9fde50f4d523c6aebfcac14c135c6895` on one newly created, headless iPhone 17 Pro
simulator (`20F39029-E990-488E-AF1C-B2005404B78B`, subsequently deleted). Both snapshots actually
ran four diagnostic tests. Xcode was 27.0 build 27A266a, the SDK iPhoneSimulator 27.0 build
24A430, and the runtime iOS 27.0 build 24A434. Builds used two jobs and inherited Swift flags
`-j2 -driver-batch-count 2`.

The corrected portable probe SHA256 is
`9783001b56928b349b1ad0acd40266f6041a5e516d06fca60c59713890b35444`.
The sorted SHA256 source-file manifest digests are
`f1804a37ffe05bb20d90f5de462b8ecffddf482848c9d1ea69cc1117bcf01a23` for main and
`3aecd4e4cd3f8eab775c19e60cd22158e9a97042b20fd7b0b443d81c1c9c9bae` for the candidate.

The original multi-paragraph fixture preserves all eight actual UIKit line rectangles and
ranges exactly. Its native lines are 20.3 points, the fixed box remains at Y44.95, and cleared
prose remains at Y306.45. The three original delayed-table opening pages preserve all ranges,
rectangles and visible table content, apart from numerical noise below 1.5e-14 points.

The larger delayed-proposal fixture also preserves every displayed rectangle and source
boundary. UIKit places table rows at source offsets 235, 237 and 239 inside page zero, at
Y130.8, Y155.8 and Y180.8. It does not exercise the macOS delayed first-fragment trigger.
The Mac test still requires the semantic second row to open its page at Y603.15 with width
1024. The UIKit branch pins the independently captured in-page Y155.8 and full width, then
checks all characters and visible table words. Neither platform silently skips the fixture.

The g275 frozen UIKit output was already invalid: two pages, with the first reaching Y726
inside a 700-point clip. The candidate repairs that clipping with four readable pages.
Its UIKit contract therefore checks complete source coverage, visible table words, native
line bounds and every painted character's horizontal and vertical segment rectangle within
0.01 points. The four readable macOS pages still retain their exact frozen vectors and
boundaries. Across the captured fixtures all 211 table-word tokens match by fixture, source
attachment offset and row, with no omissions or duplicates.

The final test/doc-only update passed all 37 focused tests on Mac and all 37 on an owned
headless UIKit simulator: 11 geometry, three preservation and 23 pagination tests. Both sets
include the unchanged generated coverage assertions; the native minimum-clip tests also pass.
Every device created for the diagnostic and focused runs was deleted. No diagnostic file
remains in either compiled test target. Full iOS integration and sample builds remain with
the integration gate; these focused results do not substitute for them.
