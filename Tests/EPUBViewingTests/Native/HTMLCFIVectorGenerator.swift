#if os(macOS)
import Foundation
import AppKit
import WebKit
import XCTest

/// Opt-in reference recorder. Supply the unchanged historical upstream78914aef epubcfi.js
/// with EPUBLIB_FOLIATE_CFI_SOURCE; the production reader has no WebKit dependency.
@MainActor final class HTMLCFIVectorGenerator: XCTestCase {
    func testRecordFoliateHTMLRanges() async throws {
        print("Foliate reference: preparing fixture source")
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPUBLIB_GENERATE_HTML_CFI_VECTORS"] == "1",
              let path = environment["EPUBLIB_FOLIATE_CFI_SOURCE"] else {
            throw XCTSkip("opt in and supply historical foliate epubcfi.js to record HTML vectors")
        }
        let foliate = try String(contentsOfFile: path, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.hasPrefix("export ") ? String($0.dropFirst(7)) : $0 }.joined(separator: "\n")
        let input = HTMLCFIFixtures.fixtures.map { ["name": $0.name, "markup": $0.markup, "quote": $0.quote] }
        let inputJSON = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        print("Foliate reference: creating WebKit document")
        let script = """
        (() => {
            try {
            const CFI = (() => { \(foliate); return { fromRange, toRange, parse }; })();
            const fixtures = \(inputJSON);
            const output = { userAgent: navigator.userAgent, upstream: '78914aef4466eb960965702401634c2cb348e9b1', documents: [] };
            for (const fixture of fixtures) {
                let document = new DOMParser().parseFromString(fixture.markup, 'application/xhtml+xml');
                if (document.querySelector('parsererror') || !document.documentElement?.namespaceURI)
                    document = new DOMParser().parseFromString(fixture.markup, 'text/html');
                const model = [], records = new Map();
                const build = element => {
                    model.push(['E', element.localName, element.namespaceURI ?? '']);
                    let pending = '';
                    const flush = () => { if (pending !== '') { model.push(['T', pending]); pending = ''; } };
                    for (const child of element.childNodes) {
                        if (child.nodeType === 1) { flush(); build(child); }
                        else if (child.nodeType === 3 || child.nodeType === 4) {
                            records.set(child, { order: model.length, base: pending.length });
                            pending += child.nodeValue;
                        }
                    }
                    flush();
                };
                build(document.documentElement);
                const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
                let text, target;
                while ((text = walker.nextNode())) {
                    const offset = text.nodeValue.indexOf(fixture.quote);
                    if (offset >= 0) { target = { text, offset }; break; }
                }
                if (!target) throw new Error('quote not found: ' + fixture.name);
                const range = document.createRange();
                range.setStart(target.text, target.offset);
                range.setEnd(target.text, target.offset + fixture.quote.length);
                const cfi = CFI.fromRange(range), restored = CFI.toRange(document, CFI.parse(cfi));
                const record = records.get(target.text);
                output.documents.push({ name: fixture.name, model, cfi, quote: restored.toString(),
                    start: [record.order, record.base + target.offset], end: [record.order, record.base + target.offset + fixture.quote.length] });
            }
            return JSON.stringify(output, null, 2);
            } catch (error) { return JSON.stringify({ error: String(error), stack: error.stack }); }
        })()
        """
        _ = NSApplication.shared
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.contentView = nil; window.close() }
        let loader = ReferenceDocumentLoader()
        webView.navigationDelegate = loader
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            loader.continuation = continuation
            webView.loadHTMLString("<!doctype html><html><head></head><body></body></html>", baseURL: nil)
        }
        print("Foliate reference: evaluating original epubcfi.js")
        let result: String = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value = value as? String { continuation.resume(returning: value) }
                else { continuation.resume(throwing: NSError(domain: "Foliate reference", code: 1)) }
            }
        }
        withExtendedLifetime(webView) {}
        print("Foliate reference: recording reference output")
        let json = result
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        guard decoded["documents"] != nil else { return XCTFail(json) }
        let source = "// Recorded from historical Foliate in WebKit by HTMLCFIVectorGenerator. Do not edit.\n"
            + "enum HTMLCFIGoldenVectors {\n    static let json = ##\"\"\"\n" + json + "\n\"\"\"##\n}\n"
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "HTMLCFIGoldenVectors.swift")
        try source.write(to: destination, atomically: true, encoding: .utf8)
    }
}

@MainActor private final class ReferenceDocumentLoader: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, any Error>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}
#endif
