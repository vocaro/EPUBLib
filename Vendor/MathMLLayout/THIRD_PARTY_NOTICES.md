# Third-party notices

MathMLLayout's original code is licensed under the [MIT license](../../LICENSE).
Selected localized speech vocabulary and regression expectations are adapted from
the following projects. Their notices and license conditions apply to the adapted
material; no third-party speech engine is bundled or required at runtime.

## MathCAT

[DAISY MathCAT](https://github.com/daisy/MathCAT), revision
`85c89a37073d6efdb08efba5765dd69c7efddaf9`.

Copyright (c) 2022 NSoiffer

Licensed under MIT; the complete copyright and permission notice is retained in
[doc/licenses/MathCAT-MIT.txt](MathCAT-MIT.txt).

Adapted material: French and German accent names and ∂ names, German ∮ name,
French comparison wording, Spanish double-dot accent name, English/French multiscript
names, French and Spanish ordinal-root templates, English point name,
the tensor multiscript regression structure, and selected regression expectations.
References for retained wording are also recorded in the
[speech wording audit](../speech-wording-audit.md).

## Speech Rule Engine

[Speech Rule Engine](https://github.com/Speech-Rule-Engine/speech-rule-engine), revision
`28cac44da8eba13bce646823183e959d6d943e79`.

Copyright 2014-2018 Volker Sorge

Licensed under Apache License, Version 2.0. The complete license is retained in
[doc/licenses/SRE-Apache-2.0.txt](SRE-Apache-2.0.txt), and the upstream NOTICE
is retained unchanged in [doc/licenses/SRE-NOTICE.txt](SRE-NOTICE.txt).

Adapted material: selected accent and operator names from the English, French, German, Spanish
and Italian `mathmaps` files; underbar actions, brace names and Italian caron wording;
bounded ordinal/digit vocabulary from number maps and number rules; punctuation and space names;
German overbar wording; Italian ClearSpeak bar wording;
French left- and right-script labels and German/Spanish/Italian positional script labels;
and selected regression expectations, including root readings. Compound closing phrases
are composed for MathMLLayout, and its reading order follows source order.
In MathMLLayout these are incorporated into Swift
phrase templates and isolated test formulas, with existing operand and alias handling.
The affected vocabulary and test files prominently identify this adaptation.
The [audit](../speech-wording-audit.md) records exact source files and decisions.
These adaptations retain the Apache license and notice obligations.

The adapted ClearSpeak fixtures also carry these attribution notices, retained here
from the pinned source files:

- German [root fixtures](https://github.com/Speech-Rule-Engine/speech-rule-engine/blob/28cac44da8eba13bce646823183e959d6d943e79/testsuite/expected/de/clearspeak/clearspeak_roots.json): "This work was sponsored by ETH Zurich".
- Italian [root fixtures](https://github.com/Speech-Rule-Engine/speech-rule-engine/blob/28cac44da8eba13bce646823183e959d6d943e79/testsuite/expected/it/clearspeak/clearspeak_roots.json): "With support from TextHelp."
- German [adornments fixtures](https://github.com/Speech-Rule-Engine/speech-rule-engine/blob/28cac44da8eba13bce646823183e959d6d943e79/testsuite/expected/de/clearspeak/clearspeak_part3_adornments.json): "This work was sponsored by ETH Zurich".
- Italian [adornments fixtures](https://github.com/Speech-Rule-Engine/speech-rule-engine/blob/28cac44da8eba13bce646823183e959d6d943e79/testsuite/expected/it/clearspeak/clearspeak_part3_adornments.json): "With support from TextHelp."

SRE's full original NOTICE is included for preservation. MathMLLayout does not use
SRE's browser or Node dependencies, including wicked good XPath.

## Bundled test corpora

Test resources under `Tests/MathMLLayoutTests/ExternalFixtures/Corpus` contain:

- MathML excerpts from OpenStax *Precalculus 2e*, Jay Abramson and contributing authors,
  Rice University, pinned to `openstax/osbooks-college-algebra-bundle` revision
  `4922e46ebc04326979e19392ccc2384cb8b9076c`. That snapshot is licensed CC-BY-4.0.
  Access for free at https://openstax.org/details/books/precalculus-2e.
  The complete license, original README and collection license metadata are retained in
  `openstax-precalculus/`. Changes: MathML extraction, namespace/whitespace normalization,
  inferred display mode and stratified sampling of 100 equations. Current upstream editions
  use different terms; those editions are not the source of the bundled excerpts.
- SRE MathML input excerpts from four Mathspeak regression files at the Apache-2.0 revision
  listed above. The complete license and unchanged upstream NOTICE are retained in
  `sre-mathspeak/`, together with a separate adaptation notice. Changes: standalone MathML
  wrappers, exact-input deduplication, omission of speech expectations and explicit expected
  rejection metadata for three incomplete script pairs.

Each manifest records source URLs and hashes. The
[corpus README](../../Tests/MathMLLayoutTests/ExternalFixtures/Corpus/README.md) describes
reproduction. Retain these resource licenses and attribution when redistributing the test
corpora. They are included only in the test target; compiled libraries and apps do not
bundle them by default, so the textbook license adds no acknowledgment requirement to
those distributions unless they also include the corpus.

## Redistributing MathMLLayout

For source distributions, retain this file, [LICENSE](../../LICENSE), the three files in
[doc/licenses](.), the corpus licenses/notices described above, and the adaptation notices
in the affected Swift files.
Keep those notices when modifying the adapted material, and identify further changes.

For compiled libraries or apps containing the adapted speech material, include readable
copies of this file, LICENSE, MathCAT-MIT.txt, SRE-Apache-2.0.txt and SRE-NOTICE.txt
with the distribution, for example in the app's bundled acknowledgments or accompanying
documentation. A link to this repository alone does not supply those copies.
SwiftPM does not automatically copy these notice and license files into an app bundle;
the distributing app or binary package must include them.

These instructions preserve the upstream MIT notice condition and Apache-2.0
[section 4](https://www.apache.org/licenses/LICENSE-2.0) requirements.
The MIT license for MathMLLayout's original code does not replace those conditions.
