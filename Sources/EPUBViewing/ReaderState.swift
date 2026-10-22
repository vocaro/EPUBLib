import EPUBCore
import Observation

public enum EPUBReaderLifecycle: Equatable, Sendable {
    case loading, ready, closed
    case failed(EPUBReaderError)
}

/// An engine's current control state. Unknown boundaries are nil and leave turns enabled.
public struct EPUBReaderStatus: Equatable, Sendable {
    public var lifecycle: EPUBReaderLifecycle = .loading
    public var capabilities: Set<EPUBReaderCapability>
    public var style = EPUBReaderStyle()
    /// The resolved appearance of the mounted viewer: always Light or Dark, whether its theme's
    /// background is dark (`EPUBReaderColors.isDark`). Sepia is Light and Black is Dark.
    public var effectiveAppearance: EPUBReaderAppearance = .light
    public var location: EPUBLocation?
    public var canGoPrevious: Bool?
    public var canGoNext: Bool?
    public var search: EPUBSearchState = .idle
    /// The completed search's result list and current match, from an engine with
    /// `.searchResults`. nil unless `search` is `.completed`.
    public var searchResults: EPUBSearchResults?
    public var activeCommands = 0
    /// The colours the mounted viewer draws with: its theme's, as Increase Contrast leaves
    /// them. A host can draw its own controls in them.
    public var effectiveColors: EPUBReaderColors = .light
    public init(capabilities: Set<EPUBReaderCapability>) { self.capabilities = capabilities }
}

/// Retained by the session. Engines update this alongside their events; hosts observe it
/// without replacing event callbacks. It remains available after close and on late attachment.
@MainActor @Observable public final class EPUBReaderState {
    public private(set) var status: EPUBReaderStatus
    public init(status: EPUBReaderStatus) { self.status = status }
    public func update(_ status: EPUBReaderStatus) {
        if self.status != status { self.status = status }
    }
    func modify(_ update: (inout EPUBReaderStatus) -> Void) {
        var value = status
        update(&value)
        self.update(value)
    }
}
