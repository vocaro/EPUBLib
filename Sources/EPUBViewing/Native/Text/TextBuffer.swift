import CoreFoundation
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Rendered UTF-16 and its attribute runs, accumulated in document order and turned into one
/// attributed string at the end, so a build never edits an attributed string per character.
struct TextBuffer {
    private(set) var units: [UInt16] = []
    private(set) var runs: [Run] = []

    struct Run {
        var location: Int
        var length: Int
        var source: Source
    }
    enum Source {
        /// An interned dictionary from `InlineStyling`.
        case attributes(Int)
        /// Rich content copied with its own attributes, plus the enclosing link if any.
        case unit(NSAttributedString, link: URL?)
    }

    var count: Int { units.count }
    /// The attributes of the last styled run, for generated text that continues it.
    var lastAttributes: Int? {
        for run in runs.reversed() { if case .attributes(let index) = run.source { return index } }
        return nil
    }

    mutating func append<C: Collection>(_ characters: C, attributes: Int) where C.Element == UInt16 {
        guard !characters.isEmpty else { return }
        let location = units.count
        units.append(contentsOf: characters)
        let length = units.count - location
        if let last = runs.indices.last, case .attributes(let index) = runs[last].source, index == attributes {
            runs[last].length += length
        } else {
            runs.append(Run(location: location, length: length, source: .attributes(attributes)))
        }
    }

    mutating func append(unit: NSAttributedString, link: URL?) {
        guard unit.length > 0 else { return }
        let location = units.count
        units.append(contentsOf: unit.string.utf16)
        runs.append(Run(location: location, length: units.count - location, source: .unit(unit, link: link)))
    }

    /// Replaces characters that would end a paragraph (U+2029, U+0085) in already appended text with
    /// U+2028, so paragraphs are exactly the builder's. Lengths are unchanged.
    mutating func replaceParagraphSeparators(from location: Int) {
        for index in location..<units.count where units[index] == 0x2029 || units[index] == 0x85 {
            units[index] = 0x2028
        }
    }

    /// Removes the last character when it belongs to a styled run (a generated separator).
    mutating func removeLast() {
        guard let last = runs.indices.last, case .attributes = runs[last].source else { return }
        units.removeLast()
        runs[last].length -= 1
        if runs[last].length == 0 { runs.removeLast() }
    }

    /// The scalar ending the text, or 0 when empty.
    var lastScalar: UInt32 {
        guard let last = units.last else { return 0 }
        if UTF16.isTrailSurrogate(last), units.count > 1, UTF16.isLeadSurrogate(units[units.count - 2]) {
            return 0x10000 + ((UInt32(units[units.count - 2]) - 0xD800) << 10) + (UInt32(last) - 0xDC00)
        }
        return UInt32(last)
    }

    /// The attributed string, built in one forward pass so the run array only ever grows at its
    /// end. Each paragraph's style (`paragraphs` sorted by `start`, covering the text) is merged
    /// into its runs' attributes rather than applied afterwards, which would split runs mid-array.
    func makeAttributedString(dictionaries: [CFDictionary],
                              paragraphs: [(start: Int, style: NSParagraphStyle)]) -> NSMutableAttributedString {
        let string = units.withUnsafeBufferPointer { buffer -> NSString in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return "" }
            return NSString(characters: base, length: buffer.count)
        }
        let result = NSMutableAttributedString(string: string as String)
        let target = result as CFMutableAttributedString
        var merged: [MergeKey: CFDictionary] = [:]
        func dictionary(_ index: Int, _ style: NSParagraphStyle?) -> CFDictionary {
            guard let style else { return dictionaries[index] }
            let key = MergeKey(attributes: index, style: ObjectIdentifier(style))
            if let cached = merged[key] { return cached }
            let copy = (dictionaries[index] as NSDictionary).mutableCopy() as! NSMutableDictionary
            copy[NSAttributedString.Key.paragraphStyle] = style
            merged[key] = copy
            return copy
        }
        var paragraph = -1
        CFAttributedStringBeginEditing(target)
        for run in runs {
            var location = run.location
            let end = run.location + run.length
            while location < end {
                while paragraph + 1 < paragraphs.count, paragraphs[paragraph + 1].start <= location { paragraph += 1 }
                let next = paragraph + 1 < paragraphs.count ? paragraphs[paragraph + 1].start : end
                let segmentEnd = min(end, next)
                let style = paragraph >= 0 ? paragraphs[paragraph].style : nil
                switch run.source {
                case .attributes(let index):
                    CFAttributedStringSetAttributes(target, CFRange(location: location, length: segmentEnd - location),
                                                    dictionary(index, style), true)
                case .unit(let unit, let link):
                    let offset = location - run.location
                    unit.enumerateAttributes(in: NSRange(location: offset, length: segmentEnd - location)) { attributes, range, _ in
                        var attributes = attributes
                        if let style { attributes[.paragraphStyle] = style }
                        if let link, attributes[.link] == nil { attributes[.link] = link }
                        result.setAttributes(attributes, range: NSRange(location: run.location + range.location, length: range.length))
                    }
                }
                location = segmentEnd
            }
        }
        CFAttributedStringEndEditing(target)
        return result
    }

    private struct MergeKey: Hashable {
        let attributes: Int
        let style: ObjectIdentifier
    }
}
