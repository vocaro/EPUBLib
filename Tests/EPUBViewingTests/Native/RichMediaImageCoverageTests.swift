import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Raster image sources, replaced-element sizing, the contrast policy and the inspector's
/// decode bounds, driven through the production `SectionBuilder` + `NativeRichContent`.
final class RichMediaImageCoverageTests: XCTestCase {
    private let viewport = CGSize(width: 400, height: 600)

    private func firstImage(_ body: String, files: [String: Data] = [:], dark: Bool = false, fontSize: CGFloat = 16) throws -> (ReaderImageAttachment?, SectionText) {
        let text = try RichMediaBook(body: body, files: files).build(fontSize: fontSize, dark: dark)
        return (text.richMediaImages.first, text)
    }

    private func line(_ width: CGFloat = 400, fontSize: CGFloat = 16) -> ReaderAttachment.Line {
        ReaderAttachment.Line(width: width, viewport: viewport, font: PlatformFont.systemFont(ofSize: fontSize))
    }

    // MARK: Core media types and decoding

    func testHandWrittenPNGColorTypesDecode() throws {
        // Indexed with a tRNS entry: the second palette index is fully transparent.
        let indexed = RichMediaImages.png(width: 2, height: 2, bitDepth: 1, colorType: 3, palette: [255, 0, 0, 0, 0, 255],
                                          transparency: [255, 0], scanlines: [0, 0b0100_0000, 0, 0b1000_0000])
        let indexedSource = try XCTUnwrap(ReaderImageSource.bitmap(indexed, path: "i.png", key: "indexed"))
        XCTAssertEqual(indexedSource.pixelSize, CGSize(width: 2, height: 2))
        let indexedImage = try XCTUnwrap(indexedSource.decode(maxPixelSize: 2))
        XCTAssertEqual(RichMediaImages.rgba(indexedImage, x: 0, y: 0), [255, 0, 0, 255], "palette index 0 is opaque red")
        XCTAssertEqual(RichMediaImages.rgba(indexedImage, x: 1, y: 0)[3], 0, "palette index 1 is transparent via tRNS")

        // 16-bit greyscale.
        let gray16 = RichMediaImages.png(width: 1, height: 1, bitDepth: 16, colorType: 0, scanlines: [0, 0x80, 0x00])
        let grayImage = try XCTUnwrap(ReaderImageSource.bitmap(gray16, path: "g.png", key: "gray16")?.decode(maxPixelSize: 1))
        XCTAssertEqual(RichMediaImages.rgba(grayImage, x: 0, y: 0), [128, 128, 128, 255])

        // Interlaced (Adam7) truecolor-alpha.
        let interlaced = RichMediaImages.png(width: 1, height: 1, bitDepth: 8, colorType: 6, interlace: 1, scanlines: [0, 10, 200, 30, 255])
        let interlacedSource = try XCTUnwrap(ReaderImageSource.bitmap(interlaced, path: "n.png", key: "interlaced"))
        XCTAssertEqual(interlacedSource.pixelSize, CGSize(width: 1, height: 1))
        XCTAssertEqual(RichMediaImages.rgba(try XCTUnwrap(interlacedSource.decode(maxPixelSize: 1)), x: 0, y: 0), [10, 200, 30, 255])

        // Greyscale + alpha.
        let grayAlpha = RichMediaImages.png(width: 2, height: 1, bitDepth: 8, colorType: 4, scanlines: [0, 0, 255, 0, 0])
        let grayAlphaImage = try XCTUnwrap(ReaderImageSource.bitmap(grayAlpha, path: "ga.png", key: "grayAlpha")?.decode(maxPixelSize: 2))
        XCTAssertEqual(RichMediaImages.rgba(grayAlphaImage, x: 0, y: 0), [0, 0, 0, 255])
        XCTAssertEqual(RichMediaImages.rgba(grayAlphaImage, x: 1, y: 0)[3], 0, "the second pixel is transparent")
    }

    func testAnimatedGIFShowsItsFirstFrameAndCMYKJPEGBecomesRGB() throws {
        let red = RichMediaImages.bitmap(width: 8, height: 8) { c, r in c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); c.fill(r) }
        let blue = RichMediaImages.bitmap(width: 8, height: 8) { c, r in c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); c.fill(r) }
        let gif = try XCTUnwrap(RichMediaImages.encode([red, blue], as: .gif))
        XCTAssertEqual(ImageType.mediaType(of: gif), "image/gif")
        let gifSource = try XCTUnwrap(ReaderImageSource.bitmap(gif, path: "a.gif", key: "gif"))
        XCTAssertEqual(gifSource.pixelSize, CGSize(width: 8, height: 8))
        XCTAssertEqual(RichMediaImages.rgba(try XCTUnwrap(gifSource.decode(maxPixelSize: 8)), x: 4, y: 4), [255, 0, 0, 255], "the first frame is red, not the second")

        let cmykBytes = (0..<(16 * 16 * 4)).map { UInt8($0 % 4 == 0 ? 255 : 0) } // pure cyan
        let provider = try XCTUnwrap(CGDataProvider(data: Data(cmykBytes) as CFData))
        let cmyk = try XCTUnwrap(CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let jpeg = try XCTUnwrap(RichMediaImages.encode([cmyk], as: .jpeg))
        let decoded = try XCTUnwrap(ReaderImageSource.bitmap(jpeg, path: "c.jpg", key: "cmyk")?.decode(maxPixelSize: 16))
        XCTAssertEqual(decoded.colorSpace?.model, .rgb, "a CMYK JPEG decodes into an RGB bitmap")
        XCTAssertEqual(RichMediaImages.rgba(decoded, x: 8, y: 8)[0] < 80, true, "cyan has little red")
    }

    func testEveryEXIFOrientationIsApplied() throws {
        // Orientation 1 keeps the red quarter top-left; others move it; 5–8 also swap the dimensions.
        let expected: [Int: (size: CGSize, corner: String)] = [
            1: (CGSize(width: 40, height: 20), "TL"), 2: (CGSize(width: 40, height: 20), "TR"),
            3: (CGSize(width: 40, height: 20), "BR"), 4: (CGSize(width: 40, height: 20), "BL"),
            5: (CGSize(width: 20, height: 40), "TL"), 6: (CGSize(width: 20, height: 40), "TR"),
            7: (CGSize(width: 20, height: 40), "BR"), 8: (CGSize(width: 20, height: 40), "BL"),
        ]
        for orientation in 1...8 {
            let jpeg = try XCTUnwrap(RichMediaImages.encode([RichMediaImages.cornerMarked(width: 40, height: 20)], as: .jpeg,
                                                            properties: [kCGImagePropertyOrientation: orientation]))
            let source = try XCTUnwrap(ReaderImageSource.bitmap(jpeg, path: "o.jpg", key: "o\(orientation)"))
            XCTAssertEqual(source.pixelSize, expected[orientation]!.size, "orientation \(orientation) reports the displayed size")
            let image = try XCTUnwrap(source.decode(maxPixelSize: 40))
            let w = image.width, h = image.height
            let corners: [String: [UInt8]] = ["TL": RichMediaImages.rgba(image, x: w / 4, y: h / 4), "TR": RichMediaImages.rgba(image, x: 3 * w / 4, y: h / 4),
                                              "BL": RichMediaImages.rgba(image, x: w / 4, y: 3 * h / 4), "BR": RichMediaImages.rgba(image, x: 3 * w / 4, y: 3 * h / 4)]
            XCTAssertGreaterThan(corners[expected[orientation]!.corner]![0], 128, "orientation \(orientation): the red mark is at \(expected[orientation]!.corner)")
        }
    }

    // MARK: Resolving references

    func testLocalReferencesResolveAcrossEncodingAndCase() throws {
        let png = RichMediaImages.solid(width: 40, height: 20)
        let files = ["pic.png": png, "images/my photo.png": png, "images/caf\u{e9}.png": png, "/top.png": png]
        func image(_ src: String) throws -> ReaderImageAttachment? {
            try firstImage("<p><img src='\(src)' alt='x'/></p>", files: files).0
        }
        XCTAssertEqual(try image("pic.png#frag")?.path, "OPS/pic.png", "a fragment on the src is stripped")
        XCTAssertEqual(try image("images/my photo.png")?.path, "OPS/images/my photo.png", "a literal space resolves")
        XCTAssertEqual(try image("images/my%20photo.png")?.path, "OPS/images/my photo.png", "percent-encoding resolves to the same file")
        XCTAssertEqual(try image("images/caf\u{e9}.png")?.path, "OPS/images/caf\u{e9}.png", "a non-ASCII path resolves")
        XCTAssertEqual(try image("images/caf%C3%A9.png")?.path, "OPS/images/caf\u{e9}.png", "its percent-encoding resolves to the same file")
        XCTAssertEqual(try image("../top.png")?.path, "top.png", "`..` within the archive resolves")
        // OCF archive paths are case-sensitive, so a case-mismatched name is a missing resource.
        let (missing, text) = try firstImage("<p><img src='PIC.PNG' alt='C'/></p>", files: files)
        XCTAssertNil(missing)
        XCTAssertEqual(text.richMediaPlain, "C")
        XCTAssertEqual(text.report.unreadableResources, 1)
    }

    func testAnImageArchivedUnderAUTF8NameWithoutTheLanguageEncodingFlagIsFetched() throws {
        // zip and ditto on a Mac write the file system's UTF-8 name, here a decomposed one, and
        // leave general-purpose bit 11 clear; the document names the picture precomposed.
        var files = try Fixture.files()
        files["OPS/one.xhtml"] = Data(RichMediaBook.xhtml("<p><img src='images/caf%C3%A9.png' alt='x'/></p>").utf8)
        files["OPS/images/cafe\u{301}.png"] = RichMediaImages.solid(width: 40, height: 20)
        let publication = try EPUBPublication.open(data: Fixture.storedArchive(Fixture.storedEntries(files, flags: 0)))
        let text = SectionBuilder.build(.init(publication: publication, spineIndex: 0, typography: NativeTypography(fontSize: 16, isDark: false),
                                              fonts: FontRegistry(publication: publication),
                                              rich: NativeRichContent(images: ReaderImageCache(budget: 64 << 20))))
        XCTAssertEqual(text.richMediaImages.first?.path, "OPS/images/caf\u{E9}.png")
        XCTAssertEqual(text.report.unreadableResources, 0)
    }

    func testRemoteReferencesAreRefusedAndCountedNotFetched() throws {
        for src in ["https://example.com/a.png", "//example.com/a.png", "file:///etc/hosts", "pic.png\\x", "100%.png"] {
            let (image, text) = try firstImage("<p><img src='\(src)' alt='Remote'/></p>", files: ["pic.png": RichMediaImages.solid(width: 10, height: 10)])
            XCTAssertNil(image, "\(src) must not resolve to an image")
            XCTAssertEqual(text.richMediaPlain, "Remote", "\(src) shows its alt text")
            XCTAssertEqual(text.report.remoteResourcesRefused, 1, "\(src) is counted as a refused out-of-archive reference")
            XCTAssertEqual(text.report.unreadableResources, 0, "\(src) is never decoded")
        }
    }

    func testAReferencePastTheContainerRootOrWithAQueryIsReadFromInsideTheArchive() throws {
        // EPUB Reading Systems 3.3 §4.1.1: a leading "/" names the container root and ".." stops
        // there (W3C tests ocf-url_link-path-absolute and ocf-url_link-leaking-relative show a
        // photograph this way). A query cannot change which entry is meant.
        let png = RichMediaImages.solid(width: 10, height: 10)
        let files = ["pic.png": png, "/top.png": png]
        for (src, path) in ["/OPS/pic.png": "OPS/pic.png", "/top.png": "top.png", "../../top.png": "top.png", "../../../../OPS/pic.png": "OPS/pic.png",
                            "pic.png?v=2": "OPS/pic.png", "pic.png?v=2#frag": "OPS/pic.png"] {
            let (image, text) = try firstImage("<p><img src='\(src)' alt='Inside'/></p>", files: files)
            XCTAssertEqual(image?.path, path, src)
            XCTAssertEqual(text.report.remoteResourcesRefused, 0, src)
            XCTAssertEqual(text.report.unreadableResources, 0, src)
        }
        // What such a reference names may still be missing, as any other may.
        let (missing, text) = try firstImage("<p><img src='../../absent.png' alt='Absent'/></p>", files: files)
        XCTAssertNil(missing)
        XCTAssertEqual(text.richMediaPlain, "Absent")
        XCTAssertEqual(text.report.remoteResourcesRefused, 0)
        XCTAssertEqual(text.report.unreadableResources, 1)
    }

    func testMissingTruncatedZeroByteAndMistypedImages() throws {
        let png = RichMediaImages.solid(width: 200, height: 100)
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='30' height='10'><rect width='30' height='10' fill='red'/></svg>"
        let files: [String: Data] = ["broken.png": Data("not an image".utf8), "zero.png": Data(),
                                     "truncated.png": png.prefix(png.count / 2), "photo.jpg": png, "drawing.png": Data(svg.utf8)]
        let (missing, missingText) = try firstImage("<p><img src='nowhere.png' alt='Map of the region'/></p>")
        XCTAssertNil(missing)
        XCTAssertEqual(missingText.richMediaPlain, "Map of the region")
        XCTAssertEqual(missingText.report.unreadableResources, 1)
        XCTAssertNil(try firstImage("<p><img src='broken.png' alt='B'/></p>", files: files).0, "non-image bytes are unreadable")
        XCTAssertNil(try firstImage("<p><img src='zero.png' alt='Z'/></p>", files: files).0, "a zero-byte file is unreadable")
        // A truncated PNG still has a readable header, so it lays out; drawing it must not trap.
        let truncated = try XCTUnwrap(firstImage("<p><img src='truncated.png' alt='T'/></p>", files: files).0)
        XCTAssertEqual(truncated.source.pixelSize, CGSize(width: 200, height: 100))
        _ = truncated.bitmap(for: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 2)
        // The format is detected from the bytes, not the extension: SVG data under a .png name renders as SVG.
        XCTAssertEqual(try firstImage("<p><img src='photo.jpg' alt='W'/></p>", files: files).0?.source.format, .bitmap, "PNG bytes named .jpg are still a bitmap")
        XCTAssertEqual(try firstImage("<p><img src='drawing.png' alt='S'/></p>", files: files).0?.source.format, .svg, "SVG bytes named .png are detected as SVG")
    }

    func testAltEmptyTitleAriaAndNoSource() throws {
        let png = RichMediaImages.solid(width: 10, height: 10)
        // Empty alt is a decorative image: shown with no accessibility text.
        let decorative = try XCTUnwrap(firstImage("<p><img src='pic.png' alt=''/></p>", files: ["pic.png": png]).0)
        XCTAssertEqual(decorative.alternative, .decorative)
        XCTAssertEqual(decorative.alt, "")
        XCTAssertEqual(decorative.textEquivalent, "")
        // `title` and `aria-label` are not promoted to the image's accessibility text on an <img>.
        XCTAssertEqual(try firstImage("<p><img src='pic.png' title='Titled'/></p>", files: ["pic.png": png]).0?.alt, "")
        XCTAssertEqual(try firstImage("<p><img src='pic.png' aria-label='Sales chart'/></p>", files: ["pic.png": png]).0?.alt, "")
        // Alt whitespace is collapsed.
        XCTAssertEqual(try firstImage("<p><img src='pic.png' alt='  A   photo '/></p>", files: ["pic.png": png]).0?.alt, "A photo")
        // Neither src nor alt contributes nothing; alt without src shows the alt as text.
        let (image, text) = try firstImage("<p>a<img alt='No source'/>b<img/>c</p>")
        XCTAssertNil(image)
        XCTAssertEqual(text.richMediaPlain, "aNo sourcebc")
    }

    /// HTML tells an empty `alt` from a missing one: decoration, and an image nobody has
    /// described. Neither has words, so selections, Copy and search get the same from both.
    func testAnEmptyAltIsDecorationAndAMissingOneIsAnImageWithoutWords() throws {
        let png = RichMediaImages.solid(width: 10, height: 10)
        let titled = Data("<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><title>Its own title</title><rect width='10' height='10'/></svg>".utf8)
        let files = ["pic.png": png, "titled.svg": titled]
        func alternative(_ markup: String) throws -> ImageAlternative? { try firstImage("<p>\(markup)</p>", files: files).0?.alternative }
        XCTAssertEqual(try alternative("<img src='pic.png'/>"), .missing)
        XCTAssertEqual(try alternative("<img src='pic.png' alt=''/>"), .decorative)
        XCTAssertEqual(try alternative("<img src='pic.png' alt=' \n\t'/>"), .decorative, "an alt of white space says no more than an empty one")
        XCTAssertEqual(try alternative("<img src='pic.png' alt='  A   photo '/>"), .text("A photo"))
        // A name from anywhere else says nothing about decoration when it is blank.
        XCTAssertEqual(try alternative("<img src='pic.png' title=''/>"), .missing)
        XCTAssertEqual(try alternative("<object data='pic.png' type='image/png' title='A chart'>Chart</object>"), .text("A chart"))
        XCTAssertEqual(try alternative("<object data='pic.png' type='image/png' title=''>Chart</object>"), .missing)
        XCTAssertEqual(try alternative("<object data='pic.png' type='image/png'>Chart</object>"), .missing)
        XCTAssertEqual(try alternative("<embed src='pic.png'/>"), .missing)
        // A drawing's own title names it where the book gave no alt, and not where the book
        // called it decoration: a title page drawn as an SVG beside the same words as text.
        XCTAssertEqual(try alternative("<img src='titled.svg'/>"), .text("Its own title"))
        XCTAssertEqual(try alternative("<img src='titled.svg' alt=''/>"), .decorative)
        XCTAssertEqual(try alternative("<img src='titled.svg' alt='The book says'/>"), .text("The book says"))
        // An inline SVG, and the image one wraps (a cover page).
        let ns = "xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'"
        XCTAssertEqual(try alternative("<svg \(ns) width='10' height='10'><rect width='10' height='10'/></svg>"), .missing)
        XCTAssertEqual(try alternative("<svg \(ns) width='10' height='10'><title>Drawn</title><rect width='10' height='10'/></svg>"), .text("Drawn"))
        XCTAssertEqual(try alternative("<svg \(ns) viewBox='0 0 10 10'><image width='10' height='10' xlink:href='pic.png'/></svg>"), .missing)
        XCTAssertEqual(try alternative("<svg \(ns) viewBox='0 0 10 10'><title>Cover</title><image width='10' height='10' xlink:href='pic.png'/></svg>"),
                       .text("Cover"))

        // What stands for each in a selection, a copy and a search: its words, or nothing.
        let text = try firstImage("<p>a<img src='pic.png'/>b<img src='pic.png' alt=''/>c<img src='titled.svg' alt=''/>d<img src='pic.png' alt='E'/>f</p>",
                                  files: files).1
        XCTAssertEqual(text.string.string, "a\u{FFFC}b\u{FFFC}c\u{FFFC}d\u{FFFC}f", "one character each, whatever the alt")
        XCTAssertEqual(text.string.readerPlainText(), "abcdEf")
        XCTAssertEqual(text.richMediaImages.map(\.textEquivalent), ["", "", "", "E"])
        // An image that cannot be shown still shows its words, and decoration that cannot, none.
        XCTAssertEqual(try firstImage("<p>a<img src='gone.png' alt='Gone'/>b<img src='gone.png' alt=''/>c<img src='gone.png'/>d</p>").1.richMediaPlain,
                       "aGonebcd")
    }

    /// WAI-ARIA 1.2 and HTML-AAM: `aria-hidden="true"` on an image or round it, or the role
    /// `presentation` or `none`, keeps the image from assistive technology and from nothing
    /// else. ARIA ignores a presentational role on an element that can take focus or that has
    /// a global ARIA attribute, and `aria-hidden="false"` hides nothing.
    func testAnImageTheBookKeepsFromAssistiveTechnologyIsPassedOverAndKeepsItsWords() throws {
        let png = RichMediaImages.solid(width: 10, height: 10)
        let titled = Data("<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><title>Its own title</title><rect width='10' height='10'/></svg>".utf8)
        let files = ["pic.png": png, "titled.svg": titled]
        let ns = "xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'"
        func image(_ markup: String) throws -> ReaderImageAttachment {
            try XCTUnwrap(firstImage("<p>\(markup)</p>", files: files).0, markup)
        }
        for markup in [
            "<img src='pic.png' alt='Words' role='presentation'/>",
            "<img src='pic.png' alt='Words' role='none'/>",
            "<img src='pic.png' alt='Words' aria-hidden='true'/>",
            "<img src='pic.png' role='presentation'/>",
            "<img src='pic.png' role='none'/>",
            "<img src='pic.png' aria-hidden='true'/>",
            "<img src='pic.png' alt='' role='presentation'/>",
            "<img src='pic.png' alt='Words' role=' NONE '/>",
            "<img src='pic.png' alt='Words' aria-hidden=' True '/>",
            // The first token that names a role is the role; one that names none is passed for the next.
            "<img src='pic.png' alt='Words' role='presentation img'/>",
            "<img src='pic.png' alt='Words' role='ornament none'/>",
            // `aria-hidden` hides what is inside, a presentational role only its own element.
            "<span aria-hidden='true'><img src='pic.png' alt='Words'/></span>",
            "<a href='two.xhtml' aria-hidden='true'><img src='pic.png' alt='Words'/></a>",
            // Neither a `tabindex` that is no number nor a global attribute with no value cancels the role.
            "<img src='pic.png' alt='Words' role='presentation' tabindex='first'/>",
            "<img src='pic.png' alt='Words' role='presentation' aria-label=' '/>",
            // Every kind of picture the reader draws.
            "<img src='titled.svg' role='none'/>",
            "<object data='pic.png' type='image/png' title='A chart' role='presentation'>Chart</object>",
            "<embed src='pic.png' aria-hidden='true'/>",
            "<svg \(ns) width='10' height='10' aria-hidden='true'><title>Drawn</title><rect width='10' height='10'/></svg>",
            "<svg \(ns) width='10' height='10' role='presentation'><title>Drawn</title><rect width='10' height='10'/></svg>",
            "<svg \(ns) viewBox='0 0 10 10' role='none'><title>Cover</title><image width='10' height='10' xlink:href='pic.png'/></svg>",
            "<svg \(ns) viewBox='0 0 10 10'><image width='10' height='10' xlink:href='pic.png' alt='Cover' aria-hidden='true'/></svg>",
        ] {
            let hidden = try image(markup)
            XCTAssertTrue(hidden.isHiddenFromAssistiveTechnology, markup)
            XCTAssertTrue(hidden.isPassedOverByAssistiveTechnology, markup)
            XCTAssertEqual(hidden.spokenAlt, "", markup)
            XCTAssertEqual(hidden.spokenEquivalent, "", markup)
        }
        for markup in [
            "<img src='pic.png' alt='Words'/>",
            "<img src='pic.png' alt='Words' aria-hidden='false'/>",
            "<img src='pic.png' alt='Words' aria-hidden=''/>",
            "<img src='pic.png' alt='Words' role='img'/>",
            "<img src='pic.png' alt='Words' role='img presentation'/>",
            "<img src='pic.png' alt='Words' role='doc-cover none'/>",
            "<span aria-hidden='false'><img src='pic.png' alt='Words'/></span>",
            "<span role='presentation'><img src='pic.png' alt='Words'/></span>",
            // A presentational role is ignored where the image can take focus or has a global ARIA attribute.
            "<img src='pic.png' alt='Words' role='presentation' tabindex='-1'/>",
            "<img src='pic.png' alt='Words' role='none' tabindex=' +2'/>",
            "<img src='pic.png' alt='Words' role='none' aria-label='Named'/>",
            "<img src='pic.png' alt='Words' role='presentation' aria-describedby='note'/>",
            "<img src='pic.png' alt='Words' role='presentation' aria-hidden='false'/>",
            // A drawing that names itself is not hidden by the image it wraps.
            "<svg \(ns) viewBox='0 0 10 10'><title>Cover</title><image width='10' height='10' xlink:href='pic.png' aria-hidden='true'/></svg>",
        ] {
            let shown = try image(markup)
            XCTAssertFalse(shown.isHiddenFromAssistiveTechnology, markup)
            XCTAssertFalse(shown.isPassedOverByAssistiveTechnology, markup)
            XCTAssertEqual(shown.spokenAlt, shown.alt, markup)
        }

        // Its words are its own still: what it stands for in a selection, a copy and a search,
        // and what is shown where it cannot be drawn. Only assistive technology goes without them.
        let kept = try image("<img src='pic.png' alt='Kept words' aria-hidden='true'/>")
        XCTAssertEqual(kept.alternative, .text("Kept words"))
        XCTAssertEqual(kept.alt, "Kept words")
        XCTAssertEqual(kept.textEquivalent, "Kept words")
        let decoration = try image("<img src='pic.png' alt=''/>")
        XCTAssertFalse(decoration.isHiddenFromAssistiveTechnology, "decoration is passed over for having no words")
        XCTAssertTrue(decoration.isPassedOverByAssistiveTechnology)
        XCTAssertEqual(try image("<img src='pic.png' role='none'/>").alternative, .missing)
        let text = try firstImage("<p>a<img src='pic.png' alt='B' aria-hidden='true'/>c<img src='pic.png' alt='D' role='presentation'/>e"
                                  + "<img src='pic.png' alt='F'/>g</p>", files: files).1
        XCTAssertEqual(text.string.readerPlainText(), "aBcDeFg", "what a selection, a copy and a search take")
        XCTAssertEqual(text.string.readerPlainText(spoken: true), "aceFg", "what VoiceOver is given")
        XCTAssertEqual(try firstImage("<p>a<img src='gone.png' alt='Gone' aria-hidden='true'/>b</p>").1.richMediaPlain, "aGoneb",
                       "an image that cannot be shown still shows its words")
    }

    func testUnknownModuleRolesFallBackToPresentationForImagesAndRules() throws {
        let files = ["pic.png": RichMediaImages.solid(width: 10, height: 10)]
        for role in ["doc-ornament none", "graphics-ornament none", "doc-cover-extra presentation",
                     "graphics-symbolic presentation", "unknown graphics-ornament doc-ornament none"] {
            let section = try RichMediaBook(body: "<p>Before <img src='pic.png' alt='Unspoken' role='\(role)'/> after.</p>"
                                           + "<hr role='\(role)'/>", files: files).build()
            let image = try XCTUnwrap(section.richMediaImages.first)
            let rule = try XCTUnwrap(section.richMediaAttachments.compactMap { $0.attachment as? ReaderRuleAttachment }.first)
            XCTAssertTrue(image.isHiddenFromAssistiveTechnology, role)
            XCTAssertTrue(rule.isHiddenFromAssistiveTechnology, role)
            XCTAssertEqual(section.string.readerPlainText(spoken: true), "Before  after.\n", role)
            XCTAssertEqual(section.string.readerPlainText(), "Before Unspoken after.\n", "Copy and search keep the words: \(role)")
        }
    }

    func testRecognizedModuleRolesTakePrecedenceOverPresentationalFallbacks() throws {
        let files = ["pic.png": RichMediaImages.solid(width: 10, height: 10)]
        // Current and deprecated DPUB roles, and all three Graphics roles, remain recognized.
        for role in ["doc-cover", "doc-endnote", "doc-pageheader", "doc-pagefooter",
                     "graphics-document", "graphics-object", "graphics-symbol"] {
            let image = try XCTUnwrap(firstImage("<img src='pic.png' alt='Spoken' role='unknown \(role) none'/>", files: files).0)
            XCTAssertFalse(image.isHiddenFromAssistiveTechnology, role)
            XCTAssertEqual(image.spokenEquivalent, "Spoken", role)
        }
    }

    /// A rule the book keeps from assistive technology, as ornament and not a break, by the
    /// same attributes and with the same exceptions.
    func testARuleTheBookKeepsFromAssistiveTechnologyIsMarkedSo() throws {
        func rule(_ markup: String) throws -> ReaderRuleAttachment {
            let text = try RichMediaBook(body: "<p>Above.</p>\(markup)<p>Below.</p>").build()
            return try XCTUnwrap(text.richMediaAttachments.compactMap { $0.attachment as? ReaderRuleAttachment }.first, markup)
        }
        for markup in ["<hr role='presentation'/>", "<hr role='none'/>", "<hr aria-hidden='true'/>", "<hr role='bar none'/>",
                       "<div aria-hidden='true'><hr/></div>"] {
            XCTAssertTrue(try rule(markup).isHiddenFromAssistiveTechnology, markup)
        }
        for markup in ["<hr/>", "<hr role='separator'/>", "<hr role='separator presentation'/>", "<hr aria-hidden='false'/>",
                       "<hr role='presentation' tabindex='0'/>", "<hr role='none' aria-label='Scene break'/>",
                       "<hr role='presentation' aria-roledescription='scene break'/>"] {
            XCTAssertFalse(try rule(markup).isHiddenFromAssistiveTechnology, markup)
        }
    }

    func testObjectEmbedAndPictureImageSelection() throws {
        let png = RichMediaImages.solid(width: 40, height: 20)
        XCTAssertNotNil(try firstImage("<p><object data='chart.png' type='image/png'>Chart</object></p>", files: ["chart.png": png]).0)
        XCTAssertNil(try firstImage("<p><object data='clip.mp4' type='video/mp4'>Clip</object></p>").0, "a non-image object falls back to its content")
        XCTAssertNotNil(try firstImage("<p><embed src='chart.png'/></p>", files: ["chart.png": png]).0)
        // A file the manifest does not list is an image by its name's extension, which ends at
        // the first `#`, found as its byte: "#" and a mark after it are one `Character`
        // (https://github.com/vocaro/EPUBLib/issues/641).
        XCTAssertNotNil(try firstImage("<p><embed src='chart.png#&#x301;x'/></p>", files: ["chart.png": png]).0)
        XCTAssertNotNil(try firstImage("<p><object data='chart.png#&#x301;x'>Chart</object></p>", files: ["chart.png": png]).0)
        // A <picture> uses its <img> child; unsupported <source type> candidates are ignored.
        let picture = try firstImage("<p><picture><source srcset='pic.avif' type='image/avif'/><img src='chart.png' alt='Pic'/></picture></p>", files: ["chart.png": png])
        XCTAssertEqual(picture.0?.path, "OPS/chart.png")
    }

    // MARK: Sizing

    func testHTMLAttributeAndCSSSizingKeepTheAspectRatio() throws {
        let files = ["s.png": RichMediaImages.solid(width: 40, height: 20), "w.png": RichMediaImages.solid(width: 800, height: 400)]
        func size(_ attr: String, source: String = "s.png") throws -> CGSize {
            let image = try XCTUnwrap(firstImage("<p><img src='\(source)' \(attr)/></p>", files: files).0)
            return image.displaySize(line())
        }
        XCTAssertEqual(try size("width='100'"), CGSize(width: 100, height: 50), "a width attribute keeps the ratio")
        XCTAssertEqual(try size("height='100'"), CGSize(width: 200, height: 100))
        XCTAssertEqual(try size("width='100' height='100'"), CGSize(width: 100, height: 50), "both attributes fit the image inside, as object-fit: contain")
        XCTAssertEqual(try size("width='50%'"), CGSize(width: 200, height: 100), "a percentage width is of the line")
        XCTAssertEqual(try size("width='abc' height='-3'"), CGSize(width: 40, height: 20), "junk and negative attributes are ignored")
        XCTAssertEqual(try size("width='0' height='0'"), CGSize(width: 1, height: 1), "a zero-sized image collapses to one point")
        XCTAssertEqual(try size("width='999999999'"), CGSize(width: 400, height: 200), "a huge declared width is clamped and then fits the line")
        XCTAssertEqual(try size("style='width:10em'"), CGSize(width: 160, height: 80), "em resolves against the font size")
        XCTAssertEqual(try size("style='width:50vw'"), CGSize(width: 200, height: 100), "vw is of the 400-wide viewport in this fixture")
        XCTAssertEqual(try size("style='max-width:100%'", source: "w.png"), CGSize(width: 400, height: 200), "max-width:100% scales a wide image down to the line")
        XCTAssertEqual(try size("style='max-width:50%'", source: "w.png"), CGSize(width: 200, height: 100))
        XCTAssertEqual(try size("style='max-height:10vh'", source: "w.png"), CGSize(width: 120, height: 60), "max-height in vh keeps the ratio")
        XCTAssertEqual(try size("style='min-width:200px'"), CGSize(width: 200, height: 100), "min-width scales up keeping the ratio")
        XCTAssertEqual(try size("style='width:auto;height:auto' width='100'"), CGSize(width: 40, height: 20),
                       "CSS auto beats the width attribute, a presentational hint (#763)")
    }

    func testAnImageNeverExceedsTheLineOrPageAndTinySpacersSurvive() throws {
        let files = ["tall.png": RichMediaImages.solid(width: 300, height: 3000), "dot.gif": RichMediaImages.solid(width: 1, height: 1)]
        let tall = try XCTUnwrap(firstImage("<p><img src='tall.png' alt='t'/></p>", files: files).0)
        let container = ReaderTextContainer(size: CGSize(width: 400, height: 0))
        container.viewportSize = CGSize(width: 400, height: 500)
        let bounds = tall.attachmentBounds(for: container, proposedLineFragment: CGRect(x: 0, y: 0, width: 400, height: 20), glyphPosition: .zero, characterIndex: 0)
        XCTAssertEqual(bounds.size, CGSize(width: 50, height: 500), "a page-taller image fits one page, keeping its ratio")
        let spacer = try XCTUnwrap(firstImage("<p><img src='dot.gif' width='100%' height='1'/></p>", files: files).0)
        XCTAssertEqual(spacer.displaySize(line()), CGSize(width: 1, height: 1), "a 1x1 spacer stays tiny")
    }

    func testBlockInlineAndVerticalAlignment() throws {
        let png = RichMediaImages.solid(width: 40, height: 20)
        let inline = try XCTUnwrap(firstImage("<p><img src='p.png' alt='i'/></p>", files: ["p.png": png]).0)
        XCTAssertFalse(inline.isBlock)
        XCTAssertEqual(inline.verticalAlign, .baseline)
        let block = try XCTUnwrap(firstImage("<p><img src='p.png' style='display:block' alt='b'/></p>", files: ["p.png": png]).0)
        XCTAssertTrue(block.isBlock)
        let top = try XCTUnwrap(firstImage("<p><img src='p.png' style='vertical-align:top' alt='t'/></p>", files: ["p.png": png]).0)
        XCTAssertEqual(top.verticalAlign, .top)
        let font = PlatformFont.systemFont(ofSize: 16)
        XCTAssertEqual(top.layoutBounds(line()).minY, font.ascender - 20, accuracy: 0.5, "vertical-align:top hangs the image from the ascent")
    }

    func testImagesInLinksHeadingsAndListsKeepTheirContext() throws {
        let png = RichMediaImages.solid(width: 40, height: 20)
        let body = "<h1><img src='p.png' alt='in heading'/></h1><p><a href='two.xhtml'><img src='p.png' alt='linked'/></a></p>"
        let text = try RichMediaBook(body: body, files: ["p.png": png]).build()
        let images = text.richMediaAttachments
        let heading = try XCTUnwrap(images.first { ($0.attachment as? ReaderImageAttachment)?.alt == "in heading" })
        XCTAssertGreaterThan((heading.attachment as? ReaderImageAttachment)?.fontSize ?? 0, 16, "an image in a heading carries the heading font size")
        let linked = try XCTUnwrap(images.first { ($0.attachment as? ReaderImageAttachment)?.alt == "linked" })
        XCTAssertNotNil(text.string.attribute(.link, at: linked.location, effectiveRange: nil), "an image inside a link keeps the link")
    }

    // MARK: Cache and contrast

    func testTheSameImageIsDecodedOnceAndRenditionsCacheByAppearance() throws {
        let cache = ReaderImageCache(budget: 64 << 20)
        let source = try XCTUnwrap(ReaderImageSource.bitmap(RichMediaImages.solid(width: 200, height: 100), path: "p.png", key: "shared"))
        _ = cache.image(for: source, maxPixelSize: 128)
        _ = cache.image(for: source, maxPixelSize: 128)
        XCTAssertEqual(cache.decodeCount, 1, "two requests for the same size and appearance decode once")
        _ = cache.image(for: source, maxPixelSize: 128, inverted: true)
        _ = cache.image(for: source, maxPixelSize: 128, lightBackdrop: true)
        XCTAssertEqual(cache.decodeCount, 3, "an inverted and a backdrop rendition are cached apart")
        XCTAssertEqual(cache.count, 3)
        let tiny = ReaderImageCache(budget: 10)
        XCTAssertNotNil(tiny.image(for: source, maxPixelSize: 64), "a decode larger than the whole budget is still returned")
        XCTAssertEqual(tiny.count, 0, "but not kept")
    }

    func testContrastPolicyBoundaries() throws {
        func image(_ draw: RichMediaImages.Draw) throws -> CGImage {
            try XCTUnwrap(ReaderImageSource.bitmap(RichMediaImages.png(width: 16, height: 16, draw: draw), path: "c.png", key: UUID().uuidString)?.decode(maxPixelSize: 16))
        }
        // Fully transparent, opaque, and near-transparent-ink images keep their exact pixels.
        let clear = try image { _, _ in }
        XCTAssertTrue(ReaderImageCache.addingLightBackdrop(clear) === clear, "a fully transparent image is unchanged")
        let opaque = try image { c, r in c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(r) }
        XCTAssertTrue(ReaderImageCache.addingLightBackdrop(opaque) === opaque, "an opaque image is unchanged")
        let faint = try image { c, _ in c.setFillColor(CGColor(gray: 0, alpha: 0.1)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 16)) }
        XCTAssertTrue(ReaderImageCache.addingLightBackdrop(faint) === faint, "near-transparent antialiasing is not treated as dark ink")
        let light = try image { c, _ in c.setFillColor(CGColor(gray: 0.9, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 16)) }
        XCTAssertTrue(ReaderImageCache.addingLightBackdrop(light) === light, "transparent light artwork is unchanged")
        // Transparent artwork with dark ink gets a white backdrop in its transparent areas.
        for draw in [{ (c: CGContext, _: CGRect) in c.setFillColor(CGColor(gray: 0.3, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 16)) },
                     { (c: CGContext, _: CGRect) in c.setFillColor(CGColor(gray: 0, alpha: 0.5)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 16)) }] {
            let artwork = try image(draw)
            let result = try XCTUnwrap(ReaderImageCache.addingLightBackdrop(artwork))
            XCTAssertFalse(result === artwork, "dark transparent artwork receives a backdrop")
            XCTAssertEqual(RichMediaImages.rgba(result, x: 12, y: 8), [255, 255, 255, 255], "its transparent area is filled white")
        }
    }

    func testDarkAttachmentUsesBackdropAndAuthorInversionWins() throws {
        let data = RichMediaImages.png(width: 16, height: 16) { c, _ in c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 16)) }
        let backdrop = try XCTUnwrap(firstImage("<p><img src='g.png'/></p>", files: ["g.png": data], dark: true).0)
        let drawn = try XCTUnwrap(backdrop.bitmap(for: CGRect(x: 0, y: 0, width: 16, height: 16), scale: 1))
        XCTAssertEqual(RichMediaImages.rgba(drawn, x: 12, y: 8), [255, 255, 255, 255], "dark line art on the dark canvas gets a light backdrop")
        let inverted = try XCTUnwrap(firstImage("<p><img src='g.png' style='filter:invert(100%)'/></p>", files: ["g.png": data], dark: true).0)
        let invertedDrawn = try XCTUnwrap(inverted.bitmap(for: CGRect(x: 0, y: 0, width: 16, height: 16), scale: 1))
        XCTAssertEqual(RichMediaImages.rgba(invertedDrawn, x: 2, y: 8), [255, 255, 255, 255], "author inversion turns black to white")
        XCTAssertEqual(RichMediaImages.rgba(invertedDrawn, x: 12, y: 8)[3], 0, "and keeps transparency, not a backdrop")
    }

    // MARK: Inspection

    func testInspectionDecodeBoundsAndFitScale() throws {
        XCTAssertEqual(ReaderImageInspection.decodeDimension(for: CGSize(width: 8192, height: 8192)), 4096, "16 MP is enforced on the long side as well")
        XCTAssertLessThanOrEqual(ReaderImageInspection.decodeDimension(for: CGSize(width: 20000, height: 1000)), ReaderImageInspection.maximumDimension)
        XCTAssertEqual(ReaderImageInspection.decodeDimension(for: CGSize(width: 1, height: 100_000)), 8192, "a thin tall image is capped at the 8192 long side")
        XCTAssertEqual(ReaderImageInspection.decodeDimension(for: CGSize(width: CGFloat.nan, height: 10)), 1, "a non-finite size never crashes")
        XCTAssertEqual(ReaderImageInspection.decodeDimension(for: .zero), 1)
        for size in [CGSize(width: 8192, height: 8192), CGSize(width: 20000, height: 1000), CGSize(width: 3000, height: 20000)] {
            let dimension = ReaderImageInspection.decodeDimension(for: size)
            let scale = CGFloat(dimension) / max(size.width, size.height)
            XCTAssertLessThanOrEqual(Int(ceil(size.width * scale) * ceil(size.height * scale)), ReaderImageInspection.maximumPixels)
        }
        XCTAssertEqual(ReaderImageInspection.fitScale(image: CGSize(width: 100, height: 50), viewport: CGSize(width: 320, height: 600)), 1, "a small image fits at its own size")
        XCTAssertEqual(ReaderImageInspection.fitScale(image: .zero, viewport: viewport), 1)
        XCTAssertGreaterThanOrEqual(ReaderImageInspection.fitScale(image: CGSize(width: 1e9, height: 1), viewport: viewport), 0.0001, "an extreme aspect ratio never fits to zero")
        XCTAssertEqual(ReaderImageInspection.maximumScale(fit: 1), 16)
        XCTAssertEqual(ReaderImageInspection.maximumScale(fit: 0.01), 4, "the maximum zoom never falls below 4x")
    }

    // MARK: Data URLs — EPUB 3.3 §3.4

    /// EPUB 3.3 §3.4 ("Data URLs") and the W3C reading-system test `pub-data-urls`
    /// (<https://www.w3.org/TR/epub-rs/#confreq-rs-data-urls>): an `<img>` whose `src` is a
    /// `data:` URL MUST be displayed, and is, as an image from the archive is (#134).
    func testDataURLImageIsDisplayed() throws {
        let b64 = RichMediaImages.solid(width: 40, height: 20).base64EncodedString()
        let (image, text) = try firstImage("<p><img src='data:image/png;base64,\(b64)' alt='Data'/></p>")
        XCTAssertNotNil(image, "a data: URL image must be displayed, not shown as alt text")
        XCTAssertEqual(image?.source.pixelSize, CGSize(width: 40, height: 20))
        XCTAssertEqual(text.richMediaPlain, "\u{FFFC}", "the image occupies one attachment character, not its alt text")
        XCTAssertEqual(image?.path, "", "it has no archive path")
        XCTAssertEqual(text.report.unreadableResources, 0)
    }

    /// The forms the data: URL processor reads: base64 broken by white space or without its
    /// padding, a type and `;base64` in any case and with parameters, white space and a fragment
    /// round the URL, and a percent-encoded body. An `<object>` of an image type is read as well.
    func testEveryFormOfADataURLImageIsShown() throws {
        let png = RichMediaImages.solid(width: 40, height: 20)
        let b64 = png.base64EncodedString()
        let lines = stride(from: 0, to: b64.count, by: 60).map { String(b64.dropFirst($0).prefix(60)) }.joined(separator: "&#10; ")
        let percent = png.map { String(format: "%%%02X", $0) }.joined()
        for markup in ["<img src='data:image/png;base64,\(lines)' alt='Data'/>",
                       "<img src='DATA:Image/PNG ; BASE64,\(b64.replacingOccurrences(of: "=", with: ""))' alt='Data'/>",
                       "<img src='data:image/png;name=square.png;base64,\(b64)' alt='Data'/>",
                       "<img src=' &#9;data:image/png;base64,\(b64)#square ' alt='Data'/>",
                       "<img src='data:image/png,\(percent)' alt='Data'/>",
                       "<object data='data:image/png;base64,\(b64)' type='image/png'>Data</object>"] {
            let (image, text) = try firstImage("<p>\(markup)</p>")
            XCTAssertEqual(image?.source.pixelSize, CGSize(width: 40, height: 20), markup)
            XCTAssertEqual(text.richMediaPlain, "\u{FFFC}", markup)
            XCTAssertEqual(text.report.unreadableResources, 0, markup)
        }
        // SVG, percent-encoded as the W3C test `pub-data-urls_top-level-content` writes it, is
        // drawn at the size it declares, as SVG from the archive is.
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='30' height='10'><title>Bar</title><rect width='30' height='10' fill='red'/></svg>"
        let escaped = try XCTUnwrap(svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let (drawing, text) = try firstImage("<p><img src='data:image/svg+xml,\(escaped)'/></p>")
        XCTAssertEqual(drawing?.source.format, .svg)
        XCTAssertEqual(drawing?.sizing.intrinsic, CGSize(width: 30, height: 10))
        XCTAssertEqual(drawing?.alternative, .text("Bar"), "an SVG without alt is named by its title")
        XCTAssertEqual(text.report.unreadableResources, 0)
        XCTAssertTrue(text.report.unsupportedElements.isEmpty)
    }

    /// Two images in `data:` URLs are told apart in the shared image cache, which knows each by
    /// its element's position, as it knows an inline SVG.
    func testDataURLImagesInOneSectionAreCachedApart() throws {
        let red = RichMediaImages.solid(width: 4, height: 4, red: 1, green: 0, blue: 0).base64EncodedString()
        let blue = RichMediaImages.solid(width: 4, height: 4, red: 0, green: 0, blue: 1).base64EncodedString()
        let text = try RichMediaBook(body: "<p><img src='data:image/png;base64,\(red)' alt='Red'/><img src='data:image/png;base64,\(blue)' alt='Blue'/></p>").build()
        let images = text.richMediaImages
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(Set(images.map(\.source.key)).count, 2)
        let pixels = try images.map { try XCTUnwrap($0.source.decode(maxPixelSize: 4)) }.map { RichMediaImages.rgba($0, x: 1, y: 1) }
        XCTAssertGreaterThan(pixels[0][0], pixels[0][2], "the first is red")
        XCTAssertGreaterThan(pixels[1][2], pixels[1][0], "the second is blue")
    }

    /// A `data:` URL that is no usable image falls back as an image from the archive that cannot be
    /// shown does: to its alt text, counted unreadable. That is one the processor cannot read (no
    /// comma, base64 that does not decode), one whose type is not an image's (`text/plain` where
    /// it names none), bytes ImageIO cannot read, and a bitmap past the pixels an archive image
    /// may have.
    func testADataURLThatIsNoUsableImageFallsBackAsAnUnreadableImageDoes() throws {
        let png = RichMediaImages.solid(width: 40, height: 20).base64EncodedString()
        let huge = RichMediaImages.headerOnlyPNG(width: 8193, height: 8193)
        XCTAssertNil(ReaderImageSource.bitmap(huge, path: "huge.png", key: "huge"), "an archive image of this size is refused too")
        for src in ["data:image/png;base64", "data:image/png;base64,\(png)=", "data:image/png;base64,\(png.dropLast(2))!=",
                    "data:text/plain;base64,\(png)", "data:;base64,\(png)", "data:,\(png)",
                    "data:image/png;base64,AAAA", "data:image/png;base64,\(huge.base64EncodedString())"] {
            let (image, text) = try firstImage("<p><img src='\(src)' alt='Fallback'/></p>")
            XCTAssertNil(image, src)
            XCTAssertEqual(text.richMediaPlain, "Fallback", src)
            XCTAssertEqual(text.report.unreadableResources, 1, src)
            XCTAssertEqual(text.report.remoteResourcesRefused, 0, src)
        }
        // An SVG that cannot be drawn is disclosed as one, as it is from the archive.
        let (broken, text) = try firstImage("<p><img src='data:image/svg+xml,%3Csvg%3E' alt='Broken'/></p>")
        XCTAssertNil(broken)
        XCTAssertEqual(text.richMediaPlain, "Broken")
        XCTAssertEqual(text.report.unsupportedElements, ["svg": 1])
        XCTAssertEqual(text.report.unreadableResources, 0)
    }

    /// A drawing in a `data:` URL has no base in the archive, so a reference in it names no file,
    /// however it is written: what it would show is left out, as the renderer leaves out what
    /// it cannot use.
    func testADrawingInADataURLReachesNoArchiveFile() throws {
        let png = RichMediaImages.solid(width: 10, height: 10)
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='30' height='10'><image href='pic.png' width='10' height='10'/>"
            + "<image href='/OPS/pic.png' x='10' width='10' height='10'/><rect x='20' width='10' height='10' fill='blue'/></svg>"
        let escaped = try XCTUnwrap(svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let (drawing, text) = try firstImage("<p><img src='data:image/svg+xml,\(escaped)' alt='Drawing'/></p>", files: ["pic.png": png, "/pic.png": png])
        let image = try XCTUnwrap(drawing)
        XCTAssertEqual(image.source.format, .svg)
        let bitmap = try XCTUnwrap(image.source.decode(maxPixelSize: 30))
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 5, y: 5)[3], 0, "the relative reference shows nothing")
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 15, y: 5)[3], 0, "nor does the one from the root")
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 25, y: 5), [0, 0, 255, 255], "the rest is drawn")
        XCTAssertEqual(text.report.unsupportedElements["svg:image"], 2)
    }

    /// The data: URL processor of the Fetch standard, with cases from the Web Platform Tests'
    /// `fetch/data-urls/resources/data-urls.json`. Every image in a `data:` URL, in a section or
    /// in a drawing given to the renderer, is read by it.
    func testTheDataURLProcessor() throws {
        func read(_ reference: String, maximumBytes: Int = .max) -> String? {
            DataURL(reference, maximumBytes: maximumBytes).map { $0.mediaType + " " + $0.body.map { String(format: "%02x", $0) }.joined() }
        }
        XCTAssertEqual(read("data:,X"), "text/plain 58")
        XCTAssertEqual(read("data:,"), "text/plain ")
        XCTAssertEqual(read("data://test/,X"), "text/plain 58")
        XCTAssertNil(read("data:"))
        XCTAssertNil(read("data:text/html"))
        XCTAssertNil(read("data:text/html    ;charset=x   "))
        XCTAssertEqual(read("data:,X#X"), "text/plain 58")
        XCTAssertEqual(read("data:,%FF"), "text/plain ff")
        XCTAssertEqual(read("data:,%F"), "text/plain 2546")
        XCTAssertEqual(read("data:,\u{B1}"), "text/plain c2b1")
        XCTAssertEqual(read("data:text/plain ,X"), "text/plain 58")
        XCTAssertEqual(read("data:text/plain%20,X"), "text/plain%20 58")
        XCTAssertEqual(read("data:text/plain\u{0C},X"), "text/plain%0c 58")
        XCTAssertEqual(read("data:text/plain\u{0},X"), "text/plain%00 58")
        XCTAssertEqual(read("data:IMAGE/gif;hi=x,%C2%B1"), "image/gif c2b1")
        XCTAssertEqual(read("data: ,%FF"), "text/plain ff")
        XCTAssertEqual(read("data:;x=x,X"), "text/plain 58")
        XCTAssertEqual(read("data:x/x;base64;base64,WA"), "x/x 58")
        XCTAssertEqual(read("data:x/x;base64;base64x,WA"), "x/x 5741")
        XCTAssertEqual(read("data:;base64;base64,WA"), "text/plain 58")
        XCTAssertEqual(read("data:x/x;base64 ,WA"), "x/x 58")
        XCTAssertEqual(read("data:x/x;base64 ;,WA"), "x/x 5741")
        XCTAssertEqual(read("data:x/x;base64\u{0},WA"), "x/x 5741")
        XCTAssertEqual(read("data:x/x;base64,W%20A"), "x/x 58")
        XCTAssertEqual(read("data:x/x;base64,W%0CA"), "x/x 58")
        XCTAssertEqual(read("data:x/x;base64,WA=="), "x/x 58")
        XCTAssertEqual(read("data:x/x;base64,WAA"), "x/x 5800")
        XCTAssertNil(read("data:x/x;base64,WA="))
        XCTAssertNil(read("data:x/x;base64,WA==="))
        XCTAssertNil(read("data:x/x;base64,W=A="))
        XCTAssertNil(read("data:x/x;base64,WAAAA"))
        // A query is part of the body; tabs and newlines are left out, and the scheme is matched
        // in any case past the controls and spaces before it.
        XCTAssertEqual(read("data:,X?Y"), "text/plain 583f59")
        XCTAssertEqual(read(" \u{1}D\nA\tTA:,X\r "), "text/plain 58")
        XCTAssertTrue(DataURL.isDataURL("\tdata:image/png"), "a data: URL the processor cannot read is still one")
        XCTAssertFalse(DataURL.isDataURL("dat:,X"))
        XCTAssertFalse(DataURL.isDataURL("./data:,X"))
        XCTAssertFalse(DataURL.isDataURL("\u{A0}data:,X"), "a no-break space is not read past")
        // The body is held to a length in both forms.
        XCTAssertEqual(read("data:,abcd", maximumBytes: 4), "text/plain 61626364")
        XCTAssertNil(read("data:,abcd", maximumBytes: 3))
        XCTAssertEqual(read("data:;base64,YWJjZA==", maximumBytes: 4), "text/plain 61626364")
        XCTAssertNil(read("data:;base64,YWJjZA==", maximumBytes: 3))
    }
}
