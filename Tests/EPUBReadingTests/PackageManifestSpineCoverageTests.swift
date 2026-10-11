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

    func testAManifestHrefWithAFragmentNamesTheFileBeforeIt() throws {
        // OPF 2.0.1 §2.3 forbids the fragment; some packages carry one all the same.
        let book = try book(items: "<item id=\"part\" href=\"two.xhtml#second-half\" \(xhtml)/>",
                            spine: "<spine><itemref idref=\"one\"/><itemref idref=\"part\"/></spine>")
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
        XCTAssertEqual(book.spine[1].resource.href, "OPS/two.xhtml")
    }

    // A `Character` holds a "/", "\", ":" or "." together with a mark, selector or joiner after
    // it, so read that way "../" + U+0301 + "x.css" has no dot segment and no separator. An
    // archive and a file system read scalars (https://github.com/vocaro/EPUBLib/issues/181).
    func testAManifestHrefIsResolvedByScalarWhateverMarkFollowsItsSeparatorsAndDots() throws {
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
            // Refused as the same href is without the mark: it leaves the container, opens with a
            // slash, or holds a backslash or a colon.
            for href in ["../../\(m)x.css", "/\(m)x.css", "a\\\(m)x.css", "./a:\(m)x.css"] {
                assertOpening(try self.book(items: "<item id=\"x\" href=\"\(href)\" media-type=\"text/css\"/>"), throws: .unsafePath(href), href.debugDescription)
            }
        }
    }

    func testAResourcePathJoinedToAFolderNamesAFileInsideIt() throws {
        // doc/integration.md: "A host that writes a resource to disk may join its `path` to a
        // directory of its own." Here every separator and dot of the hrefs has a mark after it.
        var items = "", files: [String: Data?] = [:]
        for (index, m) in Fixture.clusteringMarks.enumerated() {
            for (kind, href) in ["../\(m)x\(index).css", "./\(m)x\(index).css", "a/../\(m)x\(index)/..\(m)", ".\(m)x\(index)/\(m)x", "b//\(m)x\(index)"].enumerated() {
                items += "<item id=\"i\(index)-\(kind)\" href=\"\(href)\" media-type=\"text/css\"/>"
                let path = try XCTUnwrap(ResourceReference.resolve(href, relativeTo: "OPS/book.opf").removingPercentEncoding)
                files[path] = Data(path.utf8)
            }
        }
        let book = try book(items: items, adding: files)
        XCTAssertEqual(book.resources.count, 4 + 5 * Fixture.clusteringMarks.count)
        let outer = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let folder = outer.appending(path: "book", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: outer) }
        for resource in book.resources {
            let bytes = Array(resource.path.utf8)
            XCTAssertTrue(!bytes.contains { $0 == 0x5C || $0 == 0x3A || $0 == 0 }
                && bytes.split(separator: 0x2F, omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != [0x2E] && $0 != [0x2E, 0x2E] },
                          resource.path.debugDescription)
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

    func testAManifestItemMissingARequiredAttributeRefusesThePackage() throws {
        for item in ["<item href=\"extra.css\" media-type=\"text/css\"/>", "<item id=\"\" href=\"extra.css\" media-type=\"text/css\"/>",
                     "<item id=\"extra\" media-type=\"text/css\"/>", "<item id=\"extra\" href=\"extra.css\"/>"] {
            assertOpening(try book(items: item, adding: ["OPS/extra.css": Data("a{}".utf8)]), throws: .invalidXML("Manifest item"), item)
        }
    }

    func testARemoteManifestItemRefusesThePackage() throws {
        // doc/architecture.md: "Remote manifest resources ... fail explicitly."
        for href in ["https://example.invalid/audio/chapter1.mp3", "http://example.invalid/font.woff2", "//example.invalid/video.mp4"] {
            assertOpening(try book(items: "<item id=\"remote\" href=\"\(href)\" media-type=\"audio/mpeg\"/>"), throws: .unsafePath(href))
        }
    }

    func testAPathAbsoluteManifestHrefStartsAtTheContainerRoot() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/84")
        // EPUB Reading Systems 3.3 §4.1.1: parsing "/" against the URL of the root directory gives
        // the root directory. W3C test ocf-url_link-path-absolute declares its picture this way.
        XCTAssertEqual(try book(items: "<item id=\"photo\" href=\"/media/photo.jpg\" media-type=\"image/jpeg\"/>",
                                adding: ["media/photo.jpg": Data([0xFF, 0xD8])]).resources.first { $0.id == "photo" }?.path, "media/photo.jpg")
    }

    func testDoubleDotSegmentsBeyondTheContainerRootStopAtTheRoot() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/84")
        // EPUB Reading Systems 3.3 §4.1.1: parsing "../" against the URL of the root directory gives
        // the root directory, so no reference leaves the container. W3C test
        // ocf-url_link-leaking-relative declares its picture four levels above a one-level package.
        XCTAssertEqual(try book(items: "<item id=\"photo\" href=\"../../../../media/photo.jpg\" media-type=\"image/jpeg\"/>",
                                adding: ["media/photo.jpg": Data([0xFF, 0xD8])]).resources.first { $0.id == "photo" }?.path, "media/photo.jpg")
    }

    func testIdsWithSurroundingSpacesMatchTheirReferences() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/80")
        // An id is an XML ID, read without the white space around it: EPUBCheck passes
        // attr-id-with-spaces-valid.opf, whose items are `id="  t001"` and itemrefs `idref="t001"`.
        XCTAssertEqual(try book(items: "<item id=\"  three\" href=\"three.xhtml\" \(xhtml)/><item id=\"four  \" href=\"four.xhtml\" \(xhtml)/>",
                                spine: "<spine><itemref idref=\"one\"/><itemref idref=\"three\"/><itemref idref=\"four\"/></spine>",
                                adding: ["OPS/three.xhtml": Data("<html/>".utf8), "OPS/four.xhtml": Data("<html/>".utf8)]).spine.map(\.resource.path),
                       ["OPS/one.xhtml", "OPS/three.xhtml", "OPS/four.xhtml"])
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
