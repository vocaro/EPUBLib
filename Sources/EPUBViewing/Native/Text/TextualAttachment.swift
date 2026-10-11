import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// An attachment that stands for text. Selections, copies and VoiceOver use `textEquivalent`
/// in place of the attachment character: an image's alt text, a formula's `alttext`, a table's
/// cells. An empty equivalent (a rule) contributes nothing.
protocol ReaderTextualAttachment: AnyObject {
    var textEquivalent: String { get }
    /// The BCP 47 language `textEquivalent` is spoken in, when it is known and may differ from
    /// the text around it: a formula's generated reading is not in the book's language.
    var textLanguage: String? { get }
}

extension ReaderTextualAttachment {
    var textLanguage: String? { nil }
}

extension NSAttributedString {
    /// The plain text of `range`, each attachment replaced by its text equivalent. Attachments
    /// without one are dropped, never left as U+FFFC.
    func readerPlainText(in range: NSRange? = nil) -> String {
        let range = range ?? NSRange(location: 0, length: length)
        guard range.length > 0 else { return "" }
        var text = ""
        enumerateAttribute(.attachment, in: range) { value, run, _ in
            if let value {
                text += (value as? ReaderTextualAttachment)?.textEquivalent ?? ""
            } else {
                text += (string as NSString).substring(with: run)
            }
        }
        return text
    }
}
