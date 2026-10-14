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
    func readerPlainText(in range: NSRange? = nil) -> String {
        var text = ""
        enumerateReaderTextPieces(in: range) { piece, _, _, _ in text += piece }
        return text
    }

    /// The pieces `readerPlainText(in:)` joins, in order: each with the characters it reads,
    /// a run of text or an attachment, the attachment, and whether it opens with the space
    /// that sets off a hidden label.
    private func enumerateReaderTextPieces(in range: NSRange?,
                                           _ body: (_ piece: String, _ run: NSRange, _ attachment: Any?, _ spaced: Bool) -> Void) {
        let range = range ?? NSRange(location: 0, length: length)
        guard range.length > 0 else { return }
        var last: Unicode.Scalar?
        var afterLabel = false
        enumerateAttribute(.attachment, in: range) { value, run, _ in
            let isLabel = value is SpokenLabelAttachment
            var piece = value == nil ? (string as NSString).substring(with: run) : (value as? ReaderTextualAttachment)?.textEquivalent ?? ""
            guard !piece.isEmpty else { return }
            var spaced = false
            if afterLabel || isLabel, let last, let first = piece.unicodeScalars.first,
               !last.properties.isWhitespace, !first.properties.isWhitespace {
                piece = " " + piece
                spaced = true
            }
            last = piece.unicodeScalars.last
            afterLabel = isLabel
            body(piece, run, value, spaced)
        }
    }

    /// The languages `readerPlainText(in:)` is to be spoken in. Text is in the language its
    /// characters carry for typesetting (`InlineStyling.languageKey`): what the content
    /// declares, else the package's, as `MathSpeech.contentLanguage` finds it for a formula,
    /// with the tags that name no voice left out (`InlineLanguage.spoken`). An attachment is in
    /// the language it declares for its words, a formula's or a hidden label's, else in its
    /// character's.
    func readerSpokenLanguages(in range: NSRange) -> ReaderSpokenLanguages {
        var parts: [(text: String, language: String?)] = []
        let text = string as NSString
        func language(at location: Int) -> String? {
            (attribute(InlineStyling.languageKey, at: location, effectiveRange: nil) as? String).flatMap(InlineLanguage.spoken)
        }
        enumerateReaderTextPieces(in: range) { piece, run, attachment, spaced in
            if let attachment {
                let declared = (attachment as? ReaderTextualAttachment)?.textLanguage
                parts.append((piece, declared.map(InlineLanguage.spoken) ?? language(at: run.location)))
                return
            }
            if spaced { parts.append((" ", language(at: run.location))) }
            enumerateAttribute(InlineStyling.languageKey, in: run) { value, part, _ in
                parts.append((text.substring(with: part), (value as? String).flatMap(InlineLanguage.spoken)))
            }
        }
        return ReaderSpokenLanguages(parts)
    }
}

/// The languages words the reader reads out are in, for an assistive technology to choose its
/// voices by: each part of the words, and the language most of them are in.
struct ReaderSpokenLanguages: Equatable {
    struct Run: Equatable {
        /// UTF-16 units of the words.
        var length: Int
        /// The language of this part; nil where none is named.
        var language: String?
    }

    /// The words' parts in order, each in another language than the one before. White space
    /// is in the language of the words before it, or at the start of the words after it: a
    /// space or a break is no reason to change voices.
    private(set) var runs: [Run] = []
    /// The language of most of the words, counted by their characters other than white
    /// space; the first such language where two have as many. nil when that is none, or when
    /// there are no words.
    private(set) var main: String?

    /// Whether some of the words are in another language than `main`.
    var isMixed: Bool { runs.contains { $0.language != main } }

    /// The languages of `parts`, which follow one another in the words.
    init(_ parts: [(text: String, language: String?)]) {
        var weights: [(language: String?, weight: Int)] = []
        var leading = 0
        for (text, language) in parts where !text.isEmpty {
            let length = text.utf16.count
            let weight = text.unicodeScalars.filter { !$0.properties.isWhitespace }.count
            guard weight > 0 else {
                // White space before any words waits for them; after words it is theirs.
                if runs.isEmpty { leading += length } else { runs[runs.count - 1].length += length }
                continue
            }
            if let last = runs.last, last.language == language {
                runs[runs.count - 1].length += length
            } else {
                runs.append(Run(length: length + leading, language: language))
                leading = 0
            }
            if let index = weights.firstIndex(where: { $0.language == language }) { weights[index].weight += weight }
            else { weights.append((language, weight)) }
        }
        if leading > 0 { runs.append(Run(length: leading, language: nil)) }
        // `max(by:)` gives the first of the heaviest.
        main = weights.max { $0.weight < $1.weight }?.language
    }
}
