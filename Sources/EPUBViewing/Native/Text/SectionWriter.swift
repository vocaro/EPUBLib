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
/// - Lengths a CSS percentage or viewport unit gives resolve against a nominal 600-pt column
///   (and an 800-pt viewport height), because a section's attributes cannot depend on the
///   column it is laid out in. Total horizontal indentation is capped at a third of that column
///   so deep nesting cannot squeeze a phone column to nothing.
/// - Whitespace follows CSS Text 3 per `white-space`: collapsible runs collapse across inline
///   boundaries, a run at a line's start or end is removed, and a segment break between two East
///   Asian wide characters disappears. A single trailing forced break in a block makes no line.
/// - Every rendered character from the DOM is mapped (`TextMap`); generated text is not.
final class SectionWriter {
    enum Mode: Equatable {
        /// The spine item itself: text map, anchors, page breaks.
        case section
        /// A table cell or caption for a rich-content factory: no map.
        case detached
        /// A note's content for showing in place: no map, blocks flattened to plain paragraphs.
        case note(id: String)
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
    private var isNote: Bool { if case .note = mode { true } else { false } }

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
    private var pendingPageBreak = false
    private var pendingMarker: Marker?
    private var lists: [ListCounter] = []
    private var orphanList = ListCounter(value: 0, step: 1)
    /// Inside a fallback table row's cells: block boxes render inline.
    private var flattenDepth = 0

    // Line state.
    private var paragraphOpen = false
    private var lineStart = true
    private var pendingSpace: PendingSpace?
    private var lastWasCollapsedSpace = false
    private var pendingBreaks: [PendingBreak] = []
    private var lastScalar: UInt32 = 0x0A
    private var isolates: [Isolate] = []
    private var collectingRubyBase = false
    private var rubyBaseStart: Int?

    private var stack: [Entry] = []
    /// `ResourceReference.resolve` by href (nil: not in the archive); books repeat their links.
    private var resolvedLinks: [String: String?] = [:]

    init(state: SectionBuildState, mode: Mode) {
        self.state = state; self.mode = mode
        document = state.document; styling = state.styling
    }

    // MARK: Entry points

    func renderSection() -> Output {
        frames = [BlockFrame(style: state.initialStyle, format: blockFormat(state.initialStyle, node: nil, parent: nil),
                             keepWithNext: false, firstParagraph: 0, language: state.defaultLanguage)]
        var context = InlineContext()
        context.language = state.defaultLanguage
        walk(Entry(node: document.root, children: [document.root], style: state.initialStyle, context: context))
        return finish()
    }

    func renderContent(of element: ContentNode, style: ComputedStyle) -> NSAttributedString {
        let language = Self.inheritedLanguage(of: element) ?? state.defaultLanguage
        frames = [BlockFrame(style: style, format: blockFormat(style, node: element, parent: nil),
                             keepWithNext: false, firstParagraph: 0, language: language)]
        var context = InlineContext()
        context.language = language
        walk(Entry(node: element, children: element.children, style: style, context: context))
        return finish().string
    }

    func renderNote(_ element: ContentNode) -> NSAttributedString {
        var style = state.style(element, state.bodyStyle)
        style.display = .block
        style.isHidden = false
        style.fontSize = state.bodyStyle.fontSize
        let language = Self.inheritedLanguage(of: element) ?? state.defaultLanguage
        frames = [BlockFrame(style: style, format: blockFormat(style, node: element, parent: nil),
                             keepWithNext: false, firstParagraph: 0, language: language)]
        var context = InlineContext()
        context.language = language
        walk(Entry(node: element, children: element.children, style: style, context: context))
        return finish().string
    }

    private static func inheritedLanguage(of element: ContentNode) -> String? {
        var node: ContentNode? = element
        while let current = node {
            if let language = current.language { return language.isEmpty ? nil : language }
            node = current.parent
        }
        return nil
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

    private enum Role { case normal, ruby, media, tableRows, tableRow(cells: Int) }

    private struct Exit {
        var block = false
        var list = false
        var flatten = false
        var softBoundary = false
        var isolate = false
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

    private func enter(_ node: ContentNode, parent: Entry) {
        switch parent.role {
        case .ruby where node.isHTML("rt") || node.isHTML("rtc"):
            annotateRuby(node, parentStyle: parent.style); return
        case .ruby where node.isHTML("rp"):
            skip(node); return
        case .media where node.isHTML("source") || node.isHTML("track"):
            skip(node); return
        default: break
        }
        if node.isHTML, ContentSemantics.neverRendered.contains(node.name) { skip(node); return }
        // A formula shown as its own text never shows its encodings (TeX, content MathML).
        if node.name == "annotation" || node.name == "annotation-xml",
           node.namespace == ContentNamespace.mathML || node.namespace.isEmpty { skip(node); return }
        if node.namespace == ContentNamespace.ops, node.name == "trigger" { skip(node); return }

        let parentStyle = parent.style
        var style = state.style(node, parentStyle)
        if node.isHTML("noscript"), style.display == .none { style.display = .block }
        if style.writingMode != .horizontalTB { state.report.report.verticalWritingFlattened = true }
        if isSection, node.isHTML("body") { state.bodyStyle = style }
        register(node)
        if let kind = ContentSemantics.noteKind(node) {
            state.captureNote(node)
            if kind == .footnote { skip(node, registered: true); return }
        }
        guard style.display != .none, style.display != .tableColumn, style.display != .tableColumnGroup else {
            skip(node, registered: true); return
        }
        var context = parent.context
        if let language = node.language { context.language = language.isEmpty ? nil : language }

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
            if let result = state.request.rich.table(node, style: style, context: state.richContext) {
                insert(result, for: node, style: style, context: context)
                return
            }
            role = .tableRows
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
            else if ["thead", "tbody", "tfoot"].contains(node.name) { role = .tableRows }
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
        let blockLevel = style.display.isBlockLevel
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
            let marks = ContentSemantics.quotes(language: entry.context.language, depth: entry.context.quoteDepth)
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
        for branch in node.elementChildren where branch !== chosen { skip(branch) }
        stack.append(Entry(node: node, children: chosen?.children ?? [], style: style, context: context))
    }

    /// Ids and notes inside content that is not rendered still get anchors and note text.
    private func skip(_ node: ContentNode, registered: Bool = false) {
        let first = registered ? node.order + 1 : node.order
        guard first <= node.subtreeEnd else { return }
        for index in first...node.subtreeEnd {
            let element = document.nodes[index]
            guard element.isElement else { continue }
            register(element)
            if ContentSemantics.noteKind(element) != nil { state.captureNote(element) }
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
        if case .note(let id) = mode, path == document.path, fragment == id { return nil } // The note's own number.
        if ContentSemantics.isNoteReference(element) { return .note(href: resolved) }
        if path == document.path, let fragment, let target = document.element(id: fragment),
           ContentSemantics.noteKind(target) != nil || target.parent.flatMap(ContentSemantics.noteKind) != nil {
            return .note(href: resolved)
        }
        return .internal(href: resolved)
    }

    // MARK: Blocks

    private func enterBlock(_ node: ContentNode, style: ComputedStyle, language: String?) {
        if style.display == .listItem, pendingMarker != nil { openParagraph() } // An outer item's marker gets its own line.
        closeParagraph()
        if !isNote {
            gap.add(resolve(style.margin.top))
            let inset = resolve(style.padding.top) + Self.width(style.border.top)
            if inset > 0 { gap.seal(inset) }
        }
        if isSection {
            if style.breakBefore == .page || style.breakBefore == .column { pendingPageBreak = true }
            if style.breakBefore == .avoid, !paragraphs.isEmpty { paragraphs[paragraphs.count - 1].keepWithNext = true }
        }
        let parent = frames[frames.count - 1]
        let keep = ContentSemantics.isHeading(node) || node.isHTML("dt") || style.breakAfter == .avoid
        frames.append(BlockFrame(style: style, format: blockFormat(style, node: node, parent: parent),
                                 keepWithNext: keep, firstParagraph: paragraphs.count, language: language))
    }

    private func exitBlock() {
        if let marker = pendingMarker, marker.frame == frames.count - 1 { openParagraph() } // An empty item still shows its marker.
        closeParagraph()
        guard frames.count > 1 else { return }
        let frame = frames.removeLast()
        if !isNote {
            let inset = resolve(frame.style.padding.bottom) + Self.width(frame.style.border.bottom)
            if inset > 0 { gap.seal(inset) }
            gap.add(resolve(frame.style.margin.bottom))
        }
        if isSection, frame.style.breakAfter == .page || frame.style.breakAfter == .column { pendingPageBreak = true }
    }

    private func blockFormat(_ style: ComputedStyle, node: ContentNode?, parent: BlockFrame?) -> BlockFormat {
        var left = parent?.format.left ?? 0, right = parent?.format.right ?? 0
        if parent != nil { // The base frame is the column itself; a box adds its own edges.
            var marginLeft = resolve(style.margin.left), marginRight = resolve(style.margin.right)
            if style.margin.left == .auto, style.margin.right == .auto {
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
        return BlockFormat(alignment: alignment, endAligned: endAligned, direction: direction,
                           left: left, right: right, textIndent: resolve(style.textIndent),
                           lineHeightMultiple: multiple, lineHeight: cssLineHeight, hyphenate: style.hyphens == .auto,
                           characterWrap: style.whiteSpace == .pre,
                           tabInterval: style.whiteSpace.preservesSpaces ? 8 * InlineStyling.spaceAdvance(font) : 0)
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

    private func openParagraph() {
        guard !paragraphOpen else { return }
        let frame = frames[frames.count - 1]
        let gapValue = min(gap.value, Self.maximumGap)
        gap = MarginGap()
        var paragraph = Paragraph(start: buffer.count, format: frame.format,
                                  indentsFirstLine: paragraphs.count == frame.firstParagraph,
                                  separatorAttributes: frameAttributes())
        if let previous = paragraphs.indices.last {
            buffer.append(CollectionOfOne(0x0A), attributes: paragraphs[previous].separatorAttributes)
            paragraph.start = buffer.count
            if isNote { paragraphs[previous].spacingAfter = 0.4 * state.bodyStyle.fontSize }
            else if pendingPageBreak && isSection { paragraph.spacingBefore = gapValue; paragraph.pageBreakBefore = true }
            else { paragraphs[previous].spacingAfter = gapValue }
        } else if !isNote {
            paragraph.spacingBefore = gapValue
        }
        pendingPageBreak = false
        paragraph.keepWithNext = isSection && frames.contains { $0.keepWithNext }
        paragraphs.append(paragraph)
        paragraphOpen = true
        lineStart = true
        lastWasCollapsedSpace = false
        lastScalar = 0x0A
        if let marker = pendingMarker { emitMarker(marker) }
    }

    private func closeParagraph() {
        pendingSpace = nil
        guard paragraphOpen else { return }
        if pendingBreaks.count > 1 {
            pendingBreaks.removeLast()
            flushBreaks()
        }
        pendingBreaks.removeAll()
        paragraphOpen = false
        lineStart = true
        lastWasCollapsedSpace = false
        for index in isolates.indices { isolates[index].emitted = false }
    }

    private func finish() -> Output {
        closeParagraph()
        if !isNote, let last = paragraphs.indices.last { paragraphs[last].spacingAfter = min(gap.value, Self.maximumGap) }
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
        for paragraph in paragraphs where paragraph.start < length && (paragraph.pageBreakBefore || paragraph.keepWithNext) {
            let first = NSRange(location: paragraph.start, length: 1)
            if paragraph.pageBreakBefore { string.addAttribute(.readerPageBreakBefore, value: true, range: first) }
            if paragraph.keepWithNext { string.addAttribute(.readerKeepWithNext, value: true, range: first) }
        }
        for attribute in postAttributes where NSMaxRange(attribute.range) <= length {
            string.addAttribute(attribute.key, value: attribute.value, range: attribute.range)
        }
        string.endEditing()
        map.length = length
        return Output(string: string, map: map, anchors: anchors)
    }

    private func paragraphStyle(_ paragraph: Paragraph) -> NSParagraphStyle {
        let format = paragraph.format
        var key = ParagraphStyleKey()
        key.alignment = paragraph.blockUnit && paragraph.soleAttachment && !format.endAligned ? .center : format.alignment
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
        key.tabInterval = format.tabInterval
        guard let base = paragraph.factoryStyle, let style = base.mutableCopy() as? NSMutableParagraphStyle else {
            return styling.paragraphStyle(key)
        }
        // Rich content's own paragraph style: keep its alignment and inner spacing, add the box's.
        style.firstLineHeadIndent += key.firstLineHeadIndent
        style.headIndent += key.headIndent
        style.tailIndent = base.tailIndent <= 0 ? base.tailIndent - key.tailInset : base.tailIndent
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
                    emitText(units, index..<end, node: node, style: style, context: context, attributes: attributes)
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
                                         attributes: attributes)
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
                    emitText(units, index..<end, node: node, style: style, context: context, attributes: attributes)
                    index = end
                }
            }
        }
    }

    private func emitText(_ units: [UInt16], _ range: Range<Int>, node: ContentNode, style: ComputedStyle,
                          context: InlineContext, attributes: Int) {
        prepareForContent(next: Self.scalar(units, at: range.lowerBound))
        let location = buffer.count
        if collectingRubyBase, rubyBaseStart == nil { rubyBaseStart = location }
        if style.textTransform != .none {
            let rendered = transform(units[range], style.textTransform, language: context.language)
            buffer.append(rendered, attributes: attributes)
            buffer.replaceParagraphSeparators(from: location)
            mapSpan(location: location, length: rendered.count, node: node, offset: range.lowerBound,
                    sourceLength: range.count, exact: rendered.count == range.count)
        } else {
            buffer.append(units[range], attributes: attributes)
            buffer.replaceParagraphSeparators(from: location)
            mapSpan(location: location, length: range.count, node: node, offset: range.lowerBound,
                    sourceLength: range.count, exact: true)
        }
        didEmitContent()
    }

    /// Generated text that reads as content (`<q>` marks, inline markers): it ends a line start.
    private func emitGenerated(_ units: [UInt16], attributes: Int) {
        guard !units.isEmpty else { return }
        prepareForContent(next: Self.scalar(units, at: 0))
        buffer.append(units, attributes: attributes)
        didEmitContent()
    }

    private func mapSpan(location: Int, length: Int, node: ContentNode, offset: Int, sourceLength: Int, exact: Bool) {
        guard isSection else { return }
        map.append(TextMap.Span(location: location, length: length, node: node.order, offset: offset,
                                sourceLength: sourceLength, isExact: exact))
    }

    private func prepareForContent(next: UInt32) {
        openParagraph()
        flushBreaks()
        flushSpace(next: next)
        for index in isolates.indices where !isolates[index].emitted {
            buffer.append(isolates[index].opener, attributes: isolates[index].attributes)
            isolates[index].emitted = true
        }
        flushAnchors()
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
        flushAnchors(before: space.anchorSerial)
        let location = buffer.count
        buffer.append(CollectionOfOne(0x20), attributes: space.attributes)
        if isSection, let node = space.node {
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
            flushAnchors(before: pending.anchorSerial)
            let location = buffer.count
            buffer.append(CollectionOfOne(0x2028), attributes: pending.attributes)
            if isSection, let node = pending.node {
                map.append(TextMap.Span(location: location, length: 1, node: node, offset: pending.offset,
                                        sourceLength: pending.length, isExact: pending.length == 1))
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
        let block = style.display.isBlockLevel && flattenDepth == 0
        if block { enterBlock(node, style: style, language: context.language) }
        let utf16 = Array(result.string.utf16)
        prepareForContent(next: Self.scalar(utf16, at: 0))
        let location = buffer.count
        if collectingRubyBase, rubyBaseStart == nil { rubyBaseStart = location }
        claimSubtree(of: node, at: location)
        buffer.append(unit: result, link: style.isHidden ? nil : context.link?.url)
        if isSection {
            map.append(TextMap.Span(location: location, length: result.length, node: node.order, offset: 0,
                                    sourceLength: 0, isExact: false))
        }
        var subStart = paragraphs[paragraphs.count - 1].start
        func describe(end: Int) {
            let last = paragraphs.count - 1
            paragraphs[last].hasUnit = true
            guard block else { return }
            paragraphs[last].blockUnit = true
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
            next.pageBreakBefore = false; next.markerWidth = nil; next.hasNext = false; next.continuation = true
            next.soleAttachment = false; next.factoryStyle = nil; next.hasText = false
            paragraphs.append(next)
            subStart = next.start
        }
        describe(end: buffer.count)
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
        guard node.order < node.subtreeEnd else { return }
        for index in (node.order + 1)...node.subtreeEnd {
            let element = document.nodes[index]
            guard element.isElement else { continue }
            if isSection, let id = element.id, anchors[id] == nil { anchors[id] = location }
            if ContentSemantics.noteKind(element) != nil { state.captureNote(element) }
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
    var alignment: NSTextAlignment
    var endAligned: Bool
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
    var tabInterval: CGFloat
}

private struct BlockFrame {
    let style: ComputedStyle
    let format: BlockFormat
    let keepWithNext: Bool
    /// `paragraphs.count` when the box opened: its first paragraph gets `text-indent`.
    let firstParagraph: Int
    var attributes: Int?
    let language: String?

    init(style: ComputedStyle, format: BlockFormat, keepWithNext: Bool, firstParagraph: Int, language: String?) {
        self.style = style; self.format = format; self.keepWithNext = keepWithNext
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
    var pageBreakBefore = false
    var keepWithNext = false
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
