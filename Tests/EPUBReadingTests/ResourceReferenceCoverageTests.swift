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
        // From nowhere, a reference starts at the root and cannot name the document it stands in.
        XCTAssertEqual(try ResourceReference.resolve("fonts/a.otf", relativeTo: ""), "fonts/a.otf")
        for href in ["", "#top", "?x"] { XCTAssertThrowsError(try ResourceReference.resolve(href, relativeTo: ""), href.debugDescription) }
    }

    func testALeadingSlashNamesTheContainerRootAndDoubleDotsStopThere() throws {
        // EPUB Reading Systems 3.3 §4.1.1: parsing "/" or ".." against the container root URL
        // gives the container root URL, so no reference leaves the container.
        let cases = [
            "/media/photo.jpg": "media/photo.jpg",
            "/OPS/text/ch2.xhtml#s1": "OPS/text/ch2.xhtml#s1",
            "%2Fmedia/photo.jpg": "media/photo.jpg",
            "/a/../../b.css": "b.css",
            "../../../cover.jpg": "cover.jpg",
            "../../../../../../media/photo.jpg": "media/photo.jpg",
            "../../../OPS/../cover.jpg": "cover.jpg",
            "%2e%2e/%2e%2e/%2e%2e/cover.jpg": "cover.jpg",
        ]
        for (href, expected) in cases {
            XCTAssertEqual(try ResourceReference.resolve(href, relativeTo: base), expected, href.debugDescription)
        }
        XCTAssertEqual(try ResourceReference.resolve("../one.xhtml", relativeTo: "book.opf"), "one.xhtml", "from the container root")
        // The root itself is no entry.
        for href in ["/", "/.", "/..", "../..", "../../.."] {
            XCTAssertThrowsError(try ResourceReference.resolve(href, relativeTo: base), href.debugDescription) {
                XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath(href), href.debugDescription)
            }
        }
    }

    func testAQueryIsDroppedFromAReference() throws {
        // It cannot change which archive entry is meant, and is never read.
        let cases = [
            "ch2.xhtml?version=2": "OPS/text/ch2.xhtml",
            "ch2.xhtml?a=1&b=2#s1": "OPS/text/ch2.xhtml#s1",
            "ch2.xhtml?": "OPS/text/ch2.xhtml",
            "ch2.xhtml?a=%zz": "OPS/text/ch2.xhtml",
            "../images/a.png?w=100": "OPS/images/a.png",
            "?x": "OPS/text/ch1.xhtml",
            "?x#top": "OPS/text/ch1.xhtml#top",
            "q%3Fa.xhtml?b": "OPS/text/q%3Fa.xhtml",
            "ch2.xhtml#a?b": "OPS/text/ch2.xhtml#a?b",
        ]
        for (href, expected) in cases {
            XCTAssertEqual(try ResourceReference.resolve(href, relativeTo: base), expected, href.debugDescription)
        }
    }

    func testWhiteSpaceRoundAReferenceIsReadPastAsURLParsingReadsIt() throws {
        // An HTML href is a URL "potentially surrounded by spaces", and URL parsing strips the C0
        // controls and spaces at its ends (https://github.com/vocaro/EPUBLib/issues/76).
        let cases = [
            " ch2.xhtml": "OPS/text/ch2.xhtml",
            "ch2.xhtml#s1 ": "OPS/text/ch2.xhtml#s1",
            "\n\t  ../images/a.png\r\n  ": "OPS/images/a.png",
            "\u{C}ch2.xhtml\u{1F}": "OPS/text/ch2.xhtml",
            " /media/photo.jpg ": "media/photo.jpg",
            " #top ": "OPS/text/ch1.xhtml#top",
            " ": "OPS/text/ch1.xhtml",
            // A space inside, and white space written as an escape, are characters of the name. So
            // is a tab or newline inside, which URL parsing drops and a reference about to be
            // written keeps (https://github.com/vocaro/EPUBLib/issues/254).
            " a b.xhtml ": "OPS/text/a%20b.xhtml",
            "%20ch2.xhtml%09": "OPS/text/%20ch2.xhtml%09",
            "\tch\t2.xhtml#s\n1\n": "OPS/text/ch%092.xhtml#s%0A1",
        ]
        for (href, expected) in cases {
            XCTAssertEqual(try ResourceReference.resolve(href, relativeTo: base), expected, href.debugDescription)
        }
        // So is white space outside ASCII, which neither HTML nor URL parsing strips.
        for space in ["\u{A0}", "\u{3000}", "\u{2003}", "\u{85}", "\u{2028}", "\u{200B}"] {
            let e = escaped(space)
            XCTAssertEqual(try ResourceReference.resolve("\(space)ch2.xhtml#s1\(space)", relativeTo: base), "OPS/text/\(e)ch2.xhtml#s1\(e)", e)
        }
        // A remote reference is one past its white space, as before.
        for href in [" https://example.invalid/", "\t//example.invalid/x"] {
            XCTAssertThrowsError(try ResourceReference.resolve(href, relativeTo: base), href.debugDescription) {
                XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath(href), href.debugDescription)
            }
        }
    }

    func testARootfilePathIsJudgedPastTheWhiteSpaceRoundIt() {
        let isEntry: (String) -> Bool = { ["mimetype", "OPS/book.opf"].contains($0) }
        for fullPath in [" OPS/book.opf", "OPS/book.opf\n", "\t OPS/book.opf \r\n"] {
            XCTAssertEqual(ResourceReference.rootfilePath(fullPath, isEntry: isEntry), "OPS/book.opf", fullPath.debugDescription)
        }
        // White space alone is no more the base than an empty value is, and none hides a path a
        // rootfile may not have.
        for fullPath in ["", " ", "\t\n", " /OPS/book.opf", "OPS//book.opf ", "OPS/book.opf/ ", " ../OPS/book.opf", "OPS/book.opf#x ", "OPS/book.opf? "] {
            XCTAssertNil(ResourceReference.rootfilePath(fullPath, isEntry: isEntry), fullPath.debugDescription)
        }
        // As written, white space is part of the entry's name.
        XCTAssertEqual(ResourceReference.rootfilePath(" OPS/book.opf", isEntry: { $0 == " OPS/book.opf" }), " OPS/book.opf")
    }

    func testAnEncodedColonIsACharacterOfThePathAndStaysEncoded() throws {
        // Written bare in a first segment it would be read as a scheme, so it never is.
        let cases = [
            "c%3A/windows.xhtml": "OPS/text/c%3A/windows.xhtml",
            "Chapter%201%3A%20Start.xhtml": "OPS/text/Chapter%201%3A%20Start.xhtml",
            "./a:b.xhtml": "OPS/text/a%3Ab.xhtml",
            "notes/a:b.xhtml#c:d": "OPS/text/notes/a%3Ab.xhtml#c:d",
        ]
        for (href, expected) in cases {
            XCTAssertEqual(try ResourceReference.resolve(href, relativeTo: base), expected, href.debugDescription)
        }
        let fromRoot = try ResourceReference.resolve("./a:b.xhtml", relativeTo: "book.opf")
        XCTAssertEqual(fromRoot, "a%3Ab.xhtml")
        XCTAssertEqual(try ResourceReference.resolve(fromRoot, relativeTo: "book.opf"), fromRoot, "it resolves to itself")
    }

    func testARemoteReferenceHasASchemeOrAnAuthority() {
        for href in ["https://example.invalid/a.mp3", "HTTP://EXAMPLE.INVALID/", "//example.invalid/a.mp4", "data:font/woff2;base64,AA==",
                     "mailto:reader@example.invalid", "a:b.xhtml", "C:/x", "x-my.scheme+1:y"] {
            XCTAssertTrue(ResourceReference.isRemote(href), href)
        }
        for href in ["a.xhtml", "/media/a.jpg", "./a:b.xhtml", "a%3Ab.xhtml", "notes/a:b.xhtml", "", "#a:b", "?x=y:z", "../a.xhtml",
                     "1a:b", ":a", "-a:b", "a b:c", "a/b:c", "%68ttp://example.invalid/", "caf\u{E9}:b"] {
            XCTAssertFalse(ResourceReference.isRemote(href), href)
        }
    }

    func testARemoteReferenceIsOneHoweverMalformedTheRestOfIt() throws {
        // What a URL parser gives up on is remote all the same; so is what it reads past the tabs,
        // newlines and leading spaces it drops. None may become a path of the archive.
        let hrefs = ["http://host:port/x", "http://exa mple.invalid/x", "http://[::1", " https://example.invalid/", "\n\t https://example.invalid/",
                     "java\tscript:alert(1)", "ht\ntp://example.invalid/", " //example.invalid/x", "/\t/example.invalid/x", "http:", "http://%zz"]
        for href in hrefs {
            XCTAssertTrue(ResourceReference.isRemote(href), href.debugDescription)
            for strict in [false, true] {
                XCTAssertThrowsError(try ResourceReference.resolve(href, relativeTo: base, strict: strict), href.debugDescription) {
                    XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath(href), href.debugDescription)
                }
            }
        }
    }

    func testADelimiterBesideACombiningMarkIsStillADelimiter() throws {
        // As a Character, "/" or "?" before a combining mark is another character. Paths are bytes.
        let mark = "\u{301}", joiner = "\u{200D}", prepended = "\u{600}"
        for path in ["../\(mark)x", "/\(mark)abs", "a/./\(mark)", "a\\\(mark)b", "a//\(joiner)b", "\(prepended)/../x"] {
            XCTAssertFalse(ResourceReference.isReadablePath(path), path.debugDescription)
            XCTAssertFalse(ResourceReference.isSafePath(path), path.debugDescription)
        }
        XCTAssertTrue(ResourceReference.isReadablePath("EPUB/a:\(mark).xhtml"))
        XCTAssertFalse(ResourceReference.isSafePath("EPUB/a:\(mark).xhtml"), "a colon is one before a mark too")
        XCTAssertTrue(ResourceReference.isSafePath("..\(mark)/x"), "two dots and a mark are a name")

        XCTAssertEqual(try ResourceReference.resolve("/\(mark)x.xhtml", relativeTo: base), "%CC%81x.xhtml", "from the root")
        XCTAssertEqual(try ResourceReference.resolve("ch2.xhtml?\(mark)v=2", relativeTo: base), "OPS/text/ch2.xhtml", "a query")
        XCTAssertEqual(try ResourceReference.resolve("ch2.xhtml#\(mark)x", relativeTo: base), "OPS/text/ch2.xhtml#%CC%81x", "a fragment")
        XCTAssertEqual(try ResourceReference.resolve("..\(mark)/x.xhtml", relativeTo: base), "OPS/text/..%CC%81/x.xhtml")
        for href in ["//\(mark)example.invalid/x", "a%5C\(mark)b.xhtml", "ch2.xhtml%D8%80#%5Cx", "a\(prepended)\\b"] {
            XCTAssertThrowsError(try ResourceReference.resolve(href, relativeTo: base), href.debugDescription)
        }
        for href in ["EPUB/a.xhtml?\(mark)x", "EPUB/a.xhtml%D8%80#%5Cx", "/\(mark)x.xhtml", "EPUB/a:\(mark).xhtml", "EPUB/a%3A\(mark).xhtml"] {
            XCTAssertThrowsError(try ResourceReference.resolve(href, relativeTo: "root.opf", strict: true), href.debugDescription)
        }
    }

    func testAReferenceAboutToBeWrittenIsHeldToWhatEPUBAllowsItsAuthor() throws {
        for href in ["/media/photo.jpg", "../../../cover.jpg", "ch2.xhtml?version=2", "?x", "c%3A/windows.xhtml", "./a:b.xhtml",
                     "https://example.invalid/a.xhtml", "a%5Cb.xhtml", " ch2.xhtml", "ch2.xhtml#s1\n", " "] {
            XCTAssertThrowsError(try ResourceReference.resolve(href, relativeTo: base, strict: true), href.debugDescription) {
                XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath(href), href.debugDescription)
            }
        }
        XCTAssertEqual(try ResourceReference.resolve("../images/a b.png#x", relativeTo: base, strict: true), "OPS/images/a%20b.png#x")
        XCTAssertEqual(try ResourceReference.resolve("ch\t2.xhtml#a\nb", relativeTo: base, strict: true), "OPS/text/ch%092.xhtml#a%0Ab")
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
            "ch2.xhtml#a%5Cb", "100%.xhtml", "%E9t%E9.xhtml", "ch2.xhtml#%FF",
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

    func testAnArchiveBeingReadMayNameAnEntryWithAColon() {
        // OCF forbids it in a file name as it forbids `?` and `*`; the snapshot is looked up by
        // key, so none of them can reach a file system.
        for path in ["a:b", "C:/x", "Chapter 1: Start.xhtml", "OPS/a:b/c.xhtml", ":", "a", "what?.xhtml", "META-INF/container.xml"] {
            XCTAssertTrue(ResourceReference.isReadablePath(path), path.debugDescription)
        }
        for path in ["", "/a", "a/", "a//b", "../a:b", "a:/../b", "a:/./b", "a:\\b", "a:\0", "https://example.invalid/a"] {
            XCTAssertFalse(ResourceReference.isReadablePath(path), path.debugDescription)
        }
        XCTAssertTrue(ResourceReference.isReadablePath("a:b/", directory: true))
    }

    func testADirectoryPathMayEndInOneSlash() {
        for path in ["a/", "a/b/", "a", "a b/"] { XCTAssertTrue(ResourceReference.isSafePath(path, directory: true), path.debugDescription) }
        for path in ["/", "", "a//", "//", "../", "./", "a/../", "/a/"] {
            XCTAssertFalse(ResourceReference.isSafePath(path, directory: true), path.debugDescription)
        }
    }

    func testNoReferenceBuiltFromHostilePiecesTrapsEscapesOrChangesWhenResolvedAgain() throws {
        // Books are untrusted, and resolve() unwraps optionals: every combination must either be
        // refused with a typed error or name a path an entry can have that resolves to itself
        // from the root.
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
                guard let path, ResourceReference.isReadablePath(path), result.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }),
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
                     "fonts/[x] {y}.otf": "fonts/%5Bx%5D%20%7By%7D.otf", "Chapter 1: Start.xhtml": "Chapter%201%3A%20Start.xhtml",
                     "OPS/a:b/c.xhtml": "OPS/a%3Ab/c.xhtml"]
        for (path, href) in cases {
            let resource = EPUBResource(id: "r", path: path, mediaType: "application/octet-stream")
            XCTAssertEqual(resource.href, href, path)
            XCTAssertEqual(resource.href.removingPercentEncoding, path, path)
            XCTAssertEqual(try ResourceReference.resolve(resource.href, relativeTo: "root.opf"), href, "an href resolves to itself from the root")
        }
    }

    // MARK: Separators and dots beside a mark

    // A `Character` is an extended grapheme cluster, so a "/", "\", ":", "#" or "." shares its
    // `Character` with a mark, selector or joiner after it and a prepended mark before it. Read
    // that way "../" + U+0301 + "x" is one name: no segment of it is "..", and it holds no "/".
    // An archive and a file system read bytes (https://github.com/vocaro/EPUBLib/issues/181).

    /// Every scalar `String` takes into the `Character` of a "/" before it (`after`), and every
    /// scalar that takes a "/" after it into its own (`before`), found by asking `String`.
    /// Unicode has thousands of the first and dozens of the second. With fewer, a test that
    /// loops over them would try little or nothing and pass, so the run stops here instead.
    private static let clustering: (after: [Unicode.Scalar], before: [Unicode.Scalar]) = {
        var after: [Unicode.Scalar] = [], before: [Unicode.Scalar] = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if "/\(scalar)".count == 1 { after.append(scalar) }
            if "\(scalar)/".count == 1 { before.append(scalar) }
        }
        precondition(after.count > 2_000 && before.count > 20,
                     "String joins \(after.count) scalars to a \"/\" before them and \(before.count) to one after them")
        return (after, before)
    }()

    /// What a path that is read is held to, checked on its UTF-8 bytes, which are what an archive
    /// stores and a file system is handed: no empty, "." or ".." segment, so no leading or closing
    /// "/", and no backslash or NUL. A colon is read (https://github.com/vocaro/EPUBLib/issues/171).
    private func isReadableAsBytes(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        return !bytes.isEmpty && !bytes.contains { $0 == 0x5C || $0 == 0 }
            && bytes.split(separator: 0x2F, omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && !$0.elementsEqual([0x2E]) && !$0.elementsEqual([0x2E, 0x2E])
            }
    }

    /// What a path about to be written is held to: as one that is read, and no colon.
    private func isSafeAsBytes(_ path: String) -> Bool { isReadableAsBytes(path) && !path.utf8.contains(0x3A) }

    private func escaped(_ text: String) -> String {
        text.utf8.map { $0 < 0x80 ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    private func scalars(_ text: String?) -> [String]? { text?.unicodeScalars.map { String($0.value, radix: 16) } }

    func testTheScalarsThatJoinASeparatorsCharacterAreTheMarksSelectorsAndJoiners() {
        let (after, before) = Self.clustering
        let joined = Set(after)
        // Every combining mark with a combining class, enclosing mark, variation selector, emoji
        // modifier and join control is among them, with the spacing marks of Indic scripts.
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let properties = scalar.properties
            if properties.canonicalCombiningClass != .notReordered || properties.generalCategory == .enclosingMark
                || properties.isVariationSelector || properties.isEmojiModifier || properties.isJoinControl {
                XCTAssertTrue(joined.contains(scalar), "U+" + String(value, radix: 16))
            }
        }
        for scalar in ["\u{301}", "\u{338}", "\u{36F}", "\u{489}", "\u{20DD}", "\u{20E3}", "\u{FE00}", "\u{FE0F}", "\u{E0100}", "\u{200C}", "\u{200D}",
                       "\u{1F3FB}", "\u{93E}", "\u{94D}", "\u{E31}", "\u{3099}", "\u{FF9E}", "\u{E0020}"] as [Unicode.Scalar] {
            XCTAssertTrue(joined.contains(scalar), "U+" + String(scalar.value, radix: 16))
        }
        // Hangul jamo, regional indicators and emoji join only their own kind.
        for scalar in ["\u{1161}", "\u{11A8}", "\u{1F1EF}", "\u{1F600}", "a", "\u{E9}"] as [Unicode.Scalar] { XCTAssertFalse(joined.contains(scalar)) }
        // Prepended marks, as the Arabic number sign, take what follows them.
        let prepended = Set(before)
        XCTAssertTrue(before.contains("\u{600}") && before.contains("\u{6DD}") && before.contains("\u{110BD}"))
        XCTAssertTrue(before.allSatisfy { $0.value > 0x7F } && prepended.isDisjoint(with: joined))
        // The other separators and the dot are joined by the same scalars and by no other, so
        // every scalar is asked of each; a NUL by none.
        let followed = ["\\", ":", ".", "#", "?", "%"], preceded = ["\\", ":", ".", "#"]
        var wrong: [String] = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            for other in followed where ("\(other)\(scalar)".count == 1) != joined.contains(scalar) { wrong.append(other + " U+" + String(value, radix: 16)) }
            for other in preceded where ("\(scalar)\(other)".count == 1) != prepended.contains(scalar) { wrong.append("U+" + String(value, radix: 16) + " " + other) }
        }
        XCTAssertEqual(wrong.count, 0, wrong.prefix(20).joined(separator: ", "))
        for scalar in after { XCTAssertEqual("\0\(scalar)".count, 2, "U+" + String(scalar.value, radix: 16)) }
        for scalar in before { XCTAssertEqual("\(scalar)\0".count, 2, "U+" + String(scalar.value, radix: 16)) }
    }

    func testNoMarkHidesASeparatorOrADotSegmentFromThePathCheck() {
        var wrong: [String] = []
        // `readable` is what a path that is read is held to. One about to be written is held to
        // that and to having no colon, which `colon` says this path has.
        func expect(_ readable: Bool, _ path: String, directory: Bool = false, colon: Bool = false) {
            let safe = readable && !colon
            guard ResourceReference.isReadablePath(path, directory: directory) != readable || ResourceReference.isSafePath(path, directory: directory) != safe
                || (!directory && (isReadableAsBytes(path) != readable || isSafeAsBytes(path) != safe)) else { return }
            wrong.append((directory ? "directory " : "") + path.debugDescription)
        }
        for scalar in Self.clustering.after {
            let m = String(scalar)
            // A ".." or "." segment, an empty one (opening, or between two slashes), a backslash, a NUL.
            for path in ["../\(m)x", "a/../\(m)x", "./\(m)x", "a/./\(m)x", "/\(m)x", "/\(m)", "a//\(m)x", "a\\\(m)b", "\\\(m)", "a\0\(m)b", "a:\(m)/../b"] {
                expect(false, path)
            }
            // A colon is one before a mark too: read, and refused in a path about to be written.
            for path in ["a:\(m)b", "C:\(m)/x", ":\(m)"] { expect(true, path, colon: true) }
            // Two names, the second beginning with the mark; and a name of dots and the mark, which
            // is no dot segment to anything that reads bytes.
            for path in ["a/\(m)b", "a/\(m)", "\(m)", "\(m)x/\(m)y", ".\(m)", "..\(m)", "a/.\(m)/b", "a/..\(m)/b", "a.\(m)b", "a..\(m)"] { expect(true, path) }
            expect(true, "a/\(m)/", directory: true)
            expect(true, "a/\(m)", directory: true)
            for path in ["a//\(m)/", "../\(m)/", "a/./\(m)/", "/\(m)/", "a\\\(m)/"] { expect(false, path, directory: true) }
        }
        for scalar in Self.clustering.before {
            let m = String(scalar)
            for path in ["a\(m)/..", "\(m)/../x", "a\(m)/./x", "a\(m)/.", "a\(m)/", "a\(m)//x", "a\(m)\\b"] { expect(false, path) }
            for path in ["a\(m):b", "\(m):"] { expect(true, path, colon: true) }
            for path in ["\(m)/x", "a\(m)/b", "a/\(m).", "\(m)..", "a/\(m)../b", "\(m)"] { expect(true, path) }
            expect(true, "a\(m)/", directory: true)
            expect(false, "a\(m)//", directory: true)
        }
        XCTAssertEqual(wrong.count, 0, wrong.prefix(20).joined(separator: ", "))
    }

    func testAReferenceIsResolvedWhateverMarkFollowsItsSeparatorsAndDots() throws {
        var wrong: [String] = []
        func resolve(_ href: String, strict: Bool = false) -> String? { try? ResourceReference.resolve(href, relativeTo: base, strict: strict) }
        for scalar in Self.clustering.after {
            let m = String(scalar), e = escaped(m)
            let resolved = [
                // Dot segments, written out and escaped, before a name that begins with the mark.
                "../\(m)x": "OPS/\(e)x", "../../\(m)x": "\(e)x", "a/../\(m)x": "OPS/text/\(e)x", "./\(m)x": "OPS/text/\(e)x",
                "a/./\(m)x": "OPS/text/a/\(e)x", "..%2F\(m)x": "OPS/\(e)x", "..%2f\(e)x": "OPS/\(e)x", "%2E%2E/\(e)x": "OPS/\(e)x",
                // Two names, and an empty segment dropped as between any two slashes.
                "a/\(m)x": "OPS/text/a/\(e)x", "a/\(e)x": "OPS/text/a/\(e)x", "a//\(m)x": "OPS/text/a/\(e)x",
                // Dots and the mark are a name.
                ".\(m)/x": "OPS/text/.\(e)/x", "..\(m)/x": "OPS/text/..\(e)/x",
                // A fragment that begins with the mark.
                "ch2.xhtml#\(m)x": "OPS/text/ch2.xhtml#\(e)x", "#\(m)x": "OPS/text/ch1.xhtml#\(e)x", "../\(m)x#\(m)": "OPS/\(e)x#\(e)",
            ]
            for (href, expected) in resolved {
                let result = resolve(href)
                if result != expected || resolve(href, strict: true) != expected || (try? ResourceReference.resolve(expected, relativeTo: "root.opf")) != expected {
                    wrong.append("\(href.debugDescription) resolved to \(result ?? "an error")")
                }
            }
            // What reading forgives, with the mark as without it. A reference that climbs past
            // the container root or opens with a slash starts at the root
            // (https://github.com/vocaro/EPUBLib/issues/84); a colon outside a scheme is a
            // character of the name and a query is dropped
            // (https://github.com/vocaro/EPUBLib/issues/171). One about to be written is refused.
            let forgiven = ["../../../\(m)x": "\(e)x", "..%2F..%2F..%2F\(m)x": "\(e)x", "/\(m)x": "\(e)x", "%2F\(m)x": "\(e)x",
                            "./a:\(m)b": "OPS/text/a%3A\(e)b", "a/b%3A\(m)c": "OPS/text/a/b%3A\(e)c", "ch2.xhtml?\(m)q": "OPS/text/ch2.xhtml"]
            for (href, expected) in forgiven {
                let result = resolve(href)
                if result != expected || (try? ResourceReference.resolve(expected, relativeTo: "root.opf")) != expected {
                    wrong.append("\(href.debugDescription) resolved to \(result ?? "an error")")
                }
                if let result = resolve(href, strict: true) { wrong.append("\(href.debugDescription) to be written resolved to \(result)") }
            }
            // Refused either way: a backslash, written out or escaped, and a scheme.
            for href in ["a\\\(m)b", "a%5C\(m)b", "c:\(m)/x"] {
                if let result = resolve(href) ?? resolve(href, strict: true) { wrong.append("\(href.debugDescription) resolved to \(result)") }
            }
            // A folder of the base whose name begins with the mark is one of its segments.
            if (try? ResourceReference.resolve("../x", relativeTo: "a/\(m)b/c.opf")) != "a/x" || (try? ResourceReference.resolve("x", relativeTo: "a/\(m)b/c.opf")) != "a/\(e)b/x"
                || (try? ResourceReference.resolve("", relativeTo: "a/\(m)b")) != "a/\(e)b" {
                wrong.append("from a base under a folder named U+\(String(scalar.value, radix: 16))")
            }
        }
        for scalar in Self.clustering.before {
            let m = String(scalar), e = escaped(m)
            let resolved = ["a\(m)/../x": "OPS/text/x", "\(m)/../../x": "OPS/x", "a\(m)/./x": "OPS/text/a\(e)/x", "a\(m)/x": "OPS/text/a\(e)/x",
                            "ch2.xhtml\(m)#x": "OPS/text/ch2.xhtml\(e)#x"]
            for (href, expected) in resolved where resolve(href) != expected || resolve(href, strict: true) != expected {
                wrong.append("\(href.debugDescription) resolved to \(resolve(href) ?? "an error")")
            }
            // Forgiven when read and refused when written, as above; a backslash, refused either way.
            for (href, expected) in ["\(m)/../../../../x": "x", "./a\(m):b": "OPS/text/a\(e)%3Ab"] {
                if resolve(href) != expected { wrong.append("\(href.debugDescription) resolved to \(resolve(href) ?? "an error")") }
                if let result = resolve(href, strict: true) { wrong.append("\(href.debugDescription) to be written resolved to \(result)") }
            }
            if let result = resolve("a\(m)\\b") ?? resolve("a\(m)\\b", strict: true) { wrong.append("a backslash after U+\(String(scalar.value, radix: 16)) resolved to \(result)") }
        }
        XCTAssertEqual(wrong.count, 0, wrong.prefix(20).joined(separator: ", "))
    }

    func testAKeycapEmojiIsItsBaseCharacterToAReferenceAndPartOfANameInAPath() throws {
        // A keycap is "#", "*" or a digit, then U+FE0F and U+20E3: one `Character`. Unescaped in
        // a reference its "#" begins the fragment, as any "#" does and as a browser reads it;
        // escaped, or in an archive path, it is part of the name.
        let hash = "#\u{FE0F}\u{20E3}", star = "*\u{FE0F}\u{20E3}", marks = "%EF%B8%8F%E2%83%A3"
        XCTAssertEqual(hash.count, 1)
        XCTAssertEqual(try ResourceReference.resolve("icons/\(hash).png", relativeTo: base), "OPS/text/icons#\(marks).png")
        XCTAssertEqual(try ResourceReference.resolve("icons/%23\(marks).png", relativeTo: base), "OPS/text/icons/%23\(marks).png")
        XCTAssertEqual(try ResourceReference.resolve("icons/\(star).png#\(star)", relativeTo: base), "OPS/text/icons/*\(marks).png#*\(marks)")
        XCTAssertEqual(try ResourceReference.resolve("1\u{FE0F}\u{20E3}/./x", relativeTo: base), "OPS/text/1\(marks)/x")
        for path in ["icons/\(hash).png", "\(hash)/\(star)", "1\u{FE0F}\u{20E3}"] { XCTAssertTrue(ResourceReference.isSafePath(path), path) }
        // A rootfile path written that way is no URL of the entry, and names it as written.
        let entry = "\(hash)/book.opf"
        XCTAssertEqual(scalars(ResourceReference.rootfilePath(entry, isEntry: { $0.unicodeScalars.elementsEqual(entry.unicodeScalars) })), scalars(entry))
    }

    func testNoMarkMakesARootfilePathNameAnEntryOutsideTheContainerInEitherReading() {
        // Whatever the archive holds: the path returned is the one read as the package document.
        let always: (String) -> Bool = { _ in true }
        var wrong: [String] = []
        for scalar in Self.clustering.after {
            let m = String(scalar), e = escaped(m)
            // As a URL, resolved within the container; as written, where a "%" makes it no URL.
            for (fullPath, expected) in ["OPS/\(m)book.opf": "OPS/\(m)book.opf", "OPS/\(e)book.opf": "OPS/\(m)book.opf", "OPS/x/../\(m)book.opf": "OPS/\(m)book.opf",
                                         "OPS/./\(m)book.opf": "OPS/\(m)book.opf", "\(m)OPS/book.opf": "\(m)OPS/book.opf", "50% off/\(m)book.opf": "50% off/\(m)book.opf"] {
                let path = ResourceReference.rootfilePath(fullPath, isEntry: always)
                if scalars(path) != scalars(expected) { wrong.append("\(fullPath.debugDescription) named \(path?.debugDescription ?? "nothing")") }
            }
            // A colon is a character of the name (https://github.com/vocaro/EPUBLib/issues/171):
            // as a URL where no scheme ends at it, and as written where one would or a "%" is bare.
            for fullPath in ["OPS/a:\(m)book.opf", "c:\(m)/book.opf", "50% off/a:\(m)book.opf"] {
                let path = ResourceReference.rootfilePath(fullPath, isEntry: always)
                if scalars(path) != scalars(fullPath) { wrong.append("\(fullPath.debugDescription) named \(path?.debugDescription ?? "nothing")") }
            }
            // A rootfile path is not read past what a manifest href is: it names nothing.
            for fullPath in ["../\(m)book.opf", "OPS/../../\(m)book.opf", "/\(m)OPS/book.opf", "OPS//\(m)book.opf", "OPS\\\(m)book.opf",
                             "50% off/../\(m)book.opf", "50% off/./\(m)book.opf", "/\(m)50% off/book.opf", "50% off//\(m)book.opf", "50% off\\\(m)book.opf"] {
                if let path = ResourceReference.rootfilePath(fullPath, isEntry: always) { wrong.append("\(fullPath.debugDescription) named \(path.debugDescription)") }
            }
        }
        for scalar in Self.clustering.before {
            let m = String(scalar)
            for fullPath in ["OPS/book.opf/x\(m)/..", "OPS/book.opf\(m)/", "OPS\(m)\\book.opf", "50% off/x\(m)/..", "50% off/book.opf\(m)/"] {
                if let path = ResourceReference.rootfilePath(fullPath, isEntry: always) { wrong.append("\(fullPath.debugDescription) named \(path.debugDescription)") }
            }
        }
        XCTAssertEqual(wrong.count, 0, wrong.prefix(20).joined(separator: ", "))
    }

    func testNoReferenceBuiltFromSeparatorsDotsAndMarksEscapesOrPassesAsAPathItsBytesAreNot() throws {
        let pieces = ["a", "b.xhtml", "..", ".", "/", "\\", ":", "#", "?", "%2F", "%2E", "%5C", "%3A", "%23", "\0", "\u{301}", "\u{FE0F}", "\u{200D}",
                      "\u{20E3}", "\u{1F3FB}", "\u{93E}", "\u{600}", "%CC%81", "%D8%80"]
        let fewer = ["a", "..", ".", "/", "\\", ":", "#", "%2F", "\u{301}", "\u{200D}", "\u{600}"]
        var hrefs = pieces
        for first in pieces { for second in pieces { hrefs.append(first + second) } }
        for first in pieces { for second in pieces { for third in pieces { hrefs.append(first + second + third) } } }
        for first in fewer { for second in fewer { for third in fewer { for fourth in fewer { hrefs.append(first + second + third + fourth) } } } }
        // Whether a resolved reference is printable ASCII that resolves to itself from the root
        // and names a path its bytes pass as: one that is read, or one about to be written.
        func holds(_ result: String, written: Bool) -> Bool {
            guard let path = result.utf8.split(separator: 0x23, maxSplits: 1, omittingEmptySubsequences: false).first.flatMap({ String($0)?.removingPercentEncoding }) else { return false }
            return (written ? isSafeAsBytes(path) : isReadableAsBytes(path)) && result.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
                && (try? ResourceReference.resolve(result, relativeTo: "root.opf", strict: written)) == result
        }
        var resolved = 0, refused = 0, written = 0, readable = 0, safe = 0
        for href in hrefs {
            XCTAssertEqual(ResourceReference.isReadablePath(href), isReadableAsBytes(href), href.debugDescription)
            XCTAssertEqual(ResourceReference.isSafePath(href), isSafeAsBytes(href), href.debugDescription)
            readable += ResourceReference.isReadablePath(href) ? 1 : 0
            safe += ResourceReference.isSafePath(href) ? 1 : 0
            if let path = ResourceReference.rootfilePath(href, isEntry: { _ in true }) {
                XCTAssertTrue(isReadableAsBytes(path), "\(href.debugDescription) as a rootfile path named \(path.debugDescription)")
            }
            for base in ["OPS/text/ch1.xhtml", "root.opf", "a/\u{301}b/c\u{600}/d.opf"] {
                var read: String?
                do { read = try ResourceReference.resolve(href, relativeTo: base) } catch {
                    XCTAssertEqual(error as? EPUBPublicationError, .unsafePath(href), href.debugDescription)
                }
                if let read {
                    resolved += 1
                    if !holds(read, written: false) { XCTFail("\(href.debugDescription) from \(base) resolved to \(read.debugDescription)") }
                } else { refused += 1 }
                // About to be written, it resolves to what it does when read, or is refused.
                if let strict = try? ResourceReference.resolve(href, relativeTo: base, strict: true) {
                    written += 1
                    if strict != read || !holds(strict, written: true) { XCTFail("\(href.debugDescription) from \(base) to be written resolved to \(strict.debugDescription)") }
                }
            }
        }
        XCTAssertGreaterThan(resolved, 10_000)
        XCTAssertGreaterThan(refused, 10_000)
        XCTAssertGreaterThan(written, 10_000)
        XCTAssertGreaterThan(safe, 1_000)
        XCTAssertGreaterThan(readable, safe, "some of the paths hold a colon and nothing else a path may not")
    }

    func testDotsBesideADefaultIgnorableCharacterAreAName() {
        // Decided on https://github.com/vocaro/EPUBLib/issues/205: a segment of dots and
        // default-ignorable characters is a name the reader accepts, and the host's to judge
        // (doc/integration.md), whether or not the character joins a dot's `Character`.
        var wrong: [String] = [], count = 0
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value), scalar.properties.isDefaultIgnorableCodePoint else { continue }
            count += 1
            let z = String(scalar), e = escaped(z)
            for (name, written) in ["\(z)..": "\(e)..", "..\(z)": "..\(e)", ".\(z).": ".\(e).", "\(z).": "\(e).", ".\(z)": ".\(e)"] {
                for path in [name, "a/\(name)/b", "a/\(name)"]
                where !ResourceReference.isReadablePath(path) || !ResourceReference.isSafePath(path) || !isSafeAsBytes(path) {
                    wrong.append(path.debugDescription)
                }
                // In a reference it is a segment like any other: nothing is stepped out of.
                for strict in [false, true] where (try? ResourceReference.resolve("\(name)/x", relativeTo: base, strict: strict)) != "OPS/text/\(written)/x" {
                    wrong.append("\(name.debugDescription) in a reference\(strict ? " about to be written" : "")")
                }
            }
        }
        XCTAssertGreaterThan(count, 4_000, "U+FEFF, the zero-width space and joiners, the variation selectors and tags among them")
        XCTAssertEqual(wrong.count, 0, wrong.prefix(20).joined(separator: ", "))
    }

    func testNamesInAnyScriptAndEitherNormalizationFormAreReadAsTheyWere() throws {
        // A mark, selector or joiner inside a name belongs to the name: an accent composed and
        // decomposed, emoji of several scalars, right-to-left and East Asian text, Hangul in
        // syllables and in jamo, an Indic conjunct and Thai.
        let names = ["caf\u{E9}", "cafe\u{301}", "A\u{30A}ngstro\u{308}m", "\u{1F469}\u{200D}\u{1F4BB}", "\u{1F44D}\u{1F3FD}", "\u{1F1EF}\u{1F1F5}",
                     "1\u{FE0F}\u{20E3}", "\u{2764}\u{FE0F}", "\u{627}\u{644}\u{643}\u{62A}\u{627}\u{628}", "\u{5E1}\u{5B5}\u{5E4}\u{5B6}\u{5E8}",
                     "\u{65E5}\u{672C}\u{8A9E}", "\u{304B}\u{3099}", "\u{D55C}\u{AE00}", "\u{1112}\u{1161}\u{11AB}", "\u{915}\u{94D}\u{937}", "\u{E19}\u{E49}\u{E33}"]
        for name in names {
            let e = escaped(name)
            for path in [name, "OPS/\(name)/\(name).xhtml", "\(name).\(name)", ".\(name)", "\(name)..", "\(name)/...", "\(name) \(name)/#\(name)?%"] {
                XCTAssertTrue(ResourceReference.isSafePath(path), path.debugDescription)
                XCTAssertTrue(ResourceReference.isSafePath(path + "/", directory: true), path.debugDescription)
            }
            for path in ["\(name)/", "/\(name)", "\(name)//\(name)", "../\(name)", "\(name)/../\(name)", "\(name)/..", "./\(name)", "\(name)/./\(name)",
                         "\(name)/.", "\(name)\\\(name)", "\(name)\0"] {
                XCTAssertFalse(ResourceReference.isReadablePath(path), path.debugDescription)
                XCTAssertFalse(ResourceReference.isSafePath(path), path.debugDescription)
                XCTAssertEqual(isReadableAsBytes(path), false, path.debugDescription)
            }
            // A colon is read, and refused in a path about to be written.
            XCTAssertTrue(ResourceReference.isReadablePath("\(name):\(name)"), name)
            XCTAssertFalse(ResourceReference.isSafePath("\(name):\(name)"), name)
            let cases = [
                "\(name).xhtml": "OPS/text/\(e).xhtml", "\(e).xhtml": "OPS/text/\(e).xhtml", "./\(name)/\(name).xhtml": "OPS/text/\(e)/\(e).xhtml",
                "../\(name)/../\(name).css": "OPS/\(e).css", "../../\(name)": e, "\(name)/./\(name)/../x": "OPS/text/\(e)/x",
                "\(name)//\(name)": "OPS/text/\(e)/\(e)", "\(name).xhtml#\(name)": "OPS/text/\(e).xhtml#\(e)", "#\(name)": "OPS/text/ch1.xhtml#\(e)",
                "\(name)%2F\(name)": "OPS/text/\(e)/\(e)", "\(name)/%2E%2E/x": "OPS/text/x",
            ]
            for (href, expected) in cases {
                XCTAssertEqual(try ResourceReference.resolve(href, relativeTo: base), expected, href.debugDescription)
                XCTAssertEqual(try ResourceReference.resolve(expected, relativeTo: "root.opf"), expected, href.debugDescription)
            }
            XCTAssertEqual(try ResourceReference.resolve("../x", relativeTo: "\(name)/\(name)/\(name).opf"), "\(e)/x", name)
            XCTAssertEqual(try ResourceReference.resolve("", relativeTo: "\(name)/\(name).opf"), "\(e)/\(e).opf", name)
            // Read past, and refused in a reference about to be written: a step above the root
            // and an opening slash (https://github.com/vocaro/EPUBLib/issues/84), a colon and a
            // query (https://github.com/vocaro/EPUBLib/issues/171).
            let forgiven = ["../../../\(name)": e, "/\(name)": e, "./\(name):\(name)": "OPS/text/\(e)%3A\(e)", "\(name).xhtml?\(name)": "OPS/text/\(e).xhtml"]
            for (href, expected) in forgiven {
                XCTAssertEqual(try ResourceReference.resolve(href, relativeTo: base), expected, href.debugDescription)
                XCTAssertThrowsError(try ResourceReference.resolve(href, relativeTo: base, strict: true), href.debugDescription) {
                    XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath(href), href.debugDescription)
                }
            }
            // A backslash and an authority are refused either way.
            for href in ["\(name)\\\(name)", "//\(name)/x"] {
                for strict in [false, true] {
                    XCTAssertThrowsError(try ResourceReference.resolve(href, relativeTo: base, strict: strict), href.debugDescription) {
                        XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath(href), href.debugDescription)
                    }
                }
            }
            // A rootfile path, by its URL reading and as written.
            let entry = "\(name)/\(name).opf"
            for fullPath in [entry, "\(e)/\(e).opf", "./\(name)/x/../\(name).opf", "\(name)%2F\(name).opf"] {
                XCTAssertEqual(scalars(ResourceReference.rootfilePath(fullPath, isEntry: { $0.unicodeScalars.elementsEqual(entry.unicodeScalars) })),
                               scalars(entry), fullPath.debugDescription)
            }
            let written = "\(name) 100%/\(name)#1.opf"
            XCTAssertEqual(scalars(ResourceReference.rootfilePath(written, isEntry: { $0.unicodeScalars.elementsEqual(written.unicodeScalars) })), scalars(written))
            for fullPath in ["../\(name).opf", "/\(name).opf", "\(name)/", "\(name)//\(name).opf", "\(name)\\\(name).opf", "\(name)/.."] {
                XCTAssertNil(ResourceReference.rootfilePath(fullPath, isEntry: { _ in true }), fullPath.debugDescription)
            }
        }
    }
}
