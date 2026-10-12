import Foundation
@testable import EPUBViewing

extension NSAttributedString {
    /// The words of the text's hidden labels (`SpokenLabelAttachment`), in order.
    var spokenLabels: [String] {
        var labels: [String] = []
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, _, _ in
            if let label = value as? SpokenLabelAttachment { labels.append(label.text) }
        }
        return labels
    }

    /// What is drawn: the text without its hidden labels' characters, and without the lines of
    /// no height that hold nothing else.
    var drawnString: String {
        let text = string as NSString
        var paragraphs: [String] = []
        var location = 0
        while location < text.length {
            var end = 0, contentsEnd = 0
            text.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            var drawn = "", labels = 0
            if contentsEnd > location {
                enumerateAttribute(.attachment, in: NSRange(location: location, length: contentsEnd - location)) { value, run, _ in
                    if value is SpokenLabelAttachment { labels += run.length } else { drawn += text.substring(with: run) }
                }
            }
            if labels == 0 || !drawn.isEmpty { paragraphs.append(drawn) }
            if end == contentsEnd { break }
            location = end
            if location == text.length { paragraphs.append("") } // The text ends with a paragraph break.
        }
        return paragraphs.joined(separator: "\n")
    }
}
