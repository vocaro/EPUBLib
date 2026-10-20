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

    func testGeneratedReadingsUseTheSelectedSupportedLanguage() throws {
        let expected = ["en": F.englishReading,
                        "fr": "début de fraction a sur b au carré fin de fraction",
                        "de": "Anfang Bruch a durch b Quadrat Ende Bruch",
                        "es": "inicio de fracción a sobre b al cuadrado fin de fracción",
                        "it": "inizio frazione a fratto b al quadrato fine frazione"]
        for (requested, selected) in [("en", "en"), ("fr", "fr"), ("fr-CA", "fr"), ("de-CH", "de"),
                                      ("es", "es"), ("it", "it"), ("en-GB", "en-GB"), ("ja-JP", "en")] {
            let made = try attachment("<p>\(F.math(F.fraction))</p>", language: requested)
            XCTAssertEqual(made.language, selected)
            XCTAssertEqual(made.label, expected[selected == "en-GB" ? "en" : selected], requested)
            XCTAssertFalse(made.isLabelAuthored)
        }
        let own = try attachment("<p lang='fr'>\(F.math(F.fraction, attributes: "xml:lang='it'"))</p>", language: "de")
        XCTAssertEqual(own.language, "it")
        XCTAssertEqual(own.label, expected["it"])
        let unknown = try attachment("<p xml:lang=''>\(F.math(F.fraction))</p>", language: "fr")
        XCTAssertEqual(unknown.language, "en")
        XCTAssertEqual(unknown.label, F.englishReading)
        XCTAssertFalse(try attachment("<p>\(F.math(F.fraction, attributes: "alttext='  '"))</p>", language: "fr").isLabelAuthored)
    }

    @MainActor
    func testTheAttachmentCarriesItsLanguageToAccessibility() throws {
        let authored = try attachment("<p>\(F.math(F.fraction, attributes: "alttext=\"\(F.frenchAlttext)\""))</p>", language: "fr")
        let generated = try attachment("<p>\(F.math(F.fraction))</p>", language: "fr")
        XCTAssertEqual((authored as ReaderTextualAttachment).textLanguage, "fr")
        XCTAssertEqual((generated as ReaderTextualAttachment).textLanguage, "fr")
        #if os(iOS)
        XCTAssertEqual(authored.accessibilityLabel, F.frenchAlttext)
        XCTAssertEqual(authored.accessibilityLanguage, "fr")
        XCTAssertEqual(generated.accessibilityLabel, "début de fraction a sur b au carré fin de fraction")
        XCTAssertEqual(generated.accessibilityLanguage, "fr")
        #elseif os(macOS)
        XCTAssertEqual(authored.image?.accessibilityDescription, F.frenchAlttext)
        XCTAssertEqual(generated.image?.accessibilityDescription, "début de fraction a sur b au carré fin de fraction")
        #endif
        // Other attachments name no language of their own.
        XCTAssertNil((ReaderRuleAttachment(style: ComputedStyle(fontSize: 17), isDark: false) as ReaderTextualAttachment).textLanguage)
    }
}
