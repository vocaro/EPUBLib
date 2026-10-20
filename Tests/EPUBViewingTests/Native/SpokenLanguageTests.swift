import EPUBCore
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The languages the reader gives an assistive technology for the words it reads out (#65):
/// a word is in the language its characters carry for typesetting, the content's or else the
/// package's, which is the language a formula looks up for itself, with the tags that name
/// no voice left out; an attachment is in the language it declares for its words. The parts
/// cover the reader's plain text as VoiceOver is given it exactly, so a label can carry them.
final class SpokenLanguageTests: XCTestCase {
    private typealias F = MathFixtures

    /// The parts of `range` as "language:words", "none" where a part names no language.
    private func parts(_ text: NSAttributedString, _ range: NSRange? = nil) -> [String] {
        let range = range ?? NSRange(location: 0, length: text.length)
        let languages = text.readerSpokenLanguages(in: range)
        let plain = text.readerPlainText(in: range, spoken: true) as NSString
        XCTAssertEqual(languages.runs.reduce(0) { $0 + $1.length }, plain.length, "the parts cover the plain text")
        var location = 0
        return languages.runs.map { run in
            defer { location += run.length }
            return "\(run.language ?? "none"):" + plain.substring(with: NSRange(location: location, length: run.length))
        }
    }

    private func range(of words: String, in text: NSAttributedString) -> NSRange {
        (text.string as NSString).range(of: words)
    }

    func testWordsAreInTheLanguageTheirMarkupDeclaresElseThePackages() throws {
        let section = try BuilderHarness.build("""
            <p>Plain words.</p><p lang="fr">Une phrase.</p><p xml:lang="de-CH">Ein Satz.</p>\
            <div lang="it"><p>Parole ereditate.</p></div>\
            <p lang="und">Undetermined.</p><p lang="zxx">Nothing.</p><p lang="MUL">Several.</p><p lang="mis-x">Uncoded.</p>\
            <p xml:lang="">Unknown.</p><div xml:lang=""><p lang="es">Otra vez.</p></div>
            """)
        let text = section.string
        let expected: [(String, String?)] = [
            ("Plain words.", "en"), ("Une phrase.", "fr"), ("Ein Satz.", "de-CH"), ("Parole ereditate.", "it"),
            ("Undetermined.", nil), ("Nothing.", nil), ("Several.", nil), ("Uncoded.", nil),
            ("Unknown.", nil), ("Otra vez.", "es"),
        ]
        for (words, language) in expected {
            let languages = text.readerSpokenLanguages(in: range(of: words, in: text))
            XCTAssertEqual(languages.main, language, words)
            XCTAssertFalse(languages.isMixed, words)
        }
    }

    /// The text's own run of characters and a formula's lookup give the same language.
    func testAWordAndAFormulaBesideItAreInTheSameLanguage() throws {
        let book = try BuilderHarness.build("""
            <div lang="fr"><p>Soit \(F.math(F.fraction, attributes: "alttext=\"\(F.frenchAlttext)\"")) ici.</p></div>\
            <p>Then \(F.math(F.fraction, attributes: "alttext=\"a over b squared\"")) here.</p>
            """, rich: NativeRichContent())
        let text = book.string
        XCTAssertEqual(parts(text, range(of: "Soit", in: text).union(range(of: "ici.", in: text))),
                       ["fr:Soit \(F.frenchAlttext) ici."])
        XCTAssertEqual(parts(text, range(of: "Then", in: text).union(range(of: "here.", in: text))),
                       ["en:Then a over b squared here."])
    }

    func testALineThatMixesLanguagesHasEachPartInItsOwn() throws {
        let section = try BuilderHarness.build("<p lang=\"en\">He said <span lang=\"fr\">bonjour</span> and left.</p>")
        let text = section.string
        let line = range(of: "He said", in: text).union(range(of: "left.", in: text))
        XCTAssertEqual(parts(text, line), ["en:He said ", "fr:bonjour", "en: and left."])
        let languages = text.readerSpokenLanguages(in: line)
        XCTAssertEqual(languages.main, "en", "14 characters of English to 7 of French")
        XCTAssertTrue(languages.isMixed)
    }

    /// A formula's generated reading is English in French text; a hidden label is in the
    /// language it declares, else in the text's, and the space that sets it off is counted.
    func testAnAttachmentIsInTheLanguageItDeclaresForItsWords() throws {
        let generated = try BuilderHarness.build("<p>Soit \(F.math(F.fraction)) ici.</p>", rootAttributes: "xml:lang=\"fr\"",
                                                 rich: NativeRichContent())
        let sentence = range(of: "Soit", in: generated.string).union(range(of: "ici.", in: generated.string))
        XCTAssertEqual(parts(generated.string, sentence), ["fr:Soit ", "en:\(F.englishReading)", "fr: ici."])

        let french: [NSAttributedString.Key: Any] = [InlineStyling.languageKey: "fr"]
        func labelled(_ language: String?) -> NSAttributedString {
            let text = NSMutableAttributedString(string: "Vu", attributes: french)
            let label = NSMutableAttributedString(attributedString: NSAttributedString(
                attachment: SpokenLabelAttachment(text: "hidden words", language: language)))
            label.addAttributes(french, range: NSRange(location: 0, length: label.length))
            text.append(label)
            text.append(NSAttributedString(string: "ici.", attributes: french))
            return text
        }
        XCTAssertEqual(labelled("en").readerPlainText(), "Vu hidden words ici.")
        // The space after the label is white space, in the language of the words before it.
        XCTAssertEqual(parts(labelled("en")), ["fr:Vu", "en: hidden words ", "fr:ici."])
        XCTAssertEqual(parts(labelled(nil)), ["fr:Vu hidden words ici."])
        XCTAssertEqual(parts(labelled("und")), ["fr:Vu", "none: hidden words ", "fr:ici."],
                       "a label declared undetermined names no language, and does not take the text's")
    }

    /// What is not read decides no language: words `visibility: hidden` hides (#357), and the
    /// words of a picture the book keeps from assistive technology, which VoiceOver is not
    /// given. Each would outweigh the French around it.
    @MainActor func testWhatIsNotReadDecidesNoLanguage() throws {
        let english = "a much longer English sentence that no one reads"
        let section = try BoxLayoutHarness.build("""
            <p lang="fr">Oui<span class="v" lang="en">\(english)</span>non.</p>\
            <p lang="fr">Voici <img src="p.png" alt="\(english)" aria-hidden="true"/> une image.</p>\
            <table><tr><td lang="de">Wort</td><td lang="fr">Oui<span class="v" lang="en">\(english)</span></td></tr></table>
            """, css: BoxLayoutHarness.reset + ".v { visibility: hidden } img { width: 20px; height: 20px }",
            files: ["p.png": RichFixture.image(width: 40, height: 40)])
        let text = section.string
        // Hidden between two shown words, the English is read as one space, which is theirs.
        let hidden = range(of: "Oui", in: text).union(range(of: "non.", in: text))
        XCTAssertEqual(parts(text, hidden), ["fr:Oui non."])
        XCTAssertEqual(text.readerSpokenLanguages(in: hidden).main, "fr")

        let picture = range(of: "Voici", in: text).union(range(of: "une image.", in: text))
        XCTAssertTrue(text.readerPlainText(in: picture).contains(english), "Copy takes the picture's words")
        XCTAssertEqual(parts(text, picture), ["fr:Voici  une image."])
        XCTAssertEqual(text.readerSpokenLanguages(in: picture).main, "fr")

        var rows: [TableRowAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let row = value as? TableRowAttachment { rows.append(row) }
        }
        let table = try XCTUnwrap(rows.first?.table)
        XCTAssertEqual(table.cells.map(\.text), ["Wort", "Oui"])
        XCTAssertEqual(table.cells.map(\.spokenLanguage), ["de", "fr"])
    }

    func testWhiteSpaceAndEvenCountsChangeNoVoice() {
        let spaced = ReaderSpokenLanguages([("Words", "en"), (" ", "fr"), ("more", "en"), ("\n", nil)])
        XCTAssertEqual(spaced.runs, [.init(length: 11, language: "en")])
        XCTAssertEqual(spaced.main, "en")
        XCTAssertFalse(spaced.isMixed)
        XCTAssertEqual(ReaderSpokenLanguages([("  ", nil), ("mots", "fr")]).runs, [.init(length: 6, language: "fr")],
                       "white space before the first words is theirs")
        let even = ReaderSpokenLanguages([("abcd", "de"), (" ", nil), ("efgh", "fr")])
        XCTAssertEqual(even.main, "de", "the first of two languages with as many characters")
        XCTAssertEqual(even.runs, [.init(length: 5, language: "de"), .init(length: 4, language: "fr")])
        XCTAssertTrue(even.isMixed)
        let most = ReaderSpokenLanguages([("ab", "en"), ("cdef", "fr"), ("g", "en")])
        XCTAssertEqual(most.main, "fr")
        XCTAssertEqual(most.runs.count, 3)
        let none = ReaderSpokenLanguages([("ab", nil), ("cd", nil)])
        XCTAssertNil(none.main)
        XCTAssertFalse(none.isMixed)
        let unnamed = ReaderSpokenLanguages([("abc", nil), ("de", "en")])
        XCTAssertNil(unnamed.main, "words in no language count as words")
        XCTAssertTrue(unnamed.isMixed)
        XCTAssertEqual(ReaderSpokenLanguages([(" \n", "en")]).runs, [.init(length: 2, language: nil)])
        XCTAssertNil(ReaderSpokenLanguages([(" \n", "en")]).main)
        XCTAssertEqual(ReaderSpokenLanguages([]), ReaderSpokenLanguages([("", "en")]))
    }

    func testTheTagsThatNameNoVoiceGiveNone() {
        XCTAssertEqual(InlineLanguage.spoken("fr"), "fr")
        XCTAssertEqual(InlineLanguage.spoken(" pt-BR "), "pt-BR")
        for tag in ["", "  ", "und", "UND", "mis", "mul", "zxx", "zxx-Latn"] {
            XCTAssertNil(InlineLanguage.spoken(tag), tag)
        }
    }

    /// A row read whole is each cell's words in the language most of that cell is in.
    func testARowReadWholeHasEachCellInItsLanguage() throws {
        let section = try BuilderHarness.build("""
            <table><tr><td>Deutsche Zelle</td><td lang="fr">Cellule <span lang="en">with English</span></td></tr></table>
            """, rootAttributes: "xml:lang=\"de\"", rich: NativeRichContent())
        var rows: [TableRowAttachment] = []
        section.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: section.string.length)) { value, _, _ in
            if let row = value as? TableRowAttachment { rows.append(row) }
        }
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.textEquivalent, "Deutsche Zelle\tCellule with English")
        XCTAssertEqual(row.table.cells.map(\.spokenLanguage), ["de", "en"], "11 characters of English to 7 of French")
        let languages = row.spokenLanguages
        XCTAssertEqual(languages.runs, [.init(length: 15, language: "de"), .init(length: 20, language: "en")])
        XCTAssertEqual(languages.main, "en")
    }
}
