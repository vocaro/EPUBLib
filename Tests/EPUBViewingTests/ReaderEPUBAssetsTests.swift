#if DEBUG
import XCTest
@testable import EPUBViewing

final class ReaderEPUBAssetsTests: XCTestCase {
    func testTheStaticImportGraphIsClosedFromTheBootstrapDown() {
        XCTAssertEqual(
            ReaderEPUBAssets.unsatisfiedStaticImports, [],
            "something the prototype loads imports a file the bundle does not carry")
        for edge in ReaderEPUBAssets.bootstrapStaticImports {
            XCTAssertTrue(
                ReaderEPUBAssets.servableLibraryPaths.contains(edge),
                "bootstrap.js imports \(edge), which the scheme handler will not serve")
        }
    }

    func testTheExcludedFilesAreReachableOnlyThroughDynamicImports() {
        let excluded = Set(ReaderEPUBAssets.excluded.map(\.path))
        for file in ReaderEPUBAssets.vendored {
            let statics = Set(file.staticImports.map {
                ReaderEPUBAssets.resolve($0, from: file.path)
            })
            XCTAssertTrue(
                statics.isDisjoint(with: excluded),
                "\(file.path) statically imports an excluded file")
        }
    }

    func testViewIsTheOnlyFileWithDynamicEdgesOutOfTheBundle() {
        let vendored = ReaderEPUBAssets.servableLibraryPaths
        for file in ReaderEPUBAssets.vendored where file.path != "view.js" {
            let dynamics = Set(file.dynamicImports.map {
                ReaderEPUBAssets.resolve($0, from: file.path)
            })
            XCTAssertTrue(
                dynamics.isSubset(of: vendored),
                "\(file.path) can import outside the bundle")
        }
        let view = ReaderEPUBAssets.vendored.first { $0.path == "view.js" }
        XCTAssertNotNil(view)
        for excluded in ReaderEPUBAssets.excluded {
            XCTAssertTrue(
                view?.dynamicImports.contains(excluded.path) == true,
                "\(excluded.path) is excluded but is not a recorded view.js dynamic import")
        }
    }

    func testEveryManifestEntryIsUniqueSafeAndPinned() {
        var seen = Set<String>()
        for file in ReaderEPUBAssets.vendored {
            XCTAssertTrue(seen.insert(file.path).inserted, "duplicate manifest path \(file.path)")
            XCTAssertFalse(file.path.hasPrefix("/"), "\(file.path) is not relative")
            XCTAssertFalse(file.path.contains(".."), "\(file.path) traverses")
            XCTAssertEqual(file.blobSHA1.count, 40, "\(file.path) has no 40-character blob sha")
            XCTAssertTrue(
                file.blobSHA1.allSatisfy(\.isHexDigit), "\(file.path)'s sha is not hexadecimal")
            XCTAssertEqual(
                file.blobSHA1, file.blobSHA1.lowercased(), "\(file.path)'s sha is not normalised")
        }
        XCTAssertTrue(
            seen.isDisjoint(with: Set(ReaderEPUBAssets.excluded.map(\.path))),
            "a file is both vendored and excluded")
    }

    func testEachLicenceTextIsVendoredWithTheCodeItCovers() {
        for notice in ["LICENSE", "vendor/zip.js.LICENSE.txt"] {
            XCTAssertTrue(
                ReaderEPUBAssets.servableLibraryPaths.contains(notice),
                "the app redistributes the code \(notice) covers, so it must carry it")
        }
    }

    func testTheUpstreamPinIsAFullCommitSHA() {
        XCTAssertEqual(ReaderEPUBAssets.upstreamCommit.count, 40)
        XCTAssertTrue(ReaderEPUBAssets.upstreamCommit.allSatisfy(\.isHexDigit))
    }


    func testMissingFilesNamesEveryAbsentAsset() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            ReaderEPUBAssets.missingFiles(under: root),
            ReaderEPUBAssets.vendored.map(\.path).sorted(),
            "an empty directory is missing everything")

        for file in ReaderEPUBAssets.vendored {
            let url = root.appending(path: file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        XCTAssertEqual(ReaderEPUBAssets.missingFiles(under: root), [])

        try FileManager.default.removeItem(at: root.appending(path: "vendor/zip.js"))
        XCTAssertEqual(ReaderEPUBAssets.missingFiles(under: root), ["vendor/zip.js"])
    }

    func testImportsResolveRelativeToTheImportingFile() {
        XCTAssertEqual(ReaderEPUBAssets.resolve("epubcfi.js", from: "view.js"), "epubcfi.js")
        XCTAssertEqual(
            ReaderEPUBAssets.resolve("epubcfi.js", from: "vendor/zip.js"), "vendor/epubcfi.js")
    }
}
#endif
