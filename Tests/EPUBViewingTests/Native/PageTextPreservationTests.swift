import CoreGraphics
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Actual displayed rectangles captured from immutable main24400a9, without adding a
/// section origin to page coordinates. These are preservation inputs from issue242's review.
@MainActor final class PageTextPreservationTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private func assertFrozen(_ paginator: ReaderPaginator, pageIndex: Int, range: NSRange,
                              lines: [[Double]], file: StaticString = #filePath, line: UInt = #line) {
        let page = paginator.allPages[pageIndex]
        XCTAssertEqual(page.range, range, file: file, line: line)
        let view = H.pageView(paginator, page: page)
        let actual = PageTextGeometryTests.rawLines(in: view, intersecting: view.shownCharacters)
        XCTAssertEqual(actual.count, lines.count, file: file, line: line)
        for (value, old) in zip(actual, lines) {
            XCTAssertEqual(value.range.location + page.range.location, Int(old[0]), file: file, line: line)
            XCTAssertEqual(value.range.length, Int(old[1]), file: file, line: line)
            let rect = value.frame
            for (now, before) in zip([rect.origin.x, rect.origin.y, rect.width, rect.height], old[2...]) {
                XCTAssertEqual(now, CGFloat(before), accuracy: 0.5, file: file, line: line)
            }
        }
    }

    func testOriginalMultipleParagraphBoxPreservesTheActualFirstPage() throws {
        let section = try H.build("<figure class='c1'>Float one.</figure><figure class='c2'><p>Top two.</p><p>Middle two words wrap here.</p><p>Bottom two.</p></figure>"
            + "<aside class='c3'>Fixed three words.</aside><p class='c4'>Cleared four. \(H.prose)</p><figure class='z'>Later float.</figure><p>End words. \(H.prose)</p>",
            css: H.reset + ".c1 { float:left; width:25%; height:120.5px; margin-bottom:9.5px; break-before:page } .c2 { float:left; width:50%; height:30px; margin-bottom:9.5px; break-before:page } "
                + ".c3 { position:fixed; width:62.5%; top:3.1em } .c4 { clear:both; margin-top:30px } .z { float:left; width:60px; height:40px }", fontSize: 14.5)
        let paginator = ReaderPaginator(text: section.string, size: CGSize(width: 250, height: 333.3))
        assertFrozen(paginator, pageIndex: 0, range: NSRange(location: 0, length: 114), lines: [[0,6,0.0,85.39369885433715,38.02882555127144,19.94369885433715],
[6,5,0.0,105.3373977086743,29.3380728662014,19.94369885433715],
[11,9,0.0,215.39369885433717,57.87859809398651,19.94369885433715],
[20,17,0.0,235.33739770867433,124.33645924925804,19.94369885433715],
[37,11,0.0,255.2810965630115,72.0531495809555,19.94369885433715],
[48,12,0.0,275.2247954173486,82.94416791200638,19.94369885433715],
[60,19,0.0,44.95,123.77823588252068,19.94369885433715],
[79,35,0.0,304.66849427168574,241.61593878269196,19.94369885433715]])
    }

    func testOriginalDelayedTablesPreserveTheirActualOpeningPages() throws {
        let rows = (1...14).map { "<tr><td>Row \($0) one</td><td>two</td></tr>" }.joined()
        let later = "<figure class='z'>Later float.</figure><p>End words. \(H.prose)</p>"
        let z = ".z { float:left; width:60px; height:40px }"
        let bodies = [
            "<aside class='a'>Absolute words.</aside><table>\(rows)</table><p>After the table. \(H.prose)</p>" + later,
            "<p class='lead'>Lead.</p><aside class='a'>Absolute words.</aside><table>\(rows)</table><p>After the table. \(H.prose)</p>" + later,
            "<aside class='a'>Fixed words.</aside><table>\(rows)</table><p>After the table. \(H.prose)</p>" + later]
        let styles = [".a { position:absolute; width:100%; top:12%; height:50px }",
            ".lead { break-after:page } .a { position:absolute; width:100%; top:80px; height:50px }",
            ".a { position:fixed; width:100px; left:0; bottom:10px }"]
        let frozen: [[[Double]]] = [[[0,16,0.0,0.0,125.27063024044037,23.46317512274959],
[16,2,0.0,50.0,300.0,28.0],
[18,2,0.0,78.0,300.0,28.0],
[20,2,0.0,106.0,300.0,28.0],
[22,2,0.0,134.0,300.0,28.0],
[24,2,0.0,162.0,300.0,28.0],
[26,2,0.0,190.0,300.0,28.0],
[28,2,0.0,218.0,300.0,28.0],
[30,2,0.0,246.0,300.0,28.0],
[32,2,0.0,274.0,300.0,28.0],
[34,2,0.0,302.0,300.0,28.0],
[36,2,0.0,330.0,300.0,28.0],
[38,2,0.0,358.0,300.0,28.0],
[40,2,0.0,386.0,300.0,28.0]],[[6,16,0.0,0.0,125.27063024044037,23.46317512274959],
[22,2,0.0,50.0,300.0,28.0],
[24,2,0.0,78.0,300.0,28.0],
[26,2,0.0,106.0,300.0,28.0],
[28,2,0.0,134.0,300.0,28.0],
[30,2,0.0,162.0,300.0,28.0],
[32,2,0.0,190.0,300.0,28.0],
[34,2,0.0,218.0,300.0,28.0],
[36,2,0.0,246.0,300.0,28.0],
[38,2,0.0,274.0,300.0,28.0],
[40,2,0.0,302.0,300.0,28.0],
[42,2,0.0,330.0,300.0,28.0],
[44,2,0.0,358.0,300.0,28.0],
[46,2,0.0,386.0,300.0,28.0]],[[0,13,0.0,0.0,97.85451364517212,23.46317512274959],
[13,2,0.0,23.46317512274959,300.0,28.0],
[15,2,0.0,51.46317512274959,300.0,28.0],
[17,2,0.0,79.46317512274959,300.0,28.0],
[19,2,0.0,107.46317512274959,300.0,28.0],
[21,2,0.0,135.4631751227496,300.0,28.0],
[23,2,0.0,163.4631751227496,300.0,28.0],
[25,2,0.0,191.4631751227496,300.0,28.0],
[27,2,0.0,219.4631751227496,300.0,28.0],
[29,2,0.0,247.4631751227496,300.0,28.0],
[31,2,0.0,275.4631751227496,300.0,28.0],
[33,2,0.0,303.4631751227496,300.0,28.0],
[35,2,0.0,331.4631751227496,300.0,28.0],
[37,2,0.0,359.4631751227496,300.0,28.0],
[39,2,0.0,387.4631751227496,300.0,30.0]]]
        for index in 0..<3 {
            let section = try H.build(bodies[index], css: H.reset + styles[index] + z, fontSize: 17)
            let paginator = ReaderPaginator(text: section.string, size: CGSize(width: 300, height: 420))
            assertFrozen(paginator, pageIndex: index == 1 ? 1 : 0,
                range: NSRange(location: index == 1 ? 6 : 0, length: index == 2 ? 41 : 42), lines: frozen[index])
        }
    }

    func testRejectedVisualGroupPreservesAllFourDisplayedPagesAndBoundaries() throws {
        let section = try H.build(#"<div class='k3'><figure class='k1'>Float T1.</figure><img class='k2' src='i120x30.png' alt='Picture T2'/></div><aside class='k4'>Placed T3 words.</aside><figure class='k5'>Float T4.</figure><blockquote class='k6'><p>Quoted T5. Short one.</p></blockquote><p class='k7'>T6.</p><figure class='k8'>Float T7 with rather more words in it than fit on a line.</figure><table class='k9'><tr><td>Row 1 T8</td><td>Numbers such as 3.14159 and 2,718 sit among the words; so do (brackets) and “quotation marks”.</td><td>3</td></tr><tr><td>Row 2 T8</td><td>two</td></tr></table><figure class='k10'>Float T9.</figure><p class='k11'>T10. Words of several lengths, unremarkable and plain, fill another row or two of the column. Short one. Words of several lengths, unremarkable and plain, fill another row or two of the column. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Short one. Ordinary prose wraps beside the box and returns to the full column below it. Ordinary prose wraps beside the box and returns to the full column below it.</p><aside class='k12'>Placed T11 words.</aside><aside class='k13'><p>Placed T12 top.</p><p>Placed T12 end words.</p></aside><p class='k14'>T13. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. The harbour was quiet that morning, and nobody on the quay looked up when the ferry came in. Words of several lengths, unremarkable and plain, fill another row or two of the column.</p>"#, css: H.reset + #".k1 { float:right; width:6.5em; height:6.571428571428571em; margin:-3.3px 0 11.1px 0; border:1px solid #333;  } .k2 { float:right; width:25%; min-height:41.3px; margin:6px 8px; padding:6.4px; clear:both; font-size:0.8em; break-before:page;  } .k3 { position:relative; width:80%; margin:0 auto;  } .k4 { position:absolute; width:186.0px; right:0;  } .k5 { float:right; max-width:45%; height:120.5px; text-align:center;  } .k6 { margin:11.714285714285714px 22.8px;  } .k7 { margin-bottom:30.0px } .k8 { float:right; width:72%; height:32.9px; margin:7.6px 8.714285714285714px; clear:both;  } .k9 { width:100%;  } .k10 { float:left; width:25%; height:75px; margin:-3.3px 0 11.1px 0; clear:left; font-size:1.37em; break-before:page;  } .k11 { break-before:page;  } .k12 { position:absolute; width:167.0px; right:7.5px; bottom:10.0px; height:84.71428571428571px;  } .k13 { position:fixed; width:62.333333333333336px; right:0; top:150.5px; margin-top:5px;  } .k14 { text-align:justify;  } "#, fontSize: 14.5,
            files: ["i120x30.png": RichFixture.image(width: 120, height: 30)])
        let paginator = ReaderPaginator(text: section.string, size: CGSize(width: 390, height: 700))
        XCTAssertEqual(paginator.allPages.count, 4)
        let ranges = [NSRange(location: 0, length: 10), NSRange(location: 10, length: 117), NSRange(location: 127, length: 10), NSRange(location: 137, length: 787)]
        let frozen: [[[Double]]] = [[[0,10,87.0,0.0,57.54486471414566,19.94369885433715]],
[[10,2,137.8,0.0,165.2,41.501953125],
[12,17,0.0,53.901953125,114.55461397767067,19.94369885433715],
[29,10,272.2999878227711,73.84565197933715,59.900024354457855,19.94369885433715],
[39,22,22.8,105.50363654796001,149.47871032357216,19.94369885433715],
[61,4,0.0,137.16162111658286,21.57502993941307,19.94369885433715],
[65,38,113.0342857142857,187.10531997092002,251.80468717217445,19.94369885433715],
[103,20,113.0342857142857,207.04901882525718,114.99045017361641,19.94369885433715],
[123,2,0.0,234.59271767959433,390.0,64.0],
[125,2,0.0,298.59271767959433,390.0,46.0]],
[[127,10,0.0,0.0,77.45134838879109,28.1558101472995]],
[[137,55,0.0,0.0,374.51878783106804,19.94369885433715],
[192,56,0.0,19.94369885433715,378.8203613758087,19.94369885433715],
[248,57,0.0,39.8873977086743,374.48928865790367,19.94369885433715],
[305,53,0.0,59.83109656301145,365.93024945259094,19.94369885433715],
[358,51,0.0,79.7747954173486,370.09338119626045,19.94369885433715],
[409,54,0.0,99.71849427168576,369.6396693587303,19.94369885433715],
[463,58,0.0,119.66219312602291,386.535707116127,19.94369885433715],
[521,54,0.0,139.60589198036007,364.4526470005512,19.94369885433715],
[575,14,0.0,159.54959083469723,92.62520763278008,19.94369885433715],
[589,18,0.0,179.49328968903438,118.27117532491684,19.94369885433715],
[607,16,0.0,204.43698854337154,100.82089069485664,19.94369885433715],
[623,15,0.0,224.3806873977087,104.16699075698853,19.94369885433715],
[638,7,0.0,244.32438625204585,44.564391046762466,19.94369885433715],
[645,55,0.0,264.268085106383,390.0,19.94369885433715],
[700,55,0.0,284.21178396072014,389.9999999999999,19.94369885433715],
[755,54,0.0,304.15548281505727,389.9999999999998,19.94369885433715],
[809,55,0.0,324.0991816693944,390.0,19.94369885433715],
[864,56,0.0,344.0428805237316,390.0,19.94369885433715],
[920,4,0.0,363.98657937806877,35.26878949999809,19.94369885433715]]]
        for index in 0..<4 { assertFrozen(paginator, pageIndex: index, range: ranges[index], lines: frozen[index]) }
    }
}
