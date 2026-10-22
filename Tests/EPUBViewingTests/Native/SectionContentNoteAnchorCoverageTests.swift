import CoreText
import EPUBCore
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Footnotes and endnotes (EPUB Structural Semantics `noteref`/`footnote`/`endnote`, DPUB-ARIA
/// `doc-noteref`/`doc-footnote`) and the anchors a section gives its element ids.
final class SectionContentNoteAnchorCoverageTests: XCTestCase {
    private typealias H = BuilderHarness
    private typealias S = SectionContentSupport

    // MARK: Notes

    func testSeveralReferencesToOneNoteAreAllNoteLinksAndTheNoteIsCapturedOnce() throws {
        let text = try H.build("""
            <p>T<a epub:type="noteref" href="#n1">one</a> U<a epub:type="noteref" href="#n1">again</a> \
            V<sup><a epub:type="noteref" href="#n1"><b>bold</b></a></sup></p>\
            <aside epub:type="footnote" id="n1"><p>The note.</p></aside>
            """)
        XCTAssertEqual(text.string.string, "Tone Uagain Vbold")
        for word in ["one", "again", "bold"] { XCTAssertEqual(S.link(word, in: text), .note(href: "OPS/one.xhtml#n1"), word) }
        XCTAssertEqual(text.notes.mapValues(\.string), ["n1": "The note."])
        XCTAssertGreaterThan(H.attribute(.baselineOffset, of: "bold", in: text) as? CGFloat ?? 0, 0)
        S.assertTextMapContracts(text)
    }

    func testAReferenceToAMissingOrForeignNoteIsStillANoteLink() throws {
        let text = try H.build("""
            <p><a epub:type="noteref" href="#missing">gone</a> <a epub:type="noteref" href="two.xhtml#n9">other</a> \
            <a role="doc-noteref" href="notes/back.xhtml#n%C3%A9">encoded</a> <a epub:type="noteref">bare</a> \
            <a epub:type="noteref" href="https://example.com/n">remote</a></p>
            """)
        XCTAssertEqual(S.link("gone", in: text), .note(href: "OPS/one.xhtml#missing"))
        XCTAssertEqual(S.link("other", in: text), .note(href: "OPS/two.xhtml#n9"))
        XCTAssertEqual(S.link("encoded", in: text), .note(href: "OPS/notes/back.xhtml#n%C3%A9"))
        XCTAssertNil(S.link("bare", in: text))
        XCTAssertEqual(S.link("remote", in: text), .external("https://example.com/n"))
        XCTAssertTrue(text.notes.isEmpty)
    }

    func testNoteKindsByElementTypeAndRole() throws {
        let text = try H.build("""
            <p>x</p><aside epub:type="footnote" id="a1">aside footnote</aside><aside epub:type="note" id="a2">aside note</aside>\
            <div role="doc-footnote" id="a4">role footnote</div>\
            <aside epub:type="endnote" id="b1">aside endnote</aside><div role="doc-endnote" id="b2">role endnote</div>\
            <div epub:type="footnote" id="c1">div footnote</div><p epub:type="footnote" id="c2">p footnote</p>\
            <aside id="d1">plain aside</aside><aside epub:type="sidebar" id="d2">sidebar</aside><p>end</p>
            """)
        // Footnote asides (and `doc-footnote`) leave the flow; endnotes and other notes stay in it.
        XCTAssertEqual(S.paragraphs(text), ["x", "aside endnote", "role endnote", "div footnote", "p footnote", "plain aside", "sidebar", "end"])
        XCTAssertEqual(text.notes.mapValues(\.string), [
            "a1": "aside footnote", "a2": "aside note", "a4": "role footnote",
            "b1": "aside endnote", "b2": "role endnote", "c1": "div footnote", "c2": "p footnote",
        ])
        // A hidden note's id is the next rendered character.
        for id in ["a1", "a2", "a4"] { XCTAssertEqual(text.anchors[id], H.location(of: "aside endnote", in: text), id) }
        XCTAssertEqual(text.anchors["c1"], H.location(of: "div footnote", in: text))
        S.assertTextMapContracts(text)
    }

    func testEndnoteContainersKeepEveryNoteInTheFlow() throws {
        let text = try H.build("""
            <section epub:type="endnotes"><h2>Notes</h2><ol><li epub:type="footnote" id="e1"><p>First.</p></li>\
            <li id="e2"><aside epub:type="footnote" id="e2a">Second.</aside></li></ol></section>\
            <section role="doc-endnotes"><div role="doc-footnote" id="e3">Third.</div></section>\
            <section epub:type="rearnotes"><aside epub:type="rearnote" id="e4">Fourth.</aside></section>
            """)
        XCTAssertEqual(S.paragraphs(text), ["Notes", "1.\tFirst.", "2.\tSecond.", "Third.", "Fourth."])
        XCTAssertEqual(text.notes.mapValues(\.string), ["e1": "First.", "e2a": "Second.", "e3": "Third.", "e4": "Fourth."])
        S.assertTextMapContracts(text)
    }

    func testANoteKeepsItsMarkupWithoutBacklinksOrItsOwnNumber() throws {
        let text = try H.build("""
            <p id="r1">Text<a epub:type="noteref" href="#n1">1</a></p>\
            <aside epub:type="footnote" id="n1"><p><a href="#n1">1.</a> Note <b>bold</b> <em>em</em> <a href="two.xhtml">link</a> \
            <a href="https://example.com/">out</a> <a href="#r1" role="doc-backlink">↩</a><a href="#r1" epub:type="backlink">back</a></p>\
            <ul><li>item</li></ul><blockquote><p>quoted<br/>line</p></blockquote><p><img src="picture.png" alt="Pic"/></p></aside>
            """)
        let note = try XCTUnwrap(text.notes["n1"])
        XCTAssertEqual(note.string, "1. Note bold em link out\n• item\nquoted\u{2028}line\n[Pic]")
        func attribute(_ key: NSAttributedString.Key, _ word: String) -> Any? {
            note.attribute(key, at: (note.string as NSString).range(of: word).location, effectiveRange: nil)
        }
        XCTAssertNil(attribute(.link, "1."), "the note's own number is not a link")
        XCTAssertEqual((attribute(.link, "link") as? URL).flatMap(ReaderLink.init(url:)), .internal(href: "OPS/two.xhtml"))
        XCTAssertEqual((attribute(.link, "out") as? URL).flatMap(ReaderLink.init(url:)), .external("https://example.com/"))
        let bold = try XCTUnwrap(attribute(.font, "bold") as? PlatformFont), em = try XCTUnwrap(attribute(.font, "em") as? PlatformFont)
        XCTAssertTrue(CTFontGetSymbolicTraits(bold as CTFont).contains(.traitBold))
        XCTAssertTrue(CTFontGetSymbolicTraits(em as CTFont).contains(.traitItalic))
        // A note is shown apart from the page: no box indents.
        let quoted = try XCTUnwrap(attribute(.paragraphStyle, "quoted") as? NSParagraphStyle)
        XCTAssertEqual(quoted.headIndent, 0)
        XCTAssertFalse(text.string.string.contains("Note"))
    }

    func testANoteStyledSmallOrHiddenByTheBookIsShownAtBodySize() throws {
        let text = try S.styled("""
            <p>Text<a epub:type="noteref" href="#n1">1</a><a epub:type="noteref" href="#n2">2</a></p>\
            <aside epub:type="footnote" id="n1" class="tiny"><p>Tiny note.</p></aside>\
            <aside epub:type="footnote" id="n2" hidden="hidden"><p>Hidden <span class="gone">secret</span>note.</p></aside>
            """, css: ".tiny { font-size: 0.5em; visibility: hidden } .gone { display: none }")
        let tiny = try XCTUnwrap(text.notes["n1"])
        XCTAssertEqual(tiny.string, "Tiny note.")
        XCTAssertEqual((tiny.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)?.pointSize, 16)
        XCTAssertNotEqual(tiny.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor, .clear)
        // What the book hides inside a note stays hidden.
        XCTAssertEqual(text.notes["n2"]?.string, "Hidden note.")
        XCTAssertEqual(text.string.string, "Text12")
    }

    func testNotesInsideHiddenContainersTablesAndOtherNotesAreStillCaptured() throws {
        let text = try H.build("""
            <p>Text</p><div hidden=""><aside epub:type="footnote" id="h1">In hidden.</aside></div>\
            <table><tr><td>cell<aside epub:type="footnote" id="t1">In table.</aside></td><td>other</td></tr></table>\
            <aside epub:type="footnote" id="o1"><p>Outer</p><aside epub:type="footnote" id="i1">inner</aside><p>rest.</p></aside>
            """, rich: BuilderRecordingRich(rendersTables: true))
        XCTAssertEqual(text.notes["h1"]?.string, "In hidden.")
        XCTAssertEqual(text.notes["t1"]?.string, "In table.")
        // A note's content leaves out the notes nested in it: each is a note of its own.
        XCTAssertEqual(text.notes["i1"]?.string, "inner")
        XCTAssertEqual(text.notes["o1"]?.string, "Outer\nrest.")
    }

    func testANoteThatOpensAnotherNoteDoesNotTakeItsId() throws {
        // A note's first child's id names the note too (a reference may point at its first paragraph), but not
        // when that child is a note itself: "each is a note of its own" (`SectionBuildState.captureNote`).
        let text = try H.build("""
            <p><a epub:type="noteref" href="#outer">1</a><a epub:type="noteref" href="#inner">2</a></p>\
            <ol><li epub:type="endnote" id="outer"><aside epub:type="footnote" id="inner">The inner note.</aside> Outer text.</li></ol>
            """)
        XCTAssertEqual(text.notes["inner"]?.string, "The inner note.")
        XCTAssertEqual(text.notes["outer"]?.string, "Outer text.")
    }

    func testANotesLeadingIdsStopAtTheFirstNoteNestedInIt() throws {
        // The ids before a nested note still name the outer note, which may have none of its own; the nested
        // note's ids, and those of its own leading descendants, name it alone.
        let text = try H.build("""
            <p>Text</p><aside epub:type="footnote" id="o1"><div id="d1"><aside epub:type="footnote" id="i1"><p id="ip">Inner.</p></aside>\
            </div><p>Outer.</p></aside>\
            <ol><li epub:type="endnote"><aside epub:type="footnote" id="i2">Second inner.</aside> Unnamed outer.</li></ol>
            """)
        XCTAssertEqual(text.notes.mapValues(\.string), [
            "o1": "Outer.", "d1": "Outer.", "i1": "Inner.", "ip": "Inner.", "i2": "Second inner.",
        ])
        XCTAssertEqual(S.paragraphs(text), ["Text", "1.\tUnnamed outer."])
    }

    func testANotesFirstParagraphIdNamesTheWholeNote() throws {
        let text = try H.build("""
            <p><a epub:type="noteref" href="#p1">1</a></p>\
            <aside epub:type="footnote" id="n1"><div id="d1"><p id="p1">First.</p><p id="p2">Second.</p></div></aside>
            """)
        XCTAssertEqual(text.notes["n1"]?.string, "First.\nSecond.")
        XCTAssertEqual(text.notes["d1"]?.string, "First.\nSecond.")
        XCTAssertEqual(text.notes["p1"]?.string, "First.\nSecond.")
        // So does a later paragraph's: the aside is out of the flow, so a reference to `p2` has nothing else to show.
        XCTAssertEqual(text.notes["p2"]?.string, "First.\nSecond.")
        XCTAssertEqual(S.link("1", in: text), .note(href: "OPS/one.xhtml#p1"))
    }

    func testAPlainLinkToANoteOrIntoOneIsANoteLinkButALinkOutOfOneIsNot() throws {
        let text = try H.build("""
            <p id="ref">Ref <a href="#n1">to note</a> <a href="#inner">into note</a> <a href="#deep">deep in note</a></p>\
            <aside epub:type="endnote" id="n1"><p id="inner">Note <b><i id="deep">deep</i></b> <a href="#ref">out of note</a></p></aside>
            """)
        XCTAssertEqual(S.link("to note", in: text), .note(href: "OPS/one.xhtml#n1"))
        XCTAssertEqual(S.link("into note", in: text), .note(href: "OPS/one.xhtml#inner"))
        XCTAssertEqual(S.link("out of note", in: text), .internal(href: "OPS/one.xhtml#ref"))
        // Only the note and its children are recognised as targets; deeper elements navigate.
        XCTAssertEqual(S.link("deep in note", in: text), .internal(href: "OPS/one.xhtml#deep"))
    }

    func testANoteKeepsTheLanguageAroundIt() throws {
        let text = try H.build("""
            <section xml:lang="fr"><aside epub:type="footnote" id="n1">Une note <span lang="la">ibidem</span>.</aside></section>\
            <aside epub:type="footnote" id="n2">Plain.</aside>
            """)
        let french = try XCTUnwrap(text.notes["n1"]), plain = try XCTUnwrap(text.notes["n2"])
        XCTAssertEqual(french.attribute(InlineStyling.languageKey, at: 0, effectiveRange: nil) as? String, "fr")
        XCTAssertEqual(french.attribute(InlineStyling.languageKey, at: 9, effectiveRange: nil) as? String, "la")
        XCTAssertEqual(plain.attribute(InlineStyling.languageKey, at: 0, effectiveRange: nil) as? String, "en")
    }

    func testAFootnoteWhoseIdIsOnItsParagraphIsNotLost() throws {
        // `epub:type="footnote"` on an `aside` without an id of its own, the reference naming the paragraph inside.
        // The aside is taken out of the flow, so the note must be there to show from its reference.
        let text = try H.build("""
            <p>Claim<a epub:type="noteref" href="#fn1">1</a>.</p><aside epub:type="footnote"><p id="fn1">The note text.</p></aside>
            """)
        XCTAssertEqual(S.link("1", in: text), .note(href: "OPS/one.xhtml#fn1"))
        XCTAssertTrue(text.notes["fn1"]?.string == "The note text." || text.string.string.contains("The note text."),
                      "the note is neither in the flow nor captured for its reference: notes \(text.notes.keys.sorted())")
    }

    func testANoteWithoutAnIdIsCapturedUnderItsLeadingDescendantsIds() throws {
        // The reference may name the note's first paragraph, or the number that opens it, whatever kind of
        // note it is and however deep its first element lies.
        let text = try H.build("""
            <p id="r1">Claim<a epub:type="noteref" href="#p1">1</a>, again<a epub:type="noteref" href="#a2">2</a>.</p>\
            <aside epub:type="footnote"><div id="d1"><p id="p1"><a href="#p1">1.</a> First.</p><p id="p2">Second.</p></div></aside>\
            <aside role="doc-footnote"><p><a id="a2" href="#r1">2.</a> Numbered.</p></aside>\
            <section epub:type="endnotes"><ol><li epub:type="endnote"><p id="e3">In the flow.</p></li></ol></section>
            """)
        XCTAssertEqual(text.notes.mapValues(\.string), [
            "d1": "1. First.\nSecond.", "p1": "1. First.\nSecond.", "p2": "1. First.\nSecond.", "a2": "2. Numbered.", "e3": "In the flow.",
        ])
        // Footnotes leave the flow and endnotes stay in it, as they do with an id of their own.
        XCTAssertEqual(S.paragraphs(text), ["Claim1, again2.", "1.\tIn the flow."])
        XCTAssertEqual(text.anchors["p1"], H.location(of: "1.\tIn the flow.", in: text))
        // A link to an id the note is captured under is the note's own number; its backlink stays a link.
        XCTAssertNil(text.notes["p1"]?.attribute(.link, at: 0, effectiveRange: nil))
        let back = text.notes["a2"]?.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(back.flatMap(ReaderLink.init(url:)), .internal(href: "OPS/one.xhtml#r1"))
        S.assertTextMapContracts(text)
    }

    func testANoteWhoseOwnIdIsTakenIsCapturedUnderItsFirstParagraphsId() throws {
        let text = try H.build("""
            <p>Text<a epub:type="noteref" href="#p2">2</a></p><aside epub:type="footnote" id="n"><p id="p1">First.</p></aside>\
            <aside epub:type="footnote" id="n"><p id="p2">Second.</p></aside>
            """)
        XCTAssertEqual(text.notes.mapValues(\.string), ["n": "First.", "p1": "First.", "p2": "Second."])
    }

    // MARK: Notes named by an id that is not on their first-child chain

    func testAFootnoteNamedByALaterSiblingsIdIsCaptured() throws {
        // The id is on the note's second element, after a rule: the aside is hidden, so the note must be there to show.
        let text = try H.build("""
            <p>Claim<a epub:type="noteref" href="#fn1">1</a>.</p><aside epub:type="footnote"><hr/><p id="fn1">The note text.</p></aside>
            """)
        XCTAssertEqual(S.link("1", in: text), .note(href: "OPS/one.xhtml#fn1"))
        XCTAssertEqual(text.notes.mapValues(\.string), ["fn1": "—\nThe note text."])
        XCTAssertEqual(text.string.string, "Claim1.")
        S.assertTextMapContracts(text)
    }

    func testAFootnoteNamedByAnInlineAfterItsNumberIsCaptured() throws {
        let text = try H.build("""
            <p id="r">Claim<a epub:type="noteref" href="#fn1">1</a>, plainly<a href="#fn1">again</a>.</p>\
            <aside epub:type="footnote"><p><sup><a href="#r">1</a></sup> <span id="fn1">One.</span></p></aside>
            """)
        XCTAssertEqual(text.notes.mapValues(\.string), ["fn1": "1 One."])
        XCTAssertEqual(S.link("1", in: text), .note(href: "OPS/one.xhtml#fn1"))
        // So does a link without the `noteref` type: nothing of a hidden footnote is in the flow to navigate to.
        XCTAssertEqual(S.link("again", in: text), .note(href: "OPS/one.xhtml#fn1"))
        // The number links back to the reference, not to the note, and stays a link.
        let back = text.notes["fn1"]?.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(back.flatMap(ReaderLink.init(url:)), .internal(href: "OPS/one.xhtml#r"))
        XCTAssertEqual(text.string.string, "Claim1, plainlyagain.")
    }

    func testEveryIdInsideAFootnoteOutOfTheFlowNamesTheWholeNote() throws {
        // Two paragraphs with an id each, an id deep in inline markup and one on an empty anchor.
        let text = try H.build("""
            <p>A<a epub:type="noteref" href="#fn1">1</a> B<a epub:type="noteref" href="#fn2">2</a> C<a role="doc-noteref" href="#deep">3</a> \
            <a href="#">top</a></p>\
            <aside epub:type="footnote"><p id="fn1">One.</p><p id="fn2">Two.</p>\
            <blockquote><p>Three <em><b id="deep">deep</b></em><a id="mark"/><i id=""/>.</p></blockquote></aside>
            """)
        let whole = "One.\nTwo.\nThree deep."
        XCTAssertEqual(text.notes.mapValues(\.string), ["fn1": whole, "fn2": whole, "deep": whole, "mark": whole])
        for (word, id) in [("1", "fn1"), ("2", "fn2"), ("3", "deep")] {
            XCTAssertEqual(S.link(word, in: text), .note(href: "OPS/one.xhtml#\(id)"), id)
        }
        // An empty id names nothing: a link to `#` does not open the note that holds one
        // (`testAnEmptyIdNamesNoNoteAndALinkToTheTopOpensNone` has one on a note's leading chain).
        XCTAssertEqual(S.link("top", in: text), .internal(href: "OPS/one.xhtml#"))
        // The section is as it was: the note is out of the flow and its ids anchor where it stood.
        XCTAssertEqual(text.string.string, "A1 B2 C3 top")
        for id in ["fn1", "fn2", "deep", "mark"] { XCTAssertEqual(text.anchors[id], text.string.length, id) }
        S.assertTextMapContracts(text)
    }

    func testIdsInsideANestedNoteNameThatNoteAlone() throws {
        // The nested note has no id of its own and opens with a rule: its inner ids still name it, not the note around it.
        let text = try H.build("""
            <aside epub:type="footnote"><p id="o1">Outer.</p><div epub:type="footnote"><hr/><p id="i1">Inner <b id="i2">bold</b>.</p></div>\
            <p id="o2">More.</p></aside>
            """)
        XCTAssertEqual(text.notes.mapValues(\.string), [
            "o1": "Outer.\nMore.", "o2": "Outer.\nMore.", "i1": "—\nInner bold.", "i2": "—\nInner bold.",
        ])
    }

    func testANestedNoteThatNoIdNamesIsPartOfTheNoteAroundIt() throws {
        // No reference can open a note without an id anywhere in it, so it is not left out of the note it is nested
        // in. A named note nested in it is still a note of its own.
        let text = try H.build("""
            <p>Text</p><aside epub:type="footnote" id="fn1"><p epub:type="footnote">Text of the inner note.</p></aside>\
            <aside epub:type="footnote" id="fn2"><p>Outer.</p><div epub:type="footnote"><p>Unnamed.</p>\
            <aside epub:type="footnote" id="fn3">Named, deeper.</aside></div><p>Rest.</p></aside>\
            <div epub:type="footnote" id="d1"><p>In the flow.</p><aside epub:type="footnote">Out of it.</aside></div>
            """)
        XCTAssertEqual(text.notes.mapValues(\.string), [
            "fn1": "Text of the inner note.", "fn2": "Outer.\nUnnamed.\nRest.", "fn3": "Named, deeper.",
            "d1": "In the flow.\nOut of it.",
        ])
        // In the flow a footnote aside is hidden whether or not anything names it.
        XCTAssertEqual(S.paragraphs(text), ["Text", "In the flow."])
    }

    func testANoteWithNothingOfItsOwnShowsTheNotesNestedInIt() throws {
        // A note that is only another note (two elements marking one note, or a wrapper round several) would be
        // captured as empty, and its reference would open an empty popover.
        let text = try H.build("""
            <p id="r">Text<a epub:type="noteref" href="#fn1">1</a></p>\
            <aside epub:type="footnote" id="fn1"><div role="doc-footnote" id="inner"><p>The note.</p></div></aside>\
            <aside epub:type="footnote" id="fn2"> <a href="#r" epub:type="backlink">↩</a>\
            <aside epub:type="footnote" id="a">First.</aside><aside epub:type="footnote" id="b">Second.</aside></aside>\
            <aside epub:type="footnote" id="x"><aside epub:type="footnote" id="y"><aside epub:type="footnote" id="z">Deep.</aside></aside></aside>\
            <aside epub:type="footnote" id="pic"><img src="picture.png" alt="Pic"/><aside epub:type="footnote" id="cap">Caption.</aside></aside>
            """)
        XCTAssertEqual(text.notes.mapValues(\.string), [
            "fn1": "The note.", "inner": "The note.", "fn2": "First.\nSecond.", "a": "First.", "b": "Second.",
            "x": "Deep.", "y": "Deep.", "z": "Deep.",
            // A note with anything of its own, an image included, still leaves out the notes nested in it.
            "pic": "[Pic]", "cap": "Caption.",
        ])
        XCTAssertEqual(S.link("1", in: text), .note(href: "OPS/one.xhtml#fn1"))
    }

    func testAnIdUsedTwiceNamesOneNote() throws {
        // A note that carries the id itself or on a leading descendant comes before one that holds it elsewhere
        // (`x`); among those, the first in the document (`y`). An element outside every note does not take the id
        // from a note (`z`), though the id still anchors at that element.
        let text = try H.build("""
            <aside epub:type="footnote" id="a"><p>One.</p><p id="x">Two.</p></aside><aside epub:type="footnote" id="x">Three.</aside>\
            <aside epub:type="footnote"><hr/><p id="y">Four.</p></aside><aside epub:type="footnote" id="b"><p>Five.</p><p id="y">Six.</p></aside>\
            <p id="z">In the flow.</p><aside epub:type="footnote"><p>Seven.</p><p id="z">Eight.</p></aside>
            """)
        XCTAssertEqual(text.notes.mapValues(\.string), [
            "a": "One.\nTwo.", "x": "Three.", "y": "—\nFour.", "b": "Five.\nSix.", "z": "Seven.\nEight.",
        ])
        XCTAssertEqual(text.anchors["z"], 0)
    }

    func testALinkInANoteToAnotherPartOfTheSameNoteIsNotALink() throws {
        let text = try H.build("""
            <p id="r">Text<a epub:type="noteref" href="#n1">1</a></p>\
            <aside epub:type="footnote" id="n1"><p><a href="#n1">1.</a> See <a href="#later">below</a>, \
            <a epub:type="noteref" href="#inner">the note within</a> and <a href="#r">back</a>.</p>\
            <p id="later">Later.</p><aside epub:type="footnote" id="inner">Within.</aside></aside>
            """)
        let note = try XCTUnwrap(text.notes["n1"])
        XCTAssertEqual(note.string, "1. See below, the note within and back.\nLater.")
        func link(_ word: String) -> ReaderLink? {
            (note.attribute(.link, at: (note.string as NSString).range(of: word).location, effectiveRange: nil) as? URL)
                .flatMap(ReaderLink.init(url:))
        }
        // The note is shown whole, so a link to any id that names it leads nowhere new; one to a note nested in it,
        // or out of it, is still a link.
        XCTAssertNil(link("1."))
        XCTAssertNil(link("below"))
        XCTAssertEqual(link("the note within"), .note(href: "OPS/one.xhtml#inner"))
        XCTAssertEqual(link("back"), .internal(href: "OPS/one.xhtml#r"))
    }

    func testNotesInTableCellsAndListItemsAreNamedByAnyIdInside() throws {
        // With the table as tabbed rows, and drawn by the rich-content factory (its cells have a writer of their own).
        for rich in [PlaceholderRichContent() as any RichContentFactory, BuilderRecordingRich(rendersTables: true)] {
            let text = try H.build("""
                <p>Text</p><table><tr><td>cell<aside epub:type="footnote"><p>Lead.</p><p id="t1">In a cell.</p></aside></td><td>other</td></tr></table>\
                <ul><li>item<aside epub:type="footnote"><p>In an <span id="l1">item</span>.</p><p id="l2">Twice.</p></aside></li></ul>\
                <aside epub:type="footnote" id="n1"><table><tr><td>Cell<aside epub:type="footnote">Unnamed in a cell.</aside></td>\
                <td>Other<aside epub:type="footnote" id="n2">Named in a cell.</aside></td></tr></table></aside>
                """, rich: rich)
            XCTAssertEqual(text.notes["t1"]?.string, "Lead.\nIn a cell.")
            XCTAssertEqual(text.notes["l1"]?.string, "In an item.\nTwice.")
            XCTAssertEqual(text.notes["l2"]?.string, "In an item.\nTwice.")
            XCTAssertEqual(text.notes["n2"]?.string, "Named in a cell.")
            // A footnote that no id names, in a cell of a note's table, is part of that note; a named one is not.
            let outer = try XCTUnwrap(text.notes["n1"]?.string)
            XCTAssertTrue(outer.contains("Unnamed in a cell."), outer)
            XCTAssertFalse(outer.contains("Named in a cell."), outer)
            XCTAssertEqual(Set(text.notes.keys), ["t1", "l1", "l2", "n1", "n2"])
            XCTAssertFalse(text.string.string.contains("In a cell."))
        }
    }

    func testANoteInTheFlowIsNamedOnlyByItsLeadingIds() throws {
        // The endnote can be read where it is, so a reference to its second paragraph finds no note and navigates
        // there (`NativeSession` navigates when a note link has no note), as it did before a hidden footnote took
        // every id inside it.
        let text = try H.build("""
            <p>Claim<a epub:type="noteref" href="#e1b">1</a>, plainly<a href="#e1b">again</a>.</p>\
            <section epub:type="endnotes"><ol><li epub:type="endnote"><p>First.</p><p id="e1b">Second.</p></li>\
            <li id="e2"><p>Not a note.</p><p id="e2b">Its second.</p></li></ol></section>\
            <div epub:type="note" id="o"><p>Outer.</p><div epub:type="note"><p>Lead.</p><p id="i">Inner.</p></div></div>
            """)
        // A note nested in a note in the flow, with no leading id, is named by nothing: it is part of the note around it.
        XCTAssertEqual(text.notes.mapValues(\.string), ["o": "Outer.\nLead.\nInner."])
        XCTAssertEqual(S.paragraphs(text), ["Claim1, plainlyagain.", "1.\tFirst.", "Second.", "2.\tNot a note.", "Its second.",
                                            "Outer.", "Lead.", "Inner."])
        XCTAssertEqual(text.anchors["e1b"], H.location(of: "Second.", in: text))
        XCTAssertEqual(S.link("1", in: text), .note(href: "OPS/one.xhtml#e1b"))
        // A link without the `noteref` type to a note's child was a note link already, and still is.
        XCTAssertEqual(S.link("again", in: text), .note(href: "OPS/one.xhtml#e1b"))
        S.assertTextMapContracts(text)
    }

    func testAReferenceIntoANoteElementInTheFlowThatHoldsSeveralNotesFindsNoNoteAndNavigates() throws {
        // An endnotes page marked up as one note. Every item can be read where it is, so a reference to the
        // seventeenth navigates to it rather than opening all thirty from the top.
        let items = (1...30).map { "<li id=\"n\($0)\"><p>Endnote \($0).</p></li>" }.joined()
        let paragraphs = (1...30).map { "<p id=\"n\($0)\">Endnote \($0).</p>" }.joined()
        // With each shape: the paragraph the reference goes to, and whether a link without the `noteref` type is a
        // note link too (when the item is a child of the note element).
        let shapes: [(markup: String, item: String, plainIsNoteLink: Bool)] = [
            ("<section epub:type=\"rearnote\"><h2>Notes</h2><ol>\(items)</ol></section>", "17.\tEndnote 17.", false),
            ("<div class=\"footnotes\" epub:type=\"footnote\">\(paragraphs)</div>", "Endnote 17.", true),
            ("<aside epub:type=\"endnote\">\(paragraphs)</aside>", "Endnote 17.", true),
            ("<section role=\"doc-endnote\"><ol>\(items)</ol></section>", "17.\tEndnote 17.", false),
            ("<ol epub:type=\"endnote\">\(items)</ol>", "17.\tEndnote 17.", true),
            ("<section epub:type=\"endnotes endnote\"><ol>\(items)</ol></section>", "17.\tEndnote 17.", false),
        ]
        for (markup, item, plainIsNoteLink) in shapes {
            let text = try H.build("<p>Claim<a epub:type=\"noteref\" href=\"#n17\">ref</a>, and <a href=\"#n17\">also</a>.</p>" + markup)
            // No item's id names the element, the first's included, though it is on the element's leading chain
            // (`testAReferenceToTheFirstOfSeveralItemsInANoteInTheFlowNavigatesToo`).
            XCTAssertTrue(text.notes.isEmpty, "\(text.notes.keys.sorted()) in \(markup)")
            XCTAssertEqual(S.link("ref", in: text), .note(href: "OPS/one.xhtml#n17"), markup)
            XCTAssertEqual(S.link("also", in: text), plainIsNoteLink ? .note(href: "OPS/one.xhtml#n17") : .internal(href: "OPS/one.xhtml#n17"), markup)
            XCTAssertEqual(text.anchors["n17"], H.location(of: item, in: text), markup)
            XCTAssertEqual(S.paragraphs(text).filter { $0.hasSuffix("Endnote 17.") }, [item], markup)
        }
    }

    func testAReferenceToTheFirstOfSeveralItemsInANoteInTheFlowNavigatesToo() throws {
        // The first item's id is on the note element's leading chain, and it named the whole element: a reference to
        // the first of thirty endnotes opened all thirty (https://github.com/vocaro/EPUBLib/issues/284). Items are
        // elements of one name, each named itself or by its first element, in an element with no text of its own.
        func items(_ item: (Int) -> String) -> String { (1...3).map(item).joined(separator: "\n") }
        let shapes = [
            "<div class='footnotes' epub:type='footnote'>" + items { "<p id='n\($0)'>Endnote \($0).</p>" } + "</div>",
            "<aside epub:type='endnote'>" + items { "<p><a id='n\($0)' href='#r'>\($0).</a> Endnote \($0).</p>" } + "</aside>",
            "<aside epub:type='endnote'>" + items { "<p><a name='n\($0)'/>Endnote \($0).</p>" } + "</aside>",
            "<section role='doc-endnote'><ol>" + items { "<li id='n\($0)'><p>Endnote \($0).</p></li>" } + "</ol></section>",
            "<ol epub:type='endnote'>" + items { "<li><p id='n\($0)'>Endnote \($0).</p></li>" } + "</ol>",
            "<dl epub:type='footnote'>" + items { "<dt id='n\($0)'>\($0)</dt><dd>Endnote \($0).</dd>" } + "</dl>",
        ]
        for markup in shapes {
            let text = try H.build("<p id='r'>Claim<a epub:type='noteref' href='#n1'>first</a>.</p>" + markup)
            XCTAssertTrue(text.notes.isEmpty, "\(text.notes.keys.sorted()) in \(markup)")
            // A note link that finds no note navigates (`NativeSession`), to where the first item is shown.
            XCTAssertEqual(S.link("first", in: text), .note(href: "OPS/one.xhtml#n1"), markup)
            let anchor = try XCTUnwrap(text.anchors["n1"], markup)
            XCTAssertGreaterThan(anchor, H.location(of: "Claimfirst.", in: text), markup)
            XCTAssertLessThan(anchor, H.location(of: "Endnote 1.", in: text) + 1, markup)
        }
    }

    func testANoteInTheFlowStaysNamedByItsLeadingIdsWhenNoItemLikeTheirsFollows() throws {
        // An id after the note's number in the same paragraph is among the paragraph's words; a page break between
        // its paragraphs, and paragraphs after its heading, are not items like the first. A footnote hidden from the
        // flow is named by every id inside it, its first item's among them. A row's cells are the parts of one note
        // (`testAFootnoteInsideATablePartAndATablePartWithItsOwnIdAreNamedAsBefore`).
        let text = try H.build("""
            <p id="r">Claim.</p><div epub:type="footnote"><p><a id="a1" href="#r">1</a> See <a id="a2" href="#r">the claim</a>.</p></div>\
            <aside epub:type="endnote"><p id="b1">Lead.</p><span epub:type="pagebreak" id="page9"/><p>More.</p></aside>\
            <aside epub:type="endnote"><h3 id="c1">Notes</h3><p id="c2">One.</p><p id="c3">Two.</p></aside>\
            <aside epub:type="footnote"><p id="f1">Hidden one.</p><p id="f2">Hidden two.</p></aside>
            """)
        XCTAssertEqual(text.notes.mapValues(\.string), [
            "a1": "1 See the claim.", "b1": "Lead.\nMore.", "c1": "Notes\nOne.\nTwo.",
            "f1": "Hidden one.\nHidden two.", "f2": "Hidden one.\nHidden two.",
        ])
    }

    func testAnEmptyIdNamesNoNoteAndALinkToTheTopOpensNone() throws {
        // `id=""` on a note or on its leading descendant captured the note under the key `""`, so a link to `#`, the
        // top of the document, opened it (https://github.com/vocaro/EPUBLib/issues/284). An id further down the
        // leading chain still names its note.
        let text = try H.build("""
            <p><a href="#">top</a> <a epub:type="noteref" href="#fn1">ref</a></p>\
            <aside epub:type="endnote" id=""><p>An endnote.</p></aside><div epub:type="footnote"><p id="">In the flow.</p></div>\
            <aside epub:type="footnote"><p id="">Out of the flow.</p></aside><aside epub:type="footnote" id=""><p id="fn1">Named.</p></aside>
            """)
        XCTAssertEqual(text.notes.mapValues(\.string), ["fn1": "Named."])
        XCTAssertEqual(S.link("top", in: text), .internal(href: "OPS/one.xhtml#"))
        XCTAssertEqual(S.link("ref", in: text), .note(href: "OPS/one.xhtml#fn1"))
    }

    func testAListItemThatShowsNothingInANoteHasNoMarker() throws {
        // Each item holds only a note captured on its own, so the list showed bare bullets, "• \n• "
        // (https://github.com/vocaro/EPUBLib/issues/284); with nothing of its own the note now shows the notes in it.
        // An item left empty, and an outer item whose nested items show nothing, lose their markers too. Ordered
        // items keep their numbers.
        let text = try H.build("""
            <p>Text</p><aside epub:type="footnote" id="list"><ul><li><aside epub:type="footnote" id="a">First.</aside></li>\
            <li><aside epub:type="footnote" id="b">Second.</aside></li></ul></aside>\
            <aside epub:type="footnote" id="mixed"><ol><li>One.</li><li><aside epub:type="footnote" id="c">Apart.</aside></li>\
            <li> </li><li>Four.</li></ol></aside>\
            <aside epub:type="footnote" id="nested"><ul><li><ul><li><aside epub:type="footnote" id="d">Deep.</aside></li></ul></li>\
            <li><ul><li>Inner.</li></ul></li><li>Last.</li></ul></aside>
            """)
        XCTAssertEqual(text.notes["list"]?.string, "• First.\n• Second.")
        XCTAssertEqual(text.notes["mixed"]?.string, "1. One.\n4. Four.")
        XCTAssertEqual(text.notes["nested"]?.string, "• \n◦ Inner.\n• Last.")
        for (id, note) in [("a", "First."), ("b", "Second."), ("c", "Apart."), ("d", "Deep.")] { XCTAssertEqual(text.notes[id]?.string, note) }
        // In the flow an empty item keeps its marker, as a browser draws it.
        XCTAssertEqual(S.paragraphs(try H.build("<ul><li> </li><li>x</li></ul>")), ["•\t", "•\tx"])
    }

    func testANoteThatShowsNothingIsNotKeptSoItsReferenceNavigates() throws {
        // An empty or white-space note opened an empty popover (https://github.com/vocaro/EPUBLib/issues/284). With no
        // note under its id, a reference to it navigates (`NativeSession`).
        let text = try H.build("""
            <p id="r">Claim<a epub:type="noteref" href="#e1">one</a> <a epub:type="noteref" href="#e3">three</a> \
            <a href="#e4">four</a>.</p><aside epub:type="footnote" id="e1"></aside><aside epub:type="footnote" id="e2">  </aside>\
            <aside epub:type="footnote" id="e3"><a href="#r" epub:type="backlink">↩</a></aside>\
            <aside epub:type="endnote" id="e4"><p class="gone">Hidden by the book.</p></aside>\
            <aside epub:type="footnote" id="e5"><aside epub:type="footnote" id="e6"> </aside></aside>\
            <aside epub:type="footnote" id="kept"><img src="picture.png" alt="Pic"/></aside>
            """, rules: [(".gone", { $0.display = .none })])
        XCTAssertEqual(text.notes.mapValues(\.string), ["kept": "[Pic]"])
        XCTAssertEqual(S.link("one", in: text), .note(href: "OPS/one.xhtml#e1"))
        XCTAssertEqual(S.link("three", in: text), .note(href: "OPS/one.xhtml#e3"))
        XCTAssertEqual(S.link("four", in: text), .note(href: "OPS/one.xhtml#e4"))
    }

    func testALaterIdNamesANoteExactlyWhenTheFlowLeavesTheNoteOut() throws {
        // Every kind of note element, each with an id on its second paragraph only. The writer decides which are out
        // of the flow, and those are the ones a later id names: what is hidden can be shown, what is not navigates.
        let kinds = ["aside epub:type='footnote'", "aside epub:type='note'", "aside epub:type='rearnote'", "div role='doc-footnote'",
                     "aside epub:type='footnote' role='doc-endnote'", "aside epub:type='endnote'", "div role='doc-endnote'",
                     "div epub:type='footnote'", "section epub:type='rearnote'", "li epub:type='footnote'", "aside epub:type='sidebar'"]
        func notes(_ wrap: (String) -> String) -> String {
            kinds.enumerated().map { index, kind in
                wrap("<\(kind)><p>Lead \(index).</p><p id='k\(index)'>Later \(index).</p></\(kind.prefix { $0 != " " })>")
            }.joined()
        }
        // In the body, in an endnotes container (where every note stays in the flow) and in a footnote (where none does).
        let text = try H.build(notes { $0 } + "<section epub:type='endnotes'>" + notes { $0.replacingOccurrences(of: "id='k", with: "id='e") }
            + "</section><aside epub:type='footnote'>" + notes { $0.replacingOccurrences(of: "id='k", with: "id='f") } + "</aside>")
        var hidden = 0
        for prefix in ["k", "e", "f"] {
            for index in kinds.indices {
                let id = "\(prefix)\(index)"
                let element = try XCTUnwrap(text.document.element(id: id))
                let shown = text.map.spans.contains { $0.node > element.order && $0.node <= element.subtreeEnd }
                XCTAssertEqual(text.notes[id] != nil, !shown, "\(id): \(kinds[index])")
                if !shown { hidden += 1; XCTAssertTrue(text.notes[id]?.string.contains("Later \(index).") == true, id) }
            }
        }
        // The four footnote kinds in the body, and everything in the footnote.
        XCTAssertEqual(hidden, 4 + kinds.count)

        // The twelfth kind is the exception: a table part typed as a footnote. A table drawn as a grid shows the part
        // whatever its type, and the ids are settled without knowing how its table will be shown, so a later id names
        // the part only where a footnote around it is hidden. This factory draws no table, so in the body the writer
        // leaves the part out all the same, and its later id names nothing there (doc/native-viewer.md, Footnotes).
        let parts = Self.tableParts.map(\.name)
        func tables(_ prefix: String) -> String { parts.map { Self.table(typing: $0, later: prefix + $0, deep: prefix + $0 + "d") }.joined() }
        let tabled = try H.build(tables("k") + "<section epub:type='endnotes'>" + tables("e") + "</section><aside epub:type='footnote'>"
            + tables("f") + "</aside>")
        for (prefix, expected) in [("k", "hidden, unnamed"), ("e", "shown, unnamed"), ("f", "hidden, named")] {
            for part in parts {
                let id = prefix + part
                let element = try XCTUnwrap(tabled.document.element(id: id))
                let shown = tabled.map.spans.contains { $0.node > element.order && $0.node <= element.subtreeEnd }
                // A column holds nothing to show, in the flow or out of it, and a note that shows nothing is not kept.
                let columns = part == "colgroup" || part == "col"
                XCTAssertEqual("\(shown ? "shown" : "hidden"), \(tabled.notes[id] != nil ? "named" : "unnamed")",
                               columns ? "hidden, unnamed" : expected, "\(id): \(part) typed as a footnote")
            }
        }
    }

    // MARK: Table parts typed as footnotes

    /// The elements a table is made of, which the table builder lays out by name (`TableContent`). With each: where a
    /// table drawn as a grid shows the later text of `table(typing:)`, and whether a link without the `noteref` type
    /// to the later element is a note link (when that element is a child of the part).
    private static let tableParts: [(name: String, shown: String, plainIsNoteLink: Bool)] = [
        ("td", "in a cell", true), ("th", "in a cell", true), ("tr", "in a cell", true), ("tbody", "in a cell", false),
        ("thead", "in a cell", false), ("tfoot", "in a cell", false), ("caption", "in the flow", true),
        ("colgroup", "nowhere", true), ("col", "nowhere", true),
    ]

    /// A table of two columns with one part typed as a footnote. Inside that part an id is on an element after its
    /// first (`later`) and on one inside that element (`deep`): neither is on the part's leading chain.
    private static func table(typing part: String, later: String = "later", deep: String = "deep") -> String {
        let blocks = "<p>Lead.</p><p id='\(later)'>Later <b id='\(deep)'>deep</b>.</p>"
        let cells = "<td>Lead.</td><td id='\(later)'>Later <b id='\(deep)'>deep</b>.</td>"
        let plain = "<tr><td>a</td><td>b</td></tr>"
        switch part {
        case "td", "th": return "<table><tr><td>1.</td><\(part) role='doc-footnote'>\(blocks)</\(part)></tr></table>"
        case "tr": return "<table><tr role='doc-footnote'>\(cells)</tr></table>"
        case "tbody": return "<table><tbody role='doc-footnote'><tr>\(cells)</tr></tbody></table>"
        case "thead": return "<table><thead role='doc-footnote'><tr>\(cells)</tr></thead><tbody>\(plain)</tbody></table>"
        case "tfoot": return "<table><tbody>\(plain)</tbody><tfoot role='doc-footnote'><tr>\(cells)</tr></tfoot></table>"
        case "caption": return "<table><caption role='doc-footnote'>\(blocks)</caption>\(plain)</table>"
        case "colgroup": return "<table><colgroup role='doc-footnote'><col/><col id='\(later)'><i id='\(deep)'/></col></colgroup>\(plain)</table>"
        default: return "<table><col role='doc-footnote'><i/><i id='\(later)'><b id='\(deep)'/></i></col><col/>\(plain)</table>"
        }
    }

    /// What a reference into a table meets: where the table shows `phrase`, the ids the section's notes are under, and
    /// the kind of link each word is.
    private func facts(_ text: SectionText, showing phrase: String, links words: [String]) -> [String] {
        let inCell = TableCoverage.tables(in: text.string).contains { $0.cells.contains { $0.content.string.contains(phrase) } }
        let shown = inCell ? "in a cell" : text.string.string.contains(phrase) ? "in the flow" : "nowhere"
        return ["shown \(shown)", "keys " + text.notes.keys.sorted().map(\.string).joined(separator: " ")] + words.map { word in
            switch S.link(word, in: text) {
            case .note(let href)?: "\(word): note link to \(href)"
            case .internal(let href)?: "\(word): internal link to \(href)"
            case .external(let href)?: "\(word): external link to \(href)"
            case nil: "\(word): no link"
            }
        }
    }

    func testAReferenceIntoATableCellOrRowGroupTypedAsAFootnoteFindsNoNoteAndNavigates() throws {
        // The table builder draws a grid's parts without asking whether one is a footnote, so the typed cell is on the
        // page and a reference to its second paragraph navigates to the table (`NativeSession` navigates when a note
        // link has no note), as it did before a hidden footnote took every id inside it.
        let cell = try S.styled("""
            <p>Claim<a epub:type="noteref" href="#n17">noteref</a>, <a href="#n17">plain</a>.</p>\
            <table><tr><td>17.</td><td role="doc-footnote"><p>Lead of the cell.</p><p id="n17">Endnote number 17 here.</p></td></tr></table>
            """)
        XCTAssertEqual(facts(cell, showing: "Endnote number 17 here.", links: ["noteref", "plain"]), [
            "shown in a cell", "keys ", "noteref: note link to OPS/one.xhtml#n17", "plain: note link to OPS/one.xhtml#n17",
        ])

        // An endnotes table whose row group is typed as one footnote. No row's id names the group, the first's
        // included: a reference to the seventeenth or the thirtieth row navigates to the table rather than opening
        // all thirty from the top, and a plain link to a cell of a row is an internal link.
        let rows = (1...30).map { "<tr id=\"n\($0)\"><td>\($0).</td><td id=\"c\($0)\">Endnote number \($0) here.</td></tr>" }.joined()
        let group = try S.styled("""
            <p>Claim<a epub:type="noteref" href="#n17">seventeenth</a>, <a epub:type="noteref" href="#n30">thirtieth</a>, \
            <a href="#n17">plain</a>, <a href="#c17">cell</a>.</p><table><tbody role="doc-footnote">\(rows)</tbody></table>
            """)
        XCTAssertEqual(facts(group, showing: "Endnote number 17 here.", links: ["seventeenth", "thirtieth", "plain", "cell"]), [
            "shown in a cell", "keys ", "seventeenth: note link to OPS/one.xhtml#n17", "thirtieth: note link to OPS/one.xhtml#n30",
            "plain: note link to OPS/one.xhtml#n17", "cell: internal link to OPS/one.xhtml#c17",
        ])
    }

    func testALaterIdInATablePartTypedAsAFootnoteNamesNothingHoweverItsTableIsShown() throws {
        // With every part a table is made of: no id past the part's leading ones is a key, and the links are the ones
        // a note that stays in the flow gets. A link deeper than a child of the part is an internal link.
        let references = "<p>Claim<a epub:type='noteref' href='#later'>noteref</a>, <a href='#later'>plain</a>, <a href='#deep'>deeper</a>.</p>"
        for (part, shown, plainIsNoteLink) in Self.tableParts {
            let expected = ["keys ", "noteref: note link to OPS/one.xhtml#later",
                            "plain: \(plainIsNoteLink ? "note" : "internal") link to OPS/one.xhtml#later",
                            "deeper: internal link to OPS/one.xhtml#deep"]
            let body = references + Self.table(typing: part)
            // Drawn as a grid by the table builder, the part is on the page.
            XCTAssertEqual(facts(try S.styled(body), showing: "Later", links: ["noteref", "plain", "deeper"]), ["shown " + shown] + expected, part)
            // As tabbed rows, where no table is drawn, the writer leaves the part out. Its later ids name nothing
            // there either: the ids do not depend on how the table is shown.
            XCTAssertEqual(facts(try H.build(body), showing: "Later", links: ["noteref", "plain", "deeper"]), ["shown nowhere"] + expected, part)
        }
        // So too in a table of one column, which flows as text.
        let column = "<table><tr><td role='doc-footnote'><p>Lead.</p><p id='later'>Later <b id='deep'>deep</b>.</p></td></tr></table>"
        XCTAssertEqual(facts(try S.styled(references + column), showing: "Later", links: ["noteref", "plain", "deeper"]), [
            "shown nowhere", "keys ", "noteref: note link to OPS/one.xhtml#later", "plain: note link to OPS/one.xhtml#later",
            "deeper: internal link to OPS/one.xhtml#deep",
        ])
    }

    func testAFootnoteInsideATablePartAndATablePartWithItsOwnIdAreNamedAsBefore() throws {
        // What is inside a typed part is counted as anywhere else. A footnote `aside` in a typed cell is hidden by the
        // writer, which renders the cell's content, and takes every id inside it; the cell's own later id names nothing.
        let nested = try S.styled("""
            <p>Text</p><table><tr><td>1.</td><td role="doc-footnote"><p>Cell lead.</p>\
            <aside epub:type="footnote"><p>Aside lead.</p><p id="a2">Aside later.</p></aside><p id="c2">Cell later.</p></td></tr></table>
            """)
        XCTAssertEqual(nested.notes.mapValues(\.string), ["a2": "Aside lead.\nAside later."])
        XCTAssertEqual(TableCoverage.tables(in: nested.string).first?.cells.map(\.text), ["1.", "Cell lead. Cell later."])

        // A part that carries an id of its own, or on a leading descendant, is a note under that id as it always was:
        // each typed row opens alone. An id further into a row names nothing.
        let rows = try S.styled("""
            <p>Text</p><table><tr role="doc-footnote" id="r1"><td>1.</td><td>The first note.</td></tr>\
            <tr role="doc-footnote"><td id="r2">2.</td><td id="r2b">The second note.</td></tr></table>
            """)
        XCTAssertEqual(rows.notes.mapValues { $0.string.split(whereSeparator: \.isWhitespace).joined(separator: " ") },
                       ["r1": "1. The first note.", "r2": "2. The second note."])

        // Inside a footnote that is hidden, a typed part is hidden with it, like any note there, and takes its later ids.
        let hidden = try S.styled("<p>Text</p><aside epub:type='footnote' id='fn'>" + Self.table(typing: "td") + "</aside>")
        XCTAssertEqual(hidden.notes["later"]?.string, "Lead.\nLater deep.")
        XCTAssertEqual(hidden.notes["deep"]?.string, "Lead.\nLater deep.")
    }

    func testAPlainLinkToAnythingInsideAHiddenFootnoteShowsTheNote() throws {
        let text = try H.build("""
            <p>See <a href="#deep">deep</a>, <a href="#within">within</a> and <a href="#flow">flow</a>.</p>\
            <aside epub:type="footnote"><p>A note with <em><span id="deep">a deep target</span></em>.</p>\
            <div epub:type="endnote"><p>An endnote <b id="within">within</b> it.</p></div></aside>\
            <aside epub:type="endnote"><p>In the flow, <b id="flow">deep</b>.</p></aside>
            """)
        XCTAssertEqual(S.link("deep", in: text), .note(href: "OPS/one.xhtml#deep"))
        // A note nested in a hidden footnote is hidden with it.
        XCTAssertEqual(S.link("within", in: text), .note(href: "OPS/one.xhtml#within"))
        // A note in the flow has somewhere to go: a plain link deep into it navigates, as before.
        XCTAssertEqual(S.link("flow", in: text), .internal(href: "OPS/one.xhtml#flow"))
        XCTAssertEqual(text.notes.mapValues(\.string), [
            "deep": "A note with a deep target.", "within": "An endnote within it.", "flow": "In the flow, deep.",
        ])
        XCTAssertEqual(S.paragraphs(text), ["See deep, within and flow.", "In the flow, deep."])
    }

    func testAFootnoteWithNoIdAnywhereInItStaysHiddenAndUncaptured() throws {
        // Nothing can refer to it. A footnote `aside` is out of the flow whether or not anything does
        // (doc/native-viewer.md, Footnotes).
        let text = try H.build("<p>x</p><aside epub:type='footnote'><p>Unnamed.</p><aside epub:type='footnote'>Nested.</aside></aside><p>y</p>")
        XCTAssertEqual(S.paragraphs(text), ["x", "y"])
        XCTAssertTrue(text.notes.isEmpty)
    }

    /// EPUB 3.3 6.1.3.1: `epub:type` "MUST NOT be used on the head element or metadata content",
    /// and 6.2.3 allows it in SVG only on renderable elements. RS 10: a reading system "MUST
    /// ignore the terms" on any other element. Such an element is no note however it is typed,
    /// nor by a DPUB-ARIA role, which ARIA in HTML allows on none of the HTML ones; a link to it
    /// or into it is an ordinary link. What the head holds is in the head, valid there or not.
    func testElementsThatMayNotCarryStructuralSemanticsAreNoNotes() throws {
        let document = try ContentDocument.parse(Data("""
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">\
            <head epub:type="footnote" id="hd"><title epub:type="footnote" id="t">Title</title><meta epub:type="footnote" id="m" name="a" content="b"/>\
            <style epub:type="footnote" id="hs">p {}</style><script role="doc-footnote" id="hr">var y;</script>\
            <aside epub:type="footnote" id="ha">Misplaced in the head.</aside></head><body>\
            <p><a href="#t">title</a> <a href="#ns">noscript</a> <a href="#tb">template</a> <a href="#sd">desc</a> <a href="#st">drawn</a></p>\
            <noscript epub:type="footnote" id="ns">Shown without scripting.</noscript><template epub:type="footnote" id="tp"><b id="tb">t</b></template>\
            <script epub:type="footnote" id="sc">var x;</script><style role="doc-endnote" id="bs">p {}</style>\
            <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><desc epub:type="footnote" id="sd">A description.</desc>\
            <title epub:type="footnote" id="svt">An SVG title.</title><defs epub:type="footnote" id="df"><text>Defined.</text></defs>\
            <text epub:type="footnote" id="st" y="5">Drawn.</text></svg></body></html>
            """.utf8), path: "OPS/one.xhtml")
        let text = H.build(document: document)
        XCTAssertEqual(text.notes.mapValues(\.string), ["st": "Drawn."], "a renderable SVG element may be a note")
        XCTAssertEqual(S.paragraphs(text), ["title noscript template desc drawn", "Shown without scripting."])
        XCTAssertEqual(S.link("title", in: text), .internal(href: "OPS/one.xhtml#t"))
        XCTAssertEqual(S.link("noscript", in: text), .internal(href: "OPS/one.xhtml#ns"))
        XCTAssertEqual(S.link("template", in: text), .internal(href: "OPS/one.xhtml#tb"))
        XCTAssertEqual(S.link("desc", in: text), .internal(href: "OPS/one.xhtml#sd"))
        XCTAssertEqual(S.link("drawn", in: text), .note(href: "OPS/one.xhtml#st"))
    }

    /// A note's content is counted in the section's report once (#258). The section counts it
    /// where it shows it, in the flow or in a table's cell; the note's own rendering adds to the
    /// report only what the section shows nowhere else: a footnote hidden from the flow, a note
    /// in hidden content.
    func testWhatANoteHoldsIsReportedOnce() throws {
        let text = try H.build("""
            <p>Text</p><aside epub:type="endnote" id="e"><input type="text"/><img src="https://example.com/e.png" alt=""/></aside>\
            <aside epub:type="footnote" id="f"><p>Foot <select><option>o</option></select></p></aside>\
            <div hidden=""><aside epub:type="endnote" id="h"><textarea>t</textarea></aside></div>\
            <table><tr><td><aside epub:type="endnote" id="c">Cell <button>b</button></aside></td><td>x</td></tr></table>\
            <div epub:type="endnote" id="w"><aside epub:type="endnote" id="w1"><p><input type="checkbox"/>Wrapped.</p></aside></div>
            """, rich: BuilderRecordingRich(rendersTables: true))
        XCTAssertEqual(text.report.unsupportedElements, ["input": 2, "select": 1, "textarea": 1, "button": 1])
        XCTAssertEqual(text.report.remoteResourcesRefused, 1)
        XCTAssertEqual(text.notes["w"]?.string, "Wrapped.", "a note with nothing of its own shows the one nested in it")
    }

    // MARK: Anchors

    func testAnchorsOnEmptyInlineAndBlockElements() throws {
        let text = try H.build("<p id='a'>A<a id='e'/>B<span id='s'></span></p><div id='gap'></div><p id='z'>Z</p><div id='tail'/>")
        XCTAssertEqual(text.string.string, "AB\nZ")
        XCTAssertEqual(text.anchors, ["a": 0, "e": 1, "s": 3, "gap": 3, "z": 3, "tail": 4])
    }

    func testAnchorsAroundCollapsedSpacesAndBreaks() throws {
        let text = try H.build("<p>a <span id='sp'> </span> b</p><p>c<br id='br'/>d</p><p> <b id='lead'> x</b></p><p>e<i id='trail'> </i></p><p>f</p>")
        XCTAssertEqual(text.string.string, "a b\nc\u{2028}d\nx\ne\nf")
        XCTAssertEqual(text.anchors["sp"], 2) // After the space that was already pending when it started.
        XCTAssertEqual(text.anchors["br"], 5) // The line break itself.
        XCTAssertEqual(text.anchors["lead"], 8)
        XCTAssertEqual(text.anchors["trail"], 12) // Nothing of it is rendered: the next paragraph.
    }

    func testAnchorsAtTheSectionsVeryStartAndEnd() throws {
        let text = try H.build("<p id='first'>x</p><p>y</p><span id='last'/>", rootAttributes: "id='root'")
        XCTAssertEqual(text.anchors["root"], 0)
        XCTAssertEqual(text.anchors["first"], 0)
        XCTAssertEqual(text.anchors["last"], text.string.length)
        let body = try S.raw("""
            <html xmlns="http://www.w3.org/1999/xhtml"><head id="head"><title id="title">T</title></head>\
            <body id="body"><p>x</p></body></html>
            """)
        XCTAssertEqual(body.anchors, ["head": 0, "title": 0, "body": 0])
        let empty = try H.build("<div id='only'/>")
        XCTAssertEqual(empty.string.length, 0)
        XCTAssertEqual(empty.anchors, ["only": 0])
    }

    func testDuplicateIdsAnchorAtTheFirstElementAndXMLIdsCount() throws {
        let text = try H.build("<p id='dup'>first</p><p id='dup'>second</p><p xml:id='xid'>third</p><p hidden='' id='late'>h</p><p id='late'>fourth</p>")
        XCTAssertEqual(text.anchors["dup"], 0)
        XCTAssertEqual(text.anchors["xid"], H.location(of: "third", in: text))
        XCTAssertEqual(text.anchors["late"], H.location(of: "fourth", in: text))
    }

    /// Ids compare code unit for code unit, as `getElementById` compares them: `caf&#xE9;` and
    /// `cafe&#x301;` are two ids, though `String` compares them equal. So are two such names.
    func testCanonicallyEquivalentIdsAndNamesAreTwoAnchors() throws {
        let text = try H.build("""
            <p id="caf&#xE9;">composed</p><p id="cafe&#x301;">decomposed</p>\
            <p><a name="na&#xEF;ve">first</a> <a name="nai&#x308;ve">second</a></p>
            """)
        XCTAssertEqual(text.anchors.count, 4)
        XCTAssertEqual(text.anchors["caf\u{E9}"], H.location(of: "composed", in: text))
        XCTAssertEqual(text.anchors["cafe\u{301}"], H.location(of: "decomposed", in: text))
        XCTAssertEqual(text.anchors["na\u{EF}ve"], H.location(of: "first", in: text))
        XCTAssertEqual(text.anchors["nai\u{308}ve"], H.location(of: "second", in: text))
    }

    /// A note is named by its own ids alone: one whose id is canonically equivalent to another's
    /// is a second note, and a link to either shows that one.
    func testCanonicallyEquivalentIdsNameTwoNotes() throws {
        let text = try H.build("""
            <p>T<a epub:type="noteref" href="#n&#xE9;">one</a> U<a epub:type="noteref" href="#ne%CC%81">two</a></p>\
            <aside epub:type="footnote" id="n&#xE9;"><p>Composed.</p></aside>\
            <aside epub:type="footnote" id="ne&#x301;"><p>Decomposed.</p></aside>
            """)
        XCTAssertEqual(text.notes.count, 2)
        XCTAssertEqual(text.notes["n\u{E9}"]?.string, "Composed.")
        XCTAssertEqual(text.notes["ne\u{301}"]?.string, "Decomposed.")
    }

    /// A link goes where its own href says: hrefs that differ in code units alone are resolved
    /// one by one, not once for both.
    func testLinksToCanonicallyEquivalentIdsKeepTheirOwnTargets() throws {
        let text = try H.build("""
            <p><a href="#caf&#xE9;">first</a> <a href="#cafe&#x301;">second</a></p><p id="caf&#xE9;">x</p><p id="cafe&#x301;">y</p>
            """)
        XCTAssertEqual(S.link("first", in: text), .internal(href: "OPS/one.xhtml#caf%C3%A9"))
        XCTAssertEqual(S.link("second", in: text), .internal(href: "OPS/one.xhtml#cafe%CC%81"))
    }

    func testIdsInContentThatIsNotRenderedAnchorAtTheNextRenderedCharacter() throws {
        let text = try H.build("""
            <p>before</p><div hidden="" id="h"><p id="hp">x</p></div><script id="sc">s</script><template id="tp"><b id="tb">t</b></template>\
            <video id="v"><source id="src" src="v.mp4"/></video><p><input id="in" type="text"/>after<iframe id="fr" src="two.xhtml"/></p>\
            <p>end</p><div id="tail" hidden=""/>
            """)
        XCTAssertEqual(text.string.string, "before\nafter\nend")
        for id in ["h", "hp", "sc", "tp", "tb", "v", "src", "in"] { XCTAssertEqual(text.anchors[id], 7, id) }
        XCTAssertEqual(text.anchors["fr"], 13)
        XCTAssertEqual(text.anchors["tail"], text.string.length)
    }

    func testLegacyNamedAnchorsAreFragmentTargets() throws {
        let text = try H.build("<a name='top'/><p>x <a name='mid'>mid</a></p><a name='claimed' id='own'/><p id='claimed'>claims</p><a name=''>z</a>")
        XCTAssertEqual(text.anchors["top"], 0)
        XCTAssertEqual(text.anchors["mid"], 2)
        // An element whose id is the name wins, as `getElementById` comes first (HTML 7.4.6.4).
        XCTAssertEqual(text.anchors["claimed"], H.location(of: "claims", in: text))
        XCTAssertEqual(text.anchors["own"], H.location(of: "claims", in: text))
        XCTAssertNil(text.anchors[""])
    }

    func testAnAnchorsNameIsAFragmentTargetWhenItAlsoHasAnotherId() throws {
        // HTML 7.4.6.4 (find a potential indicated element): an element whose ID is the fragment, else an
        // `a` element whose `name` is. `<a id="page12" name="p12">` therefore answers to both.
        let text = try H.build("<p>before</p><p><a id='page12' name='p12'>both</a></p>")
        XCTAssertEqual(text.anchors["page12"], H.location(of: "both", in: text))
        XCTAssertEqual(text.anchors["p12"], H.location(of: "both", in: text))
    }

    /// The same name names an anchor inside a unit, which it points at as an id there does, and
    /// a note, which is captured under the name as under the id beside it.
    func testAnAnchorsNameNamesAUnitOrANoteAsItsIdDoes() throws {
        let text = try H.build("""
            <p>Text<a epub:type="noteref" href="#fy">1</a> and <a href="#fx">2</a></p>\
            <table id="t"><tr><td><a name="cell"/>one</td><td><a id="c2" name="cell2">two</a></td></tr></table>\
            <aside epub:type="footnote"><p><a id="fx" name="fy"></a>The note.</p></aside>
            """, rich: BuilderRecordingRich(rendersTables: true))
        let table = try XCTUnwrap(text.map.spans.first { $0.node == text.document.element(id: "t")!.order })
        for name in ["cell", "c2", "cell2"] { XCTAssertEqual(text.anchors[name], table.location, name) }
        XCTAssertEqual(text.notes.mapValues(\.string), ["fx": "The note.", "fy": "The note."])
        XCTAssertEqual(S.link("1", in: text), .note(href: "OPS/one.xhtml#fy"))
        XCTAssertEqual(S.link("2", in: text), .note(href: "OPS/one.xhtml#fx"))
    }

    func testAnchorsInsideUnitsPointAtTheUnit() throws {
        let rich = BuilderRecordingRich(rendersTables: true)
        let text = try H.build("""
            <p>Lead</p><table id="t"><tr id="row"><td id="c1">one <b id="b">bold</b></td><td id="c2">two</td></tr></table>\
            <p>Mid <math xmlns="http://www.w3.org/1998/Math/MathML" id="m"><mi id="mi">x</mi></math> <img id="img" src="picture.png" alt=""/> end.</p>
            """, rich: rich)
        let table = try XCTUnwrap(text.map.spans.first { $0.node == text.document.element(id: "t")!.order })
        for id in ["t", "row", "c1", "b", "c2"] { XCTAssertEqual(text.anchors[id], table.location, id) }
        let math = try XCTUnwrap(text.map.spans.first { $0.node == text.document.element(id: "m")!.order })
        XCTAssertEqual(text.anchors["m"], math.location)
        XCTAssertEqual(text.anchors["mi"], math.location)
        let image = try XCTUnwrap(text.map.spans.first { $0.node == text.document.element(id: "img")!.order })
        XCTAssertEqual(text.anchors["img"], image.location)
        // A DOM position inside a unit is the unit: its start, or its end for a range's end.
        let bold = try XCTUnwrap(S.textNode("bold", in: text))
        XCTAssertEqual(text.map.location(of: DOMPosition(bold, 2)), table.location)
        XCTAssertEqual(text.map.location(of: DOMPosition(bold, 2), isEnd: true), table.location + table.length)
        S.assertTextMapContracts(text)
    }

    func testAnchorsFollowDocumentOrderAndCoverEveryId() throws {
        let text = try H.build("""
            <section id="s1"><h1 id="h">T<span id="e1"/></h1><p id="p1">a <i id="i1">b</i><a id="e2"/> c</p>\
            <ul id="ul"><li id="l1">x</li><li id="l2"><p id="lp">y</p></li></ul><aside epub:type="footnote" id="fn">n</aside>\
            <pre id="pre">  code</pre><div id="d" hidden=""/><p id="p2"><q id="q">q</q><br id="br"/>z</p></section>
            """)
        var previous = 0
        for node in text.document.nodes where node.isElement {
            guard let id = node.id else { continue }
            let anchor = try XCTUnwrap(text.anchors[id], id)
            XCTAssertGreaterThanOrEqual(anchor, previous, id)
            XCTAssertLessThanOrEqual(anchor, text.string.length, id)
            previous = anchor
        }
        // An element's anchor is never after its own first rendered character.
        XCTAssertEqual(text.anchors["q"], H.location(of: "“q", in: text))
        XCTAssertEqual(text.anchors["pre"], H.location(of: "  code", in: text))
        XCTAssertEqual(text.anchors["l2"], H.location(of: "•\ty", in: text))
    }
}
