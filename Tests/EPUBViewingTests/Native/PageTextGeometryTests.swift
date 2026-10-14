import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Generated boxes from the review corpus recorded on #242, held against native section
/// lines and the characters actually visible on each page, rather than fixed page counts.
@MainActor final class PageTextGeometryTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    typealias Line = (range: NSRange, frame: CGRect)
    static func rawLines(in view: ReaderTextView, intersecting range: NSRange) -> [Line] {
        var result: [Line] = []
        view.readerLayoutManager.enumerateTextLayoutFragments(from: view.contentStorage.documentRange.location, options: [.ensuresLayout]) { fragment in
            let start = view.offset(of: fragment.rangeInElement.location)
            let frame = fragment.layoutFragmentFrame
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                let lineRange = NSRange(location: start + line.characterRange.location, length: line.characterRange.length)
                if NSIntersectionRange(range, lineRange).length > 0 {
                    result.append((lineRange, line.typographicBounds.offsetBy(dx: frame.origin.x, dy: frame.origin.y)))
                }
            }
            return true
        }
        return result
    }

    struct Generated { var body: String; var css: String; var files: [String: Data]; var leadEnd: String? }

    static let ltr = ["Ordinary prose wraps beside the box and returns to the full column below it.",
                      "The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in.",
                      "Short one.", "She counted the steps twice; forty-one each time, which settled nothing at all.",
                      "Words of several lengths, unremarkable and plain, fill another row or two of the column.",
                      "Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences.",
                      "No.", "A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up.",
                      "Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and \u{201C}quotation marks\u{201D}."]
    static let rtl = ["זהו משפט רגיל בעברית שעוטף ליד התיבה וחוזר לטור המלא מתחתיה.",
                      "هذه جملة عربية عادية تلتف بجانب المربع ثم تعود إلى العمود الكامل تحته.",
                      "משפט קצר.", "النص العربي يستمر هنا بكلمات أخرى مختلفة الطول حتى ينتهي السطر ويبدأ سطر جديد.",
                      "עוד משפט, הפעם עם מספרים 123 ומילים באנגלית like these בתוכו."]

    static func generate(_ random: inout SectionContentRandom, viewport: CGSize, deep: Int = 0) -> Generated {
        var body = "", css = "", id = 0, counter = 0
        var files: [String: Data] = [:]
        func cls(_ declarations: String) -> String { id += 1; css += ".k\(id) { \(declarations) } "; return "k\(id)" }
        func label() -> String { counter += 1; return "T\(counter)" }
        func prose(_ count: Int, rtl: Bool = false) -> String { (0..<count).map { _ in random.pick(rtl ? Self.rtl : Self.ltr) }.joined(separator: " ") }
        func frac(_ low: Double, _ high: Double, _ unit: String) -> String {
            let steps = random.pick([1.0, 4.0, 3.0, 10.0, 7.0])
            let value = low + (high - low) * Double(random.next(1000)) / 1000
            return "\((value * steps).rounded() / steps)\(unit)"
        }
        func marginDecl() -> String {
            random.pick(["", "", "", "", "margin:6px 8px; ", "margin-bottom:9.5px; ", "margin-top:7px; ", "margin:0.7em 0; ", "margin-top:-6px; ", "margin-top:-0.45em; ",
                         "margin-bottom:-4px; ", "margin:\(frac(0, 14, "px")) \(frac(0, 9, "px")); ", "margin-bottom:\(frac(0, 2, "em")); ", "margin-left:-5px; ", "margin:-3.3px 0 11.1px 0; "])
        }
        func floatBox(forceBreak: Bool = false) -> String {
            var d = "float:\(random.chance(3) ? "right" : "left"); "
            d += random.pick(["width:40px; ", "width:60px; ", "width:25%; ", "width:33.333%; ", "width:50%; ", "width:100%; ", "", "width:6.5em; ", "width:72%; ",
                              "width:\(frac(30, 140, "px")); ", "width:\(frac(2, 9, "em")); ", "max-width:45%; ", "min-width:55px; width:10%; "])
            d += random.pick(["", "", "height:30px; ", "height:75px; ", "height:120.5px; ", "height:3.3em; ", "min-height:41.3px; ", "height:\(frac(20, 160, "px")); ",
                              "height:\(frac(1, 7, "em")); ", "height:40%; "])
            d += marginDecl()
            d += random.pick(["", "", "", "padding:4px; ", "padding:0.33em 0; ", "padding:\(frac(0, 8, "px")); ", "border:1px solid #333; ", "border:2.5px solid #333; padding:3px; "])
            d += random.pick(["", "", "", "", "", "clear:left; ", "clear:both; ", "clear:right; "])
            d += random.pick(["", "", "", "", "font-size:0.8em; ", "font-size:1.37em; ", "line-height:1.1; ", "text-align:center; "])
            if forceBreak || random.chance(14) { d += "break-before:page; " }
            let name = cls(d), tag = label()
            switch random.next(9) {
            case 0: return "<figure class='\(name)'><p>Top \(tag).</p><p>Bottom \(tag) words.</p></figure>"
            case 1: return "<figure class='\(name)'>Float \(tag) with rather more words in it than fit on a line.</figure>"
            case 2: return "<figure class='\(name)'><p>Top \(tag).</p><p>Middle \(tag) words wrap here.</p><p>Bottom \(tag).</p></figure>"
            case 3: return "<figure class='\(name)' dir='rtl'>\(tag) \(prose(1, rtl: true))</figure>"
            case 4:
                let w = random.pick([40, 64, 120]), h = random.pick([30, 64, 150])
                files["i\(w)x\(h).png"] = RichFixture.image(width: w, height: h)
                return "<img class='\(name)' src='i\(w)x\(h).png' alt='Picture \(tag)'/>"
            case 5: return "<aside class='\(name)'><h3>Side \(tag)</h3><p>\(prose(1))</p></aside>"
            default: return "<figure class='\(name)'>Float \(tag).</figure>"
            }
        }
        func positioned(_ position: String = "absolute") -> String {
            var d = "position:\(position); width:\(random.pick(["30%", "100px", "45%", "100%", "62.5%", frac(40, 200, "px"), "8em"])); " + random.pick(["right:0; ", "left:0; ", "", "left:12%; ", "right:7.5px; "])
            d += random.pick(["", "top:0; ", "top:40px; ", "top:150.5px; ", "bottom:10px; ", "top:1.7em; ", "top:3.1em; ", "top:12%; ", "top:\(frac(0, 90, "px")); ",
                              "top:\(frac(0, 0.9, "px")); ", "bottom:\(frac(0, 60, "px")); ", "top:66.6%; ", "bottom:0; "])
            d += random.pick(["", "", "height:50px; ", "padding:3px; ", "height:\(frac(15, 90, "px")); ", "margin-top:5px; "])
            let tag = label()
            return random.chance(4) ? "<aside class='\(cls(d))'><p>Placed \(tag) top.</p><p>Placed \(tag) end words.</p></aside>"
                : "<aside class='\(cls(d))'>Placed \(tag) words.</aside>"
        }
        func inlineBlock() -> String {
            let box = cls("display:inline-block; width:\(random.pick(["4em", "80px", "500px", "50%", "100%", frac(20, 150, "px")])); height:\(random.pick(["2em", "40px", "100px", "61.7px", frac(10, 120, "px")])); "
                + random.pick(["", "", "vertical-align:top; ", "margin:0 4px; ", "padding:2px; "]))
            let tag = label()
            switch random.next(4) {
            case 0: return "<p><span class='\(box)'>Sized \(tag) box.</span> after. \(prose(1 + random.next(6)))</p>"
            case 1: return "<p>Before \(tag) \(prose(1)) <span class='\(box)'>Sized inline box.</span> and <span class='\(box)'>another.</span> after. \(prose(1 + random.next(4)))</p>"
            default: return "<p>Before \(tag) <span class='\(box)'>Sized inline box.</span> after. \(prose(1 + random.next(6)))</p>"
            }
        }
        func paragraph(_ sentences: Int? = nil) -> String {
            var d = random.pick(["", "", "", "", "", "clear:left; ", "clear:right; ", "clear:both; "])
            d += random.pick(["", "", "", "margin-top:5.5px; ", "margin-bottom:12px; ", "margin:1em 0; ", "margin-top:30px; ", "text-indent:1.5em; ", "margin-top:-8px; ",
                              "margin:\(frac(0, 20, "px")) 0 \(frac(0, 20, "px")) 0; ", "margin-left:7%; ", "margin:0 0 -5.5px 0; ", "text-indent:-1em; padding-left:1em; "])
            if random.chance(9) { d += "break-before:page; " }
            if random.chance(22) { d += "break-after:page; " }
            if random.chance(6) { d += "text-align:justify; " }
            if random.chance(8) { d += "line-height:\(random.pick(["1.7", "1.15", "22.4px", "0.9"])); " }
            if random.chance(12) { d += "font-size:\(random.pick(["0.83em", "1.21em", "13.3px"])); " }
            if random.chance(20) { d += "text-align:\(random.pick(["center", "right"])); " }
            let isRTL = random.chance(6)
            return "<p class='\(cls(d))'\(isRTL ? " dir='rtl'" : "")>\(label()). \(prose(sentences ?? (1 + random.next(9)), rtl: isRTL))</p>"
        }
        func dropCap() -> String {
            let cap = cls("float:left; font-size:\(random.pick(["3em", "2.4em", "2em", "4.1em", "2.75em"])); "
                + random.pick(["", "margin-right:4px; ", "line-height:1; ", "line-height:0.8; padding-right:0.1em; ", "margin:-0.1em 0.08em 0 0; ", "height:1.6em; "]))
            let isRTL = random.chance(9)
            if isRTL { return "<p dir='rtl'><span class='\(cls("float:right; font-size:2.5em; line-height:1; "))'>ש</span>\(label()) \(prose(2 + random.next(5), rtl: true))</p>" }
            return "<p><span class='\(cap)'>D</span>rop \(label()). \(prose(2 + random.next(6)))</p>"
        }
        func spacer(_ bound: CGFloat? = nil) -> String { "<p class='\(cls("margin-bottom:\(frac(0, Double(bound ?? viewport.height), "px"))"))'>\(label()).</p>" }
        func table() -> String {
            let tag = label(), rows = random.pick([2, 2, 3, 5, 9, 14])
            let cells = (1...rows).map { "<tr><td>Row \($0) \(tag)</td><td>\(random.chance(4) ? prose(1) : "two")</td>\(random.chance(3) ? "<td>3</td>" : "")</tr>" }.joined()
            return "<table\(random.chance(4) ? " class='\(cls("width:100%; "))'" : "")>\(cells)</table>"
        }
        func heading() -> String { let level = random.pick([1, 2, 2, 3]); return "<h\(level)>Heading \(label())</h\(level)>" }
        func list() -> String { "<ul>" + (0..<(2 + random.next(3))).map { _ in "<li>Item \(label()). \(prose(1))</li>" }.joined() + "</ul>" }
        func quote() -> String { "<blockquote class='\(cls("margin:\(frac(0, 16, "px")) \(frac(0, 30, "px")); "))'><p>Quoted \(label()). \(prose(1 + random.next(3)))</p></blockquote>" }
        func relative(_ inner: String) -> String {
            let rel = cls("position:relative; " + random.pick(["margin-left:10%; ", "left:-2%; ", "top:12px; ", "", "top:1.3em; ", "top:31.5px; margin-right:12%; ", "width:80%; margin:0 auto; ",
                                                               "top:\(frac(0, 25, "px")); ", "top:-9px; ", "bottom:6px; ", "height:200px; "]))
            return "<div class='\(rel)'>\(inner)</div>"
        }
        func opener() -> String {
            switch random.next(20) {
            case 0: return floatBox()
            case 1: return floatBox() + floatBox()
            case 2: return positioned()
            case 3: return positioned() + floatBox()
            case 4: return floatBox() + positioned()
            case 5: return inlineBlock()
            case 6: return dropCap()
            case 7: return relative(floatBox() + paragraph())
            case 8: return relative(positioned() + paragraph())
            case 9: return positioned("fixed")
            case 10: return heading() + floatBox()
            case 11: return floatBox() + table()
            case 12: return floatBox() + floatBox() + positioned() + floatBox()
            case 13: return positioned() + table()
            case 14: return floatBox() + floatBox() + floatBox()
            case 15: return positioned("fixed") + table()
            case 16: return floatBox() + list()
            case 17: return positioned() + positioned() + paragraph(1)
            case 18: return floatBox() + heading() + paragraph()
            default: return relative(floatBox() + floatBox()) + positioned()
            }
        }
        var leadEnd: String?
        if deep > 0 {
            // A tall lead: gaps are capped at 600 each, so many of them.
            let gap = cls("margin-bottom:\(random.pick(["600px", "600px", "599.3px", "587.25px"]))")
            for _ in 0..<deep { body += "<p class='\(gap)'>x</p>" }
            leadEnd = "ENDLEAD"
            body += "<p>ENDLEAD</p>" + opener()
        } else {
            switch random.next(6) {
            case 0, 1: body += spacer()
            case 2, 3: body += opener()
            case 4: for _ in 0..<(1 + random.next(5)) { body += spacer(600) }; body += opener()
            default: break
            }
        }
        for _ in 0..<(4 + random.next(8)) {
            switch random.next(22) {
            case 0...3: body += paragraph()
            case 4, 5: for _ in 0..<(1 + random.next(3)) { body += floatBox() }
            case 6: body += dropCap()
            case 7: body += positioned()
            case 8: body += inlineBlock()
            case 9: body += spacer()
            case 10: body += "<p class='\(cls("break-after:page; "))'>\(label()) before a break.</p>" + opener()
            case 11: body += spacer() + opener()
            case 12: body += relative(random.chance(2) ? "<p>Relative \(label()). \(prose(1 + random.next(3)))</p>" : opener() + paragraph())
            case 13: body += table()
            case 14: body += heading() + (random.chance(2) ? floatBox() : paragraph())
            case 15: body += positioned("fixed")
            case 16: body += floatBox(forceBreak: true)
            case 17: body += list()
            case 18: body += quote()
            case 19: body += floatBox() + paragraph(1) + floatBox() + paragraph(1)
            case 20: body += paragraph(12 + random.next(14))
            default: body += spacer() + floatBox() + paragraph(6 + random.next(8))
            }
        }
        body += paragraph()
        return Generated(body: body, css: css, files: files, leadEnd: leadEnd)
    }

    static let viewports = [CGSize(width: 180, height: 240), CGSize(width: 250, height: 333.3), CGSize(width: 300.5, height: 419.75), CGSize(width: 320, height: 480),
                            CGSize(width: 361.33, height: 617.5), CGSize(width: 390, height: 700), CGSize(width: 400, height: 600), CGSize(width: 512, height: 342.5),
                            CGSize(width: 720, height: 980), CGSize(width: 1024, height: 700.25)]
    static let fontSizes: [CGFloat] = [12, 13.1, 14.5, 16, 17, 18.5, 19.3, 21.7, 25, 31.4, 42]


    func testATextLineTallerThanItsColumnKeepsItsCharactersAndSemanticRoles() throws {
        let section = try H.build("<h2 id='oversized' style='font-size:400px; line-height:10'>Large heading words.</h2><p>Following words.</p>", css: H.reset)
        assertPages(section, size: CGSize(width: 180, height: 240), label: "oversized heading")
        let paginator = ReaderPaginator(text: section.string, size: CGSize(width: 180, height: 240))
        let page = paginator.allPages[0]
        XCTAssertTrue(page.usesFlowFallback)
        XCTAssertEqual(paginator.text(for: page).string, (paginator.text.string as NSString).substring(with: NSRange(location: page.range.location, length: page.layoutEnd - page.range.location)))
        // The heading role and source mapping stay on the original characters; typography
        // changes only in the displayed fallback slice.
        XCTAssertEqual(section.string.string, paginator.sourceText.string)
        let shown = paginator.text(for: page)
        XCTAssertTrue((shown.attribute(.readerHeading, at: 0, effectiveRange: nil) as? ReaderHeading) === (section.string.attribute(.readerHeading, at: 0, effectiveRange: nil) as? ReaderHeading))
        XCTAssertEqual((shown.attribute(.readerHeading, at: 0, effectiveRange: nil) as? ReaderHeading)?.level, 2)
        XCTAssertEqual(section.anchors["oversized"], 0)
    }

    func testExtremeBaselineShiftsRemainReachableInFallback() throws {
        for shift in [-1200, 1200] {
            let section = try H.build("<h2 id='shifted'>Shifted heading words.</h2><p>Following words.</p>", css: H.reset)
            let text = NSMutableAttributedString(attributedString: section.string)
            let heading = (text.string as NSString).range(of: "Shifted heading words.")
            text.addAttribute(.baselineOffset, value: shift, range: heading)
            let size = CGSize(width: 180, height: 240)
            let paginator = ReaderPaginator(text: text, size: size)
            var covered = IndexSet()
            for page in paginator.allPages {
                let view = H.pageView(paginator, page: page)
                for line in Self.rawLines(in: view, intersecting: view.shownCharacters) {
                    XCTAssertGreaterThanOrEqual(line.frame.minY, -0.5)
                    XCTAssertLessThanOrEqual(line.frame.maxY, size.height - page.topSpacing + 0.5)
                    covered.insert(integersIn: (line.range.location + page.range.location)..<(line.range.upperBound + page.range.location))
                }
            }
            XCTAssertEqual(covered, IndexSet(integersIn: 0..<text.length))
            XCTAssertEqual(paginator.sourceText.string, text.string)
            XCTAssertEqual(section.anchors["shifted"], 0)
        }
    }

    func testNegativeSignedFragmentUsesGlyphOriginsForReaderQueries() throws {
        let prefix = Array(repeating: "Earlier ordinary text around a callout.", count: 9).joined(separator: " ")
        let section = try H.build("<p>\(prefix)</p><aside><p>Opening callout.</p><p><a href='https://example.org/callout'>Later linked callout words.</a></p></aside><p>Following prose. \(H.prose)</p>",
            css: H.reset + "aside { position:absolute; right:0; top:400px; width:100px }")
        let size = CGSize(width: 400, height: 600)
        let view = H.view(section.string, size: size)
        let target = H.range("Later linked callout words.", in: section)
        var hasNegativeFrame = false
        view.readerLayoutManager.enumerateTextLayoutFragments(from: view.contentStorage.documentRange.location, options: [.ensuresLayout]) { fragment in
            let start = view.offset(of: fragment.rangeInElement.location)
            if NSLocationInRange(target.location, NSRange(location: start, length: view.offset(of: fragment.rangeInElement.endLocation) - start)) {
                hasNegativeFrame = fragment.layoutFragmentFrame.size.height < 0
            }
            return true
        }
        XCTAssertTrue(hasNegativeFrame, "the fixture must exercise a signed flow frame")
        let raw = Self.rawLines(in: view, intersecting: target)
        XCTAssertFalse(raw.isEmpty)
        for line in raw {
            let actual = try XCTUnwrap(view.line(containing: line.range.location))
            XCTAssertEqual(actual.range, line.range)
            XCTAssertEqual(actual.frame.minY, line.frame.minY, accuracy: 0.5)
            XCTAssertEqual(actual.frame.height, line.frame.height, accuracy: 0.5)
        }
        let first = try XCTUnwrap(raw.first)
        let hitPoint = CGPoint(x: view.containerOrigin.x + first.frame.minX + 2, y: view.containerOrigin.y + first.frame.midY)
        let hit = view.characterOffset(at: hitPoint)
        XCTAssertTrue(NSLocationInRange(hit, first.range))
        XCTAssertEqual(view.link(at: hitPoint), section.string.attribute(.link, at: target.location, effectiveRange: nil) as? URL)
        let clip = first.frame.insetBy(dx: -0.1, dy: -0.1)
        let all = Self.rawLines(in: view, intersecting: NSRange(location: 0, length: section.string.length))
        let visible = all.filter { !$0.frame.intersection(clip).isEmpty }.map(\.range)
        let lower = try XCTUnwrap(visible.map(\.location).min()), upper = try XCTUnwrap(visible.map(\.upperBound).max())
        XCTAssertEqual(view.visibleCharacterRange(in: clip), NSRange(location: lower, length: upper - lower))
        XCTAssertLessThanOrEqual(view.lineBoundary(atContainerY: first.frame.minY, lineEnd: false), target.location)
        XCTAssertGreaterThanOrEqual(view.lineBoundary(atContainerY: first.frame.maxY, lineEnd: true), first.range.upperBound)
        // Reader positions and bookmarks consume these same source offsets. Geometry repair
        // leaves the DOM anchor and source characters available to CFI mapping.
        XCTAssertEqual(section.string.attributedSubstring(from: target).string, "Later linked callout words.")
        let start = try XCTUnwrap(section.map.position(at: hit, in: section.document))
        let path = EPUBCFI.localPath(from: start, to: start, in: section.document)
        let restored = try XCTUnwrap(EPUBCFI.resolve(localPath: path, in: section.document))
        XCTAssertEqual(section.map.location(of: restored.start), hit)
    }

    func testForcedBreakHeadingMarginBeforeFloat() throws {
        let words = (0..<700).map { "w\($0)" }.joined(separator: " ")
        for margin in [0, 40] {
            let section = try H.build("<p>Lead words.</p><h2 class='b'>Heading words</h2><figure>Boxed words.</figure><p>After the box. \(words)</p>",
                css: H.reset + ".b { break-before:page; margin-top:\(margin)px } figure { float:left; width:100px; height:200px }", fontSize: 16)
            assertPages(section, size: CGSize(width: 400, height: 600), label: "heading margin \(margin)")
        }
    }

    func testForcedSpacingKeepsTheSettledFixedBoxAtItsAuthoredFloor() throws {
        let section = try H.build(#"<aside class='k1'>Placed T1 words.</aside><aside class='k2'>Placed T2 words.</aside><p class='k3'>T3. She counted the steps twice; forty-one each time, which settled nothing at all.</p><p class='k4'>T4. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Ordinary prose wraps beside the box and returns to the full column below it. Short one. Short one. No. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. No. No. Short one. Ordinary prose wraps beside the box and returns to the full column below it. Short one. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. No.</p><ul><li>Item T5. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</li><li>Item T6. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</li><li>Item T7. Ordinary prose wraps beside the box and returns to the full column below it.</li></ul><aside class='k5'>Placed T8 words.</aside><div class='k6'><p>Relative T9. No.</p></div><p class='k7'>T10.</p><blockquote class='k8'><p>Quoted T11. She counted the steps twice; forty-one each time, which settled nothing at all.</p></blockquote><p class='k9'>T12. She counted the steps twice; forty-one each time, which settled nothing at all. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. She counted the steps twice; forty-one each time, which settled nothing at all. She counted the steps twice; forty-one each time, which settled nothing at all. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. No. Words of several lengths, unremarkable and plain, fill another row or two of the column. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Short one.</p><table><tr><td>Row 1 T13</td><td>Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences.</td></tr><tr><td>Row 2 T13</td><td>two</td></tr><tr><td>Row 3 T13</td><td>Ordinary prose wraps beside the box and returns to the full column below it.</td></tr><tr><td>Row 4 T13</td><td>No.</td><td>3</td></tr><tr><td>Row 5 T13</td><td>two</td><td>3</td></tr></table><p class='k10'>T14. Short one. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in.</p>"#, css: H.reset + #".k1 { position:absolute; width:45%; left:0; top:150.5px; height:50px;  } .k2 { position:absolute; width:100%; right:0; bottom:10px;  } .k3 { break-after:page; text-align:center;  } .k4 { clear:left; margin-top:5.5px; break-before:page; break-after:page;  } .k5 { position:fixed; width:62.5%; right:0; bottom:0; height:50px;  } .k6 { position:relative; top:1.3em;  } .k7 { margin-bottom:440.25px } .k8 { margin:8.0px 10.333333333333334px;  } .k9 { margin-left:7%; break-before:page; text-align:justify;  } .k10 { break-before:page; line-height:0.9; font-size:0.83em;  } "#, fontSize: 16)
        let size = CGSize(width: 390, height: 700)
        let (paginator, pages) = H.pages(section, size: size)
        let fixed = H.range("Placed T8 words.", in: section)
        let page = try XCTUnwrap(pages.first { NSIntersectionRange($0.range, fixed).length > 0 })
        let view = H.pageView(paginator, page: page)
        let local = NSRange(location: fixed.location - page.range.location, length: fixed.length)
        let displayed = try XCTUnwrap(Self.rawLines(in: view, intersecting: local).first)
        XCTAssertEqual(displayed.frame.minY + page.layoutTop - page.layoutSpacing, 690, accuracy: 0.5,
            "The fixed box settles below the full-width absolute box ending at700-10, without retaining the earlier5.5pt page margin")
        assertPages(section, size: size, label: "g12#457 settled fixed box")
    }

    func testDelayedTableProposalUsesTheFullColumnAtItsDrawnHeight() throws {
        let section = try H.build(#"<aside class='k1'><p>Placed T1 top.</p><p>Placed T1 end words.</p></aside><aside class='k2'>Placed T2 words.</aside><p class='k3'>T3. She counted the steps twice; forty-one each time, which settled nothing at all.</p><p class='k4'>T4. Ordinary prose wraps beside the box and returns to the full column below it.</p><aside class='k5'>Placed T5 words.</aside><table><tr><td>Row 1 T6</td><td>two</td></tr><tr><td>Row 2 T6</td><td>Ordinary prose wraps beside the box and returns to the full column below it.</td><td>3</td></tr><tr><td>Row 3 T6</td><td>two</td><td>3</td></tr></table><aside class='k6'>Placed T7 words.</aside><blockquote class='k7'><p>Quoted T8. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</p></blockquote><p class='k8'>T9. Short one. She counted the steps twice; forty-one each time, which settled nothing at all. Words of several lengths, unremarkable and plain, fill another row or two of the column.</p><p class='k9'>T10.</p><figure class='k10'>Float T11.</figure><p class='k11'>T12. She counted the steps twice; forty-one each time, which settled nothing at all. She counted the steps twice; forty-one each time, which settled nothing at all. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Ordinary prose wraps beside the box and returns to the full column below it. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Words of several lengths, unremarkable and plain, fill another row or two of the column. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. She counted the steps twice; forty-one each time, which settled nothing at all. Words of several lengths, unremarkable and plain, fill another row or two of the column. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences.</p><p class='k12' dir='rtl'>T13. النص العربي يستمر هنا بكلمات أخرى مختلفة الطول حتى ينتهي السطر ويبدأ سطر جديد. עוד משפט, הפעם עם מספרים 123 ומילים באנגלית like these בתוכו. النص العربي يستمر هنا بكلمات أخرى مختلفة الطول حتى ينتهي السطر ويبدأ سطر جديد. משפט קצר. זהו משפט רגיל בעברית שעוטף ליד התיבה וחוזר לטור המלא מתחתיה. עוד משפט, הפעם עם מספרים 123 ומילים באנגלית like these בתוכו. النص العربي يستمر هنا بكلمات أخرى مختلفة الطول حتى ينتهي السطر ويبدأ سطر جديد. זהו משפט רגיל בעברית שעוטף ליד התיבה וחוזר לטור המלא מתחתיה. هذه جملة عربية عادية تلتف بجانب المربع ثم تعود إلى العمود الكامل تحته. זהו משפט רגיל בעברית שעוטף ליד התיבה וחוזר לטור המלא מתחתיה. זהו משפט רגיל בעברית שעוטף ליד התיבה וחוזר לטור המלא מתחתיה. זהו משפט רגיל בעברית שעוטף ליד התיבה וחוזר לטור המלא מתחתיה. זהו משפט רגיל בעברית שעוטף ליד התיבה וחוזר לטור המלא מתחתיה. משפט קצר. משפט קצר. משפט קצר. עוד משפט, הפעם עם מספרים 123 ומילים באנגלית like these בתוכו. זהו משפט רגיל בעברית שעוטף ליד התיבה וחוזר לטור המלא מתחתיה. עוד משפט, הפעם עם מספרים 123 ומילים באנגלית like these בתוכו. النص العربي يستمر هنا بكلمات أخرى مختلفة الطول حتى ينتهي السطر ويبدأ سطر جديد.</p><figure class='k13'>Float T14.</figure><figure class='k14' dir='rtl'>T15 النص العربي يستمر هنا بكلمات أخرى مختلفة الطول حتى ينتهي السطر ويبدأ سطر جديد.</figure><figure class='k15'><p>Top T16.</p><p>Middle T16 words wrap here.</p><p>Bottom T16.</p></figure><p><span class='k16'>D</span>rop T17. Ordinary prose wraps beside the box and returns to the full column below it. She counted the steps twice; forty-one each time, which settled nothing at all. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. She counted the steps twice; forty-one each time, which settled nothing at all.</p><aside class='k17'><h3>Side T18</h3><p>A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up.</p></aside><p class='k18'>T19. Ordinary prose wraps beside the box and returns to the full column below it. Words of several lengths, unremarkable and plain, fill another row or two of the column. Short one. Words of several lengths, unremarkable and plain, fill another row or two of the column. Short one. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</p>"#, css: H.reset + #".k1 { position:absolute; width:30%; right:7.5px; bottom:31.1px; padding:3px;  } .k2 { position:absolute; width:62.5%; padding:3px;  } .k3 { text-indent:-1em; padding-left:1em; text-align:justify;  } .k4 { margin-left:7%;  } .k5 { position:fixed; width:62.5%; right:0; top:40px; height:50px;  } .k6 { position:fixed; width:30%; left:12%; top:9.0px; height:50px;  } .k7 { margin:4.4px 16.5px;  } .k8 { clear:left; text-indent:1.5em;  } .k9 { margin-bottom:63.0px } .k10 { float:left; width:6.5em; height:120.5px; margin:0.7em 0; padding:0.33em 0; text-align:center;  } .k11 { margin-top:-8px;  } .k12 { margin-left:7%;  } .k13 { float:right; min-width:55px; width:10%; height:107.0px; line-height:1.1;  } .k14 { float:right; width:72%; height:6.666666666666667em; margin:12.0px 0.14285714285714285px; border:1px solid #333; text-align:center;  } .k15 { float:left; width:6.5em; height:3.3em; margin:3.0px 1.25px; border:2.5px solid #333; padding:3px;  } .k16 { float:left; font-size:3em;  } .k17 { float:left; width:72%; min-height:41.3px; margin:12.0px 8.714285714285714px; padding:4px; clear:both; break-before:page;  } .k18 { clear:right; margin:1em 0;  } "#, fontSize: 14.5)
        let size = CGSize(width: 1024, height: 700.25)
        let (paginator, pages) = H.pages(section, size: size)
        var secondRow: Int?
        section.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: section.string.length)) { value, range, _ in
            if secondRow == nil, let row = value as? TableRowAttachment, row.row == 1 { secondRow = range.location }
        }
        let sourceOffset = try XCTUnwrap(secondRow)
        let page = try XCTUnwrap(pages.first { NSLocationInRange(sourceOffset, $0.range) })
        let view = H.pageView(paginator, page: page)
        let local = NSRange(location: sourceOffset - page.range.location, length: 1)
        let row = try XCTUnwrap(Self.rawLines(in: view, intersecting: local).first)
        #if os(iOS)
        // Frozen UIKit main places this row inside the first page. Its different native
        // metrics do not exercise the delayed first-fragment proposal from macOS.
        XCTAssertEqual(page.range.location, 0)
        XCTAssertGreaterThan(local.location, 0)
        XCTAssertEqual(row.frame.minY, 155.8, accuracy: 0.5)
        #else
        XCTAssertEqual(page.range.location, sourceOffset, "The delayed row opens the displayed page")
        XCTAssertEqual(Self.rawLines(in: view, intersecting: view.shownCharacters).first?.range.location, local.location)
        XCTAssertEqual(row.frame.minY, 603.15, accuracy: 0.5)
        #endif
        XCTAssertEqual(row.frame.width, 1024, accuracy: 0.5,
            "The table uses the full column at its actual drawn height")
        assertPages(section, size: size, label: "g12#411 full-width table proposal")
    }

    func testForcedParagraphSpacingAdvancesTheFlowBeforeAFixedBox() throws {
        for margin: CGFloat in [5.5, 12, 27.0165] {
            var starts: [CGFloat] = []
            for spacing in [CGFloat(0), margin] {
                let section = try H.build("<p>Lead words.</p><p class='break'>Forced paragraph words.</p><aside>Fixed box words.</aside><p>After words.</p>",
                    css: H.reset + ".break { break-before:page; margin-top:\(spacing)px } aside { position:fixed; top:0; right:0; width:100px }")
                let view = H.view(section.string, size: CGSize(width: 400, height: 600))
                let geometry = try XCTUnwrap(view.readerContainer.boxPage?.geometry)
                let fixed = H.range("Fixed box words.", in: section)
                starts.append(try XCTUnwrap(geometry.paragraph(at: fixed.location)).flowStart)
                assertPages(section, size: CGSize(width: 400, height: 600), label: "forced spacing \(spacing)")
            }
            XCTAssertEqual(starts[1] - starts[0], margin, accuracy: 0.5,
                "The following out-of-flow box takes back an advance that includes the retained forced margin")
        }
    }

    func testPositionedBoxBeforeTablePreservesRows() throws {
        let rows = (1...14).map { "<tr><td>Row \($0) one</td><td>two</td></tr>" }.joined()
        let section = try H.build("<aside class='a'>Absolute words.</aside><table>\(rows)</table><p>After the table. \(H.prose)</p><figure class='z'>Later float.</figure><p>End words. \(H.prose)</p>",
            css: H.reset + ".a { position:absolute; width:100%; top:12%; height:50px } .z { float:left; width:60px; height:40px }", fontSize: 17)
        assertPages(section, size: CGSize(width: 300, height: 420), label: "positioned table")
    }

    func testNamedGeometryRegressionsFromIssue242() throws {
        let fixtures: [(name: String, body: String, css: String, size: CGSize, font: CGFloat)] = [
            ("g12#2221, page 0", #"<img class='k1' src='i120x150.png' alt='Picture T1'/><img class='k2' src='i40x30.png' alt='Picture T2'/><figure class='k3'>Float T3.</figure><blockquote class='k4'><p>Quoted T4. Words of several lengths, unremarkable and plain, fill another row or two of the column.</p></blockquote><p class='k5'>T5. No. No. She counted the steps twice; forty-one each time, which settled nothing at all. No. Words of several lengths, unremarkable and plain, fill another row or two of the column. No.</p><aside class='k6'>Placed T6 words.</aside><p class='k7'>T7 before a break.</p><figure class='k8'><p>Top T8.</p><p>Middle T8 words wrap here.</p><p>Bottom T8.</p></figure><table><tr><td>Row 1 T9</td><td>two</td></tr><tr><td>Row 2 T9</td><td>two</td></tr></table><p class='k9'>T10. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Short one. Short one.</p><p class='k10'>T11. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Short one. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Ordinary prose wraps beside the box and returns to the full column below it. No. Words of several lengths, unremarkable and plain, fill another row or two of the column. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. She counted the steps twice; forty-one each time, which settled nothing at all. Ordinary prose wraps beside the box and returns to the full column below it. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</p><figure class='k11'>Float T12 with rather more words in it than fit on a line.</figure><figure class='k12'>Float T13.</figure><blockquote class='k13'><p>Quoted T14. Ordinary prose wraps beside the box and returns to the full column below it. Ordinary prose wraps beside the box and returns to the full column below it. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</p></blockquote><div class='k14'><p>Relative T15. No. She counted the steps twice; forty-one each time, which settled nothing at all.</p></div><figure class='k15'>Float T16.</figure><p class='k16'>T17. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Words of several lengths, unremarkable and plain, fill another row or two of the column.</p>"#, #"html, body { margin: 0; padding: 0 } p, div, figure, figcaption, aside, section, blockquote, ul, ol, li, h1, h2, h3, main, footer, header { margin: 0; padding: 0; text-indent: 0 } .k1 { float:right; width:25%; min-height:41.3px;  } .k2 { float:right; width:33.333%; padding:6.0px;  } .k3 { float:left; width:42.142857142857146px; height:3.3em; margin-top:-6px; padding:7.857142857142857px;  } .k4 { margin:5.857142857142857px 9.666666666666666px;  } .k5 { margin-bottom:12px; text-align:justify;  } .k6 { position:absolute; width:100%; right:0; top:0.25px;  } .k7 { break-after:page;  } .k8 { float:right; width:100%; height:2.6em; margin:-3.3px 0 11.1px 0; line-height:1.1;  } .k9 { clear:right;  } .k10 { text-indent:1.5em; line-height:1.7; font-size:13.3px;  } .k11 { float:left; min-width:55px; width:10%; height:120.5px; margin-bottom:0.6666666666666666em; padding:0.33em 0; font-size:0.8em;  } .k12 { float:left; width:100%; height:132.66666666666666px; margin-bottom:9.5px; padding:0.33em 0;  } .k13 { margin:10.428571428571429px 4.666666666666667px;  } .k14 { position:relative; top:12px;  } .k15 { float:left; width:2.5em; height:40%; padding:1.6666666666666667px; break-before:page;  } .k16 { clear:both; text-indent:1.5em; line-height:22.4px;  } "#, CGSize(width: 361.33, height: 617.5), 25.0),
            ("g22#366, page 4", #"<figure class='k1'>Float T1.</figure><figure class='k2'>Float T2.</figure><aside class='k3'>Placed T3 words.</aside><figure class='k4'>Float T4.</figure><p class='k5'>T5. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up.</p><figure class='k6'>Float T6.</figure><p class='k7'>T7. Words of several lengths, unremarkable and plain, fill another row or two of the column.</p><p class='k8'>T8. Words of several lengths, unremarkable and plain, fill another row or two of the column. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Short one. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Words of several lengths, unremarkable and plain, fill another row or two of the column. Short one. Short one. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. No. She counted the steps twice; forty-one each time, which settled nothing at all. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in.</p><p class='k9'>T9. She counted the steps twice; forty-one each time, which settled nothing at all. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. She counted the steps twice; forty-one each time, which settled nothing at all. No. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. She counted the steps twice; forty-one each time, which settled nothing at all. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up.</p><p class='k10'>T10 before a break.</p><p><span class='k11'>D</span>rop T11. No. She counted the steps twice; forty-one each time, which settled nothing at all. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Short one.</p><table class='k12'><tr><td>Row 1 T12</td><td>two</td></tr><tr><td>Row 2 T12</td><td>Short one.</td><td>3</td></tr><tr><td>Row 3 T12</td><td>two</td></tr><tr><td>Row 4 T12</td><td>two</td><td>3</td></tr><tr><td>Row 5 T12</td><td>two</td></tr></table><div class='k16'><aside class='k13'><p>Placed T13 top.</p><p>Placed T13 end words.</p></aside><figure class='k14'><p>Top T14.</p><p>Bottom T14 words.</p></figure><p class='k15'>T15. Short one. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. She counted the steps twice; forty-one each time, which settled nothing at all. She counted the steps twice; forty-one each time, which settled nothing at all.</p></div><p class='k17' dir='rtl'>T16. النص العربي يستمر هنا بكلمات أخرى مختلفة الطول حتى ينتهي السطر ويبدأ سطر جديد. هذه جملة عربية عادية تلتف بجانب المربع ثم تعود إلى العمود الكامل تحته. עוד משפט, הפעם עם מספרים 123 ומילים באנגלית like these בתוכו.</p>"#, #".k1 { float:left; width:60px; height:4.333333333333333em; margin-top:-6px; border:2.5px solid #333; padding:3px;  } .k2 { float:left; width:128.9px; height:40%; margin:-3.3px 0 11.1px 0; padding:0.33em 0; clear:both; font-size:1.37em;  } .k3 { position:absolute; width:8em; left:12%; top:1.7em; padding:3px;  } .k4 { float:right; min-width:55px; width:10%; height:75px; margin-bottom:1.6666666666666667em; font-size:1.37em;  } .k5 {  } .k6 { float:right; width:40px; margin:8.9px 8.5px; padding:0.33em 0; clear:both; line-height:1.1;  } .k7 { clear:left; text-indent:1.5em; break-after:page;  } .k8 { clear:right; text-indent:1.5em;  } .k9 { text-indent:-1em; padding-left:1em; text-align:justify;  } .k10 { break-after:page;  } .k11 { float:left; font-size:3em; margin:-0.1em 0.08em 0 0;  } .k12 { width:100%;  } .k13 { position:absolute; width:62.5%; left:12%; top:1.7em; height:50px;  } .k14 { float:left; width:33.333%; min-height:41.3px; padding:7.5px; font-size:1.37em;  } .k15 { clear:both;  } .k16 { position:relative; bottom:6px;  } .k17 { margin:1em 0;  } "#, CGSize(width: 512.0, height: 342.5), 12.0),
            ("g11#465, page 0", #"<aside class='k1'>Placed T1 words.</aside><figure class='k2' dir='rtl'>T2 هذه جملة عربية عادية تلتف بجانب المربع ثم تعود إلى العمود الكامل تحته.</figure><table><tr><td>Row 1 T3</td><td>two</td></tr><tr><td>Row 2 T3</td><td>two</td></tr><tr><td>Row 3 T3</td><td>A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up.</td><td>3</td></tr><tr><td>Row 4 T3</td><td>two</td><td>3</td></tr><tr><td>Row 5 T3</td><td>Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences.</td></tr><tr><td>Row 6 T3</td><td>two</td></tr><tr><td>Row 7 T3</td><td>two</td><td>3</td></tr><tr><td>Row 8 T3</td><td>Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences.</td></tr><tr><td>Row 9 T3</td><td>two</td><td>3</td></tr><tr><td>Row 10 T3</td><td>two</td></tr><tr><td>Row 11 T3</td><td>two</td></tr><tr><td>Row 12 T3</td><td>two</td></tr><tr><td>Row 13 T3</td><td>two</td></tr><tr><td>Row 14 T3</td><td>two</td><td>3</td></tr></table><ul><li>Item T4. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up.</li><li>Item T5. No.</li><li>Item T6. No.</li></ul><div class='k7'><div class='k5'><figure class='k3'>Float T7.</figure><p class='k4' dir='rtl'>T8. משפט קצר. זהו משפט רגיל בעברית שעוטף ליד התיבה וחוזר לטור המלא מתחתיה. هذه جملة عربية عادية تلتف بجانب المربع ثم تعود إلى العمود الكامل تحته. النص العربي يستمر هنا بكلمات أخرى مختلفة الطول حتى ينتهي السطر ويبدأ سطر جديد. النص العربي يستمر هنا بكلمات أخرى مختلفة الطول حتى ينتهي السطر ويبدأ سطر جديد. هذه جملة عربية عادية تلتف بجانب المربع ثم تعود إلى العمود الكامل تحته. משפט קצר.</p></div><p class='k6'>T9. Ordinary prose wraps beside the box and returns to the full column below it. Words of several lengths, unremarkable and plain, fill another row or two of the column. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Short one. Words of several lengths, unremarkable and plain, fill another row or two of the column. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Words of several lengths, unremarkable and plain, fill another row or two of the column. Short one. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in.</p></div><p class='k8'>T10.</p><figure class='k9'>Float T11.</figure><p class='k10'>T12. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Words of several lengths, unremarkable and plain, fill another row or two of the column. She counted the steps twice; forty-one each time, which settled nothing at all. No. Short one. Short one. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Short one. Ordinary prose wraps beside the box and returns to the full column below it. Ordinary prose wraps beside the box and returns to the full column below it. Words of several lengths, unremarkable and plain, fill another row or two of the column. Words of several lengths, unremarkable and plain, fill another row or two of the column.</p><h1>Heading T13</h1><figure class='k11'>Float T14.</figure><blockquote class='k12'><p>Quoted T15. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Ordinary prose wraps beside the box and returns to the full column below it.</p></blockquote><blockquote class='k13'><p>Quoted T16. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in.</p></blockquote><figure class='k14'>Float T17 with rather more words in it than fit on a line.</figure><p class='k15'>T18. Ordinary prose wraps beside the box and returns to the full column below it.</p><figure class='k16'>Float T19.</figure><p class='k17'>T20. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up.</p><blockquote class='k18'><p>Quoted T21. Short one. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</p></blockquote><p class='k19'>T22.</p><p class='k20'>T23. No.</p><p class='k21'>T24. She counted the steps twice; forty-one each time, which settled nothing at all. Short one. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Short one. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Short one. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Ordinary prose wraps beside the box and returns to the full column below it. Short one.</p>"#, #"html, body { margin: 0; padding: 0 } p, div, figure, figcaption, aside, section, blockquote, ul, ol, li, h1, h2, h3, main, footer, header { margin: 0; padding: 0; text-indent: 0 } .k1 { position:absolute; width:100%; right:0; top:12%; height:80.66666666666667px;  } .k2 { float:left; width:40px; margin-bottom:0.14285714285714285em; padding:0.33em 0;  } .k3 { float:left; width:7.333333333333333em; min-height:41.3px; margin-top:7px; clear:right;  } .k4 { clear:right; margin:1em 0;  } .k5 { position:relative; top:12px;  } .k6 { clear:left;  } .k7 { position:relative; left:-2%;  } .k8 { margin-bottom:263.0px } .k9 { float:left; width:60px; min-height:41.3px; margin:-3.3px 0 11.1px 0; padding:4px;  } .k10 { clear:both; margin:8.0px 0 10.714285714285714px 0; break-after:page;  } .k11 { float:right; max-width:45%; height:75px; margin:-3.3px 0 11.1px 0; padding:6.285714285714286px; clear:left;  } .k12 { margin:2.8px 28.857142857142858px;  } .k13 { margin:1.0px 21.0px;  } .k14 { float:left; max-width:45%; height:75px; margin-left:-5px; padding:4.333333333333333px; clear:right; line-height:1.1;  } .k15 { text-indent:-1em; padding-left:1em; line-height:0.9;  } .k16 { float:right; width:7.0em; height:103.7px; margin-bottom:1.3em; font-size:0.8em;  } .k17 { clear:right; margin:1em 0;  } .k18 { margin:8.25px 25.9px;  } .k19 { margin-bottom:438.0px } .k20 { margin-top:30px;  } .k21 {  } "#, CGSize(width: 400.0, height: 600.0), 12.0),
            ("g13#2207, page 0", #"<figure class='k1' dir='rtl'>T1 هذه جملة عربية عادية تلتف بجانب المربع ثم تعود إلى العمود الكامل تحته.</figure><aside class='k2'>Placed T2 words.</aside><table><tr><td>Row 1 T3</td><td>two</td></tr><tr><td>Row 2 T3</td><td>two</td><td>3</td></tr><tr><td>Row 3 T3</td><td>Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</td></tr><tr><td>Row 4 T3</td><td>two</td></tr><tr><td>Row 5 T3</td><td>two</td></tr><tr><td>Row 6 T3</td><td>Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</td><td>3</td></tr><tr><td>Row 7 T3</td><td>two</td></tr><tr><td>Row 8 T3</td><td>The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in.</td></tr><tr><td>Row 9 T3</td><td>Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</td><td>3</td></tr></table><figure class='k3'>Float T4.</figure><figure class='k4'>Float T5 with rather more words in it than fit on a line.</figure><p class='k5'>T6.</p><ul><li>Item T7. She counted the steps twice; forty-one each time, which settled nothing at all.</li><li>Item T8. No.</li></ul><p class='k6'>T9. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Words of several lengths, unremarkable and plain, fill another row or two of the column. Short one. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. She counted the steps twice; forty-one each time, which settled nothing at all. Ordinary prose wraps beside the box and returns to the full column below it. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. She counted the steps twice; forty-one each time, which settled nothing at all. Short one. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Short one. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Short one. She counted the steps twice; forty-one each time, which settled nothing at all. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in.</p><p class='k7'>T10. Short one. Short one. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Short one.</p><p class='k8'>T11. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. No. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Ordinary prose wraps beside the box and returns to the full column below it. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. She counted the steps twice; forty-one each time, which settled nothing at all.</p>"#, #"html, body { margin: 0; padding: 0 } p, div, figure, figcaption, aside, section, blockquote, ul, ol, li, h1, h2, h3, main, footer, header { margin: 0; padding: 0; text-indent: 0 } .k1 { float:left; width:72%; height:5.0em; margin:0.7em 0; font-size:1.37em;  } .k2 { position:absolute; width:30%; top:40px; margin-top:5px;  } .k3 { float:right; max-width:45%; border:1px solid #333; clear:left; line-height:1.1;  } .k4 { float:right; width:7.9em; min-height:41.3px; margin-left:-5px; padding:0.33em 0; clear:both;  } .k5 { margin-bottom:329.3333333333333px } .k6 { margin:8.7px 0 18.666666666666668px 0; line-height:0.9;  } .k7 { text-indent:-1em; padding-left:1em;  } .k8 { clear:both; margin:15.25px 0 17.1px 0;  } "#, CGSize(width: 720.0, height: 980.0), 42.0),
            ("g11#821, page 3", #"<p class='k1'>T1. She counted the steps twice; forty-one each time, which settled nothing at all. Short one. Short one. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. She counted the steps twice; forty-one each time, which settled nothing at all. No. Short one. Ordinary prose wraps beside the box and returns to the full column below it. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. She counted the steps twice; forty-one each time, which settled nothing at all. Ordinary prose wraps beside the box and returns to the full column below it. Ordinary prose wraps beside the box and returns to the full column below it. Ordinary prose wraps beside the box and returns to the full column below it. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</p><aside class='k2'><p>Placed T2 top.</p><p>Placed T2 end words.</p></aside><p class='k3'>T3.</p><figure class='k4'><p>Top T4.</p><p>Bottom T4 words.</p></figure><p class='k5'>T5. No. Short one. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Short one. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Short one. Words of several lengths, unremarkable and plain, fill another row or two of the column. Words of several lengths, unremarkable and plain, fill another row or two of the column.</p><aside class='k6'><h3>Side T6</h3><p>No.</p></aside><figure class='k7'>Float T7 with rather more words in it than fit on a line.</figure><figure class='k8'><p>Top T8.</p><p>Middle T8 words wrap here.</p><p>Bottom T8.</p></figure><figure class='k9'><p>Top T9.</p><p>Bottom T9 words.</p></figure><p><span class='k10'>D</span>rop T10. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. Words of several lengths, unremarkable and plain, fill another row or two of the column. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Words of several lengths, unremarkable and plain, fill another row or two of the column. Ordinary prose wraps beside the box and returns to the full column below it. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in.</p><p>Before T11 <span class='k11'>Sized inline box.</span> after. Words of several lengths, unremarkable and plain, fill another row or two of the column. Ordinary prose wraps beside the box and returns to the full column below it. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Ordinary prose wraps beside the box and returns to the full column below it.</p><p class='k12'>T12.</p><figure class='k13' dir='rtl'>T13 النص العربي يستمر هنا بكلمات أخرى مختلفة الطول حتى ينتهي السطر ويبدأ سطر جديد.</figure><p class='k14'>T14. No. Words of several lengths, unremarkable and plain, fill another row or two of the column. Ordinary prose wraps beside the box and returns to the full column below it. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Short one. No. Short one. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</p><p class='k15'>T15. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences.</p><p class='k16'>T16. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Ordinary prose wraps beside the box and returns to the full column below it. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Ordinary prose wraps beside the box and returns to the full column below it. Short one.</p>"#, #".k1 { clear:left; margin:15.0px 0 2.1px 0; break-before:page; text-align:justify;  } .k2 { position:fixed; width:100px; left:12%; top:0; padding:3px;  } .k3 { margin-bottom:301.85714285714283px } .k4 { float:right; width:33.333%; margin:0.7em 0; clear:both;  } .k5 { margin-left:7%;  } .k6 { float:left; max-width:45%; height:30px; padding:4px;  } .k7 { float:left; max-width:45%; height:114.66666666666667px; margin-top:-0.45em; border:2.5px solid #333; padding:3px; font-size:0.8em;  } .k8 { float:left; width:25%; height:30px; margin-bottom:-4px; padding:8.0px;  } .k9 { float:right; width:7.666666666666667em; height:75px; padding:4px; break-before:page;  } .k10 { float:left; font-size:2em; margin:-0.1em 0.08em 0 0;  } .k11 { display:inline-block; width:50%; height:55.3px;  } .k12 { margin-bottom:2.4285714285714284px } .k13 { float:left; width:50%; height:40%; margin-bottom:-4px;  } .k14 { clear:right; margin-top:30px; line-height:1.15;  } .k15 { margin:1em 0; break-before:page; text-align:justify; line-height:1.15;  } .k16 { margin-top:30px; font-size:0.83em;  } "#, CGSize(width: 400.0, height: 600.0), 19.3),
            ("g14#1544, page 1", #"<p class='k1'>T1.</p><aside class='k2'>Placed T2 words.</aside><p><span class='k3'>D</span>rop T3. Words of several lengths, unremarkable and plain, fill another row or two of the column. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</p><p class='k4'>T4.</p><p><span class='k5'>D</span>rop T5. Short one. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. She counted the steps twice; forty-one each time, which settled nothing at all. No. Short one.</p><p class='k6' dir='rtl'>T6. עוד משפט, הפעם עם מספרים 123 ומילים באנגלית like these בתוכו. هذه جملة عربية عادية تلتف بجانب المربع ثم تعود إلى العمود الكامل تحته. זהו משפט רגיל בעברית שעוטף ליד התיבה וחוזר לטור המלא מתחתיה. זהו משפט רגיל בעברית שעוטף ליד התיבה וחוזר לטור המלא מתחתיה. هذه جملة عربية عادية تلتف بجانب المربع ثم تعود إلى العمود الكامل تحته. עוד משפט, הפעם עם מספרים 123 ומילים באנגלית like these בתוכו. هذه جملة عربية عادية تلتف بجانب المربع ثم تعود إلى العمود الكامل تحته. النص العربي يستمر هنا بكلمات أخرى مختلفة الطول حتى ينتهي السطر ويبدأ سطر جديد. עוד משפט, הפעם עם מספרים 123 ומילים באנגלית like these בתוכו.</p>"#, #"html, body { margin: 0; padding: 0 } p, div, figure, figcaption, aside, section, blockquote, ul, ol, li, h1, h2, h3, main, footer, header { margin: 0; padding: 0; text-indent: 0 } .k1 { margin-bottom:451.6666666666667px } .k2 { position:absolute; width:163.57142857142858px; right:7.5px; bottom:10px;  } .k3 { float:left; font-size:2.75em;  } .k4 { margin-bottom:217.85714285714286px } .k5 { float:left; font-size:2.4em; height:1.6em;  } .k6 { clear:both; margin:1em 0;  } "#, CGSize(width: 320.0, height: 480.0), 21.7),
            ("g22#932, page 2", #"<p class='k1'>T1.</p><blockquote class='k2'><p>Quoted T2. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. She counted the steps twice; forty-one each time, which settled nothing at all.</p></blockquote><p class='k3'>T3. She counted the steps twice; forty-one each time, which settled nothing at all. Short one. Ordinary prose wraps beside the box and returns to the full column below it. Ordinary prose wraps beside the box and returns to the full column below it. No.</p><p class='k4'>T4.</p><figure class='k5'>Float T5.</figure><figure class='k6'>Float T6 with rather more words in it than fit on a line.</figure><aside class='k7'><h3>Side T7</h3><p>No.</p></aside><p class='k8'>T8.</p><p><span class='k9'>D</span>rop T9. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. She counted the steps twice; forty-one each time, which settled nothing at all. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences.</p><figure class='k10'><p>Top T10.</p><p>Middle T10 words wrap here.</p><p>Bottom T10.</p></figure><p class='k11'>T11. She counted the steps twice; forty-one each time, which settled nothing at all. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences.</p>"#, #".k1 { margin-bottom:309.3px } .k2 { margin:6.0px 25.333333333333332px;  } .k3 { line-height:22.4px; font-size:13.3px;  } .k4 { margin-bottom:52.0px } .k5 { float:left; width:100%; min-height:41.3px; margin:0.7em 0; border:1px solid #333; clear:both;  } .k6 { float:right; width:86.0px; margin:0.7em 0; padding:4px; clear:both; line-height:1.1;  } .k7 { float:left; min-width:55px; width:10%; height:30px; margin-bottom:1.2857142857142858em; border:2.5px solid #333; padding:3px; clear:right; break-before:page;  } .k8 { margin-bottom:171.6px } .k9 { float:left; font-size:2.75em; height:1.6em;  } .k10 { float:left; width:6.5em; height:40%; margin-left:-5px; clear:right; break-before:page;  } .k11 { margin:18.9px 0 13.285714285714286px 0; line-height:22.4px; font-size:13.3px;  } "#, CGSize(width: 512.0, height: 342.5), 14.5),
            ("g12#876, page 1", #"<p class='k1'>T1.</p><p class='k2'>T2.</p><p class='k3'>T3.</p><figure class='k4' dir='rtl'>T4 זהו משפט רגיל בעברית שעוטף ליד התיבה וחוזר לטור המלא מתחתיה.</figure><aside class='k5'><h3>Side T5</h3><p>Ordinary prose wraps beside the box and returns to the full column below it.</p></aside><figure class='k6'>Float T6.</figure><p class='k7'>T7. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences.</p><p class='k8'>T8. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences. She counted the steps twice; forty-one each time, which settled nothing at all. Ordinary prose wraps beside the box and returns to the full column below it. She counted the steps twice; forty-one each time, which settled nothing at all. Ordinary prose wraps beside the box and returns to the full column below it.</p><p class='k9' dir='rtl'>T9. זהו משפט רגיל בעברית שעוטף ליד התיבה וחוזר לטור המלא מתחתיה. النص العربي يستمر هنا بكلمات أخرى مختلفة الطول حتى ينتهي السطر ويبدأ سطر جديد.</p><ul><li>Item T10. No.</li><li>Item T11. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up.</li><li>Item T12. No.</li></ul><p class='k10'>T13.</p><h3>Heading T14</h3><figure class='k11'>Float T15.</figure><figure class='k12'><p>Top T16.</p><p>Bottom T16 words.</p></figure><p class='k13'>T17. No.</p><figure class='k14'>Float T18 with rather more words in it than fit on a line.</figure><p class='k15'>T19. Disproportionately, uncharacteristically long words occasionally interrupt otherwise-ordinary sentences.</p><p class='k16'>T20.</p><figure class='k17'><p>Top T21.</p><p>Bottom T21 words.</p></figure><p class='k18'>T22. Short one. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Short one. Words of several lengths, unremarkable and plain, fill another row or two of the column. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”. Ordinary prose wraps beside the box and returns to the full column below it. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up. Ordinary prose wraps beside the box and returns to the full column below it. Ordinary prose wraps beside the box and returns to the full column below it.</p><p class='k19'>T23. She counted the steps twice; forty-one each time, which settled nothing at all. A line of dialogue, he said, should never run on like this one does, clause after clause, until the reader gives up.</p>"#, #".k1 { margin-bottom:84.6px } .k2 { margin-bottom:372.5px } .k3 { margin-bottom:170.0px } .k4 { float:right; width:72%; height:30px;  } .k5 { float:left; min-width:55px; width:10%; height:4.0em; clear:right;  } .k6 { float:left; width:25%; margin:6px 8px; border:1px solid #333; clear:both;  } .k7 { margin-top:30px; break-before:page; text-align:justify;  } .k8 { clear:both; margin:0 0 -5.5px 0;  } .k9 { text-indent:1.5em; line-height:22.4px;  } .k10 { margin-bottom:666.0px } .k11 { float:left; min-width:55px; width:10%; height:75px; margin:-3.3px 0 11.1px 0;  } .k12 { float:left; width:5.3em; height:100.33333333333333px; margin:-3.3px 0 11.1px 0; line-height:1.1;  } .k13 {  } .k14 { float:left; width:100%; min-height:41.3px; margin:1.3333333333333333px 8.0px; padding:4px; clear:left;  } .k15 { margin-top:30px; break-after:page; text-align:justify;  } .k16 { margin-bottom:464.3px } .k17 { float:left; width:3.0em; height:3.3em; margin-top:-6px; border:2.5px solid #333; padding:3px;  } .k18 { clear:left; text-indent:-1em; padding-left:1em;  } .k19 { clear:left; line-height:1.15;  } "#, CGSize(width: 1024.0, height: 700.25), 31.4),
        ]
        XCTAssertEqual(fixtures.count, 8)
        let files = Dictionary(uniqueKeysWithValues: [40, 64, 120].flatMap { width in [30, 64, 150].map { height in
            ("i\(width)x\(height).png", RichFixture.image(width: width, height: height))
        } })
        for fixture in fixtures {
            let section = try H.build(fixture.body, css: fixture.css, fontSize: fixture.font, files: files)
            assertPages(section, size: fixture.size, label: fixture.name)
        }
    }

    func testGeneratedBoxPagesExposeAllSectionCharacters() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["PAGE_TEXT_SECTIONS"] ?? "") ?? 24
        let seed = UInt64(environment["PAGE_TEXT_SEED"] ?? "") ?? 12
        var random = SectionContentRandom(state: seed)
        for index in 0..<count {
            let size = random.pick(Self.viewports), font = random.pick(Self.fontSizes)
            let generated = Self.generate(&random, viewport: size)
            if let only = environment["PAGE_TEXT_ONLY"], !only.split(separator: ",").contains(Substring(String(index))) { continue }
            if environment["PAGE_TEXT_DIAGNOSTICS"] != nil { print("INPUT \(String(seed) + "#" + String(index)) \(size) \(font) CSS \(generated.css) BODY \(generated.body)") }
            let section = try H.build(generated.body, css: (index.isMultiple(of: 5) ? "" : H.reset) + generated.css,
                fontSize: font, files: generated.files)
            autoreleasepool { assertPages(section, size: size, label: "seed \(seed) section \(index)") }
        }
    }

    func testFrozenReviewGeneratorExposesEveryCharacterAndTableWord() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["PAGE_TEXT_REVIEW_SECTIONS"] ?? "") ?? 24
        let seed = UInt64(environment["PAGE_TEXT_SEED"] ?? "") ?? 12
        var random = SectionContentRandom(state: seed)
        for index in 0..<count {
            let size = random.pick(Self.viewports), font = random.pick(Self.fontSizes)
            let reset = !random.chance(5)
            let generated = Self.generate(&random, viewport: size)
            let section = try H.build(generated.body, css: (reset ? H.reset : "") + generated.css,
                fontSize: font, files: generated.files)
            autoreleasepool { assertPages(section, size: size, label: "frozen review g\(seed)#\(index)") }
        }
    }

    private func assertPages(_ section: SectionText, size: CGSize, label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        Self.assertVisiblePages(section, size: size, label: label, file: file, line: line)
    }

    static func assertVisiblePages(_ section: SectionText, size: CGSize, label: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let paginator = ReaderPaginator(text: section.string, size: size)
        let whole = H.view(paginator.text, size: size)
        let expected = Self.rawLines(in: whole, intersecting: NSRange(location: 0, length: section.string.length))
        var visible = IndexSet()
        var expectedTableWords: [Int: [String]] = [:], displayedTableWords: [Int: [String]] = [:]
        section.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: section.string.length)) { value, range, _ in
            if let row = value as? TableRowAttachment {
                expectedTableWords[range.location] = row.textEquivalent.split(whereSeparator: \.isWhitespace).map(String.init).sorted()
            }
        }
        var cursor = 0
        for (index, page) in paginator.allPages.enumerated() {
            if page.range.location < cursor { XCTAssertFalse(page.tableFragments.isEmpty, label, file: file, line: line) }
            else { XCTAssertEqual(page.range.location, cursor, label, file: file, line: line) }
            cursor = max(cursor, page.range.upperBound)
            let view = H.pageView(paginator, page: page)
            let actual = Self.rawLines(in: view, intersecting: view.shownCharacters)
            for entry in view.textualAttachments(in: view.shownCharacters) where entry.attachment is TableRowAttachment {
                displayedTableWords[page.range.location + entry.range.location, default: []] += entry.text.split(whereSeparator: \.isWhitespace).map(String.init)
            }
            if ProcessInfo.processInfo.environment["PAGE_TEXT_DIAGNOSTICS"] != nil {
                print("PAGE \(label) \(index) \(page) LINES \(actual)")
            }
            let clip = page.layoutEnd > page.range.upperBound ? page.height : size.height - page.topSpacing
            view.readerLayoutManager.enumerateTextLayoutFragments(from: view.contentStorage.documentRange.location, options: [.ensuresLayout]) { fragment in
                let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
                for pair in zip(lines, lines.dropFirst()) {
                    if pair.1.typographicBounds.minY <= pair.0.typographicBounds.minY + 0.01 {
                        let overlap = pair.0.typographicBounds.intersection(pair.1.typographicBounds)
                        XCTAssertTrue(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5,
                            "Lines sharing a row occupy separate exclusion intervals: \(label) page \(index)", file: file, line: line)
                    }
                }
                return true
            }
            let before = ReaderTextView(pageColumn: true)
            (before.readerLayoutManager as! ReaderBoxLayoutManager).repairsPageFlow = false
            before.frame = view.frame
            before.readerContainer.size = view.readerContainer.size
            before.readerContainer.viewportSize = size
            before.placement = view.placement
            before.setContent(paginator.text(for: page))
            before.ensureFullLayout()
            let baseline = Self.rawLines(in: before, intersecting: before.shownCharacters)
            let canonical = expected.filter { NSIntersectionRange($0.range, page.range).length > 0 }
            func matches(_ lines: [Line]) -> Bool {
                guard lines.count == canonical.count, let first = lines.first, let start = canonical.first else { return false }
                return zip(lines, canonical).allSatisfy { lhs, rhs in
                    lhs.range.location + page.range.location == rhs.range.location && lhs.range.length == rhs.range.length
                    && abs(lhs.frame.minX - rhs.frame.minX) < 0.75
                    && abs(lhs.frame.width - rhs.frame.width) < 0.75
                    && abs(lhs.frame.height - rhs.frame.height) < 0.75
                    && abs((lhs.frame.minY - first.frame.minY) - (rhs.frame.minY - start.frame.minY)) < 0.75
                }
            }
            if matches(baseline), baseline.allSatisfy({ $0.frame.minY >= -0.75 && $0.frame.maxY <= min(clip, size.height - page.topSpacing) + 0.75 }) {
                XCTAssertTrue(matches(actual), "A page already matching its section must retain its lines: \(label) page \(index)", file: file, line: line)
                for (old, new) in zip(baseline, actual) {
                    XCTAssertEqual(new.frame.minY, old.frame.minY, accuracy: 0.75, "The existing page origin is preserved: \(label) page \(index)", file: file, line: line)
                    XCTAssertEqual(new.frame.width, old.frame.width, accuracy: 0.75, label, file: file, line: line)
                    XCTAssertEqual(new.frame.height, old.frame.height, accuracy: 0.75, label, file: file, line: line)
                }
            }
            for entry in actual {
                let range = NSIntersectionRange(entry.range, view.shownCharacters)
                let global = NSRange(location: range.location + page.range.location, length: range.length)
                XCTAssertGreaterThanOrEqual(entry.frame.minY, -0.75, "\(label) page \(index) \(global)", file: file, line: line)
                XCTAssertLessThanOrEqual(entry.frame.maxY, min(clip, size.height - page.topSpacing) + 0.75,
                    "\(label) page \(index) \(global)", file: file, line: line)
                let characters = view.contentStorage.textStorage!.string as NSString
                var inkRange = range
                while inkRange.length > 0, let scalar = UnicodeScalar(characters.character(at: inkRange.location)), CharacterSet.whitespacesAndNewlines.contains(scalar) { inkRange.location += 1; inkRange.length -= 1 }
                while inkRange.length > 0, let scalar = UnicodeScalar(characters.character(at: inkRange.upperBound - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { inkRange.length -= 1 }
                if inkRange.length > 0 {
                    for glyph in [inkRange.location, inkRange.upperBound - 1] {
                        let bounds = view.segmentFrames(for: NSRange(location: glyph, length: 1))
                        XCTAssertFalse(bounds.isEmpty, "A painted character has a native segment: \(label)", file: file, line: line)
                        for frame in bounds {
                            XCTAssertGreaterThanOrEqual(frame.minY, -0.75, "Native glyph top: \(label) page \(index)", file: file, line: line)
                            XCTAssertLessThanOrEqual(frame.maxY, min(clip, size.height - page.topSpacing) + 0.75, "Native glyph bottom: \(label) page \(index)", file: file, line: line)
                        }
                    }
                }
                if entry.frame.minY >= -0.75 && entry.frame.maxY <= min(clip, size.height - page.topSpacing) + 0.75 {
                    visible.insert(integersIn: global.location..<global.upperBound)
                }

            }
        }
        XCTAssertEqual(displayedTableWords.mapValues { $0.sorted() }, expectedTableWords,
            "Every table cell word is exposed exactly once across its continuations: \(label)", file: file, line: line)
        XCTAssertEqual(cursor, section.string.length, label, file: file, line: line)
        XCTAssertEqual(visible.count, section.string.length, "Every source character is on a visible line: \(label)", file: file, line: line)
    }
}
