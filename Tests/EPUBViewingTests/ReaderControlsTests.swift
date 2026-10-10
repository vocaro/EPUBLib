import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing

@MainActor final class ReaderControlsTests: XCTestCase {
    private final class Session: EPUBReaderSession {
        let capabilities: Set<EPUBReaderCapability> = [.pagination, .scrolling, .typography, .searchHighlight, .navigateHref]
        let readerState: EPUBReaderState?
        var received: [EPUBReaderCommand] = []
        var failure: EPUBReaderError?
        init() {
            let state = EPUBReaderState(status: .init(capabilities: capabilities))
            state.modify { $0.lifecycle = .ready }
            readerState = state
        }
        func makeView() -> AnyView { AnyView(EmptyView()) }
        func send(_ command: EPUBReaderCommand) async throws {
            if let failure { throw failure }
            received.append(command)
            if case .style(let style) = command { readerState?.modify { $0.style = style } }
            await Task.yield()
        }
        func close() { readerState?.modify { $0.lifecycle = .closed } }
    }
    private func controls(_ session: Session) throws -> EPUBReaderControls {
        EPUBReaderControls(publication: try EPUBPublication.open(data: Fixture.epub()), session: session)
    }
    func testFIFOAndRapidStyleEditsPreserveOtherFields() async throws {
        let session = Session(), model = try controls(session)
        session.readerState?.modify { $0.style = .init(fontSize: 20, isDark: true, flow: .scrolled) }
        model.changeStyle { $0.fontSize += 2 }
        model.changeStyle { $0.fontSize += 2 }
        model.changeStyle { $0.flow = .paginated }
        model.send(.nextPage)
        XCTAssertEqual(model.pendingCommands, 4)
        await model.waitForCommands()
        XCTAssertEqual(session.received, [.style(.init(fontSize: 22, isDark: true, flow: .scrolled)),
                                          .style(.init(fontSize: 24, isDark: true, flow: .scrolled)),
                                          .style(.init(fontSize: 24, isDark: true)), .nextPage])
        XCTAssertFalse(model.isBusy)
    }
    func testTypingSubmitClearAndCommandErrors() async throws {
        let session = Session(), model = try controls(session)
        model.searchText = "chapter"
        XCTAssertTrue(session.received.isEmpty)
        model.submitSearch()
        model.clearSearch()
        model.searchText = " \n "
        model.submitSearch()
        await model.waitForCommands()
        XCTAssertEqual(session.received, [.searchHighlight(text: "chapter"), .clearSearch, .clearSearch])
        session.failure = .invalidCommand("rejected")
        model.send(.nextPage)
        await model.waitForCommands()
        XCTAssertNotNil(model.commandError)
        XCTAssertFalse(model.isBusy)
        model.dismissError()
        XCTAssertNil(model.commandError)
    }
    func testClosedFailedAndCanceledQueuesDoNotSubmit() async throws {
        let session = Session(), model = try controls(session)
        model.send(.nextPage)
        session.close()
        await model.waitForCommands()
        XCTAssertTrue(session.received.isEmpty)
        XCTAssertFalse(model.canGoNext)
        session.readerState?.modify { $0.lifecycle = .failed(.engineFailure("failed")) }
        model.send(.previousPage)
        XCTAssertEqual(model.pendingCommands, 0)
        session.readerState?.modify { $0.lifecycle = .ready }
        model.send(.nextPage)
        model.cancelPendingCommands()
        await Task.yield()
        XCTAssertTrue(session.received.isEmpty)
        XCTAssertFalse(model.isBusy)
    }
    func testCapabilitiesBoundariesAndCurrentNestedContents() throws {
        let session = Session(), model = try controls(session)
        session.readerState?.modify {
            $0.canGoPrevious = false
            $0.canGoNext = true
            $0.location = .init(publicationID: model.publication.id, href: "OPS/one.xhtml", title: "First Chapter")
        }
        XCTAssertFalse(model.canGoPrevious)
        XCTAssertTrue(model.canGoNext)
        XCTAssertTrue(model.isCurrent(.init(title: "First Chapter", href: "OPS/one.xhtml#start")))
        XCTAssertFalse(model.isCurrent(.init(title: "Other", href: "OPS/one.xhtml#later")))
        XCTAssertFalse(model.isCurrent(.init(title: "First Chapter", href: "OPS/two.xhtml")))
        session.readerState?.modify { $0.capabilities = [.pagination]; $0.style.flow = .scrolled }
        XCTAssertFalse(model.canGoNext)
        XCTAssertFalse(model.supports(.searchHighlight))
    }
    func testLegacyConformerAndToolbarFreeViewRemainUsable() throws {
        final class Legacy: EPUBReaderSession {
            var capabilities: Set<EPUBReaderCapability> { [] }
            func makeView() -> AnyView { AnyView(EmptyView()) }
            func send(_ command: EPUBReaderCommand) async throws {}
            func close() {}
        }
        let legacy = Legacy()
        XCTAssertNil(legacy.readerState)
        _ = EPUBReaderView(session: legacy)
        let model = EPUBReaderControls(publication: try EPUBPublication.open(data: Fixture.epub()), session: legacy)
        XCTAssertFalse(model.isReady)
    }
}
