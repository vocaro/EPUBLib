import CoreGraphics
import CoreText
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The text container of every reader text view, including the paginator's measuring layout.
/// Attachments read `viewportSize` in `attachmentBounds(for:location:textContainer:…)`: an image
/// never exceeds one page, and `vw`/`vh` resolve against the reading viewport, not the screen.
final class ReaderTextContainer: NSTextContainer {
    /// Paginated: one column's width by the page's text height. Continuous scroll: the text
    /// column's width by the visible height. Zero until the view has a size.
    var viewportSize: CGSize = .zero
    var boxRegions: [ReaderBoxGeometry.Region] = []
    var boxOrigin: CGFloat = 0
    var boxSourceOffset = 0
    var boxPage: ReaderBoxPage?
    var boxOverride: CGRect?
    var boxColumn: CGRect?
    var proposalCorrection: ((Int) -> CGFloat)?
    var boxScope: UUID?
    var paragraphText: NSAttributedString? { didSet { indentClampCache = nil; measuredOpening = nil } }
    private var indentClampCache: (width: CGFloat, needed: Bool)?
    /// The space an aligned flex or grid box keeps above the text's first line
    /// (`.readerAlignmentLead`). TextKit drops the spacing before a document's first paragraph,
    /// so the layout manager restores this much as that fragment's top margin.
    var alignmentLead: CGFloat = 0
    /// Less than any line or box is tall, more than sums of their heights are out by.
    static let edgeSlack: CGFloat = 0.01
    /// The planned paragraph whose lines are being placed, and how far the plan's coordinates
    /// are from this container's at its first line (`lineFragmentRect`).
    private var planned: (paragraph: Int, shift: CGFloat)?
    var hasNonlinearGeometry: Bool { boxPage != nil || !boxRegions.isEmpty }
    /// The box plan measures its paragraphs in this container (`ReaderBoxLayout.measure`), and
    /// must measure them as the planned text is laid out: by this container, never on TextKit's
    /// rectangular path, even before the text's first box. That path applies a paragraph's
    /// indents itself, and its tabs, list markers and attachments land elsewhere and its lines
    /// break elsewhere, so a plan measured there is out from the layout below such a paragraph
    /// by the difference, as far as pushing a page's lines below its foot (#377).
    var measuresBoxPlan = false

    // The default becomes false merely because lineFragmentRect is overridden. Ordinary
    // sections remain rectangular and must retain TextKit's fast viewport/paragraph layout.
    override var isSimpleRectangularTextContainer: Bool {
        !hasNonlinearGeometry && !measuresBoxPlan && !needsIndentClamping && boxOverride == nil && boxColumn == nil
            && exclusionPaths.isEmpty && maximumNumberOfLines == 0
    }

    /// Ordinary paragraphs keep TextKit's fast rectangular path. An indent that consumes
    /// the column needs our delegate too: native layout can stop at that paragraph entirely.
    private var needsIndentClamping: Bool {
        guard size.width > 0, let text = layoutText else { return false }
        if let cached = indentClampCache, cached.width == size.width { return cached.needed }
        var needed = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            guard let style = value as? NSParagraphStyle else { return }
            let tail = max(0, style.tailIndent <= 0 ? -style.tailIndent : self.size.width - style.tailIndent)
            if max(0, style.headIndent, style.firstLineHeadIndent) + tail >= self.size.width {
                needed = true; stop.pointee = true
            }
        }
        indentClampCache = (size.width, needed)
        return needed
    }

    /// Leave a visible place for a glyph when authored insets consume the entire column.
    /// A one-point width lets TextKit advance, but still clips nearly every glyph at its edge.
    private func minimumLineWidth(at index: Int, width: CGFloat) -> CGFloat {
        let font = layoutText.flatMap { text in
            index >= 0 && index < text.length ? text.attribute(.font, at: index, effectiveRange: nil) as? PlatformFont : nil
        }
        return Self.minimumLineWidth(font: font, width: width)
    }

    private static func minimumLineWidth(font: PlatformFont?, width: CGFloat) -> CGFloat {
        min(width, max(1, (font?.pointSize ?? 16) * 2))
    }

    /// The text a table cell lays out with TextKit 1 in a column `width` wide
    /// (`TableCellLayout`, and `TableCellTextView` over the same text). TextKit 1 applies a
    /// paragraph's indents itself, so where they consume the column it set each glyph on a line
    /// of its own past the column's edge, with no used rect: the cell measured its first line
    /// alone, and the rest were on no page once its row was split (#569). Such a paragraph keeps
    /// the glyph-wide column `lineInsets` leaves it in TextKit 2, keeping its left indent first
    /// as that does, with its tab stops inside the column as
    /// `textContentStorage(_:textParagraphWith:)` keeps them.
    static func clampingExhaustedIndents(in text: NSAttributedString, width: CGFloat) -> NSAttributedString {
        var result: NSMutableAttributedString?
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            var first = max(0, style.firstLineHeadIndent), head = max(0, style.headIndent)
            var tail = max(0, style.tailIndent <= 0 ? -style.tailIndent : width - style.tailIndent)
            guard max(first, head) + tail >= width else { return }
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont
            let available = max(0, width - minimumLineWidth(font: font, width: width))
            if style.baseWritingDirection == .rightToLeft {
                tail = min(tail, available)
                first = min(first, available - tail); head = min(head, available - tail)
            } else {
                first = min(first, available); head = min(head, available)
                tail = min(tail, available - max(first, head))
            }
            let clamped = style.mutableCopy() as! NSMutableParagraphStyle
            clamped.firstLineHeadIndent = first; clamped.headIndent = head; clamped.tailIndent = -tail
            let lastStop = max(1, available)
            clamped.tabStops = style.tabStops.map {
                NSTextTab(textAlignment: $0.alignment, location: min($0.location, lastStop), options: $0.options)
            }
            clamped.defaultTabInterval = min(style.defaultTabInterval, lastStop)
            if result == nil { result = NSMutableAttributedString(attributedString: text) }
            result?.addAttribute(.paragraphStyle, value: clamped, range: range)
        }
        return result ?? text
    }

    private func visibleRect(_ rect: CGRect, within bounds: CGRect, at index: Int) -> CGRect {
        guard bounds.width > 0 else { return rect }
        let right = min(bounds.maxX, rect.maxX)
        let left = max(bounds.minX, rect.minX)
        if right > left { return CGRect(x: left, y: rect.minY, width: right - left, height: rect.height) }
        let width = minimumLineWidth(at: index, width: bounds.width)
        let x = min(max(bounds.minX, left), bounds.maxX - width)
        return CGRect(x: x, y: rect.minY, width: width, height: rect.height)
    }

    func configureBoxes(in text: NSAttributedString) {
        paragraphText = text
        boxPage = text.length > 0 ? text.attribute(.readerBoxPage, at: 0, effectiveRange: nil) as? ReaderBoxPage : nil
        boxRegions = boxPage?.geometry.regions ?? []
        boxOrigin = boxPage?.origin ?? 0
        boxSourceOffset = boxPage?.offset ?? 0
        planned = nil
        alignmentLead = ReaderAlignmentLayout.lead(in: text, at: 0)
    }

    /// Whether this container gives each line its paragraph's indents (`lineInsets`), which it
    /// does once it is its content storage's delegate: TextKit then sees paragraphs without any.
    private var deliversIndents: Bool {
        (textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate === self
    }

    private var layoutText: NSAttributedString? {
        if let paragraphText { return paragraphText }
        let storage = textLayoutManager?.textContentManager as? NSTextContentStorage
        return storage?.textStorage ?? storage?.attributedString
    }

    /// The paragraph style laid out at `index`, with the indents TextKit is not shown.
    private func paragraphStyle(at index: Int) -> NSParagraphStyle? {
        guard let text = layoutText, index >= 0, index < text.length else { return nil }
        return text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }

    /// What the line starting at `index` keeps clear at each side of a box `width` wide: its
    /// paragraph's first-line or head indent at the leading edge, its tail indent at the other.
    /// `firstLine` takes the line for the paragraph's first wherever `index` is in it.
    private func lineInsets(at index: Int, writingDirection: NSWritingDirection, width: CGFloat,
                            firstLine: Bool = false) -> (left: CGFloat, right: CGFloat) {
        guard let text = layoutText, let style = paragraphStyle(at: index) else { return (0, 0) }
        let opensParagraph = firstLine || index == 0 || ReaderAlignmentLayout.isParagraphBreak((text.string as NSString).character(at: index - 1))
        let leading = max(0, opensParagraph ? style.firstLineHeadIndent : style.headIndent)
        let trailing = max(0, style.tailIndent <= 0 ? -style.tailIndent : width - style.tailIndent)
        var insets = writingDirection == .rightToLeft ? (left: trailing, right: leading) : (left: leading, right: trailing)
        if insets.left + insets.right >= width {
            let available = max(0, width - minimumLineWidth(at: index, width: width))
            insets.left = min(insets.left, available)
            insets.right = min(insets.right, available - insets.left)
        }
        return insets
    }

    /// The width a line starting at `index` needs for the first piece of content it can hold
    /// (`openingWord(in:at:)`), or, where that piece surely fits in `room`, a width it fits in
    /// that is no greater than `room`. The piece is no wider than the text before the next white
    /// space a line surely may end at (`TableMeasure.endsRun(at:in:)`), and most lines beside a
    /// float open with a word far narrower than the room there. Setting that text alone on a line
    /// spares such a line finding its word's line-break opportunity and hyphenation points, and
    /// reading its paragraph for its end, which made laying out lines beside a float a third
    /// slower (#152).
    private func openingWidth(at index: Int, room: CGFloat) -> CGFloat {
        guard let text = layoutText, index >= 0, index < text.length else { return 0 }
        if let known = measuredOpening, known.index == index, known.text === text, known.exact || known.width <= room { return known.width }
        // Up to that white space, within as far as a word could run; an attachment character,
        // which TextKit sizes to its line, leaves it to the exact piece.
        let string = text.string as NSString
        let limit = min(string.length, index + 256)
        var end = index, attached = false
        while end < limit {
            let character = string.character(at: end)
            if TableMeasure.breakingSpaces.contains(character), TableMeasure.endsRun(at: end, in: string) { break }
            if character == 0xFFFC { attached = true; break }
            end += 1
        }
        if !attached, end < limit || limit == string.length {
            let bound = ceil(TableMeasure.widestRun(of: text, in: NSRange(location: index, length: end - index)))
            if bound <= room {
                measuredOpening = (index, text, bound, false)
                return bound
            }
        }
        let width = openingWord(in: text, at: index).map(Self.width(of:)) ?? 0
        measuredOpening = (index, text, width, true)
        return width
    }
    /// What `openingWidth` last measured, by the text and character it starts at: the piece's
    /// width, or a width the piece fits in.
    private var measuredOpening: (index: Int, text: NSAttributedString, width: CGFloat, exact: Bool)?
    /// The hyphenation locales of the languages of the text laid out (`TableMeasure.hyphenationLocale`).
    private var hyphenationLocales: [String: CFLocale?] = [:]

    /// The width `text` is set in, without the white space that ends it, up to the next point.
    private static func width(of text: NSAttributedString) -> CGFloat {
        let line = CTLineCreateWithAttributedString(text as CFAttributedString)
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)))
    }

    /// The first piece of content a line of `text` starting at `index` can hold, as it is set:
    /// its word, up to the first line-break opportunity after it (UAX #14, as CoreText finds
    /// them). In a paragraph that hyphenates (`hyphens: auto`, the reader's default) a word may
    /// end a line at a hyphenation point, so the piece is the word's first part and the hyphen
    /// set after it (CSS Text 3, 5.4). Nil where any character may end a line (`white-space:
    /// pre`, which the reader wraps by character) and at an attachment, which TextKit sizes to
    /// its line.
    private func openingWord(in text: NSAttributedString, at index: Int) -> NSAttributedString? {
        let style = text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        guard style?.lineBreakMode != .byCharWrapping else { return nil }
        let string = text.string as NSString
        // A word is far shorter than this; the bound keeps a long paragraph from being read.
        let span = string.substring(with: NSRange(location: index, length: min(string.length - index, 256))) as CFString
        let tokenizer = CFStringTokenizerCreate(nil, span, CFRange(location: 0, length: CFStringGetLength(span)), kCFStringTokenizerUnitLineBreak, nil)
        guard CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 else { return nil }
        let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
        var word = NSRange(location: index + token.location, length: token.length)
        var attached = false
        text.enumerateAttribute(.attachment, in: word) { value, _, stop in
            if value != nil { attached = true; stop.pointee = true }
        }
        guard !attached, word.length > 0 else { return nil }
        guard (style?.hyphenationFactor ?? 0) > 0 else { return text.attributedSubstring(from: word) }
        let language = text.attribute(InlineStyling.languageKey, at: index, effectiveRange: nil) as? String
        if hyphenationLocales[language ?? ""] == nil { hyphenationLocales[language ?? ""] = .some(TableMeasure.hyphenationLocale(language)) }
        guard let locale = hyphenationLocales[language ?? ""] ?? nil,
              let point = TableMeasure.hyphenationPoints(in: text, word: word, locale: locale).first else {
            return text.attributedSubstring(from: word)
        }
        word.length = point - word.location
        let piece = NSMutableAttributedString(attributedString: text.attributedSubstring(from: word))
        piece.append(NSAttributedString(string: "-", attributes: text.attributes(at: word.upperBound - 1, effectiveRange: nil)))
        return piece
    }

    /// How many times running TextKit may ask for a line at one character (#288). It asks a
    /// container that is not a plain rectangle for the next line down for as long as it has set
    /// nothing on the line, and text it can set on no line keeps it asking without end: a tab
    /// with neither a stop after it nor a default tab interval did (#227), and nothing shows that
    /// it is the only such text. In the reader's layouts of the fixture books and the corpora it
    /// asks for one character at most four times running, so a thousand is text it will never set.
    static let askLimit = 1_000
    /// The character TextKit last asked a line for, and how many times running.
    private var asking = (index: -1, count: 0)
    /// The paragraphs TextKit was refused a line in (`askLimit`), each time one was laid out.
    private(set) var unplacedParagraphs = 0

    /// Whether `lines` are those of a paragraph TextKit was refused a line in: below the lines
    /// it set, the empty lines it asked for, close to `askLimit` of them.
    static func holdsRefusedLines(_ lines: [NSTextLineFragment]) -> Bool {
        lines.count >= askLimit / 2 && lines.lazy.filter { $0.characterRange.length <= 0 }.count >= askLimit / 2
    }

    override func lineFragmentRect(forProposedRect proposed: CGRect, at index: Int,
                                   writingDirection: NSWritingDirection, remaining: UnsafeMutablePointer<CGRect>?) -> CGRect {
        if asking.index == index { asking.count += 1 } else { asking = (index, 1) }
        guard asking.count <= Self.askLimit else {
            // An empty rectangle is a full container to TextKit, which ends the paragraph there
            // with the empty lines it asked for and goes on with the next one. A layout of the
            // same paragraph again asks afresh: refused at its first line, TextKit would end the
            // whole layout there instead.
            asking = (-1, 0)
            unplacedParagraphs += 1
            // TextKit 1 lays a table cell out, from its layout manager's storage.
            let text = layoutText ?? (textLayoutManager == nil ? layoutManager?.textStorage : nil)
            if let text, index >= 0, index < text.length {
                (text.attribute(.readerSectionLayout, at: index, effectiveRange: nil) as? SectionLayoutRecord)?.recordUnplacedText()
            }
            remaining?.pointee = .zero
            return .zero
        }
        let correction = proposalCorrection?(boxPage?.geometry.paragraph(at: index + boxSourceOffset).map { $0.range.location - boxSourceOffset } ?? index) ?? 0
        let result = lineRect(forProposedRect: proposed.offsetBy(dx: 0, dy: -correction), at: index, writingDirection: writingDirection, remaining: remaining)
        if correction != 0, let remaining, remaining.pointee != .zero { remaining.pointee.origin.y += correction }
        return result.offsetBy(dx: 0, dy: correction)
    }

    private func lineRect(forProposedRect proposed: CGRect, at index: Int,
                          writingDirection: NSWritingDirection, remaining: UnsafeMutablePointer<CGRect>?) -> CGRect {
        // The entry point is only reached for a container that is not a plain rectangle.
        let delivers = deliversIndents && !isSimpleRectangularTextContainer
        let ownRegion = boxPage?.geometry.regions.first(where: { !$0.reserved && NSLocationInRange(index + boxSourceOffset, $0.range) })
        if let frame = boxOverride ?? ownRegion?.contentFrame ?? ownRegion?.frame {
            remaining?.pointee = .zero
            guard delivers else { return CGRect(x: frame.minX, y: proposed.minY, width: frame.width, height: proposed.height) }
            let insets = lineInsets(at: index, writingDirection: writingDirection, width: frame.width)
            let minX = frame.minX + insets.left
            return visibleRect(CGRect(x: minX, y: proposed.minY, width: max(1, frame.maxX - insets.right - minX), height: proposed.height), within: frame, at: index)
        }
        let column = boxColumn ?? boxPage?.geometry.paragraph(at: index + boxSourceOffset)?.column
        var proposal = proposed
        if delivers {
            // Once this entry point is overridden TextKit wraps a line within its paragraph's
            // indents but aligns and justifies it across the whole rectangle returned here, as
            // if it had none: a centred line sits half its indents too far along and a
            // right-aligned or justified one runs past the tail indent. So TextKit is given
            // paragraphs without indents (`textContentStorage(_:textParagraphWith:)`) and each
            // line's rectangle is the place its paragraph's indents leave it.
            let box = column ?? CGRect(x: 0, y: 0, width: size.width, height: 0)
            let insets = lineInsets(at: index, writingDirection: writingDirection, width: box.width)
            let maxX = min(proposal.maxX, min(size.width, box.maxX) - insets.right)
            proposal.origin.x = max(proposal.minX, box.minX + insets.left)
            proposal.size.width = max(1, maxX - proposal.minX)
        } else if let style = paragraphStyle(at: index) {
            // Without the delegate TextKit applies the indents itself; only the trailing edge
            // is narrowed here, as before.
            if writingDirection == .rightToLeft {
                let left = style.tailIndent <= 0 ? -style.tailIndent : size.width - style.tailIndent
                let right = proposal.maxX
                proposal.origin.x = max(proposal.minX, left)
                proposal.size.width = max(1, right - proposal.minX)
            } else {
                let right = style.tailIndent <= 0 ? size.width + style.tailIndent : style.tailIndent
                proposal.size.width = max(1, min(proposal.maxX, right) - proposal.minX)
            }
        }
        proposal = visibleRect(proposal, within: column ?? CGRect(x: 0, y: 0, width: size.width, height: 0), at: index)
        guard !boxRegions.isEmpty || column != nil else {
            return super.lineFragmentRect(forProposedRect: proposal, at: index, writingDirection: writingDirection, remaining: remaining)
        }
        let sourceIndex = index + boxSourceOffset
        // A box lays out in its own paragraph insets; exclusions apply to following flow text.
        if boxPage?.geometry.paragraph(at: sourceIndex)?.isBox == true {
            return super.lineFragmentRect(forProposedRect: proposal, at: index, writingDirection: writingDirection, remaining: remaining)
        }
        remaining?.pointee = .zero
        var rect = proposal
        rect = visibleRect(rect, within: CGRect(x: 0, y: 0, width: size.width, height: 0), at: index)
        if let column, !delivers {
            rect.origin.x = max(rect.minX, column.minX)
            rect.size.width = max(1, min(size.width, column.maxX) - rect.minX)
            rect = visibleRect(rect, within: column, at: index)
        }
        // The plan's regions are where it put them, and this container's lines are wherever
        // TextKit has got to. The two agree while everything above is laid out. In a long text
        // shown part way down, TextKit only estimates what is above, and a line can be screens
        // from where the plan has it: it would miss the boxes beside it and meet others that
        // are nowhere near. So a planned paragraph's lines are taken to the plan from where its
        // own first line was proposed, and text past the plan's end is below every box. The
        // paragraph this container opens with keeps the container's own origin: a page's is
        // its first line's place, wherever a box above the page pushed that line. TextKit
        // proposes a paragraph's first line below the spacing before the paragraph (a forced
        // break's retained margin, a heading's), which the paragraph's flow start leaves out (#362).
        var origin = boxOrigin
        if let page = boxPage {
            guard let paragraph = page.geometry.paragraph(at: sourceIndex) else { return rect }
            if index > 0, sourceIndex == paragraph.range.location {
                let spacing = max(0, paragraphStyle(at: index)?.paragraphSpacingBefore ?? 0)
                planned = (sourceIndex, paragraph.flowStart + paragraph.topAdjustment + spacing - proposed.minY
                    - (proposalCorrection?(paragraph.range.location - boxSourceOffset) ?? 0))
            }
            if let planned, planned.paragraph == paragraph.range.location { origin = planned.shift }
            else if boxSourceOffset > 0, paragraph.range.location == boxSourceOffset {
                // A page that opens a paragraph has its origin that paragraph's spacing before
                // above its first line (`ReaderPage.layoutSpacing`), and TextKit drops the spacing.
                origin += max(0, paragraphStyle(at: 0)?.paragraphSpacingBefore ?? 0)
            }
        }
        // The line after a `br` that clears floats starts below the earlier ones it names. The
        // plan measured the paragraph here, so the section, its pages and the plan agree.
        if index > 0, let text = layoutText, index < text.length, (text.string as NSString).character(at: index - 1) == 0x2028,
           let clear = text.attribute(.readerClear, at: index, effectiveRange: nil) as? ComputedStyle.Clear,
           let floor = ReaderBoxLayout.clearance(clear, of: boxRegions.filter { $0.range.upperBound <= sourceIndex }) {
            rect.origin.y = max(rect.minY, floor - origin)
        }
        while true {
            let global = rect.offsetBy(dx: 0, dy: origin)
            let scope = boxScope ?? boxPage?.geometry.paragraph(at: sourceIndex)?.scope
            // A line that starts where a box ends is clear of it, whatever the arithmetic that
            // brought the two edges together left between them.
            let reach = global.insetBy(dx: 0, dy: min(Self.edgeSlack, global.height / 4))
            let obstacles = boxRegions.filter {
                (($0.wrapsEarlierText && $0.scope == scope) || $0.range.upperBound <= sourceIndex) && $0.frame.intersects(reach)
            }
            guard !obstacles.isEmpty else { return rect }
            var intervals = [(rect.minX, rect.maxX)]
            for obstacle in obstacles {
                // A line beside a float is shortened on the float's side (CSS 2.2 9.5): nothing is
                // set between a left float and the line's start, or a right one and the line's
                // end, where a float in an indented block leaves room. Other boxes are cut out.
                let minX = obstacle.side == .left ? -CGFloat.infinity : obstacle.frame.minX
                let maxX = obstacle.side == .right ? CGFloat.infinity : obstacle.frame.maxX
                intervals = intervals.flatMap { left, right -> [(CGFloat, CGFloat)] in
                    if maxX <= left || minX >= right { return [(left, right)] }
                    var pieces: [(CGFloat, CGFloat)] = []
                    if minX > left { pieces.append((left, minX)) }
                    if maxX < right { pieces.append((maxX, right)) }
                    return pieces
                }
            }
            // A piece is used when it is readable and holds the line's first word, or the first
            // part of it where the paragraph hyphenates. A line box too narrow beside a float for
            // any of its content is shifted down (CSS 2.2 9.5); in a piece narrower than that
            // TextKit broke the word between any two characters (#152).
            let readable = min(size.width / 3, 48)
            intervals = intervals.filter { $0.1 - $0.0 >= readable }
            if let room = intervals.map({ $0.1 - $0.0 }).min() {
                let opening = openingWidth(at: index, room: room)
                intervals = intervals.filter { $0.1 - $0.0 >= opening }
            }
            if let interval = writingDirection == .rightToLeft ? intervals.last : intervals.first {
                if intervals.count > 1 {
                    let other = writingDirection == .rightToLeft ? intervals.first! : intervals.last!
                    remaining?.pointee = CGRect(x: other.0, y: rect.minY, width: other.1 - other.0, height: rect.height)
                }
                return CGRect(x: interval.0, y: rect.minY, width: interval.1 - interval.0, height: rect.height)
            }
            rect.origin.y = max(rect.minY + 1, (obstacles.map(\.frame.maxY).max() ?? global.maxY) - origin)
        }
    }

    /// Attaches the container to the content storage it lays out, so that it delivers paragraph
    /// indents itself wherever it has box geometry (`lineFragmentRect`).
    func deliverIndents(for storage: NSTextContentStorage) { storage.delegate = self }

    /// The attachment's containing content column, even when TextKit's preliminary proposal
    /// still spans the viewport. Measurement uses boxOverride; actual page layout uses the
    /// region containing this source character, retaining the original viewport for vw/vh.
    func attachmentColumn(at index: Int?) -> CGRect? {
        if let boxOverride { return boxOverride }
        guard let index, index >= 0 else { return boxColumn }
        let sourceIndex = index + boxSourceOffset
        if let region = boxPage?.geometry.regions.first(where: { !$0.reserved && NSLocationInRange(sourceIndex, $0.range) }) {
            return region.contentFrame ?? region.frame
        }
        return boxColumn ?? boxPage?.geometry.paragraph(at: sourceIndex)?.column
    }

    /// Whether this container gives each line its paragraph's indents itself (`lineInsets`), and
    /// TextKit is shown paragraphs without them (`textContentStorage(_:textParagraphWith:)`).
    var setsLineIndents: Bool { deliversIndents && !isSimpleRectangularTextContainer }

    /// The indents of the paragraph an attachment at `index` is in, in a column `width` wide:
    /// what the attachment's line keeps clear at each side (`lineInsets`); how far from that
    /// line's start the attachment stands at least, at the stop of a list item's marker it stands
    /// past (`markerStop`); and whether it does. Such an attachment, or one that opens its
    /// paragraph, is on the paragraph's first line; any other is taken to be on a later one, as
    /// it is unless it follows text on the first. Nil where the text is not known.
    func attachmentIndents(at index: Int?, width: CGFloat) -> (left: CGFloat, right: CGFloat, hang: CGFloat, pastMarker: Bool)? {
        guard let index, let text = layoutText, let style = paragraphStyle(at: index) else { return nil }
        let stop = Self.markerStop(before: index, in: text.string as NSString, style: style)
        let line = lineInsets(at: index, writingDirection: style.baseWritingDirection, width: width, firstLine: stop != nil)
        return (line.left, line.right, stop.map { max(0, $0 - max(0, style.firstLineHeadIndent)) } ?? 0, stop != nil)
    }

    /// The stop of the list item's marker whose tab is just before `index`, from the paragraph's
    /// leading edge; nil where there is no such marker. An outside marker hangs before the head
    /// indent, and the tab after it is its paragraph's first, to the paragraph's one stop: the
    /// head indent, or the `text-indent` past it (`SectionWriter.markerStop`). A tab later in
    /// such a paragraph, or in any other, is not a marker's.
    static func markerStop(before index: Int, in string: NSString, style: NSParagraphStyle) -> CGFloat? {
        guard index > 0, index <= string.length, string.character(at: index - 1) == 0x09,
              style.firstLineHeadIndent < style.headIndent, style.tabStops.count == 1,
              style.tabStops[0].location >= style.headIndent - edgeSlack else { return nil }
        var cursor = index - 2
        while cursor >= 0, !ReaderAlignmentLayout.isParagraphBreak(string.character(at: cursor)) {
            if string.character(at: cursor) == 0x09 { return nil }
            cursor -= 1
        }
        return style.tabStops[0].location
    }

    /// The size an attachment may use: the proposed line width, and the viewport height (or a
    /// generous default before layout knows it).
    static func available(in container: NSTextContainer?, lineWidth: CGFloat) -> CGSize {
        let viewport = (container as? ReaderTextContainer)?.viewportSize ?? .zero
        let width = lineWidth > 0 ? lineWidth : (viewport.width > 0 ? viewport.width : 600)
        return CGSize(width: width, height: viewport.height > 0 ? viewport.height : 800)
    }
}

extension ReaderTextContainer: NSTextContentStorageDelegate {
    /// At most this many of a paragraph's interval stops are written out (`intervalStops`). Past
    /// the last stop it is shown, TextKit 2 sets a tab at that stop plus a multiple of the
    /// interval, which is where the next ones would have been.
    static let maximumIntervalStops = 512

    /// Whether the characters of `range` in `text` hold a tab.
    static func holdsTab(_ text: NSAttributedString, in range: NSRange) -> Bool {
        (text.string as NSString).range(of: "\t", options: .literal, range: range).location != NSNotFound
    }

    /// The stops a paragraph of `style` with no stops of its own has a tab land on: every
    /// multiple of its default interval (`InlineStyling.tabInterval`) from the paragraph's
    /// leading edge, the right in right-to-left text, through the first past `limit`. TextKit 1
    /// sets a tab there in either direction, and TextKit 2 does left to right where it applies
    /// the paragraph's indents itself. Elsewhere TextKit 2 measures the interval from a line's
    /// start: in a paragraph without indents, the start the container gives each line, and right
    /// to left, the first line's start less the tail indent. So a tab past an indent landed an
    /// indent further along with a box in the section than without one (#334). Such a paragraph
    /// that holds a tab is shown these stops, moved as its own would be.
    static func intervalStops(_ style: NSParagraphStyle, through limit: CGFloat) -> [CGFloat] {
        let interval = InlineStyling.tabInterval(style.defaultTabInterval)
        var stops: [CGFloat] = []
        var step = 1
        while stops.count < maximumIntervalStops {
            let stop = CGFloat(step) * interval
            stops.append(stop)
            if stop > limit { break }
            step += 1
        }
        return stops
    }

    /// The tab stops of `style` measured from its first line's start, as TextKit is shown a
    /// paragraph whose indents it is not shown: its own, moved back by the first-line indent, or,
    /// in a paragraph that has none and `holdsTab`, its interval's (`intervalStops`) that are
    /// past that start. A paragraph's later lines have the same stops, measured from their own
    /// start, so where the first is indented differently (`text-indent`) a tab on a later line
    /// lands that difference off; a page that starts within a paragraph (`ReaderPaginator`) sets
    /// its first line at the head indent and measures them from there.
    static func firstLineStops(_ style: NSParagraphStyle, holdsTab: Bool, through limit: CGFloat) -> [NSTextTab] {
        let origin = max(0, style.firstLineHeadIndent)
        guard style.tabStops.isEmpty else {
            return style.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: max(0, $0.location - origin), options: $0.options) }
        }
        guard holdsTab else { return [] }
        return intervalStops(style, through: limit).compactMap {
            $0 > origin ? NSTextTab(textAlignment: .natural, location: $0 - origin) : nil
        }
    }

    /// `style` as TextKit 2 is shown it where it applies the paragraph's indents itself, so that
    /// its tab stops are where the style puts them; nil when that is `style`. A stop is a
    /// distance from the paragraph's leading edge, the right one in right-to-left text, as
    /// TextKit 1 places it in either direction and TextKit 2 left to right. TextKit 2 measures a
    /// right-to-left paragraph's stops from its first line's start instead, less its tail
    /// indent, so a list marker's stop set the item's first line a first-line indent further
    /// along than its wrapped lines (#276), and so it measures the paragraph's interval: a
    /// paragraph without stops of its own that `holdsTab` is shown its interval's
    /// (`intervalStops`), moved in the same way. Paragraphs without indents
    /// (`lineFragmentRect`'s) have their stops measured from each line's start, and are given
    /// them from there (`firstLineStops`).
    static func rightToLeftStops(_ style: NSParagraphStyle, width: CGFloat, holdsTab: Bool = false) -> NSParagraphStyle? {
        guard style.baseWritingDirection == .rightToLeft, !style.tabStops.isEmpty || holdsTab else { return nil }
        let first = max(0, style.firstLineHeadIndent)
        let tail = max(0, style.tailIndent <= 0 ? -style.tailIndent : width - style.tailIndent)
        guard first != tail else { return nil }
        let shown = style.mutableCopy() as! NSMutableParagraphStyle
        if style.tabStops.isEmpty {
            shown.tabStops = intervalStops(style, through: width).compactMap {
                $0 - first + tail > 0 ? NSTextTab(textAlignment: .natural, location: $0 - first + tail) : nil
            }
        } else {
            shown.tabStops = style.tabStops.map {
                NSTextTab(textAlignment: $0.alignment, location: max(0, $0.location - first + tail), options: $0.options)
            }
        }
        return shown
    }

    /// A paragraph as TextKit lays it out in a container with box geometry: without the head,
    /// first-line and tail indents that `lineFragmentRect` gives each of its lines. The stored
    /// text keeps them. Tab stops are measured from a line's start, which the first-line indent
    /// has now moved, so they move back by it, and a paragraph that holds a tab is given its
    /// interval's stops where it has none (`firstLineStops`). In a plain rectangle TextKit
    /// applies the indents itself, and a right-to-left paragraph's stops are moved to where it
    /// measures them from (`rightToLeftStops`).
    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard range.length > 0,
              let text = textContentStorage.textStorage ?? textContentStorage.attributedString, range.upperBound <= text.length,
              let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle else { return nil }
        guard !isSimpleRectangularTextContainer else {
            guard let shown = Self.rightToLeftStops(style, width: size.width,
                                                    holdsTab: style.baseWritingDirection == .rightToLeft && Self.holdsTab(text, in: range)) else { return nil }
            let paragraph = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
            paragraph.addAttribute(.paragraphStyle, value: shown, range: NSRange(location: 0, length: paragraph.length))
            return NSTextParagraph(attributedString: paragraph)
        }
        guard style.headIndent != 0 || style.firstLineHeadIndent != 0 || style.tailIndent != 0 else { return nil }
        let flat = style.mutableCopy() as! NSMutableParagraphStyle
        flat.headIndent = 0; flat.firstLineHeadIndent = 0; flat.tailIndent = 0
        let trailing = max(0, style.tailIndent <= 0 ? -style.tailIndent : size.width - style.tailIndent)
        let consumed = max(0, style.headIndent, style.firstLineHeadIndent) + trailing >= size.width
        if !style.tabStops.isEmpty {
            let lastStop = max(1, size.width - minimumLineWidth(at: range.location, width: size.width))
            flat.tabStops = Self.firstLineStops(style, holdsTab: true, through: size.width).map {
                NSTextTab(textAlignment: $0.alignment, location: consumed ? min($0.location, lastStop) : $0.location, options: $0.options)
            }
            if consumed { flat.defaultTabInterval = min(flat.defaultTabInterval, lastStop) }
        } else if !consumed, Self.holdsTab(text, in: range) {
            flat.tabStops = Self.firstLineStops(style, holdsTab: true, through: size.width)
        }
        let paragraph = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        paragraph.addAttribute(.paragraphStyle, value: flat, range: NSRange(location: 0, length: paragraph.length))
        return NSTextParagraph(attributedString: paragraph)
    }
}
