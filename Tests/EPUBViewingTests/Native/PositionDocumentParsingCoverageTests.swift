import EPUBCore
import Foundation
import libxml2
import os
import XCTest
@testable import EPUBViewing

/// `ContentDocument` on markup the recorded vectors and tidy fixtures do not contain: entity
/// sets, encodings, DOCTYPE variants, namespaces, limits at their boundaries, input that is not
/// well-formed, and the boundaries of the qualified XML-shaped HTML subset.
final class PositionDocumentParsingCoverageTests: XCTestCase {
    private static let xhtml = #"xmlns="http://www.w3.org/1999/xhtml""#
    private static let head = "<head><title>T</title></head>"
    private static let xhtml11 = #"<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">"#

    private func parse(_ markup: String, limits: ContentLimits = .init()) throws -> ContentDocument {
        try ContentDocument.parse(Data(markup.utf8), path: "parsing.xhtml", limits: limits)
    }
    private func page(_ body: String, prolog: String = "", root: String = "") throws -> ContentDocument {
        try parse("\(prolog)<html \(Self.xhtml)\(root)>\(Self.head)<body>\(body)</body></html>")
    }
    /// Elements as `<name>` and text as itself, in document order.
    private func model(_ document: ContentDocument) -> [String] { document.nodes.map { $0.isElement ? "<\($0.name)>" : $0.text } }
    private func bodyText(_ document: ContentDocument) -> String { document.body?.textContent ?? "" }
    private func first(_ name: String, in document: ContentDocument) throws -> ContentNode {
        try XCTUnwrap(document.nodes.first { $0.isElement && $0.name == name }, "no \(name)")
    }

    // MARK: - Entities and character references

    /// The XHTML 1.x DTDs' entity sets (Latin-1, symbols, special) parse without loading a DTD,
    /// in text and in attribute values; CDATA and comments are left alone.
    func testNamedEntitiesOfTheXHTMLDTDsBecomeTheirCharacters() throws {
        let document = try parse("""
        \(Self.xhtml11)<html \(Self.xhtml)><head><title>Entit&eacute;s</title></head><body>\
        <p title="a&nbsp;b&amp;c&lt;d&quot;e&apos;f&mdash;g">&nbsp;&mdash;&Eacute;&eacute;&apos;&amp;nbsp;&frac12;&sup2;&there4;&thetasym;&euro;&OElig;&zwnj;&lt;&gt;&quot;</p>\
        <p><![CDATA[&nbsp;&eacute;]]><!-- &nbsp; &bogus; -->&nbsp;</p><p>AT&amp;T &amp;amp; &#38;eacute;</p></body></html>
        """)
        XCTAssertFalse(document.recoveredAsHTML)
        XCTAssertTrue(document.canResolveCFIs)
        let paragraphs = document.nodes.filter { $0.isHTML("p") }
        XCTAssertEqual(paragraphs[0].textContent, "\u{A0}—Éé'&nbsp;½²∴ϑ€Œ\u{200C}<>\"")
        XCTAssertEqual(paragraphs[0].attribute("title"), "a\u{A0}b&c<d\"e'f—g")
        XCTAssertEqual(paragraphs[1].textContent, "&nbsp;&eacute;\u{A0}", "CDATA is literal and the comment is gone")
        XCTAssertEqual(paragraphs[1].children.count, 1, "one merged text node")
        XCTAssertEqual(paragraphs[2].textContent, "AT&T &amp; &eacute;", "an escaped ampersand never becomes a reference")
        XCTAssertEqual(document.head?.textContent, "Entités")
        // A reference is one character for a CFI offset: the text after it keeps its place.
        let text = try XCTUnwrap(paragraphs[0].children.first)
        XCTAssertEqual(text.utf16Length, 21)
        XCTAssertEqual(EPUBCFI.localPath(from: DOMPosition(text, 2), to: DOMPosition(text, 4), in: document), "/4/2,/1:2,/1:4")
        // Names are case-sensitive, as the DTD's are.
        XCTAssertEqual(try parse("\(Self.xhtml11)<html \(Self.xhtml)>\(Self.head)<body><p>&Alpha;&alpha;&Prime;&prime;&Dagger;&dagger;</p></body></html>")
            .body?.textContent, "Αα″′‡†")
    }

    func testNumericCharacterReferencesOfEveryPlane() throws {
        let document = try page("<p>&#65;&#x42;&#x1D49C;&#128512;&#xA0;&#x9;&#xD;&#x10FFFF;&#xE9;&#0233;&#x000E9;</p>")
        XCTAssertFalse(document.recoveredAsHTML)
        let text = try XCTUnwrap(try first("p", in: document).children.first)
        XCTAssertEqual(Array(text.text.unicodeScalars.map(\.value)), [0x41, 0x42, 0x1D49C, 0x1F600, 0xA0, 0x9, 0xD, 0x10FFFF, 0xE9, 0xE9, 0xE9])
        XCTAssertEqual(text.utf16Length, 14, "astral characters are two units")

        // References XML forbids make the document not well-formed: it is read as HTML, says so,
        // keeps the text around them, and issues no CFIs.
        for reference in ["&#0;", "&#x0;", "&#xD800;", "&#xDFFF;", "&#xFFFE;", "&#x110000;", "&#1;", "&#x1F;", "&#99999999999;", "&#x;", "&#;"] {
            let recovered = try page("<p>left\(reference)right</p><p>after</p>")
            XCTAssertTrue(recovered.recoveredAsHTML, reference)
            XCTAssertFalse(recovered.canResolveCFIs, reference)
            XCTAssertTrue(bodyText(recovered).hasPrefix("left"), reference)
            XCTAssertTrue(bodyText(recovered).hasSuffix("after"), reference)
            XCTAssertTrue(bodyText(recovered).contains("right"), reference)
        }
    }

    /// HTML Standard, section 14.2 (Parsing XML documents): the XHTML public identifiers stand
    /// for "a DTD containing the entity declarations for the names listed in the named character
    /// references section": every HTML name, not only HTML 4's. WebKit resolves them so, and
    /// foliate's CFI offsets counted the characters they produce.
    func testHTML5NamedReferencesResolveUnderAnXHTMLDoctype() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/100")
        let document = try parse("\(Self.xhtml11)<html \(Self.xhtml)>\(Self.head)<body><p>Dvo&rcaron;&aacute;k &check; done</p></body></html>")
        XCTAssertEqual(bodyText(document), "Dvořák ✓ done", "the characters of the references are missing from the text")
        let text = try XCTUnwrap(document.body?.children.first?.children.first)
        XCTAssertEqual(text.utf16Length, 13, "CFI offsets after a dropped reference name another character")
    }

    /// An entity the DTD cannot declare is an error in WebKit, which foliate answered by reading
    /// the file as HTML, where the reference stays as the text the author wrote. Dropping it
    /// leaves no trace that anything was there.
    func testAnUndeclaredEntityUnderADoctypeIsNotSilentlyDropped() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/100")
        let document = try parse("\(Self.xhtml11)<html \(Self.xhtml)>\(Self.head)<body><p title=\"a&bogus;b\">10&bogus;20</p></body></html>")
        XCTAssertEqual(bodyText(document), "10&bogus;20", "the reference vanished from the text")
        XCTAssertEqual(try first("p", in: document).attribute("title"), "a&bogus;b", "the reference vanished from the attribute")
        XCTAssertTrue(document.recoveredAsHTML, "a document WebKit rejects as XML is one foliate re-read as HTML")
    }

    /// EPUB 3.3, section 3.9 (XML conformance): an XML-based resource "MUST be encoded in UTF-8
    /// or UTF-16". A UTF-16 XHTML 1.1 document may use the DTD's entities like any other.
    func testNamedEntitiesSurviveInUTF16Documents() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/100")
        let markup = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\(Self.xhtml11)<html \(Self.xhtml)>\(Self.head)"
            + "<body><p>caf&eacute;&nbsp;cr&egrave;me</p></body></html>"
        for (label, bom, encoding) in [("little endian", [UInt8](arrayLiteral: 0xFF, 0xFE), String.Encoding.utf16LittleEndian),
                                       ("big endian", [0xFE, 0xFF], .utf16BigEndian)] {
            let data = Data(bom) + (try XCTUnwrap(markup.data(using: encoding)))
            let document = try ContentDocument.parse(data, path: "wide.xhtml")
            XCTAssertEqual(bodyText(document), "café\u{A0}crème", "\(label): the referenced characters are missing")
        }
    }

    // MARK: - Encodings and declarations

    func testUTF8UTF16AndDeclaredLegacyEncodingsDecode() throws {
        let body = "<p>é😀 wide — text</p>"
        func document(_ declaration: String) -> String { "\(declaration)<html \(Self.xhtml)>\(Self.head)<body>\(body)</body></html>" }
        let utf16 = document("<?xml version=\"1.0\" encoding=\"UTF-16\"?>")
        let inputs: [(String, Data)] = [
            ("UTF-8", Data(document("").utf8)),
            ("UTF-8 with a declaration", Data(document("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n").utf8)),
            ("UTF-8 with a byte order mark", Data([0xEF, 0xBB, 0xBF]) + Data(document("<?xml version=\"1.0\" encoding=\"utf-8\"?>").utf8)),
            ("UTF-16 little endian", Data([0xFF, 0xFE]) + (try XCTUnwrap(utf16.data(using: .utf16LittleEndian)))),
            ("UTF-16 big endian", Data([0xFE, 0xFF]) + (try XCTUnwrap(utf16.data(using: .utf16BigEndian)))),
            ("UTF-16 without a byte order mark", try XCTUnwrap(utf16.data(using: .utf16LittleEndian))),
            ("UTF-16 without a declaration", Data([0xFF, 0xFE]) + (try XCTUnwrap(document("").data(using: .utf16LittleEndian)))),
        ]
        for (label, data) in inputs {
            let parsed = try ContentDocument.parse(data, path: "encoded.xhtml")
            XCTAssertFalse(parsed.recoveredAsHTML, label)
            XCTAssertTrue(parsed.canResolveCFIs, label)
            XCTAssertEqual(bodyText(parsed), "é😀 wide — text", label)
            XCTAssertEqual(parsed.body?.children.first?.children.first?.utf16Length, 15, label)
        }
        // A declared single-byte encoding is honoured for well-formed XHTML.
        func legacy(_ name: String, _ bytes: [UInt8]) -> Data {
            Data("<?xml version=\"1.0\" encoding=\"\(name)\"?><html \(Self.xhtml)>\(Self.head)<body><p>caf".utf8) + Data(bytes) + Data("</p></body></html>".utf8)
        }
        XCTAssertEqual(bodyText(try ContentDocument.parse(legacy("ISO-8859-1", [0xE9]), path: "latin1.xhtml")), "café")
        XCTAssertEqual(bodyText(try ContentDocument.parse(legacy("windows-1252", [0xE9, 0x20, 0x93, 0x97, 0x94]), path: "cp1252.xhtml")), "café “—”")
        XCTAssertEqual(bodyText(try ContentDocument.parse(legacy("US-ASCII", [0x65]), path: "ascii.xhtml")), "cafe")
    }

    func testDoctypeVariantsLeaveStrictXHTMLAlone() throws {
        let reference = model(try page("<p>One <b>two</b></p>"))
        let doctypes = [
            "<!DOCTYPE html>", "<!DOCTYPE html >", "<!DOCTYPE html SYSTEM \"about:legacy-compat\">", "<!DOCTYPE html SYSTEM 'about:legacy-compat'>",
            Self.xhtml11, "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">",
            "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">",
            "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Frameset//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-frameset.dtd\">",
            "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML+RDFa 1.0//EN\" \"http://www.w3.org/MarkUp/DTD/xhtml-rdfa-1.dtd\">",
            "<!DOCTYPE html PUBLIC \"-//Unknown//DTD Anything//EN\" \"anything[1].dtd\">",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n<!DOCTYPE html>\n", "<?xml version='1.0'?><!-- before --><!DOCTYPE html><!-- after -->",
        ]
        for doctype in doctypes {
            let document = try page("<p>One <b>two</b></p>", prolog: doctype)
            XCTAssertFalse(document.recoveredAsHTML, doctype)
            XCTAssertTrue(document.canResolveCFIs, doctype)
            XCTAssertEqual(model(document), reference, doctype)
        }
        // An internal subset is refused before any parsing, declarations in it or not.
        for doctype in ["<!DOCTYPE html [<!ENTITY e \"x\">]>", "<!DOCTYPE html []>", "<!DOCTYPE html [ <!ATTLIST p note CDATA #IMPLIED> ]>",
                        "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"xhtml11.dtd\" [ <!-- nothing --> ]>",
                        "<!DOCTYPE html [<!ENTITY % all SYSTEM \"http://example.invalid/all.ent\"> %all;]>"] {
            XCTAssertThrowsError(try page("<p>One</p>", prolog: doctype), doctype) { error in
                XCTAssertEqual(error as? ContentDocumentError, .unsafeMarkup("parsing.xhtml"), doctype)
            }
        }
    }

    /// HTML Standard, section 14.2: these public identifiers all name the entity DTD, so a
    /// document using any of them with a named reference is well-formed XML to WebKit and kept
    /// its XML tree (and its CFIs) in foliate. The same markup read as HTML grows a `tbody`.
    func testEveryXHTMLPublicIdentifierKeepsItsXMLTree() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/101")
        let identifiers = [
            "-//W3C//DTD XHTML 1.0 Transitional//EN", "-//W3C//DTD XHTML 1.1//EN", "-//W3C//DTD XHTML 1.0 Strict//EN",
            "-//W3C//DTD XHTML 1.0 Frameset//EN", "-//W3C//DTD XHTML Basic 1.0//EN", "-//W3C//DTD XHTML 1.1 plus MathML 2.0//EN",
            "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN", "-//W3C//DTD MathML 2.0//EN", "-//WAPFORUM//DTD XHTML Mobile 1.0//EN",
            "-//WAPFORUM//DTD XHTML Mobile 1.1//EN", "-//WAPFORUM//DTD XHTML Mobile 1.2//EN",
        ]
        for identifier in identifiers {
            let document = try page("<table><tr><td>a&nbsp;b</td></tr></table>", prolog: "<!DOCTYPE html PUBLIC \"\(identifier)\" \"http://example.invalid/x.dtd\">")
            XCTAssertEqual(bodyText(document), "a\u{A0}b", identifier)
            XCTAssertFalse(document.recoveredAsHTML, "\(identifier): read as HTML, though WebKit parses it as XML")
            XCTAssertTrue(document.canResolveCFIs, "\(identifier): saved positions are refused in a section foliate issued them for")
        }
    }

    // MARK: - Namespaces, attributes, identifiers and language

    func testNamespacesPrefixesAndAttributeLookups() throws {
        let document = try parse("""
        <h:html xmlns:h="http://www.w3.org/1999/xhtml" xmlns:ops="http://www.idpf.org/2007/ops" xmlns:m="http://www.w3.org/1998/Math/MathML" \
        xmlns:s="http://www.w3.org/2000/svg" xmlns:xl="http://www.w3.org/1999/xlink"><h:head><h:title>T</h:title></h:head>\
        <h:body ops:type="bodymatter  chapter\n frontmatter" class=" a\tb\nc "><h:p id="plain" h:id="qualified" title="t" xl:title="linked">text</h:p>\
        <m:math><m:mfrac><m:mn>1</m:mn><m:mn>2</m:mn></m:mfrac></m:math>\
        <s:svg viewBox="0 0 1 1"><s:linearGradient id="g"/><s:image xl:href="a.png" href="b.png"/></s:svg>\
        <section xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" epub:type="footnote">default namespace</section></h:body></h:html>
        """)
        XCTAssertFalse(document.recoveredAsHTML)
        XCTAssertEqual(document.root.name, "html")
        XCTAssertEqual(document.root.namespace, ContentNamespace.xhtml)
        XCTAssertTrue(document.root.isHTML("html"))
        XCTAssertNotNil(document.head)
        let body = try XCTUnwrap(document.body)
        XCTAssertEqual(body.epubTypes, ["bodymatter", "chapter", "frontmatter"], "whatever prefix binds the OPS namespace")
        XCTAssertEqual(body.classNames, ["a", "b", "c"])
        let paragraph = try first("p", in: document)
        XCTAssertEqual(paragraph.attribute("id"), "plain", "an attribute in no namespace")
        XCTAssertEqual(paragraph.attribute("id", namespace: ContentNamespace.xhtml), "qualified")
        XCTAssertEqual(paragraph.id, "plain")
        XCTAssertEqual(paragraph.attribute("title"), "t")
        XCTAssertEqual(paragraph.attribute("title", namespace: ContentNamespace.xlink), "linked")
        XCTAssertNil(paragraph.attribute("type"))
        XCTAssertTrue(document.element(id: "plain") === paragraph)
        XCTAssertNil(document.element(id: "qualified"), "a namespaced id attribute is not an ID")
        let fraction = try first("mfrac", in: document)
        XCTAssertEqual(fraction.namespace, ContentNamespace.mathML)
        XCTAssertFalse(fraction.isHTML)
        let gradient = try first("linearGradient", in: document)
        XCTAssertEqual(gradient.namespace, ContentNamespace.svg, "foreign names keep their case")
        XCTAssertEqual(gradient.parent?.attribute("viewBox"), "0 0 1 1")
        let image = try first("image", in: document)
        XCTAssertEqual(image.attribute("href", namespace: ContentNamespace.xlink), "a.png")
        XCTAssertEqual(image.attribute("href"), "b.png")
        let section = try first("section", in: document)
        XCTAssertTrue(section.isHTML("section"))
        XCTAssertEqual(section.epubTypes, ["footnote"])
        XCTAssertEqual(section.elementChildren.count, 0)
        XCTAssertEqual(body.elementChildren.map(\.name), ["p", "math", "svg", "section"])
    }

    func testTheDocumentLanguagePrefersXMLLang() throws {
        func language(root: String = "", body: String = "") throws -> String? {
            try parse("<html \(Self.xhtml)\(root)>\(Self.head)<body\(body)><p>x</p></body></html>").language
        }
        XCTAssertNil(try language())
        XCTAssertEqual(try language(root: " lang=\"de\""), "de")
        XCTAssertEqual(try language(root: " xml:lang=\"fr\""), "fr")
        XCTAssertEqual(try language(root: " xml:lang=\"fr\" lang=\"de\""), "fr")
        XCTAssertEqual(try language(root: " lang=\"de\" xml:lang=\"fr\""), "fr", "whatever order they are written in")
        XCTAssertEqual(try language(body: " lang=\"it\""), "it")
        XCTAssertEqual(try language(root: " lang=\"de\"", body: " xml:lang=\"it\""), "de", "the root element's language first")
        let paragraph = try first("p", in: try page("<p xml:lang=\"es\" lang=\"pt\">x</p>"))
        XCTAssertEqual(paragraph.language, "es")
    }

    func testIdentifierLookupsFindTheFirstElementInTreeOrder() throws {
        let document = try page("<div><p id=\"dup\">first</p></div><p id=\"dup\">second</p><p xml:id=\"early\">third</p><p id=\"early\">fourth</p>"
            + "<p id=\"both\" xml:id=\"other\">fifth</p><svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"in-svg\"/></svg><p ID=\"upper\">sixth</p>")
        XCTAssertEqual(document.element(id: "dup")?.textContent, "first")
        XCTAssertEqual(document.element(id: "early")?.textContent, "third", "an xml:id is an identifier for lookups")
        XCTAssertEqual(document.element(id: "both")?.textContent, "fifth")
        XCTAssertEqual(document.element(id: "both")?.id, "both", "id before xml:id on one element")
        XCTAssertNil(document.element(id: "other"))
        XCTAssertEqual(document.element(id: "in-svg")?.name, "g")
        XCTAssertNil(document.element(id: "upper"), "XML attribute names are case-sensitive")
        XCTAssertNil(document.element(id: "missing"))
        XCTAssertNil(document.element(id: "DUP"), "IDs are case-sensitive")
        // An ID assertion finds only `id` attributes, as getElementById does.
        XCTAssertEqual(EPUBCFI.resolve(localPath: "/4/99[early]", in: document)?.start.node.textContent, "fourth")
        XCTAssertEqual(EPUBCFI.resolve(localPath: "/4/99[dup]", in: document)?.start.node.textContent, "first")
    }

    func testEmptyElementSpellingsBuildTheSameTree() throws {
        let spellings = try page("<p>a<br/>b<br></br>c<br />d<br\n/>e</p><p/><p></p><div><span/><span></span></div>")
        XCTAssertFalse(spellings.recoveredAsHTML)
        XCTAssertEqual(Array(model(spellings).dropFirst(5)),
                       ["<p>", "a", "<br>", "b", "<br>", "c", "<br>", "d", "<br>", "e", "<p>", "<p>", "<div>", "<span>", "<span>"])
        XCTAssertTrue(spellings.nodes.filter { $0.isHTML("br") }.allSatisfy { $0.children.isEmpty })
        // The paths through them are the same however they are spelled.
        let tail = try XCTUnwrap(spellings.nodes.first { $0.isText && $0.text == "e" })
        XCTAssertEqual(EPUBCFI.localPath(from: DOMPosition(tail), to: DOMPosition(tail), in: spellings), "/4/2/9:0")
    }

    func testCommentsAndProcessingInstructionsVanishAndCharacterDataMerges() throws {
        let document = try parse("<?xml version=\"1.0\"?><?xml-stylesheet href=\"a.css\" type=\"text/css\"?><!-- lead --><html \(Self.xhtml)><!-- in root -->"
            + "\(Self.head)<body><?target data?><p>a<?pi?>b<!-- c -->c<![CDATA[d]]>e&#102;&amp;</p><p><!-- only a comment --></p>"
            + "<p><![CDATA[]]></p><p><![CDATA[ ]]><!----> </p><p>x<![CDATA[]]>y</p></body></html><!-- trail --><?after?>")
        XCTAssertFalse(document.recoveredAsHTML)
        let paragraphs = document.nodes.filter { $0.isHTML("p") }
        XCTAssertEqual(paragraphs.map { $0.children.map(\.text) }, [["abcdef&"], [], [""], ["  "], ["xy"]])
        XCTAssertEqual(document.root.children.count, 2, "nothing but the head and body")
        XCTAssertEqual(document.body?.children.count, 5)
        // An empty CDATA section is still character data: the paragraph has a (empty) chunk.
        XCTAssertEqual(paragraphs[2].children.first?.utf16Length, 0)
    }

    // MARK: - Limits

    func testDepthNodeAndByteLimitsAtTheirBoundaries() throws {
        func nested(_ depth: Int) -> String {
            "<html \(Self.xhtml)><body>" + String(repeating: "<div>", count: depth) + "leaf" + String(repeating: "</div>", count: depth) + "</body></html>"
        }
        // The root is depth 0 and the body 1, so 198 divisions reach the default depth of 200.
        XCTAssertEqual(try parse(nested(198)).nodes.last?.text, "leaf")
        for depth in [199, 200, 255, 256, 257, 1_000, 20_000] {
            XCTAssertThrowsError(try parse(nested(depth)), "\(depth) divisions") { error in
                XCTAssertEqual(error as? ContentDocumentError, .limitExceeded("depth"), "\(depth) divisions")
            }
        }
        var limits = ContentLimits(); limits.depth = 5
        XCTAssertEqual(try parse(nested(3), limits: limits).nodes.count, 6)
        XCTAssertThrowsError(try parse(nested(4), limits: limits))
        // Unclosed elements nest just as deeply once the HTML parser has read them.
        XCTAssertThrowsError(try parse("<html><body>" + String(repeating: "<div>", count: 5_000) + "leaf")) { error in
            XCTAssertEqual(error as? ContentDocumentError, .limitExceeded("depth"))
        }

        let small = "<html \(Self.xhtml)><body><p>t</p></body></html>" // html, body, p, text
        limits = ContentLimits(); limits.nodes = 4
        XCTAssertEqual(try parse(small, limits: limits).nodes.count, 4)
        limits.nodes = 3
        XCTAssertThrowsError(try parse(small, limits: limits)) { XCTAssertEqual($0 as? ContentDocumentError, .limitExceeded("nodes")) }
        limits = ContentLimits(); limits.nodes = 1_000
        let wide = "<html \(Self.xhtml)><body>" + String(repeating: "<i>x</i>", count: 499) + "</body></html>"
        XCTAssertEqual(try parse(wide, limits: limits).nodes.count, 1_000)
        XCTAssertThrowsError(try parse(wide.replacingOccurrences(of: "</body>", with: "y</body>"), limits: limits))

        limits = ContentLimits(); limits.bytes = small.utf8.count
        XCTAssertNoThrow(try parse(small, limits: limits))
        limits.bytes -= 1
        XCTAssertThrowsError(try parse(small, limits: limits)) { XCTAssertEqual($0 as? ContentDocumentError, .limitExceeded("bytes")) }
        // The byte limit counts the file, not its decoded text.
        let wideBytes = Data([0xFF, 0xFE]) + (try XCTUnwrap(small.data(using: .utf16LittleEndian)))
        limits.bytes = wideBytes.count
        XCTAssertNoThrow(try ContentDocument.parse(wideBytes, path: "wide.xhtml", limits: limits))
        limits.bytes -= 1
        XCTAssertThrowsError(try ContentDocument.parse(wideBytes, path: "wide.xhtml", limits: limits))
    }

    func testLargeAttributesNamesAndSiblingRunsAreRead() throws {
        let value = String(repeating: "v", count: 1_000_000)
        let attributes = (0..<2_000).map { "a\($0)=\"\($0)\"" }.joined(separator: " ")
        let document = try page("<p title=\"\(value)\" \(attributes)>x</p>" + String(repeating: "<br/>", count: 20_000))
        XCTAssertFalse(document.recoveredAsHTML)
        let paragraph = try first("p", in: document)
        XCTAssertEqual(paragraph.attribute("title")?.utf8.count, 1_000_000)
        XCTAssertEqual(paragraph.attribute("a1999"), "1999")
        XCTAssertEqual(paragraph.attributes.count, 2_001)
        XCTAssertEqual(document.body?.children.count, 20_001)
        let last = try XCTUnwrap(document.nodes.last)
        XCTAssertEqual(EPUBCFI.localPath(from: DOMPosition(last), to: DOMPosition(last), in: document), "/4/40002", "20,001 adjacent elements")
    }

    // MARK: - Input that is not XML

    func testEmptyAndDegenerateInputThrowsRatherThanTraps() throws {
        for (label, data) in [("empty", Data()), ("white space", Data("  \n\t ".utf8)), ("only a declaration", Data("<?xml version=\"1.0\"?>".utf8)),
                              ("only a comment", Data("<!-- nothing -->".utf8)), ("only a doctype", Data("<!DOCTYPE html>".utf8)),
                              ("a byte order mark", Data([0xEF, 0xBB, 0xBF]))] {
            XCTAssertThrowsError(try ContentDocument.parse(data, path: "degenerate.xhtml"), label) { error in
                XCTAssertEqual(error as? ContentDocumentError, .malformed("degenerate.xhtml"), label)
            }
        }
        // Fragments and truncated files either read as recovered HTML or throw; none may trap.
        for markup in ["x", "<", ">", "<>", "</>", "</p>", "<p", "<p ", "<p a", "<p a=", "<p a=\"", "<p a=\"b", "<p a='b'", "<!", "<!-", "<!--", "<!-- x", "<!-- x -",
                       "<![", "<![CDATA[", "<![CDATA[x", "<![CDATA[x]]", "<?", "<?x", "<?xml", "<?xml version=\"1.0\"", "<!DOCTYPE", "<!DOCTYPE html", "<!DOCTYPE html [",
                       "&", "&#", "&#x", "&a", "&amp", "&nbsp", "&;", "&#;", "<p>&", "<p>&#", "<p>&nbsp", "<html", "<html>", "<html><body>", "<html></html>",
                       "<html \(Self.xhtml)", "<html \(Self.xhtml)>", "<html \(Self.xhtml)><body><p>cut", "\u{0}", "<p>\u{0}</p>", "\u{FEFF}", "]]>", "<a><b></a></b>",
                       "<html \(Self.xhtml)><body></body></html><html \(Self.xhtml)/>", "<html \(Self.xhtml)></html>trailing"] {
            if let document = try? parse(markup) {
                XCTAssertTrue(document.recoveredAsHTML, markup.debugDescription)
                XCTAssertEqual(document.nodes.first === document.root, true, markup.debugDescription)
            }
        }
        XCTAssertEqual(try parse("just some text").body?.textContent, "just some text", "bare text is readable")
    }

    /// doc/native-viewer.md: "markup that is not well-formed falls back to libxml2's HTML parser
    /// and is reported", "Unqualified HTML repairs remain readable but cannot issue or resolve
    /// CFIs".
    func testMarkupThatIsNotWellFormedIsReadAsHTMLAndSaysSo() throws {
        let cases: [(String, String, [String])] = [
            ("an unescaped ampersand", "<p>AT&T and Q&A; R&D</p><p>next</p>", ["AT&T and Q&A; R&D", "next"]),
            ("an ampersand in a link", "<p><a href=\"x?a=1&b=2\">link</a> after</p>", ["link", " after"]),
            ("unclosed void elements", "<p>one<br>two<img src=\"a.png\">three</p><p>next</p>", ["one", "two", "three", "next"]),
            ("an unquoted attribute", "<p class=a>one</p><p>next</p>", ["one", "next"]),
            ("an unclosed paragraph", "<p>one<p>two", ["one", "two"]),
            ("misnested inline elements", "<p><b>bold <i>both</b> italic</i> tail</p><p>next</p>", ["bold ", "both", "tail", "next"]),
            ("a missing end tag", "<div><p>one</div><p>two</p>", ["one", "two"]),
            ("text after the root", "<p>one</p></body></html>trailing", ["one", "trailing"]),
            ("a form feed", "<p>one\u{C}two</p><p>next</p>", ["one", "two", "next"]),
            ("an uppercase end tag", "<p>one</P><p>two</p>", ["one", "two"]),
        ]
        for (label, body, expected) in cases {
            let document = try parse("<html \(Self.xhtml)>\(Self.head)<body>\(body)</body></html>")
            XCTAssertTrue(document.recoveredAsHTML, label)
            XCTAssertFalse(document.canResolveCFIs, label)
            let text = document.root.textContent
            for word in expected { XCTAssertTrue(text.contains(word), "\(label): \(word.debugDescription) is missing from \(text.debugDescription)") }
            let node = try XCTUnwrap(document.nodes.first(where: \.isText), label)
            XCTAssertEqual(EPUBCFI.localPath(from: DOMPosition(node), to: DOMPosition(node, 1), in: document), "", label)
            XCTAssertNil(EPUBCFI.resolve(localPath: "/4/2/1:0", in: document), label)
        }
        let link = try parse("<html \(Self.xhtml)>\(Self.head)<body><p><a href=\"x?a=1&b=2\">link</a></p></body></html>")
        XCTAssertEqual(try first("a", in: link).attribute("href"), "x?a=1&b=2")
    }

    /// The same contract for a `<` the author did not escape: foliate re-read such a file as
    /// HTML, where "<" before anything but a tag name is text (HTML Standard, tokenization, Tag
    /// open state: "Emit a U+003C LESS-THAN SIGN character token").
    func testAStrayLessThanSignDoesNotWithholdTheSection() throws {
        let markup = "<html \(Self.xhtml)>\(Self.head)<body><p>if x < y then it's done</p><p>next</p></body></html>"
        XCTAssertNoThrow(try parse(markup), "a quotation mark after the stray sign makes the whole section unreadable")
    }

    /// The other shapes of that defect, each read by the HTML parser, and what the screen
    /// still refuses beside a stray sign or quotation mark: neither hides a declaration.
    func testStraySignsAndQuotationMarksFallBackAndHideNoDeclaration() throws {
        let cases = [
            ("a sign before a space", "<p>if x < y then it's done</p><p>next</p>"),
            ("a sign before a letter", "<p>if x <y then it's done</p><p>next</p>"),
            ("a sign before a no-break space", "<p>if x <\u{A0}y then it's done</p><p>next</p>"),
            ("an apostrophe in an unquoted value", "<p title=it's>if x</p><p>next</p>"),
            ("a quotation mark after a quoted value", "<p title=\"5\" tall\">if x</p><p>it's</p><p>next</p>"),
        ]
        for (label, body) in cases {
            let document = try page(body)
            XCTAssertTrue(document.recoveredAsHTML, label)
            XCTAssertTrue(bodyText(document).hasPrefix("if x"), "\(label): \(bodyText(document).debugDescription)")
            XCTAssertTrue(bodyText(document).contains("next"), "\(label): \(bodyText(document).debugDescription)")
        }
        let styled = try parse("<html \(Self.xhtml)><head><title>T</title><style>a::after { content: \"<\" }</style></head><body><p>it's</p><p>next</p></body></html>")
        XCTAssertTrue(styled.recoveredAsHTML)
        XCTAssertEqual(styled.nodes.filter { $0.isHTML("p") }.map(\.textContent), ["it's", "next"])

        let refused = [
            "<p>x < y's <!ENTITY e \"hidden\"> &e;</p>", "<p>x < \"<!DOCTYPE html [<!ENTITY e 'hidden'>]>\" > &e;</p>",
            "<p>x <y it's> <!DOCTYPE html [<!ENTITY e \"hidden\">]> &e;</p>", "<p a'> <!ENTITY e \"hidden\"> '>&e;</p>",
        ]
        for body in refused {
            XCTAssertThrowsError(try page(body), body) { XCTAssertEqual($0 as? ContentDocumentError, .unsafeMarkup("parsing.xhtml"), body) }
        }
        XCTAssertThrowsError(try page("<p>x < y's &e;</p>", prolog: "<!DOCTYPE html [<!ENTITY e \"hidden\">]>")) { error in
            XCTAssertEqual(error as? ContentDocumentError, .unsafeMarkup("parsing.xhtml"))
        }
        // An internal subset to libxml2, which reads on from the `[` although the DOCTYPE has
        // closed, with or without a stray sign in the text.
        for body in ["<p>One</p>", "<p>x < y's</p>"] {
            XCTAssertThrowsError(try page(body, prolog: "<!DOCTYPE html>[<!ATTLIST p title CDATA \"hidden\">]>"), body) { error in
                XCTAssertEqual(error as? ContentDocumentError, .unsafeMarkup("parsing.xhtml"), body)
            }
        }
    }

    func testTextAfterAStrayLessThanSignSurvivesTheFallback() throws {
        let document = try parse("<html \(Self.xhtml)>\(Self.head)<body><p>if x < y then done</p><p>next</p></body></html>")
        XCTAssertTrue(document.recoveredAsHTML)
        XCTAssertTrue(bodyText(document).contains("next"))
        XCTAssertTrue(bodyText(document).contains("y then done"), "the rest of the sentence is gone: \(bodyText(document).debugDescription)")
    }

    /// U+FDD0 or a noncharacter after it, which a Swift literal may not hold.
    private static func noncharacter(_ offset: UInt32 = 0) -> Unicode.Scalar { Unicode.Scalar(0xFDD0 + offset)! }

    /// Elements as `<name>` and text as itself, for what the body holds.
    private func bodyModel(_ document: ContentDocument) -> [String] {
        guard let body = document.body else { return [] }
        return document.nodes[(body.order + 1)..<(body.subtreeEnd + 1)].map { $0.isElement ? "<\($0.name)>" : $0.text }
    }

    /// Every `<` the HTML tokenizer emits as a character is text in the fallback (tag open state:
    /// "Anything else", which is all but an ASCII letter, `/`, `!` and `?`), and the paragraph
    /// after it is still a paragraph of its own. libxml2 alone discards each one with the text
    /// through the next `>`, and makes elements of `<.05`, `<_b` and `<:b`.
    func testEverySignHTMLReadsAsACharacterIsKeptInTheFallback() throws {
        let cases: [(String, String, [String])] = [
            ("a space", "<p>if x < y then done</p><p>next</p>", ["<p>", "if x < y then done", "<p>", "next"]),
            ("a digit", "<p>p <0.05 and 1 <2</p><p>next</p>", ["<p>", "p <0.05 and 1 <2", "<p>", "next"]),
            ("a full stop", "<p>p <.05 and q</p><p>next</p>", ["<p>", "p <.05 and q", "<p>", "next"]),
            ("an equals sign", "<p>x <= y and y >= z</p><p>next</p>", ["<p>", "x <= y and y >= z", "<p>", "next"]),
            ("another sign", "<p>a << b <<< c</p><p>next</p>", ["<p>", "a << b <<< c", "<p>", "next"]),
            ("a greater-than sign", "<p>a <> b</p><p>next</p>", ["<p>", "a <> b", "<p>", "next"]),
            ("a hyphen", "<p>a <- b <-- c</p><p>next</p>", ["<p>", "a <- b <-- c", "<p>", "next"]),
            ("an underscore", "<p>a <_b > c</p><p>next</p>", ["<p>", "a <_b > c", "<p>", "next"]),
            ("a colon", "<p>a <:b > c</p><p>next</p>", ["<p>", "a <:b > c", "<p>", "next"]),
            ("a letter outside ASCII", "<p>a <\u{E9}t\u{E9} > c</p><p>next</p>", ["<p>", "a <\u{E9}t\u{E9} > c", "<p>", "next"]),
            ("a quotation mark", "<p>a <\"b\" and <'c'</p><p>next</p>", ["<p>", "a <\"b\" and <'c'", "<p>", "next"]),
            ("a line break", "<p>a <\nb</p><p>next</p>", ["<p>", "a <\nb", "<p>", "next"]),
            ("a reference", "<p>a <&amp; b</p><p>next</p>", ["<p>", "a <& b", "<p>", "next"]),
            ("its paragraph's end tag", "<p>a <</p><p>next</p>", ["<p>", "a <", "<p>", "next"]),
            ("a space, beside tags that are tags", "<p>1 < 2 <b>and</b> 3 < 4</p><p>next</p>", ["<p>", "1 < 2 ", "<b>", "and", " 3 < 4", "<p>", "next"]),
            ("a space in a table cell", "<table><tr><td>a < b</td><td>c</td></tr></table><p>next</p>",
             ["<table>", "<tr>", "<td>", "a < b", "<td>", "c", "<p>", "next"]),
            ("a MathML operator's end tag", "<math><mi>a</mi><mo><</mo><mi>b</mi></math><p>next</p>",
             ["<math>", "<mi>", "a", "<mo>", "<", "<mi>", "b", "<p>", "next"]),
        ]
        for (label, body, expected) in cases {
            let document = try page(body)
            XCTAssertTrue(document.recoveredAsHTML, label)
            XCTAssertFalse(document.canResolveCFIs, label)
            XCTAssertEqual(bodyModel(document), expected, "a sign before \(label)")
        }
    }

    /// Only a sign in text becomes text. Raw text, where a reference would be shown as it is
    /// written, keeps the sign itself, and markup that holds a sign is the markup it was: an
    /// attribute value, a comment, a declaration, a processing instruction or a tag.
    func testASignOutsideTextIsWhatItWas() throws {
        let raw = try parse("""
        <html \(Self.xhtml)><head><title>a < b</title><style>a::after { content: "<" } b < c</style>\
        <script>if (a < b) { c <<= 1 }</script></head><body><p>d < e</p>\
        <STYLE type="text/css">f < g</stylesheet> h < i</STYLE ><script src="a.js"/><p>j < k</p>\
        <style>l < m</style x><p>n</<style>o < p</style>q < r</p></body></html>
        """)
        XCTAssertTrue(raw.recoveredAsHTML)
        func texts(_ name: String, in document: ContentDocument) -> [String] { document.nodes.filter { $0.isHTML(name) }.map(\.textContent) }
        XCTAssertEqual(texts("title", in: raw), ["a < b"])
        // libxml2 drops an end tag that closes nothing, `</stylesheet>`, and reads on as raw text.
        XCTAssertEqual(texts("style", in: raw), ["a::after { content: \"<\" } b < c", "f < g h < i", "l < m", "o < p"])
        XCTAssertEqual(texts("script", in: raw), ["if (a < b) { c <<= 1 }", ""], "`<script/>` is empty: what follows it is text")
        XCTAssertEqual(texts("p", in: raw), ["d < e", "j < k", "no < pq < r"])

        // Where libxml2 ends raw text depends on the tree it has built: directly after the start
        // tag it reads any end tag as one, so `</p>` closes the style sheet with its paragraph
        // and `</b>`, which closes nothing, is dropped with the text through its `>`.
        let ended = try page("<p>a<style></p> b < c</style>d < e<p>f<script></b g < h>if (i < j) {}</script>k < l</p>")
        XCTAssertEqual(bodyModel(ended), ["<p>", "a", "<style>", " b < cd < e", "<p>", "f", "<script>", "if (i < j) {}", "k < l"])

        let markup = try page("""
        <p title="a > b < c" class=x<y lang=d< >e < f</p><p>g<!-- h < i > j --> k < l</p><p>m<?n o < p ?> q < r</p>\
        <p>s<![CDATA[t < u]]> v < w</p><p < x>y</p z < 0>1 < 2<p>next</p>
        """)
        XCTAssertEqual(bodyModel(markup), ["<p>", "e < f", "<p>", "g k < l", "<p>", "m q < r", "<p>", "s v < w", "<p>", "y", "1 < 2", "<p>", "next"])
        let paragraph = try first("p", in: markup)
        XCTAssertEqual(paragraph.attributes.map(\.name), ["title", "class", "lang"])
        XCTAssertEqual(paragraph.attributes.map(\.value), ["a > b < c", "x<y", "d<"])
        XCTAssertEqual(markup.nodes.filter { $0.isHTML("p") }[4].attributes.map(\.name), ["x"], "a sign among the attributes names none")
        // A `>` in a DOCTYPE's quoted identifier does not end it.
        XCTAssertEqual(bodyModel(try page("<p>x < y</p>", prolog: "<!DOCTYPE html PUBLIC \"a>b < c\" \"d>e\">")), ["<p>", "x < y"])
    }

    /// Reading a sign as text brings into view the markup after it that libxml2 took for the
    /// inside of a tag. A declaration there, which the screen passed over as it did, declares
    /// nothing: the HTML parser reads no entity declarations, and the XML parser, which the
    /// screen is for, stopped at the sign.
    func testADeclarationBroughtIntoViewByAKeptSignDeclaresNothing() throws {
        let document = try page("<p>x <_y <!DOCTYPE html [<!ENTITY e \"hidden\">]> &e;</p><p>&e; next</p>")
        XCTAssertTrue(document.recoveredAsHTML)
        XCTAssertEqual(bodyModel(document), ["<p>", "x <_y ]> &e;", "<p>", "&e; next"])
    }

    /// The sign is replaced before the parser reads the bytes and is itself again in the tree:
    /// one character of its text node, counted once by the offsets after it, matched by a search
    /// and followed by an `id` that is found. The section is still one whose tree libxml2
    /// repaired, so it issues and resolves no CFI.
    func testAKeptSignIsOneCharacterAndTheSectionStillIssuesNoCFI() throws {
        let document = try page("<p id=\"one\">if x < y &lt; z &amp;lt; done</p><p id=\"two\">p <.05 next</p>")
        XCTAssertTrue(document.recoveredAsHTML)
        XCTAssertFalse(document.canResolveCFIs)
        let one = try XCTUnwrap(document.element(id: "one"))
        XCTAssertEqual(one.children.count, 1, "one text node")
        let text = try XCTUnwrap(one.children.first)
        XCTAssertEqual(text.text, "if x < y < z &lt; done", "a written reference is still the sign, and an escaped one its four characters")
        XCTAssertEqual(text.utf16Length, 22)
        XCTAssertEqual(document.element(id: "two")?.textContent, "p <.05 next", "no element was made of `.05`")
        let match = try XCTUnwrap(TextSearch.matches(of: "x < y", in: document, locale: nil).first)
        XCTAssertEqual([match.start.offset, match.end.offset], [3, 8])
        XCTAssertTrue(match.start.node === text && match.end.node === text)
        XCTAssertEqual(EPUBCFI.localPath(from: match.start, to: match.end, in: document), "")
        XCTAssertNil(EPUBCFI.resolve(localPath: "/4/2/1:5", in: document))
    }

    /// What the parser is given differs from the file only where a stray sign stood, by a
    /// noncharacter the file does not hold as itself or as a reference, so that nothing the
    /// author wrote is taken for a sign. Well-formed XHTML is read as XML with every `<` it
    /// has, and UTF-16 is decoded before its signs are sought.
    func testAStraySignIsGivenToTheParserAsACharacterTheDocumentDoesNotHold() throws {
        func replaced(_ markup: String) throws -> (text: String, placeholder: Unicode.Scalar?) {
            let result = try XCTUnwrap(HTMLStraySigns.replaced(in: Data(markup.utf8), limit: .max))
            return (String(decoding: result.data, as: UTF8.self), result.placeholder)
        }
        let unchanged = [
            "<?xml version=\"1.0\"?><!DOCTYPE html><html><head><title>T</title></head><body><p title=\"a &lt; b\">c &lt; d<!-- e --><br/></p x></body></html>",
            "<p>one<p>two</div><img src=a.png alt=\"b > c\"><a href=x?y=1&z=2>link</a></<?<!", "",
        ]
        for markup in unchanged {
            let result = try replaced(markup)
            XCTAssertEqual(result.text, markup)
            XCTAssertNil(result.placeholder, markup)
        }
        let one = String(Self.noncharacter()), two = String(Self.noncharacter(1))
        let stray = "<p>a < b <= c</p><p title=\"d < e\">f <.5 <</p><style>g < h</style>i <"
        let result = try replaced(stray)
        XCTAssertEqual(result.placeholder, Self.noncharacter())
        XCTAssertEqual(result.text, "<p>a \(one) b \(one)= c</p><p title=\"d \(one) e\">f \(one).5 \(one)</p><style>g \(one) h</style>i \(one)")
        XCTAssertEqual(HTMLStraySigns.restored(result.text, from: Self.noncharacter()), stray)

        // The author's own noncharacters, written either way, are passed over and kept.
        XCTAssertEqual(try replaced("<p>a < b \(one) &#xFDD1; &#64978; &#x0FDD3 &#XFDD4;</p>").placeholder, Self.noncharacter(5))
        let kept = try page("<p title=\"\(one) < &#xFDD1;\">a < b \(one) &#xFDD1; c</p>")
        XCTAssertEqual(bodyModel(kept), ["<p>", "a < b \(one) \(two) c"])
        XCTAssertEqual(try first("p", in: kept).attribute("title"), "\(one) < \(two)")
        // A file that holds all thirty-two is parsed as it is.
        let every = "<p>a < b " + (0xFDD0...0xFDEF).map { "&#\($0);" }.joined() + "</p>"
        XCTAssertNil(try replaced(every).placeholder)
        XCTAssertEqual(try replaced(every).text, every)

        let wellFormed = try page("<p title=\"a &lt; b\">c<![CDATA[ < d > e < f]]></p><script><![CDATA[if (g < h) {}]]></script>")
        XCTAssertFalse(wellFormed.recoveredAsHTML)
        XCTAssertEqual(bodyModel(wellFormed), ["<p>", "c < d > e < f", "<script>", "if (g < h) {}"])

        // A sign before a NUL opens nothing either, and the signs after it are still sought.
        XCTAssertEqual(try replaced("<p>a <\u{0}b < c</p>").text, "<p>a \(one)\u{0}b \(one) c</p>")
        let markup = "<html \(Self.xhtml)>\(Self.head)<body><p>if x < y then done</p><p>next</p></body></html>"
        for (label, mark, encoding) in [("little endian", [UInt8](arrayLiteral: 0xFF, 0xFE), String.Encoding.utf16LittleEndian),
                                        ("big endian", [0xFE, 0xFF], .utf16BigEndian)] {
            let wide = Data(mark) + (try XCTUnwrap(markup.data(using: encoding)))
            XCTAssertEqual(bodyModel(try ContentDocument.parse(wide, path: "wide.xhtml")), ["<p>", "if x < y then done", "<p>", "next"], label)
        }
    }

    /// The bytes given to the parser are held to the byte limit, the tree to the depth and node
    /// limits, and the scan reads its input once.
    func testReplacedSignsKeepTheLimitsAndTheInputIsReadOnce() throws {
        let stray = "<html><body><p>a < b</p></body></html>" // The placeholder is two bytes longer than the sign.
        var limits = ContentLimits(); limits.bytes = stray.utf8.count + 2
        XCTAssertEqual(try parse(stray, limits: limits).body?.textContent, "a < b")
        for bytes in [stray.utf8.count + 1, stray.utf8.count] {
            limits.bytes = bytes
            XCTAssertThrowsError(try parse(stray, limits: limits), "\(bytes) bytes") { error in
                XCTAssertEqual(error as? ContentDocumentError, .limitExceeded("bytes"), "\(bytes) bytes")
            }
        }
        // Without a stray sign nothing is added, so a file of exactly the limit is still read.
        let plain = "<html><body><p>a b</b></p></body></html>"
        limits.bytes = plain.utf8.count
        XCTAssertEqual(try parse(plain, limits: limits).body?.textContent, "a b")

        // A sign is a character, not a node: half a million of them are one text node.
        let signs = try parse("<html><body><p>" + String(repeating: "< ", count: 500_000) + "</p></body></html>")
        XCTAssertEqual(signs.nodes.count, 4)
        XCTAssertEqual(signs.nodes.last?.utf16Length, 1_000_000)
        limits = ContentLimits(); limits.nodes = 5
        XCTAssertThrowsError(try parse("<html><body><p>a < b</p><p>c < d</p></body></html>", limits: limits)) { error in
            XCTAssertEqual(error as? ContentDocumentError, .limitExceeded("nodes"))
        }
        XCTAssertThrowsError(try parse("<html><body>" + String(repeating: "<div>a < b", count: 5_000))) { error in
            XCTAssertEqual(error as? ContentDocumentError, .limitExceeded("depth"))
        }

        // Signs, the beginnings of references and the zeros a reference may be padded with, by
        // the hundred thousand. A scan that read on from each one anew would take minutes.
        for (prefix, repeated) in [("", "<"), ("", "< "), ("< ", "</"), ("< ", "&#"), ("< ", "&#x0"), ("< &#", "0"), ("< &#x", "0"), ("< ", String(Self.noncharacter()))] {
            let label = prefix + repeated
            let data = Data((prefix + String(repeating: repeated, count: 300_000 / repeated.utf8.count)).utf8)
            let start = Date()
            let result = try XCTUnwrap(HTMLStraySigns.replaced(in: data, limit: .max), label)
            XCTAssertLessThan(Date().timeIntervalSince(start), 30, label)
            XCTAssertNotNil(result.placeholder, label)
            XCTAssertLessThanOrEqual(result.data.count, data.count * 3, label)
            XCTAssertNil(HTMLStraySigns.replaced(in: data, limit: result.data.count - 1), label)
        }
    }

    /// libxml2's own HTML tree for `data`: each element with its attributes and each text node,
    /// with its depth, in document order, and whether it is text outside `script` and `style`.
    private func libxml2Tree(_ data: Data) -> [(entry: String, isText: Bool)] {
        let options = Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
            | HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NODEFDTD.rawValue)
        let parsed = data.withUnsafeBytes { buffer in
            htmlReadMemory(buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buffer.count), nil, "UTF-8", options)
        }
        guard let parsed else { return [] }
        defer { xmlFreeDoc(parsed) }
        var tree: [(entry: String, isText: Bool)] = []
        func walk(_ first: xmlNodePtr?, rawText: Bool, depth: Int) {
            var node = first
            while let current = node {
                if current.pointee.type == XML_ELEMENT_NODE {
                    let name = String(cString: current.pointee.name)
                    var entry = "\(depth) <\(name)"
                    var attribute = current.pointee.properties
                    while let property = attribute {
                        var value = ""
                        var part = property.pointee.children
                        while let text = part {
                            if let content = text.pointee.content { value += String(cString: content) }
                            part = text.pointee.next
                        }
                        entry += " \(String(cString: property.pointee.name))=\(value.debugDescription)"
                        attribute = property.pointee.next
                    }
                    tree.append((entry + ">", false))
                    if depth < 250 { walk(current.pointee.children, rawText: name == "script" || name == "style", depth: depth + 1) }
                } else if current.pointee.type == XML_TEXT_NODE || current.pointee.type == XML_CDATA_SECTION_NODE {
                    tree.append(("\(depth) " + (current.pointee.content.map { String(cString: $0) } ?? "").debugDescription, !rawText))
                }
                node = current.pointee.next
            }
        }
        walk(xmlDocGetRootElement(parsed), rawText: false, depth: 0)
        return tree
    }

    /// The placeholder is right only if libxml2 reads it as it read the sign everywhere but in
    /// text. Over generated markup, then: where no sign comes to be shown as text, the tree is
    /// the one libxml2 builds from the file as it is. No placeholder is left in the reader's
    /// tree, in a name, a text node or an attribute. And the bytes given to the parser are the
    /// file's own once each placeholder is read as the sign. (The tokens have no colon: libxml2
    /// names `<a:style>` `style` in its tree but reads no raw text in it, and the comparison
    /// tells raw text by that name.)
    func testThePlaceholderIsReadAsTheSignWasEverywhereButInText() throws {
        let tokens = ["<", "<", "<", "<", ">", ">", "\"", "'", "=", "/", " ", " ", "a", "p", "b", "x", "1", "!", "?", "-", "--", ".", "_", "\n", "\t", "\u{C}",
                      "\u{0}", "\u{E9}", String(Self.noncharacter()), "&#xFDD1;", "&lt;", "&", "<p>", "</p>", "<p ", "<a href=", "title=\"", "class='", "<br/>", "/>",
                      "</", "<?", "<!", "<!--", "-->", "--!>", "<![CDATA[", "]]>", "<!DOCTYPE", "<!doctype html", " PUBLIC", " SYSTEM", "style", "script",
                      "<style", "</style", "<style>", "</style>", "<STYLE ", "</STYLE ", "<style/>", "<script>", "</script>", "<script src=", "<script />",
                      "<title>", "</title>", "<textarea>", "</textarea>", "<xmp>", "</xmp>", "<svg>", "</svg>", "<math>", "<html>", "</html>", "<head>",
                      "<body>", "</body>", "<table>", "<tr>", "<td>", "</table>", "<select>", "<option>", "<ul>", "<li>", "<h1>", "</h1>", "<div>", "</div>"]
        var state: UInt64 = 103
        func random(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        var replacements = 0, compared = 0
        for _ in 0..<30_000 {
            let markup = (random(2) == 0 ? "<html><body>" : "") + (0...random(18)).map { _ in tokens[random(tokens.count)] }.joined()
            let data = Data(markup.utf8)
            let replaced = try XCTUnwrap(HTMLStraySigns.replaced(in: data, limit: .max))
            guard let placeholder = replaced.placeholder else { continue }
            replacements += 1
            guard HTMLStraySigns.restored(String(decoding: replaced.data, as: UTF8.self), from: placeholder) == markup else {
                return XCTFail("more than its stray signs was replaced in \(markup.debugDescription)")
            }
            let tree = libxml2Tree(replaced.data)
            if !tree.contains(where: { $0.isText && $0.entry.unicodeScalars.contains(placeholder) }) {
                compared += 1
                guard tree.map({ HTMLStraySigns.restored($0.entry, from: placeholder) }) == libxml2Tree(data).map(\.entry) else {
                    return XCTFail("the placeholder is not read as the sign was in \(markup.debugDescription)")
                }
            }
            guard let document = try? ContentDocument.parse(data, path: "generated.xhtml") else { continue }
            for node in document.nodes {
                let strings = [node.name, node.text] + node.attributes.flatMap { [$0.name, $0.value] }
                guard !strings.contains(where: { $0.unicodeScalars.contains(placeholder) }) else {
                    return XCTFail("a placeholder is left in \(node.isText ? "text" : "<\(node.name)>") of \(markup.debugDescription)")
                }
            }
        }
        XCTAssertGreaterThan(replacements, 3_000, "the generator has stopped making stray signs")
        XCTAssertGreaterThan(compared, 1_000, "the generator has stopped putting them outside text")
    }

    /// Namespaces in XML: a prefix must be declared. WebKit reports "Namespace prefix epub for
    /// type on section is not defined" and foliate then read the file as HTML, whose tree (here
    /// with a `tbody`) is the one its CFIs count. Keeping the XML tree resolves them elsewhere.
    func testAnUndeclaredNamespacePrefixIsReadAsFoliateReadIt() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/102")
        let document = try page("<section epub:type=\"chapter\"><table><tr><td>Cell</td></tr></table></section>")
        XCTAssertEqual(try first("section", in: document).epubTypes, ["chapter"], "the attribute is still read")
        XCTAssertTrue(document.recoveredAsHTML, "WebKit rejects this as XML; foliate re-read it as HTML")
        // foliate's CFI for "ell": section, table, the tbody HTML adds, tr, td.
        if let range = EPUBCFI.resolve(localPath: "/4/2/2/2/2/2,/1:1,/1:4", in: document) {
            XCTAssertEqual([range.start.offset, range.end.offset], [1, 4], "a saved range resolves, but to another place in the cell")
        }
    }

    // MARK: - XML-shaped HTML

    /// doc/native-viewer.md lists what the qualified subset holds ("UTF-8 XML-shaped markup with
    /// explicit head/body, ordinary flow/inline elements and lists, and valid HTML nesting") and
    /// what lies outside it. Inside, CFIs are available; outside, they are refused.
    func testTheQualifiedHTMLSubsetAcceptsWhatTheDocumentationLists() throws {
        func html(_ body: String, head: String = "<title>Book</title>", prolog: String = "", root: String = "") -> String {
            "\(prolog)<html\(root)><head>\(head)</head><body>\(body)</body></html>"
        }
        let accepted: [(String, String)] = [
            ("paragraphs and inline elements", html("<p>One <b>two</b> <i>three <em>four</em></i> <a href=\"x\">five</a></p><h1>Six</h1><h6>Seven</h6>")),
            ("every inline element", html("<p><span>a</span><strong>b</strong><u>c</u><s>d</s><small>e</small><sub>f</sub><sup>g</sup><code>h</code><q>i</q>"
                + "<cite>j</cite><abbr>k</abbr><mark>l</mark><br/><img src=\"m.png\" alt=\"m\"/></p>")),
            ("containers", html("<div><section><article><aside><header>a</header><footer>b</footer><nav>c</nav><main>d</main><blockquote>e</blockquote>"
                + "<figure><figcaption>f</figcaption></figure></aside></article></section></div>")),
            ("lists", html("<ul><li>a<ol><li>b</li></ol></li><li><p>c</p></li></ul><dl><dt>d</dt><dd>e</dd></dl>")),
            ("a rule between blocks", html("<div>a<hr/>b</div><hr />")),
            ("preformatted text", html("<pre>one\n  two</pre><pre><b>\nthree</b></pre>")),
            ("comments", html("<!-- c <p/> <![CDATA[ --><p>x<!-- y --></p>")),
            ("empty elements written in full", html("<p></p><div></div><span></span><p>x</p>")),
            ("deeply repeated formatting", html("<p><b><b><b><b>x</b></b></b></b> y</p>")),
            ("head metadata", html("<p>x</p>", head: "<meta name=\"a\" content=\"b\"/><title>Book</title><link rel=\"stylesheet\" href=\"a.css\"/>")),
            ("a head without a title", html("<p>x</p>", head: "")),
            ("an XML declaration and HTML doctype", html("<p>x</p>", prolog: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n<!DOCTYPE html>\n")),
            ("a byte order mark", "\u{FEFF}" + html("<p>x</p>")),
            ("language and semantic attributes", html("<p xml:lang=\"fr\" epub:type=\"x\" ID=\"A\" Class=\"c\">x</p>", root: " xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"en\"")),
            ("references", html("<p title=\"a&amp;b&#9;c\">x &amp; y &lt; z &#233; &#x1F600; &nbsp;</p>")),
            ("a namespaced document with a named reference", "<html \(Self.xhtml)><head><title>Book</title></head><body><p>a&nbsp;b</p></body></html>"),
        ]
        for (label, markup) in accepted {
            let document = try parse(markup)
            XCTAssertTrue(document.recoveredAsHTML, label)
            XCTAssertTrue(document.canResolveCFIs, label)
            XCTAssertEqual(document.root.namespace, ContentNamespace.xhtml, "\(label): an HTML parser puts every element in the XHTML namespace")
            XCTAssertTrue(document.nodes.allSatisfy { !$0.isElement || $0.namespace == ContentNamespace.xhtml }, label)
            let text = try XCTUnwrap(document.body.flatMap { body in document.nodes[body.order...].first(where: \.isText) }, label)
            let path = EPUBCFI.localPath(from: DOMPosition(text), to: DOMPosition(text, text.utf16Length), in: document)
            XCTAssertFalse(path.isEmpty, label)
            XCTAssertEqual(EPUBCFI.resolve(localPath: path, in: document)?.start, DOMPosition(text), label)
        }
        let attributes = try first("p", in: try parse(accepted[13].1))
        XCTAssertEqual(attributes.attribute("id"), "A", "HTML attribute names are lowercase")
        XCTAssertEqual(attributes.classNames, ["c"])
        XCTAssertEqual(attributes.language, "fr")
        XCTAssertEqual(attributes.epubTypes, ["x"])
    }

    func testEverythingOutsideTheQualifiedSubsetRefusesCFIs() throws {
        func html(_ body: String, head: String = "<title>Book</title>", prolog: String = "", between: String = "") -> String {
            "\(prolog)<html><head>\(head)</head>\(between)<body>\(body)</body></html>"
        }
        let refused: [(String, String)] = [
            ("a self-closing nonvoid element", html("<p><span/>x</p>")), ("a self-closing paragraph", html("<p/><p>x</p>")),
            ("a self-closing anchor", html("<p><a id=\"x\"/>x</p>")), ("a self-closing head", "<html><head/><body><p>x</p></body></html>"),
            ("a closing void tag", html("<p>a<br></br>b</p>")), ("a closing image tag", html("<p><img src=\"a\"></img></p>")),
            ("a table", html("<table><tbody><tr><td>x</td></tr></tbody></table>")), ("a table without tbody", html("<table><tr><td>x</td></tr></table>")),
            ("CDATA", html("<p><![CDATA[x]]>y</p>")), ("an empty CDATA section", html("<p><![CDATA[]]>y</p>")),
            ("a style element", html("<p>x</p>", head: "<title>Book</title><style>p{}</style>")), ("a script element", html("<script>var a;</script><p>x</p>")),
            ("a script in the head", html("<p>x</p>", head: "<title>Book</title><script src=\"a.js\"></script>")),
            ("a textarea", html("<textarea>x</textarea>")), ("an iframe", html("<iframe src=\"a\"></iframe><p>x</p>")), ("noscript", html("<noscript><p>x</p></noscript>")),
            ("inline SVG", html("<svg><text>x</text></svg>")), ("namespaced SVG", html("<svg xmlns=\"http://www.w3.org/2000/svg\"><text>x</text></svg>")),
            ("MathML", html("<p><math><mi>x</mi></math></p>")), ("a prefixed element", html("<x:p xmlns:x=\"urn:x\">x</x:p>")),
            ("a foreign attribute", html("<p xlink:href=\"a\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">x</p>")),
            ("a literal tab in an attribute", html("<p title=\"a\tb\">x</p>")), ("a literal newline in an attribute", html("<p title=\"a\nb\">x</p>")),
            ("a C1 reference HTML remaps", html("<p>&#x80;</p>")), ("a decimal C1 reference", html("<p>&#150;</p>")), ("a padded C1 reference", html("<p>&#x0009F;</p>")),
            ("a processing instruction", html("<?pi x?><p>x</p>")), ("a stylesheet instruction", html("<p>x</p>", prolog: "<?xml-stylesheet href=\"a.css\"?>")),
            ("a paragraph in a paragraph", html("<p>a<p>b</p></p>")), ("a division in a paragraph", html("<p>a<div>b</div></p>")),
            ("a heading in a paragraph", html("<p><h1>x</h1></p>")), ("a rule in a paragraph", html("<p>a<hr/>b</p>")),
            ("a list in a paragraph", html("<p><ul><li>x</li></ul></p>")), ("a block in a span", html("<div><span><div>x</div></span></div>")),
            ("a heading in a heading", html("<h1><h2>x</h2></h1>")), ("a nested anchor", html("<p><a href=\"1\">a<span><a href=\"2\">b</a></span></a></p>")),
            ("a list item outside a list", html("<li>x</li>")), ("a term outside a list", html("<div><dt>a</dt></div>")),
            ("text directly in a list", html("<ul>text<li>x</li></ul>")), ("a paragraph directly in a list", html("<ul><p>x</p></ul>")),
            ("metadata in the body", html("<meta name=\"a\"/><p>x</p>")), ("a link in the body", html("<link rel=\"a\"/><p>x</p>")),
            ("a title in the body", html("<title>x</title><p>y</p>")), ("an image in the head", html("<p>x</p>", head: "<title>Book</title><img src=\"a\"/>")),
            ("two titles", html("<p>x</p>", head: "<title>a</title><title>b</title>")), ("markup characters in the title", html("<p>x</p>", head: "<title>a &lt; b</title>")),
            ("text in the head", html("<p>x</p>", head: "stray<title>a</title>")), ("text between head and body", html("<p>x</p>", between: "stray")),
            ("a no-break space between head and body", html("<p>x</p>", between: "\u{A0}")),
            ("pre with an initial newline", html("<pre>\nx</pre>")), ("pre with a referenced initial newline", html("<pre>&#10;x</pre>")),
            ("an unknown element", html("<p><font>x</font></p>")), ("ruby", html("<p><ruby>x<rt>y</rt></ruby></p>")), ("a form control", html("<p><input type=\"text\"/></p>")),
            ("uppercase element names", html("<P>x</P>")), ("an uppercase root", "<HTML><HEAD><TITLE>B</TITLE></HEAD><BODY><P>x</P></BODY></HTML>"),
            ("a body before the head", "<html><body><p>x</p></body><head><title>a</title></head></html>"), ("no head", "<html><body><p>x</p></body></html>"),
            ("no body", "<html><head><title>a</title></head></html>"), ("two bodies", "<html><head><title>a</title></head><body><p>x</p></body><body><p>y</p></body></html>"),
            ("a frameset", "<html><head><title>a</title></head><frameset><frame src=\"a\"/></frameset></html>"),
            ("another root", "<div><head><title>a</title></head><body><p>x</p></body></div>"),
            ("a declared legacy encoding", html("<p>x</p>", prolog: "<?xml version=\"1.0\" encoding=\"us-ascii\"?>")),
            ("a NUL reference", html("<p>&#0;</p>")),
        ]
        for (label, markup) in refused {
            let document = try parse(markup)
            XCTAssertTrue(document.recoveredAsHTML, label)
            XCTAssertFalse(document.canResolveCFIs, "\(label) is outside the qualified subset")
            for cfi in ["/4", "/4/2", "/4/2/1:0", "/2/2/1:0", "/0"] { XCTAssertNil(EPUBCFI.resolve(localPath: cfi, in: document), "\(label) \(cfi)") }
            if let text = document.nodes.first(where: \.isText) {
                XCTAssertEqual(EPUBCFI.localPath(from: DOMPosition(text), to: DOMPosition(text), in: document), "", label)
            }
        }
    }

    /// doc/native-viewer.md: "Pre-head whitespace is dropped, between-head/body whitespace
    /// retained, and trailing root whitespace merged into the body."
    func testQualifiedHTMLPlacesRootWhiteSpaceAsAnHTMLParserDoes() throws {
        let document = try parse("<html>\n <head>\n<title>Book</title>\n</head>\n  <body>\n<p>One.</p>\n</body>\n\t</html>")
        XCTAssertTrue(document.canResolveCFIs)
        XCTAssertEqual(document.root.children.map { $0.isElement ? "<\($0.name)>" : $0.text }, ["<head>", "\n  ", "<body>"])
        XCTAssertEqual(document.head?.children.map { $0.isElement ? "<\($0.name)>" : $0.text }, ["\n", "<title>", "\n"], "white space inside the head stays")
        XCTAssertEqual(document.body?.children.map { $0.isElement ? "<\($0.name)>" : $0.text }, ["\n", "<p>", "\n\n\t"])
        // With no text to join, the root's trailing white space becomes the body's last child.
        let appended = try parse("<html><head><title>Book</title></head><body><p>One.</p></body>\n</html>")
        XCTAssertEqual(appended.body?.children.map { $0.isElement ? "<\($0.name)>" : $0.text }, ["<p>", "\n"])
        let empty = try parse("<html><head><title>Book</title></head><body></body> </html>")
        XCTAssertEqual(empty.body?.children.map(\.text), [" "])
        // Order and parents stay consistent in the rebuilt tree.
        for document in [document, appended, empty] {
            for (order, node) in document.nodes.enumerated() {
                XCTAssertEqual(node.order, order)
                for (index, child) in node.children.enumerated() {
                    XCTAssertTrue(child.parent === node)
                    XCTAssertEqual(child.indexInParent, index)
                }
            }
        }
    }

    /// HTML Standard, tree construction, the "after body" and "after after body" insertion
    /// modes: white space after `</html>` is processed "using the rules for the in body
    /// insertion mode", so it too lands at the end of the body. Almost every file ends with a
    /// newline, and WebKit's tree (hence foliate's CFIs) has it.
    func testWhiteSpaceAfterTheRootElementBelongsToTheBodyInQualifiedHTML() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/104")
        let document = try parse("<html><head><title>Book</title></head><body><p>One.</p><p>Two.</p></body></html>\n")
        XCTAssertTrue(document.canResolveCFIs)
        XCTAssertEqual(document.body?.children.map { $0.isElement ? "<\($0.name)>" : $0.text }, ["<p>", "<p>", "\n"],
                       "the newline that ends the file is missing from the body")
        // foliate's range over the last paragraph, ending in that text: it must not collapse.
        let range = try XCTUnwrap(EPUBCFI.resolve(localPath: "/4,/4/1:0,/5:0", in: document))
        XCTAssertEqual(range.start.node.text, "Two.")
        XCTAssertTrue(range.start < range.end, "a selection of the last paragraph resolves to an empty range")
    }

    // MARK: - Robustness

    /// Books are untrusted: no mutation of a document may trap, and whatever parses keeps the
    /// tree's invariants, which every position computation relies on.
    func testMutatedMarkupNeverTrapsAndKeepsTheTreeConsistent() throws {
        let seeds = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\(Self.xhtml11)\n<html \(Self.xhtml) xmlns:epub=\"http://www.idpf.org/2007/ops\" xml:lang=\"en\">\n"
                + "<head><title>Seed &amp; title</title><link rel=\"stylesheet\" href=\"a.css\"/></head>\n<body epub:type=\"bodymatter\">\n"
                + "<p id=\"a\">One&nbsp;<em>two</em> &eacute; &#x1F600; <![CDATA[<raw>]]><!-- note --></p>\n<ul><li>x</li><li><a href=\"#a\">y</a></li></ul>\n"
                + "<table><tr><td>cell</td></tr></table><svg xmlns=\"http://www.w3.org/2000/svg\"><text>s</text></svg>\n</body>\n</html>\n",
            "<html>\n<head><title>Book</title></head>\n<body>\n<div><p>One <b>two</b></p><ul><li>three</li></ul><pre>four</pre></div>\n</body>\n</html>\n",
        ]
        let insertions: [[UInt8]] = [[0x3C], [0x3E], [0x26], [0x22], [0x27], [0x2F], [0x21], [0x5B], [0x5D], [0x2D, 0x2D], [0x3F], [0x3B], [0x3D], [0x20],
                                     [0x00], [0xFF], [0xC3], [0xED, 0xA0, 0x80], Array("<![CDATA[".utf8), Array("<!--".utf8), Array("&#x0;".utf8),
                                     Array("&nbsp".utf8), Array("<p>".utf8), Array("</p>".utf8), Array("<br>".utf8), Array("]]>".utf8), Array("-->".utf8)]
        var state: UInt64 = 0xA5A5_5A5A_1234_4321
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        var parsed = 0, thrown = 0
        for round in 0..<4_000 {
            var bytes = Array(seeds[round % seeds.count].utf8)
            for _ in 0...next(3) {
                let at = next(bytes.count + 1)
                switch next(5) {
                case 0: bytes.insert(contentsOf: insertions[next(insertions.count)], at: at)
                case 1: if at < bytes.count { bytes.remove(at: at) }
                case 2: bytes.removeSubrange(at...)
                case 3: if at < bytes.count { bytes[at] = UInt8(next(256)) }
                default:
                    let length = min(next(40), bytes.count - at)
                    bytes.insert(contentsOf: Array(bytes[at..<at + length]), at: next(bytes.count + 1))
                }
            }
            guard let document = try? ContentDocument.parse(Data(bytes), path: "mutated.xhtml") else { thrown += 1; continue }
            parsed += 1
            XCTAssertTrue(document.nodes.first === document.root)
            var previousWasText = false
            for (order, node) in document.nodes.enumerated() {
                guard node.order == order, node.subtreeEnd >= order, node.subtreeEnd < document.nodes.count,
                      node.parent.map({ $0.children.indices.contains(node.indexInParent) && $0.children[node.indexInParent] === node }) ?? (order == 0)
                else { XCTFail("inconsistent node \(order) in \(String(decoding: bytes, as: UTF8.self).debugDescription)"); break }
                if node.isText, previousWasText, node.indexInParent > 0, node.parent?.children[node.indexInParent - 1].isText == true {
                    XCTFail("adjacent text nodes were not merged in \(String(decoding: bytes, as: UTF8.self).debugDescription)")
                }
                previousWasText = node.isText
            }
            // Positions and search over whatever was read.
            if let text = document.nodes.last(where: \.isText) {
                let path = EPUBCFI.localPath(from: DOMPosition(document.root), to: DOMPosition(text, text.utf16Length), in: document)
                if document.canResolveCFIs { XCTAssertNotNil(EPUBCFI.resolve(localPath: path, in: document), path) } else { XCTAssertEqual(path, "") }
            }
            _ = TextSearch.matches(of: "two", in: document, locale: TextSearch.locale(of: document), limit: 8)
        }
        XCTAssertGreaterThan(parsed, 1_000)
        XCTAssertGreaterThan(thrown, 10, "some mutations must be refused, or the test mutates too gently")
    }

    func testConcurrentParsesBuildTheSameTree() throws {
        let markup = "\(Self.xhtml11)<html \(Self.xhtml)>\(Self.head)<body>"
            + (0..<200).map { "<p id=\"p\($0)\">Paragraph&nbsp;\($0) with <em>caf&eacute;</em> &amp; more.</p>" }.joined() + "</body></html>"
        let reference = model(try parse(markup))
        let agreeing = OSAllocatedUnfairLock(initialState: 0)
        let data = Data(markup.utf8)
        DispatchQueue.concurrentPerform(iterations: 48) { _ in
            let document = try? ContentDocument.parse(data, path: "concurrent.xhtml")
            if document?.nodes.map({ $0.isElement ? "<\($0.name)>" : $0.text }) == reference { agreeing.withLock { $0 += 1 } }
        }
        XCTAssertEqual(agreeing.withLock { $0 }, 48)
    }

    func testDocumentOrderAncestryAndPositions() throws {
        let document = try page("<div><p>one</p><p><b>two</b>three</p></div><p>four</p>")
        for (order, node) in document.nodes.enumerated() {
            XCTAssertTrue(document.nodes[node.order] === node)
            XCTAssertEqual(node.order, order)
            XCTAssertEqual(node.subtreeEnd, node.children.last?.subtreeEnd ?? node.order)
            XCTAssertEqual(node.utf16Length, node.text.utf16.count)
            for other in document.nodes {
                var ancestor = other.parent, isAncestor = false
                while let current = ancestor { if current === node { isAncestor = true }; ancestor = current.parent }
                XCTAssertEqual(node.isAncestor(of: other), isAncestor, "\(node.order) of \(other.order)")
            }
        }
        let division = try first("div", in: document), bold = try first("b", in: document)
        XCTAssertEqual(document.nextTextNode(from: division)?.text, "one", "the first text at or after a node")
        XCTAssertEqual(document.nextTextNode(from: bold)?.text, "two")
        let four = try XCTUnwrap(document.nodes.last)
        XCTAssertTrue(document.nextTextNode(from: four) === four)
        let tail = try page("<p>x</p><br/>")
        XCTAssertNil(tail.nextTextNode(from: try XCTUnwrap(tail.nodes.last)), "nothing follows the last element")
        // An element's start precedes everything inside it; offsets order within a node.
        let one = try XCTUnwrap(document.nodes.first { $0.text == "one" })
        XCTAssertTrue(DOMPosition(division) < DOMPosition(one))
        XCTAssertTrue(DOMPosition(one, 1) < DOMPosition(one, 2))
        XCTAssertTrue(DOMPosition(one, 3) < DOMPosition(bold))
        XCTAssertFalse(DOMPosition(one, 2) < DOMPosition(one, 2))
        XCTAssertEqual(Set([DOMPosition(one, 1), DOMPosition(one, 1), DOMPosition(one, 2), DOMPosition(bold)]).count, 3)
        XCTAssertEqual(division.textContent, "onetwothree")
        XCTAssertEqual(division.elementChildren.count, 2)
    }
}
