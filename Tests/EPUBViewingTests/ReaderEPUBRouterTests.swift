#if DEBUG
import WebKit
import XCTest
@testable import EPUBViewing

final class ReaderEPUBRouterTests: XCTestCase {
    private func url(_ path: String) -> URL {
        URL(string: "\(ReaderEPUBRouter.origin)\(path)")!
    }


    func testTheFourRoutesResolve() {
        XCTAssertEqual(ReaderEPUBRouter.route(for: url("/")), .success(.page))
        XCTAssertEqual(ReaderEPUBRouter.route(for: url("/index.html")), .success(.page))
        XCTAssertEqual(ReaderEPUBRouter.route(for: url("/bootstrap.js")), .success(.bootstrap))
        XCTAssertEqual(ReaderEPUBRouter.route(for: url("/book.epub")), .success(.book))
        XCTAssertEqual(
            ReaderEPUBRouter.route(for: url("/lib/view.js")), .success(.library("view.js")))
        XCTAssertEqual(
            ReaderEPUBRouter.route(for: url("/lib/vendor/zip.js")),
            .success(.library("vendor/zip.js")))
    }

    func testAnotherSchemeOrHostIsRefused() {
        XCTAssertEqual(
            ReaderEPUBRouter.route(for: URL(string: "https://example.com/lib/view.js")!),
            .failure(.unexpectedScheme("https")))
        XCTAssertEqual(
            ReaderEPUBRouter.route(for: URL(string: "\(ReaderEPUBRouter.scheme)://elsewhere/lib/view.js")!),
            .failure(.unexpectedHost("elsewhere")))
    }

    func testTheExcludedFoliateFilesAreNotServable() {
        for excluded in ReaderEPUBAssets.excluded {
            XCTAssertEqual(
                ReaderEPUBRouter.route(for: url("/lib/\(excluded.path)")),
                .failure(.notInManifest(excluded.path)),
                "\(excluded.path) is servable")
        }
        XCTAssertEqual(
            ReaderEPUBRouter.route(for: url("/lib/vendor/pdfjs/pdf.worker.mjs")),
            .failure(.notInManifest("vendor/pdfjs/pdf.worker.mjs")))
    }

    func testTraversalAndItsEscapedSpellingsMatchNothing() {
        for path in [
            "/lib/../../../etc/passwd",
            "/lib/%2e%2e%2f%2e%2e%2fetc%2fpasswd",
            "/lib/vendor/../../book.epub",
            "/lib//view.js",
            "/lib/view.js/../mobi.js",
            "/Library/Preferences/com.apple.plist",
        ] {
            switch ReaderEPUBRouter.route(for: url(path)) {
            case .success(let route):
                XCTFail("\(path) resolved to \(route)")
            case .failure:
                break
            }
        }
    }

    func testAQueryOrFragmentDoesNotCreateANewRoute() {
        XCTAssertEqual(ReaderEPUBRouter.route(for: url("/index.html?cfi=x")), .success(.page))
        XCTAssertEqual(
            ReaderEPUBRouter.route(for: url("/lib/view.js?v=2")), .success(.library("view.js")))
        XCTAssertEqual(
            ReaderEPUBRouter.route(for: url("/lib/mobi.js?allow=1")),
            .failure(.notInManifest("mobi.js")))
    }

    func testMediaTypesFollowTheRouteRatherThanTheRequest() {
        XCTAssertEqual(ReaderEPUBRouter.mediaType(for: .page), "text/html; charset=utf-8")
        XCTAssertEqual(ReaderEPUBRouter.mediaType(for: .book), "application/epub+zip")
        XCTAssertEqual(
            ReaderEPUBRouter.mediaType(for: .library("view.js")), "text/javascript; charset=utf-8")
        XCTAssertEqual(
            ReaderEPUBRouter.mediaType(for: .library("LICENSE")), "text/plain; charset=utf-8")
        XCTAssertEqual(
            ReaderEPUBRouter.mediaType(for: .library("vendor/zip.js.LICENSE.txt")),
            "text/plain; charset=utf-8")
    }


    func testThePolicyAdmitsNoRemoteOriginAndNoScriptEscape() {
        let policy = ReaderEPUBRouter.contentSecurityPolicy
        XCTAssertTrue(policy.contains("default-src 'none'"))
        XCTAssertTrue(policy.contains("script-src 'self'"))
        for escape in ["'unsafe-eval'", "'wasm-unsafe-eval'", "http:", "https:", "*"] {
            XCTAssertFalse(policy.contains(escape), "the policy admits \(escape)")
        }
        let directives = policy.split(separator: ";").map(String.init)
        let inline = directives.filter { $0.contains("'unsafe-inline'") }
        XCTAssertEqual(inline.count, 1)
        XCTAssertTrue(inline.first?.contains("style-src") == true)
    }

    func testThePageCarriesTheSamePolicyTheHandlerServes() throws {
        let html = try XCTUnwrap(String(data: try readerResource("index.html"), encoding: .utf8))
        let marker = "http-equiv=\"Content-Security-Policy\" content=\""
        let start = try XCTUnwrap(html.range(of: marker))
        let rest = html[start.upperBound...]
        let end = try XCTUnwrap(rest.firstIndex(of: "\""))
        XCTAssertEqual(String(rest[rest.startIndex..<end]), ReaderEPUBRouter.contentSecurityPolicy)
    }

    func testNeitherHostFileCarriesInlineScriptOrAnInlineHandler() throws {
        let html = try XCTUnwrap(String(data: try readerResource("index.html"), encoding: .utf8))
        XCTAssertTrue(html.contains("<script type=\"module\" src=\"bootstrap.js\">"))
        XCTAssertEqual(html.components(separatedBy: "<script").count - 1, 1)
        for handler in [" onload=", " onclick=", " onerror=", "javascript:"] {
            XCTAssertFalse(html.contains(handler), "index.html carries \(handler)")
        }
    }


    func testTheReaderNavigatesOnlyItsOwnBytes() {
        for allowed in [
            "\(ReaderEPUBRouter.origin)/index.html",
            "blob:\(ReaderEPUBRouter.origin)/6f0a1e2c-0000-4000-8000-000000000000",
            "about:blank",
        ] {
            XCTAssertTrue(
                ReaderEPUBNavigation.allows(URL(string: allowed)), "refused \(allowed)")
        }
    }

    func testALinkOutOfABookIsRefused() {
        for refused in [
            "https://example.com/tracker.gif",
            "http://example.com",
            "mailto:someone@example.com",
            "javascript:parent.postMessage(1)",
            "file:///etc/passwd",
            "data:text/html,%3Cscript%3E1%3C/script%3E",
            "ftp://example.com",
        ] {
            XCTAssertFalse(
                ReaderEPUBNavigation.allows(URL(string: refused)), "allowed \(refused)")
        }
        XCTAssertFalse(ReaderEPUBNavigation.allows(nil))
    }

    func testASchemeIsMatchedWithoutRegardToCase() {
        XCTAssertTrue(ReaderEPUBNavigation.allows(URL(string: "BLOB:\(ReaderEPUBRouter.origin)/x")))
        XCTAssertFalse(ReaderEPUBNavigation.allows(URL(string: "HTTPS://example.com")))
    }

    func testACancelledNavigationIsNotAFailedBook() {
        for cancellation in [
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
            NSError(
                domain: ReaderEPUBNavigation.webKitErrorDomain,
                code: ReaderEPUBNavigation.frameLoadInterruptedByPolicyChange),
        ] {
            XCTAssertTrue(
                ReaderEPUBNavigation.isCancellation(cancellation),
                "\(cancellation.domain) \(cancellation.code) read as a real failure")
        }
    }

    func testARealFailureIsNotMistakenForACancellation() {
        for failure in [
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotOpenFile),
            NSError(
                domain: WKError.errorDomain,
                code: WKError.Code.webContentProcessTerminated.rawValue),
            NSError(domain: NSCocoaErrorDomain, code: NSURLErrorCancelled),
            NSError(
                domain: WKError.errorDomain,
                code: ReaderEPUBNavigation.frameLoadInterruptedByPolicyChange),
        ] {
            XCTAssertFalse(
                ReaderEPUBNavigation.isCancellation(failure),
                "\(failure.domain) \(failure.code) read as a cancellation")
        }
    }


    func testThePageStillCarriesTheFilterThePolicyCannotProvide() throws {
        let script = try XCTUnwrap(
            String(data: try readerResource("bootstrap.js"), encoding: .utf8))
        for rel in [
            "dns-prefetch", "preconnect", "prefetch", "prerender", "preload", "modulepreload",
        ] {
            XCTAssertTrue(script.contains("'\(rel)'"), "bootstrap.js does not name rel=\(rel)")
        }
        for markupExtension in [".xhtml", ".html", ".htm", ".xml", ".svg"] {
            XCTAssertTrue(
                script.contains("'\(markupExtension)'"),
                "bootstrap.js does not treat \(markupExtension) as markup")
        }
        for field in ["remoteHintsRemoved", "lateRemoteHints"] {
            XCTAssertTrue(script.contains(field), "bootstrap.js does not report \(field)")
        }
    }

    func testTheSearchCallPassesOnlyOptionsTheLibraryReads() throws {
        let script = try XCTUnwrap(
            String(data: try readerResource("bootstrap.js"), encoding: .utf8))
        XCTAssertTrue(script.contains("view.search({ query })"))
        XCTAssertFalse(script.contains("scope:"), "bootstrap.js still passes a scope option")
    }


    func testEachRouteResolvesInsideItsOwnRoot() throws {
        let root = try makeResourceTree()
        defer { try? FileManager.default.removeItem(at: root.resourceRoot) }
        XCTAssertEqual(
            try root.resolve(.page).get().lastPathComponent, "index.html")
        XCTAssertEqual(
            try root.resolve(.library("vendor/zip.js")).get().lastPathComponent, "zip.js")
        XCTAssertEqual(try root.resolve(.book).get(), root.bookURL)
    }

    func testASymlinkedAssetIsRefusedRatherThanFollowedOut() throws {
        let source = try makeResourceTree()
        defer { try? FileManager.default.removeItem(at: source.resourceRoot) }
        let outside = source.resourceRoot
            .deletingLastPathComponent().appending(path: "outside.js")
        try Data("stolen".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let planted = source.libraryRoot.appending(path: "view.js")
        try FileManager.default.removeItem(at: planted)
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: outside)

        switch source.resolve(.library("view.js")) {
        case .success(let url): XCTFail("followed a symlink out of the bundle to \(url.path)")
        case .failure(let refusal): XCTAssertEqual(refusal, .outsideBounds("view.js"))
        }
    }


    private func readerResource(_ name: String) throws -> Data {
        let candidates = [FoliateTestResources.bundle].compactMap {
            $0.url(forResource: ReaderEPUBAssets.resourceDirectory, withExtension: nil)
        }
        guard let directory = candidates.first else {
            throw XCTSkip("this build carries no \(ReaderEPUBAssets.resourceDirectory) resources")
        }
        return try Data(contentsOf: directory.appending(path: name))
    }

    private func makeResourceTree() throws -> ReaderEPUBAssetSource {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let library = root.appending(path: ReaderEPUBAssets.libraryDirectory)
        try FileManager.default.createDirectory(
            at: library.appending(path: "vendor"), withIntermediateDirectories: true)
        try Data("<!DOCTYPE html>".utf8).write(to: root.appending(path: "index.html"))
        try Data("//".utf8).write(to: root.appending(path: "bootstrap.js"))
        for file in ReaderEPUBAssets.vendored {
            try Data("//".utf8).write(to: library.appending(path: file.path))
        }
        let book = root.appending(path: "staged.epub")
        try Data("PK".utf8).write(to: book)
        return ReaderEPUBAssetSource(resourceRoot: root, bookURL: book)
    }
}
#endif
