import EPUBReading
import Foundation
import MathMLLayout

/// What assistive technologies read for a formula, and the language to read it in.
///
/// An author's `alttext` is always the reading, verbatim but for collapsed whitespace, in the
/// language of the content around the formula. Without one the reading is generated from the
/// markup in the content's language where supported. The engine reports the language actually
/// selected, including English fallback, so assistive technology can choose a matching voice.
enum MathSpeech {
    struct Reading: Equatable, Sendable {
        var text: String
        /// The BCP 47 language of `text`; nil when the content declares none.
        var language: String?
        /// Whether `text` is the author's `alttext`.
        var isAuthored: Bool
    }

    /// The language of the content at `element`: the nearest `xml:lang` or `lang` on it or an
    /// ancestor, else the publication's first language. An empty value says the language is
    /// unknown, as in XML, and stops the search; so do the tags for undetermined, uncoded,
    /// multiple and no linguistic content, which name no voice.
    static func contentLanguage(of element: ContentNode, publication: EPUBPublication) -> String? {
        var node: ContentNode? = element
        while let current = node {
            if let language = current.language { return spoken(language) }
            node = current.parent
        }
        return publication.metadata.languages.first.flatMap(spoken)
    }

    private static func spoken(_ tag: String) -> String? {
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = tag.split(separator: "-").first.map { $0.lowercased() } ?? ""
        return primary.isEmpty || ["und", "mis", "mul", "zxx"].contains(primary) ? nil : tag
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
        let reading = formula.accessibilityDescription(locale: Locale(identifier: contentLanguage ?? "en"))
        return (reading.text, reading.language)
    }
}
