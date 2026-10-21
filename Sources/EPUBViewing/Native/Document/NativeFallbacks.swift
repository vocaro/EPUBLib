import EPUBCore
import EPUBReading
import Foundation

/// The native reader's supported manifest resources. The public spine remains the authored
/// occurrence; only the bytes used for its content change. Every local dependency resolves
/// against the selected document's path, and every search uses this same selection.
enum NativeFallbacks {
    static func isImage(_ resource: EPUBResource) -> Bool {
        // ImageIO's supported formats vary by OS. The media family admits candidates; the
        // bounded bitmap decoder or SVG sanitizer decides whether their bytes are usable.
        resource.mediaType.lowercased().hasPrefix("image/")
    }

    /// Whether a resource of the chain is the original itself, by its ID's code units: a fallback
    /// whose ID is canonically equivalent to the original's is another item.
    private static func isOriginal(_ resource: EPUBResource, _ original: EPUBResource) -> Bool {
        EPUBElementID(resource.id) == EPUBElementID(original.id)
    }

    static func resources(for original: EPUBResource, in publication: EPUBPublication) -> [EPUBResource] {
        let chain = publication.fallbackChain(for: original)
        // With no designated fallback a scripted document's static/noscript content remains
        // useful. A designated fallback is processed instead of silently showing an unrun app.
        return chain.filter { item in
            !item.properties.contains("scripted") || (isOriginal(item, original) && item.fallbackID == nil)
        }
    }

    static func document(for original: EPUBResource, in publication: EPUBPublication) throws -> ContentDocument {
        for resource in resources(for: original, in: publication) {
            guard !ResourceReference.isRemote(resource.path), let data = try? publication.data(for: resource) else { continue }
            if resource.mediaType.lowercased() == "application/xhtml+xml" {
                guard let document = try? ContentDocument.parse(data, path: resource.path) else { continue }
                return isOriginal(resource, original) ? document : document.withCFIResource(resource.href)
            }
            guard isImage(resource) else { continue }
            if resource.mediaType.lowercased() == "image/svg+xml" {
                guard let svg = try? ContentDocument.parse(data, path: resource.path, asContent: false),
                      svg.root.name == "svg", SVGContent.isSVG(svg.root, root: svg.root) else { continue }
                return isOriginal(resource, original) ? svg : svg.withCFIResource(resource.href)
            } else {
                guard ReaderImageSource.bitmap(data, path: resource.path, key: publication.id + "\u{0}" + resource.path) != nil else { continue }
            }
            // A raster image's synthetic HTML is not its authored XML DOM and has no text CFIs.
            // Its absolute archive reference preserves spaces/#/% and resolves to the image.
            let reference = ("/" + resource.href).replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
            let source = "<html xmlns='http://www.w3.org/1999/xhtml'><body><img src=\"\(reference)\"/></body></html>"
            return try ContentDocument.parse(Data(source.utf8), path: resource.path).asSyntheticRaster()
        }
        throw ContentDocumentError.malformed(original.path)
    }

    /// Original and designated-fallback hrefs name the same logical spine occurrence. A target
    /// that also occurs directly in the spine wins over its use as another item's fallback.
    static func spineIndex(for path: String, in publication: EPUBPublication) -> Int? {
        if let direct = publication.spine.firstIndex(where: { $0.resource.path == path }) { return direct }
        return publication.spine.firstIndex { item in
            publication.fallbackChain(for: item.resource).dropFirst().contains { $0.path == path }
        }
    }
}
