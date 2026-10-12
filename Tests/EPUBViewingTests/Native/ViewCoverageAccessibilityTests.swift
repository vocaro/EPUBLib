import CoreGraphics
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A page column's accessibility through the platform's own entry points (doc/native-viewer.md
/// "Pages": queries bounded to the visible page; line and run elements on UIKit). API level only:
/// no assistive technology is driven.
@MainActor final class ViewCoverageAccessibilityTests: XCTestCase {
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    private func host(_ sections: [NSAttributedString], size: CGSize = CGSize(width: 420, height: 350), rtl: Bool = false) -> CanvasHost {
        var configuration = ReaderCanvasConfiguration()
        configuration.isRightToLeft = rtl
        let host = CanvasHost(FakeCanvasSource(sections), size: size, configuration: configuration)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        return host
    }

    /// A long paragraph of body text with a bold run at 40..<52.
    private func styledProse() -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: CanvasText.body(CanvasText.sentence(700, seed: 5)))
        text.addAttribute(.font, value: PlatformFont.boldSystemFont(ofSize: 17), range: NSRange(location: 40, length: 12))
        return text
    }

    // MARK: Hidden labels

    /// A heading parked off screen above an image without alternative text, a hidden word in a
    /// line, and a hidden link: what a browser reads and does not draw (`SpokenLabelAttachment`).
    private func pageWithHiddenLabels() throws -> (section: SectionText, host: CanvasHost, view: ReaderTextView) {
        let section = try BoxLayoutHarness.build("""
            <h1 class="sr">The Hidden Title</h1><img alt="" src="title.png"/>\
            <p>Words <span class="sr">unseen</span> after.</p><p><a class="sr" href="two.xhtml">Skip to chapter two</a>End.</p>
            """, css: BoxLayoutHarness.reset + ".sr { position:absolute; left:-999em } img { display:block; width:120px }",
            files: ["title.png": RichFixture.image(width: 240, height: 80)])
        XCTAssertEqual(section.string.string, "\u{FFFC}\u{FFFC}\nWords \u{FFFC}after.\n\u{FFFC}End.")
        let host = host([section.string])
        return (section, host, try XCTUnwrap(host.canvas.textViews.first))
    }

    #if os(macOS)
    func testAHiddenLabelIsStaticTextInThePagesRichText() throws {
        let (section, _, view) = try pageWithHiddenLabels()
        XCTAssertEqual(view.accessibilityValue(), section.string.string, "the characters as they are, so every range matches")
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: NSRange(location: 0, length: section.string.length)))
        var read: [String] = []
        rich.enumerateAttribute(.accessibilityAttachment, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            guard let element = value as? NSAccessibilityElement else { return }
            let isText = element.accessibilityRole() == .staticText
            read.append("\(range.location) \(isText ? "text" : "image") \((isText ? element.accessibilityValue() as? String : element.accessibilityLabel()) ?? "")")
            if isText { XCTAssertNil(element.accessibilityLabel(), "its words are its value, said once") }
        }
        XCTAssertEqual(read, ["0 text The Hidden Title", "1 image Book image", "9 text unseen", "17 text Skip to chapter two"])
        XCTAssertEqual(view.visibleText, "The Hidden Title\nWords unseen after.\nSkip to chapter two End.", "what Copy takes from the page")
    }
    #else
    func testAHiddenLabelIsATextElementWhereItStands() throws {
        let (_, host, view) = try pageWithHiddenLabels()
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.map { $0.accessibilityLabel ?? "" },
                       ["The Hidden Title", "Book image", "Words ", "unseen", "after.\n", "Skip to chapter two", "End."],
                       "no element for the break after the title or the image")
        XCTAssertEqual(elements.map { $0.accessibilityTraits.contains(.image) }, [false, true, false, false, false, false, false])
        XCTAssertEqual(elements.map { $0.accessibilityTraits.contains(.link) }, [false, false, false, false, false, true, false])
        XCTAssertTrue(elements[0].accessibilityTraits.contains(.staticText) && elements[3].accessibilityTraits.contains(.staticText))
        // Each has a place VoiceOver can rest on, inside the column, though it takes no room.
        for element in elements {
            let frame = element.accessibilityFrameInContainerSpace
            XCTAssertFalse(frame.isNull || frame.isEmpty, "\(element.accessibilityLabel ?? "")")
            XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(element.accessibilityLabel ?? ""): \(frame)")
        }
        XCTAssertEqual(elements[0].accessibilityFrameInContainerSpace.midY, elements[1].accessibilityFrameInContainerSpace.midY, accuracy: 60,
                       "the heading's label is in the line of the image it names")
        XCTAssertTrue(elements[5].accessibilityActivate(), "a hidden link is followed like any other")
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml"))
        XCTAssertEqual(view.accessibilityValue, "The Hidden Title\nWords unseen after.\nSkip to chapter two End.")
    }
    #endif

    #if os(macOS)
    func testStyleRangesStopAtThePagesEnd() throws {
        let host = host([styledProse()])
        let view = try XCTUnwrap(host.canvas.textViews.first)
        let length = view.placement.visibleLength
        XCTAssertGreaterThan(view.textLength, length, "the page ends inside the paragraph, with context laid out after it")
        XCTAssertEqual(view.accessibilityStyleRange(for: 0), NSRange(location: 0, length: 40))
        XCTAssertEqual(view.accessibilityStyleRange(for: 39), NSRange(location: 0, length: 40))
        XCTAssertEqual(view.accessibilityStyleRange(for: 40), NSRange(location: 40, length: 12))
        XCTAssertEqual(view.accessibilityStyleRange(for: 51), NSRange(location: 40, length: 12))
        // The run after the bold words continues into the context; the query ends with the page.
        var run = NSRange()
        _ = try XCTUnwrap(view.contentStorage.textStorage).attributes(at: length - 1, effectiveRange: &run)
        XCTAssertGreaterThan(NSMaxRange(run), length, "the fixture's last run crosses the page's end")
        XCTAssertEqual(view.accessibilityStyleRange(for: 52), NSRange(location: 52, length: length - 52))
        XCTAssertEqual(view.accessibilityStyleRange(for: length - 1), NSRange(location: 52, length: length - 52))
        XCTAssertEqual(view.accessibilityStyleRange(for: length).location, NSNotFound)
        XCTAssertEqual(view.accessibilityStyleRange(for: view.textLength - 1).location, NSNotFound)
        XCTAssertEqual(view.accessibilityStyleRange(for: -1).location, NSNotFound)
    }

    func testFramesAndRichTextAreGivenForThePageOnly() throws {
        let host = host([styledProse()])
        let view = try XCTUnwrap(host.canvas.textViews.first)
        let length = view.placement.visibleLength
        let column = NSAccessibility.screenRect(fromView: view, rect: view.bounds)
        let word = view.accessibilityFrame(for: NSRange(location: 40, length: 12))
        XCTAssertFalse(word.isEmpty)
        XCTAssertTrue(column.insetBy(dx: -1, dy: -1).contains(word), "\(word) in \(column)")
        let page = view.accessibilityFrame(for: NSRange(location: 0, length: length))
        XCTAssertFalse(page.isEmpty)
        XCTAssertTrue(column.insetBy(dx: -1, dy: -1).contains(page), "the whole page's frame is the column's: \(page) in \(column)")
        let lastLine = try XCTUnwrap(view.pageAccessibilityLines.last)
        let last = view.accessibilityFrame(for: lastLine.range)
        XCTAssertFalse(last.isEmpty)
        XCTAssertEqual(last.minY, column.minY, accuracy: 2, "the page's last line is at the column's bottom edge")
        for range in [NSRange(location: length - 3, length: 6), NSRange(location: length, length: 1), NSRange(location: 0, length: length + 1),
                      NSRange(location: NSNotFound, length: 0), NSRange(location: view.textLength, length: 0)] {
            XCTAssertEqual(view.accessibilityFrame(for: range), .zero, "\(range) reaches past the page")
            XCTAssertNil(view.accessibilityRTF(for: range), "\(range)")
            XCTAssertNil(view.accessibilityAttributedString(for: range), "\(range)")
            XCTAssertNil(view.accessibilityString(for: range), "\(range)")
        }
        let rtf = try XCTUnwrap(view.accessibilityRTF(for: NSRange(location: 0, length: length)))
        let decoded = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(decoded.string, view.visibleText, "the page's text and no more")
        XCTAssertEqual(view.accessibilityAttributedString(for: NSRange(location: 0, length: length))?.string, view.visibleText)
        XCTAssertEqual(view.accessibilityString(for: NSRange(location: length, length: 0)), "", "the empty range at the page's end is the page's")
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), length)
        XCTAssertEqual(view.accessibilityValue(), view.visibleText)
        XCTAssertEqual(view.accessibilityVisibleCharacterRange(), NSRange(location: 0, length: length))
    }

    func testAccessibilitySelectionsAreMadeAndReportedOnThePage() async throws {
        let host = host([styledProse()], size: CGSize(width: 1100, height: 420))
        let canvas = host.canvas
        XCTAssertEqual(canvas.textViews.count, 2)
        let view = canvas.columns[1]
        let offset = view.placement.offset, length = view.placement.visibleLength
        let text = try XCTUnwrap(host.source.sections[0]).string as NSString
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(view.accessibilitySelectedText(), "")
        view.setAccessibilitySelectedTextRange(NSRange(location: 3, length: 9))
        XCTAssertEqual(view.selectedRange, NSRange(location: 3, length: 9))
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 3, length: 9))
        XCTAssertEqual(view.accessibilitySelectedTextRanges()?.map(\.rangeValue), [NSRange(location: 3, length: 9)])
        XCTAssertEqual(view.accessibilitySelectedText(), text.substring(with: NSRange(location: offset + 3, length: 9)))
        XCTAssertEqual(canvas.currentSelection?.range, ReaderTextRange(section: 0, (offset + 3)..<(offset + 12)), "in the section's positions")
        view.setAccessibilitySelectedTextRanges([NSValue(range: NSRange(location: 12, length: 4))])
        XCTAssertEqual(view.selectedRange, NSRange(location: 12, length: 4))
        XCTAssertEqual(canvas.currentSelection?.range, ReaderTextRange(section: 0, (offset + 12)..<(offset + 16)))
        // To the page's very end, and not a character further.
        view.setAccessibilitySelectedTextRange(NSRange(location: length - 5, length: 5))
        XCTAssertEqual(view.selectedRange, NSRange(location: length - 5, length: 5))
        view.setAccessibilitySelectedTextRange(NSRange(location: length - 5, length: 6))
        XCTAssertEqual(view.selectedRange, NSRange(location: length - 5, length: 5), "refused")
        view.setAccessibilitySelectedTextRanges([NSValue(range: NSRange(location: 0, length: 2)), NSValue(range: NSRange(location: length, length: 1))])
        XCTAssertEqual(view.selectedRange, NSRange(location: length - 5, length: 5), "refused when any range leaves the page")
        XCTAssertEqual(view.accessibilitySelectedText(), text.substring(with: NSRange(location: offset + length - 5, length: 5)))
        let deadline = Date().addingTimeInterval(20)
        while host.recorder.selections.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual((host.recorder.selections.last ?? nil)?.range, ReaderTextRange(section: 0, (offset + length - 5)..<(offset + length)))
        // A caret, as VoiceOver places its cursor, is kept on the page and selects nothing.
        view.setAccessibilitySelectedTextRange(NSRange(location: view.textLength, length: 0))
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: length, length: 0))
        XCTAssertEqual(view.accessibilitySelectedText(), "")
        XCTAssertNil(canvas.currentSelection)
    }

    func testAPageWithoutClippedContextEndsItsLinesWithItsText() throws {
        let text = CanvasText.body("First line.\nSecond line.")
        let host = host([text])
        let view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(view.textLength, 24)
        XCTAssertEqual(view.placement.visibleLength, 24)
        XCTAssertEqual(view.accessibilityRange(forLine: 0), NSRange(location: 0, length: 12))
        XCTAssertEqual(view.accessibilityRange(forLine: 1), NSRange(location: 12, length: 12))
        XCTAssertEqual(view.accessibilityRange(forLine: 2).location, NSNotFound)
        XCTAssertEqual(view.accessibilityRange(forLine: -1).location, NSNotFound)
        XCTAssertEqual([0, 11, 12, 23].map { view.accessibilityLine(for: $0) }, [0, 0, 1, 1])
        XCTAssertEqual(view.accessibilityLine(for: 24), 1, "the insertion point after the last character is on the last line")
        XCTAssertEqual(view.accessibilityLine(for: 5_000), 1, "as is an offset kept from a longer page")
        XCTAssertEqual(view.accessibilityRange(for: 0), NSRange(location: 0, length: 1))
        XCTAssertEqual(view.accessibilityRange(for: 23), NSRange(location: 23, length: 1))
        XCTAssertEqual(view.accessibilityRange(for: 24).location, NSNotFound)
        XCTAssertEqual(view.accessibilityString(for: NSRange(location: 0, length: 24)), text.string)
        view.setAccessibilitySelectedTextRange(NSRange(location: 24, length: 0))
        XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), 1)
        view.setAccessibilitySelectedTextRange(NSRange(location: 12, length: 0))
        XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), 1, "a caret at a line's start is on that line")
        view.setAccessibilitySelectedTextRange(NSRange(location: 11, length: 0))
        XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), 0)
    }

    func testAShorterPageInstalledInAColumnBoundsWhatTheLongerOneAnswered() throws {
        // The last page of a section is shorter than the one before it in the same column view.
        let host = host([CanvasText.body(CanvasText.sentence(420, seed: 8))])
        let canvas = host.canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        var lengths: [Int] = [], lines: [Int] = []
        repeat {
            XCTAssertTrue(canvas.textViews.first === view, "the column view is reused")
            let length = view.placement.visibleLength, count = view.pageAccessibilityLines.count
            if let longest = lengths.max(), let most = lines.max(), length < longest {
                // Offsets and lines an assistive client kept from the longest page so far.
                XCTAssertEqual(view.accessibilityLine(for: longest), count - 1, "on the last line")
                XCTAssertEqual(view.accessibilityLine(for: longest - 1), count - 1)
                XCTAssertNil(view.accessibilityString(for: NSRange(location: 0, length: longest)))
                XCTAssertEqual(view.accessibilityRange(for: longest - 1).location, NSNotFound)
                XCTAssertEqual(view.accessibilityFrame(for: NSRange(location: longest - 1, length: 1)), .zero)
                if count < most { XCTAssertEqual(view.accessibilityRange(forLine: most - 1).location, NSNotFound) }
            }
            XCTAssertEqual(view.accessibilityNumberOfCharacters(), length)
            XCTAssertEqual(view.accessibilityValue(), view.visibleText)
            XCTAssertEqual(view.accessibilityVisibleCharacterRange(), NSRange(location: 0, length: length))
            XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 0, length: 0), "a new page starts at its first line")
            XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), 0)
            XCTAssertEqual((0..<count).map { view.accessibilityRange(forLine: $0).length }.reduce(0, +), length)
            lengths.append(length)
            lines.append(count)
        } while canvas.turnPage(forward: true) == .turned
        XCTAssertGreaterThan(lengths.count, 2)
        XCTAssertLessThan(try XCTUnwrap(lengths.last), try XCTUnwrap(lengths.max()), "the last page is the shortest")
        XCTAssertEqual(view.textLength, lengths.last, "the last page has nothing laid out after it")
    }

    /// Asking an `NSTextView` for the wrong thing drops it to TextKit 1 for good, and the reader's
    /// layout with it. What assistive clients, text input and the standard selection commands ask
    /// must not.
    func testAccessibilityQueriesAndSelectionCommandsKeepTheViewsOnTextKit2() throws {
        var switches = 0
        let token = NotificationCenter.default.addObserver(forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { switches += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        for scrolled in [false, true] {
            var configuration = ReaderCanvasConfiguration()
            configuration.flow = scrolled ? .scrolled : .paginated
            let text = NSMutableAttributedString(attributedString: CanvasText.section(0, paragraphs: 20))
            text.insert(CanvasText.attachment(size: CGSize(width: 80, height: 40)), at: 300)
            let host = CanvasHost(FakeCanvasSource([text]), size: CGSize(width: 600, height: 700), configuration: configuration)
            hosts.append(host)
            host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
            host.layOut()
            let view = try XCTUnwrap(host.canvas.textViews.first)
            let range = NSRange(location: 0, length: 400)
            let point = NSAccessibility.screenRect(fromView: view, rect: CGRect(x: 40, y: 80, width: 1, height: 1)).origin
            _ = view.accessibilityValue()
            _ = view.accessibilityString(for: range)
            _ = view.accessibilityAttributedString(for: range)
            _ = view.accessibilityRTF(for: range)
            _ = view.accessibilityFrame(for: range)
            _ = view.accessibilityLine(for: 10)
            _ = view.accessibilityRange(forLine: 1)
            _ = view.accessibilityRange(for: 10)
            _ = view.accessibilityRange(for: point)
            _ = view.accessibilityStyleRange(for: 10)
            _ = view.accessibilityVisibleCharacterRange()
            _ = view.accessibilityNumberOfCharacters()
            _ = view.accessibilityInsertionPointLineNumber()
            _ = view.accessibilitySelectedText()
            _ = view.accessibilitySelectedTextRanges()
            _ = view.accessibilityChildren()
            view.setAccessibilitySelectedTextRange(NSRange(location: 5, length: 10))
            // Text input clients: Look Up, dictation and pointer-driven assistive tools.
            _ = view.firstRect(forCharacterRange: NSRange(location: 20, length: 5), actualRange: nil)
            _ = view.characterIndex(for: point)
            _ = view.attributedSubstring(forProposedRange: NSRange(location: 20, length: 5), actualRange: nil)
            _ = view.characterIndexForInsertion(at: CGPoint(x: 40, y: 80))
            // The Edit menu's and the keyboard's selection commands.
            view.setSelectedRange(NSRange(location: 20, length: 0))
            view.selectWord(nil)
            view.selectLine(nil)
            view.selectParagraph(nil)
            view.moveDownAndModifySelection(nil)
            view.pageDownAndModifySelection(nil)
            view.moveToEndOfDocumentAndModifySelection(nil)
            XCTAssertEqual(NSMaxRange(view.selectedRange), view.placement.visibleLength, "to the end of what the reader sees")
            view.selectAll(nil)
            XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: view.placement.visibleLength))
            _ = view.dataWithPDF(inside: view.bounds)
            view.display()
            XCTAssertNotNil(view.textLayoutManager, scrolled ? "scrolled" : "paginated")
            XCTAssertTrue(view.textLayoutManager === view.readerLayoutManager)
            XCTAssertTrue(view.textContainer === view.readerContainer)
        }
        XCTAssertEqual(switches, 0, "no text view in the process fell back to TextKit 1")
    }

    func testABlankPageAnswersWithNothingAndNoLine() throws {
        let host = host([NSAttributedString(), CanvasText.body("Next section.")])
        let view = try XCTUnwrap(host.canvas.columns.first)
        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), 0)
        XCTAssertEqual(view.accessibilityValue(), "")
        XCTAssertEqual(view.accessibilityVisibleCharacterRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(view.accessibilityString(for: NSRange(location: 0, length: 0)), "")
        XCTAssertNil(view.accessibilityString(for: NSRange(location: 0, length: 1)))
        XCTAssertEqual(view.accessibilityRange(forLine: 0).location, NSNotFound)
        XCTAssertEqual(view.accessibilityRange(for: 0).location, NSNotFound)
        XCTAssertEqual(view.accessibilityStyleRange(for: 0).location, NSNotFound)
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(view.accessibilitySelectedText(), "")
        view.setAccessibilitySelectedTextRange(NSRange(location: 40, length: 0))
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 0, length: 0))
        // Turning on installs the next section's page in the same view.
        XCTAssertEqual(host.canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(view.accessibilityValue(), "Next section.")
        XCTAssertEqual(view.accessibilityRange(forLine: 0), NSRange(location: 0, length: 13))
    }
    #else
    func testLineElementsCoverThePageOnceWithLinksAndImagesAsTheirOwnElements() throws {
        let image = try ViewCoverage.readerImage(width: 120, height: 120, shownWidth: 30, alt: "")
        let labelled = try ViewCoverage.readerImage(width: 120, height: 120, shownWidth: 30, alt: "A small ornament")
        let text = NSMutableAttributedString(attributedString: CanvasText.body("Opening words, then a link that is long enough to wrap onto a second line of the column, "))
        let link = (text.string as NSString).range(of: "a link that is long enough to wrap onto a second line")
        text.addAttribute(.link, value: ReaderLink.internal(href: "OPS/two.xhtml#target").url, range: link)
        text.append(ViewCoverage.imageText(image))
        text.append(CanvasText.body(" and "))
        text.append(ViewCoverage.imageText(labelled))
        text.append(CanvasText.body(" before " + CanvasText.sentence(700, seed: 0)))
        let host = host([text])
        let view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertGreaterThan(view.textLength, view.placement.visibleLength)
        XCTAssertFalse(view.isAccessibilityElement)
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(view.accessibilityElementCount(), elements.count)
        // A link wrapping over two lines is an element on each, both activating it at its start.
        let links = elements.filter { $0.accessibilityTraits.contains(.link) }
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.map { $0.accessibilityLabel ?? "" }.joined(), (text.string as NSString).substring(with: link))
        for element in links {
            XCTAssertTrue(element.accessibilityActivate())
            XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml#target"))
        }
        let images = elements.filter { $0.accessibilityTraits.contains(.image) }
        XCTAssertEqual(images.map { $0.accessibilityLabel ?? "" }, ["Book image", "A small ornament"])
        for element in images {
            let actions = (element.accessibilityCustomActions ?? []).map(\.name)
            XCTAssertTrue(actions.contains("Next Page") && actions.contains("Previous Page"), "\(actions)")
            XCTAssertTrue(actions.contains { $0.hasPrefix("Inspect Image") }, "\(actions)")
        }
        XCTAssertTrue(try XCTUnwrap(images.last).accessibilityActivate(), "activating an image inspects it")
        XCTAssertNotNil(host.canvas.imageInspector)
        host.canvas.imageInspector?.close()
        // Every element lies in the column, and none reaches into the clipped context.
        for element in elements {
            let frame = element.accessibilityFrameInContainerSpace
            XCTAssertFalse(frame.isNull || frame.isEmpty, "\(element.accessibilityLabel ?? "")")
            XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(element.accessibilityLabel ?? ""): \(frame)")
        }
        XCTAssertEqual(view.accessibilityValue, view.visibleText)
        // The next page's elements replace these.
        XCTAssertEqual(host.canvas.turnPage(forward: true), .turned)
        let next = try XCTUnwrap(try XCTUnwrap(host.canvas.textViews.first).accessibilityElements as? [UIAccessibilityElement])
        XCTAssertFalse(next.contains { element in elements.contains { $0 === element } })
        XCTAssertEqual(next.map { $0.accessibilityLabel ?? "" }.joined(), try XCTUnwrap(host.canvas.textViews.first).visibleText)
        XCTAssertEqual(view.index(ofAccessibilityElement: elements[0]), NSNotFound, "a replaced page's element is no longer the column's")
    }

    func testABlankPageHasNoAccessibilityElements() throws {
        let host = host([NSAttributedString(), CanvasText.body("Next section.")])
        let view = try XCTUnwrap(host.canvas.columns.first)
        XCTAssertEqual(view.accessibilityElementCount(), 0)
        XCTAssertNil(view.accessibilityElement(at: 0))
        XCTAssertEqual(view.accessibilityValue, "")
        XCTAssertTrue(host.canvas.accessibilityScroll(.next), "the page after it is one scroll away")
        XCTAssertEqual((view.accessibilityElements as? [UIAccessibilityElement])?.map { $0.accessibilityLabel ?? "" }, ["Next section."])
    }
    #endif
}
