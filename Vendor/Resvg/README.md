# Bundled static SVG renderer

EPUBViewing uses resvg 0.48.1, MIT/Apache-2.0, from upstream commit
`68b14c4c3bccdb60344c777406486b54c36ec1a4`. The source tarball SHA-256 is
`fda0203e2dc383ea334c2d95a9af83526d32647e63d8dee43c2875e95c641c0c`.

`Resvg.xcframework` contains static macOS arm64/x86_64, iOS arm64, and iOS simulator
arm64/x86_64 libraries, built with isolated Rust 1.95.0 and the upstream production
profile (`opt-level=3`, LTO, one codegen unit, stripped debug information), with
`panic = "unwind"` explicitly set so boundary catches can run.
Features: `text,raster-images`; filesystem font scanning, font memory mapping, and
SVGZ are disabled. Swift package consumers do not need Rust. Only EPUBViewing
depends on CResvg; the headless products retain their existing dependencies.

Rebuild on either Apple Silicon or Intel macOS with Xcode installed:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-resvg.sh
```

The script pins/checks the source archive, downloads an isolated Rust toolchain
under `.build/resvg`, preserves the previous framework, and regenerates license
inventory and archive checksums. `EPUBLIB_RESVG_BUILD_DIR` and
`EPUBLIB_RESVG_OUTPUT` can redirect these outputs. The library's build deployment
targets are macOS 11.0 and iOS 10.0 (Rust's Apple defaults); EPUBLib itself
requires iOS/macOS 27.

The resource-policy upstream changes, in `scripts/patch-resvg.py`, close every non-data image
resolver, allow raster data types only (never nested SVG/SVGZ), and fix the C API's
feature gates so filesystem font methods compile to no-ops. Fonts are supplied
as host-exported CoreText SFNT outline bytes, with SVG/COLR/bitmap color-glyph
tables removed and disclosed as `svg:font-color`. No script or remote/file-resource loader is
installed. SVG filter effects are omitted before rendering with a disclosure; the remaining
drawing is preserved. Pattern fills are refused with authored fallback text and a disclosure;
the native pipeline bounds SVG bytes, depth, nodes, use expansion, single text-run
length, marker instances, reference loops and chains, the per-shape copies of gradient
stops, dash arrays, long inherited values and the font-variation-settings a text run
copies per span, image bytes and pixels, and output/isolated-layer raster memory before
rendering. Font databases
share immutable options and retain a process-wide 64 MiB byte reservation for
their full lifetime, including SVG trees remaining after cache eviction. A database
a tree still holds is shared by later drawings naming the same fonts, never duplicated.

The renderer follows a `mask`, a `clip-path`, a marker and a `use` by calling itself, and
a gradient's `href` in a loop. It stops a loop of one or two masks or clip paths
(`fix_recursive_links` in `usvg/parser/svgtree/parse.rs`), a marker it is already drawing
(`usvg/parser/marker.rs`) and an `href` walk that is back where it began (`HrefIter` in
`usvg/parser/svgtree/mod.rs`), and nothing else: a longer loop or a deep chain spends the
stack, and a walk into a loop it did not begin in never returns. Neither is a panic.
`SVGReferenceScreen.swift` refuses those drawings first. It reads a `url(#…)` as svgtypes
0.16.1 does (`funciri.rs`), a stylesheet and a `style` attribute as simplecss 0.2.2 does,
step for step, and takes the elements that are drawn where they stand from
`convert_element` in `usvg/parser/converter.rs`. Repeating and reflecting gradients are resolved by the renderer itself.
Review the remaining loop/depth screen against those sources whenever the renderer is updated.

`scripts/resvg-panic-boundary.py` and its Rust helper wrap both parse entry points,
all tree queries and render entry points in `catch_unwind`, using Rust-ABI inner
functions: an inner `extern "C"` would abort before the catch. A tree's opaque
handle owns a mutex-protected optional tree. Calls on one tree serialize; after a
caught panic its state is dropped while that lock is still held, and every later
query or draw fails. Separate trees can still render concurrently. The upstream
void `resvg_render` remains available; EPUBLib calls the added boolean
`resvg_render_checked` so it can distinguish failure from a transparent image.

The default Rust panic hook is deliberately unchanged: caught panic diagnostics
still go to stderr. There is no process-global hook replacement that could silence
a host's own Rust panics. EPUBLib never invokes `resvg_init_log`.

SVG initialization draws a 64-pixel raster so a known render-stage panic, as well
as a parse panic, can still become section fallback text with the usual `svg`
disclosure. That small raster is not a proof about other sizes. Every later draw
is independently guarded. If a later size panics, its attachment paints its
alternative text at the drawing's position, and earlier successful cached sizes
are ignored. Its text equivalent and accessibility label retain those same words.
The section's report is immutable after construction, so a failure first discovered
at a later draw does not add a retrospective `svg` disclosure to that report.
A caller inspecting the bitmap directly receives nil on failure.

Unwinding does not contain stack overflow, allocation failure, memory or CPU
exhaustion, or a parser loop that never returns; their screens and budgets stay.
The image output size bound remains a capacity bound, not a prediction of panics.

The XCFramework is approximately 45 MiB before compression. `checksums.json`
records the exact vendored archive hashes. `dependencies.json` identifies the
locked normal dependency graph. `Licenses/` contains their complete license and
notice texts, plus Rust's standard-library copyright/third-party notices. Host
applications redistributing this static code must retain these notices.
