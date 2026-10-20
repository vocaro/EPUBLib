import EPUBReading
import Foundation
import MathMLLayout

/// What assistive technologies read for a formula, and the language to read it in.
///
/// An author's `alttext` is always the reading, verbatim but for collapsed whitespace, in the
/// language of the content around the formula. Without one the reading is generated from the
/// markup. The reader retains the engine's default English vocabulary, so a generated
/// reading is tagged English whatever the content's language: an English voice then reads
/// English words, rather than the book's voice mispronouncing them. `generate` is the one place
/// to adopt localized engine readings in a separate change.
enum MathSpeech {
    struct Reading: Equatable, Sendable {
        var text: String
        /// The BCP 47 language of `text`; nil when the content declares none.
        var language: String?
        /// Whether `text` is the author's `alttext`.
        var isAuthored: Bool
    }

    /// The language of the default engine vocabulary used by this reader.
    static let generatedLanguage = "en"

    /// The language of the content at `element`: the nearest `xml:lang` or `lang` on it or an
    /// ancestor, else the publication's first language. An empty value says the language is
    /// unknown, as in XML, and stops the search; so do the tags for undetermined, uncoded,
    /// multiple and no linguistic content, which name no voice (`InlineLanguage.spoken`).
    /// It is the language the section's walk gives the text there (`InlineLanguage.typesetting`),
    /// which a formula, built apart from that walk, looks up for itself.
    static func contentLanguage(of element: ContentNode, publication: EPUBPublication) -> String? {
        var node: ContentNode? = element
        while let current = node {
            if let language = current.language { return InlineLanguage.spoken(language) }
            node = current.parent
        }
        return publication.metadata.languages.first.flatMap(InlineLanguage.spoken)
    }

    /// The reading of a formula with `alttext` (whitespace already collapsed; empty when the
    /// markup has none) and the engine's tree `formula`, as authored.
    static func reading(alttext: String, formula: MathMLNode, contentLanguage: String?) -> Reading {
        if !alttext.isEmpty { return Reading(text: alttext, language: contentLanguage, isAuthored: true) }
        let generated = generate(formula, contentLanguage: contentLanguage)
        return Reading(text: generated.text, language: generated.language, isAuthored: false)
    }

    /// A spoken reading of the markup and the language it came out in.
    static func generate(_ formula: MathMLNode, contentLanguage: String?) -> (text: String, language: String) {
        // The engine reads elementary math as one run of numbers; give it the rows apart.
        let rows = MathElementary.spoken(formula)
        guard rows != formula else { return (formula.accessibilityDescription, generatedLanguage) }
        return (rows.accessibilityDescription.replacingOccurrences(of: " ,", with: ","), generatedLanguage)
    }
}
