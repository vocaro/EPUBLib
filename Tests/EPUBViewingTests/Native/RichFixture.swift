import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A one-section book around inline XHTML, and a `RichContentContext` for its elements with
/// deterministic styles: the skeleton resolver's, then per-`id` overrides from the test.
final class RichFixture {
    let publication: EPUBPublication
    let document: ContentDocument
    let resolver: StyleResolver
    let fonts: FontRegistry
    let typography: NativeTypography
    let report = SectionReportBox()
    var overrides: [String: (inout ComputedStyle) -> Void] = [:]
    let factory: NativeRichContent

    init(_ body: String, files: [String: Data] = [:], typography: NativeTypography = .init(fontSize: 16),
         cache: ReaderImageCache = ReaderImageCache(budget: 64 << 20)) throws {
        var all = try Fixture.files()
        all["OPS/one.xhtml"] = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Rich</title></head><body>\(body)</body></html>
        """.utf8)
        for (name, data) in files { all["OPS/" + name] = data }
        publication = try EPUBPublication.open(data: Fixture.archive(all))
        document = try ContentDocument.parse(publication.data(at: "OPS/one.xhtml"), path: "OPS/one.xhtml")
        self.typography = typography
        resolver = StyleResolver(document: document, stylesheets: [], typography: typography)
        fonts = FontRegistry(publication: publication)
        factory = NativeRichContent(images: cache)
    }

    func element(_ id: String) -> ContentNode { document.element(id: id)! }
    func first(_ name: String) -> ContentNode { document.nodes.first { $0.isElement && $0.name == name }! }

    func style(for element: ContentNode, parent: ComputedStyle) -> ComputedStyle {
        var style = resolver.style(for: element, parent: parent)
        if let id = element.id, let override = overrides[id] { override(&style) }
        return style
    }

    /// The computed style of `element`, cascading from the root.
    func style(of element: ContentNode) -> ComputedStyle {
        var chain: [ContentNode] = []
        var node: ContentNode? = element
        while let current = node { chain.insert(current, at: 0); node = current.parent }
        var style = resolver.initialStyle
        for node in chain { style = self.style(for: node, parent: style) }
        return style
    }

    /// Renders content as plain text in its style's font, images and tables through the factory.
    func render(_ element: ContentNode, _ style: ComputedStyle) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for child in element.children {
            if child.isText {
                let text = child.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                output.append(NSAttributedString(string: text, attributes: [.font: fonts.font(for: style)]))
                continue
            }
            let childStyle = self.style(for: child, parent: style)
            if child.isHTML("img"), let image = factory.image(child, style: childStyle, context: context) { output.append(image) }
            else if child.isHTML("table"), let table = factory.table(child, style: childStyle, context: context) { output.append(table) }
            else if child.isHTML("br") { output.append(NSAttributedString(string: "\u{2028}")) }
            else { output.append(render(child, childStyle)) }
        }
        return output
    }

    var context: RichContentContext {
        RichContentContext(
            publication: publication, document: document, spineIndex: 0, typography: typography, fonts: fonts,
            style: { [unowned self] in self.style(for: $0, parent: $1) },
            renderContent: { [unowned self] in self.render($0, $1) },
            resolve: { [document, report] reference in
                guard let resolved = try? ResourceReference.resolve(reference, relativeTo: document.path) else {
                    report.report.remoteResourcesRefused += 1
                    return nil
                }
                let path = String(resolved.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
                return path.removingPercentEncoding ?? path
            },
            report: report)
    }

    func image(_ id: String) -> NSAttributedString? {
        let element = element(id)
        return factory.image(element, style: style(of: element), context: context)
    }
    func svg(_ id: String) -> NSAttributedString? {
        let element = element(id)
        return factory.svg(element, style: style(of: element), context: context)
    }
    func table(_ id: String) -> NSAttributedString? {
        let element = element(id)
        return factory.table(element, style: style(of: element), context: context)
    }

    static func attachments(in text: NSAttributedString?) -> [NSTextAttachment] {
        guard let text else { return [] }
        var found: [NSTextAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { found.append(attachment) }
        }
        return found
    }

    /// A solid PNG (or JPEG with an EXIF orientation) of the given pixel size.
    static func image(width: Int, height: Int, jpegOrientation: Int? = nil) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let type = jpegOrientation == nil ? UTType.png : UTType.jpeg
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        let properties = jpegOrientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// A line for sizing attachments outside a text view.
func line(_ width: CGFloat, viewport: CGSize = CGSize(width: 400, height: 600), font: PlatformFont? = nil,
          position: CGFloat = 0) -> ReaderAttachment.Line {
    ReaderAttachment.Line(width: width, position: position, viewport: viewport, font: font)
}
