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
        let environment = ProcessInfo.processInfo.environment
        // Attach to a fresh, normally launched reader; do not relaunch it.
        let app = XCUIApplication(bundleIdentifier: "org.epubreaderlib.voiceoververify.mac")
        let snapshots = environment["VOICEOVER_SNAPSHOTS"] != nil
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
        #if os(macOS)
        if snapshots {
            app.activate()
            guard app.buttons["Close"].waitForExistence(timeout: 20) else {
                XCTFail("The bundled synthetic EPUB must be open")
                return
            }
        }
        #else
        guard app.buttons["Close"].waitForExistence(timeout: 20) else {
            XCTFail("The bundled synthetic EPUB must be open")
            return
        }
        #endif
        var events: [[String: String]] = []
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func note(_ command: String, _ text: String) {
            let time = clock.string(from: Date())
            events.append(["command": command, "utterance": text, "time": time])
            print("VOICEOVER_EVENT \(time) \(command): \(text)")
        }
        func record(_ command: String, _ output: XCUIVoiceOverService.Output) { note(command, output.utterance) }
        defer {
            let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
            attach(data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]", name: "VoiceOver speech")
        }
        #if os(macOS)
        // The outer runner sends the VoiceOver commands while this records. XCTest's own
        // synthesized VoiceOver keys return about ten seconds later, when a delayed hint may
        // have replaced the phrase they produced.
        let deadline = Date().addingTimeInterval(300)
        var heard = "", shown = ""
        note("recording", snapshots ? "speech and XCTest values" : "speech")
        repeat {
            if snapshots {
                // XCTest's own snapshot, for comparison with fresh external reads and speech.
                let columns = app.textViews.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
                let values = columns.map { column in
                    let words = (column.value as? String ?? "").split { !$0.isLetter && !$0.isNumber }
                    return "\(words.first ?? "")…\(words.last ?? "") (\(words.count) words)"
                }.joined(separator: " | ")
                if values != shown {
                    shown = values
                    print("MAC_COLUMN_COUNT=\(columns.count)")
                    note("xctestValues", values)
                }
            }
            let speech: String
            do { speech = try voiceOver.currentSpeech().utterance } catch { speech = "ERROR \((error as NSError).code)" }
            if speech != heard {
                heard = speech
                note("heard", speech)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline && !FileManager.default.fileExists(atPath: environment["VOICEOVER_STOP"] ?? "")
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
