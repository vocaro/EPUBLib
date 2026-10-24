import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A block of a section's text, for an assistive technology's move by block: a paragraph, a
/// picture or a rule in a paragraph of its own, a list item, a table with its captions, or a
/// heading. `range` is its characters, and `spoken` the first of them that is read: a block
/// that holds nothing to read is none (`readerBlocks`).
struct ReaderTextBlock: Equatable {
    var range: NSRange
    var spoken: Int
}

extension NSAttributedString.Key {
    /// On a paragraph break the builder makes inside one line of the source, beside a sized
    /// inline box (`ReaderInlineBox`). The text each side of it is one block
    /// (`readerBlocks`), as a copy reads it as one line. It changes no character and nothing
    /// TextKit lays out.
    static let readerLayoutBreak = NSAttributedString.Key("org.epublib.layoutBreak")
}

extension NSAttributedString {
    /// The blocks of the text, in order. Each paragraph of the builder's is one
    /// (`SectionWriter`), and so is each heading, which is one block however many paragraphs it
    /// takes and also where it shares a paragraph: a hidden heading opening the line of the
    /// words after it, or one set run-in. A table is one block with its captions, all its rows
    /// one after the other, and a paragraph break the builder made inside a line of the source
    /// (`.readerLayoutBreak`) parts nothing. A block that holds nothing to read is left out:
    /// decoration, a picture or a rule the book keeps from assistive technology, words it keeps
    /// so or that `visibility: hidden` hides, a table row with nothing to say
    /// (`readerFirstSpoken`).
    func readerBlocks() -> [ReaderTextBlock] {
        guard length > 0 else { return [] }
        let text = string as NSString
        var starts: Set<Int> = [0]
        var location = 0
        while location < length {
            let found = text.rangeOfCharacter(from: Self.readerParagraphBreaks, options: [],
                                              range: NSRange(location: location, length: length - location))
            guard found.location != NSNotFound else { break }
            location = NSMaxRange(found)
            if location < length, !joinsBlocks(atBreak: found.location) { starts.insert(location) }
        }
        for (_, range) in readerHeadings() {
            starts.insert(range.location)
            if NSMaxRange(range) < length { starts.insert(NSMaxRange(range)) }
        }
        let ordered = starts.sorted()
        var blocks: [ReaderTextBlock] = []
        for (index, start) in ordered.enumerated() {
            let end = index + 1 < ordered.count ? ordered[index + 1] : length
            let range = NSRange(location: start, length: end - start)
            if let spoken = readerFirstSpoken(in: range) { blocks.append(ReaderTextBlock(range: range, spoken: spoken)) }
        }
        return blocks
    }

    /// The characters that end a paragraph.
    private static let readerParagraphBreaks = CharacterSet(charactersIn: "\n\r\u{2029}")

    /// Whether the paragraph break at `location` is inside one block: between two rows, or a
    /// caption and a row, of one table, inside one heading, or inside one line of the source.
    private func joinsBlocks(atBreak location: Int) -> Bool {
        guard location + 1 < length else { return false }
        if attribute(.readerLayoutBreak, at: location, effectiveRange: nil) != nil { return true }
        for key in [NSAttributedString.Key.readerTableModel, .readerHeading] {
            if let own = attribute(key, at: location, effectiveRange: nil) as AnyObject?,
               attribute(key, at: location + 1, effectiveRange: nil) as AnyObject? === own { return true }
        }
        return false
    }

    /// The first character of `range` that an assistive technology reads, as the reader's own
    /// elements give it: a shown word, a hidden label, a picture or a rule it does not pass
    /// over, a formula, a table row that says something or a row of a table of data, whose
    /// cells are listed where they start. Nil where there is none.
    func readerFirstSpoken(in range: NSRange) -> Int? {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard range.length > 0 else { return nil }
        let text = string as NSString
        var found: Int?
        enumerateAttributes(in: range) { attributes, run, stop in
            guard attributes[.readerHidden] == nil else { return }
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                if readerSpeaks(attachment, at: run) { found = run.location }
            } else if attributes[.readerUnspoken] != nil {
                // Kept words alone in a link leave the link, without a name, to be followed.
                if attributes[.link] != nil, holdsUnspokenWordsAlone(inLinkAt: run.location) { found = run.location }
            } else {
                let word = text.rangeOfCharacter(from: Self.readerSpokenCharacters, options: [], range: run)
                if word.location != NSNotFound { found = word.location }
            }
            if found != nil { stop.pointee = true }
        }
        return found
    }

    /// Characters that are read: neither white space nor a break, nor an attachment's character.
    private static let readerSpokenCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FFFC}")).inverted

    /// Whether `attachment`, at `range`, is read where it stands.
    private func readerSpeaks(_ attachment: NSTextAttachment, at range: NSRange) -> Bool {
        if let row = attachment as? TableRowAttachment { return row.table.isData || !row.saysNothing }
        if attachment is ReaderImageAttachment || attachment is ReaderRuleAttachment || attachment is MathAttachment {
            return !passesOver(attachment, at: range)
        }
        if let label = attachment as? SpokenLabelAttachment { return !label.text.allSatisfy(\.isWhitespace) }
        return true
    }
}
