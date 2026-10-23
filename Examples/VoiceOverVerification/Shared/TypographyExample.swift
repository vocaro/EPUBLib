import CoreText
import EPUBCore
import EPUBViewing
import Foundation

// snippet:start typography
/// Registers a font the app bundles, once at launch, so that the reader finds it by its family
/// name. Listing it under `UIAppFonts` (iOS) or `ATSApplicationFontsPath` (macOS) in the app's
/// Info.plist does the same.
func registerBundledFont(at url: URL) {
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}

/// Sets book text in that font with WCAG 2.2's text spacing (SC 1.4.12), ragged and unhyphenated,
/// over the book's own styles. Preformatted text, code, tables and MathML keep the book's.
@MainActor
func readWithLegibleText(_ controls: EPUBReaderControls, family: String) {
    controls.changeStyle { style in
        style.typography = EPUBReaderStyle.Typography(
            fontFamily: .named(family), lineHeight: 1.5, paragraphSpacing: 2, letterSpacing: 0.12,
            wordSpacing: 0.16, pageMargins: 0.5, alignment: .start, hyphenation: false,
            overridesBookStyles: true)
    }
}
// snippet:end typography
