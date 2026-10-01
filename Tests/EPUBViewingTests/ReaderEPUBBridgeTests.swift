#if DEBUG
import XCTest
@testable import EPUBViewing

final class ReaderEPUBBridgeTests: XCTestCase {
    static let cfi = "epubcfi(/6/14[chapter-two]!/4/2/10,/1:0,/1:64)"


    func testAWellFormedRelocationDecodes() throws {
        let message = try ReaderEPUBMessageDecoder.decode([
            "type": "relocated", "cfi": Self.cfi, "sectionIndex": 2,
            "fraction": 0.25, "sectionTitle": "Second section",
        ] as [String: Any])
        XCTAssertEqual(message, .relocated(ReaderEPUBLocation(
            cfi: Self.cfi, sectionIndex: 2, fraction: 0.25, sectionTitle: "Second section")))
    }

    func testAnAbsentOrNullFractionAndTitleAreCarriedAsAbsent() throws {
        let withoutOptionals = try ReaderEPUBMessageDecoder.decode([
            "type": "relocated", "cfi": Self.cfi, "sectionIndex": 0,
        ] as [String: Any])
        let withNulls = try ReaderEPUBMessageDecoder.decode([
            "type": "relocated", "cfi": Self.cfi, "sectionIndex": 0,
            "fraction": NSNull(), "sectionTitle": NSNull(),
        ] as [String: Any])
        XCTAssertEqual(withoutOptionals, withNulls)
        XCTAssertEqual(withoutOptionals, .relocated(ReaderEPUBLocation(
            cfi: Self.cfi, sectionIndex: 0, fraction: nil, sectionTitle: nil)))
    }

    func testARelocationWithoutALocatorIsStillAPosition() throws {
        let message = try ReaderEPUBMessageDecoder.decode([
            "type": "relocated", "cfi": NSNull(), "sectionIndex": 4, "fraction": 0.5,
        ] as [String: Any])
        XCTAssertEqual(message, .relocated(ReaderEPUBLocation(
            cfi: nil, sectionIndex: 4, fraction: 0.5, sectionTitle: nil)))
        XCTAssertEqual(
            try ReaderEPUBMessageDecoder.decode([
                "type": "relocated", "sectionIndex": 4, "fraction": 0.5,
            ] as [String: Any]),
            message)
    }

    func testAnEmptyLocatorIsNotAWayToSayAbsent() {
        XCTAssertThrowsError(try ReaderEPUBMessageDecoder.decode([
            "type": "relocated", "cfi": "", "sectionIndex": 0,
        ] as [String: Any])) { error in
            XCTAssertEqual(error as? ReaderEPUBMessageError, .malformedCFI)
        }
    }

    func testAPresentButMalformedLocatorIsStillRefusedOnARelocation() {
        XCTAssertThrowsError(try ReaderEPUBMessageDecoder.decode([
            "type": "relocated", "cfi": "epubcfi(/6/4\u{2028})", "sectionIndex": 0,
        ] as [String: Any])) { error in
            XCTAssertEqual(error as? ReaderEPUBMessageError, .malformedCFI)
        }
    }

    func testASelectionStillRequiresItsLocator() {
        XCTAssertThrowsError(try ReaderEPUBMessageDecoder.decode([
            "type": "selected", "text": "the critical angle of attack",
        ] as [String: Any])) { error in
            XCTAssertEqual(error as? ReaderEPUBMessageError, .missingField("cfi"))
        }
    }

    func testASelectionDecodesWithItsLocator() throws {
        let message = try ReaderEPUBMessageDecoder.decode([
            "type": "selected", "cfi": Self.cfi, "text": "the critical angle of attack",
        ] as [String: Any])
        XCTAssertEqual(message, .selected(ReaderEPUBSelection(
            cfi: Self.cfi, text: "the critical angle of attack")))
    }

    func testReadyCarriesEveryDisclosedCount() throws {
        XCTAssertEqual(
            try ReaderEPUBMessageDecoder.decode([
                "type": "ready", "sectionCount": 3, "scriptResourcesRefused": 2,
                "remoteHintsRemoved": 1, "lateRemoteHints": 0,
            ] as [String: Any]),
            .ready(ReaderEPUBReadiness(
                sectionCount: 3, scriptResourcesRefused: 2,
                remoteHintsRemoved: 1, lateRemoteHints: 0)))
    }

    func testEveryDisclosedCountIsRequiredRatherThanDefaultedToZero() {
        let complete: [String: Any] = [
            "type": "ready", "sectionCount": 3, "scriptResourcesRefused": 0,
            "remoteHintsRemoved": 0, "lateRemoteHints": 0,
        ]
        for field in ["sectionCount", "scriptResourcesRefused", "remoteHintsRemoved",
                      "lateRemoteHints"] {
            var object = complete
            object[field] = nil
            XCTAssertThrowsError(try ReaderEPUBMessageDecoder.decode(object)) { error in
                XCTAssertEqual(error as? ReaderEPUBMessageError, .missingField(field))
            }
        }
    }

    func testAPageNoticeIsItsOwnMessageAndNotAFailure() throws {
        XCTAssertEqual(
            try ReaderEPUBMessageDecoder.decode([
                "type": "notice", "detail": "getCFI threw on a stale range",
            ] as [String: Any]),
            .pageNotice("getCFI threw on a stale range"))
        XCTAssertThrowsError(
            try ReaderEPUBMessageDecoder.decode(["type": "notice"] as [String: Any])
        ) { error in
            XCTAssertEqual(error as? ReaderEPUBMessageError, .missingField("detail"))
        }
    }


    func testAWholeDocumentDisclosesNothing() {
        XCTAssertNil(ReaderEPUBDisclosure.text(for: ReaderEPUBReadiness(
            sectionCount: 12, scriptResourcesRefused: 0,
            remoteHintsRemoved: 0, lateRemoteHints: 0)))
    }

    func testEachKindOfDiminishmentIsSaidOutLoudAndCountsAgree() throws {
        let scripts = try XCTUnwrap(ReaderEPUBDisclosure.text(for: ReaderEPUBReadiness(
            sectionCount: 12, scriptResourcesRefused: 1,
            remoteHintsRemoved: 0, lateRemoteHints: 0)))
        XCTAssertEqual(scripts, "One interactive part of this document was not run.")

        let both = try XCTUnwrap(ReaderEPUBDisclosure.text(for: ReaderEPUBReadiness(
            sectionCount: 12, scriptResourcesRefused: 3,
            remoteHintsRemoved: 2, lateRemoteHints: 0)))
        XCTAssertTrue(both.contains("3 interactive parts"))
        XCTAssertTrue(both.contains("2 connections"))

        let late = try XCTUnwrap(ReaderEPUBDisclosure.text(for: ReaderEPUBReadiness(
            sectionCount: 12, scriptResourcesRefused: 0,
            remoteHintsRemoved: 0, lateRemoteHints: 1)))
        XCTAssertTrue(late.contains("may have contacted a server"))
    }


    func testANonObjectBodyIsRefused() {
        for body in ["relocated", 7, [1, 2, 3]] as [Any] {
            XCTAssertThrowsError(try ReaderEPUBMessageDecoder.decode(body)) { error in
                XCTAssertEqual(error as? ReaderEPUBMessageError, .notAnObject)
            }
        }
    }

    func testAnUnknownTypeIsRefusedRatherThanIgnored() {
        XCTAssertThrowsError(
            try ReaderEPUBMessageDecoder.decode(["type": "evaluate", "js": "1"] as [String: Any])
        ) { error in
            XCTAssertEqual(error as? ReaderEPUBMessageError, .unknownType("evaluate"))
        }
    }

    func testAMissingFieldIsNamed() {
        XCTAssertThrowsError(
            try ReaderEPUBMessageDecoder.decode(["type": "relocated", "cfi": Self.cfi])
        ) { error in
            XCTAssertEqual(error as? ReaderEPUBMessageError, .missingField("sectionIndex"))
        }
    }

    func testABooleanIsNotAnIndex() {
        XCTAssertThrowsError(try ReaderEPUBMessageDecoder.decode([
            "type": "relocated", "cfi": Self.cfi, "sectionIndex": true,
        ] as [String: Any])) { error in
            XCTAssertEqual(error as? ReaderEPUBMessageError, .wrongType(field: "sectionIndex"))
        }
    }

    func testANumericIndexOfZeroOrOneIsNotMistakenForABoolean() throws {
        for index in [NSNumber(value: 0), NSNumber(value: 1), NSNumber(value: 2)] {
            let message = try ReaderEPUBMessageDecoder.decode([
                "type": "relocated", "cfi": Self.cfi, "sectionIndex": index,
            ] as [String: Any])
            XCTAssertEqual(message, .relocated(ReaderEPUBLocation(
                cfi: Self.cfi, sectionIndex: index.intValue, fraction: nil, sectionTitle: nil)))
        }
    }

    func testAGenuineNSNumberBooleanIsStillNotAnIndex() {
        for boolean in [NSNumber(value: true), NSNumber(value: false)] {
            XCTAssertThrowsError(try ReaderEPUBMessageDecoder.decode([
                "type": "relocated", "cfi": Self.cfi, "sectionIndex": boolean,
            ] as [String: Any])) { error in
                XCTAssertEqual(error as? ReaderEPUBMessageError, .wrongType(field: "sectionIndex"))
            }
        }
    }

    func testAFractionOfExactlyZeroOrOneIsNotMistakenForABoolean() throws {
        for fraction in [NSNumber(value: 0.0), NSNumber(value: 1.0)] {
            let message = try ReaderEPUBMessageDecoder.decode([
                "type": "relocated", "cfi": Self.cfi, "sectionIndex": 0, "fraction": fraction,
            ] as [String: Any])
            XCTAssertEqual(message, .relocated(ReaderEPUBLocation(
                cfi: Self.cfi, sectionIndex: 0, fraction: fraction.doubleValue, sectionTitle: nil)))
        }
    }

    func testAReadyMessageWithGenuineNSNumberZerosDecodes() throws {
        let message = try ReaderEPUBMessageDecoder.decode([
            "type": "ready", "sectionCount": NSNumber(value: 3),
            "scriptResourcesRefused": NSNumber(value: 0),
            "remoteHintsRemoved": NSNumber(value: 0), "lateRemoteHints": NSNumber(value: 0),
        ] as [String: Any])
        XCTAssertEqual(message, .ready(ReaderEPUBReadiness(
            sectionCount: 3, scriptResourcesRefused: 0, remoteHintsRemoved: 0,
            lateRemoteHints: 0)))
    }

    func testIndicesOutsideTheirBoundsAreRefusedRatherThanClamped() {
        for index in [-1, 100_001] {
            XCTAssertThrowsError(try ReaderEPUBMessageDecoder.decode([
                "type": "relocated", "cfi": Self.cfi, "sectionIndex": index,
            ] as [String: Any])) { error in
                XCTAssertEqual(error as? ReaderEPUBMessageError, .outOfBounds(field: "sectionIndex"))
            }
        }
        XCTAssertThrowsError(try ReaderEPUBMessageDecoder.decode([
            "type": "relocated", "cfi": Self.cfi, "sectionIndex": 1.5,
        ] as [String: Any]))
    }

    func testFractionsOutsideZeroToOneAndNonFiniteOnesAreRefused() {
        for fraction in [-0.001, 1.001, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try ReaderEPUBMessageDecoder.decode([
                "type": "relocated", "cfi": Self.cfi, "sectionIndex": 0, "fraction": fraction,
            ] as [String: Any]), "accepted fraction \(fraction)")
        }
    }

    func testAnOversizedSelectionIsRefusedWholeRatherThanTruncated() {
        let text = String(repeating: "a", count: ReaderEPUBMessageDecoder.maximumSelectionLength + 1)
        XCTAssertThrowsError(try ReaderEPUBMessageDecoder.decode([
            "type": "selected", "cfi": Self.cfi, "text": text,
        ] as [String: Any])) { error in
            XCTAssertEqual(error as? ReaderEPUBMessageError, .outOfBounds(field: "text"))
        }
        XCTAssertNoThrow(try ReaderEPUBMessageDecoder.decode([
            "type": "selected", "cfi": Self.cfi, "text": String(text.dropLast()),
        ] as [String: Any]))
    }

    func testAWhitespaceOnlySelectionIsNotAPassage() {
        XCTAssertThrowsError(try ReaderEPUBMessageDecoder.decode([
            "type": "selected", "cfi": Self.cfi, "text": "  \n\t ",
        ] as [String: Any]))
    }


    func testWellFormedLocatorsAreAccepted() {
        for cfi in [
            "epubcfi(/6/4!/4/10/2:3)",
            Self.cfi,
            "epubcfi(/6/14[chap%2Dtwo]!/4/2/10)",
            "epubcfi(/6/4!/4,/2/2:0,/6/2:12)",
        ] {
            XCTAssertTrue(ReaderEPUBCFI.isWellFormed(cfi), "rejected \(cfi)")
        }
    }

    func testTheLocatorsFoliateEmitsForRealBooksAreAccepted() {
        for cfi in [
            "epubcfi(/6/14[capítulo1]!/4/2/10:3)",
            "epubcfi(/6/14[第二章]!/4/2/10)",
            "epubcfi(/6/14[глава-2]!/4/2/10)",
            "epubcfi(/6/14[note^(2^)]!/4/2/10)",
            "epubcfi(/6/14[a^(b]!/4/2/10)",
            "epubcfi(/6/4!/4/2/1:5[;s=a])",
            "epubcfi(/6/4!/4,/2/1:0[pre,post;s=b],/2/1:10)",
            "epubcfi(/6/14[a^[b^]c^,d^;e^=f]!/4/2/10)",
            "epubcfi(/6/14[a^^b]!/4/2/10)",
            "epubcfi(/6/14[o'brien]!/4/2/10)",
            "epubcfi(/6/14[a\"b]!/4/2/10)",
            "epubcfi(/6/14[ch3&note]!/4/2/10)",
            "epubcfi(/6/14[{§3}]!/4/2/10)",
        ] {
            XCTAssertTrue(ReaderEPUBCFI.isWellFormed(cfi), "rejected \(cfi)")
        }
    }

    func testTheCharacterFloorAndTheShapeChecksStillHold() {
        for cfi in [
            "epubcfi(/6/4\u{0085})",
            "epubcfi(/6/4\u{009C})",
            "epubcfi(/6/14[a\u{2028}b]!/4/2/10)",
            "epubcfi(/6/14[a\u{2029}b]!/4/2/10)",
            "epubcfi(/6/4\u{0000})",
            "epubcfi(/6/4\u{001B})",
            "epubcfi(/6/4\u{007F})",
            "epubcfi(/6/4^)",
            "epubcfi(/6/4[a^)",
            "epubcfi(/6/4^(()",
            "epubcfi(/6/4^())))",
        ] {
            XCTAssertFalse(ReaderEPUBCFI.isWellFormed(cfi), "accepted \(cfi.debugDescription)")
        }
    }

    func testAWrapperThatClosesEarlyIsRefused() {
        for cfi in [
            "epubcfi(/6/4)(x)",
            "epubcfi(/6/4)(/2)",
            "epubcfi(/6/4!/4/2/1:5[;s=a])()",
            "epubcfi(/6/4)^)",
        ] {
            XCTAssertFalse(ReaderEPUBCFI.isWellFormed(cfi), "accepted \(cfi.debugDescription)")
            XCTAssertThrowsError(try ReaderEPUBCommand.goTo(cfi: cfi).javaScript()) { error in
                XCTAssertEqual(error as? ReaderEPUBMessageError, .malformedCFI)
            }
        }
    }

    func testALocatorCarryingQuotesAndBackslashesRoundTripsAsData() throws {
        for cfi in [
            "epubcfi(/6/14[o'brien]!/4/2/10)",
            "epubcfi(/6/14[a\"b]!/4/2/10)",
            "epubcfi(/6/14[a\\b]!/4/2/10)",
            "epubcfi(/6/4!/4/2/1:5[;s=a])",
            "epubcfi(/6/14[<b>]!/4/2/10)",
        ] {
            XCTAssertTrue(ReaderEPUBCFI.isWellFormed(cfi), "rejected \(cfi)")
            XCTAssertEqual(
                try decodedArgument(of: .goTo(cfi: cfi)),
                ["command": "goTo", "cfi": cfi],
                "\(cfi) did not survive the encoder as data")
        }
    }

    func testEscapesDoNotDefeatTheLengthBound() {
        let long = "epubcfi(" + String(repeating: "^a", count: ReaderEPUBCFI.maximumLength) + ")"
        XCTAssertFalse(ReaderEPUBCFI.isWellFormed(long))
    }

    func testValuesThatAreNotShapedLikeALocatorAreRefused() {
        for cfi in [
            "",
            "/6/4!/4/10/2:3",
            "epubcfi()",
            "epubcfi(/6/4",
            "epubcfi(/6/4))",
            "epubcfi(/6/4!/4);alert(1)//)",
            "epubcfi(/6/4\"});alert(1)//)",
            "epubcfi(/6/4\n)",
            "epubcfi(/6/4\u{2028})",
            "epubcfi(" + String(repeating: "/2", count: 1_024) + ")",
        ] {
            XCTAssertFalse(ReaderEPUBCFI.isWellFormed(cfi), "accepted \(cfi.debugDescription)")
        }
    }

    func testAMalformedLocatorNeverReachesTheHostAsALocation() {
        XCTAssertThrowsError(try ReaderEPUBMessageDecoder.decode([
            "type": "relocated", "cfi": "epubcfi(/6/4);fetch('https://x')//)",
            "sectionIndex": 0,
        ] as [String: Any])) { error in
            XCTAssertEqual(error as? ReaderEPUBMessageError, .malformedCFI)
        }
    }


    func testACommandIsJSONAtItsCallSiteRatherThanInterpolatedText() throws {
        let javaScript = try ReaderEPUBCommand.goTo(cfi: Self.cfi).javaScript()
        XCTAssertTrue(javaScript.hasPrefix("\(ReaderEPUBCommand.entryPoint)("))
        XCTAssertTrue(javaScript.hasSuffix(")"))
        XCTAssertFalse(javaScript.contains("\n"))
        XCTAssertEqual(
            try decodedArgument(of: .goTo(cfi: Self.cfi)),
            ["command": "goTo", "cfi": Self.cfi])
    }

    private func decodedArgument(of command: ReaderEPUBCommand) throws -> [String: String] {
        let javaScript = try command.javaScript()
        let opening = "\(ReaderEPUBCommand.entryPoint)("
        XCTAssertTrue(javaScript.hasPrefix(opening), "\(javaScript) is not one call")
        XCTAssertTrue(javaScript.hasSuffix(")"), "\(javaScript) is not one call")
        let argument = javaScript.dropFirst(opening.count).dropLast()
        let decoded = try JSONSerialization.jsonObject(with: Data(argument.utf8))
        return try XCTUnwrap(decoded as? [String: String], "the argument is not a JSON object")
    }

    func testAQueryCarryingQuotesAndBackslashesIsEscapedRatherThanRefused() throws {
        let javaScript = try ReaderEPUBCommand.search(query: "he said \"stall\" \\ then").javaScript()
        XCTAssertTrue(javaScript.contains("\\\"stall\\\""))
        XCTAssertTrue(javaScript.contains("\\\\"))
        XCTAssertFalse(javaScript.contains("\" \\ "))
    }

    func testAMalformedLocatorIsRefusedBeforeItBecomesJavaScript() {
        for command in [
            ReaderEPUBCommand.goTo(cfi: "epubcfi(/6/4));alert(1)//("),
            ReaderEPUBCommand.select(cfi: "not a cfi"),
        ] {
            XCTAssertThrowsError(try command.javaScript()) { error in
                XCTAssertEqual(error as? ReaderEPUBMessageError, .malformedCFI)
            }
        }
    }

    func testAnEmptyOrOversizedQueryIsRefused() {
        XCTAssertThrowsError(try ReaderEPUBCommand.search(query: "").javaScript())
        XCTAssertThrowsError(try ReaderEPUBCommand.search(
            query: String(repeating: "a", count: ReaderEPUBCommand.maximumQueryLength + 1)
        ).javaScript())
    }

    func testClearSearchNeedsNoArgumentAndStillEncodesAsACommand() throws {
        XCTAssertEqual(
            try ReaderEPUBCommand.clearSearch.javaScript(),
            "\(ReaderEPUBCommand.entryPoint)({\"command\":\"clearSearch\"})")
    }


    private func decodedLocateArgument(
        of command: ReaderEPUBCommand
    ) throws -> (command: String, quote: String, highlight: Bool) {
        let javaScript = try command.javaScript()
        let opening = "\(ReaderEPUBCommand.entryPoint)("
        XCTAssertTrue(javaScript.hasPrefix(opening), "\(javaScript) is not one call")
        XCTAssertTrue(javaScript.hasSuffix(")"), "\(javaScript) is not one call")
        let argument = javaScript.dropFirst(opening.count).dropLast()
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(argument.utf8)) as? [String: Any])
        return (
            command: try XCTUnwrap(decoded["command"] as? String),
            quote: try XCTUnwrap(decoded["quote"] as? String),
            highlight: try XCTUnwrap(decoded["highlight"] as? Bool))
    }

    func testALocateCommandCarriesTheQuoteAndHighlightFlagAsData() throws {
        let highlighted = try decodedLocateArgument(
            of: .locate(quote: "a whole retrieved chunk of text", highlight: true))
        XCTAssertEqual(highlighted.command, "locate")
        XCTAssertEqual(highlighted.quote, "a whole retrieved chunk of text")
        XCTAssertTrue(highlighted.highlight)

        let unhighlighted = try decodedLocateArgument(
            of: .locate(quote: "a chapter's own retained text", highlight: false))
        XCTAssertFalse(unhighlighted.highlight)
    }

    func testALocateQuoteCarryingQuotesAndBackslashesIsEscapedRatherThanRefused() throws {
        let javaScript = try ReaderEPUBCommand.locate(
            quote: "he said \"stall\" \\ then", highlight: true).javaScript()
        XCTAssertTrue(javaScript.contains("\\\"stall\\\""))
        XCTAssertTrue(javaScript.contains("\\\\"))
    }

    func testAnEmptyOrOversizedLocateQuoteIsRefused() {
        XCTAssertThrowsError(try ReaderEPUBCommand.locate(quote: "", highlight: true).javaScript())
        XCTAssertThrowsError(try ReaderEPUBCommand.locate(
            quote: String(
                repeating: "a", count: ReaderEPUBCommand.maximumLocateQueryLength + 1),
            highlight: true
        ).javaScript())
    }


    func testPageTurnCommandsNeedNoArgumentAndStillEncodeAsCommands() throws {
        XCTAssertEqual(
            try ReaderEPUBCommand.nextPage.javaScript(),
            "\(ReaderEPUBCommand.entryPoint)({\"command\":\"nextPage\"})")
        XCTAssertEqual(
            try ReaderEPUBCommand.previousPage.javaScript(),
            "\(ReaderEPUBCommand.entryPoint)({\"command\":\"previousPage\"})")
    }

    func testTheLocateBoundIsWiderThanTheSearchBound() {
        XCTAssertGreaterThan(
            ReaderEPUBCommand.maximumLocateQueryLength, ReaderEPUBCommand.maximumQueryLength)
    }


    func testASetStyleCommandCarriesTheCSSAsData() throws {
        let css = ReaderEPUBTypography.css(fontSizePoints: 19, isDark: false)
        XCTAssertEqual(
            try decodedArgument(of: .setStyle(css: css)),
            ["command": "setStyle", "css": css])
    }

    func testAnOversizedStyleIsRefused() {
        XCTAssertThrowsError(try ReaderEPUBCommand.setStyle(
            css: String(repeating: "a", count: ReaderEPUBCommand.maximumStyleLength + 1)
        ).javaScript())
    }

    func testAnEmptyStyleIsAccepted() throws {
        XCTAssertNoThrow(try ReaderEPUBCommand.setStyle(css: "").javaScript())
    }

    func testTypographyCSSSetsTheRequestedSizeInPixels() {
        let css = ReaderEPUBTypography.css(fontSizePoints: 21, isDark: false)
        XCTAssertTrue(css.contains("font-size:21px"), css)
        XCTAssertFalse(css.contains("background"), "a light-appearance style forces no colors")
    }

    func testTypographyCSSDropsATrailingWholeNumberFraction() {
        XCTAssertFalse(
            ReaderEPUBTypography.css(fontSizePoints: 17, isDark: false).contains("17.0"))
    }

    func testTypographyCSSClampsToTheDeclaredRange() {
        let tooSmall = ReaderEPUBTypography.css(fontSizePoints: 1, isDark: false)
        XCTAssertTrue(tooSmall.contains(
            "font-size:\(Int(ReaderEPUBTypography.minimumFontSizePoints))px"), tooSmall)
        let tooLarge = ReaderEPUBTypography.css(fontSizePoints: 1_000, isDark: false)
        XCTAssertTrue(tooLarge.contains(
            "font-size:\(Int(ReaderEPUBTypography.maximumFontSizePoints))px"), tooLarge)
    }

    func testTypographyCSSForcesColorsOnlyInDarkAppearance() {
        let light = ReaderEPUBTypography.css(fontSizePoints: 17, isDark: false)
        let dark = ReaderEPUBTypography.css(fontSizePoints: 17, isDark: true)
        XCTAssertFalse(light.contains("background"))
        XCTAssertTrue(dark.contains("background"))
        XCTAssertTrue(dark.contains("color-scheme:dark"))
    }

    func testTypographyCSSNamesExactlyOneColorScheme() {
        let light = ReaderEPUBTypography.css(fontSizePoints: 17, isDark: false)
        let dark = ReaderEPUBTypography.css(fontSizePoints: 17, isDark: true)
        XCTAssertTrue(light.contains("color-scheme:light"), light)
        XCTAssertFalse(light.contains("color-scheme:light dark"), light)
        XCTAssertFalse(light.contains("color-scheme:dark"), light)
        XCTAssertTrue(dark.contains("color-scheme:dark"), dark)
        XCTAssertFalse(dark.contains("color-scheme:light dark"), dark)
        XCTAssertFalse(dark.contains("color-scheme:light}"), dark)
    }

    func testTypographyCSSNeverInvertsOrRecolorsImages() {
        let dark = ReaderEPUBTypography.css(fontSizePoints: 17, isDark: true)
        XCTAssertFalse(dark.contains("filter"), dark)
        XCTAssertFalse(dark.contains("invert"), dark)
        XCTAssertFalse(dark.contains("mix-blend-mode"), dark)
        XCTAssertFalse(dark.contains("img"), dark)
        XCTAssertFalse(dark.contains("svg"), dark)
    }

    func testTypographyCSSTargetsOnlyTheRootElementsNeverEverySelector() {
        let dark = ReaderEPUBTypography.css(fontSizePoints: 17, isDark: true)
        XCTAssertFalse(dark.contains("*{"), dark)
        XCTAssertFalse(dark.contains("* {"), dark)
        XCTAssertTrue(dark.contains("html,body{background:Canvas!important;color:CanvasText!important}"), dark)
        XCTAssertTrue(dark.contains("a,a:link,a:visited{color:LinkText!important}"), dark)
    }


    func testASetFlowCommandCarriesTheRawValueAsData() throws {
        XCTAssertEqual(
            try decodedArgument(of: .setFlow(.scrolled)),
            ["command": "setFlow", "flow": "scrolled"])
        XCTAssertEqual(
            try decodedArgument(of: .setFlow(.paginated)),
            ["command": "setFlow", "flow": "paginated"])
    }

    func testASetFlowCommandNeverThrows() {
        XCTAssertNoThrow(try ReaderEPUBCommand.setFlow(.scrolled).javaScript())
        XCTAssertNoThrow(try ReaderEPUBCommand.setFlow(.paginated).javaScript())
    }
}
#endif
