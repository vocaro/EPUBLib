import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One spine item rendered to attributed text, with everything needed to map rendered
/// locations back to the content document (for CFIs, search and highlights).
///
/// Rendered locations are UTF-16 offsets into `string`. A section's characters depend only on
/// its content document, never on typography: rebuilding for another font size or appearance
/// yields the same string with different attributes, so locations survive a style change.
struct SectionText: @unchecked Sendable {
    let spineIndex: Int
    /// The spine resource's encoded href, as `.navigate(href:)` and locations carry it.
    let href: String
    let document: ContentDocument
    let string: NSAttributedString
    let map: TextMap
    /// Rendered location of each element `id`: the first rendered character at or after the
    /// element's start (the section's end when nothing follows).
    let anchors: [String: Int]
    /// Footnote and endnote content by the note element's `id`, for showing a note in place.
    let notes: [String: NSAttributedString]
    /// `<head><title>`, whitespace-normalized; nil when absent or empty.
    let title: String?
    let report: SectionReport
}

/// What a section withheld or could not render faithfully. Aggregated into `.disclosure` text.
struct SectionReport: Equatable, Sendable {
    /// `<script>` elements and script resources, never run.
    var scriptsRefused = 0
    /// Remote (non-archive) images, stylesheets, fonts and media, never fetched.
    var remoteResourcesRefused = 0
    /// Elements shown only as their fallback content or not at all, by local name
    /// (`video`, `audio`, `iframe`, `object`, `embed`, `canvas`, `form`, an unsupported `svg`…).
    var unsupportedElements: [String: Int] = [:]
    /// Images or other resources that were missing from the archive or could not be decoded.
    var unreadableResources = 0
    /// MathML expressions shown as their `alttext` because they used unsupported elements.
    var mathFallbacks = 0
    /// The section's markup was refused (entity declarations) or unreadable; a notice replaced it.
    var withheld = false
    /// The markup was not well-formed XML and was read with the forgiving HTML parser.
    var recoveredAsHTML = false
    /// The section asked for vertical writing, which is rendered horizontally.
    var verticalWritingFlattened = false
    /// A fixed-layout spine item, rendered as reflowable text.
    var fixedLayoutReflowed = false
    /// CSS rules or declarations dropped by the parser's bounds.
    var stylesTruncated = false

    mutating func formUnion(_ other: SectionReport) {
        scriptsRefused += other.scriptsRefused
        remoteResourcesRefused += other.remoteResourcesRefused
        unsupportedElements.merge(other.unsupportedElements, uniquingKeysWith: +)
        unreadableResources += other.unreadableResources
        mathFallbacks += other.mathFallbacks
        withheld = withheld || other.withheld
        recoveredAsHTML = recoveredAsHTML || other.recoveredAsHTML
        verticalWritingFlattened = verticalWritingFlattened || other.verticalWritingFlattened
        fixedLayoutReflowed = fixedLayoutReflowed || other.fixedLayoutReflowed
        stylesTruncated = stylesTruncated || other.stylesTruncated
    }
}

/// Maps rendered UTF-16 locations to DOM positions and back.
///
/// Each span covers rendered characters that come from one source node. In an exact span
/// (`isExact`) rendered and source offsets advance together. Otherwise (a collapsed whitespace
/// run, a transformed run, or an element rendered as a unit such as an image, table or formula)
/// every rendered character maps to the span's source start, and every source position in
/// `offset..<offset + sourceLength` maps to the span's first rendered character. Generated text
/// (list markers, bidi isolates, separators) has no span. Spans are sorted by `location` and,
/// because rendering preserves document order, by source position too.
struct TextMap: Equatable, Sendable {
    struct Span: Equatable, Sendable {
        var location: Int
        var length: Int
        /// `ContentNode.order` of a text node, or of an element rendered as a unit.
        var node: Int
        /// UTF-16 offset in the text node where the span starts; 0 for an element.
        var offset: Int
        /// UTF-16 length of source covered; 0 for an element.
        var sourceLength: Int
        var isExact: Bool
        /// An element rendered as a whole (an image, table, formula or SVG).
        var isUnit: Bool { !isExact && sourceLength == 0 }
        init(location: Int, length: Int, node: Int, offset: Int, sourceLength: Int, isExact: Bool) {
            self.location = location; self.length = length; self.node = node
            self.offset = offset; self.sourceLength = sourceLength; self.isExact = isExact
        }
    }
    private(set) var spans: [Span] = []
    /// The rendered string's length.
    var length = 0

    init(spans: [Span] = [], length: Int = 0) { self.spans = spans; self.length = length }

    /// Appends a span, merging it into the previous one when both are exact and contiguous.
    mutating func append(_ span: Span) {
        guard span.length > 0 else { return }
        if var last = spans.last, last.isExact, span.isExact, last.node == span.node,
           last.location + last.length == span.location, last.offset + last.sourceLength == span.offset {
            last.length += span.length; last.sourceLength += span.sourceLength
            spans[spans.count - 1] = last
        } else { spans.append(span) }
        length = max(length, span.location + span.length)
    }

    /// The DOM position of the rendered character at `location` (clamped). Generated text maps
    /// to the start of the next mapped character, or the end of the last one.
    func position(at location: Int, in document: ContentDocument) -> DOMPosition? {
        guard !spans.isEmpty else { return nil }
        let location = max(0, min(location, length))
        var low = 0, high = spans.count
        while low < high { // first span ending after location
            let mid = (low + high) / 2
            if spans[mid].location + spans[mid].length <= location { low = mid + 1 } else { high = mid }
        }
        if low == spans.count {
            let last = spans[spans.count - 1]
            return DOMPosition(document.nodes[last.node], last.offset + last.sourceLength)
        }
        let span = spans[low]
        let node = document.nodes[span.node]
        if location < span.location || !span.isExact { return DOMPosition(node, span.offset) }
        return DOMPosition(node, span.offset + (location - span.location))
    }

    private static func node(_ node: ContentNode, isInsideElementAt order: Int) -> Bool {
        var ancestor = node.parent
        while let current = ancestor, current.order >= order {
            if current.order == order { return true }
            ancestor = current.parent
        }
        return false
    }

    /// The DOM position just after the rendered character before `location`: the end of a
    /// range ending there. Unlike `position(at:)`, a range ending before a paragraph break or
    /// other generated text ends in the node it covers, not at the start of the next one.
    func endPosition(at location: Int, in document: ContentDocument) -> DOMPosition? {
        guard location > 0, !spans.isEmpty else { return position(at: location, in: document) }
        let last = min(location, length) - 1
        var low = 0, high = spans.count
        while low < high { // last span starting at or before `last`
            let mid = (low + high) / 2
            if spans[mid].location <= last { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return position(at: location, in: document) }
        let span = spans[low - 1]
        let node = document.nodes[span.node]
        if span.isUnit {
            // After the unit's whole subtree: a range ending with an image, table or formula
            // includes it.
            let next = node.subtreeEnd + 1
            if next < document.nodes.count { return DOMPosition(document.nodes[next], 0) }
            let final = document.nodes[document.nodes.count - 1]
            return DOMPosition(final, final.isText ? final.utf16Length : 0)
        }
        guard last < span.location + span.length else {
            // `last` is generated text after the span: end after the span.
            return DOMPosition(node, span.offset + span.sourceLength)
        }
        if !span.isExact { return DOMPosition(node, span.offset + span.sourceLength) }
        return DOMPosition(node, span.offset + (last - span.location) + 1)
    }

    /// The rendered location of a DOM position: exact inside an exact span, otherwise the first
    /// rendered character at or after it (the string's end when nothing follows). A position
    /// inside an element rendered as a unit (a table, formula or SVG) is that unit: its start, or
    /// its end when `isEnd` (the end of a range).
    func location(of position: DOMPosition, isEnd: Bool = false) -> Int {
        let order = position.node.order
        let offset = position.node.isText ? position.offset : 0
        var low = 0, high = spans.count
        while low < high { // first span whose source ends after the position
            let mid = (low + high) / 2
            let span = spans[mid]
            let endsBefore = span.node < order || (span.node == order && span.offset + max(span.sourceLength, 1) <= offset)
            if endsBefore { low = mid + 1 } else { high = mid }
        }
        if low > 0, spans[low - 1].isUnit, spans[low - 1].node < order,
           Self.node(position.node, isInsideElementAt: spans[low - 1].node) {
            let unit = spans[low - 1]
            return isEnd ? unit.location + unit.length : unit.location
        }
        // The end of a text node's last exact span is just after that span's last character.
        if low > 0, position.node.isText {
            let previous = spans[low - 1]
            if previous.node == order, previous.isExact, previous.offset + previous.sourceLength == offset,
               low == spans.count || spans[low].node != order {
                return previous.location + previous.length
            }
        }
        guard low < spans.count else { return isEnd ? spans.last.map { $0.location + $0.length } ?? length : length }
        let span = spans[low]
        if span.node == order, span.isExact, offset >= span.offset {
            return span.location + min(offset - span.offset, span.length)
        }
        // A range ending before this span's source ends after the previous span, not after
        // the generated text (a paragraph break) between them.
        if isEnd, low > 0, span.node != order || offset < span.offset {
            let previous = spans[low - 1]
            return previous.location + previous.length
        }
        return span.location
    }
}

/// A link's target, carried by the `.link` attribute as a URL in a private scheme so the text
/// views give it ordinary link interaction while the session decides what activation does.
enum ReaderLink: Equatable, Sendable {
    /// An encoded archive-relative reference with optional fragment, as `.navigate(href:)` takes it.
    case `internal`(href: String)
    /// An EPUB `noteref`: show the referenced note in place when its content is known.
    case note(href: String)
    /// Anything outside the archive. Never opened.
    case external(String)

    private static let internalScheme = "epublib-internal:"
    private static let noteScheme = "epublib-note:"
    private static let externalScheme = "epublib-external:"

    var url: URL {
        switch self {
        case .internal(let href): URL(string: Self.internalScheme + href)!
        case .note(let href): URL(string: Self.noteScheme + href)!
        case .external(let target):
            URL(string: Self.externalScheme + (target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))!
        }
    }

    init?(url: URL) {
        let value = url.absoluteString
        if value.hasPrefix(Self.internalScheme) { self = .internal(href: String(value.dropFirst(Self.internalScheme.count))) }
        else if value.hasPrefix(Self.noteScheme) { self = .note(href: String(value.dropFirst(Self.noteScheme.count))) }
        else if value.hasPrefix(Self.externalScheme) {
            self = .external(String(value.dropFirst(Self.externalScheme.count)).removingPercentEncoding ?? "")
        } else { return nil }
    }
}

extension NSAttributedString.Key {
    /// `true` on a paragraph's first character when CSS asks for a page break before it.
    /// Paginated flow starts a new page (and spread column) there.
    static let readerPageBreakBefore = NSAttributedString.Key("org.epublib.pageBreakBefore")
    /// `true` on a paragraph's first character when CSS asks to avoid a break after it (headings).
    static let readerKeepWithNext = NSAttributedString.Key("org.epublib.keepWithNext")
}

extension SectionText {
    /// The text of a rendered range from the book's own characters: mapped text (attachments as
    /// their text equivalents) and the line breaks between blocks, but no other generated text.
    func mappedText(in range: Range<Int>) -> String {
        let characters = string.string as NSString
        let range = max(0, range.lowerBound)..<min(string.length, max(range.lowerBound, range.upperBound))
        var text = ""
        func generated(_ gap: Range<Int>) {
            guard !gap.isEmpty else { return }
            for scalar in characters.substring(with: NSRange(location: gap.lowerBound, length: gap.count)).unicodeScalars
            where scalar == "\n" || scalar == "\u{2028}" || scalar == "\u{2029}" { text += "\n" }
        }
        let spans = map.spans
        var low = 0, high = spans.count
        while low < high { // first span ending after the range's start
            let mid = (low + high) / 2
            if spans[mid].location + spans[mid].length <= range.lowerBound { low = mid + 1 } else { high = mid }
        }
        var cursor = range.lowerBound
        while low < spans.count, spans[low].location < range.upperBound, cursor < range.upperBound {
            let span = spans[low]
            if span.location > cursor { generated(cursor..<span.location); cursor = span.location }
            let end = min(range.upperBound, span.location + span.length)
            if end > cursor {
                text += string.readerPlainText(in: NSRange(location: cursor, length: end - cursor))
                cursor = end
            }
            low += 1
        }
        generated(cursor..<range.upperBound)
        return text
    }
}

