import Foundation

// A plain message for each extraction failure, as `EPUBPublicationError` has (#698), looked up in
// this module's string catalog, `Localizable.xcstrings`, which holds English alone (#684).
extension EPUBTextExtractionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSpineIndex:
            String(localized: "This part of the book does not exist.", bundle: .module,
                   comment: "The text of a part of the book was asked for, by its place in the reading order, and the book has no part there.")
        case .unsupportedMediaType:
            String(localized: "The text in this part of the book is in a format that cannot be read.", bundle: .module,
                   comment: "The text of a part of the book was asked for, and that part is in a format whose text is not read, such as a drawing.")
        case .malformedContent:
            String(localized: "The text in this part of the book cannot be read because it contains errors.", bundle: .module,
                   comment: "The text of a part of the book was asked for, and that part is malformed.")
        case .limitExceeded:
            String(localized: "This part of the book is too large to read as text.", bundle: .module,
                   comment: "The text of a part of the book was asked for, and that part is larger or more deeply nested than the limits allow.")
        }
    }
}
