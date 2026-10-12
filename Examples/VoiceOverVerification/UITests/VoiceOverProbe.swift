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
        // `VOICEOVER_BOOK=paragraphs` opens the book of ordinary paragraphs.
        if let book = environment["VOICEOVER_BOOK"] { app.launchArguments += ["-VerificationBook", book] }
        app.launch()
        let snapshots = true
        #endif
        // `waitForExistence` takes about a second even when the element is already there.
        guard !snapshots || app.buttons["Close"].exists || app.buttons["Close"].waitForExistence(timeout: 20) else {
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
        // Every label and frame XCTest sees in the reader, to tell when a change has finished.
        func screen() -> String {
            var items: [String] = []
            func collect(_ element: any XCUIElementSnapshot) {
                items.append("\(element.label) \(element.frame)")
                element.children.forEach(collect)
            }
            if let root = try? app.snapshot() { collect(root) }
            return items.joined(separator: "\n")
        }
        // Waits until the screen differs from `before` and has then held still for half a second,
        // for `limit` seconds at most: the fixed wait this replaces, which a step that changes
        // nothing still costs. The transcript says which it was.
        func settle(_ before: String, limit: TimeInterval) {
            let started = Date()
            var last = before, changed: Date?
            while Date().timeIntervalSince(started) < limit {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                let now = screen()
                if now != last {
                    last = now
                    changed = Date()
                } else if let changed, Date().timeIntervalSince(changed) >= 0.5 {
                    note("settled", String(format: "the screen changed and held still after %.1f s", changed.timeIntervalSince(started)))
                    return
                }
            }
            note("settled", String(format: changed == nil ? "nothing on screen changed in %.1f s" : "the screen was still changing after %.1f s", limit))
        }
        // Switched on is not yet running. On a newly booted simulator VoiceOver's first start
        // took 40 to 50 seconds on a busy Mac, by its log waiting for the voice database, while
        // `enable()` returned in a few. Until VoiceOver speaks, touches reach the reader as
        // plain touches and every move fails. `currentSpeech()` waits a second itself.
        var silence: TimeInterval = 0
        if !wasEnabled, voiceOver.isEnabled {
            let opened = Date()
            while (try? voiceOver.currentSpeech()) == nil {
                silence = Date().timeIntervalSince(opened)
                guard silence < 180 else {
                    note("voiceOver", "STOPPED: on but silent for \(Int(silence)) s")
                    XCTFail("VoiceOver is on but says nothing")
                    return
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        }
        note("voiceOver", wasEnabled ? "was already on" : !voiceOver.isEnabled ? "left off"
            : silence < 2 ? "turned on for this session" : "turned on for this session, silent for its first \(Int(silence)) s")
        heard("initial")
        let steps = (environment["VOICEOVER_STEPS"] ?? "read").split(separator: ",").map(String.init)
        for step in steps {
            let parts = step.split(separator: "=", maxSplits: 1).map(String.init)
            // Another session's app in front would be read and touched instead of the reader.
            guard app.state == .runningForeground else {
                note(step, "STOPPED: the reader is no longer in the foreground")
                XCTFail("The reader lost the foreground before \(step)")
                return
            }
            switch parts[0] {
            case "read":
                // Forward until VoiceOver stays on the last item. It then repeats that item's
                // phrase, about two seconds later, but so does a move to a second item with the
                // same label. One move back tells them apart: from the last item it reaches the
                // item before, which said something else; from a second item it reaches the first.
                var spoken = [events.last?["utterance"] ?? ""]
                var repeated = 0
                for _ in 0..<150 {
                    let phrase = try voiceOver.moveForward()
                    record("moveForward", phrase)
                    defer { spoken.append(phrase.utterance) }
                    guard phrase.utterance == spoken.last else { repeated = 0; continue }
                    if repeated == 0, spoken.count > 1, spoken[spoken.count - 2] != phrase.utterance {
                        let back = try voiceOver.moveBackward()
                        record("moveBackward", back)
                        record("moveForward", try voiceOver.moveForward())
                        if back.utterance == spoken[spoken.count - 2] {
                            note("read", "ended: VoiceOver had stayed on the last item")
                            break
                        }
                        // A second item with the same label, or VoiceOver did not move back:
                        // read on, and at the end three repeats follow.
                        if back.utterance == phrase.utterance { continue }
                    }
                    // Going back settled nothing: three repeats in a row, as before.
                    repeated += 1
                    if repeated >= 3 {
                        note("read", "ended: the same phrase three more times")
                        break
                    }
                }
            case "forward", "backward":
                // A counted number of moves, where `read` would go on through a whole book.
                for _ in 0..<(Int(parts.last ?? "") ?? 1) {
                    if parts[0] == "forward" { record("moveForward", try voiceOver.moveForward()) }
                    else { record("moveBackward", try voiceOver.moveBackward()) }
                }
            case "visible":
                // The numbered lines XCTest sees in each column, to compare with the speech. In
                // continuous scroll a line listed below or above the window is counted apart.
                var lines: [(label: String, frame: CGRect)] = []
                func collect(_ element: any XCUIElementSnapshot) {
                    if element.label.range(of: "word[01]|p[0-9]{3}w", options: .regularExpression) != nil {
                        lines.append((element.label, element.frame))
                    }
                    element.children.forEach(collect)
                }
                collect(try app.snapshot())
                let window = app.windows.firstMatch.frame
                func words(_ label: String?) -> String {
                    let all = (label ?? "").split(whereSeparator: \.isWhitespace)
                    return all.count > 8 ? all.prefix(4).joined(separator: " ") + " … " + all.suffix(2).joined(separator: " ") : all.joined(separator: " ")
                }
                note("visible", "window \(Int(window.width))x\(Int(window.height)), \(lines.count) numbered lines")
                for (column, x) in Set(lines.map { ($0.frame.minX / 100).rounded() }).sorted().enumerated() {
                    let listed = lines.filter { ($0.frame.minX / 100).rounded() == x }.sorted { $0.frame.minY < $1.frame.minY }
                    let ordered = listed.filter { $0.frame.maxY > window.minY && $0.frame.minY < window.maxY }
                    let outside = listed.count == ordered.count ? "" : " (and \(listed.count - ordered.count) outside the window: "
                        + "first \(words(listed.first?.label)) at y \(Int(listed.first?.frame.minY ?? 0)), "
                        + "last \(words(listed.last?.label)) at y \(Int(listed.last?.frame.minY ?? 0)))"
                    note("visible", "column \(column): \(ordered.count) lines, first \(words(ordered.first?.label)), last \(words(ordered.last?.label))\(outside)")
                }
            case "touch", "activate", "doubletap":
                // A touch moves VoiceOver to the item under it; a double tap then activates that item.
                let label = parts.last ?? ""
                let button = app.buttons[label].firstMatch
                let element = button.exists ? button
                    : app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
                guard element.exists || element.waitForExistence(timeout: 5) else { note(step, "MISSING"); continue }
                // `doubletap` keeps the rotor's selection: the item must already hold the cursor.
                if parts[0] != "doubletap" {
                    element.tap()
                    heard(step)
                }
                guard parts[0] != "touch" else { continue }
                let before = screen()
                element.doubleTap()
                settle(before, limit: 2)
                heard("activated")
            case "point":
                // A touch at a place in the window, as fractions of its width and height
                // (`point=0.5:0.4`): whatever is drawn there, listed or not.
                let offsets = (parts.last ?? "").split(separator: ":").compactMap { Double($0) }
                guard offsets.count == 2 else { XCTFail("point=X:Y"); continue }
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: offsets[0], dy: offsets[1])).tap()
                heard(step)
            case "flick":
                // One finger up or down steps through VoiceOver's rotor: for a line, its actions.
                // On an iPhone in landscape only the upward flick registers.
                // `flick=right*12` repeats it: VoiceOver's own next and previous item.
                let flick = (parts.last ?? "").split(separator: "*").map(String.init)
                for _ in 0..<(flick.count > 1 ? Int(flick[1]) ?? 1 : 1) {
                    let before = try? voiceOver.currentSpeech().utterance
                    switch flick.first {
                    case "up": app.swipeUp(velocity: .fast)
                    case "down": app.swipeDown(velocity: .fast)
                    case "left": app.swipeLeft(velocity: .fast)
                    default: app.swipeRight(velocity: .fast)
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                    // A move that turns pages, or a busy Mac under a simulator, can leave the
                    // phrase before the flick standing for a while: three seconds more for a
                    // new one. A flick that brings the same phrase again waits them out.
                    let limit = Date().addingTimeInterval(3)
                    while Date() < limit, (try? voiceOver.currentSpeech().utterance) == before {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    }
                    heard("flick=\(flick.first ?? "")")
                }
            case "rotor":
                // Two fingers turned on the glass turn VoiceOver's rotor to its next setting, which
                // it names. `rotor=Headings` turns it until it names that one, twenty turns at
                // most; `flick=down` and `flick=up` then move by it.
                let wanted = parts.count > 1 ? parts[1] : ""
                var found = wanted.isEmpty
                for _ in 0..<(wanted.isEmpty ? 1 : 20) {
                    app.rotate(.pi / 4, withVelocity: 2)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                    let phrase = (try? voiceOver.currentSpeech().utterance) ?? "no speech"
                    note("rotor", phrase)
                    if !wanted.isEmpty, phrase.localizedCaseInsensitiveContains(wanted) { found = true; break }
                }
                if !found { note(step, "MISSING") }
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
                let before = screen()
                XCUIDevice.shared.orientation = parts.last == "landscape" ? .landscapeLeft : .portrait
                settle(before, limit: 3)
                heard(step)
            default: XCTFail("Unknown step \(step)")
            }
        }
        // A transcript without this line stopped early, whatever became of the test session.
        note("finished", "all \(steps.count) steps")
        #endif
    }

    private func attach(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
