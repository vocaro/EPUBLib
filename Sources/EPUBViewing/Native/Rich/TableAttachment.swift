import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One row unit of a table. It fills the rest of its line; its height comes from the table's
/// layout at that width (cached per width). Text views show it through a view provider, whose
/// view draws the unit and exposes each cell to VoiceOver. (On macOS 27, TextKit 2 stops asking
/// for a view provider once the class overrides an image method, so this class draws none.)
/// Cell text is drawn, not laid out in the text view, so it is not selectable.
class TableRowsAttachment: ReaderAttachment {
    let table: TableModel
    let unit: Int

    init(table: TableModel, unit: Int) {
        self.table = table; self.unit = unit
        super.init()
        // Without an image TextKit draws a generic document icon under the view.
        image = Self.blank
    }

    private static var blank: PlatformImage {
        #if os(iOS)
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        #else
        NSImage(size: CGSize(width: 1, height: 1))
        #endif
    }
    required init?(coder: NSCoder) { nil }

    static func viewportHeight(_ container: NSTextContainer?, width: CGFloat) -> CGFloat {
        ReaderTextContainer.available(in: container, lineWidth: width).height
    }

    func layout(width: CGFloat, viewportHeight: CGFloat) -> TableLayout {
        table.layout(available: width, viewportHeight: viewportHeight)
    }

    override func layoutBounds(_ line: Line) -> CGRect {
        let width = max(1, line.width - line.position)
        let layout = layout(width: width, viewportHeight: line.viewport.height)
        return CGRect(x: 0, y: line.font?.descender ?? 0, width: width, height: layout.height(ofUnit: unit))
    }

    override func contentWidths() -> (min: CGFloat, max: CGFloat) {
        let constraints = table.constraints
        return (constraints.minimumTableWidth * TableModel.minimumScale, constraints.maximumTableWidth)
    }

    /// The unit's cells: a row's cells joined by tabs, its rows by line breaks. (A cell spanning
    /// rows is in its first.) The caption is a paragraph of its own.
    override var textEquivalent: String {
        let cells = table.unitCells[unit].map { table.cells[$0] }
        return table.units[unit].map { row in
            cells.filter { $0.row == row }.sorted { $0.column < $1.column }.map(\.text).joined(separator: "\t")
        }.joined(separator: "\n")
    }

    override func viewProvider(for parentView: PlatformView?, location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        TableRowsViewProvider(textAttachment: self, parentView: parentView,
                              textLayoutManager: textContainer?.textLayoutManager, location: location)
    }

    /// Draws the unit into the current flipped graphics context, its origin at the unit's top-left.
    func draw(in context: CGContext, size: CGSize, viewportHeight: CGFloat) {
        guard size.width > 0 else { return }
        table.draw(unit: unit, layout: layout(width: size.width, viewportHeight: viewportHeight), in: context)
    }

    /// Each cell of the unit: what VoiceOver reads, and where (in the unit's coordinates).
    func accessibilityCells(size: CGSize, viewportHeight: CGFloat) -> [(text: String, frame: CGRect, isHeader: Bool)] {
        let layout = layout(width: size.width, viewportHeight: viewportHeight)
        return table.unitCells[unit].compactMap { index in
            let cell = table.cells[index]
            return cell.text.isEmpty ? nil : (cell.text, layout.frame(ofCell: index, inUnit: unit), cell.isHeader)
        }
    }
}

/// A row unit inside a table cell's text, which string drawing draws: as an image, since string
/// drawing has no views.
final class TableRowsImageAttachment: TableRowsAttachment {
    override func viewProvider(for parentView: PlatformView?, location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? { nil }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> PlatformImage? {
        render(bounds.size, container: textContainer)
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> PlatformImage? {
        render(imageBounds.size, container: textContainer)
    }

    private func render(_ size: CGSize, container: NSTextContainer?) -> PlatformImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let viewport = Self.viewportHeight(container, width: size.width)
        #if os(iOS)
        return UIGraphicsImageRenderer(size: size).image { [self] context in
            draw(in: context.cgContext, size: size, viewportHeight: viewport)
        }
        #else
        return NSImage(size: size, flipped: true) { [self] _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, size: size, viewportHeight: viewport)
            return true
        }
        #endif
    }
}

final class TableRowsViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        // TextKit loads views on the main thread.
        guard let attachment = textAttachment as? TableRowsAttachment else { return }
        let parts = ViewParts(attachment: attachment, layoutManager: textLayoutManager)
        view = MainActor.assumeIsolated { TableRowsView(attachment: parts.attachment, layoutManager: parts.layoutManager) }
    }
}

/// What `loadView` hands to the main actor; TextKit calls it on the main thread.
private struct ViewParts: @unchecked Sendable {
    let attachment: TableRowsAttachment
    weak var layoutManager: NSTextLayoutManager?
}

/// Draws one row unit. It never takes input, so taps, clicks and selection drags reach the text
/// view (and the paginator's tap zones) beneath it.
@MainActor final class TableRowsView: PlatformView {
    let attachment: TableRowsAttachment
    private weak var layoutManager: NSTextLayoutManager?
    private var cells: [AnyObject]?

    init(attachment: TableRowsAttachment, layoutManager: NSTextLayoutManager?) {
        self.attachment = attachment
        self.layoutManager = layoutManager
        super.init(frame: .zero)
        #if os(iOS)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        #else
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        #endif
    }
    required init?(coder: NSCoder) { nil }

    private var viewportHeight: CGFloat {
        TableRowsAttachment.viewportHeight(layoutManager?.textContainer, width: bounds.width)
    }

    private func accessibilityCells() -> [AnyObject] {
        if let cells { return cells }
        let made: [AnyObject] = attachment.accessibilityCells(size: bounds.size, viewportHeight: viewportHeight).map { cell in
            #if os(iOS)
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = cell.text
            element.accessibilityTraits = cell.isHeader ? [.staticText, .header] : .staticText
            element.accessibilityFrameInContainerSpace = cell.frame
            return element
            #else
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(cell.text)
            element.setAccessibilityValue(cell.text)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(cell.frame)
            return element
            #endif
        }
        cells = made
        return made
    }

    #if os(iOS)
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        attachment.draw(in: context, size: bounds.size, viewportHeight: viewportHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cells = nil
    }

    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    override var accessibilityElements: [Any]? {
        get { accessibilityCells() }
        set {}
    }
    #else
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cells = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        attachment.draw(in: context, size: bounds.size, viewportHeight: viewportHeight)
    }

    override func accessibilityChildren() -> [Any]? { accessibilityCells() }
    #endif
}
