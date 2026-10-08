import EPUBCore
import EPUBReading
import SwiftUI

public struct EPUBSelectionAction {
    public var title: String
    public var systemImage: String
    public var perform: @MainActor (EPUBSelection) -> Void
    public init(title: String, systemImage: String = "text.quote",
                perform: @escaping @MainActor (EPUBSelection) -> Void) {
        self.title = title; self.systemImage = systemImage; self.perform = perform
    }
}

/// An engine constructs a session using a validated publication. Implementations may use any native view technology.
@MainActor public protocol EPUBReaderEngine {
    var id: String { get }
    func makeSession(publication: EPUBPublication, selectionAction: EPUBSelectionAction?,
                     onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession
}

/// The host retains one session per mounted reader. Close it when the book leaves the UI.
/// `send` acknowledges submission, not navigation completion; observe events for resulting positions/errors.
/// Cancellation before submission has no effect; after submission it cannot undo a displayed page turn.
@MainActor public protocol EPUBReaderSession: AnyObject {
    var capabilities: Set<EPUBReaderCapability> { get }
    func makeView() -> AnyView
    func send(_ command: EPUBReaderCommand) async throws
    /// Idempotent. Releases engine resources and suppresses subsequent callbacks.
    func close()
}

/// Mount exactly once per session. The host supplies its own loading, error, disclosure and toolbar UI.
public struct EPUBReaderView: View {
    private let session: any EPUBReaderSession
    public init(session: any EPUBReaderSession) { self.session = session }
    public var body: some View { session.makeView() }
}

public extension View {
    /// Reserves a vertical division of the reader, such as a fold or hinge, in the coordinate
    /// space of the `EPUBReaderView` it is applied to. In paginated flow a spread puts its gutter
    /// on the division; text never crosses it. Horizontal divisions and nil reserve nothing.
    func epubReaderDivision(_ frame: CGRect?) -> some View { environment(\.epubReaderDivision, frame) }
}

extension EnvironmentValues {
    @Entry var epubReaderDivision: CGRect? = nil
}
