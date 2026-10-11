import CoreText
import EPUBReading
@testable import EPUBViewing
import Foundation
import XCTest

/// Helpers for the `CSSCascade…CoverageTests`: computed styles by element id, and font files
/// borrowed from the system for `@font-face` loading.
enum CSSCascadeSupport {
    static func styled(_ body: String, css: String = "", head: String = "", files: [String: String] = [:],
                       typography: NativeTypography = NativeTypography(fontSize: 16)) throws -> StyledDocument {
        try StyleTestSupport.styled(body, css: css, head: head, files: files, typography: typography)
    }

    /// The computed style of one `<p id="p">` under one author rule body, e.g. `"width: 1in"`.
    static func paragraph(_ declarations: String, typography: NativeTypography = NativeTypography(fontSize: 16)) throws -> ComputedStyle {
        try styled(#"<p id="p">x</p>"#, css: "#p { \(declarations) }", typography: typography).style("p")
    }

    static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> ComputedStyle.Color {
        ComputedStyle.Color(red: red, green: green, blue: blue, alpha: alpha)
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> ComputedStyle.Color {
        color(CGFloat(value >> 16 & 0xFF) / 255, CGFloat(value >> 8 & 0xFF) / 255, CGFloat(value & 0xFF) / 255, alpha)
    }

    static func points(_ length: ComputedStyle.Length, file: StaticString = #filePath, line: UInt = #line) -> CGFloat {
        if case .points(let value) = length { return value }
        XCTFail("\(length) is not in points", file: file, line: line)
        return .nan
    }

    static func assertColor(_ actual: ComputedStyle.Color?, _ expected: ComputedStyle.Color, _ message: String = "",
                            accuracy: CGFloat = 0.002, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("no color; expected \(expected). \(message)", file: file, line: line) }
        for (a, e) in [(actual.red, expected.red), (actual.green, expected.green), (actual.blue, expected.blue), (actual.alpha, expected.alpha)] {
            XCTAssertEqual(a, e, accuracy: accuracy, "\(actual) is not \(expected). \(message)", file: file, line: line)
        }
    }

    /// The file of an installed font, to stand in for a book's embedded font.
    static func fontFile(_ postScriptName: String) throws -> Data {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        guard CTFontCopyPostScriptName(font) as String == postScriptName,
              let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
              let data = try? Data(contentsOf: url) else { throw XCTSkip("\(postScriptName) is not installed") }
        return data
    }

    /// The smallest installed font found, for tests that need many font files.
    static func smallFontFile() throws -> Data {
        for name in ["NotoSansLycian-Regular", "NotoSansGothic-Regular", "Georgia"] {
            if let data = try? fontFile(name) { return data }
        }
        throw XCTSkip("No candidate font is installed")
    }

    static func registry(files: [String: Data] = [:]) throws -> FontRegistry {
        FontRegistry(publication: try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: "<p>x</p>"), files: files))
    }

    static func fontStyle(_ families: [String], weight: Int = 400, italic: Bool = false) -> ComputedStyle {
        var style = ComputedStyle()
        style.fontFamilies = families; style.fontSize = 17; style.fontWeight = weight; style.isItalic = italic
        return style
    }

    /// Wraps a TrueType or OpenType font in a WOFF 1.0 container with its tables stored
    /// uncompressed (WOFF §5: a table whose compressed length equals its original length is stored).
    static func woff(from sfnt: Data) throws -> Data {
        let bytes = [UInt8](sfnt)
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        func u32(_ at: Int) -> Int { u16(at) << 16 | u16(at + 2) }
        guard bytes.count > 12, [[0, 1, 0, 0], Array("OTTO".utf8), Array("true".utf8)].contains(Array(bytes[0..<4])) else {
            throw XCTSkip("The font is not a single sfnt file")
        }
        let count = u16(4)
        guard bytes.count >= 12 + 16 * count else { throw XCTSkip("The font's table directory is cut short") }
        struct Table { let tag: [UInt8], checksum: Int, offset: Int, length: Int }
        let tables = (0..<count).map { index -> Table in
            let at = 12 + 16 * index
            return Table(tag: Array(bytes[at..<at + 4]), checksum: u32(at + 4), offset: u32(at + 8), length: u32(at + 12))
        }
        guard tables.allSatisfy({ $0.offset + $0.length <= bytes.count }) else { throw XCTSkip("The font's tables are cut short") }
        var out: [UInt8] = []
        func put16(_ value: Int) { out += [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func put32(_ value: Int) { put16(value >> 16 & 0xFFFF); put16(value & 0xFFFF) }
        func padded(_ length: Int) -> Int { (length + 3) & ~3 }
        // Table data keeps the font's physical order; the directory keeps its tag order.
        let physical = tables.indices.sorted { tables[$0].offset < tables[$1].offset }
        var offsets = [Int](repeating: 0, count: count)
        var cursor = 44 + 20 * count
        for index in physical { offsets[index] = cursor; cursor += padded(tables[index].length) }
        out += Array("wOFF".utf8); out += bytes[0..<4]; put32(cursor); put16(count); put16(0)
        put32(12 + 16 * count + tables.reduce(0) { $0 + padded($1.length) }); put16(1); put16(0)
        for _ in 0..<5 { put32(0) }
        for (index, table) in tables.enumerated() {
            out += table.tag; put32(offsets[index]); put32(table.length); put32(table.length); put32(table.checksum)
        }
        for index in physical {
            let table = tables[index]
            out += bytes[table.offset..<table.offset + table.length]
            out += [UInt8](repeating: 0, count: padded(table.length) - table.length)
        }
        return Data(out)
    }
}
