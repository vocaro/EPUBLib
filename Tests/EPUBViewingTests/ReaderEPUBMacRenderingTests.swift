#if os(macOS)
import WebKit
import XCTest
@testable import EPUBViewing

@MainActor
final class ReaderEPUBMacRenderingTests: XCTestCase {
    private static let unusedSource = ReaderEPUBAssetSource(
        resourceRoot: URL(fileURLWithPath: "/nonexistent/epub-reader"),
        bookURL: URL(fileURLWithPath: "/nonexistent/book.epub"))

    private func makeWebView(isDark: Bool) -> ReaderEPUBSelectingWebView {
        let representable = ReaderEPUBWebView(
            source: Self.unusedSource, model: ReaderEPUBPrototypeModel(),
            onAskAboutSelection: { _ in }, isDark: isDark)
        let coordinator = representable.makeCoordinator()
        return representable.makeView(coordinator: coordinator)
    }

    func testDarkAppearanceIsAppliedExplicitlyToTheWebViewOnMac() {
        let view = makeWebView(isDark: true)
        XCTAssertEqual(
            view.appearance?.name, NSAppearance.Name.darkAqua,
            "a dark-appearance reader web view should carry an explicit dark NSAppearance, so "
                + "a live web content process cannot resolve its own prefers-color-scheme "
                + "independently of the app's real appearance")
    }

    func testLightAppearanceIsAppliedExplicitlyToTheWebViewOnMac() {
        let view = makeWebView(isDark: false)
        XCTAssertEqual(
            view.appearance?.name, NSAppearance.Name.aqua,
            "a light-appearance reader web view should carry an explicit light NSAppearance, for "
                + "the same reason as the dark case")
    }

    func testReaderPageIsMarkedAsMacBeforeBootstrapRuns() {
        let scripts = makeWebView(isDark: false).configuration.userContentController.userScripts
        let mark = scripts.filter { $0.source == ReaderEPUBWebView.macOSPageScriptSource }
        XCTAssertEqual(mark.count, 1, "the Mac reader page should be marked exactly once")
        XCTAssertEqual(mark.first?.injectionTime, .atDocumentStart)
        XCTAssertEqual(mark.first?.isForMainFrameOnly, true)
    }
}
#endif
