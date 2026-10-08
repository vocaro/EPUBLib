import CoreGraphics
import CoreText
import EPUBReading
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Resolves computed font properties to platform fonts, including the book's `@font-face`
/// fonts (decoded from the archive, IDPF/Adobe obfuscation already removed by `EPUBReading`).
/// Thread-safe: sections build concurrently.
///
/// Matching follows CSS Fonts §5.2 for style and weight within each family of the list in turn:
/// the book's faces first, then generic families (serif is the system serif design, New York;
/// sans-serif and system-ui the system font; monospace its monospaced design; cursive and
/// fantasy serif), then installed families by name. A face without italics is used upright and
/// `needsSyntheticItalic(for:)` reports it so the builder can apply `.obliqueness`.
final class FontRegistry: @unchecked Sendable {
    static let maximumFonts = 64
    static let maximumFontBytes = 64 * 1024 * 1024
    static let maximumFaces = 512
    static let maximumCachedFonts = 4096
    static let maximumInstalledLookups = 256

    private let publication: EPUBPublication
    /// Guards the state below.
    private let lock = NSLock()
    /// Serializes registration, so a section never resolves a face another section is still loading.
    private let registration = NSLock()
    /// Bumped whenever faces change, so a resolution computed from older faces is not cached.
    private var generation = 0
    private var registered = Set<CSSFontFace>()
    /// Loaded faces by lowercased family.
    private var faces: [String: [Face]] = [:]
    private var loadedFonts = 0
    private var loadedBytes = 0
    /// Descriptors by archive path; nil when the source could not be loaded.
    private var sources: [String: [CTFontDescriptor]?] = [:]
    private var installed: [String: [Face]] = [:]
    private var resolutions: [ResolutionKey: Resolution] = [:]
    private var cache: [FontKey: PlatformFont] = [:]

    private struct Face {
        let weights: ClosedRange<Int>
        let isItalic: Bool
        let descriptor: CTFontDescriptor
        /// The font has a `wght` axis and the face declares a weight range.
        let isVariable: Bool
    }
    private struct ResolutionKey: Hashable { let families: [String]; let weight: Int; let italic: Bool }
    private struct Resolution {
        enum Source { case face(CTFontDescriptor, variableWeight: Int?), system(Design) }
        let source: Source
        let syntheticItalic: Bool
    }
    private enum Design { case serif, sans, monospace, rounded }
    private struct FontKey: Hashable { let families: [String]; let size: CGFloat; let weight: Int; let italic: Bool; let smallCaps: Bool }

    init(publication: EPUBPublication) { self.publication = publication }

    /// Registers a section's `@font-face` rules. Faces already registered are ignored. Sources are
    /// read and decoded now so failures reach the section's report; the book's total is bounded.
    func register(_ faces: [CSSFontFace], report: inout SectionReport) {
        registration.lock(); defer { registration.unlock() }
        for face in faces {
            lock.lock()
            let isNew = registered.count < Self.maximumFaces && registered.insert(face).inserted
            lock.unlock()
            guard isNew else { continue }
            var loaded: Face?
            for path in face.sources {
                guard let descriptors = descriptors(at: path, report: &report), !descriptors.isEmpty else { continue }
                let descriptor = Self.best(descriptors, weight: face.weights.lowerBound, italic: face.isItalic)
                let variable = face.weights.lowerBound != face.weights.upperBound && Self.hasWeightAxis(descriptor)
                loaded = Face(weights: face.weights, isItalic: face.isItalic, descriptor: descriptor, isVariable: variable)
                break
            }
            guard let loaded else { report.unreadableResources += 1; continue }
            lock.lock()
            self.faces[face.family, default: []].append(loaded)
            // Faces change what a family resolves to.
            generation += 1
            resolutions.removeAll(); cache.removeAll()
            lock.unlock()
        }
    }

    private func descriptors(at path: String, report: inout SectionReport) -> [CTFontDescriptor]? {
        lock.lock()
        if let known = sources[path] { lock.unlock(); return known }
        lock.unlock()
        guard let data = try? publication.data(at: path) else {
            lock.lock(); sources[path] = .some(nil); lock.unlock()
            return nil
        }
        lock.lock()
        guard loadedFonts < Self.maximumFonts, loadedBytes + data.count <= Self.maximumFontBytes else {
            lock.unlock()
            report.stylesTruncated = true
            return nil
        }
        loadedFonts += 1; loadedBytes += data.count
        lock.unlock()
        let descriptors = Self.isFontData(data)
            ? (CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor] ?? []) : []
        lock.lock(); sources[path] = descriptors.isEmpty ? .some(nil) : descriptors; lock.unlock()
        return descriptors.isEmpty ? nil : descriptors
    }

    /// TrueType, OpenType, collections, WOFF and WOFF2, which CoreText decodes; EOT and SVG fonts are not.
    static func isFontData(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let magic = data.prefix(4)
        return [[0x00, 0x01, 0x00, 0x00], Array("OTTO".utf8), Array("true".utf8), Array("ttcf".utf8),
                Array("wOFF".utf8), Array("wOF2".utf8), Array("typ1".utf8)].contains { $0.elementsEqual(magic) }
    }

    func font(for style: ComputedStyle) -> PlatformFont {
        let key = FontKey(families: style.fontFamilies, size: style.fontSize, weight: style.fontWeight,
                          italic: style.isItalic, smallCaps: style.isSmallCaps)
        lock.lock()
        if let font = cache[key] { lock.unlock(); return font }
        let current = generation
        lock.unlock()
        let resolution = resolve(families: style.fontFamilies, weight: style.fontWeight, italic: style.isItalic)
        let font = Self.makeFont(resolution, size: style.fontSize, weight: style.fontWeight,
                                 italic: style.isItalic, smallCaps: style.isSmallCaps)
        lock.lock()
        if generation == current {
            if cache.count >= Self.maximumCachedFonts { cache.removeAll() }
            cache[key] = font
        }
        lock.unlock()
        return font
    }

    /// Whether `font(for:)` returned an upright face for an italic style, so the builder should
    /// slant it (`.obliqueness`).
    func needsSyntheticItalic(for style: ComputedStyle) -> Bool {
        style.isItalic && resolve(families: style.fontFamilies, weight: style.fontWeight, italic: true).syntheticItalic
    }

    /// Whether small caps were asked for but the font has no lower-case small caps feature, so
    /// the builder should fake them (uppercase at a smaller size).
    func needsSyntheticSmallCaps(for style: ComputedStyle) -> Bool {
        guard style.isSmallCaps else { return false }
        let features = CTFontCopyFeatures(font(for: style) as CTFont) as? [[CFString: Any]] ?? []
        return !features.contains { feature in
            let type = feature[kCTFontFeatureTypeIdentifierKey] as? Int
            let selectors = feature[kCTFontFeatureTypeSelectorsKey] as? [[CFString: Any]] ?? []
            return selectors.contains { selector in
                let id = selector[kCTFontFeatureSelectorIdentifierKey] as? Int
                return (type == kLowerCaseType && id == kLowerCaseSmallCapsSelector) || (type == kLetterCaseType && id == 3)
            }
        }
    }

    // MARK: Matching

    private func resolve(families: [String], weight: Int, italic: Bool) -> Resolution {
        let key = ResolutionKey(families: families, weight: weight, italic: italic)
        lock.lock()
        if let known = resolutions[key] { lock.unlock(); return known }
        let bookFaces = faces, current = generation
        lock.unlock()
        var resolution: Resolution?
        for family in families {
            if let candidates = bookFaces[family], let match = Self.match(candidates, weight: weight, italic: italic) {
                resolution = match; break
            }
            if let design = Self.generic(family) {
                resolution = Resolution(source: .system(design), syntheticItalic: false); break
            }
            if let candidates = installedFaces(family), let match = Self.match(candidates, weight: weight, italic: italic) {
                resolution = match; break
            }
            if let design = Self.aliases[family] {
                resolution = Resolution(source: .system(design), syntheticItalic: false); break
            }
        }
        let result = resolution ?? Resolution(source: .system(.serif), syntheticItalic: false)
        lock.lock()
        if generation == current {
            if resolutions.count >= Self.maximumCachedFonts { resolutions.removeAll() }
            resolutions[key] = result
        }
        lock.unlock()
        return result
    }

    private static func match(_ candidates: [Face], weight: Int, italic: Bool) -> Resolution? {
        let preferred = candidates.filter { $0.isItalic == italic }
        let pool = preferred.isEmpty ? candidates : preferred
        guard let face = pool.min(by: { weightDistance($0.weights, weight) < weightDistance($1.weights, weight) }) else { return nil }
        let variableWeight = face.isVariable ? min(max(weight, face.weights.lowerBound), face.weights.upperBound) : nil
        return Resolution(source: .face(face.descriptor, variableWeight: variableWeight), syntheticItalic: italic && !face.isItalic)
    }

    /// CSS Fonts §5.2 weight matching as a sortable distance: inside the range is best; then for
    /// 400–500 heavier up to 500, lighter, heavier; below 400 lighter first; above 500 heavier first.
    private static func weightDistance(_ range: ClosedRange<Int>, _ desired: Int) -> Int {
        if range.contains(desired) { return 0 }
        let below = range.upperBound < desired
        let gap = below ? desired - range.upperBound : range.lowerBound - desired
        switch desired {
        case 400...500:
            if !below, range.lowerBound <= 500 { return gap }
            return below ? 1000 + gap : 2000 + gap
        case ..<400:
            return below ? gap : 1000 + gap
        default:
            return below ? 1000 + gap : gap
        }
    }

    private static func generic(_ family: String) -> Design? {
        switch family {
        case "serif", "ui-serif", "cursive", "fantasy", "math", "fangsong": .serif
        case "sans-serif", "system-ui", "ui-sans-serif", "-apple-system", "blinkmacsystemfont", "emoji": .sans
        case "monospace", "ui-monospace": .monospace
        case "ui-rounded": .rounded
        default: nil
        }
    }

    /// Common families that are not installed on Apple platforms, by the generic they stand for.
    private static let aliases: [String: Design] = [
        "consolas": .monospace, "lucida console": .monospace, "dejavu sans mono": .monospace,
        "liberation mono": .monospace, "source code pro": .monospace, "inconsolata": .monospace,
        "droid sans mono": .monospace, "ubuntu mono": .monospace, "fira mono": .monospace, "fira code": .monospace,
        "calibri": .sans, "segoe ui": .sans, "tahoma": .sans, "open sans": .sans, "roboto": .sans,
        "dejavu sans": .sans, "liberation sans": .sans, "noto sans": .sans, "lato": .sans, "arial unicode ms": .sans,
        "cambria": .serif, "liberation serif": .serif, "dejavu serif": .serif, "noto serif": .serif,
        "book antiqua": .serif, "garamond": .serif, "minion pro": .serif,
    ]

    /// Members of an installed family, cached (including absence) and bounded per book.
    private func installedFaces(_ family: String) -> [Face]? {
        guard !family.hasPrefix("."), !family.isEmpty else { return nil }
        lock.lock()
        if let known = installed[family] { lock.unlock(); return known.isEmpty ? nil : known }
        let exhausted = installed.count >= Self.maximumInstalledLookups
        lock.unlock()
        guard !exhausted else { return nil }
        let request = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let mandatory = Set([kCTFontFamilyNameAttribute as String]) as CFSet
        let members = CTFontDescriptorCreateMatchingFontDescriptors(request, mandatory) as? [CTFontDescriptor] ?? []
        let result = members.compactMap { descriptor -> Face? in
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  name.lowercased() == family, !name.hasPrefix(".") else { return nil }
            let (weight, italic) = Self.traits(descriptor)
            return Face(weights: weight...weight, isItalic: italic, descriptor: descriptor, isVariable: false)
        }
        lock.lock(); installed[family] = result; lock.unlock()
        return result.isEmpty ? nil : result
    }

    /// CSS weight and italic from CoreText traits.
    private static func traits(_ descriptor: CTFontDescriptor) -> (Int, Bool) {
        let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
        let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        let italic = symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0
        let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        // CoreText's normalized weights for thin…black, as UIFont.Weight and NSFont.Weight define them.
        let scale: [(Double, Int)] = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600),
                                      (0.4, 700), (0.56, 800), (0.62, 900)]
        let css = scale.min { abs($0.0 - weight) < abs($1.0 - weight) }!.1
        return (css, italic)
    }

    /// The descriptor of a font file closest to the face's declared weight and style (a
    /// collection or variable font yields several).
    private static func best(_ descriptors: [CTFontDescriptor], weight: Int, italic: Bool) -> CTFontDescriptor {
        guard descriptors.count > 1 else { return descriptors[0] }
        return descriptors.min { a, b in
            let (wa, ia) = traits(a), (wb, ib) = traits(b)
            return (ia != italic ? 1000 : 0) + abs(wa - weight) < (ib != italic ? 1000 : 0) + abs(wb - weight)
        }!
    }

    private static let weightAxis = 0x7767_6874 // 'wght'

    private static func hasWeightAxis(_ descriptor: CTFontDescriptor) -> Bool {
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]] ?? []
        return axes.contains { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.intValue == weightAxis }
    }

    // MARK: Fonts

    private static func makeFont(_ resolution: Resolution, size: CGFloat, weight: Int, italic: Bool, smallCaps: Bool) -> PlatformFont {
        var font: CTFont
        switch resolution.source {
        case .face(var descriptor, let variableWeight):
            if let variableWeight {
                descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, weightAxis as CFNumber, CGFloat(variableWeight))
            }
            font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        case .system(let design):
            font = systemFont(design, size: size, weight: weight, italic: italic) as CTFont
        }
        if smallCaps {
            let base = CTFontCopyFontDescriptor(font)
            let descriptor = CTFontDescriptorCreateCopyWithFeature(base, kLowerCaseType as CFNumber, kLowerCaseSmallCapsSelector as CFNumber)
            font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        return font as PlatformFont
    }

    private static func systemFont(_ design: Design, size: CGFloat, weight: Int, italic: Bool) -> PlatformFont {
        #if os(iOS)
        let platformWeight: UIFont.Weight = switch weight {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
        var descriptor = UIFont.systemFont(ofSize: size, weight: platformWeight).fontDescriptor
        let systemDesign: UIFontDescriptor.SystemDesign? = switch design {
        case .serif: .serif
        case .monospace: .monospaced
        case .rounded: .rounded
        case .sans: nil
        }
        if let systemDesign { descriptor = descriptor.withDesign(systemDesign) ?? descriptor }
        if italic { descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) ?? descriptor }
        return UIFont(descriptor: descriptor, size: size)
        #else
        let platformWeight: NSFont.Weight = switch weight {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
        var descriptor = NSFont.systemFont(ofSize: size, weight: platformWeight).fontDescriptor
        let systemDesign: NSFontDescriptor.SystemDesign? = switch design {
        case .serif: .serif
        case .monospace: .monospaced
        case .rounded: .rounded
        case .sans: nil
        }
        if let systemDesign { descriptor = descriptor.withDesign(systemDesign) ?? descriptor }
        if italic { descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic)) }
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
        #endif
    }

    /// The reader's base font in its default design, used outside any stylesheet.
    static func systemFont(families: [String], size: CGFloat, weight: Int, italic: Bool) -> PlatformFont {
        let design = families.lazy.compactMap { generic($0) ?? aliases[$0] }.first ?? .serif
        return systemFont(design, size: size, weight: weight, italic: italic)
    }
}
