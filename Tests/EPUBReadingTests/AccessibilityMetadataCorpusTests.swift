import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// Text that marks a package document as carrying accessibility metadata, or mentioning its
/// vocabulary: the `schema:access…` properties, `dcterms:conformsTo` and the `a11y:` prefix.
private func mentionsAccessibility(_ text: String) -> Bool {
    ["schema:access", "dcterms:conformsTo", "a11y:"].contains { text.contains($0) }
}

/// Accessibility metadata in EPUBCheck's fixtures (#676): every fixture whose package document
/// mentions it is read and compared with what it declares. Skipped unless
/// `EPUBLIB_EPUBCHECK_FIXTURES` is set (doc/testing.md).
final class EPUBCheckCorpusAccessibilityMetadataTests: XCTestCase {
    private static func link(_ string: String) -> EPUBMetadataValue { EPUBMetadataValue(string, isLink: true) }

    /// What each EPUBCheck fixture that mentions it reads as, by its path under
    /// `src/test/resources` at the commit `scripts/fetch-corpora.sh` pins.
    private static let epubCheck: [String: EPUBAccessibilityMetadata] = {
        let tableOfContents = EPUBAccessibilityMetadata(features: ["tableOfContents"])
        let testers = EPUBAccessibilityCertifier(name: "Accessibility Testers Group")
        var expected: [String: EPUBAccessibilityMetadata] = [
            // A credential as a link, which EPUBCheck allows though §3.5.3.3 writes text.
            "epub-accessibility/files/link-rel-a11y-certifierCredential-valid.opf":
                EPUBAccessibilityMetadata(certifierCredentials: [link("https://example.com/a11y/credential")]),
            // `a11y:contactEmail` and `a11y:exemption` are not read (doc/architecture.md).
            "epub-accessibility/files/metadata-a11y-contactEmail-valid.opf": EPUBAccessibilityMetadata(conformance: [EPUBConformanceClaim("none")]),
            "epub-accessibility/files/metadata-a11y-exemption-valid.opf": EPUBAccessibilityMetadata(conformance: [EPUBConformanceClaim("none")]),
            // The evaluator, its credential and its report, none refining another, with the prefix
            // left undeclared, as EPUB Accessibility 1.1 allows.
            "epub-accessibility/files/property-prefix-a11y-not-declared-valid.opf": EPUBAccessibilityMetadata(
                certifiers: [testers], certifierCredentials: ["DAISY OK"], certifierReports: [link("http://example.org/report")]),
            // `a11y:boo` and `a11y:certifierreport` are no properties EPUB Accessibility defines.
            "epub-accessibility/files/property-prefix-a11y-unknown-value-error.opf": EPUBAccessibilityMetadata(),
            "epub3/test-files-unused/vocab-a11y-credentials-in-link.opf": EPUBAccessibilityMetadata(
                certifiers: [testers], certifierCredentials: [link("https://example.com/a11y/credential")],
                certifierReports: [link("http://example.org/report")]),
            // Prefix declarations, and accessibility metadata in a collection's own `metadata`,
            // which is not the package's.
            "epub3/05-package-document/files/prefix-mapping-reserved-valid.opf": EPUBAccessibilityMetadata(),
            "epub3/05-package-document/files/prefix-reserved-overridden-warning.opf": EPUBAccessibilityMetadata(),
            "epub-distributable-objects/files/package-document/do-collection-valid.opf": EPUBAccessibilityMetadata(),
            "epub-distributable-objects/files/package-document/do-collection-metadata-identifier-missing-error.opf": EPUBAccessibilityMetadata(),
            // EDUPUB requires a feature; this one's is a comment, and this one's is `none`.
            "epub-edupub/files/package-document/edupub-metadata-accessibilityFeature-missing-error.opf": EPUBAccessibilityMetadata(),
            "epub-edupub/files/package-document/edupub-metadata-accessibilityFeature-none-error.opf": EPUBAccessibilityMetadata(features: ["none"]),
        ]
        for name in ["edupub-minimal-valid", "edupub-metadata-type-missing-error", "edupub-teacher-edition-minimal-valid",
                     "edupub-teacher-edition-metadata-source-missing-warning", "edupub-teacher-edition-metadata-type-missing-error"] {
            expected["epub-edupub/files/package-document/\(name).opf"] = tableOfContents
        }
        // Whole publications, each read from the package document its container names first.
        for name in ["edupub-basic-valid", "edupub-fxl-valid", "edupub-microdata-warning", "edupub-multiple-renditions-valid",
                     "edupub-multiple-renditions-dctype-missing-for-publication-error",
                     "edupub-multiple-renditions-dctype-missing-for-rendition-error", "edupub-non-linear-valid",
                     "edupub-pagelist-missing-error", "edupub-pagelist-no-source-error", "edupub-pagelist-valid"] {
            expected["epub-edupub/files/epub/\(name)"] = tableOfContents
        }
        return expected
    }()

    func testEveryEPUBCheckFixtureWithAccessibilityMetadataReadsAsItDeclares() throws {
        guard let root = EPUBCheckCorpus.root() else {
            throw XCTSkip("Set \(EPUBCheckCorpus.environmentKey) to src/test/resources of an EPUBCheck checkout")
        }
        var found: [String: Data] = [:]
        // A packed `.epub` is held to declaring none: none at the pinned commit does.
        var packed: [String: Data] = [:]
        for item in EPUBCheckCorpus.publications(under: root) {
            guard item.isDirectory else { packed[item.path] = try Data(contentsOf: item.url); continue }
            let packages = EPUBCheckCorpus.files(under: item.url).filter { $0.url.pathExtension.lowercased() == "opf" }
            if try packages.contains(where: { mentionsAccessibility(String(decoding: try Data(contentsOf: $0.url), as: UTF8.self)) }) {
                found[item.path] = try EPUBCheckCorpus.archive(of: item)
            }
        }
        for item in EPUBCheckCorpus.documents(under: root, extensions: ["opf"]) {
            let opf = try Data(contentsOf: item.url)
            if mentionsAccessibility(String(decoding: opf, as: UTF8.self)) {
                found[item.path] = EPUBCheckCorpus.container(aroundPackageDocument: opf)
            }
        }
        XCTAssertEqual(Set(found.keys), Set(Self.epubCheck.keys), "The fixtures that mention accessibility metadata")
        var read = 0
        for (path, archive) in found.sorted(by: { $0.key < $1.key }) {
            guard let expected = Self.epubCheck[path] else { continue }
            do {
                XCTAssertEqual(try EPUBPublication.open(data: archive).metadata.accessibility, expected, path)
                read += 1
            } catch { XCTFail("\(path) did not open: \(error)") }
        }
        XCTAssertEqual(read, Self.epubCheck.count)
        XCTAssertFalse(packed.isEmpty)
        for (path, archive) in packed {
            guard let publication = try? EPUBPublication.open(data: archive) else { continue }
            XCTAssertEqual(publication.metadata.accessibility, EPUBAccessibilityMetadata(), path)
        }
    }
}

/// The W3C reading-system tests declare no accessibility metadata (#676). Skipped unless
/// `EPUBLIB_W3C_EPUB_TESTS` is set (doc/testing.md).
final class SpecConformanceW3CCorpusAccessibilityMetadataTests: XCTestCase {
    func testNoW3CReadingSystemTestDeclaresAccessibilityMetadata() throws {
        guard let root = ProcessInfo.processInfo.environment[SpecConformanceCorpus.environmentKey] else {
            throw XCTSkip("Set \(SpecConformanceCorpus.environmentKey) to the tests directory of w3c/epub-tests")
        }
        // At the commit `scripts/fetch-corpora.sh` pins, w3c/epub-tests has no package with
        // accessibility metadata. One that gains some fails here until its expectation is written.
        let directories = try SpecConformanceCorpus.testDirectories(under: URL(fileURLWithPath: root))
        XCTAssertFalse(directories.isEmpty, "No test directories under \(root)")
        var opened = 0
        for (id, url) in directories {
            let files = try SpecConformanceCorpus.files(ofExpandedEPUBAt: url)
            let packages = files.filter { $0.key.lowercased().hasSuffix(".opf") }
            XCTAssertFalse(packages.contains { mentionsAccessibility(String(decoding: $0.value, as: UTF8.self)) }, id)
            guard let publication = try? EPUBPublication.open(data: Fixture.archive(files)) else { continue }
            XCTAssertEqual(publication.metadata.accessibility, EPUBAccessibilityMetadata(), id)
            opened += 1
        }
        XCTAssertGreaterThan(opened, 0)
    }
}
