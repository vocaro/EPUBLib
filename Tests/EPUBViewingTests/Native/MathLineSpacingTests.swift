import CoreText
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Inline formulas in the reader's TextKit 2 canvas: lines make room for a formula's ascent and
/// descent with clear space to the lines around it, and lines without formulas keep their spacing.
@MainActor final class MathLineSpacingTests: XCTestCase {
    private struct Line {
        var top: CGFloat, bottom: CGFloat
        /// Extent of what the line draws: its text's font boxes and its formulas' ink.
        var inkTop: CGFloat, inkBottom: CGFloat
        var formulas = 0
        var minimumHeight: CGFloat
    }

    private static let fractions = [
        "<mi>y</mi><mo>=</mo><mstyle displaystyle=\"true\"><mfrac><mn>1</mn><mrow><mn>2</mn><mi>x</mi></mrow></mfrac></mstyle>",
        "<mstyle displaystyle=\"true\"><mfrac><mrow><mi>d</mi><mo>(</mo><msup><mi>y</mi><mi>n</mi></msup><mo>)</mo></mrow><mrow><mi>d</mi><mo>(</mo><msup><mi>y</mi><mn>5</mn></msup><mo>)</mo></mrow></mfrac></mstyle>",
        "<mstyle displaystyle=\"true\"><mfrac><mi>a</mi><msup><mi>b</mi><mn>2</mn></msup></mfrac></mstyle><msup><mi>x</mi><mn>3</mn></msup>",
    ]

    private func body() -> String {
        let math = "xmlns=\"http://www.w3.org/1998/Math/MathML\""
        var paragraph = "<p>Inline formulas"
        for index in 0..<12 {
            paragraph += " sit within text <math \(math) alttext=\"f\">\(Self.fractions[index % 3])</math>"
        }
        paragraph += " and the paragraph ends with words of plain running text to fill out its final lines.</p>"
        return paragraph + "<p>" + CanvasText.sentence(60, seed: 3) + "</p>"
    }

    /// Every line the canvas's text views lay out, top to bottom, in each view's coordinates.
    private func lines(in canvas: ReaderCanvasView) throws -> [Line] {
        var result: [Line] = []
        for view in canvas.textViews {
            let layoutManager = try XCTUnwrap(view.textLayoutManager)
            layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
                let frame = fragment.layoutFragmentFrame
                for line in fragment.textLineFragments where line.characterRange.length > 0 {
                    let bounds = line.typographicBounds
                    let top = frame.minY + bounds.minY, baseline = top + line.glyphOrigin.y
                    var entry = Line(top: top, bottom: frame.minY + bounds.maxY, inkTop: .infinity, inkBottom: -.infinity,
                                     minimumHeight: 0)
                    line.attributedString.enumerateAttributes(in: line.characterRange) { attributes, range, _ in
                        if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
                            entry.minimumHeight = max(entry.minimumHeight, paragraph.minimumLineHeight)
                        }
                        if let formula = attributes[.attachment] as? MathAttachment,
                           let location = layoutManager.location(fragment.rangeInElement.location, offsetBy: range.location) {
                            let box = fragment.frameForTextAttachment(at: location).offsetBy(dx: 0, dy: frame.minY)
                            let scale = box.width / formula.layout.width
                            entry.inkTop = min(entry.inkTop, box.minY + formula.clearance.top * scale)
                            entry.inkBottom = max(entry.inkBottom, box.maxY - formula.clearance.bottom * scale)
                            entry.formulas += 1
                        } else if let font = attributes[.font] as? PlatformFont {
                            entry.inkTop = min(entry.inkTop, baseline - CTFontGetAscent(font as CTFont))
                            entry.inkBottom = max(entry.inkBottom, baseline + CTFontGetDescent(font as CTFont))
                        }
                    }
                    result.append(entry)
                }
                return true
            }
        }
        return result
    }

    func testInlineFractionsKeepClearOfTheLinesAround() async throws {
        let text = try BuilderHarness.build(body(), rich: NativeRichContent())
        let host = CanvasHost(FakeCanvasSource([text.string]), size: CGSize(width: 340, height: 1600))
        defer { host.close() }
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        try await host.settle()
        let lines = try lines(in: host.canvas)
        XCTAssertGreaterThan(lines.count, 10)
        let em: CGFloat = 16
        var adjacentFormulas = 0
        for (line, next) in zip(lines, lines.dropFirst()) where next.top >= line.top {
            XCTAssertLessThanOrEqual(line.inkBottom, line.bottom + 0.01, "a line holds its formula's descent")
            XCTAssertGreaterThanOrEqual(line.inkTop, line.top - 0.01, "a line holds its formula's ascent")
            XCTAssertGreaterThanOrEqual(next.inkTop - line.inkBottom, 0.1 * em,
                                        "ink of consecutive lines stays apart (\(line.inkBottom) then \(next.inkTop))")
            if line.formulas > 0, next.formulas > 0 { adjacentFormulas += 1 }
        }
        XCTAssertGreaterThan(adjacentFormulas, 0, "the fixture puts fractions on consecutive lines")
        // Lines without formulas keep the line height of text: the formula paragraph's minimum,
        // and in the plain paragraph that follows, its own.
        let plain = lines.filter { $0.formulas == 0 }
        let withMinimum = plain.filter { $0.minimumHeight > 0 }, others = plain.filter { $0.minimumHeight == 0 }
        XCTAssertGreaterThan(withMinimum.count, 1)
        XCTAssertGreaterThan(others.count, 3)
        for line in withMinimum { XCTAssertEqual(line.bottom - line.top, line.minimumHeight, accuracy: 0.5) }
        for line in others { XCTAssertEqual(line.bottom - line.top, others[0].bottom - others[0].top, accuracy: 0.5) }
    }
}
