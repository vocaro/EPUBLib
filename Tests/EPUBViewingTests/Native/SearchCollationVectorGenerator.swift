#if os(macOS)
import AppKit
import CryptoKit
import WebKit
import XCTest

/// Opt-in recorder using unchanged `search.js` and `text-walker.js` from the former reader.
/// Extract them from commit `6e6930c^` and provide EPUBLIB_FOLIATE_SEARCH_SOURCE and
/// EPUBLIB_FOLIATE_TEXT_WALKER_SOURCE; set EPUBLIB_GENERATE_SEARCH_COLLATION_VECTORS=1.
@MainActor final class SearchCollationVectorGenerator: XCTestCase {
    func testRecordSearchCollationVectors() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPUBLIB_GENERATE_SEARCH_COLLATION_VECTORS"] == "1",
              let searchPath = environment["EPUBLIB_FOLIATE_SEARCH_SOURCE"],
              let walkerPath = environment["EPUBLIB_FOLIATE_TEXT_WALKER_SOURCE"] else {
            throw XCTSkip("opt in and supply the historical Foliate search and walker sources")
        }
        func module(_ path: String, exports: String) throws -> String {
            let source = try String(contentsOfFile: path, encoding: .utf8)
                .components(separatedBy: "\n").map { $0.hasPrefix("export ") ? String($0.dropFirst(7)) : $0 }.joined(separator: "\n")
            return "(() => { \(source); return { \(exports) }; })()"
        }
        func sha256(_ path: String) throws -> String {
            SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
        }
        let fixtures = SearchCollationFixtures.fixtures.map { ["locale": $0.locale, "query": $0.query, "markup": $0.markup] }
        let input = String(decoding: try JSONSerialization.data(withJSONObject: fixtures), as: UTF8.self)
        let script = """
        (() => {
            try {
                const Search = \(try module(searchPath, exports: "searchMatcher"));
                const Walker = \(try module(walkerPath, exports: "textWalker"));
                const search = Search.searchMatcher(Walker.textWalker, {});
                const output = {
                    userAgent: navigator.userAgent,
                    source: '4b7942d4d1682e60f505cb161c87b7757fb927ee',
                    searchSourceSHA256: '\(try sha256(searchPath))',
                    walkerSourceSHA256: '\(try sha256(walkerPath))',
                    fixtures: [],
                };
                for (const fixture of \(input)) {
                    const doc = new DOMParser().parseFromString(fixture.markup, 'application/xhtml+xml');
                    const nodes = [];
                    const visit = node => { nodes.push(node); for (const child of node.childNodes) visit(child); };
                    visit(doc.documentElement);
                    const matches = Array.from(search(doc, fixture.query), ({range}) => [
                        nodes.indexOf(range.startContainer), range.startOffset,
                        nodes.indexOf(range.endContainer), range.endOffset,
                    ]);
                    output.fixtures.push({ locale: fixture.locale, query: fixture.query, matches });
                }
                return JSON.stringify(output, null, 2);
            } catch (error) { return JSON.stringify({ error: String(error), stack: error.stack }); }
        })()
        """
        prepareMacTestApplication()
        _ = NSApplication.shared
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = makeMacTestWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.contentView = nil; window.close() }
        let loader = SearchReferenceDocumentLoader()
        webView.navigationDelegate = loader
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            loader.continuation = continuation
            webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        }
        let result: String = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value = value as? String { continuation.resume(returning: value) }
                else { continuation.resume(throwing: NSError(domain: "Foliate search reference", code: 1)) }
            }
        }
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        guard decoded["fixtures"] != nil else { return XCTFail(result) }
        let source = "// Recorded from the historical Foliate matcher in WebKit. Do not edit.\n"
            + "// Regenerate with SearchCollationVectorGenerator and the sources from 6e6930c^.\n"
            + "enum SearchCollationGoldenVectors {\n    static let json = ##\"\"\"\n" + result + "\n\"\"\"##\n}\n"
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "SearchCollationGoldenVectors.swift")
        try source.write(to: destination, atomically: true, encoding: .utf8)
    }
}

@MainActor private final class SearchReferenceDocumentLoader: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, any Error>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}
#endif
