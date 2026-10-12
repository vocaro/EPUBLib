@testable import EPUBViewing
import XCTest

/// How a section's author stylesheets are found and read (`SectionStyles`): `link` and `style`
/// in every position, their attributes, text wrappers, encodings and bounds.
final class CSSSyntaxStylesheetLoadingCoverageTests: XCTestCase {
    /// A section whose body has one paragraph per id, with `sheets` (name to selector ids) in the archive.
    private func marked(head: String, ids: [String], sheets: [String: String] = [:], body: String = "") throws -> (ids: [String], result: StyledDocument) {
        let paragraphs = ids.map { #"<p id="\#($0)">x</p>"# }.joined()
        let files = sheets.mapValues { "#\($0) { \(CSSSyntaxSupport.marker) }" }
        let result = try CSSSyntaxSupport.styled(section: StyleTestSupport.xhtml(body: paragraphs + body, head: head), files: files)
        return (CSSSyntaxSupport.marked(result), result)
    }

    func testOnlyALinkWhoseRelTokensIncludeStylesheetAndNotAlternateIsLoaded() throws {
        let (ids, result) = try marked(head: """
            <link rel="stylesheet" href="a.css"/>
            <link rel="STYLESHEET" href="b.css"/>
            <link rel="  stylesheet  " href="c.css"/>
            <link rel="preload stylesheet" href="d.css"/>
            <link rel="stylesheet&#9;next" href="e.css"/>
            <link href="f.css" rel="stylesheet" id="late"/>
            <link rel="alternate stylesheet" href="x.css"/>
            <link rel="stylesheet alternate" href="x.css"/>
            <link rel="Alternate StyleSheet" href="x.css" title="Night"/>
            <link rel="icon" href="x.css"/>
            <link rel="" href="x.css"/>
            <link href="x.css"/>
            <link rel="stylesheets" href="x.css"/>
            <link rel="style sheet" href="x.css"/>
            <link rel="stylesheet"/>
            """, ids: ["a", "b", "c", "d", "e", "f", "x"],
                                       sheets: ["a.css": "a", "b.css": "b", "c.css": "c", "d.css": "d", "e.css": "e", "f.css": "f", "x.css": "x"])
        XCTAssertEqual(ids, ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(result.sheets.count, 6)
        XCTAssertEqual(result.report.unreadableResources, 0, "A link that is not a stylesheet is not a failed one")
    }

    func testLinkTypeAndMediaAttributesDecideWhetherASheetApplies() throws {
        let applied = "abcdefghijk".map { String($0) }
        let (ids, result) = try marked(head: """
            <link rel="stylesheet" type="text/css" href="a.css"/>
            <link rel="stylesheet" type="TEXT/CSS" href="b.css"/>
            <link rel="stylesheet" type=" text/css ; charset=utf-8" href="c.css"/>
            <link rel="stylesheet" type="" href="d.css"/>
            <link rel="stylesheet" type="text/x-oeb1-css" href="e.css"/>
            <link rel="stylesheet" media="screen" href="f.css"/>
            <link rel="stylesheet" media="" href="g.css"/>
            <link rel="stylesheet" media="  ALL  " href="h.css"/>
            <link rel="stylesheet" media="print, screen" href="i.css"/>
            <link rel="stylesheet" media="not amzn-mobi" href="j.css"/>
            <link rel="stylesheet" media="only screen and (min-width: 1px)" href="k.css"/>
            <link rel="stylesheet" type="text/plain" href="x.css"/>
            <link rel="stylesheet" type="text/less" href="x.css"/>
            <link rel="stylesheet" type="css" href="x.css"/>
            <link rel="stylesheet" media="print" href="x.css"/>
            <link rel="stylesheet" media="amzn-kf8" href="x.css"/>
            <link rel="stylesheet" media="bogus!" href="x.css"/>
            <link rel="stylesheet" media="screen and (monochrome)" href="x.css"/>
            <link rel="stylesheet" media="print" href="missing-print.css"/>
            """, ids: applied + ["x"], sheets: Dictionary(uniqueKeysWithValues: (applied + ["x"]).map { ("\($0).css", $0) }))
        XCTAssertEqual(ids, applied)
        XCTAssertEqual(result.report.unreadableResources, 0, "A sheet for another medium is never read")
    }

    func testAnAdobePageTemplateLinkedAsAStylesheetYieldsNoRuleAndNoReport() throws {
        // EPUB 2 books made for Adobe Digital Editions link an XML page template with rel="stylesheet".
        let template = """
            <ade:template xmlns="http://www.w3.org/1999/xhtml" xmlns:ade="http://ns.adobe.com/2006/ade" xmlns:fo="http://www.w3.org/1999/XSL/Format">
            <fo:layout-master-set><fo:simple-page-master master-name="single_column"><fo:region-body margin-bottom="3pt"/></fo:simple-page-master></fo:layout-master-set>
            <ade:style><ade:styling-rule selector="#x" display="none"/></ade:style></ade:template>
            """
        let section = StyleTestSupport.xhtml(body: #"<p id="a">a</p><p id="x">x</p>"#, head: """
            <link rel="stylesheet" type="application/vnd.adobe-page-template+xml" href="page-template.xpgt"/>
            <link rel="stylesheet" href="page-template.xpgt"/>
            <link rel="stylesheet" type="text/css" href="main.css"/>
            """)
        let result = try CSSSyntaxSupport.styled(section: section, files: ["page-template.xpgt": template, "main.css": "#a { clear: both }"])
        XCTAssertEqual(CSSSyntaxSupport.marked(result), ["a"])
        XCTAssertEqual(result.style("x").display, .block, "Markup read as CSS yields no rule")
        XCTAssertEqual(result.report, SectionReport(), "Neither form of the link is a failure to report")
    }

    func testStyleElementsAndLinksApplyInDocumentOrderWhereverTheyStand() throws {
        let section = """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title>
            <style>#a { text-align: left } #b { text-align: left }</style>
            <link rel="stylesheet" href="one.css"/>
            <style>#b { text-align: right }</style>
            </head><body><p id="a">a</p><style>#c { text-align: center }</style><p id="b">b</p><p id="c">c</p>
            <div><style>#d { text-align: right }</style><p id="d">d</p><link rel="stylesheet" href="two.css"/></div>
            <svg xmlns="http://www.w3.org/2000/svg"><style>#e { text-align: center }</style><defs><style type="text/css">#f { text-align: right }</style></defs></svg>
            <p id="e">e</p><p id="f">f</p><p id="g">g</p><style>#g { text-align: left }</style></body></html>
            """
        let result = try CSSSyntaxSupport.styled(section: section, files: [
            "one.css": "#a { text-align: right } #b { text-align: center } #c { text-align: left }",
            "two.css": "#d { text-align: center } #g { text-align: right }",
        ])
        XCTAssertEqual(["a", "b", "c", "d", "e", "f", "g"].map { result.style($0).textAlign }, [.right, .right, .center, .center, .center, .right, .left])
        XCTAssertEqual(result.sheets.count, 9)
    }

    func testStyleTypeAndMediaAttributes() throws {
        let (ids, _) = try marked(head: """
            <style type="text/css">#a { clear: both }</style>
            <style type="TEXT/CSS">#b { clear: both }</style>
            <style type="">#c { clear: both }</style>
            <style media="screen">#d { clear: both }</style>
            <style media="not print">#e { clear: both }</style>
            <style media="print, all" type="text/css; charset=utf-8">#f { clear: both }</style>
            <style type="text/plain">#x { clear: both }</style>
            <style type="text/x-scss">#x { clear: both }</style>
            <style media="print">#x { clear: both }</style>
            <style media="speech and (color)">#x { clear: both }</style>
            <style media="not all">#x { clear: both }</style>
            """, ids: ["a", "b", "c", "d", "e", "f", "x"])
        XCTAssertEqual(ids, ["a", "b", "c", "d", "e", "f"])
    }

    func testStyleTextInCDATAEntitiesAndCommentWrappers() throws {
        let (ids, result) = try marked(head: """
            <style><![CDATA[ #a > i, #a { clear: both } ]]></style>
            <style>/*<![CDATA[*/ #b { clear: both } /*]]>*/</style>
            <style>#c { clear: both } <![CDATA[ #d { clear: both } ]]> #e { clear: both }</style>
            <style>#f &gt; i, #f { clear: both } #g::before { content: "&lt;&amp;" } #g { clear: both }</style>
            <style>&lt;!-- #h { clear: both } --&gt;</style>
            <style><!-- #x { clear: both } --></style>
            <style><!--/*--><![CDATA[/*><!--*/ #i { clear: both } /*]]>*/--></style>
            <style>#j { clear: both }<!-- #x { clear: both } -->#k { clear: both }</style>
            <style></style><style> </style><style/>
            """, ids: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "x"])
        // An XML comment inside `style` is not style text: an XHTML user agent sees no rule in it.
        XCTAssertEqual(ids, ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"])
        XCTAssertFalse(result.report.stylesTruncated)
    }

    func testACommentWrappedStyleSheetAppliesInAnHTMLParsedDocument() throws {
        // HTML reads `style` as raw text, so the comment delimiters reach CSS, which skips them.
        let section = """
            <html><head><title>T</title><style type="text/css"><!--
            #a { clear: both }
            body > p#b { clear: both }
            --></style></head><body><p id="a">a</p><p id="b">b</p><p id="c">c</p></body></html>
            """
        let result = try CSSSyntaxSupport.styled(section: section)
        XCTAssertTrue(result.document.recoveredAsHTML)
        XCTAssertEqual(CSSSyntaxSupport.marked(result), ["a", "b"])
    }

    func testMissingRemoteAndUnsafeSheetsAreReportedAndNamespaceNamesAreNot() throws {
        let (ids, result) = try marked(head: """
            <link rel="stylesheet" href="missing.css"/>
            <link rel="stylesheet" href="https://example.com/remote.css"/>
            <link rel="stylesheet" href="//cdn.example.com/remote.css"/>
            <link rel="stylesheet" href="../../../outside.css"/>
            <link rel="stylesheet" href="data:text/css,%23x%7Bclear%3Aboth%7D"/>
            <link rel="stylesheet" href="present.css?v=2#top"/>
            <link rel="stylesheet" href=" spaced.css "/>
            <style>
            @namespace epub "http://www.idpf.org/2007/ops"; @namespace url(http://www.w3.org/1999/xhtml);
            #c { clear: both }
            </style>
            """, ids: ["a", "b", "c", "x"], sheets: ["present.css": "a", "spaced.css": "b"])
        XCTAssertEqual(ids, ["a", "b", "c"])
        XCTAssertEqual(result.report.remoteResourcesRefused, 2, "Two remote sheets; a namespace name is not a resource")
        XCTAssertEqual(result.report.unreadableResources, 2, "A missing sheet and one leaving the archive")
    }

    /// A `Character` holds a "/", "\", "?" or "#" together with a combining mark, variation
    /// selector or joiner after it; a reference is read by its bytes, as the archive's paths are
    /// (https://github.com/vocaro/EPUBLib/issues/181).
    func testAStyleReferenceIsReadWhateverMarkFollowsItsSeparators() throws {
        let base = "OPS/css/main.css"
        func path(_ reference: String) -> [Unicode.Scalar]? {
            guard case .local(let path) = StyleReference(reference, relativeTo: base) else { return nil }
            return Array(path.unicodeScalars)
        }
        for mark in ["\u{301}", "\u{338}", "\u{20E3}", "\u{FE0F}", "\u{200D}", "\u{1F3FB}", "\u{93E}", "\u{3099}"] {
            // The path ends at the first "?" or "#", and its dot segments resolve.
            XCTAssertEqual(path("fonts/a.otf#\(mark)x"), Array("OPS/css/fonts/a.otf".unicodeScalars), mark.debugDescription)
            XCTAssertEqual(path("fonts/a.otf?\(mark)v=2#iefix"), Array("OPS/css/fonts/a.otf".unicodeScalars), mark.debugDescription)
            XCTAssertEqual(path("../\(mark)a.css"), Array("OPS/\(mark)a.css".unicodeScalars), mark.debugDescription)
            XCTAssertEqual(path("x/../\(mark)a.css?\(mark)"), Array("OPS/css/\(mark)a.css".unicodeScalars), mark.debugDescription)
            // Read as the same reference is without the mark. One that climbs past the container
            // root or opens with a slash starts at the root (https://github.com/vocaro/EPUBLib/issues/84),
            // and a colon is a character of the name (https://github.com/vocaro/EPUBLib/issues/171).
            XCTAssertEqual(path("../../../\(mark)a.css"), Array("\(mark)a.css".unicodeScalars), mark.debugDescription)
            XCTAssertEqual(path("/\(mark)a.css"), Array("\(mark)a.css".unicodeScalars), mark.debugDescription)
            XCTAssertEqual(path("./a:\(mark)b.css"), Array("OPS/css/a:\(mark)b.css".unicodeScalars), mark.debugDescription)
            // A backslash names no entry, and nor does a query or a fragment with no path before it.
            for reference in ["a\\\(mark)b.css", "?\(mark)", "#\(mark)a"] {
                XCTAssertEqual(StyleReference(reference, relativeTo: base), .invalid, reference.debugDescription)
            }
        }
    }

    func testAMissingImportIsReportedAndARemoteOneCounted() throws {
        let section = StyleTestSupport.xhtml(body: #"<p id="a">a</p>"#, head: """
            <link rel="stylesheet" href="css/main.css"/><style>@import "css/gone.css"; @import url(https://example.com/inline.css);</style>
            """)
        let result = try CSSSyntaxSupport.styled(section: section, files: [
            "css/main.css": "@import 'nowhere.css'; @import 'https://example.com/font.css'; @import 'print.css' print; #a { clear: both }",
        ])
        XCTAssertEqual(CSSSyntaxSupport.marked(result), ["a"])
        XCTAssertEqual(result.report.unreadableResources, 2, "nowhere.css and css/gone.css; the print import is never read")
        XCTAssertEqual(result.report.remoteResourcesRefused, 2)
    }

    func testASheetLinkedAgainCascadesAgainAtItsLaterPosition() throws {
        let section = StyleTestSupport.xhtml(body: #"<p id="a">a</p>"#, head: """
            <link rel="stylesheet" href="left.css"/><link rel="stylesheet" href="right.css"/><link rel="stylesheet" href="left.css"/>
            """)
        let result = try CSSSyntaxSupport.styled(section: section, files: ["left.css": "p { text-align: left }", "right.css": "p { text-align: right }"])
        XCTAssertEqual(result.style("a").textAlign, .left)
        XCTAssertEqual(result.sheets.count, 3)
    }

    func testOnlyThePreferredTitledStyleSheetSetApplies() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/116")
        // HTML §4.6.7 link type "stylesheet" and CSSOM §6.2 "add a CSS style sheet": the first
        // titled, non-alternate sheet names the preferred set; a sheet with another title is
        // disabled. Untitled sheets are persistent and always apply.
        let section = StyleTestSupport.xhtml(body: #"<p id="a">a</p>"#, head: """
            <link rel="stylesheet" href="base.css"/>
            <link rel="stylesheet" href="day.css" title="Day"/>
            <link rel="stylesheet" href="night.css" title="Night"/>
            <link rel="stylesheet" href="more-day.css" title="Day"/>
            """)
        let result = try CSSSyntaxSupport.styled(section: section, files: [
            "base.css": "p { text-indent: 1px }", "day.css": "p { text-align: left }", "night.css": "p { text-align: right; font-weight: 700 }",
            "more-day.css": "p { word-spacing: 2px }",
        ])
        XCTAssertEqual(result.style("a").textIndent, .points(1))
        XCTAssertEqual(result.style("a").wordSpacing, 2)
        XCTAssertEqual(result.style("a").textAlign, .left, "The Night set is not the preferred one")
        XCTAssertEqual(result.style("a").fontWeight, 400)
    }

    func testADisabledLinkIsNotApplied() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/116")
        // HTML §4.2.4: "The disabled attribute is a boolean attribute that is used to disable an
        // explicitly enabled style sheet"; scripts never run here, so it can never be re-enabled.
        let section = StyleTestSupport.xhtml(body: #"<p id="a">a</p>"#, head: """
            <link rel="stylesheet" href="day.css"/><link rel="stylesheet" href="night.css" disabled="disabled"/>
            """)
        let result = try CSSSyntaxSupport.styled(section: section, files: ["day.css": "p { text-align: left }", "night.css": "p { text-align: right }"])
        XCTAssertEqual(result.style("a").textAlign, .left)
    }

    func testAStylesheetAssociatedByAnXMLStylesheetProcessingInstructionApplies() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/115")
        // Associating Style Sheets with XML documents 1.0 §4, which HTML's XML syntax and CSSOM
        // §6.4 require of user agents; foliate-js rewrote these hrefs so that WebKit loaded them.
        let section = """
            <?xml version="1.0" encoding="UTF-8"?>
            <?xml-stylesheet href="css/associated.css" type="text/css"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body><p id="a">a</p></body></html>
            """
        let result = try CSSSyntaxSupport.styled(section: section, files: ["css/associated.css": "#a { clear: both }"])
        XCTAssertEqual(CSSSyntaxSupport.marked(result), ["a"])
    }

    func testAByteOrderMarkIsNotStyleTextInASheetCutToTheSizeBound() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/116")
        // The sheet's two rules come first; only the comment after them crosses the bound.
        let rules = "#a { clear: both } #b { clear: both }"
        let padding = "/*" + String(repeating: "x", count: SectionStyles.maximumSheetBytes) + "*/"
        let section = StyleTestSupport.xhtml(body: #"<p id="a">a</p><p id="b">b</p>"#, head: #"<link rel="stylesheet" href="big.css"/>"#)
        let plain = try CSSSyntaxSupport.styled(section: section, files: ["big.css": Data((rules + padding).utf8)])
        XCTAssertEqual(CSSSyntaxSupport.marked(plain), ["a", "b"])
        XCTAssertTrue(plain.report.stylesTruncated)
        let marked = try CSSSyntaxSupport.styled(section: section, files: ["big.css": Data([0xEF, 0xBB, 0xBF]) + Data((rules + padding).utf8)])
        XCTAssertEqual(CSSSyntaxSupport.marked(marked), ["a", "b"], "The byte order mark must not become part of the first selector")
        XCTAssertTrue(marked.report.stylesTruncated)
    }

    func testStylesheetBytesDecodeFromUTF8UTF16AndLatin1() throws {
        func utf16(_ text: String, bigEndian: Bool) -> Data {
            var data = Data(bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE])
            for unit in text.utf16 { data.append(contentsOf: bigEndian ? [UInt8(unit >> 8), UInt8(unit & 0xFF)] : [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
            return data
        }
        XCTAssertEqual(SectionStyles.decode(Data([0xEF, 0xBB, 0xBF]) + Data("p{}".utf8)), "p{}", "A UTF-8 byte order mark is not style text")
        XCTAssertEqual(SectionStyles.decode(utf16(".é{}", bigEndian: false)), ".é{}")
        XCTAssertEqual(SectionStyles.decode(utf16(".é{}", bigEndian: true)), ".é{}")
        XCTAssertEqual(SectionStyles.decode(Data("@charset \"iso-8859-1\"; .caf".utf8) + Data([0xE9]) + Data("{}".utf8)), "@charset \"iso-8859-1\"; .café{}")
        XCTAssertEqual(SectionStyles.decode(Data()), "")
        XCTAssertEqual(SectionStyles.decode(Data([0xEF, 0xBB, 0xBF])), "")
        XCTAssertEqual(SectionStyles.decode(Data([0xFF, 0xFE])), "")
        for bytes: [UInt8] in [[0xFF], [0xFE, 0xFF, 0x00], [0x81, 0x8D, 0x8F, 0x90, 0x9D], [0xC3], [0xED, 0xA0, 0x80], [0xF8, 0x88, 0x80, 0x80, 0x80]] {
            _ = SectionStyles.decode(Data(bytes)) // Undecodable bytes must never trap.
        }

        let body = #"<p id="bom">a</p><p id="le" class="é">b</p><p id="be">c</p><p id="latin" class="café">d</p><p id="x">x</p>"#
        let section = StyleTestSupport.xhtml(body: body, head: """
            <link rel="stylesheet" href="bom.css"/><link rel="stylesheet" href="le.css"/><link rel="stylesheet" href="be.css"/>
            <link rel="stylesheet" href="latin.css"/>
            """)
        let result = try CSSSyntaxSupport.styled(section: section, files: [
            "bom.css": Data([0xEF, 0xBB, 0xBF]) + Data("#bom { clear: both } #x { float: left }".utf8),
            "le.css": utf16("@charset \"utf-16\";\n.é { clear: both }", bigEndian: false),
            "be.css": utf16("#be { clear: both }", bigEndian: true),
            "latin.css": Data("@charset \"iso-8859-1\";\n.caf".utf8) + Data([0xE9]) + Data(" { clear: both }".utf8),
        ])
        XCTAssertEqual(CSSSyntaxSupport.marked(result), ["bom", "le", "be", "latin"])
        XCTAssertEqual(result.style("x").float, .left)
    }

    func testTheRuleBoundSpansTheSheetsOfASection() throws {
        let perSheet = CSSStyleSheet.maximumRules * 3 / 5
        func rules(_ prefix: String) -> String { (0..<perSheet).map { ".\(prefix)\($0){clear:both}" }.joined(separator: "\n") }
        let kept = CSSStyleSheet.maximumRules - perSheet
        let section = StyleTestSupport.xhtml(body: """
            <p id="first" class="a0">a</p><p id="early" class="b0">b</p><p id="edge" class="b\(kept - 1)">c</p><p id="past" class="b\(kept)">d</p>
            """, head: #"<link rel="stylesheet" href="a.css"/><link rel="stylesheet" href="b.css"/>"#)
        let result = try CSSSyntaxSupport.styled(section: section, files: ["a.css": rules("a"), "b.css": rules("b")])
        XCTAssertEqual(result.sheets.map(\.rules.count), [perSheet, kept])
        XCTAssertEqual(CSSSyntaxSupport.marked(result), ["first", "early", "edge"], "Rules past the section's bound are dropped in source order")
        XCTAssertTrue(result.report.stylesTruncated)
    }

    func testTheByteBudgetSpansTheSheetsOfASection() throws {
        // Each sheet is mostly a comment, with its one rule at the very end.
        let size = SectionStyles.maximumSheetBytes - 1024
        let count = SectionStyles.maximumSectionBytes / size + 1
        var files: [String: String] = [:]
        for index in 0..<count {
            let rule = "#p\(index){clear:both}"
            files["s\(index).css"] = "/*" + String(repeating: "x", count: size - rule.utf8.count - 4) + "*/" + rule
        }
        let section = StyleTestSupport.xhtml(body: (0..<count).map { #"<p id="p\#($0)">x</p>"# }.joined(),
                                             head: (0..<count).map { #"<link rel="stylesheet" href="s\#($0).css"/>"# }.joined())
        let result = try CSSSyntaxSupport.styled(section: section, files: files)
        XCTAssertEqual(CSSSyntaxSupport.marked(result), (0..<(count - 1)).map { "p\($0)" }, "The sheet that crosses the budget loses the rule it cannot hold whole")
        XCTAssertTrue(result.report.stylesTruncated)
    }

    func testWithinItsBoundsNothingIsReportedAsTruncated() throws {
        let (ids, result) = try marked(head: #"<link rel="stylesheet" href="a.css"/><style>#b { clear: both } @media print { #x { clear: both } }</style>"#,
                                       ids: ["a", "b", "x"], sheets: ["a.css": "a"])
        XCTAssertEqual(ids, ["a", "b"])
        XCTAssertEqual(result.report, SectionReport(), "An ordinary section reports nothing")
    }
}
