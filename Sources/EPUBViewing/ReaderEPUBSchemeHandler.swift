import Foundation
import WebKit

enum ReaderEPUBRoute: Equatable, Sendable {
    case page
    case bootstrap
    case library(String)
    case book
}

enum ReaderEPUBRefusal: Error, Equatable, CustomStringConvertible, Sendable {
    case unexpectedScheme(String?)
    case unexpectedHost(String?)
    case unknownPath(String)
    case notInManifest(String)
    case unreadable(String)
    case outsideBounds(String)

    var description: String {
        switch self {
        case .unexpectedScheme(let scheme):
            "the reader scheme handler was asked for scheme \(scheme ?? "none")"
        case .unexpectedHost(let host):
            "the reader scheme handler was asked for host \(host ?? "none")"
        case .unknownPath(let path):
            "the reader has no resource at \(path)"
        case .notInManifest(let path):
            "\(path) is not a vendored reader asset"
        case .unreadable(let path):
            "the reader asset at \(path) could not be read"
        case .outsideBounds(let path):
            "\(path) resolves outside the reader's asset bounds"
        }
    }
}

enum ReaderEPUBRouter {
    static let scheme = "sw-reader"
    static let host = "book"
    static var origin: String { "\(scheme)://\(host)" }
    static var pageURL: URL { URL(string: "\(origin)/index.html")! }

    static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'self'",
        "style-src 'self' blob: data: 'unsafe-inline'",
        "img-src 'self' blob: data:",
        "font-src 'self' blob: data:",
        "media-src blob: data:",
        "frame-src blob:",
        "connect-src 'self' blob:",
        "worker-src 'none'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
    ].joined(separator: "; ")

    static func route(for url: URL) -> Result<ReaderEPUBRoute, ReaderEPUBRefusal> {
        guard url.scheme == scheme else { return .failure(.unexpectedScheme(url.scheme)) }
        guard url.host() == host else { return .failure(.unexpectedHost(url.host())) }
        let path = url.path()
        switch path {
        case "", "/", "/index.html": return .success(.page)
        case "/bootstrap.js": return .success(.bootstrap)
        case "/book.epub": return .success(.book)
        default:
            guard path.hasPrefix("/lib/") else { return .failure(.unknownPath(path)) }
            let name = String(path.dropFirst("/lib/".count))
            guard ReaderEPUBAssets.servableLibraryPaths.contains(name) else {
                return .failure(.notInManifest(name))
            }
            return .success(.library(name))
        }
    }

    static func mediaType(for route: ReaderEPUBRoute) -> String {
        switch route {
        case .page: "text/html; charset=utf-8"
        case .bootstrap: "text/javascript; charset=utf-8"
        case .book: "application/epub+zip"
        case .library(let name):
            name.hasSuffix(".js") ? "text/javascript; charset=utf-8" : "text/plain; charset=utf-8"
        }
    }
}

struct ReaderEPUBAssetSource: Sendable {
    let resourceRoot: URL
    let bookURL: URL
    var bookData: Data? = nil

    static func bundled(bookURL: URL, bundle: Bundle = .module) -> ReaderEPUBAssetSource? {
        guard let root = bundle.url(
            forResource: ReaderEPUBAssets.resourceDirectory, withExtension: nil)
        else { return nil }
        return ReaderEPUBAssetSource(resourceRoot: root, bookURL: bookURL)
    }

    var libraryRoot: URL {
        resourceRoot.appending(path: ReaderEPUBAssets.libraryDirectory)
    }

    func resolve(_ route: ReaderEPUBRoute) -> Result<URL, ReaderEPUBRefusal> {
        switch route {
        case .page: bounded(resourceRoot.appending(path: "index.html"), within: resourceRoot)
        case .bootstrap: bounded(resourceRoot.appending(path: "bootstrap.js"), within: resourceRoot)
        case .library(let name): bounded(libraryRoot.appending(path: name), within: libraryRoot)
        case .book: .success(bookURL)
        }
    }

    private func bounded(_ candidate: URL, within root: URL) -> Result<URL, ReaderEPUBRefusal> {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = resolvedRoot.pathComponents
        let components = resolved.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return .failure(.outsideBounds(candidate.lastPathComponent))
        }
        return .success(resolved)
    }
}

@MainActor
final class ReaderEPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    private let source: ReaderEPUBAssetSource
    private let onRefusal: @MainActor (ReaderEPUBRefusal) -> Void

    init(
        source: ReaderEPUBAssetSource,
        onRefusal: @escaping @MainActor (ReaderEPUBRefusal) -> Void = { _ in }
    ) {
        self.source = source
        self.onRefusal = onRefusal
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            return fail(task, .unexpectedScheme(nil))
        }
        switch ReaderEPUBRouter.route(for: url).flatMap({ route in
            source.resolve(route).map { (route, $0) }
        }) {
        case .failure(let refusal):
            fail(task, refusal)
        case .success(let (route, fileURL)):
            guard var data = (route == .book ? source.bookData : nil)
                ?? (try? Data(contentsOf: fileURL, options: .mappedIfSafe)) else {
                return fail(task, .unreadable(fileURL.lastPathComponent))
            }
            if route == .library("epub.js") {
                guard let patched = try? ReaderEPUBURLPatch.apply(to: data) else {
                    return fail(task, .unreadable("epub.js compatibility patch"))
                }
                data = patched
            }
            var headers = [
                "Content-Type": ReaderEPUBRouter.mediaType(for: route),
                "Content-Length": String(data.count),
                "Cache-Control": "no-store",
            ]
            if case .page = route {
                headers["Content-Security-Policy"] = ReaderEPUBRouter.contentSecurityPolicy
            }
            guard let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            else { return fail(task, .unreadable(url.lastPathComponent)) }
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func fail(_ task: any WKURLSchemeTask, _ refusal: ReaderEPUBRefusal) {
        onRefusal(refusal)
        task.didFailWithError(refusal)
    }
}
