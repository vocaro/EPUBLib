import XCTest
import XCUIAutomation

/// Diagnostic speech capture. A passing probe does not satisfy the acceptance matrix.
@MainActor final class VoiceOverProbe: XCTestCase {
    func testCaptureNavigation() throws {
        let voiceOver = XCUIDevice.shared.voiceOverService
        let wasEnabled = voiceOver.isEnabled
        #if os(macOS)
        // The outer runner owns the Mac toggle and restoration, including timeouts.
        guard wasEnabled else { throw XCTSkip("Run with scripts/run-voiceover-mac.py") }
        let app = XCUIApplication(bundleIdentifier: "org.epubreaderlib.voiceoververify.mac")
        app.activate() // Attach to a fresh, normally launched reader; do not relaunch it.
        #else
        defer {
            if !wasEnabled && voiceOver.isEnabled {
                do { try voiceOver.disable() }
                catch { XCTFail("VoiceOver restoration failed: \(error)") }
            }
        }
        if !wasEnabled { try voiceOver.enable() }
        let app = XCUIApplication(bundleIdentifier: "org.epubreaderlib.voiceoververify")
        app.launchArguments = ["-SampleFlow", "paginated"]
        app.launch()
        #endif
        guard app.buttons["Close"].waitForExistence(timeout: 20) else {
            XCTFail("The bundled synthetic EPUB must be open")
            return
        }
        var events: [[String: String]] = []
        func record(_ command: String, _ output: XCUIVoiceOverService.Output) {
            events.append(["command": command, "utterance": output.utterance])
            print("VOICEOVER_EVENT \(command): \(output.utterance)")
        }
        defer {
            let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
            attach(data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]", name: "VoiceOver speech")
        }
        #if os(macOS)
        let columns = app.textViews.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
        guard let column = columns.last else { XCTFail("No reading column"); return }
        print("MAC_COLUMN_COUNT=\(columns.count)")
        attach(column.value as? String ?? "", name: "Initial column accessibility value")
        // Stay outside the 56-point page-turn edge zones; record the current line
        // before advancing, so a one-word first line is not silently skipped by the probe.
        column.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        column.typeKey(.downArrow, modifierFlags: [.control, .option, .shift])
        record("interact", try voiceOver.currentSpeech())
        column.typeKey("l", modifierFlags: [.control, .option])
        record("currentLineAfterEntry", try voiceOver.currentSpeech())
        column.typeKey(.downArrow, modifierFlags: [.control, .option])
        record("nextLine", try voiceOver.currentSpeech())
        column.typeKey(.end, modifierFlags: [.control, .option])
        record("endOfText", try voiceOver.currentSpeech())
        column.typeKey("l", modifierFlags: [.control, .option])
        record("currentLineAtEnd", try voiceOver.currentSpeech())
        column.typeKey(.downArrow, modifierFlags: [.control, .option])
        record("attemptBeyondPage", try voiceOver.currentSpeech())
        #else
        record("initial", try voiceOver.currentSpeech())
        var repeated = 0
        for _ in 0..<100 {
            let speech = try voiceOver.moveForward()
            repeated = speech.utterance == events.last?["utterance"] ? repeated + 1 : 0
            record("moveForward", speech)
            if repeated >= 3 { break }
        }
        #endif
    }

    private func attach(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
