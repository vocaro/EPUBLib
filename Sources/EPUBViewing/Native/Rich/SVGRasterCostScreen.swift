import CoreGraphics
import Foundation

/// A marker's clip bounds what is visible, but resvg first allocates and paints the layer
/// for its unclipped content. Keep that content near its authored viewport before decoding;
/// charging every ordinary arrowhead as a full-canvas layer would blur diagrams unnecessarily.
enum SVGRasterCostScreen {
    /// Eight viewport dimensions of overshoot admits stock arrowheads and their strokes.
    static let maximumMarkerOvershoot = 8.0
    static let maximumMarkerCanvasAreas = 256.0
    private static let properties: Set<String> = ["transform", "stroke-width", "stroke-miterlimit", "font-size", "font"]

    static func accepts(_ svg: ContentNode, nodes: [ContentNode]) -> Bool {
        guard nodes.contains(where: { $0.name == "marker" }) else { return true }
        // The renderer can accept attributes by local name from several namespaces.
        // A tiny alternative viewBox or large alternative viewport must not hide behind
        // the ordinary attribute that the screen's helpers resolve.
        for node in nodes where ["svg", "symbol", "marker"].contains(node.name) {
            for name in ["width", "height", "viewBox", "markerWidth", "markerHeight", "markerUnits"] {
                if Set(node.attributes.filter { $0.name == name }.map(\.value)).count > 1 { return false }
            }
        }
        typealias Subject = SVGReferenceScreen.Subject
        var styled: [Subject: [String: [String]]] = [:]
        for sheet in nodes where sheet.name == "style" && SVGContent.serializeKeepsSheet(sheet.textContent) {
            for rule in SVGReferenceScreen.CSSReader.rules(of: sheet.textContent, referencesOnly: false) {
                for declaration in rule.declarations where properties.contains(declaration.name) {
                    for subject in rule.subjects {
                        styled[subject, default: [:]][declaration.name, default: []].append(declaration.value)
                    }
                }
            }
        }
        guard !styled.values.contains(where: { $0["font"] != nil }) else { return false }
        var candidates: [ObjectIdentifier: [String: [String]]] = [:]
        var hasOwnTransform = Set<ObjectIdentifier>()
        for node in nodes where node.isElement {
            var values: [String: [String]] = [:]
            for attribute in node.attributes {
                if properties.contains(attribute.name) { values[attribute.name, default: []].append(attribute.value) }
                if attribute.name == "style" {
                    for declaration in SVGReferenceScreen.CSSReader.declarations(of: attribute.value, referencesOnly: false)
                        where properties.contains(declaration.name) {
                        values[declaration.name, default: []].append(declaration.value)
                    }
                }
            }
            for subject in SVGReferenceScreen.subjects(of: node) {
                for (name, alternatives) in styled[subject] ?? [:] { values[name, default: []] += alternatives }
            }
            if node.attribute("transform") != nil || SVGReferenceScreen.CSSReader.declarations(of: node.attribute("style") ?? "", referencesOnly: false).contains(where: { $0.name == "transform" }) {
                hasOwnTransform.insert(ObjectIdentifier(node))
            }
            guard values["font"] == nil else { return false }
            candidates[ObjectIdentifier(node)] = values
        }
        struct State {
            var scale = 1.0, offset = 0.0, stroke = 1.0, miter = 4.0, font = 16.0
        }
        func state(_ node: ContentNode, inherited: State, relative: Double, transforms: Bool) -> State? {
            var result = inherited
            let values = candidates[ObjectIdentifier(node)] ?? [:]
            for text in values["font-size"] ?? [] where text != "inherit" {
                guard let value = SVGGeometryCostScreen.length(text, relativeTo: inherited.font, fontSize: inherited.font), value >= 0 else { return nil }
                result.font = max(result.font, value)
            }
            for text in values["stroke-width"] ?? [] where text != "inherit" {
                guard let value = SVGGeometryCostScreen.length(text, relativeTo: relative, fontSize: result.font), value >= 0 else { return nil }
                result.stroke = max(result.stroke, value)
            }
            for text in values["stroke-miterlimit"] ?? [] where text != "inherit" {
                guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, value >= 1 else { return nil }
                result.miter = max(result.miter, value)
            }
            if transforms {
                var scale = hasOwnTransform.contains(ObjectIdentifier(node)) ? 0.0 : 1.0, offset = 0.0
                for text in values["transform"] ?? [] {
                    if text == "none" { scale = max(scale, 1); continue }
                    guard let t = SVGGeometryCostScreen.transform(text) else { return nil }
                    scale = max(scale, Double(max(abs(t.a) + abs(t.c), abs(t.b) + abs(t.d))))
                    offset = max(offset, Double(max(abs(t.tx), abs(t.ty))))
                }
                result.offset += inherited.scale * offset
                result.scale *= scale
            }
            guard [result.scale, result.offset, result.stroke, result.miter, result.font].allSatisfy(\.isFinite) else { return nil }
            return result
        }
        func bounds(_ node: ContentNode, viewport: CGRect, font: Double) -> CGRect? {
            let dimension = Double(max(viewport.width, viewport.height))
            func n(_ name: String, _ fallback: Double = 0) -> Double? {
                let texts = node.attributes.filter { $0.name == name }.map(\.value)
                guard !texts.isEmpty else { return fallback }
                var largest = 0.0
                for text in texts {
                    guard let value = SVGGeometryCostScreen.length(text, relativeTo: dimension, fontSize: font) else { return nil }
                    if abs(value) > abs(largest) { largest = value }
                }
                return largest
            }
            switch node.name {
            case "path":
                var result = CGRect.null
                for attribute in node.attributes where attribute.name == "d" && !attribute.value.isEmpty {
                    guard let box = SVGGeometryCostScreen.pathBounds(attribute.value, includingOrigin: false) else { return nil }
                    result = result.union(box)
                }
                return result.isNull ? .zero : result
            case "polyline", "polygon":
                // Feeding the point list as an implicit lineto path also handles compact signs,
                // scientific notation and every separator accepted by the geometry lexer.
                var result = CGRect.null
                for attribute in node.attributes where attribute.name == "points" && !attribute.value.isEmpty {
                    guard let box = SVGGeometryCostScreen.pathBounds("M" + attribute.value, includingOrigin: false) else { return nil }
                    result = result.union(box)
                }
                return result.isNull ? .zero : result
            case "rect":
                guard let x = n("x"), let y = n("y"), let w = n("width"), let h = n("height"), w >= 0, h >= 0 else { return nil }
                return CGRect(x: x, y: y, width: w, height: h)
            case "circle", "ellipse":
                guard let x = n("cx"), let y = n("cy"), let rx = n(node.name == "circle" ? "r" : "rx"),
                      let ry = n(node.name == "circle" ? "r" : "ry"), rx >= 0, ry >= 0 else { return nil }
                return CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry)
            case "line":
                guard let x1 = n("x1"), let y1 = n("y1"), let x2 = n("x2"), let y2 = n("y2") else { return nil }
                return CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
            default: return .zero
            }
        }
        // A wide marker viewport can make the local envelope arbitrarily wide. Bound its
        // projected size too, including the strokeWidth unit and every possible host/use
        // transform. This walk is bounded by the already-screened expansion plus a step cap.
        let canvas = SVGContent.viewBox(svg)?.size ?? SVGContent.intrinsicSize(svg, fontSize: 16, fallback: CGSize(width: 300, height: 150))
        let canvasDimension = Double(max(canvas.width, canvas.height))
        let canvasShortSide = Double(min(canvas.width, canvas.height))
        var hostScale = 1.0, hostStrokeScale = 1.0, steps = 0
        let ids = SVGContent.elementsByID(nodes)
        func hosts(_ node: ContentNode, inherited: State, viewport: CGSize, depth: Int) -> Bool {
            steps += 1
            guard steps <= SVGContent.markerStepBudget, depth <= SVGContent.maximumDepth else { return false }
            if node.name == "marker" { return true }
            guard var here = state(node, inherited: inherited, relative: canvasDimension, transforms: true) else { return false }
            var childViewport = viewport
            if node !== svg, node.name == "svg" || node.name == "symbol" {
                guard let width = SVGGeometryCostScreen.length(node.attribute("width") ?? "100%", relativeTo: viewport.width, fontSize: here.font),
                      let height = SVGGeometryCostScreen.length(node.attribute("height") ?? "100%", relativeTo: viewport.height, fontSize: here.font) else { return false }
                let box = SVGContent.viewBox(node)?.size ?? CGSize(width: width, height: height)
                guard box.width > 0, box.height > 0 else { return true }
                here.scale *= Double(max(width / box.width, height / box.height))
                childViewport = box
            }
            hostScale = max(hostScale, here.scale)
            hostStrokeScale = max(hostStrokeScale, here.scale * here.stroke)
            guard hostStrokeScale.isFinite else { return false }
            for child in node.elementChildren { guard hosts(child, inherited: here, viewport: childViewport, depth: depth + 1) else { return false } }
            if node.name == "use", let id = SVGContent.fragment(node) {
                for target in ids[id] ?? [] {
                    var placed = here
                    if target.name == "svg" || target.name == "symbol" {
                        guard let authoredWidth = SVGGeometryCostScreen.length(target.attribute("width") ?? "100%", relativeTo: childViewport.width, fontSize: here.font),
                              let authoredHeight = SVGGeometryCostScreen.length(target.attribute("height") ?? "100%", relativeTo: childViewport.height, fontSize: here.font) else { return false }
                        guard authoredWidth > 0, authoredHeight > 0 else { continue }
                        let width = node.attributes.filter { $0.name == "width" }.compactMap { SVGGeometryCostScreen.length($0.value, relativeTo: childViewport.width, fontSize: here.font) }.map(abs).max() ?? authoredWidth
                        let height = node.attributes.filter { $0.name == "height" }.compactMap { SVGGeometryCostScreen.length($0.value, relativeTo: childViewport.height, fontSize: here.font) }.map(abs).max() ?? authoredHeight
                        placed.scale *= Double(max(1, max(width / authoredWidth, height / authoredHeight)))
                    }
                    guard hosts(target, inherited: placed, viewport: childViewport, depth: depth + 1) else { return false }
                }
            }
            return true
        }
        guard canvasShortSide.isFinite, canvasShortSide > 0, hosts(svg, inherited: State(), viewport: canvas, depth: 0) else { return false }
        var maximumProjectedArea = 0.0
        func marker(_ node: ContentNode, inherited: State) -> Bool {
            func size(_ name: String) -> Double? {
                let texts = node.attributes.filter { $0.name == name }.map(\.value)
                guard !texts.isEmpty else { return 3 }
                var largest = 0.0
                for text in texts {
                    guard let value = SVGGeometryCostScreen.length(text, relativeTo: 3, fontSize: inherited.font), value > 0 else { return nil }
                    largest = max(largest, value)
                }
                return largest
            }
            guard let width = size("markerWidth"), let height = size("markerHeight"), width > 0, height > 0 else { return false }
            let unitScale = node.attribute("markerUnits") == "userSpaceOnUse" ? hostScale : hostStrokeScale
            guard max(width, height) * unitScale <= 2 * canvasShortSide else { return false }
            let viewport = SVGContent.viewBox(node) ?? CGRect(x: 0, y: 0, width: width, height: height)
            let dimension = Double(max(viewport.width, viewport.height))
            let allowed = viewport.insetBy(dx: -maximumMarkerOvershoot * dimension, dy: -maximumMarkerOvershoot * dimension)
            let viewportScale = node.attribute("viewBox") == nil ? 1 : max(width / viewport.width, height / viewport.height)
            var paintedBounds = CGRect.null
            var markerSteps = 0
            func visit(_ node: ContentNode, inherited: State, above: [CGAffineTransform]) -> Bool {
                guard let here = state(node, inherited: inherited, relative: dimension, transforms: false) else { return false }
                let texts = candidates[ObjectIdentifier(node)]?["transform"] ?? []
                var alternatives: [CGAffineTransform] = hasOwnTransform.contains(ObjectIdentifier(node)) ? [] : [.identity]
                for text in texts {
                    guard let transform = SVGGeometryCostScreen.transform(text) else { return false }
                    alternatives.append(transform)
                }
                if alternatives.isEmpty { alternatives = [.identity] }
                var transforms: [CGAffineTransform] = []
                for parent in above {
                    for own in alternatives {
                        markerSteps += 1
                        guard markerSteps <= SVGContent.markerStepBudget, transforms.count < 64 else { return false }
                        transforms.append(own.concatenating(parent))
                    }
                }
                if ["path", "polyline", "polygon", "rect", "circle", "ellipse", "line"].contains(node.name) {
                    guard let box = bounds(node, viewport: viewport, font: here.font) else { return false }
                    let stroke = here.stroke * max(1, here.miter) / 2
                    let expanded = box.insetBy(dx: -stroke, dy: -stroke)
                    for transform in transforms {
                        let painted = expanded.applying(transform)
                        guard [painted.minX, painted.maxX, painted.minY, painted.maxY].allSatisfy(\.isFinite),
                              painted.minX >= allowed.minX, painted.maxX <= allowed.maxX,
                              painted.minY >= allowed.minY, painted.maxY <= allowed.maxY else { return false }
                        paintedBounds = paintedBounds.union(painted)
                    }
                }
                return node.elementChildren.allSatisfy { visit($0, inherited: here, above: transforms) }
            }
            var local = inherited
            local.scale = 1; local.offset = 0
            guard visit(node, inherited: local, above: [.identity]) else { return false }
            if !paintedBounds.isNull {
                let projectedWidth = Double(paintedBounds.width) * Double(viewportScale) * unitScale
                let projectedHeight = Double(paintedBounds.height) * Double(viewportScale) * unitScale
                // An auto-oriented marker can rotate through any angle; its enclosing square
                // is no wider than the sum of these two extents.
                let span = projectedWidth + projectedHeight
                maximumProjectedArea = max(maximumProjectedArea, span * span)
            }
            return maximumProjectedArea.isFinite
        }
        func walk(_ node: ContentNode, inherited: State) -> Bool {
            if node.name == "marker" { return marker(node, inherited: inherited) }
            // XML ancestors supply presentation values to definitions, but their transforms
            // do not scale the marker's local coordinates.
            guard let here = state(node, inherited: inherited, relative: 3, transforms: false) else { return false }
            return node.elementChildren.allSatisfy { walk($0, inherited: here) }
        }
        guard walk(svg, inherited: State()) else { return false }
        let instances = SVGContent.markerVerdict(svg, nodes: nodes, ids: ids).instances
        let canvasArea = Double(canvas.width * canvas.height)
        guard canvasArea.isFinite, canvasArea > 0 else { return false }
        return maximumProjectedArea * Double(instances) <= maximumMarkerCanvasAreas * canvasArea
    }
}
