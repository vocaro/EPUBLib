import EPUBCore
import Foundation
import XCTest

/// `ResourceReference`: resolving a URL reference inside the archive and judging archive paths.
final class ResourceReferenceCoverageTests: XCTestCase {
    private let base = "OPS/text/ch1.xhtml"

    func testReferencesResolveAgainstTheFolderOfTheirDocument() throws {
        let cases = [
            "ch2.xhtml": "OPS/text/ch2.xhtml",
            "./ch2.xhtml": "OPS/text/ch2.xhtml",
            "notes/n1.xhtml": "OPS/text/notes/n1.xhtml",
            "notes/../ch2.xhtml": "OPS/text/ch2.xhtml",
            "../images/a.png": "OPS/images/a.png",
            "../../cover.jpg": "cover.jpg",
            "../../META-INF/container.xml": "META-INF/container.xml",
            "./././../text/./ch1.xhtml": "OPS/text/ch1.xhtml",
            "%2e%2e/styles/a.css": "OPS/styles/a.css",
            ".%2E/styles/a.css": "OPS/styles/a.css",
            "%2E/ch2.xhtml": "OPS/text/ch2.xhtml",
            "": "OPS/text/ch1.xhtml",
            "#top": "OPS/text/ch1.xhtml#top",
            "ch2.xhtml#s1": "OPS/text/ch2.xhtml#s1",
            "../toc.xhtml#toc-1.2": "OPS/toc.xhtml#toc-1.2",
        ]
        for (href, expected) in cases {
            XCTAssertEqual(try ResourceReference.resolve(href, relativeTo: base), expected, href.debugDescription)
        }
        XCTAssertEqual(try ResourceReference.resolve("one.xhtml", relativeTo: "book.opf"), "one.xhtml", "from the container root")
        XCTAssertEqual(try ResourceReference.resolve("#x", relativeTo: "book.opf"), "book.opf#x")
        XCTAssertEqual(try ResourceReference.resolve("../b/c.xhtml", relativeTo: "a/b/c/d/e.xhtml"), "a/b/c/b/c.xhtml")
    }

    func testAResolvedReferenceIsEncodedHoweverItWasWritten() throws {
        let cases = [
            "a b.xhtml": "OPS/text/a%20b.xhtml",
            "a%20b.xhtml": "OPS/text/a%20b.xhtml",
            "caf\u{E9}.xhtml": "OPS/text/caf%C3%A9.xhtml",
            "caf%c3%a9.xhtml": "OPS/text/caf%C3%A9.xhtml",
            "%63h2.xhtml": "OPS/text/ch2.xhtml",
            "\u{65E5}\u{672C}/\u{7AE0}.xhtml": "OPS/text/%E6%97%A5%E6%9C%AC/%E7%AB%A0.xhtml",
            "100%25.xhtml": "OPS/text/100%25.xhtml",
            "a%2520b.xhtml": "OPS/text/a%2520b.xhtml",
            "q%3Fa.xhtml": "OPS/text/q%3Fa.xhtml",
            "n%231.xhtml": "OPS/text/n%231.xhtml",
            "n%231.xhtml#n%231": "OPS/text/n%231.xhtml#n%231",
            "a+b&c=d;e,f@g!h'(i)*~_.xhtml": "OPS/text/a+b&c=d;e,f@g!h'(i)*~_.xhtml",
            "%5Bx%5D%7By%7D%5E%60%7C%22%3C%3E.xhtml": "OPS/text/%5Bx%5D%7By%7D%5E%60%7C%22%3C%3E.xhtml",
            "ch2.xhtml#caf\u{E9} au lait": "OPS/text/ch2.xhtml#caf%C3%A9%20au%20lait",
            "ch2.xhtml#caf%C3%A9%20au%20lait": "OPS/text/ch2.xhtml#caf%C3%A9%20au%20lait",
            "ch2.xhtml#a/b?c=d&e:f": "OPS/text/ch2.xhtml#a/b?c=d&e:f",
        ]
        for (href, expected) in cases {
            let resolved = try ResourceReference.resolve(href, relativeTo: base)
            XCTAssertEqual(resolved, expected, href.debugDescription)
            XCTAssertTrue(resolved.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }, "\(resolved) is printable ASCII")
        }
    }

    func testReferencesThatDoNotNameAnArchiveEntryAreRefused() throws {
        let hrefs = [
            "http://example.invalid/a.xhtml", "HTTPS://EXAMPLE.INVALID/", "mailto:reader@example.invalid", "tel:+15555550100",
            "data:text/plain,hello", "javascript:void(0)", "file:///etc/passwd", "urn:isbn:9780000000002", "a:b",
            "//example.invalid/a.xhtml", "%00", "ch%002.xhtml", "ch2.xhtml#a%00b", "a%5Cb.xhtml", "a%5cb.xhtml",
            "c%3A/windows.xhtml", "%E9t%E9.xhtml", "ch2.xhtml#%FF",
        ]
        for href in hrefs {
            XCTAssertThrowsError(try ResourceReference.resolve(href, relativeTo: base), href.debugDescription) {
                XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath(href), href.debugDescription)
            }
        }
    }

    func testSafePathsAreRelativeAndFreeOfDotSegmentsAndSeparatorsOtherSystemsRead() {
        for path in ["a", "a/b", "a b/c d.xhtml", "\u{65E5}\u{672C}/\u{7AE0}.xhtml", "a.b", "...", ".hidden", "a..", "a/.b/c", "-", "~", "100%.xhtml",
                     "what?.xhtml", "n#1.xhtml", "a+b.xhtml", "mimetype", "META-INF/container.xml"] {
            XCTAssertTrue(ResourceReference.isSafePath(path), path.debugDescription)
        }
        for path in ["", "/", "/a", "a/", "a//b", "//", ".", "..", "./a", "a/.", "a/./b", "../a", "a/../b", "a/..", "a\\b", "\\", "a:b", "C:/x", "a\0b", "\0"] {
            XCTAssertFalse(ResourceReference.isSafePath(path), path.debugDescription)
        }
    }

    func testADirectoryPathMayEndInOneSlash() {
        for path in ["a/", "a/b/", "a", "a b/"] { XCTAssertTrue(ResourceReference.isSafePath(path, directory: true), path.debugDescription) }
        for path in ["/", "", "a//", "//", "../", "./", "a/../", "/a/"] {
            XCTAssertFalse(ResourceReference.isSafePath(path, directory: true), path.debugDescription)
        }
    }

    func testNoReferenceBuiltFromHostilePiecesTrapsEscapesOrChangesWhenResolvedAgain() throws {
        // Books are untrusted, and resolve() unwraps optionals: every combination must either be
        // refused with a typed error or name a safe path that resolves to itself from the root.
        let pieces = ["a", "b.xhtml", "..", ".", "/", "//", "%2F", "%2f", "%2E%2E", "%2e", "%00", "%5C", "\\", "#", "?", ":", "%", "%zz", "%C3",
                      "%A9", " ", "\u{E9}", "e\u{301}", "%25", "%23", "+", "\0", "\n", "x:", "&", "\u{1F600}", "%F0%9F", "[", "]"]
        var hrefs = pieces
        for first in pieces { for second in pieces { hrefs.append(first + second) } }
        for first in pieces { for second in pieces { for third in pieces { hrefs.append(first + second + third) } } }
        var resolved = 0, refused = 0
        for base in ["OPS/text/ch1.xhtml", "root.opf"] {
            for href in hrefs {
                let result: String
                do { result = try ResourceReference.resolve(href, relativeTo: base) } catch {
                    XCTAssertEqual(error as? EPUBPublicationError, .unsafePath(href), href.debugDescription)
                    refused += 1
                    continue
                }
                resolved += 1
                let path = String(result.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]).removingPercentEncoding
                guard let path, ResourceReference.isSafePath(path), result.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }),
                      (try? ResourceReference.resolve(result, relativeTo: "root.opf")) == result else {
                    XCTFail("\(href.debugDescription) from \(base) resolved to \(result.debugDescription)")
                    continue
                }
            }
        }
        XCTAssertGreaterThan(resolved, 1_000)
        XCTAssertGreaterThan(refused, 1_000)
    }

    func testAResourceHrefIsItsEncodedPath() throws {
        let cases = ["OPS/one.xhtml": "OPS/one.xhtml", "OPS/chapter #100%?.xhtml": "OPS/chapter%20%23100%25%3F.xhtml",
                     "OPS/caf\u{E9} \u{65E5}\u{672C}.xhtml": "OPS/caf%C3%A9%20%E6%97%A5%E6%9C%AC.xhtml", "a+b&c;d=e,f@g.css": "a+b&c;d=e,f@g.css",
                     "fonts/[x] {y}.otf": "fonts/%5Bx%5D%20%7By%7D.otf"]
        for (path, href) in cases {
            let resource = EPUBResource(id: "r", path: path, mediaType: "application/octet-stream")
            XCTAssertEqual(resource.href, href, path)
            XCTAssertEqual(resource.href.removingPercentEncoding, path, path)
            XCTAssertEqual(try ResourceReference.resolve(resource.href, relativeTo: "root.opf"), href, "an href resolves to itself from the root")
        }
    }
}
