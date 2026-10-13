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

    /// A heading parked off screen above an image the book marks as decoration, as a Standard
    /// Ebooks title page has it, a hidden word in a line, and a hidden link: what a browser
    /// reads and does not draw (`SpokenLabelAttachment`).
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
        XCTAssertEqual(read, ["0 text The Hidden Title", "9 text unseen", "17 text Skip to chapter two"],
                       "the image of the title is decoration: nothing stands for it")
        XCTAssertEqual(view.visibleText, "The Hidden Title\nWords unseen after.\nSkip to chapter two End.", "what Copy takes from the page")
    }
    #else
    func testAHiddenLabelIsATextElementWhereItStands() throws {
        let (_, host, view) = try pageWithHiddenLabels()
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.map { $0.accessibilityLabel ?? "" },
                       ["The Hidden Title", "Words ", "unseen", "after.\n", "Skip to chapter two", "End."],
                       "no element for the image of the title, which is decoration, or the break after it")
        XCTAssertFalse(elements.contains { $0.accessibilityTraits.contains(.image) })
        XCTAssertEqual(elements.map { $0.accessibilityTraits.contains(.link) }, [false, false, false, false, true, false])
        XCTAssertTrue(elements[0].accessibilityTraits.contains(.staticText) && elements[2].accessibilityTraits.contains(.staticText))
        // Each has a place VoiceOver can rest on, inside the column, though it takes no room.
        for element in elements {
            let frame = element.accessibilityFrameInContainerSpace
            XCTAssertFalse(frame.isNull || frame.isEmpty, "\(element.accessibilityLabel ?? "")")
            XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(element.accessibilityLabel ?? ""): \(frame)")
        }
        let image = try XCTUnwrap(view.imageAttachments().first)
        XCTAssertEqual(elements[0].accessibilityFrameInContainerSpace.midY,
                       try XCTUnwrap(view.segmentFrames(for: image.range).first).midY + view.containerOrigin.y, accuracy: 60,
                       "the heading's label is in the line of the image it names")
        XCTAssertTrue(elements[4].accessibilityActivate(), "a hidden link is followed like any other")
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml"))
        XCTAssertEqual(view.accessibilityValue, "The Hidden Title\nWords unseen after.\nSkip to chapter two End.")
    }
    #endif

    // MARK: Images with words, without any, and marked as decoration

    /// What a book can say of a picture: nothing, that it is decoration (an empty `alt`), or
    /// words; standing alone, and as all or part of what a link holds.
    private func pageOfPictures() throws -> (section: SectionText, host: CanvasHost, view: ReaderTextView) {
        let section = try BoxLayoutHarness.build("""
            <p>Undescribed <img src="p.png"/> stands.</p><p>Decoration <img src="p.png" alt=""/> passed.</p>\
            <p>Words <img src="p.png" alt="A described picture"/> stand.</p>\
            <p>Bare: <a href="two.xhtml"><img src="p.png" alt=""/></a></p>\
            <p><a href="three.xhtml"><img src="p.png" alt=""/>Jump with decoration</a></p>\
            <p><a href="four.xhtml"><img src="p.png" alt="Described jump"/></a></p>\
            <p><a href="five.xhtml"><img src="p.png"/></a></p>
            """, css: BoxLayoutHarness.reset + "img { width: 20px; height: 20px }",
            files: ["p.png": RichFixture.image(width: 40, height: 40)])
        XCTAssertEqual(section.string.string, "Undescribed \u{FFFC} stands.\nDecoration \u{FFFC} passed.\nWords \u{FFFC} stand.\n"
                       + "Bare: \u{FFFC}\n\u{FFFC}Jump with decoration\n\u{FFFC}\n\u{FFFC}")
        let host = host([section.string], size: CGSize(width: 420, height: 500))
        let view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(view.placement.visibleLength, section.string.length, "the section is one page")
        return (section, host, view)
    }

    /// The same words for a selection, a copy and a search whatever a picture's `alt` says of
    /// its part: its words where it has them, and nothing for decoration or for none.
    private static let picturesAsText = "Undescribed  stands.\nDecoration  passed.\nWords A described picture stand.\n"
        + "Bare: \nJump with decoration\nDescribed jump\n"

    func testCopyTakesAPicturesWordsAndNothingForDecorationOrNone() async throws {
        let (section, host, view) = try pageOfPictures()
        XCTAssertEqual(view.visibleText, Self.picturesAsText)
        XCTAssertEqual(section.string.readerPlainText(), Self.picturesAsText, "what a search of the section reads")
        view.selectedRange = NSRange(location: 0, length: section.string.length)
        host.canvas.textViewSelectionDidChange(view)
        try await host.settle()
        XCTAssertEqual((host.recorder.selections.last ?? nil)?.text, Self.picturesAsText, "the selection a host is told of")
        #if os(macOS)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), Self.picturesAsText)
        #else
        let pasteboard = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("org.epublib.tests.pictures.\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        view.pasteboard = pasteboard
        view.copy(nil)
        XCTAssertEqual(pasteboard.string, Self.picturesAsText)
        #endif
    }

    #if os(macOS)
    func testDecorationHasNoElementAndAPictureWithoutWordsIsAnImageWithoutALabel() throws {
        let (section, host, view) = try pageOfPictures()
        XCTAssertEqual(view.accessibilityValue(), section.string.string, "the characters as they are, so every range matches")
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: NSRange(location: 0, length: section.string.length)))
        var read: [String] = [], actions: [[String]] = [], elements: [NSAccessibilityElement] = []
        rich.enumerateAttribute(.accessibilityAttachment, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            guard let element = value as? NSAccessibilityElement else { return }
            XCTAssertEqual(element.accessibilityRole(), .image)
            let link = (section.string.attribute(.link, at: range.location, effectiveRange: nil) as? URL).flatMap { url in
                ["two", "three", "four", "five"].first { ReaderLink.internal(href: "OPS/\($0).xhtml").url == url }
            }
            read.append("\(range.location) \(element.accessibilityLabel() ?? "nil")" + (link.map { " to \($0)" } ?? ""))
            actions.append((element.accessibilityCustomActions() ?? []).map(\.name))
            elements.append(element)
            XCTAssertFalse(element.accessibilityFrameInParentSpace().isEmpty, "\(range.location) has a place")
        }
        let text = section.string.string as NSString
        let bare = NSMaxRange(text.range(of: "Bare: ")), described = NSMaxRange(text.range(of: "Jump with decoration\n"))
        XCTAssertEqual(read, ["12 nil", "49 A described picture", "\(bare) nil to two", "\(described) Described jump to four",
                              "\(described + 2) nil to five"],
                       "no element for decoration in a line or in a link that has words; one for decoration that is all its link holds")
        XCTAssertEqual(actions, [["Inspect Image"], ["Inspect Image: A described picture"], ["Inspect Image"],
                                 ["Inspect Image: Described jump"], ["Inspect Image"]])
        // VoiceOver reads the help of an element without a label in the label's place, so an
        // image without words has none: it was heard as "Double-click or choose Inspect Image
        // to enlarge. image" in the middle of its line.
        XCTAssertEqual(elements.map { $0.accessibilityHelp() != nil }, [false, true, false, true, false])
        XCTAssertTrue(try XCTUnwrap(elements[1].accessibilityCustomActions()?.first).handler?() ?? false)
        XCTAssertNotNil(host.canvas.imageInspector)
        host.canvas.imageInspector?.close()
        // The link with decoration in it is still a link, by its words.
        XCTAssertEqual(section.string.attribute(.link, at: text.range(of: "Jump with").location, effectiveRange: nil) as? URL,
                       ReaderLink.internal(href: "OPS/three.xhtml").url)
    }

    func testTheInspectorNamesAnImageByItsWordsAndMakesUpNone() throws {
        let (_, host, view) = try pageOfPictures()
        let images = view.imageAttachments().map(\.image)
        var labels: [String?] = []
        for image in images {
            host.canvas.inspectImage(image)
            labels.append(try XCTUnwrap(host.canvas.imageInspector).imageView.accessibilityLabel())
            host.canvas.imageInspector?.close()
        }
        XCTAssertEqual(labels, [nil, nil, "A described picture", nil, nil, "Described jump", nil])
    }
    #else
    private func described(_ element: UIAccessibilityElement) -> String {
        let traits = element.accessibilityTraits
        let kind = [(UIAccessibilityTraits.link, "link"), (.image, "image"), (.staticText, "text")].filter { traits.contains($0.0) }.map(\.1)
        return kind.joined(separator: "+") + " " + (element.accessibilityLabel.map { "\"\($0)\"" } ?? "nil")
    }

    func testDecorationHasNoElementAndAPictureWithoutWordsIsAnImageWithoutALabel() throws {
        let (_, host, view) = try pageOfPictures()
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.map(described), [
            "text \"Undescribed \"", "image+text nil", "text \" stands.\n\"",
            "text \"Decoration  passed.\n\"",
            "text \"Words \"", "image+text \"A described picture\"", "text \" stand.\n\"",
            "text \"Bare: \"", "link+image nil",
            "link \"Jump with decoration\"",
            "link+image \"Described jump\"",
            "link+image nil",
        ], "a line with decoration in it is one element; decoration that is all its link holds is the link")
        for element in elements {
            let frame = element.accessibilityFrameInContainerSpace
            XCTAssertFalse(frame.isNull || frame.isEmpty, described(element))
            XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(described(element)): \(frame)")
        }
        // Every link is followed, whatever its image's alt says.
        for (index, href) in [(8, "two"), (9, "three"), (10, "four"), (11, "five")] {
            XCTAssertTrue(elements[index].accessibilityActivate(), href)
            XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/\(href).xhtml"))
        }
        XCTAssertNil(host.canvas.imageInspector)
        // Inspection is offered for each image VoiceOver is told of, and not for decoration.
        let inspections = elements.map { ($0.accessibilityCustomActions ?? []).map(\.name).filter { $0.hasPrefix("Inspect Image") } }
        XCTAssertEqual(inspections, [[], ["Inspect Image"], [], [], [], ["Inspect Image: A described picture"], [], [], ["Inspect Image"], [],
                                     ["Inspect Image: Described jump"], ["Inspect Image"]])
        XCTAssertFalse(elements[3].accessibilityActivate(), "a line with decoration in it opens nothing")
        XCTAssertNil(host.canvas.imageInspector)
        XCTAssertTrue(elements[1].accessibilityActivate(), "an image without words is inspected as any other")
        XCTAssertNotNil(host.canvas.imageInspector)
        host.canvas.imageInspector?.close()
        XCTAssertEqual(view.accessibilityValue, Self.picturesAsText)
    }

    /// A page of decoration alone would give VoiceOver no element to stand on, and so no place
    /// to turn the page from: its images are listed, as images without a name.
    func testAPageOfDecorationAloneListsItSoThePageCanBeTurned() throws {
        let section = try BoxLayoutHarness.build("<p><img src=\"p.png\" alt=\"\"/></p><p> <img src=\"p.png\" alt=\"\"/> </p>",
            css: BoxLayoutHarness.reset + "img { display: block; width: 120px }", files: ["p.png": RichFixture.image(width: 240, height: 80)])
        let host = host([section.string, CanvasText.body("Next section.")])
        let view = try XCTUnwrap(host.canvas.textViews.first)
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.map(described), ["image+text nil", "image+text nil"])
        XCTAssertEqual(view.accessibilityElementCount(), 2)
        XCTAssertEqual(view.accessibilityValue, section.string.readerPlainText(), "it still has no words")
        let actions = (elements[0].accessibilityCustomActions ?? []).map(\.name)
        XCTAssertEqual(actions, ["Next Page", "Previous Page", "Inspect Image"])
        XCTAssertTrue(elements[0].accessibilityScroll(.next), "the page is turned from it")
        XCTAssertEqual((try XCTUnwrap(host.canvas.textViews.first).accessibilityElements as? [UIAccessibilityElement])?.map(described),
                       ["text \"Next section.\""])
    }

    func testTheInspectorNamesAnImageByItsWordsAndMakesUpNone() throws {
        let (_, host, view) = try pageOfPictures()
        var labels: [String?] = []
        for image in view.imageAttachments().map(\.image) {
            host.canvas.inspectImage(image)
            let shown = try XCTUnwrap(host.canvas.imageInspector).imageView
            labels.append(shown.accessibilityLabel)
            XCTAssertTrue(shown.isAccessibilityElement && shown.accessibilityTraits.contains(.image))
            host.canvas.imageInspector?.close()
        }
        XCTAssertEqual(labels, [nil, nil, "A described picture", nil, nil, "Described jump", nil])
    }
    #endif

    // MARK: Rules

    /// A rule between two scenes, as a book writes a change of subject (`<hr>`), and one that
    /// is all a link holds.
    private func pageWithRules() throws -> (section: SectionText, host: CanvasHost, view: ReaderTextView) {
        let section = try BoxLayoutHarness.build(
            "<p>First scene ends.</p><hr/><p>Second scene starts.</p><a href=\"two.xhtml\"><hr/></a><p>Last words.</p>",
            css: BoxLayoutHarness.reset)
        XCTAssertEqual(section.string.string, "First scene ends.\n\u{FFFC}\nSecond scene starts.\n\u{FFFC}\nLast words.")
        let host = host([section.string, CanvasText.body("Next section.")])
        let view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(view.placement.visibleLength, section.string.length, "the section is one page")
        return (section, host, view)
    }

    /// A rule has no words. What VoiceOver is told of it is the reader's word and not the
    /// book's, so a selection, a copy and a search read nothing in its place.
    func testARuleHasNoWordsForACopyOrASearch() async throws {
        let (section, host, view) = try pageWithRules()
        let words = "First scene ends.\n\nSecond scene starts.\n\nLast words."
        XCTAssertEqual(view.visibleText, words)
        XCTAssertEqual(section.string.readerPlainText(), words, "what a search of the section reads")
        XCTAssertFalse(words.localizedCaseInsensitiveContains(ReaderRuleAttachment.spokenName))
        view.selectedRange = NSRange(location: 0, length: section.string.length)
        host.canvas.textViewSelectionDidChange(view)
        try await host.settle()
        XCTAssertEqual((host.recorder.selections.last ?? nil)?.text, words, "the selection a host is told of")
        #if os(macOS)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), words)
        #else
        let pasteboard = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("org.epublib.tests.rules.\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        view.pasteboard = pasteboard
        view.copy(nil)
        XCTAssertEqual(pasteboard.string, words)
        #endif
    }

    #if os(macOS)
    /// The elements `view` gives in its rich text for `range`, each with its place in that text.
    private func attachmentElements(of view: ReaderTextView, in range: NSRange) throws -> [(location: Int, element: NSAccessibilityElement)] {
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: range))
        var found: [(Int, NSAccessibilityElement)] = []
        rich.enumerateAttribute(.accessibilityAttachment, in: NSRange(location: 0, length: rich.length)) { value, run, _ in
            if let element = value as? NSAccessibilityElement { found.append((run.location, element)) }
        }
        return found
    }

    /// What WebKit gives an `hr` on Mac, which AppKit has no role for: a splitter that is a
    /// break in content, called a separator. It has no name, no value and no help, so the role
    /// description is all VoiceOver has to say.
    private func assertIsASeparator(_ element: NSAccessibilityElement, in view: ReaderTextView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(element.accessibilityRole(), .splitter, file: file, line: line)
        XCTAssertEqual(element.accessibilitySubrole()?.rawValue, "AXContentSeparator", "a break in content, not the bar of a split view", file: file, line: line)
        XCTAssertEqual(element.accessibilityRoleDescription(), "separator", file: file, line: line)
        XCTAssertEqual(element.accessibilityOrientation(), .horizontal, file: file, line: line)
        XCTAssertNil(element.accessibilityLabel(), "the word is the role's and not a name", file: file, line: line)
        XCTAssertNil(element.accessibilityValue(), file: file, line: line)
        XCTAssertNil(element.accessibilityHelp(), "VoiceOver reads the help of an element without a label in the label's place", file: file, line: line)
        XCTAssertTrue((element.accessibilityCustomActions() ?? []).isEmpty, "a rule opens nothing", file: file, line: line)
        XCTAssertTrue(element.accessibilityParent() as? ReaderTextView === view, file: file, line: line)
        XCTAssertFalse(element.accessibilityFrameInParentSpace().isEmpty, "it has a place", file: file, line: line)
    }

    /// On Mac the text area is the element and a rule is a character of its value. The
    /// character carries a separator element, so that VoiceOver says a break is there, and the
    /// value and every range stay those of the characters.
    func testARuleIsASeparatorElementWithoutWordsOnMac() throws {
        let (section, _, view) = try pageWithRules()
        let whole = NSRange(location: 0, length: section.string.length)
        XCTAssertEqual(view.accessibilityValue(), section.string.string, "the characters as they are, so every range matches")
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), section.string.length)
        let found = try attachmentElements(of: view, in: whole)
        XCTAssertEqual(found.map(\.location), [18, 41], "one element for each rule, on the rule's own character")
        for (location, element) in found {
            XCTAssertEqual(view.accessibilityString(for: NSRange(location: location, length: 1)), "\u{FFFC}")
            assertIsASeparator(element, in: view)
            let drawn = view.segmentFrames(for: NSRange(location: location, length: 1)).reduce(CGRect.null) { $0.union($1) }
            XCTAssertEqual(element.accessibilityFrameInParentSpace(), drawn.offsetBy(dx: view.containerOrigin.x, dy: view.containerOrigin.y),
                           "where the rule is drawn")
        }
        XCTAssertNotEqual(found.first?.element.accessibilityFrameInParentSpace(), found.last?.element.accessibilityFrameInParentSpace())
        // The second rule is all its link holds. On Mac a link is text, and the rule in it is a rule.
        XCTAssertNotNil(section.string.attribute(.link, at: 41, effectiveRange: nil))
        // A read of part of the page gives the same elements, at their places in that part.
        let again = try attachmentElements(of: view, in: whole)
        XCTAssertTrue(zip(found, again).allSatisfy { $0.element === $1.element } && again.count == 2, "an element is kept from one read to the next")
        let part = try attachmentElements(of: view, in: NSRange(location: 18, length: 24))
        XCTAssertEqual(part.map(\.location), [0, 23])
        XCTAssertTrue(zip(found, part).allSatisfy { $0.element === $1.element })
        XCTAssertTrue(try attachmentElements(of: view, in: NSRange(location: 0, length: 18)).isEmpty, "none where there is no rule")
        XCTAssertTrue(try attachmentElements(of: view, in: NSRange(location: 19, length: 22)).isEmpty)
        // The rule is still no image and has no words: nothing else stands for it.
        XCTAssertTrue(view.textualAttachments().isEmpty && view.announcedImages().isEmpty)
        XCTAssertEqual(view.visibleText, "First scene ends.\n\nSecond scene starts.\n\nLast words.")
    }

    /// A page that holds a rule and nothing else has one character, which is the separator.
    func testAPageThatHoldsARuleAloneHasItsSeparatorOnMac() throws {
        let section = try BoxLayoutHarness.build("<hr/>", css: BoxLayoutHarness.reset)
        XCTAssertEqual(section.string.string, "\u{FFFC}")
        let host = host([section.string, CanvasText.body("Next section.")])
        let view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(view.accessibilityValue(), "\u{FFFC}")
        XCTAssertEqual(view.accessibilityRange(forLine: 0), NSRange(location: 0, length: 1))
        let found = try attachmentElements(of: view, in: NSRange(location: 0, length: 1))
        XCTAssertEqual(found.map(\.location), [0])
        assertIsASeparator(try XCTUnwrap(found.first).element, in: view)
        XCTAssertEqual(view.visibleText, "", "the page has no words")
        // The next page's text replaces it: a new read gives no separator and keeps no element.
        XCTAssertEqual(host.canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(view.accessibilityValue(), "Next section.")
        XCTAssertTrue(try attachmentElements(of: view, in: NSRange(location: 0, length: 13)).isEmpty)
    }

    /// In continuous scroll one text area holds the book, and a rule in it is a separator too.
    func testARuleIsASeparatorInContinuousScrollOnMac() throws {
        let section = try BoxLayoutHarness.build("<p>First scene ends.</p><hr/><p>Second scene starts.</p>", css: BoxLayoutHarness.reset)
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = .scrolled
        let host = CanvasHost(FakeCanvasSource([section.string]), size: CGSize(width: 420, height: 350), configuration: configuration)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        let view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertFalse(view.isPageColumn)
        XCTAssertEqual(view.accessibilityValue(), "First scene ends.\n\u{FFFC}\nSecond scene starts.", "the characters as they are")
        let found = try attachmentElements(of: view, in: NSRange(location: 0, length: section.string.length))
        XCTAssertEqual(found.map(\.location), [18])
        assertIsASeparator(try XCTUnwrap(found.first).element, in: view)
    }
    #else
    /// A rule is a stop of its own between the lines it parts. It is not a picture, which
    /// VoiceOver would call an image, and UIKit has no trait for a separator, so the reader
    /// names it; the name is the element's and not the page's.
    func testARuleIsAStopThatSaysASeparatorIsThereAndIsNotAnImage() throws {
        let (_, host, view) = try pageWithRules()
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.map { $0.accessibilityLabel ?? "" },
                       ["First scene ends.\n", "Separator", "Second scene starts.\n", "Separator", "Last words."],
                       "one stop for each rule, where it stands, and none for the break after it")
        XCTAssertEqual(ReaderRuleAttachment.spokenName, "Separator")
        XCTAssertFalse(elements.contains { $0.accessibilityTraits.contains(.image) }, "a rule is not a picture")
        XCTAssertEqual(elements.map(\.accessibilityTraits), [.staticText, [], .staticText, .link, .staticText],
                       "nor words of the book; inside a link it is the link")
        for element in elements {
            let frame = element.accessibilityFrameInContainerSpace
            XCTAssertFalse(frame.isNull || frame.isEmpty, element.accessibilityLabel ?? "")
            XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(element.accessibilityLabel ?? ""): \(frame)")
        }
        XCTAssertLessThan(elements[0].accessibilityFrameInContainerSpace.midY, elements[1].accessibilityFrameInContainerSpace.minY + 1)
        XCTAssertLessThan(elements[1].accessibilityFrameInContainerSpace.midY, elements[2].accessibilityFrameInContainerSpace.minY + 1)
        // The page is turned from a rule as from a line, and nothing else is offered on it.
        XCTAssertEqual((elements[1].accessibilityCustomActions ?? []).map(\.name), ["Next Page", "Previous Page"])
        XCTAssertFalse(elements[1].accessibilityActivate(), "a rule opens nothing")
        XCTAssertNil(host.canvas.imageInspector)
        XCTAssertTrue(host.recorder.links.isEmpty)
        XCTAssertTrue(elements[3].accessibilityActivate(), "a link that holds a rule alone is followed")
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml"))
        XCTAssertEqual(view.accessibilityValue, "First scene ends.\n\nSecond scene starts.\n\nLast words.",
                       "the page's words, which a rule has none of")
    }

    /// A page that holds a rule and nothing else still gives VoiceOver an element to stand on:
    /// the rule's own stop, from which the page is turned.
    func testAPageThatHoldsARuleAloneIsTurnedFromTheRule() throws {
        let section = try BoxLayoutHarness.build("<hr/>", css: BoxLayoutHarness.reset)
        XCTAssertEqual(section.string.string, "\u{FFFC}")
        let host = host([section.string, CanvasText.body("Next section.")])
        let view = try XCTUnwrap(host.canvas.textViews.first)
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.map(described), [" \"Separator\""], "a stop that is neither a link, an image nor text")
        XCTAssertEqual(view.accessibilityElementCount(), 1)
        XCTAssertFalse(elements[0].accessibilityFrameInContainerSpace.isEmpty)
        XCTAssertEqual(view.accessibilityValue, "", "the page has no words")
        XCTAssertEqual((elements[0].accessibilityCustomActions ?? []).map(\.name), ["Next Page", "Previous Page"])
        XCTAssertTrue(elements[0].accessibilityScroll(.next), "the page is turned from it")
        XCTAssertEqual((try XCTUnwrap(host.canvas.textViews.first).accessibilityElements as? [UIAccessibilityElement])?.map(described),
                       ["text \"Next section.\""])
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
        let image = try ViewCoverage.readerImage(width: 120, height: 120, shownWidth: 30, alt: nil)
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
        XCTAssertEqual(images.map(\.accessibilityLabel), [nil, "A small ornament"], "no name is made up for an image without words")
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
