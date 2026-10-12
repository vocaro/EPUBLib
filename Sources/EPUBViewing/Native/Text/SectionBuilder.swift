import EPUBCore
import EPUBReading
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SectionBuildRequest: @unchecked Sendable {
    let publication: EPUBPublication
    let spineIndex: Int
    let typography: NativeTypography
    let fonts: FontRegistry
    let rich: any RichContentFactory
}

/// The computed style of an element given its parent's computed style: the cascade, injected so
/// the builder can be exercised with arbitrary computed values.
typealias SectionStyleFunction = (_ element: ContentNode, _ parent: ComputedStyle) -> ComputedStyle

/// Builds a spine item's attributed text in one walk of its DOM: CSS block boxes become
/// paragraphs (collapsed vertical margins as paragraph spacing, accumulated horizontal boxes as
/// indents), inline boxes become attribute runs, and every rendered character is mapped back to
/// the DOM. `SectionWriter` describes the model and its simplifications.
///
/// Builds are independent and run off the main thread, concurrently across sections. The only
/// objects they share are the font registry and the rich-content factory, both thread-safe.
enum SectionBuilder {
    /// Builds one spine item. Never throws: a section that cannot be read becomes a short notice
    /// paragraph with `report.withheld` set, so the rest of the book stays readable.
    static func build(_ request: SectionBuildRequest) -> SectionText {
        let item = request.publication.spine[request.spineIndex]
        let document: ContentDocument
        do {
            let data = try request.publication.data(for: item.resource)
            document = try ContentDocument.parse(data, path: item.resource.path)
        } catch {
            return withheld(request, reason: error)
        }
        var report = SectionReport()
        let sheets = SectionStyles.load(for: document, publication: request.publication, fonts: request.fonts, report: &report)
        let resolver = StyleResolver(document: document, stylesheets: sheets, typography: request.typography, fonts: request.fonts)
        report.stylesTruncated = report.stylesTruncated || resolver.stylesTruncated
        return build(document: document, request: request, initialStyle: resolver.initialStyle, report: report) {
            resolver.style(for: $0, parent: $1)
        }
    }

    /// The builder proper, over an already parsed document and an injected cascade.
    /// `initialStyle` is what the root element inherits (by default the reader's base size).
    static func build(document: ContentDocument, request: SectionBuildRequest, initialStyle: ComputedStyle? = nil,
                      report: SectionReport = SectionReport(), style: @escaping SectionStyleFunction) -> SectionText {
        let item = request.publication.spine[request.spineIndex]
        let state = SectionBuildState(request: request, document: document, style: style,
                                      initialStyle: initialStyle ?? ComputedStyle(fontSize: request.typography.fontSize))
        state.report.report = report
        state.report.report.recoveredAsHTML = report.recoveredAsHTML || document.recoveredAsHTML
        state.report.report.cfiUnavailable = report.cfiUnavailable || !document.canResolveCFIs
        if item.layout == .prePaginated { state.report.report.fixedLayoutReflowed = true }
        state.report.report.scriptsRefused += document.nodes.reduce(0) { count, node in
            count + (node.isElement && node.name == "script"
                && (node.isHTML || node.namespace == ContentNamespace.svg) ? 1 : 0)
        }
        let output = SectionWriter(state: state, mode: .section).renderSection()
        let title = document.head?.elementChildren.first { $0.isHTML("title") }?.textContent
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SectionText(spineIndex: request.spineIndex, href: item.resource.href, document: document,
                           string: output.string, map: output.map, anchors: output.anchors, notes: state.notes,
                           title: title?.isEmpty == false ? title : nil, report: state.report.report)
    }

    static func withheld(_ request: SectionBuildRequest, reason: Error) -> SectionText {
        let item = request.publication.spine[request.spineIndex]
        let empty = try! ContentDocument.parse(Data("<html xmlns='http://www.w3.org/1999/xhtml'><body/></html>".utf8),
                                               path: item.resource.path)
        var report = SectionReport()
        report.withheld = true
        let notice = NSAttributedString(string: "This section could not be shown.", attributes: [
            .font: request.fonts.font(for: ComputedStyle(fontSize: request.typography.fontSize)),
            .foregroundColor: ReaderPalette.secondaryText(dark: request.typography.isDark),
        ])
        return SectionText(spineIndex: request.spineIndex, href: item.resource.href, document: empty, string: notice,
                           map: TextMap(length: notice.length), anchors: [:], notes: [:], title: nil, report: report)
    }
}

/// Everything one section build shares between the section's writer and the nested writers it
/// starts for table cells and captions (`RichContentContext.renderContent`) and for notes.
final class SectionBuildState {
    let request: SectionBuildRequest
    let document: ContentDocument
    let style: SectionStyleFunction
    let initialStyle: ComputedStyle
    let report = SectionReportBox()
    let styling: InlineStyling
    var notes: [String: NSAttributedString] = [:]
    /// The body's computed style: notes are styled like body text.
    var bodyStyle: ComputedStyle
    /// The publication's first language: a hint for typesetting text whose document declares
    /// none (`InlineLanguage`), never the language of that text.
    let languageHint: String?
    /// A pre-paginated spine item, reflowed: its absolutely positioned boxes stay in the flow.
    let isFixedLayout: Bool
    /// Nesting of `renderContent` and note captures, bounded so hostile nesting cannot recurse deeply.
    private var nesting = 0
    private static let maximumNesting = 8
    /// UTF-16 units all of a section's notes may hold. A note leaves out the notes nested in it
    /// unless it has nothing else to show, so only hostile markup comes near this.
    static let maximumNoteLength = 4 << 20
    private var noteBudget = SectionBuildState.maximumNoteLength
    /// Nodes that notes with nothing of their own may walk a second time, to show the notes
    /// nested in them: a few passes over the document, so hostile nesting cannot walk a subtree
    /// once for every note around it.
    private lazy var wholeNoteBudget = 4 * document.nodes.count
    /// Whether each node (by order) has an endnotes container among its ancestors, computed in one
    /// pass when first needed, so classifying notes is not quadratic in their nesting.
    private lazy var insideEndnotes: [Bool] = {
        var inside = [Bool](repeating: false, count: document.nodes.count)
        for node in document.nodes where node.isElement {
            if let parent = node.parent {
                inside[node.order] = inside[parent.order] || ContentSemantics.isEndnotesContainer(parent)
            }
        }
        return inside
    }()

    init(request: SectionBuildRequest, document: ContentDocument, style: @escaping SectionStyleFunction,
         initialStyle: ComputedStyle) {
        self.request = request; self.document = document; self.style = style; self.initialStyle = initialStyle
        bodyStyle = initialStyle
        styling = InlineStyling(fonts: request.fonts, isDark: request.typography.isDark)
        languageHint = request.publication.metadata.languages.first.flatMap { $0.isEmpty ? nil : $0 }
        isFixedLayout = request.publication.spine[request.spineIndex].layout == .prePaginated
    }

    private(set) lazy var richContext = RichContentContext(
        publication: request.publication, document: document, spineIndex: request.spineIndex,
        typography: request.typography, fonts: request.fonts,
        style: { [unowned self] in self.style($0, $1) },
        renderContent: { [unowned self] in self.renderContent($0, style: $1) },
        renderNodes: { [unowned self] in self.renderNodes($0, style: $1) },
        resolve: { [unowned self] in self.resolveResource($0) },
        report: report)

    /// An element's children rendered into a separate string, as the section renders a block's
    /// content, with no text map. Too deep a nesting renders the plain text instead.
    func renderContent(_ element: ContentNode, style: ComputedStyle) -> NSAttributedString {
        guard nesting < Self.maximumNesting else {
            let text = element.textContent.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return NSAttributedString(string: text, attributes: [
                .font: request.fonts.font(for: style),
                .foregroundColor: ReaderPalette.text(dark: request.typography.isDark),
            ])
        }
        nesting += 1
        defer { nesting -= 1 }
        return SectionWriter(state: self, mode: .detached).renderContent(of: element, style: style)
    }

    /// Consecutive sibling nodes rendered into a separate string the same way, for the anonymous
    /// cell a table puts around content written outside its cells. Too deep a nesting renders
    /// their words, without those of the elements the flow leaves out (`flowStyle`).
    func renderNodes(_ nodes: [ContentNode], style: ComputedStyle) -> NSAttributedString {
        guard let first = nodes.first, let last = nodes.last else { return NSAttributedString() }
        guard nesting < Self.maximumNesting else {
            var words: [Substring] = []
            // The styles of the elements the walk is inside, each with the last node it holds.
            var open: [(end: Int, style: ComputedStyle)] = []
            var order = first.order
            while order <= last.subtreeEnd {
                let node = document.nodes[order]
                while let innermost = open.last, innermost.end < order { open.removeLast() }
                if node.isElement {
                    guard let computed = flowStyle(of: node, in: open.last?.style ?? style) else { order = node.subtreeEnd + 1; continue }
                    open.append((node.subtreeEnd, computed))
                } else if node.isText { words += node.text.split(whereSeparator: \.isWhitespace) }
                order += 1
            }
            return NSAttributedString(string: words.joined(separator: " "), attributes: [
                .font: request.fonts.font(for: style),
                .foregroundColor: ReaderPalette.text(dark: request.typography.isDark),
            ])
        }
        nesting += 1
        defer { nesting -= 1 }
        return SectionWriter(state: self, mode: .detached).renderContent(of: nodes, style: style)
    }

    /// An element's computed style, or nil where the writer leaves the element out of the flow
    /// whatever it holds (`SectionWriter.enter`): one that is never rendered or has no box, and
    /// a footnote, which is kept in the section's notes.
    private func flowStyle(of element: ContentNode, in parent: ComputedStyle) -> ComputedStyle? {
        if element.isHTML, ContentSemantics.neverRendered.contains(element.name) { return nil }
        var computed = style(element, parent)
        if element.isHTML("noscript"), computed.display == .none { computed.display = .block }
        guard noteKind(element) != .footnote, computed.display != .none, computed.display != .tableColumn,
              computed.display != .tableColumnGroup else { return nil }
        return computed
    }

    /// The note an element is, with endnote scopes memoized.
    func noteKind(_ element: ContentNode) -> ContentSemantics.NoteKind? {
        ContentSemantics.noteKind(element) { self.insideEndnotes[$0.order] }
    }

    /// The nearest note at or around each element, by order (-1 for none), computed in one pass
    /// when first needed.
    private lazy var enclosingNote: [Int] = {
        var enclosing = [Int](repeating: -1, count: document.nodes.count)
        for node in document.nodes where node.isElement {
            if noteKind(node) != nil { enclosing[node.order] = node.order }
            else if let parent = node.parent { enclosing[node.order] = enclosing[parent.order] }
        }
        return enclosing
    }()

    /// The ids each note is captured under, by the note element's order (`captureNote` has the
    /// rule). Settled for the whole document before any note is rendered, so an id names one
    /// note whatever order the notes are reached in.
    private lazy var noteIDs: [Int: [String]] = {
        let enclosing = enclosingNote
        var ids: [Int: [String]] = [:], taken = Set<String>()
        // First each note's own id and those of its leading descendants, as far as a nested note.
        for note in document.nodes where note.isElement && enclosing[note.order] == note.order {
            var leading: ContentNode? = note
            while let node = leading, enclosing[node.order] == note.order {
                if let id = node.id, taken.insert(id).inserted { ids[note.order, default: []].append(id) }
                leading = node.children.first(where: \.isElement)
            }
        }
        // Then every other id inside a note. An empty one is no id, and adds no name.
        for node in document.nodes where node.isElement && enclosing[node.order] >= 0 {
            if let id = node.id, !id.isEmpty, taken.insert(id).inserted { ids[enclosing[node.order], default: []].append(id) }
        }
        return ids
    }()

    /// Whether a note's content is being rendered: by its own writer, or by one that writer
    /// started for a table cell or caption in the note.
    private(set) var isCapturingNote = false

    /// Whether some id names a note, so that it is captured on its own.
    func isNamedNote(_ element: ContentNode) -> Bool { noteIDs[element.order] != nil }

    /// Whether an element is a footnote hidden from the flow, or inside one: navigating to it
    /// shows nothing.
    func isInsideHiddenFootnote(_ element: ContentNode) -> Bool {
        var note = enclosingNote[element.order]
        while note >= 0 {
            if noteKind(document.nodes[note]) == .footnote { return true }
            note = document.nodes[note].parent.map { enclosingNote[$0.order] } ?? -1
        }
        return false
    }

    /// Captures a note element's content once, under every id inside it that is not inside a
    /// note nested in it: a reference may name the note, its first paragraph, a later one or the
    /// number that opens it, and the note needs no id of its own. Ids inside a nested note name
    /// that note alone.
    ///
    /// An id used more than once names one note. The notes that carry it themselves or on a
    /// leading descendant (a first element child, and that one's, up to the first nested note)
    /// come first, in document order; then the notes that hold it anywhere else.
    ///
    /// Only the section's own walk captures notes, and it reaches every element once. A note's
    /// content leaves out the notes nested in it that are captured on their own, so notes do not
    /// repeat each other's text however deeply they nest. A nested note that no id names is
    /// captured nowhere else, so it is part of the note around it; and a note with nothing of
    /// its own shows the notes nested in it rather than nothing. The note budget bounds the rest.
    func captureNote(_ element: ContentNode) {
        guard noteBudget > 0, nesting < Self.maximumNesting else { return }
        guard let ids = noteIDs[element.order], notes[ids[0]] == nil else { return }
        // Claims the ids, so a note cannot capture itself again.
        for id in ids { notes[id] = NSAttributedString() }
        nesting += 1
        isCapturingNote = true
        defer { nesting -= 1; isCapturingNote = false }
        let names = Set(ids), reported = report.report
        let writer = SectionWriter(state: self, mode: .note(ids: names, whole: false))
        var content = writer.renderNote(element)
        if writer.leftOutNote, wholeNoteBudget > 0, content.string.allSatisfy(\.isWhitespace) {
            // Whichever rendering is not kept leaves nothing in the report.
            wholeNoteBudget -= element.subtreeEnd - element.order
            let own = report.report
            report.report = reported
            let whole = SectionWriter(state: self, mode: .note(ids: names, whole: true)).renderNote(element)
            if whole.string.allSatisfy(\.isWhitespace) { report.report = own } else { content = whole }
        }
        if content.length > noteBudget {
            let end = (content.string as NSString).rangeOfComposedCharacterSequence(at: noteBudget).location
            content = content.attributedSubstring(from: NSRange(location: 0, length: end))
        }
        noteBudget -= content.length
        for id in ids { notes[id] = content }
    }

    /// `RichContentContext.resolve`: the decoded archive path of a local reference. Remote and
    /// other non-archive references count as refused (`data:` URIs as unreadable) and return nil.
    func resolveResource(_ reference: String) -> String? {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return nil }
        guard let path = archivePath(of: reference) else {
            if reference.lowercased().hasPrefix("data:") { report.report.unreadableResources += 1 }
            else { report.report.remoteResourcesRefused += 1 }
            return nil
        }
        return path
    }

    /// The manifest media type of a local reference, without counting anything.
    func mediaType(of reference: String) -> String? {
        guard let path = archivePath(of: reference) else { return nil }
        return request.publication.resources.first { $0.path == path }?.mediaType
    }

    private func archivePath(of reference: String) -> String? {
        guard let resolved = try? ResourceReference.resolve(reference, relativeTo: document.path) else { return nil }
        let path = String(resolved.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        return path.removingPercentEncoding ?? path
    }
}
