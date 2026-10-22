import Foundation

// A plain message for every failure the library throws or emits, which a host shows as it is
// (#698): `localizedDescription` says what happened and `recoverySuggestion`, where anything
// helps, what the reader can do. `String(describing:)` still gives the case and its detail, for a
// developer. Each message is looked up in this module's string catalog, `Localizable.xcstrings`,
// which holds English alone: translating it is #684's.

extension EPUBPublicationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedEncryption:
            String(localized: "This book is protected by DRM and cannot be opened. The file is not damaged.", bundle: .module,
                   comment: "A book encrypted by DRM, which the reader cannot read, was refused. Its file is intact.")
        case .notEPUB:
            String(localized: "This file is not an EPUB book.", bundle: .module,
                   comment: "A file that reads as a ZIP archive but is not marked as an EPUB book, such as another kind of document, was refused.")
        case .notArchive:
            String(localized: "This file is not an EPUB book, or it is damaged.", bundle: .module,
                   comment: "A file that is no ZIP archive was refused: another kind of file, or an EPUB book cut short, as by a download that did not finish.")
        case .invalidArchive:
            String(localized: "This book is damaged and cannot be opened.", bundle: .module,
                   comment: "An EPUB book whose archive is damaged, for example by a bad download or a failing disk, was refused.")
        case .unsafePath:
            String(localized: "This book cannot be opened because it refers to files outside the book.", bundle: .module,
                   comment: "A book that names a file outside itself as one of its parts, such as a page on a website, was refused.")
        case .limitExceeded:
            String(localized: "This book is too large to open.", bundle: .module,
                   comment: "A book larger than the reader's size limits allow, as a whole or in one of its parts, was refused.")
        case .missingResource:
            String(localized: "Part of this book is missing.", bundle: .module,
                   comment: "A file that the book needs, such as a chapter, is not in the book.")
        case .invalidXML:
            String(localized: "This book cannot be opened because it contains errors.", bundle: .module,
                   comment: "A book whose files that describe its parts and their order are malformed was refused.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedEncryption:
            String(localized: "Open it in the app it came from, or get a copy without DRM.", bundle: .module,
                   comment: "What to do with a book protected by DRM: read it where it was bought or borrowed, or find a copy that is not protected.")
        case .notEPUB, .unsafePath, .limitExceeded: nil
        case .notArchive:
            String(localized: "If it is an EPUB book, download it again or get another copy.", bundle: .module,
                   comment: "What to do with a file that is not an EPUB book or is damaged, in case it is a book cut short.")
        case .invalidArchive, .missingResource, .invalidXML:
            String(localized: "Download the book again, or get another copy.", bundle: .module,
                   comment: "What to do with a book that is damaged, incomplete or malformed.")
        }
    }
}

extension EPUBReaderError: LocalizedError {
    public var errorDescription: String? { plainMessage }

    public var recoverySuggestion: String? {
        switch self {
        case .notReady:
            String(localized: "Try again in a moment.", bundle: .module,
                   comment: "What to do when the reader was asked for something before it had finished opening the book.")
        case .unsupported, .incompatibleLocation, .invalidCommand, .closed, .engineFailure: nil
        }
    }

    /// `errorDescription`, which is never nil.
    var plainMessage: String {
        switch self {
        case .unsupported:
            String(localized: "This reader does not support this action.", bundle: .module,
                   comment: "The reader was asked for something it cannot do, such as searching or going to a bookmark.")
        case .incompatibleLocation:
            String(localized: "This saved position belongs to a different book or reader.", bundle: .module,
                   comment: "A bookmark or saved reading position from another book, or from another reader app, was refused.")
        case .invalidCommand:
            String(localized: "The reader cannot carry out this request.", bundle: .module,
                   comment: "The reader was asked for something that does not apply to this book, such as going to a part it does not have.")
        case .notReady:
            String(localized: "The reader is not ready.", bundle: .module,
                   comment: "The reader was asked for something before it had finished opening the book.")
        case .closed:
            String(localized: "This book is closed.", bundle: .module,
                   comment: "The reader was asked for something after its book was closed.")
        case .engineFailure:
            String(localized: "The reader cannot show this book.", bundle: .module,
                   comment: "The reader failed while opening or showing the book.")
        }
    }
}
