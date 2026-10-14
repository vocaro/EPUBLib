import CoreGraphics
import Foundation

/// Bounds work that happens before resvg's checked raster boundary (#230). In particular,
/// converting an ellipse to cubics and measuring a text path happens during parsing.
enum SVGGeometryCostScreen {
    static let maximumPathCoordinate = 10_000_000.0
    static let maximumImageSpan = 8.0

    struct Numbers {
        let bytes: [UInt8]
        var index = 0
        init(_ text: String) { bytes = Array(text.utf8) }
        mutating func skip() { while index < bytes.count, bytes[index] == 44 || bytes[index] <= 32 { index += 1 } }
        mutating func number() -> Double? {
            skip()
            let start = index
            if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
            var digits = 0
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1; digits += 1 }
            if index < bytes.count, bytes[index] == 46 {
                index += 1
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1; digits += 1 }
            }
            guard digits > 0 else { index = start; return nil }
            if index + 1 < bytes.count, (bytes[index] == 69 || bytes[index] == 101),
               (48...57).contains(bytes[index + 1]) || bytes[index + 1] == 43 || bytes[index + 1] == 45 {
                index += 1
                if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
                let exponent = index
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                guard index > exponent else { return nil }
            }
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else { return nil }
            return value
        }
        mutating func flag() -> Bool {
            skip()
            guard index < bytes.count, bytes[index] == 48 || bytes[index] == 49 else { return false }
            index += 1; return true
        }
    }

    /// A control-point envelope, rather than a flattened path. Relative segments accumulate;
    /// an arc pays its corrected radius, including the enlargement to reach its endpoints.
    static func pathBounds(_ text: String, includingOrigin: Bool = true) -> CGRect? {
        var reader = Numbers(text), command: UInt8 = 0
        var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0
        var minX = includingOrigin ? 0.0 : Double.infinity, minY = includingOrigin ? 0.0 : Double.infinity
        var maxX = includingOrigin ? 0.0 : -Double.infinity, maxY = includingOrigin ? 0.0 : -Double.infinity
        var arcWork = 0.0
        func bounded(_ value: Double) -> Bool { value.isFinite && abs(value) <= maximumPathCoordinate }
        func include(_ px: Double, _ py: Double) -> Bool {
            guard bounded(px), bounded(py) else { return false }
            minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
            return true
        }
        while true {
            reader.skip()
            if reader.index == reader.bytes.count { break }
            let byte = reader.bytes[reader.index]
            if (65...90).contains(byte) || (97...122).contains(byte) {
                command = byte; reader.index += 1
                if command | 32 == 122 {
                    x = startX; y = startY; command = 0; continue
                }
            }
            let relative = command >= 97
            let lower = command | 32
            let counts: [UInt8: Int] = [109: 2, 108: 2, 104: 1, 118: 1, 99: 6, 115: 4, 113: 4, 116: 2, 97: 7]
            guard let count = counts[lower] else { return nil }
            var values: [Double] = []
            for part in 0..<count {
                if lower == 97, part == 3 || part == 4 {
                    guard reader.flag() else { return nil }; values.append(0)
                } else {
                    guard let value = reader.number(), bounded(value) else { return nil }; values.append(value)
                }
            }
            let oldX = x, oldY = y
            if lower == 104 { x = values[0] + (relative ? x : 0) }
            else if lower == 118 { y = values[0] + (relative ? y : 0) }
            else {
                x = values[count - 2] + (relative ? x : 0); y = values[count - 1] + (relative ? y : 0)
                if lower != 97 {
                    for offset in stride(from: 0, to: count, by: 2) {
                        guard include(values[offset] + (relative ? oldX : 0), values[offset + 1] + (relative ? oldY : 0)) else { return nil }
                    }
                } else {
                    let rx = abs(values[0]), ry = abs(values[1])
                    if rx > 0, ry > 0 {
                        // Rotation cannot make the chord longer than its Euclidean length.
                        let corrected = max(rx, ry) * max(1, hypot(x - oldX, y - oldY) / (2 * min(rx, ry)))
                        guard corrected.isFinite, corrected <= maximumPathCoordinate else { return nil }
                        arcWork += max(4, pow(11.163 * corrected, 1.0 / 6.0)) + 8
                        guard arcWork <= 10_000 else { return nil }
                        guard include(min(oldX, x) - 2 * corrected, min(oldY, y) - 2 * corrected),
                              include(max(oldX, x) + 2 * corrected, max(oldY, y) + 2 * corrected) else { return nil }
                    }
                }
            }
            guard include(x, y) else { return nil }
            if lower == 109 { startX = x; startY = y; command = relative ? 108 : 76 }
        }
        return minX.isFinite ? CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : .zero
    }

    static func length(_ text: String, relativeTo: Double, fontSize: Double = 16) -> Double? {
        var reader = Numbers(text)
        guard let number = reader.number() else { return nil }
        let unit = String(decoding: reader.bytes[reader.index...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let factors = ["": 1.0, "px": 1, "pt": 4.0 / 3, "pc": 16, "in": 96, "cm": 96 / 2.54,
                       "mm": 96 / 25.4, "em": fontSize, "ex": fontSize / 2, "%": relativeTo / 100]
        return factors[unit].map { number * $0 }
    }

    static func transform(_ text: String) -> CGAffineTransform? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "none" { return .identity }
        var reader = Numbers(text), result = CGAffineTransform.identity
        while true {
            reader.skip(); if reader.index == reader.bytes.count { return result }
            let start = reader.index
            while reader.index < reader.bytes.count, (65...122).contains(reader.bytes[reader.index]) { reader.index += 1 }
            let name = String(decoding: reader.bytes[start..<reader.index], as: UTF8.self)
            reader.skip()
            guard reader.index < reader.bytes.count, reader.bytes[reader.index] == 40 else { return nil }
            reader.index += 1
            var values: [Double] = []
            while true {
                reader.skip()
                guard reader.index < reader.bytes.count else { return nil }
                if reader.bytes[reader.index] == 41 { reader.index += 1; break }
                guard values.count < 6, let value = reader.number() else { return nil }; values.append(value)
            }
            let next: CGAffineTransform
            switch (name, values.count) {
            case ("matrix", 6): next = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            case ("translate", 1...2): next = CGAffineTransform(translationX: values[0], y: values.count == 2 ? values[1] : 0)
            case ("scale", 1...2): next = CGAffineTransform(scaleX: values[0], y: values.count == 2 ? values[1] : values[0])
            case ("rotate", 1), ("rotate", 3):
                let rotation = CGAffineTransform(rotationAngle: values[0] * .pi / 180)
                next = values.count == 1 ? rotation : CGAffineTransform(translationX: values[1], y: values[2]).concatenating(rotation).translatedBy(x: -values[1], y: -values[2])
            case ("skewX", 1): next = CGAffineTransform(a: 1, b: 0, c: tan(values[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case ("skewY", 1): next = CGAffineTransform(a: 1, b: tan(values[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: return nil
            }
            result = next.concatenating(result)
            guard [result.a, result.b, result.c, result.d, result.tx, result.ty].allSatisfy(\.isFinite) else { return nil }
        }
    }

    static func accepts(_ svg: ContentNode, nodes: [ContentNode], ids: [String: [ContentNode]]) -> Bool {
        for node in nodes where node.name == "path" {
            for attribute in node.attributes where attribute.name == "d" {
                guard pathBounds(attribute.value) != nil else { return false }
            }
        }
        let textPaths = nodes.filter { $0.name == "textPath" }
        let textTargets = Set(textPaths.compactMap(SVGContent.fragment))
        for id in textTargets {
            // usvg can turn any linked shape into a text path. Keep the supported form a
            // path whose control envelope we can bound without asking the renderer.
            if (ids[id] ?? []).contains(where: { $0.name != "path" }) { return false }
        }
        guard nodes.contains(where: { $0.name == "image" }) || !textPaths.isEmpty else { return true }
        // Geometry CSS is uncommon for archive images. A stylesheet transform may enlarge
        // an image through any matching ancestor; refuse it rather than reproduce the cascade.
        var stylesheetFont = 16.0
        for sheet in nodes where sheet.name == "style" {
            for rule in SVGReferenceScreen.CSSReader.rules(of: sheet.textContent, referencesOnly: false) {
                for declaration in rule.declarations {
                    if declaration.name == "transform", declaration.value != "none" { return false }
                    if declaration.name == "font" { return false }
                    if declaration.name == "font-size" {
                        // A relative rule can match successive ancestors and multiply at every
                        // level. Absolute candidates can instead be charged globally.
                        let value = declaration.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if value.hasSuffix("em") || value.hasSuffix("ex") || value.hasSuffix("%") { return false }
                        if let size = length(value, relativeTo: 16) { stylesheetFont = max(stylesheetFont, size) }
                    }
                }
            }
        }
        for node in nodes where node.name == "svg" || node.name == "symbol" {
            for name in ["width", "height", "viewBox"] {
                if Set(node.attributes.filter { $0.name == name }.map(\.value)).count > 1 { return false }
            }
        }
        let size = SVGContent.viewBox(svg)?.size ?? SVGContent.intrinsicSize(svg, fontSize: 16, fallback: CGSize(width: 300, height: 150))
        var steps = 0
        func visit(_ node: ContentNode, viewport: CGSize, above: CGAffineTransform, fontSize: Double, depth: Int) -> Bool {
            steps += 1
            guard steps <= SVGContent.markerStepBudget, depth <= SVGContent.maximumDepth else { return false }
            var local = CGAffineTransform.identity
            var transforms: [CGAffineTransform] = []
            var font = fontSize
            var declarations: [(name: String, value: String)] = node.attributes.map { ($0.name, $0.value) }
            for attribute in node.attributes where attribute.name == "style" {
                declarations += SVGReferenceScreen.CSSReader.declarations(of: attribute.value, referencesOnly: false)
            }
            if declarations.contains(where: { $0.name == "font" }) { return false }
            for declaration in declarations where declaration.name == "font-size" {
                if ["inherit", "unset", "initial"].contains(declaration.value) { continue }
                guard let size = length(declaration.value, relativeTo: fontSize, fontSize: fontSize), size.isFinite else { return false }
                font = max(font, size)
            }
            for attribute in node.attributes where attribute.name == "transform" {
                guard let value = transform(attribute.value) else { return false }; transforms.append(value)
            }
            for attribute in node.attributes where attribute.name == "style" {
                for declaration in SVGReferenceScreen.CSSReader.declarations(of: attribute.value, referencesOnly: false) where declaration.name == "transform" {
                    guard let value = transform(declaration.value) else { return false }; transforms.append(value)
                }
            }
            if !transforms.isEmpty {
                // Presentation attributes, inline styles and namespace alternatives override
                // each other; multiplying them could let a downscale conceal an upscale.
                // Componentwise absolute maxima enclose every cascade choice, and remain
                // conservative when ancestor matrices are subsequently multiplied.
                local = CGAffineTransform(a: transforms.map { abs($0.a) }.max()!, b: transforms.map { abs($0.b) }.max()!,
                                          c: transforms.map { abs($0.c) }.max()!, d: transforms.map { abs($0.d) }.max()!,
                                          tx: transforms.map { abs($0.tx) }.max()!, ty: transforms.map { abs($0.ty) }.max()!)
            }
            let total = local.concatenating(above)
            if node.name == "path", node.attributes.contains(where: { $0.name == "id" && textTargets.contains($0.value) }) {
                for attribute in node.attributes where attribute.name == "d" {
                    guard let box = pathBounds(attribute.value) else { return false }
                    let x = max(abs(box.minX), abs(box.maxX)), y = max(abs(box.minY), abs(box.maxY))
                    guard total.a * x + total.c * y + abs(total.tx) <= maximumPathCoordinate,
                          total.b * x + total.d * y + abs(total.ty) <= maximumPathCoordinate else { return false }
                }
            }
            var here = viewport
            if node !== svg, node.name == "svg" || node.name == "symbol" {
                let width = node.attributes.filter { $0.name == "width" }.compactMap { length($0.value, relativeTo: viewport.width, fontSize: font) }.map(abs).max() ?? viewport.width
                let height = node.attributes.filter { $0.name == "height" }.compactMap { length($0.value, relativeTo: viewport.height, fontSize: font) }.map(abs).max() ?? viewport.height
                let box = SVGContent.viewBox(node)?.size ?? CGSize(width: width, height: height)
                guard box.width > 0, box.height > 0 else { return true }
                here = box
                let scale = max(width / box.width, height / box.height)
                // `slice` scales both axes by the larger ratio. Charging it for every mode
                // also safely overestimates meet/none without reproducing preserveAspectRatio.
                return children(node, viewport: here, above: CGAffineTransform(scaleX: scale, y: scale).concatenating(total), fontSize: font, depth: depth)
            }
            if node.name == "image" {
                var intrinsic = CGSize.zero
                if let reference = SVGContent.href(node), reference.hasPrefix("data:"), let comma = reference.firstIndex(of: ","),
                   let data = Data(base64Encoded: String(reference[reference.index(after: comma)...])),
                   data.count <= SVGContent.maximumInlinedImageBytes,
                   let bitmap = ReaderImageSource.bitmap(data, path: "", key: "svg-span") { intrinsic = bitmap.pixelSize }
                let width = node.attributes.filter { $0.name == "width" }.compactMap { length($0.value, relativeTo: here.width, fontSize: font) }.map(abs).max() ?? intrinsic.width
                let height = node.attributes.filter { $0.name == "height" }.compactMap { length($0.value, relativeTo: here.height, fontSize: font) }.map(abs).max() ?? intrinsic.height
                let spanX = abs(total.a * width) + abs(total.c * height), spanY = abs(total.b * width) + abs(total.d * height)
                guard spanX.isFinite, spanY.isFinite, spanX <= size.width * maximumImageSpan, spanY <= size.height * maximumImageSpan else { return false }
            }
            return children(node, viewport: here, above: total, fontSize: font, depth: depth)
        }
        func children(_ node: ContentNode, viewport: CGSize, above: CGAffineTransform, fontSize: Double, depth: Int) -> Bool {
            for child in node.elementChildren { guard visit(child, viewport: viewport, above: above, fontSize: fontSize, depth: depth + 1) else { return false } }
            if node.name == "use", let id = SVGContent.fragment(node) {
                for target in ids[id] ?? [] {
                    var placed = above
                    if target.name == "svg" || target.name == "symbol" {
                        let authoredWidth = length(target.attribute("width") ?? "100%", relativeTo: viewport.width, fontSize: fontSize) ?? viewport.width
                        let authoredHeight = length(target.attribute("height") ?? "100%", relativeTo: viewport.height, fontSize: fontSize) ?? viewport.height
                        let width = node.attributes.filter { $0.name == "width" }.compactMap { length($0.value, relativeTo: viewport.width, fontSize: fontSize) }.map(abs).max() ?? authoredWidth
                        let height = node.attributes.filter { $0.name == "height" }.compactMap { length($0.value, relativeTo: viewport.height, fontSize: fontSize) }.map(abs).max() ?? authoredHeight
                        guard authoredWidth > 0, authoredHeight > 0 else { continue }
                        let scale = max(1, width / authoredWidth, height / authoredHeight)
                        placed = CGAffineTransform(scaleX: scale, y: scale).concatenating(above)
                    }
                    guard visit(target, viewport: viewport, above: placed, fontSize: fontSize, depth: depth + 1) else { return false }
                }
            }
            return true
        }
        return visit(svg, viewport: size, above: .identity, fontSize: stylesheetFont, depth: 0)
    }
}
