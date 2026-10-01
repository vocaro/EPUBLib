import OSLog
import EPUBCore
import EPUBReading
import SwiftUI
import WebKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class ReaderEPUBPrototypeModel {
    enum Status: Equatable {
        case loading
        case ready(ReaderEPUBReadiness)
        case failed(String)
    }

    var onMessage: ((ReaderEPUBMessage) -> Void)?
    var onNotice: ((String) -> Void)?
    private(set) var status: Status = .loading
    private(set) var location: ReaderEPUBLocation?
    private(set) var selection: ReaderEPUBSelection?
    private(set) var refusals: [String] = []

    @ObservationIgnored weak var webView: WKWebView?

    func send(_ command: ReaderEPUBCommand) {
        guard let webView else { return }
        do {
            let js = try command.javaScript()
            webView.evaluateJavaScript(js) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor in
                    self?.record(refusal: "the host's own command failed: \(error)")
                }
            }
        } catch {
            record(refusal: String(describing: error))
        }
    }

    func apply(_ message: ReaderEPUBMessage) {
        switch message {
        case .ready(let readiness):
            status = .ready(readiness)
        case .relocated(let location):
            self.location = location
        case .selected(let selection):
            self.selection = selection
        case .selectionCleared:
            selection = nil
        case .pageNotice(let detail):
            record(refusal: "the reader page reported: \(detail)")
        case .failed(let reason):
            status = .failed(reason)
        }
        onMessage?(message)
    }

    private static let log = Logger(
        subsystem: "org.epubreaderlib.foliate", category: "reader.epub")

    func record(refusal: String) {
        onNotice?(refusal)
        Self.log.error("EPUB reader refusal: \(refusal, privacy: .public)")
        if refusals.count < 200 { refusals.append(refusal) }
    }
}

enum ReaderEPUBNavigation {
    static let allowedSchemes: Set<String> = [ReaderEPUBRouter.scheme, "blob", "about"]

    static func allows(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme else { return false }
        return allowedSchemes.contains(scheme.lowercased())
    }

    static let webKitErrorDomain = "WebKitErrorDomain"
    static let frameLoadInterruptedByPolicyChange = 102

    static func isCancellation(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return true }
        return error.domain == webKitErrorDomain
            && error.code == frameLoadInterruptedByPolicyChange
    }
}

enum ReaderEPUBPageTurnCommand: Equatable, Sendable {
    case next
    case previous
}

enum ReaderEPUBPageTurnKey {
    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124
    private static let pageUp: UInt16 = 116
    private static let pageDown: UInt16 = 121
    private static let space: UInt16 = 49

    static func command(forKeyCode keyCode: UInt16, hasShift: Bool) -> ReaderEPUBPageTurnCommand? {
        switch keyCode {
        case leftArrow, pageUp: .previous
        case rightArrow, pageDown: .next
        case space: hasShift ? .previous : .next
        default: nil
        }
    }

    static func command(for key: KeyEquivalent, hasShift: Bool) -> ReaderEPUBPageTurnCommand? {
        switch key {
        case .leftArrow, .pageUp: .previous
        case .rightArrow, .pageDown: .next
        case .space: hasShift ? .previous : .next
        default: nil
        }
    }
}

struct ReaderEPUBWebView {
    let source: ReaderEPUBAssetSource
    let model: ReaderEPUBPrototypeModel
    let onAskAboutSelection: (String) -> Void
    var isDark = false
    var selectionActionTitle: String? = nil
    var selectionActionImage: String = "text.quote"

    static let messageHandlerName = "studywrightReader"

    #if os(macOS)
    /// Marks the reader page as macOS before bootstrap.js runs. The Mac host keeps its controls in
    /// the window toolbar rather than floating over the page, so bootstrap.js skips the
    /// continuous-scroll edge fade when this class is present. The strips are page DOM, so the
    /// mark has to reach the page; a user script is not subject to the page's script-src policy.
    static let macOSPageClass = "sw-macos"
    static let macOSPageScriptSource =
        "document.documentElement.classList.add('\(macOSPageClass)')"
    #endif

    @MainActor private func applyAppearance(to view: ReaderEPUBSelectingWebView) {
        #if os(iOS)
        let background = isDark ? UIColor.black : UIColor.white
        view.isOpaque = false
        view.backgroundColor = background
        view.scrollView.backgroundColor = background
        view.underPageBackgroundColor = background
        // Let the enclosing navigation toolbar supply its live safe-area clearance.
        view.scrollView.contentInsetAdjustmentBehavior = .automatic
        let inset = UIEdgeInsets(top: 48, left: 0, bottom: 64, right: 0)
        if view.scrollView.contentInset != inset {
            view.scrollView.contentInset = inset
        }
        if #available(iOS 26, *) {
            view.scrollView.topEdgeEffect.style = .soft
            view.scrollView.bottomEdgeEffect.style = .soft
        }
        #elseif os(macOS)
        view.underPageBackgroundColor = isDark ? .black : .white
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        #endif
    }

    @MainActor func makeView(coordinator: Coordinator) -> ReaderEPUBSelectingWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            ReaderEPUBSchemeHandler(source: source) { [weak coordinator] refusal in
                coordinator?.model.record(refusal: refusal.description)
            },
            forURLScheme: ReaderEPUBRouter.scheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(
            coordinator, name: Self.messageHandlerName)
        #if os(macOS)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.macOSPageScriptSource, injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        #endif
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = ReaderEPUBSelectingWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.allowsBackForwardNavigationGestures = false
        view.selectionActionTitle = selectionActionTitle
        view.selectionActionImage = selectionActionImage
        view.selectedPassage = { [weak coordinator] in coordinator?.model.selection?.text }
        view.askAboutSelection = { [weak coordinator] in
            guard let text = coordinator?.model.selection?.text else { return }
            coordinator?.parent.onAskAboutSelection(text)
        }
        view.pageTurnHandler = { [weak coordinator] command in
            coordinator?.model.send(command == .next ? .nextPage : .previousPage)
        }
        #if os(iOS)
        view.scrollView.bounces = false
        #endif
        view.isInspectable = false
        applyAppearance(to: view)
        coordinator.model.webView = view
        coordinator.pageNavigation = view.load(URLRequest(url: ReaderEPUBRouter.pageURL))
        return view
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate,
                                        WKUIDelegate {
        var parent: ReaderEPUBWebView
        var model: ReaderEPUBPrototypeModel { parent.model }
        fileprivate var pageNavigation: WKNavigation?
        init(parent: ReaderEPUBWebView) { self.parent = parent }


        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.name == ReaderEPUBWebView.messageHandlerName else { return }
            guard message.frameInfo.isMainFrame else {
                return model.record(refusal: "a subframe tried to message the host")
            }
            do {
                model.apply(try ReaderEPUBMessageDecoder.decode(message.body))
            } catch {
                model.record(refusal: String(describing: error))
            }
        }


        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard ReaderEPUBNavigation.allows(action.request.url) else {
                model.record(
                    refusal: "navigation refused: \(action.request.url?.scheme ?? "no scheme")")
                return .cancel
            }
            return .allow
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
        ) {
            handle(error, for: navigation)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            handle(error, for: navigation)
        }

        private func handle(_ error: any Error, for navigation: WKNavigation?) {
            if ReaderEPUBNavigation.isCancellation(error) {
                return model.record(
                    refusal: "navigation cancelled: \(error.localizedDescription)")
            }
            if let pageNavigation, navigation === pageNavigation {
                return model.apply(.failed(reason: error.localizedDescription))
            }
            if pageNavigation == nil, case .loading = model.status {
                return model.apply(.failed(reason: error.localizedDescription))
            }
            model.record(
                refusal: "a subordinate navigation failed: \(error.localizedDescription)")
        }


        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? { nil }

        func webView(
            _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void
        ) { completionHandler() }

        func webView(
            _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void
        ) { completionHandler(false) }

        func webView(
            _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?, initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor (String?) -> Void
        ) { completionHandler(nil) }
    }
}

final class ReaderEPUBSelectingWebView: WKWebView {
    var selectionActionTitle: String?
    var selectionActionImage = "text.quote"
    var selectedPassage: (@MainActor () -> String?)?
    var askAboutSelection: (@MainActor () -> Void)?
    var pageTurnHandler: (@MainActor (ReaderEPUBPageTurnCommand) -> Void)?

    #if os(iOS)
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard let selectionActionTitle else { return }
        builder.insertSibling(
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: selectionActionTitle,
                    image: UIImage(systemName: selectionActionImage)
                ) {
                    [weak self] _ in self?.askAboutSelection?()
                }
            ]), beforeMenu: .lookup)
    }
    #elseif os(macOS)
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let selectionActionTitle, selectedPassage?() != nil else { return }
        menu.addItem(.separator())
        let item = NSMenuItem(
            title: selectionActionTitle,
            action: #selector(askAboutThis), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func askAboutThis() { askAboutSelection?() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let command = ReaderEPUBPageTurnKey.command(
            forKeyCode: event.keyCode, hasShift: event.modifierFlags.contains(.shift))
        else {
            super.keyDown(with: event)
            return
        }
        pageTurnHandler?(command)
    }
    #endif
}

#if os(iOS)
extension ReaderEPUBWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> ReaderEPUBSelectingWebView {
        makeView(coordinator: context.coordinator)
    }
    func updateUIView(_ view: ReaderEPUBSelectingWebView, context: Context) {
        context.coordinator.parent = self
        applyAppearance(to: view)
    }
}
#elseif os(macOS)
extension ReaderEPUBWebView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> ReaderEPUBSelectingWebView {
        makeView(coordinator: context.coordinator)
    }
    func updateNSView(_ view: ReaderEPUBSelectingWebView, context: Context) {
        context.coordinator.parent = self
        applyAppearance(to: view)
    }
}
#endif
