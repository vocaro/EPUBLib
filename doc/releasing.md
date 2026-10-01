# Integration and verification

EPUBLib is an internal shared package. Consumers pin a reviewed commit; every product in the
package resolves from that revision. There is no public source-API compatibility promise.
Persisted publication identities, reading locations and consumer artifact contracts are separate
from source API compatibility and must be preserved or explicitly migrated.

For a module or import change, build the affected products, compile the sample, run the relevant
headless parser/extraction/writer/bridge tests and verify vendor identities and documentation.
Run platform builds where SDK or resource packaging changes. Live rendering tests remain
available on demand in [testing](testing.md); they are not implied by a package rename.

Upstream Foliate resources remain pinned and unchanged. The URL compatibility patch checks each
substitution before serving assets. Historical version verification documents record their own
producing revision and are not rewritten by a module move.
