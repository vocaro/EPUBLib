import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A `details` element of a section, which shows its `summary` and opens and closes on it
/// (HTML §4.11.1, "Details and summary" in `doc/native-viewer.md`).
///
/// A section's characters do not depend on whether a details is open: its string holds the
/// whole of every details, as it is shown open, so that search, CFIs, the text map and every
/// rendered position read the same text whatever has been opened or closed. What a closed one
/// keeps from the page is collapsed where it is shown (`ReaderDisclosures.render`): its
/// characters stay, take no room and draw nothing, and are read by nobody, as text
/// `visibility: hidden` hides is not read.
struct ReaderDisclosure: Hashable, Sendable {
    /// The `details` element's `ContentNode.order`: what names it among its section's.
    let id: Int
    /// The summary's characters, its marker included, without the break that ends them.
    let summary: NSRange
    /// What the details holds besides its summary, as rendered characters: each range from the
    /// start of a paragraph to the end of a paragraph, the break that ends it included. The
    /// summary's own paragraph is none of them. Empty when the details holds nothing else.
    let content: [NSRange]
    /// Where the summary's disclosure triangle is, when its marker is one (`disclosure-open`,
    /// `disclosure-closed`): one UTF-16 unit, the triangle of `isOpenInBook`.
    let marker: Int?
    /// Whether the book has the details open (its `open` attribute).
    let isOpenInBook: Bool
    /// Whether the summary's text runs right to left, which a closed triangle points along.
    let isRightToLeft: Bool
    /// The summary's own margin, padding and border below its text: what stands between it
    /// and the end of its details when the details is closed.
    var summaryGap: CGFloat = 0

    /// Whether `location` is in what the details hides when it is closed.
    func hides(_ location: Int) -> Bool { content.contains { NSLocationInRange(location, $0) } }
}

/// The open and closed state of a section's disclosures, and the text it is shown with.
enum ReaderDisclosures {
    /// `string` as it is shown when each disclosure is open or closed as `isOpen` says: a
    /// closed one's content collapsed, its summary's triangle pointing along the line, and every
    /// summary saying whether its details is open (`.readerExpanded`). `string` itself when that
    /// is how it is written: no details is closed and no triangle turns.
    static func render(_ string: NSAttributedString, _ disclosures: [ReaderDisclosure],
                       isOpen: (ReaderDisclosure) -> Bool) -> NSAttributedString {
        let states = disclosures.map(isOpen)
        guard zip(disclosures, states).contains(where: { !$1 || $0.isOpenInBook != $1 }) else { return string }
        let shown = NSMutableAttributedString(attributedString: string)
        let length = shown.length
        shown.beginEditing()
        for (disclosure, open) in zip(disclosures, states) where open != disclosure.isOpenInBook {
            if let marker = disclosure.marker, marker < length {
                let triangle = open ? ListMarker.disclosureOpen
                    : disclosure.isRightToLeft ? ListMarker.disclosureClosedRightToLeft : ListMarker.disclosureClosed
                shown.replaceCharacters(in: NSRange(location: marker, length: 1), with: triangle)
            }
            if NSMaxRange(disclosure.summary) <= length {
                shown.addAttribute(.readerExpanded, value: open, range: disclosure.summary)
            }
        }
        // A details inside a closed one is collapsed with it, whatever its own state.
        var collapsed: [NSRange] = []
        for (disclosure, open) in zip(disclosures, states) where !open {
            for range in disclosure.content where NSMaxRange(range) <= length && range.length > 0 {
                guard !collapsed.contains(where: { NSLocationInRange(range.location, $0) }) else { continue }
                // The paragraph after the summary's opens what the summary closes.
                let followsSummary = range.location == NSMaxRange(disclosure.summary) + 1
                collapse(range, in: shown, original: string, summaryGap: followsSummary ? disclosure.summaryGap : nil)
                collapsed.append(range)
            }
        }
        shown.endEditing()
        return shown
    }

    /// Makes `range` take no room and draw nothing, and keeps it from whoever reads the text:
    /// every paragraph of it a line of no height (as a line of hidden labels alone is,
    /// `SpokenLabelAttachment.lineHeight`), each attachment one that has no size, and every
    /// character `.readerHidden` and `.readerCollapsed`. Nothing of what it was laid out with
    /// stays: no link, heading, page break, box, float or alignment. The gap after it is the
    /// one it had at its end, which its last margins and those after it make. Where it follows
    /// a summary it lies against the summary, and the summary's own trailing margin
    /// (`ReaderDisclosure.summaryGap`) joins that gap, as margins collapse through the details:
    /// the gap the summary had to the content does not, since it holds the content's first
    /// margin.
    private static func collapse(_ range: NSRange, in shown: NSMutableAttributedString, original: NSAttributedString,
                                 summaryGap: CGFloat?) {
        let characters = original.string as NSString
        let first = original.attributes(at: range.location, effectiveRange: nil)
        let base = (first[.paragraphStyle] as? NSParagraphStyle) ?? .default
        var attributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: SpokenLabelAttachment.lineHeight),
            .foregroundColor: PlatformColor.clear,
            .paragraphStyle: collapsedStyle(base, spacingAfter: 0),
            .readerHidden: true,
            .readerCollapsed: true,
        ]
        if let record = first[.readerSectionLayout] { attributes[.readerSectionLayout] = record }
        // The gap that followed the collapsed paragraphs, which now follows the last of them.
        let lastParagraph = characters.paragraphRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
        let endStyle = original.attribute(.paragraphStyle, at: lastParagraph.location, effectiveRange: nil) as? NSParagraphStyle
        var gap = endStyle?.paragraphSpacing ?? 0
        let opensParagraph = range.location == 0 || ReaderAlignmentLayout.isParagraphBreak(characters.character(at: range.location - 1))
        if opensParagraph, range.location > 0, let summaryGap {
            gap = max(gap, summaryGap)
            let previous = characters.paragraphRange(for: NSRange(location: range.location - 1, length: 0))
            let style = original.attribute(.paragraphStyle, at: previous.location, effectiveRange: nil) as? NSParagraphStyle
            if let style, style.paragraphSpacing != 0, let lying = style.mutableCopy() as? NSMutableParagraphStyle {
                lying.paragraphSpacing = 0
                shown.addAttribute(.paragraphStyle, value: lying, range: previous)
            }
        }
        shown.setAttributes(attributes, range: range)
        // Content that goes on in a paragraph begun before it keeps that paragraph's style.
        if !opensParagraph {
            let paragraph = characters.paragraphRange(for: NSRange(location: range.location, length: 0))
            let end = min(NSMaxRange(paragraph), NSMaxRange(range))
            if let style = original.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) {
                shown.addAttribute(.paragraphStyle, value: style, range: NSRange(location: range.location, length: end - range.location))
            }
        }
        let tail = NSIntersectionRange(lastParagraph, range)
        if tail.location == lastParagraph.location, tail.length > 0 {
            shown.addAttribute(.paragraphStyle, value: collapsedStyle(endStyle ?? base, spacingAfter: gap), range: tail)
        }
        var index = range.location
        while index < NSMaxRange(range) {
            let found = characters.range(of: "\u{FFFC}", options: .literal,
                                         range: NSRange(location: index, length: NSMaxRange(range) - index))
            guard found.location != NSNotFound else { break }
            // TextKit sizes each character's attachment where it stands.
            shown.addAttribute(.attachment, value: ReaderCollapsedAttachment(), range: found)
            index = NSMaxRange(found)
        }
    }

    private static func collapsedStyle(_ base: NSParagraphStyle, spacingAfter: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = base.baseWritingDirection
        style.maximumLineHeight = SpokenLabelAttachment.lineHeight
        style.paragraphSpacing = spacingAfter
        // Every tab must have somewhere to go (`InlineStyling.tabInterval`).
        style.defaultTabInterval = base.defaultTabInterval > 0 ? base.defaultTabInterval : 36
        style.tabStops = []
        return style
    }
}

/// What stands for an image, a table's row, a formula or a rule in a closed details: nothing,
/// of no size. Its characters are hidden, so it has no words either.
final class ReaderCollapsedAttachment: ReaderAttachment {
    override init() { super.init(isHidden: true) }
    required init?(coder: NSCoder) { nil }

    override func layoutBounds(_ line: Line) -> CGRect { .zero }
    override func contentWidths() -> (min: CGFloat, max: CGFloat) { (0, 0) }
    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> PlatformImage? { nil }
    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> PlatformImage? { nil }
}

extension NSAttributedString.Key {
    /// On a summary's characters, whether its details is open, as it is shown: VoiceOver calls
    /// the summary a button that is expanded or collapsed, and on Mac a disclosure triangle.
    static let readerExpanded = NSAttributedString.Key("org.epublib.expanded")
    /// `true` on every character a closed details keeps from the page
    /// (`ReaderDisclosures.render`). They are `.readerHidden` too.
    static let readerCollapsed = NSAttributedString.Key("org.epublib.collapsed")
}

extension NSAttributedString {
    /// The run of characters a closed details collapses that holds `location`, whole
    /// paragraphs of no height; nil where none does.
    func readerCollapsedRun(at location: Int) -> NSRange? {
        guard location >= 0, location < length else { return nil }
        var run = NSRange()
        guard attribute(.readerCollapsed, at: location, longestEffectiveRange: &run,
                        in: NSRange(location: 0, length: length)) != nil else { return nil }
        return run
    }
}
