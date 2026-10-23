import EPUBCore
import Foundation
import XCTest

/// `EPUBLicense`: the license and notice texts a host shows, read from EPUBCore's resource bundle
/// as an app carries it (#699). scripts/check-licenses.py holds the texts to the pinned projects'.
final class PackageLicenseTests: XCTestCase {
    func testEveryLicenseAndNoticeTheProductsRequireIsInTheBundle() throws {
        let licenses = try EPUBLicense.all()
        XCTAssertEqual(licenses.first?.id, "EPUBLib/LICENSE")
        XCTAssertTrue(try licenses.first?.text().hasPrefix("MIT License\n\nCopyright (c) 2026 Vocaro Technologies LLC") == true)
        XCTAssertEqual(Set(licenses.map(\.component)), ["EPUBLib", "foliate-js", "MathMLLayout", "StaticSVG", "ZIPFoundation"])
        XCTAssertEqual(licenses.map(\.id), licenses.map(\.id).sorted { $0.lowercased() < $1.lowercased() })
        XCTAssertEqual(Set(licenses.map(\.id)).count, licenses.count)
        var texts: [String: String] = [:]
        for license in licenses {
            XCTAssertEqual(license.url.lastPathComponent, license.path.split(separator: "/").last.map(String.init))
            texts[license.id] = try license.text()
            XCTAssertFalse(texts[license.id]!.isEmpty, license.id)
        }
        // MathMLLayout's notices name the five files an app must include.
        for name in ["LICENSE.txt", "THIRD_PARTY_NOTICES.md", "MathCAT-MIT.txt", "SRE-Apache-2.0.txt", "SRE-NOTICE.txt"] {
            XCTAssertNotNil(texts["MathMLLayout/\(name)"], name)
        }
        XCTAssertTrue(texts["ZIPFoundation/LICENSE"]?.contains("Copyright (c) 2017-2025 Thomas Zoechling") == true)
        XCTAssertTrue(texts["foliate-js/LICENSE"]?.contains("Copyright (c) 2022 John Factotum") == true)
        // StaticSVG's inventory names every text of resvg and each crate it depends on.
        struct Crate: Decodable { let name: String; let texts: [String] }
        let crates = try JSONDecoder().decode([Crate].self, from: Data(try XCTUnwrap(texts["StaticSVG/dependencies.json"]).utf8))
        XCTAssertTrue(crates.contains { $0.name == "resvg" })
        for crate in crates {
            XCTAssertFalse(crate.texts.isEmpty, crate.name)
            for text in crate.texts { XCTAssertNotNil(texts["StaticSVG/\(text)"], text) }
        }
        XCTAssertTrue(texts.keys.contains { $0.hasPrefix("StaticSVG/Licenses/rust-") && $0.hasSuffix("/COPYRIGHT-library.html") })
        XCTAssertNotNil(texts["StaticSVG/LICENSE.txt"])
    }
}
