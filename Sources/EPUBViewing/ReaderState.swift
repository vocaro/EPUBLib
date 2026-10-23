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
    /// The appearance the style resolves to: always Light or Dark, whether its theme's background
    /// is dark (`EPUBReaderColors.isDark`). Sepia is Light and Black is Dark. The mounted viewer's
    /// page takes it once text built for it is on screen, after a change when its section is rebuilt.
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
    /// Where the pages on screen sit in the reader's current pagination: page X of Y. nil in
    /// continuous scroll, before the first page is shown, and from engines that do not count
    /// pages. It changes as `location` does, and on its own as counting goes on and after a
    /// relayout; an engine sets it before it emits the `.relocated` of the pages it describes.
    public var layoutPage: EPUBLayoutPage?
    /// The colours the mounted viewer draws with: its theme's, as Increase Contrast leaves
    /// them. A host can draw its own controls in them.
    public var effectiveColors: EPUBReaderColors = .light
    /// The highlights of the latest `.setHighlights` that the reader does not draw, by their `id`,
    /// and why. Empty while it draws them all. A highlight whose passage is found missing only when
    /// its section is built joins it then. The bundled reader also gives one `.notice` for the
    /// list, a sentence for a person that names none of them (#698).
    public var undrawnHighlights: [String: EPUBHighlightFailure] = [:]
    public init(capabilities: Set<EPUBReaderCapability>) { self.capabilities = capabilities }
}

/// Why the reader does not draw a host's highlight (`EPUBReaderStatus.undrawnHighlights`).
public enum EPUBHighlightFailure: Hashable, Sendable {
    /// Its location belongs to another book or reader, or holds no position this reader can read,
    /// as `EPUBReaderError.incompatibleLocation` says of a position to restore.
    case incompatibleLocation
    /// Its passage is not in this book as the reader shows it: a part of it cannot be found, or
    /// it is only content that shows nothing.
    case passageNotFound
}

/// The pages on screen in the current paginated layout: "page 12 of 230", and the pages left
/// in the section. Indices count from 0, so page 12 is index 11. A layout's pages depend on the
/// reader's size, its text size and its style, so they are no part of a saved position, unlike
/// `EPUBLocation.progression`. Pages are counted a little at a time, and what is not counted
/// yet is nil: the section's count first, then the book's.
public struct EPUBLayoutPage: Hashable, Sendable {
    /// The first page on screen, counted from the book's first page: every page of each section
    /// page turns reach before this one, then `sectionIndex`. nil until those sections are
    /// counted, and for a section page turns do not reach, such as a nonlinear one shown by a link.
    public var index: Int?
    /// The book's pages: every page of each section page turns reach. nil until all are counted.
    public var count: Int?
    /// The first page on screen, counted from its section's first page.
    public var sectionIndex: Int
    /// The section's pages; nil until the section is counted.
    public var sectionCount: Int?
    /// The pages on screen: 1, or 2 when a spread shows two columns, and 1 when the second
    /// column of a spread at the end of a section is empty. A section starts on a spread's
    /// first column, so the empty column is no page and is not counted.
    public var shownCount: Int

    public init(index: Int?, count: Int?, sectionIndex: Int, sectionCount: Int?, shownCount: Int) {
        self.index = index; self.count = count; self.sectionIndex = sectionIndex
        self.sectionCount = sectionCount; self.shownCount = shownCount
    }
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
