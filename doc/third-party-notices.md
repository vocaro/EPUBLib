# Third-party notices

An app built with EPUBLib carries the license and notice texts below in EPUBCore's resource
bundle and shows them with `EPUBLicense.all()` ([host integration](integration.md#licenses)).
They are in [Sources/EPUBCore/Licenses](../Sources/EPUBCore/Licenses), a folder for each
component, each file unchanged and under the name its project gave it, except where noted. The
gate holds each copy to its project's file at the revision `Package.resolved` pins, and this list
to the folders and pins ([license texts](testing.md#license-texts)).

- **ZIPFoundation 0.9.20** — MIT — Copyright Thomas Zoechling.
  https://github.com/weichsel/ZIPFoundation. EPUBReading and EPUBWriting read and write archives
  with it. Its `LICENSE` is in `ZIPFoundation/`.
- **foliate-js** at `78914aef4466eb960965702401634c2cb348e9b1` — MIT —
  Copyright (c) 2022 John Factotum. https://github.com/johnfactotum/foliate-js.
  `Sources/EPUBViewing/Native/Position/` ports its `epubcfi.js`, `search.js` and
  `text-walker.js` to Swift, and the native viewer's column arithmetic follows its
  `paginator.js`. Its `LICENSE`, at that commit, is in `foliate-js/`. No foliate-js code ships
  in the package.
- **MathMLLayout 0.3.1** — MIT — Copyright (c) 2026 Vocaro Technologies LLC.
  https://github.com/vocaro/MathMLLayout. It draws
  with the copy of STIX Two Math (SIL Open Font License 1.1, Copyright 2001-2021 The STIX Fonts
  Project Authors) that macOS and iOS install; neither package distributes the font.
  Its speech vocabulary includes material adapted from MathCAT (MIT) and Speech Rule Engine
  (Apache-2.0). Its notices require an app containing it to include readable copies of all
  of its licenses and notices, which SwiftPM does not bundle. They are in `MathMLLayout/`, from
  tag `0.3.1`: its `LICENSE`, as `LICENSE.txt`, and the four files of its `doc/licenses`.
- **StaticSVG 0.1.1** — MIT — Copyright (c) 2026 Vocaro Technologies LLC.
  https://github.com/vocaro/StaticSVG. EPUBViewing draws SVG with it. Its release includes a
  static library built from **resvg 0.48.1** (MIT/Apache-2.0, https://github.com/linebender/resvg),
  the 60 other Rust crates it depends on and parts of the Rust 1.95.0 standard library, all under
  permissive licenses. An app linking EPUBViewing contains this static code, and StaticSVG's
  notices require it to include StaticSVG's license, those notices and the crates' texts.
  They are in `StaticSVG/`, from tag `0.1.1`, with the locked dependency inventory: its
  `LICENSE`, as `LICENSE.txt`, its `THIRD_PARTY_NOTICES.md`, its `Resvg/dependencies.json` and
  its `Resvg/Licenses/`, which holds every crate's and the Rust standard library's notices.
  How the library is built, patched and verified is in StaticSVG's
  [renderer notes](https://github.com/vocaro/StaticSVG/blob/0.1.1/doc/renderer.md).

The native viewer and its regression tests originate in StudyWright and EPUBLib,
Copyright (c) 2026 Vocaro Technologies LLC, and are distributed here under this repository's MIT
license, a copy of which is in `EPUBLib/`.
