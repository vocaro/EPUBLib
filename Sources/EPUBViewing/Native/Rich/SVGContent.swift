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
    /// Characters in one `<text>` element (its own text and that of its `tspan`/`textPath`
    /// descendants). Text layout is super-linear in the length of one run, so the document
    /// byte limit alone lets a single run cost minutes; a real label is far shorter.
    static let maximumTextRunCharacters = 20_000
    /// Marker instances the renderer may build: summed over the vertices of every marker-bearing
    /// shape (each `<use>` and `<marker>` clone included), times the graphic nodes the markers
    /// draw. Markers are cloned per vertex inside the renderer and are counted by neither the
    /// node nor the expansion limit.
    static let maximumMarkerInstances = 100_000

    /// Shapes whose vertices can carry a marker, and whose geometry the renderer builds.
    private static let markerableShapes: Set<String> = ["path", "line", "polyline", "polygon", "rect", "circle", "ellipse"]
    /// Local names of the marker properties (`marker` is the shorthand for all three).
    private static let markerProperties: Set<String> = ["marker", "marker-start", "marker-mid", "marker-end"]
    /// Graphic nodes that are one draw operation each when a marker instantiates them (`use` is
    /// followed to its target instead of counted here).
    private static let drawableShapes: Set<String> = ["path", "line", "polyline", "polygon", "rect", "circle", "ellipse",
                                                       "text", "image"]

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
                node.attribute("style").map({ omittingFilterDeclarations($0).omitted }) == true ||
                (node.name == "style" && omittingFilterDeclarations(node.textContent).omitted) {
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
        let refused: Set<String> = omittingFilters ? ["svg:pattern"] : ["svg:filter", "svg:pattern"]
        guard valid, unsupportedConstructs(svg).isDisjoint(with: refused) else { return false }
        guard textRunsAreBounded(nodes) else { return false }
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
        // Marker accounting runs after the byte cost passes, so `<use>` expansion is already
        // bounded (every instantiated node cost at least a few bytes), which bounds this walk.
        guard cost(svg, depth: 0) != nil, markerInstancesAreBounded(svg, ids: ids) else { return false }
        return true
    }

    /// Whether every `<text>` element's run is within the per-run character bound. A run is the
    /// element's own text plus that of its `tspan`/`textPath` descendants, which the renderer
    /// shapes as one super-linear unit; separate `<text>` elements stay roughly linear.
    private static func textRunsAreBounded(_ nodes: [ContentNode]) -> Bool {
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

    /// Whether the markers the drawing instantiates stay within the instance bound. The renderer
    /// clones a marker's content at every vertex of each shape that references it; the clone is
    /// counted by neither the node nor the expansion limit, so a small shape and marker, a shape
    /// multiplied by `<use>`, nested markers, or a stylesheet rule can amplify into hundreds of
    /// megabytes. This walks the rendered tree once, following `<use>` so a marker-bearing shape
    /// reached through N uses is charged N times, and multiplies nested markers. It is an upper
    /// bound: a shape is charged its vertex count times the drawing load of every marker reached
    /// from it or its ancestors (markers are inherited), start and end markers once each; a
    /// stylesheet marker rule, whose selector this does not evaluate, charges every shape the
    /// largest referenced marker. Cost (the byte limit) has already bounded `<use>` expansion,
    /// so this walk terminates; it also saturates at the bound and stops early.
    private static func markerInstancesAreBounded(_ svg: ContentNode, ids: [String: ContentNode]) -> Bool {
        var markersByID: [String: [ContentNode]] = [:]
        func collectMarkers(_ node: ContentNode) {
            if node.name == "marker", let id = node.id { markersByID[id, default: []].append(node) }
            for child in node.elementChildren { collectMarkers(child) }
        }
        collectMarkers(svg)
        guard !markersByID.isEmpty else { return true }

        let ceiling = maximumMarkerInstances + 1
        func clamp(_ value: Int) -> Int { value > ceiling ? ceiling : value }
        var ambientMid = 0
        var loadCache: [ObjectIdentifier: Int] = [:]
        var active = Set<ObjectIdentifier>()
        var uncacheable = 0

        func loadForID(_ id: String, _ depth: Int) -> Int {
            (markersByID[id] ?? []).reduce(0) { max($0, markerLoad($1, depth)) }
        }

        // Marker url ids a node declares, split into mid-like (mid + the `marker` shorthand) and
        // endpoint (start, end), from its attributes (any namespace) and its `style`.
        func ownReferences(_ node: ContentNode) -> (mid: [String], end: [String]) {
            var mid: [String] = [], end: [String] = []
            for attribute in node.attributes where markerProperties.contains(attribute.name) {
                guard let id = urlFragment(attribute.value) else { continue }
                if attribute.name == "marker-start" || attribute.name == "marker-end" { end.append(id) } else { mid.append(id) }
            }
            if let style = node.attribute("style") {
                let references = markerCSSReferences(style)
                mid += references.mid; end += references.end
            }
            return (mid, end)
        }

        // Draw operations a subtree produces when instantiated once, under the marker loads
        // inherited from its ancestors. `countDrawables` is true inside a marker, where each
        // drawable is one instance per vertex of the referencing shape; false in the page tree,
        // where a drawable is simply drawn and only its markers amplify.
        func load(_ node: ContentNode, inMid: Int, inEnd: Int, countDrawables: Bool, depth: Int) -> Int {
            guard depth <= maximumDepth else { uncacheable += 1; return ceiling }
            let own = ownReferences(node)
            let mid = clamp(inMid + own.mid.reduce(0) { $0 + loadForID($1, depth) })
            let end = clamp(inEnd + own.end.reduce(0) { $0 + loadForID($1, depth) })
            var total = countDrawables && drawableShapes.contains(node.name) ? 1 : 0
            if markerableShapes.contains(node.name), mid + end > 0 {
                total = clamp(total + clamp(vertexCount(node) * mid) + end)
            }
            if total >= ceiling { return ceiling }
            if node.name == "use", let href = href(node), href.hasPrefix("#"), let target = ids[String(href.dropFirst())],
               active.insert(ObjectIdentifier(target)).inserted {
                total = clamp(total + load(target, inMid: mid, inEnd: end, countDrawables: countDrawables, depth: depth + 1))
                active.remove(ObjectIdentifier(target))
            }
            for child in node.children where !unrendered.contains(child.name) {
                total = clamp(total + load(child, inMid: mid, inEnd: end, countDrawables: countDrawables, depth: depth + 1))
                if total >= ceiling { break }
            }
            return total
        }

        // Draw operations one instantiation of a marker produces, including nested markers.
        func markerLoad(_ marker: ContentNode, _ depth: Int) -> Int {
            let key = ObjectIdentifier(marker)
            if let cached = loadCache[key] { return cached }
            if active.contains(key) { uncacheable += 1; return 0 } // recursive marker: the renderer skips it
            guard depth <= maximumDepth else { uncacheable += 1; return ceiling }
            active.insert(key)
            let before = uncacheable
            var total = 0
            for child in marker.children where !unrendered.contains(child.name) {
                total = clamp(total + load(child, inMid: ambientMid, inEnd: 0, countDrawables: true, depth: depth + 1))
                if total >= ceiling { break }
            }
            active.remove(key)
            if uncacheable == before { loadCache[key] = total } // a value reached through a cycle is context-dependent
            return total
        }

        // A stylesheet marker rule can attach a marker to shapes this walk does not match by
        // selector, so when one is present every shape is charged the largest marker it could
        // name (the referenced markers, or any marker in the document when the url is opaque).
        var stylesheetIDs: [String] = []
        var stylesheetNeedsLargest = false
        func collectStylesheets(_ node: ContentNode) {
            if node.name == "style" {
                let references = markerCSSReferences(node.textContent)
                if references.present {
                    stylesheetIDs += references.mid + references.end
                    if references.mid.isEmpty && references.end.isEmpty { stylesheetNeedsLargest = true }
                }
            }
            for child in node.elementChildren { collectStylesheets(child) }
        }
        collectStylesheets(svg)
        if !stylesheetIDs.isEmpty || stylesheetNeedsLargest {
            // Base loads (no stylesheet charge yet) size the charge; `ambientMid` stays 0 here.
            var charge = 0
            for id in stylesheetIDs { charge = max(charge, loadForID(id, 0)) }
            if stylesheetNeedsLargest {
                for markers in markersByID.values { for marker in markers { charge = max(charge, markerLoad(marker, 0)) } }
            }
            ambientMid = charge
            loadCache.removeAll() // recompute marker loads with the ambient stylesheet charge applied
            uncacheable = 0
        }
        return load(svg, inMid: ambientMid, inEnd: 0, countDrawables: false, depth: 0) <= maximumMarkerInstances
    }

    /// The marker url ids a block of CSS declarations attaches, split into mid-like (mid and the
    /// `marker` shorthand) and endpoint (start, end), and whether any marker property is present
    /// at all. Robust to the whitespace and comments the renderer accepts between the property
    /// name and its colon; case-insensitive and ignoring escapes, both of which the renderer
    /// does not honour, so this stays a superset of what it draws. Selectors are not evaluated.
    private static func markerCSSReferences(_ css: String) -> (mid: [String], end: [String], present: Bool) {
        let characters = Array(stripCSSComments(css))
        func isIdentifier(_ character: Character) -> Bool { character.isLetter || character.isNumber || character == "-" || character == "_" }
        var mid: [String] = [], end: [String] = [], present = false
        var index = 0
        while index < characters.count {
            guard isIdentifier(characters[index]), index == 0 || !isIdentifier(characters[index - 1]) else { index += 1; continue }
            var nameEnd = index
            while nameEnd < characters.count, isIdentifier(characters[nameEnd]) { nameEnd += 1 }
            let name = String(characters[index..<nameEnd]).lowercased()
            var cursor = nameEnd
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count, characters[cursor] == ":", markerProperties.contains(name) else { index = nameEnd; continue }
            present = true
            var valueEnd = cursor + 1
            while valueEnd < characters.count, characters[valueEnd] != ";", characters[valueEnd] != "}", characters[valueEnd] != "{" { valueEnd += 1 }
            if let id = urlFragment(String(characters[(cursor + 1)..<valueEnd])) {
                if name == "marker-start" || name == "marker-end" { end.append(id) } else { mid.append(id) }
            }
            index = valueEnd
        }
        return (mid, end, present)
    }

    /// CSS with every `/* … */` comment replaced by a space, so a comment cannot hide a boundary.
    private static func stripCSSComments(_ css: String) -> String {
        guard css.contains("/*") else { return css }
        var output = ""
        var characters = Substring(css)
        while let open = characters.range(of: "/*") {
            output += characters[..<open.lowerBound]
            output += " "
            if let close = characters.range(of: "*/", range: open.upperBound..<characters.endIndex) {
                characters = characters[close.upperBound...]
            } else {
                return output
            }
        }
        return output + characters
    }

    /// The fragment id of the first `url(#…)` in a CSS value; nil for `none`, an external url or
    /// anything else. Case-insensitive on `url(`; the id itself is kept verbatim.
    private static func urlFragment(_ value: String) -> String? {
        guard let start = value.range(of: "url(", options: .caseInsensitive) else { return nil }
        let inside = value[start.upperBound...].drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\"" || $0 == "'" }
        guard inside.hasPrefix("#") else { return nil }
        let id = inside.dropFirst().prefix { $0 != ")" && $0 != " " && $0 != "\t" && $0 != "\n" && $0 != "\"" && $0 != "'" }
        return id.isEmpty ? nil : String(id)
    }

    /// An upper bound on a shape's marker vertices: numeric tokens in a `path` `d` or a
    /// `polyline`/`polygon` `points` (each real vertex needs at least one, curves and arcs
    /// several), or a small constant for the closed and two-point primitives.
    private static func vertexCount(_ shape: ContentNode) -> Int {
        switch shape.name {
        case "path": return numberCount(shape.attribute("d") ?? "")
        case "polyline", "polygon": return numberCount(shape.attribute("points") ?? "")
        case "line": return 2
        default: return 5 // rect, circle and ellipse expand to a closed five-vertex path.
        }
    }

    /// The count of numeric tokens in SVG coordinate data, over-counting rather than under.
    private static func numberCount(_ value: String) -> Int {
        var count = 0
        var inNumber = false
        var sawDot = false
        var previous: Character = " "
        for character in value {
            if character.isNumber {
                if !inNumber { count += 1; inNumber = true; sawDot = false }
            } else if character == "." {
                if inNumber, sawDot { count += 1 } else if !inNumber { count += 1; inNumber = true }
                sawDot = true
            } else if character == "e" || character == "E" {
                // Part of the current number's exponent; never a token on its own.
            } else if character == "+" || character == "-" {
                if previous != "e", previous != "E" { count += 1; inNumber = true; sawDot = false }
            } else {
                inNumber = false; sawDot = false
            }
            previous = character
        }
        return count
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
        func number(_ name: String) -> CGFloat? {
            if case .points(let value)? = ImageSizing.length(image.attribute(name), fontSize: fontSize) { value } else { nil }
        }
        let imageSize = source.pixelSize
        let box = viewBox(svg) ?? CGRect(origin: .zero, size: intrinsicSize(svg, fontSize: fontSize, fallback: imageSize))
        let width = number("width").flatMap { $0 > 0 ? $0 : nil } ?? (viewBox(svg) == nil ? box.width : imageSize.width)
        let height = number("height").flatMap { $0 > 0 ? $0 : nil } ?? (viewBox(svg) == nil ? box.height : imageSize.height)
        let rect = CGRect(x: ((number("x") ?? 0) - box.minX) / box.width, y: ((number("y") ?? 0) - box.minY) / box.height,
                          width: width / box.width, height: height / box.height)
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
    /// archive path; nil for anything that cannot be used.
    static func serialize(_ svg: ContentNode, resolve: (String) -> String?, publication: EPUBPublication,
                          fontAliases: [String: String] = [:], report: SectionReportBox? = nil) -> Data? {
        // Filters remain refused by the direct renderer. The archive path can preserve the
        // drawing by omitting effects before handing it to that same strict entry point.
        // Count the original tree first, so omitted definitions cannot evade input bounds.
        guard isWithinRenderingLimits(svg, omittingFilters: true) else { return nil }
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
            return omittingFilterDeclarations(result).css
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
            if node.name == "style" {
                write(">" + escape(css(node.textContent), attribute: false) + "</style>")
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

    /// Remove only filter declarations, retaining neighboring geometry, paint and font CSS.
    /// Boundaries inside strings, comments and functions are not declaration boundaries.
    /// Tokenizing each declaration recognizes comments and escaped property names as well.
    private static func omittingFilterDeclarations(_ value: String) -> (css: String, omitted: Bool) {
        var output = ""
        var start = value.startIndex
        var index = start
        var quote: Character?
        var comment = false
        var nesting = 0
        var omitted = false
        func append(until end: String.Index, declaration: Bool) -> Bool {
            let text = String(value[start..<end])
            var truncated = false
            let components = declaration ? CSSParser.components(text, truncated: &truncated).significant : []
            if components.count >= 2, components[0].ident == "filter", components[1] == .token(.colon) {
                omitted = true
                return true
            } else {
                output += text
                return false
            }
        }
        while index < value.endIndex {
            let character = value[index]
            let next = value.index(after: index)
            if comment {
                if character == "*", next < value.endIndex, value[next] == "/" {
                    comment = false; index = value.index(after: next); continue
                }
            } else if let ending = quote {
                if character == "\\", next < value.endIndex {
                    index = value.index(after: next); continue
                }
                if character == ending { quote = nil }
            } else if character == "/", next < value.endIndex, value[next] == "*" {
                comment = true; index = value.index(after: next); continue
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" || character == "[" {
                nesting += 1
            } else if character == ")" || character == "]" {
                nesting = max(0, nesting - 1)
            } else if nesting == 0, character == ";" || character == "{" || character == "}" {
                let removed = append(until: index, declaration: character != "{")
                if character != ";" || !removed { output.append(character) }
                start = next
            }
            index = next
        }
        _ = append(until: value.endIndex, declaration: true)
        return (output, omitted)
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
