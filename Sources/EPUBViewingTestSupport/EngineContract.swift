import EPUBCore
import EPUBReading
import EPUBViewing
import Foundation

/// Reusable, toolkit-independent checks. Link this product to an adapter's test target.
/// Use a two-section publication and mount the supplied session in a real visible test window.
@MainActor public enum EPUBEngineContract {
    public struct Failure: LocalizedError, CustomStringConvertible {
        public let description: String
        public var errorDescription: String? { description }
    }

    /// Tests lifecycle, advertised commands, cancellation, location identity and bookmark restoration.
    /// Rendering fidelity, input gestures and resource release require adapter-specific tests.
    /// The mount closure returns cleanup; it must retain its window until cleanup runs.
    public static func verify(
        engine: any EPUBReaderEngine, publication: EPUBPublication,
        firstHref: String, secondHref: String, text: String,
        timeout: TimeInterval = 20,
        mount: (any EPUBReaderSession) throws -> (@MainActor () -> Void)
    ) async throws {
        var events: [EPUBReaderEvent] = []
        let session = try engine.makeSession(publication: publication, selectionAction: nil) { events.append($0) }
        defer { session.close() }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: message) }
        }
        try require(timeout.isFinite && timeout > 0, "Timeout must be positive and finite")
        try require(firstHref != secondHref && publication.spine.contains { $0.resource.href == firstHref }
            && publication.spine.contains { $0.resource.href == secondHref }, "Provide two distinct spine resource hrefs")
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if let failure = events.compactMap({ event -> EPUBReaderError? in
                    if case .failed(let error) = event { return error }; return nil
                }).first { throw Failure(description: "Engine failed: \(failure)") }
                guard Date() < deadline else { throw Failure(description: "Timed out waiting for \(label)") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func expect(_ command: EPUBReaderCommand, error expected: EPUBReaderError) async throws {
            do { try await session.send(command) }
            catch let error as EPUBReaderError {
                try require(error == expected, "Expected \(expected), received \(error)")
                return
            }
            throw Failure(description: "Accepted command that should throw \(expected)")
        }
        func locations(since index: Int = 0) -> [EPUBLocation] {
            events.dropFirst(index).compactMap {
                if case .relocated(let location) = $0 { return location }; return nil
            }
        }
        let cancelled = Task { try await session.send(.nextPage) }
        cancelled.cancel()
        do { try await cancelled.value; throw Failure(description: "Pre-cancelled command was accepted") }
        catch is CancellationError {}
        let unmount = try mount(session)
        defer { unmount() }
        try await wait("ready") { events.contains(.ready) }
        if session.capabilities.contains(.navigateHref) {
            try await session.send(.navigate(href: firstHref))
            try await wait("first href") { locations().last?.href == firstHref }
            let saved = locations().last!
            try require(saved.publicationID == publication.id, "Wrong publication identity")
            let secondStart = events.count
            try await session.send(.navigate(href: secondHref))
            try await wait("second href") { locations(since: secondStart).contains { $0.href == secondHref } }
            if session.capabilities.contains(.bookmarks) {
                try require(saved.bookmark?.engineID == engine.id, "Missing or wrong bookmark engine identity")
                let restoreStart = events.count
                try await session.send(.restore(saved))
                try await wait("restoration") { locations(since: restoreStart).contains { $0.href == saved.href } }
                var foreign = saved
                foreign.publicationID += "-different"
                try await expect(.restore(foreign), error: .incompatibleLocation)
                foreign = saved; foreign.bookmark?.engineID += "-different"
                try await expect(.restore(foreign), error: .incompatibleLocation)
                foreign = saved; foreign.bookmark?.format += "-different"
                try await expect(.restore(foreign), error: .incompatibleLocation)
            }
        }
        if !session.capabilities.contains(.bookmarks) {
            try await expect(.restore(.init(publicationID: publication.id)), error: .unsupported(.bookmarks))
        } else {
            try await wait("bookmark") { locations().contains { $0.bookmark != nil } }
            for location in locations() {
                try require(location.publicationID == publication.id, "Location belongs to another publication")
                if let bookmark = location.bookmark {
                    try require(bookmark.engineID == engine.id && !bookmark.format.isEmpty && !bookmark.value.isEmpty,
                                "Invalid engine bookmark")
                }
            }
        }
        let commands: [(EPUBReaderCapability, EPUBReaderCommand)] = [
            (.pagination, .nextPage), (.pagination, .previousPage),
            (.navigateHref, .navigate(href: firstHref)),
            (.locateText, .locate(text: text, highlight: false)),
            (.searchHighlight, .searchHighlight(text: text)), (.searchHighlight, .clearSearch),
            (.highlights, .setHighlights([])),
        ]
        for (capability, command) in commands {
            if session.capabilities.contains(capability) { try await session.send(command) }
            else { try await expect(command, error: .unsupported(capability)) }
        }
        if session.capabilities.contains(.typography) {
            try await session.send(.style(.init(fontSize: 21)))
        } else { try await expect(.style(.init(fontSize: 21)), error: .unsupported(.typography)) }
        if session.capabilities.contains(.scrolling) {
            try await session.send(.style(.init(flow: .scrolled)))
            try await session.send(.style(.init()))
        } else { try await expect(.style(.init(flow: .scrolled)), error: .unsupported(.scrolling)) }
        try require(!events.contains { if case .failed = $0 { return true }; return false }, "Engine emitted a failure")
        try require(events.filter { $0 == .ready }.count == 1, "Ready must be emitted exactly once")
        let count = events.count
        session.close(); session.close()
        try await expect(.nextPage, error: .closed)
        try await Task.sleep(for: .milliseconds(150))
        try require(events.count == count, "Callback after close")
    }
}
