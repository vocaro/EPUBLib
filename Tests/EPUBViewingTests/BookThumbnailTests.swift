import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EPUBViewing

/// The cover thumbnail a Quick Look thumbnail extension gives (#695): the cover in its own
/// proportions within the size asked for, decoded to no more pixels than that, upright in Core
/// Graphics coordinates; or a title page when the book has no cover that can be drawn.
final class BookThumbnailTests: XCTestCase {
    /// A book of two chapters with `cover` as its cover image, if any.
    static func book(cover: (href: String, mediaType: String, data: Data, item: String)? = nil, extra: String = "",
                     files: [String: Data] = [:], metadata: String? = nil) -> Fixture.SpecBook {
        var book = Fixture.SpecBook()
        if let metadata { book.metadata = metadata }
        book.add("one", body: "<h1>One</h1><p>The opening words of the book.</p>")
        book.add("two", body: "<h1>Two</h1><p>The second chapter.</p>")
        if let cover {
            book.resource(cover.href, id: "cover", mediaType: cover.mediaType, cover.data,
                          item: "properties=\"cover-image\"" + (cover.item.isEmpty ? "" : " " + cover.item))
        }
        book.manifest += extra
        for (path, data) in files { book.files[path] = data }
        return book
    }

    /// An image whose top half is red and bottom half blue, as an encoded file.
    static func halves(width: Int, height: Int, as type: UTType = .png) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        // Core Graphics puts y = 0 at the bottom: the top half is the upper one.
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The pixels of `image` as RGBA rows, the first the image's top.
    static func pixels(_ image: CGImage) -> (width: Int, height: Int, bytes: [UInt8]) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (width, height, bytes)
    }

    static func pixel(_ pixels: (width: Int, height: Int, bytes: [UInt8]), x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let offset = (y * pixels.width + x) * 4
        return (pixels.bytes[offset], pixels.bytes[offset + 1], pixels.bytes[offset + 2])
    }

    func testACoverIsDrawnUprightAtTheSizeAskedForInItsProportions() throws {
        let book = Self.book(cover: ("cover.png", "image/png", Self.halves(width: 600, height: 900), ""))
        let thumbnail = EPUBThumbnail(publication: try EPUBPublication.open(data: book.archive()),
                                      maximumSize: CGSize(width: 200, height: 200), scale: 2)
        XCTAssertEqual(thumbnail.content, .cover)
        XCTAssertEqual(thumbnail.size.height, 200, accuracy: 0.01)
        XCTAssertEqual(thumbnail.size.width / thumbnail.size.height, 600.0 / 900.0, accuracy: 0.01)
        let image = try XCTUnwrap(thumbnail.image)
        XCTAssertEqual(image.height, 400, "decoded for 200 points at 2 pixels a point")
        let drawn = try XCTUnwrap(thumbnail.makeImage())
        XCTAssertEqual(drawn.height, 400)
        XCTAssertEqual(drawn.width, Int((thumbnail.size.width * 2).rounded()))
        let pixels = Self.pixels(drawn)
        let top = Self.pixel(pixels, x: pixels.width / 2, y: 10), bottom = Self.pixel(pixels, x: pixels.width / 2, y: pixels.height - 10)
        XCTAssertGreaterThan(top.r, 200, "the top is red: \(top)")
        XCTAssertLessThan(top.b, 60, "the top is red: \(top)")
        XCTAssertGreaterThan(bottom.b, 200, "the bottom is blue: \(bottom)")
        XCTAssertLessThan(bottom.r, 60, "the bottom is blue: \(bottom)")
    }

    func testALargeCoverIsDecodedToNoMorePixelsThanTheThumbnailHas() throws {
        let book = Self.book(cover: ("cover.jpg", "image/jpeg", Self.halves(width: 3_000, height: 4_500, as: .jpeg), ""))
        let publication = try EPUBPublication.open(data: book.archive())
        let small = EPUBThumbnail(publication: publication, maximumSize: CGSize(width: 64, height: 96), scale: 1)
        let image = try XCTUnwrap(small.image)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 96)
        // However much is asked for, no more than the most a thumbnail has.
        let large = EPUBThumbnail(publication: publication, maximumSize: CGSize(width: 10_000, height: 10_000), scale: 4)
        let largeImage = try XCTUnwrap(large.image)
        XCTAssertLessThanOrEqual(max(largeImage.width, largeImage.height), EPUBThumbnail.maximumPixelSize)
        XCTAssertEqual(large.content, .cover)
    }

    func testABookWithoutACoverHasATitlePageOfItsTitleAndAuthors() throws {
        let book = Self.book(metadata: "<dc:title>A Title Page Book</dc:title>\n<dc:creator>First Author</dc:creator>\n<dc:creator>Second Author</dc:creator>\n<dc:language>en</dc:language>")
        let thumbnail = EPUBThumbnail(publication: try EPUBPublication.open(data: book.archive()),
                                      maximumSize: CGSize(width: 300, height: 300), scale: 2)
        XCTAssertEqual(thumbnail.content, .titlePage)
        XCTAssertNil(thumbnail.image)
        XCTAssertEqual(thumbnail.title, "A Title Page Book")
        XCTAssertEqual(thumbnail.authors, ["First Author", "Second Author"])
        XCTAssertEqual(thumbnail.size.height, 300, accuracy: 0.01)
        XCTAssertEqual(thumbnail.size.width, 200, accuracy: 0.01)
        let pixels = Self.pixels(try XCTUnwrap(thumbnail.makeImage()))
        XCTAssertEqual(pixels.width, 400)
        XCTAssertEqual(pixels.height, 600)
        // Paper at the corner, and ink in the middle band, where the words are.
        let corner = Self.pixel(pixels, x: 4, y: 4)
        XCTAssertGreaterThan(corner.r, 230)
        var ink = 0
        for y in stride(from: pixels.height / 4, to: pixels.height * 3 / 4, by: 2) {
            for x in stride(from: pixels.width / 5, to: pixels.width * 4 / 5, by: 2) where Self.pixel(pixels, x: x, y: y).r < 120 { ink += 1 }
        }
        XCTAssertGreaterThan(ink, 200, "the title and authors are drawn")
    }

    func testACoverThatCannotBeDrawnGivesTheTitlePage() throws {
        let book = Self.book(cover: ("cover.png", "image/png", Data("not a picture at all".utf8), ""))
        let thumbnail = EPUBThumbnail(publication: try EPUBPublication.open(data: book.archive()),
                                      maximumSize: CGSize(width: 120, height: 120))
        XCTAssertEqual(thumbnail.content, .titlePage)
        XCTAssertNotNil(thumbnail.makeImage())
    }

    func testACoverIsFoundInItsManifestFallbackChain() throws {
        let book = Self.book(cover: ("cover.heif", "image/x-unreadable", Data("no image ImageIO reads".utf8), "fallback=\"cover-png\""),
                             extra: "\n    <item id=\"cover-png\" href=\"cover.png\" media-type=\"image/png\"/>",
                             files: ["cover.png": Self.halves(width: 100, height: 160)])
        let thumbnail = EPUBThumbnail(publication: try EPUBPublication.open(data: book.archive()),
                                      maximumSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(thumbnail.content, .cover)
        XCTAssertEqual(thumbnail.size.width / thumbnail.size.height, 100.0 / 160.0, accuracy: 0.02)
    }

    func testAnSVGCoverIsDrawn() throws {
        let svg = Data(Fixture.SpecBook.svg(width: 300, height: 450).utf8)
        let book = Self.book(cover: ("cover.svg", "image/svg+xml", svg, ""))
        let thumbnail = EPUBThumbnail(publication: try EPUBPublication.open(data: book.archive()),
                                      maximumSize: CGSize(width: 100, height: 100), scale: 2)
        XCTAssertEqual(thumbnail.content, .cover)
        XCTAssertEqual(thumbnail.size.width / thumbnail.size.height, 300.0 / 450.0, accuracy: 0.02)
        let pixels = Self.pixels(try XCTUnwrap(thumbnail.makeImage()))
        // The drawing's blue ground, #336699, at its corner.
        let corner = Self.pixel(pixels, x: 3, y: 3)
        XCTAssertEqual(Int(corner.b), 0x99, accuracy: 12)
        XCTAssertEqual(Int(corner.r), 0x33, accuracy: 12)
    }

    func testAThumbnailReadsTheCoverAndNothingElseOfTheBook() throws {
        // Chapters and pictures far larger than the cover, none of which a thumbnail needs.
        let filler = Data(String(repeating: "<p>Text the thumbnail never reads.</p>", count: 20_000).utf8)
        var book = Self.book(cover: ("cover.png", "image/png", Self.halves(width: 60, height: 90), ""))
        book.add(href: "long.xhtml", id: "long", mediaType: "application/xhtml+xml",
                 Data(Fixture.SpecBook.xhtml(body: String(decoding: filler, as: UTF8.self)).utf8))
        book.resource("picture.png", id: "picture", mediaType: "image/png", Fixture.SpecBook.image(width: 2_000, height: 2_000))
        let data = try book.archive()
        let whole = try EPUBPublication.open(data: data)
        let publication = try EPUBPublication.open(data: data, onDemand: true)
        let described = publication.expandedBytesRead
        let thumbnail = EPUBThumbnail(publication: publication, maximumSize: CGSize(width: 64, height: 64))
        XCTAssertEqual(thumbnail.content, .cover)
        let cover = try whole.data(at: "EPUB/cover.png").count
        XCTAssertEqual(publication.expandedBytesRead, described + cover)
        XCTAssertLessThan(publication.expandedBytesRead * 10, whole.expandedBytesRead)
    }

    func testAThumbnailOfAFileIsHeldToTheLimitsGiven() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.epub")
        let data = try Self.book(cover: ("cover.png", "image/png", Self.halves(width: 60, height: 90), "")).archive()
        try data.write(to: url)
        let thumbnail = try EPUBThumbnail(contentsOf: url, maximumSize: CGSize(width: 64, height: 64))
        XCTAssertEqual(thumbnail.content, .cover)
        var limits = EPUBImportLimits.quickLook
        limits.archiveBytes = data.count - 1
        XCTAssertThrowsError(try EPUBThumbnail(contentsOf: url, maximumSize: CGSize(width: 64, height: 64), limits: limits)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded("import limits"))
        }
    }

    func testSizesThatCannotBeDrawnAtGiveAThumbnailAllTheSame() throws {
        let publication = try EPUBPublication.open(data: Self.book().archive())
        for size in [CGSize.zero, CGSize(width: -5, height: 40), CGSize(width: CGFloat.nan, height: .infinity)] {
            let thumbnail = EPUBThumbnail(publication: publication, maximumSize: size, scale: .nan)
            XCTAssertGreaterThanOrEqual(thumbnail.size.width, 1, "\(size)")
            XCTAssertGreaterThanOrEqual(thumbnail.size.height, 1, "\(size)")
            XCTAssertNotNil(thumbnail.makeImage(), "\(size)")
        }
    }

    func testTheQuickLookLimitsAreBelowAnApp() {
        let quickLook = EPUBImportLimits.quickLook, app = EPUBImportLimits()
        XCTAssertEqual(quickLook.archiveBytes, 32 * 1024 * 1024)
        XCTAssertLessThan(quickLook.archiveBytes, app.archiveBytes)
        XCTAssertLessThan(quickLook.resourceBytes, app.resourceBytes)
        XCTAssertLessThan(quickLook.expandedBytes, app.expandedBytes)
        XCTAssertEqual(quickLook.xmlBytes, app.xmlBytes)
        XCTAssertEqual(quickLook.entryCount, app.entryCount)
    }
}
