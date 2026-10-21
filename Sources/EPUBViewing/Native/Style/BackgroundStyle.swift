import Foundation

// The `background` shorthand (CSS Backgrounds 3 §3.10) and the images it names (CSS Images 3
// and 4). Only the final layer's colour is drawn, but every layer is read in full, so that a
// declaration with a value the reader does not know, such as a gradient prefixed for another
// engine, is ignored as CSS 2.2 §4.2 requires and the colour an earlier one set stays.

extension CSSPropertyParser {
    /// Layers separated by commas, each of an image, a position with an optional size after
    /// `/`, a repeat style, an attachment and up to two boxes (`text` among them, as
    /// `background-clip` takes it), in any order and each at most once; the final layer may also
    /// have a colour. A valid shorthand without a colour sets it to transparent.
    static func background(_ c: [CSSComponent]) -> [(CSSProperty, CSSValue)]? {
        let layers = c.split(separator: .token(.comma), omittingEmptySubsequences: false)
        var colorValue: CSSColor?
        for (number, layer) in layers.enumerated() {
            guard !layer.isEmpty else { return nil }
            var image = false, position = false, repetition = false, attachment = false, boxes = 0
            var index = layer.startIndex
            while index < layer.endIndex {
                let component = layer[index], keyword = component.ident
                index += 1
                if !image, keyword == "none" || isImage(component) {
                    image = true
                } else if !repetition, let keyword, repeatKeywords.contains(keyword) {
                    repetition = true
                    // `repeat-x` and `repeat-y` stand alone; the others can name each axis.
                    if !keyword.hasPrefix("repeat-"), index < layer.endIndex, let next = layer[index].ident,
                       repeatKeywords.contains(next), !next.hasPrefix("repeat-") { index += 1 }
                } else if !attachment, let keyword, ["scroll", "fixed", "local"].contains(keyword) {
                    attachment = true
                } else if boxes < 2, let keyword, ["border-box", "padding-box", "content-box", "text"].contains(keyword) {
                    boxes += 1
                } else if !position, isPositionComponent(component) {
                    position = true
                    var end = index
                    while end < layer.endIndex, isPositionComponent(layer[end]) { end += 1 }
                    guard isPosition(layer[(index - 1)..<end], threeValues: true) else { return nil }
                    index = end
                    if index < layer.endIndex, layer[index].isDelim("/") {
                        guard let sizeEnd = backgroundSizeEnd(layer, from: index + 1) else { return nil }
                        index = sizeEnd
                    }
                } else if colorValue == nil, number == layers.count - 1, let value = color(component) {
                    colorValue = value
                } else {
                    return nil
                }
            }
        }
        return [(.backgroundColor, .color(colorValue ?? .rgba(ComputedStyle.Color(red: 0, green: 0, blue: 0, alpha: 0))))]
    }

    private static let repeatKeywords: Set<String> = ["repeat-x", "repeat-y", "repeat", "space", "round", "no-repeat"]

    /// Where a `<bg-size>` that starts at `start` ends: after `cover`, `contain`, or one or two
    /// of `auto` and a length or percentage.
    private static func backgroundSizeEnd(_ c: ArraySlice<CSSComponent>, from start: Int) -> Int? {
        guard start < c.endIndex else { return nil }
        if let keyword = c[start].ident, keyword == "cover" || keyword == "contain" { return start + 1 }
        var end = start
        while end < c.endIndex, end - start < 2, length(c[end], percent: true, negative: false, auto: true) != nil { end += 1 }
        return end > start ? end : nil
    }

    private static func isPositionComponent(_ component: CSSComponent) -> Bool {
        if let keyword = component.ident { return ["left", "center", "right", "top", "bottom"].contains(keyword) }
        return isLengthPercentage(component)
    }

    /// `<position>` (CSS Values 4 §9.2): one, two or four values, or three in a background
    /// (`<bg-position>`, CSS Backgrounds 3 §3.6).
    private static func isPosition(_ c: ArraySlice<CSSComponent>, threeValues: Bool) -> Bool {
        guard c.allSatisfy(isPositionComponent) else { return false }
        // A keyword, or nil for a length or percentage.
        let words = c.map(\.ident)
        let horizontal: Set<String?> = ["left", "center", "right", nil]
        let vertical: Set<String?> = ["top", "center", "bottom", nil]
        switch words.count {
        case 1:
            return true
        case 2:
            return horizontal.contains(words[0]) && vertical.contains(words[1])
                || ["top", "bottom", "center"].contains(words[0]) && ["left", "right", "center"].contains(words[1])
        case 3 where threeValues, 4:
            // A keyword for each axis, each but `center` with an optional offset after it.
            var axes: [String] = []
            var index = 0
            while index < words.count {
                guard let word = words[index] else { return false }
                index += 1
                if word != "center", index < words.count, words[index] == nil { index += 1 }
                axes.append(word)
            }
            guard axes.count == 2 else { return false }
            return horizontal.contains(axes[0]) && vertical.contains(axes[1])
                || vertical.contains(axes[0]) && horizontal.contains(axes[1])
        default:
            return false
        }
    }

    // MARK: Images

    /// An image as WebKit reads one: `url()`, a gradient in its standard form or in WebKit's
    /// prefixed one, with arguments that follow its grammar, an image set or a cross-fade. A
    /// gradient prefixed for another engine (`-moz-`, `-o-`, `-ms-`) is not one.
    static func isImage(_ component: CSSComponent) -> Bool {
        switch component {
        case .token(.url):
            return true
        case .function(let name, let arguments):
            let parts = arguments.commaSeparated
            switch name {
            case "url":
                guard parts.count == 1, parts[0].count == 1, case .token(.string) = parts[0][0] else { return false }
                return true
            case "linear-gradient", "repeating-linear-gradient":
                return isGradient(parts, prelude: { isInterpolated($0) { isLinearDirection($0, legacy: false) } },
                                  position: isLengthPercentage)
            case "-webkit-linear-gradient", "-webkit-repeating-linear-gradient":
                return isGradient(parts, prelude: { isLinearDirection($0, legacy: true) }, position: isLengthPercentage)
            case "radial-gradient", "repeating-radial-gradient":
                return isGradient(parts, prelude: { isInterpolated($0) { isRadialShape($0, legacy: false) } },
                                  position: isLengthPercentage)
            case "-webkit-radial-gradient", "-webkit-repeating-radial-gradient":
                // The position, when there is one, is a part of its own before the shape and size.
                var rest = parts[...]
                if let first = rest.first, isPosition(first[...], threeValues: false) { rest = rest.dropFirst() }
                return isGradient(Array(rest), prelude: { isRadialShape($0, legacy: true) }, position: isLengthPercentage)
            case "conic-gradient", "repeating-conic-gradient":
                return isGradient(parts, prelude: { isInterpolated($0, isConicShape) }, position: isAnglePercentage)
            case "-webkit-gradient":
                return isWebKitGradient(parts)
            case "image-set", "-webkit-image-set":
                // Each option an image or a URL string, with a resolution or a type.
                return parts.allSatisfy { option in
                    guard let first = option.first, option.count <= 3 else { return false }
                    if case .token(.string) = first {} else if !isImage(first) { return false }
                    return option.dropFirst().allSatisfy { component in
                        if case .function("type", _) = component { return true }
                        guard case .token(.dimension(_, let unit, _, _)) = component else { return false }
                        return ["x", "dppx", "dpi", "dpcm"].contains(unit.lowercased())
                    }
                }
            case "cross-fade", "-webkit-cross-fade":
                // WebKit's form: two images and how far to fade from the first to the second.
                return parts.count == 3 && parts.allSatisfy { $0.count == 1 } && isImage(parts[0][0]) && isImage(parts[1][0])
                    && isNumberOrPercentage(parts[2][0])
            default:
                return false
            }
        default:
            return false
        }
    }

    /// A gradient's arguments: a first part that `prelude` accepts unless it starts with a
    /// colour, then colour stops, at least two, each a colour with up to two positions that
    /// `position` accepts, and a position alone between two of them as a hint (CSS Images 4
    /// §3.5.3).
    private static func isGradient(_ parts: [[CSSComponent]], prelude: (ArraySlice<CSSComponent>) -> Bool,
                                   position: (CSSComponent) -> Bool) -> Bool {
        guard let first = parts.first?.first else { return false }
        let hasPrelude = color(first) == nil
        if hasPrelude, !prelude(parts[0][...]) { return false }
        var stops = 0, afterStop = false
        for part in parts.dropFirst(hasPrelude ? 1 : 0) {
            if part.count == 1, position(part[0]) {
                guard afterStop else { return false }
                afterStop = false
                continue
            }
            guard let stopColor = part.first, color(stopColor) != nil, part.count <= 3,
                  part.dropFirst().allSatisfy(position) else { return false }
            stops += 1
            afterStop = true
        }
        return stops >= 2 && afterStop
    }

    /// What `rest` accepts, with a colour interpolation method (`in oklch longer hue`, CSS
    /// Color 4 §12) before or after it, or the method alone.
    private static func isInterpolated(_ c: ArraySlice<CSSComponent>, _ rest: (ArraySlice<CSSComponent>) -> Bool) -> Bool {
        guard let start = c.firstIndex(where: { $0.ident == "in" }) else { return rest(c) }
        var end = start + 1
        guard end < c.endIndex, let space = c[end].ident,
              rectangularColorSpaces.contains(space) || polarColorSpaces.contains(space) else { return false }
        end += 1
        if polarColorSpaces.contains(space), end + 1 < c.endIndex, let method = c[end].ident,
           ["shorter", "longer", "increasing", "decreasing"].contains(method), c[end + 1].ident == "hue" { end += 2 }
        if start == c.startIndex { return end == c.endIndex || rest(c[end...]) }
        return end == c.endIndex && rest(c[..<start])
    }

    private static let rectangularColorSpaces: Set<String> = [
        "srgb", "srgb-linear", "display-p3", "a98-rgb", "prophoto-rgb", "rec2020", "lab", "oklab", "xyz", "xyz-d50", "xyz-d65"]
    private static let polarColorSpaces: Set<String> = ["hsl", "hwb", "lch", "oklch"]

    /// An angle, or `to` a side or corner. WebKit's prefixed form names the side it starts
    /// from, without `to`.
    private static func isLinearDirection(_ c: ArraySlice<CSSComponent>, legacy: Bool) -> Bool {
        if c.count == 1, let only = c.first, isAngle(only) { return true }
        let sides = legacy ? c : c.first?.ident == "to" ? c.dropFirst() : []
        let words = sides.compactMap(\.ident)
        let horizontal = words.filter { $0 == "left" || $0 == "right" }.count
        let vertical = words.filter { $0 == "top" || $0 == "bottom" }.count
        return !words.isEmpty && words.count == sides.count && horizontal <= 1 && vertical <= 1
            && horizontal + vertical == words.count
    }

    /// A shape (`circle` or `ellipse`) and a size in either order, either one optional, then
    /// `at` a position. WebKit's prefixed form has no `at` and also takes `contain` and `cover`.
    private static func isRadialShape(_ c: ArraySlice<CSSComponent>, legacy: Bool) -> Bool {
        var shapeAndSize = c
        if !legacy, let at = c.firstIndex(where: { $0.ident == "at" }) {
            guard isPosition(c[(at + 1)...], threeValues: false) else { return false }
            shapeAndSize = c[..<at]
        }
        let shapes = shapeAndSize.filter { $0.ident == "circle" || $0.ident == "ellipse" }
        let size = shapeAndSize.filter { $0.ident != "circle" && $0.ident != "ellipse" }
        guard shapes.count <= 1, shapes.isEmpty || shapeAndSize.first == shapes[0] || shapeAndSize.last == shapes[0] else {
            return false
        }
        let shape = shapes.first?.ident
        switch size.count {
        case 0:
            return true
        case 1:
            if let keyword = size[0].ident {
                return ["closest-side", "closest-corner", "farthest-side", "farthest-corner"].contains(keyword)
                    || legacy && (keyword == "contain" || keyword == "cover")
            }
            return shape != "ellipse" && length(size[0], percent: false, negative: false, auto: false) != nil
        case 2:
            return shape != "circle" && size.allSatisfy { length($0, percent: true, negative: false, auto: false) != nil }
        default:
            return false
        }
    }

    /// `from` an angle, then `at` a position, either one optional.
    private static func isConicShape(_ c: ArraySlice<CSSComponent>) -> Bool {
        var rest = c
        if rest.first?.ident == "from" {
            guard rest.count >= 2, isAngle(rest[rest.startIndex + 1]) else { return false }
            rest = rest.dropFirst(2)
        }
        guard let first = rest.first else { return !c.isEmpty }
        return first.ident == "at" && isPosition(rest.dropFirst(), threeValues: false)
    }

    /// WebKit's first gradient: `linear` and two points, or `radial` and two points each with a
    /// radius, then any number of `from()`, `to()` and `color-stop()`.
    private static func isWebKitGradient(_ parts: [[CSSComponent]]) -> Bool {
        guard let kind = parts.first, kind.count == 1, let name = kind[0].ident, name == "linear" || name == "radial" else {
            return false
        }
        let radial = name == "radial"
        let geometry = radial ? 4 : 2
        guard parts.count > geometry else { return false }
        for (offset, part) in parts[1...geometry].enumerated() {
            if radial, offset % 2 == 1 {
                guard part.count == 1, case .token(.number(let radius, _, _)) = part[0], radius >= 0 else { return false }
            } else {
                // A point: a number, a percentage or a keyword for each axis.
                guard part.count == 2,
                      isNumberOrPercentage(part[0]) || ["left", "center", "right"].contains(part[0].ident ?? ""),
                      isNumberOrPercentage(part[1]) || ["top", "center", "bottom"].contains(part[1].ident ?? "") else { return false }
            }
        }
        return parts.dropFirst(geometry + 1).allSatisfy { part in
            guard part.count == 1, case .function(let name, let arguments) = part[0] else { return false }
            let values = arguments.commaSeparated
            guard values.allSatisfy({ $0.count == 1 }), let stopColor = values.last?.first, color(stopColor) != nil else { return false }
            switch name {
            case "from", "to": return values.count == 1
            case "color-stop": return values.count == 2 && isNumberOrPercentage(values[0][0])
            default: return false
            }
        }
    }

    private static func isNumberOrPercentage(_ component: CSSComponent) -> Bool {
        switch component {
        case .token(.number), .token(.percentage): true
        default: false
        }
    }

    private static func isLengthPercentage(_ component: CSSComponent) -> Bool {
        length(component, percent: true, negative: true, auto: false) != nil
    }

    /// An angle; a unitless zero counts, as CSS Images 4 allows in gradients.
    private static func isAngle(_ component: CSSComponent) -> Bool {
        switch component {
        case .token(.dimension(_, let unit, _, _)): ["deg", "rad", "grad", "turn"].contains(unit.lowercased())
        case .token(.number(let value, _, _)): value == 0
        default: false
        }
    }

    private static func isAnglePercentage(_ component: CSSComponent) -> Bool {
        if case .token(.percentage) = component { return true }
        return isAngle(component)
    }
}
