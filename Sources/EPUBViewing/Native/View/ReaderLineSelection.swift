import Foundation
#if os(iOS)
import UIKit
#endif

/// The words a selection made with VoiceOver grows or shrinks by, one at a time: runs of the
/// text without white space, cut again where a word begins inside one, as words follow one
/// another in a language written without spaces. Punctuation goes with the word it touches
/// ("sea;", "began."), and a word that a hyphen joins to the next is two. Text that
/// `visibility: hidden` hides, or that the book keeps from assistive technology, is no word:
/// the reader says the word it adds or takes away, and a word nobody may hear would be
/// silence (doc/native-viewer.md, "Text selected with VoiceOver").
enum ReaderSelectionWords {
    /// What a move does: take the selection's first or last word out of it, or add the word
    /// before it or after it.
    enum Move: CaseIterable {
        case unselectFirst, unselectLast, selectPrevious, selectNext

        /// The action's name, as VoiceOver offers it.
        var name: String {
            switch self {
            case .unselectFirst: "Unselect First Word"
            case .unselectLast: "Unselect Last Word"
            case .selectPrevious: "Select Previous Word"
            case .selectNext: "Select Next Word"
            }
        }

        /// The move adds a word, rather than taking one away.
        var selects: Bool { self == .selectPrevious || self == .selectNext }
    }

    /// How far from the selection's edge words are looked for. A word is never this long.
    private static let reach = 4096

    /// `selection` after `move`, in `text`'s characters, and the word it added or took away.
    /// Nil where there is no word to move by: before the text's first word, after its last,
    /// or where the selection would be left with none.
    static func apply(_ move: Move, to selection: NSRange, in text: NSAttributedString) -> (selection: NSRange, word: NSRange)? {
        let end = NSMaxRange(selection)
        guard selection.length > 0, end <= text.length else { return nil }
        switch move {
        case .unselectFirst:
            let found = words(in: NSRange(location: selection.location, length: min(selection.length, reach)), of: text)
            guard let first = found.firstIndex(where: { NSMaxRange($0) > selection.location }),
                  first + 1 < found.count, found[first + 1].location < end else { return nil }
            let start = found[first + 1].location
            return (NSRange(location: start, length: end - start), NSRange(location: selection.location, length: start - selection.location))
        case .unselectLast:
            let lower = max(selection.location, end - reach)
            let found = words(in: NSRange(location: lower, length: end - lower), of: text)
            guard let last = found.lastIndex(where: { $0.location < end }), last > 0,
                  NSMaxRange(found[last - 1]) > selection.location else { return nil }
            let kept = NSMaxRange(found[last - 1])
            return (NSRange(location: selection.location, length: kept - selection.location), NSRange(location: kept, length: end - kept))
        case .selectPrevious:
            let lower = max(0, selection.location - reach)
            guard let word = words(in: NSRange(location: lower, length: selection.location - lower), of: text)
                .last(where: { $0.location < selection.location }) else { return nil }
            return (NSRange(location: word.location, length: end - word.location),
                    NSRange(location: word.location, length: selection.location - word.location))
        case .selectNext:
            let upper = min(text.length, end + reach)
            guard let word = words(in: NSRange(location: end, length: upper - end), of: text)
                .first(where: { NSMaxRange($0) > end }) else { return nil }
            return (NSRange(location: selection.location, length: NSMaxRange(word) - selection.location),
                    NSRange(location: end, length: NSMaxRange(word) - end))
        }
    }

    /// The words of `text` that meet `range`, whole, in order.
    static func words(in range: NSRange, of text: NSAttributedString) -> [NSRange] {
        let string = text.string as NSString
        func isSpace(_ index: Int) -> Bool {
            if let scalar = Unicode.Scalar(string.character(at: index)), scalar.properties.isWhitespace { return true }
            return text.attribute(.readerHidden, at: index, effectiveRange: nil) != nil
                || text.attribute(.readerUnspoken, at: index, effectiveRange: nil) != nil
        }
        // Whole words: the range is taken out to the spaces round the words at its edges.
        var lower = max(0, range.location), upper = min(text.length, NSMaxRange(range))
        let limit = reach
        while lower > 0, lower > range.location - limit, !isSpace(lower - 1) { lower -= 1 }
        while upper < text.length, upper < NSMaxRange(range) + limit, !isSpace(upper) { upper += 1 }
        var result: [NSRange] = []
        var index = lower
        while index < upper {
            guard !isSpace(index) else { index += 1; continue }
            var runEnd = index
            while runEnd < upper, !isSpace(runEnd) { runEnd += 1 }
            let run = NSRange(location: index, length: runEnd - index)
            // A word that begins after another has ended, inside the run, starts a word of its own.
            var cuts: [Int] = [], seen = false
            string.enumerateSubstrings(in: run, options: [.byWords, .substringNotRequired]) { _, word, _, _ in
                if seen, word.location > run.location { cuts.append(word.location) }
                seen = true
            }
            var start = run.location
            for cut in cuts + [runEnd] where cut > start {
                let word = NSRange(location: start, length: cut - start)
                // An attachment that says nothing, a rule's, is no word.
                if !text.readerPlainText(in: word, spoken: true).allSatisfy(\.isWhitespace) { result.append(word) }
                start = cut
            }
            index = runEnd
        }
        return result
    }
}

#if os(iOS)
extension ReaderTextView {
    /// The characters the item at `range` selects as its line, in this view's: every line it
    /// is on, as far as their first and last characters that are not white space, and in a
    /// page column no further than the page. A link, a picture or the words beside them are
    /// part of a line, and select it; a heading is one item, and selects all its lines. Nil
    /// where those lines hold no words VoiceOver is given: a picture without words or one the
    /// book keeps from assistive technology, a rule.
    func accessibilityLineCharacters(of range: NSRange) -> NSRange? {
        guard let storage = contentStorage.textStorage, range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        var lines = range
        if let first = line(containing: range.location) { lines.formUnion(first.range) }
        if let last = line(containing: NSMaxRange(range) - 1) { lines.formUnion(last.range) }
        lines = NSIntersectionRange(lines, isPageColumn ? shownCharacters : NSRange(location: 0, length: storage.length))
        let text = storage.string as NSString
        let shown = CharacterSet.whitespacesAndNewlines.inverted
        let first = text.rangeOfCharacter(from: shown, options: [], range: lines)
        guard first.location != NSNotFound else { return nil }
        let last = text.rangeOfCharacter(from: shown, options: .backwards, range: lines)
        let selected = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        return spokenText(in: selected).allSatisfy(\.isWhitespace) ? nil : selected
    }

    /// Whether the item at `range`, in this view's characters, holds any of the reader's
    /// selection, however it was made.
    func holdsLineSelection(_ range: NSRange) -> Bool {
        guard let canvas, let selection = canvas.currentSelection,
              let local = canvas.localRange(of: selection.range, in: self) else { return false }
        return NSIntersectionRange(local, range).length > 0
    }

    /// What VoiceOver can do with the text of the item whose characters `range` gives, in
    /// this view's, when they are asked for: on iPhone and iPad it cannot select the reader's
    /// text as it does a text view's, and no edit menu comes up for a selection set in code
    /// (doc/native-viewer.md, "Text selected with VoiceOver"). An item outside the selection
    /// selects its line, or adds its line to a selection in the same section. An item that
    /// holds some of the selection takes the selection away, copies it, gives it to the host's
    /// selection action, and moves either end of it by a word. `range` is asked again when an
    /// action is performed: VoiceOver keeps the actions it was given, and the item may stand
    /// for another line by then.
    func lineSelectionActions(for range: @escaping @MainActor () -> NSRange?) -> [ReaderTableAction] {
        guard let canvas, let characters = range(), let line = lineSelectionRange(of: characters) else { return [] }
        let selection = canvas.currentSelection?.range
        let plain = selection.map { $0.start.tableCell == nil && $0.end.tableCell == nil } ?? false
        guard holdsLineSelection(characters) else {
            var result = [ReaderTableAction(name: "Select Line") { [weak self] in
                guard let self, let canvas = self.canvas, let characters = range(), let line = lineSelectionRange(of: characters) else { return false }
                return canvas.selectFromAccessibility(line)
            }]
            if let selection, plain, selection.start.section == line.start.section, selection.end.section == line.end.section {
                result.append(ReaderTableAction(name: "Extend Selection to Line") { [weak self] in
                    guard let self, let canvas = self.canvas, let current = canvas.currentSelection?.range,
                          current.start.tableCell == nil, current.end.tableCell == nil,
                          let characters = range(), let line = lineSelectionRange(of: characters),
                          current.start.section == line.start.section, current.end.section == line.end.section else { return false }
                    return canvas.selectFromAccessibility(ReaderTextRange(start: min(current.start, line.start), end: max(current.end, line.end)))
                })
            }
            return result
        }
        var result = [
            ReaderTableAction(name: "Deselect Text") { [weak canvas] in
                guard let canvas, canvas.currentSelection != nil else { return false }
                canvas.clearSelection()
                return true
            },
            ReaderTableAction(name: "Copy") { [weak self] in
                guard let self, let canvas = self.canvas, let text = canvas.selectionText(for: self) ?? canvas.currentSelection?.text,
                      !text.isEmpty else { return false }
                // What the edit menu's Copy writes (`copy(_:)`). Nothing a listener can tell
                // changes when the words are copied.
                pasteboard.string = text
                canvas.announce("Copied")
                return true
            }]
        if let title = canvas.configuration.selectionActionTitle {
            result.append(ReaderTableAction(name: title) { [weak canvas] in
                guard let canvas, canvas.currentSelection != nil else { return false }
                canvas.performSelectionAction()
                return true
            })
        }
        // A selection that begins or ends in a table's cell, or runs into another section, is
        // moved by touch alone.
        if let selection, plain, selection.start.section == selection.end.section {
            result += ReaderSelectionWords.Move.allCases.map { move in
                ReaderTableAction(name: move.name) { [weak canvas] in canvas?.moveSelectionForAccessibility(move) ?? false }
            }
        }
        return result
    }

    /// The book's range of the line `characters` selects, as `accessibilityLineCharacters(of:)` finds it.
    private func lineSelectionRange(of characters: NSRange) -> ReaderTextRange? {
        guard let canvas, let lines = accessibilityLineCharacters(of: characters),
              let start = canvas.position(at: lines.location, in: self),
              let end = canvas.position(at: NSMaxRange(lines), in: self) else { return nil }
        return ReaderTextRange(start: start, end: end)
    }
}

extension ReaderCanvasView {
    /// Moves an end of the selection by a word (`ReaderSelectionWords`) and says which word,
    /// with "selected" or "unselected" after it, as VoiceOver says of the words it selects in
    /// a text field. The word is in its own language, and the rest in the reader's English, as
    /// "Copied" is. False where there is no word to move by.
    func moveSelectionForAccessibility(_ move: ReaderSelectionWords.Move) -> Bool {
        guard let current = currentSelection?.range, current.start.tableCell == nil, current.end.tableCell == nil,
              current.start.section == current.end.section, let text = dataSource?.text(forSection: current.start.section),
              let moved = ReaderSelectionWords.apply(move, to: NSRange(location: current.start.offset, length: current.end.offset - current.start.offset), in: text),
              selectFromAccessibility(ReaderTextRange(section: current.start.section, moved.selection.location..<NSMaxRange(moved.selection)))
        else { return false }
        let words = text.readerPlainText(in: moved.word, spoken: true).trimmingCharacters(in: .whitespacesAndNewlines)
        let said = NSMutableAttributedString(string: words)
        if let language = text.readerSpokenLanguages(in: moved.word).main {
            said.addAttribute(.accessibilitySpeechLanguage, value: language, range: NSRange(location: 0, length: said.length))
        }
        said.append(NSAttributedString(string: move.selects ? " selected" : " unselected"))
        announce(said)
        return true
    }
}
#endif
