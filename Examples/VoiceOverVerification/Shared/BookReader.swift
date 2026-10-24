import EPUBViewing
import EPUBCore
import EPUBReading
import Foundation
import Observation

// snippet:start lifecycle
@MainActor @Observable
final class BookReader {
    private(set) var publication: EPUBPublication?
    private(set) var session: (any EPUBReaderSession)?
    private(set) var controls: EPUBReaderControls?
    private(set) var ready = false
    private(set) var loading = false
    var busy: Bool { controls?.isBusy == true }
    private(set) var location: EPUBLocation?
    private(set) var savedPosition: EPUBLocation?
    private(set) var disclosure: String?
    private(set) var notice: String?
    private(set) var selection: String?
    /// Where the selection is: what to keep for a highlight of it.
    private(set) var selectionLocation: EPUBLocation?
    private(set) var selectedText: String?
    private(set) var error: String?
    private var opening: Task<Void, Never>?
    private var generation = UUID()
    var sessionID: UUID { generation }

    func reportImportError(_ error: Error) { self.error = Self.message(for: error) }

    /// What to tell the reader: what went wrong and, where the error says, what to do about it.
    nonisolated static func message(for error: Error) -> String {
        let error = error as NSError
        return [error.localizedDescription, error.localizedRecoverySuggestion].compactMap { $0 }.joined(separator: " ")
    }

    func open(url: URL) {
        close()
        loading = true
        let token = generation
        opening = Task { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let work = Task.detached { try EPUBPublication.open(at: url) }
            do {
                let book = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard let self, generation == token else { return }
                try install(book, engine: EPUBReader())
            } catch is CancellationError {
                // Closing or opening another book intentionally cancels the previous import.
            } catch {
                guard let self, generation == token else { return }
                self.error = Self.message(for: error)
            }
            if let self, generation == token { loading = false; opening = nil }
        }
    }

    func install(_ book: EPUBPublication, engine: any EPUBReaderEngine) throws {
        let token = generation
        publication = book
        // Saved under the book's persistentID, or under an identity it had before.
        if let data = book.publicationIDs.lazy.compactMap({ UserDefaults.standard.data(forKey: "position.\($0)") }).first {
            savedPosition = try? JSONDecoder().decode(EPUBLocation.self, from: data)
        }
        session = try engine.makeSession(publication: book,
            selectionAction: EPUBSelectionAction(title: "Use passage") { [weak self] selection in
                guard let self, generation == token else { return }
                selectedText = selection.text
            }, onEvent: { [weak self] event in
                guard let self, generation == token else { return }
                switch event {
                case .ready: ready = true
                case .relocated(let value): location = value
                case .disclosure(let value): disclosure = value
                case .notice(let value): notice = value
                case .failed(let value): error = Self.message(for: value); ready = false
                case .selectionChanged(let value): selection = value?.text; selectionLocation = value?.location
                case .searchChanged, .searchResultsChanged: break
                }
            })
        if let session { controls = EPUBReaderControls(publication: book, session: session) }
    }

    func send(_ command: EPUBReaderCommand) {
        controls?.send(command)
    }

    func savePosition() {
        guard let location else {
            notice = "Reading position is not available yet."
            return
        }
        do {
            let data = try JSONEncoder().encode(location)
            UserDefaults.standard.set(data, forKey: "position.\(location.publicationID)")
            savedPosition = location
            notice = "Bookmark saved."
        } catch {
            self.error = "Could not save the bookmark: \(error.localizedDescription)"
        }
    }

    func restorePosition() {
        guard let savedPosition else {
            notice = "No bookmark saved for this book."
            return
        }
        send(.restore(savedPosition))
    }

    func clearPosition() {
        guard let publication else { return }
        for id in publication.publicationIDs { UserDefaults.standard.removeObject(forKey: "position.\(id)") }
        savedPosition = nil
        notice = "Bookmark cleared."
    }

    func close() {
        generation = UUID()
        opening?.cancel(); opening = nil
        controls?.cancelPendingCommands(); controls = nil
        session?.close(); session = nil
        publication = nil; ready = false; loading = false
        location = nil; disclosure = nil; notice = nil; selection = nil; selectionLocation = nil; selectedText = nil; error = nil
        savedPosition = nil
    }
}
// snippet:end lifecycle
