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

    func testRemoteAndOutOfArchiveReferencesAreRefusedAndCountedNotFetched() throws {
        for src in ["https://example.com/a.png", "//example.com/a.png", "file:///etc/hosts", "/OPS/pic.png", "../../top.png", "pic.png?v=2"] {
            let (image, text) = try firstImage("<p><img src='\(src)' alt='Remote'/></p>", files: ["pic.png": RichMediaImages.solid(width: 10, height: 10)])
            XCTAssertNil(image, "\(src) must not resolve to an image")
            XCTAssertEqual(text.richMediaPlain, "Remote", "\(src) shows its alt text")
            XCTAssertEqual(text.report.remoteResourcesRefused, 1, "\(src) is counted as a refused out-of-archive reference")
            XCTAssertEqual(text.report.unreadableResources, 0, "\(src) is never decoded")
        }
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

    func testObjectEmbedAndPictureImageSelection() throws {
        let png = RichMediaImages.solid(width: 40, height: 20)
        XCTAssertNotNil(try firstImage("<p><object data='chart.png' type='image/png'>Chart</object></p>", files: ["chart.png": png]).0)
        XCTAssertNil(try firstImage("<p><object data='clip.mp4' type='video/mp4'>Clip</object></p>").0, "a non-image object falls back to its content")
        XCTAssertNotNil(try firstImage("<p><embed src='chart.png'/></p>", files: ["chart.png": png]).0)
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
        XCTAssertEqual(try size("style='width:auto;height:auto' width='100'"), CGSize(width: 100, height: 50), "CSS auto lets the width attribute through")
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
    /// `data:` URL MUST be displayed. The engine decodes `data:` images inside SVG already, but a
    /// top-level `<img src="data:...">` is counted unreadable and shown as its alt text instead.
    func testDataURLImageIsDisplayed() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/134")
        let b64 = RichMediaImages.solid(width: 40, height: 20).base64EncodedString()
        let (image, text) = try firstImage("<p><img src='data:image/png;base64,\(b64)' alt='Data'/></p>")
        XCTAssertNotNil(image, "a data: URL image must be displayed, not shown as alt text")
        XCTAssertEqual(image?.source.pixelSize, CGSize(width: 40, height: 20))
        XCTAssertEqual(text.richMediaPlain, "\u{FFFC}", "the image occupies one attachment character, not its alt text")
    }
}
