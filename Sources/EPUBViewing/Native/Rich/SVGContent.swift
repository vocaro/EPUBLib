import CoreGraphics
import EPUBCore
import EPUBReading
import Foundation
import StaticSVG

/// SVG for the rich-content factory. An SVG that only wraps one `<image>` (every cover and
/// title page in the catalog) is shown as that image with the SVG's sizing. Any other SVG is
/// handed to StaticSVG as its own tree, serialized and sanitized for its bundled static
/// renderer: scripts, foreign content and every reference outside the document are removed, and
/// the images it uses, from the archive or in `data:` URLs, are decoded and inlined, so the
/// decoder can never reach anything but the bytes given to it. StaticSVG reads the archive only
/// through `PublicationSVGResources`.
enum SVGContent {
    /// Content that may be drawn where it stands, for `wrappedImage`.
    private static let graphics: Set<String> = ["rect", "circle", "ellipse", "line", "polyline", "polygon", "path",
                                                "text", "use", "image", "foreignObject", "switch"]
    /// Content that is never drawn where it stands: SVG 2's never-rendered elements (§3.2.1),
    /// among them a `symbol` until a `use` draws it, and `filter` (Filter Effects 1 §7).
    private static let unrendered: Set<String> = ["defs", "title", "desc", "metadata", "style", "script", "symbol",
                                                  "clipPath", "mask", "pattern", "linearGradient", "radialGradient",
                                                  "filter", "marker"]

    static func isSVG(_ node: ContentNode, root: ContentNode) -> Bool {
        node.isElement && (node.namespace == ContentNamespace.svg || (node.namespace.isEmpty && root.namespace.isEmpty))
    }

    /// Whether a drawing has nothing to draw: every element it holds is one SVG never renders,
    /// or one of another namespace, which it leaves out of rendering (SVG 2 §5.10). A sprite
    /// sheet, `<defs>` and `<symbol>`s that other drawings use, is one; a browser draws nothing
    /// for it. A `use` beside them draws, so a drawing that holds one is drawn.
    static func drawsNothing(_ svg: ContentNode) -> Bool {
        svg.children.allSatisfy { !isSVG($0, root: svg) || unrendered.contains($0.name) }
    }

    /// The subtree as StaticSVG's own tree, names, namespaces, attributes and text as they are.
    /// The content document's limits already bound it; StaticSVG's screens apply the drawing's.
    static func document(_ element: ContentNode) -> SVGDocument? {
        var builder = SVGDocument.Builder(limits: .document)
        func add(_ node: ContentNode) throws {
            if node.isText { try builder.appendText(node.text); return }
            try builder.startElement(node.name, namespace: node.namespace, attributes: node.attributes.map {
                SVGAttribute(name: $0.name, namespace: $0.namespace, value: $0.value)
            })
            for child in node.children { try add(child) }
            try builder.endElement()
        }
        do {
            try add(element)
            return try builder.finish()
        } catch {
            return nil
        }
    }

    /// An SVG resource in the archive, or in a `data:` URL, parsed as the reader parses a
    /// content document's markup, named character references included, then given to StaticSVG.
    static func document(_ data: Data, path: String) -> (root: ContentNode, svg: SVGDocument)? {
        guard let parsed = try? ContentDocument.parse(data, path: path, asContent: false),
              parsed.root.name == "svg", isSVG(parsed.root, root: parsed.root),
              let svg = document(parsed.root) else { return nil }
        return (parsed.root, svg)
    }

    /// `svg` serialized by StaticSVG, its diagnostics added to `report`. `resolve` maps a
    /// reference to an archive path; nil for anything that cannot be used. An `<image>` in a
    /// `data:` URL is not given to it: StaticSVG reads it from the URL's own bytes.
    static func serialize(_ svg: SVGDocument, resolve: (String) -> String?, publication: EPUBPublication,
                          fontAliases: [String: String] = [:], report: SectionReportBox? = nil,
                          imagePreparation: SVGImagePreparation? = nil) -> Data? {
        let serialization = svg.serialized(resolve: resolve, resources: PublicationSVGResources(publication: publication),
                                           fontAliases: fontAliases, preparation: imagePreparation)
        if let report { add(serialization.diagnostics, to: report) }
        return serialization.data
    }

    /// `serialize` for an element of a content document.
    static func serialize(_ svg: ContentNode, resolve: (String) -> String?, publication: EPUBPublication,
                          fontAliases: [String: String] = [:], report: SectionReportBox? = nil,
                          imagePreparation: SVGImagePreparation? = nil) -> Data? {
        guard let document = document(svg) else { return nil }
        return serialize(document, resolve: resolve, publication: publication, fontAliases: fontAliases,
                         report: report, imagePreparation: imagePreparation)
    }

    /// Adds StaticSVG's diagnostics to a section's report, under the names the report has
    /// always given them (`svg:image`, `svg:filter`…). A count is capped as StaticSVG caps the
    /// counts it merges, so a drawing that repeats an image through nested drawings cannot
    /// overflow the section's total.
    static func add(_ diagnostics: SVGDiagnostics, to report: SectionReportBox) {
        for (kind, count) in diagnostics.counts {
            let current = report.report.unsupportedElements[kind.rawValue] ?? 0
            let added = min(count, max(0, SVGDiagnostics.maximumMergedCount - current))
            if added > 0 { report.report.unsupportedElements[kind.rawValue] = current + added }
        }
    }

    /// The disclosures for what a drawing holds that is not drawn, or refuses it.
    static func disclose(_ svg: SVGDocument, report: SectionReportBox) {
        for kind in svg.constructs { report.report.unsupportedElements[kind.rawValue, default: 0] += 1 }
    }

    /// The one `<image>` an SVG draws, when it draws nothing else.
    static func wrappedImage(_ svg: ContentNode) -> ContentNode? {
        func hasStyle(_ node: ContentNode) -> Bool { node.name == "style" || node.children.contains(where: hasStyle) }
        guard !hasStyle(svg) else { return nil }
        var found: [ContentNode] = []
        var requiresRenderer = false
        func visit(_ node: ContentNode) {
            // The bitmap attachment implements the default centred meet fit only. Other
            // fits need clipping/stretching, and a nested SVG establishes another viewport.
            if (node.name == "svg" && node !== svg) ||
                node.attribute("preserveAspectRatio").map({
                    let value = $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    return value != "xMidYMid" && value != "xMidYMid meet"
                }) == true {
                requiresRenderer = true
            }
            if node.name == "image", ["width", "height"].contains(where: {
                let value = ImageSizing.length(node.attribute($0), fontSize: 16)
                return value == .points(0) || value == .percent(0)
            }) { requiresRenderer = true }
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
        // SVG 2: an unprefixed `href` takes precedence over `xlink:href`, as the renderer resolves
        // it.
        (element.attribute("href") ?? element.attribute("href", namespace: ContentNamespace.xlink))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func viewBox(_ svg: ContentNode) -> CGRect? {
        let numbers = (svg.attribute("viewBox") ?? "").split { $0 == " " || $0 == "," || $0.isNewline || $0 == "\t" }
            .compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0, numbers.allSatisfy(\.isFinite) else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// The intrinsic size of an SVG box in points: absolute `width`/`height` attributes, with
    /// the authored viewport preserved; else the viewBox; else `fallback`. The renderer
    /// applies the viewBox's preserveAspectRatio inside this viewport. A viewBox so thin that
    /// the dimension its ratio gives overflows sizes nothing: `fallback` stands in.
    /// `SVGDocument.intrinsicSize` gives the same size, which StaticSVG's screens use.
    static func intrinsicSize(_ svg: ContentNode, fontSize: CGFloat, fallback: CGSize) -> CGSize {
        func absolute(_ name: String) -> CGFloat? {
            if case .points(let value)? = ImageSizing.length(svg.attribute(name), fontSize: fontSize), value > 0 { value } else { nil }
        }
        let box = viewBox(svg)
        let aspect = box.map { $0.width / $0.height } ?? (fallback.height > 0 ? fallback.width / fallback.height : 1)
        let size: CGSize = switch (absolute("width"), absolute("height")) {
        case let (w?, h?): CGSize(width: w, height: h)
        case let (w?, nil): CGSize(width: w, height: w / aspect)
        case let (nil, h?): CGSize(width: h * aspect, height: h)
        case (nil, nil): box?.size ?? fallback
        }
        return size.width.isFinite && size.height.isFinite ? size : fallback
    }

    /// The furthest an edge of a wrapped `<image>` may lie from its SVG's box, in boxes: the
    /// largest number `ImageSizing.length` takes from an attribute.
    static let maximumPlacement: CGFloat = 100_000

    /// Where a wrapped `<image>` sits in its SVG, as fractions of the SVG's box; nil when it
    /// fills it. A viewBox far smaller than the image or far from it gives a rectangle with no
    /// bound, so a placement is kept only while it leaves a pixel or more of the image in the
    /// box and lies within `maximumPlacement` of it: nil otherwise too, and the image fills
    /// the box.
    static func placement(of image: ContentNode, in svg: ContentNode, source: ReaderImageSource, fontSize: CGFloat) -> CGRect? {
        let imageSize = source.pixelSize
        let viewport = intrinsicSize(svg, fontSize: fontSize, fallback: imageSize)
        let box = viewBox(svg) ?? CGRect(origin: .zero, size: viewport)
        func length(_ name: String, reference: CGFloat) -> CGFloat? {
            ImageSizing.length(image.attribute(name), fontSize: fontSize)?.resolve(reference: reference, viewport: box.size)
        }
        func coordinate(_ name: String, reference: CGFloat) -> CGFloat {
            let value = image.attribute(name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Positions, unlike sizes, may be negative.
            let negative = value.hasPrefix("-")
            let magnitude = negative ? String(value.dropFirst()) : value
            return (ImageSizing.length(magnitude, fontSize: fontSize)?.resolve(reference: reference, viewport: box.size) ?? 0)
                * (negative ? -1 : 1)
        }
        let width = length("width", reference: box.width).flatMap { $0 > 0 ? $0 : nil }
        let height = length("height", reference: box.height).flatMap { $0 > 0 ? $0 : nil }
        // SVG 2 image sizing: one auto dimension follows the intrinsic ratio; with both
        // auto, use the image's own dimensions. A percentage is of the SVG viewport in
        // user coordinates, so under a viewBox 100% means its width/height, not bitmap pixels.
        let size: CGSize = switch (width, height) {
        case let (width?, height?): CGSize(width: width, height: height)
        case let (width?, nil): CGSize(width: width, height: width * imageSize.height / imageSize.width)
        case let (nil, height?): CGSize(width: height * imageSize.width / imageSize.height, height: height)
        case (nil, nil): imageSize
        }
        // The root's default meet transform may letterbox its viewBox inside a differently
        // proportioned authored viewport. Map the image viewport through that transform
        // before the attachment applies the image's own centred meet fit.
        let scale = min(viewport.width / box.width, viewport.height / box.height)
        let offset = CGPoint(x: (viewport.width - box.width * scale) / 2, y: (viewport.height - box.height * scale) / 2)
        let rect = CGRect(x: (offset.x + (coordinate("x", reference: box.width) - box.minX) * scale) / viewport.width,
                          y: (offset.y + (coordinate("y", reference: box.height) - box.minY) * scale) / viewport.height,
                          width: size.width * scale / viewport.width, height: size.height * scale / viewport.height)
        let filled = abs(rect.minX) < 0.001 && abs(rect.minY) < 0.001 && abs(rect.width - 1) < 0.001 && abs(rect.height - 1) < 0.001
        // The most pixels a decode has across the image: its own, or those an SVG is rasterized at.
        let ceiling = CGFloat(ReaderImageSource.maximumSVGDimension)
        let pixels = source.format == .svg ? CGSize(width: ceiling, height: ceiling) : imageSize
        // Each comparison is false for a number that is infinite or not a number.
        let kept = rect.width <= pixels.width && rect.height <= pixels.height
            && [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy { abs($0) <= maximumPlacement }
        return filled || !kept ? nil : rect
    }
}

/// The publication as StaticSVG reads it for the images a drawing names: a resource's manifest
/// fallback chain, with remote resources left out, the archive's bytes and media types, and
/// references resolved within the archive. An SVG image is parsed as the reader parses markup.
struct PublicationSVGResources: SVGResourceProvider {
    let publication: EPUBPublication

    func imageCandidates(for path: String) -> [String] {
        let paths: [String]
        if let resource = publication.manifestResource(at: path) {
            paths = NativeFallbacks.resources(for: resource, in: publication).filter(NativeFallbacks.isImage).map(\.path)
        } else { paths = [path] }
        return paths.filter { !ResourceReference.isRemote($0) }
    }

    func data(at path: String) -> Data? { try? publication.data(at: path) }

    func mediaType(at path: String) -> String? { publication.manifestResource(at: path)?.mediaType }

    func resolve(_ reference: String, relativeTo path: String) -> String? {
        guard let resolved = try? ResourceReference.resolve(reference, relativeTo: path) else { return nil }
        return String(resolved.split(separator: "#", maxSplits: 1)[0]).removingPercentEncoding
    }

    func document(from data: Data, path: String) -> SVGDocument? {
        SVGContent.document(data, path: path)?.svg
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
