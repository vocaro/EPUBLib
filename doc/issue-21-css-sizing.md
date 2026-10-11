# CSS paragraph sizing qualification

The native section builder retains authored paragraph dimensions until layout.
Percentage margins, padding and text indents resolve against the live containing
content width, including constrained float and inline-block ancestors. Vertical
percentage margins and padding also use that width; adjoining margins collapse
before paragraph spacing is installed. Insets remain bounded to preserve a readable
column. Paginated layout resolves dimensions before measuring and removes resize
metadata from page slices so continuation indentation and spacing do not repeat.
Continuous-scroll layout starts from immutable source dimensions on each resize,
changing attributes while preserving characters, selection ranges and DOM maps.

`ex` lengths use CoreText's x-height for the face selected by the font registry,
including embedded `@font-face` resources. An `ex` font size uses its parent's
metrics. Font metric work runs only for actual `ex` units; ordinary lengths keep
the existing inexpensive computation. Fonts without a usable metric fall back
to half the em size.

Centered `figcaption` text at `0.9em` is an intentional user-agent reader default.
Explicit author alignment overrides it through the existing cascade. The earlier
catalog-wide comparison with WebKit reported this default as a difference; it is
not an author-alignment failure.

## Focused coverage

`ParagraphSizingTests` verifies 300-, 600- and 900-point containing widths at
16- and 25-point reader text, nested percentages, vertical collapse and padding,
RTL, outside list markers, constrained flow ancestors, pagination continuation,
and repeated scrolled resizing without selection or source-text changes. A
multi-row table regression checks that only its first/last paragraphs receive
the outer dynamic margins. `FontLengthTests` embeds a locally available Georgia
face and compares resolved lengths directly with its CoreText x-height at both
reader sizes. The test skips explicitly if that face is unavailable.

The original 68,817-element catalog-wide WebKit comparison has not been rerun.
These are focused native geometry and font-metric regressions, not a claim of
complete browser CSS equivalence or hardware qualification.

The integrated Mac suite on macOS 27 / Swift 6.4 / Xcode 27.1 completed 568 tests,
including ten optional skips, with no failures on 2026-10-10. This run includes
the percentage geometry, embedded-face metric and multi-row table regressions,
and uses the working changes based on commit `6759e2e`.

The integrated iPhone 17 Pro and iPad Air 13-inch (M4) simulator suites on iOS
27.0 each completed 555 tests, including seven optional skips, with no failures.
Both sample applications built, and the module-boundary and documentation-snippet
checks passed. These simulator results do not replace physical-device coverage.

## Remaining boundaries

Mixed symbolic/absolute CSS calculations and `min`/`max`/`clamp` branch selection
retain the existing nominal media-query viewport approximation. Viewport-relative
font sizes and media-query decisions also retain that nominal viewport. The
ordinary block model is still expressed as TextKit paragraphs; it does not add
arbitrary block height, flex/grid alignment or a full CSS box-layout engine.
The native flow-box subset and its readable-width fallback remain in effect.
