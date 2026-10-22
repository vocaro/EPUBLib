import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// The package document's `manifest` and `spine`.
final class PackageManifestSpineCoverageTests: XCTestCase {
    private let xhtml = "media-type=\"application/xhtml+xml\""

    /// The plain book with items added to its manifest, its spine element replaced when given,
    /// and files added.
    private func book(items: String = "", spine: String? = nil, metadata: String = "", epub2: Bool = false,
                      adding: [String: Data?] = [:]) throws -> EPUBPublication {
        try EPUBPublication.open(data: Fixture.packageVariant(epub2: epub2, opf: { opf in
            var opf = opf.replacingOccurrences(of: "<manifest>", with: "<manifest>" + items)
                .replacingOccurrences(of: "</metadata>", with: metadata + "</metadata>")
            if let spine {
                let start = opf.range(of: "<spine")!.lowerBound, end = opf.range(of: "</spine>")!.upperBound
                opf.replaceSubrange(start..<end, with: spine)
            }
            return opf
        }, adding: adding))
    }

    private func assertOpening(_ book: @autoclosure () throws -> EPUBPublication, throws expected: EPUBPublicationError,
                               _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try book(), message, file: file, line: line) {
            XCTAssertEqual($0 as? EPUBPublicationError, expected, "\(message): \($0)", file: file, line: line)
        }
    }

    // MARK: Manifest hrefs

    func testManifestHrefsAreURLReferencesDecodedIntoArchivePaths() throws {
        let cases: [(href: String, path: String, encoded: String)] = [
            ("chapter%20one.xhtml", "OPS/chapter one.xhtml", "OPS/chapter%20one.xhtml"),
            ("chapter two.xhtml", "OPS/chapter two.xhtml", "OPS/chapter%20two.xhtml"),
            ("caf%C3%A9.xhtml", "OPS/caf\u{E9}.xhtml", "OPS/caf%C3%A9.xhtml"),
            ("na%c3%afve.xhtml", "OPS/na\u{EF}ve.xhtml", "OPS/na%C3%AFve.xhtml"),
            ("\u{65E5}\u{672C}\u{8A9E}.xhtml", "OPS/\u{65E5}\u{672C}\u{8A9E}.xhtml", "OPS/%E6%97%A5%E6%9C%AC%E8%AA%9E.xhtml"),
            ("a+b.xhtml", "OPS/a+b.xhtml", "OPS/a+b.xhtml"),
            ("100%25.xhtml", "OPS/100%.xhtml", "OPS/100%25.xhtml"),
            ("what%3F.xhtml", "OPS/what?.xhtml", "OPS/what%3F.xhtml"),
            ("%5Bdraft%5D.xhtml", "OPS/[draft].xhtml", "OPS/%5Bdraft%5D.xhtml"),
            ("text/./deep/../ch.xhtml", "OPS/text/ch.xhtml", "OPS/text/ch.xhtml"),
            ("../shared/common.css", "shared/common.css", "shared/common.css"),
            ("../OPS/back.xhtml", "OPS/back.xhtml", "OPS/back.xhtml"),
            ("Text/Section0001.xhtml", "OPS/Text/Section0001.xhtml", "OPS/Text/Section0001.xhtml"),
            ("styles/main.css?v=3", "OPS/styles/main.css", "OPS/styles/main.css"),
            ("/shared/root.css", "shared/root.css", "shared/root.css"),
            ("Chapter%201%3A%20Start.xhtml", "OPS/Chapter 1: Start.xhtml", "OPS/Chapter%201%3A%20Start.xhtml"),
        ]
        var items = "", files: [String: Data?] = [:]
        for (index, item) in cases.enumerated() {
            items += "<item id=\"i\(index)\" href=\"\(item.href)\" \(xhtml)/>"
            files[item.path] = Data("file \(index)".utf8)
        }
        let book = try book(items: items, adding: files)
        for (index, item) in cases.enumerated() {
            let resource = book.resources.first { $0.id == "i\(index)" }
            XCTAssertEqual(resource?.path, item.path, item.href)
            XCTAssertEqual(resource?.href, item.encoded, item.href)
            XCTAssertEqual(try resource.map(book.data(for:)), Data("file \(index)".utf8), item.href)
            XCTAssertEqual(resource?.href.removingPercentEncoding, item.path, item.href)
        }
    }

    func testAManifestHrefIsReadPastTheWhiteSpaceRoundIt() throws {
        // As URL parsing reads every reference (https://github.com/vocaro/EPUBLib/issues/76).
        // Written as an escape, a space is part of the name.
        let book = try book(items: "<item id=\"three\" href=\" three.xhtml \" \(xhtml)/><item id=\"four\" href=\"&#9;four.xhtml&#10;\" \(xhtml)/>"
                            + "<item id=\"five\" href=\"%20five.xhtml\" \(xhtml)/>",
                            spine: "<spine><itemref idref=\"one\"/><itemref idref=\"three\"/><itemref idref=\"four\"/><itemref idref=\"five\"/></spine>",
                            adding: ["OPS/three.xhtml": Data("<html/>".utf8), "OPS/four.xhtml": Data("<html/>".utf8), "OPS/ five.xhtml": Data("<html/>".utf8)])
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/three.xhtml", "OPS/four.xhtml", "OPS/ five.xhtml"])
        XCTAssertEqual(book.spine.map(\.resource.href), ["OPS/one.xhtml", "OPS/three.xhtml", "OPS/four.xhtml", "OPS/%20five.xhtml"])
    }

    func testAManifestHrefWithAFragmentNamesTheFileBeforeIt() throws {
        // OPF 2.0.1 §2.3 forbids the fragment; some packages carry one all the same.
        let book = try book(items: "<item id=\"part\" href=\"two.xhtml#second-half\" \(xhtml)/>",
                            spine: "<spine><itemref idref=\"one\"/><itemref idref=\"part\"/></spine>")
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
        XCTAssertEqual(book.spine[1].resource.href, "OPS/two.xhtml")
    }

    // A `Character` holds a "/", "\", ":" or "." together with a mark, selector or joiner after
    // it, so read that way "../" + U+0301 + "x.css" has no dot segment and no separator. An
    // archive and a file system read bytes (https://github.com/vocaro/EPUBLib/issues/181).
    func testAManifestHrefIsResolvedWhateverMarkFollowsItsSeparatorsAndDots() throws {
        for m in Fixture.clusteringMarks {
            let e = Fixture.escapingNonASCII(m)
            // Within the container: dot segments resolve and the name begins with the mark.
            let cases: [(href: String, path: String)] = [
                ("../\(m)x.css", "\(m)x.css"), ("./\(m)x.css", "OPS/\(m)x.css"), ("a/../\(m)x.css", "OPS/\(m)x.css"), ("a/\(m)x.css", "OPS/a/\(m)x.css"),
                ("a//\(m)x.css", "OPS/a/\(m)x.css"), ("..%2F\(e)y.css", "\(m)y.css"), ("\(e)z.css#\(m)top", "OPS/\(m)z.css"),
            ]
            var items = "", files: [String: Data?] = [:]
            for (index, item) in cases.enumerated() {
                items += "<item id=\"i\(index)\" href=\"\(item.href)\" media-type=\"text/css\"/>"
                files[item.path] = Data(item.path.utf8)
            }
            let book = try book(items: items, adding: files)
            for (index, item) in cases.enumerated() {
                let resource = try XCTUnwrap(book.resources.first { $0.id == "i\(index)" }, item.href.debugDescription)
                XCTAssertEqual(Array(resource.path.unicodeScalars), Array(item.path.unicodeScalars), item.href.debugDescription)
                XCTAssertEqual(resource.href, Fixture.escapingNonASCII(item.path), item.href.debugDescription)
                XCTAssertEqual(try book.data(for: resource), Data(item.path.utf8), item.href.debugDescription)
            }
            // Read as the same href is without the mark. One that climbs past the container root
            // or opens with a slash starts at the root (https://github.com/vocaro/EPUBLib/issues/84),
            // and a colon is a character of the name (https://github.com/vocaro/EPUBLib/issues/171).
            for (href, path) in [("../../\(m)x.css", "\(m)x.css"), ("/\(m)x.css", "\(m)x.css"), ("./a:\(m)x.css", "OPS/a:\(m)x.css")] {
                let book = try self.book(items: "<item id=\"x\" href=\"\(href)\" media-type=\"text/css\"/>", adding: [path: Data(path.utf8)])
                let resource = try XCTUnwrap(book.resources.first { $0.id == "x" }, href.debugDescription)
                XCTAssertEqual(Array(resource.path.unicodeScalars), Array(path.unicodeScalars), href.debugDescription)
                XCTAssertEqual(try book.data(for: resource), Data(path.utf8), href.debugDescription)
            }
            // A backslash names no file, and still refuses the book.
            let href = "a\\\(m)x.css"
            assertOpening(try self.book(items: "<item id=\"x\" href=\"\(href)\" media-type=\"text/css\"/>"), throws: .unsafePath(href), href.debugDescription)
        }
    }

    func testAResourcePathJoinedToAFolderNamesAFileInsideIt() throws {
        // doc/integration.md: "A host that writes a resource to disk may join its `path` to a
        // directory of its own." Here every separator, dot and colon of the hrefs has a mark
        // after it, and two of them start at or climb past the container root.
        var items = "", files: [String: Data?] = [:]
        let kinds = 8
        for (index, m) in Fixture.clusteringMarks.enumerated() {
            let hrefs = ["../\(m)x\(index).css", "./\(m)x\(index).css", "a/../\(m)x\(index)/..\(m)", ".\(m)x\(index)/\(m)x", "b//\(m)x\(index)",
                         "../../../\(m)y\(index)/..\(m)", "/\(m)z\(index).css", "./c:\(m)x\(index)"]
            XCTAssertEqual(hrefs.count, kinds)
            for (kind, href) in hrefs.enumerated() {
                items += "<item id=\"i\(index)-\(kind)\" href=\"\(href)\" media-type=\"text/css\"/>"
                let path = try XCTUnwrap(ResourceReference.resolve(href, relativeTo: "OPS/book.opf").removingPercentEncoding)
                files[path] = Data(path.utf8)
            }
        }
        let book = try book(items: items, adding: files)
        XCTAssertEqual(book.resources.count, 4 + kinds * Fixture.clusteringMarks.count)
        let outer = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let folder = outer.appending(path: "book", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: outer) }
        for resource in book.resources {
            let bytes = Array(resource.path.utf8)
            // No "." or ".." segment, no empty one and so no leading "/", no backslash and no NUL.
            // A path that fails is not written: it might name a file outside the folder.
            guard !bytes.contains(where: { $0 == 0x5C || $0 == 0 }),
                  bytes.split(separator: 0x2F, omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != [0x2E] && $0 != [0x2E, 0x2E] }) else {
                XCTFail(resource.path.debugDescription)
                continue
            }
            let file = folder.appending(path: resource.path, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try book.data(for: resource).write(to: file)
        }
        // Nothing lies beside the folder, and each file is where its path says, under it.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outer.path), ["book"])
        let written = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])).compactMap { $0 as? URL }
            .filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        XCTAssertEqual(written.count, book.resources.count)
        for resource in book.resources {
            XCTAssertEqual(try Data(contentsOf: folder.appending(path: resource.path, directoryHint: .notDirectory)), try book.data(for: resource),
                           resource.path.debugDescription)
        }
    }

    func testManifestAndContentsHrefsNameFilesInAnyScriptAndEitherNormalizationForm() throws {
        // A mark, selector or joiner inside a name belongs to it: an accent composed and
        // decomposed, emoji of several scalars, right-to-left and East Asian text, Hangul in
        // syllables and in jamo, an Indic conjunct and Thai.
        let names = ["caf\u{E9}", "nai\u{308}ve", "\u{1F469}\u{200D}\u{1F4BB}", "\u{1F44D}\u{1F3FD}", "\u{1F1EF}\u{1F1F5}", "1\u{FE0F}\u{20E3}",
                     "\u{627}\u{644}\u{643}\u{62A}\u{627}\u{628}", "\u{5E1}\u{5B5}\u{5E4}\u{5B6}\u{5E8}", "\u{65E5}\u{672C}\u{8A9E}", "\u{304B}\u{3099}",
                     "\u{D55C}\u{AE00}", "\u{1112}\u{1161}\u{11AB}", "\u{915}\u{94D}\u{937}", "\u{E19}\u{E49}\u{E33}"]
        var items = "", links = "", files: [String: Data?] = [:]
        for (index, name) in names.enumerated() {
            let path = "OPS/\(name)/\(name).xhtml", written = "\(name)/\(name).xhtml"
            // Written out in one item and escaped in the next.
            items += "<item id=\"n\(index)\" href=\"\(index % 2 == 0 ? written : Fixture.escapingNonASCII(written))\" \(xhtml)/>"
            links += "<li><a href=\"./\(name)/x/../\(name).xhtml#\(name)\">\(index)</a></li>"
            files[path] = Data(path.utf8)
        }
        let book = try EPUBPublication.open(data: Fixture.packageVariant(
            opf: { $0.replacingOccurrences(of: "<manifest>", with: "<manifest>" + items) },
            nav: { _ in Fixture.navigationDocument("<nav epub:type=\"toc\"><ol>\(links)</ol></nav>") }, adding: files))
        XCTAssertEqual(book.tableOfContents.count, names.count)
        for (index, name) in names.enumerated() {
            let path = "OPS/\(name)/\(name).xhtml", e = Fixture.escapingNonASCII(name)
            let resource = try XCTUnwrap(book.resources.first { $0.id == "n\(index)" }, name)
            XCTAssertEqual(Array(resource.path.unicodeScalars), Array(path.unicodeScalars), name)
            XCTAssertEqual(resource.href, "OPS/\(e)/\(e).xhtml", name)
            XCTAssertEqual(try book.data(for: resource), Data(path.utf8), name)
            XCTAssertEqual(try book.data(at: path), Data(path.utf8), name)
            XCTAssertEqual(book.tableOfContents[index].href, "OPS/\(e)/\(e).xhtml#\(e)", name)
        }
    }

    func testOneFileUnderTwoManifestIdsIsTwoResources() throws {
        let book = try book(items: "<item id=\"again\" href=\"./one.xhtml\" \(xhtml)/>",
                            spine: "<spine><itemref idref=\"again\"/><itemref idref=\"two\"/><itemref idref=\"one\"/></spine>")
        XCTAssertEqual(book.resources.filter { $0.path == "OPS/one.xhtml" }.map(\.id), ["again", "one"])
        XCTAssertEqual(book.spine.map(\.resource.id), ["again", "two", "one"])
        XCTAssertEqual(try book.data(for: book.spine[0].resource), try book.data(for: book.spine[2].resource))
    }

    /// IDs and the IDREFs that name them compare code unit for code unit, as XML compares them:
    /// `caf&#xE9;` and `cafe&#x301;` are two items, though `String` compares them equal. The
    /// spine, a fallback and the EPUB 2 cover each name the item with their own code units.
    func testCanonicallyEquivalentIdsAreTwoItems() throws {
        let book = try book(items: "<item id=\"caf&#xE9;\" href=\"three.xhtml\" \(xhtml)/>"
            + "<item id=\"cafe&#x301;\" href=\"four.xhtml\" \(xhtml) fallback=\"caf&#xE9;\"/>"
            + "<item id=\"na&#xEF;ve\" href=\"a.png\" media-type=\"image/png\"/><item id=\"nai&#x308;ve\" href=\"b.png\" media-type=\"image/png\"/>",
            spine: "<spine><itemref idref=\"cafe&#x301;\"/><itemref idref=\"caf&#xE9;\"/></spine>",
            metadata: "<meta name=\"cover\" content=\"nai&#x308;ve\"/>",
            adding: ["OPS/three.xhtml": Data("<html/>".utf8), "OPS/four.xhtml": Data("<html/>".utf8),
                     "OPS/a.png": Data([0]), "OPS/b.png": Data([1])])
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/four.xhtml", "OPS/three.xhtml"])
        XCTAssertEqual(book.fallbackChain(for: book.spine[0].resource).map(\.path), ["OPS/four.xhtml", "OPS/three.xhtml"])
        XCTAssertEqual(book.cover?.path, "OPS/b.png")
    }

    func testAManifestItemMissingARequiredAttributeRefusesThePackage() throws {
        for item in ["<item href=\"extra.css\" media-type=\"text/css\"/>", "<item id=\"\" href=\"extra.css\" media-type=\"text/css\"/>",
                     "<item id=\"extra\" media-type=\"text/css\"/>", "<item id=\"extra\" href=\"extra.css\"/>"] {
            assertOpening(try book(items: item, adding: ["OPS/extra.css": Data("a{}".utf8)]), throws: .invalidXML("Manifest item"), item)
        }
    }

    func testARemoteManifestItemIsLeftOutAndNothingIsFetched() throws {
        // EPUB 3.3 §3.6 lets audio, video and fonts live outside the container. The item is left
        // out as one whose file the archive lacks is: doc/architecture.md, Publication model.
        let plain = try book()
        for href in ["https://example.invalid/audio/chapter1.mp3", "http://example.invalid/font.woff2", "//example.invalid/video.mp4",
                     "data:audio/mpeg;base64,AAAA"] {
            let book = try book(items: "<item id=\"remote\" href=\"\(href)\" media-type=\"audio/mpeg\" properties=\"cover-image\"/>")
            XCTAssertEqual(book.resources, plain.resources, href)
            XCTAssertEqual(book.spine, plain.spine, href)
            XCTAssertNil(book.cover, href)
        }
    }

    func testASpineThatNamesARemoteItemRefusesThePackage() throws {
        // A reading order cannot be fetched either, and without its document there is no book.
        for href in ["https://example.invalid/chapter3.xhtml", "//example.invalid/chapter3.xhtml"] {
            assertOpening(try book(items: "<item id=\"remote\" href=\"\(href)\" \(xhtml)/>",
                                   spine: "<spine><itemref idref=\"one\"/><itemref idref=\"remote\"/></spine>"), throws: .unsafePath(href), href)
        }
    }

    func testARemoteItemRepeatedVerbatimCountsOnceAndAConflictingOneIsRefused() throws {
        let item = "<item id=\"remote\" href=\"https://example.invalid/a.mp3\" media-type=\"audio/mpeg\"/>"
        XCTAssertEqual(try book(items: item + item).resources, try book().resources)
        assertOpening(try book(items: item + "<item id=\"remote\" href=\"one.xhtml\" \(xhtml)/>"), throws: .invalidXML("Manifest item"))
        assertOpening(try book(items: item + "<item id=\"remote\" href=\"https://example.invalid/b.mp3\" media-type=\"audio/mpeg\"/>"),
                      throws: .invalidXML("Manifest item"))
    }

    func testARemoteItemAndALocalOneUnderOneIdAreTwoResources() throws {
        // `x:y` is remote and `../x%3Ay` the file `x:y` in the container root: the same spelling
        // once decoded, and not a verbatim repeat.
        let items = "<item id=\"both\" href=\"x:y\" media-type=\"text/css\"/><item id=\"both\" href=\"../x%3Ay\" media-type=\"text/css\"/>"
        assertOpening(try book(items: items, adding: ["x:y": Data("a{}".utf8)]), throws: .invalidXML("Manifest item"))
    }

    func testAManifestHrefAURLParserGivesUpOnIsRemoteAllTheSame() throws {
        let plain = try book()
        for href in ["http://host:port/a.mp3", " https://example.invalid/a.mp3", "http://exa mple.invalid/a.mp3"] {
            XCTAssertEqual(try book(items: "<item id=\"remote\" href=\"\(href)\" media-type=\"audio/mpeg\"/>").resources, plain.resources, href)
            assertOpening(try book(items: "<item id=\"remote\" href=\"\(href)\" \(xhtml)/>",
                                   spine: "<spine><itemref idref=\"one\"/><itemref idref=\"remote\"/></spine>"), throws: .unsafePath(href), href)
        }
    }

    func testAnHrefWithABareColonIsRemoteWhateverTheArchiveHolds() throws {
        // `a:b.xhtml` is a URL with the scheme `a`. Only `%3A` or a leading `./` names such a file.
        let files: [String: Data?] = ["OPS/a:b.xhtml": Data("<html/>".utf8)]
        XCTAssertNil(try book(items: "<item id=\"colon\" href=\"a:b.xhtml\" \(xhtml)/>", adding: files).resources.first { $0.id == "colon" })
        for href in ["a%3Ab.xhtml", "./a:b.xhtml"] {
            let resource = try XCTUnwrap(try book(items: "<item id=\"colon\" href=\"\(href)\" \(xhtml)/>", adding: files).resources.first { $0.id == "colon" }, href)
            XCTAssertEqual(resource.path, "OPS/a:b.xhtml", href)
            XCTAssertEqual(resource.href, "OPS/a%3Ab.xhtml", href)
        }
    }

    func testAManifestHrefDifferingOnlyInCaseNamesTheOneEntryThatMatches() throws {
        // A file system that ignores case hides the mismatch from the book's author.
        let chapter = Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Third.</p></body></html>".utf8)
        let spine = "<spine><itemref idref=\"one\"/><itemref idref=\"three\"/></spine>"
        let item = "<item id=\"three\" href=\"Text/Chapter3.XHTML\" \(xhtml)/>"
        let matched = try book(items: item, spine: spine, adding: ["OPS/text/chapter3.xhtml": chapter])
        XCTAssertEqual(matched.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/text/chapter3.xhtml"], "the entry's own spelling")
        XCTAssertEqual(try matched.data(for: matched.spine[1].resource), chapter)
        XCTAssertEqual(matched.spine[1].resource.href, "OPS/text/chapter3.xhtml")

        // An exact match is never second-guessed.
        let exact = try book(items: item, spine: spine, adding: ["OPS/text/chapter3.xhtml": Data("other".utf8), "OPS/Text/Chapter3.XHTML": chapter])
        XCTAssertEqual(exact.spine[1].resource.path, "OPS/Text/Chapter3.XHTML")
        XCTAssertEqual(try exact.data(for: exact.spine[1].resource), chapter)

        // Between two entries that differ only in case there is nothing to choose by.
        let two: [String: Data?] = ["OPS/text/chapter3.xhtml": chapter, "OPS/TEXT/CHAPTER3.xhtml": chapter]
        assertOpening(try book(items: item, spine: spine, adding: two), throws: .missingResource("OPS/Text/Chapter3.XHTML"), "two candidates, in the spine")
        XCTAssertNil(try book(items: item, adding: two).resources.first { $0.id == "three" }, "two candidates, outside the spine")
        assertOpening(try book(items: item, spine: spine), throws: .missingResource("OPS/Text/Chapter3.XHTML"), "no candidate")
    }

    func testAPathAbsoluteManifestHrefStartsAtTheContainerRoot() throws {
        // EPUB Reading Systems 3.3 §4.1.1: parsing "/" against the URL of the root directory gives
        // the root directory. W3C test ocf-url_link-path-absolute declares its picture this way.
        XCTAssertEqual(try book(items: "<item id=\"photo\" href=\"/media/photo.jpg\" media-type=\"image/jpeg\"/>",
                                adding: ["media/photo.jpg": Data([0xFF, 0xD8])]).resources.first { $0.id == "photo" }?.path, "media/photo.jpg")
    }

    func testDoubleDotSegmentsBeyondTheContainerRootStopAtTheRoot() throws {
        // EPUB Reading Systems 3.3 §4.1.1: parsing "../" against the URL of the root directory gives
        // the root directory, so no reference leaves the container. W3C test
        // ocf-url_link-leaking-relative declares its picture four levels above a one-level package.
        XCTAssertEqual(try book(items: "<item id=\"photo\" href=\"../../../../media/photo.jpg\" media-type=\"image/jpeg\"/>",
                                adding: ["media/photo.jpg": Data([0xFF, 0xD8])]).resources.first { $0.id == "photo" }?.path, "media/photo.jpg")
    }

    func testIdsWithSurroundingSpacesMatchTheirReferences() throws {
        // An id is an XML ID, read without the white space around it: EPUBCheck passes
        // attr-id-with-spaces-valid.opf, whose items are `id="  t001"` and itemrefs `idref="t001"`.
        XCTAssertEqual(try book(items: "<item id=\"  three\" href=\"three.xhtml\" \(xhtml)/><item id=\"four  \" href=\"four.xhtml\" \(xhtml)/>",
                                spine: "<spine><itemref idref=\"one\"/><itemref idref=\"three\"/><itemref idref=\"four\"/></spine>",
                                adding: ["OPS/three.xhtml": Data("<html/>".utf8), "OPS/four.xhtml": Data("<html/>".utf8)]).spine.map(\.resource.path),
                       ["OPS/one.xhtml", "OPS/three.xhtml", "OPS/four.xhtml"])
    }

    /// Every other reference to an item reads its id, and its own value, as the spine does: a
    /// fallback, the spine's `toc` and the EPUB 2 cover. This `toc` names the second of two NCX
    /// items; the first would stand in for one that named none.
    func testAFallbackTheNCXAndTheCoverNameTheirItemWhateverWhiteSpaceSurroundsEither() throws {
        let other = "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><navMap><navPoint id=\"x\" playOrder=\"1\">"
            + "<navLabel><text>Another</text></navLabel><content src=\"one.xhtml\"/></navPoint></navMap></ncx>"
        let book = try book(items: "<item id=\"other\" href=\"other.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
            + "<item id=\" three\t\" href=\"three.xhtml\" \(xhtml) fallback=\"&#9;four \"/><item id=\"four\" href=\"four.xhtml\" \(xhtml)/>"
            + "<item id=\"\n art \" href=\"art.png\" media-type=\"image/png\"/>",
            spine: "<spine toc=\" ncx\n\"><itemref idref=\"three \"/><itemref idref=\"one\"/></spine>",
            metadata: "<meta name=\"cover\" content=\" art\"/>", epub2: true,
            adding: ["OPS/other.ncx": Data(other.utf8), "OPS/three.xhtml": Data("<html/>".utf8), "OPS/four.xhtml": Data("<html/>".utf8),
                     "OPS/art.png": Data([0])])
        XCTAssertEqual(book.spine.map(\.resource.id), ["three", "one"])
        XCTAssertEqual(book.spine[0].resource.fallbackID, "four")
        XCTAssertEqual(book.fallbackChain(for: book.spine[0].resource).map(\.path), ["OPS/three.xhtml", "OPS/four.xhtml"])
        XCTAssertEqual(book.tableOfContents.map(\.title), ["First Chapter"])
        XCTAssertEqual(book.cover?.path, "OPS/art.png")
    }

    /// An id is one ID however much XML white space surrounds it, so an item that differs from
    /// another only by that repeats it, verbatim or in conflict, and an id of nothing else is
    /// empty. Within it a run of that white space is one space, as XML Schema collapses an
    /// `xsd:ID`. Other white space, a no-break space among it, is part of the id.
    func testAnIdIsOneIdWhateverXMLWhiteSpaceSurroundsIt() throws {
        let three: [String: Data?] = ["OPS/three.xhtml": Data("<html/>".utf8)]
        XCTAssertEqual(try book(items: "<item id=\" one \" href=\"one.xhtml\" \(xhtml)/>").resources, try book().resources)
        assertOpening(try book(items: "<item id=\"one&#9;\" href=\"two.xhtml\" \(xhtml)/>"), throws: .invalidXML("Manifest item"), "a conflict")
        assertOpening(try book(items: "<item id=\" &#9;&#10;&#13; \" href=\"extra.css\" media-type=\"text/css\"/>", adding: ["OPS/extra.css": Data("a{}".utf8)]),
                      throws: .invalidXML("Manifest item"), "white space alone")
        XCTAssertEqual(try book(items: "<item id=\"three &#9;\n four\" href=\"three.xhtml\" \(xhtml)/>",
                                spine: "<spine><itemref idref=\"three four\"/></spine>", adding: three).spine.map(\.resource.id), ["three four"])
        for space in ["&#xA0;", "\u{A0}", "\u{3000}", "&#x200B;"] {
            assertOpening(try book(items: "<item id=\"\(space)three\" href=\"three.xhtml\" \(xhtml)/>",
                                   spine: "<spine><itemref idref=\"three\"/></spine>", adding: three), throws: .invalidXML("Spine idref"), space)
        }
    }

    func testPropertiesAreSeparatedByAnyWhiteSpace() throws {
        let book = try book(items: "<item id=\"rich\" href=\"rich.xhtml\" \(xhtml) properties=\"  scripted\n\tmathml   svg remote-resources \"/>"
            + "<item id=\"bare\" href=\"bare.xhtml\" \(xhtml) properties=\"\"/>",
            spine: "<spine><itemref idref=\"rich\" properties=\"page-spread-left\n rendition:layout-pre-paginated\"/><itemref idref=\"bare\"/></spine>",
            adding: ["OPS/rich.xhtml": Data("<html/>".utf8), "OPS/bare.xhtml": Data("<html/>".utf8)])
        XCTAssertEqual(book.resources.first { $0.id == "rich" }?.properties, ["scripted", "mathml", "svg", "remote-resources"])
        XCTAssertEqual(book.resources.first { $0.id == "bare" }?.properties, [])
        XCTAssertEqual(book.resources.first { $0.id == "one" }?.properties, [], "no attribute")
        XCTAssertEqual(book.spine.map(\.layout), [.prePaginated, .reflowable])
    }

    // MARK: Spine

    func testLinearNoMarksAuxiliaryContentAndTheSpineKeepsItsOrder() throws {
        let book = try book(spine: "<spine><itemref idref=\"two\" linear=\"no\"/><itemref idref=\"one\" linear=\"yes\"/>"
            + "<itemref idref=\"nav\"/><itemref idref=\"two\" id=\"again\"/></spine>")
        XCTAssertEqual(book.spine.map(\.resource.id), ["two", "one", "nav", "two"])
        XCTAssertEqual(book.spine.map(\.isLinear), [false, true, true, true])
        XCTAssertEqual(book.spine[0].resource, book.spine[3].resource, "one item may be read twice")
    }

    func testASpineItemOverridesTheLayoutOfThePublicationEitherWay() throws {
        func layouts(_ meta: String) throws -> [EPUBLayout] {
            try book(spine: "<spine><itemref idref=\"one\"/><itemref idref=\"two\" properties=\"rendition:layout-reflowable\"/>"
                + "<itemref idref=\"nav\" properties=\"page-spread-right rendition:layout-pre-paginated\"/></spine>", metadata: meta).spine.map(\.layout)
        }
        XCTAssertEqual(try layouts("<meta property=\"rendition:layout\">pre-paginated</meta>"), [.prePaginated, .reflowable, .prePaginated])
        XCTAssertEqual(try layouts("<meta property=\"rendition:layout\">\n  pre-paginated\n</meta>"), [.prePaginated, .reflowable, .prePaginated])
        XCTAssertEqual(try layouts("<meta property=\"rendition:layout\">reflowable</meta>"), [.reflowable, .reflowable, .prePaginated])
        XCTAssertEqual(try layouts(""), [.reflowable, .reflowable, .prePaginated])
        XCTAssertEqual(try layouts("<meta property=\"rendition:orientation\">landscape</meta><meta property=\"rendition:spread\">both</meta>"),
                       [.reflowable, .reflowable, .prePaginated], "other rendition metadata")
    }

    func testPageProgressionDirectionIsReadAndAnythingUnknownIsTheDefault() throws {
        // EPUB Reading Systems 3.3 §5.5: without a value a reader "MUST assume the value of default".
        func progression(_ attribute: String) throws -> EPUBPageProgression {
            try book(spine: "<spine \(attribute)><itemref idref=\"one\"/></spine>").pageProgression
        }
        XCTAssertEqual(try progression("page-progression-direction=\"rtl\""), .rtl)
        XCTAssertEqual(try progression("page-progression-direction=\"ltr\""), .ltr)
        XCTAssertEqual(try progression("page-progression-direction=\"default\""), .default)
        XCTAssertEqual(try progression(""), .default)
        XCTAssertEqual(try progression("toc=\"ncx\" page-progression-direction=\"rtl\" id=\"s\""), .rtl)
        XCTAssertEqual(try progression("page-progression-direction=\"sideways\""), .default)
        XCTAssertEqual(try progression("page-progression-direction=\"\""), .default)
    }

    func testASpineThatCannotBeResolvedRefusesThePackage() throws {
        assertOpening(try book(spine: "<spine/>"), throws: .invalidXML("Empty spine"))
        assertOpening(try book(spine: "<spine><!-- nothing yet --></spine>"), throws: .invalidXML("Empty spine"))
        assertOpening(try book(spine: ""), throws: .invalidXML("OPF package, manifest or spine"), "no spine")
        assertOpening(try book(spine: "<spine><itemref idref=\"one\"/><itemref idref=\"absent\"/></spine>"), throws: .invalidXML("Spine idref"))
        assertOpening(try book(spine: "<spine><itemref/></spine>"), throws: .invalidXML("Spine idref"), "no idref")
        assertOpening(try book(spine: "<spine><itemref idref=\"ONE\"/></spine>"), throws: .invalidXML("Spine idref"), "ids are case-sensitive")
        assertOpening(try EPUBPublication.open(data: Fixture.packageVariant(opf: {
            $0.replacingOccurrences(of: "<manifest>", with: "<resources>").replacingOccurrences(of: "</manifest>", with: "</resources>")
        })), throws: .invalidXML("OPF package, manifest or spine"), "no manifest")
        assertOpening(try EPUBPublication.open(data: Fixture.packageVariant(opf: {
            $0.replacingOccurrences(of: "<package ", with: "<opf ").replacingOccurrences(of: "</package>", with: "</opf>")
        })), throws: .invalidXML("OPF package, manifest or spine"), "another root element")
    }
}
