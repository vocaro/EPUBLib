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
    /// The resolved appearance of the mounted viewer: always Light or Dark.
    public var effectiveAppearance: EPUBReaderAppearance = .light
    public var location: EPUBLocation?
    public var canGoPrevious: Bool?
    public var canGoNext: Bool?
    public var search: EPUBSearchState = .idle
    public var activeCommands = 0
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
