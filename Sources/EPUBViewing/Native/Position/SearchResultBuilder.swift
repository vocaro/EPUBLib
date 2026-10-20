import EPUBCore
import Foundation

/// Turns one built section's matches into the public result model: where each rendered
/// occurrence is, what section it belongs to and the text around it. Matches in content that
/// renders nothing, or that takes in text `visibility: hidden` hides, are left out, exactly as
/// they are left undrawn, so result `n` of a section is its `n`th drawn search highlight.
enum SearchResultBuilder {
    /// UTF-16 units of rendered text read on each side of an occurrence, before trimming to
    /// whole words: about a line, enough to tell neighbouring occurrences apart.
    static let contextBefore = 48
    static let contextAfter = 96

    /// What every result of one section shares.
    struct Section: Sendable {
        var text: SectionText
        var publicationID: String
        var engineID: String
        var bookmarkFormat: String
        var spine: SpineCFIs
        var progress: NativeProgress
    }

    struct Batch: Sendable {
        var results: [EPUBSearchResult] = []
        /// `ranges[i]` is where `results[i]` is drawn and shown.
        var ranges: [ReaderTextRange] = []
        /// The section has rendered occurrences beyond `limit`.
        var hasMore = false
    }

    /// A match's rendered range. The match may come from a fresh parse of the section that is
    /// already gone (nodes keep only weak parents), so it is read in the built section's own
    /// document, node for node: both parses read the same bytes.
    static func renderedRange(of match: TextSearch.Match, in text: SectionText) -> ReaderTextRange {
        let match = rebased(match, in: text.document)
        return ReaderTextRange(start: text.renderedPosition(match.start), end: text.renderedPosition(match.end, isEnd: true))
    }

    /// Whether a match's range holds rendered characters. Content that renders nothing maps to
    /// an empty range, or to a reversed one when rendered text surrounds it: its start falls on
    /// the next rendered character and its end after the previous one.
    static func isRendered(_ range: ReaderTextRange) -> Bool { range.start < range.end }

    /// Whether a match's range is a result: it holds rendered characters, and none that
    /// `visibility: hidden` hides in the flow (`SectionText.holdsHiddenText`), which a browser
    /// does not find either.
    static func isListed(_ range: ReaderTextRange, in text: SectionText) -> Bool {
        isRendered(range) && !text.holdsHiddenText(range)
    }

    private static func rebased(_ match: TextSearch.Match, in document: ContentDocument) -> TextSearch.Match {
        func rebased(_ position: DOMPosition) -> DOMPosition {
            guard document.nodes.indices.contains(position.node.order) else { return position }
            return DOMPosition(document.nodes[position.node.order], position.offset)
        }
        return TextSearch.Match(start: rebased(match.start), end: rebased(match.end))
    }

    /// The section's rendered occurrences in document order, numbered from `firstIndex`, at most
    /// `limit` of them.
    static func results(for matches: [TextSearch.Match], in section: Section, firstIndex: Int, limit: Int) -> Batch {
        let text = section.text, document = text.document
        let marks = section.progress.marks(inSection: text.spineIndex, anchors: text.anchors)
        let length = text.string.length
        let characters = text.string.string as NSString
        let indices = EPUBCFI.ChildIndexCache()
        var batch = Batch()
        for found in matches {
            let match = rebased(found, in: document)
            let range = ReaderTextRange(start: text.renderedPosition(match.start), end: text.renderedPosition(match.end, isEnd: true))
            guard isListed(range, in: text) else { continue }
            guard batch.results.count < limit else { batch.hasMore = true; break }
            let matched = listed(TextSearch.text(of: match, in: document).unicodeScalars).trimmingCharacters(in: .whitespaces)
            let cfi = section.spine.cfi(spineIndex: text.spineIndex, start: match.start, end: match.end, in: document, indices: indices)
            let title = marks.title(at: range.start.offset)
            let page = marks.page(at: range.start.offset)
            let location = EPUBLocation(
                publicationID: section.publicationID, href: text.href,
                progression: section.progress.progression(section: text.spineIndex,
                    fraction: length > 0 ? Double(range.start.offset) / Double(length) : 0),
                title: title, quote: matched,
                bookmark: cfi.isEmpty ? nil : EPUBEngineBookmark(engineID: section.engineID, format: section.bookmarkFormat, value: cfi),
                page: page, pages: page.map { [$0] })
            let context = context(of: range, in: text, characters: characters)
            batch.results.append(EPUBSearchResult(
                index: firstIndex + batch.results.count, location: location, spineIndex: text.spineIndex,
                sectionTitle: title ?? text.title, matchedText: matched,
                contextBefore: context.before, contextAfter: context.after))
            batch.ranges.append(range)
        }
        return batch
    }

    /// The rendered text on each side of a range: the reader's own characters with attachments
    /// as their text equivalents, never generated list markers. An occurrence inside a table
    /// cell reads that cell.
    /// `characters` is the section's rendered string, passed in when reading many ranges.
    static func context(of range: ReaderTextRange, in text: SectionText,
                        characters: NSString? = nil) -> (before: String, after: String) {
        let characters = characters ?? text.string.string as NSString
        func read(_ position: ReaderTextPosition, before: Bool) -> String {
            if let endpoint = position.tableCell, let cell = text.tableCell(position) {
                let window = window(at: endpoint.offset, before: before, in: cell.content.string as NSString)
                return trimmed(cell.content.readerPlainText(in: window.range), before: before, isCut: window.isCut)
            }
            let window = window(at: position.offset, before: before, in: characters)
            return trimmed(text.mappedText(in: window.range.location..<NSMaxRange(window.range)), before: before, isCut: window.isCut)
        }
        return (read(range.start, before: true), read(range.end, before: false))
    }

    /// Up to a context's length of `string` ending (or starting) at `offset`, never splitting a
    /// composed character. `isCut` when more text lies beyond it.
    private static func window(at offset: Int, before: Bool, in string: NSString) -> (range: NSRange, isCut: Bool) {
        let offset = min(max(offset, 0), string.length)
        var lower = before ? max(0, offset - contextBefore) : offset
        var upper = before ? offset : min(string.length, offset + contextAfter)
        if before, lower > 0, lower < string.length { lower = NSMaxRange(string.rangeOfComposedCharacterSequence(at: lower - 1)) }
        if !before, upper > 0, upper < string.length { upper = string.rangeOfComposedCharacterSequence(at: upper).location }
        lower = min(lower, offset); upper = max(upper, offset)
        return (NSRange(location: lower, length: upper - lower), before ? lower > 0 : upper < string.length)
    }

    /// Text as a result lists it: white space runs as single spaces, a leading or trailing run
    /// included, and invisible layout controls dropped (soft hyphens, zero-width spaces, word
    /// joiners and the bidi marks and isolates the renderer adds). Joiners that shape text, as
    /// in emoji sequences and Persian, stay.
    static func listed(_ raw: some Sequence<Unicode.Scalar>) -> String {
        var text = ""
        var pendingSpace = false
        for scalar in raw {
            switch scalar.value {
            case 0xAD, 0x200B, 0x200E, 0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF: continue
            default: break
            }
            if scalar.properties.isWhitespace {
                pendingSpace = true
            } else {
                if pendingSpace { text.unicodeScalars.append(" ") }
                pendingSpace = false
                text.unicodeScalars.append(scalar)
            }
        }
        if pendingSpace { text.unicodeScalars.append(" ") }
        return text
    }

    /// A context as it is listed: only the occurrence's own paragraph or line, keeping the
    /// space that separates it from the occurrence. A context cut short by the window, rather
    /// than by a line's end, loses the partial word at its far end when it holds more than one.
    static func trimmed(_ raw: String, before: Bool, isCut: Bool) -> String {
        func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}"
        }
        var scalars = Substring(raw).unicodeScalars
        var isCut = isCut
        if before, let last = scalars.lastIndex(where: isLineBreak) {
            scalars = scalars[scalars.index(after: last)...]; isCut = false
        } else if !before, let first = scalars.firstIndex(where: isLineBreak) {
            scalars = scalars[..<first]; isCut = false
        }
        var text = listed(scalars)
        // An attachment's text equivalent (an image's description, a formula) can be far longer
        // than the window it was read through.
        let limit = before ? contextBefore : contextAfter
        if text.count > limit {
            text = String(before ? text.suffix(limit) : text.prefix(limit))
            isCut = true
        }
        if isCut {
            if before, let space = text.firstIndex(of: " "), text[space...].contains(where: { $0 != " " }) {
                text = String(text[text.index(after: space)...])
            } else if !before, let space = text.lastIndex(of: " "), text[..<space].contains(where: { $0 != " " }) {
                text = String(text[..<space])
            }
        }
        // Only the side that meets the occurrence keeps its space.
        if before { while text.first == " " { text.removeFirst() } }
        else { while text.last == " " { text.removeLast() } }
        return text
    }
}
