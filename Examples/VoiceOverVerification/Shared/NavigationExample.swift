import EPUBCore
import EPUBReading
import EPUBViewing

// snippet:start navigation
/// Call after the session emits `.ready`.
@MainActor
func navigateToFirstSection(publication: EPUBPublication, session: any EPUBReaderSession) async throws {
    guard session.capabilities.contains(.navigateHref),
          let first = publication.spine.first(where: { $0.isLinear }) else { return }
    // href is URL-encoded; path is the decoded key used for publication.data(at:).
    try await session.send(.navigate(href: first.resource.href))
}
// snippet:end navigation
