# Integration and verification

EPUBLib is an internal shared package. Consumers pin a reviewed commit; every product in the
package resolves from that revision. There is no public source-API compatibility promise.
Persisted publication identities, reading locations and consumer artifact contracts are separate
from source API compatibility and must be preserved or explicitly migrated.

For a module or import change, build the affected products, build the VoiceOver verification host, run the relevant
headless parser/extraction/writer tests and verify module boundaries and documentation.
Run platform builds where SDK or resource packaging changes. Live rendering tests remain
available on demand in [testing](testing.md); they are not implied by a package rename.

The engine identifier `org.epublib.reader` and the `epublib-cfi-v1` bookmark format are persisted
contracts: a viewer change keeps both and must keep resolving the CFIs recorded in
`CFIGoldenVectors.swift`.

A release is tagged only on a commit whose gate passed. Its
[GitHub release notes](https://github.com/vocaro/EPUBLib/releases) say what changed, its
requirements and its compatibility, not how it was verified; published notes are not rewritten.
The shared [releasing guide](https://github.com/vocaro/apple-engineering/blob/main/guides/releasing.md)
has the steps.
