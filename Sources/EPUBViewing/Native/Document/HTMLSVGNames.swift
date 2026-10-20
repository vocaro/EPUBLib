/// The HTML Standard's SVG element/attribute adjustments for foreign content:
/// https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inforeign
/// https://html.spec.whatwg.org/multipage/parsing.html#adjust-svg-attributes
///
/// libxml2's HTML parser lowercases these names without restoring their SVG spelling.
/// Apply the tables when converting a recovered SVG subtree, before sizing, sanitization
/// and rendering-cost checks read it. Changing only serialized output would give the
/// renderer a different tree from the one those checks counted. Strict XML never uses this.
enum HTMLSVGNames {
    private static let elements = Dictionary(uniqueKeysWithValues: [
        "altGlyph", "altGlyphDef", "altGlyphItem", "animateColor", "animateMotion", "animateTransform",
        "clipPath", "feBlend", "feColorMatrix", "feComponentTransfer", "feComposite", "feConvolveMatrix",
        "feDiffuseLighting", "feDisplacementMap", "feDistantLight", "feDropShadow", "feFlood", "feFuncA",
        "feFuncB", "feFuncG", "feFuncR", "feGaussianBlur", "feImage", "feMerge", "feMergeNode",
        "feMorphology", "feOffset", "fePointLight", "feSpecularLighting", "feSpotLight", "feTile",
        "feTurbulence", "foreignObject", "glyphRef", "linearGradient", "radialGradient", "textPath"
    ].map { ($0.lowercased(), $0) })

    private static let attributes = Dictionary(uniqueKeysWithValues: [
        "attributeName", "attributeType", "baseFrequency", "baseProfile", "calcMode", "clipPathUnits",
        "diffuseConstant", "edgeMode", "filterUnits", "glyphRef", "gradientTransform", "gradientUnits",
        "kernelMatrix", "kernelUnitLength", "keyPoints", "keySplines", "keyTimes", "lengthAdjust",
        "limitingConeAngle", "markerHeight", "markerUnits", "markerWidth", "maskContentUnits", "maskUnits",
        "numOctaves", "pathLength", "patternContentUnits", "patternTransform", "patternUnits", "pointsAtX",
        "pointsAtY", "pointsAtZ", "preserveAlpha", "preserveAspectRatio", "primitiveUnits", "refX", "refY",
        "repeatCount", "repeatDur", "requiredExtensions", "requiredFeatures", "specularConstant",
        "specularExponent", "spreadMethod", "startOffset", "stdDeviation", "stitchTiles", "surfaceScale",
        "systemLanguage", "tableValues", "targetX", "targetY", "textLength", "viewBox", "viewTarget",
        "xChannelSelector", "yChannelSelector", "zoomAndPan"
    ].map { ($0.lowercased(), $0) })

    /// SVG HTML integration points: their element children are HTML again unless an
    /// inner `<svg>` establishes another SVG subtree. This does not repair HTML's tree shape.
    static let integrationPoints: Set<String> = ["foreignObject", "desc", "title"]

    static func element(_ lowercase: String) -> String { elements[lowercase] ?? lowercase }

    static func attribute(_ lowercase: String, value: String) -> ContentAttribute {
        // The Standard's foreign-attribute adjustment table. Unknown prefixes remain
        // unbound names, so the SVG serializer still refuses to turn them into references.
        let foreign: (name: String, namespace: String)? = switch lowercase {
        case "xlink:actuate", "xlink:arcrole", "xlink:href", "xlink:role", "xlink:show", "xlink:title", "xlink:type":
            (String(lowercase.dropFirst(6)), ContentNamespace.xlink)
        case "xml:lang", "xml:space":
            (String(lowercase.dropFirst(4)), ContentNamespace.xml)
        case "xmlns": ("xmlns", "http://www.w3.org/2000/xmlns/")
        case "xmlns:xlink": ("xlink", "http://www.w3.org/2000/xmlns/")
        default: nil
        }
        return ContentAttribute(name: foreign?.name ?? attributes[lowercase] ?? lowercase,
                                namespace: foreign?.namespace ?? "", value: value)
    }
}
