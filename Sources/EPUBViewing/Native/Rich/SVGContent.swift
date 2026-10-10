import CoreGraphics
import EPUBCore
import EPUBReading
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// SVG for the rich-content factory. An SVG that only wraps one `<image>` (every cover and
/// title page in the catalog) is shown as that image with the SVG's sizing. Any other SVG is
/// serialized, sanitized, for the bundled static renderer: scripts, foreign content and every
/// reference outside the document are removed, and archive images it uses are inlined, so the
/// decoder can never reach anything but the bytes given to it.
enum SVGContent {
    /// Bytes of serialized SVG the decoder is given at most.
    static let maximumBytes = 4 * 1024 * 1024
    /// Bytes of archive images inlined into one SVG at most.
    static let maximumInlinedImageBytes = 8 * 1024 * 1024
    static let maximumNodes = 10_000
    static let maximumDepth = 64
    static let maximumExpandedBytes = 8 * 1024 * 1024
    static let maximumImagePixels = 4 * 1024 * 1024
    static let maximumTotalImagePixels = 16 * 1024 * 1024

    private static let graphics: Set<String> = ["rect", "circle", "ellipse", "line", "polyline", "polygon", "path",
                                                "text", "use", "image", "foreignObject", "switch"]
    /// Content that is never drawn where it stands.
    private static let unrendered: Set<String> = ["defs", "title", "desc", "metadata", "style", "script", "symbol",
                                                  "clipPath", "mask", "pattern", "linearGradient", "radialGradient",
                                                  "filter", "marker"]
    private static let dropped: Set<String> = ["script", "foreignObject", "iframe", "video", "audio", "handler", "listener",
                                                "animate", "animateMotion", "animateTransform", "set"]

    static func isSVG(_ node: ContentNode, root: ContentNode) -> Bool {
        node.isElement && (node.namespace == ContentNamespace.svg || (node.namespace.isEmpty && root.namespace.isEmpty))
    }

    /// The one `<image>` an SVG draws, when it draws nothing else.
    static func wrappedImage(_ svg: ContentNode) -> ContentNode? {
        func hasStyle(_ node: ContentNode) -> Bool { node.name == "style" || node.children.contains(where: hasStyle) }
        guard !hasStyle(svg) else { return nil }
        var found: [ContentNode] = []
        var requiresRenderer = false
        func visit(_ node: ContentNode) {
            if node.attribute("transform") != nil || node.attribute("clip-path") != nil || node.attribute("mask") != nil ||
                node.attribute("opacity") != nil || node.attribute("filter") != nil || node.attribute("style") != nil {
                requiresRenderer = true
            }
            for child in node.children where isSVG(child, root: svg) && found.count < 2 {
                if child.name == "style" { requiresRenderer = true }
                if unrendered.contains(child.name) { continue }
                if graphics.contains(child.name) { found.append(child); visit(child) } else { visit(child) }
            }
        }
        visit(svg)
        return !requiresRenderer && found.count == 1 && found[0].name == "image" ? found[0] : nil
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

    static func accessibleLabel(_ svg: ContentNode) -> String? {
        let parts = ["title", "desc"].compactMap { name -> String? in
            let value = svg.elementChildren.first { $0.name == name }?.textContent.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return value?.isEmpty == false ? value : nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    static func fallbackText(_ svg: ContentNode) -> String {
        if let label = accessibleLabel(svg) { return label }
        var text: [String] = []
        func visit(_ node: ContentNode) {
            if node.name == "text" { text.append(node.textContent); return }
            for child in node.elementChildren where !dropped.contains(child.name) { visit(child) }
        }
        visit(svg)
        let result = text.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return result.isEmpty ? "Illustration unavailable" : result
    }

    static func unsupportedConstructs(_ svg: ContentNode) -> Set<String> {
        var result = Set<String>()
        func visit(_ node: ContentNode) {
            if dropped.contains(node.name) { result.insert("svg:" + node.name); return }
            if node.name == "pattern" { result.insert("svg:pattern") }
            if node.name == "filter" || node.attribute("filter") != nil ||
                node.attribute("style")?.range(of: "(?i)filter\\s*:", options: .regularExpression) != nil ||
                (node.name == "style" && node.textContent.range(of: "(?i)filter\\s*:", options: .regularExpression) != nil) {
                result.insert("svg:filter")
            }
            for child in node.elementChildren { visit(child) }
        }
        visit(svg)
        return result
    }

    /// Refuse expansion bombs before handing them to the renderer, including references in
    /// definitions. Cost follows `<use>` targets and is memoized without expanding a tree.
    static func isWithinRenderingLimits(_ svg: ContentNode) -> Bool {
        var nodes: [ContentNode] = []
        var ids: [String: ContentNode] = [:]
        var valid = true
        func collect(_ node: ContentNode, depth: Int) {
            guard valid, depth <= maximumDepth, nodes.count < maximumNodes else { valid = false; return }
            nodes.append(node)
            if let id = node.id, ids[id] == nil { ids[id] = node }
            for child in node.children { collect(child, depth: depth + 1) }
        }
        collect(svg, depth: 0)
        guard valid, unsupportedConstructs(svg).isDisjoint(with: ["svg:filter", "svg:pattern"]) else { return false }
        var costs: [ObjectIdentifier: Int] = [:]
        var active = Set<ObjectIdentifier>()
        func cost(_ node: ContentNode, depth: Int) -> Int? {
            guard depth <= maximumDepth else { return nil }
            let key = ObjectIdentifier(node)
            if let cached = costs[key] { return cached }
            guard active.insert(key).inserted else { return nil }
            defer { active.remove(key) }
            var total = 32 + node.text.utf8.count + node.attributes.reduce(0) { $0 + $1.value.utf8.count + $1.name.utf8.count }
            if node.name == "use", let href = href(node), href.hasPrefix("#"), let target = ids[String(href.dropFirst())] {
                guard let targetCost = cost(target, depth: depth + 1) else { return nil }
                total += targetCost
            }
            for child in node.children {
                guard let childCost = cost(child, depth: depth + 1), childCost <= maximumExpandedBytes - total else { return nil }
                total += childCost
            }
            guard total <= maximumExpandedBytes else { return nil }
            costs[key] = total
            return total
        }
        return cost(svg, depth: 0) != nil
    }

    /// The direct renderer entry point is also used by tests and inspection. Validate data
    /// image headers before Rust can decode them; arbitrary strings are denied by its resolver.
    static func preparedImagesAreBounded(_ svg: ContentNode) -> Bool {
        var pixels = 0
        var bytes = 0
        func visit(_ node: ContentNode) -> Bool {
            if node.name == "image", let reference = href(node), reference.hasPrefix("data:") {
                guard let comma = reference.firstIndex(of: ","),
                      ["data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64", "data:image/webp;base64"].contains(String(reference[..<comma])),
                      let data = Data(base64Encoded: String(reference[reference.index(after: comma)...])),
                      data.count <= maximumInlinedImageBytes - bytes,
                      let source = ReaderImageSource.bitmap(data, path: "", key: "svg-preflight"),
                      source.pixelSize.width * source.pixelSize.height <= CGFloat(maximumImagePixels) else { return false }
                let count = Int(source.pixelSize.width * source.pixelSize.height)
                guard count <= maximumTotalImagePixels - pixels else { return false }
                pixels += count; bytes += data.count
            }
            return node.children.allSatisfy(visit)
        }
        return visit(svg)
    }

    /// resvg's temporary isolated layers can cover 25 times the output canvas. Account for
    /// every potentially isolated group before choosing a raster size, keeping their combined
    /// worst-case RGBA plus clip/mask alpha storage under 96 MiB. Plain paths/shapes still
    /// use the 4096-pixel ceiling.
    static func isolatedLayers(_ svg: ContentNode) -> Int {
        var ids: [String: ContentNode] = [:]
        var styledLayers = false
        func collect(_ node: ContentNode) {
            if let id = node.id, ids[id] == nil { ids[id] = node }
            if node.name == "style", node.textContent.range(of: "(?i)(opacity|clip-path|mask|mix-blend-mode|isolation)\\s*:", options: .regularExpression) != nil { styledLayers = true }
            for child in node.elementChildren { collect(child) }
        }
        collect(svg)
        var cache: [ObjectIdentifier: Int] = [:]
        func count(_ node: ContentNode) -> Int {
            let key = ObjectIdentifier(node)
            if let cached = cache[key] { return cached }
            let isolates = styledLayers || ["clipPath", "mask", "pattern"].contains(node.name) ||
                ["opacity", "clip-path", "mask", "mix-blend-mode", "isolation"].contains(where: { node.attribute($0) != nil }) ||
                node.attribute("style")?.range(of: "(?i)(opacity|clip-path|mask|mix-blend-mode|isolation)\\s*:", options: .regularExpression) != nil
            var result = isolates ? 1 : 0
            for child in node.elementChildren { result += count(child) }
            if node.name == "use", let href = href(node), href.hasPrefix("#"), let target = ids[String(href.dropFirst())] { result += count(target) }
            cache[key] = result
            return result
        }
        return count(svg)
    }

    static func fontFamilies(_ svg: ContentNode) -> Set<String> {
        var result = Set<String>()
        let expression = try! NSRegularExpression(pattern: "(?i)font-family\\s*:\\s*([^;}]+)")
        func add(_ value: String) {
            for name in value.split(separator: ",") {
                let clean = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
                if !clean.isEmpty { result.insert(clean.lowercased()) }
            }
        }
        func visit(_ node: ContentNode) {
            if let family = node.attribute("font-family") { add(family) }
            let css = node.name == "style" ? node.textContent : node.attribute("style") ?? ""
            let string = css as NSString
            for match in expression.matches(in: css, range: NSRange(location: 0, length: string.length)) { add(string.substring(with: match.range(at: 1))) }
            for child in node.elementChildren { visit(child) }
        }
        visit(svg)
        return result
    }

    /// The intrinsic size of an SVG box in points: absolute `width`/`height` attributes, with
    /// the authored viewport preserved; else the viewBox; else `fallback`. The renderer
    /// applies the viewBox's preserveAspectRatio inside this viewport.
    static func intrinsicSize(_ svg: ContentNode, fontSize: CGFloat, fallback: CGSize) -> CGSize {
        func absolute(_ name: String) -> CGFloat? {
            if case .points(let value)? = ImageSizing.length(svg.attribute(name), fontSize: fontSize), value > 0 { value } else { nil }
        }
        let box = viewBox(svg)
        let aspect = box.map { $0.width / $0.height } ?? (fallback.height > 0 ? fallback.width / fallback.height : 1)
        switch (absolute("width"), absolute("height")) {
        case let (w?, h?): return CGSize(width: w, height: h)
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
    static func serialize(_ svg: ContentNode, resolve: (String) -> String?, publication: EPUBPublication,
                          fontAliases: [String: String] = [:], report: SectionReportBox? = nil) -> Data? {
        guard isWithinRenderingLimits(svg) else { return nil }
        var output = ""
        var inlined = 0
        var imagePixels = 0
        var overflow = false
        func family(_ value: String) -> String {
            value.split(separator: ",").map {
                let clean = $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
                return fontAliases[clean.lowercased()].map { "'" + $0 + "'" } ?? String($0)
            }.joined(separator: ",")
        }
        func css(_ value: String) -> String {
            let expression = try! NSRegularExpression(pattern: "(?i)(font-family\\s*:\\s*)([^;}]+)")
            let string = value as NSString
            var result = value
            for match in expression.matches(in: value, range: NSRange(location: 0, length: string.length)).reversed() {
                if let range = Range(match.range(at: 2), in: result) { result.replaceSubrange(range, with: family(string.substring(with: match.range(at: 2)))) }
            }
            return result
        }
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
            if node.isText { write(escape(node.parent?.name == "style" ? css(node.text) : node.text, attribute: false)); return }
            guard isSVG(node, root: svg), !dropped.contains(node.name) else { return }
            if node.name == "style", unsafeCSS(node.textContent) || node.textContent.lowercased().contains("@import") {
                report?.report.unsupportedElements["svg:style", default: 0] += 1
                return
            }
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
                              let original = try? publication.data(at: path),
                              let (data, pixels) = boundedArchiveImage(original),
                              inlined + data.count <= maximumInlinedImageBytes,
                              pixels <= maximumTotalImagePixels - imagePixels else {
                            report?.report.unsupportedElements["svg:image", default: 0] += 1
                            continue
                        }
                        inlined += data.count; imagePixels += pixels
                        value = "data:image/png;base64," + data.base64EncodedString()
                    }
                } else if unsafeCSS(value) {
                    report?.report.unsupportedElements["svg:attribute", default: 0] += 1
                    continue
                }
                if local == "font-family" { value = family(value) }
                if local == "style" { value = css(value) }
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

    private static func boundedArchiveImage(_ data: Data) -> (Data, Int)? {
        guard data.count <= maximumInlinedImageBytes, ImageType.mediaType(of: data) != nil,
              let source = ReaderImageSource.bitmap(data, path: "", key: "svg-inline"),
              source.pixelSize.width * source.pixelSize.height <= CGFloat(maximumTotalImagePixels),
              let image = source.decode(maxPixelSize: 2048), image.width <= maximumImagePixels / image.height else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumInlinedImageBytes else { return nil }
        return (output as Data, image.width * image.height)
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
