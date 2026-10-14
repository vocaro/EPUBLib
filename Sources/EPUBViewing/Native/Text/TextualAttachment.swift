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

#if os(macOS)
extension NSAccessibilityElement {
    /// Makes the element what stands at an attachment for an assistive client on Mac, in a
    /// page's text or in a table cell's. Words that are text, a hidden label's, are static text
    /// whose value they are, with no label, so that they are said once. Anything else is an
    /// image named by its words, and without words an image without a name, which VoiceOver
    /// says in its own word. A rule is neither (`ReaderRuleAttachment.makeSeparator`).
    func setReaderAttachment(words: String, isText: Bool) {
        if isText {
            setAccessibilityRole(.staticText)
            setAccessibilityValue(words)
            setAccessibilityLabel(nil)
        } else {
            setAccessibilityRole(.image)
            setAccessibilityLabel(words.isEmpty ? nil : words)
        }
        setAccessibilityChildren(nil)
    }
}
#endif

extension NSAttributedString {
    /// The plain text of `range`, each attachment replaced by its text equivalent. Attachments
    /// without one are dropped, never left as U+FFFC. A hidden label is words of its own, set
    /// off by a space from text it touches: it takes no room, so nothing else separates them.
    /// Text that `visibility: hidden` hides in the flow is left out (`readerHiddenText(_:)`).
    func readerPlainText(in range: NSRange? = nil) -> String { attachmentPlainText(in: range, authored: false) }

    /// Copy uses authored text from detached table-cell maps; spoken text keeps its existing
    /// equivalents and typography. Ordinary characters are supplied by the enclosing map.
    func readerCopyPlainText(in range: NSRange? = nil) -> String { attachmentPlainText(in: range, authored: true) }

    private func attachmentPlainText(in range: NSRange?, authored: Bool) -> String {
        let range = range ?? NSRange(location: 0, length: length)
        guard range.length > 0 else { return "" }
        var text = ""
        var afterLabel = false
        func append(_ piece: String, isLabel: Bool) {
            guard !piece.isEmpty else { return }
            if afterLabel || isLabel, let last = text.unicodeScalars.last, let first = piece.unicodeScalars.first,
               !last.properties.isWhitespace, !first.properties.isWhitespace { text += " " }
            text += piece
            afterLabel = isLabel
        }
        enumerateAttribute(.readerHidden, in: range) { hidden, part, _ in
            if hidden != nil { return append(readerHiddenText(part), isLabel: false) }
            enumerateAttribute(.attachment, in: part) { value, run, _ in
                if let value {
                    let words = authored ? (value as? TableRowAttachment)?.copyTextEquivalent : nil
                    append(words ?? (value as? ReaderTextualAttachment)?.textEquivalent ?? "", isLabel: value is SpokenLabelAttachment)
                } else {
                    append((string as NSString).substring(with: run), isLabel: false)
                }
            }
        }
        return text
    }

    /// What is read of `run`, characters that `visibility: hidden` hides in the flow
    /// (`.readerHidden`): a browser keeps their room and reads none of them. The breaks that end
    /// their lines and paragraphs are kept, so that the lines around them stay apart. Without a
    /// break, they read as one space where they stand between two shown words, which the room
    /// they take sets apart on the page, and otherwise as nothing.
    func readerHiddenText(_ run: NSRange) -> String {
        let characters = string as NSString
        var breaks = ""
        for index in run.location..<NSMaxRange(run) where Self.isReaderBreak(characters.character(at: index)) {
            breaks.unicodeScalars.append(Unicode.Scalar(characters.character(at: index))!)
        }
        if !breaks.isEmpty { return breaks }
        func shownWord(at index: Int) -> Bool {
            guard index >= 0, index < length, attribute(.readerHidden, at: index, effectiveRange: nil) == nil else { return false }
            return Unicode.Scalar(characters.character(at: index)).map { !$0.properties.isWhitespace } ?? true
        }
        return shownWord(at: run.location - 1) && shownWord(at: NSMaxRange(run)) ? " " : ""
    }

    /// The hidden characters of `range` (`.readerHidden`) but the breaks among them, in runs:
    /// what is given as spaces to an assistive client that reads the characters one for one
    /// with their ranges, as AppKit's text views give them (`readerBlankingHidden`).
    func readerHiddenCharacters(in range: NSRange) -> [NSRange] {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard range.length > 0 else { return [] }
        let characters = string as NSString
        var result: [NSRange] = []
        enumerateAttribute(.readerHidden, in: range) { value, run, _ in
            guard value != nil else { return }
            var start = run.location
            for index in run.location...NSMaxRange(run) where index == NSMaxRange(run) || Self.isReaderBreak(characters.character(at: index)) {
                if index > start { result.append(NSRange(location: start, length: index - start)) }
                start = index + 1
            }
        }
        return result
    }

    /// `characters`, which are this text's from `location` one for one, with each hidden
    /// character but a break given as a space (`readerHiddenCharacters(in:)`): the same length,
    /// so every range still matches the text, and no hidden word to say.
    func readerBlankingHidden(_ characters: String, from location: Int) -> String {
        let result = NSMutableString(string: characters)
        let hidden = readerHiddenCharacters(in: NSRange(location: location, length: result.length))
        guard !hidden.isEmpty else { return characters }
        for run in hidden {
            result.replaceCharacters(in: NSRange(location: run.location - location, length: run.length),
                                     with: String(repeating: " ", count: run.length))
        }
        return result as String
    }

    /// U+000A, U+2028 and U+2029: what ends a line or a paragraph of the reader's text.
    static func isReaderBreak(_ unit: unichar) -> Bool { unit == 0x0A || unit == 0x2028 || unit == 0x2029 }
}
