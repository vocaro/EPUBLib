import CoreText
import Foundation

/// resvg uses font bytes rather than the platform's font rasterizer. Reconstruct a standalone
/// SFNT from CoreText's decoded tables, including archive WOFF/WOFF2 faces. Neither SVG nor
/// resvg gets a file path, and the known fallback faces are exported only once.
struct SVGFontData: Sendable {
    let family: String
    let data: Data
    let strippedColorGlyphs: Bool

    init(family: String, data: Data, strippedColorGlyphs: Bool = false) {
        self.family = family; self.data = data; self.strippedColorGlyphs = strippedColorGlyphs
    }

    // Color glyphs can contain SVG/SVGZ, unbounded raster images, or generated clipping
    // trees. Keep only the font's ordinary outlines so every drawing passes SVG preflight.
    private static let colorTables: Set<UInt32> = [
        0x53564720, 0x434F4C52, 0x4350414C, 0x73626978, // SVG, COLR, CPAL, sbix
        0x43424454, 0x43424C43, 0x45424454, 0x45424C43, // CBDT, CBLC, EBDT, EBLC
    ]

    static func hasColorGlyphs(_ font: CTFont) -> Bool {
        guard let tags = CTFontCopyAvailableTables(font, []) else { return false }
        return (0..<CFArrayGetCount(tags)).contains {
            colorTables.contains(UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(tags, $0))))
        }
    }

    static func hasColorGlyphs(_ data: Data) -> Bool {
        guard data.count >= 12 else { return true }
        let count = Int(data[4]) << 8 | Int(data[5])
        guard count <= 128, data.count >= 12 + count * 16 else { return true }
        return (0..<count).contains { index in
            let offset = 12 + index * 16
            let tag = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return colorTables.contains(tag)
        }
    }
    static let maximumBytes = 8 * 1024 * 1024

    static let defaults: [SVGFontData] = [
        "TimesNewRomanPSMT", "TimesNewRomanPS-BoldMT", "TimesNewRomanPS-ItalicMT", "TimesNewRomanPS-BoldItalicMT",
        "ArialMT", "Arial-BoldMT", "Arial-ItalicMT", "Arial-BoldItalicMT",
        "CourierNewPSMT", "CourierNewPS-BoldMT", "CourierNewPS-ItalicMT", "CourierNewPS-BoldItalicMT",
    ].compactMap { export(CTFontCreateWithName($0 as CFString, 12, nil)) }

    static func export(_ font: CTFont) -> SVGFontData? {
        guard let tags = CTFontCopyAvailableTables(font, []) else { return nil }
        let count = CFArrayGetCount(tags)
        guard count > 0, count <= 128 else { return nil }
        var tables: [(tag: UInt32, bytes: Data)] = []
        var total = 12 + count * 16
        // This CFArray has raw integer tags as pointer-sized values, not CFNumber objects.
        for index in 0..<count {
            let tag = UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(tags, index)))
            if colorTables.contains(tag) { continue }
            guard let table = CTFontCopyTable(font, tag, []) as Data?,
                  table.count <= maximumBytes - total else { return nil }
            // CoreText can return font tables backed by read-only mappings. Force owned
            // storage before editing `head`, rather than mutating the bridged CFData.
            var bytes = Data([UInt8](table))
            // The adjustment is computed after all directory checksums are known.
            if tag == 0x68656164, bytes.count >= 12 { bytes.replaceSubrange(8..<12, with: [0, 0, 0, 0]) }
            total += (bytes.count + 3) & ~3
            guard total <= maximumBytes else { return nil }
            tables.append((tag, bytes))
        }
        // Some Apple legacy faces (notably Courier) have no OS/2 table. fontdb otherwise
        // classifies every such face as weight 400, even when CoreText selects bold. Supply
        // the missing metrics/style record from that face's public CoreText properties.
        if !tables.contains(where: { $0.tag == 0x4F532F32 }) {
            var os2 = Data(count: 78) // OS/2 version 0
            func put(_ offset: Int, _ value: Int) {
                let bits = UInt16(truncatingIfNeeded: value)
                os2[offset] = UInt8((bits >> 8) & 255); os2[offset + 1] = UInt8(bits & 255)
            }
            let traits = CTFontGetSymbolicTraits(font)
            let bold = traits.contains(.traitBold), italic = traits.contains(.traitItalic)
            put(4, bold ? 700 : 400); put(6, 5)
            put(62, (bold ? 32 : 0) | (italic ? 1 : 0) | (!bold && !italic ? 64 : 0))
            put(66, 0xFFFF)
            let units = CGFloat(CTFontGetUnitsPerEm(font)) / max(1, CTFontGetSize(font))
            let ascent = Int((CTFontGetAscent(font) * units).rounded())
            let descent = Int((CTFontGetDescent(font) * units).rounded())
            put(68, ascent); put(70, -descent); put(72, Int((CTFontGetLeading(font) * units).rounded()))
            put(74, ascent); put(76, descent)
            tables.append((0x4F532F32, os2))
            guard total + 16 + 80 <= maximumBytes else { return nil }
        }
        tables.sort { $0.tag < $1.tag }
        guard tables.contains(where: { $0.tag == 0x676C7966 || $0.tag == 0x43464620 || $0.tag == 0x43464632 }) else { return nil }
        let power = 1 << Int(log2(Double(tables.count)))
        var output = Data()
        func u16(_ value: Int) { output.append(UInt8((value >> 8) & 255)); output.append(UInt8(value & 255)) }
        func u32(_ value: UInt32) {
            output.append(UInt8((value >> 24) & 255)); output.append(UInt8((value >> 16) & 255))
            output.append(UInt8((value >> 8) & 255)); output.append(UInt8(value & 255))
        }
        u32(tables.contains(where: { $0.tag == 0x43464620 || $0.tag == 0x43464632 }) ? 0x4F54544F : 0x00010000)
        u16(tables.count); u16(power * 16); u16(Int(log2(Double(power)))); u16(tables.count * 16 - power * 16)
        var offset = 12 + tables.count * 16
        var headOffset: Int?
        for table in tables {
            u32(table.tag); u32(checksum(table.bytes)); u32(UInt32(offset)); u32(UInt32(table.bytes.count))
            if table.tag == 0x68656164 { headOffset = offset }
            offset += (table.bytes.count + 3) & ~3
        }
        for table in tables {
            output.append(table.bytes)
            while output.count & 3 != 0 { output.append(0) }
        }
        if let headOffset, headOffset + 12 <= output.count {
            let adjustment = 0xB1B0AFBA &- checksum(output)
            output.replaceSubrange((headOffset + 8)..<(headOffset + 12), with: [
                UInt8((adjustment >> 24) & 255), UInt8((adjustment >> 16) & 255),
                UInt8((adjustment >> 8) & 255), UInt8(adjustment & 255),
            ])
        }
        return SVGFontData(family: CTFontCopyFamilyName(font) as String, data: output, strippedColorGlyphs: hasColorGlyphs(font))
    }

    private static func checksum(_ bytes: Data) -> UInt32 {
        var result: UInt32 = 0
        var word: UInt32 = 0
        for (index, byte) in bytes.enumerated() {
            word = (word << 8) | UInt32(byte)
            if index & 3 == 3 { result = result &+ word; word = 0 }
        }
        if bytes.count & 3 != 0 { result = result &+ (word << UInt32((4 - (bytes.count & 3)) * 8)) }
        return result
    }
}
