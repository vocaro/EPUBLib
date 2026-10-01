import EPUBViewing
import EPUBCore
import EPUBReading
import EPUBViewing
import Foundation
import Observation

// snippet:start lifecycle
@MainActor @Observable
final class BookReader {
    private(set) var publication: EPUBPublication?
    private(set) var session: (any EPUBReaderSession)?
    private(set) var ready = false
    private(set) var loading = false
    private(set) var busy = false
    private(set) var location: EPUBLocation?
    private(set) var disclosure: String?
    private(set) var notice: String?
    private(set) var selectedText: String?
    private(set) var error: String?
    private var opening: Task<Void, Never>?
    private var commands: Task<Void, Never>?
    private var generation = UUID()
    private var latestCommand = UUID()
    var sessionID: UUID { generation }

    func reportImportError(_ error: Error) { self.error = error.localizedDescription }

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
                self.error = String(describing: error)
            }
            if let self, generation == token { loading = false; opening = nil }
        }
    }

    func install(_ book: EPUBPublication, engine: any EPUBReaderEngine) throws {
        let token = generation
        publication = book
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
                case .failed(let value): error = String(describing: value); ready = false
                case .selectionChanged: break
                }
            })
    }

    func send(_ command: EPUBReaderCommand) {
        guard ready, let session else { return }
        let previous = commands
        let token = generation
        let commandID = UUID()
        latestCommand = commandID
        busy = true
        commands = Task { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                try await session.send(command)
            } catch is CancellationError {
            } catch {
                guard let self, generation == token else { return }
                self.error = String(describing: error)
            }
            if let self, generation == token, latestCommand == commandID { busy = false }
        }
    }

    func savePosition() {
        guard let location, let data = try? JSONEncoder().encode(location) else { return }
        UserDefaults.standard.set(data, forKey: "position.\(location.publicationID)")
        notice = "Position saved."
    }

    func restorePosition() {
        guard let publication,
              let data = UserDefaults.standard.data(forKey: "position.\(publication.id)"),
              let saved = try? JSONDecoder().decode(EPUBLocation.self, from: data) else {
            notice = "No saved position for this book."; return
        }
        send(.restore(saved))
    }

    func close() {
        generation = UUID()
        opening?.cancel(); opening = nil
        commands?.cancel(); commands = nil
        session?.close(); session = nil
        publication = nil; ready = false; loading = false; busy = false
        location = nil; disclosure = nil; notice = nil; selectedText = nil; error = nil
    }
}
// snippet:end lifecycle
