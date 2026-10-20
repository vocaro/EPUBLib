import Foundation
import XCTest
@testable import EPUBViewing

final class SVGImagePreparationTests: XCTestCase {
    private func image(_ value: UInt8 = 1, pixels: Int = 1, report: SectionReport = SectionReport()) -> SVGImagePreparation.Image {
        .init(data: Data([value]), pixels: pixels, report: report)
    }

    /// Exercises the actual shared request/candidate memoization used by serialization, with
    /// a deterministic preparation callback. No SVG renderer or exponential probe is involved.
    func testSevenLevelTenWayDAGPreparesEachArchiveImageOnce() throws {
        let context = SVGImagePreparation()
        var built: [String: Int] = [:]
        func prepare(_ depth: Int, ancestors: Set<String>, bytes: Int = 1024, pixels: Int = 1024) -> SVGImagePreparation.Image? {
            let path = "level\(depth).svg"
            return context.request(at: path, ancestors: ancestors, fonts: [:], maximumBytes: bytes, maximumPixels: pixels) {
                context.image(at: path, ancestors: ancestors, fonts: [:], maximumBytes: bytes, maximumPixels: pixels,
                    load: { Data([UInt8(depth)]) }) { _ in
                    built[path, default: 0] += 1
                    guard context.consumeSerializedBytes(1), context.reserveRasterPixels(1) else { return nil }
                    if depth > 0 {
                        for index in 0..<10 {
                            guard prepare(depth - 1, ancestors: ancestors.union([path]), bytes: 1024 - index, pixels: 1024 - index) != nil else { return nil }
                        }
                    }
                    return self.image(UInt8(depth))
                }
            }
        }
        XCTAssertNotNil(prepare(7, ancestors: []))
        XCTAssertEqual(built.count, 8)
        XCTAssertTrue(built.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(context.visits, 16, "eight chain requests plus eight distinct candidate preparations")
        XCTAssertEqual(context.cacheHits, 63)
    }

    func testAncestorCyclesAndDepthDoNotCallTheExpensivePreparation() {
        let context = SVGImagePreparation()
        var calls = 0
        let cycle = context.image(at: "a.svg", ancestors: ["a.svg"], fonts: [:], maximumBytes: 1024, maximumPixels: 1024,
                                  load: { Data([1]) }) { _ in calls += 1; return self.image() }
        XCTAssertNil(cycle)
        let deep = context.image(at: "a.svg", ancestors: Set((0..<8).map { "level\($0)" }), fonts: [:], maximumBytes: 1024, maximumPixels: 1024,
                                 load: { Data([1]) }) { _ in calls += 1; return self.image() }
        XCTAssertNil(deep)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(context.visits, 0)
    }

    func testFontAndAncestorContextsAreSeparateAndCachedReportsReplayExactly() {
        let context = SVGImagePreparation()
        var calls = 0
        func prepare(_ fonts: [String: String], _ ancestors: Set<String>) -> SVGImagePreparation.Image? {
            context.image(at: "a.svg", ancestors: ancestors, fonts: fonts, maximumBytes: 1024, maximumPixels: 1024,
                          load: { Data([1]) }) { _ in
                calls += 1
                var report = SectionReport(); report.unsupportedElements["svg:image"] = 2
                return self.image(report: report)
            }
        }
        let first = prepare(["source": "alias1"], [])
        let repeated = prepare(["source": "alias1"], [])
        XCTAssertNotNil(prepare(["source": "alias2"], []))
        XCTAssertNotNil(prepare(["source": "alias1"], ["parent.svg"]))
        XCTAssertEqual(calls, 3)
        let report = SectionReportBox()
        SVGImagePreparation.replay(first!.report, into: report)
        SVGImagePreparation.replay(repeated!.report, into: report)
        XCTAssertEqual(report.report.unsupportedElements["svg:image"], 4)
    }

    func testSourceVisitSerializationPixelAndCacheBudgetsStopBeforeMoreWork() {
        var limits = SVGImagePreparation.Limits(); limits.visits = 1; limits.sourceBytes = 1
        limits.serializedBytes = 1; limits.rasterPixels = 1; limits.cachedBytes = 1
        let context = SVGImagePreparation(limits: limits)
        var calls = 0
        XCTAssertNotNil(context.image(at: "one", ancestors: [], fonts: [:], maximumBytes: 10, maximumPixels: 10,
                                      load: { Data([1]) }) { _ in calls += 1; return self.image() })
        XCTAssertNil(context.image(at: "two", ancestors: [], fonts: [:], maximumBytes: 10, maximumPixels: 10,
                                   load: { XCTFail("visit cap must precede load"); return Data([1]) }) { _ in calls += 1; return self.image() })
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(context.consumeSerializedBytes(1)); XCTAssertFalse(context.consumeSerializedBytes(1))
        XCTAssertTrue(context.reserveRasterPixels(1)); XCTAssertFalse(context.reserveRasterPixels(1))
        XCTAssertNotNil(context.image(at: "one", ancestors: [], fonts: [:], maximumBytes: 10, maximumPixels: 10,
                                      load: { XCTFail("memo must precede load"); return nil }) { _ in XCTFail(); return nil })
        var sourceLimits = limits; sourceLimits.visits = 10; sourceLimits.sourceBytes = 0
        let source = SVGImagePreparation(limits: sourceLimits)
        XCTAssertNil(source.image(at: "x", ancestors: [], fonts: [:], maximumBytes: 10, maximumPixels: 10,
                                  load: { Data([1]) }) { _ in XCTFail("input cap must precede preparation"); return nil })
        var cacheLimits = limits; cacheLimits.cachedBytes = 0
        let cache = SVGImagePreparation(limits: cacheLimits)
        XCTAssertNil(cache.image(at: "x", ancestors: [], fonts: [:], maximumBytes: 10, maximumPixels: 10,
                                 load: { Data([1]) }) { _ in self.image() })
    }

    func testTightParentCapDoesNotPoisonLaterRequestsAndIntrinsicFailuresAreMemoized() {
        let context = SVGImagePreparation()
        var calls = 0
        func prepared(_ maximum: Int) -> SVGImagePreparation.Image? {
            context.image(at: "x", ancestors: [], fonts: [:], maximumBytes: 1024, maximumPixels: maximum,
                          load: { Data([1]) }) { _ in
                calls += 1
                guard maximum >= 10 else { context.refuse(); return nil }
                return self.image(pixels: 10)
            }
        }
        XCTAssertNil(prepared(1)); XCTAssertNotNil(prepared(20)); XCTAssertNil(prepared(1))
        XCTAssertEqual(calls, 2)
        for _ in 0..<2 {
            XCTAssertNil(context.image(at: "bad", ancestors: [], fonts: [:], maximumBytes: 1024, maximumPixels: 1024,
                                      load: { Data([1]) }) { _ in calls += 1; return nil })
        }
        XCTAssertEqual(calls, 3)
    }

    func testCancellationStopsLoadsAndCachedResultsAndAmplifiedReportsStayRepresentable() {
        var cancelled = false
        let context = SVGImagePreparation(cancelled: { cancelled })
        XCTAssertNotNil(context.image(at: "x", ancestors: [], fonts: [:], maximumBytes: 1024, maximumPixels: 1024,
                                      load: { Data([1]) }) { _ in self.image() })
        cancelled = true
        XCTAssertNil(context.image(at: "x", ancestors: [], fonts: [:], maximumBytes: 1024, maximumPixels: 1024,
                                   load: { XCTFail(); return nil }) { _ in XCTFail(); return nil })
        XCTAssertNil(context.request(at: "new", ancestors: [], fonts: [:], maximumBytes: 1024, maximumPixels: 1024) { XCTFail(); return nil })
        let report = SectionReportBox()
        var huge = SectionReport(); huge.unsupportedElements["svg:image"] = Int.max
        SVGImagePreparation.replay(huge, into: report)
        SVGImagePreparation.replay(huge, into: report)
        XCTAssertEqual(report.report.unsupportedElements["svg:image"], SVGImagePreparation.maximumReportCount)
        report.report.unsupportedElements["svg:image", default: 0] += 1
        XCTAssertGreaterThan(report.report.unsupportedElements["svg:image"]!, SVGImagePreparation.maximumReportCount)
    }
}
