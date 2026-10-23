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
    /// What VoiceOver is given in its place, where that differs from `textEquivalent`: nothing
    /// for an image or a formula the book keeps from assistive technology, whose words
    /// selections, copies and search still take, nor for one `visibility: hidden` hides, whose
    /// character leaves its words out of those too (`.readerHidden`).
    var spokenEquivalent: String { get }
    /// The BCP 47 language `textEquivalent` is spoken in, when it is known and may differ from
    /// the text around it: a formula's generated reading is not in the book's language.
    var textLanguage: String? { get }
}

extension ReaderTextualAttachment {
    var spokenEquivalent: String { textEquivalent }
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
    /// Text that `visibility: hidden` hides in the flow is left out (`readerHiddenText(_:)`),
    /// rich content it hides included. `spoken` gives what VoiceOver is told instead: each
    /// attachment's `spokenEquivalent`, and nothing of the text the book keeps from assistive
    /// technology with `aria-hidden` (`.readerUnspoken`), which is left out as hidden text is.
    func readerPlainText(in range: NSRange? = nil, spoken: Bool = false) -> String {
        attachmentPlainText(in: range, authored: false, spoken: spoken)
    }

    /// Copy uses authored text from detached table-cell maps; spoken text keeps its existing
    /// equivalents and typography. Ordinary characters are supplied by the enclosing map.
    func readerCopyPlainText(in range: NSRange? = nil) -> String {
        attachmentPlainText(in: range, authored: true, spoken: false)
    }

    private func attachmentPlainText(in range: NSRange?, authored: Bool, spoken: Bool) -> String {
        var text = ""
        enumerateReaderTextPieces(in: range, authored: authored, spoken: spoken) { piece, _, _, _ in text += piece }
        return text
    }

    /// What a piece of the reader's text reads: characters of the text, characters that
    /// `visibility: hidden` hides (or, read to VoiceOver, that `aria-hidden` keeps from it), or
    /// an attachment.
    private enum ReaderTextPiece {
        case text
        case hidden
        case attachment(Any)
    }

    /// The pieces `attachmentPlainText` joins, in order: each with the characters it reads,
    /// the run of the text it reads them for, what that run is, and whether the piece opens
    /// with the space that sets off a hidden label.
    private func enumerateReaderTextPieces(in range: NSRange?, authored: Bool, spoken: Bool,
                                           _ body: (_ piece: String, _ run: NSRange, _ kind: ReaderTextPiece, _ spaced: Bool) -> Void) {
        let range = range ?? NSRange(location: 0, length: length)
        guard range.length > 0 else { return }
        var last: Unicode.Scalar?
        var afterLabel = false
        var formulas: Set<ObjectIdentifier> = []
        func append(_ piece: String, _ run: NSRange, _ kind: ReaderTextPiece, isLabel: Bool) {
            guard !piece.isEmpty else { return }
            var piece = piece, spaced = false
            if afterLabel || isLabel, let last, let first = piece.unicodeScalars.first,
               !last.properties.isWhitespace, !first.properties.isWhitespace {
                piece = " " + piece
                spaced = true
            }
            last = piece.unicodeScalars.last
            afterLabel = isLabel
            body(piece, run, kind, spaced)
        }
        enumerateReaderLeftOut(in: range, spoken: spoken) { leftOut, part in
            if leftOut { return append(readerHiddenText(part, spoken: spoken), part, .hidden, isLabel: false) }
            enumerateAttribute(.attachment, in: part) { value, run, _ in
                if let value {
                    // An inline formula broken over rows is read once, where its first part stands.
                    if let math = value as? MathAttachment, let inline = math.inline {
                        if formulas.insert(ObjectIdentifier(inline)).inserted {
                            append(spoken ? math.spokenEquivalent : math.label, run, .attachment(value), isLabel: false)
                        }
                        return
                    }
                    let attachment = value as? ReaderTextualAttachment
                    let words = authored ? (value as? TableRowAttachment)?.copyTextEquivalent : nil
                    append(words ?? (spoken ? attachment?.spokenEquivalent : attachment?.textEquivalent) ?? "",
                           run, .attachment(value), isLabel: value is SpokenLabelAttachment)
                } else {
                    append((string as NSString).substring(with: run), run, .text, isLabel: false)
                }
            }
        }
    }

    /// The languages of the words `readerPlainText(in:spoken:)` gives VoiceOver. Text is in the
    /// language its characters carry for typesetting (`InlineStyling.languageKey`): what the
    /// content declares, else the package's, as `MathSpeech.contentLanguage` finds it for a
    /// formula, with the tags that name no voice left out (`InlineLanguage.spoken`). An
    /// attachment's spoken words are in the language it declares for them, a formula's or a
    /// hidden label's, else in its character's; an image the book keeps from assistive
    /// technology has none to weigh. What `visibility: hidden` hides, or `aria-hidden` keeps
    /// from VoiceOver, is read as breaks or a space at most, so it decides no language: white
    /// space takes the words' beside it.
    func readerSpokenLanguages(in range: NSRange) -> ReaderSpokenLanguages {
        var parts: [(text: String, language: String?)] = []
        let text = string as NSString
        func language(at location: Int) -> String? {
            (attribute(InlineStyling.languageKey, at: location, effectiveRange: nil) as? String).flatMap(InlineLanguage.spoken)
        }
        enumerateReaderTextPieces(in: range, authored: false, spoken: true) { piece, run, kind, spaced in
            switch kind {
            case .hidden:
                parts.append((piece, nil))
            case .attachment(let attachment):
                let declared = (attachment as? ReaderTextualAttachment)?.textLanguage
                parts.append((piece, declared.map(InlineLanguage.spoken) ?? language(at: run.location)))
            case .text:
                if spaced { parts.append((" ", language(at: run.location))) }
                enumerateAttribute(InlineStyling.languageKey, in: run) { value, part, _ in
                    parts.append((text.substring(with: part), (value as? String).flatMap(InlineLanguage.spoken)))
                }
            }
        }
        return ReaderSpokenLanguages(parts)
    }

    /// What is read of `run`, characters that `visibility: hidden` hides in the flow
    /// (`.readerHidden`): a browser keeps their room and reads none of them. The breaks that end
    /// their lines and paragraphs are kept, so that the lines around them stay apart. Without a
    /// break, they read as one space where they stand between two shown words, which the room
    /// they take sets apart on the page, and otherwise as nothing. `spoken` reads characters
    /// that `aria-hidden` keeps from assistive technology (`.readerUnspoken`) the same way, for
    /// VoiceOver. What a closed details collapses (`.readerCollapsed`) takes no room, and reads
    /// as nothing, its breaks included: the line before it and the line after it are one break
    /// apart, as they are on the page.
    func readerHiddenText(_ run: NSRange, spoken: Bool = false) -> String {
        let characters = string as NSString
        var breaks = "", collapsed = false
        for index in run.location..<NSMaxRange(run) where Self.isReaderBreak(characters.character(at: index)) {
            if attribute(.readerCollapsed, at: index, effectiveRange: nil) != nil { collapsed = true; continue }
            breaks.unicodeScalars.append(Unicode.Scalar(characters.character(at: index))!)
        }
        if !breaks.isEmpty || collapsed { return breaks }
        func shownWord(at index: Int) -> Bool {
            guard index >= 0, index < length, attribute(.readerHidden, at: index, effectiveRange: nil) == nil,
                  !spoken || attribute(.readerUnspoken, at: index, effectiveRange: nil) == nil else { return false }
            return Unicode.Scalar(characters.character(at: index)).map { !$0.properties.isWhitespace } ?? true
        }
        return shownWord(at: run.location - 1) && shownWord(at: NSMaxRange(run)) ? " " : ""
    }

    /// The runs of `range` in order, each with whether it is left out of what is read: what
    /// `visibility: hidden` hides (`.readerHidden`), and, where `spoken` asks for what VoiceOver
    /// is given, what `aria-hidden` keeps from it (`.readerUnspoken`). The two marks are read
    /// apart, each by its own runs, as a whole book's text is in continuous scroll on Mac.
    func enumerateReaderLeftOut(in range: NSRange, spoken: Bool, _ body: (_ leftOut: Bool, _ run: NSRange) -> Void) {
        guard spoken else {
            enumerateAttribute(.readerHidden, in: range) { hidden, run, _ in body(hidden != nil, run) }
            return
        }
        var marked: [NSRange] = []
        for key in [NSAttributedString.Key.readerHidden, .readerUnspoken] {
            enumerateAttribute(key, in: range) { value, run, _ in if value != nil { marked.append(run) } }
        }
        marked.sort { $0.location < $1.location }
        var cursor = range.location, held: NSRange?
        func flush() {
            guard let run = held else { return }
            if run.location > cursor { body(false, NSRange(location: cursor, length: run.location - cursor)) }
            body(true, run)
            cursor = NSMaxRange(run)
            held = nil
        }
        for run in marked {
            if let current = held, run.location <= NSMaxRange(current) { held = NSUnionRange(current, run) }
            else { flush(); held = run }
        }
        flush()
        if cursor < NSMaxRange(range) { body(false, NSRange(location: cursor, length: NSMaxRange(range) - cursor)) }
    }

    /// The characters of `range` that an assistive client is not given, but the breaks among
    /// them, in runs: those `visibility: hidden` hides (`.readerHidden`) and those `aria-hidden`
    /// keeps from assistive technology (`.readerUnspoken`). They are given as spaces to an
    /// assistive client that reads the characters one for one with their ranges, as AppKit's
    /// text views give them (`readerBlankingHidden`), and a copy still takes the second.
    func readerHiddenCharacters(in range: NSRange) -> [NSRange] {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard range.length > 0 else { return [] }
        let characters = string as NSString
        var result: [NSRange] = []
        enumerateReaderLeftOut(in: range, spoken: true) { leftOut, run in
            guard leftOut else { return }
            var start = run.location
            for index in run.location...NSMaxRange(run) where index == NSMaxRange(run) || Self.isReaderBreak(characters.character(at: index)) {
                if index > start { result.append(NSRange(location: start, length: index - start)) }
                start = index + 1
            }
        }
        return result
    }

    /// `characters`, which are this text's from `location` one for one, with each character an
    /// assistive client is not given but a break given as a space (`readerHiddenCharacters(in:)`):
    /// the same length, so every range still matches the text, and no hidden word to say.
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
