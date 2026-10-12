import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Text a book keeps for assistive technology and hides from the page: a box parked off screen
/// or clipped to nothing (`ComputedStyle.isSpokenOnlyPositionedBox`). A browser draws none of it
/// and reads all of it. Here it is one character that takes no room and draws nothing, whose
/// `textEquivalent` VoiceOver, selections and copies read in its place, as they read an image's
/// alternative text.
final class SpokenLabelAttachment: ReaderAttachment {
    let text: String
    /// The language the label declares for itself, when it declares one.
    let language: String?

    init(text: String, language: String?) {
        self.text = text; self.language = language
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override var textEquivalent: String { text }
    override var textLanguage: String? { language }

    override func layoutBounds(_ line: Line) -> CGRect { .zero }
    override func contentWidths() -> (min: CGFloat, max: CGFloat) { (0, 0) }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> PlatformImage? { nil }
    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> PlatformImage? { nil }

    /// The height of the line a label has to itself between blocks: none to the eye and less
    /// than any tolerance of the layout, so the blocks around it lie where they would without it.
    static let lineHeight: CGFloat = 0.001
}
