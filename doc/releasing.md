# Integration and verification

EPUBLib is an internal shared package. Consumers pin a reviewed commit; every product in the
package resolves from that revision. There is no public source-API compatibility promise.
Persisted publication identities, reading locations and consumer artifact contracts are separate
from source API compatibility and must be preserved or explicitly migrated.

For a module or import change, build the affected products, compile the sample, run the relevant
headless parser/extraction/writer tests and verify module boundaries and documentation.
Run platform builds where SDK or resource packaging changes. Live rendering tests remain
available on demand in [testing](testing.md); they are not implied by a package rename.

The engine identifier and `epubcfi-v1` bookmark format are persisted contracts: a viewer change
must keep resolving the CFIs recorded in `CFIGoldenVectors.swift`. Historical version verification
documents record their own producing revision and are not rewritten by a module move.
