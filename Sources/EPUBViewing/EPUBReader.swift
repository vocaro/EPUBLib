import EPUBCore
import EPUBReading
import SwiftUI

/// The package's EPUB viewer. Its renderer and bundled assets are implementation details.
@MainActor public struct EPUBReader: EPUBReaderEngine {
    /// Retained across the package rename so stored engine bookmarks remain valid.
    public static let identifier = FoliateEngine.identifier
    public var id: String { Self.identifier }
    public init() {}
    public func makeSession(publication: EPUBPublication, selectionAction: EPUBSelectionAction? = nil,
                            onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
        try FoliateEngine().makeSession(publication: publication, selectionAction: selectionAction, onEvent: onEvent)
    }
}
