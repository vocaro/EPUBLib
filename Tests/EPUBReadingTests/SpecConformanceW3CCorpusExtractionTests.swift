import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBText
import Foundation
import XCTest

/// The W3C reading-system test suite through headless text extraction, the half of the corpus run
/// the viewer's test target cannot reach (`SpecConformanceW3CCorpusTests` builds the sections).
/// Skipped unless `EPUBLIB_W3C_EPUB_TESTS` names the suite's `tests` directory.
final class SpecConformanceW3CCorpusExtractionTests: XCTestCase {
    private typealias Corpus = SpecConformanceCorpus

    func testEverySpineDocumentIsExtractedOrRefusedWithItsTypedError() throws {
        guard let root = ProcessInfo.processInfo.environment[Corpus.environmentKey] else {
            throw XCTSkip("Set \(Corpus.environmentKey) to the tests directory of w3c/epub-tests")
        }
        let directories = try Corpus.testDirectories(under: URL(fileURLWithPath: root))
        XCTAssertFalse(directories.isEmpty, "No test directories under \(root)")
        var extracted = 0, refused = 0
        for (id, url) in directories {
            let expectation = Corpus.expectation(for: id)
            let publication: EPUBPublication
            do { publication = try EPUBPublication.open(data: Corpus.archive(ofExpandedEPUBAt: url)) }
            catch {
                // The viewer's run holds the refusal to its expectation.
                XCTAssertNotNil(expectation.refused, "\(id) could not be opened: \(error)")
                continue
            }
            for index in publication.spine.indices {
                let resource = publication.spine[index].resource
                do {
                    let section = try publication.textSection(at: index)
                    extracted += 1
                    XCTAssertEqual(section.resource, resource, id)
                    XCTAssertEqual(section.isLinear, publication.spine[index].isLinear, id)
                    XCTAssertFalse(expectation.withheld.contains(index) || expectation.recovered.contains(index),
                                   "\(id) section \(index) was expected to be refused")
                    for case .rendered(index, let phrase) in expectation.checks where resource.mediaType == "application/xhtml+xml" {
                        // A manifest fallback stands in for a scripted document only in a renderer.
                        guard !resource.properties.contains("scripted") else { continue }
                        XCTAssertTrue(section.text.contains(phrase), "\(id) section \(index) lacks \(phrase.debugDescription): \(section.text.prefix(160))")
                    }
                } catch let error as EPUBTextExtractionError {
                    refused += 1
                    switch error {
                    case .unsupportedMediaType(let type):
                        // doc/text-extraction.md: "other spine media types fail explicitly".
                        XCTAssertEqual(type, resource.mediaType, id)
                        XCTAssertNotEqual(type, "application/xhtml+xml", id)
                    case .malformedContent(let path):
                        // Entity declarations and markup that is not well-formed fail by default.
                        XCTAssertEqual(path, resource.path, id)
                        XCTAssertTrue(expectation.withheld.contains(index) || expectation.recovered.contains(index),
                                      "\(id) section \(index) is refused as malformed: \(resource.path)")
                    default: XCTFail("\(id) section \(index): \(error)")
                    }
                } catch { XCTFail("\(id) section \(index): \(error)") }
            }
        }
        print("W3C epub-tests: \(extracted) spine documents extracted, \(refused) refused with a typed error")
    }
}
