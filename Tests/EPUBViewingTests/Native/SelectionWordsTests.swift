import Foundation
import XCTest
@testable import EPUBViewing

/// The words a selection made with VoiceOver moves by (`ReaderSelectionWords`,
/// doc/native-viewer.md, "Text selected with VoiceOver").
final class SelectionWordsTests: XCTestCase {
    private func words(_ text: NSAttributedString) -> [String] {
        ReaderSelectionWords.words(in: NSRange(location: 0, length: text.length), of: text).map { (text.string as NSString).substring(with: $0) }
    }

    private func moved(_ move: ReaderSelectionWords.Move, _ selected: String, in string: String) -> (selection: String, word: String)? {
        let text = NSAttributedString(string: string)
        let range = (string as NSString).range(of: selected)
        guard let found = ReaderSelectionWords.apply(move, to: range, in: text) else { return nil }
        return ((string as NSString).substring(with: found.selection), (string as NSString).substring(with: found.word))
    }

    func testPunctuationGoesWithItsWordAndAWordInsideARunStartsAnother() {
        XCTAssertEqual(words(NSAttributedString(string: "Begin Consider the sea; “how,” she said—well-known.")),
                       ["Begin", "Consider", "the", "sea;", "“how,”", "she", "said—", "well-", "known."])
        // A language written without spaces is still read a word at a time, as the system
        // finds its words.
        let unspaced = words(NSAttributedString(string: "日本語の本です"))
        XCTAssertGreaterThan(unspaced.count, 1, "\(unspaced)")
        XCTAssertEqual(unspaced.joined(), "日本語の本です")
    }

    func testEachEndMovesByAWordEitherWay() throws {
        let line = "Begin Consider the subtleness of the sea; how its most"
        XCTAssertEqual(moved(.unselectFirst, line, in: line + " dreaded")?.selection, "Consider the subtleness of the sea; how its most")
        XCTAssertEqual(moved(.unselectFirst, line, in: line)?.word, "Begin ")
        XCTAssertEqual(moved(.unselectLast, line, in: line)?.selection, "Begin Consider the subtleness of the sea; how its")
        XCTAssertEqual(moved(.unselectLast, line, in: line)?.word, " most")
        XCTAssertEqual(moved(.selectNext, line, in: line + "\n      dreaded creatures")?.selection, line + "\n      dreaded")
        XCTAssertEqual(moved(.selectPrevious, "Consider", in: "Begin Consider")?.selection, "Begin Consider")
        // A selection that begins or ends inside a word is completed to it first.
        XCTAssertEqual(moved(.selectPrevious, "sider the", in: "Begin Consider the")?.selection, "Consider the")
        XCTAssertEqual(moved(.selectNext, "Begin Cons", in: "Begin Consider the")?.selection, "Begin Consider")
        XCTAssertEqual(moved(.unselectFirst, "sea; how", in: "the sea; how its")?.selection, "how")
    }

    func testThereIsNoWordToMoveByAtEitherEndOrToLeaveNone() {
        XCTAssertNil(moved(.selectPrevious, "Begin", in: "Begin Consider"))
        XCTAssertNil(moved(.selectNext, "Consider", in: "Begin Consider"))
        XCTAssertNil(moved(.unselectFirst, "Begin", in: "Begin Consider"))
        XCTAssertNil(moved(.unselectLast, "Consider", in: "Begin Consider"))
        XCTAssertNil(moved(.selectNext, "Consider", in: "Begin Consider \n  "))
    }

    /// Words nobody may hear are none: what `visibility: hidden` hides and what the book keeps
    /// from assistive technology are passed over.
    func testHiddenAndUnspokenWordsAreNoWords() {
        let text = NSMutableAttributedString(string: "Shown hidden kept last")
        let string = text.string as NSString
        text.addAttribute(.readerHidden, value: true, range: string.range(of: "hidden"))
        text.addAttribute(.readerUnspoken, value: true, range: string.range(of: "kept"))
        XCTAssertEqual(words(text), ["Shown", "last"])
        let found = ReaderSelectionWords.apply(.selectNext, to: string.range(of: "Shown"), in: text)
        XCTAssertEqual(found.map { string.substring(with: $0.selection) }, "Shown hidden kept last")
    }
}
