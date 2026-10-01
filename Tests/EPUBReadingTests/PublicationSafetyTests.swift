import EPUBCore
import EPUBReading
import EPUBText
import EPUBTestSupport
import Foundation
import XCTest
import ZIPFoundation

final class PublicationSafetyTests: XCTestCase {
    private func damagedArchive(_ transform: (Archive) throws -> Void) throws -> Data {
        let archive = try Archive(data: Fixture.epub(), accessMode: .update)
        try transform(archive)
        return try XCTUnwrap(archive.data)
    }

    func testDuplicateEntryIsRejected() throws {
        let bytes = try damagedArchive { archive in
            try archive.addEntry(with: "OPS/one.xhtml", type: .file, uncompressedSize: Int64(1)) { _, _ in Data([0]) }
        }
        XCTAssertThrowsError(try EPUBPublication.open(data: bytes)) {
            guard case .invalidArchive(let reason) = $0 as? EPUBPublicationError else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("Duplicate"))
        }
    }

    func testSymlinkIsRejectedWithoutFollowingTarget() throws {
        let bytes = try damagedArchive { archive in
            let target = Data("../../outside".utf8)
            try archive.addEntry(with: "OPS/link", type: .symlink, uncompressedSize: Int64(target.count)) { offset, size in
                target.subdata(in: Int(offset)..<(Int(offset) + size))
            }
        }
        XCTAssertThrowsError(try EPUBPublication.open(data: bytes)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath("OPS/link"))
        }
    }

    func testStoredPayloadCorruptionFailsCRCBeforeParsing() throws {
        var bytes = try Fixture.epub()
        // The first stored entry is mimetype. Change its data, leaving ZIP checksums untouched.
        let marker = try XCTUnwrap(bytes.range(of: Data("application/epub+zip".utf8)))
        bytes[marker.lowerBound] ^= 1
        XCTAssertThrowsError(try EPUBPublication.open(data: bytes)) {
            guard case .invalidArchive(let reason) = $0 as? EPUBPublicationError else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("CRC"))
        }
    }

    func testDeepXMLAndWideXMLAreRejected() throws {
        for xml in [String(repeating: "<x>", count: 65) + String(repeating: "</x>", count: 65),
                    "<x>" + String(repeating: "<y/>", count: 100_001) + "</x>"] {
            XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/nav.xhtml": xml]))) {
                XCTAssertEqual($0 as? EPUBPublicationError, .invalidXML("OPS/nav.xhtml"))
            }
        }
    }

    func testUTF16NavigationAndEntityRejection() throws {
        var files = try Fixture.files()
        let ordinary = "<?xml version='1.0' encoding='UTF-16'?><html xmlns:epub='http://www.idpf.org/2007/ops'><nav epub:type='toc'><ol><li><a href='one.xhtml'>日本語</a></li></ol></nav></html>"
        files["OPS/nav.xhtml"] = try XCTUnwrap(ordinary.data(using: .utf16))
        XCTAssertEqual(try EPUBPublication.open(data: Fixture.archive(files)).tableOfContents.first?.title, "日本語")
        let hostile = "<?xml version='1.0' encoding='UTF-16'?><!DOCTYPE html [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><html>&x;</html>"
        files["OPS/nav.xhtml"] = try XCTUnwrap(hostile.data(using: .utf16))
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.archive(files)))
    }

    func testFontObfuscationMatchesIndependentKnownVectors() throws {
        // SHA-1('test-book'), independently reproducible with `printf test-book | shasum`.
        let idpfKey: [UInt8] = [0x35, 0x3f, 0x85, 0x83, 0x14, 0x98, 0xd7, 0xc5, 0x88, 0x9e,
                              0xff, 0x84, 0x22, 0xb1, 0x73, 0x61, 0xc1, 0x42, 0xbf, 0x54]
        try checkFont(algorithm: "http://www.idpf.org/2008/embedding", identifier: "test-book",
                      key: idpfKey, prefix: 1040)
        try checkFont(algorithm: "http://ns.adobe.com/pdf/enc#RC",
                      identifier: "urn:uuid:00112233-4455-6677-8899-aabbccddeeff",
                      key: Array(stride(from: UInt8(0x00), through: UInt8(0xff), by: 0x11)), prefix: 1024)
    }

    private func checkFont(algorithm: String, identifier: String, key: [UInt8], prefix: Int) throws {
        var files = try Fixture.files()
        files["OPS/book.opf"] = Data(String(decoding: files["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: ">test-book<", with: ">\(identifier)<").utf8)
        let original = Data((0..<1100).map { UInt8($0 % 251) })
        var obfuscated = original
        for i in 0..<prefix { obfuscated[i] ^= key[i % key.count] }
        files["OPS/font.otf"] = obfuscated
        files["META-INF/encryption.xml"] = Data("<encryption><EncryptedData><EncryptionMethod Algorithm='\(algorithm)'/><CipherData><CipherReference URI='OPS/font.otf'/></CipherData></EncryptedData></encryption>".utf8)
        let archive = try Fixture.archive(files)
        let publication = try EPUBPublication.open(data: archive)
        XCTAssertEqual(try publication.data(at: "OPS/font.otf"), original)
        XCTAssertEqual(publication.archiveData, archive)
    }

    func testLimitsRejectInvalidValuesAndAllowExactBoundaries() throws {
        let files = try Fixture.files()
        let bytes = try Fixture.archive(files)
        var limits = EPUBImportLimits()
        limits.archiveBytes = bytes.count
        limits.expandedBytes = files.values.reduce(0) { $0 + $1.count }
        limits.resourceBytes = files.values.map(\.count).max()!
        limits.entryCount = files.count
        _ = try EPUBPublication.open(data: bytes, limits: limits)
        limits.expandedBytes -= 1
        XCTAssertThrowsError(try EPUBPublication.open(data: bytes, limits: limits))
        for value in [0, -1, Int.min] {
            limits = EPUBImportLimits(); limits.entryCount = value
            XCTAssertThrowsError(try EPUBPublication.open(data: bytes, limits: limits))
        }
    }

    func testCancellationAfterExpansionStartsReturnsNoPublication() async throws {
        let bytes = try Fixture.epub(overrides: ["OPS/payload": String(repeating: "x", count: 131_072)])
        let task = Task.detached {
            try EPUBPublication.open(data: bytes, onProgress: { expanded in
                if expanded > 32_768 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await task.value; XCTFail("Cancelled expansion returned a publication") }
        catch is CancellationError {}
    }
}
