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
    /// The completed search's result list and current match, from an engine with
    /// `.searchResults`. nil unless `search` is `.completed`.
    public var searchResults: EPUBSearchResults?
    public var activeCommands = 0
    /// The text size the engine draws, in points: `style.fontSize` times `dynamicTypeScale`,
    /// within the sizes it draws (12–96 for the bundled reader). nil from an engine that does not
    /// report it; the supplied controls then take `style.fontSize`.
    public var effectiveFontSize: Double?
    /// What the system text size multiplies `style.fontSize` by: the body text style's size at
    /// the mounted view's Dynamic Type size over its size at the default (Large), 53 / 17 at the
    /// largest accessibility size. 1 while `style.followsDynamicType` is off.
    public var dynamicTypeScale: Double = 1
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
