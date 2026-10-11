import Foundation
import XCTest
@testable import EPUBViewing

/// EPUB CFI 1.1 syntax beyond the recorded foliate vectors: the specification's own examples,
/// every escapable character, malformed input, sorting (section 3.2) and ranges (section 3.4).
final class PositionCFISyntaxCoverageTests: XCTestCase {
    private typealias Step = EPUBCFI.Expression.Step

    /// The forms the specification's examples take (sections 3.1.1 to 3.1.9 and 3.4), with
    /// original identifiers and text.
    func testTheSpecificationsExampleFormsParseAndPrintUnchanged() throws {
        let examples = [
            "epubcfi(/6/4[ref-one]!/4[main]/10[para-five]/3:10)",
            "epubcfi(/6/4[ref-one]!/4[main]/16[figure])",
            "epubcfi(/6/4[ref-one]!/4[main]/10[para-five]/1:0)",
            "epubcfi(/6/4[ref-one]!/4[main]/10[para-five]/2/1:3)",
            "epubcfi(/6/4[ref-one]!/4[main]/10[para-five]/2/1:3[abc])",
            "epubcfi(/6/4[ref-one]!/4[main]/10[para-five]/1:3[ab,c])",
            "epubcfi(/6/4[ref-one]!/4[main]/10[para-five]/2/1:3[,c])",
            "epubcfi(/6/4[ref-one]!/4[main]/10[para-five]/3:5[;s=b])",
            "epubcfi(/6/4[ref-one]!/4[main]/10[para-five]/3:5[;s=a])",
            "epubcfi(/6/4[ref-one]!/4[main]/10[para-five]/2/1:3[abc;s=b])",
            "epubcfi(/6/4[ref-one]!/4[main]/10[para-five],/2/1:1,/3:4)",
            "epubcfi(/6/4[ref-one]!/4[main]/16[figure]@50:50)",
            "epubcfi(/6/4[ref-one]!/4[main]/16[figure]@0:100)",
            "epubcfi(/6/4[ref-one]!/4[main]/18[clip]~23.5)",
            "epubcfi(/6/4[ref-one]!/4[main]/18[clip]~23.5@5.75:97.6)",
            "epubcfi(/6/4[ref-one]!/4[main]/10[para-five]/3:9[Ж-\"spa ce\"-99%-aa^[bb^]^^])",
            "epubcfi(/6/4[ref-one]!/4/2!/4/6/1:0)",
        ]
        for example in examples {
            let expression = try EPUBCFI.parse(example)
            XCTAssertEqual(EPUBCFI.string(expression), example)
            XCTAssertTrue(EPUBCFI.isCFI(example), example)
            XCTAssertTrue(EPUBCFI.isWellFormed(example), example)
            XCTAssertEqual(try EPUBCFI.parse(EPUBCFI.unwrap(example)), expression, "the wrapper is optional when parsing")
        }
        let assertion = try XCTUnwrap(try EPUBCFI.parse(examples[15]).path?.last?.last)
        XCTAssertEqual(assertion, Step(index: 3, offset: 9, text: ["Ж-\"spa ce\"-99%-aa[bb]^"]), "escapes are removed when parsing")
        let media = try XCTUnwrap(try EPUBCFI.parse(examples[14]).path?.last?.last)
        XCTAssertEqual(media, Step(index: 18, id: "clip", temporal: 23.5, spatial: [5.75, 97.6]))
        // foliate reads the empty assertion before the parameter as an empty text assertion.
        let side = try XCTUnwrap(try EPUBCFI.parse(examples[7]).path?.last?.last)
        XCTAssertEqual(side, Step(index: 3, offset: 5, text: [""], side: "b"))
        let both = try XCTUnwrap(try EPUBCFI.parse(examples[9]).path?.last?.last)
        XCTAssertEqual(both, Step(index: 1, offset: 3, text: ["abc"], side: "b"))
        XCTAssertEqual(try EPUBCFI.parse(examples[16]).path?.count, 3, "one path per indirection")
    }

    /// Section 2.3: `^ [ ] ( ) , ; =` are escaped with a circumflex wherever they are data.
    func testEverySpecialCharacterRoundTripsInsideAssertions() throws {
        let values = ["^", "[", "]", "(", ")", ",", ";", "=", "a^b", "[x]", "f(x)=y;z,w", "^^", "]]]", "((", "a b", " lead", "trail ",
                      "/", "!", ":", "~", "@", "/6/4!/4:3~1@2:3", "épée", "第二章", "𝒜𝒷", "e\u{301}", "\u{5E9}\u{5DC}\u{5D5}\u{5DD}", "%2D", "\"", "'", "\\", "s=b", ";s=b"]
        for value in values {
            let element = EPUBCFI.Expression(path: [[Step(index: 6), Step(index: 4, id: value)], [Step(index: 4, id: value), Step(index: 2)]])
            let printed = EPUBCFI.string(element)
            XCTAssertEqual(try EPUBCFI.parse(printed), element, "ID \(value.debugDescription) as \(printed)")
            XCTAssertTrue(EPUBCFI.isCFI(printed), printed)
            XCTAssertTrue(EPUBCFI.isWellFormed(printed), printed)

            let text = EPUBCFI.Expression(path: [[Step(index: 6), Step(index: 4)], [Step(index: 4), Step(index: 3, offset: 2, text: [value, value], side: "a")]])
            XCTAssertEqual(try EPUBCFI.parse(EPUBCFI.string(text)), text, "text assertion \(value.debugDescription) as \(EPUBCFI.string(text))")

            let range = EPUBCFI.Expression(parent: [[Step(index: 6), Step(index: 4, id: value)], [Step(index: 4, id: value)]],
                                           start: [[Step(index: 2, id: value), Step(index: 1, offset: 0)]],
                                           end: [[Step(index: 2, id: value), Step(index: 1, offset: 3)]])
            XCTAssertEqual(try EPUBCFI.parse(EPUBCFI.string(range)), range, "range with \(value.debugDescription) as \(EPUBCFI.string(range))")
        }
    }

    func testAnEscapedDelimiterIsNeverAStepOrASeparator() throws {
        // A comma, bang or slash inside an assertion must not split the range, the path or the step.
        let cfi = "epubcfi(/6/4[a^,b!c/8]!/4/2[x^]y],/1:1[p^,q],/1:4)"
        let expression = try EPUBCFI.parse(cfi)
        XCTAssertTrue(expression.isRange)
        XCTAssertEqual(expression.parent, [[Step(index: 6), Step(index: 4, id: "a,b!c/8")], [Step(index: 4), Step(index: 2, id: "x]y")]])
        XCTAssertEqual(expression.start, [[Step(index: 1, offset: 1, text: ["p,q"])]])
        XCTAssertEqual(expression.end, [[Step(index: 1, offset: 4)]])
        XCTAssertEqual(EPUBCFI.string(expression), cfi)
        XCTAssertEqual(EPUBCFI.collapse(cfi), "epubcfi(/6/4[a^,b!c/8]!/4/2[x^]y]/1:1[p^,q])")
        XCTAssertEqual(EPUBCFI.collapse(cfi, toEnd: true), "epubcfi(/6/4[a^,b!c/8]!/4/2[x^]y]/1:4)")
    }

    /// Books and stored locators are untrusted: nothing here may trap, and what parses must
    /// print to something that parses to the same expression.
    func testMalformedInputFailsCleanly() throws {
        let document = try ContentDocument.parse(
            Data(#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body><p id="a">One <em>two</em></p></body></html>"#.utf8),
            path: "malformed.xhtml")
        let spine = SpineCFIs(package: nil, spineCount: 2)
        let malformed = [
            "", " ", "epubcfi", "epubcfi(", "epubcfi)", "epubcfi()", "epubcfi(())", "epubcfi(/)", "epubcfi(//)", "epubcfi(/6//4)", "epubcfi(/6/4!)",
            "epubcfi(!)", "epubcfi(!!)", "epubcfi(,)", "epubcfi(,,)", "epubcfi(,,,)", "epubcfi(/6/4,)", "epubcfi(/6/4,,)", "epubcfi(/6/4!/4,/2)",
            "epubcfi(/6/4[)", "epubcfi(/6/4[])", "epubcfi(/6/4])", "epubcfi(/6/4[[]])", "epubcfi(/6/4[a]b])", "epubcfi(/6/4[a", "epubcfi(/6/4[a^",
            "epubcfi(/6/4^)", "epubcfi(^)", "epubcfi(^^^)", "epubcfi(/6/4[;])", "epubcfi(/6/4[;=])", "epubcfi(/6/4[;s])", "epubcfi(/6/4[;s=])",
            "epubcfi(/6/4[;;;])", "epubcfi(/6/4[=])", "epubcfi(:)", "epubcfi(:1)", "epubcfi(~)", "epubcfi(@)", "epubcfi(@:)", "epubcfi(~1.2.3)",
            "epubcfi(/6/4!/4/2/1:)", "epubcfi(/6/4!/4/2/1::3)", "epubcfi(/6/4!/4/2/1:3:4)", "epubcfi(/6/4!/4/2/1:-3)", "epubcfi(/-6/4)", "epubcfi(/+6)",
            "epubcfi(/6.5/4)", "epubcfi(/0x10)", "epubcfi(/١٢)", "epubcfi(/６)", "epubcfi(/1e3)", "epubcfi(/ 6 / 4)", "epubcfi(/6/4!/4/2/1:3~)",
            "epubcfi(/6/4!/4/2/1:3@)", "epubcfi(/6/4!/4/2/1:3@1:)", "epubcfi(/6/4!/4/2/1:3@:1)", "epubcfi(/6/4!/4/2/1:3~~1)", "epubcfi(/6/4!/4/2/1:3@@1)",
            "epubcfi(/6/4)epubcfi(/6/4)", "epubcfi(epubcfi(/6/4))", "EPUBCFI(/6/4)", "epubcfi (/6/4)", "epubcfi(/6/4) ", "epubcfi(/6/4\u{0})", "epubcfi(/6/4\t!/4)",
            "/6/4!", "!/4", ",/1:0,/1:2", "/6/4,/1:0", "[a]", "[a][b]", ";s=a", "/6/4[a][b][c]", "/6/4[a;s=b;s=c;t=d]",
            "epubcfi(/9223372036854775807)", "epubcfi(/9223372036854775808)", "epubcfi(/18446744073709551616)", "epubcfi(/6/4!/4/2/1:9223372036854775808)",
            "epubcfi(/6/4!/4/2/1:3~1e400)", "epubcfi(/6/4!/4/2/1:3~" + String(repeating: "9", count: 400) + ")",
            "epubcfi(/6/4!/4/2/1:3@" + String(repeating: "1:", count: 500) + "1)", "epubcfi(/6/4" + String(repeating: "[", count: 500) + ")",
            "epubcfi(/6/4" + String(repeating: "[a]", count: 500) + ")", "epubcfi(/6/4" + String(repeating: "!", count: 500) + ")",
            "epubcfi(/6/4" + String(repeating: ",", count: 500) + ")", "epubcfi(/6/4[" + String(repeating: "^", count: 501) + "])",
            String(repeating: "/", count: 5_000), String(repeating: ":", count: 5_000), String(repeating: "/2", count: 20_000),
        ]
        for cfi in malformed {
            _ = EPUBCFI.isCFI(cfi)
            _ = EPUBCFI.isWellFormed(cfi)
            _ = EPUBCFI.compare(cfi, "epubcfi(/6/4!/4/2/1:1)")
            _ = EPUBCFI.compare("epubcfi(/6/4!/4/2,/1:0,/1:1)", cfi)
            _ = EPUBCFI.collapse(cfi)
            _ = EPUBCFI.collapse(cfi, toEnd: true)
            _ = EPUBCFI.resolve(localPath: cfi, in: document)
            _ = spine.resolve(cfi)
            if let parsed = try? EPUBCFI.parse(cfi) {
                let printed = EPUBCFI.string(parsed)
                if !printed.contains("NaN"), !printed.contains("Infinity") {
                    XCTAssertEqual(EPUBCFI.string(try EPUBCFI.parse(printed)), printed, cfi.debugDescription)
                }
                _ = EPUBCFI.resolve(parsed, in: document)
                _ = EPUBCFI.buildRange(from: parsed, to: parsed)
            }
        }
        // A step or offset needs digits, and both stay exact (foliate's numbers were doubles).
        for cfi in ["epubcfi(/)", "epubcfi(/6/)", "epubcfi(/6/4!/4/2/1:)", "epubcfi(/-6/4)", "epubcfi(/a)", "epubcfi(/9223372036854775808)",
                    "epubcfi(/18446744073709551616)", "epubcfi(/6/4!/4/2/1:9223372036854775808)", "epubcfi(/9007199254740993)", "epubcfi(/6/4,/2)",
                    "epubcfi(:3)", "epubcfi([x])", "epubcfi(~1)", "epubcfi(@1:2)", "epubcfi([;s=a])"] {
            XCTAssertThrowsError(try EPUBCFI.parse(cfi), cfi)
        }
        XCTAssertEqual(try EPUBCFI.parse("epubcfi(/9007199254740992)").path, [[Step(index: 9_007_199_254_740_992)]])
        XCTAssertNil(EPUBCFI.resolve(localPath: "/9007199254740992/2", in: document), "an index far past the children names nothing")
        XCTAssertNil(spine.resolve("epubcfi(/6/9007199254740992!/4)"))
    }

    func testVeryLongPathsAreBoundedNotQuadratic() throws {
        // 100,000 steps exceed the parse bound and are refused before any work.
        let enormous = "epubcfi(" + String(repeating: "/2", count: 100_000) + ")"
        XCTAssertThrowsError(try EPUBCFI.parse(enormous))
        XCTAssertFalse(EPUBCFI.isWellFormed(enormous))
        XCTAssertEqual(EPUBCFI.collapse(enormous), enormous, "what does not parse is returned unchanged")
        XCTAssertEqual(EPUBCFI.compare(enormous, "epubcfi(/6/2)"), -1, "and orders as an empty path")

        // The longest input that parses: about 32,000 steps, exactly at the bound.
        let steps = (EPUBCFI.maximumParseLength - "epubcfi(/22)".count) / 2
        let shared = "/22" + String(repeating: "/2", count: steps - 1)
        let longest = "epubcfi(" + shared + "/2)"
        XCTAssertEqual(longest.utf16.count, EPUBCFI.maximumParseLength)
        let parsed = try EPUBCFI.parse(longest)
        XCTAssertEqual(parsed.path?.first?.count, steps + 1)
        XCTAssertEqual(EPUBCFI.string(parsed), longest)
        XCTAssertEqual(EPUBCFI.compare(longest, longest), 0)
        XCTAssertEqual(EPUBCFI.compare(longest, "epubcfi(" + shared + "/4)"), -1)
        XCTAssertThrowsError(try EPUBCFI.parse(longest + " "), "one unit over the bound, even if it is white space")
        let range = "epubcfi(" + String(repeating: "/2", count: 10_000) + ",/1:0,/1:5)"
        XCTAssertEqual(EPUBCFI.collapse(range, toEnd: true), "epubcfi(" + String(repeating: "/2", count: 10_000) + "/1:5)")
    }

    /// Section 3.2: earlier steps matter most, steps and offsets sort in natural order,
    /// assertions are ignored. A range sorts by its start, then by its end.
    func testSortingPutsCFIsInReadingOrder() {
        let ordered = [
            "epubcfi(/6/2)",
            "epubcfi(/6/2!/4/2)",
            "epubcfi(/6/2!/4/2/1:0)",
            "epubcfi(/6/2!/4/2/1:9)",
            "epubcfi(/6/2!/4/2/1:10)",
            "epubcfi(/6/2!/4/2/2)",
            "epubcfi(/6/2!/4/2/2/1:4)",
            "epubcfi(/6/2!/4/2/3:0)",
            "epubcfi(/6/2!/4/2,/3:0,/3:2)",
            "epubcfi(/6/2!/4/2,/3:0,/3:7)",
            "epubcfi(/6/2!/4/2/3:1)",
            "epubcfi(/6/2!/4,/2/3:2,/100/1:0)",
            "epubcfi(/6/2!/4/4)",
            "epubcfi(/6/2!/4/10/1:0)",
            "epubcfi(/6/2!/4/100)",
            "epubcfi(/6/4)",
            "epubcfi(/6/4!/2)",
            "epubcfi(/6/4!/4/2/1:0)",
            "epubcfi(/6/10!/4/2/1:0)",
            "epubcfi(/6/100!/2)",
        ]
        for (i, a) in ordered.enumerated() {
            for (j, b) in ordered.enumerated() {
                XCTAssertEqual(EPUBCFI.compare(a, b), i < j ? -1 : i > j ? 1 : 0, "\(a) against \(b)")
            }
        }
        // Sorting a shuffled copy restores reading order, whatever order the input came in.
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        var shuffled = ordered
        for index in shuffled.indices.dropLast().reversed() {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            shuffled.swapAt(index + 1, Int((state >> 33) % UInt64(index + 2)))
        }
        XCTAssertEqual(shuffled.sorted { EPUBCFI.compare($0, $1) < 0 }, ordered)

        // "All bracketed assertions are removed (ignored) entirely."
        for (a, b) in [("epubcfi(/6/4[one]!/4[body]/2[p]/1:3[ab,cd;s=b])", "epubcfi(/6/4!/4/2/1:3)"),
                       ("epubcfi(/6/4[zzz]!/4/2)", "epubcfi(/6/4[aaa]!/4/2)"),
                       ("epubcfi(/6/4!/4/2[x^]y],/1:0,/1:3)", "epubcfi(/6/4!/4/2,/1:0[q],/1:3[;s=a])")] {
            XCTAssertEqual(EPUBCFI.compare(a, b), 0, "\(a) against \(b)")
            XCTAssertEqual(EPUBCFI.compare(b, a), 0, "\(b) against \(a)")
        }
        // Leading zeros are the same number, and the wrapper is optional.
        XCTAssertEqual(EPUBCFI.compare("epubcfi(/06/004!/4/2/1:007)", "/6/4!/4/2/1:7"), 0)
        XCTAssertEqual(EPUBCFI.compare("epubcfi(/6/4!/4/2/1:10)", "epubcfi(/6/4!/4/2/1:9)"), 1, "numbers, not strings")
    }

    /// Section 3.4: `epubcfi(P,S,E)`.
    func testRangesCollapseToTheirEndsAndAreBuiltFromThem() throws {
        let range = "epubcfi(/6/4[ref-one]!/4[main]/10[para-five],/2/1:1,/3:4)"
        let start = "epubcfi(/6/4[ref-one]!/4[main]/10[para-five]/2/1:1)", end = "epubcfi(/6/4[ref-one]!/4[main]/10[para-five]/3:4)"
        XCTAssertEqual(EPUBCFI.collapse(range), start)
        XCTAssertEqual(EPUBCFI.collapse(range, toEnd: true), end)
        XCTAssertEqual(EPUBCFI.string(EPUBCFI.buildRange(from: try EPUBCFI.parse(start), to: try EPUBCFI.parse(end))), range)
        XCTAssertEqual(EPUBCFI.collapse(start), start, "a position collapses to itself")
        XCTAssertEqual(EPUBCFI.collapse(start, toEnd: true), start)

        // "The start location may be empty, to avoid repetition of a common path."
        let emptyStart = "epubcfi(/6/4!/4/10,,/3:4)"
        XCTAssertEqual(EPUBCFI.collapse(emptyStart), "epubcfi(/6/4!/4/10)")
        XCTAssertEqual(EPUBCFI.collapse(emptyStart, toEnd: true), "epubcfi(/6/4!/4/10/3:4)")
        XCTAssertEqual(EPUBCFI.string(try EPUBCFI.parse(emptyStart)), emptyStart)

        // Both ends in one text chunk share everything but the offset.
        let from = try EPUBCFI.parse("epubcfi(/6/4!/4/10/3:4)"), to = try EPUBCFI.parse("epubcfi(/6/4!/4/10/3:9)")
        XCTAssertEqual(EPUBCFI.string(EPUBCFI.buildRange(from: from, to: to)), "epubcfi(/6/4!/4/10,/3:4,/3:9)")
        // From offset zero the chunk's step is still not common, or its offset would be lost.
        let zero = try EPUBCFI.parse("epubcfi(/6/4!/4/10/3:0)")
        XCTAssertEqual(EPUBCFI.string(EPUBCFI.buildRange(from: zero, to: to)), "epubcfi(/6/4!/4/10,/3:0,/3:9)")
        // Ends in different blocks share only the body.
        let far = try EPUBCFI.parse("epubcfi(/6/4!/4/22/1:2)")
        XCTAssertEqual(EPUBCFI.string(EPUBCFI.buildRange(from: from, to: far)), "epubcfi(/6/4!/4,/10/3:4,/22/1:2)")
        // Building from ranges uses the first's start and the second's end.
        let first = try EPUBCFI.parse("epubcfi(/6/4!/4/10,/1:2,/1:5)"), second = try EPUBCFI.parse("epubcfi(/6/4!/4/12,/1:1,/1:8)")
        XCTAssertEqual(EPUBCFI.string(EPUBCFI.buildRange(from: first, to: second)), "epubcfi(/6/4!/4,/10/1:2,/12/1:8)")
        // A range's two ends compare in order, and the range sorts at its start.
        XCTAssertEqual(EPUBCFI.compare(EPUBCFI.collapse(range), EPUBCFI.collapse(range, toEnd: true)), -1)
        XCTAssertEqual(EPUBCFI.compare(range, start), 1, "after the position at its start, by its end")
        XCTAssertEqual(EPUBCFI.compare(range, end), -1)
    }

    func testWrappingJoiningAndWhiteSpace() throws {
        XCTAssertEqual(EPUBCFI.wrap("/6/4"), "epubcfi(/6/4)")
        XCTAssertEqual(EPUBCFI.wrap("epubcfi(/6/4)"), "epubcfi(/6/4)", "wrapped once")
        XCTAssertEqual(EPUBCFI.unwrap("epubcfi(/6/4)"), "/6/4")
        XCTAssertEqual(EPUBCFI.unwrap("/6/4"), "/6/4")
        XCTAssertEqual(EPUBCFI.wrap(""), "epubcfi()")
        XCTAssertEqual(EPUBCFI.joinIndirections("epubcfi(/6/4[a^]b])", "/4/2,/1:0,/1:3"), "epubcfi(/6/4[a^]b]!/4/2,/1:0,/1:3)")
        XCTAssertEqual(EPUBCFI.joinIndirections("/6/4", "epubcfi(/4/2)", "/2/1:0"), "epubcfi(/6/4!/4/2!/2/1:0)")
        // An ID may end in a parenthesis: the wrapper is the outermost pair only.
        XCTAssertEqual(EPUBCFI.unwrap("epubcfi(/6/4[f^(x^)])"), "/6/4[f^(x^)]")
        XCTAssertEqual(try EPUBCFI.parse("epubcfi(/6/4[f^(x^)])").path, [[Step(index: 6), Step(index: 4, id: "f(x)")]])
        // Surrounding white space is trimmed; white space inside an assertion is data.
        XCTAssertEqual(try EPUBCFI.parse("  /6/4[ a b ]!/4/2/1:3\n"), try EPUBCFI.parse("/6/4[ a b ]!/4/2/1:3"))
        XCTAssertEqual(try EPUBCFI.parse("/6/4[ a b ]").path?.last?.last?.id, " a b ")
        XCTAssertFalse(EPUBCFI.isCFI(" epubcfi(/6/4)"), "the wrapper test itself does not trim")
        XCTAssertFalse(EPUBCFI.isCFI("epubcfi(/6/4)\n"))
    }
}
