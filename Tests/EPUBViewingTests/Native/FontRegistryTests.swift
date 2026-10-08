import CoreText
import EPUBReading
@testable import EPUBViewing
import Synchronization
import XCTest

final class FontRegistryTests: XCTestCase {
    private func fontFile(_ postScriptName: String) throws -> Data {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        guard CTFontCopyPostScriptName(font) as String == postScriptName,
              let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
              let data = try? Data(contentsOf: url) else { throw XCTSkip("\(postScriptName) is not installed") }
        return data
    }

    private func registry(files: [String: Data] = [:]) throws -> FontRegistry {
        let section = StyleTestSupport.xhtml(body: "<p>x</p>")
        return FontRegistry(publication: try StyleTestSupport.publication(section: section, files: files))
    }

    private func style(_ families: [String], size: CGFloat = 17, weight: Int = 400, italic: Bool = false,
                       smallCaps: Bool = false) -> ComputedStyle {
        Self.style(families, size: size, weight: weight, italic: italic, smallCaps: smallCaps)
    }

    private static func style(_ families: [String], size: CGFloat, weight: Int, italic: Bool, smallCaps: Bool) -> ComputedStyle {
        var style = ComputedStyle()
        style.fontFamilies = families; style.fontSize = size; style.fontWeight = weight
        style.isItalic = italic; style.isSmallCaps = smallCaps
        return style
    }

    private func family(_ font: PlatformFont) -> String { CTFontCopyFamilyName(font as CTFont) as String }
    private func traits(_ font: PlatformFont) -> CTFontSymbolicTraits { CTFontGetSymbolicTraits(font as CTFont) }

    func testGenericFamiliesUseSystemDesigns() throws {
        let fonts = try registry()
        let serif = fonts.font(for: style(["serif"]))
        XCTAssertTrue(serif.fontName.contains("NewYork"), serif.fontName)
        XCTAssertEqual(serif.pointSize, 17)
        XCTAssertEqual(family(fonts.font(for: style(["sans-serif"]))), family(PlatformFont.systemFont(ofSize: 17)))
        XCTAssertEqual(family(fonts.font(for: style(["system-ui"]))), family(PlatformFont.systemFont(ofSize: 17)))
        XCTAssertTrue(traits(fonts.font(for: style(["monospace"]))).contains(.traitMonoSpace))
        XCTAssertTrue(fonts.font(for: style(["cursive"])).fontName.contains("NewYork"))
        XCTAssertTrue(fonts.font(for: style(["no such family"])).fontName.contains("NewYork"), "The reader default is serif")
        XCTAssertTrue(traits(fonts.font(for: style(["no such family", "monospace"]))).contains(.traitMonoSpace))
        XCTAssertTrue(traits(fonts.font(for: style(["consolas"]))).contains(.traitMonoSpace), "Common uninstalled families map to their generic")
        let boldItalic = fonts.font(for: style(["serif"], weight: 700, italic: true))
        XCTAssertTrue(traits(boldItalic).contains(.traitItalic))
        XCTAssertTrue(traits(boldItalic).contains(.traitBold))
        XCTAssertFalse(fonts.needsSyntheticItalic(for: style(["serif"], italic: true)))
    }

    func testInstalledFamiliesByName() throws {
        let fonts = try registry()
        let georgia = fonts.font(for: style(["georgia", "serif"]))
        guard family(georgia) == "Georgia" else { throw XCTSkip("Georgia is not installed") }
        XCTAssertEqual(fonts.font(for: style(["georgia"], weight: 700)).fontName, "Georgia-Bold")
        XCTAssertEqual(fonts.font(for: style(["georgia"], weight: 300, italic: true)).fontName, "Georgia-Italic")
        XCTAssertEqual(fonts.font(for: style(["georgia"], weight: 900, italic: true)).fontName, "Georgia-BoldItalic")
        XCTAssertFalse(fonts.needsSyntheticItalic(for: style(["georgia"], italic: true)))
        XCTAssertEqual(family(fonts.font(for: style([".hidden system face", "georgia"]))), "Georgia")
    }

    func testEmbeddedFacesMatchByWeightAndStyle() throws {
        let files = ["fonts/light.ttf": try fontFile("TimesNewRomanPSMT"), "fonts/regular.ttf": try fontFile("Georgia"),
                     "fonts/bold.ttf": try fontFile("Georgia-Bold"), "fonts/garbage.ttf": Data(repeating: 7, count: 512)]
        let fonts = try registry(files: files)
        var report = SectionReport()
        fonts.register([
            CSSFontFace(family: "book face", weights: 300...300, sources: ["OPS/fonts/light.ttf"]),
            CSSFontFace(family: "book face", sources: ["OPS/fonts/missing.ttf", "OPS/fonts/regular.ttf"]),
            CSSFontFace(family: "book face", weights: 700...700, sources: ["OPS/fonts/bold.ttf"]),
            CSSFontFace(family: "broken", sources: ["OPS/fonts/garbage.ttf"]),
        ], report: &report)
        fonts.register([CSSFontFace(family: "book face", sources: ["OPS/fonts/regular.ttf"])], report: &report)
        XCTAssertEqual(report.unreadableResources, 1, "Only a face with no loadable source is reported")
        func name(_ weight: Int, italic: Bool = false) -> String {
            fonts.font(for: style(["book face", "monospace"], weight: weight, italic: italic)).fontName
        }
        XCTAssertEqual(name(400), "Georgia")
        XCTAssertEqual(name(300), "TimesNewRomanPSMT")
        XCTAssertEqual(name(350), "TimesNewRomanPSMT", "Below 400, lighter faces come first")
        XCTAssertEqual(name(450), "Georgia", "Between 400 and 500, a lighter face beats one above 500")
        XCTAssertEqual(name(500), "Georgia")
        XCTAssertEqual(name(600), "Georgia-Bold", "Above 500, heavier faces come first")
        XCTAssertEqual(name(900), "Georgia-Bold")
        XCTAssertEqual(name(100), "TimesNewRomanPSMT")
        XCTAssertEqual(name(400, italic: true), "Georgia", "A family without italics is used upright…")
        XCTAssertTrue(fonts.needsSyntheticItalic(for: style(["book face"], italic: true)), "…and slanted by the builder")
        XCTAssertFalse(fonts.needsSyntheticItalic(for: style(["book face"])))
        XCTAssertTrue(traits(fonts.font(for: style(["broken", "monospace"]))).contains(.traitMonoSpace))
        XCTAssertEqual(fonts.font(for: style(["book face"], size: 31)).pointSize, 31)
    }

    func testFontFacesLoadFromStylesheets() throws {
        let section = StyleTestSupport.xhtml(body: #"<p id="p">x</p>"#, head: #"<link rel="stylesheet" href="css/book.css"/>"#)
        let css = """
            @font-face { font-family: "Text Face"; font-style: italic; font-weight: 300 500; src: url("../fonts/text.ttf") format("truetype") }
            @font-face { font-family: Remote; src: url(http://example.com/a.woff) }
            p { font-family: "Text Face", serif; font-style: italic }
            """
        let book = try StyleTestSupport.publication(section: section, files: ["css/book.css": Data(css.utf8),
                                                                              "fonts/text.ttf": try fontFile("Georgia-Italic")])
        let fonts = FontRegistry(publication: book)
        let document = try ContentDocument.parse(Data(section.utf8), path: "OPS/one.xhtml")
        var report = SectionReport()
        let sheets = SectionStyles.load(for: document, publication: book, fonts: fonts, report: &report)
        XCTAssertEqual(sheets[0].fontFaces, [CSSFontFace(family: "text face", weights: 300...500, isItalic: true, sources: ["OPS/fonts/text.ttf"])])
        XCTAssertEqual(report.remoteResourcesRefused, 1)
        let resolver = StyleResolver(document: document, stylesheets: sheets, typography: NativeTypography())
        let styles = StyleTestSupport.styleAll(document, resolver)
        let paragraph = styles[document.element(id: "p")!.order]!
        XCTAssertEqual(fonts.font(for: paragraph).fontName, "Georgia-Italic")
        XCTAssertFalse(fonts.needsSyntheticItalic(for: paragraph))
    }

    func testSmallCapsUseTheFontFeature() throws {
        let fonts = try registry()
        let font = fonts.font(for: style(["serif"], smallCaps: true)) as CTFont
        let settings = CTFontCopyFeatureSettings(font) as? [[CFString: Any]] ?? []
        XCTAssertTrue(settings.contains {
            $0[kCTFontFeatureTypeIdentifierKey] as? Int == kLowerCaseType
                && $0[kCTFontFeatureSelectorIdentifierKey] as? Int == kLowerCaseSmallCapsSelector
        })
        XCTAssertFalse(fonts.needsSyntheticSmallCaps(for: style(["serif"], smallCaps: true)))
        XCTAssertFalse(fonts.needsSyntheticSmallCaps(for: style(["serif"])))
        if family(fonts.font(for: style(["georgia"]))) == "Georgia" {
            XCTAssertTrue(fonts.needsSyntheticSmallCaps(for: style(["georgia"], smallCaps: true)), "Georgia has no small caps")
        }
    }

    func testFontDataIsSniffed() {
        XCTAssertTrue(FontRegistry.isFontData(Data([0, 1, 0, 0] + Array(repeating: 0, count: 12))))
        XCTAssertTrue(FontRegistry.isFontData(Data("wOF2".utf8 + Array(repeating: 0, count: 12))))
        XCTAssertFalse(FontRegistry.isFontData(Data("<svg>".utf8 + Array(repeating: 0, count: 12))))
        XCTAssertFalse(FontRegistry.isFontData(Data([0x4C, 0x50, 0, 0])))
    }

    func testConcurrentLookups() throws {
        let fonts = try registry(files: ["fonts/regular.ttf": try fontFile("Georgia")])
        let names = Mutex<Set<String>>([])
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            var report = SectionReport()
            fonts.register([CSSFontFace(family: "shared", sources: ["OPS/fonts/regular.ttf"])], report: &report)
            let style = Self.style(["shared", "serif"], size: CGFloat(10 + index % 7), weight: 100 * (1 + index % 9),
                                   italic: index % 2 == 0, smallCaps: false)
            let font = fonts.font(for: style)
            names.withLock { _ = $0.insert(font.fontName) }
        }
        XCTAssertEqual(names.withLock { $0 }, ["Georgia"])
    }
}
