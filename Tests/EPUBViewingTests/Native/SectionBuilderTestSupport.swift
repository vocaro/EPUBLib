import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Builds inline XHTML with the skeleton's user-agent defaults plus per-test computed-style
/// overrides, so builder tests do not depend on the CSS engine.
enum BuilderHarness {
    typealias Rule = (selector: String, apply: (inout ComputedStyle) -> Void)

    static let publication: EPUBPublication = {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Builder</dc:title><dc:language>en</dc:language><dc:identifier id="uid">builder</dc:identifier></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="picture" href="picture.png" media-type="image/png"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>
        """
        return try! EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/book.opf": opf, "OPS/picture.png": "not really a png"]))
    }()

    static func document(_ body: String, head: String = "", rootAttributes: String = "") throws -> ContentDocument {
        let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" \(rootAttributes)><head>\(head)</head><body>\(body)</body></html>
        """
        return try ContentDocument.parse(Data(xhtml.utf8), path: "OPS/one.xhtml")
    }

    static func build(_ body: String, head: String = "", rootAttributes: String = "", dark: Bool = false,
                      rich: any RichContentFactory = PlaceholderRichContent(), rules: [Rule] = []) throws -> SectionText {
        try build(document: document(body, head: head, rootAttributes: rootAttributes), dark: dark, rich: rich, rules: rules)
    }

    static func build(document: ContentDocument, dark: Bool = false, spineIndex: Int = 0,
                      rich: any RichContentFactory = PlaceholderRichContent(), rules: [Rule] = [],
                      publication: EPUBPublication = publication, fonts: FontRegistry? = nil) -> SectionText {
        let typography = NativeTypography(fontSize: 16, isDark: dark)
        let request = SectionBuildRequest(publication: publication, spineIndex: spineIndex, typography: typography,
                                          fonts: fonts ?? FontRegistry(publication: publication), rich: rich)
        let resolver = StyleResolver(document: document, stylesheets: [], typography: typography)
        return SectionBuilder.build(document: document, request: request, initialStyle: resolver.initialStyle) { node, parent in
            var style = resolver.style(for: node, parent: parent)
            for rule in rules where matches(rule.selector, node) { rule.apply(&style) }
            return style
        }
    }

    /// `tag`, `.class` or `#id`.
    private static func matches(_ selector: String, _ node: ContentNode) -> Bool {
        if selector.hasPrefix("#") { return node.id == String(selector.dropFirst()) }
        if selector.hasPrefix(".") { return node.classNames.contains(String(selector.dropFirst())) }
        return node.name == selector
    }

    static func paragraphStyle(_ text: SectionText, at location: Int) -> NSParagraphStyle? {
        text.string.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
    }

    static func location(of substring: String, in text: SectionText) -> Int {
        (text.string.string as NSString).range(of: substring).location
    }

    static func attribute(_ key: NSAttributedString.Key, of substring: String, in text: SectionText) -> Any? {
        let location = location(of: substring, in: text)
        guard location != NSNotFound else { return nil }
        return text.string.attribute(key, at: location, effectiveRange: nil)
    }

    /// Every mapped character maps to a DOM position that maps back to it (exact spans) or to
    /// its span's start (units and collapsed whitespace); spans are ordered and within the text.
    static func assertMapRoundTrips(_ text: SectionText, file: StaticString = #filePath, line: UInt = #line) {
        let map = text.map, document = text.document
        XCTAssertEqual(map.length, text.string.length, "map length", file: file, line: line)
        let rendered = Array(text.string.string.utf16)
        var previousEnd = 0, previousSource = (node: -1, offset: -1)
        for span in map.spans {
            XCTAssertGreaterThanOrEqual(span.location, previousEnd, "spans overlap", file: file, line: line)
            XCTAssertLessThanOrEqual(span.location + span.length, map.length, "span past the end", file: file, line: line)
            XCTAssertTrue(span.node > previousSource.node || (span.node == previousSource.node && span.offset >= previousSource.offset),
                          "spans out of source order", file: file, line: line)
            previousEnd = span.location + span.length
            previousSource = (span.node, span.offset)
            let node = document.nodes[span.node]
            if span.isExact {
                XCTAssertTrue(node.isText, file: file, line: line)
                XCTAssertEqual(span.length, span.sourceLength, file: file, line: line)
                let source = Array(node.text.utf16)
                for index in 0..<span.length {
                    let character = rendered[span.location + index], original = source[span.offset + index]
                    let newline = (original == 0x0A || original == 0x0D || original == 0x2029 || original == 0x85) && character == 0x2028
                    if character != original && !newline {
                        XCTAssertEqual(String(utf16CodeUnits: [character], count: 1).lowercased(),
                                       String(utf16CodeUnits: [original], count: 1).lowercased(),
                                       "exact span renders other text", file: file, line: line)
                    }
                }
            }
            for index in 0..<span.length {
                let location = span.location + index
                guard let position = map.position(at: location, in: document) else {
                    XCTFail("unmapped location \(location)", file: file, line: line); continue
                }
                XCTAssertTrue(position.node === node, "position(at: \(location)) names another node", file: file, line: line)
                if span.isExact {
                    XCTAssertEqual(position.offset, span.offset + index, file: file, line: line)
                    XCTAssertEqual(map.location(of: position), location, "round trip at \(location)", file: file, line: line)
                } else {
                    XCTAssertEqual(position.offset, span.offset, file: file, line: line)
                    XCTAssertEqual(map.location(of: position), span.location, "unit round trip at \(location)", file: file, line: line)
                }
            }
        }
    }
}

/// A rich-content factory that records its calls and returns plain attachments.
final class BuilderRecordingRich: RichContentFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private let rendersTables: Bool
    init(rendersTables: Bool = false) { self.rendersTables = rendersTables }

    var calls: [String] { lock.withLock { log } }
    private func record(_ call: String) { lock.withLock { log.append(call) } }
    private func attachment() -> NSAttributedString { NSAttributedString(attachment: NSTextAttachment()) }

    func image(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        record("image:\(element.name)")
        if let source = element.attribute("src") ?? element.attribute("data"), context.resolve(source) == nil { return nil }
        return attachment()
    }
    func svg(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        record("svg"); return attachment()
    }
    func table(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        record("table")
        guard rendersTables else { return nil }
        let cells = context.document.nodes[element.order...element.subtreeEnd].filter { $0.isHTML("td") || $0.isHTML("th") }
        let result = NSMutableAttributedString()
        for (index, cell) in cells.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: " | ")) }
            result.append(context.renderContent(cell, context.style(cell, style)))
        }
        return result
    }
    func math(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        record("math"); return attachment()
    }
    func horizontalRule(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString {
        record("hr"); return attachment()
    }
}
