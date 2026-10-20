import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// `META-INF/container.xml` and `META-INF/encryption.xml`.
final class ContainerDocumentCoverageTests: XCTestCase {
    private static let idpf = "http://www.idpf.org/2008/embedding"
    private static let adobe = "http://ns.adobe.com/pdf/enc#RC"

    /// The plain book with everything under `OPS/` moved to `folder` ("" for the container root)
    /// and its package document renamed, as `fullPath` then has to say.
    private func relocated(to folder: String, package: String = "book.opf", fullPath: String) throws -> Data {
        var files: [String: Data] = [:]
        for (path, data) in try Fixture.files() {
            files[path.hasPrefix("OPS/") ? folder + (path == "OPS/book.opf" ? package : String(path.dropFirst(4))) : path] = data
        }
        files["META-INF/container.xml"] = Data(String(decoding: files["META-INF/container.xml"]!, as: UTF8.self)
            .replacingOccurrences(of: "OPS/book.opf", with: fullPath).utf8)
        return try Fixture.archive(files)
    }

    /// The plain book's package document and content with `OPS/` renamed `folder` ("" for the
    /// container root) and the title `title`.
    private func rendition(in folder: String, title: String) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for (path, data) in try Fixture.files() where path.hasPrefix("OPS/") {
            files[folder + String(path.dropFirst(4))] = path == "OPS/book.opf"
                ? Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "A Test Book", with: title).utf8) : data
        }
        return files
    }

    /// An archive of `files` under a container whose rootfile is `fullPath`.
    private func archive(_ files: [String: Data], fullPath: String) throws -> Data {
        var files = files
        files["mimetype"] = Data("application/epub+zip".utf8)
        files["META-INF/container.xml"] = Data(container("<rootfiles><rootfile full-path=\"\(fullPath)\"/></rootfiles>")("").utf8)
        return try Fixture.archive(files)
    }

    private func container(_ rootfiles: String) -> (String) -> String {
        { _ in "<?xml version=\"1.0\"?><container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\">\(rootfiles)</container>" }
    }

    private func assertOpening(_ data: @autoclosure () throws -> Data, throws expected: EPUBPublicationError,
                               _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EPUBPublication.open(data: data()), message, file: file, line: line) {
            XCTAssertEqual($0 as? EPUBPublicationError, expected, "\(message): \($0)", file: file, line: line)
        }
    }

    // MARK: container.xml

    func testAPackageDocumentInTheContainerRootResolvesItsReferencesFromTheRoot() throws {
        let book = try EPUBPublication.open(data: relocated(to: "", fullPath: "book.opf"))
        XCTAssertEqual(book.spine.map(\.resource.path), ["one.xhtml", "two.xhtml"])
        XCTAssertEqual(book.spine[0].resource.href, "one.xhtml")
        XCTAssertEqual(book.tableOfContents.first?.href, "one.xhtml#start")
        XCTAssertEqual(book.tableOfContents.first?.children.first?.href, "two.xhtml")
    }

    func testThePackageDocumentMayHaveAnyNameInAnyFolder() throws {
        let book = try EPUBPublication.open(data: relocated(to: "a/b c/d/", package: "volume.xml", fullPath: "a/b c/d/volume.xml"))
        XCTAssertEqual(book.metadata.title, "A Test Book")
        XCTAssertEqual(book.spine.map(\.resource.path), ["a/b c/d/one.xhtml", "a/b c/d/two.xhtml"])
        XCTAssertEqual(book.spine[0].resource.href, "a/b%20c/d/one.xhtml")
        XCTAssertEqual(book.tableOfContents.first?.href, "a/b%20c/d/one.xhtml#start")
    }

    func testARootfilePathOutsideASCIINamesItsFile() throws {
        let book = try EPUBPublication.open(data: relocated(to: "B\u{FC}cher/", package: "\u{672C}.opf", fullPath: "B\u{FC}cher/\u{672C}.opf"))
        XCTAssertEqual(book.spine.map(\.resource.path), ["B\u{FC}cher/one.xhtml", "B\u{FC}cher/two.xhtml"])
        XCTAssertEqual(book.tableOfContents.first?.href, "B%C3%BCcher/one.xhtml#start")
    }

    func testAPercentEncodedRootfilePathNamesTheDecodedFile() throws {
        // EPUB 3.3 §4.2.6.3.1.3: full-path is a path-relative-scheme-less-URL string, so a space
        // in the path is written %20.
        let literal = try EPUBPublication.open(data: relocated(to: "My Books/", fullPath: "My Books/book.opf"))
        XCTAssertEqual(literal.spine.map(\.resource.path), ["My Books/one.xhtml", "My Books/two.xhtml"], "written with a space")
        XCTAssertEqual(try EPUBPublication.open(data: relocated(to: "My Books/", fullPath: "My%20Books/book.opf")).spine.map(\.resource.path),
                       ["My Books/one.xhtml", "My Books/two.xhtml"], "written %20")
    }

    func testARootfilePathIsReadPastTheWhiteSpaceRoundIt() throws {
        // As URL parsing reads it (https://github.com/vocaro/EPUBLib/issues/76). Written as an
        // escape, white space is a character of the name (testARootfilePathIsJudgedOnlyOnceDecoded).
        for fullPath in [" OPS/book.opf", "OPS/book.opf ", "&#9;OPS/book.opf&#13;&#10;", "\n  OPS/book.opf\n"] {
            let book = try EPUBPublication.open(data: Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"\(fullPath)\"/></rootfiles>")))
            XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"], fullPath.debugDescription)
        }
        // White space alone names the container root's file no more than an empty value does, and
        // none hides what a rootfile path may not be.
        for fullPath in ["", "  ", "&#9;", " /OPS/book.opf", "OPS/book.opf/ ", " ../OPS/book.opf", " OPS//book.opf", "OPS/book.opf#x "] {
            assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"\(fullPath)\"/></rootfiles>")),
                          throws: .invalidXML("container rootfile"), fullPath.debugDescription)
        }
    }

    func testARootfilePathIsDecodedOnce() throws {
        let cases: [(folder: String, package: String, fullPath: String)] = [
            // Any octet, in either case of hexadecimal digit.
            ("B\u{FC}cher/", "\u{672C}.opf", "B%C3%BCcher/%e6%9c%ac.opf"),
            ("OPS/", "book.opf", "%4FPS/b%6Fok.opf"),
            // What a URL reads as syntax is part of a name when escaped.
            ("50% off #1?/", "book.opf", "50%25%20off%20%231%3F/book.opf"),
            // Once only: what is left is the name, though it reads as an escape or a dot segment.
            ("a%20b/", "book.opf", "a%2520b/book.opf"),
            ("%2e%2e/", "book.opf", "%252e%252e/book.opf"),
        ]
        for (folder, package, fullPath) in cases {
            let book = try EPUBPublication.open(data: relocated(to: folder, package: package, fullPath: fullPath))
            XCTAssertEqual(book.metadata.title, "A Test Book", fullPath)
            XCTAssertEqual(book.spine.map(\.resource.path), [folder + "one.xhtml", folder + "two.xhtml"], fullPath)
            XCTAssertEqual(book.tableOfContents.first?.href.flatMap(\.removingPercentEncoding), folder + "one.xhtml#start", fullPath)
        }
    }

    func testARootfilePathResolvesItsDotSegmentsWithinTheContainer() throws {
        // Written out or escaped, and around an escaped separator, as in a manifest href.
        for fullPath in ["./OPS/book.opf", "OPS/./book.opf", "OPS/text/../book.opf", "OPS/%2E/book.opf", "OPS/text/%2e%2e/book.opf",
                         "OPS%2Fbook.opf", "OPS%2ftext%2F..%2Fbook.opf", "OPS/book.opf/../book.opf"] {
            let book = try EPUBPublication.open(data: Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"\(fullPath)\"/></rootfiles>")))
            XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"], fullPath)
            XCTAssertEqual(book.tableOfContents.first?.href, "OPS/one.xhtml#start", fullPath)
        }
    }

    func testARootfilePathHasToEndInAFilesName() throws {
        // A URL path that closes with a slash, written or left by a closing dot segment (URL
        // Standard, path state), is a folder's, and an empty segment is part of no archive name.
        // Reading either as the package document beside it would be a repair, which a manifest
        // href gets and a rootfile, refused in these forms before, does not.
        for fullPath in ["OPS/book.opf/", "OPS/book.opf%2F", "OPS/book.opf/x/..", "OPS/book.opf/x/%2e%2e", "OPS/book.opf/.", "OPS/book.opf/%2E",
                         "OPS//book.opf", "OPS%2F%2Fbook.opf", ".//OPS/book.opf", "OPS/", "OPS/text/.."] {
            assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"\(fullPath)\"/></rootfiles>")),
                          throws: .invalidXML("container rootfile"), fullPath.debugDescription)
        }
    }

    func testARootfilePathIsJudgedOnlyOnceDecoded() throws {
        // The path is an untrusted archive's word, so what its escapes spell is what is checked.
        // None of these is the name of an entry as written, which is the other reading (below).
        let refused = [
            // A dot segment that leaves the container, or leaves no name.
            "%2e%2e/OPS/book.opf", "%2E%2E/%2E%2E/escape", ".%2E/OPS/book.opf", "%2e./OPS/book.opf", "OPS/%2e%2e/%2e%2e/OPS/book.opf", "%2E", "OPS/%2e%2e",
            // A separator: one that hides a dot segment or makes the path absolute, and one other systems read.
            "..%2FOPS%2Fbook.opf", "OPS%2F..%2F..%2Fescape", "OPS%2f%2e%2e%2f%2e%2e%2fescape", "%2FOPS/book.opf", "%2F%2Fexample.invalid/book.opf",
            "OPS%5Cbook.opf", "OPS%5cbook.opf", "..%5Cescape", "%5C%5Cexample.invalid%5Cbook.opf",
            // A NUL.
            "%00", "OPS/book.opf%00", "OPS/book%00.opf", "OPS%00/book.opf",
            // No escape at all, or none of UTF-8: a lone byte, an overlong "..", "." or "/", half a surrogate pair.
            "%", "OPS/book.opf%", "OPS/book.opf%4", "OPS/%zz/book.opf", "OPS/book%.opf", "OPS/%E9.opf", "OPS/%C3", "OPS/%C3%28.opf",
            "%C0%AE%C0%AE/OPS/book.opf", "%E0%80%AE%E0%80%AE/OPS/book.opf", "%C0%AFOPS/book.opf", "OPS%C0%AFbook.opf", "%ED%A0%80/book.opf",
            // As before, the same written out and another origin, whose scheme an escape does not hide.
            "../OPS/book.opf", "OPS/../../escape", "/OPS/book.opf", "//example.invalid/book.opf", "OPS\\book.opf", "C:/book.opf", ".", "OPS/..",
            "file:///OPS/book.opf", "https://example.invalid/book.opf", "%66ile:///OPS/book.opf", "%68ttps://example.invalid/book.opf",
            // More than a file's path: a query or a fragment, empty or not.
            "OPS/book.opf?v=2", "OPS/book.opf?", "?", "OPS/book.opf#package", "OPS/book.opf#", "#package",
        ]
        for fullPath in refused {
            assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"\(fullPath)\"/></rootfiles>")),
                          throws: .invalidXML("container rootfile"), fullPath.debugDescription)
        }
        // A control character other than NUL separates nothing and is no worse in a name than in
        // an entry's own: the name it spells is looked up, and is not there. Nor does an escaped
        // colon separate anything, in a key of the archive read into memory.
        for (fullPath, path) in [("OPS/book.opf%0A", "OPS/book.opf\n"), ("OPS/book.opf%0D%0A", "OPS/book.opf\r\n"), ("%09OPS/book.opf", "\tOPS/book.opf"),
                                 ("OPS/book%7F.opf", "OPS/book\u{7F}.opf"), ("OPS/%1Fbook.opf", "OPS/\u{1F}book.opf"),
                                 ("C%3A/book.opf", "C:/book.opf"), ("OPS/a%3Ab.opf", "OPS/a:b.opf")] {
            assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"\(fullPath)\"/></rootfiles>")),
                          throws: .missingResource(path), fullPath.debugDescription)
        }
    }

    func testARootfilePathThatIsNoURLOfAnEntryNamesTheEntryWrittenThatWay() throws {
        // Validators long looked full-path up as written, so books carry a name's own "%", "#"
        // and "?" unescaped. Read as a URL such a value is refused or names nothing; the entry of
        // that very name is then the package document, and the base of its references.
        let cases: [(folder: String, package: String)] = [
            // No escape, or none of UTF-8.
            ("OPS/", "100%.opf"), ("50% off/", "book.opf"), ("caf%E9/", "book.opf"),
            // A fragment or a query, were it a URL.
            ("Book #1/", "book.opf"), ("OPS/", "vol#2.opf"), ("What?/", "book.opf"),
            // An escape of a name the archive lacks.
            ("a%20b/", "book.opf"), ("x%41/", "book.opf"), ("OPS/", "100%25.opf"),
            // An escape of what no name may hold: a dot segment out of the container, a separator, a NUL.
            ("%2e%2e/", "book.opf"), ("a%2F..%2F..%2Fb/", "book.opf"), ("OPS/", "a%5Cb.opf"), ("OPS/", "a%00b.opf"),
        ]
        for (folder, package) in cases {
            let book = try EPUBPublication.open(data: relocated(to: folder, package: package, fullPath: folder + package))
            XCTAssertEqual(book.metadata.title, "A Test Book", folder + package)
            XCTAssertEqual(book.spine.map(\.resource.path), [folder + "one.xhtml", folder + "two.xhtml"], folder + package)
            XCTAssertEqual(book.tableOfContents.first?.href.flatMap(\.removingPercentEncoding), folder + "one.xhtml#start", folder + package)
        }
        // The value as written is an archive path or nothing: it is not resolved.
        for fullPath in ["./50% off/book.opf", "50% off//book.opf", "50% off/x/../book.opf", "50% off/book.opf#package", "50% off/book.opf/"] {
            assertOpening(try relocated(to: "50% off/", fullPath: fullPath), throws: .invalidXML("container rootfile"), fullPath)
        }
    }

    func testTheURLReadingOfARootfilePathComesBeforeThePathAsWritten() throws {
        // An archive holding a book under each spelling.
        let both = try rendition(in: "a b/", title: "Decoded").merging(rendition(in: "a%20b/", title: "Written")) { $1 }
        let first = try EPUBPublication.open(data: archive(both, fullPath: "a%20b/book.opf"))
        XCTAssertEqual(first.metadata.title, "Decoded")
        XCTAssertEqual(first.spine.map(\.resource.path), ["a b/one.xhtml", "a b/two.xhtml"])
        XCTAssertEqual(first.tableOfContents.first?.href, "a%20b/one.xhtml#start")
        // The other is reached by its own URL.
        let second = try EPUBPublication.open(data: archive(both, fullPath: "a%2520b/book.opf"))
        XCTAssertEqual(second.metadata.title, "Written")
        XCTAssertEqual(second.spine.map(\.resource.path), ["a%20b/one.xhtml", "a%20b/two.xhtml"])
        // Whichever reading finds the package document, the path it was read at is the base of
        // its references: content under the other spelling is no part of the book.
        let onlyWritten = try EPUBPublication.open(data: archive(both.filter { $0.key != "a b/book.opf" }, fullPath: "a%20b/book.opf"))
        XCTAssertEqual(onlyWritten.metadata.title, "Written")
        XCTAssertEqual(onlyWritten.spine.map(\.resource.path), ["a%20b/one.xhtml", "a%20b/two.xhtml"])
        XCTAssertEqual(onlyWritten.tableOfContents.first?.href, "a%2520b/one.xhtml#start")
        XCTAssertEqual(onlyWritten.resources.map(\.path).filter { $0.hasPrefix("a b/") }, [])
        let onlyDecoded = try EPUBPublication.open(data: archive(both.filter { $0.key != "a%20b/book.opf" }, fullPath: "a%20b/book.opf"))
        XCTAssertEqual(onlyDecoded.metadata.title, "Decoded")
        XCTAssertEqual(onlyDecoded.spine.map(\.resource.path), ["a b/one.xhtml", "a b/two.xhtml"])
        XCTAssertEqual(onlyDecoded.resources.map(\.path).filter { $0.hasPrefix("a%20b/") }, [])
    }

    func testARootfilePathThatLeavesTheContainerNamesNoEntryButOneWrittenThatWay() throws {
        // A book in the container root and one under OPS/, either of which these would name were
        // ".." stopped at the root or dropped.
        var files = try rendition(in: "", title: "Root").merging(rendition(in: "OPS/", title: "OPS")) { $1 }
        let leaving = ["../book.opf", "%2e%2e/book.opf", "%2E%2E%2Fbook.opf", "x/%2e%2e/%2e%2e/book.opf", "OPS/%2e%2e/%2e%2e/book.opf", "%2e%2e%5Cbook.opf",
                       "%2e%2e/OPS/book.opf", "..%2FOPS%2Fbook.opf", "OPS/%2e%2e/%2e%2e/OPS/book.opf", "OPS/../../OPS/book.opf"]
        for fullPath in leaving {
            assertOpening(try archive(files, fullPath: fullPath), throws: .invalidXML("container rootfile"), fullPath.debugDescription)
        }
        XCTAssertEqual(try EPUBPublication.open(data: archive(files, fullPath: "OPS/%2e%2e/book.opf")).metadata.title, "Root", "within the container")
        // With a third book in a folder named "%2e%2e", the one value that is its package
        // document's name as written names it, and nothing else does.
        files.merge(try rendition(in: "%2e%2e/", title: "Written")) { $1 }
        for fullPath in leaving where fullPath != "%2e%2e/book.opf" {
            assertOpening(try archive(files, fullPath: fullPath), throws: .invalidXML("container rootfile"), fullPath.debugDescription)
        }
        let book = try EPUBPublication.open(data: archive(files, fullPath: "%2e%2e/book.opf"))
        XCTAssertEqual(book.metadata.title, "Written")
        XCTAssertEqual(book.spine.map(\.resource.path), ["%2e%2e/one.xhtml", "%2e%2e/two.xhtml"])
        XCTAssertEqual(book.tableOfContents.first?.href, "%252e%252e/one.xhtml#start")
    }

    // A `Character` holds a "/", "\", ":" or "." together with a mark, selector or joiner after
    // it, so read that way "../" + U+0301 + "book.opf" has no dot segment and no separator. An
    // archive and a file system read bytes (https://github.com/vocaro/EPUBLib/issues/181).
    func testARootfilePathIsReadWhateverMarkFollowsItsSeparatorsAndDots() throws {
        for m in Fixture.clusteringMarks {
            let e = Fixture.escapingNonASCII(m)
            // A package document whose name, or whose folder's, begins with the mark: named as a
            // URL, written out or escaped and through dot segments, and named as written.
            let cases: [(folder: String, package: String, fullPath: String)] = [
                ("OPS/", "\(m)book.opf", "OPS/\(m)book.opf"), ("OPS/", "\(m)book.opf", "OPS/\(e)book.opf"), ("OPS/", "\(m)book.opf", "OPS/x/../\(m)book.opf"),
                ("OPS/", "\(m)book.opf", "OPS/./\(m)book.opf"), ("OPS/", "\(m)book.opf", "OPS%2F\(e)book.opf"), ("\(m)OPS/", "book.opf", "\(m)OPS/book.opf"),
                ("a/\(m)b/", "book.opf", "a/c/../\(m)b/book.opf"), ("50% off/", "\(m)book.opf", "50% off/\(m)book.opf"),
                ("50% off/\(m)x/", "book.opf", "50% off/\(m)x/book.opf"),
                // A colon is a character of the name (https://github.com/vocaro/EPUBLib/issues/171):
                // escaped and written out, and where it reads as a scheme and so only as written.
                ("OPS/a:\(m)b/", "book.opf", "OPS/a%3A\(e)b/book.opf"), ("OPS/a:\(m)b/", "book.opf", "OPS/a:\(m)b/book.opf"),
                ("c:\(m)/", "book.opf", "c:\(m)/book.opf"),
            ]
            for (folder, package, fullPath) in cases {
                let book = try EPUBPublication.open(data: relocated(to: folder, package: package, fullPath: fullPath))
                XCTAssertEqual(book.metadata.title, "A Test Book", fullPath.debugDescription)
                XCTAssertEqual(book.spine.map { Array($0.resource.path.unicodeScalars) },
                               [folder + "one.xhtml", folder + "two.xhtml"].map { Array($0.unicodeScalars) }, fullPath.debugDescription)
                XCTAssertEqual(book.tableOfContents.first?.href.flatMap(\.removingPercentEncoding), folder + "one.xhtml#start", fullPath.debugDescription)
            }
            // Neither reading takes these: out of the container, an opening or doubled slash or
            // a backslash, as a URL and where a "%" leaves only the path as written.
            for fullPath in ["../\(m)OPS/book.opf", "OPS/../../\(m)OPS/book.opf", "/\(m)OPS/book.opf", "OPS//\(m)book.opf", "OPS\\\(m)book.opf",
                             "50% off/../\(m)book.opf", "50% off/./\(m)book.opf", "50% off//\(m)book.opf", "50% off\\\(m)book.opf"] {
                assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"\(fullPath)\"/></rootfiles>")),
                              throws: .invalidXML("container rootfile"), fullPath.debugDescription)
            }
            // A path with a colon is one, and here names no entry.
            assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"OPS/a:\(m)book.opf\"/></rootfiles>")),
                          throws: .missingResource("OPS/a:\(m)book.opf"), m.debugDescription)
        }
    }

    func testTheFirstRootfileNamesThePackageDocument() throws {
        // EPUB Reading Systems 3.3 §4.1.3: by default the package document of the first rootfile.
        let other = String(decoding: try Fixture.files()["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: "A Test Book", with: "Another Rendition")
        func title(_ paths: [String]) throws -> String {
            let rootfiles = paths.map { "<rootfile full-path=\"\($0)\" media-type=\"application/oebps-package+xml\"/>" }.joined()
            return try EPUBPublication.open(data: Fixture.packageVariant(container: container("<rootfiles>\(rootfiles)</rootfiles>"),
                                                                         adding: ["OPS/other.opf": Data(other.utf8)])).metadata.title
        }
        XCTAssertEqual(try title(["OPS/book.opf", "OPS/other.opf"]), "A Test Book")
        XCTAssertEqual(try title(["OPS/other.opf", "OPS/book.opf", "OPS/missing.opf"]), "Another Rendition")
    }

    func testARootfileThatIsNoPackageDocumentIsPassedOverForTheFirstThatIs() throws {
        // OCF 2.0.1 let a container list other renditions, such as a PDF, and some list one first.
        let package = "application/oebps-package+xml"
        func data(_ rootfiles: [(path: String, type: String?)]) throws -> Data {
            let elements = rootfiles.map { "<rootfile full-path=\"\($0.path)\"" + ($0.type.map { " media-type=\"\($0)\"" } ?? "") + "/>" }.joined()
            let other = String(decoding: try Fixture.files()["OPS/book.opf"]!, as: UTF8.self).replacingOccurrences(of: "A Test Book", with: "Another Rendition")
            return try Fixture.packageVariant(container: container("<rootfiles>\(elements)</rootfiles>"),
                                              adding: ["book.pdf": Data("%PDF-1.7".utf8), "OPS/other.opf": Data(other.utf8)])
        }
        func title(_ rootfiles: [(path: String, type: String?)]) throws -> String { try EPUBPublication.open(data: data(rootfiles)).metadata.title }
        XCTAssertEqual(try title([("book.pdf", "application/pdf"), ("OPS/book.opf", package), ("OPS/other.opf", package)]), "A Test Book")
        XCTAssertEqual(try title([("book.pdf", "application/pdf"), ("OPS/other.opf", nil), ("OPS/book.opf", package)]), "A Test Book",
                       "an untyped rootfile is passed over too")
        XCTAssertEqual(try title([("book.pdf", "application/pdf"), ("OPS/book.opf", " Application/OEBPS-Package+XML&#10;")]), "A Test Book",
                       "a media type is compared without regard to case or the white space around it")
        // Where none is typed as a package document, the first rootfile is taken for one.
        XCTAssertEqual(try title([("OPS/book.opf", nil), ("book.pdf", "application/pdf")]), "A Test Book")
        XCTAssertEqual(try title([("OPS/book.opf", "application/xml"), ("OPS/other.opf", "text/xml")]), "A Test Book")
        assertOpening(try data([("book.pdf", "application/pdf"), ("OPS/book.opf", nil)]), throws: .invalidXML("book.pdf"))
        // The first one typed as a package document is the one, usable or not.
        assertOpening(try data([("OPS/absent.opf", package), ("OPS/book.opf", package)]), throws: .missingResource("OPS/absent.opf"))
    }

    func testARootfilePathMayHoldAColon() throws {
        // Escaped as a URL has it, and as written, which may read as a scheme and is then only
        // the name of the entry written that way.
        for (folder, fullPath) in [("Vol 1: Start/", "Vol%201%3A%20Start/book.opf"), ("Vol 1: Start/", "Vol 1: Start/book.opf"), ("a:b/", "a:b/book.opf")] {
            let book = try EPUBPublication.open(data: relocated(to: folder, fullPath: fullPath))
            XCTAssertEqual(book.spine.map(\.resource.path), [folder + "one.xhtml", folder + "two.xhtml"], fullPath)
            XCTAssertEqual(book.spine[0].resource.href.removingPercentEncoding, folder + "one.xhtml", fullPath)
            XCTAssertFalse(book.spine[0].resource.href.contains(":"), fullPath)
            XCTAssertEqual(book.tableOfContents.first?.href, book.spine[0].resource.href + "#start", fullPath)
        }
        assertOpening(try relocated(to: "a:b/", fullPath: "a:c/book.opf"), throws: .invalidXML("container rootfile"), "a scheme, and no entry's name")
    }

    func testARootfilePathIsNotReadPastWhatAManifestHrefIs() throws {
        // A query is dropped from a manifest href, and a step above the container root stops
        // there (#84). A rootfile was refused in these forms before and still is.
        for fullPath in ["OPS/book.opf?v=2", "/OPS/book.opf", "../OPS/book.opf", "../../OPS/book.opf", "OPS/../../OPS/book.opf", "%2FOPS/book.opf"] {
            assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"\(fullPath)\"/></rootfiles>")),
                          throws: .invalidXML("container rootfile"), fullPath)
        }
    }

    func testAContainerDocumentAsPackagingToolsWriteItIsRead() throws {
        // A byte-order mark, a declaration, a prefix for the namespace, attributes in another
        // order and elements this library has no use for.
        let xml = """
            \u{FEFF}<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <!-- Written by a packaging tool -->
            <ocf:container xmlns:ocf="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <ocf:rootfiles>
                <ocf:rootfile
                    media-type="application/oebps-package+xml"
                    full-path="OPS/book.opf" />
              </ocf:rootfiles>
              <ocf:links><ocf:link href="OPS/map.xml" rel="mapping" media-type="application/xml"/></ocf:links>
            </ocf:container>

            """
        let book = try EPUBPublication.open(data: Fixture.packageVariant(container: { _ in xml }))
        XCTAssertEqual(book.metadata.title, "A Test Book")
    }

    func testAContainerThatNamesNoReadablePackageDocumentFailsTyped() throws {
        assertOpening(try Fixture.packageVariant(adding: ["META-INF/container.xml": nil]), throws: .missingResource("META-INF/container.xml"))
        assertOpening(try Fixture.packageVariant(container: container("<rootfiles/>")), throws: .invalidXML("container rootfile"), "no rootfile")
        assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile media-type=\"application/oebps-package+xml\"/></rootfiles>")),
                      throws: .invalidXML("container rootfile"), "no full-path")
        assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"\"/></rootfiles>")),
                      throws: .invalidXML("container rootfile"), "an empty full-path")
        assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"OPS/absent.opf\"/></rootfiles>")),
                      throws: .missingResource("OPS/absent.opf"))
        assertOpening(try Fixture.packageVariant(container: { _ in "<container><rootfiles>" }), throws: .invalidXML("META-INF/container.xml"))
        assertOpening(try Fixture.packageVariant(container: { _ in "" }), throws: .invalidXML("META-INF/container.xml"), "an empty file")
        assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"OPS/one.xhtml\"/></rootfiles>")),
                      throws: .invalidXML("OPF package, manifest or spine"), "a rootfile that is no package document")
    }

    func testFilesNoManifestListsAreIgnoredButReadable() throws {
        // What stores and tools leave in a container; EPUB 3.3 §4.2.6.1 lets META-INF hold more.
        let extras: [String: Data?] = [
            "META-INF/com.apple.ibooks.display-options.xml": Data("<display_options/>".utf8),
            "META-INF/calibre_bookmarks.txt": Data("encoding=json+base64:".utf8),
            "META-INF/rights.xml": Data("<rights/>".utf8), "META-INF/signatures.xml": Data("<signatures/>".utf8),
            "iTunesMetadata.plist": Data("<plist/>".utf8), "OPS/Thumbs.db": Data([0, 1, 2]),
            // As a Mac's Finder archives a folder.
            "__MACOSX/OPS/._one.xhtml": Data([0, 5, 22, 7]), "OPS/.DS_Store": Data([0, 0, 0, 1]),
        ]
        let plain = try EPUBPublication.open(data: Fixture.epub())
        let book = try EPUBPublication.open(data: Fixture.packageVariant(adding: extras))
        XCTAssertEqual(book.resources, plain.resources)
        XCTAssertEqual(book.metadata, plain.metadata)
        XCTAssertEqual(try book.data(at: "OPS/Thumbs.db"), Data([0, 1, 2]))
    }

    // MARK: encryption.xml

    private func encryption(_ entries: [(algorithm: String, uri: String)]) -> Data {
        let body = entries.map {
            "<enc:EncryptedData><enc:EncryptionMethod Algorithm=\"\($0.algorithm)\"/><enc:CipherData>"
                + "<enc:CipherReference URI=\"\($0.uri)\"/></enc:CipherData></enc:EncryptedData>"
        }.joined(separator: "\n  ")
        return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              \(body)
            </encryption>
            """.utf8)
    }

    private func obfuscated(_ original: Data, key: [UInt8], prefix: Int) -> Data {
        var bytes = original
        for index in 0..<min(prefix, bytes.count) { bytes[index] ^= key[index % key.count] }
        return bytes
    }

    private func sha1(_ text: String) -> [UInt8] { Array(Insecure.SHA1.hash(data: Data(text.utf8))) }

    private func font(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }) }

    /// The plain book with its unique identifier's element content replaced by `identifier`.
    private func book(identifier: String, fonts: [String: Data], encryption: Data) throws -> Data {
        var adding: [String: Data?] = ["META-INF/encryption.xml": encryption]
        for (path, data) in fonts { adding[path] = data }
        return try Fixture.packageVariant(opf: { $0.replacingOccurrences(of: ">test-book<", with: ">\(identifier)<") }, adding: adding)
    }

    func testObfuscatedFontsShorterThanAtAndBeyondTheObfuscatedPrefix() throws {
        let uuid = "urn:uuid:00112233-4455-6677-8899-aabbccddeeff"
        let cases: [(algorithm: String, key: [UInt8], prefix: Int)] = [
            (Self.idpf, sha1(uuid), 1040),
            (Self.adobe, Array(stride(from: UInt8(0x00), through: UInt8(0xff), by: 0x11)), 1024),
        ]
        for (algorithm, key, prefix) in cases {
            for count in [0, 1, key.count - 1, key.count, key.count + 1, prefix - 1, prefix, prefix + 1, 3_000] {
                let original = font(count)
                let data = try book(identifier: uuid, fonts: ["OPS/font.otf": obfuscated(original, key: key, prefix: prefix)],
                                    encryption: encryption([(algorithm, "OPS/font.otf")]))
                XCTAssertEqual(try EPUBPublication.open(data: data).data(at: "OPS/font.otf"), original, "\(algorithm), \(count) bytes")
            }
        }
    }

    func testSeveralFontsUnderBothAlgorithmsAreEachDecodedOnce() throws {
        let uuid = "urn:uuid:00112233-4455-6677-8899-aabbccddeeff"
        let adobeKey = Array(stride(from: UInt8(0x00), through: UInt8(0xff), by: 0x11))
        let originals = ["OPS/fonts/a.otf": font(2_000), "OPS/fonts/b.ttf": font(1_500), "OPS/fonts/c.woff": font(900), "OPS/plain.otf": font(1_200)]
        let data = try book(identifier: uuid, fonts: [
            "OPS/fonts/a.otf": obfuscated(originals["OPS/fonts/a.otf"]!, key: sha1(uuid), prefix: 1040),
            "OPS/fonts/b.ttf": obfuscated(originals["OPS/fonts/b.ttf"]!, key: adobeKey, prefix: 1024),
            "OPS/fonts/c.woff": obfuscated(originals["OPS/fonts/c.woff"]!, key: sha1(uuid), prefix: 1040),
            "OPS/plain.otf": originals["OPS/plain.otf"]!,
        ], encryption: encryption([(Self.idpf, "OPS/fonts/a.otf"), (Self.adobe, "OPS/fonts/b.ttf"), (Self.idpf, "OPS/fonts/c.woff")]))
        let book = try EPUBPublication.open(data: data)
        for (path, original) in originals { XCTAssertEqual(try book.data(at: path), original, path) }
        XCTAssertEqual(book.archiveData, data)
    }

    func testACipherReferenceIsAPercentEncodedPathFromTheContainerRoot() throws {
        // EPUB 3.3 §4.2.5: in META-INF files, URLs are relative to the root, not to the package.
        let original = font(1_100)
        let data = try book(identifier: "test-book", fonts: ["OPS/fonts/My Font \u{E9}.otf": obfuscated(original, key: sha1("test-book"), prefix: 1040)],
                            encryption: encryption([(Self.idpf, "OPS/fonts/My%20Font%20%C3%A9.otf")]))
        XCTAssertEqual(try EPUBPublication.open(data: data).data(at: "OPS/fonts/My Font \u{E9}.otf"), original)
        let colon = try book(identifier: "test-book", fonts: ["OPS/fonts/Serif: Bold.otf": obfuscated(original, key: sha1("test-book"), prefix: 1040)],
                             encryption: encryption([(Self.idpf, "OPS/fonts/Serif%3A%20Bold.otf")]))
        XCTAssertEqual(try EPUBPublication.open(data: colon).data(at: "OPS/fonts/Serif: Bold.otf"), original, "a colon in the path")
    }

    func testTheIDPFKeyIgnoresXMLWhiteSpaceInTheIdentifier() throws {
        // EPUB 3.3 §4.4.3: U+0020, U+0009, U+000D and U+000A are removed before hashing.
        let original = font(1_100)
        let data = try book(identifier: "\n    urn:isbn: 978 0\t00 000000\n 2\r\n  ",
                            fonts: ["OPS/font.otf": obfuscated(original, key: sha1("urn:isbn:9780000000002"), prefix: 1040)],
                            encryption: encryption([(Self.idpf, "OPS/font.otf")]))
        XCTAssertEqual(try EPUBPublication.open(data: data).data(at: "OPS/font.otf"), original)
    }

    func testTheKeyIsMadeFromAnIdentifierInsideTheDeprecatedDCMetadataElement() throws {
        // OPF 2.0.1 §2.2 has a reading system allow `dc-metadata`, which OEBPS 1.2 packages wrapped
        // their Dublin Core elements in, the unique identifier among them (#85). Read without it,
        // the identifier was empty: IDPF's key could not be made and the book was refused, and
        // Adobe's, from the first identifier that is a UUID, left its font out.
        let uuid = "urn:uuid:00112233-4455-6677-8899-aabbccddeeff"
        let original = font(1_100)
        // A book for each algorithm, so that neither stops the other being checked.
        func check(_ algorithm: String, key: [UInt8], prefix: Int) throws {
            let data = try Fixture.packageVariant(epub2: true, opf: {
                $0.replacingOccurrences(of: "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">",
                                        with: "<metadata><dc-metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">")
                    .replacingOccurrences(of: "</metadata>", with: "</dc-metadata></metadata>").replacingOccurrences(of: ">test-book<", with: ">\(uuid)<")
            }, adding: ["META-INF/encryption.xml": encryption([(algorithm, "OPS/font.otf")]),
                        "OPS/font.otf": obfuscated(original, key: key, prefix: prefix)])
            let book = try EPUBPublication.open(data: data)
            XCTAssertEqual(book.metadata.identifiers, [uuid], algorithm)
            XCTAssertEqual(try book.data(at: "OPS/font.otf"), original, algorithm)
        }
        XCTAssertNoThrow(try check(Self.idpf, key: sha1(uuid), prefix: 1040), "IDPF")
        XCTAssertNoThrow(try check(Self.adobe, key: Array(stride(from: UInt8(0x00), through: UInt8(0xff), by: 0x11)), prefix: 1024), "Adobe")
    }

    func testTheIDPFKeyKeepsOtherSpaceCharactersOfTheIdentifier() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/82")
        // EPUB 3.3 §4.4.3 removes "specifically, the Unicode code points U+0020, U+0009, U+000D
        // and U+000A"; an ideographic or no-break space inside the identifier is part of the key.
        let identifier = "\u{66F8}\u{540D}\u{3000}\u{7B2C}\u{4E00}\u{5DFB}\u{A0}2"
        let original = font(1_100)
        let data = try book(identifier: identifier, fonts: ["OPS/font.otf": obfuscated(original, key: sha1(identifier), prefix: 1040)],
                            encryption: encryption([(Self.idpf, "OPS/font.otf")]))
        let decoded = try EPUBPublication.open(data: data).data(at: "OPS/font.otf")
        XCTAssertEqual(Array(decoded.prefix(8)), Array(original.prefix(8)), "the font's first bytes")
        XCTAssertEqual(decoded.suffix(60), original.suffix(60), "bytes after the obfuscated prefix are never changed")
    }

    func testAnAdobeKeyIsReadFromAnUpperCaseOrPaddedIdentifier() throws {
        let key = Array(stride(from: UInt8(0x00), through: UInt8(0xff), by: 0x11))
        let original = font(1_100)
        for identifier in ["urn:uuid:00112233-4455-6677-8899-AABBCCDDEEFF", "\n  urn:uuid:00112233-4455-6677-8899-aabbccddeeff\n  "] {
            let data = try book(identifier: identifier, fonts: ["OPS/font.otf": obfuscated(original, key: key, prefix: 1024)],
                                encryption: encryption([(Self.adobe, "OPS/font.otf")]))
            XCTAssertEqual(try EPUBPublication.open(data: data).data(at: "OPS/font.otf"), original, identifier)
        }
    }

    func testAKeyIsMadeFromTheIdentifierByItsOwnRuleNotFromItsMetadataValue() throws {
        // An identifier's metadata value has its ASCII whitespace stripped and collapsed and its
        // other white space kept (https://github.com/vocaro/EPUBLib/issues/75). A key is not made
        // from that value. IDPF's leaves out every space, tab and line end, where the value keeps
        // one for each run, and the zero-width space at either end, which the value keeps and
        // `Character` does not count as white space: made from the value, the key would hold
        // both. Adobe's is the UUID whatever white space surrounds it, a no-break space included,
        // which the value keeps. What a key reads at the identifier's ends is
        // https://github.com/vocaro/EPUBLib/issues/82's to settle, and is held here as it stands.
        let original = font(1_100)
        let spaced = try EPUBPublication.open(data: book(identifier: "\u{200B}\n    urn:isbn: 978 0\t00 000000\n 2\r\n  \u{200B}",
            fonts: ["OPS/font.otf": obfuscated(original, key: sha1("urn:isbn:9780000000002"), prefix: 1040)], encryption: encryption([(Self.idpf, "OPS/font.otf")])))
        XCTAssertEqual(spaced.metadata.identifiers.map { Array($0.unicodeScalars) }, [Array("\u{200B} urn:isbn: 978 0 00 000000 2 \u{200B}".unicodeScalars)])
        XCTAssertEqual(try spaced.data(at: "OPS/font.otf"), original)
        let key = Array(stride(from: UInt8(0x00), through: UInt8(0xff), by: 0x11))
        let padded = try EPUBPublication.open(data: book(identifier: " \u{A0}urn:uuid:00112233-4455-6677-8899-aabbccddeeff\u{3000}\n",
            fonts: ["OPS/font.otf": obfuscated(original, key: key, prefix: 1024)], encryption: encryption([(Self.adobe, "OPS/font.otf")])))
        XCTAssertEqual(padded.metadata.identifiers, ["\u{A0}urn:uuid:00112233-4455-6677-8899-aabbccddeeff\u{3000}"])
        XCTAssertEqual(try padded.data(at: "OPS/font.otf"), original)
    }

    func testAnAdobeKeyIsReadFromAUUIDWithoutHyphensOrInAnotherIdentifier() throws {
        let key = Array(stride(from: UInt8(0x00), through: UInt8(0xff), by: 0x11))
        let original = font(1_100)
        let scrambled = obfuscated(original, key: key, prefix: 1024)
        for identifier in ["00112233445566778899aabbccddeeff", "urn:uuid:00112233445566778899AABBCCDDEEFF", "00112233-4455-6677-8899-aabbccddeeff",
                           "URN:UUID:00112233-4455-6677-8899-aabbccddeeff", "urn:uuid:0011-2233-4455-6677-8899-aabb-ccdd-eeff"] {
            let data = try book(identifier: identifier, fonts: ["OPS/font.otf": scrambled], encryption: encryption([(Self.adobe, "OPS/font.otf")]))
            XCTAssertEqual(try EPUBPublication.open(data: data).data(at: "OPS/font.otf"), original, identifier)
        }
        // A unique identifier that is no UUID: the first identifier that is one gives the key.
        let uuid = "<dc:identifier>urn:uuid:00112233-4455-6677-8899-aabbccddeeff</dc:identifier>"
        let another = "<dc:identifier>urn:uuid:ffffffff-ffff-ffff-ffff-ffffffffffff</dc:identifier>"
        let files: [String: Data?] = ["META-INF/encryption.xml": encryption([(Self.adobe, "OPS/font.otf")]), "OPS/font.otf": scrambled]
        let later = try Fixture.packageVariant(opf: {
            $0.replacingOccurrences(of: ">test-book<", with: ">urn:isbn:9780000000002<")
                .replacingOccurrences(of: "</metadata>", with: "<dc:identifier>doi:10.0000/example</dc:identifier>" + uuid + another + "</metadata>")
        }, adding: files)
        XCTAssertEqual(try EPUBPublication.open(data: later).data(at: "OPS/font.otf"), original, "in a later identifier")
        // A unique identifier that is a UUID is the key, whatever stands before it.
        let earlier = try Fixture.packageVariant(opf: {
            $0.replacingOccurrences(of: "<dc:identifier id=\"uid\">test-book<", with: another + "<dc:identifier id=\"uid\">urn:uuid:00112233-4455-6677-8899-aabbccddeeff<")
        }, adding: files)
        XCTAssertEqual(try EPUBPublication.open(data: earlier).data(at: "OPS/font.otf"), original, "the unique identifier first")
    }

    func testAnObfuscatedFontWithoutAKeyIsLeftOutOfTheBook() throws {
        // Only a typeface is lost. The item is left out as one whose file the archive lacks is.
        let manifest = "<manifest><item id=\"font\" href=\"font.otf\" media-type=\"font/otf\"/><item id=\"plain\" href=\"plain.otf\" media-type=\"font/otf\"/>"
            + "<item id=\"embedded\" href=\"embedded.otf\" media-type=\"font/otf\"/>"
        let embedded = font(1_200)
        for identifier in ["test-book", "urn:isbn:9780000000002", "urn:uuid:00112233-4455-6677-8899-aabbccddeef", "00112233445566778899aabbccddeeff0",
                           "urn:uuid:0011223g-4455-6677-8899-aabbccddeeff", "urn:uuid:"] {
            let data = try Fixture.packageVariant(opf: {
                $0.replacingOccurrences(of: ">test-book<", with: ">\(identifier)<").replacingOccurrences(of: "<manifest>", with: manifest)
            }, adding: [
                "META-INF/encryption.xml": encryption([(Self.adobe, "OPS/font.otf"), (Self.idpf, "OPS/embedded.otf")]),
                "OPS/font.otf": font(1_100), "OPS/plain.otf": font(900),
                "OPS/embedded.otf": obfuscated(embedded, key: sha1(identifier), prefix: 1040),
            ])
            let book = try EPUBPublication.open(data: data)
            XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"], identifier)
            XCTAssertEqual(book.resources.filter { $0.mediaType == "font/otf" }.map(\.id), ["plain", "embedded"], identifier)
            XCTAssertThrowsError(try book.data(at: "OPS/font.otf"), identifier) {
                XCTAssertEqual($0 as? EPUBPublicationError, .missingResource("OPS/font.otf"), identifier)
            }
            XCTAssertEqual(try book.data(at: "OPS/plain.otf"), font(900), identifier)
            XCTAssertEqual(try book.data(at: "OPS/embedded.otf"), embedded, "a font under the other algorithm is still decoded: \(identifier)")
            XCTAssertEqual(book.archiveData, data, identifier)
        }
    }

    func testAFontWithoutAKeyIsOneByItsMediaTypeOrItsNameHoweverOftenItIsListed() throws {
        /// The plain book with one more manifest item, its file listed as obfuscated by `entries`.
        func book(href: String, type: String, entries: [String]) throws -> EPUBPublication {
            try EPUBPublication.open(data: Fixture.packageVariant(
                opf: { $0.replacingOccurrences(of: "<manifest>", with: "<manifest><item id=\"font\" href=\"\(href)\" media-type=\"\(type)\"/>") },
                adding: ["META-INF/encryption.xml": encryption(entries.map { ($0, "OPS/" + href) }), "OPS/" + href: font(1_100)]))
        }
        // By media type, in the spellings books give it, whatever the file is called.
        for type in ["font/otf", "font/woff2", "application/vnd.ms-opentype", "application/x-font-ttf", "application/font-sfnt",
                     "Application/X-Font-OpenType", "application/x-truetype-font", "application/vnd.ms-fontobject"] {
            let book = try book(href: "typeface.bin", type: type, entries: [Self.adobe])
            XCTAssertNil(book.resources.first { $0.id == "font" }, type)
            XCTAssertEqual(book.spine.count, 2, type)
        }
        // By name, when the manifest calls it something else.
        for name in ["serif.otf", "serif.TTF", "fonts/serif.woff2", "serif.woff", "serif.ttc", "serif.eot"] {
            let book = try book(href: name, type: "application/octet-stream", entries: [Self.adobe])
            XCTAssertNil(book.resources.first { $0.id == "font" }, name)
            XCTAssertThrowsError(try book.data(at: "OPS/" + name), name)
        }
        // Listed twice, or under both obfuscations, it is still one font left out.
        XCTAssertNil(try book(href: "serif.otf", type: "font/otf", entries: [Self.adobe, Self.adobe, Self.idpf]).resources.first { $0.id == "font" })
        // A font the manifest does not declare is one by its name.
        let undeclared = try EPUBPublication.open(data: Fixture.packageVariant(adding: [
            "META-INF/encryption.xml": encryption([(Self.adobe, "OPS/stray.otf")]), "OPS/stray.otf": font(1_100)]))
        XCTAssertThrowsError(try undeclared.data(at: "OPS/stray.otf"))
        XCTAssertEqual(undeclared.spine.count, 2)
        // Encryption of another kind on the same file is not undone by leaving the font out.
        for entries in [[Self.adobe, "http://www.w3.org/2001/04/xmlenc#aes256-cbc"], ["http://www.w3.org/2001/04/xmlenc#aes256-cbc", Self.adobe],
                        [Self.adobe, "urn:example:scramble"]] {
            XCTAssertThrowsError(try book(href: "serif.otf", type: "font/otf", entries: entries), "\(entries)") {
                XCTAssertEqual($0 as? EPUBPublicationError, .unsupportedEncryption, "\(entries)")
            }
        }
    }

    func testAnythingButAFontObfuscatedWithoutAKeyStillRefusesTheBook() throws {
        // A typeface can be done without. A chapter, the contents or a style sheet scrambled the
        // same way is encryption this package cannot undo, in the reading order or not.
        for path in ["OPS/one.xhtml", "OPS/nav.xhtml", "OPS/toc.ncx"] {
            assertOpening(try Fixture.packageVariant(adding: ["META-INF/encryption.xml": encryption([(Self.adobe, path)])]),
                          throws: .unsupportedEncryption, path)
        }
        for type in ["text/css", "image/png", "application/octet-stream"] {
            assertOpening(try Fixture.packageVariant(opf: { $0.replacingOccurrences(of: "<manifest>", with: "<manifest><item id=\"extra\" href=\"extra.bin\" media-type=\"\(type)\"/>") },
                                                     adding: ["META-INF/encryption.xml": encryption([(Self.adobe, "OPS/extra.bin")]), "OPS/extra.bin": font(600)]),
                          throws: .unsupportedEncryption, type)
        }
        // A file the manifest does not declare and nothing names as a font, the package's own among them.
        for path in ["OPS/stray.png", "OPS/book.opf", "META-INF/container.xml", "mimetype"] {
            assertOpening(try Fixture.packageVariant(adding: ["META-INF/encryption.xml": encryption([(Self.adobe, path)]), "OPS/stray.png": font(600)]),
                          throws: .unsupportedEncryption, path)
        }
        // One file declared as a font and as a chapter is the chapter too.
        assertOpening(try Fixture.packageVariant(opf: { $0.replacingOccurrences(of: "<manifest>", with: "<manifest><item id=\"font\" href=\"one.xhtml\" media-type=\"font/otf\"/>") },
                                                 adding: ["META-INF/encryption.xml": encryption([(Self.adobe, "OPS/one.xhtml")])]),
                      throws: .unsupportedEncryption, "declared twice")
        // The manifest names the chapter in another case: still the scrambled chapter, not a missing one.
        assertOpening(try Fixture.packageVariant(opf: { $0.replacingOccurrences(of: "href=\"one.xhtml\"", with: "href=\"ONE.xhtml\"") },
                                                 adding: ["META-INF/encryption.xml": encryption([(Self.adobe, "OPS/one.xhtml")])]),
                      throws: .unsupportedEncryption, "named in another case")
    }

    func testEncryptionThatCannotBeUndoneFailsAsUnsupported() throws {
        func entry(_ method: String, _ cipher: String) -> Data {
            Data(("<encryption xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" xmlns:enc=\"http://www.w3.org/2001/04/xmlenc#\">"
                + "<enc:EncryptedData>\(method)\(cipher)</enc:EncryptedData></encryption>").utf8)
        }
        let reference = "<enc:CipherData><enc:CipherReference URI=\"OPS/one.xhtml\"/></enc:CipherData>"
        let documents = [
            // A rights-managed chapter, as a store's DRM writes it.
            "AES": entry("<enc:EncryptionMethod Algorithm=\"http://www.w3.org/2001/04/xmlenc#aes256-cbc\"/>"
                + "<ds:KeyInfo xmlns:ds=\"http://www.w3.org/2000/09/xmldsig#\"><ds:RetrievalMethod URI=\"license.lcpl#/encryption/content_key\"/>"
                + "</ds:KeyInfo>", reference),
            "no method": entry("", reference),
            "no reference": entry("<enc:EncryptionMethod Algorithm=\"\(Self.idpf)\"/>", "<enc:CipherData/>"),
            "an algorithm of its own": entry("<enc:EncryptionMethod Algorithm=\"urn:example:scramble\"/>", reference),
        ]
        for (name, document) in documents {
            assertOpening(try Fixture.packageVariant(adding: ["META-INF/encryption.xml": document]), throws: .unsupportedEncryption, name)
        }
        // The IDPF key is the unique identifier, and cannot be derived from none.
        assertOpening(try book(identifier: "  ", fonts: ["OPS/font.otf": font(100)], encryption: encryption([(Self.idpf, "OPS/font.otf")])),
                      throws: .unsupportedEncryption, "IDPF without an identifier")
        assertOpening(try Fixture.packageVariant(adding: ["META-INF/encryption.xml": Data("<encryption><EncryptedData>".utf8)]),
                      throws: .invalidXML("META-INF/encryption.xml"))
    }
}
