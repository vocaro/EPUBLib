import XCTest
import XCUIAutomation
#if os(iOS)
import UIKit
#endif

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
        // VoiceOver cursor whenever the runner types. Without snapshots nothing below names an
        // application, so the same recording serves a session the runner holds in Safari.
        let app = XCUIApplication(bundleIdentifier: "org.epubreaderlib.voiceoververify.mac")
        let snapshots = environment["VOICEOVER_SNAPSHOTS"] != nil
        if snapshots { app.activate() }
        #else
        // In a teardown block, which runs however the test ends. An exception XCTest raises
        // for a gesture ends the test without unwinding it: a `defer` here did not run, and
        // VoiceOver stayed on on a phone.
        addTeardownBlock { @MainActor in
            let service = XCUIDevice.shared.voiceOverService
            if !wasEnabled && service.isEnabled {
                do { try service.disable() }
                catch { XCTFail("VoiceOver restoration failed: \(error)") }
            } else if wasEnabled && !service.isEnabled {
                do { try service.enable() }
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
        // Further launch arguments of the reader, with spaces between: `-SampleSelectionLine YES`.
        if let more = environment["VOICEOVER_LAUNCH"] { app.launchArguments += more.split(separator: " ").map(String.init) }
        let readerArguments = app.launchArguments
        if environment["VOICEOVER_ACTIVATION_CHECK"] == "1" {
            app.launchArguments = ["-VerificationActivationCheck", "YES"]
            app.launch()
            let button = app.buttons["activation.check"]
            XCTAssertTrue(button.waitForExistence(timeout: 20))
            let deadline = Date().addingTimeInterval(180)
            while (try? voiceOver.currentSpeech()) == nil, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            button.tap()
            app.typeKey(" ", modifierFlags: [.control, .option])
            let once = NSPredicate(format: "label == %@", "Activation check 1")
            guard XCTWaiter.wait(for: [expectation(for: once, evaluatedWith: button)], timeout: 5) == .completed else {
                XCTFail("Cursor activation self-test failed: keyboard command must activate exactly once")
                return
            }
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8)).doubleTap()
            let twice = NSPredicate(format: "label == %@", "Activation check 2")
            guard XCTWaiter.wait(for: [expectation(for: twice, evaluatedWith: button)], timeout: 5) == .completed else {
                XCTFail("Cursor activation self-test failed: off-target double tap must activate exactly once")
                return
            }
            // SwiftUI has updated the button twice. Focus its current element before
            // asking for actions, and use the same native iPad rotor as the reader matrix.
            button.tap()
            XCTAssertEqual(button.label, "Activation check 2")
            var actions = false
            for _ in 0..<30 {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    app.rotate(.pi / 12, withVelocity: 2)
                } else {
                    app.typeKey(.rightArrow, modifierFlags: [.control, .option, .command])
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                if (try? voiceOver.currentSpeech().utterance.hasPrefix("Actions")) == true { actions = true; break }
            }
            guard actions else { XCTFail("Activation self-test: Actions rotor missing"); return }
            var chosen = false
            for _ in 0..<4 {
                app.swipeUp(velocity: .fast)
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                if (try? voiceOver.currentSpeech().utterance.hasPrefix("Increment check")) == true { chosen = true; break }
            }
            guard chosen else { XCTFail("Activation self-test: custom action missing"); return }
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8)).doubleTap()
            let custom = NSPredicate(format: "label == %@", "Activation check 12")
            guard XCTWaiter.wait(for: [expectation(for: custom, evaluatedWith: button)], timeout: 5) == .completed else {
                XCTFail("Cursor activation self-test failed: custom action must add ten exactly once")
                return
            }
            print("VOICEOVER_ACTIVATION_CHECK passed: keyboard default, off-target default and off-target custom action each activated once")
            try voiceOver.disable()
            app.terminate()
            app.launchArguments = readerArguments
        }
        app.launch()
        let snapshots = true
        #endif
        // `waitForExistence` takes about a second even when the element is already there.
        guard !snapshots || app.buttons["Close"].exists || app.buttons["Close"].waitForExistence(timeout: 20) else {
            XCTFail("The bundled synthetic EPUB must be open")
            return
        }
        #if os(iOS)
        if environment["VOICEOVER_ACTIVATION_CHECK"] == "1" { try voiceOver.enable() }
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
        // see doc/testing.md#voiceover-testing.
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
        // `VOICEOVER_START_LIMIT` waits longer than three minutes, on a Mac other sessions keep busy.
        var silence: TimeInterval = 0
        let startLimit = environment["VOICEOVER_START_LIMIT"].flatMap(TimeInterval.init) ?? 180
        if !wasEnabled, voiceOver.isEnabled {
            let opened = Date()
            while (try? voiceOver.currentSpeech()) == nil {
                silence = Date().timeIntervalSince(opened)
                guard silence < startLimit else {
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
        // The action `choose` last looked for was not offered: a double tap would perform
        // whichever the rotor had come round to.
        var unchosen = false
        let strict = environment["VOICEOVER_STRICT"] == "1"
        var marks: [String: String] = [:]
        func visibleLabels() throws -> [String] {
            var labels: [String] = []
            let window = app.windows.firstMatch.frame
            func collect(_ element: any XCUIElementSnapshot, clip: CGRect) {
                // Continuous scroll lists context lines beyond its viewport. Some of those
                // still fall inside the window, behind the host's controls: clip to the
                // text/scroll surface too, rather than accepting an off-screen cached line.
                let clipped = element.elementType == .textView || element.elementType == .scrollView
                    ? clip.intersection(element.frame) : clip
                if element.children.isEmpty, !element.label.isEmpty, clipped.intersects(element.frame) {
                    labels.append(element.label.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                element.children.forEach { collect($0, clip: clipped) }
            }
            collect(try app.snapshot(), clip: window)
            return labels
        }
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
                // A counted number of moves, where `read` would go on through a whole book. On a
                // busy Mac the service can hand back the phrase from before the move, which reads
                // as an item said twice and the next one missing: a phrase that repeats the last
                // waits three seconds for VoiceOver's own, and is recorded as it stands after them.
                for _ in 0..<(Int(parts.last ?? "") ?? 1) {
                    let before = events.last?["utterance"]
                    var phrase = try (parts[0] == "forward" ? voiceOver.moveForward() : voiceOver.moveBackward()).utterance
                    let limit = Date().addingTimeInterval(3)
                    while phrase == before, Date() < limit {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                        phrase = (try? voiceOver.currentSpeech().utterance) ?? phrase
                    }
                    note(parts[0] == "forward" ? "moveForward" : "moveBackward", phrase)
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
            case "touch", "activate", "doubletap", "press":
                // A touch moves VoiceOver to the item under it; a double tap then activates that item.
                let label = parts.last ?? ""
                let button = app.buttons[label].firstMatch
                let element = button.exists ? button
                    : app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
                guard element.exists || element.waitForExistence(timeout: 5) else {
                    note(step, "MISSING")
                    if strict { XCTFail("Missing target: \(step)"); return }
                    continue
                }
                if parts[0] == "press" {
                    // A finger held on the item for a second: with VoiceOver off, the touch that
                    // selects the word under it and brings up the edit menu.
                    let before = screen()
                    element.press(forDuration: 1)
                    settle(before, limit: 2)
                    continue
                }
                if parts[0] == "doubletap", unchosen {
                    note(step, "SKIPPED: the action to perform was not offered")
                    continue
                }
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
            case "keyactivate":
                // VoiceOver's own Activate command, preserving the cursor and rotor choice.
                // Unlike a double tap on a named element, this cannot pass by touching a button.
                if unchosen {
                    note(step, "SKIPPED: the action to perform was not offered")
                    continue
                }
                let before = screen()
                app.typeKey(" ", modifierFlags: [.control, .option])
                settle(before, limit: 2)
                heard(step)
            case "point", "doublepoint":
                // A touch at a place in the window, as fractions of its width and height
                // (`point=0.5:0.4`): whatever is drawn there, listed or not.
                let offsets = (parts.last ?? "").split(separator: ":").compactMap { Double($0) }
                guard offsets.count == 2 else { XCTFail("point=X:Y"); continue }
                let point = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: offsets[0], dy: offsets[1]))
                if parts[0] == "doublepoint" {
                    guard !unchosen else { note(step, "SKIPPED: the action to perform was not offered"); continue }
                    let before = screen()
                    point.doubleTap()
                    settle(before, limit: 2)
                } else {
                    point.tap()
                }
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
            case "rotor", "keyrotor":
                // Two fingers turned on the glass turn VoiceOver's rotor, which names the setting
                // it comes to. `rotor=Headings` turns it until its phrase begins with that, thirty
                // turns at most; `flick=down` and `flick=up` then move by it. One turn of a given
                // size moved the rotor one setting in some sessions and three in others, which
                // went round and round past Headings: the turns are of several sizes. On a
                // physical iPad the five sizes together came round to the same five settings,
                // and Rows was never one of them: after two rounds the smallest turn is made
                // alone, which moved one setting at a time there. On a physical iPhone no turn
                // registered, on the screen, the window or the text.
                let wanted = parts.count > 1 ? parts[1] : ""
                let keyboard = parts[0] == "keyrotor"
                var found = wanted.isEmpty
                let turns: [CGFloat] = [.pi / 4, .pi / 6, .pi / 9, .pi / 5, .pi / 12]
                for turn in 0..<(wanted.isEmpty ? 1 : 30) {
                    if keyboard {
                        // VoiceOver's next rotor setting: independent of landscape touch geometry.
                        app.typeKey(.rightArrow, modifierFlags: [.control, .option, .command])
                    } else {
                        app.rotate(turn < 2 * turns.count ? turns[turn % turns.count] : .pi / 12, withVelocity: 2)
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                    let phrase = (try? voiceOver.currentSpeech().utterance) ?? "no speech"
                    note(parts[0], phrase)
                    // The setting's name comes first. Elsewhere in the phrase it can be the item's own
                    // hint, "Use the rotor to access Headings", when a turn did not register.
                    if !wanted.isEmpty, phrase.lowercased().hasPrefix(wanted.lowercased()) { found = true; break }
                }
                if !found {
                    note(step, "MISSING")
                    if strict { XCTFail("Missing rotor setting: \(step)"); return }
                }
            case "choose", "chooseup":
                // One finger through the rotor until VoiceOver names the requested action,
                // downward for choose and upward for chooseup, twelve steps at most. Where an
                // action stands depends on what else the item offers. It must hold the cursor.
                let wanted = parts.count > 1 ? parts[1] : ""
                let upward = parts[0] == "chooseup"
                var found = false
                for _ in 0..<12 where !found {
                    let before = try? voiceOver.currentSpeech().utterance
                    if upward { app.swipeUp(velocity: .fast) }
                    else { app.swipeDown(velocity: .fast) }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                    let limit = Date().addingTimeInterval(3)
                    while Date() < limit, (try? voiceOver.currentSpeech().utterance) == before {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    }
                    let phrase = (try? voiceOver.currentSpeech().utterance) ?? "no speech"
                    note(upward ? "flick=up" : "flick=down", phrase)
                    found = phrase.hasPrefix(wanted)
                }
                unchosen = !found
                if !found {
                    note(step, "MISSING")
                    if strict { XCTFail("Missing rotor action: \(step)"); return }
                }
            case "expect", "expectcontains":
                let wanted = parts.last ?? ""
                func matches(_ phrase: String) -> Bool {
                    parts[0] == "expect" ? phrase.hasPrefix(wanted) : phrase.contains(wanted)
                }
                let deadline = Date().addingTimeInterval(5)
                var phrase = (try? voiceOver.currentSpeech().utterance) ?? "no speech"
                while !matches(phrase), Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                    phrase = (try? voiceOver.currentSpeech().utterance) ?? "no speech"
                }
                note(step, phrase)
                XCTAssertTrue(matches(phrase), "Expected speech \(parts[0] == "expect" ? "beginning with" : "containing") \(wanted), got \(phrase)")
            case "expectstate":
                let line = app.staticTexts["sample.selection"].firstMatch
                note(step, line.exists ? line.label : "MISSING")
                XCTAssertTrue(line.exists)
                XCTAssertEqual(line.label, parts.last ?? "")
            case "exists", "absent":
                let target = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", parts.last ?? "")).firstMatch
                note(step, target.exists ? "present" : "absent")
                XCTAssertEqual(target.exists, parts[0] == "exists", step)
            case "focusvisible":
                var phrase = "", labels: [String] = []
                let deadline = Date().addingTimeInterval(3)
                repeat {
                    phrase = (try? voiceOver.currentSpeech().utterance) ?? "no speech"
                    labels = try visibleLabels()
                    if labels.contains(where: { phrase.hasPrefix($0) }) { break }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                } while Date() < deadline
                note(step, phrase)
                XCTAssertTrue(labels.contains { phrase.hasPrefix($0) }, "VoiceOver's cursor must name a currently visible item: \(phrase); visible labels: \(labels)")
            case "entertext":
                // Start on a host control after a scroll step. The first numbered line
                // VoiceOver reaches must be the first one on screen, including after a menu
                // has primed its cache (#428). Do not walk past a stale line to find a good one.
                let labels = try visibleLabels()
                let numbered = "word[0-9]{4}|p[0-9]{3}w[0-9]{2}"
                let first = try XCTUnwrap(labels.first { $0.range(of: numbered, options: .regularExpression) != nil })
                note("entertextExpected", first)
                var found = false
                for _ in 0..<20 {
                    let phrase = try voiceOver.moveForward().utterance
                    note("entertext", phrase)
                    if phrase.range(of: numbered, options: .regularExpression) != nil {
                        XCTAssertTrue(phrase.hasPrefix(first), "First line after activation must be the first visible line: \(first), got \(phrase)")
                        found = true
                        break
                    }
                    if phrase.hasPrefix("Chapter") {
                        XCTAssertTrue(labels.contains { phrase.hasPrefix($0) }, "VoiceOver reached a stale chapter heading: \(phrase)")
                    }
                }
                XCTAssertTrue(found, "VoiceOver never entered the visible text after activation")
            case "menuback":
                // The physical 27.2 iPad takes both paths after a chapter menu: pinned
                // controls, or the previous chapter. Check each observed continuation;
                // text must end chapter one and remain visible and consecutive, not stale.
                var phrase = try voiceOver.moveBackward().utterance
                note(step, phrase)
                if phrase.hasPrefix("Bookmark") {
                    for wanted in ["Paging", "Continuous Scroll", "Appearance"] {
                        phrase = try voiceOver.moveBackward().utterance
                        note(step, phrase)
                        XCTAssertTrue(phrase.contains(wanted), "Expected native control \(wanted), got \(phrase)")
                    }
                } else {
                    let pattern = try NSRegularExpression(pattern: "p([0-9]{3})w([0-9]{2})")
                    var previous = 1601 // forty paragraphs of forty words before Chapter two
                    for move in 0..<4 {
                        if move > 0 { phrase = try voiceOver.moveBackward().utterance; note(step, phrase) }
                        let text = phrase as NSString
                        let numbers = pattern.matches(in: phrase, range: NSRange(location: 0, length: text.length)).compactMap { match -> Int? in
                            guard let paragraph = Int(text.substring(with: match.range(at: 1))),
                                  let word = Int(text.substring(with: match.range(at: 2))),
                                  (1...40).contains(paragraph), (1...40).contains(word) else { return nil }
                            return (paragraph - 1) * 40 + word
                        }
                        guard let first = numbers.first, let last = numbers.last, first <= last else {
                            XCTFail("Expected the previous chapter's numbered text, got \(phrase)"); return
                        }
                        XCTAssertEqual(last, previous - 1, "Backward reading skipped or repeated words")
                        XCTAssertEqual(numbers.count, last - first + 1)
                        XCTAssertTrue(numbers.enumerated().allSatisfy { $0.element == first + $0.offset })
                        let labels = try visibleLabels()
                        XCTAssertTrue(labels.contains { phrase.hasPrefix($0) }, "Previous-chapter speech must be visible: \(phrase)")
                        previous = first
                    }
                }
            case "mark", "changed", "same":
                let key = parts.last ?? ""
                let value = try visibleLabels().joined(separator: "\n")
                if parts[0] == "mark" { marks[key] = value }
                else {
                    let previous = try XCTUnwrap(marks[key], "No mark named \(key)")
                    if parts[0] == "same" { XCTAssertEqual(value, previous, step) }
                    else { XCTAssertNotEqual(value, previous, step) }
                }
                note(step, "checked visible labels")
            case "readall":
                // VoiceOver reading on by itself, as two fingers swiped down start it: its
                // Read All key, Control-Option-A, from the item under its cursor. `readall=top`
                // is Control-Option-B, from the top of the screen. XCTest has no two-finger
                // swipe; a simulator's VoiceOver takes its keys. Nothing is recorded here:
                // `listen=` after it records what VoiceOver reads, and a touch or a move stops it.
                app.typeKey(parts.last == "top" ? "b" : "a", modifierFlags: [.control, .option])
            case "listen":
                // Every phrase VoiceOver speaks in that many seconds, where a step records one:
                // what it says by itself after a change, in the order it says it.
                let until = Date().addingTimeInterval(Double(parts.last ?? "") ?? 3)
                var last: String?
                while Date() < until {
                    let phrase = (try? voiceOver.currentSpeech().utterance) ?? "no speech"
                    if phrase != last {
                        last = phrase
                        note("heard", phrase)
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
            case "state":
                // The sample's own line of what the reader reports as selected and what its
                // selection action was last given (`-SampleSelectionLine YES`). Reading it moves
                // nothing: it is XCTest's snapshot, not a touch.
                let line = app.staticTexts["sample.selection"].firstMatch
                note(step, line.exists ? line.label : "MISSING")
                // What the pasteboard holds (`-SampleCopiedLine YES`) and what became of the
                // actions the sample performs itself (`-SampleActions`), where it shows them.
                for identifier in ["sample.copied", "sample.actions"] {
                    let more = app.staticTexts[identifier].firstMatch
                    if more.exists { note(step, more.label) }
                }
            case "find":
                // Whether anything on screen is named so, and what it is: an edit menu's Copy,
                // which is in no item's list of actions. Nothing is touched.
                let label = parts.last ?? ""
                let found = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", label))
                    .allElementsBoundByIndex.map { "\($0.elementType.rawValue) at \($0.frame.integral)" }
                note(step, found.isEmpty ? "nothing on screen is named so" : "\(found.count) on screen: " + found.joined(separator: "; "))
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
            case "relaunch", "fresh":
                // FLOW:SIZE:HREF starts another workflow in the same owned simulator. This
                // also exercises text-size changes and an already running VoiceOver process.
                let settings = (parts.last ?? "").split(separator: ":").map(String.init)
                guard settings.count == 4 else { XCTFail("relaunch=FLOW:SIZE:HREF:CONTROLS"); return }
                let fresh = parts[0] == "fresh" && environment["VOICEOVER_OFF"] == nil
                if fresh, voiceOver.isEnabled { try voiceOver.disable() }
                var arguments: [String] = []
                var index = 0
                while index < readerArguments.count {
                    if ["-SampleFlow", "-SampleFontSize", "-SampleHref", "-SampleControls"].contains(readerArguments[index]) { index += 2 }
                    else { arguments.append(readerArguments[index]); index += 1 }
                }
                app.terminate()
                app.launchArguments = arguments + ["-SampleFlow", settings[0], "-SampleFontSize", settings[1], "-SampleHref", settings[2], "-SampleControls", settings[3]]
                app.launch()
                XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 20))
                unchosen = false
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                if fresh {
                    try voiceOver.enable()
                    let deadline = Date().addingTimeInterval(startLimit)
                    var ready = false
                    repeat {
                        if (try? voiceOver.moveForward()) != nil { ready = true; break }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    } while Date() < deadline
                    guard ready else { XCTFail("Fresh VoiceOver session never became ready"); return }
                }
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
