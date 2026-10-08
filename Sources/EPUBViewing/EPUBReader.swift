import EPUBCore
import EPUBReading
import SwiftUI

/// The package's EPUB viewer: native TextKit 2 rendering. Its renderer is an implementation detail.
@MainActor public struct EPUBReader: EPUBReaderEngine {
    /// The engine identity stored in this reader's bookmarks, `org.epublib.reader`.
    public static let identifier = NativeEngine.identifier
    /// The format of this reader's bookmarks, `epublib-cfi-v1`: the value is an EPUB CFI.
    public static let bookmarkFormat = NativeEngine.bookmarkFormat
    public var id: String { Self.identifier }
    public init() {}
    public func makeSession(publication: EPUBPublication, selectionAction: EPUBSelectionAction? = nil,
                            onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
        try NativeEngine().makeSession(publication: publication, selectionAction: selectionAction, onEvent: onEvent)
    }
}
