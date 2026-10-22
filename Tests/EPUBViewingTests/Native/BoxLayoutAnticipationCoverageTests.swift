import CoreGraphics
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// Boxes positioned by a vertical inset can sit above their place in the source, so the layout
/// places them in one pass and in the next has the text and the floats before each of them keep
/// clear of where it was. Every paragraph and float of that pass asks which of those boxes it
/// has not reached yet: the answer has to be the one a search of the placed regions gives, and
/// in a book of thousands of such boxes it must not cost a search per box per paragraph.
@MainActor final class BoxLayoutAnticipationCoverageTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private typealias Region = ReaderBoxGeometry.Region
    private let size = CGSize(width: 400, height: 600)

    /// CPU seconds of this thread: unlike a wall clock, unaffected by other work on the machine.
    private func threadSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

    /// The lesser CPU time of two layouts of `body`. A section that fell back to plain flow
    /// would cost nothing and prove nothing, so every box has to keep its region.
    private func cpuSeconds(resolving body: String, css: String, regions: Int, positioned: Int) throws -> Double {
        let section = try H.build(body, css: H.reset + css)
        return try (0..<2).map { _ in
            let start = threadSeconds()
            let resolved = ReaderBoxLayout.resolve(section.string, viewport: size)
            let elapsed = threadSeconds() - start
            XCTAssertEqual(resolved.text.string, section.string.string)
            let plan = try XCTUnwrap(resolved.geometry, "\(positioned) positioned boxes are planned")
            XCTAssertEqual(plan.regions.count, regions, "every box keeps its region")
            XCTAssertEqual(plan.regions.filter(\.wrapsEarlierText).count, positioned, "and every positioned box is one text can wrap ahead of")
            return elapsed
        }.min() ?? 0
    }

    // MARK: Cost

    /// A positioned box with a top inset in a relative container of its own, a paragraph beside
    /// it and a paragraph before the next container: a page of margin notes, as often as the
    /// book likes. While each paragraph of the second pass searched the regions placed so far
    /// for every box of the first, 600 of these took 13 s of CPU and 1,200 took 99 s on the
    /// machine these tests were written on; with one lookup a box they take 0.9 s and 2.9 s.
    func testResolvingInsetBoxesBetweenParagraphsDoesNotGrowCubically() throws {
        func seconds(_ count: Int) throws -> Double {
            try cpuSeconds(resolving: (0..<count).map { "<div class='rel'><aside>A\($0).</aside><p>Paragraph \($0) beside its box.</p></div><p>Separator \($0).</p>" }.joined(),
                        css: ".rel { position:relative } aside { position:absolute; right:0; top:0; width:60px }", regions: count, positioned: count)
        }
        let small = try seconds(50), large = try seconds(600)
        // Linear work is 12 times as long, quadratic 144, cubic 1,728. The search made it 400
        // times (a section of 50 is too short for its cube to show in full); it is now 35.
        XCTAssertLessThan(large, 144 * small, "50 boxes took \(small) s of CPU and 600 took \(large) s")
    }

    /// The same containers with a float in each. A float keeps clear of every box the earlier
    /// pass placed and this one has not reached, and found them by the same search: 400 of
    /// these took 12 s of CPU and now take 0.9 s.
    func testResolvingFloatsBesideInsetBoxesDoesNotGrowCubically() throws {
        func seconds(_ count: Int) throws -> Double {
            try cpuSeconds(resolving: (0..<count).map { "<div class='rel'><aside>A\($0).</aside><figure>F\($0).</figure><p>Paragraph \($0) beside its box.</p></div><p>Separator \($0).</p>" }.joined(),
                        css: ".rel { position:relative } aside { position:absolute; right:0; top:0; width:60px } figure { float:left; width:60px }",
                        regions: 2 * count, positioned: count)
        }
        let small = try seconds(50), large = try seconds(400)
        // Linear work is 8 times as long, quadratic 64, cubic 512. The search made it 190 times; it is now 21.
        XCTAssertLessThan(large, 64 * small, "50 of each took \(small) s of CPU and 400 took \(large) s")
    }

    /// A container of many floats, or many paragraphs, and then as many boxes positioned by an
    /// inset, below the issue's container from #209, whose paragraph gains a line in the pass that
    /// knows of its note. The container below moves down then, so every box in it is anticipated
    /// from its new top, and every float and paragraph before them asks where they will be. While
    /// each question settled every such box again, below a list growing with each, 400 of each
    /// took 19 s of CPU, where the layout before #209 took 0.75 s; settled once a pass, they take
    /// 0.9 s. The text is one pixel high, so that every group fits a page, and the boxes stand side
    /// by side.
    func testAnticipatingBoxesInAContainerThatMovedDoesNotGrowCubically() throws {
        let first = "<div class='rel'><p>P. Ordinary prose wraps beside the box and returns.</p><aside class='note'>A.</aside></div>"
        let css = ".rel { position:relative } .note { position:absolute; right:0; top:0; width:120px; height:50px } "
            + ".low { position:absolute; width:1px; font-size:1px; line-height:1px } .t { font-size:1px; line-height:1px } "
        func boxes(_ count: Int) -> String { (0..<count).map { "<aside class='low' style='left:\($0)px'>.</aside>" }.joined() }
        func floats(_ count: Int) throws -> Double {
            try cpuSeconds(resolving: first + "<div class='rel'>" + String(repeating: "<figure>.</figure>", count: count) + boxes(count)
                            + "</div><p style='clear:left'>End.</p>",
                           css: css + ".low { top:300px } figure { float:left; width:1px; font-size:1px; line-height:1px }",
                           regions: 2 * count + 1, positioned: count + 1)
        }
        func paragraphs(_ count: Int) throws -> Double {
            try cpuSeconds(resolving: first + "<div class='rel'>" + String(repeating: "<p class='t'>.</p>", count: count) + boxes(count) + "</div><p>End.</p>",
                           css: css + ".low { top:520px }", regions: count + 1, positioned: count + 1)
        }
        // Linear work is 8 times as long, quadratic 64, cubic 512.
        let smallFloats = try floats(50), largeFloats = try floats(400)
        XCTAssertLessThan(largeFloats, 64 * smallFloats, "50 floats and boxes took \(smallFloats) s of CPU and 400 took \(largeFloats) s")
        let smallParagraphs = try paragraphs(50), largeParagraphs = try paragraphs(400)
        XCTAssertLessThan(largeParagraphs, 64 * smallParagraphs,
                          "50 paragraphs and boxes took \(smallParagraphs) s of CPU and 400 took \(largeParagraphs) s")
    }

    // MARK: Anticipated boxes

    /// End to end: a callout written last is positioned at the top of the column, where a float
    /// and the prose written before it would have been. Both are laid out before the callout
    /// is reached, and both keep clear of where the pass before placed it.
    func testAFloatAndProseWrittenBeforeABoxPositionedOverThemKeepClearOfIt() throws {
        let section = try H.build("<p>Lead words.</p><figure>Float words.</figure><p>\(H.prose)</p><aside>Callout words.</aside><p>After words.</p>",
                                  css: H.reset + "figure { float:right; width:100px; height:40px } aside { position:absolute; right:0; top:0; width:120px; height:60px }")
        let plan = try XCTUnwrap(ReaderBoxLayout.resolve(section.string, viewport: size).geometry)
        func region(_ phrase: String) throws -> Region {
            try XCTUnwrap(plan.regions.first { !$0.reserved && NSIntersectionRange($0.range, H.range(phrase, in: section)).length > 0 }, phrase)
        }
        let callout = try region("Callout words."), float = try region("Float words.")
        XCTAssertTrue(callout.wrapsEarlierText)
        XCTAssertEqual(callout.frame.minX, 280, accuracy: 1); XCTAssertEqual(callout.frame.minY, 0, accuracy: 1)
        XCTAssertEqual(callout.frame.width, 120, accuracy: 1); XCTAssertEqual(callout.frame.height, 60, accuracy: 1)
        // In flow the float starts under the lead's one line, inside the callout's rows.
        XCTAssertEqual(float.frame.minX, 300, accuracy: 1)
        XCTAssertEqual(float.frame.minY, callout.frame.maxY, accuracy: 0.5, "the float drops below the box it would have overlapped")
        let prose = try XCTUnwrap(plan.paragraph(at: H.range(H.prose, in: section).location))
        let besideCallout = prose.lines.filter { $0.frame.minY < callout.frame.maxY - 0.5 }
        let besideFloat = prose.lines.filter { $0.frame.maxY > float.frame.minY + 0.5 && $0.frame.minY < float.frame.maxY - 0.5 }
        XCTAssertGreaterThanOrEqual(besideCallout.count, 2); XCTAssertGreaterThanOrEqual(besideFloat.count, 1)
        XCTAssertTrue(besideCallout.allSatisfy { $0.frame.maxX <= callout.frame.minX + 0.5 }, "prose written before the callout is planned beside it")
        XCTAssertTrue(besideFloat.allSatisfy { $0.frame.maxX <= float.frame.minX + 0.5 }, "and beside the float where the float came to rest")
        let below = prose.lines.filter { $0.frame.minY >= float.frame.maxY - 0.5 }
        XCTAssertGreaterThan(below.map(\.frame.maxX).max() ?? 0, float.frame.minX + 0.5, "below both it has the whole column")
    }

    /// Which boxes are still to come is defined by the search the layout began with: a box of
    /// the earlier pass is unplaced while no region placed so far has its range, and text wraps
    /// ahead of it when it is also a box positioned by a vertical inset, in the text's own
    /// scope, that this pass has not left in flow. The set and the lists by scope have to give
    /// those same boxes in that same order, after every region placed, whatever is placed and
    /// in whatever order.
    func testAnticipatedBoxesAreTheOnesASearchOfThePlacedRegionsFinds() {
        func unplaced(_ anticipated: [Region], among placed: [Region]) -> [Region] {
            anticipated.filter { candidate in !placed.contains(where: { $0.range == candidate.range }) }
        }
        func wrapped(_ anticipated: [Region], among placed: [Region], disabled: [NSRange], scope: UUID?) -> [Region] {
            anticipated.filter { candidate in
                candidate.wrapsEarlierText && !placed.contains(where: { $0.range == candidate.range })
                    && !disabled.contains(where: { NSIntersectionRange($0, candidate.range).length > 0 })
                    && candidate.scope == scope
            }
        }
        func described(_ regions: [Region]) -> [String] {
            regions.map { "\($0.range) \($0.frame) \($0.wrapsEarlierText) \($0.scope?.uuidString ?? "no scope")" }
        }
        func scope(_ number: UInt8) -> UUID { UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, number)) }
        // Text outside any positioned container has no scope; `elsewhere` holds no box at all.
        let scopes: [UUID?] = [nil, scope(1), scope(2), scope(3)], elsewhere = scope(9)

        var random = SectionContentRandom(state: 0x180_B0C5)
        var failures: [String] = []
        var answers = 0, wrapping = 0, withheldAsPlaced = 0, withheldAsDisabled = 0, withheldByScope = 0
        for round in 0..<500 {
            // The earlier pass's boxes in source order, each a run of paragraphs, with prose between some.
            var anticipated: [Region] = [], end = 0
            for index in 0..<random.next(16) {
                let range = NSRange(location: end + (random.chance(2) ? 0 : random.next(80)), length: 1 + random.next(60))
                end = range.upperBound
                anticipated.append(Region(range: range, frame: CGRect(x: index, y: round, width: 60, height: 20), side: .none,
                                          wrapsEarlierText: !random.chance(5), scope: random.pick(scopes)))
                // No layout makes two regions of one range, but nothing in the type rules it out.
                if random.chance(12) {
                    anticipated.append(Region(range: range, frame: CGRect(x: index, y: -1, width: 60, height: 20), side: .left,
                                              wrapsEarlierText: random.chance(2), scope: random.pick(scopes)))
                }
            }
            // Boxes this pass leaves in flow: stretches of the text that cover a box, overlap
            // one, sit inside one, or only share an edge with one.
            var disabled: [NSRange] = []
            if round % 2 == 0 {
                for _ in 0..<random.next(5) {
                    guard let box = anticipated.isEmpty ? nil : random.pick(anticipated).range else { continue }
                    switch random.next(5) {
                    case 0: disabled.append(box)
                    case 1: disabled.append(NSRange(location: box.upperBound, length: random.next(30)))
                    case 2: disabled.append(NSRange(location: max(0, box.location - 10), length: min(10, box.location)))
                    case 3: disabled.append(NSRange(location: box.location + random.next(box.length), length: random.next(3)))
                    default: disabled.append(NSRange(location: random.next(end + 1), length: random.next(120)))
                    }
                }
            }
            // What this pass places: most of those boxes again, floats and inline boxes that were
            // never anticipated, and a line's range before an inline box, which can be anything.
            var order = anticipated.map(\.range).filter { _ in !random.chance(5) }
            for _ in 0..<random.next(6) { order.append(NSRange(location: random.next(end + 40), length: 1 + random.next(60))) }
            if let box = anticipated.first, random.chance(3) { order.append(box.range) }
            // The layout places in source order; the answers must not depend on it.
            if round % 3 == 0 {
                for index in order.indices.dropFirst().reversed() { order.swapAt(index, random.next(index + 1)) }
            } else { order.sort { $0.location < $1.location } }

            var pending = ReaderBoxLayout.Anticipation(anticipated, disabled: disabled)
            var placed: [Region] = []
            for step in 0...order.count {
                if step > 0 {
                    placed.append(Region(range: order[step - 1], frame: CGRect(x: 0, y: step, width: 60, height: 20), side: .left))
                    pending.place(order[step - 1])
                }
                let expected = unplaced(anticipated, among: placed)
                if described(pending.unplaced) != described(expected) {
                    failures.append("round \(round), \(step) placed: unplaced \(described(pending.unplaced)), not \(described(expected))")
                }
                for scope in scopes + [elsewhere] {
                    let expected = wrapped(anticipated, among: placed, disabled: disabled, scope: scope)
                    let answer = pending.unplaced(wrappingTextIn: scope)
                    if described(answer) != described(expected) {
                        failures.append("round \(round), \(step) placed, scope \(scope?.uuidString ?? "none"): \(described(answer)), not \(described(expected))")
                    }
                    answers += 1
                    if !expected.isEmpty { wrapping += 1 }
                    if wrapped(anticipated, among: [], disabled: disabled, scope: scope).count > expected.count { withheldAsPlaced += 1 }
                    if wrapped(anticipated, among: placed, disabled: [], scope: scope).count > expected.count { withheldAsDisabled += 1 }
                }
                if scopes.map({ wrapped(anticipated, among: placed, disabled: disabled, scope: $0).count }).filter({ $0 > 0 }).count > 1 { withheldByScope += 1 }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) answers differ: \(failures.prefix(2).joined(separator: "; "))")
        XCTAssertGreaterThan(answers, 20_000)
        XCTAssertGreaterThan(wrapping, answers / 5, "many answers name boxes")
        XCTAssertGreaterThan(withheldAsPlaced, 2_000, "many leave out a box already placed")
        XCTAssertGreaterThan(withheldAsDisabled, 500, "some leave out a box left in flow")
        XCTAssertGreaterThan(withheldByScope, 2_000, "and many tell the boxes of one scope from another's")

        // By hand: two boxes in one container and one in another; text outside both wraps ahead of neither.
        let first = Region(range: NSRange(location: 10, length: 5), frame: CGRect(x: 0, y: 0, width: 60, height: 20), side: .none, wrapsEarlierText: true, scope: scope(1))
        let second = Region(range: NSRange(location: 30, length: 5), frame: CGRect(x: 0, y: 40, width: 60, height: 20), side: .none, wrapsEarlierText: true, scope: scope(1))
        let third = Region(range: NSRange(location: 50, length: 5), frame: CGRect(x: 0, y: 80, width: 60, height: 20), side: .none, wrapsEarlierText: true, scope: scope(2))
        var pending = ReaderBoxLayout.Anticipation([first, second, third], disabled: [])
        XCTAssertEqual(pending.unplaced.map(\.range), [first.range, second.range, third.range])
        XCTAssertEqual(pending.unplaced(wrappingTextIn: scope(1)).map(\.range), [first.range, second.range])
        XCTAssertEqual(pending.unplaced(wrappingTextIn: nil).map(\.range), [])
        pending.place(first.range)
        XCTAssertEqual(pending.unplaced.map(\.range), [second.range, third.range])
        XCTAssertEqual(pending.unplaced(wrappingTextIn: scope(1)).map(\.range), [second.range])
        XCTAssertEqual(pending.unplaced(wrappingTextIn: scope(2)).map(\.range), [third.range])
        // A range that only overlaps a box's is another region: the box is still to come.
        pending.place(NSRange(location: 30, length: 4))
        XCTAssertEqual(pending.unplaced(wrappingTextIn: scope(1)).map(\.range), [second.range])
        // A box left in flow is still one for floats to keep clear of, as it was.
        var held = ReaderBoxLayout.Anticipation([first, second, third], disabled: [NSRange(location: 34, length: 30)])
        XCTAssertEqual(held.unplaced.map(\.range), [first.range, second.range, third.range])
        XCTAssertEqual(held.unplaced(wrappingTextIn: scope(1)).map(\.range), [first.range])
        XCTAssertEqual(held.unplaced(wrappingTextIn: scope(2)).map(\.range), [])
        var none = ReaderBoxLayout.Anticipation([], disabled: [NSRange(location: 0, length: 10)])
        XCTAssertTrue(none.unplaced.isEmpty); XCTAssertTrue(none.unplaced(wrappingTextIn: nil).isEmpty)
    }

    // MARK: Runs of containers

    private static let note = "P. Ordinary prose wraps beside the box and returns."
    private static let notes = ".rel { position:relative } aside { position:absolute; right:0; top:0; width:120px; height:50px }"

    /// Where each of `phrase`'s occurrences is in `section`, in order.
    private func occurrences(of phrase: String, in section: SectionText) -> [NSRange] {
        let text = section.string.string as NSString
        var ranges: [NSRange] = [], start = 0
        while start < text.length {
            let range = text.range(of: phrase, range: NSRange(location: start, length: text.length - start))
            guard range.location != NSNotFound else { break }
            ranges.append(range); start = range.upperBound
        }
        return ranges
    }

    /// A chapter of margin notes: `count` relative containers, each holding a paragraph and,
    /// written after it, a note positioned at the container's top-right corner, with a paragraph
    /// between one container and the next. A note's insets are measured from its own container
    /// (CSS 2.2 10.6.4), so where it stands depends on the containers above it and on nothing
    /// below: at the top of its paragraph's first line, 120 by 50 points, against the column's
    /// right edge. The paragraph written before it wraps beside it, and so does a separator that
    /// comes into its rows.
    @discardableResult
    private func assertNotesBesideTheirParagraphs(_ count: Int, paragraph: String = note,
                                                  file: StaticString = #filePath, line: UInt = #line) throws -> SectionText {
        let section = try H.build(String(repeating: "<div class='rel'><p>\(paragraph)</p><aside>A.</aside></div><p>Separator.</p>", count: count),
                                  css: H.reset + Self.notes)
        let resolved = ReaderBoxLayout.resolve(section.string, viewport: size)
        XCTAssertEqual(resolved.text.string, section.string.string, file: file, line: line)
        let plan = try XCTUnwrap(resolved.geometry, "\(count) containers have a plan", file: file, line: line)
        let notes = plan.regions.filter(\.wrapsEarlierText)
        XCTAssertEqual(notes.count, count, "every note keeps its region", file: file, line: line)
        let boxes = occurrences(of: "A.", in: section), paragraphs = occurrences(of: paragraph, in: section)
        let separators = occurrences(of: "Separator.", in: section)
        XCTAssertEqual(boxes.count, count, file: file, line: line); XCTAssertEqual(paragraphs.count, count, file: file, line: line)
        for (index, note) in notes.enumerated() where index < count {
            let label = "note \(index + 1) of \(count)"
            XCTAssertGreaterThan(NSIntersectionRange(note.range, boxes[index]).length, 0, label, file: file, line: line)
            let lines = plan.paragraph(at: paragraphs[index].location)?.lines ?? []
            let top = try XCTUnwrap(lines.first?.frame.minY, label, file: file, line: line)
            XCTAssertEqual(note.frame.minY, top, accuracy: 0.5, "\(label) stands at its container's top", file: file, line: line)
            XCTAssertEqual(note.frame.minX, size.width - 120, accuracy: 1, label, file: file, line: line)
            XCTAssertEqual(note.frame.width, 120, accuracy: 1, label, file: file, line: line)
            XCTAssertEqual(note.frame.height, 50, accuracy: 1, label, file: file, line: line)
            let following = plan.paragraph(at: separators[index].location)?.lines ?? []
            let beside = (lines + following).filter { $0.frame.minY < note.frame.maxY - 0.5 && $0.frame.maxY > note.frame.minY + 0.5 }
            XCTAssertGreaterThanOrEqual(beside.count, 2, "\(label) has its paragraph's lines beside it", file: file, line: line)
            XCTAssertTrue(beside.allSatisfy { $0.frame.maxX <= note.frame.minX + 0.5 }, "\(label) has the text beside it keep clear of it",
                          file: file, line: line)
        }
        return section
    }

    /// The issue's chapter (#209). Each paragraph is one line across the column and two beside its
    /// note, so it is taller in the pass that knows of the note than in the pass that placed it,
    /// and every container below it stands lower. Each pass found the right place for a few more
    /// notes than the pass before, and with no more passes to make, twelve containers had every
    /// note left in flow and eight were placed. With a paragraph twice as long, six were placed
    /// and twelve were not.
    func testEveryNoteInALongRunOfRelativeContainersIsPlaced() throws {
        try assertNotesBesideTheirParagraphs(8)
        let section = try assertNotesBesideTheirParagraphs(12)
        try assertNotesBesideTheirParagraphs(12, paragraph: "P. Ordinary prose wraps beside the box and returns. Ordinary prose wraps beside the box again.")
        // The layout sets the lines where the plan has them and pages every character.
        let measured = try XCTUnwrap(BoxPlanAgreementTests.disagreement(section, viewport: size))
        XCTAssertGreaterThan(measured.compared, 24)
        XCTAssertLessThan(measured.worst, 0.75, "the plan puts every line where the layout does: \(measured.at)")
        H.pages(section, size: size)
    }

    /// A few hundred: the chapter is longer than many pages, and every note is still placed.
    func testEveryNoteInHundredsOfRelativeContainersIsPlaced() throws {
        try assertNotesBesideTheirParagraphs(300)
    }
}
