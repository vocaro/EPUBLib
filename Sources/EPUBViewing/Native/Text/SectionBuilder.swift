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
            document = try NativeFallbacks.document(for: item.resource, in: request.publication)
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
                           string: output.string, map: output.map, anchors: output.anchors, notes: state.shownNotes,
                           title: title?.isEmpty == false ? title : nil, report: state.report.report, layout: state.layout)
    }

    static func withheld(_ request: SectionBuildRequest, reason: Error) -> SectionText {
        let item = request.publication.spine[request.spineIndex]
        let empty = try! ContentDocument.parse(Data("<html xmlns='http://www.w3.org/1999/xhtml'><body/></html>".utf8),
                                               path: item.resource.path)
        var report = SectionReport()
        report.withheld = true
        let font = request.fonts.font(for: ComputedStyle(fontSize: request.typography.fontSize))
        // No text handed to layout is without a tab interval, as in a section that was built.
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = InlineStyling.tabInterval(font)
        let notice = NSAttributedString(string: "This section could not be shown.", attributes: [
            .font: font, .paragraphStyle: paragraph,
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
    /// What laying out the text this build writes finds; the writer covers that text with it.
    let layout = SectionLayoutRecord()
    let styling: InlineStyling
    /// Counters and quotes for generated content, shared by the section's writer and those it
    /// starts for table cells and captions.
    var generated = GeneratedContentState()
    /// Every note captured, under each id that names it (`captureNote`).
    var notes: [EPUBElementID: NSAttributedString] = [:]
    /// The notes captured that show something. A note that is empty or white space opens no
    /// popover: a reference to it finds no note and navigates to it.
    var shownNotes: [EPUBElementID: NSAttributedString] { notes.filter { !$0.value.string.allSatisfy(\.isWhitespace) } }
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
    /// UTF-16 units all of a section's notes may hold of their own. A note leaves out the notes
    /// nested in it that are captured on their own, so only hostile markup comes near this.
    static let maximumNoteLength = 4 << 20
    private var noteBudget = SectionBuildState.maximumNoteLength
    /// UTF-16 units the notes with nothing of their own may hold of the notes nested in them.
    /// It is apart from the note budget, so what such a note repeats takes nothing from a
    /// note's own text.
    private var wholeNoteBudget = SectionBuildState.maximumNoteLength
    /// How many levels of the notes nested in it a note with nothing of its own shows: two
    /// elements marking one note, inside a wrapper around several. `captureNote` has the bound
    /// this puts on the work.
    static let wholeNoteDepth = 2
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
                .readerSectionLayout: layout,
            ])
        }
        nesting += 1
        defer { nesting -= 1 }
        return SectionWriter(state: self, mode: noteMode ?? .detached).renderContent(of: element, style: style)
    }

    /// Consecutive sibling nodes rendered into a separate string the same way, for the anonymous
    /// cell a table puts around content written outside its cells. Too deep a nesting renders
    /// their words, without those of the elements the flow leaves out (`flowStyle`).
    func renderNodes(_ nodes: [ContentNode], style: ComputedStyle) -> NSAttributedString {
        guard let first = nodes.first, let last = nodes.last else { return NSAttributedString() }
        guard nesting < Self.maximumNesting else { return flattenedNodes(first: first, last: last, style: style) }
        nesting += 1
        defer { nesting -= 1 }
        return SectionWriter(state: self, mode: noteMode ?? .detached).renderContent(of: nodes, style: style)
    }

    /// The bounded-depth fallback is its own phase: its large computed-style traversal
    /// temporaries must not stay on the stack while anonymous table cells recurse.
    private func flattenedNodes(first: ContentNode, last: ContentNode, style: ComputedStyle) -> NSAttributedString {
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
            .readerSectionLayout: layout,
        ])
    }

    /// An element's computed style, or nil where the writer leaves the element out of the flow
    /// whatever it holds (`SectionWriter.enter`): one that is never rendered or has no box, and
    /// a footnote, which is kept in the section's notes.
    private func flowStyle(of element: ContentNode, in parent: ComputedStyle) -> ComputedStyle? {
        if element.isHTML, ContentSemantics.neverRendered.contains(element.name) { return nil }
        var computed = style(element, parent)
        if element.isHTML("noscript"), computed.display == .none { computed.display = .block }
        guard !isHiddenFootnote(element), computed.display != .none, computed.display != .tableColumn,
              computed.display != .tableColumnGroup else { return nil }
        return computed
    }

    /// The note an element is, with endnote scopes memoized.
    func noteKind(_ element: ContentNode) -> ContentSemantics.NoteKind? {
        ContentSemantics.noteKind(element) { self.insideEndnotes[$0.order] }
    }

    /// Whether the writer leaves an element out of the flow as a footnote, to show it only in
    /// place of its reference (`SectionWriter.enter`). By the same test a note takes every id
    /// inside it (`noteIDs`), so that what is hidden can be shown, with the one exception
    /// `insideHiddenFootnote` makes: a table part.
    func isHiddenFootnote(_ element: ContentNode) -> Bool { noteKind(element) == .footnote }

    /// Legacy named anchors follow the section's fragment registration: an id takes precedence,
    /// an anchor with an id uses that id, and the first eligible name in document order wins.
    private lazy var namedAnchors: [EPUBElementID: ContentNode] = {
        var names: [EPUBElementID: ContentNode] = [:]
        for node in document.nodes where node.isHTML("a") && node.id == nil {
            if let name = node.attribute("name"), !name.isEmpty, document.element(id: name) == nil, names[name] == nil {
                names[name] = node
            }
        }
        return names
    }()

    /// The element a fragment names. An empty fragment names none, whatever carries an empty id:
    /// `href="#"` is the top of the document.
    func fragmentTarget(_ name: String) -> ContentNode? {
        guard !name.isEmpty else { return nil }
        return document.element(id: name) ?? namedAnchors[name]
    }

    /// The name a note may be captured under that an element carries: its id, or an eligible
    /// legacy name. An empty id names nothing.
    private func noteName(of node: ContentNode) -> String? {
        if let id = node.id { return id.isEmpty ? nil : id }
        guard let name = node.attribute("name"), namedAnchors[name] === node else { return nil }
        return name
    }

    /// Whether an element or one of its leading descendants carries a name.
    private func leadsWithName(_ element: ContentNode) -> Bool {
        var node: ContentNode? = element
        while let current = node {
            if noteName(of: current) != nil { return true }
            node = current.children.first(where: \.isElement)
        }
        return false
    }

    /// Whether an element is one of several items, with more after it: a later sibling of its
    /// name is named itself or by a leading descendant, and their parent holds no text of its
    /// own. The paragraphs or list items of an endnotes section typed as one note are such
    /// items. The cells of a table row are the parts of one item, and the elements in a
    /// paragraph's text are among its words.
    private func isOneOfSeveralItems(_ element: ContentNode) -> Bool {
        guard let parent = element.parent, !element.isHTML("td"), !element.isHTML("th"),
              !parent.children.contains(where: { $0.isText && !$0.text.allSatisfy(\.isWhitespace) }) else { return false }
        return parent.children[(element.indexInParent + 1)...].contains {
            $0.isElement && $0.name == element.name && $0.namespace == element.namespace && leadsWithName($0)
        }
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

    /// Whether each element (by order) is a footnote hidden from the flow or inside one,
    /// computed in one pass when first needed, so asking is not a climb through the notes
    /// around the element.
    ///
    /// A footnote is hidden when the writer hides it (`isHiddenFootnote`), with one exception:
    /// a table part typed as a footnote (`ContentSemantics.isTablePart`) is not counted. The
    /// table builder (`TableContent.build`) makes a grid of a table's parts by their names and
    /// never asks whether one is a footnote, so a table of two or more columns draws a cell,
    /// row, row group or caption so typed where it stands (a column has nothing to show), and
    /// only a table that flows as text has the writer leave it out. Which of the two a table
    /// is, is the rich-content factory's decision and not known here. So in both the part is
    /// named as a note that stays in the flow, and a reference to a later element of it
    /// navigates to the table. Where the table flows as text, that reference finds nothing
    /// shown.
    ///
    /// What is around or inside the part is counted as anywhere else: a part inside a hidden
    /// footnote is hidden with it, and a footnote inside a part is hidden itself, since
    /// whatever a grid shows that is not one of its parts goes through the writer.
    private lazy var insideHiddenFootnote: [Bool] = {
        let enclosing = enclosingNote
        var inside = [Bool](repeating: false, count: document.nodes.count)
        for node in document.nodes where node.isElement {
            if enclosing[node.order] == node.order, isHiddenFootnote(node), !ContentSemantics.isTablePart(node) {
                inside[node.order] = true
            } else if let parent = node.parent { inside[node.order] = inside[parent.order] }
        }
        return inside
    }()

    /// The ids each note is captured under, by the note element's order (`captureNote` has the
    /// rule). Settled for the whole document before any note is rendered, so an id names one
    /// note whatever order the notes are reached in.
    private lazy var noteIDs: [Int: [String]] = {
        let enclosing = enclosingNote, hidden = insideHiddenFootnote
        var ids: [Int: [String]] = [:], taken = Set<EPUBElementID>()
        // First each note's own id and those of its leading descendants, as far as a nested note,
        // or in a note that stays in the flow as far as an item of several.
        for note in document.nodes where note.isElement && enclosing[note.order] == note.order {
            var leading: ContentNode? = note
            while let node = leading, enclosing[node.order] == note.order,
                  node === note || hidden[note.order] || !isOneOfSeveralItems(node) {
                if let id = noteName(of: node), taken.insert(EPUBElementID(id)).inserted { ids[note.order, default: []].append(id) }
                leading = node.children.first(where: \.isElement)
            }
        }
        // Then every other id inside a footnote hidden from the flow, for the nearest note
        // around it.
        for node in document.nodes where node.isElement && hidden[node.order] {
            if let id = noteName(of: node), taken.insert(EPUBElementID(id)).inserted { ids[enclosing[node.order], default: []].append(id) }
        }
        return ids
    }()

    /// How many notes captured on their own each element is in, itself counted (by order),
    /// computed in one pass when first needed.
    private lazy var namedNoteDepth: [Int] = {
        let ids = noteIDs
        var depth = [Int](repeating: 0, count: document.nodes.count)
        for node in document.nodes where node.isElement {
            depth[node.order] = (node.parent.map { depth[$0.order] } ?? 0) + (ids[node.order] == nil ? 0 : 1)
        }
        return depth
    }()

    /// Whether a note's content is being rendered: by its own writer, or by one that writer
    /// started for a table cell or caption in the note.
    private(set) var noteMode: SectionWriter.Mode?
    var isCapturingNote: Bool { noteMode != nil }

    /// Whether some id names a note, so that it is captured on its own.
    func isNamedNote(_ element: ContentNode) -> Bool { noteIDs[element.order] != nil }

    /// How many notes captured on their own an element is in, itself counted.
    func noteDepth(of element: ContentNode) -> Int { namedNoteDepth[element.order] }

    /// Whether an element is a footnote hidden from the flow, or inside one, as
    /// `insideHiddenFootnote` counts them: navigating to it shows nothing.
    func isInsideHiddenFootnote(_ element: ContentNode) -> Bool { insideHiddenFootnote[element.order] }

    /// Captures a note element's content once, under the ids that name it. A note that stays
    /// in the flow is named by its own id and those of its leading descendants (a first element
    /// child, and that one's, up to the first nested note): a reference may name the note's
    /// first paragraph or the number that opens it, and the note needs no id of its own. A
    /// reference to any other element of such a note navigates to it, since it can be read
    /// there. So does one to the first of several items in it (`isOneOfSeveralItems`), which
    /// ends the leading descendants: the first paragraph or list item of an endnotes section
    /// typed as one note names that item, as the later ones do, not the whole section. A
    /// footnote hidden from the flow (`insideHiddenFootnote`) cannot be read there, so it and
    /// every note inside it are also named by every other id inside them that is not inside a
    /// note nested further in. Ids inside a nested note name that note alone. A table part
    /// typed as a footnote is not hidden on that account, since a table may draw it: unless a
    /// hidden footnote is around it, it is named as a note that stays in the flow.
    ///
    /// An id used more than once names one note. The notes that carry it themselves or on a
    /// leading descendant come first, in document order; then the hidden ones that hold it
    /// anywhere else.
    ///
    /// Only the section's own walk captures notes, and it reaches every element once. A note's
    /// content leaves out the notes nested in it that are captured on their own, so notes do not
    /// repeat each other's text however deeply they nest, and the note budget bounds what they
    /// hold. A nested note that no id names is captured nowhere else, so it is part of the note
    /// around it.
    ///
    /// A note with nothing of its own would show nothing, so it is rendered a second time with
    /// the notes nested in it, `wholeNoteDepth` levels of them. That is the only repetition,
    /// and it does not grow with the document or the nesting: besides the rendering for the
    /// note it belongs to, an element is rendered at most `wholeNoteDepth + 1` times more, for
    /// that note and the `wholeNoteDepth` captured notes around it. A note deeper inside a
    /// stack of notes that hold only one another is left out of the outer ones, which stay
    /// empty. What the second rendering holds comes from a budget of its own.
    ///
    /// A note that shows nothing, white space at most, is captured all the same, so that it is
    /// rendered once, but the section does not keep it (`shownNotes`).
    ///
    /// A note's rendering leaves the counters and quotes of generated content as they were
    /// (`generated`), since the section's walk reaches its content again, unless
    /// `keepsCounters`: a footnote hidden from the flow counts where it stands, as it would shown.
    func captureNote(_ element: ContentNode, keepsCounters: Bool = false) {
        guard noteBudget > 0, nesting < Self.maximumNesting else { return }
        guard let ids = noteIDs[element.order], notes[ids[0]] == nil else { return }
        // Claims the ids, so a note cannot capture itself again.
        let claimed = NSAttributedString()
        for id in ids { notes[id] = claimed }
        nesting += 1
        let previousMode = noteMode
        defer { nesting -= 1; noteMode = previousMode }
        let names = Set(ids.map { EPUBElementID($0) }), depth = namedNoteDepth[element.order], reported = report.report
        noteMode = .note(ids: names, depth: depth)
        let counters = generated
        let writer = SectionWriter(state: self, mode: .note(ids: names, depth: depth))
        var content = Self.cut(writer.renderNote(element), to: &noteBudget)
        var counted = generated
        if writer.leftOutNote, wholeNoteBudget > 0, content.string.allSatisfy(\.isWhitespace) {
            // Whichever rendering is not kept leaves nothing in the report.
            let own = report.report
            report.report = reported
            noteMode = .note(ids: names, depth: depth + Self.wholeNoteDepth)
            generated = counters
            let whole = SectionWriter(state: self, mode: .note(ids: names, depth: depth + Self.wholeNoteDepth)).renderNote(element)
            if whole.string.allSatisfy(\.isWhitespace) { report.report = own }
            else { content = Self.cut(whole, to: &wholeNoteBudget); counted = generated }
        }
        generated = keepsCounters ? counted : counters
        for id in ids { notes[id] = content }
    }

    /// A note's content, cut to what is left of a budget and taken from it.
    private static func cut(_ content: NSAttributedString, to budget: inout Int) -> NSAttributedString {
        var content = content
        if content.length > budget {
            let end = (content.string as NSString).rangeOfComposedCharacterSequence(at: budget).location
            content = content.attributedSubstring(from: NSRange(location: 0, length: end))
        }
        budget -= content.length
        return content
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
