import EPUBCore
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
    /// element's start (the section's end when nothing follows). By the id's code units, as a
    /// fragment names it (`EPUBElementID`).
    let anchors: [EPUBElementID: Int]
    /// Footnote and endnote content for showing a note in place, under every `id` that names the
    /// note: its own and those of its leading descendants and, for a footnote hidden from the
    /// flow and the notes inside one, those of every other element inside it, apart from the
    /// ones inside a note nested in it (`SectionBuildState.captureNote` has the rule, its
    /// exception for a table part typed as a footnote, and where the leading descendants of a
    /// note in the flow end). An empty id names nothing, and a note that shows nothing is not
    /// here, so that a reference to it navigates.
    let notes: [EPUBElementID: NSAttributedString]
    /// `<head><title>`, whitespace-normalized; nil when absent or empty.
    let title: String?
    /// What the build withheld or simplified, and what laying the text out has found since.
    var report: SectionReport {
        var report = builtReport
        report.textNotLaidOut = layout.hasUnplacedText
        return report
    }
    private let builtReport: SectionReport
    /// What the layouts of `string` find (`.readerSectionLayout`).
    let layout: SectionLayoutRecord

    init(spineIndex: Int, href: String, document: ContentDocument, string: NSAttributedString, map: TextMap,
         anchors: [EPUBElementID: Int], notes: [EPUBElementID: NSAttributedString], title: String?, report: SectionReport,
         layout: SectionLayoutRecord = SectionLayoutRecord()) {
        self.spineIndex = spineIndex; self.href = href; self.document = document; self.string = string
        self.map = map; self.anchors = anchors; self.notes = notes; self.title = title
        builtReport = report; self.layout = layout
    }
}

/// What the layouts of a section's text find that its build could not know: text TextKit could
/// set on no line, which the reader's text container stopped laying out
/// (`ReaderTextContainer.askLimit`). The builder covers the section's text, its notes and its
/// table cells with the record (`.readerSectionLayout`), so that a layout of any slice of them,
/// in any view or in the box plan, reaches it.
///
/// A record is equal only to itself. CoreFoundation shares attribute dictionaries that compare
/// equal between strings, so records that compared equal would let a section's text carry
/// another section's record: of two builds of one section, the second's text carried the first's (#288).
final class SectionLayoutRecord: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var unplaced = false
    private var observer: (@MainActor @Sendable () -> Void)?

    var hasUnplacedText: Bool { lock.withLock { unplaced } }

    /// Calls `body` on the main actor once text is found that could not be laid out, or soon
    /// after this when some already was.
    func observe(_ body: @escaping @MainActor @Sendable () -> Void) {
        let found = lock.withLock { observer = body; return unplaced }
        if found { Task { @MainActor in body() } }
    }

    /// Called by a layout, on whatever thread it runs, inside TextKit's layout: the observer is
    /// told later, on the main actor.
    func recordUnplacedText() {
        let observer = lock.withLock { () -> (@MainActor @Sendable () -> Void)? in
            guard !unplaced else { return nil }
            unplaced = true
            return self.observer
        }
        if let observer { Task { @MainActor in observer() } }
    }
}

/// What a section withheld or could not render faithfully. Aggregated into `.disclosure` text.
struct SectionReport: Equatable, Sendable {
    /// `<script>` elements and script resources, never run.
    var scriptsRefused = 0
    /// Remote (non-archive) images, stylesheets, fonts and media, never fetched.
    var remoteResourcesRefused = 0
    /// Elements shown only as their fallback content or not at all, by local name
    /// (`video`, `audio`, `iframe`, `object`, `embed`, `canvas`, `form`, an unsupported `svg`…).
    /// `table` counts the tables with cells their grid has no slot for, which follow the table.
    var unsupportedElements: [String: Int] = [:]
    /// Images or other resources that were missing from the archive or could not be decoded.
    var unreadableResources = 0
    /// MathML expressions shown as their `alttext` because they used unsupported elements.
    var mathFallbacks = 0
    /// MathML expressions with an unavailable glyph image shown as alternative text, or
    /// elementary math (`mstack`, `mlongdiv`) set as a table by the reader's retained policy.
    var mathApproximations = 0
    /// MathML expressions that no row breaking keeps at a readable size in a narrow column
    /// (`MathFormula.narrowColumn`): they shrink to the line rather than lose content.
    var mathReductions = 0
    /// The section's markup was refused (entity declarations) or unreadable; a notice replaced it.
    var withheld = false
    /// The markup was not well-formed XML and was read with the forgiving HTML parser.
    var recoveredAsHTML = false
    /// HTML tree repair was not qualified against Foliate; CFIs are withheld rather than guessed.
    var cfiUnavailable = false
    /// The section asked for vertical writing, which is rendered horizontally.
    var verticalWritingFlattened = false
    /// A fixed-layout spine item, rendered as reflowable text.
    var fixedLayoutReflowed = false
    /// Floats, positioned callouts or sized inline-blocks rendered as ordinary flow boxes.
    var flowBoxesReflowed = false
    /// Flex or grid containers shown as blocks in reading order: side-by-side, wrapped,
    /// reversed, reordered or explicitly placed items, or nesting past the supported depth.
    var flexGridSimplified = false
    /// CSS rules, declarations or selectors dropped by parser or sibling-search bounds.
    var stylesTruncated = false
    /// Content a `::before` or `::after` asks for that is not shown: an image or another item
    /// the reader does not generate (`ComputedStyle.ContentItem.unsupported`), that of a table
    /// laid out as a grid or of its rows, or characters past the section's bound.
    var generatedContentOmitted = false
    /// Text that TextKit could set on no line at the size it was laid out at, and that is not
    /// shown (`SectionLayoutRecord`). Found by laying the section out, never by building it.
    var textNotLaidOut = false

    mutating func formUnion(_ other: SectionReport) {
        scriptsRefused += other.scriptsRefused
        remoteResourcesRefused += other.remoteResourcesRefused
        unsupportedElements.merge(other.unsupportedElements, uniquingKeysWith: +)
        unreadableResources += other.unreadableResources
        mathFallbacks += other.mathFallbacks
        mathApproximations += other.mathApproximations
        mathReductions += other.mathReductions
        withheld = withheld || other.withheld
        recoveredAsHTML = recoveredAsHTML || other.recoveredAsHTML
        cfiUnavailable = cfiUnavailable || other.cfiUnavailable
        verticalWritingFlattened = verticalWritingFlattened || other.verticalWritingFlattened
        fixedLayoutReflowed = fixedLayoutReflowed || other.fixedLayoutReflowed
        stylesTruncated = stylesTruncated || other.stylesTruncated
        flowBoxesReflowed = flowBoxesReflowed || other.flowBoxesReflowed
        flexGridSimplified = flexGridSimplified || other.flexGridSimplified
        generatedContentOmitted = generatedContentOmitted || other.generatedContentOmitted
        textNotLaidOut = textNotLaidOut || other.textNotLaidOut
    }
}

/// Maps rendered UTF-16 locations to DOM positions and back.
///
/// Each span covers rendered characters that come from one source node. In an exact span
/// (`isExact`) rendered and source offsets advance together. Otherwise (a collapsed whitespace
/// run, a transformed run, or an element rendered as a unit such as an image, table or formula)
/// every rendered character maps to the span's source start, and every source position in
/// `offset..<offset + sourceLength` maps to the span's first rendered character. Generated text
/// (list markers, `::before` and `::after` content with `q` marks, bidi isolates, separators)
/// has no span. Spans are sorted by `location` and,
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
        /// Authored copy text when typography substitutes characters. Exact spans slice this
        /// by their rendered UTF-16 offsets; a length-changing grapheme is copied as one unit.
        var authoredText: String?
        /// An element rendered as a whole (an image, table, formula or SVG).
        var isUnit: Bool { !isExact && sourceLength == 0 }
        init(location: Int, length: Int, node: Int, offset: Int, sourceLength: Int, isExact: Bool, authoredText: String? = nil) {
            self.location = location; self.length = length; self.node = node
            self.offset = offset; self.sourceLength = sourceLength; self.isExact = isExact
            self.authoredText = authoredText
        }
    }
    private(set) var spans: [Span] = []
    /// The rendered string's length.
    var length = 0
    /// Paragraph separators introduced only to lay out inline flow boxes. Copy replaces them
    /// with the collapsed authored space, if any, rather than inventing a block break.
    private(set) var layoutSeparators: [Int: String] = [:]

    init(spans: [Span] = [], length: Int = 0) { self.spans = spans; self.length = length }

    mutating func layoutSeparator(at location: Int, copyText: String) { layoutSeparators[location] = copyText }

    /// Appends a span, merging it into the previous one when both are exact and contiguous.
    mutating func append(_ span: Span) {
        guard span.length > 0 else { return }
        if var last = spans.last, last.isExact, span.isExact, last.authoredText == nil, span.authoredText == nil, last.node == span.node,
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
        if low == spans.count { return end(of: spans[spans.count - 1], in: document) }
        let span = spans[low]
        let node = document.nodes[span.node]
        if location < span.location || !span.isExact { return DOMPosition(node, span.offset) }
        return DOMPosition(node, span.offset + (location - span.location))
    }

    /// The DOM position just after a span's source: after the whole subtree of an element
    /// rendered as a unit, so a range ending there includes it, even when nothing follows it in
    /// the document (`ContentDocument.end`).
    private func end(of span: Span, in document: ContentDocument) -> DOMPosition {
        let node = document.nodes[span.node]
        return span.isUnit ? document.position(after: node) : DOMPosition(node, span.offset + span.sourceLength)
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
        // A unit (a range ending with an image, table or formula includes it), a collapsed
        // run, or generated text after the span (`last` past it): end after the span.
        guard span.isExact, last < span.location + span.length else { return end(of: span, in: document) }
        return DOMPosition(document.nodes[span.node], span.offset + (last - span.location) + 1)
    }

    /// The DOM range of a rendered range: from `position(at:)` its start to `endPosition(at:)`
    /// its end, and a position (`position(at:)` twice) when it is empty.
    ///
    /// A range holding only generated text (a list marker, a line break, a quotation mark) has
    /// none of the document's characters: its start comes forward to the next mapped character
    /// and its end back to the last one before it, so the two cross. They are taken the other
    /// way round, from the end of the text before it to the start of the text after it: a range
    /// that runs forwards over the place in the document where that text is generated.
    func domRange(_ range: Range<Int>, in document: ContentDocument) -> (start: DOMPosition, end: DOMPosition)? {
        guard let start = position(at: range.lowerBound, in: document) else { return nil }
        guard !range.isEmpty, let end = endPosition(at: range.upperBound, in: document) else { return (start, start) }
        return end < start ? (end, start) : (start, end)
    }

    /// The rendered location of a DOM position: exact inside an exact span, otherwise the first
    /// rendered character at or after it (the string's end when nothing follows). A position
    /// inside an element rendered as a unit (a table, formula or SVG) is that unit: its start, or
    /// its end when `isEnd` (the end of a range). Just after an element (the document's end,
    /// `DOMPosition`) is after the element's unit, when it is one.
    func location(of position: DOMPosition, isEnd: Bool = false) -> Int {
        let order = position.node.order
        let offset = position.node.isText ? position.offset : min(max(position.offset, 0), 1)
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
    /// The `SectionLayoutRecord` of the section, over all of its text.
    static let readerSectionLayout = NSAttributedString.Key("org.epublib.sectionLayout")
}

extension SectionText {
    /// Whether a rendered range takes in text that `visibility: hidden` hides in the flow
    /// (`.readerHidden`): in the section's string, or in the table cells its ends are in.
    func holdsHiddenText(_ range: ReaderTextRange) -> Bool {
        func hidden(_ text: NSAttributedString, _ lower: Int, _ upper: Int) -> Bool {
            let lower = max(0, lower), upper = min(text.length, upper)
            guard upper > lower else { return false }
            var found = false
            text.enumerateAttribute(.readerHidden, in: NSRange(location: lower, length: upper - lower)) { value, _, stop in
                if value != nil { found = true; stop.pointee = true }
            }
            return found
        }
        let first = range.start.tableCell.flatMap { endpoint in tableCell(range.start).map { (endpoint, $0) } }
        let last = range.end.tableCell.flatMap { endpoint in tableCell(range.end).map { (endpoint, $0) } }
        if let first, let last, first.0.table == last.0.table, first.0.cell == last.0.cell {
            return hidden(first.1.content, first.0.offset, last.0.offset)
        }
        if let first, hidden(first.1.content, first.0.offset, first.1.content.length) { return true }
        if let last, hidden(last.1.content, 0, last.0.offset) { return true }
        return hidden(string, range.start.offset, range.end.offset)
    }

    /// The text of a rendered range from the book's own characters: mapped text (attachments as
    /// their text equivalents) and authored line/block breaks, but no layout-only separators.
    func mappedText(in range: Range<Int>) -> String { map.mappedText(in: range, from: string) }
}

extension TextMap {
    /// Also used for a detached table cell's passage: its map retains the same authored
    /// substitutions and layout separators as the section map.
    func mappedText(in range: Range<Int>, from string: NSAttributedString, generatedBreaks: String = "\n") -> String {
        let characters = string.string as NSString
        let lower = max(0, min(string.length, range.lowerBound))
        let upper = max(lower, min(string.length, range.upperBound))
        let range = lower..<upper
        var text = ""
        func generated(_ gap: Range<Int>) {
            guard !gap.isEmpty else { return }
            var location = gap.lowerBound
            for scalar in characters.substring(with: NSRange(location: gap.lowerBound, length: gap.count)).unicodeScalars {
                if let replacement = layoutSeparators[location] { text += replacement }
                else if scalar == "\n" || scalar == "\u{2028}" || scalar == "\u{2029}" { text += generatedBreaks }
                location += scalar.utf16.count
            }
        }
        func shown(_ part: Range<Int>) {
            var low = 0, high = spans.count
            while low < high { // first span ending after this visible part's start
                let mid = (low + high) / 2
                if spans[mid].location + spans[mid].length <= part.lowerBound { low = mid + 1 } else { high = mid }
            }
            var cursor = part.lowerBound
            while low < spans.count, spans[low].location < part.upperBound, cursor < part.upperBound {
                let span = spans[low]
                if span.location > cursor { generated(cursor..<span.location); cursor = span.location }
                let end = min(part.upperBound, span.location + span.length)
                if end > cursor {
                    if let authored = span.authoredText {
                        if span.isExact {
                            text += (authored as NSString).substring(with: NSRange(location: cursor - span.location, length: end - cursor))
                        } else { text += authored }
                    } else { text += string.readerCopyPlainText(in: NSRange(location: cursor, length: end - cursor)) }
                    cursor = end
                }
                low += 1
            }
            generated(cursor..<part.upperBound)
        }
        // Visibility belongs to the rendered source range, before any authored spelling is
        // substituted. Enumerate it across spans so one hidden run split by inline markup or
        // a ß expansion still contributes the same separator as the full attributed string.
        string.enumerateAttribute(.readerHidden, in: NSRange(location: range.lowerBound, length: range.count)) { hidden, part, _ in
            if hidden != nil { text += string.readerHiddenText(part) }
            else { shown(part.location..<NSMaxRange(part)) }
        }
        return text
    }
}
