import EPUBReading
import EPUBTestSupport
@testable import EPUBViewing
import MathMLLayout
import XCTest
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What a formula is read as, and in which language: the author's `alttext` in the content's
/// language, else a generated reading in the language the generator writes.
final class MathSpeechTests: XCTestCase {
    private typealias F = MathFixtures

    private func attachment(_ body: String, language: String? = "en", root: String = "") throws -> MathAttachment {
        try XCTUnwrap(try MathHarness.make(body, language: language, root: root).attachment)
    }

    func testAlttextIsPreservedVerbatimInTheContentsLanguage() throws {
        // A French book, a German passage in an English book, and markup that says so on `math`.
        let french = try attachment("<p>\(F.math(F.fraction, attributes: "alttext=\"\(F.frenchAlttext)\""))</p>", language: "fr")
        XCTAssertEqual(french.label, F.frenchAlttext)
        XCTAssertEqual(french.language, "fr")
        XCTAssertTrue(french.isLabelAuthored)
        let german = try attachment("<div lang=\"de\"><p>\(F.math(F.fraction, attributes: "alttext=\"\(F.germanAlttext)\""))</p></div>")
        XCTAssertEqual(german.label, F.germanAlttext)
        XCTAssertEqual(german.language, "de")
        let own = try attachment("<p>\(F.math(F.fraction, attributes: "xml:lang=\"de-CH\" alttext=\"\(F.germanAlttext)\""))</p>", language: "fr")
        XCTAssertEqual(own.language, "de-CH")
        // Whatever the author wrote is what is read: no translation, no rewording, only XML's
        // whitespace collapsed. Symbols and other scripts pass through.
        for text in ["a over b squared", "x² ≤ ½ · √y", "α 加 β", "  la   somme\n de 1 à n  ", "<b> & \"q\""] {
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            let made = try attachment("<p>\(F.math(F.fraction, attributes: "alttext=\"\(escaped)\""))</p>", language: "fr")
            XCTAssertEqual(made.label, text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
            XCTAssertEqual(made.textEquivalent, made.label)
            XCTAssertEqual(made.language, "fr")
        }
    }

    func testContentLanguageIsInheritedThenThePublications() throws {
        func language(_ body: String, publication: String? = "en", root: String = "") throws -> String? {
            let section = try MathHarness.section(body, language: publication, root: root)
            return MathSpeech.contentLanguage(of: try XCTUnwrap(section.formulas.first), publication: section.context.publication)
        }
        let math = F.math(F.fraction)
        XCTAssertEqual(try language("<p>\(math)</p>", publication: "fr"), "fr", "the publication's language")
        XCTAssertEqual(try language("<p>\(math)</p>", publication: "fr", root: "xml:lang=\"es\""), "es", "the document's")
        XCTAssertEqual(try language("<p>\(math)</p>", publication: "fr", root: "lang=\"es\""), "es")
        XCTAssertEqual(try language("<section lang=\"es\"><p xml:lang=\"it\">\(math)</p></section>"), "it", "the nearest ancestor's")
        XCTAssertEqual(try language("<p lang=\"it\">\(F.math(F.fraction, attributes: "xml:lang=\"pt-BR\""))</p>"), "pt-BR", "its own")
        XCTAssertEqual(try language("<p lang=\"it\">\(F.math(F.fraction, attributes: "lang=\"ja\""))</p>"), "ja")
        // An empty value says the language is unknown: no voice is asked for.
        XCTAssertNil(try language("<p xml:lang=\"\">\(math)</p>", publication: "fr"))
        XCTAssertNil(try language("<p>\(math)</p>", publication: nil))
        // So do the tags that name no language to speak.
        XCTAssertNil(try language("<p>\(math)</p>", publication: "und"))
        XCTAssertNil(try language("<p lang=\"zxx\">\(math)</p>", publication: "fr"))
        XCTAssertNil(try language("<p lang=\"mul-Latn\">\(math)</p>", publication: "fr"))
    }

    /// MathMLLayout 0.1.0 generates English and takes no locale: the reading is tagged with the
    /// language it is in, so a French book's formula is not read as French words.
    func testGeneratedReadingIsTaggedWithTheLanguageItIsWrittenIn() throws {
        for (language, root) in [("fr", ""), ("de", ""), ("en", "xml:lang=\"ja\"")] {
            let made = try attachment("<p>\(F.math(F.fraction))</p>", language: language, root: root)
            XCTAssertEqual(made.label, F.englishReading)
            XCTAssertEqual(made.language, MathSpeech.generatedLanguage)
            XCTAssertEqual(made.language, "en")
            XCTAssertFalse(made.isLabelAuthored)
        }
        // The content's language reaches the one place a localized generator would take it.
        let node = try MathHarness.node(F.fraction)
        let generated = MathSpeech.generate(node, contentLanguage: "fr")
        XCTAssertEqual(generated.text, node.accessibilityDescription)
        XCTAssertEqual(generated.language, "en")
        XCTAssertEqual(MathSpeech.reading(alttext: "", formula: node, contentLanguage: "fr"),
                       MathSpeech.Reading(text: F.englishReading, language: "en", isAuthored: false))
        XCTAssertEqual(MathSpeech.reading(alttext: F.frenchAlttext, formula: node, contentLanguage: "fr"),
                       MathSpeech.Reading(text: F.frenchAlttext, language: "fr", isAuthored: true))
        // A whitespace-only alttext is no alttext.
        XCTAssertFalse(try attachment("<p>\(F.math(F.fraction, attributes: "alttext=\"  \""))</p>", language: "fr").isLabelAuthored)
    }

    @MainActor
    func testTheAttachmentCarriesItsLanguageToAccessibility() throws {
        let authored = try attachment("<p>\(F.math(F.fraction, attributes: "alttext=\"\(F.frenchAlttext)\""))</p>", language: "fr")
        let generated = try attachment("<p>\(F.math(F.fraction))</p>", language: "fr")
        XCTAssertEqual((authored as ReaderTextualAttachment).textLanguage, "fr")
        XCTAssertEqual((generated as ReaderTextualAttachment).textLanguage, "en")
        #if os(iOS)
        XCTAssertEqual(authored.accessibilityLabel, F.frenchAlttext)
        XCTAssertEqual(authored.accessibilityLanguage, "fr")
        XCTAssertEqual(generated.accessibilityLabel, F.englishReading)
        XCTAssertEqual(generated.accessibilityLanguage, "en")
        #elseif os(macOS)
        XCTAssertEqual(authored.image?.accessibilityDescription, F.frenchAlttext)
        XCTAssertEqual(generated.image?.accessibilityDescription, F.englishReading)
        #endif
        // Other attachments name no language of their own.
        XCTAssertNil((ReaderRuleAttachment(style: ComputedStyle(fontSize: 17), isDark: false) as ReaderTextualAttachment).textLanguage)
    }
}
