import Foundation

/// A heading of the book, for assistive technology: the value of `.readerHeading` on every
/// character of the heading's text, and on a hidden label that stands for one
/// (`SpokenLabelAttachment`). Each heading element has one object, so a heading is the
/// characters that share it: two headings one after the other stay two, and one whose blocks
/// are several paragraphs stays one. The attribute changes no character, no span of the text
/// map and nothing TextKit lays out.
final class ReaderHeading: NSObject, @unchecked Sendable {
    /// 1 to 6, or 0 for a heading with a level that is none of those (`aria-level="7"`).
    let level: Int

    init(level: Int) { self.level = level }
}

extension NSAttributedString.Key {
    /// The `ReaderHeading` a character belongs to.
    static let readerHeading = NSAttributedString.Key("org.epublib.heading")
}

extension NSAttributedString {
    /// The headings in `range` (the whole text when nil), in order, each with its characters
    /// there. A heading's text is one range; its paragraph's closing break is not part of it.
    func readerHeadings(in range: NSRange? = nil) -> [(heading: ReaderHeading, range: NSRange)] {
        let full = NSRange(location: 0, length: length)
        let range = range.map { NSIntersectionRange($0, full) } ?? full
        var result: [(ReaderHeading, NSRange)] = []
        guard range.length > 0 else { return result }
        enumerateAttribute(.readerHeading, in: range) { value, run, _ in
            if let heading = value as? ReaderHeading { result.append((heading, run)) }
        }
        return result
    }
}
