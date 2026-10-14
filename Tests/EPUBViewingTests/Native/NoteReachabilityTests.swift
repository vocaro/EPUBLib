import CoreText
import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing

final class NoteReachabilityTests: XCTestCase {
    func testALegacyNamedAnchorAnywhereInAHiddenNoteNamesTheWholeNote() throws {
        let text = try BuilderHarness.build("""
            <p>Claim<a href='#fn1'>plain</a> <a epub:type='noteref' href='#fn1'>typed</a>.</p>\
            <aside epub:type='footnote'><p>First.</p><p><a name='fn1'/>Second.</p></aside><p>After.</p>
            """)
        XCTAssertEqual(text.notes["fn1"]?.string, "First.\nSecond.")
        for label in ["plain", "typed"] {
            XCTAssertEqual(SectionContentSupport.link(label, in: text), .note(href: "OPS/one.xhtml#fn1"))
        }
        XCTAssertEqual(text.anchors["fn1"], BuilderHarness.location(of: "After.", in: text))
        XCTAssertFalse(text.string.string.contains("Second."))
        SectionContentSupport.assertTextMapContracts(text)
    }

    func testNamedNoteAnchorsKeepIdPrecedenceAndExistingNameRules() throws {
        let text = try BuilderHarness.build("""
            <p><a href='#claimed'>claimed link</a> <a href='#first'>first link</a> <a href='#alias'>alias link</a></p>\
            <p id='claimed'>Id wins.</p><p><a name='first'/>First name wins.</p>\
            <aside epub:type='footnote'><p><a name='claimed'/>Not the claimed note.</p>\
            <p><a name='first'/>Not the first name.</p><p><a id='own' name='alias'/>Own-id note.</p></aside>
            """)
        XCTAssertNil(text.notes["claimed"])
        XCTAssertNil(text.notes["first"])
        XCTAssertNil(text.notes["alias"], "An anchor with an id keeps the existing #133 behavior")
        XCTAssertNotNil(text.notes["own"])
        for label in ["claimed", "first", "alias"] {
            XCTAssertEqual(SectionContentSupport.link(label + " link", in: text), .internal(href: "OPS/one.xhtml#" + label))
        }
        XCTAssertEqual(text.anchors["claimed"], BuilderHarness.location(of: "Id wins.", in: text))
        XCTAssertEqual(text.anchors["first"], BuilderHarness.location(of: "First name wins.", in: text))
        SectionContentSupport.assertTextMapContracts(text)
    }

    func testRichTableCellsAndCaptionsUseTheirEnclosingNotesRules() throws {
        let text = try SectionContentSupport.styled("""
            <p id='ref'>Text.</p><aside epub:type='footnote' id='outer'><p>Before.</p>\
            <table><caption>Caption <a role='doc-backlink' href='#ref'>caption-back</a></caption>\
            <tr><td><p>Cell <a href='#outer'>1.</a> <a role='doc-backlink' href='#ref'>cell-back</a></p>\
            <div epub:type='endnote' id='inner'><b>Separate note.</b></div><p>Tail.</p>\
            <div epub:type='endnote'>Unnamed note.</div></td>\
            <td><p><b>Bold</b> <a href='two.xhtml'>target</a> <a epub:type='backlink' href='#ref'>typed-back</a></p></td></tr>\
            </table><p>After.</p></aside><p>End.</p>
            """)
        let note = try XCTUnwrap(text.notes["outer"])
        let table = try XCTUnwrap(TableCoverage.tables(in: note).first)
        XCTAssertEqual(table.cells.map(\.content.string), ["Cell 1.\nTail.\nUnnamed note.", "Bold target"])
        XCTAssertEqual(text.notes["inner"]?.string, "Separate note.")
        XCTAssertFalse(note.string.contains("caption-back"))
        XCTAssertTrue(note.string.contains("Caption"))
        XCTAssertFalse(text.string.string.contains("Before."))
        let first = try XCTUnwrap(table.cells.first).content
        let ownNumber = (first.string as NSString).range(of: "1.").location
        guard ownNumber != NSNotFound else { return XCTFail("The note's own number was lost") }
        XCTAssertNil(first.attribute(.link, at: ownNumber, effectiveRange: nil))
        let second = try XCTUnwrap(table.cells.last).content
        let target = (second.string as NSString).range(of: "target").location
        guard target != NSNotFound else { return XCTFail("The ordinary link was lost") }
        XCTAssertEqual((second.attribute(.link, at: target, effectiveRange: nil) as? URL).flatMap(ReaderLink.init(url:)),
                       .internal(href: "OPS/two.xhtml"))
        let bold = try XCTUnwrap(second.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        XCTAssertTrue(CTFontGetSymbolicTraits(bold as CTFont).contains(.traitBold))
        SectionContentSupport.assertTextMapContracts(text)
    }

    func testAnonymousRichTableCellsAlsoLeaveOutBacklinksAndSeparatelyCapturedNotes() throws {
        let text = try SectionContentSupport.styled("""
            <p>Text.</p><aside epub:type='footnote' id='outer'><table>\
            <tr><td>One.</td><td>Two.</td></tr><p>Anonymous <a role='doc-backlink' href='#ref'>back</a>\
            <span epub:type='endnote' id='inner'>Separate.</span> tail.</p></table></aside>
            """)
        let note = try XCTUnwrap(text.notes["outer"])
        let table = try XCTUnwrap(TableCoverage.tables(in: note).first)
        XCTAssertEqual(table.cells.map(\.content.string), ["One.", "Two.", "Anonymous tail."])
        XCTAssertEqual(text.notes["inner"]?.string, "Separate.")
    }
}

@MainActor final class NoteLinkSessionTests: XCTestCase {
    func testPlainCrossDocumentLinksPresentCapturedNotesWithoutNavigating() async throws {
        let reader = try SessionCoverageReader(SessionCoverageBook.epub([
            .init("one", """
                <p><a href='notes.xhtml#fn1'>id note</a> <a href='notes.xhtml#fn%C3%A9'>legacy note</a> \
                <a epub:type='noteref' href='notes.xhtml#fn1'>typed note</a> \
                <a href='notes.xhtml#ordinary'>ordinary target</a> <a href='notes.xhtml#missing'>missing note</a> \
                <a href='missing.xhtml#fn1'>missing document</a> <a href='https://example.invalid/n'>external</a></p>
                """),
            .init("notes", """
                <p>Notes opening.</p><aside epub:type='footnote' id='fn1'><p>The id note.</p></aside>\
                <aside epub:type='footnote'><p><a name='fné'/>The legacy note.</p></aside><p id='ordinary'>Ordinary target.</p>
                """, linear: false),
        ]))
        defer { reader.close() }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        let source = try XCTUnwrap(reader.session.book.section(0))
        func activate(_ label: String) throws {
            let link = try XCTUnwrap(SectionContentSupport.link(label, in: source))
            reader.session.canvas(canvas, didActivate: link, at: .init(section: 0, offset: 0),
                                  rect: CGRect(x: 10, y: 10, width: 40, height: 20))
        }
        let place = reader.session.visibleRange
        let count = reader.events.count
        for (label, expected) in [("id note", "The id note."), ("legacy note", "The legacy note."), ("typed note", "The id note.")] {
            try activate(label)
            try await reader.wait(label) { canvas.presentedNote?.string == expected }
            XCTAssertEqual(reader.session.visibleRange, place)
        }
        XCTAssertTrue(reader.locations(since: count).isEmpty)

        try activate("external")
        try await reader.wait("external refusal") { !reader.notices(since: count).isEmpty }
        XCTAssertEqual(reader.notices(since: count), ["This reader does not open links outside the book."])
        try activate("missing document")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(reader.session.visibleRange, place)

        try activate("ordinary target")
        try await reader.wait("ordinary target navigation") { reader.section == 1 }
        XCTAssertEqual(reader.session.lastLocation?.href, "OPS/notes.xhtml")
        try await reader.session.send(.navigate(href: "OPS/one.xhtml"))
        try await reader.wait("return to source") { reader.section == 0 }
        try activate("missing note")
        try await reader.wait("missing fragment navigation") { reader.section == 1 }
    }
}
