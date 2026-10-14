import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing

final class NativeParserPreflightSafetyTests: XCTestCase {
    func testNativeXMLAndHTMLRefuseAttributeFanoutBeforeParsing() {
        let attributes = (0...XMLSafety.attributesPerElement).map { " a\($0)='v'" }.joined()
        for source in ["<html xmlns='http://www.w3.org/1999/xhtml'><body><p\(attributes)>text</p></body></html>",
                       "<html><body><p\(attributes)>text</wrong></html>"] {
            XCTAssertThrowsError(try ContentDocument.parse(Data(source.utf8), path: "chapter.xhtml")) {
                XCTAssertEqual($0 as? ContentDocumentError, .limitExceeded("attributesPerElement"))
            }
        }
    }

    func testNativeRefusesEncodedDeclarationsBeforeStrictOrRecoveryParsing() {
        let utf7 = Data("<?xml version='1.0' encoding='UTF-7'?>+ADw-!DOCTYPE html [+ADw-!ENTITY y 'z'>]><html><body>&y;</body></html>".utf8)
        XCTAssertThrowsError(try ContentDocument.parse(utf7, path: "chapter.xhtml")) {
            XCTAssertEqual($0 as? ContentDocumentError, .unsafeMarkup("chapter.xhtml"))
        }
    }
}
