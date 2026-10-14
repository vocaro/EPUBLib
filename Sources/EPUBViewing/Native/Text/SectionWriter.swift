import CoreText
import EPUBCore
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One walk of a content document (or of one element's content) into attributed text.
///
/// The model follows CSS 2.1 visual formatting, simplified to what TextKit paragraphs express:
/// - Each run of inline content in a block box is one paragraph (`\n`-terminated). `<br>` and
///   preserved newlines are U+2028, so a block's spacing applies once.
/// - Adjoining vertical margins collapse (the largest positive plus the most negative); a block's
///   top or bottom padding or border stops its margin collapsing with its children's. The gap
///   between two paragraphs is the earlier paragraph's `paragraphSpacing`, so a page that breaks
///   there starts flush, as CSS truncates margins at an unforced break. After a forced break
///   (`.readerPageBreakBefore`) it is the later paragraph's `paragraphSpacingBefore` instead.
///   The section's leading gap is its first paragraph's `paragraphSpacingBefore`.
/// - Ancestors' horizontal margins, borders and padding accumulate into the head and tail indents
///   (by direction), and `text-indent` indents a block's first line.
/// - Percentage/viewport paragraph lengths retain authored dimensions for resolution at live
///   layout size. Total horizontal indentation is capped at a third of the column so deep
///   nesting cannot squeeze a phone column to nothing.
/// - Whitespace follows CSS Text 3 per `white-space`: collapsible runs collapse across inline
///   boundaries, a run at a line's start or end is removed, and a segment break between two East
///   Asian wide characters disappears. A single trailing forced break in a block makes no line.
/// - Floats, positioned callouts and sized inline-blocks keep separate source paragraphs and
///   symbolic constraints. The native layout resolves wrapping and positions at viewport size;
///   oversized or complex boxes remain pageable in-flow text with the same exact map.
/// - A positioned box hidden from the page but not from assistive technology (parked off screen
///   or clipped to nothing) is a `SpokenLabelAttachment` for each block of its text: a character
///   that takes no room, in a line of the text, because a text view's own accessibility reads
///   lines that hold something. Inside a line it stands where the box does, and the line's
///   white space collapses across it. Between blocks it opens the line of the content after it,
///   or ends the paragraph before when that content must open its own (a table, a float); with
///   neither it has a paragraph of no height, which the paragraphs after it do not see.
/// - A heading (`ContentSemantics.headingLevel`) is marked for assistive technology alone: its
///   text, from its first character to its last, and a hidden label standing for one, carry
///   `.readerHeading`. No character, map span or paragraph is different for it.
/// - Every rendered character from the DOM is mapped (`TextMap`); generated text is not.
final class SectionWriter {
    enum Mode: Equatable {
        /// The spine item itself: text map, anchors, page breaks.
        case section
        /// A table cell or caption for a rich-content factory: no map.
        case detached
        /// A note's content for showing in place: no map, blocks flattened to plain paragraphs.
        /// `ids` are the ids the note is captured under. `depth` is how deep in notes captured
        /// on their own (`SectionBuildState.noteDepth`) the content goes: the note's own depth,
        /// or further for a note with nothing else to show.
        case note(ids: Set<String>, depth: Int)
    }

    struct Output {
        let string: NSAttributedString
        let map: TextMap
        let anchors: [String: Int]
    }

    /// Nominal column the percentages of a section resolve against.
    static let nominalColumn: CGFloat = 600
    private static let nominalViewport = CGSize(width: 600, height: 800)
    private static let maximumIndent: CGFloat = 200
    private static let maximumGap: CGFloat = 600

    private let state: SectionBuildState
    private let mode: Mode
    private let document: ContentDocument
    private let styling: InlineStyling
    private var isSection: Bool { mode == .section }
    private var recordsMap: Bool { !isNote }
    private var isNote: Bool { if case .note = mode { true } else { false } }
    /// Whether a note's writer left out a note nested in it.
    private(set) var leftOutNote = false

    private var buffer = TextBuffer()
    private var map = TextMap()
    private var anchors: [String: Int] = [:]
    /// Ids waiting for the next rendered character, with their registration serial.
    private var pendingAnchors: [(id: String, serial: Int)] = []
    private var anchorSerial = 0
    private var paragraphs: [Paragraph] = []
    private var postAttributes: [(range: NSRange, key: NSAttributedString.Key, value: Any)] = []

    // Block state.
    private var frames: [BlockFrame] = []
    private var gap = MarginGap()
    private var sizingGap = ReaderParagraphGap()
    private var pendingPageBreak = false
    private var pendingMarker: Marker?
    private var lists: [ListCounter] = []
    private var orphanList = ListCounter(value: 0, step: 1)
    /// Inside a fallback table row's cells: block boxes render inline.
    private var flattenDepth = 0

    // Line state.
    /// Only a real block boundary is a break in a copied passage. Inline flow boxes split
    /// TextKit paragraphs for layout while retaining the source line and its collapsed space.
    private var pendingPassageBoundary = false
    private var pendingPassageSpace: (segmentBreak: Bool, before: UInt32)?
    private var paragraphOpen = false
    private var lineStart = true
    private var pendingSpace: PendingSpace?
    private var lastWasCollapsedSpace = false
    private var pendingBreaks: [PendingBreak] = []
    private var lastScalar: UInt32 = 0x0A
    /// The sized inline box that closed last, while nothing but white space has followed it on
    /// its block's line: with that block's depth and the paragraph count when the box closed.
    private var lastInlineBox: (box: ReaderInlineBox, depth: Int, paragraphs: Int)?
    private var isolates: [Isolate] = []
    private var collectingRubyBase = false
    private var rubyBaseStart: Int?

    /// Hidden labels waiting for a line to stand in: the next content's, wherever that is.
    private var pendingSpoken: [SpokenLabel] = []
    private var spokenAttributes: Int?

    /// The headings being walked, the nearest last, each with where its first content was written.
    private var openHeadings: [(heading: ReaderHeading, start: Int?)] = []
    /// What `.readerHeading` is set on: each heading's text, and each hidden label of one.
    private var headingRanges: [(range: NSRange, heading: ReaderHeading)] = []
    /// One object for each heading element, by the element's order.
    private var headings: [Int: ReaderHeading] = [:]

    private var stack: [Entry] = []
    /// `ResourceReference.resolve` by href (nil: not in the archive); books repeat their links.
    private var resolvedLinks: [String: String?] = [:]

    init(state: SectionBuildState, mode: Mode) {
        self.state = state; self.mode = mode
        document = state.document; styling = state.styling
    }

    // MARK: Entry points

    func renderSection() -> Output {
        let language = InlineLanguage(hint: state.languageHint)
        frames = [BlockFrame(style: state.initialStyle, format: blockFormat(state.initialStyle, node: nil, parent: nil),
                             keepWithNext: false, firstParagraph: 0, language: language)]
        var context = InlineContext()
        context.language = language
        walk(Entry(node: document.root, children: [document.root], style: state.initialStyle, context: context))
        return finish()
    }

    func renderContent(of element: ContentNode, style: ComputedStyle) -> NSAttributedString {
        renderContent(element.children, in: element, box: element, style: style, source: element.order...element.subtreeEnd)
    }

    /// Consecutive children of one element as the content of an anonymous box inheriting `style`
    /// (an anonymous table cell). The detached map covers the nodes and what is between them.
    func renderContent(of nodes: [ContentNode], style: ComputedStyle) -> NSAttributedString {
        guard let first = nodes.first, let last = nodes.last, let parent = first.parent else { return NSAttributedString() }
        return renderContent(nodes, in: parent, box: nil, style: style, source: first.order...last.subtreeEnd)
    }

    private func renderContent(_ children: [ContentNode], in element: ContentNode, box: ContentNode?, style: ComputedStyle,
                               source: ClosedRange<Int>) -> NSAttributedString {
        let language = inheritedLanguage(of: element)
        frames = [BlockFrame(style: style, format: blockFormat(style, node: box, parent: nil),
                             keepWithNext: false, firstParagraph: 0, language: language)]
        var context = InlineContext()
        context.language = language
        walk(Entry(node: element, children: children, style: style, context: context))
        let result = finish()
        let text = NSMutableAttributedString(attributedString: result.string)
        if text.length > 0 {
            text.addAttribute(.readerDetachedMap, value: ReaderDetachedTextMap(map: result.map,
                node: source.lowerBound, subtreeEnd: source.upperBound), range: NSRange(location: 0, length: text.length))
        }
        return text
    }

    func renderNote(_ element: ContentNode) -> NSAttributedString {
        var style = state.style(element, state.bodyStyle)
        style.display = .block
        style.isHidden = false
        style.fontSize = state.bodyStyle.fontSize
        let language = inheritedLanguage(of: element)
        frames = [BlockFrame(style: style, format: blockFormat(style, node: element, parent: nil),
                             keepWithNext: false, firstParagraph: 0, language: language)]
        var context = InlineContext()
        context.language = language
        walk(Entry(node: element, children: element.children, style: style, context: context))
        return finish().string
    }

    /// The language the section's walk reaches `element` with: what it or its nearest ancestor
    /// declares, else none and the package's as the hint.
    private func inheritedLanguage(of element: ContentNode) -> InlineLanguage {
        var language = InlineLanguage(hint: state.languageHint)
        var node: ContentNode? = element
        while let current = node {
            if let declared = current.language { language.declare(declared); break }
            node = current.parent
        }
        return language
    }

    // MARK: Walk

    /// An element being walked. The walk is iterative: documents may nest 200 deep and builds run
    /// on background threads with small stacks.
    private final class Entry {
        let node: ContentNode
        let children: [ContentNode]
        var next = 0
        let style: ComputedStyle
        var context: InlineContext
        var textAttributes: Int?
        var role: Role = .normal
        var exit = Exit()

        init(node: ContentNode, children: [ContentNode], style: ComputedStyle, context: InlineContext) {
            self.node = node; self.children = children; self.style = style; self.context = context
        }
    }

    private enum Role {
        case normal, ruby, media, tableRows, tableRow(cells: Int)
        /// `epub:switch`: only the chosen branch renders.
        case switchBranches(chosen: ContentNode?)
    }

    private struct Exit {
        var block = false
        var list = false
        var flatten = false
        var softBoundary = false
        var isolate = false
        var heading = false
        var closeQuote: (text: String, attributes: Int)?
        var ruby: (collecting: Bool, start: Int?)?
    }

    private func walk(_ root: Entry) {
        stack.append(root)
        while let top = stack.last {
            if top.next < top.children.count {
                let child = top.children[top.next]
                top.next += 1
                if child.isText {
                    let attributes = top.textAttributes ?? styling.attributes(top.style, top.context)
                    top.textAttributes = attributes
                    appendText(child, style: top.style, context: top.context, attributes: attributes)
                } else {
                    enter(child, parent: top)
                }
            } else {
                leave(stack.removeLast())
            }
        }
    }

    /// Style/eligibility work ends before table cells recurse, so its temporary value copies
    /// do not occupy the stack at every nesting level.
    private final class Prepared {
        let style: ComputedStyle
        let context: InlineContext
        init(style: ComputedStyle, context: InlineContext) { self.style = style; self.context = context }
    }

    private func enter(_ node: ContentNode, parent: Entry) {
        guard let prepared = prepare(node, parent: parent) else { return }
        if node.isHTML("table"), enterTable(node, style: prepared.style, context: prepared.context) { return }
        enterContent(node, parent: parent, style: prepared.style, context: prepared.context)
    }

    private func prepare(_ node: ContentNode, parent: Entry) -> Prepared? {
        switch parent.role {
        case .ruby where node.isHTML("rt") || node.isHTML("rtc"):
            annotateRuby(node, parentStyle: parent.style); return nil
        case .ruby where node.isHTML("rp"):
            skip(node); return nil
        case .media where node.isHTML("source") || node.isHTML("track"):
            skip(node); return nil
        case .switchBranches(let chosen) where node !== chosen:
            skip(node); return nil
        default: break
        }
        if node.isHTML, ContentSemantics.neverRendered.contains(node.name) { skip(node); return nil }
        // A formula shown as its own text never shows its encodings (TeX, content MathML).
        if node.name == "annotation" || node.name == "annotation-xml",
           node.namespace == ContentNamespace.mathML || node.namespace.isEmpty { skip(node); return nil }
        if node.namespace == ContentNamespace.ops, node.name == "trigger" { skip(node); return nil }

        let parentStyle = parent.style
        var style = state.style(node, parentStyle)
        if node.isHTML("noscript"), style.display == .none { style.display = .block }
        if style.writingMode != .horizontalTB { state.report.report.verticalWritingFlattened = true }
        if isSection, node.isHTML("body") { state.bodyStyle = style }
        register(node)
        if state.noteKind(node) != nil {
            if isSection { state.captureNote(node) }
            if case .note(_, let depth) = mode {
                // A note's content leaves out the notes nested in it that are captured on their
                // own, below the depth it goes to. One that no id names is captured nowhere
                // else: it is part of this note.
                if state.isNamedNote(node), state.noteDepth(of: node) > depth { leftOutNote = true; return nil }
            } else if state.isHiddenFootnote(node), !state.isCapturingNote || state.isNamedNote(node) {
                // A footnote is shown only in place of its reference. In a cell of a note's
                // table, one that no id names is part of that note, as it is outside the table.
                skip(node, registered: true); return nil
            }
        }
        guard style.display != .none, style.display != .tableColumn, style.display != .tableColumnGroup else {
            skip(node, registered: true); return nil
        }
        // Common visually hidden labels must not become visible duplicate text when their
        // positioned geometry is replaced by normal flow. Actual callouts remain selectable.
        if style.isOutOfFlow, !state.isFixedLayout, style.isVisuallyHiddenPositionedBox {
            skip(node, registered: true)
            speak(node, style: style, context: parent.context)
            return nil
        }
        if style.requiresFlowBox, !node.isHTML("html"), !node.isHTML("body") {
            state.report.report.flowBoxesReflowed = true
        }
        // An inline flex or grid container has no box of its own here: its items follow one another.
        if style.blockifiesChildren, !style.display.isBlockLevel, node.elementChildren.count > 1 {
            state.report.report.flexGridSimplified = true
        }
        var context = parent.context
        if let language = node.language { context.language.declare(language) }

        return Prepared(style: style, context: context)
    }

    private func enterTable(_ node: ContentNode, style: ComputedStyle, context: InlineContext) -> Bool {
        guard let result = state.request.rich.table(node, style: style, context: state.richContext) else { return false }
        insert(result, for: node, style: style, context: context)
        return true
    }

    private func enterContent(_ node: ContentNode, parent: Entry, style: ComputedStyle, context: InlineContext) {
        let parentStyle = parent.style
        if node.namespace == ContentNamespace.ops, node.name == "switch" {
            enterSwitch(node, style: style, context: context); return
        }
        if node.name == "svg", node.namespace == ContentNamespace.svg || node.namespace.isEmpty {
            if let result = state.request.rich.svg(node, style: style, context: state.richContext) {
                insert(result, for: node, style: style, context: context)
            } else { skip(node, registered: true) }
            return
        }
        if node.name == "math", node.namespace == ContentNamespace.mathML || node.namespace.isEmpty {
            if let result = state.request.rich.math(node, style: style, context: state.richContext) {
                insert(result, for: node, style: style, context: context)
            } else { push(node, style: style, context: context, parentStyle: parentStyle, role: .normal) }
            return
        }
        guard node.isHTML else {
            push(node, style: style, context: context, parentStyle: parentStyle, role: .normal); return
        }
        var role = Role.normal
        switch node.name {
        case "br": lineBreak(attributes: styling.attributes(style, context)); return
        case "wbr": wordBreak(attributes: styling.attributes(style, context)); return
        case "img":
            if let result = state.request.rich.image(node, style: style, context: state.richContext) {
                insert(result, for: node, style: style, context: context)
            } else { skip(node, registered: true) }
            return
        case "hr":
            insert(state.request.rich.horizontalRule(node, style: style, context: state.richContext),
                   for: node, style: style, context: context)
            return
        case "table":
            // A one-column table (a callout box) flows as ordinary blocks; wider ones as tabbed rows.
            role = Self.maximumCellsPerRow(node) > 1 ? .tableRows : .normal
        case "object", "embed":
            let reference = node.name == "object" ? node.attribute("data") : node.attribute("src")
            if isImage(reference, type: node.attribute("type")),
               let result = state.request.rich.image(node, style: style, context: state.richContext) {
                insert(result, for: node, style: style, context: context)
                return
            }
            countUnsupported(node)
            if node.name == "embed" { skip(node, registered: true); return }
            role = .media
        case "input", "select", "textarea", "keygen":
            if node.attribute("type")?.lowercased() != "hidden" { countUnsupported(node) }
            skip(node, registered: true)
            return
        case "button", "form":
            countUnsupported(node)
        case "iframe", "frame", "frameset":
            countUnsupported(node)
            skip(node, registered: true)
            return
        case _ where ContentSemantics.fallbackOnly.contains(node.name):
            countUnsupported(node)
            role = .media
        case "ruby":
            role = .ruby
        case "rp":
            skip(node, registered: true); return
        case "a" where isNote && ContentSemantics.isBacklink(node):
            skip(node, registered: true); return
        default: break
        }
        if case .tableRows = parent.role {
            if node.isHTML("tr") { role = .tableRow(cells: 0) }
            else if ContentSemantics.rowGroups.contains(node.name) { role = .tableRows }
        }
        if case .tableRow(let cells) = parent.role, node.isHTML("td") || node.isHTML("th") {
            parent.role = .tableRow(cells: cells + 1)
            if cells > 0 { cellSeparator() }
            flattenDepth += 1
            let entry = Entry(node: node, children: node.children, style: style, context: context)
            entry.exit.flatten = true
            stack.append(entry)
            return
        }
        push(node, style: style, context: context, parentStyle: parentStyle, role: role)
    }

    /// Pushes an element whose content is walked normally: a block box, or an inline box with its
    /// link, background, baseline shift, bidi isolation and generated quotes.
    private func push(_ node: ContentNode, style: ComputedStyle, context: InlineContext,
                      parentStyle: ComputedStyle, role: Role) {
        let entry = Entry(node: node, children: node.children, style: style, context: context)
        entry.role = role
        if let heading = heading(for: node) {
            openHeadings.append((heading, nil))
            entry.exit.heading = true
        }
        let blockLevel = style.display.isBlockLevel || style.requiresFlowBox
        if blockLevel && flattenDepth == 0 {
            enterBlock(node, style: style, language: context.language)
            entry.exit.block = true
            entry.context.background = nil
            entry.context.baselineOffset = 0
        } else {
            if blockLevel {
                softBoundary()
                entry.exit.softBoundary = true
            }
            if let background = style.backgroundColor, background.alpha > 0 { entry.context.background = background }
            switch style.verticalAlign {
            case .sub: entry.context.baselineOffset -= parentStyle.fontSize / 5
            case .super: entry.context.baselineOffset += parentStyle.fontSize / 3
            case .offset(let value): entry.context.baselineOffset += value
            default: break
            }
            let limit = 3 * max(parentStyle.fontSize, 1)
            entry.context.baselineOffset = min(max(entry.context.baselineOffset, -limit), limit)
            if node.isHTML, let isolate = isolation(node, style: style, context: entry.context) {
                isolates.append(isolate)
                entry.exit.isolate = true
            }
        }
        if node.isHTML, ContentSemantics.lists.contains(node.name) {
            lists.append(ListCounter(list: node))
            entry.exit.list = true
        }
        if style.display == .listItem { startListItem(node, style: style, context: entry.context) }
        if node.isHTML("a"), let href = node.attribute("href") ?? node.attribute("href", namespace: ContentNamespace.xlink) {
            if let link = link(for: node, href: href) {
                entry.context.link = link
                entry.context.linkBaseColor = parentStyle.color
            } else { entry.context.link = nil }
        }
        if node.isHTML("q") {
            let marks = ContentSemantics.quotes(language: entry.context.language.declared, depth: entry.context.quoteDepth)
            let attributes = styling.attributes(style, entry.context)
            emitGenerated(Array(marks.open.utf16), attributes: attributes)
            entry.exit.closeQuote = (marks.close, attributes)
            entry.context.quoteDepth += 1
        }
        if case .ruby = role {
            entry.exit.ruby = (collectingRubyBase, rubyBaseStart)
            collectingRubyBase = true
            rubyBaseStart = nil
        }
        stack.append(entry)
    }

    private func leave(_ entry: Entry) {
        if let quote = entry.exit.closeQuote { emitGenerated(Array(quote.text.utf16), attributes: quote.attributes) }
        if entry.exit.isolate, let isolate = isolates.popLast(), isolate.emitted, paragraphOpen {
            buffer.append(isolate.closer, attributes: isolate.attributes)
        }
        // A heading's text ends with its last content, before the break that ends its paragraph.
        if entry.exit.heading, let open = openHeadings.popLast(), let start = open.start, buffer.count > start {
            headingRanges.append((NSRange(location: start, length: buffer.count - start), open.heading))
        }
        if entry.exit.flatten { flattenDepth -= 1 }
        if entry.exit.softBoundary { softBoundary() }
        if let saved = entry.exit.ruby { collectingRubyBase = saved.collecting; rubyBaseStart = saved.start }
        if entry.exit.block { exitBlock() }
        if entry.exit.list { lists.removeLast() }
    }

    /// EPUB 3 `epub:switch`: the MathML case when there is one (MathML is supported), else the default.
    private func enterSwitch(_ node: ContentNode, style: ComputedStyle, context: InlineContext) {
        let branches = node.elementChildren.filter { $0.namespace == ContentNamespace.ops }
        let chosen = branches.first { $0.name == "case" && $0.attribute("required-namespace") == ContentNamespace.mathML }
            ?? branches.first { $0.name == "default" }
        let entry = Entry(node: node, children: node.elementChildren, style: style, context: context)
        entry.role = .switchBranches(chosen: chosen)
        stack.append(entry)
    }

    /// The most cells in one of a table's own rows (not a nested table's).
    private static func maximumCellsPerRow(_ table: ContentNode) -> Int {
        var maximum = 0
        func visit(_ node: ContentNode) {
            for child in node.elementChildren where child.isHTML {
                if child.name == "tr" {
                    maximum = max(maximum, child.elementChildren.reduce(0) { $0 + ($1.isHTML("td") || $1.isHTML("th") ? 1 : 0) })
                } else if ContentSemantics.rowGroups.contains(child.name) { visit(child) }
            }
        }
        visit(table)
        return maximum
    }

    /// Ids and notes inside content that is not rendered still get anchors and note text. Only the
    /// section's walk needs them: it reaches every element, cell and note content included.
    private func skip(_ node: ContentNode, registered: Bool = false) {
        let first = registered ? node.order + 1 : node.order
        guard isSection, first <= node.subtreeEnd else { return }
        for index in first...node.subtreeEnd {
            let element = document.nodes[index]
            guard element.isElement else { continue }
            register(element)
            if state.noteKind(element) != nil { state.captureNote(element) }
        }
    }

    private func register(_ node: ContentNode) {
        guard isSection else { return }
        if let id = node.id { if anchors[id] == nil { pendAnchor(id) } }
        else if node.isHTML("a"), let name = node.attribute("name"), !name.isEmpty, anchors[name] == nil,
                document.element(id: name) == nil {
            pendAnchor(name) // A legacy named anchor, when no element claims the id.
        }
    }

    private func countUnsupported(_ node: ContentNode) {
        state.report.report.unsupportedElements[node.name, default: 0] += 1
    }

    private func isImage(_ reference: String?, type: String?) -> Bool {
        if let type = type?.lowercased(), type.hasPrefix("image/") { return true }
        guard let reference, !reference.isEmpty else { return false }
        if let mediaType = state.mediaType(of: reference) { return mediaType.hasPrefix("image/") }
        let path = reference.split(separator: "#").first.map(String.init) ?? reference
        return ContentSemantics.imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    // MARK: Links

    private func link(for element: ContentNode, href: String) -> ReaderLink? {
        let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolution = resolvedLinks[href] ?? (try? ResourceReference.resolve(href, relativeTo: document.path))
        resolvedLinks[href] = .some(resolution)
        guard let resolved = resolution else { return .external(href) }
        let parts = resolved.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let fragment = parts.count == 2 ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : nil
        // The note's own number, or another link to the note it is in.
        if case .note(let ids, _) = mode, path == document.path, let fragment, ids.contains(fragment) { return nil }
        if ContentSemantics.isNoteReference(element) { return .note(href: resolved) }
        // A plain link to a note or its child is a note link; so is one to anything inside a
        // footnote hidden from the flow (`isInsideHiddenFootnote`), where there is nothing to
        // navigate to.
        if path == document.path, let fragment, let target = state.fragmentTarget(fragment),
           state.noteKind(target) != nil || target.parent.flatMap(state.noteKind) != nil
            || (!fragment.isEmpty && state.isInsideHiddenFootnote(target)) {
            return .note(href: resolved)
        }
        return .internal(href: resolved)
    }

    // MARK: Blocks

    private func enterBlock(_ node: ContentNode, style: ComputedStyle, language: InlineLanguage) {
        pendingPassageBoundary = pendingPassageBoundary || style.display.isBlockLevel
        if style.display == .listItem, pendingMarker != nil { openParagraph() } // An outer item's marker gets its own line.
        let inline = inlineBox(style) // Read from the line the box is on, which closing the paragraph ends.
        closeParagraph()
        lastInlineBox = nil
        if !isNote {
            gap.add(resolve(style.margin.top))
            let inset = resolve(style.padding.top) + Self.width(style.border.top)
            if inset > 0 { gap.seal(inset) }
            let containing = frames.last?.format.edges
            sizingGap.add(style.margin.top, containing: containing)
            sizingGap.seal(style.padding.top, border: Self.width(style.border.top), containing: containing)
        }
        if isSection {
            if style.breakBefore == .page || style.breakBefore == .column { pendingPageBreak = true }
            if style.breakBefore == .avoid, !paragraphs.isEmpty { paragraphs[paragraphs.count - 1].keepWithNext = true }
        }
        let parent = frames[frames.count - 1]
        let keep = ContentSemantics.isHeading(node) || node.isHTML("dt") || style.breakAfter == .avoid
        frames.append(BlockFrame(style: style, format: blockFormat(style, node: node, parent: parent, inline: inline),
                                 keepWithNext: keep, keepTogether: style.breakInside == .avoid,
                                 firstParagraph: paragraphs.count, language: language))
        frames[frames.count - 1].inlineBox = inline
    }

    /// A sized inline box's place on the line it is written on: whether text or another such box
    /// precedes it there, and the white space between them, which the box's own paragraph drops.
    private func inlineBox(_ style: ComputedStyle) -> ReaderInlineBox? {
        guard style.display == .inlineBlock, style.float == .none, !style.isOutOfFlow, style.requiresFlowBox else { return nil }
        let parent = frames[frames.count - 1]
        var continues = false, space: CGFloat = 0
        if paragraphOpen {
            continues = !lineStart && pendingBreaks.isEmpty
            if continues, pendingSpace != nil { space = spaceAdvance(parent) }
        } else if let last = lastInlineBox, last.depth == frames.count, last.paragraphs == paragraphs.count {
            continues = true
            space = last.box.trailingSpace
        }
        let opensBlock = !continues && paragraphs.count == parent.firstParagraph && pendingMarker == nil
        return ReaderInlineBox(block: parent.format.flow, rightToLeft: parent.format.direction == .rightToLeft,
                               continuesLine: continues, leadingSpace: space,
                               firstLineIndent: opensBlock ? parent.format.textIndent : 0)
    }

    private func spaceAdvance(_ frame: BlockFrame) -> CGFloat {
        InlineStyling.spaceAdvance(state.request.fonts.font(for: frame.style))
    }

    private func exitBlock() {
        pendingPassageBoundary = pendingPassageBoundary || (frames.last?.style.display.isBlockLevel ?? false)
        if let marker = pendingMarker, marker.frame == frames.count - 1 { openParagraph() } // An empty item still shows its marker.
        closeParagraph()
        guard frames.count > 1 else { return }
        let frame = frames.removeLast()
        lastInlineBox = frame.inlineBox.map { ($0, frames.count, paragraphs.count) }
        if frame.format.itemAlignment.close() { state.report.report.flexGridSimplified = true }
        // `break-inside: avoid` keeps a box's paragraphs with each other, not its last with what follows.
        if frame.keepTogether, let last = paragraphs.indices.last, last >= frame.firstParagraph,
           paragraphs[last].keptTogetherBy == frames.count {
            paragraphs[last].keepWithNext = paragraphs[last].keepsOwnNext
        }
        if !isNote {
            let inset = resolve(frame.style.padding.bottom) + Self.width(frame.style.border.bottom)
            if inset > 0 { gap.seal(inset) }
            gap.add(resolve(frame.style.margin.bottom))
            sizingGap.seal(frame.style.padding.bottom, border: Self.width(frame.style.border.bottom), containing: frame.format.edges.parent)
            sizingGap.add(frame.style.margin.bottom, containing: frame.format.edges.parent)
        }
        if isSection, frame.style.breakAfter == .page || frame.style.breakAfter == .column { pendingPageBreak = true }
    }

    private func blockFormat(_ style: ComputedStyle, node: ContentNode?, parent: BlockFrame?,
                             inline: ReaderInlineBox? = nil) -> BlockFormat {
        var left = parent?.format.left ?? 0, right = parent?.format.right ?? 0
        if parent != nil { // The base frame is the column itself; a box adds its own edges.
            var marginLeft = resolve(style.margin.left), marginRight = resolve(style.margin.right)
            if style.margin.left == .auto, style.margin.right == .auto, !style.requiresFlowBox {
                let width: CGFloat? = switch (style.width, style.maxWidth) {
                case (.percent(let value), _), (.auto, .percent(let value)): value
                default: nil
                }
                if let width, width > 0, width < 100 {
                    marginLeft = Self.nominalColumn * (100 - width) / 200; marginRight = marginLeft
                }
            }
            left += marginLeft + Self.width(style.border.left) + resolve(style.padding.left)
            right += marginRight + Self.width(style.border.right) + resolve(style.padding.right)
        }
        let direction: NSWritingDirection
        switch node?.isHTML == true ? node?.attribute("dir")?.lowercased() : nil {
        case "rtl": direction = .rightToLeft
        case "ltr": direction = .leftToRight
        case "auto": direction = .natural
        default:
            if let parent, parent.style.direction == style.direction { direction = parent.format.direction }
            else { direction = style.direction == .rtl ? .rightToLeft : .leftToRight }
        }
        let rtl = direction == .rightToLeft
        let alignment: NSTextAlignment, endAligned: Bool
        switch style.textAlign {
        case .start: (alignment, endAligned) = (.natural, false)
        case .end: (alignment, endAligned) = (rtl ? .left : .right, true)
        case .left: (alignment, endAligned) = (.left, rtl)
        case .right: (alignment, endAligned) = (.right, !rtl)
        case .center: (alignment, endAligned) = (.center, false)
        case .justify: (alignment, endAligned) = (.justified, false)
        }
        let font = state.request.fonts.font(for: style)
        var cssLineHeight: CGFloat?, multiple: CGFloat?
        switch style.lineHeight {
        case .normal: break
        case .multiple(let value):
            let points = min(max(value, 0.5), 5) * style.fontSize
            cssLineHeight = points
            let natural = InlineStyling.naturalLineHeight(font)
            if natural > 0 { multiple = points / natural }
        case .points(let value):
            cssLineHeight = min(max(value, style.fontSize * 0.5), style.fontSize * 5)
        }
        var boxes = parent?.format.boxes ?? []
        // Replaced content (images, tables, formulas) already sizes itself against its line.
        let replaced = node.map { ["img", "object", "embed", "svg", "math", "table", "hr"].contains($0.name) } ?? false
        let containing = parent?.format.scope
        let scope = style.position != .static || containing == nil ? ReaderBoxScope(style: style, left: left, right: right, parent: containing) : containing!
        if style.requiresFlowBox && boxes.count < 8 {
            boxes.append(ReaderFlowBoxConstraint(style: style, containing: containing, replaced: replaced, inline: inline))
        }
        let itemAlignment = parent.map { ReaderAlignmentFrame(style: style, parent: $0.format.itemAlignment) } ?? (isSection ? .root : .none)
        return BlockFormat(boxes: boxes, flow: ReaderParagraphFlow(style: style, scope: scope), scope: scope,
                           itemAlignment: itemAlignment, edges: ReaderParagraphEdges(style: style, parent: parent?.format.edges),
                           alignment: alignment, endAligned: endAligned, float: style.float, direction: direction,
                           left: left, right: right, textIndent: resolve(style.textIndent),
                           lineHeightMultiple: multiple, lineHeight: cssLineHeight, hyphenate: style.hyphens == .auto,
                           characterWrap: style.whiteSpace == .pre,
                           tabInterval: InlineStyling.tabInterval(font), preservesTabs: style.whiteSpace.preservesSpaces)
    }

    private func resolve(_ length: ComputedStyle.Length) -> CGFloat {
        let value = length.resolve(reference: Self.nominalColumn, viewport: Self.nominalViewport) ?? 0
        return value.isFinite ? min(max(value, -Self.maximumGap), Self.maximumGap) : 0
    }

    private static func width(_ border: ComputedStyle.Border) -> CGFloat {
        border.isVisible && border.width.isFinite ? min(border.width, 100) : 0
    }

    private func frameAttributes() -> Int {
        let index = frames.count - 1
        if let attributes = frames[index].attributes { return attributes }
        var context = InlineContext()
        context.language = frames[index].language
        let attributes = styling.attributes(frames[index].style, context)
        frames[index].attributes = attributes
        return attributes
    }

    // MARK: Paragraphs

    private func openParagraph(next: UInt32? = nil) {
        guard !paragraphOpen else { return }
        let frame = frames[frames.count - 1]
        let gapValue = min(gap.value, Self.maximumGap)
        gap = MarginGap()
        let dynamicGap = sizingGap
        sizingGap = ReaderParagraphGap()
        var paragraph = Paragraph(start: buffer.count, format: frame.format,
                                  indentsFirstLine: paragraphs.count == frame.firstParagraph,
                                  separatorAttributes: frameAttributes())
        paragraph.alignmentItem = frame.format.itemAlignment.paragraphItem()
        if let previous = paragraphs.indices.last {
            if !pendingPassageBoundary {
                let space = pendingPassageSpace
                let removesBreak = space.map { space in
                    space.segmentBreak && next.map { Self.removesSegmentBreak(between: space.before, and: $0) } == true
                } ?? false
                if recordsMap { map.layoutSeparator(at: buffer.count, copyText: space != nil && !removesBreak ? " " : "") }
            }
            buffer.append(CollectionOfOne(0x0A), attributes: paragraphs[previous].separatorAttributes)
            paragraph.start = buffer.count
            if previous == 0, paragraphs[0].isSpoken {
                // Hidden labels with a paragraph to themselves open the section and lie against
                // this one: the section's leading gap is above them.
                paragraphs[0].spacingBefore = gapValue
                paragraphs[0].sizingBefore = dynamicGap
            } else if isNote { paragraphs[previous].spacingAfter = 0.4 * state.bodyStyle.fontSize }
            else if pendingPageBreak && isSection {
                paragraph.spacingBefore = gapValue; paragraph.pageBreakBefore = true
                paragraph.sizingBefore = dynamicGap
            } else {
                paragraphs[previous].spacingAfter = gapValue
                paragraphs[previous].sizingAfter = dynamicGap
            }
        } else if !isNote {
            paragraph.spacingBefore = gapValue
            paragraph.sizingBefore = dynamicGap
        }
        pendingPageBreak = false
        pendingPassageBoundary = false
        pendingPassageSpace = nil
        if isSection {
            paragraph.keepsOwnNext = frames.contains { $0.keepWithNext }
            paragraph.keptTogetherBy = frames.firstIndex { $0.keepTogether }
            paragraph.keepWithNext = paragraph.keepsOwnNext || paragraph.keptTogetherBy != nil
        }
        paragraphs.append(paragraph)
        paragraphOpen = true
        lineStart = true
        lastWasCollapsedSpace = false
        lastScalar = 0x0A
        if let marker = pendingMarker { emitMarker(marker) }
    }

    private func closeParagraph() {
        if !pendingPassageBoundary, let space = pendingSpace {
            pendingPassageSpace = (space.segmentBreak, lastScalar)
        }
        pendingSpace = nil
        guard paragraphOpen else { return }
        if pendingBreaks.count > 1 {
            pendingBreaks.removeLast()
            flushBreaks()
        }
        pendingBreaks.removeAll()
        flushSpokenInline()
        paragraphOpen = false
        lineStart = true
        lastWasCollapsedSpace = false
        for index in isolates.indices { isolates[index].emitted = false }
    }

    private func finish() -> Output {
        closeParagraph()
        if !pendingSpoken.isEmpty { // Labels after the last content end its paragraph; with no content they are all there is.
            if !paragraphs.isEmpty { flushSpokenInline() }
            else if spokenLabelsStandAlone { flushSpokenParagraph() }
            else {
                openParagraph()
                flushSpokenInline()
                closeParagraph()
            }
        }
        // The section's trailing gap follows the flow's last paragraph, not a hidden label after it.
        if !isNote, let last = paragraphs.lastIndex(where: { !$0.isSpoken }) ?? paragraphs.indices.last {
            paragraphs[last].spacingAfter = min(gap.value, Self.maximumGap)
            paragraphs[last].sizingAfter = sizingGap
        }
        // A trailing empty paragraph (a lone `<br>`) cannot exist without a trailing break.
        while let last = paragraphs.last, last.start == buffer.count {
            paragraphs.removeLast()
            if !paragraphs.isEmpty { buffer.removeLast() }
        }
        for (id, _) in pendingAnchors where anchors[id] == nil { anchors[id] = buffer.count }
        pendingAnchors.removeAll()
        let length = buffer.count
        for (id, location) in anchors where location > length { anchors[id] = length }
        var styles: [(start: Int, style: NSParagraphStyle)] = []
        styles.reserveCapacity(paragraphs.count)
        for index in paragraphs.indices {
            let end = index + 1 < paragraphs.count ? paragraphs[index + 1].start : length
            if end > paragraphs[index].start { styles.append((paragraphs[index].start, paragraphStyle(paragraphs[index]))) }
        }
        let string = buffer.makeAttributedString(dictionaries: styling.dictionaries, paragraphs: styles)
        string.beginEditing()
        for index in paragraphs.indices where !isNote {
            let paragraph = paragraphs[index], start = paragraph.start
            let end = index + 1 < paragraphs.count ? paragraphs[index + 1].start : length
            guard end > start, paragraph.format.edges.isDynamic || paragraph.sizingBefore?.isDynamic == true
                || paragraph.sizingAfter?.isDynamic == true else { continue }
            let base = string.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle ?? .default
            string.addAttribute(.readerParagraphSizing, value: ReaderParagraphSizing(base: base,
                edges: paragraph.format.edges, firstLine: paragraph.indentsFirstLine, markerWidth: paragraph.markerWidth,
                before: paragraph.sizingBefore, after: paragraph.sizingAfter,
                nominalLeft: paragraph.format.left, nominalRight: paragraph.format.right,
                nominalIndent: paragraph.format.textIndent), range: NSRange(location: start, length: end - start))
        }
        for paragraph in paragraphs where paragraph.start < length && (paragraph.pageBreakBefore || paragraph.keepWithNext) {
            let first = NSRange(location: paragraph.start, length: 1)
            if paragraph.pageBreakBefore { string.addAttribute(.readerPageBreakBefore, value: true, range: first) }
            if paragraph.keepWithNext { string.addAttribute(.readerKeepWithNext, value: true, range: first) }
        }
        for index in paragraphs.indices where !paragraphs[index].format.boxes.isEmpty {
            let start = paragraphs[index].start
            let end = index + 1 < paragraphs.count ? paragraphs[index + 1].start : length
            guard end > start else { continue }
            string.addAttribute(.readerFlowBox,
                                value: ReaderFlowBoxParagraph(constraints: paragraphs[index].format.boxes,
                                    base: string.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle ?? .default),
                                range: NSRange(location: start, length: end - start))
        }
        for index in paragraphs.indices {
            let start = paragraphs[index].start
            let end = index + 1 < paragraphs.count ? paragraphs[index + 1].start : length
            if end > start { string.addAttribute(.readerParagraphFlow, value: paragraphs[index].format.flow,
                                                range: NSRange(location: start, length: end - start)) }
        }
        if isSection {
            adoptSpokenParagraph()
            ReaderAlignmentLayout.tag(string, paragraphs: paragraphs.map { ($0.start, $0.alignmentItem) })
        }
        for attribute in postAttributes where NSMaxRange(attribute.range) <= length {
            string.addAttribute(attribute.key, value: attribute.value, range: attribute.range)
        }
        // The longer range first: a heading inside another, and a hidden label, keep their own.
        for entry in headingRanges.sorted(by: { $0.range.length > $1.range.length }) where NSMaxRange(entry.range) <= length {
            string.addAttribute(.readerHeading, value: entry.heading, range: entry.range)
        }
        string.endEditing()
        map.length = length
        return Output(string: string, map: map, anchors: anchors)
    }

    private func paragraphStyle(_ paragraph: Paragraph) -> NSParagraphStyle {
        if paragraph.isSpoken {
            var key = ParagraphStyleKey()
            key.direction = paragraph.format.direction
            key.spacingBefore = max(0, paragraph.spacingBefore)
            key.maximumLineHeight = SpokenLabelAttachment.lineHeight
            return styling.paragraphStyle(key)
        }
        let format = paragraph.format
        var key = ParagraphStyleKey()
        if paragraph.blockUnit && paragraph.soleAttachment {
            // A lone block-level attachment is centred, or set to the side it floats to.
            switch format.float {
            case .left: key.alignment = .left
            case .right: key.alignment = .right
            case .none: key.alignment = format.endAligned ? format.alignment : .center
            }
        } else { key.alignment = format.alignment }
        if isNote, key.alignment == .justified { key.alignment = .natural }
        key.direction = format.direction
        var head = format.direction == .rightToLeft ? format.right : format.left
        var tail = format.direction == .rightToLeft ? format.left : format.right
        if isNote { head = 0; tail = 0 }
        head = max(0, head); tail = max(0, tail)
        if head + tail > Self.maximumIndent {
            let scale = Self.maximumIndent / (head + tail)
            head *= scale; tail *= scale
        }
        key.headIndent = head
        key.tailInset = tail
        let indent = paragraph.indentsFirstLine && !isNote ? format.textIndent : 0
        key.firstLineHeadIndent = max(0, head + indent)
        if let width = paragraph.markerWidth {
            let stop = max(head, width)
            key.firstLineHeadIndent = max(0, head - width)
            key.headIndent = stop
            key.tabStop = stop
        }
        key.spacingBefore = max(0, paragraph.spacingBefore)
        key.spacingAfter = max(0, paragraph.spacingAfter)
        if paragraph.hasUnit {
            key.minimumLineHeight = format.lineHeight ?? 0 // Attachments make their own lines taller.
        } else if let multiple = format.lineHeightMultiple {
            key.lineHeightMultiple = multiple
        } else if let points = format.lineHeight {
            key.minimumLineHeight = points; key.maximumLineHeight = points
        }
        key.hyphenate = format.hyphenate
        key.characterWrap = format.characterWrap
        // Every tab must have somewhere to go wherever its line starts, and a paragraph can hold
        // one whatever its box's `white-space`: an inline box that keeps its own, a string
        // marker, the tab between a fallback table row's cells. TextKit cannot place a tab that
        // has neither a stop after it nor an interval (`InlineStyling.tabInterval`), so every
        // paragraph has the interval of its box's `tab-size`.
        key.tabInterval = format.tabInterval
        // A marker's one stop is not always ahead of it: a box left in flow moves its first
        // line onto or past the stop (`ReaderFlowBoxLayout`), and TextKit measures a
        // right-to-left paragraph's stops short by its tail indent. A tab past the stop falls
        // on the next multiple of the marker's width instead, unless the item keeps its tabs.
        if !format.preservesTabs, let width = paragraph.markerWidth { key.tabInterval = InlineStyling.tabInterval(width) }
        guard let base = paragraph.factoryStyle, let style = base.mutableCopy() as? NSMutableParagraphStyle else {
            return styling.paragraphStyle(key)
        }
        // Rich content's own paragraph style: keep its alignment and inner spacing, add the box's.
        style.firstLineHeadIndent += key.firstLineHeadIndent
        style.headIndent += key.headIndent
        style.tailIndent = base.tailIndent <= 0 ? base.tailIndent - key.tailInset : base.tailIndent
        // Its stops are its own (a table row's are the system's, which end 336 points along),
        // and so is its interval where it has one, but in the paragraph a marker opens.
        let own = base.defaultTabInterval
        if paragraph.markerWidth != nil || !(own.isFinite && own >= 1) { style.defaultTabInterval = key.tabInterval }
        if !paragraph.continuation { style.paragraphSpacingBefore = key.spacingBefore }
        if !paragraph.hasNext { style.paragraphSpacing = key.spacingAfter }
        if style.baseWritingDirection == .natural { style.baseWritingDirection = key.direction }
        return style
    }

    // MARK: Lists

    private func startListItem(_ node: ContentNode, style: ComputedStyle, context: InlineContext) {
        let value: Int
        if let last = lists.indices.last {
            lists[last].advance(for: node); value = lists[last].value
        } else {
            orphanList.advance(for: node); value = orphanList.value
        }
        guard let text = ListMarker.text(style.listStyleType, value: value) else { return }
        var markerContext = InlineContext()
        markerContext.language = context.language
        let attributes = styling.attributes(style, markerContext)
        let outside = style.listStylePosition == .outside && flattenDepth == 0 && !isNote
        let suffix = ListMarker.hasSuffix(style.listStyleType)
        let width = outside ? styling.markerWidth(text + " ", style: style) : 0
        let marker = Marker(text: text, suffix: suffix, attributes: attributes, outside: outside, width: width,
                            frame: frames.count - 1)
        if flattenDepth > 0 { emitGenerated(Array((text + (suffix ? " " : "")).utf16), attributes: attributes) }
        else { pendingMarker = marker }
    }

    private func emitMarker(_ marker: Marker) {
        pendingMarker = nil
        flushAnchors()
        if marker.outside {
            buffer.append(Array(marker.text.utf16) + [0x09], attributes: marker.attributes)
            paragraphs[paragraphs.count - 1].markerWidth = marker.width
            lineStart = true
        } else {
            buffer.append(Array((marker.text + (marker.suffix ? " " : "")).utf16), attributes: marker.attributes)
            lineStart = false
            lastWasCollapsedSpace = marker.suffix
        }
        lastScalar = buffer.lastScalar
    }

    // MARK: Inline content

    private static func isCollapsible(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0C
    }

    private func appendText(_ node: ContentNode, style: ComputedStyle, context: InlineContext, attributes: Int) {
        let units = Array(node.text.utf16)
        let count = units.count
        guard count > 0 else { return }
        let spaceAttributes = style.wordSpacing != 0 && !style.isHidden
            ? styling.attributes(style, context, wordSpacing: true) : attributes
        var index = 0
        // HTML ignores a newline right after `<pre>`'s start tag.
        if style.whiteSpace.preservesNewlines, units[0] == 0x0A, node.indexInParent == 0,
           node.parent?.isHTML("pre") == true { index = 1 }
        switch style.whiteSpace {
        case .pre, .preWrap, .breakSpaces:
            while index < count {
                if units[index] == 0x0A || units[index] == 0x0D {
                    let pair = units[index] == 0x0D && index + 1 < count && units[index + 1] == 0x0A
                    forcedBreak(node: node, offset: index, length: pair ? 2 : 1, attributes: attributes)
                    index += pair ? 2 : 1
                } else {
                    var end = index + 1
                    while end < count, units[end] != 0x0A, units[end] != 0x0D { end += 1 }
                    emitText(units, index..<end, node: node, style: style, context: context, attributes: attributes,
                             spaceAttributes: spaceAttributes)
                    index = end
                }
            }
        case .normal, .nowrap, .preLine:
            let keepsNewlines = style.whiteSpace == .preLine
            while index < count {
                if Self.isCollapsible(units[index]) {
                    var end = index + 1, newline = units[index] == 0x0A || units[index] == 0x0D
                    while end < count, Self.isCollapsible(units[end]) {
                        newline = newline || units[end] == 0x0A || units[end] == 0x0D
                        end += 1
                    }
                    if keepsNewlines && newline {
                        var position = index
                        while position < end {
                            let unit = units[position]
                            if unit == 0x0A || (unit == 0x0D && (position + 1 == end || units[position + 1] != 0x0A)) {
                                forcedBreak(node: node, offset: position, length: 1, attributes: attributes)
                            }
                            position += 1
                        }
                    } else {
                        collapsibleSpace(node: node, offset: index, length: end - index,
                                         exact: end - index == 1 && units[index] == 0x20, segmentBreak: newline,
                                         attributes: spaceAttributes)
                    }
                    index = end
                } else {
                    // A word run continues through single spaces between words: one exact span.
                    var end = index + 1
                    while end < count {
                        let unit = units[end]
                        if unit == 0x20, end + 1 < count, !Self.isCollapsible(units[end + 1]) { end += 2; continue }
                        if Self.isCollapsible(unit) { break }
                        end += 1
                    }
                    emitText(units, index..<end, node: node, style: style, context: context, attributes: attributes,
                             spaceAttributes: spaceAttributes)
                    index = end
                }
            }
        }
    }

    private func emitText(_ units: [UInt16], _ range: Range<Int>, node: ContentNode, style: ComputedStyle,
                          context: InlineContext, attributes: Int, spaceAttributes: Int) {
        prepareForContent(next: Self.scalar(units, at: range.lowerBound))
        let location = buffer.count
        if collectingRubyBase, rubyBaseStart == nil { rubyBaseStart = location }
        let startsWord = Self.startsWord(after: lastScalar)
        let synthetic = style.isSmallCaps && state.request.fonts.needsSyntheticSmallCaps(for: style)
        let transformed = style.textTransform == .none ? nil : transform(units[range], style.textTransform, language: context.language.declared)
        let characters = transformed.map { $0[...] } ?? units[range]
        if synthetic {
            emitSyntheticSmallCaps(characters, style: style, context: context, attributes: attributes,
                                   spaceAttributes: spaceAttributes)
        } else if spaceAttributes == attributes {
            buffer.append(characters, attributes: attributes)
        } else {
            // `word-spacing` widens each space: those take their own attributes.
            var start = characters.startIndex
            for index in characters.indices where characters[index] == 0x20 {
                buffer.append(characters[start..<index], attributes: attributes)
                buffer.append(CollectionOfOne(0x20), attributes: spaceAttributes)
                start = index + 1
            }
            buffer.append(characters[start...], attributes: attributes)
        }
        buffer.replaceParagraphSeparators(from: location)
        let length = buffer.count - location
        mapAuthoredRun(units, range: range, node: node, location: location, length: length,
                       transform: style.textTransform, synthetic: synthetic, language: context.language.declared,
                       startsWord: startsWord)
        didEmitContent()
    }

    /// Small caps for a font without them, as browsers fake them: lower-case letters as capitals
    /// in a smaller size. The source map keeps their authored spelling separately.
    private func emitSyntheticSmallCaps(_ characters: ArraySlice<UInt16>, style: ComputedStyle, context: InlineContext,
                                        attributes: Int, spaceAttributes: Int) {
        var small = style
        small.isSmallCaps = false
        small.fontSize = style.fontSize * 0.7
        let smallAttributes = styling.attributes(small, context)
        let locale = Locale(identifier: context.language.declared ?? "en")
        for character in String(decoding: characters, as: UTF16.self) {
            if character.isLowercase {
                buffer.append(String(character).uppercased(with: locale).utf16, attributes: smallAttributes)
            } else {
                buffer.append(String(character).utf16, attributes: character == " " ? spaceAttributes : attributes)
            }
        }
    }

    /// Case transformations preserve order. Map equal-length portions exactly and only a
    /// length-changing grapheme (ß → SS, a ligature, a dotted i) as a unit, retaining the source
    /// spelling for Copy. Whole-string rendering still supplies contextual mappings such as
    /// Greek final sigma; isolated mappings here establish lengths, never replace those glyphs.
    private func mapAuthoredRun(_ units: [UInt16], range: Range<Int>, node: ContentNode, location: Int, length: Int,
                               transform: ComputedStyle.TextTransform, synthetic: Bool, language: String?, startsWord: Bool) {
        guard recordsMap else { return }
        func record(_ source: Range<Int>, rendered: Range<Int>, exact: Bool? = nil) {
            let original = units[source], shown = buffer.units[rendered]
            let authored = original.elementsEqual(shown) ? nil : String(decoding: original, as: UTF16.self)
            mapSpan(location: rendered.lowerBound, length: rendered.count, node: node, offset: source.lowerBound,
                    sourceLength: source.count, exact: exact ?? (rendered.count == source.count), authoredText: authored)
        }
        if (transform == .none && !synthetic) || (length == range.count && units[range].allSatisfy({ $0 < 0x80 })) {
            record(range, rendered: location..<location + length); return
        }
        let locale = Locale(identifier: language ?? "en")
        var pieces: [(source: Int, shown: Int)] = [], atWordStart = startsWord
        for character in String(decoding: units[range], as: UTF16.self) {
            let source = String(character)
            let transformed: String
            switch transform {
            case .none: transformed = source
            case .uppercase: transformed = source.uppercased(with: locale)
            case .lowercase: transformed = source.lowercased(with: locale)
            case .capitalize: transformed = atWordStart && character.isLetter ? source.uppercased(with: locale) : source
            }
            let shown = synthetic ? transformed.map { $0.isLowercase ? String($0).uppercased(with: locale) : String($0) }.joined() : transformed
            pieces.append((source.utf16.count, shown.utf16.count))
            atWordStart = character.unicodeScalars.last.map { Self.startsWord(after: $0.value) } ?? true
        }
        guard pieces.reduce(0, { $0 + $1.shown }) == length else {
            // A contextual mapping with a different expansion keeps a conservative whole-run
            // source range; its copied spelling is still authored rather than inferred.
            record(range, rendered: location..<location + length, exact: false); return
        }
        var source = range.lowerBound, shown = location, exactSource = source, exactShown = shown
        for piece in pieces {
            if piece.source != piece.shown {
                if source > exactSource { record(exactSource..<source, rendered: exactShown..<shown) }
                record(source..<source + piece.source, rendered: shown..<shown + piece.shown)
                exactSource = source + piece.source; exactShown = shown + piece.shown
            }
            source += piece.source; shown += piece.shown
        }
        if source > exactSource { record(exactSource..<source, rendered: exactShown..<shown) }
    }

    /// Generated text that reads as content (`<q>` marks, inline markers): it ends a line start.
    private func emitGenerated(_ units: [UInt16], attributes: Int) {
        guard !units.isEmpty else { return }
        prepareForContent(next: Self.scalar(units, at: 0))
        buffer.append(units, attributes: attributes)
        didEmitContent()
    }

    private func mapSpan(location: Int, length: Int, node: ContentNode, offset: Int, sourceLength: Int, exact: Bool, authoredText: String? = nil) {
        guard recordsMap else { return }
        map.append(TextMap.Span(location: location, length: length, node: node.order, offset: offset,
                                sourceLength: sourceLength, isExact: exact, authoredText: authoredText))
    }

    private func prepareForContent(next: UInt32) {
        openParagraph(next: next)
        flushBreaks()
        flushSpace(next: next)
        flushSpokenInline()
        for index in isolates.indices where !isolates[index].emitted {
            buffer.append(isolates[index].opener, attributes: isolates[index].attributes)
            isolates[index].emitted = true
        }
        flushAnchors()
        // A heading's text begins with its own first content: after the break, the marker, the
        // white space and the hidden labels that were waiting for a line.
        for index in openHeadings.indices where openHeadings[index].start == nil { openHeadings[index].start = buffer.count }
    }

    private func didEmitContent() {
        lineStart = false
        lastWasCollapsedSpace = false
        lastScalar = buffer.lastScalar
        paragraphs[paragraphs.count - 1].hasText = true
    }

    /// A collapsible whitespace run: at most one space survives, emitted before the next content
    /// on the line. A single U+0020 maps exactly, so a paragraph's words share one span.
    private func collapsibleSpace(node: ContentNode?, offset: Int, length: Int, exact: Bool, segmentBreak: Bool,
                                  attributes: Int) {
        if !paragraphOpen, !pendingPassageBoundary {
            pendingPassageSpace = (segmentBreak || (pendingPassageSpace?.segmentBreak ?? false), pendingPassageSpace?.before ?? lastScalar)
        }
        // After a sized inline box the space opens no paragraph; the box keeps it for what follows.
        if !paragraphOpen, let last = lastInlineBox, last.depth == frames.count, last.paragraphs == paragraphs.count {
            last.box.trailingSpace = spaceAdvance(frames[frames.count - 1])
        }
        guard paragraphOpen, !lineStart, pendingBreaks.isEmpty, !lastWasCollapsedSpace else { return }
        if pendingSpace == nil {
            pendingSpace = PendingSpace(node: node?.order, offset: offset, length: length, exact: exact,
                                        attributes: attributes, segmentBreak: segmentBreak, anchorSerial: anchorSerial)
        } else if segmentBreak {
            pendingSpace?.segmentBreak = true
        }
    }

    /// A block box inside a flattened table cell separates its text like a space.
    private func softBoundary() {
        guard let attributes = buffer.lastAttributes else { return }
        collapsibleSpace(node: nil, offset: 0, length: 0, exact: false, segmentBreak: false, attributes: attributes)
    }

    private func flushSpace(next: UInt32) {
        guard let space = pendingSpace else { return }
        pendingSpace = nil
        if space.segmentBreak, Self.removesSegmentBreak(between: lastScalar, and: next) { return }
        flushSpokenInline(before: space.anchorSerial)
        flushAnchors(before: space.anchorSerial)
        let location = buffer.count
        buffer.append(CollectionOfOne(0x20), attributes: space.attributes)
        if recordsMap, let node = space.node {
            map.append(TextMap.Span(location: location, length: 1, node: node, offset: space.offset,
                                    sourceLength: space.length, isExact: space.exact))
        }
        lastWasCollapsedSpace = true
        lastScalar = 0x20
    }

    private func forcedBreak(node: ContentNode?, offset: Int, length: Int, attributes: Int) {
        openParagraph()
        pendingSpace = nil
        lastWasCollapsedSpace = false
        pendingBreaks.append(PendingBreak(node: node?.order, offset: offset, length: length, attributes: attributes,
                                          anchorSerial: anchorSerial))
        lineStart = true
    }

    private func lineBreak(attributes: Int) {
        forcedBreak(node: nil, offset: 0, length: 0, attributes: attributes)
    }

    private func flushBreaks() {
        guard !pendingBreaks.isEmpty else { return }
        for pending in pendingBreaks {
            flushSpokenInline(before: pending.anchorSerial)
            flushAnchors(before: pending.anchorSerial)
            let location = buffer.count
            buffer.append(CollectionOfOne(0x2028), attributes: pending.attributes)
            if recordsMap, let node = pending.node {
                map.append(TextMap.Span(location: location, length: 1, node: node, offset: pending.offset,
                                        sourceLength: pending.length, isExact: pending.length == 1, authoredText: "\n"))
            }
        }
        pendingBreaks.removeAll()
        lastScalar = 0x2028
    }

    private func wordBreak(attributes: Int) {
        guard paragraphOpen, !lineStart, pendingBreaks.isEmpty else { return }
        flushSpace(next: 0x200B)
        buffer.append(CollectionOfOne(0x200B), attributes: attributes)
        lastScalar = 0x200B
    }

    /// The tab between a fallback table row's cells.
    private func cellSeparator() {
        openParagraph()
        pendingSpace = nil
        flushBreaks()
        buffer.append(CollectionOfOne(0x09), attributes: buffer.lastAttributes ?? frameAttributes())
        lineStart = true
        lastWasCollapsedSpace = false
        lastScalar = 0x09
    }

    private func pendAnchor(_ id: String) {
        pendingAnchors.append((id, anchorSerial))
        anchorSerial += 1
    }

    /// Anchors the pending ids (those registered before `serial`, when given) at the next character.
    private func flushAnchors(before serial: Int = .max) {
        guard let first = pendingAnchors.first, first.serial < serial else { return }
        let count = pendingAnchors.firstIndex { $0.serial >= serial } ?? pendingAnchors.count
        for (id, _) in pendingAnchors.prefix(count) where anchors[id] == nil { anchors[id] = buffer.count }
        pendingAnchors.removeFirst(count)
    }

    // MARK: Hidden labels

    /// Whether a hidden label with no line to stand in gets a paragraph of its own. A table
    /// cell's and a note's blocks are plain paragraphs: there it opens an ordinary one.
    private var spokenLabelsStandAlone: Bool { isSection && flattenDepth == 0 }

    /// What a visually hidden box keeps for assistive technology, placed where a browser reads
    /// it. Nothing for a box `aria-hidden` hides from that too, or one with no words.
    private func speak(_ node: ContentNode, style: ComputedStyle, context: InlineContext) {
        guard style.isSpokenOnlyPositionedBox, node.attribute("aria-hidden") != "true" else { return }
        let segments = spokenSegments(of: node, style: style)
        guard !segments.isEmpty else { return }
        var link = context.link
        if link == nil, node.isHTML("a"),
           let href = node.attribute("href") ?? node.attribute("href", namespace: ContentNamespace.xlink) {
            link = self.link(for: node, href: href)
        }
        // Ids inside the box were registered before this serial; white space after it has a later one.
        anchorSerial += 1
        let serial = anchorSerial
        anchorSerial += 1
        for segment in segments {
            pendingSpoken.append(SpokenLabel(attachment: SpokenLabelAttachment(text: segment.text, language: segment.language),
                                             owner: segment.owner, link: link?.url, serial: serial))
        }
    }

    private struct SpokenSegment {
        var text: String
        var language: String?
        /// The element whose text this is, or the first text node of a run that shares its
        /// element with other blocks.
        var owner: ContentNode
    }

    /// The words of a hidden box, one entry for each block of them: text nodes with their white
    /// space collapsed, and the alternative text of what stands for text. Not what is hidden
    /// from assistive technology too (`display: none`, `visibility: hidden`, `aria-hidden`),
    /// nor ruby annotations or notes shown elsewhere.
    private func spokenSegments(of root: ContentNode, style: ComputedStyle) -> [SpokenSegment] {
        var segments: [SpokenSegment] = []
        func collect(_ container: ContentNode, _ style: ComputedStyle, _ language: String?, _ depth: Int) {
            var words = ""
            var first: ContentNode?
            let before = segments.count
            func cut() {
                let text = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                words = ""
                defer { first = nil }
                guard !text.isEmpty, let first else { return }
                // The box's first words stand for the box; a later run, after blocks of its own, for itself.
                segments.append(SpokenSegment(text: text, language: language, owner: segments.count == before ? container : first))
            }
            func add(_ text: String, from node: ContentNode) {
                guard !text.isEmpty else { return }
                if first == nil { first = node }
                words += text
            }
            func inline(_ node: ContentNode, _ style: ComputedStyle, _ depth: Int) {
                for child in node.children {
                    if child.isText {
                        if !style.isHidden { add(child.text, from: child) }
                        continue
                    }
                    guard child.isElement, child.attribute("aria-hidden") != "true",
                          !(child.isHTML && (ContentSemantics.neverRendered.contains(child.name) || child.name == "rt" || child.name == "rp")),
                          state.noteKind(child) == nil else { continue }
                    let childStyle = state.style(child, style)
                    guard childStyle.display != .none else { continue }
                    if let text = Self.spokenEquivalent(of: child) {
                        if !childStyle.isHidden { add(" \(text) ", from: child) }
                    } else if depth >= Self.maximumSpokenDepth {
                        if !childStyle.isHidden { add(" \(child.textContent) ", from: child) }
                    } else if childStyle.display.isBlockLevel {
                        cut()
                        collect(child, childStyle, child.language ?? language, depth + 1)
                    } else {
                        inline(child, childStyle, depth + 1)
                    }
                }
            }
            inline(container, style, depth)
            cut()
        }
        collect(root, style, root.language, 0)
        return segments
    }

    /// Documents may nest 200 deep; a hidden label's blocks are read as plain text below this.
    private static let maximumSpokenDepth = 24

    /// The text of an element that stands for text or for nothing, nil for one read by its content.
    private static func spokenEquivalent(of element: ContentNode) -> String? {
        if element.isHTML {
            switch element.name {
            case "img", "input": return element.attribute("alt") ?? ""
            case "br": return " "
            case "hr", "audio", "video", "object", "embed", "iframe", "canvas", "select", "textarea": return ""
            default: return nil
            }
        }
        if element.name == "svg", element.namespace == ContentNamespace.svg || element.namespace.isEmpty {
            return element.attribute("aria-label") ?? element.children.first { $0.name == "title" }?.textContent ?? ""
        }
        if element.name == "math", element.namespace == ContentNamespace.mathML || element.namespace.isEmpty {
            return element.attribute("alttext") ?? element.textContent
        }
        return nil
    }

    private struct SpokenLabel {
        let attachment: SpokenLabelAttachment
        let owner: ContentNode
        let link: URL?
        let serial: Int
    }

    /// A font too small to give a line any height: the label's character must not make its line
    /// taller, and UIKit keeps a line as tall as its font's descender whatever the paragraph allows.
    private func spokenLabelAttributes() -> Int {
        if let spokenAttributes { return spokenAttributes }
        let attributes = styling.intern([.font: PlatformFont.systemFont(ofSize: SpokenLabelAttachment.lineHeight)])
        spokenAttributes = attributes
        return attributes
    }

    /// Pending labels (those met before `serial`, when given) at the end of the text so far: in
    /// the open paragraph, or closing the last one. They are not content of the line: its white
    /// space collapses across them, as across any box taken out of the flow.
    private func flushSpokenInline(before serial: Int = .max) {
        guard let first = pendingSpoken.first, first.serial < serial, !paragraphs.isEmpty else { return }
        let count = pendingSpoken.firstIndex { $0.serial >= serial } ?? pendingSpoken.count
        let attributes = spokenLabelAttributes()
        for label in pendingSpoken.prefix(count) { appendSpoken(label, attributes: attributes) }
        pendingSpoken.removeFirst(count)
    }

    /// Pending labels in a paragraph of their own, for a section that opens with them before
    /// content that cannot hold them, or holds nothing else. It is the section's first
    /// paragraph, has no height and is kept with the one after it, which is spaced, indented
    /// and marked as the section's first (`openParagraph`).
    private func flushSpokenParagraph() {
        guard !pendingSpoken.isEmpty, paragraphs.isEmpty else { return }
        let attributes = spokenLabelAttributes()
        var paragraph = Paragraph(start: buffer.count, format: frames[frames.count - 1].format, indentsFirstLine: false,
                                  separatorAttributes: attributes)
        paragraph.isSpoken = true
        paragraph.keepsOwnNext = true
        paragraph.keepWithNext = true
        // Nothing comes before it for a forced break to part it from.
        pendingPageBreak = false
        // The boxes that open here have not begun: their first paragraph is still to come.
        for frame in frames.indices where frames[frame].firstParagraph == 0 { frames[frame].firstParagraph = 1 }
        paragraphs.append(paragraph)
        for label in pendingSpoken { appendSpoken(label, attributes: attributes) }
        pendingSpoken.removeAll()
    }

    /// Such a paragraph is no item of a flex or grid container, but when the section opens
    /// inside one it lies among the container's paragraphs, which are found as the consecutive
    /// ones tagged with it (`ReaderAlignmentLayout.boxes`): it takes the item of the paragraph
    /// after it.
    private func adoptSpokenParagraph() {
        guard paragraphs.count > 1, paragraphs[0].isSpoken, let item = paragraphs[1].alignmentItem else { return }
        for container in paragraphs[0].format.itemAlignment.containers {
            if let found = item.inside(container) { paragraphs[0].alignmentItem = found; return }
        }
    }

    private func appendSpoken(_ label: SpokenLabel, attributes: Int) {
        flushAnchors(before: label.serial)
        var dictionary = styling.dictionaries[attributes] as NSDictionary as? [NSAttributedString.Key: Any] ?? [:]
        dictionary[.attachment] = label.attachment
        dictionary[.link] = nil
        let location = buffer.count
        buffer.append(unit: NSAttributedString(string: "\u{FFFC}", attributes: dictionary), link: label.link)
        // An element is a unit: every position inside it is the label. A text node stands for its run.
        mapSpan(location: location, length: 1, node: label.owner, offset: 0,
                sourceLength: label.owner.isText ? label.owner.utf16Length : 0, exact: false)
        // A hidden heading is a heading, and so are hidden words inside a shown one.
        if let heading = heading(enclosing: label.owner) {
            headingRanges.append((NSRange(location: location, length: 1), heading))
        }
    }

    // MARK: Headings

    private func heading(for node: ContentNode) -> ReaderHeading? {
        if let known = headings[node.order] { return known }
        guard let level = ContentSemantics.headingLevel(node) else { return nil }
        let heading = ReaderHeading(level: level)
        headings[node.order] = heading
        return heading
    }

    /// The heading `node` is, or the nearest one it is inside.
    private func heading(enclosing node: ContentNode) -> ReaderHeading? {
        var current: ContentNode? = node
        while let candidate = current {
            if let heading = heading(for: candidate) { return heading }
            current = candidate.parent
        }
        return nil
    }

    /// Bidi isolation for an inline element's `dir`, `<bdi>` and `<bdo>`, as generated isolate
    /// (and override) characters around its content.
    private func isolation(_ node: ContentNode, style: ComputedStyle, context: InlineContext) -> Isolate? {
        let direction = node.attribute("dir")?.lowercased()
        let opener: [UInt16], closer: [UInt16]
        if node.name == "bdo" {
            let rtl = direction == "rtl"
            opener = [rtl ? 0x2067 : 0x2066, rtl ? 0x202E : 0x202D]
            closer = [0x202C, 0x2069]
        } else {
            switch direction {
            case "rtl": opener = [0x2067]
            case "ltr": opener = [0x2066]
            case "auto": opener = [0x2068]
            default:
                guard node.name == "bdi" else { return nil }
                opener = [0x2068]
            }
            closer = [0x2069]
        }
        return Isolate(opener: opener, closer: closer, attributes: styling.attributes(style, context))
    }

    /// `language` is the one the content declares: case mapping is not the package's to choose.
    private func transform(_ units: ArraySlice<UInt16>, _ transform: ComputedStyle.TextTransform,
                           language: String?) -> [UInt16] {
        let string = String(decoding: units, as: UTF16.self)
        let locale = Locale(identifier: language ?? "en")
        switch transform {
        case .none: return Array(units)
        case .uppercase: return Array(string.uppercased(with: locale).utf16)
        case .lowercase: return Array(string.lowercased(with: locale).utf16)
        case .capitalize:
            var result = "", atWordStart = Self.startsWord(after: lastScalar)
            for character in string {
                if atWordStart, character.isLetter {
                    result += String(character).uppercased(with: locale)
                } else {
                    result.append(character)
                }
                atWordStart = character.unicodeScalars.last.map { Self.startsWord(after: $0.value) } ?? true
            }
            return Array(result.utf16)
        }
    }

    private static func startsWord(after scalar: UInt32) -> Bool {
        guard let value = Unicode.Scalar(scalar) else { return true }
        if value == "'" || value == "\u{2019}" { return false }
        let properties = value.properties
        return !(properties.isAlphabetic || properties.numericType != nil
                 || properties.generalCategory == .nonspacingMark || properties.generalCategory == .spacingMark)
    }

    private static func scalar(_ units: [UInt16], at index: Int) -> UInt32 {
        let unit = units[index]
        if UTF16.isLeadSurrogate(unit), index + 1 < units.count, UTF16.isTrailSurrogate(units[index + 1]) {
            return 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[index + 1]) - 0xDC00)
        }
        return UInt32(unit)
    }

    /// CSS Text 3 segment-break transformation: a break between two East Asian wide (or
    /// fullwidth, halfwidth) characters, neither Hangul, or next to U+200B, disappears.
    private static func removesSegmentBreak(between before: UInt32, and after: UInt32) -> Bool {
        if before == 0x200B || after == 0x200B { return true }
        return isWideNonHangul(before) && isWideNonHangul(after)
    }

    private static func isWideNonHangul(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x2E80...0x303E, 0x3041...0x30FF, 0x3190...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFF61...0xFF9F, 0xFFE0...0xFFE6, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            true
        default: false
        }
    }

    // MARK: Rich content

    /// Inserts rich content as a unit: one non-exact span on the element. Block-level content gets
    /// its own paragraphs (one per paragraph of the result) and the element's box.
    private func insert(_ result: NSAttributedString, for node: ContentNode, style: ComputedStyle, context: InlineContext) {
        let result = Self.trimmingParagraphBreaks(result)
        guard result.length > 0 else { skip(node, registered: true); return }
        let block = (style.display.isBlockLevel || style.requiresFlowBox) && flattenDepth == 0
        let utf16 = Array(result.string.utf16)
        // A table's rows and a float's or a positioned box's content are found at the start of
        // their paragraphs: a hidden label waiting here ends the paragraph before instead, or
        // stands alone when the section has none.
        if block, !pendingSpoken.isEmpty, spokenLabelsStandAlone, !paragraphOpen,
           style.requiresFlowBox || utf16.contains(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0x2029 })
            || result.attribute(.attachment, at: 0, effectiveRange: nil) is TableRowAttachment {
            if paragraphs.isEmpty { flushSpokenParagraph() } else { flushSpokenInline() }
        }
        if block { enterBlock(node, style: style, language: context.language) }
        // Labels that open this content's own paragraph are not what it is measured by.
        let waiting = block && !paragraphOpen ? pendingSpoken.count : 0
        prepareForContent(next: Self.scalar(utf16, at: 0))
        let leadingLabels = waiting - (block && waiting > 0 ? pendingSpoken.count : 0)
        let location = buffer.count
        if collectingRubyBase, rubyBaseStart == nil { rubyBaseStart = location }
        claimSubtree(of: node, at: location)
        buffer.append(unit: result, link: style.isHidden ? nil : context.link?.url)
        if isSection {
            result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length)) { value, range, _ in
                if let row = value as? TableRowAttachment { row.table.sourceRowOffsets[row.row] = location + range.location }
            }
        }
        if recordsMap {
            map.append(TextMap.Span(location: location, length: result.length, node: node.order, offset: 0,
                                    sourceLength: 0, isExact: false))
        }
        var subStart = paragraphs[paragraphs.count - 1].start + leadingLabels
        func describe(end: Int) {
            let last = paragraphs.count - 1
            paragraphs[last].hasUnit = true
            guard block else { return }
            paragraphs[last].blockUnit = true
            paragraphs[last].indentsFirstLine = false // `text-indent` indents lines of text, not a block's content.
            let length = end - subStart
            if length > 0, subStart >= location {
                paragraphs[last].soleAttachment = length == 1 && result.attribute(.attachment, at: subStart - location, effectiveRange: nil) != nil
                paragraphs[last].factoryStyle = result.attribute(.paragraphStyle, at: subStart - location, effectiveRange: nil) as? NSParagraphStyle
            }
        }
        for (offset, unit) in utf16.enumerated() where unit == 0x0A || unit == 0x0D || unit == 0x2029 {
            describe(end: location + offset)
            let last = paragraphs.count - 1
            paragraphs[last].hasNext = true
            var next = paragraphs[last]
            next.start = location + offset + 1
            next.indentsFirstLine = false; next.spacingBefore = 0; next.spacingAfter = 0
            next.sizingBefore = nil; next.sizingAfter = nil
            next.pageBreakBefore = false; next.markerWidth = nil; next.hasNext = false; next.continuation = true
            next.soleAttachment = false; next.factoryStyle = nil; next.hasText = false
            paragraphs.append(next)
            subStart = next.start
        }
        describe(end: buffer.count)
        if block {
            // The break after block content continues it (a table's rows set a 1-pt font so each
            // row's line is its attachment's height), without repeating the attachment.
            var trailing = result.attributes(at: result.length - 1, effectiveRange: nil)
            trailing[.attachment] = nil
            trailing[.link] = nil
            paragraphs[paragraphs.count - 1].separatorAttributes = styling.intern(trailing)
        }
        lineStart = false
        lastWasCollapsedSpace = false
        lastScalar = 0xFFFC
        if block { exitBlock() }
    }

    /// Rich content must not begin or end with a paragraph break; one that does is trimmed.
    private static func trimmingParagraphBreaks(_ string: NSAttributedString) -> NSAttributedString {
        let units = string.string.utf16
        func isBreak(_ unit: UInt16) -> Bool { unit == 0x0A || unit == 0x0D || unit == 0x2029 }
        let leading = units.prefix { isBreak($0) }.count
        guard leading < string.length else { return NSAttributedString() }
        let trailing = units.reversed().prefix { isBreak($0) }.count
        guard leading > 0 || trailing > 0 else { return string }
        return string.attributedSubstring(from: NSRange(location: leading, length: string.length - leading - trailing))
    }

    /// Ids inside a unit point at it, and notes inside it are captured.
    private func claimSubtree(of node: ContentNode, at location: Int) {
        guard isSection, node.order < node.subtreeEnd else { return }
        for index in (node.order + 1)...node.subtreeEnd {
            let element = document.nodes[index]
            guard element.isElement else { continue }
            if let id = element.id, anchors[id] == nil { anchors[id] = location }
            if state.noteKind(element) != nil { state.captureNote(element) }
        }
    }

    // MARK: Ruby

    /// An `rt` (or `rtc`) annotates the base text since the previous annotation: the base keeps
    /// its characters and map; the annotation is a `CTRubyAnnotation` and is not in the text.
    private func annotateRuby(_ node: ContentNode, parentStyle: ComputedStyle) {
        let style = state.style(node, parentStyle)
        register(node)
        skip(node, registered: true)
        defer { rubyBaseStart = nil }
        guard style.display != .none, let start = rubyBaseStart, buffer.count > start else { return }
        let text = Self.annotationText(node).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return }
        let attributes = [kCTRubyAnnotationSizeFactorAttributeName as String: 0.5] as CFDictionary
        let annotation = CTRubyAnnotationCreateWithAttributes(.auto, .auto, .before, text as CFString, attributes)
        postAttributes.append((NSRange(location: start, length: buffer.count - start), InlineStyling.rubyKey, annotation))
    }

    private static func annotationText(_ node: ContentNode) -> String {
        if node.isText { return node.text }
        if node.isHTML("rp") { return "" }
        return node.children.map(annotationText).joined()
    }
}

// MARK: - Builder records

private struct MarginGap {
    private var fixed: CGFloat = 0, positive: CGFloat = 0, negative: CGFloat = 0
    /// A margin adjoining the others: they collapse.
    mutating func add(_ margin: CGFloat) {
        if margin > 0 { positive = max(positive, margin) } else { negative = min(negative, margin) }
    }
    /// Padding or border: the margins so far are fixed, and later ones collapse among themselves.
    mutating func seal(_ inset: CGFloat) {
        fixed += positive + negative + inset
        positive = 0; negative = 0
    }
    var value: CGFloat { max(0, fixed + positive + negative) }
}

/// A block box's paragraph formatting, resolved when the box opens.
private struct BlockFormat {
    var boxes: [ReaderFlowBoxConstraint]
    var flow: ReaderParagraphFlow
    var scope: ReaderBoxScope
    /// The box's place among flex and grid containers (`BoxAlignment.swift`).
    var itemAlignment: ReaderAlignmentFrame
    var edges: ReaderParagraphEdges
    var alignment: NSTextAlignment
    var endAligned: Bool
    var float: ComputedStyle.Float
    var direction: NSWritingDirection
    /// Physical content edges from the column's, accumulated over ancestors.
    var left: CGFloat
    var right: CGFloat
    var textIndent: CGFloat
    /// CSS's multiple of the font size, as a multiple of the font's own line height.
    var lineHeightMultiple: CGFloat?
    /// The CSS line height in points.
    var lineHeight: CGFloat?
    var hyphenate: Bool
    var characterWrap: Bool
    /// `tab-size` in points: eight spaces of the box's font, and never zero.
    var tabInterval: CGFloat
    /// `white-space` keeps the box's own tabs (`pre`, `pre-wrap`, `break-spaces`).
    var preservesTabs: Bool
}

private struct BlockFrame {
    let style: ComputedStyle
    let format: BlockFormat
    /// A heading, a term or `break-after: avoid`: its paragraphs keep with the next.
    let keepWithNext: Bool
    /// `break-inside: avoid`.
    let keepTogether: Bool
    /// `paragraphs.count` when the box opened: its first paragraph gets `text-indent`. Later
    /// when a hidden label's paragraph stands there.
    var firstParagraph: Int
    var attributes: Int?
    /// Set for a sized inline box: its place on its parent's line.
    var inlineBox: ReaderInlineBox?
    let language: InlineLanguage

    init(style: ComputedStyle, format: BlockFormat, keepWithNext: Bool, keepTogether: Bool = false,
         firstParagraph: Int, language: InlineLanguage) {
        self.style = style; self.format = format; self.keepWithNext = keepWithNext; self.keepTogether = keepTogether
        self.firstParagraph = firstParagraph; self.language = language
    }
}

private struct Paragraph {
    var start: Int
    var format: BlockFormat
    var indentsFirstLine: Bool
    var separatorAttributes: Int
    var spacingBefore: CGFloat = 0
    var spacingAfter: CGFloat = 0
    var sizingBefore: ReaderParagraphGap?
    var sizingAfter: ReaderParagraphGap?
    var pageBreakBefore = false
    var keepWithNext = false
    /// Kept with the next for its own sake (a heading), not only by an enclosing `break-inside: avoid`.
    var keepsOwnNext = false
    /// The outermost enclosing `break-inside: avoid` frame.
    var keptTogetherBy: Int?
    var hasText = false
    var hasUnit = false
    /// One paragraph of block-level rich content.
    var blockUnit = false
    var soleAttachment = false
    var factoryStyle: NSParagraphStyle?
    /// A later paragraph of the same rich content, or one with more after it.
    var continuation = false
    var hasNext = false
    /// An outside list marker's width, which hangs before the content.
    var markerWidth: CGFloat?
    /// The flex or grid item holding the paragraph.
    var alignmentItem: ReaderAlignmentItem?
    /// Hidden labels' own paragraph, of no height and outside the flow (`flushSpokenParagraph`).
    var isSpoken = false

    init(start: Int, format: BlockFormat, indentsFirstLine: Bool, separatorAttributes: Int) {
        self.start = start; self.format = format; self.indentsFirstLine = indentsFirstLine
        self.separatorAttributes = separatorAttributes
    }
}

private struct PendingSpace {
    /// Source text node, nil for a generated separator.
    var node: Int?
    var offset: Int
    var length: Int
    var exact: Bool
    var attributes: Int
    var segmentBreak: Bool
    /// Anchors registered before the space point at it; later ones at what follows.
    var anchorSerial: Int
}

private struct PendingBreak {
    var node: Int?
    var offset: Int
    var length: Int
    var attributes: Int
    /// As for a pending space.
    var anchorSerial: Int
}

private struct Isolate {
    let opener: [UInt16]
    let closer: [UInt16]
    let attributes: Int
    /// Opened in the current paragraph; a paragraph break ends every isolate.
    var emitted = false
}

private struct Marker {
    let text: String
    let suffix: Bool
    let attributes: Int
    let outside: Bool
    let width: CGFloat
    /// The list item's block frame.
    let frame: Int
}

private struct ListCounter {
    var value: Int
    let step: Int

    init(value: Int, step: Int) { self.value = value; self.step = step }

    /// `ol`'s `start` and `reversed`; `ul`, `menu` and `dir` count from 1.
    init(list: ContentNode) {
        let reversed = list.name == "ol" && list.attribute("reversed") != nil
        let start = list.name == "ol"
            ? list.attribute("start").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map(Self.clamp) : nil
        let items = list.elementChildren.reduce(0) { $0 + ($1.isHTML("li") ? 1 : 0) }
        step = reversed ? -1 : 1
        value = (start ?? (reversed ? items : 1)) - step
    }

    /// The next item's value: its own `value`, else one step on.
    mutating func advance(for item: ContentNode) {
        if item.isHTML("li"), let explicit = item.attribute("value").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            value = Self.clamp(explicit)
        } else {
            value = Self.clamp(value + step)
        }
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, -1_000_000_000), 1_000_000_000) }
}
