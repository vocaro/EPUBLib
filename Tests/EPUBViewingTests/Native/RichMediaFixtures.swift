import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A two-chapter book whose first spine item, manifest and archive files a test chooses, built
/// through the production `SectionBuilder` and `NativeRichContent` as the reader builds it.
struct RichMediaBook {
    let publication: EPUBPublication
    let cache: ReaderImageCache

    static let xhtmlType = "application/xhtml+xml"

    static func xhtml(_ body: String, head: String = "", root: String = "") -> String {
        """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" \(root)><head><title>Rich media</title>\(head)</head><body>\(body)</body></html>
        """
    }

    /// `files` are archive paths under `OPS/`, or from the archive's root when they begin with `/`. `manifest` is extra `<item>` markup. `first` replaces
    /// the first spine item's manifest entry (its href and media type) when the section is not XHTML.
    init(section: String, files: [String: Data] = [:], manifest: String = "",
         first: (href: String, mediaType: String)? = nil, cache: ReaderImageCache = ReaderImageCache(budget: 64 << 20)) throws {
        var all = try Fixture.files()
        var package = String(decoding: try XCTUnwrap(all["OPS/book.opf"]), as: UTF8.self)
        if let first {
            package = package.replacingOccurrences(of: "<item id=\"one\" href=\"one.xhtml\" media-type=\"application/xhtml+xml\"/>",
                                                   with: "<item id=\"one\" href=\"\(first.href)\" media-type=\"\(first.mediaType)\"/>")
            all["OPS/one.xhtml"] = nil
            all["OPS/" + first.href] = Data(section.utf8)
        } else {
            all["OPS/one.xhtml"] = Data(section.utf8)
        }
        package = package.replacingOccurrences(of: "</manifest>", with: manifest + "</manifest>")
        all["OPS/book.opf"] = Data(package.utf8)
        for (name, data) in files { all[name.hasPrefix("/") ? String(name.dropFirst()) : "OPS/" + name] = data }
        publication = try EPUBPublication.open(data: Fixture.archive(all))
        self.cache = cache
    }

    init(body: String, files: [String: Data] = [:], manifest: String = "", head: String = "",
         cache: ReaderImageCache = ReaderImageCache(budget: 64 << 20)) throws {
        try self.init(section: Self.xhtml(body, head: head), files: files, manifest: manifest, cache: cache)
    }

    func build(_ spineIndex: Int = 0, fontSize: CGFloat = 16, dark: Bool = false) -> SectionText {
        SectionBuilder.build(.init(publication: publication, spineIndex: spineIndex,
                                   typography: NativeTypography(fontSize: fontSize, isDark: dark),
                                   fonts: FontRegistry(publication: publication), rich: NativeRichContent(images: cache)))
    }
}

extension SectionText {
    /// Every attachment of the section's text with its character offset, in reading order.
    var richMediaAttachments: [(attachment: NSTextAttachment, location: Int)] {
        var found: [(NSTextAttachment, Int)] = []
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment { found.append((attachment, range.location)) }
        }
        return found
    }
    var richMediaImages: [ReaderImageAttachment] { richMediaAttachments.compactMap { $0.attachment as? ReaderImageAttachment } }
    var richMediaFormulas: [MathAttachment] { richMediaAttachments.compactMap { $0.attachment as? MathAttachment } }
    /// The section's characters with each attachment shown as `￼`.
    var richMediaPlain: String { string.string }
}

/// Image bytes made in code: bitmaps through CoreGraphics and ImageIO, and PNG files written chunk
/// by chunk for the shapes ImageIO does not write on request (palettes, interlace, headers that
/// declare more pixels than they hold).
enum RichMediaImages {
    typealias Draw = (CGContext, CGRect) -> Void

    static func bitmap(width: Int, height: Int, draw: Draw) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context, CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func encode(_ images: [CGImage], as type: UTType, properties: [CFString: Any] = [:]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil) else { return nil }
        for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func png(width: Int, height: Int, draw: Draw) -> Data {
        encode([bitmap(width: width, height: height, draw: draw)], as: .png)!
    }

    /// An opaque PNG of one colour.
    static func solid(width: Int, height: Int, red: CGFloat = 0.2, green: CGFloat = 0.4, blue: CGFloat = 0.8) -> Data {
        png(width: width, height: height) { context, rect in
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(rect)
        }
    }

    /// A blue picture whose top-left quarter is red, so a decode shows which way up it came out.
    static func cornerMarked(width: Int, height: Int) -> CGImage {
        bitmap(width: width, height: height) { context, rect in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(rect)
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: rect.height / 2, width: rect.width / 2, height: rect.height / 2))
        }
    }

    /// The straight RGBA of a pixel, top-left origin.
    static func rgba(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(image.height - 1 - y),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let alpha = Int(data[3])
        guard alpha > 0 else { return [0, 0, 0, 0] }
        return (0..<3).map { UInt8(min(255, (Int(data[$0]) * 255 + alpha / 2) / alpha)) } + [UInt8(alpha)]
    }

    // MARK: PNG by hand

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    private static func crc(_ bytes: [UInt8]) -> UInt32 {
        ~bytes.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    private static func big(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }

    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let tagged = Array(type.utf8) + body
        return big(UInt32(body.count)) + tagged + big(crc(tagged))
    }

    /// A zlib stream of stored (uncompressed) blocks.
    private static func stored(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let count = min(65_535, bytes.count - offset)
            let last: UInt8 = offset + count == bytes.count ? 1 : 0
            output += [last, UInt8(count & 255), UInt8(count >> 8), UInt8(~count & 255), UInt8((~count >> 8) & 255)]
            output += bytes[offset..<(offset + count)]
            offset += count
        } while offset < bytes.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
        return output + big(b << 16 | a)
    }

    /// A PNG file from its header fields and the scanlines as they are stored (each led by its
    /// filter byte). `scanlines` nil leaves the image data out: a header that promises pixels the
    /// file does not hold.
    static func png(width: Int, height: Int, bitDepth: UInt8, colorType: UInt8, interlace: UInt8 = 0,
                    palette: [UInt8]? = nil, transparency: [UInt8]? = nil, scanlines: [UInt8]?) -> Data {
        var file: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        file += chunk("IHDR", big(UInt32(width)) + big(UInt32(height)) + [bitDepth, colorType, 0, 0, interlace])
        if let palette { file += chunk("PLTE", palette) }
        if let transparency { file += chunk("tRNS", transparency) }
        file += chunk("IDAT", stored(scanlines ?? [0]))
        file += chunk("IEND", [])
        return Data(file)
    }

    /// A PNG whose header declares `width` × `height` and whose data is one byte.
    static func headerOnlyPNG(width: Int, height: Int) -> Data {
        png(width: width, height: height, bitDepth: 8, colorType: 2, scanlines: nil)
    }
}
