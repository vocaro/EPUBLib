# Third-party notices

StaticSVG's Swift sources are distributed under its [MIT license](LICENSE),
Copyright (c) 2026 Vocaro Technologies LLC. They and their regression tests originate in
[EPUBLib](https://github.com/vocaro/EPUBLib), by the same copyright holder.

## The renderer library

The `CResvg` binary target, distributed as each release's `Resvg.xcframework.zip` asset, is a
static library built from **resvg 0.48.1** (MIT OR Apache-2.0, Copyright the Resvg Authors,
<https://github.com/linebender/resvg>) and the 60 other Rust crates it depends on with the
release's features, together with parts of the **Rust 1.95.0 standard library**. Every crate,
its version, declared license and repository are listed in
[Resvg/dependencies.json](Resvg/dependencies.json). Their complete license, copyright and notice
texts are in [Resvg/Licenses](Resvg/Licenses), one directory per crate, and Rust's
standard-library copyright and third-party notices are in
[Resvg/Licenses/rust-1.95.0](Resvg/Licenses/rust-1.95.0). How they are collected is in
[maintenance](doc/maintenance.md#notices).

The crates are under permissive licenses: MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, Zlib,
0BSD, the Unlicense and Unicode-3.0, most of them offered under a choice of these. Where a crate
offers a choice, StaticSVG takes it under MIT or Apache-2.0. Two of them are patched in the
release build: resvg-capi (resource policy and panic boundary) and tiny-skia 0.12.0 (an unwind
guard), as [the bundled renderer](doc/renderer.md#patches) describes; the scripts that patch them
are in [scripts](scripts).

## Redistributing

An application or library that links StaticSVG contains this static code and must retain the
notices: include [LICENSE](LICENSE), this file, and the texts in [Resvg/Licenses](Resvg/Licenses)
in its acknowledgments or accompanying documentation. Swift Package Manager does not put them
into an application bundle by itself.

## Development tools

The build scripts use Python 3, `curl`, Xcode's `lipo`, `xcodebuild` and `ditto`, and a Rust
toolchain they download from rust-lang.org into the build directory. None of these is part of
the library.
