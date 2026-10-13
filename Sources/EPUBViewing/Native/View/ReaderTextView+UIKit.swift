#if os(iOS)
import SwiftUI
import UIKit

/// A TextKit 2 `UITextView` over its own content storage: a page column (one fixed slice that
/// never scrolls) or the continuous-scroll view.
final class ReaderTextView: UITextView {
    let contentStorage: NSTextContentStorage
    let readerLayoutManager: NSTextLayoutManager
    let readerContainer: ReaderTextContainer
    let isPageColumn: Bool
    var placement = ReaderTextPlacement()
    var flowSourceText: NSAttributedString?
    /// The text shown has boxes resolved against the viewport (`refreshFlowBoxLayout`), so a
    /// new viewport size lays all of it out anew.
    var layoutFollowsViewport = false
    var tableInteraction: ReaderTableInteraction?
    var containsTableRows = false
    weak var canvas: ReaderCanvasView?
    private var pageAccessibilityCache: ReaderAccessibilityList?
    /// The scroll view's listed lines, and where the view stood when they were measured.
    private var scrollAccessibilityCache: (place: ScrollAccessibilityPlace, list: ReaderAccessibilityList)?
    /// The line of the scroll view an assistive technology's cursor is on: from the moment the
    /// line is told so until UIKit's focus notification names something that is not one of this
    /// view's lines.
    private var accessibilityCursor: ReaderPageAccessibilityElement?
    /// Whether that cursor is on something VoiceOver reaches after the scroll view's lines: one
    /// of the scroll view's own bars, or an item below the reading area.
    private var accessibilityCursorFollowsText = false
    /// The line of a page column an assistive technology's cursor is on: from the moment the
    /// line is told so until UIKit's focus notification names something that is not one of
    /// this column's lines. VoiceOver goes on holding the element when the page is turned
    /// under it, so this is then a line the column no longer lists
    /// (`accessibilityCursorHasLeftThePage`), until the element is made a line of the page
    /// shown (`accessibilityCursorStands(for:)`).
    private var pageAccessibilityCursor: ReaderPageAccessibilityElement?
    /// The elements that stand in the list for the scroll view's own bars (`scrollBarListed`).
    private var scrollBarElements: [ReaderScrollBarAccessibilityElement] = []
    /// How many lines the scroll view lists past the screen: as many items as VoiceOver was seen
    /// to ask for at once (iOS 27.0).
    private static let accessibilityLinesPastScreen = 50
    /// How far inside the area the insets leave UIKit brings what VoiceOver's cursor goes to
    /// (iOS 27.0).
    private static let accessibilityScrollMargin: CGFloat = 40
    private var imageGestureDelegate: ReaderImageGestureDelegate?
    private var selectionGestureDelegate: ReaderSpreadSelectionGestureDelegate?
    /// VoiceOver's Headings rotor for the lines this view lists.
    private lazy var headingRotor = UIAccessibilityCustomRotor(systemType: .heading) { [weak self] predicate in
        self?.heading(for: predicate)
    }

    init(pageColumn: Bool) {
        (contentStorage, readerLayoutManager, readerContainer) = Self.makeTextKitStack()
        isPageColumn = pageColumn
        super.init(frame: .zero, textContainer: readerContainer)
        isEditable = false
        isSelectable = true
        dataDetectorTypes = []
        linkTextAttributes = [:] // The builder colors links.
        backgroundColor = .clear
        let imageDelegate = ReaderImageGestureDelegate(view: self)
        imageGestureDelegate = imageDelegate
        let imageTap = UITapGestureRecognizer(target: imageDelegate, action: #selector(ReaderImageGestureDelegate.openImage(_:)))
        imageTap.numberOfTapsRequired = 2
        imageTap.delegate = imageDelegate
        addGestureRecognizer(imageTap)
        if pageColumn { selectionGestureDelegate = ReaderSpreadSelectionGestureDelegate.install(on: self) }
        textContainerInset = .zero
        textDragInteraction?.isEnabled = false
        for name in [UIAccessibility.elementFocusedNotification, UIAccessibility.voiceOverStatusDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(accessibilityFocusChanged(_:)), name: name, object: nil)
        }
        if pageColumn {
            isScrollEnabled = false
            readerContainer.widthTracksTextView = false
            contentInsetAdjustmentBehavior = .never
            showsVerticalScrollIndicator = false
            clipsToBounds = true
        } else {
            readerContainer.widthTracksTextView = true
            alwaysBounceVertical = true
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The text container's origin in this view's coordinates.
    var containerOrigin: CGPoint { CGPoint(x: textContainerInset.left, y: textContainerInset.top) }

    /// Asks for the text already on screen to be drawn again. The text view draws each laid-out
    /// fragment in a view of its own beneath it, which its own `setNeedsDisplay()` does not
    /// reach. Only views that draw themselves are asked: `setNeedsDisplay()` is for those.
    func setRenderedTextNeedsDisplay() {
        let selector = #selector(UIView.draw(_:))
        let inherited = UIView.instanceMethod(for: selector)
        func invalidate(_ view: UIView) {
            if view.method(for: selector) != inherited { view.setNeedsDisplay() }
            view.subviews.forEach(invalidate)
        }
        subviews.forEach(invalidate)
    }

    // A page column shows its slice from the top, always: UIKit's selection autoscroll must not
    // reveal the clipped context line.
    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set { super.contentOffset = isPageColumn ? .zero : newValue }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        super.setContentOffset(isPageColumn ? .zero : contentOffset, animated: animated)
    }

    /// Where Copy writes; the general pasteboard outside tests.
    var pasteboard = UIPasteboard.general

    // Copy carries the reader's text: attachments as their alt text, never U+FFFC.
    override func copy(_ sender: Any?) {
        let text = canvas?.selectionText(for: self) ?? plainText(in: selectedRange)
        guard !text.isEmpty else { return }
        pasteboard.string = text
    }

    // MARK: Keys and accessibility

    override var keyCommands: [UIKeyCommand]? {
        guard let canvas else { return super.keyCommands }
        let pageCommands = canvas.pageKeyCommands
        // Replace only explicitly bound native text commands. Removed bindings fall back to
        // the text view's ordinary selection/scroll handling.
        let native = (super.keyCommands ?? []).filter { command in
            !pageCommands.contains { $0.input == command.input && $0.modifierFlags == command.modifierFlags }
        }
        return pageCommands + native
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(pageTurnKeyCommand(_:)), let command = sender as? UIKeyCommand {
            guard let canvas else { return false }
            return Self.pageTurnDirection(input: command.input, flags: command.modifierFlags,
                                          controls: canvas.configuration.pageControls) != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func pageTurnKeyCommand(_ command: UIKeyCommand) { canvas?.pageTurnKeyCommand(command) }

    static func pageTurnDirection(input: String?, flags: UIKeyModifierFlags,
                                  controls: EPUBPageControls = .init()) -> Bool? {
        guard let input, let key = EPUBPageKey(uiInput: input) else { return nil }
        return controls.direction(for: key, modifiers: EPUBPageKeyModifiers(uiFlags: flags))
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard isPageColumn, let canvas else { return super.accessibilityScroll(direction) }
        return canvas.accessibilityScroll(direction)
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            // VoiceOver offers a container's actions on every element in it, after the
            // element's own. A view that lists its lines offers none: each line offers what
            // is in it. With UIKit's actions here, one for every link of the text, and the
            // reader's for its images, a plain line offered the picture beside it, and a line
            // of continuous scroll every link of the book.
            guard !listsLines else { return nil }
            // A note keeps UIKit's elements and what UIKit offers for them. The reader has
            // nothing to add there: a note has no canvas to inspect an image in.
            return super.accessibilityCustomActions
        }
        set { super.accessibilityCustomActions = newValue }
    }

    // UIKit's native text accessibility can traverse TextKit's hidden paragraph context even
    // with a shortened accessibilityValue. Expose only measured visible lines, splitting links
    // and attachments into independently actionable elements, and a heading as one element
    // with the header trait and its level. Visual text and selection retain the original
    // TextKit 2 storage and all of its paragraph layout context.
    //
    // The canvas's scroll view lists its lines too. UIKit's own elements are every paragraph of
    // the book, and VoiceOver moving into the text takes the first: the book's first paragraph,
    // which it scrolls the reader back to, wherever the reader was.
    override var isAccessibilityElement: Bool {
        get { listsLines ? false : super.isAccessibilityElement }
        set { super.isAccessibilityElement = newValue }
    }

    override var accessibilityElements: [Any]? {
        get { listsLines ? listedAccessibilityElements : super.accessibilityElements }
        set { super.accessibilityElements = newValue }
    }

    override func accessibilityElementCount() -> Int {
        listsLines ? listedAccessibilityElements.count : super.accessibilityElementCount()
    }

    override func accessibilityElement(at index: Int) -> Any? {
        guard listsLines else { return super.accessibilityElement(at: index) }
        let elements = listedAccessibilityElements
        return elements.indices.contains(index) ? elements[index] : nil
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        guard listsLines else { return super.index(ofAccessibilityElement: element) }
        let elements = accessibilityList.listed
        if let index = elements.firstIndex(where: { $0 === element as AnyObject }) { return index }
        // A bar's stand-in follows the last line, and UIKit's own bar is where its stand-in is.
        if let index = scrollBarListed.firstIndex(where: { $0 === element as AnyObject || $0.bar === element as AnyObject }) {
            return elements.count + index
        }
        // An element kept from before the list moved away and back stands for its line, which
        // is known by its place in the book. A page column counts characters from its page's
        // first: by those, a line of the page before stood for whichever line of the page
        // turned to had the same ones, and VoiceOver went on from the middle of that page.
        // A table kept so stands for the rows of it listed now.
        if let kept = element as? ReaderTableAccessibilityElement, kept.view === self {
            return elements.firstIndex { ($0 as? ReaderTableAccessibilityElement)?.table === kept.table } ?? NSNotFound
        }
        guard let kept = element as? ReaderPageAccessibilityElement, !(kept is ReaderTableCellAccessibilityElement),
              kept.view === self else { return NSNotFound }
        return elements.firstIndex { ($0 as? ReaderPageAccessibilityElement)?.isSameLine(as: kept) == true } ?? NSNotFound
    }

    /// Whether an assistive technology's cursor is on a line of a page this column no longer
    /// shows: the page was turned under it. A table's cell is listed by its table and has no
    /// place in the column's own list, so it is looked for among the cells listed.
    var accessibilityCursorHasLeftThePage: Bool {
        guard let cursor = pageAccessibilityCursor else { return false }
        if cursor is ReaderTableCellAccessibilityElement { return !lineAccessibilityElements.contains { cursor.isSameLine(as: $0) } }
        return index(ofAccessibilityElement: cursor) == NSNotFound
    }

    /// The line that holds `location`, in this view's characters, or the first one listed after it.
    func accessibilityLine(from location: Int) -> Any? {
        guard listsLines else { return nil }
        return lineAccessibilityElements.first { NSMaxRange($0.range) > location }
    }

    /// Has the element an assistive technology's cursor was left on in this column stand for
    /// `line`, a line of the page now shown, here or in another column, and gives it that
    /// line's place in the list. The answer is the element the cursor is on: that one, or
    /// `line` where no cursor was left. VoiceOver keeps what was chosen in its rotor while
    /// its cursor stays on one item, as a line's Next Page, and on coming to another item
    /// its rotor is at its default. A data table's cell is an element of another kind, inside
    /// its table's: it becomes no line and no line becomes one, so from a cell or to one the
    /// answer is `line`.
    func accessibilityCursorStands(for line: Any?) -> Any? {
        guard let line = line as? ReaderPageAccessibilityElement, let cursor = pageAccessibilityCursor, cursor !== line,
              !(cursor is ReaderTableCellAccessibilityElement), !(line is ReaderTableCellAccessibilityElement),
              let view = line.view, var list = view.pageAccessibilityCache,
              let index = list.elements.firstIndex(where: { $0 === line }),
              let place = list.listed.firstIndex(where: { $0 === line }) else { return line }
        cursor.stand(for: line)
        list.elements[index] = cursor
        list.listed[place] = cursor
        view.pageAccessibilityCache = list
        pageAccessibilityCursor = nil
        view.pageAccessibilityCursor = cursor
        return cursor
    }

    // VoiceOver's own Headings rotor moves among the elements it is given, and a page or a
    // screen holds few of a book's headings: past the last of them it finds none. So the lines'
    // container gives VoiceOver that rotor itself, and goes on to the book's next heading.
    // A rotor is not an action: VoiceOver says "Actions available" of a line for the actions
    // the line is offered, with this rotor and without it.
    override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
        get { listsLines ? [headingRotor] : super.accessibilityCustomRotors }
        set { super.accessibilityCustomRotors = newValue }
    }

    /// The heading of the book after or before the item under VoiceOver's cursor: on the page
    /// or the screen when it is there, and otherwise wherever it is, which the reader turns or
    /// scrolls to. A heading in several elements, around a link, is one stop, at its first
    /// words. The search goes by the item's place in the book, not by where it is listed:
    /// VoiceOver asks twice for one move, the second time from the same item, though the first
    /// answer may have turned the page that item was on, and both answers must be the same.
    private func heading(for predicate: UIAccessibilityCustomRotorSearchPredicate) -> UIAccessibilityCustomRotorItemResult? {
        guard let canvas else { return nil }
        let forward = predicate.searchDirection == .next
        var from = (predicate.currentItem.targetElement as? ReaderPageAccessibilityElement)?.position
        if from == nil {
            // With the cursor on none of the reader's lines: from before the first listed, or after the last.
            let listed = lineAccessibilityElements
            if forward {
                from = listed.first?.position.map { ReaderTextPosition(section: $0.section, offset: $0.offset - 1) }
            } else {
                from = listed.last.flatMap { canvas.position(at: NSMaxRange($0.range), in: self) }
            }
        }
        guard let from, let target = canvas.heading(from: from, forward: forward) else { return nil }
        func shown() -> ReaderPageAccessibilityElement? {
            for view in canvas.textViews {
                guard let local = canvas.localRange(of: ReaderTextRange(section: target.section, target.offset..<(target.offset + 1)), in: view)
                else { continue }
                if let element = view.lineAccessibilityElements.first(where: { NSLocationInRange(local.location, $0.range) }) { return element }
            }
            return nil
        }
        // It can be on the page or the screen already; otherwise the reader goes to it.
        if shown() == nil { canvas.showForAccessibilityRotor(target) }
        return shown().map { UIAccessibilityCustomRotorItemResult(targetElement: $0, targetRange: nil) }
    }

    /// A page column and the canvas's scroll view list their lines; a note keeps UIKit's elements.
    private var listsLines: Bool { isPageColumn || isCanvasScrollView }

    private var isCanvasScrollView: Bool { !isPageColumn && canvas?.scrollTextView === self }

    private var accessibilityList: ReaderAccessibilityList {
        isPageColumn ? pageAccessibilityElements : scrollAccessibilityElements
    }

    /// Every line and every table cell listed, in reading order.
    private var lineAccessibilityElements: [ReaderPageAccessibilityElement] { accessibilityList.elements }

    /// What the view lists: its lines, a table's cells inside an element for the table, and
    /// after them a stand-in for each of the scroll view's own bars.
    private var listedAccessibilityElements: [NSObject] { accessibilityList.listed + (scrollBarListed as [NSObject]) }

    private var pageAccessibilityElements: ReaderAccessibilityList {
        if let pageAccessibilityCache { return pageAccessibilityCache }
        let list = self.list(accessibilityElements(for: pageAccessibilityLines, reusing: []))
        pageAccessibilityCache = list
        return list
    }

    /// `elements` as an assistive technology is given them: each line, and a table's cells
    /// inside an element for the table. A table's rows follow one another, so its cells do
    /// too, also when the rows around a resting cursor and the rows on screen are listed
    /// apart: one element holds both. A table keeps its element while any cell of it stays listed.
    private func list(_ elements: [ReaderPageAccessibilityElement]) -> ReaderAccessibilityList {
        var listed: [NSObject] = [], run: [ReaderTableCellAccessibilityElement] = []
        func close() {
            guard let first = run.first else { return }
            let table = run.lazy.compactMap { $0.accessibilityContainer as? ReaderTableAccessibilityElement }.first
                ?? ReaderTableAccessibilityElement(view: self, table: first.table)
            table.list(run)
            listed.append(table)
            run = []
        }
        for element in elements {
            guard let cell = element as? ReaderTableCellAccessibilityElement else { close(); listed.append(element); continue }
            if let last = run.last, last.table !== cell.table { close() }
            run.append(cell)
        }
        close()
        return ReaderAccessibilityList(elements: elements, listed: listed)
    }

    /// The scroll view's own scroll bars, as elements the view lists itself after its last line.
    ///
    /// UIKit gives VoiceOver a scroll view's bar after the view's last element and then holds
    /// the bar to stand before the first: it keeps the bar among the views it calls the scroll
    /// view's supplementary headers, and asked for the items each side of a header it answers
    /// with the first line listed and with the control before the scroll view. So VoiceOver
    /// read the screen a second time after the book's last line, and went back from the bar
    /// to the control before the text. A bar hidden from assistive technology is no such
    /// header, and is not given to VoiceOver at all. So each bar is hidden, and an element of
    /// the reader's own is listed in its place: it says what the bar says and adjusts as the
    /// bar adjusts, by asking the bar, and being an element of the list like any line it has
    /// the last line before it and whatever follows the scroll view after it. A bar is a view
    /// of the scroll view's own that is an accessibility element: the lines are no views.
    private var scrollBarListed: [ReaderScrollBarAccessibilityElement] {
        guard isCanvasScrollView else { return [] }
        scrollBarElements.removeAll { $0.bar.superview !== self }
        for bar in subviews where bar.isAccessibilityElement && !bar.accessibilityElementsHidden {
            bar.accessibilityElementsHidden = true
            scrollBarElements.append(ReaderScrollBarAccessibilityElement(view: self, bar: bar))
        }
        scrollBarElements.forEach { $0.refresh() }
        return scrollBarElements
    }

    /// Where a bar's stand-in is for VoiceOver: the bar's own place, less what the insets
    /// cover. UIKit scrolls the view until the area the insets leave holds the frame of the
    /// item the cursor goes to, and a bar is as tall as the view: for the bar itself the view
    /// went back by the top inset and 40 points at every move to it.
    fileprivate func accessibilityFrame(ofScrollBar bar: UIView) -> CGRect {
        let area = UIAccessibility.convertToScreenCoordinates(bounds.inset(by: adjustedContentInset), in: self)
        let frame = bar.accessibilityFrame
        return CGRect(x: frame.minX, y: area.minY, width: frame.width, height: area.height)
    }

    /// `area` of this view, less the side a scroll bar is on. A touch on the bar reached
    /// UIKit's bar, a view, before any line the scroll view lists. An element in its place is
    /// one of those the touch is tried against, and VoiceOver took a line that ended within a
    /// few points of the finger for the one touched: a full line of a paragraph runs under
    /// the bar's place, which is ten times as wide as the bar is drawn.
    private func clearOfScrollBars(_ area: CGRect) -> CGRect {
        var area = area
        // An element's frame is the screen's. The view is upright on it and at its scale.
        let origin = UIAccessibility.convertToScreenCoordinates(bounds, in: self).origin
        for element in scrollBarListed {
            let bar = element.bar.accessibilityFrame.offsetBy(dx: bounds.minX - origin.x, dy: bounds.minY - origin.y)
            guard bar.height > bar.width else { continue }
            let (minX, maxX) = bar.midX > area.midX ? (area.minX, min(area.maxX, bar.minX)) : (max(area.minX, bar.maxX), area.maxX)
            area = CGRect(x: minX, y: area.minY, width: max(0, maxX - minX), height: area.height)
        }
        return area
    }

    /// An assistive technology's cursor came to a bar's stand-in.
    fileprivate func accessibilityCursorMovedToScrollBar() {
        accessibilityCursor = nil
        accessibilityCursorFollowsText = true
    }

    /// The lines VoiceOver is given in continuous scroll: those on screen and the fifty after
    /// them. Moving into the text from a control it takes the first line listed, the first on
    /// screen. Moving back into it from below it takes the last, so while its cursor is on
    /// something that follows the text the list is the lines on screen alone and that is the
    /// last of them, or the line it was given as the last a move ago (`lastLineKept`).
    ///
    /// VoiceOver asks for the items after the one its cursor is on, then moves through what it
    /// was given and asks again only when it has used them. As a rule it asks for two. At its
    /// first move after the screen has changed under it, as when a menu closes, it asks for
    /// fifty each way: given the lines on screen alone, it read to the last of them and went on
    /// to the scroll bar. While its cursor is on a line, fifty are listed each side of the
    /// screen and of that line: UIKit scrolls the line it lands on into view, and so it reads on
    /// through the book in either direction. A line keeps its element while it is listed or
    /// under the cursor.
    private var scrollAccessibilityElements: ReaderAccessibilityList {
        guard let canvas else { return ReaderAccessibilityList() }
        let place = ScrollAccessibilityPlace(offset: contentOffset, size: bounds.size, content: contentSize,
                                             insets: adjustedContentInset, cursor: accessibilityCursor.map(ObjectIdentifier.init),
                                             cursorFollowsText: accessibilityCursorFollowsText, bars: scrollBarListed.count)
        if let cache = scrollAccessibilityCache, cache.place == place { return cache.list }
        guard let shown = canvas.scrollSpokenCharacters() else { return ReaderAccessibilityList() }
        let past = Self.accessibilityLinesPastScreen
        var listed = [withLines(before: 0, after: accessibilityCursorFollowsText ? 0 : past, shown)]
        if accessibilityCursorFollowsText, let kept = lastLineKept(past: shown) { listed = [shown.union(kept)] }
        if let cursor = accessibilityCursor, var held = line(containing: cursor.range.location)?.range {
            // A heading under the cursor can take several lines.
            if let last = line(containing: NSMaxRange(cursor.range) - 1) { held.formUnion(last.range) }
            let screen = withLines(before: past, after: past, shown), around = withLines(before: past, after: past, held)
            // The cursor can rest on a line the person has since scrolled away from.
            if NSMaxRange(around) < screen.location { listed = [around, screen] }
            else if NSMaxRange(screen) < around.location { listed = [screen, around] }
            else { listed = [screen.union(around)] }
        }
        let lines = listed.flatMap(measuredLines(in:))
        let existing = (scrollAccessibilityCache?.list.elements ?? []) + [accessibilityCursor].compactMap { $0 }
        var elements = accessibilityElements(for: lines, reusing: existing)
        // A screen of decoration alone lists it, whatever is listed past the screen: VoiceOver
        // would otherwise come in at a line below the screen, and the reader would go there.
        if !elements.contains(where: { NSIntersectionRange($0.range, shown).length > 0 }) {
            elements = accessibilityElements(for: lines, reusing: existing, passingOverDecoration: true, keepingDecorationIn: shown)
        }
        // UIKit scrolls the line the cursor comes to until the area the insets leave holds its
        // frame, and then 40 points further. A first line on screen that the top inset cuts
        // would move the reader as VoiceOver came in, so a line on screen is listed by the
        // part of it in that area, and by the part clear of the scroll bar.
        let area = clearOfScrollBars(canvas.scrollVisibleContainerRect.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y))
        for element in elements where NSIntersectionRange(element.range, shown).length > 0 {
            var frame = element.accessibilityFrameInContainerSpace
            // Hidden labels standing at the top with the first line can be a fraction above it.
            if frame.maxY <= area.minY { frame.origin.y = area.minY }
            frame = frame.intersection(area)
            if !frame.isEmpty { element.accessibilityFrameInContainerSpace = frame }
        }
        let list = self.list(elements)
        scrollAccessibilityCache = (place, list)
        return list
    }

    /// The line the list goes on ending at while VoiceOver's cursor is after the text, where
    /// that is no longer the last line on screen.
    ///
    /// As its cursor comes to a control below the reader VoiceOver is given the scroll bar and
    /// the last line listed, and at its next move it asks for the line before that one. In
    /// between it has UIKit bring the bar into view as it would a line. The bar is as tall as
    /// the view, the top inset cuts it, and the view goes back by that inset and 40 points
    /// more, wherever it has the room: the line VoiceOver holds is then below the screen, and
    /// asked from a line that was no longer listed UIKit answered with the control before the
    /// text. So the list still ends at the line it ended at when it was last made with the
    /// cursor after the text, with the lines between that line and the screen, while the view
    /// has gone back no further than one such move since. That holds each time the cursor
    /// goes to the bar. After a longer move back, the person's or the reader's own, or a move
    /// forward past that line, the list ends at the last line on screen again.
    private func lastLineKept(past shown: NSRange) -> NSRange? {
        guard let cache = scrollAccessibilityCache, cache.place.cursorFollowsText, cache.place.size == bounds.size,
              cache.place.insets == adjustedContentInset, let last = cache.list.elements.last?.range,
              NSMaxRange(last) > NSMaxRange(shown) else { return nil }
        guard cache.place.offset.y - contentOffset.y <= adjustedContentInset.top + Self.accessibilityScrollMargin + 1 else { return nil }
        // The last element can be part of its line: a link, or the words before one.
        return line(containing: NSMaxRange(last) - 1).map { last.union($0.range) } ?? last
    }

    /// `range` with as many lines before it and after it, where the text has them.
    private func withLines(before: Int, after: Int, _ range: NSRange) -> NSRange {
        var result = range
        for _ in 0..<before {
            guard result.location > 0, let line = line(containing: result.location - 1) else { break }
            result.formUnion(line.range)
        }
        for _ in 0..<after {
            guard NSMaxRange(result) < textLength, let line = line(containing: NSMaxRange(result)) else { break }
            result.formUnion(line.range)
        }
        return result
    }

    /// An assistive technology's cursor came to `element`, a line of this view.
    fileprivate func accessibilityCursorMoved(to element: ReaderPageAccessibilityElement) {
        if isPageColumn { pageAccessibilityCursor = element }
        guard isCanvasScrollView else { return }
        accessibilityCursor = element
        accessibilityCursorFollowsText = false
    }

    /// Lists the lines again if the view or the cursor has moved since they were listed. A
    /// table's element is asked for its cells without the text view being asked first.
    fileprivate func updateAccessibilityList() {
        if listsLines { _ = accessibilityList }
    }

    /// The cursor went to something that is not one of this view's lines, or VoiceOver was
    /// switched. Each move posts two focus notifications, the first naming only the element
    /// left, and a line left is told so before the next is told it has the cursor: taking
    /// either for the cursor leaving the text shrank the list to the screen for a moment, and
    /// VoiceOver then stopped at a line it had reached above the screen.
    @objc private func accessibilityFocusChanged(_ notification: Notification) {
        var followsText = false
        if notification.name == UIAccessibility.elementFocusedNotification {
            guard let focused = notification.userInfo?[UIAccessibility.focusedElementUserInfoKey],
                  (focused as? ReaderPageAccessibilityElement)?.view !== self,
                  (focused as? ReaderScrollBarAccessibilityElement)?.view !== self else { return }
            followsText = isCanvasScrollView && accessibilityOrderPutsAfterLines(focused)
        }
        pageAccessibilityCursor = nil
        accessibilityCursor = nil
        accessibilityCursorFollowsText = followsText
    }

    /// Whether VoiceOver reaches `element` after this scroll view's lines: UIKit lists the
    /// scroll view's own bars after them, and what lies below the reading area follows those.
    private func accessibilityOrderPutsAfterLines(_ element: Any) -> Bool {
        if let view = element as? UIView, view.isDescendant(of: self) { return true }
        guard let canvas, let frame = (element as? NSObject)?.accessibilityFrame, !frame.isEmpty else { return false }
        let area = canvas.scrollVisibleContainerRect.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)
        return frame.minY >= UIAccessibility.convertToScreenCoordinates(area, in: self).maxY - 1
    }

    /// One element for each line, except where a link or attachment needs its own, and one for
    /// a heading's text however many lines it takes: VoiceOver reads it whole, says it is a
    /// heading once and stops on it once when it moves by heading. An image the book marks as
    /// decoration has none, unless nothing on the page can be read without it, or nothing on
    /// screen in continuous scroll: a page or a screen that holds decoration alone would leave
    /// VoiceOver no place there to turn the page or read on from, so its images are listed, as
    /// images without a name.
    /// A rule always has one, so a page that holds a rule alone is turned from the rule.
    private func accessibilityElements(for lines: [ReaderVisualLine],
                                       reusing existing: [ReaderPageAccessibilityElement]) -> [ReaderPageAccessibilityElement] {
        let elements = accessibilityElements(for: lines, reusing: existing, passingOverDecoration: true)
        return elements.isEmpty ? accessibilityElements(for: lines, reusing: existing, passingOverDecoration: false) : elements
    }

    /// The elements of `lines`. Decoration that is passed over is still listed in `kept`.
    private func accessibilityElements(for lines: [ReaderVisualLine], reusing existing: [ReaderPageAccessibilityElement],
                                       passingOverDecoration: Bool, keepingDecorationIn kept: NSRange? = nil) -> [ReaderPageAccessibilityElement] {
        guard let storage = contentStorage.textStorage else { return [] }
        let text = storage.string as NSString
        var elements: [ReaderPageAccessibilityElement] = []
        // A table's cells by table and cell, those listed before and those listed so far: a
        // table of a thousand cells is listed in time linear in them.
        var keptCells: [ReaderTableCellKey: ReaderTableCellAccessibilityElement] = [:], cells = keptCells
        for case let cell as ReaderTableCellAccessibilityElement in existing { keptCells[cell.key] = cell }
        for line in lines {
            // Layout flags (often stored on a paragraph's first UTF-16 unit), colors and
            // fonts do not define AX reading units. Keep each actual line intact except
            // where a link, an attachment or a heading needs its own label and behavior.
            var runs: [(range: NSRange, url: URL?, attachment: NSTextAttachment?, heading: ReaderHeading?)] = []
            storage.enumerateAttributes(in: line.range) { attributes, range, _ in
                let url = attributes[.link] as? URL ?? (attributes[.link] as? String).flatMap(URL.init(string:))
                let attachment = listedAttachment(attributes, at: range, passingOverDecoration: passingOverDecoration
                                                  && NSIntersectionRange(kept ?? NSRange(), range).length == 0)
                var heading = attributes[.readerHeading] as? ReaderHeading
                if let previous = runs.last, NSMaxRange(previous.range) == range.location,
                   previous.url == url, previous.attachment === attachment {
                    // The break that ends a heading's line is read with it, as any line's is.
                    if heading == nil, attachment == nil, previous.heading != nil, Self.isBreak(text, range) { heading = previous.heading }
                    if previous.heading === heading {
                        runs[runs.count - 1].range.length += range.length
                        return
                    }
                }
                runs.append((range, url, attachment, heading))
            }
            for (run, url, attachment, heading) in runs {
                // A data table's row is its cells, each an element inside the table's.
                if let row = attachment as? TableRowAttachment, row.table.isData {
                    appendCells(of: row, at: run, line: line, reusing: keptCells, listed: &cells, to: &elements)
                    continue
                }
                var range = run
                if heading != nil, attachment == nil {
                    range = headingText(at: run.location, passingOverDecoration: passingOverDecoration)
                    // The line before this one gave the same heading.
                    if let last = elements.last, last.range == range, last.url == url { continue }
                }
                var label: String? = plainText(in: range)
                // The break after an attachment that ends its paragraph is a run of its own
                // with nothing to say, and so is decoration between two of them: no element,
                // or VoiceOver stops on silence.
                if attachment == nil, label?.allSatisfy(\.isWhitespace) != false { continue }
                var traits: UIAccessibilityTraits = url == nil ? .staticText : .link
                // A hidden label is words the page does not show, not a picture.
                let isSpoken = attachment is SpokenLabelAttachment
                // A table row is its cells' words, read once where the row stands. A row that
                // shows pictures and no words is an image and no more, as a picture without
                // words in a line is. One with nothing to say, or decoration alone, has no
                // element, unless nothing listed can be read without it.
                let isRow = attachment is TableRowAttachment
                let isWordlessRow = isRow && label?.allSatisfy(\.isWhitespace) != false
                if isWordlessRow, passingOverDecoration, announcedImages(in: range).isEmpty { continue }
                let element = existing.first { $0.range == range && $0.url == url }
                    ?? ReaderPageAccessibilityElement(view: self, range: range, url: url)
                element.image = attachment as? ReaderImageAttachment
                if attachment is ReaderRuleAttachment {
                    // A rule is a break between what stands before it and what follows:
                    // not a picture, which VoiceOver would call an image, and not words of
                    // the book. UIKit has no trait for a separator, so VoiceOver has no word
                    // of its own for one and the reader names it.
                    label = ReaderRuleAttachment.spokenName
                    traits.remove(.staticText)
                } else if isRow {
                    if isWordlessRow { label = nil; traits.insert(.image) }
                } else if attachment != nil {
                    if !isSpoken { traits.insert(.image) }
                    // An image without words is an image and no more: the trait says so, in
                    // VoiceOver's own language, and the reader makes up no name for it.
                    if let image = attachment as? ReaderImageAttachment { label = image.alt.isEmpty ? nil : image.alt }
                    // A formula's reading has its own voice: the book's language or the generator's.
                    if let language = (attachment as? ReaderTextualAttachment)?.textLanguage {
                        element.accessibilityLanguage = language
                    }
                }
                // A heading is read as its words: with its paragraph's break after them VoiceOver
                // ends the phrase there, before it has said that this is a heading.
                if heading != nil, let words = label, let end = words.lastIndex(where: { !$0.isNewline }) { label = String(words[...end]) }
                element.accessibilityLabel = label
                element.position = canvas?.position(at: range.location, in: self)
                if let heading {
                    traits.insert(.header)
                    // VoiceOver takes a heading's level from its label's attributes; 0 is none.
                    if let label {
                        element.accessibilityAttributedLabel = NSAttributedString(
                            string: label, attributes: [.accessibilityTextHeadingLevel: heading.level])
                    }
                }
                element.accessibilityTraits = traits
                // A scroll view's bounds move with its content, and a line listed past the
                // screen is outside them.
                if range != run { ensureLayout(from: range.location, through: NSMaxRange(range) - 1) }
                var frame = segmentFrames(for: range).reduce(CGRect.null) { $0.union($1) }
                if frame.isNull { frame = line.frame }
                // It takes no room; a point where it stands lets VoiceOver rest on it.
                if isSpoken { frame.size = CGSize(width: max(frame.width, 1), height: max(frame.height, 1)) }
                let placed = frame.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)
                element.accessibilityFrameInContainerSpace = isPageColumn ? placed.intersection(bounds) : placed
                elements.append(element)
            }
        }
        return elements
    }

    /// The attachment an element is made for at `range`, or nil. Decoration that is passed
    /// over is part of the text it stands in, with nothing to say; one that was listed keeps
    /// its element while the cursor is on it.
    private func listedAttachment(_ attributes: [NSAttributedString.Key: Any], at range: NSRange,
                                  passingOverDecoration: Bool) -> NSTextAttachment? {
        let attachment = attributes[.attachment] as? NSTextAttachment
        if passingOverDecoration, let image = attachment as? ReaderImageAttachment, isPassedOver(image, at: range),
           accessibilityCursor?.image !== image || accessibilityCursor?.range != range { return nil }
        return attachment
    }

    /// Whether `range` holds nothing but the characters that end a line or a paragraph.
    private static func isBreak(_ text: NSString, _ range: NSRange) -> Bool {
        range.length > 0 && text.rangeOfCharacter(from: CharacterSet.newlines.inverted, range: range).location == NSNotFound
    }

    /// What one element reads of the heading at `location`: its text there over every line it
    /// takes, as far as a link or an attachment in it begins or ends, with the break that ends
    /// its paragraph. A page column gives the part on its page. The same characters whichever
    /// of the heading's lines is asked for, so a line listed later finds the element already
    /// there, and a heading half above the screen in continuous scroll keeps one element as
    /// more of its lines are listed.
    private func headingText(at location: Int, passingOverDecoration: Bool) -> NSRange {
        let unknown = NSRange(location: location, length: 0)
        guard let storage = contentStorage.textStorage else { return unknown }
        let bounds = isPageColumn ? shownCharacters : NSRange(location: 0, length: storage.length)
        var whole = NSRange()
        guard NSLocationInRange(location, bounds),
              storage.attribute(.readerHeading, at: location, longestEffectiveRange: &whole, in: bounds) != nil else { return unknown }
        func link(_ attributes: [NSAttributedString.Key: Any]) -> URL? {
            attributes[.link] as? URL ?? (attributes[.link] as? String).flatMap(URL.init(string:))
        }
        let own = link(storage.attributes(at: location, effectiveRange: nil))
        var found = unknown, ended = false
        storage.enumerateAttributes(in: whole) { attributes, range, stop in
            if listedAttachment(attributes, at: range, passingOverDecoration: passingOverDecoration) == nil, link(attributes) == own {
                found = found.length > 0 ? found.union(range) : range
            } else if range.location > location {
                ended = true
                stop.pointee = true
            } else { found = unknown }
        }
        guard !ended else { return found }
        let text = storage.string as NSString
        var end = NSMaxRange(found)
        while end < NSMaxRange(bounds) {
            let attributes = storage.attributes(at: end, effectiveRange: nil)
            let character = NSRange(location: end, length: 1)
            guard attributes[.readerHeading] == nil, attributes[.attachment] == nil, link(attributes) == own,
                  Self.isBreak(text, character) else { break }
            end += 1
            if text.character(at: end - 1) == 0x0A { break }
        }
        return NSRange(location: found.location, length: end - found.location)
    }

    /// The cells read where a row of a data table stands, after `elements`. A cell that spans
    /// rows is read where it starts; the lines of it that later rows of the same page hold are
    /// added to it there. `kept` are the cells of the listing before, and `cells` those of this one.
    private func appendCells(of row: TableRowAttachment, at range: NSRange, line: ReaderVisualLine,
                             reusing kept: [ReaderTableCellKey: ReaderTableCellAccessibilityElement],
                             listed cells: inout [ReaderTableCellKey: ReaderTableCellAccessibilityElement],
                             to elements: inout [ReaderPageAccessibilityElement]) {
        let rowFrame = segmentFrames(for: range).first ?? line.frame
        for spoken in row.spokenCells(size: rowFrame.size, viewportHeight: readerContainer.viewportSize.height) {
            let key = ReaderTableCellKey(table: ObjectIdentifier(row.table), cell: spoken.cell)
            if let listed = cells[key] {
                if !spoken.text.isEmpty {
                    listed.accessibilityLabel = [listed.accessibilityLabel ?? "", spoken.text].filter { !$0.isEmpty }.joined(separator: " ")
                    listed.accessibilityTraits.remove(.image)
                }
                listed.images += spoken.images
                listed.continuations.append(range.location)
                continue
            }
            // A cell is listed where it has something to say. One that says nothing anywhere
            // is listed where it starts, for its place in the grid; one whose words stand on a
            // later page, as a short cell centred beside a tall one does, is listed there.
            guard !spoken.text.isEmpty || !spoken.images.isEmpty || (spoken.starts && spoken.isBlank) else { continue }
            let element = kept[key].flatMap { $0.range == range ? $0 : nil }
                ?? ReaderTableCellAccessibilityElement(view: self, range: range, table: row.table, cell: spoken.cell)
            cells[key] = element
            element.accessibilityLabel = spoken.text.isEmpty ? nil : spoken.text
            element.position = canvas?.position(at: range.location, in: self)
            element.continuations = []
            element.images = spoken.images
            // A cell of pictures without words is an image and no more, as a picture in a line is.
            var traits: UIAccessibilityTraits = .staticText
            if spoken.text.isEmpty, !spoken.images.isEmpty { traits.insert(.image) }
            if element.isLink { traits = .link }
            element.accessibilityTraits = traits
            let placed = spoken.frame.offsetBy(dx: rowFrame.minX + containerOrigin.x, dy: rowFrame.minY + containerOrigin.y)
            element.accessibilityFrameInContainerSpace = isPageColumn ? placed.intersection(bounds) : placed
            elements.append(element)
        }
    }

    // VoiceOver reads the page, not the clipped context after it, with attachments as their text.
    override var accessibilityValue: String? {
        get { isPageColumn ? visibleText : super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }

    /// UIKit reads an attachment in text by its accessibility label: give each one that stands
    /// for text its text equivalent, unless it labels itself.
    func exposeTextualAttachments() {
        pageAccessibilityCache = nil
        scrollAccessibilityCache = nil
        accessibilityCursor = nil
        for (attachment, text, _) in textualAttachments() where attachment.accessibilityLabel == nil {
            attachment.accessibilityLabel = text
        }
    }
}

/// Where a scroll view stood, and the line under an assistive technology's cursor, when its
/// lines were listed.
private struct ScrollAccessibilityPlace: Equatable {
    var offset: CGPoint
    var size: CGSize
    var content: CGSize
    var insets: UIEdgeInsets
    var cursor: ObjectIdentifier?
    var cursorFollowsText: Bool
    /// How many scroll bars the lines were listed clear of.
    var bars: Int
}

/// A scroll bar of the canvas's scroll view, as the scroll view lists it: UIKit's own bar,
/// which is hidden from assistive technology, asked for everything it says and does.
@MainActor private final class ReaderScrollBarAccessibilityElement: UIAccessibilityElement {
    private(set) weak var view: ReaderTextView?
    let bar: UIView

    init(view: ReaderTextView, bar: UIView) {
        self.view = view
        self.bar = bar
        super.init(accessibilityContainer: view)
        isAccessibilityElement = true
        refresh()
    }

    /// What the bar says now, and where it is. A subclass of `UIAccessibilityElement` cannot
    /// answer for its label or value itself, so they are read from the bar whenever the
    /// scroll view is asked for its elements, and after the bar is adjusted.
    func refresh() {
        accessibilityLabel = bar.accessibilityLabel
        accessibilityValue = bar.accessibilityValue
        accessibilityHint = bar.accessibilityHint
        accessibilityTraits = bar.accessibilityTraits
        if let view { accessibilityFrame = view.accessibilityFrame(ofScrollBar: bar) }
    }

    override func accessibilityIncrement() {
        bar.accessibilityIncrement()
        adjusted()
    }

    override func accessibilityDecrement() {
        bar.accessibilityDecrement()
        adjusted()
    }

    /// The bar has taken the view a tenth of the way through the book, with the cursor still
    /// here, and UIKit tells VoiceOver nothing of it. VoiceOver holds the two lines it was
    /// given before this element when its cursor came here. They are screens away now, no
    /// longer listed, and the elements that stood for them are gone. At its next move back
    /// VoiceOver found the nearer one gone and asked again from here, and then asked for one
    /// more from the further: for an element UIKit no longer knew it was given nothing, noted
    /// that as the start of the list, and two lines up it stayed where it was at every move
    /// back. A layout change that names this element has VoiceOver drop what it holds and
    /// ask again for the items each side of it, and it says nothing more for that than the
    /// bar's new value.
    private func adjusted() {
        refresh()
        view?.canvas?.postAccessibilityNotification(.layoutChanged, self)
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        view?.accessibilityScroll(direction) ?? false
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        view?.accessibilityCursorMovedToScrollBar()
    }
}

/// What a text view that lists its lines gives an assistive technology: `elements`, every line
/// and every table cell in reading order, and `listed`, the same with each table's cells inside
/// an element for the table.
private struct ReaderAccessibilityList {
    var elements: [ReaderPageAccessibilityElement] = []
    var listed: [NSObject] = []
}

/// A bounded slice of one visible line. VoiceOver's word/character navigation operates on
/// this label rather than the native text view's longer paragraph storage.
@MainActor private class ReaderPageAccessibilityElement: UIAccessibilityElement {
    weak var view: ReaderTextView?
    private(set) var range: NSRange
    private(set) var url: URL?
    /// Where the element's first character is in the book. It holds when the page the element
    /// was on has been turned, which is when VoiceOver asks the Headings rotor about it again.
    var position: ReaderTextPosition?
    /// The image the element stands for, when it is one.
    var image: ReaderImageAttachment?

    /// Whether `other` is the same characters of the book, wherever each view counted them from.
    func isSameLine(as other: ReaderPageAccessibilityElement) -> Bool {
        guard url == other.url, range.length == other.range.length else { return false }
        if let position, let place = other.position { return position == place }
        return position == nil && other.position == nil && range == other.range
    }

    init(view: ReaderTextView, range: NSRange, url: URL?) {
        self.view = view
        self.range = range
        self.url = url
        super.init(accessibilityContainer: view)
        isAccessibilityElement = true
    }

    /// Becomes `line`, an element made for a line of the page now shown: its characters, its
    /// words, where it stands, what it is and so what it offers. Nothing of the line this
    /// element stood for is kept.
    func stand(for line: ReaderPageAccessibilityElement) {
        view = line.view
        accessibilityContainer = line.accessibilityContainer
        range = line.range
        url = line.url
        position = line.position
        image = line.image
        // A heading's level is in its attributed label, which is set after the label, as for
        // a new element, and is not left on an element that was a heading.
        accessibilityAttributedLabel = nil
        accessibilityLabel = line.accessibilityLabel
        if let label = line.accessibilityAttributedLabel { accessibilityAttributedLabel = label }
        accessibilityTraits = line.accessibilityTraits
        accessibilityLanguage = line.accessibilityLanguage
        accessibilityFrameInContainerSpace = line.accessibilityFrameInContainerSpace
    }

    override func accessibilityActivate() -> Bool {
        guard let view, let canvas = view.canvas else { return false }
        if let url { canvas.activateLink(url, range: range, in: view); return true }
        if let image = image ?? view.announcedImages(in: range).first?.image { canvas.inspectImage(image); return true }
        return false
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        view?.accessibilityScroll(direction) ?? false
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        view?.accessibilityCursorMoved(to: self)
    }

    /// A page's elements turn the page. Continuous scroll scrolls natively, by VoiceOver's own
    /// gesture.
    func pageActions(of view: ReaderTextView) -> [UIAccessibilityCustomAction] {
        guard view.isPageColumn else { return [] }
        return [true, false].map { forward in
            UIAccessibilityCustomAction(name: forward ? "Next Page" : "Previous Page") { [weak view] _ in
                view?.canvas?.turnPageFromAccessibility(forward: forward) ?? false
            }
        }
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard let view else { return nil }
            // These are all VoiceOver is to offer here: it adds the actions of whatever
            // contains the item, and the text view and the reader around it have none.
            var actions = pageActions(of: view)
            actions += (image.map { [$0] } ?? view.announcedImages(in: range).map(\.image)).map { image in
                UIAccessibilityCustomAction(name: image.alt.isEmpty ? "Inspect Image" : "Inspect Image: \(image.alt)") { [weak view] _ in
                    guard let canvas = view?.canvas else { return false }
                    canvas.inspectImage(image)
                    return true
                }
            }
            if view.contentStorage.textStorage?.attribute(.attachment, at: range.location, effectiveRange: nil) is TableRowAttachment {
                actions += (view.tableInteraction?.accessibilityActions(at: range.location) ?? []).map { action in
                    UIAccessibilityCustomAction(name: action.name) { _ in action.perform() }
                }
            }
            return actions.isEmpty ? nil : actions
        }
        set { super.accessibilityCustomActions = newValue }
    }
}

/// A cell among the cells listed: its table, and its index in the table's cells.
private struct ReaderTableCellKey: Hashable {
    let table: ObjectIdentifier
    let cell: Int
}

/// A cell of a data table: an element inside the table's, where its row stands among the lines.
@MainActor private final class ReaderTableCellAccessibilityElement: ReaderPageAccessibilityElement, UIAccessibilityContainerDataTableCell {
    let table: TableModel
    let cell: Int
    var key: ReaderTableCellKey { ReaderTableCellKey(table: ObjectIdentifier(table), cell: cell) }

    /// The pictures the cell shows here that say something.
    var images: [ReaderImageAttachment] = []
    /// The rows after its own, on this page, that hold more of the cell's lines.
    var continuations: [Int] = []

    init(view: ReaderTextView, range: NSRange, table: TableModel, cell: Int) {
        self.table = table
        self.cell = cell
        super.init(view: view, range: range, url: nil)
    }

    /// The cell's words are one link and nothing else: the cell is that link.
    var isLink: Bool {
        let content = table.cells[cell].content
        var links = 0, linked = 0, words = 0
        content.enumerateAttribute(.link, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            let count = (content.string as NSString).substring(with: range).filter { !$0.isWhitespace }.count
            words += count
            if value != nil { links += 1; linked += count }
        }
        return links == 1 && linked == words && words > 0
    }

    func accessibilityRowRange() -> NSRange {
        (accessibilityContainer as? ReaderTableAccessibilityElement)?.asked = self
        return NSRange(location: table.cells[cell].row, length: table.cells[cell].rowSpan)
    }

    func accessibilityColumnRange() -> NSRange {
        (accessibilityContainer as? ReaderTableAccessibilityElement)?.asked = self
        return NSRange(location: table.cells[cell].column, length: table.cells[cell].columnSpan)
    }

    /// What the cell's text views offer for the words shown here, where it is on screen.
    private var interactions: (select: (@MainActor () -> Bool)?, links: [(name: String, perform: @MainActor () -> Bool)]) {
        var select: (@MainActor () -> Bool)?, links: [(name: String, perform: @MainActor () -> Bool)] = []
        for location in [range.location] + continuations {
            guard let found = view?.tableInteraction?.accessibilityActions(at: location, cell: cell) else { continue }
            select = select ?? found.select
            links += found.links
        }
        return (select, links)
    }

    // A double tap follows the cell's link when it has one and no other, and otherwise shows
    // its picture when it has one and no words.
    override func accessibilityActivate() -> Bool {
        guard let view, let canvas = view.canvas else { return false }
        let links = interactions.links
        if links.count == 1 { return links[0].perform() }
        if links.isEmpty, accessibilityLabel == nil, let image = images.first { canvas.inspectImage(image); return true }
        return false
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard let view else { return nil }
            var actions = pageActions(of: view)
            actions += images.map { image in
                UIAccessibilityCustomAction(name: image.alt.isEmpty ? "Inspect Image" : "Inspect Image: \(image.alt)") { [weak view] _ in
                    guard let canvas = view?.canvas else { return false }
                    canvas.inspectImage(image)
                    return true
                }
            }
            let found = interactions
            if let select = found.select { actions.append(UIAccessibilityCustomAction(name: "Select Cell Text") { _ in select() }) }
            actions += found.links.map { link in UIAccessibilityCustomAction(name: "Follow Link: " + link.name) { _ in link.perform() } }
            return actions.isEmpty ? nil : actions
        }
        set { super.accessibilityCustomActions = newValue }
    }

    /// The same cell of the same row with the same words: every cell of a row is at the row's
    /// place in the book, and a row cut at a page's end has a part of a cell on each page.
    override func isSameLine(as other: ReaderPageAccessibilityElement) -> Bool {
        guard let other = other as? ReaderTableCellAccessibilityElement, other.cell == cell,
              other.accessibilityLabel == accessibilityLabel else { return false }
        return super.isSameLine(as: other)
    }

    // The element's container is the table's element, which is no view.
    override var accessibilityFrame: CGRect {
        get { view.map { UIAccessibility.convertToScreenCoordinates(accessibilityFrameInContainerSpace, in: $0) } ?? super.accessibilityFrame }
        set { super.accessibilityFrame = newValue }
    }
}

/// A table that is data, as an assistive technology is given it: the cells listed of it, with
/// the row and column each stands in and the cells that head them.
@MainActor private final class ReaderTableAccessibilityElement: UIAccessibilityElement, UIAccessibilityContainerDataTable {
    weak var view: ReaderTextView?
    let table: TableModel
    private(set) var cells: [ReaderTableCellAccessibilityElement] = []
    private var listedByCell: [Int: ReaderTableCellAccessibilityElement] = [:]
    /// The cell last asked where it stands. UIKit asks for a row's and a column's header
    /// cells, not a cell's, and VoiceOver says them before the cell it comes to. A cell is
    /// headed by the header cells above it and before it, so those after the cell asked are
    /// left out: a header cell over a second row of them is not read under their names.
    weak var asked: ReaderTableCellAccessibilityElement?
    /// Header cells whose row is not listed, on another page or far off the screen.
    private var unlistedHeaders: [Int: ReaderTableHeaderName] = [:]

    init(view: ReaderTextView, table: TableModel) {
        self.view = view
        self.table = table
        super.init(accessibilityContainer: view)
        isAccessibilityElement = false
        accessibilityContainerType = .dataTable
    }

    func list(_ cells: [ReaderTableCellAccessibilityElement]) {
        self.cells = cells
        listedByCell = [:]
        for cell in cells {
            cell.accessibilityContainer = self
            listedByCell[cell.cell] = cell
        }
        accessibilityFrameInContainerSpace = cells.reduce(CGRect.null) { $0.union($1.accessibilityFrameInContainerSpace) }
    }

    /// The cells listed now. In continuous scroll the rows listed follow the cursor, and
    /// VoiceOver asks a table for its next cell before it asks the text view for anything:
    /// answered from the rows listed for the cell before, a table ended at the last of them.
    private var listedCells: [ReaderTableCellAccessibilityElement] {
        view?.updateAccessibilityList()
        return cells
    }

    override var accessibilityElements: [Any]? {
        get { listedCells }
        set { super.accessibilityElements = newValue }
    }

    override var accessibilityFrame: CGRect {
        get { view.map { UIAccessibility.convertToScreenCoordinates(accessibilityFrameInContainerSpace, in: $0) } ?? super.accessibilityFrame }
        set { super.accessibilityFrame = newValue }
    }

    func accessibilityDataTableCellElement(forRow row: Int, column: Int) -> UIAccessibilityContainerDataTableCell? {
        guard table.rowCells.indices.contains(row) else { return nil }
        _ = listedCells
        // The cell that covers the slot, among the few the row holds.
        let cell = table.rowCells[row].first { table.cells[$0].column <= column && column < table.cells[$0].column + table.cells[$0].columnSpan }
        return cell.flatMap { listedByCell[$0] }
    }

    func accessibilityRowCount() -> Int { table.rows.count }

    func accessibilityColumnCount() -> Int { table.columnCount }

    func accessibilityHeaderElements(forRow row: Int) -> [UIAccessibilityContainerDataTableCell]? {
        var cells = table.rowHeaders(row)
        if let asked, asked.accessibilityContainer === self, NSLocationInRange(row, NSRange(location: table.cells[asked.cell].row, length: table.cells[asked.cell].rowSpan)) {
            cells = cells.filter { $0 == asked.cell || table.cells[$0].column < table.cells[asked.cell].column }
        }
        let headers = cells.compactMap(header)
        return headers.isEmpty ? nil : headers
    }

    func accessibilityHeaderElements(forColumn column: Int) -> [UIAccessibilityContainerDataTableCell]? {
        var cells = table.columnHeaders(column)
        if let asked, asked.accessibilityContainer === self, NSLocationInRange(column, NSRange(location: table.cells[asked.cell].column, length: table.cells[asked.cell].columnSpan)) {
            cells = cells.filter { $0 == asked.cell || table.cells[$0].row < table.cells[asked.cell].row }
        }
        let headers = cells.compactMap(header)
        return headers.isEmpty ? nil : headers
    }

    override func accessibilityElementCount() -> Int { listedCells.count }

    override func accessibilityElement(at index: Int) -> Any? {
        let cells = listedCells
        return cells.indices.contains(index) ? cells[index] : nil
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        let cells = listedCells
        if let index = cells.firstIndex(where: { $0 === element as AnyObject }) { return index }
        // A cell kept from before the list moved away and back stands for the cell listed now.
        guard let kept = element as? ReaderTableCellAccessibilityElement, kept.table === table else { return NSNotFound }
        return cells.firstIndex { $0.cell == kept.cell && $0.range == kept.range } ?? NSNotFound
    }

    private func header(_ cell: Int) -> UIAccessibilityContainerDataTableCell? {
        if let listed = listedByCell[cell] { return listed }
        if let kept = unlistedHeaders[cell] { return kept }
        guard !table.cells[cell].text.isEmpty else { return nil }
        let name = ReaderTableHeaderName(table: self, cell: table.cells[cell])
        unlistedHeaders[cell] = name
        return name
    }
}

/// A header cell of a row that is not listed: its words, for VoiceOver to say before a cell
/// it heads, and nowhere for its cursor to go.
@MainActor private final class ReaderTableHeaderName: UIAccessibilityElement, UIAccessibilityContainerDataTableCell {
    private let rows: NSRange
    private let columns: NSRange

    init(table: ReaderTableAccessibilityElement, cell: TableModel.Cell) {
        rows = NSRange(location: cell.row, length: cell.rowSpan)
        columns = NSRange(location: cell.column, length: cell.columnSpan)
        super.init(accessibilityContainer: table)
        accessibilityLabel = cell.text
        accessibilityTraits = .staticText
    }

    func accessibilityRowRange() -> NSRange { rows }

    func accessibilityColumnRange() -> NSRange { columns }
}

/// Observes native selection gestures simultaneously and takes over only when their endpoint
/// crosses into the other column. Long press starts a selection; pan extends a native handle.
@MainActor final class ReaderSpreadSelectionGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var view: UIView?
    private weak var activeGesture: UIGestureRecognizer?
    private var crossesSurface = false
    init(view: UIView) { self.view = view }

    static func install(on view: UIView) -> ReaderSpreadSelectionGestureDelegate {
        let delegate = ReaderSpreadSelectionGestureDelegate(view: view)
        let drag = UIPanGestureRecognizer(target: delegate, action: #selector(Self.drag(_:)))
        drag.delegate = delegate
        drag.maximumNumberOfTouches = 1
        drag.cancelsTouchesInView = false
        view.addGestureRecognizer(drag)
        let press = UILongPressGestureRecognizer(target: delegate, action: #selector(Self.drag(_:)))
        press.minimumPressDuration = 0.45
        press.delegate = delegate
        press.cancelsTouchesInView = false
        view.addGestureRecognizer(press)
        return delegate
    }

    private var canvas: ReaderCanvasView? {
        (view as? ReaderTextView)?.canvas ?? (view as? TableCellTextView)?.canvas
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let view, let canvas, canvas.imageInspector == nil,
              canvas.columns.filter({ !$0.isHidden }).count > 1 else { return false }
        let point = recognizer.location(in: view)
        let selected: NSRange
        if let body = view as? ReaderTextView {
            guard body.tableInteraction?.selectionPosition(at: point) == nil else { return false }
            guard body.link(at: point) == nil, body.image(at: point) == nil else { return false }
            selected = body.selectedRange
        } else if let cell = view as? TableCellTextView {
            guard cell.cellLink(at: point) == nil, cell.cellImage(at: point) == nil else { return false }
            selected = cell.cellSelection
        } else { return false }
        return recognizer is UILongPressGestureRecognizer || selected.length > 0
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    @objc func drag(_ recognizer: UIGestureRecognizer) {
        guard let view, let canvas else { return }
        let point = recognizer.location(in: canvas)
        switch recognizer.state {
        case .began:
            guard activeGesture == nil, let position = canvas.selectionPosition(at: point) else { return }
            activeGesture = recognizer
            crossesSurface = false
            var anchor = position
            if recognizer is UIPanGestureRecognizer, let selection = canvas.currentSelection {
                func distance(to endpoint: ReaderTextPosition) -> Int {
                    if let cell = position.tableCell, let target = endpoint.tableCell,
                       cell.table == target.table, cell.cell == target.cell {
                        return abs(cell.offset - target.offset)
                    }
                    if position.offset == endpoint.offset, position.tableCell != endpoint.tableCell { return Int.max }
                    return abs(position.offset - endpoint.offset)
                }
                anchor = distance(to: selection.range.start) < distance(to: selection.range.end)
                    ? selection.range.end : selection.range.start
            }
            canvas.beginSelectionDrag(at: anchor)
        case .changed:
            guard activeGesture === recognizer, let end = canvas.selectionPosition(at: point) else { return }
            if !view.convert(view.bounds, to: canvas).contains(point) { crossesSurface = true }
            if crossesSurface { canvas.extendSelectionDrag(to: end) }
        case .ended, .cancelled, .failed:
            guard activeGesture === recognizer else { return }
            if crossesSurface, let end = canvas.selectionPosition(at: point) { canvas.extendSelectionDrag(to: end) }
            canvas.endSelectionDrag()
            activeGesture = nil
        default: break
        }
    }
}

@MainActor private final class ReaderImageGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var view: ReaderTextView?
    init(view: ReaderTextView) { self.view = view }
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let view else { return false }
        let point = recognizer.location(in: view)
        guard view.tableInteraction?.selectionPosition(at: point) == nil else { return false }
        return view.image(at: point) != nil && view.link(at: point) == nil && view.selectedRange.length == 0
    }
    @objc func openImage(_ recognizer: UITapGestureRecognizer) {
        guard let view, let image = view.image(at: recognizer.location(in: view)) else { return }
        view.canvas?.inspectImage(image)
    }
}

extension EPUBPageKey {
    var uiInput: String {
        switch self {
        case .leftArrow: UIKeyCommand.inputLeftArrow
        case .rightArrow: UIKeyCommand.inputRightArrow
        case .upArrow: UIKeyCommand.inputUpArrow
        case .downArrow: UIKeyCommand.inputDownArrow
        case .pageUp: UIKeyCommand.inputPageUp
        case .pageDown: UIKeyCommand.inputPageDown
        case .home: UIKeyCommand.inputHome
        case .end: UIKeyCommand.inputEnd
        case .space: " "
        case .character(let character): String(character)
        }
    }
    init?(uiInput: String) {
        switch uiInput {
        case UIKeyCommand.inputLeftArrow: self = .leftArrow
        case UIKeyCommand.inputRightArrow: self = .rightArrow
        case UIKeyCommand.inputUpArrow: self = .upArrow
        case UIKeyCommand.inputDownArrow: self = .downArrow
        case UIKeyCommand.inputPageUp: self = .pageUp
        case UIKeyCommand.inputPageDown: self = .pageDown
        case UIKeyCommand.inputHome: self = .home
        case UIKeyCommand.inputEnd: self = .end
        case " ": self = .space
        default:
            guard uiInput.count == 1, let character = uiInput.first else { return nil }
            self = .character(character)
        }
    }
}

extension EPUBPageKeyModifiers {
    init(uiFlags flags: UIKeyModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.alternate) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }
    var uiFlags: UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        if contains(.option) { flags.insert(.alternate) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}
#endif
