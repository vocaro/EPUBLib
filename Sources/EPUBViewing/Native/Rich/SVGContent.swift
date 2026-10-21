import CoreGraphics
import CryptoKit
import EPUBCore
import EPUBReading
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// SVG for the rich-content factory. An SVG that only wraps one `<image>` (every cover and
/// title page in the catalog) is shown as that image with the SVG's sizing. Any other SVG is
/// serialized, sanitized, for the bundled static renderer: scripts, foreign content and every
/// reference outside the document are removed, and the images it uses, from the archive or in
/// `data:` URLs, are decoded and inlined, so the decoder can never reach anything but the bytes
/// given to it.
enum SVGContent {
    /// Bytes of serialized SVG the decoder is given at most.
    static let maximumBytes = 4 * 1024 * 1024
    /// Bytes of images inlined into one SVG at most.
    static let maximumInlinedImageBytes = 8 * 1024 * 1024
    static let maximumNodes = 10_000
    static let maximumDepth = 64
    static let maximumExpandedBytes = 8 * 1024 * 1024
    static let maximumImagePixels = 4 * 1024 * 1024
    static let maximumTotalImagePixels = 16 * 1024 * 1024
    /// Characters in one `<text>` element (its own text and that of its `tspan`/`textPath`
    /// descendants). Text layout is super-linear in the length of one run, so the document
    /// byte limit alone lets a single run cost minutes; a real label is far shorter.
    static let maximumTextRunCharacters = 20_000
    /// Every em/ex length reparses every ancestor's font-size (usvg `units.rs`), including
    /// each dash and text-position entry. Bound the value itself, not just one reparse per shape.
    /// CSS values are trimmed by simplecss; XML presentation attributes retain their padding.
    static let maximumFontSizeValueBytes = 64
    /// What the renderer may build for markers, which neither the node nor the expansion limit
    /// counts: the renderer converts a marker's content again at every vertex it is drawn at.
    /// The unit is one element of a marker's content, so a marker of ten elements drawn 10,000
    /// times is at the limit. `markerVerdict` holds what an SVG can reach.
    static let maximumMarkerInstances = 100_000
    /// Steps of the walk that counts marker instances: one for each element it visits and each
    /// `<use>` it follows, in what is drawn and again in each mask. An SVG within
    /// `maximumExpandedBytes`, at 32 bytes or more an element, cannot reach it.
    static let markerStepBudget = 4 * (maximumExpandedBytes / 32)
    /// The copies of shared and inherited values the renderer makes per painted shape, which the
    /// node and expansion limits do not count: a gradient's stops for each shape it paints, a dash
    /// array for each stroked shape, a long inherited value re-parsed per shape, the variation
    /// settings and font family a `<text>` copies per span. A unit is roughly one stop copied, one
    /// byte stored, or 64 bytes re-parsed. The value is set from measurement, not tied to another
    /// limit: at this ceiling the renderer spends on the order of 110 MB or 0.35 s on the worst
    /// passing document (a 2,048-stop gradient on 4,096 shapes costs it about 110 MB and 0.3 s),
    /// the same order the other limits allow. `copyVerdict` holds what an SVG can reach. That is
    /// so for the values named here. `SVGRenderingCostScreen` separately bounds every stylesheet
    /// declaration and passes the resource map so these copies count per mask/clip reference too.
    static let maximumSharedCopies = 8 * 1024 * 1024
    /// Bytes of CSS that `copyVerdict` reads for one step of its budget. It reads a stylesheet and
    /// a `style` attribute several times, once for each thing it looks for, and charges every
    /// reading, so that a reading made once for each declaration or each rule, where one for the
    /// text will do, spends the budget and is refused, and does not run on. A text is read eight
    /// times at most (`styleSheetCopyBytes` counts them), so the CSS of an SVG takes an eighth of
    /// its bytes in steps at most, where elements of as many bytes would take a sixteenth to
    /// walk: were all that `maximumExpandedBytes` allows CSS, and all of it read eight times, that
    /// would be `markerStepBudget` and no more. An SVG within the expansion limit so cannot
    /// spend the budget by its CSS, as it cannot by its elements. A `<style>` inside another
    /// would duplicate those readings; `SVGStyleScreen` refuses it before CSS is read.
    static let cssBytesPerStep = 64
    /// Shapes whose vertices can carry a marker, and whose geometry the renderer builds.
    private static let markerableShapes: Set<String> = ["path", "line", "polyline", "polygon", "rect", "circle", "ellipse"]
    /// All that a `<marker>` may hold.
    private static let markerContent: Set<String> = markerableShapes.union(["g", "title", "desc"])

    /// The presentation properties the renderer stores as an attribute (the value string copied) on
    /// every element a stylesheet rule matches (usvg `svgtree/parse.rs`, `write_declaration`: it keeps
    /// a declaration only when its name is a presentation property, or the `marker`/`font` shorthands).
    /// A declaration of any other name is dropped and never reaches an element, so it is not charged.
    /// `filter` is left out: `serialize` strips filter declarations before the renderer parses them.
    static let copiedStyleProperties: Set<String> = [
        "alignment-baseline", "baseline-shift", "background-color", "clip-path", "clip-rule", "color",
        "color-interpolation", "color-interpolation-filters", "color-rendering", "direction", "display",
        "dominant-baseline", "fill", "fill-opacity", "fill-rule", "flood-color", "flood-opacity",
        "font", "font-family", "font-kerning", "font-optical-sizing", "font-size", "font-size-adjust",
        "font-stretch", "font-style", "font-variant", "font-weight", "font-variation-settings",
        "glyph-orientation-horizontal", "glyph-orientation-vertical", "image-rendering", "isolation",
        "letter-spacing", "lighting-color", "marker", "marker-end", "marker-mid", "marker-start", "mask",
        "mask-type", "mix-blend-mode", "opacity", "overflow", "paint-order", "shape-rendering",
        "stop-color", "stop-opacity", "stroke", "stroke-dasharray", "stroke-dashoffset", "stroke-linecap",
        "stroke-linejoin", "stroke-miterlimit", "stroke-opacity", "stroke-width", "text-anchor",
        "text-decoration", "text-overflow", "text-rendering", "transform", "transform-origin",
        "unicode-bidi", "vector-effect", "visibility", "white-space", "word-spacing", "writing-mode"]

    /// The presentation properties the renderer re-reads and re-parses afresh for every shape that
    /// inherits them (they are inheritable: usvg reads the nearest ancestor that sets each, once per
    /// shape), so a long value on an ancestor is re-parsed as many times as there are shapes below it.
    /// `fill`/`stroke` paint, numbers (`stroke-width`, opacities, `stroke-miterlimit`, offsets) and
    /// keyword enumerations all belong here; `font-family`, `font-variation-settings` and
    /// `stroke-dasharray` are left out because they are charged in full by their own terms.
    private static let reparsedProperties: Set<String> = [
        "clip-rule", "color", "color-interpolation", "color-interpolation-filters", "color-rendering",
        "direction", "fill", "fill-opacity", "fill-rule", "font-kerning", "font-optical-sizing",
        "font-size", "font-size-adjust", "font-stretch", "font-style", "font-variant", "font-weight",
        "glyph-orientation-horizontal", "glyph-orientation-vertical", "image-rendering", "isolation",
        "kerning", "letter-spacing", "marker", "marker-end", "marker-mid", "marker-start",
        "mix-blend-mode", "paint-order", "shape-rendering", "stroke", "stroke-dashoffset",
        "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-opacity", "stroke-width",
        "text-anchor", "text-rendering", "vector-effect", "visibility", "white-space", "word-spacing",
        "writing-mode", "background-color", "mask-type", "text-overflow", "unicode-bidi"]

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
        // it. Following the wrong one would let a `<use href='#big' xlink:href='#small'>` hide the
        // expanded target from the byte and marker counts.
        (element.attribute("href") ?? element.attribute("href", namespace: ContentNamespace.xlink))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The id a `<use>` names, read as the renderer reads it: after leading white space a `#`,
    /// then all that precedes the first space. An id may end in other white space, so no more is
    /// trimmed: a `<use>` whose target is not found here is one whose expansion is not counted.
    static func fragment(_ element: ContentNode) -> EPUBElementID? {
        guard let reference = element.attribute("href") ?? element.attribute("href", namespace: ContentNamespace.xlink) else { return nil }
        let rest = reference.utf8.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        guard rest.first == UInt8(ascii: "#") else { return nil }
        let id = String(decoding: rest.dropFirst().prefix { $0 != 0x20 }, as: UTF8.self)
        return id.isEmpty ? nil : EPUBElementID(id)
    }

    /// The elements a reference by id can mean. The renderer takes an element's id from its first
    /// attribute named `id` in any namespace, and resolves a `<use>` to the first element with an
    /// id but a marker property to the last. Every element with the id in any such attribute is
    /// kept, so that whichever the renderer picks is counted.
    static func elementsByID(_ nodes: [ContentNode]) -> [EPUBElementID: [ContentNode]] {
        var ids: [EPUBElementID: [ContentNode]] = [:]
        for node in nodes {
            for attribute in node.attributes where attribute.name == "id" && ids[attribute.value]?.last !== node {
                ids[EPUBElementID(attribute.value), default: []].append(node)
            }
        }
        return ids
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
        guard SVGStyleScreen.verdict(svg).withinLimits else { return [] }
        var result = Set<String>()
        func visit(_ node: ContentNode) {
            if dropped.contains(node.name) { result.insert("svg:" + node.name); return }
            if node.name == "pattern" { result.insert("svg:pattern") }
            // The renderer takes a `filter` attribute in more than one namespace (`xlink:filter`,
            // #253), and each is looked for here, with a `style` in any.
            if node.name == "filter" || node.attributes.contains(where: { attribute in
                attribute.name == "filter" || (attribute.name == "style" && omittingFilterDeclarations(attribute.value, sheet: false).omitted)
            }) || (node.name == "style" && omittingFilterDeclarations(node.textContent, sheet: true).omitted) {
                result.insert("svg:filter")
            }
            for child in node.elementChildren { visit(child) }
        }
        visit(svg)
        return result
    }

    /// Refuse expansion bombs before handing them to the renderer, including references in
    /// definitions. Cost follows `<use>` targets and is memoized without expanding a tree.
    static func isWithinRenderingLimits(_ svg: ContentNode, omittingFilters: Bool = false) -> Bool {
        // The limits are read from this tree and the renderer parses the bytes for itself. Bytes
        // that were not XML here were recovered as HTML, under an `html` root: a tree in which
        // names keep their prefixes, and which is not the one the renderer would draw.
        guard svg.name == "svg" else { return false }
        guard SVGStyleScreen.verdict(svg).withinLimits else { return false }
        var nodes: [ContentNode] = []
        var valid = true
        func collect(_ node: ContentNode, depth: Int) {
            guard valid, depth <= maximumDepth, nodes.count < maximumNodes else { valid = false; return }
            nodes.append(node)
            for child in node.children { collect(child, depth: depth + 1) }
        }
        collect(svg, depth: 0)
        let refused: Set<String> = omittingFilters ? ["svg:pattern"] : ["svg:filter", "svg:pattern"]
        guard valid, unsupportedConstructs(svg).isDisjoint(with: refused) else { return false }
        guard textRunsAreBounded(nodes) else { return false }
        let ids = elementsByID(nodes)
        var costs: [ObjectIdentifier: Int] = [:]
        var active = Set<ObjectIdentifier>()
        func cost(_ node: ContentNode, depth: Int) -> Int? {
            guard depth <= maximumDepth else { return nil }
            let key = ObjectIdentifier(node)
            if let cached = costs[key] { return cached }
            guard active.insert(key).inserted else { return nil }
            defer { active.remove(key) }
            var total = 32 + node.text.utf8.count + node.attributes.reduce(0) { $0 + $1.value.utf8.count + $1.name.utf8.count }
            let targets = node.name == "use" ? fragment(node).flatMap { ids[$0] } ?? [] : []
            for child in targets + node.children {
                guard let childCost = cost(child, depth: depth + 1), childCost <= maximumExpandedBytes - total else { return nil }
                total += childCost
            }
            guard total <= maximumExpandedBytes else { return nil }
            costs[key] = total
            return total
        }
        guard cost(svg, depth: 0) != nil else { return false }
        // Bound stylesheet materialization and reference multiplication before constructing the
        // reference graph or walking per-shape copies. The resource map is shared by those counts.
        let original = SVGRenderingCostScreen.verdict(svg, nodes: nodes, ids: ids)
        guard original.withinLimits, SVGReferenceScreen.accepts(nodes, ids: ids) else { return false }
        guard SVGGeometryCostScreen.accepts(svg, nodes: nodes, ids: ids) else { return false }
        guard SVGRasterCostScreen.accepts(svg, nodes: nodes) else { return false }
        let markers = markerVerdict(svg, nodes: nodes, ids: ids)
        guard markers.withinLimits else { return false }
        let rendering = SVGRenderingCostScreen.chargingMarkers(original, instances: markers.instances)
        guard rendering.withinLimits else { return false }
        return copyVerdict(svg, nodes: nodes, ids: ids, resourceReferences: rendering.resources,
                           markerResourceReferences: rendering.markerResourceReferences, markerInstances: markers.instances).withinLimits
    }

    /// Whether every `<text>` element's run is within the per-run character bound. A run is the
    /// element's own text plus that of its `tspan`/`textPath` descendants, which the renderer
    /// shapes as one super-linear unit; separate `<text>` elements stay roughly linear. A `<tref>`
    /// adds to a run the text of an element elsewhere, which this count does not see: SVG 2 has
    /// removed it, and an SVG that holds one is refused.
    private static func textRunsAreBounded(_ nodes: [ContentNode]) -> Bool {
        guard !nodes.contains(where: { $0.name == "tref" }) else { return false }
        for node in nodes where node.name == "text" {
            var characters = 0
            func count(_ node: ContentNode) -> Bool {
                if node.isText {
                    characters += node.text.unicodeScalars.count
                    return characters <= maximumTextRunCharacters
                }
                for child in node.children where !count(child) { return false }
                return true
            }
            guard count(node) else { return false }
        }
        return true
    }

    // MARK: Marker expansion

    /// The verdict on an SVG's markers, with the instances counted and the steps the walk took, so a
    /// test can assert both instead of timing the check.
    typealias MarkerVerdict = (withinLimits: Bool, instances: Int, steps: Int)

    /// What an element's own attributes ask of the shapes below it, each of which is inherited: the
    /// size of the largest marker each marker property could name, whether its fill or stroke names
    /// a paint server, and the bytes of its dash array. One element's declaration only ever raises
    /// what another's set, never lowers it: a shape is charged the most that it or any ancestor
    /// asks for, so a declaration the renderer ignores cannot hide one that it honours.
    private struct Inherited {
        var start = 0, mid = 0, end = 0
        var paintServer = false
        var dashBytes = 0
        var marked: Bool { start > 0 || mid > 0 || end > 0 }

        mutating func raise(to other: Inherited) {
            start = max(start, other.start); mid = max(mid, other.mid); end = max(end, other.end)
            paintServer = paintServer || other.paintServer
            dashBytes = max(dashBytes, other.dashBytes)
        }
    }

    /// What a property value can name: nothing, the element with one id, or an element not known.
    private enum Reference: Equatable { case none, id(EPUBElementID), unknown }

    /// The properties a declaration can set that this check reads.
    private struct Property: OptionSet {
        let rawValue: Int
        static let start = Property(rawValue: 1), mid = Property(rawValue: 2), end = Property(rawValue: 4)
        static let markers: Property = [.start, .mid, .end]
        static let paint = Property(rawValue: 8), dash = Property(rawValue: 16)
    }

    /// Whether the renderer's marker expansion stays within `maximumMarkerInstances`. The renderer
    /// is not modelled. Markers are counted in the few forms a diagram uses, and an SVG that uses
    /// them in any other form is refused:
    ///
    ///  1. No stylesheet holds a `url(#…)`: a stylesheet names no marker, and nothing a marker or a
    ///     shape that bears one could draw with.
    ///  2. A shape's markers come from the `marker-start`, `marker-mid` and `marker-end` attributes
    ///     and the `style` declarations, `marker` among them, of the shape and of its ancestors,
    ///     those of each `<use>` that draws it included. The largest marker any of them names is
    ///     charged: one declaration never lowers what another asks for.
    ///  3. No `<marker>`, and no element one stands in, names a marker or a paint server, and
    ///     nothing inside a `<marker>` holds a `url(…)`, an `href` or a filter: a marker's content
    ///     bears no marker and draws nothing but itself.
    ///  4. A `<marker>` holds only shapes, `<g>`, `<title>` and `<desc>`. `markerSize` is what one
    ///     instance of it costs.
    ///  5. No shape in a `<mask>` bears a marker: the renderer draws a mask's content again for
    ///     every element that uses the mask. A `<clipPath>` draws no markers.
    ///  6. A `circle`, an `ellipse` and a rounded `rect` have the vertices their radius allows. A
    ///     path with an elliptical arc has a number its text does not bound: under `marker-mid`,
    ///     or inside a `<marker>`, it is refused.
    ///  7. One walk of what is drawn, following `<use>` as `cost` does, sums for each shape its
    ///     vertices times its `marker-mid` size, and its `marker-start` and `marker-end` sizes,
    ///     and one more for each of the three it draws with. The sum is held to
    ///     `maximumMarkerInstances` and the walk to `markerStepBudget`.
    ///
    /// Two costs of an instance come from the shape it is drawn on, not from the marker. The
    /// renderer copies the shape's dash array for each instance, so 64 bytes of dash array count
    /// one more for each. And a marker painted with `context-fill` or `context-stroke` copies the
    /// stops of the shape's paint server for each: with such a marker in the SVG, a shape whose
    /// fill or stroke names a paint server bears no marker.
    static func markerVerdict(_ svg: ContentNode, nodes: [ContentNode], ids: [EPUBElementID: [ContentNode]],
                              stepBudget: Int = markerStepBudget) -> MarkerVerdict {
        guard nodes.contains(where: { $0.name == "marker" }) else { return (true, 0, 0) }
        let refused: MarkerVerdict = (false, 0, 0)

        // Rule 1. What else a stylesheet declares names no element, and is taken to reach every
        // element: a context paint, and its longest declaration as an attribute of each element in
        // a marker and as the dash array of each shape that bears one.
        let sheets = nodes.filter { $0.name == "style" }.map(\.textContent)
        guard !sheets.contains(where: namesElement) else { return refused }
        let sheetBytes = sheets.map(longestDeclaration).max() ?? 0
        let contextPaint = sheets.contains { mentions($0, "context-") } || nodes.contains { node in
            node.attributes.contains { ($0.name == "fill" || $0.name == "stroke" || $0.name == "style") && mentions($0.value, "context-") }
        }

        // Rule 4, and the part of rule 3 inside a marker: the size of each, by every id it has.
        var sizes: [EPUBElementID: Int] = [:]
        var largest = 0
        func measure(_ node: ContentNode, above: Int) -> Bool {
            guard node.name == "marker" else {
                let bytes = above + attributeBytes(node)
                return node.elementChildren.allSatisfy { measure($0, above: bytes) }
            }
            guard let size = markerSize(node, above: above) else { return false }
            largest = max(largest, size)
            for attribute in node.attributes where attribute.name == "id" {
                sizes[attribute.value] = max(sizes[attribute.value] ?? 0, size)
            }
            return true
        }
        guard measure(svg, above: sheetBytes) else { return refused }
        func size(_ reference: Reference) -> Int {
            switch reference {
            case .none: 0
            case .id(let id): sizes[id] ?? 0
            case .unknown: largest
            }
        }

        // Rule 2: what one element's attributes and `style` declare. Each element is read once,
        // however often a `<use>` draws it, and kept by its place in the SVG.
        struct Element {
            var own = Inherited()
            var targets: [ContentNode] = []
            /// Nil for a shape whose text does not bound them.
            var vertices: Int? = 0
            var isShape = false
            var isDrawn = true
        }
        var elements = [Element?](repeating: nil, count: svg.subtreeEnd - svg.order + 1)
        func element(_ node: ContentNode) -> Element {
            if let known = elements[node.order - svg.order] { return known }
            var element = Element()
            for attribute in node.attributes {
                var dashed = false
                func declare(_ property: Property, _ reference: Reference) {
                    let size = property.isDisjoint(with: .markers) ? 0 : size(reference)
                    if property.contains(.start) { element.own.start = max(element.own.start, size) }
                    if property.contains(.mid) { element.own.mid = max(element.own.mid, size) }
                    if property.contains(.end) { element.own.end = max(element.own.end, size) }
                    if property.contains(.paint), reference != .none { element.own.paintServer = true }
                    if property.contains(.dash) { dashed = true }
                }
                switch attribute.name {
                case "style": declarations(in: attribute.value, declare)
                case "marker": declare(.markers, reference(Array(attribute.value.utf8), from: 0))
                case "marker-start": declare(.start, reference(Array(attribute.value.utf8), from: 0))
                case "marker-mid": declare(.mid, reference(Array(attribute.value.utf8), from: 0))
                case "marker-end": declare(.end, reference(Array(attribute.value.utf8), from: 0))
                case "fill", "stroke": declare(.paint, reference(Array(attribute.value.utf8), from: 0))
                case "stroke-dasharray": element.own.dashBytes = max(element.own.dashBytes, attribute.value.utf8.count)
                default: break
                }
                if dashed { element.own.dashBytes = max(element.own.dashBytes, longestDeclaration(attribute.value)) }
            }
            element.isShape = markerableShapes.contains(node.name)
            element.isDrawn = !unrendered.contains(node.name)
            if element.isShape { element.vertices = vertices(node) }
            if node.name == "use", let id = fragment(node) { element.targets = ids[id] ?? [] }
            elements[node.order - svg.order] = element
            return element
        }

        // Rule 3 where each marker stands, and for rule 5 what each mask's content inherits.
        var masks: [(mask: ContentNode, inherited: Inherited)] = []
        func survey(_ node: ContentNode, above: Inherited) -> Bool {
            var here = above
            here.raise(to: element(node).own)
            if node.name == "marker" { return !here.marked && !here.paintServer }
            if node.name == "mask" { masks.append((node, here)) }
            return node.elementChildren.allSatisfy { survey($0, above: here) }
        }
        guard survey(svg, above: Inherited()) else { return refused }

        // Rule 7, and rule 5 for a mask's content.
        var instances = 0
        var steps = 0
        func step() -> Bool {
            steps += 1
            return steps <= stepBudget
        }
        func walk(_ node: ContentNode, above: Inherited, inMask: Bool, depth: Int) -> Bool {
            guard step(), depth <= maximumDepth else { return false }
            let element = element(node)
            var here = above
            here.raise(to: element.own)
            if here.marked, element.isShape {
                guard !inMask, !(contextPaint && here.paintServer) else { return false }
                // The renderer copies the shape's dash array for each instance it draws on it, and
                // builds a group and a clip path for each marker property the shape draws with.
                let dash = max(here.dashBytes, sheetBytes) / 64
                instances += (here.start > 0 ? here.start + dash + 1 : 0) + (here.end > 0 ? here.end + dash + 1 : 0)
                if here.mid > 0 {
                    guard let vertices = element.vertices, vertices <= maximumMarkerInstances / (here.mid + dash) else { return false }
                    instances += vertices * (here.mid + dash) + 1
                }
                guard instances <= maximumMarkerInstances else { return false }
            }
            for target in element.targets {
                guard step(), walk(target, above: here, inMask: inMask, depth: depth + 1) else { return false }
            }
            return walk(in: node, above: here, inMask: inMask, depth: depth + 1)
        }
        // Definitions are drawn only where a reference draws them, and a mask from where it stands.
        func walk(in node: ContentNode, above: Inherited, inMask: Bool, depth: Int) -> Bool {
            for child in node.children where child.isElement && element(child).isDrawn {
                guard walk(child, above: above, inMask: inMask, depth: depth) else { return false }
            }
            return true
        }
        var within = walk(svg, above: Inherited(), inMask: false, depth: 0)
        for (mask, inherited) in masks where within {
            within = walk(in: mask, above: inherited, inMask: true, depth: 1)
        }
        return (within, instances, steps)
    }

    /// `markerVerdict` for an SVG on its own, for tests.
    static func markerVerdict(_ svg: ContentNode, stepBudget: Int = markerStepBudget) -> MarkerVerdict {
        var nodes: [ContentNode] = []
        func collect(_ node: ContentNode) {
            nodes.append(node)
            for child in node.elementChildren { collect(child) }
        }
        collect(svg)
        return markerVerdict(svg, nodes: nodes, ids: elementsByID(nodes), stepBudget: stepBudget)
    }

    // MARK: Per-shape copies

    /// The verdict on what the renderer copies per painted shape, with the copies counted and the
    /// steps the check took, so a test can assert both instead of timing the check: one step for
    /// each gradient whose stops are looked for through its `href`, each element the walk visits
    /// and each `<use>` it follows, and one for every `cssBytesPerStep` bytes of CSS it reads, in
    /// all the readings it makes of each stylesheet and each `style` attribute.
    typealias CopyVerdict = (withinLimits: Bool, copies: Int, steps: Int)

    /// What an element asks of the shapes below it, each of which is inherited: the stops of the
    /// gradient its fill or stroke could name, the bytes of its dash array, the bytes of the
    /// `font-family` and `font-variation-settings` a `<text>` copies per span, and the bytes of the
    /// inherited presentation values the renderer re-parses for every shape. One element only ever
    /// raises what another sets — a declaration the renderer ignores cannot hide one it honours —
    /// except `reparseBytes`, which sums down the chain: the renderer re-parses the nearest ancestor
    /// of each inherited property per shape, so distinct long values on distinct ancestors add up.
    private struct Copied {
        var fillStops = 0, strokeStops = 0
        var dashBytes = 0
        var familyBytes = 0
        var variationBytes = 0
        var reparseBytes = 0
        /// Whether a `text-decoration` names a line: the renderer clones a text span's dash array into
        /// each decoration stroke it draws, so a decorated run copies the dash more than an
        /// undecorated one.
        var decorated = false

        mutating func raise(to other: Copied) {
            fillStops = max(fillStops, other.fillStops); strokeStops = max(strokeStops, other.strokeStops)
            dashBytes = max(dashBytes, other.dashBytes)
            familyBytes = max(familyBytes, other.familyBytes)
            variationBytes = max(variationBytes, other.variationBytes)
            reparseBytes += other.reparseBytes
            decorated = decorated || other.decorated
        }
    }

    /// Whether what the renderer copies per painted shape stays within `maximumSharedCopies`. The
    /// renderer is not modelled; each shape is charged the most that it or any ancestor, through
    /// every `<use>` that draws it, could ask for, so the count never falls below what the renderer
    /// does, except for a stylesheet's declarations, which rule 4 charges only in part. For a shape
    /// the markers do not count here:
    ///
    ///  1. The renderer copies a gradient's stops into a fresh paint server for every shape it
    ///     paints by `fill` or `stroke`, directly or inherited, in an attribute or a `style`
    ///     declaration, through a gradient `href` chain, and through each `<use>`. Each shape is
    ///     charged the stops of the gradient its fill names and those its stroke names. A gradient
    ///     with no stops of its own is charged those its `href` chain leads to, at any length, or
    ///     the most any gradient has where the chain meets an id that several gradients share.
    ///  2. The renderer stores a stroke's dash array for every stroked shape that has or inherits
    ///     one. Each shape is charged its dash-array bytes, an upper bound on its entries.
    ///  3. The renderer re-reads and re-parses the nearest ancestor's value of each inherited
    ///     presentation property for every shape that inherits it — `fill`/`stroke` paint, the
    ///     numbers (`stroke-width`, the opacities, `stroke-miterlimit`, offsets) and the keyword
    ///     enumerations alike. Each shape is charged the bytes of those values, summed down its
    ///     chain, over 64. A `style` value is counted with its white space trimmed, as the renderer
    ///     trims it before storing it, so a value padded with spaces costs nothing.
    ///  4. A stylesheet declaration the renderer applies is copied onto every element a rule matches,
    ///     so each shape is charged the longest presentation declaration of any `<style>` (an
    ///     at-rule such as `@font-face`, which the renderer never applies to an element, is not
    ///     counted, nor is a `<style>` `serialize` strips whole), and the largest gradient any
    ///     stylesheet paints with, since the selectors are not evaluated. The declaration charge is
    ///     a partial bound: one value, the longest, per painted shape and per character of a text
    ///     run. It does not bound what many declarations cost, or what a rule costs on the groups
    ///     and `<use>` elements it matches; `SVGRenderingCostScreen` bounds those separately.
    ///  5. `<text>` clones its resolved style for every span (at most one span per character): the
    ///     gradient stops its fill and stroke name, into the span and each of three text decorations
    ///     (four pairs); the dash array, into the span's stroke and, when the run is decorated, each
    ///     of three decoration strokes (so four copies, else one); the font family; and the variation
    ///     settings. A run is charged its characters times those copies. A long inherited value
    ///     re-parses to a small resolved value the span clones cheaply, so the re-parse of rule 3 is
    ///     not charged per character.
    ///
    /// A `<switch>` draws one alternative but the walk charges every one, a sound over-charge. A
    /// resource map from `SVGRenderingCostScreen` charges a mask/clip's content per reference,
    /// including copies of paints and inherited values; without that map the standalone verdict
    /// retains its original once-per-mask charge for the individual shared-value regression tests.
    ///
    /// The check's own work is charged to `stepBudget`, and an SVG that spends it is refused: the
    /// gradients looked up, the elements walked, and the CSS read, by the byte. The budget does
    /// not bound all of that work. A visit to an element goes over every child the element has,
    /// drawn or not, for its one step. What bounds that is the expansion limit, which counts 32
    /// bytes or more for each child of each element the walk visits, as often as it visits it,
    /// and which `isWithinRenderingLimits` applies before it calls this.
    static func copyVerdict(_ svg: ContentNode, nodes: [ContentNode], ids: [EPUBElementID: [ContentNode]],
                            stepBudget: Int = markerStepBudget,
                            resourceReferences: [ObjectIdentifier: [ContentNode]]? = nil,
                            markerResourceReferences: [(source: ContentNode, target: ContentNode)] = [],
                            markerInstances: Int = 0) -> CopyVerdict {
        var steps = 0
        func step() -> Bool {
            steps += 1
            return steps <= stepBudget
        }
        // Each reading of CSS text is charged as it is made, a step for every `cssBytesPerStep`
        // bytes, the odd bytes carried to the next reading: false once the budget is spent, and
        // nothing more is charged then, as nothing more is to be read.
        var bytesNotCharged = 0
        func read(_ bytes: Int) -> Bool {
            guard steps <= stepBudget else { return false }
            bytesNotCharged += bytes
            steps += bytesNotCharged / cssBytesPerStep
            bytesNotCharged %= cssBytesPerStep
            return steps <= stepBudget
        }

        // Check all stored font sizes, including definitions, markers, and tspan descendants:
        // a relative-length consumer need not itself be a shape visited by the copy walk.
        for node in nodes {
            for attribute in node.attributes {
                if attribute.name == "font-size", attribute.value.utf8.count > maximumFontSizeValueBytes {
                    return (false, 0, steps)
                }
                if attribute.name == "style" {
                    let bytes = Array(attribute.value.utf8)
                    guard read(bytes.count) else { return (false, 0, steps) }
                    var scan = DeclarationScan()
                    var bounded = true
                    forEachDeclaration(bytes, bytes.indices, &scan, valueBody: { name, range in
                        if !fontSizeDeclarationIsBounded(name, bytes, range) { bounded = false }
                    }) { _, _ in }
                    guard bounded, read(scan.bytesRead) else { return (false, 0, steps) }
                }
            }
        }

        // Rule 1's stops, for each gradient. The renderer paints with those of the first gradient
        // that has a `<stop>`: the gradient itself, or else the one its `href` names, and so on
        // from one to the next for as long as the chain is (usvg `paint_server.rs`,
        // `find_gradient_with_stops`). An id that several elements share names the last of them
        // (`svgtree/parse.rs`, where `doc.links` is filled). Which is last is not worked out
        // here, so a gradient is charged by this rule:
        //
        //  - With stops of its own, those.
        //  - With none, what the gradient its `href` names is charged, where one gradient alone
        //    has that id: the chain is followed to its end, however long.
        //  - With none, and an `href` to an id that several gradients share, the most stops any
        //    gradient in the SVG has. Whichever of them the renderer takes, and wherever it goes
        //    on to from there, it ends at a gradient of the SVG.
        //  - With none, and an `href` no gradient answers to or a chain that comes back on
        //    itself, no stops: the renderer finds none there either, and paints nothing.
        //
        // A gradient without stops so leads to one gradient at most, and what it is charged does
        // not depend on where its chain was joined: each is read once and its count kept. That
        // is one step for each, whatever the ids and the `href`s are, charged to the step budget
        // with the walk's. An SVG within the node limit has no more than `maximumNodes` of them,
        // a hundredth of the budget.
        /// What an id names among the gradients.
        enum Named { case one(ContentNode), several }
        let gradients = nodes.filter { $0.name == "linearGradient" || $0.name == "radialGradient" }
        var named: [EPUBElementID: Named] = [:]
        var painted: [ObjectIdentifier: Int] = [:]
        var largestGradient = 0
        for gradient in gradients {
            let own = gradient.children.reduce(0) { $0 + ($1.name == "stop" ? 1 : 0) }
            if own > 0 { painted[ObjectIdentifier(gradient)] = own }
            largestGradient = max(largestGradient, own)
            for attribute in gradient.attributes where attribute.name == "id" {
                switch named[attribute.value] {
                case nil: named[attribute.value] = .one(gradient)
                case .one(let other)? where other !== gradient: named[attribute.value] = .several
                default: break
                }
            }
        }
        for gradient in gradients where painted[ObjectIdentifier(gradient)] == nil {
            var chain: [ObjectIdentifier] = []
            var count = 0
            var next: ContentNode? = gradient
            while let current = next {
                let key = ObjectIdentifier(current)
                // A gradient on this chain is kept as painting with no stops until the chain is
                // read, so one met a second time, which is a loop, ends the chain with none.
                if let known = painted[key] { count = known; break }
                guard step() else { return (false, 0, steps) }
                painted[key] = 0
                chain.append(key)
                switch fragment(current).flatMap({ named[$0] }) {
                case .one(let target)?: next = target
                case .several?: (count, next) = (largestGradient, nil)
                case nil: next = nil
                }
            }
            for key in chain { painted[key] = count }
        }
        // By every id a gradient has, and where several gradients share one, the most any of
        // them paints with: a `fill` or a `stroke` is charged what the id it names has here, and
        // one that is not read as naming one id, the largest gradient.
        var gradientStops: [EPUBElementID: Int] = [:]
        for gradient in gradients {
            let count = painted[ObjectIdentifier(gradient)] ?? 0
            for attribute in gradient.attributes where attribute.name == "id" {
                gradientStops[attribute.value] = max(gradientStops[attribute.value] ?? 0, count)
            }
        }
        func stops(_ reference: Reference) -> Int {
            switch reference {
            case .none: 0
            case .id(let id): gradientStops[id] ?? 0
            case .unknown: largestGradient
            }
        }

        // Rule 4: the longest declaration the renderer copies from a stylesheet onto a matched
        // element, and the largest gradient any stylesheet paints with, taken to reach every shape.
        // `sheetBytes` is that one value, charged once to each painted shape and each character of
        // a text run: a partial bound on what a stylesheet costs (`styleSheetCopyBytes`, #282).
        // A `<style>` `serialize` strips whole (an `@import`, or a `url()` that leaves the document,
        // which makes it unsafe) reaches no element: it is dropped here too, so the screen on this
        // tree agrees with the screen on the serialized bytes, from which that stylesheet is gone.
        // A stylesheet is read once to tell whether it is kept, by `styleSheetCopyBytes` as that
        // says, and once more for its paints where there is a gradient to paint with.
        var sheets: [String] = []
        var sheetBytes = 0
        for node in nodes where node.name == "style" {
            let sheet = node.textContent
            guard read(sheet.utf8.count) else { return (false, 0, steps) }
            guard serializeKeepsSheet(sheet) else { continue }
            guard let bytes = styleSheetCopyBytes(sheet, read: read) else { return (false, 0, steps) }
            sheetBytes = max(sheetBytes, bytes)
            sheets.append(sheet)
        }
        var sheetStops = 0
        if largestGradient > 0 {
            for sheet in sheets {
                guard read(sheet.utf8.count) else { return (false, 0, steps) }
                declarations(in: sheet) { property, reference in
                    if property.contains(.paint) { sheetStops = max(sheetStops, stops(reference)) }
                }
            }
        }

        // Nothing is copied per shape unless the SVG holds a gradient, a chargeable stylesheet, a
        // `<text>`, or an element carrying a value the renderer re-reads per shape. Without any of
        // these the walk could only count zero, so it is skipped before it runs: a maximal `<use>`
        // tree the cheaper limits already refuse is not walked a second time, and an ordinary
        // use-heavy drawing that paints nothing per shape is not walked at all.
        let chargeable = largestGradient > 0 || sheetBytes > 0 || nodes.contains { node in
            node.name == "text" || node.attributes.contains { attribute in
                switch attribute.name {
                case "fill", "stroke", "stroke-dasharray", "font-family", "font-variation-settings", "style": true
                default: reparsedProperties.contains(attribute.name)
                }
            }
        }
        guard chargeable else { return (true, 0, steps) }

        // What an element is to the walk, told from its name. The name is read once for each
        // element, however often a `<use>` draws it and whatever its length: nothing charges a
        // name's bytes, so a step of the walk must not read them again.
        enum Kind { case shape, text, use, undrawn, other }
        var kinds = [Kind?](repeating: nil, count: svg.subtreeEnd - svg.order + 1)
        func kind(_ node: ContentNode) -> Kind {
            if let known = kinds[node.order - svg.order] { return known }
            let kind: Kind = switch node.name {
            case "text": .text
            case "use": .use
            case let name where markerableShapes.contains(name): .shape
            case let name where unrendered.contains(name): .undrawn
            default: .other
            }
            kinds[node.order - svg.order] = kind
            return kind
        }

        // Rules 1 to 3: what one element's attributes and `style` declare, with the elements a
        // `<use>` draws and the characters of a `<text>` run. Each element is read once, however
        // often a `<use>` draws it, and kept by its place in the SVG.
        struct Element {
            var copied = Copied()
            var kind = Kind.other
            var targets: [ContentNode] = []
            var characters = 0
        }
        var elements = [Element?](repeating: nil, count: svg.subtreeEnd - svg.order + 1)
        func element(_ node: ContentNode) -> Element {
            if let known = elements[node.order - svg.order] { return known }
            var copied = Copied()
            for attribute in node.attributes {
                switch attribute.name {
                case "fill":
                    copied.fillStops = max(copied.fillStops, stops(reference(Array(attribute.value.utf8), from: 0)))
                    copied.reparseBytes += attribute.value.utf8.count
                case "stroke":
                    copied.strokeStops = max(copied.strokeStops, stops(reference(Array(attribute.value.utf8), from: 0)))
                    copied.reparseBytes += attribute.value.utf8.count
                case "stroke-dasharray": copied.dashBytes = max(copied.dashBytes, attribute.value.utf8.count)
                case "font-family": copied.familyBytes = max(copied.familyBytes, attribute.value.utf8.count)
                case "font-variation-settings": copied.variationBytes = max(copied.variationBytes, attribute.value.utf8.count)
                case "text-decoration": copied.decorated = copied.decorated || namesDecoration(attribute.value)
                case "style":
                    // The declaration list is read four times at most: for a decoration, for the
                    // paints and whether a dash array is declared, for the longest declaration
                    // where one is, and for the values. Each reading is charged as it is made, and
                    // none is made once the budget is spent: the walk then stops at this element.
                    let style = attribute.value
                    let bytes = style.utf8.count
                    if read(bytes), namesDecoration(style) { copied.decorated = true }
                    var dashed = false
                    if read(bytes) {
                        declarations(in: style) { property, reference in
                            // A paint declaration names fill or stroke indistinguishably here; charged to
                            // both, as a declaration never lowers the charge.
                            if property.contains(.paint) {
                                copied.fillStops = max(copied.fillStops, stops(reference))
                                copied.strokeStops = max(copied.strokeStops, stops(reference))
                            }
                            if property.contains(.dash) { dashed = true }
                        }
                    }
                    // The list's longest declaration bounds every dash array in it, so it is found
                    // once for the list and not once for each dash declaration.
                    if dashed, read(bytes) { copied.dashBytes = max(copied.dashBytes, longestDeclaration(style)) }
                    if read(bytes) {
                        forEachStyleDeclaration(style) { property, valueBytes in
                            if property == "font-variation-settings" { copied.variationBytes = max(copied.variationBytes, valueBytes) }
                            else if property == "font-family" { copied.familyBytes = max(copied.familyBytes, valueBytes) }
                            else if reparsedProperties.contains(property) { copied.reparseBytes += valueBytes }
                        }
                    }
                default:
                    if reparsedProperties.contains(attribute.name) { copied.reparseBytes += attribute.value.utf8.count }
                }
            }
            var element = Element(copied: copied, kind: kind(node))
            if element.kind == .use, let id = fragment(node) { element.targets = ids[id] ?? [] }
            if element.kind == .text { element.characters = textCharacters(node) }
            elements[node.order - svg.order] = element
            return element
        }

        var copies = 0
        /// Charges the shape or text that `element` is, whose inherited values are `here`.
        func charge(_ element: Element, _ here: Copied) -> Bool {
            let fillStops = max(here.fillStops, sheetStops), strokeStops = max(here.strokeStops, sheetStops)
            let reparse = here.reparseBytes / 64
            if element.kind == .shape {
                copies += fillStops + strokeStops + here.dashBytes + sheetBytes + reparse
            } else if element.kind == .text {
                // A run resolves its style once and clones it for each of its spans, at most one span
                // per character. A long inherited value re-parses to a small resolved value that
                // clones cheaply (measured: a padded `fill`, `stroke`, `stroke-width` or
                // `letter-spacing` on a 20,000-character run stays near the floor), so it is not
                // charged per character. What is cloned in full is charged: the stops of the gradient
                // its fill and stroke name, copied into the span and each of the three text
                // decorations (four pairs); the dash array, cloned into the span's stroke and each of
                // those three decoration strokes (four copies); the font family; and the variation
                // settings, the worst per-span copy — a `Vec` held per span and again in the glyph
                // cache — so a byte of them is charged more than a re-parsed byte. A stylesheet value
                // copied onto the element is charged per character too.
                let dashCopies = here.decorated ? 4 : 1
                let perSpan = 4 * (fillStops + strokeStops) + dashCopies * here.dashBytes + here.familyBytes
                    + here.variationBytes / 8 + sheetBytes
                copies += element.characters * perSpan
            }
            return copies <= maximumSharedCopies
        }
        var activeCopies = Set<ObjectIdentifier>()
        func inheritedAbove(_ node: ContentNode) -> Copied {
            var inherited = Copied()
            var ancestor = node.parent
            while let parent = ancestor {
                inherited.raise(to: element(parent).copied)
                if parent === svg { break }
                ancestor = parent.parent
            }
            return inherited
        }
        func walk(_ node: ContentNode, above: Copied, depth: Int) -> Bool {
            let identity = ObjectIdentifier(node)
            if activeCopies.contains(identity) { return true } // Short resource loops are unlinked.
            guard step(), depth <= (resourceReferences == nil ? maximumDepth : 2 * maximumDepth) else { return false }
            activeCopies.insert(identity)
            defer { activeCopies.remove(identity) }
            let element = element(node)
            var here = above
            here.raise(to: element.copied)
            // Reading the element's `style` is charged too, and may have spent the budget.
            guard steps <= stepBudget, charge(element, here) else { return false }
            for resource in resourceReferences?[identity] ?? [] {
                var inherited = here
                inherited.raise(to: inheritedAbove(resource))
                guard walk(resource, above: inherited, depth: depth + 1) else { return false }
            }
            if element.kind == .text { return true } // Its spans are charged; its children draw nothing.
            for target in element.targets {
                guard step(), walk(target, above: here, depth: depth + 1) else { return false }
            }
            for child in node.children where child.isElement && kind(child) != .undrawn {
                guard walk(child, above: here, depth: depth + 1) else { return false }
            }
            return true
        }
        guard walk(svg, above: Copied(), depth: 0) else { return (false, copies, steps) }
        // A marker's content can take its root's mask/clip by `inherit`. Its external resources
        // convert again at each vertex, including their gradient, dash and text-span copies.
        for reference in markerResourceReferences {
            var inherited = inheritedAbove(reference.source)
            inherited.raise(to: element(reference.source).copied)
            inherited.raise(to: inheritedAbove(reference.target))
            for _ in 0..<markerInstances {
                guard walk(reference.target, above: inherited, depth: 1) else { return (false, copies, steps) }
            }
        }
        // The standalone shared-value verdict retains its once-per-mask charge.
        for mask in nodes where resourceReferences == nil && mask.name == "mask" {
            for child in mask.children where child.isElement && kind(child) != .undrawn {
                guard walk(child, above: Copied(), depth: 1) else { return (false, copies, steps) }
            }
        }
        return (true, copies, steps)
    }

    /// `copyVerdict` for an SVG on its own, for tests.
    static func copyVerdict(_ svg: ContentNode, stepBudget: Int = markerStepBudget) -> CopyVerdict {
        var nodes: [ContentNode] = []
        func collect(_ node: ContentNode) {
            nodes.append(node)
            for child in node.elementChildren { collect(child) }
        }
        collect(svg)
        return copyVerdict(svg, nodes: nodes, ids: elementsByID(nodes), stepBudget: stepBudget)
    }

    /// The characters in a `<text>` element's run, its own and its descendants', capped at the
    /// per-run bound that `textRunsAreBounded` has already applied, so the count is linear.
    private static func textCharacters(_ text: ContentNode) -> Int {
        var characters = 0
        func count(_ node: ContentNode) {
            if node.isText { characters += node.text.unicodeScalars.count }
            for child in node.children where characters <= maximumTextRunCharacters { count(child) }
        }
        count(text)
        return min(characters, maximumTextRunCharacters)
    }

    /// The size of a marker — what one instance of it costs the renderer, which converts the
    /// marker's content afresh for each — or nil when it holds anything but plain shapes. Each
    /// element in it counts one, and one more for every 32 vertices of its shape and every 64 bytes
    /// of the attributes it has or inherits, `above` being those of the elements the marker
    /// stands in: the renderer reads an inherited attribute again for every shape that inherits it.
    private static func markerSize(_ marker: ContentNode, above: Int) -> Int? {
        var size = attributeBytes(marker) / 64
        func add(_ element: ContentNode, above: Int) -> Bool {
            guard markerContent.contains(element.name), let vertices = vertices(element), !element.attributes.contains(where: {
                $0.name == "href" || $0.name == "filter" || mentions($0.value, "url(") || mentions($0.value, "filter")
            }) else { return false }
            let bytes = above + attributeBytes(element)
            size += 1 + vertices / 32 + bytes / 64
            return element.elementChildren.allSatisfy { add($0, above: bytes) }
        }
        let bytes = above + attributeBytes(marker)
        return marker.elementChildren.allSatisfy({ add($0, above: bytes) }) ? max(1, size) : nil
    }

    private static func attributeBytes(_ element: ContentNode) -> Int {
        element.attributes.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
    }

    /// Whether CSS text holds a `url(…)` that can name an element of the document.
    private static func namesElement(_ css: String) -> Bool {
        let bytes = Array(css.utf8)
        for index in bytes.indices where bytes[index] | 0x20 == UInt8(ascii: "u") {
            if holds("url(", bytes, at: index), reference(bytes, from: index) != .none { return true }
        }
        return false
    }

    /// At least the bytes of the longest value CSS text gives a property that the renderer reads in
    /// full, a dash array among them: the longest stretch between two of `;`, `{` and `}`, which
    /// no list of numbers, lengths or transforms crosses.
    private static func longestDeclaration(_ css: String) -> Int {
        var longest = 0
        var stretch = 0
        for byte in css.utf8 {
            stretch = byte == UInt8(ascii: ";") || byte == UInt8(ascii: "{") || byte == UInt8(ascii: "}") ? 0 : stretch + 1
            longest = max(longest, stretch)
        }
        return longest
    }

    /// Whether `serialize` keeps a stylesheet rather than stripping it whole. It strips one that is
    /// unsafe (holds a backslash, or a `url()` that leaves the document) or holds an `@import`, and
    /// the renderer then never sees those bytes, so this check — the same condition, by a single byte
    /// scan so a maximal stylesheet is screened cheaply — keeps the screen on this tree in step with
    /// the screen on the serialized bytes, from which such a stylesheet is gone.
    static func serializeKeepsSheet(_ css: String) -> Bool {
        let bytes = Array(css.utf8)
        let n = bytes.count
        var index = 0
        while index < n {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") { return false }
            if byte == UInt8(ascii: "@"), holds("@import", bytes, at: index) { return false }
            if byte | 0x20 == UInt8(ascii: "u"), holds("url(", bytes, at: index) {
                var cursor = index + 4
                while cursor < n, bytes[cursor] == UInt8(ascii: " ") || bytes[cursor] == UInt8(ascii: "\"") || bytes[cursor] == UInt8(ascii: "'") { cursor += 1 }
                if cursor >= n || bytes[cursor] != UInt8(ascii: "#") { return false }
            }
            index += 1
        }
        return true
    }

    /// The most bytes a single declaration the renderer copies from a `<style>` sheet onto a matched
    /// element can hold: the longest trimmed value of a presentation-property declaration in an
    /// ordinary rule. The renderer (usvg `svgtree/parse.rs`) applies a rule's declaration to an
    /// element only when its name is a presentation property (`copiedStyleProperties`); it skips
    /// at-rules (simplecss skips `@font-face`, `@media`, `@keyframes`, `@import`), so an embedded
    /// font's `src: url(data:…)` — never applied to any element — is not counted, and neither is a
    /// declaration of some other name, which the renderer drops.
    ///
    /// `copyVerdict` charges this one value, the longest, to each painted shape and to each character
    /// of a text run, so that a single very long presentation value in a stylesheet cannot be copied
    /// onto thousands of shapes for free. That is a partial bound, and not what a stylesheet costs
    /// the renderer, which stores every presentation declaration of a matched rule, each as a string
    /// of its own, on every element the rule matches (`write_declaration` and `insert_attribute` in
    /// usvg `svgtree/parse.rs`). Its cost goes as declarations times matched elements, about 65
    /// bytes for each as measured, even where every value is one character. So two things are not
    /// bounded here: what many declarations cost, a rule of dozens being charged as a rule of one;
    /// and what a rule costs on the groups and `<use>` elements it matches, which are charged
    /// nothing. A 3.3 KB drawing whose rule holds 47 one-character declarations and matches some
    /// 250,000 rects drawn through `<use>` passes with a charge of 254,080 and costs the renderer
    /// about 750 MB; one of as many empty groups, matched by its rule, is charged nothing and costs
    /// it hundreds of megabytes too. Both pass without this charge as well. Bounding that means
    /// deciding which rules can match which elements, and `SVGRenderingCostScreen` bounds it
    /// separately with the shared reference screen's last-compound-selector reader.
    ///
    /// The sheet is read twice here: once for its rules, and each rule's body once more for its
    /// declarations. A declaration can open a comment or a string that the first reading took
    /// otherwise (`a{";fill:/*"}`: one string to the first, a comment to the second), which then
    /// ends wherever its end is, past the rule and perhaps at the end of the sheet. What it is
    /// charged is the value as far as that, so the end is found as before, and `DeclarationScan`
    /// keeps where it was found: every rule of a sheet can open one, and each would otherwise read
    /// the rest of the sheet again. Each reading is charged through `read`, which is false once the
    /// budget is spent, and the result is then nil. With the reading that tells whether the sheet
    /// is kept and the one for its paints, a sheet is read eight times at most: those two, the two
    /// here, and once each at most for the comments, the strings in each kind of quote and the
    /// white space at its end that `DeclarationScan` reads.
    private static func styleSheetCopyBytes(_ css: String, read: (Int) -> Bool) -> Int? {
        let bytes = Array(css.utf8)
        let n = bytes.count
        guard read(n) else { return nil }
        var scan = DeclarationScan()
        var index = 0
        var longest = 0
        while index < n {
            let byte = bytes[index]
            if byte <= 0x20 { index += 1; continue }
            if byte == UInt8(ascii: "/"), index + 1 < n, bytes[index + 1] == UInt8(ascii: "*") { index = endOfComment(bytes, index); continue }
            if byte == UInt8(ascii: "@") { index = skipAtRule(bytes, index); continue }
            // A rule set: a selector list up to `{`, then the declarations up to the matching `}`.
            while index < n, bytes[index] != UInt8(ascii: "{"), bytes[index] != UInt8(ascii: "}") {
                if bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") { index = endOfString(bytes, index); continue }
                if bytes[index] == UInt8(ascii: "/"), index + 1 < n, bytes[index + 1] == UInt8(ascii: "*") { index = endOfComment(bytes, index); continue }
                index += 1
            }
            guard index < n, bytes[index] == UInt8(ascii: "{") else { if index < n { index += 1 }; continue }
            let bodyStart = index + 1
            index = skipBlock(bytes, index)
            let body = bodyStart..<max(bodyStart, index - 1)
            var bounded = true
            forEachDeclaration(bytes, body, &scan, valueBody: { name, range in
                if !fontSizeDeclarationIsBounded(name, bytes, range) { bounded = false }
            }) { property, valueBytes in
                if copiedStyleProperties.contains(property) { longest = max(longest, valueBytes) }
            }
            guard bounded, read(body.count + scan.bytesRead) else { return nil }
            scan.bytesRead = 0
        }
        return longest
    }

    /// Calls `body` with the lowercased name and the trimmed value byte length of each declaration in
    /// a `style` attribute's declaration list.
    private static func forEachStyleDeclaration(_ css: String, _ body: (String, Int) -> Void) {
        let bytes = Array(css.utf8)
        var scan = DeclarationScan()
        forEachDeclaration(bytes, bytes.indices, &scan, body)
    }

    /// Where the comments and strings end that `forEachDeclaration` has read in one text, kept from
    /// one range of the text to the next. A comment or a string that a declaration opens is read to
    /// its end wherever that is, and when that is past the range the scan of the range is over. The
    /// next range can open another that ends at the same place, and so can every range after it:
    /// each end is found once, and what `endOfComment` and `endOfString` would give is given from
    /// here, exactly, for every comment and string opened before it. The ranges come in order, so a
    /// scan that has to be made starts past the end the last one found, and all that are made read
    /// the text once at most for comments and once for strings in each kind of quote.
    private struct DeclarationScan {
        /// The last scans made for the end of a comment, of a string in double quotes and of one in
        /// single quotes: the byte each began at, after the opening `/*` or quote, and the byte it
        /// stopped at, which is the closing `*/` or quote, or is at the end of the text.
        private var comment: (from: Int, stop: Int)?
        private var doubleQuoted: (from: Int, stop: Int)?
        private var singleQuoted: (from: Int, stop: Int)?
        /// Where the white space that ends the text begins.
        private var tail: Int?
        /// Bytes the scans made here have read since this was last set to zero, for a caller that
        /// charges them.
        var bytesRead = 0

        /// What `SVGContent.endOfComment` gives. A scan that began at or before this one, and
        /// stopped at or after where this one begins, passed no `*/` that this one could stop at:
        /// both stop at the same byte.
        mutating func endOfComment(_ bytes: [UInt8], _ index: Int) -> Int {
            var cursor = index + 2
            if let comment, comment.from <= cursor, cursor <= comment.stop {
                cursor = comment.stop
            } else {
                let from = cursor
                while cursor + 1 < bytes.count, !(bytes[cursor] == UInt8(ascii: "*") && bytes[cursor + 1] == UInt8(ascii: "/")) { cursor += 1 }
                comment = (from, cursor)
                bytesRead += cursor - from
            }
            return min(cursor + 2, bytes.count)
        }

        /// What `SVGContent.endOfString` gives. An earlier scan for the same quote that stopped at
        /// or after where this one begins did not stop at this string's opening quote, so it took
        /// that quote as escaped and went on from the byte after it, where this one begins: both
        /// stop at the same byte, escapes and all.
        mutating func endOfString(_ bytes: [UInt8], _ index: Int) -> Int {
            let quote = bytes[index]
            let known = quote == UInt8(ascii: "\"") ? doubleQuoted : singleQuoted
            var cursor = index + 1
            if let known, known.from <= cursor, cursor <= known.stop {
                cursor = known.stop
            } else {
                let from = cursor
                while cursor < bytes.count, bytes[cursor] != quote { cursor += bytes[cursor] == UInt8(ascii: "\\") ? 2 : 1 }
                if quote == UInt8(ascii: "\"") { doubleQuoted = (from, cursor) } else { singleQuoted = (from, cursor) }
                bytesRead += min(cursor, bytes.count) - from
            }
            return min(cursor + 1, bytes.count)
        }

        /// Where a value that runs to the end of the text ends once its trailing white space is
        /// dropped, and no earlier than `low`. A comment or a string that nothing closes runs to
        /// the end of the text from every range that opens one.
        mutating func endOfValue(_ bytes: [UInt8], from low: Int) -> Int {
            if tail == nil {
                var start = bytes.count
                while start > 0, bytes[start - 1] <= 0x20 { start -= 1 }
                tail = start
                bytesRead += bytes.count - start
            }
            return max(low, tail ?? low)
        }
    }

    /// Calls `body` with the lowercased name and trimmed value byte length of each `name: value`
    /// declaration in `range` of `bytes`. A `;` inside a string, comment or parentheses does not end
    /// a declaration, and the value's leading and trailing white space is dropped, as simplecss drops
    /// it before storing the value: a value padded with white space costs the renderer nothing.
    /// A comment or a string still open at the end of `range` is read to its own end, past it, and
    /// the value is counted that far; `scan` keeps the ends found, for the next range of the text.
    private static func forEachDeclaration(_ bytes: [UInt8], _ range: Range<Int>, _ scan: inout DeclarationScan,
                                           valueBody: ((String, Range<Int>) -> Void)? = nil,
                                           _ body: (String, Int) -> Void) {
        var index = range.lowerBound
        let end = range.upperBound
        while index < end {
            while index < end, bytes[index] <= 0x20 || bytes[index] == UInt8(ascii: ";") { index += 1 }
            if index < end, bytes[index] == UInt8(ascii: "/"), index + 1 < end, bytes[index + 1] == UInt8(ascii: "*") {
                index = scan.endOfComment(bytes, index); continue
            }
            // simplecss strips one leading '*' (the IE7 property hack), consumes an identifier,
            // then skips whitespace/comments before ':'. In particular a colon inside that
            // comment cannot terminate the property name. Keep the historical malformed-name
            // recovery of this conservative scanner, but canonicalize every name it charges.
            let nameStart = index
            var firstComment: Int?
            var canonicalizesComment: Bool?
            var validNameTail = true
            while index < end, bytes[index] != UInt8(ascii: ":"), bytes[index] != UInt8(ascii: ";"),
                  bytes[index] != UInt8(ascii: "{"), bytes[index] != UInt8(ascii: "}") {
                if bytes[index] == UInt8(ascii: "/"), index + 1 < end, bytes[index + 1] == UInt8(ascii: "*") {
                    if canonicalizesComment == nil {
                        var prefix = String(decoding: bytes[nameStart..<index], as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if prefix.first == "*" { prefix.removeFirst() }
                        canonicalizesComment = copiedStyleProperties.contains(prefix)
                    }
                    // Only names this scanner charges need renderer canonicalization. Keep its
                    // existing conservative recovery for malformed unknown names (including
                    // comments a rule's string scan interpreted differently).
                    if canonicalizesComment == true {
                        if firstComment == nil { firstComment = index }
                        index = scan.endOfComment(bytes, index)
                    } else { index += 1 }
                } else {
                    if firstComment != nil, bytes[index] > 0x20 { validNameTail = false }
                    index += 1
                }
            }
            guard index < end, bytes[index] == UInt8(ascii: ":") else { if index < end { index += 1 }; continue }
            var start = nameStart
            if bytes[start] == UInt8(ascii: "*") { start += 1 }
            var stop = firstComment ?? index
            while stop > start, bytes[stop - 1] <= 0x20 { stop -= 1 }
            // A comment inside the identifier is not an identifier continuation. Between its
            // first comment and the colon only whitespace and more comments are allowed.
            var name = String(decoding: bytes[start..<stop], as: UTF8.self).lowercased()
            if !validNameTail { name = "" }
            index += 1
            // simplecss also drops whitespace and comments before the first value term. A
            // shorthand's leading comment must not hide its actual size token from the cap.
            if name == "font" || name == "font-size" {
                while index < end {
                    if bytes[index] <= 0x20 { index += 1 }
                    else if bytes[index] == UInt8(ascii: "/"), index + 1 < end,
                            bytes[index + 1] == UInt8(ascii: "*") { index = scan.endOfComment(bytes, index) }
                    else { break }
                }
            }
            var depth = 0
            let valueStart = index
            while index < end {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") { index = scan.endOfString(bytes, index); continue }
                if byte == UInt8(ascii: "/"), index + 1 < end, bytes[index + 1] == UInt8(ascii: "*") { index = scan.endOfComment(bytes, index); continue }
                if byte == UInt8(ascii: "(") || byte == UInt8(ascii: "[") { depth += 1 }
                else if byte == UInt8(ascii: ")") || byte == UInt8(ascii: "]") { depth = max(0, depth - 1) }
                else if depth == 0, byte == UInt8(ascii: ";") || byte == UInt8(ascii: "{") || byte == UInt8(ascii: "}") { break }
                index += 1
            }
            var low = valueStart, high = index
            while low < high, bytes[low] <= 0x20 { low += 1 }
            if low < high, high == bytes.count { high = scan.endOfValue(bytes, from: low) }
            else { while high > low, bytes[high - 1] <= 0x20 { high -= 1 } }
            if !name.isEmpty {
                body(name, high - low)
                valueBody?(name, low..<high)
            }
        }
    }

    /// Bound the value usvg stores as font-size, including the size token of the CSS font
    /// shorthand. svgtypes 0.16.1 consumes at most four optional style/variant/weight/stretch
    /// identifiers, then a length or a size keyword; the family and optional line height follow
    /// that size. They are not repeatedly parsed as font-size and retain their existing limits.
    private static func fontSizeDeclarationIsBounded(_ name: String, _ bytes: [UInt8], _ range: Range<Int>) -> Bool {
        guard name == "font-size" || name == "font" else { return true }
        var end = range.upperBound
        // simplecss strips the trailing priority before storing a declaration value.
        if end - range.lowerBound >= 9, holds("important", bytes, at: end - 9) {
            var priority = end - 9
            while priority > range.lowerBound, bytes[priority - 1] <= 0x20 { priority -= 1 }
            if priority > range.lowerBound, bytes[priority - 1] == UInt8(ascii: "!") {
                end = priority - 1
                while end > range.lowerBound, bytes[end - 1] <= 0x20 { end -= 1 }
            }
        }
        if name == "font-size" { return end - range.lowerBound <= maximumFontSizeValueBytes }
        let optional: Set<String> = ["normal", "small-caps", "italic", "oblique", "bold", "bolder", "lighter",
            "100", "200", "300", "400", "500", "600", "700", "800", "900", "ultra-condensed",
            "extra-condensed", "condensed", "semi-condensed", "semi-expanded", "expanded", "extra-expanded", "ultra-expanded"]
        var index = range.lowerBound
        for _ in 0..<4 {
            let start = index
            while index < end, index - start <= maximumFontSizeValueBytes,
                (bytes[index] >= 0x61 && bytes[index] <= 0x7A)
                || (bytes[index] >= 0x41 && bytes[index] <= 0x5A)
                || (bytes[index] >= 0x30 && bytes[index] <= 0x39) || bytes[index] == 0x2D { index += 1 }
            if !optional.contains(String(decoding: bytes[start..<index], as: UTF8.self)) { index = start; break }
            while index < end, bytes[index] <= 0x20 { index += 1 }
        }
        let start = index
        // No valid font-size token crosses whitespace or '/'. Counting the whole token also
        // bounds a malformed suffix that the renderer may treat as the start of a family.
        while index < end, index - start <= maximumFontSizeValueBytes,
              bytes[index] > 0x20, bytes[index] != UInt8(ascii: "/") { index += 1 }
        return index - start <= maximumFontSizeValueBytes
    }

    /// The index just past the `/* … */` comment whose `/*` is at `index`.
    private static func endOfComment(_ bytes: [UInt8], _ index: Int) -> Int {
        var cursor = index + 2
        while cursor + 1 < bytes.count, !(bytes[cursor] == UInt8(ascii: "*") && bytes[cursor + 1] == UInt8(ascii: "/")) { cursor += 1 }
        return min(cursor + 2, bytes.count)
    }

    /// The index just past the quoted string whose opening quote is at `index`.
    private static func endOfString(_ bytes: [UInt8], _ index: Int) -> Int {
        let quote = bytes[index]
        var cursor = index + 1
        while cursor < bytes.count {
            if bytes[cursor] == UInt8(ascii: "\\") { cursor += 2; continue }
            if bytes[cursor] == quote { return cursor + 1 }
            cursor += 1
        }
        return bytes.count
    }

    /// The index past an at-rule beginning at `index` (`@`): just after its `{ … }` block, or just
    /// after its terminating `;`, as simplecss skips an unsupported at-rule.
    private static func skipAtRule(_ bytes: [UInt8], _ index: Int) -> Int {
        var cursor = index
        let n = bytes.count
        while cursor < n {
            let byte = bytes[cursor]
            if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") { cursor = endOfString(bytes, cursor); continue }
            if byte == UInt8(ascii: "/"), cursor + 1 < n, bytes[cursor + 1] == UInt8(ascii: "*") { cursor = endOfComment(bytes, cursor); continue }
            if byte == UInt8(ascii: ";") { return cursor + 1 }
            if byte == UInt8(ascii: "{") { return skipBlock(bytes, cursor) }
            cursor += 1
        }
        return cursor
    }

    /// The index just past the `{ … }` block whose `{` is at `index`, matching nested braces.
    private static func skipBlock(_ bytes: [UInt8], _ index: Int) -> Int {
        var cursor = index
        let n = bytes.count
        var depth = 0
        while cursor < n {
            let byte = bytes[cursor]
            if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") { cursor = endOfString(bytes, cursor); continue }
            if byte == UInt8(ascii: "/"), cursor + 1 < n, bytes[cursor + 1] == UInt8(ascii: "*") { cursor = endOfComment(bytes, cursor); continue }
            if byte == UInt8(ascii: "{") { depth += 1 }
            else if byte == UInt8(ascii: "}") { depth -= 1; if depth == 0 { return cursor + 1 } }
            cursor += 1
        }
        return cursor
    }

    /// An upper bound on the segments of a shape's geometry — the positions a `marker-mid` is drawn
    /// at, and the points each instance of a marker's own shape stores — or nil when its text does
    /// not bound them. Geometry is read from every attribute of the name, in any namespace, as the
    /// renderer accepts more than one. Path data and points give at most one segment for each
    /// number and one more for each close, after which the renderer starts a new subpath. A
    /// `circle`, an `ellipse` and a rounded `rect` are flattened into a number of segments that
    /// grows with the radius, bounded by `arcSegments`. A path with an elliptical arc is the one
    /// whose segments nothing in its text bounds: the radius the renderer flattens it by depends
    /// on where its end points fall.
    private static func vertices(_ shape: ContentNode) -> Int? {
        var numbers = 0
        var closes = 0
        var arc = false
        var radius: Double? = 0
        for attribute in shape.attributes {
            switch attribute.name {
            case "d", "points":
                var dots = -1 // The dots in the run of digits and dots being read; -1 outside one.
                for byte in attribute.value.utf8 {
                    if byte == UInt8(ascii: ".") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                        dots = max(dots, 0) + (byte == UInt8(ascii: ".") ? 1 : 0)
                        continue
                    }
                    // Every number has a digit, and a run of digits and dots holds as many numbers
                    // as it has dots, or one.
                    if dots >= 0 { numbers += max(1, dots); dots = -1 }
                    if byte == UInt8(ascii: "z") || byte == UInt8(ascii: "Z") { closes += 1 }
                    if byte == UInt8(ascii: "a") || byte == UInt8(ascii: "A") { arc = true }
                }
                if dots >= 0 { numbers += max(1, dots) }
            case "r", "rx", "ry":
                // A length with a unit or a percentage is not bounded here.
                radius = Double(attribute.value).flatMap { value in radius.map { max($0, abs(value)) } }
            default: break
            }
        }
        switch shape.name {
        case "path": return arc ? nil : numbers + closes
        case "polyline", "polygon": return numbers
        case "line": return 2
        case "rect": return radius == 0 ? 5 : radius.flatMap(arcSegments).map { 5 + $0 }
        case "circle", "ellipse": return radius.flatMap(arcSegments)
        default: return 0
        }
    }

    /// A sound upper bound on the cubic segments the renderer flattens a full ellipse of the given
    /// radius into, over-estimating `kurbo`'s per-arc count (`n_err = max((11.163·r)^(1/6), 4)`,
    /// tolerance 0.1, summed over four quarter arcs) with headroom; nil when there is none.
    private static func arcSegments(_ radius: Double) -> Int? {
        let nErr = max(pow(11.163 * radius, 1.0 / 6.0), 4.0)
        guard nErr.isFinite, nErr < Double(maximumMarkerInstances) else { return nil }
        return Int(nErr.rounded(.up)) + 8
    }

    /// Calls `body` with every declaration in CSS text of a property this check reads, and what its
    /// value can name: one for each name `propertyNames` finds that ends in the property's name.
    private static func declarations(in css: String, _ body: (Property, Reference) -> Void) {
        let bytes = Array(css.utf8)
        propertyNames(in: bytes) { name, next in
            func ends(_ suffix: StaticString) -> Bool {
                name.count >= suffix.utf8CodeUnitCount && holds(suffix, bytes, at: name.upperBound - suffix.utf8CodeUnitCount)
            }
            var property: Property = []
            if ends("marker") { property = .markers }
            if ends("marker-start") { property = .start }
            if ends("marker-mid") { property = .mid }
            if ends("marker-end") { property = .end }
            if ends("fill") || ends("stroke") { property = .paint }
            if ends("dasharray") { property = .dash }
            if !property.isEmpty { body(property, bytes[next] == UInt8(ascii: ":") ? reference(bytes, from: next + 1) : .unknown) }
        }
    }

    /// Calls `body` with every name in CSS text that the renderer's tokenizer could read a
    /// declaration of, and where what follows it after white space is: each one it can find and
    /// more, since nothing is skipped. A name is any run of name characters, in either case, that
    /// is followed after white space by a colon, or by a `/`, which may open a comment before
    /// one, wherever it stands — in a string, a comment or another declaration's value. The
    /// tokenizer can begin a name part way through such a run, as it does after `!important`, but
    /// ends it where the run ends, so the property it reads is the run's last characters.
    private static func propertyNames(in bytes: [UInt8], _ body: (_ name: Range<Int>, _ next: Int) -> Void) {
        var index = 0
        while index < bytes.count {
            guard isNameByte(bytes[index]) else { index += 1; continue }
            let start = index
            while index < bytes.count, isNameByte(bytes[index]) { index += 1 }
            var cursor = index
            while cursor < bytes.count, bytes[cursor] <= 0x20 { cursor += 1 }
            // A comment may stand before the colon; what follows it is then not read.
            guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: ":") || bytes[cursor] == UInt8(ascii: "/") else { continue }
            body(start..<index, cursor)
        }
    }

    /// An ASCII letter, a digit, `-` or `_`.
    private static func isNameByte(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte | 0x20)
    }

    /// Whether `bytes` hold the ASCII `text` at `index`, letters compared without case. `text` is in
    /// lower case.
    private static func holds(_ text: StaticString, _ bytes: [UInt8], at index: Int) -> Bool {
        guard index + text.utf8CodeUnitCount <= bytes.count else { return false }
        return text.withUTF8Buffer { expected in
            for offset in expected.indices {
                let byte = bytes[index + offset]
                guard ((UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte | 0x20 : byte) == expected[offset] else { return false }
            }
            return true
        }
    }

    /// What a property value names, read from `index`. A value the renderer resolves begins, after
    /// white space, `url(`, then white space, an optional quote and `#`. A value that does not names
    /// nothing. One in the plain form `url(#id)`, or quoted as a browser writes it, `url("#id")`,
    /// names that id. Any other is taken to name an element not known: one after a comment, one
    /// with white space inside it, one whose id holds a quote or a parenthesis.
    private static func reference(_ bytes: [UInt8], from index: Int) -> Reference {
        var cursor = index
        // More than the renderer skips, so that this never stops short of a `url(` it reaches.
        func skipSpace() { while cursor < bytes.count, bytes[cursor] <= 0x20 || bytes[cursor] >= 0x80 { cursor += 1 } }
        func isQuote(_ byte: UInt8) -> Bool { byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") }
        skipSpace()
        if holds("/*", bytes, at: cursor) { return .unknown }
        guard holds("url(", bytes, at: cursor) else { return .none }
        cursor += 4
        skipSpace()
        guard cursor < bytes.count else { return .unknown }
        let quote = isQuote(bytes[cursor]) ? bytes[cursor] : nil
        if quote != nil { cursor += 1 }
        guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: "#") else { return quote == nil ? .none : .unknown }
        let start = cursor + 1
        cursor = start
        func endsID(_ byte: UInt8) -> Bool {
            switch byte {
            case 0...0x20, UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "#"), UInt8(ascii: "\\"), UInt8(ascii: ";"): true
            default: isQuote(byte)
            }
        }
        while cursor < bytes.count, !endsID(bytes[cursor]) { cursor += 1 }
        let end = cursor
        if let quote {
            // The renderer trims white space of any kind from the end of a quoted id.
            guard cursor < bytes.count, bytes[cursor] == quote, bytes[start..<end].allSatisfy({ $0 < 0x80 }) else { return .unknown }
            cursor += 1
        }
        guard end > start, cursor < bytes.count, bytes[cursor] == UInt8(ascii: ")") else { return .unknown }
        return .id(EPUBElementID(String(decoding: bytes[start..<end], as: UTF8.self)))
    }

    /// Whether a `text-decoration` value names a line the renderer draws (`underline`, `overline` or
    /// `line-through`), each of which carries its own stroke that clones the span's dash array.
    private static func namesDecoration(_ value: String) -> Bool {
        mentions(value, "underline") || mentions(value, "overline") || mentions(value, "line-through")
    }

    /// Whether `text` holds the ASCII `word`, letters compared without case. `word` is in lower
    /// case and its first byte occurs nowhere else in it, so a failed match restarts at that byte.
    private static func mentions(_ text: String, _ word: String) -> Bool {
        let word = Array(word.utf8)
        var matched = 0
        for byte in text.utf8 {
            let lowered = (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte | 0x20 : byte
            matched = lowered == word[matched] ? matched + 1 : (lowered == word[0] ? 1 : 0)
            if matched == word.count { return true }
        }
        return false
    }

    /// The direct renderer entry point is also used by tests and inspection. Validate data
    /// image headers before Rust can decode them; arbitrary strings are denied by its resolver.
    /// Its `data:` URLs are read as the renderer reads them, by the data: URL processor
    /// (`DataURL`), and it decodes only the four bitmap types.
    static func preparedImagesAreBounded(_ svg: ContentNode) -> Bool {
        var pixels = 0
        var bytes = 0
        func visit(_ node: ContentNode) -> Bool {
            if node.name == "image", let reference = href(node), DataURL.isDataURL(reference) {
                guard let url = DataURL(reference, maximumBytes: maximumInlinedImageBytes - bytes),
                      ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(url.mediaType),
                      let source = ReaderImageSource.bitmap(url.body, path: "", key: "svg-preflight"),
                      source.pixelSize.width * source.pixelSize.height <= CGFloat(maximumImagePixels) else { return false }
                let count = Int(source.pixelSize.width * source.pixelSize.height)
                guard count <= maximumTotalImagePixels - pixels else { return false }
                pixels += count; bytes += url.body.count
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
        var nodes: [ContentNode] = []
        var styledLayers = false
        func collect(_ node: ContentNode) {
            nodes.append(node)
            if node.name == "style", node.textContent.range(of: "(?i)(opacity|clip-path|mask|mix-blend-mode|isolation)\\s*:", options: .regularExpression) != nil { styledLayers = true }
            for child in node.elementChildren { collect(child) }
        }
        collect(svg)
        let ids = elementsByID(nodes)
        var cache: [ObjectIdentifier: Int] = [:]
        func count(_ node: ContentNode) -> Int {
            let key = ObjectIdentifier(node)
            if let cached = cache[key] { return cached }
            let isolates = styledLayers || ((node.name == "svg" && node !== svg) || node.name == "symbol") || ["clipPath", "mask", "pattern"].contains(node.name) ||
                ["opacity", "clip-path", "mask", "mix-blend-mode", "isolation"].contains(where: { node.attribute($0) != nil }) ||
                node.attribute("style")?.range(of: "(?i)(opacity|clip-path|mask|mix-blend-mode|isolation)\\s*:", options: .regularExpression) != nil
            var result = isolates ? 1 : 0
            for child in node.elementChildren { result += count(child) }
            if node.name == "use", let id = fragment(node) { for target in ids[id] ?? [] { result += count(target) } }
            cache[key] = result
            return result
        }
        return count(svg)
    }

    static func fontFamilies(_ svg: ContentNode) -> Set<String> {
        guard SVGStyleScreen.verdict(svg).withinLimits else { return [] }
        var result = Set<String>()
        let expression = try! NSRegularExpression(pattern: "(?i)font-family\\s*:\\s*([^;}]+)")
        func add(_ value: String) {
            for family in familyNames(value) where !family.name.isEmpty { result.insert(family.name.lowercased()) }
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

    /// The names in a `font-family` list, each as written and trimmed of white space and quotes.
    /// The list is split at every comma by scalar, so that a mark after a comma does not join the
    /// names on either side of it (#248); empty names are dropped, as they were before.
    private static func familyNames(_ value: String) -> [(written: String, name: String)] {
        value.unicodeScalars.split(separator: ",").map { scalars in
            var written = ""
            written.unicodeScalars.append(contentsOf: scalars)
            return (written, written.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))))
        }
    }

    /// An embedded font's own family name between single quotes, to stand for the family a
    /// drawing names; nil when it holds anything but letters, marks, digits, spaces and `-`, `_`,
    /// `.`, `&` and `+`, and the family is then left as the drawing names it. The name is read
    /// from the font file (`CTFontCopyFamilyName`), which is book content: a quote or a backslash
    /// in it would end the string, and what follows would be read as CSS of its own, a
    /// declaration or a rule the drawing did not hold (#248).
    static func quotedFamily(_ name: String) -> String? {
        let plain = !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber: true
            default: " -_.&+".unicodeScalars.contains(scalar)
            }
        }
        return plain ? "'" + name + "'" : nil
    }

    /// The intrinsic size of an SVG box in points: absolute `width`/`height` attributes, with
    /// the authored viewport preserved; else the viewBox; else `fallback`. The renderer
    /// applies the viewBox's preserveAspectRatio inside this viewport. A viewBox so thin that
    /// the dimension its ratio gives overflows sizes nothing: `fallback` stands in.
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

    /// The SVG subtree as a standalone, sanitized document. `resolve` maps a reference to an
    /// archive path; nil for anything that cannot be used. An `<image>` in a `data:` URL is not
    /// given to it: it is read from the URL's own bytes (`boundedDataImage`).
    static func serialize(_ svg: ContentNode, resolve: (String) -> String?, publication: EPUBPublication,
                          fontAliases: [String: String] = [:], report: SectionReportBox? = nil,
                          visitedImagePaths: Set<String> = [], imagePreparation: SVGImagePreparation? = nil) -> Data? {
        let preparation = imagePreparation ?? SVGImagePreparation()
        guard preparation.permitsWork() else { return nil }
        // Filters remain refused by the direct renderer. The archive path can preserve the
        // drawing by omitting effects before handing it to that same strict entry point.
        // Count the original tree first, so omitted definitions cannot evade input bounds.
        guard isWithinRenderingLimits(svg, omittingFilters: true) else { return nil }
        var output = ""
        var inlined = 0
        var imagePixels = 0
        var overflow = false
        func family(_ value: String) -> String {
            familyNames(value).map { family in
                fontAliases[family.name.lowercased()].flatMap(quotedFamily) ?? family.written
            }.joined(separator: ",")
        }
        func css(_ value: String, sheet: Bool) -> String {
            let expression = try! NSRegularExpression(pattern: "(?i)(font-family\\s*:\\s*)([^;}]+)")
            let string = value as NSString
            var result = value
            for match in expression.matches(in: value, range: NSRange(location: 0, length: string.length)).reversed() {
                if let range = Range(match.range(at: 2), in: result) { result.replaceSubrange(range, with: family(string.substring(with: match.range(at: 2)))) }
            }
            return omittingFilterDeclarations(result, sheet: sheet).css
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
                // A parser reads a literal tab or line end in an attribute value as a space, and a
                // literal carriage return in text as a line feed. Written as references, each is
                // read back as it stands here, so a class list or an `href` means what it did.
                case "\t" where attribute: result += "&#9;"
                case "\n" where attribute: result += "&#10;"
                case "\r": result += "&#13;"
                default: result.unicodeScalars.append(character)
                }
            }
            return result
        }
        func write(_ text: String) {
            guard !overflow, preparation.consumeSerializedBytes(text.utf8.count) else { overflow = true; return }
            output += text
            if output.utf8.count > maximumBytes { overflow = true }
        }
        func emit(_ node: ContentNode, isRoot: Bool) {
            guard !overflow else { return }
            if node.isText { write(escape(node.text, attribute: false)); return }
            guard isSVG(node, root: svg), !dropped.contains(node.name), node.name != "filter" else { return }
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
                guard name != "xmlns", !name.hasPrefix("xmlns:"), !local.hasPrefix("on"), local != "base", local != "filter" else { continue }
                var value = attribute.value
                if local == "href" || local == "src" {
                    let reference = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !reference.hasPrefix("#") {
                        // An image in a `data:` URL is read from the URL's own bytes, and is never
                        // resolved: it names no archive file and is no refused resource (#657).
                        let prepared: (Data, Int)?
                        if node.name != "image" {
                            prepared = nil
                        } else if DataURL.isDataURL(reference) {
                            prepared = boundedDataImage(reference, publication: publication, fontAliases: fontAliases,
                                report: report, visited: visitedImagePaths, preparation: preparation,
                                maximumBytes: maximumInlinedImageBytes - inlined, maximumPixels: maximumTotalImagePixels - imagePixels)
                        } else if let path = resolve(reference) {
                            prepared = boundedArchiveImage(at: path, publication: publication,
                                fontAliases: fontAliases, report: report, visited: visitedImagePaths,
                                preparation: preparation, maximumBytes: maximumInlinedImageBytes - inlined,
                                maximumPixels: maximumTotalImagePixels - imagePixels)
                        } else {
                            prepared = nil
                        }
                        guard let (data, pixels) = prepared,
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
                if local == "style" { value = css(value, sheet: false) }
                write(" \(name)=\"\(escape(value, attribute: true))\"")
            }
            if node.name == "style" {
                write(">" + escape(css(node.textContent, sheet: true), attribute: false) + "</style>")
                return
            }
            if node.children.isEmpty { write("/>"); return }
            write(">")
            for child in node.children { emit(child, isRoot: false) }
            write("</\(node.name)>")
        }
        emit(svg, isRoot: true)
        return overflow ? nil : Data(output.utf8)
    }

    /// The first bounded drawable image in a manifest chain. The shared preparation context
    /// memoizes a repeated DAG, charges work before parsing/decoding, and keeps ancestor-aware
    /// cycle/depth and font/report semantics for every reference.
    private static func boundedArchiveImage(at path: String, publication: EPUBPublication,
                                            fontAliases: [String: String], report: SectionReportBox?,
                                            visited: Set<String>, preparation: SVGImagePreparation,
                                            maximumBytes: Int, maximumPixels: Int) -> (Data, Int)? {
        let prepared = preparation.request(at: path, ancestors: visited, fonts: fontAliases,
            maximumBytes: maximumBytes, maximumPixels: maximumPixels) {
            let paths: [String]
            if let resource = publication.manifestResource(at: path) {
                paths = NativeFallbacks.resources(for: resource, in: publication).filter(NativeFallbacks.isImage).map(\.path)
            } else { paths = [path] }
            for candidate in paths where !ResourceReference.isRemote(candidate) {
                let prepared = preparation.image(at: candidate, ancestors: visited, fonts: fontAliases,
                    maximumBytes: maximumBytes, maximumPixels: maximumPixels,
                    load: { try? publication.data(at: candidate) }) { bytes in
                    preparedImage(bytes, path: candidate, key: candidate, mediaType: publication.manifestResource(at: candidate)?.mediaType,
                                  publication: publication, fontAliases: fontAliases, visited: visited, preparation: preparation,
                                  maximumBytes: maximumBytes, maximumPixels: maximumPixels)
                }
                if let prepared { return prepared }
                if !preparation.hasRemainingVisits { break }
            }
            return nil
        }
        guard let prepared else { return nil }
        SVGImagePreparation.replay(prepared.report, into: report)
        return (prepared.data, prepared.pixels)
    }

    /// The image a `data:` URL holds, read by the data: URL processor (`DataURL`) and prepared
    /// as an archive image is (`preparedImage`), under the same memo and work budget, known by a
    /// digest of the URL in place of a path. Its type stands for a manifest's, so one that is not
    /// an image's is no image. Having no path, a drawing in it resolves no reference against the
    /// archive, as the URL Standard parses none against a `data:` URL.
    private static func boundedDataImage(_ reference: String, publication: EPUBPublication,
                                         fontAliases: [String: String], report: SectionReportBox?,
                                         visited: Set<String>, preparation: SVGImagePreparation,
                                         maximumBytes: Int, maximumPixels: Int) -> (Data, Int)? {
        // A key no archive path can be: a path has no NUL.
        let key = "\u{0}data:" + SHA256.hash(data: Data(reference.utf8)).map { String(format: "%02x", $0) }.joined()
        var mediaType = ""
        let prepared = preparation.image(at: key, ancestors: visited, fonts: fontAliases,
            maximumBytes: maximumBytes, maximumPixels: maximumPixels,
            load: {
                guard let url = DataURL(reference, maximumBytes: maximumInlinedImageBytes), url.mediaType.hasPrefix("image/") else { return nil }
                mediaType = url.mediaType
                return url.body
            }) { bytes in
            preparedImage(bytes, path: "", key: key, mediaType: mediaType, publication: publication, fontAliases: fontAliases,
                          visited: visited, preparation: preparation, maximumBytes: maximumBytes, maximumPixels: maximumPixels)
        }
        guard let prepared else { return nil }
        SVGImagePreparation.replay(prepared.report, into: report)
        return (prepared.data, prepared.pixels)
    }

    /// An image's bytes as a drawing inlines them: a bitmap ImageIO reads, or an SVG sanitized
    /// and drawn by the renderer, decoded within the drawing's pixel limits and written as PNG.
    /// `key` names the image in the memo and among the ancestors of what a drawing in it draws.
    /// An SVG resolves its references against `path`; one with no path resolves none.
    private static func preparedImage(_ bytes: Data, path: String, key: String, mediaType: String?,
                                      publication: EPUBPublication, fontAliases: [String: String],
                                      visited: Set<String>, preparation: SVGImagePreparation,
                                      maximumBytes: Int, maximumPixels: Int) -> SVGImagePreparation.Image? {
        guard bytes.count <= maximumInlinedImageBytes, preparation.permitsWork() else { return nil }
        let localReport = SectionReportBox()
        let source: ReaderImageSource
        let svgResource = ImageType.mediaType(of: bytes) == nil && ImageType.isSVG(bytes, path: path, mediaType: mediaType)
        if !svgResource, let bitmap = ReaderImageSource.bitmap(bytes, path: path, key: "svg-inline-" + key) {
            guard bitmap.pixelSize.width * bitmap.pixelSize.height <= CGFloat(maximumTotalImagePixels) else { return nil }
            source = bitmap
        } else {
            guard svgResource,
                  let document = try? ContentDocument.parse(bytes, path: path, asContent: false),
                  document.root.name == "svg", isSVG(document.root, root: document.root) else { return nil }
            let resolve: (String) -> String? = { reference in
                guard !path.isEmpty, let resolved = try? ResourceReference.resolve(reference, relativeTo: path) else { return nil }
                return String(resolved.split(separator: "#", maxSplits: 1)[0]).removingPercentEncoding
            }
            guard let serialized = serialize(document.root, resolve: resolve, publication: publication,
                fontAliases: fontAliases, report: localReport, visitedImagePaths: visited.union([key]),
                imagePreparation: preparation), preparation.reserveRasterPixels(64 * 64),
                let svg = ReaderImageSource.svg(serialized, path: path, key: "svg-inline-" + key) else { return nil }
            source = svg
        }
        // ImageIO does not enlarge bitmaps; SVG's rasterizer does. Reserve the upper
        // bound before the actual decode, including its aspect ratio and rounding.
        let long = max(source.pixelSize.width, source.pixelSize.height)
        let scale = source.format == .bitmap ? min(1, 2048 / long) : 2048 / long
        let width = max(1, Int(ceil(source.pixelSize.width * scale)))
        let height = max(1, Int(ceil(source.pixelSize.height * scale)))
        guard height > 0, width <= maximumImagePixels / height,
              width * height <= maximumPixels, maximumBytes >= 128 else { preparation.refuse(); return nil }
        guard preparation.reserveRasterPixels(width * height), preparation.permitsWork(),
              let image = source.decode(maxPixelSize: 2048), image.height > 0,
              image.width <= maximumImagePixels / image.height else { return nil }
        let output = NSMutableData()
        guard preparation.permitsWork(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumInlinedImageBytes else { return nil }
        return SVGImagePreparation.Image(data: output as Data, pixels: image.width * image.height, report: localReport.report)
    }

    /// The CSS of a `style` attribute, or of a stylesheet (`sheet`), without its `filter`
    /// declarations, the rest kept as the renderer reads it, and whether it had any. The text is
    /// read by byte, so that a mark after a quote or a bracket hides no delimiter (#248), and in
    /// up to three passes, each over what the one before left:
    ///
    ///  1. As a browser reads it: a declaration is what lies between two of `;`, `{` and `}`
    ///     outside strings, comments and brackets. One named `filter` in any case, or with a name
    ///     holding an escape, which could spell it, is removed with its `;`.
    ///  2. Where a name is left that the renderer's tokenizer could begin a `filter` declaration
    ///     at, found as `declarations(in:)` finds the marker properties (`filterNames`), as the
    ///     renderer reads it (`SVGReferenceScreen.CSSReader`). It finds a declaration the first
    ///     pass does not, straight after `!important` or a `*` (#253), and each it reads as
    ///     `filter` is cut so that it reads the rest as it did.
    ///  3. Each such name still left is blanked, and where that leaves another, every run of
    ///     name characters that ends in `filter`, wherever it stands.
    ///
    /// The third pass is the guarantee, should the reading of the second differ from the
    /// renderer's: a declaration the renderer reads as `filter` has such a name, so none is left.
    /// Each pass is linear in the text, and so is each search for names, of which there are four
    /// at most. Text without the letters of `filter` or a backslash is read only to look for
    /// them, and the second pass, which costs what the other screens' readings of a stylesheet
    /// cost, is made only for text in which the first left a name. What the worst text of
    /// `maximumBytes` costs is on #253.
    static func omittingFilterDeclarations(_ value: String, sheet: Bool) -> (css: String, omitted: Bool) {
        guard mentions(value, "filter") || value.utf8.contains(UInt8(ascii: "\\")) else { return (value, false) }
        var (bytes, omitted) = omittingNamedFilters(Array(value.utf8))
        var names = filterNames(in: bytes)
        guard !names.isEmpty else { return omitted ? (String(decoding: bytes, as: UTF8.self), true) : (value, false) }
        if let spliced = SVGReferenceScreen.CSSReader.omittingFilters(bytes, sheet: sheet) {
            bytes = spliced
            names = filterNames(in: bytes)
        }
        blank(names, in: &bytes)
        return (String(decoding: bytes, as: UTF8.self), true)
    }

    /// The first pass of `omittingFilterDeclarations`. Boundaries inside strings, comments and
    /// brackets are not declaration boundaries.
    private static func omittingNamedFilters(_ bytes: [UInt8]) -> (bytes: [UInt8], omitted: Bool) {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var start = 0
        var index = 0
        var quote: UInt8?
        var comment = false
        var nesting = 0
        var omitted = false
        func append(until end: Int, declaration: Bool) -> Bool {
            if declaration, namesFilter(bytes, start..<end) {
                omitted = true
                return true
            }
            output += bytes[start..<end]
            return false
        }
        while index < bytes.count {
            let byte = bytes[index]
            let opensOrClosesComment = index + 1 < bytes.count
                && (comment ? byte == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")
                            : byte == UInt8(ascii: "/") && bytes[index + 1] == UInt8(ascii: "*"))
            if comment {
                if opensOrClosesComment { comment = false; index += 2; continue }
            } else if let ending = quote {
                if byte == UInt8(ascii: "\\"), index + 1 < bytes.count { index += 2; continue }
                if byte == ending { quote = nil }
            } else if opensOrClosesComment {
                comment = true; index += 2; continue
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: "(") || byte == UInt8(ascii: "[") {
                nesting += 1
            } else if byte == UInt8(ascii: ")") || byte == UInt8(ascii: "]") {
                nesting = max(0, nesting - 1)
            } else if nesting == 0, byte == UInt8(ascii: ";") || byte == UInt8(ascii: "{") || byte == UInt8(ascii: "}") {
                let removed = append(until: index, declaration: byte != UInt8(ascii: "{"))
                if byte != UInt8(ascii: ";") || !removed { output.append(byte) }
                start = index + 1
            }
            index += 1
        }
        _ = append(until: bytes.count, declaration: true)
        return (output, omitted)
    }

    /// Whether the declaration in `range` is named `filter` as a browser reads it: after white
    /// space and comments, a name that is `filter` in any case and is followed after white space
    /// and comments by a colon, or a name holding an escape, which could spell it. The `*` the
    /// renderer reads past before a name is read past here too.
    private static func namesFilter(_ bytes: [UInt8], _ range: Range<Int>) -> Bool {
        var index = range.lowerBound
        /// False at a comment that is not closed.
        func skipSpaceAndComments() -> Bool {
            while index < range.upperBound {
                if bytes[index] <= 0x20 {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "/"), index + 1 < range.upperBound, bytes[index + 1] == UInt8(ascii: "*") {
                    index += 2
                    while index + 1 < range.upperBound, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) { index += 1 }
                    guard index + 1 < range.upperBound else { return false }
                    index += 2
                } else {
                    break
                }
            }
            return true
        }
        guard skipSpaceAndComments() else { return false }
        if index < range.upperBound, bytes[index] == UInt8(ascii: "*") { index += 1 }
        let start = index
        while index < range.upperBound {
            if bytes[index] == UInt8(ascii: "\\") { return true }
            guard isNameByte(bytes[index]) || bytes[index] >= 0x80 else { break }
            index += 1
        }
        guard index - start == 6, holds("filter", bytes, at: start), skipSpaceAndComments() else { return false }
        return index < range.upperBound && bytes[index] == UInt8(ascii: ":")
    }

    /// The names `propertyNames` finds that end in `filter`: all that the renderer's tokenizer
    /// could read a `filter` declaration of, and more.
    private static func filterNames(in bytes: [UInt8]) -> [Range<Int>] {
        var names: [Range<Int>] = []
        propertyNames(in: bytes) { name, _ in
            if name.count >= 6, holds("filter", bytes, at: name.upperBound - 6) { names.append(name) }
        }
        return names
    }

    /// The third pass of `omittingFilterDeclarations`: blanks `names`. Blanking a name can leave
    /// another before it followed by a colon (`filter afilter:`), and every run of name
    /// characters that ends in `filter` is then blanked, wherever it stands.
    private static func blank(_ names: [Range<Int>], in bytes: inout [UInt8]) {
        guard !names.isEmpty else { return }
        bytes.withUnsafeMutableBufferPointer { buffer in
            for name in names { buffer[name].update(repeating: 0x20) }
        }
        guard !filterNames(in: bytes).isEmpty else { return }
        var runs: [Range<Int>] = []
        var index = 0
        while index < bytes.count {
            guard isNameByte(bytes[index]) else { index += 1; continue }
            let start = index
            while index < bytes.count, isNameByte(bytes[index]) { index += 1 }
            if index - start >= 6, holds("filter", bytes, at: index - 6) { runs.append(start..<index) }
        }
        bytes.withUnsafeMutableBufferPointer { buffer in
            for run in runs { buffer[run].update(repeating: 0x20) }
        }
    }

    /// Whether CSS in `value` might reach outside the document: a `url()` to anything but a
    /// fragment, or any escape, which could spell one (`u\72l(`) past a textual check. Both are
    /// looked for by byte, so that a mark after the backslash or the bracket hides neither (#248).
    static func unsafeCSS(_ value: String) -> Bool {
        value.utf8.contains(UInt8(ascii: "\\")) || referencesOutside(value)
    }

    /// Whether CSS in `value` points anywhere but into the document (`url(#…)`).
    static func referencesOutside(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        for index in bytes.indices where bytes[index] | 0x20 == UInt8(ascii: "u") && holds("url(", bytes, at: index) {
            var cursor = index + 4
            while cursor < bytes.count, bytes[cursor] == UInt8(ascii: " ") || bytes[cursor] == UInt8(ascii: "\"") || bytes[cursor] == UInt8(ascii: "'") { cursor += 1 }
            if cursor >= bytes.count || bytes[cursor] != UInt8(ascii: "#") { return true }
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
