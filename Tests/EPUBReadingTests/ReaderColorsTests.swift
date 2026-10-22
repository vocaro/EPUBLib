import EPUBCore
import Foundation
import XCTest

/// Reading themes' colours (#674): WCAG 2.2's contrast arithmetic, the presets' contrast, and
/// what Increase Contrast does to a theme. Expectations are WCAG's definitions and the issue's
/// thresholds, not the colours' current values.
final class ReaderColorsTests: XCTestCase {
    private func color(_ hex: String, file: StaticString = #filePath, line: UInt = #line) throws -> EPUBReaderColor {
        try XCTUnwrap(EPUBReaderColor(hex: hex), hex, file: file, line: line)
    }

    /// WCAG 2.2's relative luminance and contrast ratio, against values WCAG and its
    /// understanding documents give: 21:1 for black on white, 1:1 for a colour on itself, and
    /// #767676 as the lightest grey that meets 4.5:1 on white, #777777 just short of it.
    func testContrastRatiosAreWCAGs() throws {
        XCTAssertEqual(EPUBReaderColor.white.relativeLuminance, 1, accuracy: 1e-12)
        XCTAssertEqual(EPUBReaderColor.black.relativeLuminance, 0, accuracy: 1e-12)
        XCTAssertEqual(EPUBReaderColor.black.contrastRatio(to: .white), 21, accuracy: 1e-9)
        XCTAssertEqual(EPUBReaderColor.white.contrastRatio(to: .black), 21, accuracy: 1e-9, "either order")
        XCTAssertEqual(try color("#336699").contrastRatio(to: color("#336699")), 1, accuracy: 1e-12)
        XCTAssertEqual(try color("#767676").contrastRatio(to: .white), 4.54, accuracy: 0.005)
        XCTAssertLessThan(try color("#777777").contrastRatio(to: .white), 4.5)
        // Pure primaries: sRGB red is 0.2126, green 0.7152 and blue 0.0722 (WCAG 2.2's formula).
        XCTAssertEqual(try color("#FF0000").relativeLuminance, 0.2126, accuracy: 1e-12)
        XCTAssertEqual(try color("#00FF00").relativeLuminance, 0.7152, accuracy: 1e-12)
        XCTAssertEqual(try color("#0000FF").relativeLuminance, 0.0722, accuracy: 1e-12)
        // Below WCAG 2.2's 0.04045 threshold a channel is linear: 10/255 / 12.92.
        XCTAssertEqual(try color("#0A0A0A").relativeLuminance, 10.0 / 255 / 12.92, accuracy: 1e-12)
    }

    func testHexSpellingsAndComponents() throws {
        XCTAssertEqual(try color("#FBF0D9").hex, "#FBF0D9")
        XCTAssertEqual(try color("fbf0d9"), try color("#FBF0D9"))
        for bad in ["", "#", "#FFF", "#FFFFFFF", "GGGGGG", "#12345G", " #123456", "#-12345"] {
            XCTAssertNil(EPUBReaderColor(hex: bad), bad)
        }
        let clamped = EPUBReaderColor(red: 2, green: -1, blue: .nan)
        XCTAssertEqual(clamped, EPUBReaderColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(EPUBReaderColor.black.mixed(with: .white, by: 0.5), EPUBReaderColor(red: 0.5, green: 0.5, blue: 0.5))
        XCTAssertEqual(EPUBReaderColor.black.mixed(with: .white, by: 3), .white)
    }

    /// The issue's acceptance: text and links meet 4.5:1 against the background in every
    /// preset. With Increase Contrast they meet WCAG's enhanced 7:1, and are never less than
    /// without it.
    func testEveryPresetsTextAndLinksMeetTheContrastTheIssueAsks() {
        let presets: [(String, EPUBReaderColors)] = [("light", .light), ("dark", .dark), ("sepia", .sepia), ("black", .black)]
        for (name, colors) in presets {
            XCTAssertGreaterThanOrEqual(colors.text.contrastRatio(to: colors.background), 4.5, "\(name) text")
            XCTAssertGreaterThanOrEqual(colors.link.contrastRatio(to: colors.background), 4.5, "\(name) links")
            let increased = colors.increasingContrast
            XCTAssertEqual(increased.background, colors.background, "\(name): Increase Contrast keeps the page")
            for (part, before, after) in [("text", colors.text, increased.text), ("links", colors.link, increased.link)] {
                let ratio = after.contrastRatio(to: colors.background), was = before.contrastRatio(to: colors.background)
                XCTAssertGreaterThanOrEqual(ratio, 7, "\(name) \(part) with Increase Contrast")
                if before == .black || before == .white {
                    XCTAssertEqual(after, before, "\(name) \(part): as far from the page as it can be already")
                } else {
                    XCTAssertGreaterThan(ratio, was, "\(name) \(part): higher contrast with Increase Contrast")
                }
            }
        }
        XCTAssertFalse(EPUBReaderColors.light.isDark)
        XCTAssertFalse(EPUBReaderColors.sepia.isDark)
        XCTAssertTrue(EPUBReaderColors.dark.isDark)
        XCTAssertTrue(EPUBReaderColors.black.isDark)
        XCTAssertNotEqual(EPUBReaderColors.dark.background, EPUBReaderColors.black.background, "Dark and Black are two themes")
        XCTAssertEqual(EPUBReaderColors.black.background, .black)
    }

    /// A custom theme: its contrast is the reader's choice, so one below 4.5:1 is drawn as given;
    /// with Increase Contrast it still gets higher contrast, and whether it is dark follows the
    /// crossing where white and black text have the same contrast with it.
    func testCustomColoursAreTheReadersOwnAndIncreaseContrastStillApplies() throws {
        let faint = EPUBReaderColors(background: try color("#FFFFFF"), text: try color("#BBBBBB"), link: try color("#99BBFF"))
        XCTAssertLessThan(faint.text.contrastRatio(to: faint.background), 4.5)
        XCTAssertGreaterThanOrEqual(faint.increasingContrast.text.contrastRatio(to: faint.background), 7)
        XCTAssertGreaterThanOrEqual(faint.increasingContrast.link.contrastRatio(to: faint.background), 7)
        let yellowOnBlue = EPUBReaderColors(background: try color("#0000AA"), text: try color("#FFFF00"), link: .white)
        XCTAssertTrue(yellowOnBlue.isDark)
        XCTAssertGreaterThan(yellowOnBlue.increasingContrast.text.contrastRatio(to: yellowOnBlue.background),
                             yellowOnBlue.text.contrastRatio(to: yellowOnBlue.background))
        XCTAssertEqual(yellowOnBlue.increasingContrast.link, .white)
        // The two meet between these greys: #767676 has more contrast with black (4.62:1 against
        // 4.54:1), #757575 with white.
        XCTAssertFalse(EPUBReaderColors(background: try color("#767676"), text: .black, link: .black).isDark)
        XCTAssertTrue(EPUBReaderColors(background: try color("#757575"), text: .white, link: .white).isDark)
        // No colour reaches 7:1 on mid grey: the text goes as far as it can, to black.
        let grey = EPUBReaderColors(background: try color("#777777"), text: try color("#222222"), link: try color("#222222"))
        XCTAssertEqual(grey.increasingContrast.text, .black)
    }

    func testAStyleChoosesItsColoursByItsAppearance() throws {
        var style = EPUBReaderStyle()
        XCTAssertNil(style.customColors)
        XCTAssertEqual(style.colors(systemIsDark: false), .light)
        XCTAssertEqual(style.colors(systemIsDark: true), .dark)
        let expected: [EPUBReaderAppearance: EPUBReaderColors] = [.light: .light, .dark: .dark, .sepia: .sepia, .black: .black, .custom: .light]
        for (appearance, colors) in expected {
            style.appearance = appearance
            XCTAssertEqual(style.colors(systemIsDark: true), colors, "\(appearance)")
            XCTAssertEqual(style.colors(systemIsDark: false), colors, "\(appearance) does not follow the system")
        }
        let own = EPUBReaderColors(background: try color("#FFFFCC"), text: try color("#000066"), link: try color("#990000"))
        style.customColors = own
        style.appearance = .custom
        XCTAssertEqual(style.colors(systemIsDark: false), own)
        style.appearance = .sepia
        XCTAssertEqual(style.colors(systemIsDark: false), .sepia, "custom colours wait while another theme is chosen")
        XCTAssertEqual(style.customColors, own)
        XCTAssertNotEqual(style, EPUBReaderStyle(appearance: .sepia), "custom colours are part of a style")
        XCTAssertFalse(EPUBReaderStyle(appearance: .black).isDark, "isDark is true for explicit Dark only")
    }

    func testThemesKeepTheSpellingAHostStores() throws {
        let own = EPUBReaderColors(background: try color("#102030"), text: try color("#F0E0D0"), link: try color("#80C0FF"))
        let data = try JSONEncoder().encode(own)
        XCTAssertEqual(try JSONDecoder().decode(EPUBReaderColors.self, from: data), own)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: [String: Double]])
        XCTAssertEqual(Set(object.keys), ["background", "text", "link"])
        XCTAssertEqual(Set(try XCTUnwrap(object["text"]).keys), ["red", "green", "blue"])
        XCTAssertEqual(try JSONDecoder().decode(EPUBReaderColor.self, from: Data(#"{"red":1,"green":0.5,"blue":0}"#.utf8)),
                       EPUBReaderColor(red: 1, green: 0.5, blue: 0))
    }
}
