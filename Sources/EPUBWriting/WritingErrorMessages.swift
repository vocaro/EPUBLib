import Foundation

// A plain message for each failure to write a book, as `EPUBPublicationError` has (#698), looked up
// in this module's string catalog, `Localizable.xcstrings`, which holds English alone (#684).
extension EPUBWritingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPublication:
            String(localized: "This book cannot be saved as an EPUB because it has errors.", bundle: .module,
                   comment: "A book could not be written as an EPUB file because something it needs is missing or does not match, such as its title or a chapter its contents list.")
        case .resourceLimit:
            String(localized: "This book is too large to save as an EPUB.", bundle: .module,
                   comment: "A book could not be written as an EPUB file because it is larger than the limits allow.")
        }
    }
}
