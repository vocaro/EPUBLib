import CoreGraphics
import CoreText
import EPUBCore
import EPUBReading
import EPUBTestSupport
import ImageIO
import SwiftUI
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Reading themes, Increase Contrast and Bold Text (#674): the colours the reader derives from a
/// theme, a section built in each, and an open book recoloured, made higher in contrast and
/// drawn heavier in both flows. Contrast expectations are WCAG 2.2's: 4.5:1 for text, 7:1
/// enhanced, 3:1 for graphics.
@MainActor final class ReaderThemeTests: XCTestCase {
    /// Cream on navy: a dark custom theme of the kind a reader with low vision chooses.
    static let navy = EPUBReaderColors(background: EPUBReaderColor(hex: "#14213D")!, text: EPUBReaderColor(hex: "#FCE8B2")!,
                                       link: EPUBReaderColor(hex: "#9AD1FF")!)
    static let presets: [(String, EPUBReaderColors)] = [("light", .light), ("dark", .dark), ("sepia", .sepia), ("black", .black)]
    static let appearances: [(EPUBReaderAppearance, EPUBReaderColors)] = [
        (.light, .light), (.dark, .dark), (.sepia, .sepia), (.black, .black), (.custom, navy),
    ]

    // MARK: - Derived colours

    /// What the reader draws beside and behind text keeps the text readable in every preset, and
    /// Increase Contrast makes each of them stand further from the page.
    func testDerivedColoursKeepTextReadableAndIncreaseContrastStrengthensThem() {
        for (name, colors) in Self.presets {
            let standard = ReaderTheme(colors), increased = ReaderTheme(colors, increasesContrast: true)
            let page = colors.background
            XCTAssertEqual(increased.colors, colors.increasingContrast, name)
            XCTAssertEqual(standard.isDark, colors.isDark, name)
            func fill(_ theme: ReaderTheme, _ kind: ReaderHighlight.Kind) -> EPUBReaderColor {
                // The current result is drawn over its own search highlight.
                let beneath = kind == .currentSearch ? theme.composite(theme.highlightFill(.search), over: page) : page
                return theme.composite(theme.highlightFill(kind), over: beneath)
            }
            for (theme, label) in [(standard, "standard"), (increased, "Increase Contrast")] {
                let floor = theme.increasesContrast ? 7.0 : 4.5
                XCTAssertGreaterThanOrEqual(theme.secondaryTextColor.contrastRatio(to: page), floor, "\(name) \(label): secondary text")
                for kind in [ReaderHighlight.Kind.search, .annotation, .currentSearch] {
                    XCTAssertGreaterThanOrEqual(theme.colors.text.contrastRatio(to: fill(theme, kind)), 4.5,
                                                "\(name) \(label): text over a \(kind) highlight")
                }
                XCTAssertGreaterThanOrEqual(theme.colors.text.contrastRatio(to: theme.selectionColor), 4.5, "\(name) \(label): selected text")
            }
            XCTAssertGreaterThanOrEqual(increased.ruleColor.contrastRatio(to: page), 3, "\(name): a rule with Increase Contrast")
            XCTAssertGreaterThan(increased.ruleColor.contrastRatio(to: page), standard.ruleColor.contrastRatio(to: page), name)
            XCTAssertGreaterThan(increased.selectionColor.contrastRatio(to: page), standard.selectionColor.contrastRatio(to: page),
                                 "\(name): the selection stands further from the page")
            for kind in [ReaderHighlight.Kind.search, .annotation, .currentSearch] {
                XCTAssertGreaterThan(fill(increased, kind).contrastRatio(to: page), fill(standard, kind).contrastRatio(to: page),
                                     "\(name): a \(kind) highlight stands further from the page with Increase Contrast")
            }
        }
    }

    /// Light and Dark keep the reader's palette: what was drawn before themes is what they draw,
    /// but for Dark's page, now the grey that sets it apart from Black.
    func testLightAndDarkAreThePalettesThemes() {
        for dark in [false, true] {
            let theme: ReaderTheme = dark ? .dark : .light
            XCTAssertEqual(ReaderPalette.background(dark: dark), theme.background)
            XCTAssertEqual(ReaderPalette.text(dark: dark), theme.text)
            XCTAssertEqual(ReaderPalette.link(dark: dark), theme.link)
            XCTAssertEqual(ReaderPalette.rule(dark: dark), theme.rule)
            XCTAssertEqual(ReaderPalette.secondaryText(dark: dark), theme.secondaryText)
            XCTAssertEqual(ReaderPalette.highlight(.currentSearch, dark: dark), theme.highlight(.currentSearch))
            XCTAssertEqual(theme.isDark, dark)
        }
        XCTAssertEqual(NativeTypography(isDark: true).theme, .dark)
        XCTAssertEqual(NativeTypography(isDark: false), NativeTypography(theme: .light))
        XCTAssertFalse(NativeTypography().boldText)
        var configuration = ReaderCanvasConfiguration()
        configuration.isDark = true
        XCTAssertEqual(configuration.theme, .dark)
        configuration.theme = ReaderTheme(.sepia)
        XCTAssertFalse(configuration.isDark)
        configuration.theme = ReaderTheme(.black)
        XCTAssertTrue(configuration.isDark)
    }

    // MARK: - A section in each theme

    /// Transparent black line art, which a dark page would swallow.
    private static func lineArt() -> Data {
        let context = CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 480,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 26, width: 100, height: 8))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Themes</title><style>\
        .red { color: #c00000 } .mark { background-color: #ffff00 } \
        @media (prefers-color-scheme: dark) { img.art { filter: invert(1) } }\
        </style></head><body>\
        <p>Plain words and <a href="two.xhtml">a link</a> and <span class="red">red words</span> and <span class="mark">marked words</span>.</p>\
        <p><b>Bold words</b> beside regular words.</p>\
        <hr/><p><img src="art.png" alt="Line art"/></p><p><img class="art" src="art.png" alt="Inverted art"/></p>\
        <p><img src="missing.png" alt="A lost picture"/></p>\
        <table border="1"><tr><td>Alpha cell</td><td>Beta cell</td></tr></table>\
        \(String(repeating: "<p>A paragraph of ordinary reading text for pagination.</p>", count: 40))\
        </body></html>
        """

    private func book() throws -> Data {
        var files = try Fixture.files()
        files["OPS/one.xhtml"] = Data(Self.chapter.utf8)
        files["OPS/art.png"] = Self.lineArt()
        return try Fixture.archive(files)
    }

    private func section(_ typography: NativeTypography, publication: EPUBPublication) -> SectionText {
        SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0, typography: typography,
                                                 fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
    }

    private func attribute(_ key: NSAttributedString.Key, of words: String, in section: SectionText,
                           file: StaticString = #filePath, line: UInt = #line) throws -> Any? {
        let range = (section.string.string as NSString).range(of: words)
        XCTAssertNotEqual(range.location, NSNotFound, words, file: file, line: line)
        guard range.location != NSNotFound else { return nil }
        return section.string.attribute(key, at: range.location, effectiveRange: nil)
    }

    private func attachments<T>(_ type: T.Type, in section: SectionText) -> [T] {
        var found: [T] = []
        section.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: section.string.length)) { value, _, _ in
            if let value = value as? T { found.append(value) }
        }
        return found
    }

    /// Each theme colours text, links, rules, secondary text and tables; a dark one takes the
    /// book's own colours away and puts dark line art on a white backdrop, as Dark always has, and
    /// `prefers-color-scheme: dark` follows the theme, not the system. The characters are the
    /// same in every theme, so positions hold across a change.
    func testASectionTakesItsThemesColours() throws {
        let publication = try EPUBPublication.open(data: book())
        var characters: Set<String> = []
        for (appearance, colors) in Self.appearances {
            for increases in [false, true] {
                let theme = ReaderTheme(colors, increasesContrast: increases)
                let label = "\(appearance)\(increases ? " with Increase Contrast" : "")"
                let text = section(NativeTypography(theme: theme), publication: publication)
                characters.insert(text.string.string)
                XCTAssertEqual(try attribute(.foregroundColor, of: "Plain words", in: text) as? PlatformColor, theme.text, label)
                XCTAssertEqual(try attribute(.foregroundColor, of: "a link", in: text) as? PlatformColor, theme.link, label)
                XCTAssertEqual(try attribute(.foregroundColor, of: "A lost picture", in: text) as? PlatformColor, theme.secondaryText, label)
                let red = try attribute(.foregroundColor, of: "red words", in: text) as? PlatformColor
                let marked = try attribute(.backgroundColor, of: "marked words", in: text)
                if colors.isDark {
                    XCTAssertEqual(red, theme.text, "\(label): the book's colours give way")
                    XCTAssertNil(marked, "\(label): the book's backgrounds give way")
                } else {
                    XCTAssertEqual(red?.cgColor.components?.prefix(3).map { ($0 * 255).rounded() }, [192, 0, 0], "\(label): the book's own colour")
                    XCTAssertNotNil(marked, "\(label): the book's own background")
                }
                let rule = try XCTUnwrap(attachments(ReaderRuleAttachment.self, in: text).first, label)
                XCTAssertEqual(rule.color, theme.rule, label)
                let images = attachments(ReaderImageAttachment.self, in: text)
                XCTAssertEqual(images.count, 2, label)
                XCTAssertEqual(images.map(\.isDark), [colors.isDark, colors.isDark], "\(label): white backdrop on any dark page")
                XCTAssertEqual(images.map(\.invertsColors), [false, colors.isDark], "\(label): prefers-color-scheme follows the theme")
                let table = try XCTUnwrap(attachments(TableRowAttachment.self, in: text).first?.table, label)
                if colors.isDark { XCTAssertEqual(table.cells[0].borders.top?.color, theme.rule.cgColor, label) }
            }
        }
        XCTAssertEqual(characters.count, 1, "a theme never changes a section's characters")
    }

    // MARK: - An open book

    private func waitOrFail(_ label: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line,
                            until condition: () -> Bool) async throws {
        let deadline = TestDeadline(seconds: timeout)
        while !condition() {
            guard try !deadline.hasPassed() else {
                XCTFail("Timed out waiting for \(label)", file: file, line: line)
                throw Timeout(label: label)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct Timeout: Error, CustomStringConvertible {
        let label: String
        var description: String { "timed out waiting for \(label)" }
    }

    private func open() throws -> SessionCoverageReader { try SessionCoverageReader(book()) }

    /// The background colours drawn behind the text of the canvas's text views.
    private func drawnHighlights(_ canvas: ReaderCanvasView) -> [PlatformColor] {
        var colors: [PlatformColor] = []
        for view in canvas.textViews {
            let layoutManager = view.readerLayoutManager
            layoutManager.enumerateRenderingAttributes(from: layoutManager.documentRange.location, reverse: false) { _, attributes, _ in
                if let color = attributes[.backgroundColor] as? PlatformColor { colors.append(color) }
                return true
            }
        }
        return colors
    }

    private func canvasBackground(_ canvas: ReaderCanvasView, flow: EPUBReadingFlow) -> [CGColor?] {
        #if os(macOS)
        [canvas.layer?.backgroundColor] + (flow == .scrolled ? [(canvas.scrollContainer as? NSScrollView)?.backgroundColor.cgColor] : [])
        #else
        [canvas.backgroundColor?.cgColor] + (flow == .scrolled ? [canvas.scrollTextView?.backgroundColor?.cgColor] : [])
        #endif
    }

    #if os(iOS)
    /// The red, green and blue the canvas draws at `point`, in sRGB.
    private func pixel(of canvas: ReaderCanvasView, at point: CGPoint) throws -> [Int] {
        canvas.layoutIfNeeded()
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: -point.x, y: point.y + 1)
            context.scaleBy(x: 1, y: -1)
            canvas.layer.render(in: context)
        }
        return bytes.prefix(3).map(Int.init)
    }
    #endif

    /// The issue's first acceptance: each preset and a custom theme recolour both flows, with
    /// popovers, selection, search highlights and tables, and keep the position.
    func testEveryThemeRecoloursBothFlowsAndKeepsThePosition() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let reader = try open()
            defer { reader.close() }
            let session = reader.session, state = try XCTUnwrap(session.readerState)
            try await waitOrFail("ready") { reader.events.contains(.ready) && session.book.isComplete }
            var style = EPUBReaderStyle(fontSize: 17, appearance: .light, flow: flow)
            style.customColors = Self.navy
            try await session.send(.style(style))
            try await session.send(.search(text: "ordinary reading text"))
            let current = try XCTUnwrap(session.searchResults?.currentIndex)
            let match = session.searchResultRanges[current]
            for (appearance, colors) in Self.appearances {
                style.appearance = appearance
                try await session.send(.style(style))
                let theme = ReaderTheme(colors)
                try await waitOrFail("\(appearance) in \(flow)") {
                    session.book.isComplete && session.book.typography.theme == theme && session.canvas?.configuration.theme == theme
                }
                let canvas = try XCTUnwrap(session.canvas)
                let label = "\(appearance), \(flow)"
                XCTAssertEqual(state.status.effectiveColors, colors, label)
                XCTAssertEqual(state.status.effectiveAppearance, colors.isDark ? .dark : .light, label)
                XCTAssertEqual(state.status.style.appearance, appearance, label)
                let visible = try XCTUnwrap(session.visibleRange)
                XCTAssertTrue(visible.start <= match.start && match.start < visible.end, "\(label): the position is kept")
                let text = try XCTUnwrap(session.book.section(match.start.section))
                XCTAssertEqual(text.string.attribute(.foregroundColor, at: match.start.offset, effectiveRange: nil) as? PlatformColor,
                               theme.text, label)
                let backgrounds = canvasBackground(canvas, flow: flow)
                XCTAssertEqual(backgrounds.count, flow == .scrolled ? 2 : 1, label)
                for background in backgrounds { XCTAssertEqual(background, theme.background.cgColor, "\(label): the page") }
                #if os(iOS)
                let drawn = try pixel(of: canvas, at: CGPoint(x: canvas.bounds.maxX - 3, y: canvas.bounds.maxY - 3))
                let page = [colors.background.red, colors.background.green, colors.background.blue].map { Int(($0 * 255).rounded()) }
                XCTAssertTrue(zip(drawn, page).allSatisfy { abs($0 - $1) <= 2 }, "\(label): the page as drawn is \(drawn), not \(page)")
                #endif
                let highlights = drawnHighlights(canvas)
                XCTAssertTrue(highlights.contains(theme.highlight(.search)), "\(label): search highlights")
                XCTAssertTrue(highlights.contains(theme.highlight(.currentSearch)), "\(label): the current result")
                #if os(macOS)
                XCTAssertFalse(canvas.textViews.isEmpty)
                for view in canvas.textViews {
                    XCTAssertEqual(view.selectedTextAttributes[.backgroundColor] as? NSColor, theme.selection, "\(label): selection")
                }
                #else
                XCTAssertEqual(canvas.tintColor, theme.link, "\(label): selection, its handles and the caret")
                #endif
                try assertNote(on: canvas, theme: theme, label: label)
            }
        }
    }

    /// A live change of theme, as of appearance (#243), keeps the page's text and the canvas in
    /// one theme while the section on screen is rebuilt: the canvas keeps the old theme, with the
    /// old text, until the new build is in, then both change together. Light to Sepia, both light
    /// themes, and Sepia to Sepia with Increase Contrast, in either flow.
    func testALiveChangeOfThemeKeepsThePageAndCanvasInOneTheme() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let gate = ThemeBuildGate(holding: "OPS/one.xhtml")
            defer { gate.release() }
            let book = try SessionCoverageBook.epub([
                .init("one", SessionCoverageBook.filler(40) + "<hr/>" + SessionCoverageBook.filler(40)),
                .init("two", SessionCoverageBook.filler(10)),
            ])
            let session = try NativeSession(publication: try EPUBPublication.open(data: book), action: nil, rich: gate) { _ in }
            let window = ReaderTestWindow(session: session)
            defer { session.close(); window.close() }
            try await waitOrFail("the Light reader") { session.isReady && session.book.isComplete }
            var style = EPUBReaderStyle(fontSize: 17, appearance: .light, flow: flow)
            try await session.send(.style(style))
            try await waitOrFail("the whole book in continuous scroll") { flow == .paginated || session.canvas?.scrollBook != nil }
            let canvas = try XCTUnwrap(session.canvas)
            await settle(canvas)
            XCTAssertEqual(canvas.configuration.theme, .light)
            let steps: [(String, ReaderTheme)] = [
                ("Sepia", ReaderTheme(.sepia)), ("Sepia with Increase Contrast", ReaderTheme(.sepia, increasesContrast: true)),
            ]
            var before = ReaderTheme.light
            for (name, theme) in steps {
                let held = expectation(description: "the shown section's \(name) build is held, \(flow)")
                gate.hold(theme, held: held)
                if theme.increasesContrast { window.pageControls.increasesContrast = true } else {
                    style.appearance = .sepia
                    try await session.send(.style(style))
                }
                let fulfilled = try await TestDeadline.fulfillment(of: [held], within: 20)
                XCTAssertTrue(fulfilled, "\(name), \(flow)")
                await settle(canvas)
                XCTAssertEqual(canvas.configuration.theme, before, "\(name), \(flow): the canvas keeps the theme of the text it shows")
                assertTextAgreesWithCanvas(canvas, "while the \(name) rebuild is held, \(flow)")
                XCTAssertEqual(session.readerState?.status.effectiveColors, theme.colors, "\(name), \(flow): the status has the new theme at once")
                gate.release()
                try await waitOrFail("\(name), \(flow)") {
                    session.book.isComplete && session.book.typography.theme == theme && canvas.configuration.theme == theme
                }
                await settle(canvas)
                assertTextAgreesWithCanvas(canvas, "once the \(name) rebuild is in, \(flow)")
                XCTAssertEqual(shownTextColors(canvas), [theme.text], "\(name), \(flow): the page shows the new theme's text")
                before = theme
            }
        }
    }

    private func settle(_ canvas: ReaderCanvasView) async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #if os(macOS)
        canvas.window?.contentView?.layoutSubtreeIfNeeded()
        #else
        canvas.window?.layoutIfNeeded()
        #endif
    }

    /// The text colours of what the canvas shows (the book sets none of its own).
    private func shownTextColors(_ canvas: ReaderCanvasView) -> Set<PlatformColor> {
        var colors: Set<PlatformColor> = []
        for view in canvas.textViews {
            guard let storage = view.contentStorage.textStorage else { continue }
            storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let color = value as? PlatformColor, color != .clear { colors.insert(color) }
            }
        }
        return colors
    }

    private func assertTextAgreesWithCanvas(_ canvas: ReaderCanvasView, _ moment: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let theme = canvas.configuration.theme
        #if os(macOS)
        XCTAssertEqual(canvas.layer?.backgroundColor, theme.background.cgColor,
                       "\(moment): the canvas paints another theme than it has", file: file, line: line)
        #else
        XCTAssertEqual(canvas.backgroundColor, theme.background,
                       "\(moment): the canvas paints another theme than it has", file: file, line: line)
        #endif
        let shown = shownTextColors(canvas)
        XCTAssertFalse(shown.isEmpty, "\(moment): no text on screen", file: file, line: line)
        XCTAssertTrue(shown.isSubset(of: [theme.text, theme.secondaryText]),
                      "\(moment): text in \(shown) is shown on a canvas whose text is \(theme.text)", file: file, line: line)
    }

    /// A note's popover is drawn on the page's colour.
    private func assertNote(on canvas: ReaderCanvasView, theme: ReaderTheme, label: String) throws {
        canvas.presentNote(NSAttributedString(string: "A note."), theme: theme, from: CGRect(x: 100, y: 100, width: 20, height: 20))
        #if os(macOS)
        let popover = try XCTUnwrap(canvas.presentedNote as? NSPopover, label)
        defer { popover.close() }
        XCTAssertEqual(popover.appearance?.name, theme.isDark ? .darkAqua : .aqua, label)
        let controller = try XCTUnwrap(popover.contentViewController as? ReaderNoteViewController, label)
        let scrollView = try XCTUnwrap(controller.view as? NSScrollView, label)
        XCTAssertTrue(scrollView.drawsBackground, label)
        XCTAssertEqual(scrollView.backgroundColor, theme.background, "\(label): the note's page")
        XCTAssertEqual(controller.textView.selectedTextAttributes[.backgroundColor] as? NSColor, theme.selection, label)
        #else
        let controller = try XCTUnwrap(canvas.presentedNote as? ReaderNoteViewController, label)
        defer { controller.dismiss(animated: false) }
        XCTAssertEqual(controller.textView.backgroundColor, theme.background, "\(label): the note's page")
        XCTAssertEqual(controller.popoverPresentationController?.backgroundColor, theme.background, "\(label): the popover round it")
        XCTAssertEqual(controller.textView.tintColor, theme.link, label)
        XCTAssertEqual(controller.overrideUserInterfaceStyle, theme.isDark ? .dark : .light, label)
        #endif
    }

    /// The issue's last acceptance, for Increase Contrast: turning it on or off changes an open
    /// book's text in every theme, its highlights with it, and keeps the position.
    func testIncreaseContrastChangesAnOpenBooksText() async throws {
        let reader = try open()
        defer { reader.close() }
        let session = reader.session, state = try XCTUnwrap(session.readerState), window = try XCTUnwrap(reader.window)
        try await waitOrFail("ready") { reader.events.contains(.ready) && session.book.isComplete }
        XCTAssertFalse(session.systemIncreasesContrast, "the test window keeps Increase Contrast off until asked")
        var style = EPUBReaderStyle(fontSize: 17, appearance: .light, flow: .paginated)
        style.customColors = Self.navy
        try await session.send(.search(text: "ordinary reading text"))
        let match = session.searchResultRanges[try XCTUnwrap(session.searchResults?.currentIndex)]
        func drawn() throws -> (text: PlatformColor?, link: PlatformColor?) {
            let section = try XCTUnwrap(session.book.section(0))
            let link = (section.string.string as NSString).range(of: "a link").location
            return (section.string.attribute(.foregroundColor, at: match.start.offset, effectiveRange: nil) as? PlatformColor,
                    section.string.attribute(.foregroundColor, at: link, effectiveRange: nil) as? PlatformColor)
        }
        for (appearance, colors) in Self.appearances {
            style.appearance = appearance
            try await session.send(.style(style))
            for increases in [true, false, true, false] {
                window.pageControls.increasesContrast = increases
                let theme = ReaderTheme(colors, increasesContrast: increases)
                try await waitOrFail("\(appearance), Increase Contrast \(increases)") {
                    session.systemIncreasesContrast == increases && session.book.isComplete
                        && session.book.typography.theme == theme && session.canvas?.configuration.theme == theme
                }
                let label = "\(appearance), Increase Contrast \(increases ? "on" : "off")"
                let (text, link) = try drawn()
                XCTAssertEqual(text, theme.text, label)
                XCTAssertEqual(link, theme.link, label)
                XCTAssertEqual(state.status.effectiveColors, theme.colors, label)
                XCTAssertTrue(drawnHighlights(try XCTUnwrap(session.canvas)).contains(theme.highlight(.currentSearch)), label)
                let visible = try XCTUnwrap(session.visibleRange)
                XCTAssertTrue(visible.start <= match.start && match.start < visible.end, "\(label): the position is kept")
            }
            let standard = ReaderTheme(colors), increased = ReaderTheme(colors, increasesContrast: true)
            XCTAssertTrue(standard.text != increased.text || standard.link != increased.link,
                          "\(appearance): Increase Contrast changes the text or its links")
            XCTAssertNotEqual(standard.highlight(.search), increased.highlight(.search), "\(appearance): and the highlights")
        }
    }

    private func weight(_ font: PlatformFont?) -> CGFloat {
        guard let font else { return .nan }
        return weight(font as CTFont)
    }

    private func weight(_ font: CTFont) -> CGFloat {
        let traits = CTFontCopyTraits(font) as NSDictionary
        return (traits[kCTFontWeightTrait] as? NSNumber).map { CGFloat($0.doubleValue) } ?? .nan
    }

    /// The issue's last acceptance, for Bold Text: turning it on draws an open book's text
    /// heavier, regular and bold alike, and turning it off draws it as before, its characters
    /// and its position unchanged.
    func testBoldTextDrawsAnOpenBooksTextHeavier() async throws {
        let reader = try open()
        defer { reader.close() }
        let session = reader.session, window = try XCTUnwrap(reader.window)
        try await waitOrFail("ready") { reader.events.contains(.ready) && session.book.isComplete }
        XCTAssertFalse(session.systemBoldText, "the test window keeps Bold Text off until asked")
        try await session.send(.search(text: "ordinary reading text"))
        let match = session.searchResultRanges[try XCTUnwrap(session.searchResults?.currentIndex)]
        func fonts() throws -> (regular: CGFloat, bold: CGFloat, string: String) {
            let section = try XCTUnwrap(session.book.section(0))
            let bold = (section.string.string as NSString).range(of: "Bold words").location
            return (weight(section.string.attribute(.font, at: match.start.offset, effectiveRange: nil) as? PlatformFont),
                    weight(section.string.attribute(.font, at: bold, effectiveRange: nil) as? PlatformFont), section.string.string)
        }
        let before = try fonts()
        XCTAssertGreaterThan(before.bold, before.regular, "the book's bold is bolder than its text")
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            try await session.send(.style(EPUBReaderStyle(fontSize: 17, appearance: .light, flow: flow)))
            window.pageControls.boldText = true
            try await waitOrFail("Bold Text in \(flow)") { session.systemBoldText && session.book.isComplete && session.book.typography.boldText }
            let bold = try fonts()
            XCTAssertGreaterThan(bold.regular, before.regular, "\(flow): text is drawn heavier")
            XCTAssertGreaterThan(bold.bold, before.bold, "\(flow): bold text is drawn heavier still")
            XCTAssertEqual(bold.string, before.string, "\(flow): the same characters")
            var visible = try XCTUnwrap(session.visibleRange)
            XCTAssertTrue(visible.start <= match.start && match.start < visible.end, "\(flow): the position is kept")
            window.pageControls.boldText = false
            try await waitOrFail("Bold Text off in \(flow)") { !session.systemBoldText && session.book.isComplete && !session.book.typography.boldText }
            let after = try fonts()
            XCTAssertEqual(after.regular, before.regular, "\(flow)")
            XCTAssertEqual(after.bold, before.bold, "\(flow)")
            visible = try XCTUnwrap(session.visibleRange)
            XCTAssertTrue(visible.start <= match.start && match.start < visible.end, "\(flow): the position is kept")
        }
    }

    /// Bold Text adds 200 to a weight, to at most 900, and no rule takes it away: it is the
    /// reader's, not the book's.
    func testBoldTextIsAWeightHeavierWhereverTheBookSetsOne() throws {
        let publication = try EPUBPublication.open(data: book())
        let resolver = StyleResolver(document: try ContentDocument.parse(publication.data(at: "OPS/one.xhtml"), path: "OPS/one.xhtml"),
                                     stylesheets: [], typography: NativeTypography(theme: .light, boldText: true))
        XCTAssertTrue(resolver.initialStyle.usesBoldText)
        var style = ComputedStyle()
        for (weight, used) in [(100, 300), (400, 600), (700, 900), (800, 900), (900, 900)] {
            style.fontWeight = weight
            style.usesBoldText = false
            XCTAssertEqual(style.usedFontWeight, weight)
            style.usesBoldText = true
            XCTAssertEqual(style.usedFontWeight, used, "\(weight)")
        }
        let plain = StyleResolver(document: resolver.document, stylesheets: [], typography: NativeTypography(theme: .light))
        XCTAssertFalse(plain.initialStyle.usesBoldText)
    }

    #if os(iOS)
    /// On iPhone and iPad the settings reach the reader as its window's traits, as they do from
    /// Settings, through SwiftUI's environment.
    func testTheWindowsTraitsReachTheReader() async throws {
        let reader = try open()
        defer { reader.close() }
        let session = reader.session, window = try XCTUnwrap(reader.window)
        try await waitOrFail("ready") { reader.events.contains(.ready) && session.book.isComplete }
        window.pageControls.accessibilityFollowsWindow = true
        window.window.traitOverrides.accessibilityContrast = .high
        try await waitOrFail("Increase Contrast from the window") { session.systemIncreasesContrast && session.book.isComplete }
        XCTAssertTrue(session.book.typography.theme.increasesContrast)
        window.window.traitOverrides.legibilityWeight = .bold
        try await waitOrFail("Bold Text from the window") { session.systemBoldText && session.book.isComplete }
        XCTAssertTrue(session.book.typography.boldText)
        window.window.traitOverrides.accessibilityContrast = .normal
        window.window.traitOverrides.legibilityWeight = .regular
        try await waitOrFail("both off again") {
            !session.systemIncreasesContrast && !session.systemBoldText && session.book.isComplete && session.book.typography == NativeTypography(theme: .light)
        }
    }

    /// Bold Text draws regular text as iOS draws its own with Bold Text on: SwiftUI's and
    /// UIKit's body font under a bold legibility weight is the face the reader's regular text is
    /// found in with Bold Text. The system's text-style fonts report a weight trait of 0 at any
    /// legibility weight, so the faces are compared by name (`.SFUI-Semibold` on iOS 27.0).
    func testBoldTextMatchesTheSystemsOwnBoldText() {
        func name(_ font: CTFont) -> String { CTFontCopyPostScriptName(font) as String }
        var environment = EnvironmentValues()
        environment.legibilityWeight = .regular
        let systemRegular = name(Font.body.resolve(in: environment.fontResolutionContext).ctFont)
        environment.legibilityWeight = .bold
        let systemBold = name(Font.body.resolve(in: environment.fontResolutionContext).ctFont)
        XCTAssertNotEqual(systemBold, systemRegular)
        XCTAssertEqual(name(UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(legibilityWeight: .bold))), systemBold,
                       "UIKit's body font with Bold Text is SwiftUI's")
        var style = ComputedStyle(fontSize: 17)
        style.fontFamilies = ["system-ui"]
        func ours() -> String { name(FontRegistry.systemFont(families: style.fontFamilies, size: 17, weight: style.usedFontWeight, italic: false)) }
        XCTAssertEqual(ours(), systemRegular, "the reader's regular is the system's")
        style.usesBoldText = true
        XCTAssertEqual(ours(), systemBold, "regular text drawn as the system draws body text with Bold Text")
    }
    #endif
}

/// Holds a build of some documents in one theme at their rules until released; every other
/// build passes. `hold` arms it again for another theme.
private final class ThemeBuildGate: RichContentFactory, @unchecked Sendable {
    private let condition = NSCondition()
    private let paths: Set<String>
    private var theme: ReaderTheme?
    private var held: XCTestExpectation?
    private let content = NativeRichContent()

    init(holding path: String) { paths = [path] }

    func hold(_ theme: ReaderTheme, held: XCTestExpectation) {
        condition.lock()
        self.theme = theme
        self.held = held
        condition.unlock()
    }

    func release() {
        condition.lock()
        theme = nil
        condition.broadcast()
        condition.unlock()
    }

    func horizontalRule(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString {
        condition.lock()
        if let theme, context.typography.theme == theme, paths.contains(context.document.path) {
            held?.fulfill()
            held = nil
            while self.theme == theme { condition.wait() }
        }
        condition.unlock()
        return content.horizontalRule(element, style: style, context: context)
    }

    func image(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        content.image(element, style: style, context: context)
    }
    func svg(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        content.svg(element, style: style, context: context)
    }
    func table(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        content.table(element, style: style, context: context)
    }
    func math(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        content.math(element, style: style, context: context)
    }
}
