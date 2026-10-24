# StaticSVG notices

Copies, unchanged, of the license and notice texts of [StaticSVG](https://github.com/vocaro/StaticSVG)
at tag `0.1.3`, which EPUBViewing links:

- `LICENSE.txt`: StaticSVG's MIT license (its `LICENSE`).
- `dependencies.json`: the renderer library's locked Rust dependencies, with their versions,
  declared licenses and repositories (its `Resvg/dependencies.json`).
- `Licenses/`: the complete license, copyright and notice texts of resvg 0.48.1, each of those
  dependencies and the Rust 1.95.0 standard library (its `Resvg/Licenses/`).

The renderer is a static library inside StaticSVG's release, so an application distributing
EPUBViewing contains it and must retain these notices
([third-party notices](../../doc/third-party-notices.md)). Replace the copies when the pinned
StaticSVG release changes.
