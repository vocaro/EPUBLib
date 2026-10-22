import CoreText
import EPUBCore
import EPUBReading
@testable import EPUBViewing
import XCTest
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The host's font, spacing, alignment and hyphenation (`EPUBReaderStyle.Typography`, #673) in
/// the style resolver, with the switch that sets them over the book's own declarations off and
/// on. The expectations are CSS's: off, the settings are a user style sheet's normal
/// declarations on `:root` and `p` (CSS Cascade 4 §6.2), which the book's declarations beat and
/// its elements inherit; on, each value set is the element's whatever the book declares.
/// Preformatted text, code, tables, MathML and boxes sized or placed by the book are styled as
/// with no settings at all, which is the issue's "leaving alone what must not change".
final class ReaderTextSettingsTests: XCTestCase {
    /// WCAG 2.2 SC 1.4.12's text spacing: line height 1.5, paragraph spacing 2, letter spacing
    /// 0.12 and word spacing 0.16 times the font size, with a family, alignment and hyphenation.
    private static func settings(overrides: Bool, alignment: EPUBReaderStyle.Typography.Alignment = .justified,
                                 hyphenation: Bool = false) -> EPUBReaderStyle.Typography {
        EPUBReaderStyle.Typography(fontFamily: .named("Atkinson Hyperlegible"), lineHeight: 1.5, paragraphSpacing: 2,
                                   letterSpacing: 0.12, wordSpacing: 0.16, pageMargins: 0, alignment: alignment,
                                   hyphenation: hyphenation, overridesBookStyles: overrides)
    }

    private func styled(_ body: String, css: String = "", _ settings: EPUBReaderStyle.Typography? = nil) throws -> StyledDocument {
        var typography = NativeTypography(fontSize: 16)
        if let settings { typography.text = ReaderTextSettings(settings) }
        return try StyleTestSupport.styled(body, css: css, typography: typography)
    }

    /// A style as the book's styles alone give it: the record of the settings taken off.
    private func plain(_ style: ComputedStyle) -> ComputedStyle {
        var style = style
        style.textSettings = nil
        return style
    }

    func testNothingSetLeavesEveryStyleAsItWas() throws {
        let body = "<h1 id='h'>Title</h1><p id='p'>Text <em id='em'>here</em>.</p><pre id='pre'>a  b</pre>"
        let css = "body { font-family: Georgia, serif } p { margin: 0 }"
        let before = try styled(body, css: css)
        let after = try styled(body, css: css, EPUBReaderStyle.Typography(pageMargins: 2, overridesBookStyles: true))
        XCTAssertEqual(ReaderTextSettings(EPUBReaderStyle.Typography(pageMargins: 2, overridesBookStyles: true)), ReaderTextSettings(),
                       "page margins are the canvas's, and the switch alone sets nothing, so neither rebuilds the text")
        for (order, style) in before.styles {
            XCTAssertEqual(after.styles[order], style)
            XCTAssertNil(after.styles[order]?.textSettings)
        }
    }

    // MARK: The switch off: the reader's defaults

    func testWithTheSwitchOffTheSettingsStandInForTheReadersDefaults() throws {
        let body = "<h1 id='h'>Title</h1><p id='p'>Text <em id='em'>here</em>.</p>"
        let result = try styled(body, Self.settings(overrides: false))
        let paragraph = result.style("p")
        XCTAssertEqual(paragraph.fontFamilies, ["atkinson hyperlegible", "serif"], "the reader's serif follows the family")
        XCTAssertEqual(paragraph.lineHeight, .multiple(1.5))
        XCTAssertEqual(paragraph.letterSpacing, 0.12 * 16, accuracy: 0.001, "the root's ems, inherited as a length")
        XCTAssertEqual(paragraph.wordSpacing, 0.16 * 16, accuracy: 0.001)
        XCTAssertEqual(paragraph.textAlign, .justify)
        XCTAssertEqual(paragraph.hyphens, .manual)
        XCTAssertEqual(paragraph.margin.top, .points(32), "a paragraph's own ems, in place of the user agent's 1em")
        XCTAssertEqual(paragraph.margin.bottom, .points(32))
        let heading = result.style("h")
        XCTAssertEqual(heading.fontFamilies, ["atkinson hyperlegible", "serif"])
        XCTAssertEqual(heading.lineHeight, .multiple(1.5))
        XCTAssertEqual(heading.letterSpacing, 0.12 * 16, accuracy: 0.001, "a computed letter spacing is inherited as it is")
        XCTAssertEqual(heading.margin.top, .points(0.67 * 32), "only a paragraph takes the paragraph spacing")
        XCTAssertEqual(result.style("em").fontFamilies, ["atkinson hyperlegible", "serif"])

        var ragged = Self.settings(overrides: false, alignment: .start, hyphenation: true)
        ragged.fontFamily = .sansSerif
        let other = try styled(body, ragged)
        XCTAssertEqual(other.style("p").textAlign, .start)
        XCTAssertEqual(other.style("p").hyphens, .auto)
        XCTAssertEqual(other.style("p").fontFamilies.first, "sans-serif")
    }

    func testWithTheSwitchOffTheBooksOwnFontsAndSpacingAreUnchanged() throws {
        let body = "<h1 id='h'>Title</h1><p id='p'>Text <em id='em'>here</em>.</p><p id='end' class='end'>Signed</p>"
        let css = """
            body { font-family: Georgia, serif; line-height: 1.2; letter-spacing: 0.02em; word-spacing: 0;
                   text-align: left; hyphens: none }
            p { margin: 0 } h1 { text-align: center } .end { text-align: right }
            """
        let before = try styled(body, css: css)
        let after = try styled(body, css: css, Self.settings(overrides: false))
        let bodyElement = try XCTUnwrap(before.document.body)
        func inBody(_ node: ContentNode) -> Bool {
            var current: ContentNode? = node
            while let at = current, at !== bodyElement { current = at.parent }
            return current != nil
        }
        for node in before.document.nodes where node.isElement && inBody(node) {
            XCTAssertEqual(plain(after.styles[node.order]!), before.styles[node.order], "<\(node.name)>")
        }
        XCTAssertEqual(after.style("p").fontFamilies, ["georgia", "serif"])
        XCTAssertEqual(after.style("p").margin.top, .points(0))
        XCTAssertEqual(after.styles[after.document.root.order]?.fontFamilies, ["atkinson hyperlegible", "serif"],
                       "the root, where the book declares nothing, takes the settings")
    }

    /// CSS Cascade 4 §7.3.4: `revert` in the book's sheet rolls back to the user origin, here the
    /// settings, and not past them to the user agent's `line-height: 1.4`.
    func testTheBooksRevertRollsBackToTheSettings() throws {
        let css = "html { line-height: revert; hyphens: revert }"
        let result = try styled("<p id='p'>Text</p>", css: css, Self.settings(overrides: false))
        XCTAssertEqual(result.style("p").lineHeight, .multiple(1.5))
        XCTAssertEqual(result.style("p").hyphens, .manual)
        let without = try styled("<p id='p'>Text</p>", css: css)
        XCTAssertEqual(without.style("p").lineHeight, .multiple(1.4))
    }

    // MARK: The switch on: over the book's styles

    func testWithTheSwitchOnBodyTextFollowsTheSettingsOverTheBooks() throws {
        let body = """
            <h1 id='h'>Title</h1><p id='p'>Text <em id='em'>here</em>.</p><p id='end' class='end'>Signed</p>
            <div id='div'>Loose text</div>
            """
        let css = """
            body { font-family: Georgia, serif; line-height: 1.2; letter-spacing: 0.02em; word-spacing: 0;
                   text-align: left; hyphens: none }
            p { margin: 0 !important; line-height: 1 !important }
            h1 { font-family: "Trebuchet MS"; text-align: center; letter-spacing: 0.1em } .end { text-align: right }
            """
        let result = try styled(body, css: css, Self.settings(overrides: true))
        let paragraph = result.style("p")
        XCTAssertEqual(paragraph.fontFamilies, ["atkinson hyperlegible", "georgia", "serif"],
                       "the book's families follow the setting's, for what it lacks")
        XCTAssertEqual(paragraph.lineHeight, .multiple(1.5), "over the book's own, even an important one")
        XCTAssertEqual(paragraph.letterSpacing, 0.12 * 16, accuracy: 0.001)
        XCTAssertEqual(paragraph.wordSpacing, 0.16 * 16, accuracy: 0.001)
        XCTAssertEqual(paragraph.hyphens, .manual)
        XCTAssertEqual(paragraph.textAlign, .justify, "the book's ragged lines are justified")
        XCTAssertEqual(paragraph.margin.top, .points(32))
        XCTAssertEqual(paragraph.margin.bottom, .points(32))
        XCTAssertEqual(result.style("em").fontFamilies, ["atkinson hyperlegible", "georgia", "serif"])
        XCTAssertEqual(result.style("div").textAlign, .justify)
        XCTAssertEqual(result.style("div").margin.top, .points(0), "only a paragraph takes the paragraph spacing")
        let heading = result.style("h")
        XCTAssertEqual(heading.fontFamilies, ["atkinson hyperlegible", "trebuchet ms"])
        XCTAssertEqual(heading.letterSpacing, 0.12 * 32, accuracy: 0.001, "in the heading's own ems")
        XCTAssertEqual(heading.lineHeight, .multiple(1.5))
        XCTAssertEqual(heading.textAlign, .center, "a centred line stays centred")
        XCTAssertEqual(result.style("end").textAlign, .right, "a line set to the end side stays there")

        let ragged = try styled(body, css: css.replacingOccurrences(of: "text-align: left", with: "text-align: justify"),
                                Self.settings(overrides: true, alignment: .start, hyphenation: true))
        XCTAssertEqual(ragged.style("p").textAlign, .start, "the book's justified lines are ragged")
        XCTAssertEqual(ragged.style("p").hyphens, .auto, "over the book's hyphens: none")
        XCTAssertEqual(ragged.style("h").textAlign, .center)
    }

    func testWithTheSwitchOnRightToLeftTextKeepsItsSides() throws {
        let body = "<div dir='rtl'><p id='start' style='text-align: right'>א</p><p id='end' style='text-align: left'>ב</p></div>"
        let result = try styled(body, Self.settings(overrides: true))
        XCTAssertEqual(result.style("start").textAlign, .justify, "right is the start side of right-to-left text")
        XCTAssertEqual(result.style("end").textAlign, .left, "left is its end side")
    }

    // MARK: What the settings leave alone

    /// "leaving alone what must not change: preformatted text, tables, MathML and anything sized
    /// to fit": each of these, and what it holds, is styled exactly as with no settings, with
    /// the switch off and on, while the paragraph beside them follows the settings.
    func testPreformattedTextCodeTablesMathAndSizedBoxesAreLeftAsTheBookStylesThem() throws {
        let body = """
            <p id='plain'>Body text with <code id='code'>code()</code> and <kbd id='kbd'>K</kbd>.</p>
            <pre id='pre'><span id='pre-span'>let  x = 1</span></pre>
            <p id='wrapped' style='white-space: pre-wrap'>Kept   spaces</p>
            <table id='table'><tr><td id='cell'><p id='cell-p'>Cell text</p></td></tr></table>
            <m:math id='math'><m:mi id='mi'>x</m:mi></m:math>
            <div id='float' style='float: left'>D</div>
            <div id='placed' style='position: absolute'>Placed</div>
            <div id='sized' style='height: 10em'><p id='sized-p'>Fitted</p></div>
            <div id='screen' style='max-height: 100vh'>Screen</div>
            """
        let css = "body { font-family: Georgia, serif; text-align: justify; hyphens: auto } td { text-align: left }"
        let left = ["code", "kbd", "pre", "pre-span", "wrapped", "table", "cell", "cell-p", "math", "mi", "float", "placed",
                    "sized", "sized-p", "screen"]
        let without = try styled(body, css: css)
        for overrides in [false, true] {
            let with = try styled(body, css: css, Self.settings(overrides: overrides))
            for id in left {
                XCTAssertEqual(plain(with.style(id)), without.style(id), "#\(id), overrides \(overrides)")
                XCTAssertTrue(with.style(id).textSettings === ReaderTextTrace.leftAlone, "#\(id)")
            }
            XCTAssertEqual(with.style("plain").lineHeight, .multiple(1.5), "the paragraph beside them follows the settings")
            XCTAssertNotEqual(plain(with.style("plain")), without.style("plain"))
        }
    }

    /// A book that sizes its root and body to the page, or keeps white space throughout as a
    /// plain text made a book can, still has its text follow the settings.
    func testTheRootAndBodyAreNeverLeftAlone() throws {
        let css = "html, body { height: 100vh; white-space: pre-wrap }"
        let result = try styled("<p id='p'>Text</p>", css: css, Self.settings(overrides: true))
        XCTAssertEqual(result.style("p").lineHeight, .multiple(1.5))
        XCTAssertFalse(result.styles[result.document.body!.order]!.textSettings === ReaderTextTrace.leftAlone)
    }

    // MARK: Through the builder

    /// The settings reach the text the builder writes: the font, the kern of letter and word
    /// spacing, line height, justification, hyphenation and paragraph spacing.
    func testTheBuiltTextCarriesTheSettings() throws {
        let section = StyleTestSupport.xhtml(body: "<p>First paragraph of words.</p><p>Second paragraph of words.</p>")
        let book = try StyleTestSupport.publication(section: section)
        func build(_ settings: EPUBReaderStyle.Typography?) throws -> SectionText {
            var typography = NativeTypography(fontSize: 16)
            if let settings { typography.text = ReaderTextSettings(settings) }
            let spineIndex = try XCTUnwrap(book.spine.firstIndex { $0.resource.path == "OPS/one.xhtml" })
            return SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: spineIndex, typography: typography,
                                                            fonts: FontRegistry(publication: book), rich: PlaceholderRichContent()))
        }
        var settings = Self.settings(overrides: true)
        settings.fontFamily = .monospace
        let plainText = try build(nil), set = try build(settings)
        XCTAssertEqual(set.string.string, plainText.string.string, "the characters never change")
        let second = BuilderHarness.location(of: "Second", in: set)
        let style = try XCTUnwrap(BuilderHarness.paragraphStyle(set, at: second))
        XCTAssertEqual(style.alignment, .justified)
        XCTAssertEqual(style.hyphenationFactor, 0)
        let font = try XCTUnwrap(set.string.attribute(.font, at: second, effectiveRange: nil) as? PlatformFont)
        XCTAssertTrue(CTFontGetSymbolicTraits(font as CTFont).contains(.traitMonoSpace))
        XCTAssertEqual(set.string.attribute(.kern, at: second, effectiveRange: nil) as? CGFloat ?? 0, 0.12 * 16, accuracy: 0.001)
        let space = BuilderHarness.location(of: " paragraph", in: set)
        XCTAssertEqual(set.string.attribute(.kern, at: space, effectiveRange: nil) as? CGFloat ?? 0, (0.12 + 0.16) * 16, accuracy: 0.001,
                       "a space takes the word spacing as well")
        XCTAssertEqual(style.lineHeightMultiple * InlineStyling.naturalLineHeight(font), 1.5 * 16, accuracy: 0.01)
        let plainStyle = try XCTUnwrap(BuilderHarness.paragraphStyle(plainText, at: second))
        let plainFont = try XCTUnwrap(plainText.string.attribute(.font, at: second, effectiveRange: nil) as? PlatformFont)
        XCTAssertEqual(plainStyle.lineHeightMultiple * InlineStyling.naturalLineHeight(plainFont), 1.4 * 16, accuracy: 0.01,
                       "the reader's own line height")
        XCTAssertEqual(plainStyle.hyphenationFactor, 1, "the reader hyphenates by default")
        func gap(_ text: SectionText) throws -> CGFloat {
            let first = try XCTUnwrap(BuilderHarness.paragraphStyle(text, at: BuilderHarness.location(of: "First", in: text)))
            let second = try XCTUnwrap(BuilderHarness.paragraphStyle(text, at: BuilderHarness.location(of: "Second", in: text)))
            return first.paragraphSpacing + second.paragraphSpacingBefore
        }
        XCTAssertEqual(try gap(set), 32, accuracy: 0.01, "the paragraphs' margins of 2em, collapsed")
        XCTAssertEqual(try gap(plainText), 16, accuracy: 0.01, "the user agent's 1em")
        XCTAssertEqual(plainStyle.alignment, .natural)
    }
}

extension ReaderTextSettingsTests {
    /// A section is built on a background thread's small stack, and the deepest point of its
    /// build is in nested tables (`TableWidthStackTests`). With settings the style function
    /// computes the book's styles beside them, so the nine-level tables are built again on the
    /// production stack, with the switch off and on.
    func testNestedTablesBuildOnTheProductionStackWithSettings() throws {
        var cells = "<table><tr><td>a</td><td>b</td></tr></table>"
        for _ in 1...8 { cells = "<table><tr><td>\(cells)</td><td>x</td></tr></table>" }
        let publication = try TableCoverage.publication("<p>Before</p>\(cells)")
        for overrides in [false, true] {
            let typography = NativeTypography(fontSize: 16, text: ReaderTextSettings(Self.settings(overrides: overrides)))
            let result = StackBuild()
            let thread = Thread {
                let section = TableCoverage.section(of: publication, typography: typography)
                result.condition.lock()
                result.section = section
                result.stackBytes = pthread_get_stacksize_np(pthread_self())
                result.finished = true
                result.condition.signal()
                result.condition.unlock()
            }
            #if DEBUG
            thread.stackSize = 448 * 1_024
            #else
            thread.stackSize = 320 * 1_024
            #endif
            result.condition.lock()
            thread.start()
            while !result.finished { result.condition.wait() }
            let built = try XCTUnwrap(result.section)
            let stackBytes = result.stackBytes
            result.condition.unlock()
            #if DEBUG
            XCTAssertLessThanOrEqual(stackBytes, 512 * 1_024)
            #else
            XCTAssertLessThanOrEqual(stackBytes, 384 * 1_024)
            #endif
            XCTAssertFalse(built.report.withheld)
            var tables = TableCoverage.tables(in: built.string)
            var depth = 0
            while let table = tables.first {
                depth += 1
                tables = table.cells.flatMap { TableCoverage.tables(in: $0.content) }
            }
            XCTAssertEqual(depth, 9, "every nesting level remains a grid, overrides \(overrides)")
        }
    }
}

private final class StackBuild: @unchecked Sendable {
    let condition = NSCondition()
    var section: SectionText?
    var finished = false
    var stackBytes = 0
}

/// A font the host registers, used for book text, with characters it lacks drawn in the
/// family after it.
final class ReaderTextSettingsFontTests: XCTestCase {
    private func style(_ families: [String]) -> ComputedStyle {
        var style = ComputedStyle()
        style.fontFamilies = families; style.fontSize = 17
        return style
    }

    private func family(_ font: CTFont) -> String { CTFontCopyFamilyName(font) as String }

    private func registry() throws -> FontRegistry {
        try XCTSkipUnless(TestFontFactory.registered, "the test font could not be registered") // never expected
        return FontRegistry(publication: try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: "<p>x</p>")))
    }

    func testARegisteredFontDrawsTheTextItHasGlyphsFor() throws {
        let fonts = try registry()
        let font = fonts.font(for: style(["epublib test face", "serif"])) as CTFont
        XCTAssertEqual(family(font), TestFontFactory.family)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, TestFontFactory.postScriptName)
        let serif = family(fonts.font(for: style(["serif"])) as CTFont)
        XCTAssertEqual(family(CTFontCreateForString(font, "Abc" as CFString, CFRange(location: 0, length: 3))), TestFontFactory.family)
        XCTAssertEqual(family(CTFontCreateForString(font, "αβγ" as CFString, CFRange(location: 0, length: 3))), serif,
                       "Greek, which the font lacks, is drawn in the family after it")
        XCTAssertEqual(family(CTFontCreateForString(font, "é" as CFString, CFRange(location: 0, length: 1))), serif)
    }

    /// The text as CoreText sets it: each character in a font that has a glyph for it, none
    /// drawn as the missing glyph, the registered font's own in it.
    func testATextOfTwoScriptsFallsBackCharacterByCharacter() throws {
        let fonts = try registry()
        let font = fonts.font(for: style(["epublib test face", "georgia", "serif"]))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Word λόγος word", attributes: [.font: font]))
        var families: [String] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            XCTAssertFalse(glyphs.contains(0), "a missing glyph in \(family(runFont))")
            families.append(family(runFont))
        }
        XCTAssertEqual(families.first, TestFontFactory.family)
        XCTAssertEqual(families.last, TestFontFactory.family)
        let georgia = family(fonts.font(for: style(["georgia"])) as CTFont)
        XCTAssertTrue(families.contains(georgia), "the Greek word in the next family, \(georgia): \(families)")
    }

    /// The settings name the registered family for body text, and the builder writes it.
    func testTheSettingsFontReachesTheBuiltText() throws {
        _ = try registry()
        let section = StyleTestSupport.xhtml(body: "<p>Plain words.</p>", css: "body { font-family: Georgia, serif }")
        let book = try StyleTestSupport.publication(section: section)
        let spineIndex = try XCTUnwrap(book.spine.firstIndex { $0.resource.path == "OPS/one.xhtml" })
        for overrides in [false, true] {
            var typography = NativeTypography(fontSize: 16)
            typography.text = ReaderTextSettings(EPUBReaderStyle.Typography(fontFamily: .named(TestFontFactory.family),
                                                                            overridesBookStyles: overrides))
            let text = SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: spineIndex, typography: typography,
                                                                fonts: FontRegistry(publication: book), rich: PlaceholderRichContent()))
            let font = try XCTUnwrap(BuilderHarness.attribute(.font, of: "Plain", in: text) as? PlatformFont)
            if overrides {
                XCTAssertEqual(family(font as CTFont), TestFontFactory.family)
            } else {
                XCTAssertNotEqual(family(font as CTFont), TestFontFactory.family, "the book's own Georgia, with the switch off")
            }
        }
    }
}
