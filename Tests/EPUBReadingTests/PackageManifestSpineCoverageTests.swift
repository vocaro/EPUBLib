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

    func testAManifestHrefWithAFragmentNamesTheFileBeforeIt() throws {
        // OPF 2.0.1 §2.3 forbids the fragment; some packages carry one all the same.
        let book = try book(items: "<item id=\"part\" href=\"two.xhtml#second-half\" \(xhtml)/>",
                            spine: "<spine><itemref idref=\"one\"/><itemref idref=\"part\"/></spine>")
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
        XCTAssertEqual(book.spine[1].resource.href, "OPS/two.xhtml")
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
