import EPUBCore
import EPUBReading
import SwiftUI

/// The package's EPUB viewer: native TextKit 2 rendering. Its renderer is an implementation detail.
@MainActor public struct EPUBReader: EPUBReaderEngine {
    /// Unchanged since the WebKit reader, so stored `epubcfi-v1` bookmarks remain valid.
    public static let identifier = NativeEngine.identifier
    public var id: String { Self.identifier }
    public init() {}
    public func makeSession(publication: EPUBPublication, selectionAction: EPUBSelectionAction? = nil,
                            onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
        try NativeEngine().makeSession(publication: publication, selectionAction: selectionAction, onEvent: onEvent)
    }
}
