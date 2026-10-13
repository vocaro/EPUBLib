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
