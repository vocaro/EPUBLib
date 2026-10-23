import EPUBCore
import Foundation

// What a reader is told when a command is refused or a search fails (#698): a plain sentence,
// which the reader's controls show as it is. An engine's own detail is for a developer: the
// error keeps it, and `String(describing:)` gives it. Each sentence is looked up in this
// module's string catalog, `Localizable.xcstrings`, which holds English alone: translating it is
// #684's.

public extension EPUBReaderError {
    /// What the reader's controls show for a refused command or a failed search: a plain sentence.
    /// For a request the bundled reader refuses, it says why; otherwise it is
    /// `localizedDescription`, since the detail of another engine's `invalidCommand` or
    /// `engineFailure` is for a developer.
    var message: String { NativeRefusal(self)?.message ?? localizedDescription }
}

/// Why the bundled reader refused a command. The raw value is the detail its `invalidCommand`
/// carries, for a developer; `message` is what a reader is told.
enum NativeRefusal: String, CaseIterable {
    /// `.navigate(href:)` with an empty href, a fragment alone or more than 4,096 characters.
    case emptyHref = "Empty publication href"
    /// `.navigate(href:)` with an href that names no file of the book, or a place outside it.
    case unknownHref = "Unknown publication href"
    /// `.navigate(href:)` with an href that names a file of the book that is not one of its
    /// sections and has none to fall back on, such as an image or a style sheet.
    case notASection = "Not a section of this publication"
    /// `.goToProgression` with a number that is not finite.
    case nonfiniteProgression = "The progression is not a finite number"
    /// `.locate` with a passage that is empty once normalized or longer than
    /// `NativeSession.maximumQuoteLength`.
    case passageLength = "The passage to locate is empty or too long"
    /// `.search` or `.searchHighlight` with text that is empty once normalized or longer than
    /// `NativeSession.maximumSearchLength`.
    case searchLength = "The search text is empty or too long"
    /// `.showSearchResult` with a result that the current search does not list.
    case staleSearchResult = "That search result is no longer available"
    /// `.style` with a font size that is not finite.
    case nonfiniteFontSize = "Nonfinite font size"
    /// `.style` with a spacing or margin in its typography that is not finite.
    case nonfiniteTypography = "A typography setting is not a finite number"

    init?(_ error: EPUBReaderError) {
        guard case .invalidCommand(let detail) = error else { return nil }
        self.init(rawValue: detail)
    }

    var error: EPUBReaderError { .invalidCommand(rawValue) }

    var message: String {
        switch self {
        case .emptyHref, .unknownHref:
            String(localized: "That part of the book cannot be found.", bundle: .module,
                   comment: "The reader was asked to go to a part of the book that the book does not have, as by an entry in its contents that leads nowhere.")
        case .notASection:
            String(localized: "That part of the book cannot be shown.", bundle: .module,
                   comment: "The reader was asked to go to a file of the book that is not a page of text, such as a picture, as by an entry in its contents.")
        case .nonfiniteProgression:
            String(localized: "That place in the book cannot be found.", bundle: .module,
                   comment: "The reader was asked to go to a place in the book given as a fraction of the way through it, and the fraction was not a number or was infinite.")
        case .passageLength:
            String(localized: "The passage to find is empty or longer than 4,096 characters.", bundle: .module,
                   comment: "The reader was asked to find and show a passage, such as a quotation, that is empty or longer than the reader looks for.")
        case .searchLength:
            String(localized: "The search is empty or longer than 512 characters.", bundle: .module,
                   comment: "A search was refused because its text is empty or longer than the reader searches for.")
        case .staleSearchResult:
            String(localized: "That search result is no longer available.", bundle: .module,
                   comment: "A search result was chosen after the search it came from was replaced or cleared.")
        case .nonfiniteFontSize:
            String(localized: "That text size cannot be used.", bundle: .module,
                   comment: "The reader was asked to show the book's text at a size that is not a number or is infinite.")
        case .nonfiniteTypography:
            String(localized: "That spacing or margin cannot be used.", bundle: .module,
                   comment: "The reader was asked to space the book's lines, paragraphs, letters or words, or to set its page margins, by an amount that is not a number or is infinite.")
        }
    }
}
