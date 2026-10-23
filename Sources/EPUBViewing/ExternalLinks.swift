import Foundation
import SwiftUI

/// What the bundled reader does with a link outside the book that a reader activates, by
/// pointer, keyboard or VoiceOver, in the text, in a table cell or in a note's popover. Change
/// it on a mounted view with `epubReaderExternalLinks(_:)`.
///
/// Only a link to a web page or an email address, an `http` or `https` URL with a host or a
/// `mailto` URL with an address, is ever opened or given to a host. Any other link outside the
/// book (`javascript:`, `file:`, `data:`, `tel:`, an app's own scheme, or an address with no
/// scheme) is never opened or passed on: the reader reports it with a `.notice` and does
/// nothing else. Remote images, fonts and style sheets are never fetched, whatever this says.
public struct EPUBExternalLinks: Sendable {
    /// The default. The reader asks first, naming the address, and when the reader chooses
    /// Open, opens it with the view's `openURL` action: the system's, unless the host has set
    /// its own, so a web page opens in the browser and an email address in the mail app
    /// (EPUB Reading Systems 3.3 §3.9).
    public static let ask = Self(behavior: .ask)
    /// Refuses every link outside the book with the notice "This reader does not open links
    /// outside the book.", as the reader did before it asked.
    public static let refuse = Self(behavior: .refuse)
    /// Gives the link's URL to `open` and does not ask: the host asks, if it wants to, and
    /// opens the link or not. Only `http`, `https` and `mailto` URLs are given.
    public static func handle(_ open: @escaping @MainActor @Sendable (URL) -> Void) -> Self {
        Self(behavior: .handle(open))
    }

    enum Behavior: Sendable {
        case ask, refuse
        case handle(@MainActor @Sendable (URL) -> Void)
    }

    let behavior: Behavior
}

public extension View {
    /// Says what the native reader does with a link outside the book that a reader activates:
    /// asks before opening it (the default), refuses it, or gives it to the host.
    func epubReaderExternalLinks(_ links: EPUBExternalLinks) -> some View {
        environment(\.epubReaderExternalLinks, links)
    }
}

extension EnvironmentValues {
    @Entry var epubReaderExternalLinks = EPUBExternalLinks.ask
}

/// A link outside the book that may be opened, and what the reader says of it.
struct ExternalLinkAddress: Equatable, Sendable {
    /// The link as the system opens it: percent-encoded, with an international domain name in
    /// its ASCII form, so the address shown cannot be reordered or disguised by the characters
    /// a book puts in it.
    let url: URL

    /// The longest address shown in full. A longer one is shown to there and "…": what it
    /// opens, its scheme and host, comes first.
    static let shownLength = 1_000

    /// A web page with a host, or an email address; nil for anything else.
    init?(_ href: String) {
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": guard let host = url.host(), !host.isEmpty else { return nil }
        case "mailto": guard !url.path().isEmpty else { return nil }
        default: return nil
        }
        self.url = url
    }

    var shown: String {
        let address = url.absoluteString
        return address.count <= Self.shownLength ? address : String(address.prefix(Self.shownLength)) + "…"
    }
}

/// The question the reader asks before opening a link outside the book.
struct ExternalLinkQuestion: Equatable {
    static let title = "Open a link outside the book?"
    static let open = "Open"
    static let cancel = "Cancel"
    let address: ExternalLinkAddress
    var title: String { Self.title }
    var message: String { address.shown }
}
