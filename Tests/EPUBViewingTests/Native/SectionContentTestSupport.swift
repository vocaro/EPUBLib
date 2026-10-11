import CoreGraphics
import CoreText
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

/// Helpers for the `SectionContent…CoverageTests`: sections built through the whole pipeline
/// (book stylesheets, the native rich-content factory), and text-map checks beyond
/// `BuilderHarness.assertMapRoundTrips`.
enum SectionContentSupport {
    /// A section built as the reader builds it: the document's own `<style>` through the CSS
    /// engine, and the native rich content unless another factory is given.
    static func styled(_ body: String, css: String = "", head: String = "", files: [String: Data] = [:],
                       typography: NativeTypography = NativeTypography(fontSize: 16),
                       rich: any RichContentFactory = NativeRichContent()) throws -> SectionText {
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body, head: head, css: css),
                                                           files: files)
        return SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0, typography: typography,
                                                        fonts: FontRegistry(publication: publication), rich: rich))
    }

    /// A section from a whole content document (its own root element, namespaces and doctype).
    static func raw(_ xhtml: String, typography: NativeTypography = NativeTypography(fontSize: 16),
                    rich: any RichContentFactory = PlaceholderRichContent()) throws -> SectionText {
        let publication = try StyleTestSupport.publication(section: xhtml)
        return SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0, typography: typography,
                                                        fonts: FontRegistry(publication: publication), rich: rich))
    }

    static func link(_ substring: String, in text: SectionText) -> ReaderLink? {
        (BuilderHarness.attribute(.link, of: substring, in: text) as? URL).flatMap(ReaderLink.init(url:))
    }

    static func font(_ substring: String, in text: SectionText) -> PlatformFont? {
        BuilderHarness.attribute(.font, of: substring, in: text) as? PlatformFont
    }

    static func traits(_ substring: String, in text: SectionText) -> CTFontSymbolicTraits {
        font(substring, in: text).map { CTFontGetSymbolicTraits($0 as CTFont) } ?? []
    }

    static func language(_ substring: String, in text: SectionText) -> String? {
        BuilderHarness.attribute(InlineStyling.languageKey, of: substring, in: text) as? String
    }

    /// The paragraphs of a section's string, as TextKit sees them.
    static func paragraphs(_ text: SectionText) -> [String] { text.string.string.components(separatedBy: "\n") }

    /// The rendered text the map attributes to one source text node, in rendered order.
    static func rendered(of node: ContentNode, in text: SectionText) -> String {
        let characters = text.string.string as NSString
        return text.map.spans.filter { $0.node == node.order }
            .map { characters.substring(with: NSRange(location: $0.location, length: $0.length)) }.joined()
    }

    static func textNode(_ content: String, in text: SectionText) -> ContentNode? {
        text.document.nodes.first { $0.isText && $0.text == content }
    }

    /// Whether a location is generated text: no span covers it.
    static func isGenerated(_ location: Int, in text: SectionText) -> Bool {
        !text.map.spans.contains { $0.location <= location && location < $0.location + $0.length }
    }

    static func escape(_ string: String) -> String {
        var result = ""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x0A: result += "\\n"
            case 0x09: result += "\\t"
            case 0x0D: result += "\\r"
            case 0x20...0x7E: result.unicodeScalars.append(scalar)
            default: result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            }
        }
        return result
    }

    // MARK: Text-map contracts

    /// `BuilderHarness.assertMapRoundTrips` as a list of violations, so a property test can look
    /// for its smallest failing document. Exact spans must render their source characters
    /// (`sameCharacters`: unless a transform keeps the length).
    static func mapViolations(_ text: SectionText, sameCharacters: Bool = true) -> [String] {
        var violations: [String] = []
        let map = text.map, document = text.document
        if map.length != text.string.length { violations.append("map length \(map.length) for \(text.string.length) characters") }
        let rendered = Array(text.string.string.utf16)
        var previousEnd = 0, previousSource = (node: -1, offset: -1)
        for span in map.spans {
            guard span.location >= previousEnd, span.location + span.length <= rendered.count, span.length > 0 else {
                violations.append("span at \(span.location)+\(span.length) overlaps or leaves the text"); break
            }
            if span.node < previousSource.node || (span.node == previousSource.node && span.offset < previousSource.offset) {
                violations.append("span at \(span.location) is out of source order")
            }
            previousEnd = span.location + span.length
            previousSource = (span.node, span.offset + span.sourceLength)
            let node = document.nodes[span.node]
            if span.isExact {
                let source = Array(node.text.utf16)
                guard node.isText, span.length == span.sourceLength, span.offset + span.length <= source.count else {
                    violations.append("exact span at \(span.location) does not fit its node"); continue
                }
                for index in 0..<span.length where sameCharacters {
                    let character = rendered[span.location + index], original = source[span.offset + index]
                    let newline = [0x0A, 0x0D, 0x2029, 0x85].contains(original) && character == 0x2028
                    if character != original && !newline {
                        violations.append("exact span at \(span.location) renders other characters"); break
                    }
                }
            } else if node.isText, span.offset + span.sourceLength > node.utf16Length {
                violations.append("span at \(span.location) covers source past its node")
            }
            for index in 0..<span.length {
                let location = span.location + index
                guard let position = map.position(at: location, in: document), position.node === node else {
                    violations.append("position(at: \(location)) names another node"); break
                }
                let expected: (offset: Int, location: Int) = span.isExact ? (span.offset + index, location) : (span.offset, span.location)
                if position.offset != expected.offset || map.location(of: position) != expected.location {
                    violations.append("location \(location) does not round-trip"); break
                }
            }
        }
        return violations
    }

    /// A rendered range becomes a DOM range (`position(at:)` to `endPosition(at:)`) and back
    /// (`location(of:)`, `location(of:isEnd:)`). Checked for every pair of locations when the
    /// text is short, else for pairs around every span boundary. For a range holding at least
    /// one mapped character:
    /// - the DOM range is never inverted;
    /// - it comes back as a range that contains it;
    /// - an end that lies in an exact span comes back with no other mapped character added (generated
    ///   ones may be: an isolate's closing character can sit between two spans of one text node).
    static func rangeViolations(_ text: SectionText, limit: Int = 5) -> [String] {
        let map = text.map, document = text.document
        var exact = [Bool](repeating: false, count: map.length + 1)
        var mapped = [Bool](repeating: false, count: map.length + 1)
        var boundaries = Set<Int>()
        for span in map.spans {
            for index in span.location..<(span.location + span.length) { mapped[index] = true; exact[index] = span.isExact }
            for offset in [-1, 0, 1] {
                boundaries.insert(span.location + offset); boundaries.insert(span.location + span.length + offset)
            }
        }
        let all = map.length <= 80 ? Array(0...map.length) : boundaries.filter { $0 >= 0 && $0 <= map.length }.sorted()
        var violations: [String] = []
        for start in all where start < map.length {
            for end in all where end > start {
                guard violations.count < limit else { return violations }
                guard mapped[start..<end].contains(true) else { continue }
                guard let first = map.position(at: start, in: document), let last = map.endPosition(at: end, in: document) else {
                    violations.append("no position for \(start)..<\(end)"); continue
                }
                if last < first { violations.append("\(start)..<\(end) is an inverted DOM range"); continue }
                let lower = map.location(of: first), upper = map.location(of: last, isEnd: true)
                if (mapped[start] && lower > start) || (mapped[end - 1] && upper < end) || lower > upper {
                    violations.append("\(start)..<\(end) came back as \(lower)..<\(upper), which does not contain it")
                } else if (mapped[start] && exact[start] && lower < start && mapped[lower..<start].contains(true))
                            || (mapped[end - 1] && exact[end - 1] && upper > end && mapped[end..<upper].contains(true)) {
                    violations.append("\(start)..<\(end) came back as \(lower)..<\(upper), with other text added")
                }
            }
        }
        return violations
    }

    /// Every DOM position (each offset of each text node, each element start) has a rendered
    /// location inside the text, and locations never decrease in document order.
    static func locationViolations(_ text: SectionText) -> [String] {
        var previous = 0, previousEnd = 0
        for node in text.document.nodes {
            for offset in 0...(node.isText ? node.utf16Length : 0) {
                let position = DOMPosition(node, offset)
                let location = text.map.location(of: position), end = text.map.location(of: position, isEnd: true)
                guard location >= previous, location <= text.string.length, end >= previousEnd, end <= text.string.length else {
                    return ["node \(node.order) (\(node.isText ? escape(node.text) : node.name)) offset \(offset): location \(location) "
                        + "(as an end \(end)) after \(previous) (as an end \(previousEnd))"]
                }
                previous = location; previousEnd = end
            }
        }
        return []
    }

    /// The string holds exactly the builder's paragraphs: no stray paragraph separator, no
    /// trailing break, one paragraph style over each paragraph, and anchors inside the text.
    static func stringViolations(_ text: SectionText) -> [String] {
        var violations: [String] = []
        let string = text.string.string as NSString
        if string.length > 0, string.character(at: string.length - 1) == 0x0A { violations.append("trailing paragraph break") }
        for index in 0..<string.length where [0x0D, 0x2029, 0x85, 0x0C].contains(string.character(at: index)) {
            violations.append("stray separator U+\(String(string.character(at: index), radix: 16)) at \(index)"); break
        }
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            var effective = NSRange()
            _ = text.string.attribute(.paragraphStyle, at: location, longestEffectiveRange: &effective, in: paragraph)
            if effective != paragraph, violations.count < 3 {
                violations.append("paragraph at \(paragraph.location)+\(paragraph.length) has more than one paragraph style")
            }
            location = NSMaxRange(paragraph)
        }
        for (id, anchor) in text.anchors where anchor < 0 || anchor > string.length { violations.append("anchor \(id) at \(anchor)") }
        return violations
    }

    static func assertTextMapContracts(_ text: SectionText, sameCharacters: Bool = true,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let violations = mapViolations(text, sameCharacters: sameCharacters) + rangeViolations(text) + locationViolations(text)
            + stringViolations(text)
        XCTAssertEqual(violations, [], "in \(escape(text.string.string))", file: file, line: line)
    }

    // MARK: Drawing

    /// The greatest alpha an image draws at `size`; nil when there is no image to draw.
    static func maximumAlpha(of image: PlatformImage?, size: CGSize) -> UInt8? {
        let width = Int(size.width.rounded(.up)), height = Int(size.height.rounded(.up))
        guard let image, width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        #if os(macOS)
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let bitmap = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        #else
        guard let bitmap = image.cgImage else { return nil }
        #endif
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var maximum: UInt8 = 0
        for index in stride(from: 3, to: width * height * 4, by: 4) { maximum = max(maximum, pixels[index]) }
        return maximum
    }
}

/// A deterministic generator (the property tests' linear congruential one) for random documents.
struct SectionContentRandom {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
    mutating func pick<T>(_ values: [T]) -> T { values[next(values.count)] }
    mutating func chance(_ oneIn: Int) -> Bool { next(oneIn) == 0 }
}

/// CSS Text 3 section 4.1 for the simplest inline formatting contexts, written independently of
/// the builder: blocks of text, atoms and forced breaks under `white-space: normal`.
struct SectionContentWhitespaceModel {
    enum Token: Equatable {
        case text(String)
        /// An inline replaced element, shown as this text.
        case atom(String)
        case lineBreak
        /// The start or end of a block box.
        case boundary
    }

    private(set) var tokens: [Token] = []
    mutating func append(_ token: Token) { tokens.append(token) }

    /// The paragraphs the tokens make, joined as the builder joins them.
    var rendered: String {
        var paragraphs: [String] = []
        var line = "", lines: [String] = [], pendingSpace = false, hasContent = false, breaks = 0
        func isCollapsible(_ scalar: Unicode.Scalar) -> Bool { [" ", "\t", "\n", "\r"].contains(scalar) }
        func endBlock() {
            defer { line = ""; lines = []; pendingSpace = false; hasContent = false; breaks = 0 }
            guard hasContent || breaks > 0 else { return }
            // A block's last line ends at its end, and a forced break that ends a block makes no line.
            if !line.isEmpty || lines.isEmpty { lines.append(line) }
            paragraphs.append(lines.joined(separator: "\u{2028}"))
        }
        for token in tokens {
            switch token {
            case .boundary: endBlock()
            case .lineBreak: breaks += 1; lines.append(line); line = ""; pendingSpace = false
            case .atom(let text):
                if pendingSpace { line += " " }
                pendingSpace = false; line += text; hasContent = true
            case .text(let text):
                for scalar in text.unicodeScalars {
                    if isCollapsible(scalar) {
                        // A collapsible space at a line's start is removed; a run keeps one space,
                        // which is removed again if it ends the line.
                        if !line.isEmpty { pendingSpace = true }
                    } else {
                        if pendingSpace { line += " " }
                        pendingSpace = false; line.unicodeScalars.append(scalar); hasContent = true
                    }
                }
            }
        }
        endBlock()
        // The section's last paragraph cannot be empty.
        while paragraphs.last == "" { paragraphs.removeLast() }
        return paragraphs.joined(separator: "\n")
    }
}
