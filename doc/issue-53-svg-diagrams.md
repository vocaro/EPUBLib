# Networking SVG diagrams with omitted filters

Issue #53 is reproduced with Charles R. Severance's *Introduction to Networking*,
available under CC BY 4.0 from the [publisher](https://www.dr-chuck.com/net-intro/).
The unchanged [English EPUB](https://do1.dr-chuck.net/net-intro/EN_us/net-intro.epub)
is 2,752,493 bytes and has SHA-256
`54d3886b30e92daca03f2f66065c01cb0d48c592824365605308b7b542c45c6d`.
The external corpus remains optional and is not copied into this repository.

`media/file5.svg`, referenced by `ch002.xhtml`, contains the four TCP/IP boxes and
labels Application, Transport, Internetwork and Link. Its `Shadow` definition uses
Gaussian blur, offset, flood and composite operations. The shadow references are
separate from its ordinary rectangle and text groups. Refusing the whole SVG loses
the instructional diagram even though those groups require no filter support.

The sanitizer now omits filter definitions, presentation attributes and CSS
declarations while preserving the remaining drawing. `SectionReport` retains its
`svg:filter` disclosure. CSS omission preserves neighboring fill, stroke, clipping
and font declarations, including comments and quoted/function values. Stylesheet
text is sanitized together so XML text/CDATA boundaries do not split declarations.
The renderer's direct entry point continues to refuse filters, including commented
and escaped CSS property names; it only receives the prepared drawing.

The original node, depth, local-reference expansion and cycle checks run before
omission. Pattern fills still use the disclosed text fallback. All existing
serialized-size, archive-image, decoded-image, external-resource, raster-layer and
font budgets remain in force.

## Verification

On macOS 27 with Apple Swift 6.4, the focused suite passed all 16 tests with no
failures, including the original publisher corpus and native reader inspection.
`git diff --check` also passed.

The full iPhone 17 Pro and iPad Air 13-inch M4 suites passed on dedicated iOS 27.0
simulators. The corpus opt-in was not forwarded by the initial Xcode runs, so a
focused iPad run set `TEST_RUNNER_EPUBLIB_SVG_CORPUS` explicitly. That test passed
without a skip, rendering all 33 original SVGs and checking the four layer labels
and light/dark narrow attachments. All three temporary simulators were deleted.

Run the focused suite with the unchanged publisher EPUB:

```sh
EPUBLIB_SVG_CORPUS=/tmp/issue-53-net-intro.epub \
EPUBLIB_SVG_CORPUS_VISUAL_OUTPUT=/tmp/issue-53-networking.png \
swift test --scratch-path .build/issue-53 --filter SVGRenderingTests
```

The corpus test now renders all 33 SVG resources, including the six previously
refused resources (`file5`, `file8`, `file11`, `file19`, `file24`, `file33`). Previously
it rendered 27 and skipped six. The exported four-layer bitmap was inspected: all
four boxes and their labels are present, with shadows omitted. Pixel assertions
check ink in each label's region of the original diagram.

Focused tests cover inline and archive attachments in both appearances at a
90-point available width, preserved label pixels, and inspection bitmap decoding.
Native reader coverage opens, zooms and closes a filtered diagram in both
appearances and both reading flows in 320-point hosts, checking the reader anchor
is preserved. Safety regressions cover cyclic/expanded references, original depth
inside omitted definitions, remote image refusal and strict raw-filter refusal.

## Proposed shared documentation changes

In `native-viewer.md`, describe SVG filters as omitted effects with a disclosure;
the remaining illustration stays visible. Preserve the existing fallback wording
for pattern fills and rendering-limit refusals. The limitations section should
say that filter effects are unsupported and omitted, rather than implying a whole
diagram is unavailable whenever it contains a filter.

Suggested release note: "Preserve SVG diagram shapes and labels when unsupported
filter effects are omitted, including the networking book's four TCP/IP layers."
