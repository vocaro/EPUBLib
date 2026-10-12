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

    func testEveryIdInsideANoteNamesTheWholeNote() throws {
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
        // An empty id names nothing: a link to `#` does not open the note that holds one.
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

    func testAnEndnoteInTheFlowIsNamedByAnyIdInsideAndStaysInTheFlow() throws {
        let text = try H.build("""
            <p>Claim<a epub:type="noteref" href="#e1b">1</a>.</p>\
            <section epub:type="endnotes"><ol><li epub:type="endnote"><p>First.</p><p id="e1b">Second.</p></li>\
            <li id="e2"><p>Not a note.</p><p id="e2b">Its second.</p></li></ol></section>
            """)
        XCTAssertEqual(text.notes.mapValues(\.string), ["e1b": "First.\nSecond."])
        XCTAssertEqual(S.paragraphs(text), ["Claim1.", "1.\tFirst.", "Second.", "2.\tNot a note.", "Its second."])
        XCTAssertEqual(text.anchors["e1b"], H.location(of: "Second.", in: text))
        XCTAssertEqual(S.link("1", in: text), .note(href: "OPS/one.xhtml#e1b"))
        S.assertTextMapContracts(text)
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
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/133")
        // HTML 7.4.6.4 (find a potential indicated element): an element whose ID is the fragment, else an
        // `a` element whose `name` is. `<a id="page12" name="p12">` therefore answers to both.
        let text = try H.build("<p>before</p><p><a id='page12' name='p12'>both</a></p>")
        XCTAssertEqual(text.anchors["page12"], H.location(of: "both", in: text))
        XCTAssertEqual(text.anchors["p12"], H.location(of: "both", in: text))
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
