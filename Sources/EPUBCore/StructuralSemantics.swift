import Foundation

/// The elements that may carry structural semantics by their name, for the reader and for text
/// extraction alike (#133, #777).
///
/// EPUB 3.3 §6.1.3.1: `epub:type` "MUST NOT be used on the head element or metadata content";
/// §6.2.3: in SVG it goes only on a renderable element. A reading system "MUST ignore the terms"
/// anywhere else (EPUB Reading Systems 3.3 §10). Each reader of a tree takes what the head holds
/// as in it, valid there or not.
package enum StructuralSemantics {
    /// HTML's metadata content (HTML 3.2.5.2.1), which may stand in the body too.
    package static let metadataContent: Set<String> = ["base", "link", "meta", "noscript", "script", "style", "template", "title"]

    /// SVG 2's renderable elements (its Rendering Model chapter defines them); `symbol` is one
    /// only as the root of a `use` element's shadow tree, which the reader does not build.
    package static let renderableSVG: Set<String> = [
        "a", "circle", "ellipse", "foreignObject", "g", "image", "line", "path", "polygon", "polyline", "rect", "svg",
        "switch", "text", "textPath", "tspan", "use",
    ]

    /// `renderableSVG` in lowercase, as libxml2's HTML parser writes every name.
    package static let lowercaseRenderableSVG = Set(renderableSVG.map { $0.lowercased() })
}
