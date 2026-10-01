import EPUBCore
import EPUBReading
import EPUBViewing
import EPUBViewing
import Foundation

// snippet:start parsing
// Call off the main actor. Keep security-scoped file access active until this returns.
func readPublication(at bookURL: URL) throws -> EPUBPublication {
    let publication = try EPUBPublication.open(at: bookURL)
    print(publication.metadata.title)
    for chapter in publication.spine {
        let bytes = try publication.data(for: chapter.resource)
        print(chapter.resource.path, bytes.count)
    }
    return publication
}
// snippet:end parsing

// snippet:start session
@MainActor
func makeReader(publication: EPUBPublication,
                onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
    let engine: any EPUBReaderEngine = EPUBReader()
    return try engine.makeSession(
        publication: publication,
        selectionAction: EPUBSelectionAction(title: "Use passage") { selection in
            print(selection.text)
        },
        onEvent: onEvent
    )
}
// snippet:end session
