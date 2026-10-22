import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The inspector uses archive pixels, independently of CSS and body font size. Keep its
/// decoded bitmap bounded even for a full-page scan; the original resource is never changed.
struct ReaderImageInspection {
    static let maximumPixels = 16 * 1024 * 1024
    static let maximumDimension = 8192
    /// What an assistive client on Mac is told of an image that has a name, in a page's text or
    /// a table cell's. An image without a name has no help.
    static let accessibilityHelp = "Double-click or choose Inspect Image to enlarge."

    static func decodeDimension(for size: CGSize) -> Int {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return 1 }
        let factor = min(1, min(CGFloat(maximumDimension) / max(size.width, size.height),
                                sqrt(CGFloat(maximumPixels) / (size.width * size.height))))
        // The shared cache rounds to 64-pixel buckets. Round down to keep the bound exact.
        if factor == 1 { return Int(max(size.width, size.height).rounded(.up)) }
        let wanted = max(size.width, size.height) * factor
        return max(1, Int(wanted / 64) * 64)
    }

    static func bitmap(for attachment: ReaderImageAttachment) -> CGImage? {
        attachment.cache.image(for: attachment.source,
            maxPixelSize: decodeDimension(for: attachment.source.pixelSize),
            inverted: attachment.invertsColors, lightBackdrop: attachment.isDark && !attachment.invertsColors,
            maximumDecodedPixelSize: decodeDimension(for: attachment.source.pixelSize))
    }

    static func fitScale(image: CGSize, viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return max(0.0001, min(1, min(max(1, viewport.width) / image.width, max(1, viewport.height) / image.height)))
    }

    static func maximumScale(fit: CGFloat) -> CGFloat { max(4, fit * 16) }
}

extension ReaderCanvasView {
    #if os(iOS)
    private static func firstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let responder = firstResponder(in: child) { return responder }
        }
        return nil
    }
    #endif

    /// Opening/closing inspection does not replace reader text, move its anchor, or mutate its
    /// selection. It is a separate native scroll surface above the unchanged book.
    func inspectImage(_ attachment: ReaderImageAttachment) {
        // An image that `visibility: hidden` hides draws nothing: there is nothing to enlarge.
        guard !attachment.isHidden, let bitmap = ReaderImageInspection.bitmap(for: attachment) else { return }
        imageInspector?.removeFromSuperview()
        let hostWindow = window
        #if os(macOS)
        let responder = window?.firstResponder
        #else
        let responder = window.flatMap { Self.firstResponder(in: $0) }
        #endif
        let inspector = ReaderImageInspector(bitmap: bitmap, label: attachment.spokenAlt, dark: configuration.isDark)
        inspector.onClose = { [weak self, weak inspector, weak responder, weak hostWindow] in
            inspector?.removeFromSuperview()
            self?.imageInspector = nil
            #if os(macOS)
            for view in self?.textViews ?? [] { view.setAccessibilityHidden(false) }
            self?.scrollContainer?.setAccessibilityHidden(false)
            if let responder { hostWindow?.makeFirstResponder(responder) }
            if let self { NSAccessibility.post(element: self, notification: .layoutChanged) }
            #else
            responder?.becomeFirstResponder()
            UIAccessibility.post(notification: .screenChanged, argument: responder ?? self)
            #endif
        }
        imageInspector = inspector
        #if os(macOS)
        for view in textViews { view.setAccessibilityHidden(true) }
        scrollContainer?.setAccessibilityHidden(true)
        #endif
        inspector.frame = bounds
        #if os(macOS)
        inspector.autoresizingMask = [.width, .height]
        #else
        inspector.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
        addSubview(inspector)
        inspector.open()
    }
}

extension NSAttributedString {
    /// Whether assistive technology passes over `attachment`, which stands at `range` of this
    /// text, a section's or a table cell's: an image the book marks as decoration with an
    /// empty `alt`, an image or a rule it keeps from assistive technology with `aria-hidden` or
    /// a presentational role, and a formula it keeps so with `aria-hidden`. One that is all its
    /// link holds is the link and stays, because a link has to be reachable whatever its image
    /// or rule says. One that `visibility: hidden` hides is passed over too: it has no link.
    func passesOver(_ attachment: NSTextAttachment, at range: NSRange) -> Bool {
        guard Self.isPassedOverAlone(attachment) else { return false }
        guard range.location < length else { return true }
        var link = NSRange()
        guard attribute(.link, at: range.location, longestEffectiveRange: &link,
                        in: NSRange(location: 0, length: length)) != nil else { return true }
        // Anything else in the link that can be read carries it, but not words the book keeps
        // from assistive technology.
        var carried = false
        enumerateAttribute(.attachment, in: link) { value, run, stop in
            if let other = value as? ReaderImageAttachment { carried = !other.isPassedOverByAssistiveTechnology }
            else if let value { carried = (value as? ReaderTextualAttachment)?.spokenEquivalent.isEmpty == false }
            else { carried = !readerPlainText(in: run, spoken: true).allSatisfy(\.isWhitespace) }
            stop.pointee = ObjCBool(carried)
        }
        return carried
    }

    /// Whether assistive technology passes over `attachment` where no link keeps it.
    static func isPassedOverAlone(_ attachment: NSTextAttachment) -> Bool {
        if let image = attachment as? ReaderImageAttachment { return image.isPassedOverByAssistiveTechnology }
        if let math = attachment as? MathAttachment { return math.isPassedOverByAssistiveTechnology }
        return (attachment as? ReaderRuleAttachment)?.isPassedOverByAssistiveTechnology == true
    }

    /// Whether the link at `location` holds words and nothing else, all of which the book keeps
    /// from assistive technology with `aria-hidden` (`.readerUnspoken`). It stays reachable, as
    /// a link without a name, as one that is all an image kept from assistive technology is.
    func holdsUnspokenWordsAlone(inLinkAt location: Int) -> Bool {
        guard location >= 0, location < length else { return false }
        var link = NSRange()
        guard attribute(.link, at: location, longestEffectiveRange: &link, in: NSRange(location: 0, length: length)) != nil
        else { return false }
        var unspoken = false, other = false
        enumerateAttributes(in: link) { attributes, run, stop in
            if attributes[.attachment] != nil { other = true }
            else if !(string as NSString).substring(with: run).allSatisfy(\.isWhitespace) {
                if attributes[.readerUnspoken] != nil { unspoken = true } else { other = true }
            }
            if other { stop.pointee = true }
        }
        return unspoken && !other
    }
}

extension ReaderRuleAttachment {
    /// Whether assistive technology passes over the rule where no link keeps it: a rule the
    /// book keeps from it as ornament, and one that `visibility: hidden` hides.
    var isPassedOverByAssistiveTechnology: Bool { isHiddenFromAssistiveTechnology || isHidden }
}

extension ReaderTextView {
    /// Laid-out images only: avoid asking TextKit to lay out a whole continuous-scroll book
    /// just to handle a pointer or accessibility action. Positions stay in native text space.
    func imageAttachments(in range: NSRange? = nil) -> [(image: ReaderImageAttachment, range: NSRange)] {
        guard let storage = contentStorage.textStorage else { return [] }
        var result: [(ReaderImageAttachment, NSRange)] = []
        let full = NSRange(location: 0, length: min(placement.visibleLength, storage.length))
        storage.enumerateAttribute(.attachment, in: range.map { NSIntersectionRange($0, full) } ?? full) { value, run, _ in
            if let image = value as? ReaderImageAttachment { result.append((image, run)) }
            else if let row = value as? TableRowAttachment, let frame = segmentFrames(for: run).first {
                for image in row.images(size: frame.size, viewportHeight: readerContainer.viewportSize.height) {
                    result.append((image.image, run))
                }
            }
        }
        return result
    }

    /// Whether assistive technology passes over `attachment`, an image or a rule, which stands
    /// at `range` (`NSAttributedString.passesOver`).
    func isPassedOver(_ attachment: NSTextAttachment, at range: NSRange) -> Bool {
        contentStorage.textStorage?.passesOver(attachment, at: range) ?? NSAttributedString.isPassedOverAlone(attachment)
    }

    /// The images of `range` that assistive technology is told of: `imageAttachments(in:)`
    /// without the decoration it passes over, nor the images the book keeps from it, in the
    /// text or in a table's cells.
    func announcedImages(in range: NSRange? = nil) -> [(image: ReaderImageAttachment, range: NSRange)] {
        let storage = contentStorage.textStorage
        return imageAttachments(in: range).filter { image, run in
            guard image.isPassedOverByAssistiveTechnology else { return true }
            // A table row's images share the row's character and have no link of the text's.
            return storage?.attribute(.attachment, at: run.location, effectiveRange: nil) as? ReaderImageAttachment === image
                && !isPassedOver(image, at: run)
        }
    }

    /// The image drawn at `point`, which a tap or a double click there opens. An image that
    /// `visibility: hidden` hides is not drawn, and its room is the text's, as a browser gives
    /// a pointer nothing of such an element.
    func image(at point: CGPoint) -> ReaderImageAttachment? {
        let target = CGPoint(x: point.x - containerOrigin.x, y: point.y - containerOrigin.y)
        guard let fragment = drawnFragment(at: target),
              let storage = contentStorage.textStorage else { return nil }
        let lower = offset(of: fragment.rangeInElement.location)
        let upper = min(placement.visibleLength, offset(of: fragment.rangeInElement.endLocation))
        guard lower >= 0, upper > lower, upper <= storage.length else { return nil }
        var found: ReaderImageAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: lower, length: upper - lower)) { value, range, stop in
            for frame in segmentFrames(for: range) where frame.contains(target) {
                if let image = value as? ReaderImageAttachment { found = image }
                else if let row = value as? TableRowAttachment {
                    found = row.image(at: CGPoint(x: target.x - frame.minX, y: target.y - frame.minY),
                        size: frame.size, viewportHeight: readerContainer.viewportSize.height)
                }
                if found?.isHidden == true { found = nil }
                if found != nil { stop.pointee = true; return }
            }
        }
        return found
    }
}
