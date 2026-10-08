import CoreGraphics
import EPUBCore
import EPUBReading
import Foundation

/// SVG for the rich-content factory. An SVG that only wraps one `<image>` (every cover and
/// title page in the catalog) is shown as that image with the SVG's sizing. Any other SVG is
/// serialized, sanitized, for the platform image decoder: scripts, foreign content and every
/// reference outside the document are removed, and archive images it uses are inlined, so the
/// decoder can never reach anything but the bytes given to it.
enum SVGContent {
    /// Bytes of serialized SVG the decoder is given at most.
    static let maximumBytes = 4 * 1024 * 1024
    /// Bytes of archive images inlined into one SVG at most.
    static let maximumInlinedImageBytes = 8 * 1024 * 1024

    private static let graphics: Set<String> = ["rect", "circle", "ellipse", "line", "polyline", "polygon", "path",
                                                "text", "use", "image", "foreignObject", "switch"]
    /// Content that is never drawn where it stands.
    private static let unrendered: Set<String> = ["defs", "title", "desc", "metadata", "style", "script", "symbol",
                                                  "clipPath", "mask", "pattern", "linearGradient", "radialGradient",
                                                  "filter", "marker"]
    private static let dropped: Set<String> = ["script", "foreignObject", "iframe", "video", "audio", "handler", "listener"]

    static func isSVG(_ node: ContentNode, root: ContentNode) -> Bool {
        node.isElement && (node.namespace == ContentNamespace.svg || (node.namespace.isEmpty && root.namespace.isEmpty))
    }

    /// The one `<image>` an SVG draws, when it draws nothing else.
    static func wrappedImage(_ svg: ContentNode) -> ContentNode? {
        var found: [ContentNode] = []
        func visit(_ node: ContentNode) {
            for child in node.children where isSVG(child, root: svg) && found.count < 2 {
                if unrendered.contains(child.name) { continue }
                if graphics.contains(child.name) { found.append(child) } else { visit(child) }
            }
        }
        visit(svg)
        return found.count == 1 && found[0].name == "image" ? found[0] : nil
    }

    static func href(_ element: ContentNode) -> String? {
        (element.attribute("href", namespace: ContentNamespace.xlink) ?? element.attribute("href"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func viewBox(_ svg: ContentNode) -> CGRect? {
        let numbers = (svg.attribute("viewBox") ?? "").split { $0 == " " || $0 == "," || $0.isNewline || $0 == "\t" }
            .compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0, numbers.allSatisfy(\.isFinite) else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// The SVG's own `<title>`, whitespace-normalized.
    static func title(_ svg: ContentNode) -> String? {
        let title = svg.elementChildren.first { $0.name == "title" }?.textContent
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return title?.isEmpty == false ? title : nil
    }

    /// The intrinsic size of an SVG box in points: absolute `width`/`height` attributes, with
    /// the viewBox's aspect fitted inside them; else the viewBox; else `fallback`.
    static func intrinsicSize(_ svg: ContentNode, fontSize: CGFloat, fallback: CGSize) -> CGSize {
        func absolute(_ name: String) -> CGFloat? {
            if case .points(let value)? = ImageSizing.length(svg.attribute(name), fontSize: fontSize), value > 0 { value } else { nil }
        }
        let box = viewBox(svg)
        let aspect = box.map { $0.width / $0.height } ?? (fallback.height > 0 ? fallback.width / fallback.height : 1)
        switch (absolute("width"), absolute("height")) {
        case let (w?, h?): return w / h > aspect ? CGSize(width: h * aspect, height: h) : CGSize(width: w, height: w / aspect)
        case let (w?, nil): return CGSize(width: w, height: w / aspect)
        case let (nil, h?): return CGSize(width: h * aspect, height: h)
        case (nil, nil): return box?.size ?? fallback
        }
    }

    /// Where a wrapped `<image>` sits in its SVG, as fractions of the SVG's box; nil when it
    /// fills it.
    static func placement(of image: ContentNode, in svg: ContentNode, imageSize: CGSize, fontSize: CGFloat) -> CGRect? {
        func number(_ name: String) -> CGFloat? {
            if case .points(let value)? = ImageSizing.length(image.attribute(name), fontSize: fontSize) { value } else { nil }
        }
        let box = viewBox(svg) ?? CGRect(origin: .zero, size: intrinsicSize(svg, fontSize: fontSize, fallback: imageSize))
        let width = number("width").flatMap { $0 > 0 ? $0 : nil } ?? (viewBox(svg) == nil ? box.width : imageSize.width)
        let height = number("height").flatMap { $0 > 0 ? $0 : nil } ?? (viewBox(svg) == nil ? box.height : imageSize.height)
        let rect = CGRect(x: ((number("x") ?? 0) - box.minX) / box.width, y: ((number("y") ?? 0) - box.minY) / box.height,
                          width: width / box.width, height: height / box.height)
        let filled = abs(rect.minX) < 0.001 && abs(rect.minY) < 0.001 && abs(rect.width - 1) < 0.001 && abs(rect.height - 1) < 0.001
        return filled || !rect.width.isFinite || !rect.height.isFinite ? nil : rect
    }

    /// The SVG subtree as a standalone, sanitized document. `resolve` maps a reference to an
    /// archive path; nil for anything that cannot be used.
    static func serialize(_ svg: ContentNode, resolve: (String) -> String?, publication: EPUBPublication) -> Data? {
        var output = ""
        var inlined = 0
        var overflow = false
        func escape(_ value: String, attribute: Bool) -> String {
            var result = ""
            result.reserveCapacity(value.utf8.count)
            for character in value.unicodeScalars {
                switch character {
                case "&": result += "&amp;"
                case "<": result += "&lt;"
                case ">": result += "&gt;"
                case "\"" where attribute: result += "&quot;"
                case "\n" where attribute: result += "&#10;"
                default: result.unicodeScalars.append(character)
                }
            }
            return result
        }
        func write(_ text: String) {
            output += text
            if output.utf8.count > maximumBytes { overflow = true }
        }
        func emit(_ node: ContentNode, isRoot: Bool) {
            guard !overflow else { return }
            if node.isText { write(escape(node.text, attribute: false)); return }
            guard isSVG(node, root: svg), !dropped.contains(node.name) else { return }
            if node.name == "style", unsafeCSS(node.textContent) || node.textContent.lowercased().contains("@import") { return }
            write("<" + node.name)
            if isRoot { write(" xmlns=\"\(ContentNamespace.svg)\" xmlns:xlink=\"\(ContentNamespace.xlink)\"") }
            for attribute in node.attributes {
                let name: String
                switch attribute.namespace {
                case "":
                    // A prefix no ancestor declares stays in the name (`xlink:href`); written out
                    // under the root's declarations it would become a live reference.
                    guard !attribute.name.contains(":") else { continue }
                    name = attribute.name
                case ContentNamespace.xlink: name = "xlink:" + attribute.name
                case ContentNamespace.xml: name = "xml:" + attribute.name
                default: continue
                }
                let local = attribute.name.lowercased()
                guard name != "xmlns", !name.hasPrefix("xmlns:"), !local.hasPrefix("on"), local != "base" else { continue }
                var value = attribute.value
                if local == "href" || local == "src" {
                    let reference = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !reference.hasPrefix("#") {
                        guard node.name == "image", let path = resolve(reference),
                              let data = try? publication.data(at: path),
                              inlined + data.count <= maximumInlinedImageBytes,
                              let type = ImageType.mediaType(of: data) else { continue }
                        inlined += data.count
                        value = "data:\(type);base64," + data.base64EncodedString()
                    }
                } else if unsafeCSS(value) { continue }
                write(" \(name)=\"\(escape(value, attribute: true))\"")
            }
            if node.children.isEmpty { write("/>"); return }
            write(">")
            for child in node.children { emit(child, isRoot: false) }
            write("</\(node.name)>")
        }
        emit(svg, isRoot: true)
        return overflow ? nil : Data(output.utf8)
    }

    /// Whether CSS in `value` might reach outside the document: a `url()` to anything but a
    /// fragment, or any escape, which could spell one (`u\72l(`) past a textual check.
    static func unsafeCSS(_ value: String) -> Bool {
        value.contains("\\") || referencesOutside(value)
    }

    /// Whether CSS in `value` points anywhere but into the document (`url(#…)`).
    static func referencesOutside(_ value: String) -> Bool {
        var rest = Substring(value.lowercased())
        while let range = rest.range(of: "url(") {
            let target = rest[range.upperBound...].drop { $0 == " " || $0 == "\"" || $0 == "'" }
            if !target.hasPrefix("#") { return true }
            rest = rest[range.upperBound...]
        }
        return false
    }
}

enum ImageType {
    /// The media type of image data, for a `data:` URI; nil when ImageIO cannot read it.
    static func mediaType(of data: Data) -> String? {
        let prefix = [UInt8](data.prefix(12))
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if prefix.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if prefix.count >= 12, prefix[0..<4].elementsEqual(Array("RIFF".utf8)), prefix[8..<12].elementsEqual(Array("WEBP".utf8)) {
            return "image/webp"
        }
        return nil
    }

    /// Whether a resource is SVG, by media type, extension, or its first bytes.
    static func isSVG(_ data: Data, path: String, mediaType: String?) -> Bool {
        if mediaType?.lowercased() == "image/svg+xml" { return true }
        let lowered = path.lowercased()
        if lowered.hasSuffix(".svg") || lowered.hasSuffix(".svgz") { return true }
        guard mediaType == nil || mediaType?.hasPrefix("image/") == true, ImageType.mediaType(of: data) == nil else { return false }
        let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        return head.contains("<svg")
    }
}
