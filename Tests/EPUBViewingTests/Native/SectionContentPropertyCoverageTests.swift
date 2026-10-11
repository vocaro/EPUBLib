import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing

/// Random documents over every kind of element the builder treats specially, wider than
/// `SectionBuilderPropertyTests`: each word is numbered, so besides the text-map and anchor
/// contracts the test knows which words must be shown, in which order, and which belong to notes.
final class SectionContentPropertyCoverageTests: XCTestCase {
    private typealias H = BuilderHarness
    private typealias S = SectionContentSupport

    private struct Generator {
        var random: SectionContentRandom
        var word = 0, id = 0
        /// Words in document order: shown in the section, captured by a note, or neither.
        var shown: [Int] = [], noted: [String: [Int]] = [:]
        var transforms = false

        struct Context {
            var hidden = false
            var note: String?
            var depth = 0
            /// Under `visibility: hidden`: still text, except in a positioned box, which is left out.
            var invisible = false
            var endnote = false
        }

        static let suffixes = ["", "", "", "é", "😀", "漢", "ß", "e\u{301}", "\u{A0}", "&amp;", "&#x10400;", "ك"]
        static let spaces = [" ", " ", "  ", "\n", " \t ", "\n  ", "", "&#13;\n"]
        static let phrasing = ["em", "strong", "i", "b", "u", "s", "small", "sub", "sup", "code", "kbd", "mark", "abbr", "cite", "var",
                               "span", "x-custom", "label", "bdi", "time"]
        static let blocks = ["p", "div", "section", "article", "blockquote", "h1", "h3", "h6", "address", "center", "main", "figcaption"]

        mutating func nextID() -> String { id += 1; return "e\(id)" }

        mutating func text(_ context: Context) -> String {
            word += 1
            if !context.hidden {
                if let note = context.note { noted[note, default: []].append(word) } else { shown.append(word) }
            }
            return random.pick(Self.spaces) + "t\(word)x" + random.pick(Self.suffixes) + random.pick(Self.spaces)
        }

        mutating func inline(_ context: Context) -> String {
            var html = ""
            var inner = context
            inner.depth += 1
            var hidden = inner
            hidden.hidden = true
            for _ in 0..<(1 + random.next(3)) {
                switch random.next(context.depth > 4 ? 6 : 40) {
                case 0, 1, 2, 3, 4, 5: html += text(context)
                case 6: html += "<br/>"
                case 7: html += "<wbr/>"
                case 8: html += "<img id='\(nextID())' src='picture.png' alt=''/>"
                case 9: html += "<!-- c -->" + random.pick(Self.spaces)
                case 10: html += "<![CDATA[" + random.pick([" ", "<", "a  b"]) + "]]>"
                case 11: html += "<a id='\(nextID())' href='\(random.pick(["#e1", "two.xhtml", "https://example.com", "", "#"]))'>" + inline(inner) + "</a>"
                case 12: html += "<q id='\(nextID())'>" + inline(inner) + "</q>"
                case 13: html += "<bdo id='\(nextID())' dir='\(random.pick(["rtl", "ltr"]))'>" + inline(inner) + "</bdo>"
                case 14: html += "<span id='\(nextID())' dir='\(random.pick(["rtl", "ltr", "auto"]))' lang='\(random.pick(["ar", "fr", ""]))'>" + inline(inner) + "</span>"
                case 15: html += "<ruby id='\(nextID())'>" + text(context) + "<rp>(</rp><rt>" + text(hidden) + "</rt><rp>)</rp></ruby>"
                case 16: html += "<ruby><rb>" + text(context) + "</rb><rt id='\(nextID())'>" + text(hidden) + "</rt><rtc>" + text(hidden) + "</rtc></ruby>"
                case 17: html += "<span hidden='' id='\(nextID())'>" + inline(hidden) + "</span>"
                case 18: html += "<span class='dn' id='\(nextID())'>" + inline(hidden) + "</span>"
                case 19:
                    var invisible = inner
                    invisible.invisible = true
                    html += "<span class='vh' id='\(nextID())'>" + inline(invisible) + "</span>"
                case 20: transforms = true; html += "<span class='\(random.pick(["u", "c", "l"]))'>" + inline(inner) + "</span>"
                case 21: html += "<span class='\(random.pick(["pw", "pl", "nw"]))'>" + inline(inner) + "</span>"
                case 22: html += "<script id='\(nextID())'>" + text(hidden) + "</script>"
                case 23: html += "<template>" + inline(hidden) + "</template>"
                case 24: html += "<video id='\(nextID())' src='v.mp4'><source src='v.webm'/>" + inline(inner) + "</video>"
                case 25: html += "<iframe id='\(nextID())' src='two.xhtml'>" + text(hidden) + "</iframe><input id='\(nextID())' type='text'/>"
                case 26: html += "<select id='\(nextID())'><option>" + text(hidden) + "</option></select><button>" + inline(inner) + "</button>"
                case 27:
                    html += "<epub:switch id='\(nextID())'><epub:case required-namespace='urn:x'>" + inline(hidden)
                        + "</epub:case><epub:default>" + inline(inner) + "</epub:default></epub:switch>"
                case 28: html += "<math xmlns='http://www.w3.org/1998/Math/MathML' id='\(nextID())'><mi>x</mi></math>"
                case 29: html += "<svg xmlns='http://www.w3.org/2000/svg' id='\(nextID())'><g id='\(nextID())'/></svg>"
                case 30: html += "<a epub:type='noteref' href='#e\(1 + random.next(max(id, 1)))'>" + text(context) + "</a>"
                case 31:
                    let box = random.pick(["bl", "fl", "ib", "abs"])
                    html += "<span class='\(box)' id='\(nextID())'>" + inline(box == "abs" && context.invisible ? hidden : inner) + "</span>"
                case 32: html += "<object data='x.bin'><param name='a' value='b'/>" + inline(inner) + "</object>"
                case 33: html += "<span epub:type='pagebreak' id='\(nextID())' title='7'/>"
                default: let tag = random.pick(Self.phrasing); html += "<\(tag) id='\(nextID())'>" + inline(inner) + "</\(tag)>"
                }
            }
            return html
        }

        mutating func block(_ context: Context) -> String {
            var html = ""
            var inner = context
            inner.depth += 1
            var hidden = inner
            hidden.hidden = true
            for _ in 0..<(1 + random.next(3)) {
                guard context.depth < 4 else { html += inline(context); continue }
                switch random.next(30) {
                case 0, 1, 2, 3, 4, 5, 6: html += inline(context)
                case 7:
                    let attributes = random.pick(["", " start='7'", " reversed=''", " type='a'", " type='I' start='3'", " dir='rtl'"])
                    html += "<ol id='\(nextID())'\(attributes)>" + (0..<(1 + random.next(3))).map { _ in
                        "<li\(random.pick(["", "", " value='4'", " id='\(nextID())'"]))>" + (random.chance(4) ? "" : block(inner)) + "</li>"
                    }.joined() + "</ol>"
                case 8: html += "<ul id='\(nextID())' class='\(random.pick(["", "in", "ns"]))'><li>" + block(inner) + "</li><li>" + inline(inner) + "</li></ul>"
                case 9: html += "<dl id='\(nextID())'><dt>" + inline(inner) + "</dt><dd>" + block(inner) + "</dd></dl>"
                case 10: html += "<pre id='\(nextID())'>" + random.pick(["", "\n", "\n\n"]) + inline(inner) + random.pick(["", "\n", "\n\n", "\t"]) + "</pre>"
                case 11: html += "<figure id='\(nextID())'><img src='picture.png' alt=''/><figcaption>" + inline(inner) + "</figcaption></figure>"
                case 12: html += "<details id='\(nextID())'><summary>" + inline(inner) + "</summary>" + block(inner) + "</details>"
                case 13:
                    html += "<table id='\(nextID())'><caption>" + inline(inner) + "</caption><tr><td id='\(nextID())'>" + block(inner)
                        + "</td><td>" + inline(inner) + "</td></tr><tr><td/><th>" + inline(inner) + "</th></tr></table>"
                case 14: html += "<table id='\(nextID())'><tbody><tr><td>" + block(inner) + "</td></tr><tr><td>" + block(inner) + "</td></tr></tbody></table>"
                case 15 where context.note == nil && !context.hidden:
                    let note = nextID()
                    var noted = inner
                    noted.note = note
                    html += "<aside epub:type='footnote' id='\(note)'>" + block(noted) + "</aside>"
                case 16 where context.note == nil && !context.hidden && !context.endnote:
                    // An endnote stays in the flow and is captured too. It opens with a paragraph: a note that
                    // opens with another note is its own case (`SectionContentNoteAnchorCoverageTests`).
                    let note = nextID()
                    let from = word
                    var endnote = inner
                    endnote.endnote = true
                    html += "<div epub:type='endnote' id='\(note)'><p>" + inline(endnote) + "</p>" + block(endnote) + "</div>"
                    noted[note] = shown.filter { $0 > from }
                case 17: html += "<div hidden='' id='\(nextID())'>" + block(hidden) + "</div>"
                case 18: html += "<hr id='\(nextID())'/>"
                case 19:
                    let box = random.pick(["fl", "abs", "li", "in", "kt"])
                    html += "<div class='\(box)' id='\(nextID())'>" + block(box == "abs" && context.invisible ? hidden : inner) + "</div>"
                case 20: html += "<div dir='rtl' lang='he' id='\(nextID())'>" + block(inner) + "</div>"
                case 21: html += "<br/>"
                default:
                    let tag = random.pick(Self.blocks)
                    html += "<\(tag) id='\(nextID())'>" + block(inner) + "</\(tag)>" + random.pick(["", "\n", "\n  "])
                }
            }
            return html
        }
    }

    private static func makeRules() -> [H.Rule] { [
        (".u", { $0.textTransform = .uppercase }), (".c", { $0.textTransform = .capitalize }), (".l", { $0.textTransform = .lowercase }),
        (".pw", { $0.whiteSpace = .preWrap }), (".pl", { $0.whiteSpace = .preLine }), (".nw", { $0.whiteSpace = .nowrap }),
        (".dn", { $0.display = .none }), (".vh", { $0.isHidden = true }), (".bl", { $0.display = .block }),
        (".fl", { $0.float = .left }), (".abs", { $0.isOutOfFlow = true }), (".li", { $0.display = .listItem }),
        (".ib", { $0.display = .inlineBlock; $0.width = .points(50) }), (".in", { $0.listStylePosition = .inside }),
        (".ns", { $0.listStyleType = .none }), (".kt", { $0.breakInside = .avoid; $0.breakBefore = .page }),
    ] }

    private static func words(in string: String) -> [Int] {
        var result: [Int] = [], digits = "", open = false
        for character in string {
            if character == "t" || character == "T" { open = true; digits = "" }
            else if open, character.isASCII, character.isNumber { digits.append(character) }
            else {
                if open, character == "x" || character == "X", let number = Int(digits) { result.append(number) }
                open = false
            }
        }
        return result
    }

    private func violations(body: String, generator: Generator) throws -> [String] {
        let document = try H.document(body)
        let text = H.build(document: document, rich: BuilderRecordingRich(), rules: Self.makeRules())
        var violations = S.mapViolations(text, sameCharacters: !generator.transforms) + S.rangeViolations(text, limit: 2)
            + S.locationViolations(text) + S.stringViolations(text)
        if text.report.withheld { violations.append("withheld") }
        // Characters: every word outside hidden content and footnotes is shown once, in document order.
        if Self.words(in: text.string.string) != generator.shown { violations.append("shown words \(Self.words(in: text.string.string)) are not \(generator.shown)") }
        for (note, expected) in generator.noted where Self.words(in: text.notes[note]?.string ?? "") != expected {
            violations.append("note \(note) holds \(Self.words(in: text.notes[note]?.string ?? "")), not \(expected)")
        }
        // Anchors: every id, in document order, never after the element's own first character.
        var previous = 0
        for node in document.nodes where node.isElement {
            guard let id = node.id, document.element(id: id) === node else { continue }
            guard let anchor = text.anchors[id] else { violations.append("no anchor for \(id)"); continue }
            if anchor < previous || anchor > text.string.length { violations.append("anchor \(id) at \(anchor) after \(previous)") }
            previous = max(previous, anchor)
        }
        for span in text.map.spans {
            var ancestor = document.nodes[span.node].parent
            while let element = ancestor {
                if let id = element.id, document.element(id: id) === element, let anchor = text.anchors[id], anchor > span.location {
                    violations.append("\(id) anchors at \(anchor), after its content at \(span.location)")
                }
                ancestor = element.parent
            }
        }
        return violations
    }

    private func run(seed: UInt64, rounds: Int, blockLevel: Bool) throws {
        var random = SectionContentRandom(state: seed)
        var failures: [(body: String, violations: [String])] = []
        for _ in 0..<rounds {
            var generator = Generator(random: random)
            // End with white space, as most markup does: a last node that is an image is its own case (text-map tests).
            let body = (blockLevel ? generator.block(.init()) : "<p>" + generator.inline(.init()) + "</p>") + "\n"
            random = generator.random
            let found = try violations(body: body, generator: generator)
            if !found.isEmpty { failures.append((body, found)) }
        }
        if let smallest = failures.min(by: { $0.body.utf8.count < $1.body.utf8.count }) {
            XCTFail("\(failures.count) of \(rounds) random documents (seed \(seed)) break a contract: "
                + smallest.violations.prefix(4).joined(separator: "; ") + ". The smallest: \(S.escape(smallest.body))")
        }
    }

    func testRandomInlineContentKeepsItsWordsInOrderAndItsMap() throws {
        try run(seed: 0x1D0C_5EED, rounds: 400, blockLevel: false)
    }

    func testRandomDocumentsKeepTheirWordsInOrderTheirMapAndTheirAnchors() throws {
        try run(seed: 0xB10C_5EED, rounds: 300, blockLevel: true)
    }

    func testRandomDocumentsBuildTheSameCharactersAtAnotherSizeAndAppearance() throws {
        var random = SectionContentRandom(state: 0x7E57_5EED)
        for round in 0..<120 {
            var generator = Generator(random: random)
            let body = generator.block(.init())
            random = generator.random
            let document = try H.document(body)
            let publication = H.publication, rules = Self.makeRules()
            func build(_ typography: NativeTypography) -> SectionText {
                let request = SectionBuildRequest(publication: publication, spineIndex: 0, typography: typography,
                                                  fonts: FontRegistry(publication: publication), rich: BuilderRecordingRich())
                let resolver = StyleResolver(document: document, stylesheets: [], typography: typography)
                return SectionBuilder.build(document: document, request: request, initialStyle: resolver.initialStyle) { node, parent in
                    var style = resolver.style(for: node, parent: parent)
                    for rule in rules where node.classNames.contains(String(rule.selector.dropFirst())) { rule.apply(&style) }
                    return style
                }
            }
            let small = build(NativeTypography(fontSize: 12, isDark: false)), large = build(NativeTypography(fontSize: 64, isDark: true))
            XCTAssertEqual(small.string.string, large.string.string, "round \(round): \(body)")
            XCTAssertEqual(small.map, large.map, "round \(round): \(body)")
            XCTAssertEqual(small.anchors, large.anchors, "round \(round): \(body)")
            XCTAssertEqual(small.notes.mapValues(\.string), large.notes.mapValues(\.string), "round \(round): \(body)")
        }
    }
}
