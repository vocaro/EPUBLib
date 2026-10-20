#if os(iOS)
import EPUBCore
import EPUBReading
import UIKit
import XCTest
@testable import EPUBViewing

/// Each element a page or the scroll view lists on iPhone and iPad names the language of its
/// words (#65): the nearest `xml:lang` or `lang`, else the package's, and none for the tags
/// that name no voice. A line whose words are in several languages has the language of most
/// of them, and each part of its label carries its own. What each element says, is and
/// offers stays as it was: these tests pin the labels, traits and actions with the languages.
@MainActor final class ContentLanguageAccessibilityTests: XCTestCase {
    private var readers: [SessionCoverageReader] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
        try await super.tearDown()
    }

    private static let square = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><rect width=\"32\" height=\"32\" fill=\"#07c\"/></svg>"

    /// English words that no one reads, more letters than the French beside them, and few
    /// enough that hidden in a line they leave it one line: they keep their room.
    private static let unread = "unseen English words"

    /// A German book, by its package, with French and English in it: a section of lines,
    /// headings, links, a formula and a picture, one that opens with a line of English and
    /// French and holds a rule, a table used for layout and a table of data, and one of words
    /// that are not read, which would outweigh the French around them: English that
    /// `visibility: hidden` hides, in a line and in a cell, and a picture the book keeps from
    /// assistive technology in a heading. That one holds a rule kept from assistive technology
    /// too, which is all its link holds. Each takes one page of an iPhone.
    private static func book() throws -> EPUBPublication {
        try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("sprachen", """
                <h1 lang="fr">Chapitre premier</h1>\
                <p>Ein deutscher Satz.</p>\
                <p lang="fr">Une phrase française.</p>\
                <h2 lang="en">Notes on <i lang="fr">la vie</i></h2>\
                <p lang="en"><a href="notes.xhtml">An English link</a> and <a href="notes.xhtml" lang="fr">un lien</a>.</p>\
                <p lang="fr">Soit <math xmlns="http://www.w3.org/1998/Math/MathML" alttext="x plus deux"><mi>x</mi><mo>+</mo><mn>2</mn></math> ici.</p>\
                <p><img src="square.svg" alt="Ein blaues Quadrat"/> steht hier.</p>\
                <p lang="und">Words of no determined language.</p>\
                <p xml:lang="">Words of a language unknown.</p>
                """),
            SessionCoverageBook.Section("tabellen", """
                <p lang="en">He said <span lang="fr">bonjour</span> and left.</p>\
                <hr/>\
                <table><tr><td>Deutsche Tabellenzelle</td><td lang="fr">Cellule</td></tr></table>\
                <table><tr><th>Name</th><th lang="fr">Ville</th></tr><tr><td>Anna</td><td lang="fr">Lyon</td></tr></table>\
                <p>Letzte Worte.</p>
                """),
            SessionCoverageBook.Section("verborgen", """
                <p lang="fr">Oui<span style="visibility: hidden" lang="en">\(unread)</span>non.</p>\
                <h2 lang="fr">Titre <img src="square.svg" alt="\(unread)" aria-hidden="true"/> caché</h2>\
                <a href="notes.xhtml"><hr aria-hidden="true"/></a>\
                <table><tr><th>Wort</th><th lang="fr">Mot</th></tr><tr><td>Satz</td><td lang="fr">Oui<span style="visibility: hidden" lang="en">\(unread)</span></td></tr></table>\
                <p>Ende.</p>
                """),
            SessionCoverageBook.Section("notes", "<h1>Notes</h1><p>The linked note.</p>")],
            manifest: "<item id=\"square\" href=\"square.svg\" media-type=\"image/svg+xml\"/>",
            files: ["OPS/square.svg": square], language: "de"))
    }

    /// What an element gives an assistive technology: its words without the break after
    /// them, its language, the parts of its label that carry a language of their own as
    /// "language:words", a heading's level, its traits and its actions.
    private struct Spoken: Equatable {
        var label: String?
        var language: String?
        var parts: [String] = []
        var level: Int?
        var traits: UIAccessibilityTraits = .staticText
        var actions: [String] = []
    }

    private func spoken(_ element: UIAccessibilityElement) -> Spoken {
        var parts: [String] = []
        var level: Int?
        if let label = element.accessibilityAttributedLabel, label.length > 0 {
            XCTAssertEqual(label.string, element.accessibilityLabel, "the label read and the one its attributes are on are the same words")
            level = label.attribute(.accessibilityTextHeadingLevel, at: 0, effectiveRange: nil) as? Int
            label.enumerateAttribute(.accessibilitySpeechLanguage, in: NSRange(location: 0, length: label.length)) { value, range, _ in
                guard let language = value as? String else { return }
                parts.append(language + ":" + (label.string as NSString).substring(with: range).trimmingCharacters(in: .newlines))
            }
        }
        return Spoken(label: element.accessibilityLabel?.trimmingCharacters(in: .newlines), language: element.accessibilityLanguage,
                      parts: parts, level: level, traits: element.accessibilityTraits,
                      actions: (element.accessibilityCustomActions ?? []).map(\.name))
    }

    /// What a view lists, in reading order: each line, and each cell of a table of data where
    /// the table's element stands.
    private func items(of view: ReaderTextView) throws -> [UIAccessibilityElement] {
        try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement]).flatMap { element -> [UIAccessibilityElement] in
            guard element is UIAccessibilityContainerDataTable else { return [element] }
            return try XCTUnwrap(element.accessibilityElements as? [UIAccessibilityElement])
        }
    }

    /// The first section's items, with the actions `page` adds to each.
    private static func languages(page: [String]) -> [Spoken] {
        [
            Spoken(label: "Chapitre premier", language: "fr", level: 1, traits: [.staticText, .header], actions: page),
            Spoken(label: "Ein deutscher Satz.", language: "de", actions: page),
            Spoken(label: "Une phrase française.", language: "fr", actions: page),
            // A heading in two languages: its level and each part's language, over the same words.
            Spoken(label: "Notes on la vie", language: "en", parts: ["en:Notes on ", "fr:la vie"], level: 2,
                   traits: [.staticText, .header], actions: page),
            Spoken(label: "An English link", language: "en", traits: .link, actions: page),
            Spoken(label: " and ", language: "en", actions: page),
            Spoken(label: "un lien", language: "fr", traits: .link, actions: page),
            Spoken(label: ".", language: "en", actions: page),
            Spoken(label: "Soit ", language: "fr", actions: page),
            // An authored reading is in the language of the text around the formula.
            Spoken(label: "x plus deux", language: "fr", traits: [.staticText, .image], actions: page),
            Spoken(label: " ici.", language: "fr", actions: page),
            // A picture's words are not given a language (#548).
            Spoken(label: "Ein blaues Quadrat", language: nil, traits: [.staticText, .image],
                   actions: page + ["Inspect Image: Ein blaues Quadrat"]),
            Spoken(label: " steht hier.", language: "de", actions: page),
            Spoken(label: "Words of no determined language.", language: nil, actions: page),
            Spoken(label: "Words of a language unknown.", language: nil, actions: page),
        ]
    }

    /// The second section's items, with the actions `page` adds to each.
    private static func tables(page: [String]) -> [Spoken] {
        [
            Spoken(label: "He said bonjour and left.", language: "en",
                   parts: ["en:He said ", "fr:bonjour", "en: and left."], actions: page),
            // The reader's own word for a rule is in no language of the book's.
            Spoken(label: "Separator", language: nil, traits: [], actions: page),
            // A row read whole: each cell's words in the language of that cell.
            Spoken(label: "Deutsche Tabellenzelle\tCellule", language: "de", parts: ["de:Deutsche Tabellenzelle\t", "fr:Cellule"],
                   actions: page + ["Select Table Text: Deutsche Tabellenzelle", "Select Table Text: Cellule"]),
            // A cell of a table of data is read as one text, in its own language.
            Spoken(label: "Name", language: "de", actions: page + ["Select Cell Text"]),
            Spoken(label: "Ville", language: "fr", actions: page + ["Select Cell Text"]),
            Spoken(label: "Anna", language: "de", actions: page + ["Select Cell Text"]),
            Spoken(label: "Lyon", language: "fr", actions: page + ["Select Cell Text"]),
            Spoken(label: "Letzte Worte.", language: "de", actions: page),
        ]
    }

    /// The third section's items, with the actions `page` adds to each: none reads the words
    /// that are not read, and those decide no language.
    private static func unread(page: [String]) -> [Spoken] {
        [
            Spoken(label: "Oui non.", language: "fr", actions: page),
            Spoken(label: "Titre  caché", language: "fr", level: 2, traits: [.staticText, .header], actions: page),
            // A rule kept from assistive technology that is all its link holds is the link, in
            // the reader's word, which is in no language of the book's.
            Spoken(label: "Separator", language: nil, traits: .link, actions: page),
            Spoken(label: "Wort", language: "de", actions: page + ["Select Cell Text"]),
            Spoken(label: "Mot", language: "fr", actions: page + ["Select Cell Text"]),
            Spoken(label: "Satz", language: "de", actions: page + ["Select Cell Text"]),
            Spoken(label: "Oui", language: "fr", actions: page + ["Select Cell Text"]),
            Spoken(label: "Ende.", language: "de", actions: page),
        ]
    }

    /// `items` as a page lists them: VoiceOver reading on past the last turns the page (#468).
    private static func turning(_ items: [Spoken]) -> [Spoken] {
        var items = items
        if !items.isEmpty { items[items.count - 1].traits.insert(.causesPageTurn) }
        return items
    }

    func testEachElementOfAPageNamesTheLanguageOfItsWords() async throws {
        let reader = try SessionCoverageReader(publication: try Self.book())
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        let view = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
        let turns = ["Next Page", "Previous Page"]
        XCTAssertEqual(canvas.visibleRange?.start.section, 0)
        XCTAssertEqual(try items(of: view).map(spoken), Self.turning(Self.languages(page: turns)))

        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        try await reader.wait("the second section") { canvas.visibleRange?.start.section == 1 }
        try await reader.wait("the cells' text views") { view.tableInteraction?.cells.isEmpty == false }
        XCTAssertEqual(try items(of: view).map(spoken), Self.turning(Self.tables(page: turns)))

        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        try await reader.wait("the third section") { canvas.visibleRange?.start.section == 2 }
        try await reader.wait("the cells' text views") { view.tableInteraction?.cells.isEmpty == false }
        XCTAssertEqual(try items(of: view).map(spoken), Self.turning(Self.unread(page: turns)))
    }

    func testEachElementOfContinuousScrollNamesTheLanguageOfItsWords() async throws {
        let reader = try SessionCoverageReader(publication: try Self.book())
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        let view = try XCTUnwrap(canvas.scrollTextView)
        try await reader.wait("the cells' text views") { view.tableInteraction?.cells.isEmpty == false }
        // Continuous scroll scrolls by VoiceOver's own gesture: no item turns a page. The
        // scroll view lists the book's lines past the screen, and its bars after them.
        let expected = Self.languages(page: []) + Self.tables(page: [])
        let listed = try items(of: view).map(spoken)
        XCTAssertGreaterThan(listed.count, expected.count)
        XCTAssertEqual(Array(listed.prefix(expected.count)), expected)
        // The third section stands below the screen, and whether its table's cells have text
        // views to select from there is not what this test is about: its items without actions.
        func withoutActions(_ items: [Spoken]) -> [Spoken] { items.map { var item = $0; item.actions = []; return item } }
        let unread = withoutActions(Self.unread(page: []))
        XCTAssertEqual(withoutActions(Array(listed.dropFirst(expected.count).prefix(unread.count))), unread)
    }

    /// The element under VoiceOver's cursor, taken to the next page and back by its own page
    /// actions, is what the first item of each page is, languages and all, and keeps none of
    /// the item before: the heading's level is not left on the line of two languages, nor that
    /// line's parts on the heading.
    func testTheElementUnderTheCursorTakesTheLanguagesOfTheItemItStandsFor() async throws {
        let reader = try SessionCoverageReader(publication: try Self.book())
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        let view = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
        let turns = ["Next Page", "Previous Page"]
        let cursor = try XCTUnwrap(try items(of: view).first)
        cursor.accessibilityElementDidBecomeFocused()
        NotificationCenter.default.post(name: UIAccessibility.elementFocusedNotification, object: nil,
                                        userInfo: [UIAccessibility.focusedElementUserInfoKey: cursor])
        func perform(_ name: String) throws {
            let action = try XCTUnwrap(cursor.accessibilityCustomActions?.first { $0.name == name })
            XCTAssertTrue(try XCTUnwrap(action.actionHandler)(action))
        }

        try perform("Next Page")
        try await reader.wait("the second section") { canvas.visibleRange?.start.section == 1 }
        XCTAssertTrue(try items(of: view).first === cursor)
        XCTAssertEqual(spoken(cursor), Self.tables(page: turns)[0])

        try perform("Previous Page")
        try await reader.wait("the first section") { canvas.visibleRange?.start.section == 0 }
        XCTAssertTrue(try items(of: view).first === cursor)
        XCTAssertEqual(spoken(cursor), Self.languages(page: turns)[0])
    }
}
#endif
