import XCTest
import XCUIAutomation

/// Diagnostic speech capture. A passing probe does not satisfy the acceptance matrix.
@MainActor final class VoiceOverProbe: XCTestCase {
    func testCaptureNavigation() throws {
        let voiceOver = XCUIDevice.shared.voiceOverService
        let wasEnabled = voiceOver.isEnabled
        let environment = ProcessInfo.processInfo.environment
        #if os(macOS)
        // The outer runner owns the Mac toggle and restoration, including timeouts.
        guard wasEnabled else { throw XCTSkip("Run with scripts/run-voiceover-mac.py") }
        // Attach to a fresh, normally launched reader; do not relaunch it. Unless asked for its
        // snapshots, never query it: XCTest's Automation Running banner would then take the
        // VoiceOver cursor whenever the runner types.
        let app = XCUIApplication(bundleIdentifier: "org.epubreaderlib.voiceoververify.mac")
        let snapshots = environment["VOICEOVER_SNAPSHOTS"] != nil
        if snapshots { app.activate() }
        #else
        defer {
            if !wasEnabled && voiceOver.isEnabled {
                do { try voiceOver.disable() }
                catch { XCTFail("VoiceOver restoration failed: \(error)") }
            }
        }
        // `VOICEOVER_OFF` runs the same steps as plain touches, to tell a VoiceOver failure
        // from one of the reader's own.
        if !wasEnabled, environment["VOICEOVER_OFF"] == nil { try voiceOver.enable() }
        let app = XCUIApplication(bundleIdentifier: "org.epubreaderlib.voiceoververify")
        // `VOICEOVER_FLOW=scrolled` opens the book in continuous scroll.
        app.launchArguments = ["-SampleFlow", environment["VOICEOVER_FLOW"] ?? "paginated"]
        if let size = environment["VOICEOVER_FONT_SIZE"] { app.launchArguments += ["-SampleFontSize", size] }
        // A section other than the first, such as the fixture's hidden labels (`OPS/labels.xhtml`).
        if let href = environment["VOICEOVER_HREF"] { app.launchArguments += ["-SampleHref", href] }
        app.launch()
        let snapshots = true
        #endif
        guard !snapshots || app.buttons["Close"].waitForExistence(timeout: 20) else {
            XCTFail("The bundled synthetic EPUB must be open")
            return
        }
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
                    note("xctestValues", values)
                }
            }
            // No speech is evidence too: `ERROR 3` is `XCUIVoiceOverService.Error.noSpeech`.
            let speech: String
            do { speech = try voiceOver.currentSpeech().utterance } catch { speech = "ERROR \((error as NSError).code)" }
            if speech != heard {
                heard = speech
                note("heard", speech)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline && !FileManager.default.fileExists(atPath: environment["VOICEOVER_STOP"] ?? "")
        #else
        // `TEST_RUNNER_VOICEOVER_STEPS` replaces the default forward reading from the first item;
        // see doc/voiceover-testing.md.
        func heard(_ command: String) {
            note(command, (try? voiceOver.currentSpeech().utterance) ?? "no speech")
        }
        note("voiceOver", wasEnabled ? "was already on" : voiceOver.isEnabled ? "turned on for this session" : "left off")
        heard("initial")
        for step in (environment["VOICEOVER_STEPS"] ?? "read").split(separator: ",").map(String.init) {
            let parts = step.split(separator: "=", maxSplits: 1).map(String.init)
            // Another session's app in front would be read and touched instead of the reader.
            guard app.state == .runningForeground else {
                note(step, "STOPPED: the reader is no longer in the foreground")
                XCTFail("The reader lost the foreground before \(step)")
                return
            }
            switch parts[0] {
            case "read":
                // Forward until VoiceOver repeats itself at the end of the screen.
                var repeated = 0
                for _ in 0..<150 {
                    let speech = try voiceOver.moveForward()
                    repeated = speech.utterance == events.last?["utterance"] ? repeated + 1 : 0
                    record("moveForward", speech)
                    if repeated >= 3 { break }
                }
            case "visible":
                // The numbered lines XCTest sees in each column, to compare with the speech.
                var lines: [(label: String, frame: CGRect)] = []
                func collect(_ element: any XCUIElementSnapshot) {
                    if element.label.contains("word0") || element.label.contains("word1") { lines.append((element.label, element.frame)) }
                    element.children.forEach(collect)
                }
                collect(try app.snapshot())
                let window = app.windows.firstMatch.frame.size
                note("visible", "window \(Int(window.width))x\(Int(window.height)), \(lines.count) numbered lines")
                for (column, x) in Set(lines.map { ($0.frame.minX / 100).rounded() }).sorted().enumerated() {
                    let ordered = lines.filter { ($0.frame.minX / 100).rounded() == x }.sorted { $0.frame.minY < $1.frame.minY }
                    note("visible", "column \(column): \(ordered.count) lines, first \(ordered.first?.label ?? ""), last \(ordered.last?.label ?? "")")
                }
            case "touch", "activate", "doubletap":
                // A touch moves VoiceOver to the item under it; a double tap then activates that item.
                let label = parts.last ?? ""
                let button = app.buttons[label].firstMatch
                let element = button.exists ? button
                    : app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
                guard element.waitForExistence(timeout: 5) else { note(step, "MISSING"); continue }
                // `doubletap` keeps the rotor's selection: the item must already hold the cursor.
                if parts[0] != "doubletap" {
                    element.tap()
                    heard(step)
                }
                guard parts[0] != "touch" else { continue }
                element.doubleTap()
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                heard("activated")
            case "flick":
                // One finger up or down steps through VoiceOver's rotor: for a line, its actions.
                // On an iPhone in landscape only the upward flick registers.
                switch parts.last {
                case "up": app.swipeUp(velocity: .fast)
                case "down": app.swipeDown(velocity: .fast)
                case "left": app.swipeLeft(velocity: .fast)
                default: app.swipeRight(velocity: .fast)
                }
                heard(step)
            case "wait":
                RunLoop.current.run(until: Date().addingTimeInterval(Double(parts.last ?? "") ?? 1))
            case "screenshot":
                // What is on the glass, independent of every accessibility cache.
                let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                attachment.name = "Screen \(events.count)"
                attachment.lifetime = .keepAlways
                add(attachment)
                note(step, attachment.name ?? "")
            case "rotate":
                XCUIDevice.shared.orientation = parts.last == "landscape" ? .landscapeLeft : .portrait
                RunLoop.current.run(until: Date().addingTimeInterval(3))
                heard(step)
            default: XCTFail("Unknown step \(step)")
            }
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
