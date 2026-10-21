import Foundation
import XCTest
@testable import EPUBViewing

/// Resolving and generating CFIs in documents the recorded foliate vectors do not contain.
final class PositionCFIResolutionCoverageTests: XCTestCase {
    private static let xhtml = #"xmlns="http://www.w3.org/1999/xhtml""#

    private func parse(_ markup: String, path: String = "position.xhtml") throws -> ContentDocument {
        try ContentDocument.parse(Data(markup.utf8), path: path)
    }
    private func page(_ body: String) throws -> ContentDocument {
        try parse("<html \(Self.xhtml)><head><title>T</title></head><body>\(body)</body></html>")
    }
    private func text(_ string: String, in document: ContentDocument, file: StaticString = #filePath, line: UInt = #line) throws -> ContentNode {
        try XCTUnwrap(document.nodes.first { $0.isText && $0.text == string }, "no text node \(string.debugDescription)", file: file, line: line)
    }
    private func element(_ name: String, _ index: Int = 0, in document: ContentDocument) throws -> ContentNode {
        let elements = document.nodes.filter { $0.isElement && $0.name == name }
        return try XCTUnwrap(elements.indices.contains(index) ? elements[index] : nil, "no \(name) \(index)")
    }
    private func resolve(_ cfi: String, in document: ContentDocument) -> [DOMPosition]? {
        EPUBCFI.resolve(localPath: cfi, in: document).map { [$0.start, $0.end] }
    }
    private func path(_ start: DOMPosition, _ end: DOMPosition? = nil, in document: ContentDocument) -> String {
        EPUBCFI.localPath(from: start, to: end ?? start, in: document)
    }
    /// The characters between two positions, as a DOM range's `toString` reads them.
    private func string(_ range: [DOMPosition]?, in document: ContentDocument) -> String? {
        guard let range, range.count == 2 else { return nil }
        var output = ""
        for node in document.nodes[range[0].node.order...max(range[0].node.order, range[1].node.order)] where node.isText {
            let lower = node === range[0].node ? range[0].offset : 0
            let upper = node === range[1].node ? range[1].offset : node.utf16Length
            if upper > lower { output += (node.text as NSString).substring(with: NSRange(location: lower, length: upper - lower)) }
        }
        return output
    }

    /// Every element start and a spread of text offsets; all offsets of short text.
    private func positions(in document: ContentDocument) -> [DOMPosition] {
        var positions: [DOMPosition] = []
        for node in document.nodes.dropFirst() {
            guard node.isText else { positions.append(DOMPosition(node)); continue }
            let length = node.utf16Length
            let offsets = length <= 6 ? Array(0...length) : Array(Set([0, 1, length / 2, length - 1, length])).sorted()
            positions += offsets.map { DOMPosition(node, $0) }
        }
        return positions
    }

    /// Every sampled pair of positions becomes a path that resolves back to the same pair.
    private func assertRoundTrips(_ document: ContentDocument, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let positions = positions(in: document)
        XCTAssertFalse(positions.isEmpty, label, file: file, line: line)
        let step = max(1, positions.count / 40)
        var checked = 0, failures = 0
        for (index, start) in positions.enumerated() {
            var ends = Array(positions[index...].prefix(4))
            ends += stride(from: index, to: positions.count, by: step).map { positions[$0] }
            ends.append(positions[positions.count - 1])
            for end in ends {
                let cfi = EPUBCFI.localPath(from: start, to: end, in: document)
                let resolved = EPUBCFI.resolve(localPath: cfi, in: document)
                checked += 1
                if resolved?.start != start || resolved?.end != end {
                    failures += 1
                    if failures <= 5 {
                        let got = resolved.map { "\($0.start.node.order):\($0.start.offset)–\($0.end.node.order):\($0.end.offset)" } ?? "nil"
                        XCTFail("\(label): \(cfi) for \(start.node.order):\(start.offset)–\(end.node.order):\(end.offset) resolved to \(got)",
                                file: file, line: line)
                    }
                }
            }
        }
        XCTAssertEqual(failures, 0, "\(label): \(failures) of \(checked) ranges did not round trip", file: file, line: line)
    }

    // MARK: - The specification's example

    /// The document of the specification's running example in shape (sections 3.1.1 to 3.1.4):
    /// indented markup, a body with an ID, the fifth paragraph holding text, an `em` and digits,
    /// and an image eighth among the body's children.
    private func example(fifth: String, compact: Bool = false) throws -> ContentDocument {
        let body = ["<p>first</p>", "<p>second</p>", "<p>third</p>", "<p>fourth</p>", "<p id=\"para-five\">\(fifth)</p>", "<p>sixth</p>",
                    "<p>seventh</p>", "<img id=\"figure\" src=\"figure.svg\" alt=\"A figure\"/>", "<p>ninth</p>", "<p>tenth</p>"]
        let separator = compact ? "" : "\n        "
        return try parse("<html \(Self.xhtml)>\(separator)<head>\(separator)<title>Shape</title>\(separator)</head>\(separator)\(separator)"
            + "<body id=\"main\">\(separator)\(body.joined(separator: separator))\(separator)</body>\(separator)</html>")
    }

    func testTheSpecificationsExamplePathsResolveAndComeBackUnchanged() throws {
        let decorated = "abc<em>def</em><![CDATA[]]><!--one--><![CDATA[0123]]>4<!--two-->5<?pi three?><![CDATA[67]]>&#56;&#x39;"
        for (label, document) in [("indented", try example(fifth: "abc<em>def</em>0123456789")),
                                  ("compact", try example(fifth: "abc<em>def</em>0123456789", compact: true)),
                                  ("split character data", try example(fifth: decorated)),
                                  ("split and compact", try example(fifth: decorated, compact: true))] {
            let digits = try text("0123456789", in: document), abc = try text("abc", in: document), def = try text("def", in: document)
            let image = try element("img", in: document)
            XCTAssertEqual(resolve("/4[main]/10[para-five]/3:10", in: document), [DOMPosition(digits, 10), DOMPosition(digits, 10)], label)
            XCTAssertEqual(resolve("/4[main]/16[figure]", in: document), [DOMPosition(image), DOMPosition(image)], label)
            XCTAssertEqual(resolve("/4[main]/10[para-five]/1:0", in: document), [DOMPosition(abc), DOMPosition(abc)], label)
            XCTAssertEqual(resolve("/4[main]/10[para-five]/2/1:0", in: document), [DOMPosition(def), DOMPosition(def)], label)
            XCTAssertEqual(resolve("/4[main]/10[para-five]/2/1:3", in: document), [DOMPosition(def, 3), DOMPosition(def, 3)], label)
            // Without the assertions the steps alone name the same places.
            XCTAssertEqual(resolve("/4/10/3:10", in: document), [DOMPosition(digits, 10), DOMPosition(digits, 10)], label)
            XCTAssertEqual(resolve("/4/16", in: document), [DOMPosition(image), DOMPosition(image)], label)
            for cfi in ["/4[main]/10[para-five]/3:10", "/4[main]/16[figure]", "/4[main]/10[para-five]/1:0", "/4[main]/10[para-five]/2/1:0",
                        "/4[main]/10[para-five]/2/1:3"] {
                let range = try XCTUnwrap(EPUBCFI.resolve(localPath: cfi, in: document), "\(label) \(cfi)")
                XCTAssertEqual(EPUBCFI.localPath(from: range.start, to: range.end, in: document), cfi, label)
            }
            // Section 3.4's range, and each digit as a one-character range.
            XCTAssertEqual(string(resolve("/4[main]/10[para-five],/2/1:1,/3:4", in: document), in: document), "ef0123", label)
            for digit in 0..<10 {
                XCTAssertEqual(string(resolve("/4/10,/3:\(digit),/3:\(digit + 1)", in: document), in: document), "\(digit)", label)
            }
            assertRoundTrips(document, label)
        }
    }

    /// Section 3.1.1: "content other than element and character data is ignored", CDATA is
    /// character data, and consecutive chunks are one position. Decorating a document with
    /// comments, processing instructions and CDATA sections changes no path.
    func testCommentsProcessingInstructionsAndCDATAChangeNoPath() throws {
        let plain = try page("<p>Alpha beta gamma</p><p>one<b>two</b>three</p><div><p>deep text</p></div>")
        let decorated = try parse("<?xml version=\"1.0\"?><!-- before the root --><?proc one?><html \(Self.xhtml)><!-- in the root --><head><!-- in the head -->"
            + "<title>T</title></head><?proc two?><body><!-- first in body --><p>Alpha<!-- split --> beta<?proc three?> <![CDATA[gamma]]></p><?proc four?>"
            + "<p><!-- lead -->one<b><![CDATA[t]]>w<![CDATA[]]>o</b><?proc five?>thr&#101;e<!-- tail --></p><!-- between --><div><p><![CDATA[deep text]]></p>"
            + "<!-- last in div --></div><!-- last in body --></body><!-- last in root --></html><!-- after the root -->")
        func model(_ document: ContentDocument) -> [String] { document.nodes.map { $0.isElement ? "<\($0.name)>" : $0.text } }
        XCTAssertEqual(model(decorated), model(plain))
        for node in plain.nodes where node.isText {
            let twin = decorated.nodes[node.order]
            for offset in 0...node.utf16Length {
                let cfi = path(DOMPosition(node, offset), in: plain)
                XCTAssertEqual(path(DOMPosition(twin, offset), in: decorated), cfi)
                XCTAssertEqual(resolve(cfi, in: decorated), [DOMPosition(twin, offset), DOMPosition(twin, offset)], cfi)
            }
        }
        assertRoundTrips(decorated, "decorated")
    }

    // MARK: - Round trips

    func testEveryRangeRoundTripsInAnSVGSpineDocument() throws {
        let document = try parse("""
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 100">
          <title>Plate</title>
          <desc>A plate with <tspan>nested</tspan> text.</desc>
          <g id="layer"><text x="1" y="2">First <tspan id="span">second</tspan> third</text><image xlink:href="plate.png" width="10" height="10"/></g>
        </svg>
        """, path: "plate.svg")
        XCTAssertFalse(document.recoveredAsHTML)
        XCTAssertTrue(document.canResolveCFIs)
        XCTAssertEqual(document.root.name, "svg")
        let second = try text("second", in: document)
        XCTAssertEqual(path(DOMPosition(second, 2), in: document), "/6[layer]/2/2[span]/1:2", "steps start at the root element, whatever it is")
        XCTAssertEqual(resolve("/6[layer]/4", in: document)?.first, DOMPosition(try element("image", in: document)))
        XCTAssertEqual(resolve("/2/1:3", in: document)?.first, DOMPosition(try text("Plate", in: document), 3))
        assertRoundTrips(document, "svg")
    }

    func testEveryRangeRoundTripsThroughMathMLAndPrefixedNamespaces() throws {
        let document = try parse("""
        <html \(Self.xhtml) xmlns:m="http://www.w3.org/1998/Math/MathML" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Math</title></head>
        <body epub:type="bodymatter"><p>Let <m:math><m:mrow><m:mi>x</m:mi><m:mo>=</m:mo><m:mfrac><m:mn>1</m:mn><m:mn>2</m:mn></m:mfrac></m:mrow></m:math> and
        <math xmlns="http://www.w3.org/1998/Math/MathML" display="block" id="root"><msqrt><mi>y</mi></msqrt></math> hold.</p>
        <svg xmlns="http://www.w3.org/2000/svg"><text>inline <tspan>figure</tspan></text></svg></body></html>
        """)
        let x = try text("x", in: document)
        XCTAssertEqual(x.parent?.namespace, ContentNamespace.mathML)
        XCTAssertEqual(path(DOMPosition(x, 1), in: document), "/4/2/2/2/2/1:1")
        XCTAssertEqual(path(DOMPosition(try text("y", in: document)), in: document), "/4/2/4[root]/2/2/1:0")
        assertRoundTrips(document, "math")
    }

    func testEveryRangeRoundTripsAmongEmptyElementsWhiteSpaceAndVoids() throws {
        let document = try page("""

          <div>   </div>
          <p></p>
          <p>a<br/>b<br/><br/>c<img src="i.png" alt="i"/><img src="j.png" alt="j"/></p>
          <hr/>
          <ul><li>one</li><li/><li>three</li></ul>
          <p><span></span><span/>tail</p>
          loose text<p>p</p>more loose<span>s</span><span>t</span>
        """)
        assertRoundTrips(document, "sparse")
        // White space between blocks is a chunk like any other.
        let blank = try text("   ", in: document)
        XCTAssertEqual(path(DOMPosition(blank, 2), in: document), "/4/2/1:2")
        XCTAssertEqual(resolve("/4/1:1", in: document)?.first?.node.text.hasPrefix("\n"), true)
    }

    func testEveryRangeRoundTripsWithoutAHeadAndInTextOnlyBodies() throws {
        let headless = try parse("<html \(Self.xhtml)><body><p>Only a body.</p></body></html>")
        XCTAssertNil(headless.head)
        XCTAssertEqual(path(DOMPosition(try text("Only a body.", in: headless), 4), in: headless), "/2/2/1:4", "the body is the root's first element")
        assertRoundTrips(headless, "headless")
        let bare = try parse("<html \(Self.xhtml)><head><title>T</title></head><body>text only</body></html>")
        assertRoundTrips(bare, "bare")
        let empty = try parse("<html \(Self.xhtml)><head/><body/></html>")
        assertRoundTrips(empty, "empty")
        XCTAssertEqual(path(DOMPosition(empty.root), in: empty), "/2", "the root is its first child's start")
        let hollow = try parse("<html \(Self.xhtml)/>")
        XCTAssertEqual(path(DOMPosition(hollow.root), in: hollow), "", "an empty root has no step to name")
        XCTAssertNil(resolve("", in: hollow))
        XCTAssertNil(resolve("/2", in: hollow))
    }

    func testEveryRangeRoundTripsInUnicodeText() throws {
        let document = try page("<p>a😀b𝒜c</p><p>cafe&#x301; e&#x301;&#x302; ﬁn</p><p dir=\"rtl\">שלום עולם مرحبا</p><p>한글 かな 漢字 ｶﾞ</p>"
            + "<p>👨‍👩‍👧 🇫🇷 ❤️</p><p>a&#xA0;b&#xAD;c&#x200B;d&#xFEFF;e&#x2028;f</p>")
        assertRoundTrips(document, "unicode")
    }

    func testEveryRangeRoundTripsInDeepNestingTablesAndLongText() throws {
        let depth = 60
        let deep = try page(String(repeating: "<span>x", count: depth) + "leaf" + String(repeating: "y</span>", count: depth))
        assertRoundTrips(deep, "deep")
        let tables = try page("<table><caption>Caption</caption><thead><tr><th>h</th></tr></thead><tbody><tr><td>a<table><tr><td>inner</td></tr></table>b</td>"
            + "<td/></tr></tbody></table>")
        assertRoundTrips(tables, "tables")
        XCTAssertEqual(path(DOMPosition(try text("inner", in: tables), 2), in: tables), "/4/2/6/2/2/2/2/2/1:2", "no tbody is invented in XHTML")

        let sentence = "It was a bright cold day in the middle of nowhere, and the clocks were striking. "
        let long = try page("<p>" + String(repeating: sentence, count: 1_048_576 / sentence.utf8.count) + "</p><p>after</p>")
        let node = try XCTUnwrap(long.nodes.first { $0.isText && $0.utf16Length > 1_000_000 })
        for offset in [0, 1, 65_535, 65_536, 65_537, node.utf16Length / 2, node.utf16Length - 1, node.utf16Length] {
            let cfi = path(DOMPosition(node, offset), in: long)
            XCTAssertEqual(cfi, "/4/2/1:\(offset)")
            XCTAssertEqual(resolve(cfi, in: long), [DOMPosition(node, offset), DOMPosition(node, offset)])
        }
        XCTAssertEqual(resolve("/4/2/1:\(node.utf16Length + 1)", in: long)?.first, DOMPosition(node, node.utf16Length), "clamped to the node")
        assertRoundTrips(long, "long")
    }

    func testEveryRangeRoundTripsWithUnusualIdentifiers() throws {
        let document = try page("<p xml:id=\"only-xml\">a</p><p id=\"a]b\">b</p><p id=\"c,d;e=f\">c</p><p id=\"^\">d</p><p id=\"(g)\">e</p><p id=\"sp ace\">f</p>"
            + "<p id=\"é\">g</p><p id=\"!/4/2\">h</p><p id=\"\">i</p><p id=\"0\">j</p><p id=\"📖\">k</p><div id=\"outer\"><p id=\"inner\">l</p></div>")
        assertRoundTrips(document, "identifiers")
        XCTAssertEqual(path(DOMPosition(try text("a", in: document), 1), in: document), "/4/2/1:1", "xml:id is not an ID assertion")
        XCTAssertEqual(path(DOMPosition(try text("b", in: document), 1), in: document), "/4/4[a^]b]/1:1")
        XCTAssertEqual(path(DOMPosition(try text("c", in: document), 1), in: document), "/4/6[c^,d^;e^=f]/1:1")
        XCTAssertEqual(path(DOMPosition(try text("d", in: document), 1), in: document), "/4/8[^^]/1:1")
        XCTAssertEqual(path(DOMPosition(try text("h", in: document), 1), in: document), "/4/16[!/4/2]/1:1")
        XCTAssertEqual(path(DOMPosition(try text("i", in: document), 1), in: document), "/4/18/1:1", "an empty id asserts nothing")
        // An ID that is itself path syntax still names its own element, not the path it spells.
        XCTAssertEqual(resolve("/4/16[!/4/2]", in: document)?.first, DOMPosition(try element("p", 7, in: document)))
        // An element in the middle of a path keeps its assertion; only the last step's is used.
        XCTAssertEqual(path(DOMPosition(try text("l", in: document)), in: document), "/4/24[outer]/2[inner]/1:0")
        XCTAssertEqual(resolve("/4/24[inner]/2[outer]/1:0", in: document)?.first, DOMPosition(try text("l", in: document)),
                       "assertions on earlier steps are not consulted")
        XCTAssertEqual(resolve("/4/2[only-xml]/1:1", in: document)?.first, DOMPosition(try text("a", in: document), 1))
        XCTAssertEqual(resolve("/4/99[only-xml]", in: document), nil, "xml:id is not what an ID assertion finds")
    }

    func testEveryRangeRoundTripsInQualifiedHTML() throws {
        let document = try parse("<html>\n<head><title>Book</title></head>\n<body>\n<div><p>One <b>two</b></p>\n<ul>\n<li>three</li>\n</ul></div>\n</body>\n</html>")
        XCTAssertTrue(document.recoveredAsHTML)
        XCTAssertTrue(document.canResolveCFIs)
        assertRoundTrips(document, "html")
    }

    /// `ChildIndexCache` must give the indices the uncached walk gives, whatever mix of text and
    /// adjacent elements a parent holds.
    func testCachedChildIndicesMatchTheUncachedWalk() throws {
        var state: UInt64 = 0x0DDB_A11C_0FFE_E000
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for length in [31, 32, 33, 200] {
            var body = ""
            for index in 0..<length {
                switch next(4) {
                case 0: body += "text \(index) "
                case 1: body += "<br/>"
                case 2: body += "<span>s\(index)</span><!-- c -->"
                default: body += "<i>i</i><b>b\(index)</b>"
                }
            }
            let document = try page("<div>\(body)</div>")
            let cache = EPUBCFI.ChildIndexCache()
            for node in document.nodes.dropFirst() {
                let position = DOMPosition(node, node.isText ? min(1, node.utf16Length) : 0)
                let cached = EPUBCFI.localPath(from: position, to: position, in: document, indices: cache)
                XCTAssertEqual(cached, EPUBCFI.localPath(from: position, to: position, in: document), "\(length) children, node \(node.order)")
                XCTAssertEqual(EPUBCFI.resolve(localPath: cached, in: document)?.start, position, cached)
            }
        }
    }

    // MARK: - Offsets and virtual positions

    /// Section 3.1.4: an offset counts UTF-16 code units, zero is before the first unit and the
    /// length is after the last. A stale offset clamps; one inside a surrogate pair or a
    /// combining sequence is kept as the unit it names.
    func testCharacterOffsetsCountUTF16Units() throws {
        let document = try page("<p>a😀b</p><p>e&#x301;x</p>")
        let astral = try text("a😀b", in: document), combining = try text("e\u{301}x", in: document)
        XCTAssertEqual(astral.utf16Length, 4)
        for offset in 0...4 {
            XCTAssertEqual(resolve("/4/2/1:\(offset)", in: document), [DOMPosition(astral, offset), DOMPosition(astral, offset)])
            XCTAssertEqual(path(DOMPosition(astral, offset), in: document), "/4/2/1:\(offset)")
        }
        XCTAssertEqual(resolve("/4/2/1:5", in: document)?.first, DOMPosition(astral, 4))
        XCTAssertEqual(string(resolve("/4/2,/1:1,/1:3", in: document), in: document), "😀", "the pair is two units")
        XCTAssertEqual(string(resolve("/4/2,/1:3,/1:4", in: document), in: document), "b")
        XCTAssertEqual(resolve("/4/4/1:1", in: document)?.first, DOMPosition(combining, 1), "between a base and its mark")
        XCTAssertEqual(string(resolve("/4/4,/1:2,/1:3", in: document), in: document), "x")
        // A range that ends inside the pair still reads without trapping.
        let split = try XCTUnwrap(EPUBCFI.resolve(localPath: "/4/2,/1:0,/1:2", in: document))
        XCTAssertEqual([split.start.offset, split.end.offset], [0, 2])
        _ = TextSearch.text(of: TextSearch.Match(start: split.start, end: split.end), in: document)
    }

    /// Section 3.1.1: "0 is a valid index" before the first chunk and "n+2 is a valid index"
    /// after the last. `EPUBCFI`'s header documents how each maps to a DOM position.
    func testVirtualPositionsInBodiesOfOneKindOfChild() throws {
        let bare = try parse("<html \(Self.xhtml)><head><title>T</title></head><body>text only</body></html>")
        let only = try text("text only", in: bare), bareBody = try XCTUnwrap(bare.body)
        XCTAssertEqual(resolve("/4/1:3", in: bare)?.first, DOMPosition(only, 3))
        XCTAssertEqual(resolve("/4/0", in: bare)?.first, DOMPosition(bareBody), "before: the body's start")
        XCTAssertEqual(resolve("/4/2", in: bare)?.first, DOMPosition(only, 9), "after the last node: the document's end")
        XCTAssertNil(resolve("/4/3", in: bare), "past the virtual end")
        XCTAssertNil(resolve("/4/1/1:0", in: bare), "character data has no children")

        let single = try page("<p>only</p>")
        let paragraph = try element("p", in: single), word = try text("only", in: single)
        XCTAssertEqual(resolve("/4/1", in: single)?.first, DOMPosition(paragraph), "the empty first chunk: the first child")
        XCTAssertEqual(resolve("/4/2", in: single)?.first, DOMPosition(paragraph))
        XCTAssertEqual(resolve("/4/3", in: single)?.first, DOMPosition(paragraph), "the empty last chunk: the last child")
        XCTAssertEqual(resolve("/4/4", in: single)?.first, DOMPosition(word, 4), "after the body")
        XCTAssertNil(resolve("/4/5", in: single))
        XCTAssertNil(resolve("/4/6", in: single))
        XCTAssertEqual(resolve("/6", in: single)?.first, DOMPosition(word, 4), "after the root's last element")
        XCTAssertEqual(resolve("/0", in: single)?.first, DOMPosition(single.root))
    }

    /// An image, a line break and other void elements are named by their own even step;
    /// a character offset on them changes nothing, and nothing lies below them.
    func testImagesAndLineBreaksAreNamedByTheirOwnStep() throws {
        let document = try page("<p id=\"p\">a<img id=\"i\" src=\"x.png\" alt=\"picture\"/>b<br/>c</p>")
        let image = try element("img", in: document), lineBreak = try element("br", in: document)
        let a = try text("a", in: document), b = try text("b", in: document)
        for cfi in ["/4/2/2", "/4/2/2:0", "/4/2/2:1", "/4/2/2:7", "/4/2[p]/2[i]", "/4/2/2[i]:1", "/4/2/2@10:20", "/4/2/2~3.5"] {
            XCTAssertEqual(resolve(cfi, in: document), [DOMPosition(image), DOMPosition(image)], cfi)
        }
        XCTAssertEqual(path(DOMPosition(image), in: document), "/4/2[p]/2[i]")
        XCTAssertEqual(path(DOMPosition(lineBreak), in: document), "/4/2[p]/4")
        XCTAssertEqual(path(DOMPosition(a), DOMPosition(image), in: document), "/4/2[p],/1:0,/2[i]", "a range ending on the image")
        XCTAssertEqual(path(DOMPosition(image), DOMPosition(lineBreak), in: document), "/4/2[p],/2[i],/4")
        XCTAssertEqual(path(DOMPosition(image), DOMPosition(b, 1), in: document), "/4/2[p],/2[i],/3:1")
        XCTAssertEqual(resolve("/4/2[p],/2[i],/3:1", in: document), [DOMPosition(image), DOMPosition(b, 1)])
        for cfi in ["/4/2/2/1:0", "/4/2/2/2", "/4/2/4/1", "/4/2/4/0"] { XCTAssertNil(resolve(cfi, in: document), cfi) }
    }

    func testRangesOfEveryShapeAreWrittenAsFoliateWroteThem() throws {
        let document = try page("<h1 id=\"t\">Title</h1><p id=\"one\">Alpha <em>beta</em> gamma</p><p>Delta<img src=\"i.png\" alt=\"i\"/></p>")
        let title = try text("Title", in: document), alpha = try text("Alpha ", in: document), beta = try text("beta", in: document)
        let delta = try text("Delta", in: document), image = try element("img", in: document)
        let heading = try element("h1", in: document), first = try element("p", in: document)
        let shapes: [(String, DOMPosition, DOMPosition, String)] = [
            ("collapsed", DOMPosition(alpha, 2), DOMPosition(alpha, 2), "/4/4[one]/1:2"),
            ("within one chunk", DOMPosition(alpha, 1), DOMPosition(alpha, 4), "/4/4[one],/1:1,/1:4"),
            ("inside inline markup", DOMPosition(beta, 1), DOMPosition(beta, 3), "/4/4[one]/2,/1:1,/1:3"),
            ("into inline markup", DOMPosition(alpha, 2), DOMPosition(beta, 2), "/4/4[one],/1:2,/2/1:2"),
            ("across blocks", DOMPosition(title, 2), DOMPosition(delta, 3), "/4,/2[t]/1:2,/6/1:3"),
            ("between element starts", DOMPosition(heading), DOMPosition(first), "/4,/2[t],/4[one]"),
            ("an element to its own text", DOMPosition(first), DOMPosition(alpha, 3), "/4/4[one],,/1:3"),
            ("ending on an image", DOMPosition(delta), DOMPosition(image), "/4/6,/1:0,/2"),
            ("the whole document", DOMPosition(document.root), DOMPosition(image), ",/2,/4/6/2"),
            ("the whole body text", DOMPosition(title), DOMPosition(delta, 5), "/4,/2[t]/1:0,/6/1:5"),
        ]
        for (label, start, end, expected) in shapes {
            XCTAssertEqual(path(start, end, in: document), expected, label)
            XCTAssertEqual(path(end, start, in: document), expected, "\(label), reversed ends are swapped")
            let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: expected, in: document), label)
            // The root has no step of its own: it is written as its first child's start.
            let writtenStart = start.node === document.root ? DOMPosition(try XCTUnwrap(document.head)) : start
            XCTAssertEqual([resolved.start, resolved.end], [writtenStart, end], label)
        }
        // A full CFI of the whole document keeps the package path as the range's parent.
        let spine = SpineCFIs(package: nil, spineCount: 1)
        let whole = spine.cfi(spineIndex: 0, start: DOMPosition(document.root), end: DOMPosition(image), in: document)
        XCTAssertEqual(whole, "epubcfi(/6/2!,/2,/4/6/2)")
        let target = try XCTUnwrap(spine.resolve(whole))
        XCTAssertEqual(target.spineIndex, 0)
        XCTAssertEqual(resolve(target.localPath, in: document), [DOMPosition(try XCTUnwrap(document.head)), DOMPosition(image)])
        XCTAssertEqual(string(resolve("/4,/2[t]/1:0,/6/1:5", in: document), in: document), "TitleAlpha beta gammaDelta")
    }

    // MARK: - Identifiers

    /// `getElementById` compares IDs code unit by code unit: two IDs that differ only in
    /// Unicode normalization form are different elements. An assertion naming the second must
    /// not resolve to the first.
    func testAnIDAssertionMatchesItsExactCodeUnits() throws {
        let document = try page("<p id=\"caf&#xE9;\">composed</p><p id=\"cafe&#x301;\">decomposed</p>")
        let composed = try element("p", 0, in: document), decomposed = try element("p", 1, in: document)
        XCTAssertEqual(Array(try XCTUnwrap(composed.attribute("id")).unicodeScalars.map(\.value)), [0x63, 0x61, 0x66, 0xE9])
        XCTAssertEqual(Array(try XCTUnwrap(decomposed.attribute("id")).unicodeScalars.map(\.value)), [0x63, 0x61, 0x66, 0x65, 0x301])
        let cfi = path(DOMPosition(decomposed), in: document)
        XCTAssertEqual(Array(cfi.unicodeScalars.map(\.value).suffix(6)), [0x63, 0x61, 0x66, 0x65, 0x301, 0x5D], "the assertion is written as the ID is spelled")
        XCTAssertEqual(resolve(cfi, in: document)?.first?.node.textContent, "decomposed", "the element's own CFI names the other element")
        XCTAssertEqual(resolve("/4/99[cafe\u{301}]", in: document)?.first?.node.textContent, "decomposed")
        XCTAssertEqual(resolve("/4/99[caf\u{E9}]", in: document)?.first?.node.textContent, "composed")
    }

    /// The session refuses a bookmark whose value fails `EPUBCFI.isWellFormed`
    /// (`incompatibleLocation`), so every CFI the library itself writes must pass it. An element
    /// ID is written into the CFI verbatim, control characters and line separators included.
    func testEveryIssuedCFIPassesTheReadersOwnWellFormednessCheck() throws {
        let document = try page("<p id=\"plain\">a</p><p id=\"tab&#9;bed\">b</p><p id=\"next&#x85;line\">c</p><p id=\"line&#x2028;separator\">d</p>")
        let spine = SpineCFIs(package: nil, spineCount: 1)
        for node in document.nodes where node.isText && node.parent?.name == "p" {
            let cfi = spine.cfi(spineIndex: 0, start: DOMPosition(node), end: DOMPosition(node, 1), in: document)
            let id = node.parent?.attribute("id") ?? ""
            XCTAssertTrue(EPUBCFI.isWellFormed(cfi),
                          "the CFI issued inside the element with id \(id.debugDescription) is refused on restore: \(cfi.debugDescription)")
            XCTAssertEqual(cfi.components(separatedBy: "epubcfi(").count, 2, "wrapped exactly once: \(cfi.debugDescription)")
        }
    }

    /// The document's own ID table, which link fragments use too, compares as the assertion does.
    func testTheDocumentFindsAnElementByItsIDsExactCodeUnits() throws {
        let document = try page("<p id=\"caf&#xE9;\">composed</p><p id=\"cafe&#x301;\">decomposed</p>")
        XCTAssertEqual(document.element(id: "cafe\u{301}")?.textContent, "decomposed")
        XCTAssertEqual(document.element(id: "caf\u{E9}")?.textContent, "composed")
        XCTAssertNil(document.element(id: "cafe"))
    }

    /// The CFI grammar takes a control character or a line or paragraph separator in an ID only
    /// as it is, and `isWellFormed` refuses it there, so such an ID is not asserted: the step's
    /// index alone names its element. Every other ID is asserted as before.
    func testAnIDTheWellFormednessCheckRefusesIsNotAsserted() throws {
        let ids = ["tab&#9;bed", "line&#10;feed", "next&#x85;line", "c1&#x9F;control", "line&#x2028;separator", "paragraph&#x2029;separator"]
        let document = try page("<p id=\"plain\">a</p>" + ids.map { "<p id=\"\($0)\">b</p>" }.joined())
        let paragraphs = document.nodes.filter { $0.isElement && $0.name == "p" }
        XCTAssertEqual(paragraphs.compactMap { $0.attribute("id") },
                       ["plain", "tab\tbed", "line\nfeed", "next\u{85}line", "c1\u{9F}control", "line\u{2028}separator", "paragraph\u{2029}separator"])
        XCTAssertEqual(path(DOMPosition(paragraphs[0]), in: document), "/4/2[plain]")
        for (index, paragraph) in paragraphs.enumerated().dropFirst() {
            let step = "/4/\(2 * index + 2)", text = try XCTUnwrap(paragraph.children.first)
            XCTAssertEqual(path(DOMPosition(paragraph), in: document), step)
            XCTAssertEqual(path(DOMPosition(text, 0), DOMPosition(text, 1), in: document), "\(step),/1:0,/1:1")
            XCTAssertEqual(resolve("\(step),/1:0,/1:1", in: document), [DOMPosition(text, 0), DOMPosition(text, 1)])
        }
    }

    /// ID assertions are the one unbounded part of a CFI. When they take an issued CFI past the
    /// length `isWellFormed` allows, it is issued without any, and its indices name the range.
    func testACFITooLongWithItsIDAssertionsIsIssuedWithoutThem() throws {
        let long = String(repeating: "a", count: EPUBCFI.maximumLength)
        let document = try page("<section id=\"s\"><p id=\"\(long)\">long</p><p id=\"short\">short</p></section>")
        let longText = try text("long", in: document), shortText = try text("short", in: document)
        let spine = SpineCFIs(package: nil, spineCount: 1)
        let ranges = [(DOMPosition(shortText, 1), DOMPosition(shortText, 3), "epubcfi(/6/2!/4/2[s]/4[short],/1:1,/1:3)"),
                      (DOMPosition(longText, 1), DOMPosition(longText, 3), "epubcfi(/6/2!/4/2/2,/1:1,/1:3)"),
                      (DOMPosition(longText, 1), DOMPosition(shortText, 3), "epubcfi(/6/2!/4/2,/2/1:1,/4/1:3)")]
        for (start, end, expected) in ranges {
            let cfi = spine.cfi(spineIndex: 0, start: start, end: end, in: document)
            XCTAssertEqual(cfi, expected)
            XCTAssertTrue(EPUBCFI.isWellFormed(cfi), expected)
            let target = try XCTUnwrap(spine.resolve(cfi), expected)
            XCTAssertEqual(resolve(target.localPath, in: document), [start, end], expected)
        }
    }

    func testUnqualifiedHTMLIssuesNoCFIAtAnyLevel() throws {
        let document = try parse("<html><head><title>Book</title></head><body><table><tr><td>Cell</td></tr></table></body></html>")
        XCTAssertTrue(document.recoveredAsHTML)
        XCTAssertFalse(document.canResolveCFIs)
        let cell = try text("Cell", in: document)
        XCTAssertEqual(path(DOMPosition(cell), DOMPosition(cell, 4), in: document), "")
        XCTAssertEqual(SpineCFIs(package: nil, spineCount: 1).cfi(spineIndex: 0, start: DOMPosition(cell), end: DOMPosition(cell, 4), in: document), "")
        for cfi in ["/4/2/2/2/1:0", "/4/2/2/2/2/1:0", "/4", "/0", "/4/2,/1:0,/1:1"] { XCTAssertNil(resolve(cfi, in: document), cfi) }
    }
}
