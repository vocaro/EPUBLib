import CoreGraphics
import CoreText
import Foundation

/// A TrueType font made in the test, as a host's own bundled font would be registered, with no
/// font file in the repository: printable ASCII alone (U+0020–U+007E), each character but the
/// space a filled box. Anything else, Greek or an accented letter, it has no glyph for.
///
/// Its tables are the minimum CoreText reads (OpenType 1.9: `OS/2`, `cmap` format 4, `glyf`,
/// `head`, `hhea`, `hmtx`, `loca`, `maxp`, `name`, `post` 3.0), with checksums.
enum TestFontFactory {
    static let family = "EPUBLib Test Face"
    static let postScriptName = "EPUBLibTestFace-Regular"

    /// Registers the font for this process once, as `CTFontManagerRegisterFontsForURL` registers
    /// a host's, from a file in the temporary directory. Returns whether it is registered.
    static let registered: Bool = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBLibTestFace-\(ProcessInfo.processInfo.processIdentifier).ttf")
        do { try data().write(to: url) } catch { return false }
        var error: Unmanaged<CFError>?
        let done = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !done, let error = error?.takeRetainedValue(),
           CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue { return true }
        return done
    }()

    static let firstCharacter: UInt16 = 0x20
    static let lastCharacter: UInt16 = 0x7E
    private static let unitsPerEm: UInt16 = 1000

    static func data() -> Data {
        // Glyph 0 is .notdef, then one glyph a character: the space empty, the rest a box.
        let characters = Int(lastCharacter - firstCharacter) + 1
        let glyphCount = 1 + characters
        var box = Writer()
        box.int16(1); box.int16(50); box.int16(0); box.int16(450); box.int16(700) // one contour, bounds
        box.uint16(3) // its last point
        box.uint16(0) // no instructions
        for _ in 0..<4 { box.uint8(0x01) } // on-curve points, 16-bit coordinates
        for x in [50, 0, 400, 0] { box.int16(Int16(x)) }
        for y in [0, 700, 0, -700] { box.int16(Int16(y)) }
        box.pad()

        var glyf = Writer(), loca = Writer(), hmtx = Writer()
        for glyph in 0..<glyphCount {
            loca.uint32(UInt32(glyf.data.count))
            let isBox = glyph > 1
            if isBox { glyf.bytes(box.data) }
            hmtx.uint16(glyph == 1 ? 250 : 500); hmtx.int16(isBox ? 50 : 0)
        }
        loca.uint32(UInt32(glyf.data.count))

        // cmap: one format 4 subtable for Windows Unicode BMP: U+0020–U+007E to glyphs 1…95 by
        // one delta, and the closing U+FFFF segment.
        var cmap = Writer()
        cmap.uint16(0); cmap.uint16(1)
        cmap.uint16(3); cmap.uint16(1); cmap.uint32(12)
        let segments: [(start: UInt16, end: UInt16, delta: Int16)] = [(firstCharacter, lastCharacter, Int16(1) - Int16(firstCharacter)), (0xFFFF, 0xFFFF, 1)]
        cmap.uint16(4); cmap.uint16(UInt16(16 + 8 * segments.count)); cmap.uint16(0)
        cmap.uint16(UInt16(2 * segments.count)); cmap.uint16(4); cmap.uint16(1); cmap.uint16(0)
        for segment in segments { cmap.uint16(segment.end) }
        cmap.uint16(0)
        for segment in segments { cmap.uint16(segment.start) }
        for segment in segments { cmap.int16(segment.delta) }
        for _ in segments { cmap.uint16(0) }

        var head = Writer()
        head.uint32(0x0001_0000); head.uint32(0x0001_0000); head.uint32(0) // version, revision, adjustment
        head.uint32(0x5F0F_3CF5); head.uint16(0x000B); head.uint16(unitsPerEm)
        head.uint32(0); head.uint32(0); head.uint32(0); head.uint32(0) // created, modified
        head.int16(0); head.int16(0); head.int16(450); head.int16(700)
        head.uint16(0); head.uint16(8); head.int16(2); head.int16(1); head.int16(0) // long loca

        var hhea = Writer()
        hhea.uint32(0x0001_0000); hhea.int16(800); hhea.int16(-200); hhea.int16(0)
        hhea.uint16(500); hhea.int16(0); hhea.int16(0); hhea.int16(450)
        hhea.int16(1); hhea.int16(0); hhea.int16(0)
        for _ in 0..<4 { hhea.int16(0) }
        hhea.int16(0); hhea.uint16(UInt16(glyphCount))

        var maxp = Writer()
        maxp.uint32(0x0001_0000); maxp.uint16(UInt16(glyphCount)); maxp.uint16(4); maxp.uint16(1)
        maxp.uint16(0); maxp.uint16(0); maxp.uint16(2)
        for _ in 0..<8 { maxp.uint16(0) }

        var os2 = Writer()
        os2.uint16(4); os2.int16(500); os2.uint16(400); os2.uint16(5); os2.uint16(0)
        for value in [650, 600, 0, 75, 650, 600, 0, 350, 50, 300] { os2.int16(Int16(value)) }
        os2.int16(0)
        for _ in 0..<10 { os2.uint8(0) }
        os2.uint32(1); os2.uint32(0); os2.uint32(0); os2.uint32(0) // Basic Latin
        os2.bytes(Data("NONE".utf8))
        os2.uint16(0x0040); os2.uint16(firstCharacter); os2.uint16(lastCharacter)
        os2.int16(800); os2.int16(-200); os2.int16(0); os2.uint16(800); os2.uint16(200)
        os2.uint32(1); os2.uint32(0) // Latin 1
        os2.int16(500); os2.int16(700); os2.uint16(0); os2.uint16(0x20); os2.uint16(1)

        let names: [(UInt16, String)] = [(1, family), (2, "Regular"), (3, postScriptName), (4, family), (6, postScriptName)]
        var name = Writer(), strings = Writer()
        name.uint16(0); name.uint16(UInt16(names.count)); name.uint16(UInt16(6 + 12 * names.count))
        for (id, text) in names {
            let utf16 = Data(text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
            name.uint16(3); name.uint16(1); name.uint16(0x0409); name.uint16(id)
            name.uint16(UInt16(utf16.count)); name.uint16(UInt16(strings.data.count))
            strings.bytes(utf16)
        }
        name.bytes(strings.data)

        var post = Writer()
        post.uint32(0x0003_0000); post.uint32(0); post.int16(-100); post.int16(50)
        for _ in 0..<5 { post.uint32(0) }

        let tables: [(String, Data)] = [("OS/2", os2.data), ("cmap", cmap.data), ("glyf", glyf.data), ("head", head.data),
                                        ("hhea", hhea.data), ("hmtx", hmtx.data), ("loca", loca.data), ("maxp", maxp.data),
                                        ("name", name.data), ("post", post.data)]
        var font = Writer()
        font.uint32(0x0001_0000); font.uint16(UInt16(tables.count))
        font.uint16(128); font.uint16(3); font.uint16(UInt16(tables.count * 16 - 128))
        var offset = 12 + 16 * tables.count
        var body = Writer()
        var headOffset = 0
        for (tag, table) in tables {
            font.bytes(Data(tag.utf8)); font.uint32(checksum(table)); font.uint32(UInt32(offset)); font.uint32(UInt32(table.count))
            if tag == "head" { headOffset = offset }
            body.bytes(table); body.pad()
            offset += (table.count + 3) / 4 * 4
        }
        font.bytes(body.data)
        var result = font.data
        let adjustment = 0xB1B0_AFBA &- checksum(result)
        for (index, byte) in [UInt8(adjustment >> 24), UInt8(adjustment >> 16 & 0xFF), UInt8(adjustment >> 8 & 0xFF),
                              UInt8(adjustment & 0xFF)].enumerated() {
            result[headOffset + 8 + index] = byte
        }
        return result
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        var index = 0
        let bytes = [UInt8](data)
        while index < bytes.count {
            var word: UInt32 = 0
            for offset in 0..<4 { word = word << 8 | UInt32(index + offset < bytes.count ? bytes[index + offset] : 0) }
            sum = sum &+ word
            index += 4
        }
        return sum
    }

    private struct Writer {
        var data = Data()
        mutating func uint8(_ value: UInt8) { data.append(value) }
        mutating func uint16(_ value: UInt16) { data.append(UInt8(value >> 8)); data.append(UInt8(value & 0xFF)) }
        mutating func int16(_ value: Int16) { uint16(UInt16(bitPattern: value)) }
        mutating func uint32(_ value: UInt32) { uint16(UInt16(value >> 16)); uint16(UInt16(value & 0xFFFF)) }
        mutating func bytes(_ value: Data) { data.append(value) }
        mutating func pad() { while data.count % 4 != 0 { data.append(0) } }
    }
}
