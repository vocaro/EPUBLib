# Third-party notices

- **ZIPFoundation 0.9.20** — MIT — Copyright Thomas Zoechling.
  https://github.com/weichsel/ZIPFoundation. Its Swift package includes its MIT license.
- **foliate-js** at `78914aef4466eb960965702401634c2cb348e9b1` — MIT —
  Copyright (c) 2022 John Factotum. https://github.com/johnfactotum/foliate-js.
  `Sources/EPUBViewing/Native/Position/` ports its `epubcfi.js`, `search.js` and
  `text-walker.js` to Swift, and the native viewer's column arithmetic follows its
  `paginator.js`. The license follows. No foliate-js file ships in the package.
- **MathMLLayout 0.3.1** — MIT — Copyright (c) 2026 Vocaro Technologies LLC.
  https://github.com/vocaro/MathMLLayout. Its Swift package includes its MIT license. It draws
  with the copy of STIX Two Math (SIL Open Font License 1.1, Copyright 2001-2021 The STIX Fonts
  Project Authors) that macOS and iOS install; neither package distributes the font.
  Its speech vocabulary includes material adapted from MathCAT (MIT) and Speech Rule Engine
  (Apache-2.0). Readable copies of all required licenses and notices are retained unchanged in
  [Vendor/MathMLLayout](../Vendor/MathMLLayout), from tag `0.3.1`. Applications distributing EPUBViewing must include these copies in their own
  acknowledgments or accompanying documentation; SwiftPM does not bundle them automatically.
- **StaticSVG 0.1.0** — MIT — Copyright (c) 2026 Vocaro Technologies LLC.
  https://github.com/vocaro/StaticSVG. EPUBViewing draws SVG with it. Its release includes a
  static library built from **resvg 0.48.1** (MIT/Apache-2.0, https://github.com/linebender/resvg),
  the 60 other Rust crates it depends on and parts of the Rust 1.95.0 standard library, all under
  permissive licenses. Readable copies of StaticSVG's license, the locked dependency inventory and
  the complete dependency and Rust standard-library notices are retained unchanged in
  [Vendor/StaticSVG](../Vendor/StaticSVG/README.md), from tag `0.1.0`. Applications distributing
  EPUBViewing contain this static code and must include these notices in their own
  acknowledgments or accompanying documentation; SwiftPM does not bundle them automatically.
  How the library is built, patched and verified is in StaticSVG's
  [renderer notes](https://github.com/vocaro/StaticSVG/blob/0.1.0/doc/renderer.md).

The native viewer and its regression tests originate in StudyWright and EPUBLib,
Copyright (c) 2026 Vocaro Technologies LLC, and are distributed here under this repository's MIT license.

## foliate-js license

```text
MIT License

Copyright (c) 2022 John Factotum

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
