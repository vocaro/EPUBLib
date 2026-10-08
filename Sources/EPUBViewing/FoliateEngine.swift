import EPUBCore
import EPUBReading
import Foundation
import SwiftUI
import WebKit

/// The bundled, pinned foliate-js implementation. The host never needs its JavaScript bridge types.
@MainActor struct FoliateEngine: EPUBReaderEngine {
    static let identifier = "org.epubreaderlib.foliate"
    var id: String { Self.identifier }
    init() {}
    func makeSession(publication: EPUBPublication, selectionAction: EPUBSelectionAction? = nil,
                            onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
        try FoliateSession(publication: publication, action: selectionAction, onEvent: onEvent)
    }
}

@MainActor @Observable final class FoliateSession: EPUBReaderSession {
    var capabilities: Set<EPUBReaderCapability> { Set<EPUBReaderCapability>([
        .navigateHref, .pagination, .scrolling, .typography, .selection, .bookmarks, .locateText, .searchHighlight,
    ]).subtracting(publication.spine.contains { $0.layout == .prePaginated } ? [.scrolling, .typography] : []) }
    let publication: EPUBPublication
    let model = ReaderEPUBPrototypeModel()
    let source: ReaderEPUBAssetSource
    let action: EPUBSelectionAction?
    var onEvent: (@MainActor (EPUBReaderEvent) -> Void)?
    var style = EPUBReaderStyle()
    var closed = false
    var didBecomeReady = false

    init(publication: EPUBPublication, action: EPUBSelectionAction?,
         onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws {
        self.publication = publication; self.action = action; self.onEvent = onEvent
        guard var source = ReaderEPUBAssetSource.bundled(bookURL: URL(fileURLWithPath: "/unused.epub")),
              ReaderEPUBAssets.missingFiles(under: source.libraryRoot).isEmpty else {
            throw EPUBReaderError.engineFailure("Missing bundled Foliate resources")
        }
        source.bookData = publication.archiveData
        self.source = source
        model.onMessage = { [weak self] in self?.receive($0) }
        model.onNotice = { [weak self] in self?.emit(.notice($0)) }
    }

    func makeView() -> AnyView { AnyView(FoliateSurface(session: self)) }

    func close() {
        guard !closed else { return }
        closed = true
        onEvent = nil
        model.onMessage = nil
        model.onNotice = nil
        if let view = model.webView {
            view.stopLoading()
            view.configuration.userContentController.removeScriptMessageHandler(forName: ReaderEPUBWebView.messageHandlerName)
            view.navigationDelegate = nil
            view.uiDelegate = nil
            view.loadHTMLString("", baseURL: nil)
        }
        model.webView = nil
    }

    func send(_ command: EPUBReaderCommand) async throws {
        try Task.checkCancellation()
        guard !closed else { throw EPUBReaderError.closed }
        guard case .ready = model.status, let webView = model.webView else { throw EPUBReaderError.notReady }
        let commands: [ReaderEPUBCommand]
        switch command {
        case .nextPage: commands = [.nextPage]
        case .previousPage: commands = [.previousPage]
        case .navigate(let href):
            guard let reference = href.split(separator: "#", maxSplits: 1).first, !href.hasPrefix("#") else {
                throw EPUBReaderError.invalidCommand("Empty publication href")
            }
            let path = String(reference).removingPercentEncoding
            guard let path, publication.resources.contains(where: { $0.path == path }),
                  let components = URLComponents(string: href),
                  components.scheme == nil, components.host == nil, components.query == nil else {
                throw EPUBReaderError.invalidCommand("Unknown publication href")
            }
            commands = [.navigate(href: href)]
        case .restore(let location):
            guard location.publicationID == publication.id, let bookmark = location.bookmark,
                  bookmark.engineID == FoliateEngine.identifier, bookmark.format == "epubcfi-v1",
                  ReaderEPUBCFI.isWellFormed(bookmark.value) else { throw EPUBReaderError.incompatibleLocation }
            commands = [.goTo(cfi: bookmark.value)]
        case .locate(let text, let highlight): commands = [.locate(quote: text, highlight: highlight)]
        case .searchHighlight(let text): commands = [.search(query: text)]
        case .clearSearch: commands = [.clearSearch]
        case .style(let newStyle):
            guard newStyle.fontSize.isFinite else { throw EPUBReaderError.invalidCommand("Nonfinite font size") }
            if newStyle.flow == .scrolled && !capabilities.contains(.scrolling) {
                throw EPUBReaderError.unsupported(.scrolling)
            }
            if newStyle.fontSize != style.fontSize && !capabilities.contains(.typography) {
                throw EPUBReaderError.unsupported(.typography)
            }
            var update: [ReaderEPUBCommand] = [.setStyle(css: ReaderEPUBTypography.css(
                fontSizePoints: newStyle.fontSize, isDark: newStyle.isDark))]
            if newStyle.flow != style.flow {
                update.append(.setFlow(newStyle.flow == .paginated ? .paginated : .scrolled))
                if let cfi = model.location?.cfi { update.append(.goTo(cfi: cfi)) }
            }
            commands = update
            style = newStyle
        }
        for command in commands {
            try Task.checkCancellation()
            guard !closed else { throw EPUBReaderError.closed }
            let js: String
            do { js = try command.javaScript() }
            catch { throw EPUBReaderError.invalidCommand(String(describing: error)) }
            do { _ = try await webView.evaluateJavaScript(js) }
            catch { throw EPUBReaderError.engineFailure(error.localizedDescription) }
        }
    }

    func performSelection() {
        guard !closed, let selection = model.selection else { return }
        action?.perform(EPUBSelection(text: selection.text,
            location: location(cfi: selection.cfi, quote: selection.text)))
    }

    private func emit(_ event: EPUBReaderEvent) { if !closed { onEvent?(event) } }
    private func location(cfi: String?, quote: String? = nil, section: Int? = nil,
                          fraction: Double? = nil, title: String? = nil) -> EPUBLocation {
        let href = section.flatMap { publication.spine.indices.contains($0) ? publication.spine[$0].resource.href : nil }
        return EPUBLocation(publicationID: publication.id, href: href, progression: fraction,
            title: title, quote: quote, bookmark: cfi.map {
                EPUBEngineBookmark(engineID: FoliateEngine.identifier, format: "epubcfi-v1", value: $0)
            })
    }
    private func receive(_ message: ReaderEPUBMessage) {
        switch message {
        case .ready(let readiness):
            if !didBecomeReady {
                didBecomeReady = true
                emit(.ready)
            }
            if let text = ReaderEPUBDisclosure.text(for: readiness) { emit(.disclosure(text)) }
        case .relocated(let value):
            emit(.relocated(location(cfi: value.cfi, section: value.sectionIndex,
                                     fraction: value.fraction, title: value.sectionTitle)))
        case .selected(let value):
            emit(.selectionChanged(EPUBSelection(text: value.text, location: location(cfi: value.cfi, quote: value.text))))
        case .selectionCleared: emit(.selectionChanged(nil))
        case .pageNotice: break // Forwarded through onNotice once.
        case .failed(let reason): emit(.failed(.engineFailure(reason)))
        }
    }
}

private struct FoliateSurface: View {
    let session: FoliateSession
    var body: some View {
        if !session.closed {
            ZStack {
                ReaderEPUBWebView(source: session.source, model: session.model,
                    onAskAboutSelection: { _ in session.performSelection() }, isDark: session.style.isDark,
                    isScrolled: session.style.flow == .scrolled, selectionActionTitle: session.action?.title, selectionActionImage: session.action?.systemImage ?? "text.quote")
                if session.style.flow == .paginated {
                    HStack(spacing: 0) {
                        zone(.previousPage)
                        Spacer(minLength: 0)
                        zone(.nextPage)
                    }
                }
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .pageUp, .pageDown, .space]) { press in
                guard let command = ReaderEPUBPageTurnKey.command(for: press.key, hasShift: press.modifiers.contains(.shift)) else { return .ignored }
                submit(command == .next ? .nextPage : .previousPage)
                return .handled
            }
            .accessibilityScrollAction { edge in
                if edge == .leading { submit(.previousPage) }
                if edge == .trailing { submit(.nextPage) }
            }
            .accessibilityAction(named: Text("Next Page")) { submit(.nextPage) }
            .accessibilityAction(named: Text("Previous Page")) { submit(.previousPage) }
        }
    }
    private func zone(_ command: EPUBReaderCommand) -> some View {
        Color.clear.frame(width: 56).contentShape(Rectangle())
            .onTapGesture { submit(command) }.accessibilityHidden(true)
    }
    private func submit(_ command: EPUBReaderCommand) {
        Task { @MainActor in
            do { try await session.send(command) }
            catch { session.onEvent?(.notice(String(describing: error))) }
        }
    }
}
